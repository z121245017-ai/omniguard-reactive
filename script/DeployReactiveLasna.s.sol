// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {OmniGuardSentinel} from "../src/OmniGuardSentinel.sol";

/// @notice Deploys OmniGuardSentinel on Reactive Network Lasna Testnet (chain 5318007)
///         subscribing to Base Sepolia OmniGuardVault events and fanning out callbacks to
///         BOTH Base Sepolia and Unichain Sepolia.
contract DeployReactiveLasna is Script {
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    function run() external returns (OmniGuardSentinel sentinel) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address originVault = vm.envAddress("BASE_SEPOLIA_VAULT");
        address mirrorGuardian = vm.envOr("UNICHAIN_SEPOLIA_MIRROR", address(0));
        uint256 fundingWei = vm.envOr("LASNA_FUNDING_WEI", uint256(0.5 ether)); // 0.5 lREACT

        vm.startBroadcast(pk);
        sentinel = new OmniGuardSentinel{value: fundingWei}(
            BASE_SEPOLIA_CHAIN_ID,
            UNICHAIN_SEPOLIA_CHAIN_ID,
            originVault,
            mirrorGuardian,
            3600,  // 1-hour decaying slippage window
            500,   // 5.00% cumulative slippage breach
            86400, // 24-hour stale accrual threshold
            9000,  // 90.00% critical utilization threshold
            7000   // 70.00% single-block utilization jump
        );
        vm.stopBroadcast();

        console2.log("OmniGuardSentinel deployed on Reactive Lasna:", address(sentinel));
        console2.log("Monitoring Base Sepolia Vault:", originVault);
        console2.log("Mirror Guardian (Unichain Sepolia):", mirrorGuardian);
        console2.log("Funded lREACT (wei):", fundingWei);
    }
}
