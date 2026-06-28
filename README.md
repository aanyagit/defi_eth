# defi_eth — DEX/AMM for ETHGlobal

A constant-product (x·y=k) automated market maker in the style of Uniswap V2,
built as a **Foundry + Hardhat hybrid** so you get fast Solidity-native testing
*and* the TypeScript/ethers.js tooling for frontend integration.

## Contracts

| Contract | Description |
| --- | --- |
| [`src/SimpleAMM.sol`](src/SimpleAMM.sol) | Single-pair constant-product AMM. Is itself the LP (ERC20) token. 0.3% swap fee accrues to LPs. Reentrancy-guarded, `SafeERC20` transfers, sorted token0/token1, locked `MINIMUM_LIQUIDITY`. |
| [`src/MockERC20.sol`](src/MockERC20.sol) | Freely-mintable ERC20 with a faucet, for local/testnet seeding. **Not for mainnet.** |

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

Both deploy two demo tokens (`dUSD`/`dETH`), a `SimpleAMM` pool, and seed
100k/100k initial liquidity so the pool is immediately tradeable.

## Next steps

- Add a `Router` contract for multi-hop swaps and balanced `addLiquidity` (with min-amount slippage guards).
- Wire up Sepolia / Base Sepolia in `foundry.toml` and `hardhat.config.ts` (placeholders included) when ready to demo on a public testnet.
- Build the frontend against the generated `typechain-types/`.
