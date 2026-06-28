# defi_eth — DEX/AMM for ETHGlobal

A constant-product (x·y=k) automated market maker in the style of Uniswap V2,
built as a **Foundry + Hardhat hybrid** so you get fast Solidity-native testing
*and* the TypeScript/ethers.js tooling for frontend integration.

## Contracts

| Contract | Description |
| --- | --- |
| [`src/SimpleAMM.sol`](src/SimpleAMM.sol) | Single-pair constant-product pool. Is itself the LP (ERC20) token. 0.3% swap fee accrues to LPs. Reentrancy-guarded, `SafeERC20` transfers, sorted token0/token1, locked `MINIMUM_LIQUIDITY`. |
| [`src/AMMFactory.sol`](src/AMMFactory.sol) | Deploys and registers one `SimpleAMM` pool per token pair, keyed by sorted addresses (`getPair`). |
| [`src/AMMRouter.sol`](src/AMMRouter.sol) | User-facing entry point: ratio-balanced `addLiquidity`/`removeLiquidity` with per-token slippage floors and deadlines, plus multi-hop `swapExactTokensForTokens` across a `path`. Holds no funds between calls. |
| [`src/MockERC20.sol`](src/MockERC20.sol) | Freely-mintable ERC20 with a faucet, for local/testnet seeding. **Not for mainnet.** |

Typical flow: users interact with the **Router**, which looks up pools via the **Factory** and routes through the underlying **SimpleAMM** pools.

> ⚠️ Hackathon-grade primitive. Reserves are synced from balances, so
> fee-on-transfer / rebasing tokens are **not** supported. Not audited.

## Stack

- **Foundry** (`forge`/`cast`/`anvil`) — contracts, Solidity tests, gas reports, scripted deploys.
- **Hardhat** + `@nomicfoundation/hardhat-foundry` — reads `foundry.toml` + `remappings.txt`, so both toolchains share `src/` and `lib/`. TypeChain types are generated for the frontend.
- **OpenZeppelin Contracts v5** + **forge-std**, vendored under `lib/`.

## Layout

```
src/            Solidity contracts (shared by both toolchains)
test/           Foundry tests (*.t.sol)
test-hardhat/   Hardhat/TS tests (*.ts)
script/         Foundry deploy scripts (*.s.sol)
scripts/        Hardhat/TS deploy scripts (*.ts)
lib/            Foundry deps (forge-std, openzeppelin-contracts)
```

## Setup

```bash
forge install      # already vendored in lib/, re-run if cloning fresh
npm install        # Hardhat + toolchain
cp .env.example .env
```

## Build & test

```bash
# Foundry (primary)
forge build
forge test            # npm run test
forge test --gas-report

# Hardhat (TS / ethers integration)
npm run hh:compile
npx hardhat test
```

## Deploy to local Anvil

```bash
# Terminal 1 — start the local chain
anvil                         # npm run node

# Terminal 2 — deploy + seed liquidity (uses PRIVATE_KEY from .env)
npm run deploy:local          # Foundry script
# or
npm run hh:deploy:local       # Hardhat/ethers script
```

Both deploy the factory, router, three demo tokens (`dUSD`/`dETH`/`dDAI`), and
seed two pools (A/B and B/C) so a multi-hop **dUSD → dETH → dDAI** swap works
out of the box via `router.swapExactTokensForTokens`.

## Next steps

- Wire up Sepolia / Base Sepolia in `foundry.toml` and `hardhat.config.ts` (placeholders included) when ready to demo on a public testnet.
- Add `swapTokensForExactTokens` (exact-output) and native-ETH wrapping (WETH) router helpers.
- Build the frontend against the generated `typechain-types/`.
