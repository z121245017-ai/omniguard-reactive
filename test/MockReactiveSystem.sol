// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @notice Local Foundry mock etched at Reactive Omni's canonical System Contract address
///         (0x8888888888888888888888888888888888888888) for end-to-end 3-chain testing.
contract MockReactiveSystem {
    uint256 public subscribeCount;
    uint256 public unsubscribeCount;

    event MockCallbackRequested(
        address indexed reactiveContract,
        uint256 indexed chainId,
        address indexed recipient,
        uint64 gasLimit,
        bytes payload
    );

    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCount += 1;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscribeCount += 1;
    }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory config_) external {
        ISystemContract.CallbackConfiguration_V_1_0 memory cfg =
            abi.decode(config_, (ISystemContract.CallbackConfiguration_V_1_0));
        emit MockCallbackRequested(msg.sender, cfg.chainId, cfg.recipient, cfg.gasLimit, cfg.payload);
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        emit MockCallbackRequested(msg.sender, config_.chainId, config_.recipient, config_.gasLimit, config_.payload);
    }
}
