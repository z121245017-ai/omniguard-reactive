// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {OmniGuardTypes} from "./OmniGuardTypes.sol";

/// @title OmniGuardSentinel
/// @notice Native Reactive Omni stateful sentinel deployed on Reactive Lasna (chain 5318007)
///         using the Reactive Omni System Contract (0x8888888888888888888888888888888888888888).
///         Subscribes to Base Sepolia OmniGuardVault telemetry, runs three stateful on-chain risk
///         engines directly on Lasna CometBFT (~1s finality), and fans out dual-chain callbacks to
///         BOTH Base Sepolia and Unichain Sepolia via SYSTEM.requestCallbackV_1_0().
contract OmniGuardSentinel is AbstractReactive {
    error UnauthorizedOwner();

    uint64 public constant CALLBACK_GAS_LIMIT = 800_000;

    bytes4 private constant SEL_EXEC_ORDER = bytes4(keccak256("executeOrder(address,uint256,uint256,uint256,bytes32)"));
    bytes4 private constant SEL_HEDGE_SIG = bytes4(keccak256("recordHedgeSignal(address,uint256,uint256,uint256,bytes32)"));
    bytes4 private constant SEL_EXEC_BREAKER = bytes4(keccak256("executeCircuitBreaker(address,uint8,uint256,uint256,bytes32)"));
    bytes4 private constant SEL_MIRROR_BREAKER = bytes4(keccak256("tripCrossChainBreaker(address,address,uint8,uint256,uint256,bytes32)"));

    address internal immutable owner;
    uint256 internal immutable originChainId;
    uint256 internal immutable mirrorChainId;
    address internal immutable originVault;
    address internal immutable mirrorGuardian;

    uint256 internal immutable slippageDecayWindow;
    uint256 internal immutable maxCumulativeSlippageBps;
    uint256 internal immutable maxStaleAccrualSeconds;
    uint256 internal immutable criticalUtilizationBps;
    uint256 internal immutable maxSingleJumpUtilBps;

    // Packed into a single 32-byte storage slot to minimize Lasna react() gas
    struct VaultRiskState {
        uint64 accumulatedSlippageBps;
        uint64 lastSlippageTimestamp;
        uint64 lastUtilizationBps;
        uint64 incidentCount;
    }

    // Packed into 2 storage slots instead of 6
    struct TrackedOrder {
        uint128 positionAmount;
        uint128 triggerPriceD8;
        address trader;
        bool isStopLoss;
        bool active;
    }

    bool public paused;
    uint64 public totalEventsProcessed;
    uint64 public totalBreachesDetected;
    uint64 public totalOrdersTriggered;

    mapping(address => VaultRiskState) public vaultRiskState;
    mapping(uint256 => TrackedOrder) internal trackedOrders;
    uint256[] internal activeOrderIds;

    event TelemetryProcessed(uint256 indexed topic0, uint256 indexed originBlock, uint256 totalEventsProcessed);
    event RiskBreachDetected(bytes32 indexed incidentId, address indexed vault, uint8 indexed reasonCode, uint256 metricValue, uint256 originTimestamp);
    event ReactiveOrderMatched(bytes32 indexed incidentId, uint256 indexed orderId, uint256 priceD8, uint256 originTimestamp);
    event SentinelPauseChanged(bool paused);

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner();
        _;
    }

    constructor(
        uint256 _originChainId,
        uint256 _mirrorChainId,
        address _originVault,
        address _mirrorGuardian,
        uint256 _slippageDecayWindow,
        uint256 _maxCumulativeSlippageBps,
        uint256 _maxStaleAccrualSeconds,
        uint256 _criticalUtilizationBps,
        uint256 _maxSingleJumpUtilBps
    ) payable {
        owner = msg.sender;
        originChainId = _originChainId;
        mirrorChainId = _mirrorChainId;
        originVault = _originVault;
        mirrorGuardian = _mirrorGuardian;
        slippageDecayWindow = _slippageDecayWindow;
        maxCumulativeSlippageBps = _maxCumulativeSlippageBps;
        maxStaleAccrualSeconds = _maxStaleAccrualSeconds;
        criticalUtilizationBps = _criticalUtilizationBps;
        maxSingleJumpUtilBps = _maxSingleJumpUtilBps;

        SYSTEM.subscribe(_originChainId, _originVault, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function pause() external onlyOwner {
        if (!paused) {
            paused = true;
            SYSTEM.unsubscribe(originChainId, originVault, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            emit SentinelPauseChanged(true);
        }
    }

    function resume() external payable onlyOwner {
        if (paused) {
            paused = false;
            _coverDebt();
            SYSTEM.subscribe(originChainId, originVault, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            emit SentinelPauseChanged(false);
        }
    }

    function coverDebt() external {
        _coverDebt();
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external override onlySystem {
        uint64 ev = ++totalEventsProcessed;
        emit TelemetryProcessed(log_.topic0, log_.blockNumber, ev);

        uint256 t0 = log_.topic0;
        if (t0 == OmniGuardTypes.SWAP_EXECUTED_TOPIC_0) {
            _handleSwapExecuted(log_);
        } else if (t0 == OmniGuardTypes.VAULT_ACCRUAL_TOPIC_0) {
            _handleVaultAccrual(log_);
        } else if (t0 == OmniGuardTypes.STOP_LOSS_REGISTERED_TOPIC_0) {
            _handleOrderRegistered(log_);
        } else if (t0 == OmniGuardTypes.ORACLE_PRICE_UPDATED_TOPIC_0) {
            _handlePriceUpdated(log_);
        }
    }

    function _handleSwapExecuted(LogRecord calldata log_) internal {
        address vault = address(uint160(log_.topic1));
        (, , uint256 slippageBps, uint256 originTimestamp) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint256));

        VaultRiskState storage state = vaultRiskState[vault];
        uint256 decayed = _decayedSlippage(state.accumulatedSlippageBps, state.lastSlippageTimestamp, originTimestamp);
        uint256 updatedCumulative = decayed + slippageBps;

        state.lastSlippageTimestamp = uint64(originTimestamp);
        if (updatedCumulative >= maxCumulativeSlippageBps) {
            state.accumulatedSlippageBps = 0;
            _emitDualCircuitBreaker(vault, OmniGuardTypes.REASON_CUMULATIVE_SLIPPAGE, updatedCumulative, originTimestamp, log_);
        } else {
            state.accumulatedSlippageBps = uint64(updatedCumulative);
        }
    }

    function _decayedSlippage(uint256 priorAcc, uint256 lastTs, uint256 curTs) internal view returns (uint256) {
        if (priorAcc == 0 || lastTs == 0 || curTs <= lastTs) return priorAcc;
        uint256 elapsed = curTs - lastTs;
        if (elapsed >= slippageDecayWindow) return 0;
        return (priorAcc * (slippageDecayWindow - elapsed)) / slippageDecayWindow;
    }

    function _handleVaultAccrual(LogRecord calldata log_) internal {
        address vault = address(uint160(log_.topic1));
        (uint256 utilizationBps, uint256 staleSeconds, , uint256 originTimestamp) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint256));

        VaultRiskState storage state = vaultRiskState[vault];
        uint256 prevUtil = state.lastUtilizationBps;
        state.lastUtilizationBps = uint64(utilizationBps);

        if (staleSeconds >= maxStaleAccrualSeconds && utilizationBps >= criticalUtilizationBps) {
            _emitDualCircuitBreaker(vault, OmniGuardTypes.REASON_STALE_ACCRUAL_SPIKE, staleSeconds, originTimestamp, log_);
        } else if (utilizationBps > prevUtil && (utilizationBps - prevUtil) >= maxSingleJumpUtilBps) {
            _emitDualCircuitBreaker(vault, OmniGuardTypes.REASON_FLASH_UTILIZATION_JUMP, utilizationBps - prevUtil, originTimestamp, log_);
        }
    }

    function _handleOrderRegistered(LogRecord calldata log_) internal {
        uint256 orderId = log_.topic1;
        if (trackedOrders[orderId].active) return;
        address trader = address(uint160(log_.topic2));
        (uint256 positionAmount, uint256 triggerPriceD8, bool isStopLoss, ) =
            abi.decode(log_.data, (uint256, uint256, bool, uint256));

        trackedOrders[orderId] = TrackedOrder({
            positionAmount: uint128(positionAmount),
            triggerPriceD8: uint128(triggerPriceD8),
            trader: trader,
            isStopLoss: isStopLoss,
            active: true
        });
        activeOrderIds.push(orderId);
    }

    function _handlePriceUpdated(LogRecord calldata log_) internal {
        (uint256 priceD8, uint256 originTimestamp) = abi.decode(log_.data, (uint256, uint256));

        uint256 i = 0;
        while (i < activeOrderIds.length) {
            uint256 orderId = activeOrderIds[i];
            TrackedOrder storage ord = trackedOrders[orderId];

            bool triggered = ord.active &&
                ((ord.isStopLoss && priceD8 <= ord.triggerPriceD8) || (!ord.isStopLoss && priceD8 >= ord.triggerPriceD8));

            if (triggered) {
                ord.active = false;
                totalOrdersTriggered += 1;
                activeOrderIds[i] = activeOrderIds[activeOrderIds.length - 1];
                activeOrderIds.pop();

                bytes32 incidentId = keccak256(abi.encodePacked(log_.chainId, log_.txHash, log_.logIndex, orderId, priceD8));
                emit ReactiveOrderMatched(incidentId, orderId, priceD8, originTimestamp);

                _requestCb(originChainId, originVault, abi.encodeWithSelector(SEL_EXEC_ORDER, address(0), orderId, priceD8, originTimestamp, incidentId));
                if (mirrorGuardian != address(0)) {
                    _requestCb(mirrorChainId, mirrorGuardian, abi.encodeWithSelector(SEL_HEDGE_SIG, address(0), orderId, priceD8, originTimestamp, incidentId));
                }
            } else {
                ++i;
            }
        }
    }

    function _emitDualCircuitBreaker(
        address vault,
        uint8 reasonCode,
        uint256 metricValue,
        uint256 originTimestamp,
        LogRecord calldata log_
    ) internal {
        vaultRiskState[vault].incidentCount += 1;
        totalBreachesDetected += 1;

        bytes32 incidentId = keccak256(abi.encodePacked(log_.chainId, log_.txHash, log_.logIndex, reasonCode, metricValue));
        emit RiskBreachDetected(incidentId, vault, reasonCode, metricValue, originTimestamp);

        _requestCb(originChainId, originVault, abi.encodeWithSelector(SEL_EXEC_BREAKER, address(0), reasonCode, metricValue, originTimestamp, incidentId));
        if (mirrorGuardian != address(0)) {
            _requestCb(mirrorChainId, mirrorGuardian, abi.encodeWithSelector(SEL_MIRROR_BREAKER, address(0), vault, reasonCode, metricValue, originTimestamp, incidentId));
        }
    }

    function _requestCb(uint256 chainId_, address recipient_, bytes memory payload_) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: chainId_,
                recipient: recipient_,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload_
            })
        );
    }

    function getActiveOrdersCount() external view returns (uint256) {
        return activeOrderIds.length;
    }
}
