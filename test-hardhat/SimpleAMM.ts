import { expect } from "chai";
import { ethers } from "hardhat";

// Smoke test proving the Hardhat/ethers.js layer can drive the same contracts
// Foundry tests. Deep invariant testing lives in test/SimpleAMM.t.sol.
describe("SimpleAMM (hardhat)", () => {
  async function deploy() {
    const [deployer, trader] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const tokenA = await MockERC20.deploy("Token A", "TKA", 18);
    const tokenB = await MockERC20.deploy("Token B", "TKB", 18);
    const SimpleAMM = await ethers.getContractFactory("SimpleAMM");
    const amm = await SimpleAMM.deploy(
      await tokenA.getAddress(),
      await tokenB.getAddress(),
    );
    return { deployer, trader, tokenA, tokenB, amm };
  }

  it("seeds liquidity and swaps along the constant-product curve", async () => {
    const { deployer, trader, tokenA, tokenB, amm } = await deploy();
    const ammAddr = await amm.getAddress();
    const amount = ethers.parseEther("1000");

    await tokenA.mint(deployer.address, amount);
    await tokenB.mint(deployer.address, amount);
    await tokenA.approve(ammAddr, amount);
    await tokenB.approve(ammAddr, amount);
    await amm.addLiquidity(amount, amount);

    expect(await amm.totalSupply()).to.be.gt(0n);

    const swapIn = ethers.parseEther("10");
    await tokenA.mint(trader.address, swapIn);
    await tokenA.connect(trader).approve(ammAddr, swapIn);

    const before = await tokenB.balanceOf(trader.address);
    await amm
      .connect(trader)
      .swap(await tokenA.getAddress(), swapIn, 0n, trader.address);
    const received = (await tokenB.balanceOf(trader.address)) - before;

    expect(received).to.be.gt(0n);
    expect(received).to.be.lt(swapIn); // fee + slippage
  });
});
