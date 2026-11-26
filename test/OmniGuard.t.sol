// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {OmniGuardTypes} from "../src/OmniGuardTypes.sol";
import {OmniGuardVault} from "../src/OmniGuardVault.sol";
import {CrossChainMirrorGuardian} from "../src/CrossChainMirrorGuardian.sol";
import {OmniGuardSentinel} from "../src/OmniGuardSentinel.sol";

/// @notice End-to-end simulation of the 3-chain Reactive Omni architecture:
///         Base Sepolia (84532) -> Reactive Lasna ReactVM (5318007) -> Base Sepolia + Unichain Sepolia (1301).
contract OmniGuardTest is Test {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    bytes32 internal constant CALLBACK_EVENT_SIG = keccak256("Callback(uint256,address,uint64,bytes)");

    address internal baseCallbackProxy = makeAddr("baseCallbackProxy");
    address internal unichainCallbackProxy = makeAddr("unichainCallbackProxy");
    address internal trader = makeAddr("trader");
    address internal attacker = makeAddr("attacker");
    address internal ethAsset = makeAddr("WETH");

    OmniGuardVault internal vault;
    CrossChainMirrorGuardian internal mirror;
    OmniGuardSentinel internal sentinel;

    function setUp() public {
        vm.warp(1_764_100_000);

        vault = new OmniGuardVault(baseCallbackProxy);
        mirror = new CrossChainMirrorGuardian(unichainCallbackProxy);

        // In Foundry local EVM, 0x...fffFfF has code size 0, so AbstractReactive sets vm = true (ReactVM mode),
        // matching live ReactVM runtime behavior where `react()` executes stateful event logic.
        sentinel = new OmniGuardSentinel(
            BASE_SEPOLIA_CHAIN_ID,
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(vault),
            address(mirror),
            3600,  // 1-hour slippage decay window
            500,   // 5.00% cumulative slippage breach threshold
            86400, // 24-hour stale accrual threshold
            9000,  // 90.00% critical utilization threshold
            7000   // 70.00% single-step utilization jump threshold
        );
    }

    /*//////////////////////////////////////////////////////////////
              TEST 1: MULTI-STEP SLOW-BLEED SLIPPAGE BREACH
    //////////////////////////////////////////////////////////////*/

    function test_cumulativeSlowBleedSlippageTripsDualChainCircuitBreaker() public {
        // Each swap has 190 bps (1.90%) slippage — below the vault's local 200 bps (2.00%) cap!
        // Swap 1: 1.90% -> cumulative 1.90% (< 5.00%, NO false positive)
        _executeSwapAndRelay(100_000e6, 98_100e6, 1);
        assertFalse(vault.circuitBreakerTripped(), "swap 1 should not trip breaker");
        assertFalse(mirror.crossChainFreezeActive(), "swap 1 should not freeze mirror");

        // Swap 2 (60 seconds later): decayed ~186 bps + 190 bps = ~376 bps (< 5.00%, still below)
        vm.warp(vm.getBlockTimestamp() + 60);
        _executeSwapAndRelay(100_000e6, 98_100e6, 2);
        assertFalse(vault.circuitBreakerTripped(), "swap 2 should not trip breaker");

        // Swap 3 (60 seconds later): decayed ~369 bps + 190 bps = ~559 bps (>= 5.00% BREACH!)
        vm.warp(vm.getBlockTimestamp() + 60);
        uint256 originTs = vm.getBlockTimestamp();
        uint256 callbacksDelivered = _executeSwapAndRelayWithLatency(100_000e6, 98_100e6, 3, 1);

        assertEq(callbacksDelivered, 2, "must emit dual-chain callbacks (Base + Unichain)");
        assertTrue(vault.circuitBreakerTripped(), "Base Sepolia vault must be frozen");
        assertEq(vault.lastTripReason(), OmniGuardTypes.REASON_CUMULATIVE_SLIPPAGE);
        assertEq(vault.maxSingleSwapSlippageBps(), 25, "slippage cap must tighten to 25 bps");
        assertTrue(mirror.crossChainFreezeActive(), "Unichain Sepolia mirror must be frozen");
        assertEq(mirror.lastFreezeReason(), OmniGuardTypes.REASON_CUMULATIVE_SLIPPAGE);
        assertEq(mirror.lastAffectedOriginVault(), address(vault));

        // Verify exact 1-second Reactive Omni latency instrumentation on both chains
        OmniGuardTypes.LatencyStats memory baseStats = vault.getLatencyStats();
        OmniGuardTypes.LatencyStats memory mirrorStats = mirror.getLatencyStats();
        assertEq(baseStats.totalCallbacks, 1);
        assertEq(baseStats.avgLatencySeconds, 1);
        assertEq(mirrorStats.totalCallbacks, 1);
        assertEq(mirrorStats.avgLatencySeconds, 1);

        // Subsequent swaps on Base Sepolia MUST revert immediately
        vm.expectRevert(OmniGuardVault.CircuitBreakerActive.selector);
        vault.recordVaultSwap(100_000e6, 99_900e6);

        // Verify origin timestamp recorded accurately
        (, , , uint256 recOriginTs, uint256 recCbTs, uint256 recLatency, ) = vault.callbackHistory(0);
        assertEq(recOriginTs, originTs);
        assertEq(recCbTs, originTs + 1);
        assertEq(recLatency, 1);
    }

    function test_decayedSlippageDoesNotTriggerFalsePositive() public {
        _executeSwapAndRelay(100_000e6, 98_100e6, 10);
        _executeSwapAndRelay(100_000e6, 98_100e6, 11);

        // Wait past full 1-hour decay window: accumulator decays to 0
        vm.warp(vm.getBlockTimestamp() + 3601);
        uint256 callbacks = _executeSwapAndRelayWithLatency(100_000e6, 98_100e6, 12, 1);
        assertEq(callbacks, 0, "decayed slippage must not trigger false positive");
        assertFalse(vault.circuitBreakerTripped());
    }

    function test_singleSwapExceedingLocalCapRevertsImmediately() public {
        vm.expectRevert(abi.encodeWithSelector(OmniGuardVault.SingleSwapSlippageExceeded.selector, 250, 200));
        vault.recordVaultSwap(100_000e6, 97_500e6);
    }

    /*//////////////////////////////////////////////////////////////
          TEST 2: STALE ACCRUAL + UTILIZATION SPIKE DETECTION
    //////////////////////////////////////////////////////////////*/

    function test_staleAccrualAndHighUtilizationTripsDualBreaker() public {
        vm.recordLogs();
        // 30 days stale last-update + 99.5% utilization spike
        vault.recordVaultAccrual(9950, 30 days, 1_990_000e6);
        Vm.Log[] memory originLogs = vm.getRecordedLogs();

        IReactive.LogRecord memory rec = _toLogRecord(originLogs[0], 100);
        uint256 delivered = _reactAndDispatch(rec, 2);

        assertEq(delivered, 2, "must trigger both Base and Unichain circuit breakers");
        assertTrue(vault.circuitBreakerTripped());
        assertEq(vault.lastTripReason(), OmniGuardTypes.REASON_STALE_ACCRUAL_SPIKE);
        assertTrue(mirror.crossChainFreezeActive());
        assertEq(mirror.lastFreezeReason(), OmniGuardTypes.REASON_STALE_ACCRUAL_SPIKE);
        assertEq(vault.getLatencyStats().avgLatencySeconds, 2);
    }

    function test_flashUtilizationJumpTripsDualBreaker() public {
        // Baseline healthy accrual at 10% utilization
        vm.recordLogs();
        vault.recordVaultAccrual(1000, 12, 0);
        Vm.Log[] memory baseLogs = vm.getRecordedLogs();
        assertEq(_reactAndDispatch(_toLogRecord(baseLogs[0], 101), 0), 0, "baseline accrual must not trip");

        // Sudden 75% jump (10% -> 85%) in a single block even with fresh timestamp
        vm.recordLogs();
        vault.recordVaultAccrual(8500, 12, 5_000_000e6);
        Vm.Log[] memory jumpLogs = vm.getRecordedLogs();
        uint256 delivered = _reactAndDispatch(_toLogRecord(jumpLogs[0], 102), 1);

        assertEq(delivered, 2, "single-step utilization jump trips dual-chain breaker");
        assertTrue(vault.circuitBreakerTripped());
        assertEq(vault.lastTripReason(), OmniGuardTypes.REASON_FLASH_UTILIZATION_JUMP);
        assertTrue(mirror.crossChainFreezeActive());
        assertEq(mirror.lastFreezeReason(), OmniGuardTypes.REASON_FLASH_UTILIZATION_JUMP);
    }

    /*//////////////////////////////////////////////////////////////
             TEST 3: KEEPER-LESS SUB-SECOND STOP-LOSS & HEDGE
    //////////////////////////////////////////////////////////////*/

    function test_keeperlessStopLossAndCrossChainHedge() public {
        // Trader registers a stop-loss at $3,000.00 (3000e8) and a take-profit at $4,000.00 (4000e8)
        vm.recordLogs();
        vm.prank(trader);
        uint256 slOrderId = vault.registerOrder(10 ether, 3000e8, true);
        Vm.Log[] memory regLogs1 = vm.getRecordedLogs();
        sentinel.react(_toLogRecord(regLogs1[0], 201));

        vm.recordLogs();
        vm.prank(trader);
        uint256 tpOrderId = vault.registerOrder(5 ether, 4000e8, false);
        Vm.Log[] memory regLogs2 = vm.getRecordedLogs();
        sentinel.react(_toLogRecord(regLogs2[0], 202));

        assertEq(sentinel.getActiveOrdersCount(), 2);

        // Price tick at $3,500 — neither order triggers
        vm.recordLogs();
        vault.publishPriceTick(ethAsset, 3500e8);
        Vm.Log[] memory neutralTick = vm.getRecordedLogs();
        assertEq(_reactAndDispatch(_toLogRecord(neutralTick[0], 203), 1), 0, "neutral tick triggers 0 orders");
        assertEq(sentinel.getActiveOrdersCount(), 2);

        // Flash drop to $2,950 — stop-loss triggers in 1 second + cross-chain hedge mirrors on Unichain!
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.recordLogs();
        vault.publishPriceTick(ethAsset, 2950e8);
        Vm.Log[] memory crashTick = vm.getRecordedLogs();
        uint256 delivered = _reactAndDispatch(_toLogRecord(crashTick[0], 204), 1);

        assertEq(delivered, 2, "stop-loss settlement + Unichain hedge signal");
        assertEq(sentinel.getActiveOrdersCount(), 1, "only TP order remains active");

        (, , , , bool slActive, , uint256 settledAt, uint256 settledPrice) = vault.orders(slOrderId);
        assertFalse(slActive, "stop-loss order must be marked settled");
        assertEq(settledPrice, 2950e8);
        assertGt(settledAt, 0);
        assertEq(mirror.hedgedOrderPriceD8(slOrderId), 2950e8);

        // Rally to $4,100 — take-profit order settles cleanly in 1 second!
        vm.warp(vm.getBlockTimestamp() + 15);
        vm.recordLogs();
        vault.publishPriceTick(ethAsset, 4100e8);
        Vm.Log[] memory rallyTick = vm.getRecordedLogs();
        uint256 tpDelivered = _reactAndDispatch(_toLogRecord(rallyTick[0], 205), 1);
        assertEq(tpDelivered, 2, "take-profit settlement + Unichain hedge signal");
        assertEq(sentinel.getActiveOrdersCount(), 0, "all orders settled");

        (, , , , bool tpActive, , , uint256 tpSettledPrice) = vault.orders(tpOrderId);
        assertFalse(tpActive, "take-profit order must be marked settled");
        assertEq(tpSettledPrice, 4100e8);
        assertEq(mirror.hedgeSignalsCount(), 2);
    }

    function test_duplicateIncidentIdRevertsReplay() public {
        bytes32 incidentId = keccak256("replay-incident");
        vm.prank(baseCallbackProxy);
        vault.executeCircuitBreaker(address(this), 1, 500, vm.getBlockTimestamp(), incidentId);

        vm.prank(baseCallbackProxy);
        vm.expectRevert(abi.encodeWithSelector(OmniGuardVault.IncidentAlreadyProcessed.selector, incidentId));
        vault.executeCircuitBreaker(address(this), 1, 500, vm.getBlockTimestamp(), incidentId);

        vm.prank(unichainCallbackProxy);
        mirror.tripCrossChainBreaker(address(this), address(vault), 1, 500, vm.getBlockTimestamp(), incidentId);

        vm.prank(unichainCallbackProxy);
        vm.expectRevert(abi.encodeWithSelector(CrossChainMirrorGuardian.IncidentAlreadyProcessed.selector, incidentId));
        mirror.tripCrossChainBreaker(address(this), address(vault), 1, 500, vm.getBlockTimestamp(), incidentId);
    }

    /*//////////////////////////////////////////////////////////////
                 TEST 4: SECURITY & ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_unauthorizedCallbackSenderReverts() public {
        vm.prank(attacker);
        vm.expectRevert("Authorized sender only");
        vault.executeCircuitBreaker(address(this), 1, 500, block.timestamp, keccak256("spoof"));
    }

    function test_wrongRvmIdReverts() public {
        vm.prank(baseCallbackProxy);
        vm.expectRevert("Authorized RVM ID only");
        vault.executeCircuitBreaker(attacker, 1, 500, block.timestamp, keccak256("wrong-rvm"));
    }

    function test_adminResetRestoresVaultOperations() public {
        test_staleAccrualAndHighUtilizationTripsDualBreaker();
        vault.resetCircuitBreaker(100);
        assertFalse(vault.circuitBreakerTripped());
        assertEq(vault.maxSingleSwapSlippageBps(), 100);

        // Vault accepts normal low-slippage swap again
        uint256 swapId = vault.recordVaultSwap(10_000e6, 9_950e6);
        assertEq(swapId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL RELAY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _executeSwapAndRelay(uint256 valueIn, uint256 valueOut, uint256 txSeed) internal returns (uint256) {
        return _executeSwapAndRelayWithLatency(valueIn, valueOut, txSeed, 1);
    }

    function _executeSwapAndRelayWithLatency(
        uint256 valueIn,
        uint256 valueOut,
        uint256 txSeed,
        uint256 simulatedLatencySeconds
    ) internal returns (uint256) {
        vm.recordLogs();
        vault.recordVaultSwap(valueIn, valueOut);
        Vm.Log[] memory originLogs = vm.getRecordedLogs();
        return _reactAndDispatch(_toLogRecord(originLogs[0], txSeed), simulatedLatencySeconds);
    }

    function _toLogRecord(Vm.Log memory entry, uint256 txSeed) internal view returns (IReactive.LogRecord memory rec) {
        rec = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: entry.emitter,
            topic_0: entry.topics.length > 0 ? uint256(entry.topics[0]) : 0,
            topic_1: entry.topics.length > 1 ? uint256(entry.topics[1]) : 0,
            topic_2: entry.topics.length > 2 ? uint256(entry.topics[2]) : 0,
            topic_3: entry.topics.length > 3 ? uint256(entry.topics[3]) : 0,
            data: entry.data,
            block_number: block.number,
            op_code: 0,
            block_hash: uint256(keccak256(abi.encodePacked(block.number))),
            tx_hash: uint256(keccak256(abi.encodePacked(txSeed, vm.getBlockTimestamp()))),
            log_index: 0
        });
    }

    /// @dev Runs `sentinel.react(rec)` and routes any emitted `Callback` events through the
    ///      authentic Callback Proxy with the deployer's RVM ID injected into arg 0, matching
    ///      Reactive Network's live callback delivery semantics.
    function _reactAndDispatch(
        IReactive.LogRecord memory rec,
        uint256 simulatedLatencySeconds
    ) internal returns (uint256 delivered) {
        vm.recordLogs();
        sentinel.react(rec);
        Vm.Log[] memory reactiveLogs = vm.getRecordedLogs();

        if (simulatedLatencySeconds > 0) {
            vm.warp(vm.getBlockTimestamp() + simulatedLatencySeconds);
        }

        for (uint256 i = 0; i < reactiveLogs.length; ++i) {
            if (reactiveLogs[i].topics[0] == CALLBACK_EVENT_SIG) {
                uint256 destChainId = uint256(reactiveLogs[i].topics[1]);
                address destContract = address(uint160(uint256(reactiveLogs[i].topics[2])));
                bytes memory payload = abi.decode(reactiveLogs[i].data, (bytes));

                // Reactive Network overwrites the first 32-byte word after the 4-byte selector with RVM ID (address(this))
                bytes memory injectedPayload = _injectRvmId(payload, address(this));
                address proxy = destChainId == BASE_SEPOLIA_CHAIN_ID ? baseCallbackProxy : unichainCallbackProxy;

                vm.prank(proxy);
                (bool ok, bytes memory ret) = destContract.call(injectedPayload);
                require(ok, string(abi.encodePacked("callback failed: ", ret)));
                delivered += 1;
            }
        }
    }

    function _injectRvmId(bytes memory payload, address rvmId) internal pure returns (bytes memory out) {
        require(payload.length >= 36, "payload too short");
        out = payload;
        assembly {
            mstore(add(out, 36), rvmId)
        }
    }
}
