// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {CrossChainMirrorGuardian} from "../src/CrossChainMirrorGuardian.sol";

/// @notice Deploys CrossChainMirrorGuardian on Unichain Sepolia (chain 1301) bound to the official Reactive Omni
///         Callback Proxy and the deterministic OmniGuardSentinel contract address on Reactive Lasna (5318007).
contract DeployUnichainSepolia is Script {
    address public constant UNICHAIN_SEPOLIA_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    function run() external returns (CrossChainMirrorGuardian mirror) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address expectedSentinel = vm.envAddress("EXPECTED_SENTINEL");
        uint256 fundingWei = vm.envOr("CALLBACK_FUNDING_WEI", uint256(0.002 ether));

        vm.startBroadcast(pk);
        mirror = new CrossChainMirrorGuardian{value: fundingWei}(UNICHAIN_SEPOLIA_CALLBACK_PROXY, expectedSentinel);
        vm.stopBroadcast();

        console2.log("CrossChainMirrorGuardian deployed on Unichain Sepolia:", address(mirror));
        console2.log("Callback Proxy:", UNICHAIN_SEPOLIA_CALLBACK_PROXY);
        console2.log("Authorized Reactive Sentinel:", expectedSentinel);
        console2.log("Funded wei:", fundingWei);
    }
}
