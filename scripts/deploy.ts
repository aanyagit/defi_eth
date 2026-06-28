import { ethers } from "hardhat";

// Hardhat/ethers.js deployment of the full DEX stack, mirroring script/Deploy.s.sol:
// factory + router + three demo tokens + two seeded pools (A/B, B/C) for multi-hop.
// Run against a local node:  npm run hh:deploy:local
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const seed = ethers.parseEther("100000");
  const maxUint = ethers.MaxUint256;
  const deadline = Math.floor(Date.now() / 1000) + 3600;

  const Factory = await ethers.getContractFactory("AMMFactory");
  const factory = await Factory.deploy();
  await factory.waitForDeployment();

  const Router = await ethers.getContractFactory("AMMRouter");
  const router = await Router.deploy(await factory.getAddress());
  await router.waitForDeployment();
  const routerAddr = await router.getAddress();

  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const tokenA = await MockERC20.deploy("Demo USD", "dUSD", 18);
  const tokenB = await MockERC20.deploy("Demo ETH", "dETH", 18);
  const tokenC = await MockERC20.deploy("Demo DAI", "dDAI", 18);
  await Promise.all([
    tokenA.waitForDeployment(),
    tokenB.waitForDeployment(),
    tokenC.waitForDeployment(),
  ]);

  await (await tokenA.mint(deployer.address, seed)).wait();
  await (await tokenB.mint(deployer.address, seed * 2n)).wait();
  await (await tokenC.mint(deployer.address, seed)).wait();
  await (await tokenA.approve(routerAddr, maxUint)).wait();
  await (await tokenB.approve(routerAddr, maxUint)).wait();
  await (await tokenC.approve(routerAddr, maxUint)).wait();

  const [a, b, c] = [
    await tokenA.getAddress(),
    await tokenB.getAddress(),
    await tokenC.getAddress(),
  ];
  await (await router.addLiquidity(a, b, seed, seed, 0, 0, deployer.address, deadline)).wait();
  await (await router.addLiquidity(b, c, seed, seed, 0, 0, deployer.address, deadline)).wait();

  console.log("Factory:", await factory.getAddress());
  console.log("Router: ", routerAddr);
  console.log("Token A (dUSD):", a);
  console.log("Token B (dETH):", b);
  console.log("Token C (dDAI):", c);
  console.log("Pair A/B:", await factory.getPair(a, b));
  console.log("Pair B/C:", await factory.getPair(b, c));
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
