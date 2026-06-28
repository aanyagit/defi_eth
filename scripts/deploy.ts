import { ethers } from "hardhat";

// Hardhat/ethers.js deployment of the DEX stack, mirroring script/Deploy.s.sol.
// Run against a local node:  npm run hh:deploy:local
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const seed = ethers.parseEther("100000");

  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const tokenA = await MockERC20.deploy("Demo USD", "dUSD", 18);
  const tokenB = await MockERC20.deploy("Demo ETH", "dETH", 18);
  await tokenA.waitForDeployment();
  await tokenB.waitForDeployment();

  const SimpleAMM = await ethers.getContractFactory("SimpleAMM");
  const amm = await SimpleAMM.deploy(
    await tokenA.getAddress(),
    await tokenB.getAddress(),
  );
  await amm.waitForDeployment();

  // Seed balances + initial liquidity so the pool is immediately tradeable.
  await (await tokenA.mint(deployer.address, seed)).wait();
  await (await tokenB.mint(deployer.address, seed)).wait();
  await (await tokenA.approve(await amm.getAddress(), seed)).wait();
  await (await tokenB.approve(await amm.getAddress(), seed)).wait();
  await (await amm.addLiquidity(seed, seed)).wait();

  console.log("Token A:  ", await tokenA.getAddress());
  console.log("Token B:  ", await tokenB.getAddress());
  console.log("SimpleAMM:", await amm.getAddress());
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
