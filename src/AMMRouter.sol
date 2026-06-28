// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AMMFactory } from "./AMMFactory.sol";
import { SimpleAMM } from "./SimpleAMM.sol";

/// @title AMMRouter
/// @notice User-facing entry point for the DEX: ratio-balanced liquidity provision
///         with slippage guards, and multi-hop exact-input swaps across pools.
/// @dev    Stateless aside from its factory reference. Holds no funds between calls —
///         tokens are pulled, routed through pairs, and forwarded to the recipient in
///         the same transaction. The caller must approve this router for the input
///         token(s) (and the LP token, for removeLiquidity) beforehand.
contract AMMRouter {
    using SafeERC20 for IERC20;

    AMMFactory public immutable factory;

    error Expired();
    error InvalidPath();
    error PairNotFound();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();

    /// @dev Reverts the transaction if the user-supplied deadline has passed.
    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(address factory_) {
        factory = AMMFactory(factory_);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @notice Add liquidity to `tokenA`/`tokenB`, creating the pair if it doesn't exist.
    /// @dev    On an existing pool the deposit is balanced to the current reserve ratio;
    ///         the side that would exceed its `*Min` floor reverts (slippage protection).
    ///         LP tokens are minted to `to`.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) pair = factory.createPair(tokenA, tokenB);

        (amountA, amountB) = _balanceAmounts(
            pair, tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin
        );

        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);
        IERC20(tokenA).forceApprove(pair, amountA);
        IERC20(tokenB).forceApprove(pair, amountB);

        // SimpleAMM.addLiquidity takes amounts positionally by sorted (token0,token1).
        (uint256 amount0, uint256 amount1) =
            tokenA < tokenB ? (amountA, amountB) : (amountB, amountA);
        liquidity = SimpleAMM(pair).addLiquidity(amount0, amount1);

        // Pair mints LP to this router; forward to the requested recipient.
        IERC20(pair).safeTransfer(to, liquidity);
    }

    /// @notice Burn LP tokens and withdraw the underlying, with per-token minimum guards.
    /// @dev    Caller must approve this router for `liquidity` LP tokens.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();

        IERC20(pair).safeTransferFrom(msg.sender, address(this), liquidity);
        (uint256 amount0, uint256 amount1) = SimpleAMM(pair).removeLiquidity(liquidity);

        (amountA, amountB) = tokenA < tokenB ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();

        // Pair sent the underlying to this router; forward to the recipient.
        IERC20(tokenA).safeTransfer(to, amountA);
        IERC20(tokenB).safeTransfer(to, amountB);
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    /// @notice Swap an exact `amountIn` of `path[0]` for `path[last]`, hopping through
    ///         each intermediate pair, reverting if the final output < `amountOutMin`.
    /// @param  path  Ordered token addresses; a pair must exist for each adjacent pair.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();

        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amounts[0]);

        for (uint256 i; i < path.length - 1; ++i) {
            address pair = factory.getPair(path[i], path[i + 1]);
            if (pair == address(0)) revert PairNotFound();
            // Final hop pays out to the recipient; intermediate hops stay in the router.
            address recipient = i < path.length - 2 ? address(this) : to;
            IERC20(path[i]).forceApprove(pair, amounts[i]);
            SimpleAMM(pair).swap(path[i], amounts[i], amounts[i + 1], recipient);
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Cascade `getAmountOut` across `path`, returning the amount at each hop.
    /// @return amounts amounts[0] == amountIn; amounts[last] is the final output.
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        public
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; ++i) {
            address pair = factory.getPair(path[i], path[i + 1]);
            if (pair == address(0)) revert PairNotFound();
            (uint256 reserveIn, uint256 reserveOut) = _reservesFor(pair, path[i], path[i + 1]);
            amounts[i + 1] = SimpleAMM(pair).getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Reserves of a pair oriented as (tokenA-side, tokenB-side).
    function _reservesFor(address pair, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (uint256 reserve0, uint256 reserve1) = SimpleAMM(pair).getReserves();
        (reserveA, reserveB) = tokenA < tokenB ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @dev Compute the deposit amounts that respect the current reserve ratio. For an
    ///      empty pool the desired amounts set the initial price; otherwise one side is
    ///      scaled down to match, and must clear its `*Min` slippage floor.
    function _balanceAmounts(
        address pair,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = _reservesFor(pair, tokenA, tokenB);

        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            if (amountBOptimal < amountBMin) revert InsufficientBAmount();
            return (amountADesired, amountBOptimal);
        }

        uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
        // amountAOptimal <= amountADesired holds by construction when the branch above failed.
        if (amountAOptimal < amountAMin) revert InsufficientAAmount();
        return (amountAOptimal, amountBDesired);
    }
}
