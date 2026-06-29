# defi_eth — DEX/AMM for ETHGlobal

A constant-product (x·y=k) automated market maker in the style of Uniswap V2,
built as a **Foundry + Hardhat hybrid** so you get fast Solidity-native testing
*and* the TypeScript/ethers.js tooling for frontend integration.

## Contracts

| Contract | Description |
| --- | --- |
| [`src/SimpleAMM.sol`](src/SimpleAMM.sol) | Single-pair constant-product pool. Is itself the LP (ERC20) token. 0.3% swap fee accrues to LPs. Reentrancy-guarded, `SafeERC20` transfers, sorted token0/token1, locked `MINIMUM_LIQUIDITY`. |
| [`src/AMMFactory.sol`](src/AMMFactory.sol) | Deploys and registers one `SimpleAMM` pool per token pair, keyed by sorted addresses (`getPair`). |
| [`src/AMMRouter.sol`](src/AMMRouter.sol) | User-facing entry point: ratio-balanced liquidity provision and multi-hop swaps (exact-input *and* exact-output), with native-ETH variants that wrap/unwrap via WETH. Per-token slippage floors and deadlines throughout. Holds no funds between calls. |
| [`src/WETH9.sol`](src/WETH9.sol) | Minimal canonical wrapped-ether (deposit/withdraw) so the ERC20-only pools can trade against native ETH. |
| [`src/MockERC20.sol`](src/MockERC20.sol) | Freely-mintable ERC20 with a faucet, for local/testnet seeding. **Not for mainnet.** |

### Router surface

- **Liquidity**: `addLiquidity` / `removeLiquidity`, `addLiquidityETH` / `removeLiquidityETH`
- **Exact-input swaps**: `swapExactTokensForTokens`, `swapExactETHForTokens`, `swapExactTokensForETH`
- **Exact-output swaps**: `swapTokensForExactTokens`, `swapETHForExactTokens`, `swapTokensForExactETH`
- **Quoting**: `getAmountsOut` (forward), `getAmountsIn` (reverse)

Exact-output swaps deliver *at least* the requested output while never spending more than `amountInMax` (the pools price by exact input, so any rounding surplus is negligible dust).

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

Both deploy WETH, the factory, router, and two demo tokens (`dUSD`/`dDAI`), then
seed a token/token pool (A/B) and a token/ETH pool (A/WETH) — so token swaps and
native-ETH swaps both work out of the box.

## Deploy to a testnet

Fill in the RPC URLs, a funded `PRIVATE_KEY`, and verification keys in `.env`
(see [.env.example](.env.example)), then:

```bash
npm run deploy:sepolia          # Foundry → Sepolia (+ Etherscan verify)
npm run deploy:base-sepolia     # Foundry → Base Sepolia (+ Basescan verify)
# Hardhat equivalents:
npm run hh:deploy:sepolia
npm run hh:deploy:base-sepolia
```

Networks are pre-configured in both [foundry.toml](foundry.toml) and
[hardhat.config.ts](hardhat.config.ts). The seed deploy uses **0.1 ETH** for the
ETH pool to stay faucet-friendly.

## Next steps

- Build the frontend against the generated `typechain-types/`.
- Consider a permissionless price oracle (cumulative-price TWAP) on the pairs.
- Harden for non-standard tokens (fee-on-transfer support) before any real value.
