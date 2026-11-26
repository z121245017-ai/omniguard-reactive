// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {OmniGuardVault} from "../src/OmniGuardVault.sol";

/// @notice Triggers the live end-to-end Reactive Omni demonstration loop on Base Sepolia:
///         1) Register a keeper-less stop-loss order & trigger it via price tick (~1s Base settlement + Unichain hedge)
///         2) Emit a 30-day stale-accrual + 99.5% utilization spike to trip BOTH Base Sepolia and Unichain Sepolia
///            circuit breakers automatically in ~1-2 seconds.
contract TriggerDemoLoop is Script {
    address public constant DEMO_ETH_ASSET = 0x4200000000000000000000000000000000000006; // Base WETH

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        OmniGuardVault vault = OmniGuardVault(payable(vm.envAddress("BASE_SEPOLIA_VAULT")));

        vm.startBroadcast(pk);

        // Scenario A: Keeper-less Stop-Loss ($3,000 trigger -> $2,950 tick) -> dual callback (Base settle + Unichain hedge)
        uint256 orderId = vault.registerOrder(10 ether, 3000e8, true);
        console2.log("Registered Stop-Loss orderId:", orderId);
        vault.publishPriceTick(DEMO_ETH_ASSET, 2950e8);
        console2.log("Published crash price tick ($2,950) at timestamp:", block.timestamp);

        // Scenario B: Stale-Accrual + Critical Utilization Spike -> dual callback (Base freeze + Unichain mirror freeze)
        vault.recordVaultAccrual(9950, 30 days, 1_990_000e6);
        console2.log("Submitted stale-accrual 99.5% utilization spike at timestamp:", block.timestamp);

        vm.stopBroadcast();
    }
}
