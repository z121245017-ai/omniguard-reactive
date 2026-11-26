// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {OmniGuardVault} from "../src/OmniGuardVault.sol";

/// @notice Deploys OmniGuardVault on Base Sepolia (chain 84532) bound to the official Reactive Omni Callback Proxy
///         and the deterministic OmniGuardSentinel contract address on Reactive Lasna (5318007).
contract DeployBaseSepolia is Script {
    address public constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external returns (OmniGuardVault vault) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address expectedSentinel = vm.envAddress("EXPECTED_SENTINEL");
        uint256 fundingWei = vm.envOr("CALLBACK_FUNDING_WEI", uint256(0.002 ether));

        vm.startBroadcast(pk);
        vault = new OmniGuardVault{value: fundingWei}(BASE_SEPOLIA_CALLBACK_PROXY, expectedSentinel);
        vm.stopBroadcast();

        console2.log("OmniGuardVault deployed on Base Sepolia:", address(vault));
        console2.log("Callback Proxy:", BASE_SEPOLIA_CALLBACK_PROXY);
        console2.log("Authorized Reactive Sentinel:", expectedSentinel);
        console2.log("Funded wei:", fundingWei);
    }
}
