// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {OmniGuardVault} from "../src/OmniGuardVault.sol";

/// @notice Triggers the live end-to-end Reactive Omni demonstration loop on Base Sepolia:
///         1) Register a keeper-less stop-loss order & trigger it via price tick (1-second callback + Unichain hedge)
///         2) Execute 3 consecutive 1.90% swaps (below local 2% guard) to prove cumulative slow-bleed detection
///            tripping BOTH Base Sepolia and Unichain Sepolia circuit breakers automatically.
contract TriggerDemoLoop is Script {
    address public constant DEMO_ETH_ASSET = 0x4200000000000000000000000000000000000006; // Base WETH

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        OmniGuardVault vault = OmniGuardVault(payable(vm.envAddress("BASE_SEPOLIA_VAULT")));

        vm.startBroadcast(pk);

        // Scenario A: Keeper-less Stop-Loss ($3,000 trigger -> $2,950 tick)
        uint256 orderId = vault.registerOrder(10 ether, 3000e8, true);
        console2.log("Registered Stop-Loss orderId:", orderId);
        vault.publishPriceTick(DEMO_ETH_ASSET, 2950e8);
        console2.log("Published crash price tick ($2,950) at timestamp:", block.timestamp);

        // Scenario B: Slow-Bleed Cumulative Slippage (3 x 1.90% swaps = 5.70% > 5.00% Reactive threshold)
        vault.recordVaultSwap(100_000e6, 98_100e6);
        vault.recordVaultSwap(100_000e6, 98_100e6);
        vault.recordVaultSwap(100_000e6, 98_100e6);
        console2.log("Submitted 3 x 1.90% swaps at timestamp:", block.timestamp);

        vm.stopBroadcast();
    }
}
