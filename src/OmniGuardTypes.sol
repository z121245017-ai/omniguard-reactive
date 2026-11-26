// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title OmniGuardTypes
/// @notice Shared event signatures, reason codes, and telemetry structs across Base Sepolia,
///         Reactive Network (Lasna), and Unichain Sepolia.
library OmniGuardTypes {
    uint8 internal constant REASON_NONE = 0;
    uint8 internal constant REASON_CUMULATIVE_SLIPPAGE = 1;
    uint8 internal constant REASON_STALE_ACCRUAL_SPIKE = 2;
    uint8 internal constant REASON_FLASH_UTILIZATION_JUMP = 3;
    uint8 internal constant REASON_STOP_LOSS_TRIGGER = 4;
    uint8 internal constant REASON_TAKE_PROFIT_TRIGGER = 5;

    uint256 internal constant SWAP_EXECUTED_TOPIC_0 =
        uint256(keccak256("SwapExecuted(address,uint256,uint256,uint256,uint256,uint256)"));

    uint256 internal constant VAULT_ACCRUAL_TOPIC_0 =
        uint256(keccak256("VaultAccrualObserved(address,uint256,uint256,uint256,uint256)"));

    uint256 internal constant STOP_LOSS_REGISTERED_TOPIC_0 =
        uint256(keccak256("StopLossRegistered(uint256,address,uint256,uint256,bool,uint256)"));

    uint256 internal constant ORACLE_PRICE_UPDATED_TOPIC_0 =
        uint256(keccak256("OraclePriceUpdated(address,uint256,uint256)"));

    struct CallbackReceipt {
        bytes32 incidentId;
        uint64 originTimestamp;
        uint64 callbackTimestamp;
        uint64 latencySeconds;
        uint64 callbackBlock;
        uint8 reasonCode;
        uint128 metricValue;
    }

    struct LatencyStats {
        uint256 totalCallbacks;
        uint256 totalLatencySeconds;
        uint256 minLatencySeconds;
        uint256 maxLatencySeconds;
        uint256 avgLatencySeconds;
    }
}
