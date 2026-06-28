// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { AMMFactory } from "../src/AMMFactory.sol";
import { AMMRouter } from "../src/AMMRouter.sol";
import { SimpleAMM } from "../src/SimpleAMM.sol";
import { MockERC20 } from "../src/MockERC20.sol";

contract AMMRouterTest is Test {
    AMMFactory internal factory;
    AMMRouter internal router;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    address internal user = makeAddr("user");
    uint256 internal constant MINT = 10_000_000 ether;
    uint256 internal deadline;

    function setUp() public {
        factory = new AMMFactory();
        router = new AMMRouter(address(factory));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        tokenC = new MockERC20("Token C", "TKC", 18);

        deadline = block.timestamp + 1 hours;

        tokenA.mint(user, MINT);
        tokenB.mint(user, MINT);
        tokenC.mint(user, MINT);

        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _addLiquidity(MockERC20 t0, MockERC20 t1, uint256 a0, uint256 a1) internal {
        vm.prank(user);
        router.addLiquidity(address(t0), address(t1), a0, a1, 0, 0, user, deadline);
    }

    function test_addLiquidity_createsPairAndMintsLpToUser() public {
        vm.prank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 1_000 ether, 4_000 ether, 0, 0, user, deadline
        );

        assertEq(amountA, 1_000 ether);
        assertEq(amountB, 4_000 ether);
        assertGt(liquidity, 0);

        address pair = factory.getPair(address(tokenA), address(tokenB));
        assertTrue(pair != address(0));
        assertEq(SimpleAMM(pair).balanceOf(user), liquidity);
        assertEq(factory.allPairsLength(), 1);
    }

    function test_addLiquidity_balancesToReserveRatio() public {
        _addLiquidity(tokenA, tokenB, 1_000 ether, 1_000 ether); // price 1:1

        // Try to deposit 500 A / 2000 B against a 1:1 pool -> B is scaled down to 500.
        vm.prank(user);
        (uint256 amountA, uint256 amountB,) = router.addLiquidity(
            address(tokenA), address(tokenB), 500 ether, 2_000 ether, 0, 0, user, deadline
        );

        assertEq(amountA, 500 ether);
        assertEq(amountB, 500 ether);
    }

    function test_addLiquidity_revertsWhenBelowMin() public {
        _addLiquidity(tokenA, tokenB, 1_000 ether, 1_000 ether);

        // Balanced B would be 500, but we demand at least 1900 -> revert.
        vm.prank(user);
        vm.expectRevert(AMMRouter.InsufficientBAmount.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB), 500 ether, 2_000 ether, 0, 1_900 ether, user, deadline
        );
    }

    function test_swap_multiHop_AtoBtoC() public {
        // Two pools sharing tokenB: A/B and B/C, both 1:1 priced.
        _addLiquidity(tokenA, tokenB, 100_000 ether, 100_000 ether);
        _addLiquidity(tokenB, tokenC, 100_000 ether, 100_000 ether);

        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountIn = 1_000 ether;
        uint256[] memory expected = router.getAmountsOut(amountIn, path);

        uint256 cBefore = tokenC.balanceOf(user);
        vm.prank(user);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(amountIn, expected[2], path, user, deadline);

        assertEq(amounts[0], amountIn);
        assertEq(amounts[2], expected[2]);
        assertEq(tokenC.balanceOf(user) - cBefore, expected[2]);
        // Two 0.3% hops -> output is below a hypothetical 1:1 single hop.
        assertLt(amounts[2], amountIn);
    }

    function test_swap_revertsOnSlippage() public {
        _addLiquidity(tokenA, tokenB, 100_000 ether, 100_000 ether);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountIn = 1_000 ether;
        uint256 out = router.getAmountsOut(amountIn, path)[1];

        vm.prank(user);
        vm.expectRevert(AMMRouter.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(amountIn, out + 1, path, user, deadline);
    }

    function test_swap_revertsWhenPairMissing() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenC);

        vm.prank(user);
        vm.expectRevert(AMMRouter.PairNotFound.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, user, deadline);
    }

    function test_removeLiquidity_returnsUnderlyingToUser() public {
        vm.prank(user);
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 1_000 ether, 1_000 ether, 0, 0, user, deadline
        );

        address pair = factory.getPair(address(tokenA), address(tokenB));
        vm.startPrank(user);
        SimpleAMM(pair).approve(address(router), liquidity);
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            address(tokenA), address(tokenB), liquidity, 0, 0, user, deadline
        );
        vm.stopPrank();

        assertGt(amountA, 0);
        assertGt(amountB, 0);
        assertEq(SimpleAMM(pair).balanceOf(user), 0);
    }

    function test_expiredDeadlineReverts() public {
        vm.prank(user);
        vm.expectRevert(AMMRouter.Expired.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB), 1 ether, 1 ether, 0, 0, user, block.timestamp - 1
        );
    }

    function test_factory_revertsOnDuplicatePair() public {
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(address(tokenB), address(tokenA));
    }
}
