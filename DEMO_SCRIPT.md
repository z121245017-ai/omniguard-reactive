# OmniGuard — 2-Minute Judge Demo Script & 1-Command Live Deploy Checklist

> Target: **DoraHacks Reactive Omni Buildathon — Track 1: Every Second Counts (`$2,000` 1st / `$5,500` total REACT)**  
> Deployer Testnet Wallet: `0x0Cf943E4043b47D2ccba0ca94a2d45989a3fF260`

## 1. Free Testnet Faucet Checklist (`$0.00` real spend)
1. **Base Sepolia (`84532`)**: Get `>= 0.05` Base Sepolia ETH (e.g., Coinbase CDP Faucet / QuickNode / Alchemy / Superchain Faucet) → `0x0Cf943E4043b47D2ccba0ca94a2d45989a3fF260`.
2. **Unichain Sepolia (`1301`)**: Get `>= 0.02` Unichain Sepolia ETH (Superchain Faucet / QuickNode) → `0x0Cf943E4043b47D2ccba0ca94a2d45989a3fF260`.
3. **Reactive Lasna (`5318007`)**: Send `0.02` Sepolia ETH to official Lasna Faucet `0x2afaFD298b23b62760711756088F75B7409f5967` (mints `lREACT` automatically on Lasna `5318007`).

## 2. Exact 4-Command 3-Chain Live Deployment
```bash
cd /Users/zhufan/Documents/Gemini接单/projects/reactive-vault-sentinel
export PRIVATE_KEY=<deployer_private_key>

# Step 1: Deploy Origin + Destination Vault on Base Sepolia (84532)
~/.foundry/bin/forge script script/DeployBaseSepolia.s.sol:DeployBaseSepolia \
  --rpc-url https://sepolia.base.org --broadcast

# Step 2: Deploy Cross-Chain Mirror Guardian on Unichain Sepolia (1301)
~/.foundry/bin/forge script script/DeployUnichainSepolia.s.sol:DeployUnichainSepolia \
  --rpc-url https://sepolia.unichain.org --broadcast

# Step 3: Deploy Stateful Sentinel on Reactive Lasna (5318007)
export BASE_SEPOLIA_VAULT=<deployed_base_vault>
export UNICHAIN_SEPOLIA_MIRROR=<deployed_unichain_mirror>
~/.foundry/bin/forge script script/DeployReactiveLasna.s.sol:DeployReactiveLasna \
  --rpc-url https://lasna-rpc.rnk.dev/ --broadcast

# Step 4: Trigger Live End-to-End 3-Chain Demo Loop (Stop-Loss + Slow-Bleed Circuit Breaker)
~/.foundry/bin/forge script script/TriggerDemoLoop.s.sol:TriggerDemoLoop \
  --rpc-url https://sepolia.base.org --broadcast
```

## 3. 2-Minute Demo Video Storyboard
- **0:00 – 0:25 (Problem)**: Show why single-tx vault slippage caps (`2.00%`) fail against consecutive `1.90%` slow-bleed swaps and why off-chain keeper bots miss sub-second cross-chain contagion.
- **0:25 – 0:55 (Architecture)**: Walk through the 3-chain Mermaid diagram (`Base Sepolia OmniGuardVault` → `Reactive Lasna OmniGuardSentinel` → parallel ~1s callbacks to Base Sepolia + Unichain Sepolia `CrossChainMirrorGuardian`).
- **0:55 – 1:30 (Live Testnet Proof)**: Show `TriggerDemoLoop` tx on BaseScan Sepolia, Reactscan tx on Lasna, and the automatic ~1-second callback receipts + `getLatencyStats()` on BOTH Base Sepolia and Unichain Sepolia inside `dashboard/index.html`.
- **1:30 – 2:00 (Verification & Security)**: Run `forge test -vv` showing **`16/16` tests passing** (`10` E2E integration tests + `5 × 256`-run fuzz property tests + duplicate-order idempotency check, `0` warnings), highlighting RVM ID authentication and incident replay protection.
