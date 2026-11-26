// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {OmniGuardTypes} from "./OmniGuardTypes.sol";

/// @title OmniGuardVault
/// @notice Origin & destination DeFi Vault deployed on Base Sepolia (chain 84532).
///         Emits granular execution, accrual, order, and price telemetry that Reactive Omni
///         monitors in sub-second finality, and receives authenticated Reactive callbacks
///         to trip circuit breakers or settle keeper-less stop-loss/take-profit orders.
contract OmniGuardVault is AbstractCallback {
    error UnauthorizedOwner();
    error CircuitBreakerActive();
    error SingleSwapSlippageExceeded(uint256 slippageBps, uint256 maxSingleSwapBps);
    error InvalidOrderParameters();
    error OrderNotActive(uint256 orderId);
    error IncidentAlreadyProcessed(bytes32 incidentId);

    struct PositionOrder {
        address trader;
        uint256 positionAmount;
        uint256 triggerPriceD8;
        bool isStopLoss; // true = trigger when price <= triggerPriceD8; false = take-profit (price >= triggerPriceD8)
        bool active;
        uint256 createdAt;
        uint256 settledAt;
        uint256 settledPriceD8;
    }

    address public immutable owner;
    bool public circuitBreakerTripped;
    uint8 public lastTripReason;
    uint256 public maxSingleSwapSlippageBps = 200; // 2.00% local single-tx cap (bypassable by slow-bleed without Reactive!)
    uint256 public swapCounter;
    uint256 public orderCounter;
    uint256 public lastPriceD8;

    mapping(uint256 => PositionOrder) public orders;
    mapping(bytes32 => bool) public processedIncidents;
    OmniGuardTypes.CallbackReceipt[] public callbackHistory;

    uint64 public totalCallbacks;
    uint64 public totalLatencySeconds;
    uint64 public minLatencySeconds = type(uint64).max;
    uint64 public maxLatencySeconds;

    event SwapExecuted(
        address indexed vault,
        uint256 indexed swapId,
        uint256 valueInUsd,
        uint256 valueOutUsd,
        uint256 slippageBps,
        uint256 originTimestamp
    );

    event VaultAccrualObserved(
        address indexed vault,
        uint256 utilizationBps,
        uint256 staleSeconds,
        uint256 borrowDeltaUsd,
        uint256 originTimestamp
    );

    event StopLossRegistered(
        uint256 indexed orderId,
        address indexed trader,
        uint256 positionAmount,
        uint256 triggerPriceD8,
        bool isStopLoss,
        uint256 createdAt
    );

    event OraclePriceUpdated(address indexed asset, uint256 priceD8, uint256 originTimestamp);

    event CircuitBreakerExecuted(
        bytes32 indexed incidentId,
        uint8 indexed reasonCode,
        uint256 metricValue,
        uint256 originTimestamp,
        uint256 callbackTimestamp,
        uint256 latencySeconds
    );

    event StopLossSettled(
        uint256 indexed orderId,
        address indexed trader,
        uint256 executionPriceD8,
        uint256 originTimestamp,
        uint256 callbackTimestamp,
        uint256 latencySeconds
    );

    event CircuitBreakerReset(address indexed admin, uint256 newMaxSingleSwapSlippageBps);

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner();
        _;
    }

    modifier whenNotTripped() {
        if (circuitBreakerTripped) revert CircuitBreakerActive();
        _;
    }

    /// @param _callbackProxy Reactive Omni Callback Proxy on Base Sepolia (0x476F44b11F5C942c58f4c8E3d0300E5710743585)
    /// @param _callbackSender Authorized OmniGuardSentinel contract deployed on Reactive Lasna (5318007)
    constructor(address _callbackProxy, address _callbackSender)
        AbstractCallback(IPayable(payable(_callbackProxy)), _callbackSender)
        payable
    {
        owner = msg.sender;
    }

    function coverDebt() external {
        _coverDebt();
    }

    /*//////////////////////////////////////////////////////////////
                        ORIGIN EVENT PRODUCERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Records a vault swap that passes the local single-tx 2% slippage cap.
    ///         Repeated swaps just under 2% can still slowly drain a vault unless Reactive Omni
    ///         tracks cumulative decaying slippage across transactions and trips the circuit breaker.
    function recordVaultSwap(uint256 valueInUsd, uint256 valueOutUsd) external whenNotTripped returns (uint256 swapId) {
        uint256 slippageBps = 0;
        if (valueInUsd > 0 && valueOutUsd < valueInUsd) {
            slippageBps = ((valueInUsd - valueOutUsd) * 10_000) / valueInUsd;
        }
        if (slippageBps > maxSingleSwapSlippageBps) {
            revert SingleSwapSlippageExceeded(slippageBps, maxSingleSwapSlippageBps);
        }

        swapId = ++swapCounter;
        emit SwapExecuted(address(this), swapId, valueInUsd, valueOutUsd, slippageBps, block.timestamp);
    }

    /// @notice Emits vault accrual and utilization telemetry for stale-accrual / jump detection.
    function recordVaultAccrual(
        uint256 utilizationBps,
        uint256 staleSeconds,
        uint256 borrowDeltaUsd
    ) external whenNotTripped {
        emit VaultAccrualObserved(address(this), utilizationBps, staleSeconds, borrowDeltaUsd, block.timestamp);
    }

    /// @notice Registers an on-chain keeper-less stop-loss or take-profit order monitored by Reactive Omni.
    function registerOrder(
        uint256 positionAmount,
        uint256 triggerPriceD8,
        bool isStopLoss
    ) external whenNotTripped returns (uint256 orderId) {
        if (positionAmount == 0 || triggerPriceD8 == 0) revert InvalidOrderParameters();

        orderId = ++orderCounter;
        orders[orderId] = PositionOrder({
            trader: msg.sender,
            positionAmount: positionAmount,
            triggerPriceD8: triggerPriceD8,
            isStopLoss: isStopLoss,
            active: true,
            createdAt: block.timestamp,
            settledAt: 0,
            settledPriceD8: 0
        });

        emit StopLossRegistered(orderId, msg.sender, positionAmount, triggerPriceD8, isStopLoss, block.timestamp);
    }

    /// @notice Publishes a price tick (e.g., from DEX pool / oracle adapter) that Reactive Omni evaluates in ~1s.
    function publishPriceTick(address asset, uint256 priceD8) external {
        lastPriceD8 = priceD8;
        emit OraclePriceUpdated(asset, priceD8, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                    REACTIVE NETWORK CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Authenticated Reactive Omni callback tripping the emergency circuit breaker and tightening slippage cap.
    /// @param reactiveSender Overwritten by Reactive Omni Callback Proxy with the authentic Reactive contract address.
    function executeCircuitBreaker(
        address reactiveSender,
        uint8 reasonCode,
        uint256 metricValue,
        uint256 originTimestamp,
        bytes32 incidentId
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) {
        if (processedIncidents[incidentId]) revert IncidentAlreadyProcessed(incidentId);
        processedIncidents[incidentId] = true;

        circuitBreakerTripped = true;
        lastTripReason = reasonCode;
        // Tighten per-swap cap to 25 bps (0.25%) for post-recovery defense-in-depth
        maxSingleSwapSlippageBps = 25;

        uint256 latency = _recordLatency(incidentId, reasonCode, metricValue, originTimestamp);
        emit CircuitBreakerExecuted(incidentId, reasonCode, metricValue, originTimestamp, block.timestamp, latency);
    }

    /// @notice Authenticated Reactive Omni callback executing a keeper-less stop-loss or take-profit order.
    /// @param reactiveSender Overwritten by Reactive Omni Callback Proxy with the authentic Reactive contract address.
    function executeOrder(
        address reactiveSender,
        uint256 orderId,
        uint256 executionPriceD8,
        uint256 originTimestamp,
        bytes32 incidentId
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) {
        PositionOrder storage ord = orders[orderId];
        if (!ord.active) revert OrderNotActive(orderId);
        if (processedIncidents[incidentId]) revert IncidentAlreadyProcessed(incidentId);

        processedIncidents[incidentId] = true;
        ord.active = false;
        ord.settledAt = block.timestamp;
        ord.settledPriceD8 = executionPriceD8;

        uint8 reason = ord.isStopLoss
            ? OmniGuardTypes.REASON_STOP_LOSS_TRIGGER
            : OmniGuardTypes.REASON_TAKE_PROFIT_TRIGGER;
        uint256 latency = _recordLatency(incidentId, reason, executionPriceD8, originTimestamp);

        emit StopLossSettled(orderId, ord.trader, executionPriceD8, originTimestamp, block.timestamp, latency);
    }

    /*//////////////////////////////////////////////////////////////
                       ADMIN & TELEMETRY VIEWS
    //////////////////////////////////////////////////////////////*/

    function resetCircuitBreaker(uint256 newMaxSingleSwapSlippageBps) external onlyOwner {
        circuitBreakerTripped = false;
        lastTripReason = OmniGuardTypes.REASON_NONE;
        maxSingleSwapSlippageBps = newMaxSingleSwapSlippageBps;
        emit CircuitBreakerReset(msg.sender, newMaxSingleSwapSlippageBps);
    }

    function getCallbackHistoryLength() external view returns (uint256) {
        return callbackHistory.length;
    }

    function getLatencyStats() external view returns (OmniGuardTypes.LatencyStats memory stats) {
        stats.totalCallbacks = totalCallbacks;
        stats.totalLatencySeconds = totalLatencySeconds;
        stats.minLatencySeconds = totalCallbacks == 0 ? 0 : minLatencySeconds;
        stats.maxLatencySeconds = maxLatencySeconds;
        stats.avgLatencySeconds = totalCallbacks == 0 ? 0 : totalLatencySeconds / totalCallbacks;
    }

    function _recordLatency(
        bytes32 incidentId,
        uint8 reasonCode,
        uint256 metricValue,
        uint256 originTimestamp
    ) internal returns (uint256 latency) {
        latency = block.timestamp >= originTimestamp ? block.timestamp - originTimestamp : 0;

        uint64 lat64 = uint64(latency);
        totalCallbacks += 1;
        totalLatencySeconds += lat64;
        if (lat64 < minLatencySeconds) minLatencySeconds = lat64;
        if (lat64 > maxLatencySeconds) maxLatencySeconds = lat64;

        callbackHistory.push(
            OmniGuardTypes.CallbackReceipt({
                incidentId: incidentId,
                originTimestamp: uint64(originTimestamp),
                callbackTimestamp: uint64(block.timestamp),
                latencySeconds: lat64,
                callbackBlock: uint64(block.number),
                reasonCode: reasonCode,
                metricValue: uint128(metricValue)
            })
        );
    }
}
