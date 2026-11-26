// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {OmniGuardTypes} from "../src/OmniGuardTypes.sol";
import {OmniGuardVault} from "../src/OmniGuardVault.sol";
import {CrossChainMirrorGuardian} from "../src/CrossChainMirrorGuardian.sol";
import {OmniGuardSentinel} from "../src/OmniGuardSentinel.sol";
import {MockReactiveSystem} from "./MockReactiveSystem.sol";

/// @notice End-to-end simulation of the native Reactive Omni 3-chain architecture:
///         Base Sepolia (84532) -> Reactive Lasna Omni (5318007, SYSTEM 0x8888...8888)
///         -> Base Sepolia + Unichain Sepolia (1301).
contract OmniGuardTest is Test {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;
    bytes32 internal constant MOCK_CB_EVENT_SIG =
        keccak256("MockCallbackRequested(address,uint256,address,uint64,bytes)");

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

        MockReactiveSystem impl = new MockReactiveSystem();
        vm.etch(OMNI_SYSTEM, address(impl).code);

        // Compute deterministic OmniGuardSentinel address deployed 2 nonces after Vault & Mirror
        uint64 curNonce = vm.getNonce(address(this));
        address predictedSentinel = vm.computeCreateAddress(address(this), curNonce + 2);

        vault = new OmniGuardVault(baseCallbackProxy, predictedSentinel);
        mirror = new CrossChainMirrorGuardian(unichainCallbackProxy, predictedSentinel);
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
        assertEq(address(sentinel), predictedSentinel, "deterministic sentinel address must match");
        assertEq(MockReactiveSystem(payable(OMNI_SYSTEM)).subscribeCount(), 1, "must subscribe to origin vault");
    }

    function test_cumulativeSlowBleedSlippageTripsDualChainCircuitBreaker() public {
        _executeSwapAndRelay(100_000e6, 98_100e6, 1);
        assertFalse(vault.circuitBreakerTripped(), "swap 1 should not trip breaker");
        assertFalse(mirror.crossChainFreezeActive(), "swap 1 should not freeze mirror");

        vm.warp(vm.getBlockTimestamp() + 60);
        _executeSwapAndRelay(100_000e6, 98_100e6, 2);
        assertFalse(vault.circuitBreakerTripped(), "swap 2 should not trip breaker");

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

        OmniGuardTypes.LatencyStats memory baseStats = vault.getLatencyStats();
        OmniGuardTypes.LatencyStats memory mirrorStats = mirror.getLatencyStats();
        assertEq(baseStats.totalCallbacks, 1);
        assertEq(baseStats.avgLatencySeconds, 1);
        assertEq(mirrorStats.totalCallbacks, 1);
        assertEq(mirrorStats.avgLatencySeconds, 1);

        vm.expectRevert(OmniGuardVault.CircuitBreakerActive.selector);
        vault.recordVaultSwap(100_000e6, 99_900e6);

        (, uint64 recOriginTs, uint64 recCbTs, uint64 recLatency, , , ) = vault.callbackHistory(0);
        assertEq(recOriginTs, originTs);
        assertEq(recCbTs, originTs + 1);
        assertEq(recLatency, 1);
    }

    function test_decayedSlippageDoesNotTriggerFalsePositive() public {
        _executeSwapAndRelay(100_000e6, 98_100e6, 10);
        _executeSwapAndRelay(100_000e6, 98_100e6, 11);

        vm.warp(vm.getBlockTimestamp() + 3601);
        uint256 callbacks = _executeSwapAndRelayWithLatency(100_000e6, 98_100e6, 12, 1);
        assertEq(callbacks, 0, "decayed slippage must not trigger false positive");
        assertFalse(vault.circuitBreakerTripped());
    }

    function test_singleSwapExceedingLocalCapRevertsImmediately() public {
        vm.expectRevert(abi.encodeWithSelector(OmniGuardVault.SingleSwapSlippageExceeded.selector, 250, 200));
        vault.recordVaultSwap(100_000e6, 97_500e6);
    }

    function test_staleAccrualAndHighUtilizationTripsDualBreaker() public {
        vm.recordLogs();
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
        vm.recordLogs();
        vault.recordVaultAccrual(1000, 12, 0);
        Vm.Log[] memory baseLogs = vm.getRecordedLogs();
        assertEq(_reactAndDispatch(_toLogRecord(baseLogs[0], 101), 0), 0, "baseline accrual must not trip");

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

    function test_keeperlessStopLossAndCrossChainHedge() public {
        vm.recordLogs();
        vm.prank(trader);
        uint256 slOrderId = vault.registerOrder(10 ether, 3000e8, true);
        vm.prank(OMNI_SYSTEM);
        sentinel.react(_toLogRecord(vm.getRecordedLogs()[0], 201));

        vm.recordLogs();
        vm.prank(trader);
        uint256 tpOrderId = vault.registerOrder(5 ether, 4000e8, false);
        vm.prank(OMNI_SYSTEM);
        sentinel.react(_toLogRecord(vm.getRecordedLogs()[0], 202));

        assertEq(sentinel.getActiveOrdersCount(), 2);

        vm.recordLogs();
        vault.publishPriceTick(ethAsset, 3500e8);
        assertEq(_reactAndDispatch(_toLogRecord(vm.getRecordedLogs()[0], 203), 1), 0, "neutral tick triggers 0 orders");
        assertEq(sentinel.getActiveOrdersCount(), 2);

        vm.warp(vm.getBlockTimestamp() + 10);
        vm.recordLogs();
        vault.publishPriceTick(ethAsset, 2950e8);
        uint256 delivered = _reactAndDispatch(_toLogRecord(vm.getRecordedLogs()[0], 204), 1);

        assertEq(delivered, 2, "stop-loss settlement + Unichain hedge signal");
        assertEq(sentinel.getActiveOrdersCount(), 1, "only TP order remains active");

        (, , , , bool slActive, , uint256 settledAt, uint256 settledPrice) = vault.orders(slOrderId);
        assertFalse(slActive, "stop-loss order must be marked settled");
        assertEq(settledPrice, 2950e8);
        assertGt(settledAt, 0);
        assertEq(mirror.hedgedOrderPriceD8(slOrderId), 2950e8);

        vm.warp(vm.getBlockTimestamp() + 15);
        vm.recordLogs();
        vault.publishPriceTick(ethAsset, 4100e8);
        uint256 tpDelivered = _reactAndDispatch(_toLogRecord(vm.getRecordedLogs()[0], 205), 1);
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
        vault.executeCircuitBreaker(address(sentinel), 1, 500, vm.getBlockTimestamp(), incidentId);

        vm.prank(baseCallbackProxy);
        vm.expectRevert(abi.encodeWithSelector(OmniGuardVault.IncidentAlreadyProcessed.selector, incidentId));
        vault.executeCircuitBreaker(address(sentinel), 1, 500, vm.getBlockTimestamp(), incidentId);

        vm.prank(unichainCallbackProxy);
        mirror.tripCrossChainBreaker(address(sentinel), address(vault), 1, 500, vm.getBlockTimestamp(), incidentId);

        vm.prank(unichainCallbackProxy);
        vm.expectRevert(abi.encodeWithSelector(CrossChainMirrorGuardian.IncidentAlreadyProcessed.selector, incidentId));
        mirror.tripCrossChainBreaker(address(sentinel), address(vault), 1, 500, vm.getBlockTimestamp(), incidentId);
    }

    function test_unauthorizedCallbackProxyAndSenderRevert() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, attacker, baseCallbackProxy));
        vault.executeCircuitBreaker(address(sentinel), 1, 500, block.timestamp, keccak256("spoof"));

        vm.prank(baseCallbackProxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, attacker, address(sentinel)));
        vault.executeCircuitBreaker(attacker, 1, 500, block.timestamp, keccak256("wrong-sender"));

        // Sentinel react() must reject non-SYSTEM callers
        IReactive.LogRecord memory emptyRec;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, attacker, OMNI_SYSTEM));
        sentinel.react(emptyRec);
    }

    function test_adminResetAndSentinelPauseResume() public {
        test_staleAccrualAndHighUtilizationTripsDualBreaker();
        vault.resetCircuitBreaker(100);
        assertFalse(vault.circuitBreakerTripped());
        assertEq(vault.maxSingleSwapSlippageBps(), 100);

        uint256 swapId = vault.recordVaultSwap(10_000e6, 9_950e6);
        assertEq(swapId, 1);

        sentinel.pause();
        assertTrue(sentinel.paused());
        assertEq(MockReactiveSystem(payable(OMNI_SYSTEM)).unsubscribeCount(), 1);

        sentinel.resume();
        assertFalse(sentinel.paused());
        assertEq(MockReactiveSystem(payable(OMNI_SYSTEM)).subscribeCount(), 2);
    }

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
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: entry.emitter,
            topic0: entry.topics.length > 0 ? uint256(entry.topics[0]) : 0,
            topic1: entry.topics.length > 1 ? uint256(entry.topics[1]) : 0,
            topic2: entry.topics.length > 2 ? uint256(entry.topics[2]) : 0,
            topic3: entry.topics.length > 3 ? uint256(entry.topics[3]) : 0,
            data: entry.data,
            blockNumber: block.number,
            opCode: entry.topics.length,
            blockHash: uint256(keccak256(abi.encodePacked(block.number))),
            txHash: uint256(keccak256(abi.encodePacked(txSeed, vm.getBlockTimestamp()))),
            logIndex: 0
        });
    }

    function _reactAndDispatch(
        IReactive.LogRecord memory rec,
        uint256 simulatedLatencySeconds
    ) internal returns (uint256 delivered) {
        vm.recordLogs();
        vm.prank(OMNI_SYSTEM);
        sentinel.react(rec);
        Vm.Log[] memory reactiveLogs = vm.getRecordedLogs();

        if (simulatedLatencySeconds > 0) {
            vm.warp(vm.getBlockTimestamp() + simulatedLatencySeconds);
        }

        for (uint256 i = 0; i < reactiveLogs.length; ++i) {
            if (reactiveLogs[i].topics[0] == MOCK_CB_EVENT_SIG) {
                address reactiveContract = address(uint160(uint256(reactiveLogs[i].topics[1])));
                uint256 destChainId = uint256(reactiveLogs[i].topics[2]);
                address destContract = address(uint160(uint256(reactiveLogs[i].topics[3])));
                (, bytes memory payload) = abi.decode(reactiveLogs[i].data, (uint64, bytes));

                // Reactive Omni Callback Proxy overwrites arg 0 with the calling reactive contract address
                bytes memory injectedPayload = _injectSender(payload, reactiveContract);
                address proxy = destChainId == BASE_SEPOLIA_CHAIN_ID ? baseCallbackProxy : unichainCallbackProxy;

                vm.prank(proxy);
                (bool ok, bytes memory ret) = destContract.call(injectedPayload);
                require(ok, string(abi.encodePacked("callback failed: ", ret)));
                delivered += 1;
            }
        }
    }

    function _injectSender(bytes memory payload, address sender) internal pure returns (bytes memory out) {
        require(payload.length >= 36, "payload too short");
        out = payload;
        assembly {
            mstore(add(out, 36), sender)
        }
    }
}
