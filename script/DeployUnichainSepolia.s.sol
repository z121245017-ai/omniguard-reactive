// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {CrossChainMirrorGuardian} from "../src/CrossChainMirrorGuardian.sol";

/// @notice Deploys CrossChainMirrorGuardian on Unichain Sepolia (chain 1301) using the official Reactive Callback Proxy.
contract DeployUnichainSepolia is Script {
    // Official Reactive Omni Callback Proxy on Unichain Sepolia (verified via dev.reactive.network/origins-and-destinations)
    address public constant UNICHAIN_SEPOLIA_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    function run() external returns (CrossChainMirrorGuardian mirror) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 fundingWei = vm.envOr("CALLBACK_FUNDING_WEI", uint256(0.01 ether));

        vm.startBroadcast(pk);
        mirror = new CrossChainMirrorGuardian{value: fundingWei}(UNICHAIN_SEPOLIA_CALLBACK_PROXY);
        vm.stopBroadcast();

        console2.log("CrossChainMirrorGuardian deployed on Unichain Sepolia:", address(mirror));
        console2.log("Callback Proxy:", UNICHAIN_SEPOLIA_CALLBACK_PROXY);
        console2.log("Funded wei:", fundingWei);
    }
}
