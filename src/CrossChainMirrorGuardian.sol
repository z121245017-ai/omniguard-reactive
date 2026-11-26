// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {OmniGuardTypes} from "./OmniGuardTypes.sol";

/// @title CrossChainMirrorGuardian
/// @notice Cross-chain destination guardian deployed on Unichain Sepolia (chain 1301).
///         Receives parallel sub-second callbacks from Reactive Lasna whenever an anomaly
///         or stop-loss event fires on Base Sepolia, immediately freezing sister-vault bridge
///         liquidity or recording a cross-chain hedge execution before contagion spreads.
contract CrossChainMirrorGuardian is AbstractCallback {
    error UnauthorizedOwner();
    error IncidentAlreadyProcessed(bytes32 incidentId);

    address public immutable owner;
    bool public crossChainFreezeActive;
    address public lastAffectedOriginVault;
    uint8 public lastFreezeReason;
    uint256 public hedgeSignalsCount;

    mapping(bytes32 => bool) public processedIncidents;
    mapping(uint256 => uint256) public hedgedOrderPriceD8;
    OmniGuardTypes.CallbackReceipt[] public mirrorHistory;

    uint64 public totalCallbacks;
    uint64 public totalLatencySeconds;
    uint64 public minLatencySeconds = type(uint64).max;
    uint64 public maxLatencySeconds;

    event CrossChainBreakerTripped(
        bytes32 indexed incidentId,
        address indexed originVault,
        uint8 indexed reasonCode,
        uint256 metricValue,
        uint256 originTimestamp,
        uint256 callbackTimestamp,
        uint256 latencySeconds
    );

    event CrossChainHedgeRecorded(
        bytes32 indexed incidentId,
        uint256 indexed orderId,
        uint256 executionPriceD8,
        uint256 originTimestamp,
        uint256 callbackTimestamp,
        uint256 latencySeconds
    );

    event CrossChainFreezeCleared(address indexed admin);

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner();
        _;
    }

    /// @param _callbackProxy Reactive Omni Callback Proxy on Unichain Sepolia (0x775c9B990ADe401060B78D0e98684eEf8d2466C1)
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

    /// @notice Trips the cross-chain sister-vault circuit breaker on Unichain Sepolia.
    function tripCrossChainBreaker(
        address reactiveSender,
        address originVault,
        uint8 reasonCode,
        uint256 metricValue,
        uint256 originTimestamp,
        bytes32 incidentId
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) {
        if (processedIncidents[incidentId]) revert IncidentAlreadyProcessed(incidentId);
        processedIncidents[incidentId] = true;

        crossChainFreezeActive = true;
        lastAffectedOriginVault = originVault;
        lastFreezeReason = reasonCode;

        uint256 latency = _recordLatency(incidentId, reasonCode, metricValue, originTimestamp);
        emit CrossChainBreakerTripped(
            incidentId,
            originVault,
            reasonCode,
            metricValue,
            originTimestamp,
            block.timestamp,
            latency
        );
    }

    /// @notice Records a parallel cross-chain hedge signal on Unichain Sepolia when a Base Sepolia stop-loss triggers.
    function recordHedgeSignal(
        address reactiveSender,
        uint256 orderId,
        uint256 executionPriceD8,
        uint256 originTimestamp,
        bytes32 incidentId
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) {
        if (processedIncidents[incidentId]) revert IncidentAlreadyProcessed(incidentId);
        processedIncidents[incidentId] = true;

        hedgeSignalsCount += 1;
        hedgedOrderPriceD8[orderId] = executionPriceD8;

        uint256 latency = _recordLatency(
            incidentId,
            OmniGuardTypes.REASON_STOP_LOSS_TRIGGER,
            executionPriceD8,
            originTimestamp
        );
        emit CrossChainHedgeRecorded(
            incidentId,
            orderId,
            executionPriceD8,
            originTimestamp,
            block.timestamp,
            latency
        );
    }

    function clearCrossChainFreeze() external onlyOwner {
        crossChainFreezeActive = false;
        lastFreezeReason = OmniGuardTypes.REASON_NONE;
        emit CrossChainFreezeCleared(msg.sender);
    }

    function getMirrorHistoryLength() external view returns (uint256) {
        return mirrorHistory.length;
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

        mirrorHistory.push(
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
