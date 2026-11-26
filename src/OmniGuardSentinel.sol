// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractPausableReactive} from "reactive-lib/abstract-base/AbstractPausableReactive.sol";
import {OmniGuardTypes} from "./OmniGuardTypes.sol";

/// @title OmniGuardSentinel
/// @notice Stateful Reactive Smart Contract deployed on Reactive Network (Lasna, chain 5318007).
///         Subscribes to Base Sepolia OmniGuardVault telemetry, runs three stateful on-chain risk
///         engines inside the ReactVM, and emits dual-chain callbacks to BOTH Base Sepolia and
///         Unichain Sepolia within ~1 second upon any invariant breach or stop-loss trigger.
contract OmniGuardSentinel is AbstractPausableReactive {
    uint64 public constant CALLBACK_GAS_LIMIT = 400_000;

    uint256 public immutable originChainId;
    uint256 public immutable mirrorChainId;
    address public immutable originVault;
    address public immutable mirrorGuardian;

    // Risk thresholds configured at deployment (immutable so both RN & ReactVM share identical bounds)
    uint256 public immutable slippageDecayWindow;      // e.g. 3600s (1 hour)
    uint256 public immutable maxCumulativeSlippageBps; // e.g. 500 bps (5.00%)
    uint256 public immutable maxStaleAccrualSeconds;   // e.g. 86400s (24 hours)
    uint256 public immutable criticalUtilizationBps;   // e.g. 9000 bps (90.00%)
    uint256 public immutable maxSingleJumpUtilBps;     // e.g. 7000 bps (70.00% jump in 1 block)

    // Stateful ReactVM Risk Telemetry (persisted across events inside the ReactVM)
    struct VaultRiskState {
        uint256 accumulatedSlippageBps;
        uint256 lastSlippageTimestamp;
        uint256 lastUtilizationBps;
        uint256 incidentCount;
    }

    struct TrackedOrder {
        uint256 orderId;
        address trader;
        uint256 positionAmount;
        uint256 triggerPriceD8;
        bool isStopLoss;
        bool active;
    }

    mapping(address => VaultRiskState) public vaultRiskState;
    mapping(uint256 => TrackedOrder) public trackedOrders;
    uint256[] public activeOrderIds;

    uint256 public totalEventsProcessed;
    uint256 public totalBreachesDetected;
    uint256 public totalOrdersTriggered;

    event TelemetryProcessed(uint256 indexed topic0, uint256 indexed originBlock, uint256 totalEventsProcessed);
    event RiskBreachDetected(
        bytes32 indexed incidentId,
        address indexed vault,
        uint8 indexed reasonCode,
        uint256 metricValue,
        uint256 originTimestamp
    );
    event ReactiveOrderMatched(
        bytes32 indexed incidentId,
        uint256 indexed orderId,
        uint256 priceD8,
        uint256 originTimestamp
    );

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
        originChainId = _originChainId;
        mirrorChainId = _mirrorChainId;
        originVault = _originVault;
        mirrorGuardian = _mirrorGuardian;
        slippageDecayWindow = _slippageDecayWindow;
        maxCumulativeSlippageBps = _maxCumulativeSlippageBps;
        maxStaleAccrualSeconds = _maxStaleAccrualSeconds;
        criticalUtilizationBps = _criticalUtilizationBps;
        maxSingleJumpUtilBps = _maxSingleJumpUtilBps;

        if (!vm) {
            Subscription[] memory subs = getPausableSubscriptions();
            for (uint256 i = 0; i < subs.length; ++i) {
                service.subscribe(
                    subs[i].chain_id,
                    subs[i]._contract,
                    subs[i].topic_0,
                    subs[i].topic_1,
                    subs[i].topic_2,
                    subs[i].topic_3
                );
            }
        }
    }

    function getPausableSubscriptions() internal view override returns (Subscription[] memory subs) {
        subs = new Subscription[](4);
        subs[0] = Subscription({
            chain_id: originChainId,
            _contract: originVault,
            topic_0: OmniGuardTypes.SWAP_EXECUTED_TOPIC_0,
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
        subs[1] = Subscription({
            chain_id: originChainId,
            _contract: originVault,
            topic_0: OmniGuardTypes.VAULT_ACCRUAL_TOPIC_0,
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
        subs[2] = Subscription({
            chain_id: originChainId,
            _contract: originVault,
            topic_0: OmniGuardTypes.STOP_LOSS_REGISTERED_TOPIC_0,
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
        subs[3] = Subscription({
            chain_id: originChainId,
            _contract: originVault,
            topic_0: OmniGuardTypes.ORACLE_PRICE_UPDATED_TOPIC_0,
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
    }

    /// @notice Core ReactVM entrypoint invoked automatically on every subscribed Base Sepolia event.
    function react(LogRecord calldata log) external override vmOnly {
        totalEventsProcessed += 1;
        emit TelemetryProcessed(log.topic_0, log.block_number, totalEventsProcessed);

        if (log.topic_0 == OmniGuardTypes.SWAP_EXECUTED_TOPIC_0) {
            _handleSwapExecuted(log);
        } else if (log.topic_0 == OmniGuardTypes.VAULT_ACCRUAL_TOPIC_0) {
            _handleVaultAccrual(log);
        } else if (log.topic_0 == OmniGuardTypes.STOP_LOSS_REGISTERED_TOPIC_0) {
            _handleOrderRegistered(log);
        } else if (log.topic_0 == OmniGuardTypes.ORACLE_PRICE_UPDATED_TOPIC_0) {
            _handlePriceUpdated(log);
        }
    }

    /*//////////////////////////////////////////////////////////////
                   ENGINE 1: ROLLING SLIPPAGE SENTINEL
    //////////////////////////////////////////////////////////////*/

    function _handleSwapExecuted(LogRecord calldata log) internal {
        address vault = address(uint160(log.topic_1));
        (, , uint256 slippageBps, uint256 originTimestamp) =
            abi.decode(log.data, (uint256, uint256, uint256, uint256));

        VaultRiskState storage state = vaultRiskState[vault];
        uint256 decayed = _decayedSlippage(state.accumulatedSlippageBps, state.lastSlippageTimestamp, originTimestamp);
        uint256 updatedCumulative = decayed + slippageBps;

        state.accumulatedSlippageBps = updatedCumulative;
        state.lastSlippageTimestamp = originTimestamp;

        if (updatedCumulative >= maxCumulativeSlippageBps) {
            _emitDualCircuitBreaker(
                vault,
                OmniGuardTypes.REASON_CUMULATIVE_SLIPPAGE,
                updatedCumulative,
                originTimestamp,
                log
            );
            // Reset accumulator after tripping so post-recovery monitoring begins cleanly
            state.accumulatedSlippageBps = 0;
        }
    }

    function _decayedSlippage(
        uint256 priorAccumulated,
        uint256 lastTs,
        uint256 currentTs
    ) internal view returns (uint256) {
        if (priorAccumulated == 0 || lastTs == 0 || currentTs <= lastTs) {
            return priorAccumulated;
        }
        uint256 elapsed = currentTs - lastTs;
        if (elapsed >= slippageDecayWindow) {
            return 0;
        }
        return (priorAccumulated * (slippageDecayWindow - elapsed)) / slippageDecayWindow;
    }

    /*//////////////////////////////////////////////////////////////
              ENGINE 2: STALE ACCRUAL & UTILIZATION SPIKE
    //////////////////////////////////////////////////////////////*/

    function _handleVaultAccrual(LogRecord calldata log) internal {
        address vault = address(uint160(log.topic_1));
        (uint256 utilizationBps, uint256 staleSeconds, , uint256 originTimestamp) =
            abi.decode(log.data, (uint256, uint256, uint256, uint256));

        VaultRiskState storage state = vaultRiskState[vault];
        uint256 prevUtil = state.lastUtilizationBps;
        state.lastUtilizationBps = utilizationBps;

        // Pattern A: Stale last-update window combined with sudden high utilization (retroactive interest exploit)
        if (staleSeconds >= maxStaleAccrualSeconds && utilizationBps >= criticalUtilizationBps) {
            _emitDualCircuitBreaker(
                vault,
                OmniGuardTypes.REASON_STALE_ACCRUAL_SPIKE,
                staleSeconds,
                originTimestamp,
                log
            );
            return;
        }

        // Pattern B: Single-step extreme utilization jump
        if (utilizationBps > prevUtil && (utilizationBps - prevUtil) >= maxSingleJumpUtilBps) {
            _emitDualCircuitBreaker(
                vault,
                OmniGuardTypes.REASON_FLASH_UTILIZATION_JUMP,
                utilizationBps - prevUtil,
                originTimestamp,
                log
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
           ENGINE 3: KEEPER-LESS SUB-SECOND STOP-LOSS / TP
    //////////////////////////////////////////////////////////////*/

    function _handleOrderRegistered(LogRecord calldata log) internal {
        uint256 orderId = log.topic_1;
        address trader = address(uint160(log.topic_2));
        (uint256 positionAmount, uint256 triggerPriceD8, bool isStopLoss, ) =
            abi.decode(log.data, (uint256, uint256, bool, uint256));

        trackedOrders[orderId] = TrackedOrder({
            orderId: orderId,
            trader: trader,
            positionAmount: positionAmount,
            triggerPriceD8: triggerPriceD8,
            isStopLoss: isStopLoss,
            active: true
        });
        activeOrderIds.push(orderId);
    }

    function _handlePriceUpdated(LogRecord calldata log) internal {
        (uint256 priceD8, uint256 originTimestamp) = abi.decode(log.data, (uint256, uint256));

        uint256 i = 0;
        while (i < activeOrderIds.length) {
            uint256 orderId = activeOrderIds[i];
            TrackedOrder storage ord = trackedOrders[orderId];

            bool triggered = ord.active &&
                ((ord.isStopLoss && priceD8 <= ord.triggerPriceD8) || (!ord.isStopLoss && priceD8 >= ord.triggerPriceD8));

            if (triggered) {
                ord.active = false;
                totalOrdersTriggered += 1;

                // Swap-and-pop from active list so future price ticks stay O(active)
                activeOrderIds[i] = activeOrderIds[activeOrderIds.length - 1];
                activeOrderIds.pop();

                bytes32 incidentId = keccak256(
                    abi.encodePacked(log.chain_id, log.tx_hash, log.log_index, orderId, priceD8)
                );
                emit ReactiveOrderMatched(incidentId, orderId, priceD8, originTimestamp);

                // Callback 1: Settle order on Base Sepolia OmniGuardVault
                bytes memory settlePayload = abi.encodeWithSignature(
                    "executeOrder(address,uint256,uint256,uint256,bytes32)",
                    address(0),
                    orderId,
                    priceD8,
                    originTimestamp,
                    incidentId
                );
                emit Callback(originChainId, originVault, CALLBACK_GAS_LIMIT, settlePayload);

                // Callback 2: Signal parallel cross-chain hedge on Unichain Sepolia
                if (mirrorGuardian != address(0)) {
                    bytes memory hedgePayload = abi.encodeWithSignature(
                        "recordHedgeSignal(address,uint256,uint256,uint256,bytes32)",
                        address(0),
                        orderId,
                        priceD8,
                        originTimestamp,
                        incidentId
                    );
                    emit Callback(mirrorChainId, mirrorGuardian, CALLBACK_GAS_LIMIT, hedgePayload);
                }
            } else {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                      DUAL-CHAIN CALLBACK FAN-OUT
    //////////////////////////////////////////////////////////////*/

    function _emitDualCircuitBreaker(
        address vault,
        uint8 reasonCode,
        uint256 metricValue,
        uint256 originTimestamp,
        LogRecord calldata log
    ) internal {
        vaultRiskState[vault].incidentCount += 1;
        totalBreachesDetected += 1;

        bytes32 incidentId = keccak256(
            abi.encodePacked(log.chain_id, log.tx_hash, log.log_index, reasonCode, metricValue)
        );
        emit RiskBreachDetected(incidentId, vault, reasonCode, metricValue, originTimestamp);

        // Callback 1: Freeze Base Sepolia origin vault immediately
        bytes memory vaultPayload = abi.encodeWithSignature(
            "executeCircuitBreaker(address,uint8,uint256,uint256,bytes32)",
            address(0),
            reasonCode,
            metricValue,
            originTimestamp,
            incidentId
        );
        emit Callback(originChainId, originVault, CALLBACK_GAS_LIMIT, vaultPayload);

        // Callback 2: Simultaneously trip cross-chain mirror circuit breaker on Unichain Sepolia
        if (mirrorGuardian != address(0)) {
            bytes memory mirrorPayload = abi.encodeWithSignature(
                "tripCrossChainBreaker(address,address,uint8,uint256,uint256,bytes32)",
                address(0),
                vault,
                reasonCode,
                metricValue,
                originTimestamp,
                incidentId
            );
            emit Callback(mirrorChainId, mirrorGuardian, CALLBACK_GAS_LIMIT, mirrorPayload);
        }
    }

    function getActiveOrdersCount() external view returns (uint256) {
        return activeOrderIds.length;
    }
}
