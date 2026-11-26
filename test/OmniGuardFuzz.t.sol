// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {OmniGuardTypes} from "../src/OmniGuardTypes.sol";
import {OmniGuardVault} from "../src/OmniGuardVault.sol";
import {CrossChainMirrorGuardian} from "../src/CrossChainMirrorGuardian.sol";
import {OmniGuardSentinel} from "../src/OmniGuardSentinel.sol";

/// @notice Fuzz & property-based verification suite for OmniGuard's 3-chain Reactive Omni architecture.
contract OmniGuardFuzzTest is Test {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    bytes32 internal constant CALLBACK_EVENT_SIG = keccak256("Callback(uint256,address,uint64,bytes)");

    address internal baseCallbackProxy = makeAddr("baseCallbackProxy");
    address internal unichainCallbackProxy = makeAddr("unichainCallbackProxy");
    address internal ethAsset = makeAddr("WETH");

    OmniGuardVault internal vault;
    CrossChainMirrorGuardian internal mirror;
    OmniGuardSentinel internal sentinel;

    function setUp() public {
        vm.warp(1_764_100_000);
        vault = new OmniGuardVault(baseCallbackProxy);
        mirror = new CrossChainMirrorGuardian(unichainCallbackProxy);
        sentinel = new OmniGuardSentinel(
            BASE_SEPOLIA_CHAIN_ID,
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(vault),
            address(mirror),
            3600,
            500,
            86400,
            9000,
            7000
        );
    }

    function testFuzz_decayingSlippageMonotonicAndBounded(
        uint16 slip1Bps,
        uint16 slip2Bps,
        uint32 dtSeconds
    ) public {
        slip1Bps = uint16(bound(slip1Bps, 1, 200));
        slip2Bps = uint16(bound(slip2Bps, 1, 200));
        dtSeconds = uint32(bound(dtSeconds, 0, 7200));

        uint256 valIn = 100_000e6;
        uint256 valOut1 = (valIn * (10_000 - slip1Bps)) / 10_000;
        uint256 valOut2 = (valIn * (10_000 - slip2Bps)) / 10_000;

        uint256 ts1 = vm.getBlockTimestamp();
        uint256 cb1 = _swapAndRelay(valIn, valOut1, 1);
        assertEq(cb1, 0, "single swap <= 200 bps must never breach 500 bps cap");

        vm.warp(ts1 + dtSeconds);
        uint256 ts2 = vm.getBlockTimestamp();
        uint256 cb2 = _swapAndRelay(valIn, valOut2, 2);
        assertEq(cb2, 0, "two swaps <= 200 bps each (<= 400 bps total) must never breach 500 bps cap");

        (uint256 acc, uint256 lastTs, , ) = sentinel.vaultRiskState(address(vault));
        assertEq(lastTs, ts2);
        uint256 expectedDecayed = dtSeconds >= 3600 ? 0 : (uint256(slip1Bps) * (3600 - dtSeconds)) / 3600;
        assertEq(acc, expectedDecayed + slip2Bps, "decayed cumulative slippage must match exact linear decay");
    }

    function testFuzz_multiOrderStopLossAndTakeProfitSettlement(
        uint64 slTrigger,
        uint64 tpTrigger,
        uint64 tickPrice
    ) public {
        slTrigger = uint64(bound(slTrigger, 100e8, 3000e8));
        tpTrigger = uint64(bound(tpTrigger, 3001e8, 10_000e8));
        tickPrice = uint64(bound(tickPrice, 1e8, 15_000e8));

        vm.recordLogs();
        uint256 slId = vault.registerOrder(5 ether, slTrigger, true);
        sentinel.react(_toLogRecord(vm.getRecordedLogs()[0], 10));

        vm.recordLogs();
        uint256 tpId = vault.registerOrder(5 ether, tpTrigger, false);
        sentinel.react(_toLogRecord(vm.getRecordedLogs()[0], 11));

        assertEq(sentinel.getActiveOrdersCount(), 2);

        vm.warp(vm.getBlockTimestamp() + 2);
        vm.recordLogs();
        vault.publishPriceTick(ethAsset, tickPrice);
        uint256 delivered = _reactAndDispatch(_toLogRecord(vm.getRecordedLogs()[0], 12), 1);

        bool expectSl = tickPrice <= slTrigger;
        bool expectTp = tickPrice >= tpTrigger;

        if (expectSl) {
            assertEq(delivered, 2);
            (, , , , bool activeSl, , , uint256 settledPx) = vault.orders(slId);
            assertFalse(activeSl);
            assertEq(settledPx, tickPrice);
            assertEq(mirror.hedgedOrderPriceD8(slId), tickPrice);
            assertEq(sentinel.getActiveOrdersCount(), 1);
        } else if (expectTp) {
            assertEq(delivered, 2);
            (, , , , bool activeTp, , , uint256 settledPx) = vault.orders(tpId);
            assertFalse(activeTp);
            assertEq(settledPx, tickPrice);
            assertEq(mirror.hedgedOrderPriceD8(tpId), tickPrice);
            assertEq(sentinel.getActiveOrdersCount(), 1);
        } else {
            assertEq(delivered, 0);
            assertEq(sentinel.getActiveOrdersCount(), 2);
        }
    }

    function testFuzz_accrualThresholdClassification(uint16 utilBps, uint32 staleSeconds) public {
        utilBps = uint16(bound(utilBps, 0, 10_000));
        staleSeconds = uint32(bound(staleSeconds, 0, 365 days));

        vm.recordLogs();
        vault.recordVaultAccrual(utilBps, staleSeconds, 1_000_000e6);
        uint256 delivered = _reactAndDispatch(_toLogRecord(vm.getRecordedLogs()[0], 20), 1);

        bool expectStaleSpike = staleSeconds >= 86400 && utilBps >= 9000;
        bool expectFlashJump = !expectStaleSpike && utilBps >= 7000;

        if (expectStaleSpike) {
            assertEq(delivered, 2);
            assertEq(vault.lastTripReason(), OmniGuardTypes.REASON_STALE_ACCRUAL_SPIKE);
            assertEq(mirror.lastFreezeReason(), OmniGuardTypes.REASON_STALE_ACCRUAL_SPIKE);
        } else if (expectFlashJump) {
            assertEq(delivered, 2);
            assertEq(vault.lastTripReason(), OmniGuardTypes.REASON_FLASH_UTILIZATION_JUMP);
            assertEq(mirror.lastFreezeReason(), OmniGuardTypes.REASON_FLASH_UTILIZATION_JUMP);
        } else {
            assertEq(delivered, 0);
            assertFalse(vault.circuitBreakerTripped());
            assertFalse(mirror.crossChainFreezeActive());
        }
    }

    function testFuzz_latencyStatsInvariants(uint8 lat1, uint8 lat2, uint8 lat3) public {
        uint256[3] memory lats = [uint256(lat1), uint256(lat2), uint256(lat3)];
        uint256 sum;
        uint256 minL = type(uint256).max;
        uint256 maxL = 0;

        for (uint256 i = 0; i < 3; ++i) {
            uint256 originTs = vm.getBlockTimestamp();
            vm.warp(originTs + lats[i]);
            bytes32 inc = keccak256(abi.encodePacked("lat", i, lats[i]));
            vm.prank(baseCallbackProxy);
            vault.executeCircuitBreaker(address(this), 1, 500 + i, originTs, inc);
            vault.resetCircuitBreaker(200);

            sum += lats[i];
            if (lats[i] < minL) minL = lats[i];
            if (lats[i] > maxL) maxL = lats[i];
        }

        OmniGuardTypes.LatencyStats memory st = vault.getLatencyStats();
        assertEq(st.totalCallbacks, 3);
        assertEq(st.totalLatencySeconds, sum);
        assertEq(st.minLatencySeconds, minL);
        assertEq(st.maxLatencySeconds, maxL);
        assertEq(st.avgLatencySeconds, sum / 3);
    }

    function testFuzz_accessControlRejectsArbitraryCallers(address caller, address wrongRvm, bytes32 inc) public {
        vm.assume(caller != baseCallbackProxy && caller != unichainCallbackProxy && caller != address(this));
        vm.assume(wrongRvm != address(this));

        vm.prank(caller);
        vm.expectRevert("Authorized sender only");
        vault.executeCircuitBreaker(address(this), 1, 500, vm.getBlockTimestamp(), inc);

        vm.prank(baseCallbackProxy);
        vm.expectRevert("Authorized RVM ID only");
        vault.executeCircuitBreaker(wrongRvm, 1, 500, vm.getBlockTimestamp(), inc);

        vm.prank(caller);
        vm.expectRevert(OmniGuardVault.UnauthorizedOwner.selector);
        vault.resetCircuitBreaker(200);

        vm.prank(caller);
        vm.expectRevert(CrossChainMirrorGuardian.UnauthorizedOwner.selector);
        mirror.clearCrossChainFreeze();
    }

    function test_duplicateOrderEventDoesNotDuplicateActiveOrders() public {
        vm.recordLogs();
        vault.registerOrder(1 ether, 2500e8, true);
        IReactive.LogRecord memory rec = _toLogRecord(vm.getRecordedLogs()[0], 99);

        sentinel.react(rec);
        sentinel.react(rec);
        assertEq(sentinel.getActiveOrdersCount(), 1, "duplicate registration log must be idempotent");
    }

    function _swapAndRelay(uint256 valIn, uint256 valOut, uint256 seed) internal returns (uint256) {
        vm.recordLogs();
        vault.recordVaultSwap(valIn, valOut);
        return _reactAndDispatch(_toLogRecord(vm.getRecordedLogs()[0], seed), 1);
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
