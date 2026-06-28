// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SimpleAMM } from "../src/SimpleAMM.sol";
import { MockERC20 } from "../src/MockERC20.sol";

contract SimpleAMMTest is Test {
    SimpleAMM internal amm;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    uint256 internal constant INITIAL = 1_000_000 ether;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        amm = new SimpleAMM(address(tokenA), address(tokenB));

        tokenA.mint(lp, INITIAL);
        tokenB.mint(lp, INITIAL);
        tokenA.mint(trader, INITIAL);
        tokenB.mint(trader, INITIAL);
    }

    function _seedLiquidity(uint256 a, uint256 b) internal returns (uint256 liquidity) {
        // addLiquidity's args are positional (amount0/amount1 by sorted address), which
        // need not line up with tokenA/tokenB — approve both generously to stay agnostic.
        vm.startPrank(lp);
        tokenA.approve(address(amm), a + b);
        tokenB.approve(address(amm), a + b);
        liquidity = amm.addLiquidity(a, b);
        vm.stopPrank();
    }

    function test_constructor_ordersTokens() public view {
        // token0 is always the lower address.
        address t0 = address(amm.token0());
        address t1 = address(amm.token1());
        assertTrue(t0 < t1, "token0 must be < token1");
    }

    function test_addLiquidity_firstDepositMintsSharesAndLocksMinimum() public {
        uint256 liquidity = _seedLiquidity(100 ether, 400 ether);

        // sqrt(100e18 * 400e18) = 200e18; minus MINIMUM_LIQUIDITY.
        assertEq(liquidity, 200 ether - amm.MINIMUM_LIQUIDITY());
        assertEq(amm.balanceOf(lp), liquidity);
        assertEq(amm.balanceOf(address(1)), amm.MINIMUM_LIQUIDITY());
        assertEq(amm.totalSupply(), 200 ether);

        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(r0 + r1, 500 ether);
    }

    function test_addLiquidity_proportionalSecondDeposit() public {
        _seedLiquidity(100 ether, 100 ether);
        uint256 supplyBefore = amm.totalSupply();

        vm.startPrank(trader);
        tokenA.approve(address(amm), 50 ether);
        tokenB.approve(address(amm), 50 ether);
        uint256 minted = amm.addLiquidity(50 ether, 50 ether);
        vm.stopPrank();

        // Deposited half the reserves -> minted half the existing supply.
        assertEq(minted, supplyBefore / 2);
    }

    function test_swap_respectsConstantProductAndFee() public {
        _seedLiquidity(1_000 ether, 1_000 ether);

        uint256 amountIn = 10 ether;
        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 expectedOut = amm.getAmountOut(amountIn, r0, r1);

        uint256 balBefore = tokenB.balanceOf(trader);
        vm.startPrank(trader);
        tokenA.approve(address(amm), amountIn);
        uint256 out = amm.swap(address(tokenA), amountIn, expectedOut, trader);
        vm.stopPrank();

        assertEq(out, expectedOut);
        assertEq(tokenB.balanceOf(trader) - balBefore, expectedOut);
        // Fee keeps k non-decreasing.
        (uint256 nr0, uint256 nr1) = amm.getReserves();
        assertGe(nr0 * nr1, r0 * r1);
    }

    function test_swap_revertsOnSlippage() public {
        _seedLiquidity(1_000 ether, 1_000 ether);
        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 out = amm.getAmountOut(10 ether, r0, r1);

        vm.startPrank(trader);
        tokenA.approve(address(amm), 10 ether);
        vm.expectRevert(SimpleAMM.InsufficientOutputAmount.selector);
        amm.swap(address(tokenA), 10 ether, out + 1, trader);
        vm.stopPrank();
    }

    function test_swap_revertsOnInvalidToken() public {
        _seedLiquidity(1_000 ether, 1_000 ether);
        vm.prank(trader);
        vm.expectRevert(SimpleAMM.InvalidToken.selector);
        amm.swap(address(0xdead), 1 ether, 0, trader);
    }

    function test_removeLiquidity_returnsProportionalReserves() public {
        uint256 liquidity = _seedLiquidity(100 ether, 100 ether);

        vm.prank(lp);
        (uint256 a, uint256 b) = amm.removeLiquidity(liquidity);

        // lp burned all of its shares (minimum liquidity remains locked).
        assertEq(amm.balanceOf(lp), 0);
        assertGt(a, 0);
        assertGt(b, 0);
        // Roughly all but the locked dust comes back.
        assertApproxEqAbs(a, 100 ether, amm.MINIMUM_LIQUIDITY());
        assertApproxEqAbs(b, 100 ether, amm.MINIMUM_LIQUIDITY());
    }

    function testFuzz_getAmountOut_neverExceedsReserveOut(uint256 amountIn) public view {
        uint256 reserveIn = 1_000 ether;
        uint256 reserveOut = 1_000 ether;
        amountIn = bound(amountIn, 1, 1_000_000 ether);
        uint256 out = amm.getAmountOut(amountIn, reserveIn, reserveOut);
        assertLt(out, reserveOut);
    }
}
