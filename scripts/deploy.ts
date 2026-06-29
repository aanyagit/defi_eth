import { ethers } from "hardhat";

// Hardhat/ethers.js deployment of the full DEX stack, mirroring script/Deploy.s.sol:
// WETH + factory + router + two demo tokens, a token/token pool (A/B) and a
// token/ETH pool (A/WETH) for native-ETH swaps.
// Run against a local node:  npm run hh:deploy:local
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const seed = ethers.parseEther("100000");
  const ethSeed = ethers.parseEther("0.1"); // faucet-friendly for testnets
  const maxUint = ethers.MaxUint256;
  const deadline = Math.floor(Date.now() / 1000) + 3600;

  const WETH9 = await ethers.getContractFactory("WETH9");
  const weth = await WETH9.deploy();
  await weth.waitForDeployment();

  const Factory = await ethers.getContractFactory("AMMFactory");
  const factory = await Factory.deploy();
  await factory.waitForDeployment();

  const Router = await ethers.getContractFactory("AMMRouter");
  const router = await Router.deploy(await factory.getAddress(), await weth.getAddress());
  await router.waitForDeployment();
  const routerAddr = await router.getAddress();

  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const tokenA = await MockERC20.deploy("Demo USD", "dUSD", 18);
  const tokenB = await MockERC20.deploy("Demo DAI", "dDAI", 18);
  await Promise.all([tokenA.waitForDeployment(), tokenB.waitForDeployment()]);

  await (await tokenA.mint(deployer.address, seed * 2n)).wait();
  await (await tokenB.mint(deployer.address, seed)).wait();
  await (await tokenA.approve(routerAddr, maxUint)).wait();
  await (await tokenB.approve(routerAddr, maxUint)).wait();

  const [a, b] = [await tokenA.getAddress(), await tokenB.getAddress()];
  await (await router.addLiquidity(a, b, seed, seed, 0, 0, deployer.address, deadline)).wait();
  await (
    await router.addLiquidityETH(a, seed, 0, 0, deployer.address, deadline, { value: ethSeed })
  ).wait();

  console.log("WETH:   ", await weth.getAddress());
  console.log("Factory:", await factory.getAddress());
  console.log("Router: ", routerAddr);
  console.log("Token A (dUSD):", a);
  console.log("Token B (dDAI):", b);
  console.log("Pair A/B:   ", await factory.getPair(a, b));
  console.log("Pair A/WETH:", await factory.getPair(a, await weth.getAddress()));
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
