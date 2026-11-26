# OmniGuard — 2-Minute Judge Demo Script & Live 3-Chain Proof Checklist

> Target: **DoraHacks Reactive Omni Buildathon — Track 1: Every Second Counts (`$2,000` 1st / `$5,500` total REACT)**
> Native **`reactive-lib-omni`** (`SYSTEM = 0x8888888888888888888888888888888888888888`, Solc `0.8.29`)

## 1. Live Deployed Contracts (All Explorer-Verified)
- **Base Sepolia (`84532`) `OmniGuardVault`**: `0xFb0dF9C593dF951B75d35ea3Caf6a75fA689e7ab` (Deploy TX `0x8c6c77390c0656212ac7b325d962e7bc57ea45afe55ae29a88c816bbf9127a9a`)
- **Reactive Lasna Omni (`5318007`) `OmniGuardSentinel`**: `0xfF1E8e50C8895897C00a0c801E73abE2F1337edA` (Deploy TX `0x60b8c6b04fb7a66804a8d32348e5e3b078633704ca66a98d78587b0a68c97961`)
- **Unichain Sepolia (`1301`) `CrossChainMirrorGuardian`**: `0x48eba200ACC1C45bC83eF9a5c1445d690470453E` (Deploy TX `0x052eeca0dcd99c8ef50a7f3995de0e7f5e7536791df1a8a89943c8fb9666d402`)

## 2. Verified Live End-to-End 3-Chain Loop (`1s` Base / `3s` Unichain)
1. **Base Sepolia Origin Register (`registerOrder`)**: `0xc661daf57fe559f7199be8391a7be3286da09f723e38d85aacfdcd9b27a3fe5e` (`#63864488`)
2. **Reactive Lasna Ingest (`react`)**: `0xe732d12bf7e6a3367d0560f23187fa24e4bdac2563f72796f7ee3740d0d4a701` (`#9295466`)
3. **Base Sepolia Origin Price Crash (`publishPriceTick $2,950`)**: `0xfec6f0f5f8452e4aad1675b4a93eba50e7dc764fa4f336bce28fdc3042bb0298` (`#63864495`)
4. **Reactive Lasna Dual Fan-Out (`react` → `SYSTEM.requestCallbackV_1_0` ×2)**: `0xd0904a2f2a5246a91d4cde253dde65172b4365dbf14c8e74ff4a9c6905ea4518` (`#9295467`)
5. **Base Sepolia Destination Callback (`executeOrder`, `1s` on-chain latency, `status: ok`)**: `0xef5f95bd994e71fc1b4a312562f2cfd654c4754c9768f8567bc6c8bc1a2d8996` (`#63864500`)
6. **Unichain Sepolia Parallel Callback (`recordHedgeSignal`, `3s` cross-chain latency, `status: ok`)**: `0x7f02b84fe6cafcd321ae3aa11def922c172e47ab998b1f24941ef0ce7185ccfa` (`#68842342`)

## 3. 50-Second HD Demo Video Storyboard (`docs/demo.mp4`)
- **0:00 – 0:06**: Title & live 3-chain latency headline (`1s` Base / `3s` Unichain).
- **0:06 – 0:16**: Live 3-chain RPC auto-poll dashboard reading `getLatencyStats()` across Base Sepolia, Lasna Omni, and Unichain Sepolia + clickable explorer proof table.
- **0:16 – 0:26**: Stateful decaying slow-bleed slippage defense (`3 × 1.90%` swaps -> dual-chain freeze + cap tightened `200 -> 25 bps`).
- **0:26 – 0:35**: Keeper-less sub-second stop-loss & parallel Unichain hedge fan-out (`onlySystem` + `onlyServiceProvider` + immutable `onlyCallbackSender`).
- **0:35 – 0:45**: Stale-accrual & utilization spike defense + `15/15` Foundry verification (`5 × 256` fuzz runs, `0` warnings).
- **0:45 – 0:50**: Open-source MIT links & live GitHub Pages dashboard.
