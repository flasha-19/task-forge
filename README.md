# Task Forge

Task Forge is a small, non-custodial task marketplace for Arc Testnet. A task creator escrows ERC-20 USDC, contributors submit an offchain deliverable URL, the creator selects one submission, and the chosen contributor pulls the reward.

## Architecture

```text
MetaMask / EVM wallet
        │ approve + transact
        ▼
React + Vite + Wagmi ───────────────► Arc Testnet RPC
        │                                      │
        └──── read contract state ◄────────────┘
                                               │
                              ERC-20 USDC ──► TaskForge escrow
                                               │
              creator accepts ──► contributor reward credit
              cancellation/expiry ──► creator refund credit
                                               │
                         contributor/creator pull their funds
```

## Contract model

`TaskForge` holds one ERC-20 reward per task. The state machine is:

```text
Open → Awarded → Completed
  ├──→ Cancelled  (creator; before deadline; no submissions)
  └──→ Expired    (anyone; after deadline; no award)
```

Rewards and refunds are pull payments. Accepting moves the task reward to the accepted contributor's credit; cancellation or expiry moves it to the creator's refund credit. Only then can the entitled party withdraw. This ensures an expired/cancelled task cannot take a previously awarded reward.

Financial invariants:

- Each funded task increases `totalEscrowed` exactly once.
- A task can credit only one reward or one refund, never both.
- Withdrawal changes state/credit before its ERC-20 transfer and is reentrancy-protected.
- No function iterates over tasks or submissions in a state-changing transaction.

## Arc Testnet configuration

The checked settings are:

- Chain ID: `5042002`
- RPC: `https://rpc.testnet.arc.network`
- Explorer: `https://testnet.arcscan.app`
- ERC-20 USDC: `0x3600000000000000000000000000000000000000`
- USDC decimals: `6`
- Faucet: [Circle Faucet](https://faucet.circle.com)

Arc's ERC-20 USDC interface and decimals are documented by [Arcscan](https://docs.arc-scan.org/docs/addresses). The address remains an explicit deployment environment variable rather than a hardcoded constructor parameter.

## Install and test

Prerequisites: Foundry, Git, and Node.js 22+.

```powershell
cd contracts
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std --no-commit
forge fmt --check
forge build
forge test -vvv
```

Install and run the frontend:

```powershell
cd frontend
npm install
copy ..\.env.example .env.local
# Set VITE_TASK_FORGE_ADDRESS after deployment
npm run dev
```

The interface does not show invented tasks: without `VITE_TASK_FORGE_ADDRESS`, it displays a configuration notice and makes no contract writes.

## Deploy to Arc Testnet

1. Copy `.env.example` to `.env` at the repository root and set `PRIVATE_KEY`. Do not share or commit it.
2. Fund the deployer with Arc testnet USDC from the faucet. Arc uses USDC for gas.
3. From `contracts`, run:

```powershell
$env:ARC_RPC_URL="https://rpc.testnet.arc.network"
$env:PRIVATE_KEY="YOUR_PRIVATE_KEY"
$env:USDC_ADDRESS="0x3600000000000000000000000000000000000000"
forge script script/DeployTaskForge.s.sol:DeployTaskForge --rpc-url $env:ARC_RPC_URL --broadcast -vvvv
```

4. Record the deployed address and transaction hash in `deployments/arc-testnet.json` only after the transaction succeeds. Set `VITE_TASK_FORGE_ADDRESS` in `frontend/.env.local` to the address and rebuild.

The script rejects every chain other than Arc Testnet. It never reads a private key from frontend configuration.

## Publish the frontend

1. Commit and push the repository to GitHub.
2. In **Settings → Pages**, select **GitHub Actions** as the source.
3. In **Settings → Secrets and variables → Actions → Variables**, set `VITE_TASK_FORGE_ADDRESS` to the deployed contract address.
4. Push to `main` or run the **Deploy frontend to GitHub Pages** workflow.

The Vite base path is generated from GitHub's `GITHUB_REPOSITORY` value. The site will be available at `https://YOUR_GITHUB_USERNAME.github.io/YOUR_REPOSITORY_NAME/`.

## Repository layout

- `contracts/src/TaskForge.sol` — escrow marketplace contract.
- `contracts/test/TaskForge.t.sol` — local unit/security tests using a mock USDC.
- `contracts/script/DeployTaskForge.s.sol` — Arc-only deployment script.
- `frontend/` — React/Vite/Wagmi interface.
- `deployments/arc-testnet.json` — deployment record template; no fabricated deployment.
- `.github/workflows/` — contract CI and GitHub Pages workflow.

## Scope and limitations

Task descriptions and deliverable URLs are public blockchain data. Keep large files and sensitive information offchain. The MVP intentionally has no database or indexer; the frontend reads contract state directly and scans submissions for small task volumes. This is suitable for an MVP, not a high-volume production marketplace.
