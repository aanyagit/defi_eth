// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { AMMFactory } from "../src/AMMFactory.sol";
import { AMMRouter } from "../src/AMMRouter.sol";
import { SimpleAMM } from "../src/SimpleAMM.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { WETH9 } from "../src/WETH9.sol";

/// @notice Covers the exact-output and native-ETH (WETH-wrapping) router helpers.
contract AMMRouterETHTest is Test {
    AMMFactory internal factory;
    AMMRouter internal router;
    WETH9 internal weth;
    MockERC20 internal token;
    MockERC20 internal tokenC;

    address internal user = makeAddr("user");
    uint256 internal constant MINT = 10_000_000 ether;
    uint256 internal deadline;

    function setUp() public {
        factory = new AMMFactory();
        weth = new WETH9();
        router = new AMMRouter(address(factory), address(weth));
        token = new MockERC20("Token", "TKN", 18);
        tokenC = new MockERC20("Token C", "TKC", 18);

        deadline = block.timestamp + 1 hours;

        token.mint(user, MINT);
        tokenC.mint(user, MINT);
        vm.deal(user, 1_000 ether);

        vm.startPrank(user);
        token.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        // Seed a token/WETH pool (1 token : 1 ETH) by adding ETH liquidity.
        router.addLiquidityETH{ value: 100 ether }(address(token), 100 ether, 0, 0, user, deadline);
        vm.stopPrank();
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    // --- Liquidity with ETH ------------------------------------------------

    function test_addLiquidityETH_createsWethPair() public view {
        address pair = factory.getPair(address(token), address(weth));
        assertTrue(pair != address(0));
        assertGt(SimpleAMM(pair).balanceOf(user), 0);
        assertEq(weth.balanceOf(pair), 100 ether);
    }

    function test_addLiquidityETH_refundsExcessEth() public {
        // Pool is 1:1. Deposit 10 token but 50 ETH -> only 10 ETH used, 40 refunded.
        uint256 balBefore = user.balance;
        vm.prank(user);
        (, uint256 amountETH,) = router.addLiquidityETH{ value: 50 ether }(
            address(token), 10 ether, 0, 0, user, deadline
        );
        assertEq(amountETH, 10 ether);
        assertEq(user.balance, balBefore - 10 ether);
    }

    function test_removeLiquidityETH_returnsEth() public {
        address pair = factory.getPair(address(token), address(weth));
        uint256 liquidity = SimpleAMM(pair).balanceOf(user);

        uint256 ethBefore = user.balance;
        vm.startPrank(user);
        SimpleAMM(pair).approve(address(router), liquidity);
        (uint256 amountToken, uint256 amountETH) =
            router.removeLiquidityETH(address(token), liquidity, 0, 0, user, deadline);
        vm.stopPrank();

        assertGt(amountToken, 0);
        assertGt(amountETH, 0);
        assertEq(user.balance, ethBefore + amountETH);
    }

    // --- ETH swaps ---------------------------------------------------------

    function test_swapExactETHForTokens() public {
        uint256[] memory expected =
            router.getAmountsOut(1 ether, _path(address(weth), address(token)));
        uint256 balBefore = token.balanceOf(user);

        vm.prank(user);
        router.swapExactETHForTokens{ value: 1 ether }(
            expected[1], _path(address(weth), address(token)), user, deadline
        );

        assertEq(token.balanceOf(user) - balBefore, expected[1]);
    }

    function test_swapExactTokensForETH() public {
        address[] memory path = _path(address(token), address(weth));
        uint256[] memory expected = router.getAmountsOut(1 ether, path);

        uint256 ethBefore = user.balance;
        vm.prank(user);
        router.swapExactTokensForETH(1 ether, expected[1], path, user, deadline);

        assertEq(user.balance - ethBefore, expected[1]);
    }

    function test_swapETHForExactTokens_refundsLeftoverEth() public {
        address[] memory path = _path(address(weth), address(token));
        uint256 amountOut = 5 ether;
        uint256 inNeeded = router.getAmountsIn(amountOut, path)[0];

        uint256 ethBefore = user.balance;
        uint256 tokBefore = token.balanceOf(user);
        vm.prank(user);
        router.swapETHForExactTokens{ value: 100 ether }(amountOut, path, user, deadline);

        // Spent exactly inNeeded ETH; got at least amountOut tokens.
        assertEq(user.balance, ethBefore - inNeeded);
        assertGe(token.balanceOf(user) - tokBefore, amountOut);
    }

    function test_swapTokensForExactETH() public {
        address[] memory path = _path(address(token), address(weth));
        uint256 amountOut = 5 ether;
        uint256 inMax = router.getAmountsIn(amountOut, path)[0];

        uint256 ethBefore = user.balance;
        vm.prank(user);
        router.swapTokensForExactETH(amountOut, inMax, path, user, deadline);

        assertEq(user.balance - ethBefore, amountOut);
    }

    // --- Exact-output token swap ------------------------------------------

    function test_swapTokensForExactTokens_multiHop() public {
        // Add a token/tokenC pool so token -> WETH -> ... no; build token->WETH->tokenC.
        vm.startPrank(user);
        router.addLiquidityETH{ value: 100 ether }(address(tokenC), 100 ether, 0, 0, user, deadline);
        vm.stopPrank();

        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = address(weth);
        path[2] = address(tokenC);

        uint256 amountOut = 1 ether;
        uint256[] memory amounts = router.getAmountsIn(amountOut, path);

        uint256 cBefore = tokenC.balanceOf(user);
        vm.prank(user);
        router.swapTokensForExactTokens(amountOut, amounts[0], path, user, deadline);

        assertGe(tokenC.balanceOf(user) - cBefore, amountOut);
    }

    function test_swapTokensForExactTokens_revertsOnExcessiveInput() public {
        address[] memory path = _path(address(token), address(weth));
        uint256 amountOut = 5 ether;
        uint256 inNeeded = router.getAmountsIn(amountOut, path)[0];

        vm.prank(user);
        vm.expectRevert(AMMRouter.ExcessiveInputAmount.selector);
        router.swapTokensForExactTokens(amountOut, inNeeded - 1, path, user, deadline);
    }

    function test_swapExactETHForTokens_revertsOnBadPath() public {
        // path[0] must be WETH.
        vm.prank(user);
        vm.expectRevert(AMMRouter.InvalidPath.selector);
        router.swapExactETHForTokens{ value: 1 ether }(
            0, _path(address(token), address(weth)), user, deadline
        );
    }
}
