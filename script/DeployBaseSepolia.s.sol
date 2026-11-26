// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {OmniGuardVault} from "../src/OmniGuardVault.sol";

/// @notice Deploys OmniGuardVault on Base Sepolia (chain 84532) using the official Reactive Callback Proxy.
contract DeployBaseSepolia is Script {
    // Official Reactive Omni Callback Proxy on Base Sepolia (verified via dev.reactive.network/origins-and-destinations)
    address public constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external returns (OmniGuardVault vault) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 fundingWei = vm.envOr("CALLBACK_FUNDING_WEI", uint256(0.01 ether));

        vm.startBroadcast(pk);
        vault = new OmniGuardVault{value: fundingWei}(BASE_SEPOLIA_CALLBACK_PROXY);
        vm.stopBroadcast();

        console2.log("OmniGuardVault deployed on Base Sepolia:", address(vault));
        console2.log("Callback Proxy:", BASE_SEPOLIA_CALLBACK_PROXY);
        console2.log("Funded wei:", fundingWei);
    }
}
