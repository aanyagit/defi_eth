// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AMMFactory } from "./AMMFactory.sol";
import { SimpleAMM } from "./SimpleAMM.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title AMMRouter
/// @notice User-facing entry point for the DEX: ratio-balanced liquidity provision
///         with slippage guards, multi-hop swaps (exact-input and exact-output), and
///         native-ETH variants that wrap/unwrap through WETH.
/// @dev    Stateless aside from its factory/WETH references. Holds no funds between
///         calls — tokens are pulled, routed through pairs, and forwarded to the
///         recipient in the same transaction. The caller must approve this router for
///         the input token(s) (and the LP token, for removeLiquidity) beforehand.
///
///         Exact-output note: the underlying pools price by exact input, so an
///         exact-output swap delivers *at least* the requested output (any rounding
///         surplus is negligible dust retained by the router), while never spending
///         more than `amountInMax`.
contract AMMRouter {
    using SafeERC20 for IERC20;

    AMMFactory public immutable factory;
    address public immutable WETH;

    error Expired();
    error InvalidPath();
    error PairNotFound();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();
    error ExcessiveInputAmount();
    error OnlyWETH();
    error EthTransferFailed();

    /// @dev Reverts the transaction if the user-supplied deadline has passed.
    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(address factory_, address weth_) {
        factory = AMMFactory(factory_);
        WETH = weth_;
    }

    /// @dev Only accept ETH from the WETH contract (during withdraw).
    receive() external payable {
        if (msg.sender != WETH) revert OnlyWETH();
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @notice Add liquidity to `tokenA`/`tokenB`, creating the pair if it doesn't exist.
    /// @dev    On an existing pool the deposit is balanced to the current reserve ratio;
    ///         the side that would fall below its `*Min` floor reverts (slippage guard).
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
        liquidity = _deposit(pair, tokenA, tokenB, amountA, amountB, to);
    }

    /// @notice Add liquidity to a `token`/ETH pool, wrapping the attached ETH to WETH.
    /// @dev    Unused ETH (when the pool ratio needs less than `msg.value`) is refunded.
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        address pair = factory.getPair(token, WETH);
        if (pair == address(0)) pair = factory.createPair(token, WETH);

        (amountToken, amountETH) = _balanceAmounts(
            pair, token, WETH, amountTokenDesired, msg.value, amountTokenMin, amountETHMin
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);
        IWETH(WETH).deposit{ value: amountETH }();
        liquidity = _deposit(pair, token, WETH, amountToken, amountETH, to);

        if (msg.value > amountETH) _safeTransferETH(msg.sender, msg.value - amountETH);
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
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();

        IERC20(pair).safeTransferFrom(msg.sender, address(this), liquidity);
        (uint256 amount0, uint256 amount1) = SimpleAMM(pair).removeLiquidity(liquidity);

        (amountA, amountB) = tokenA < tokenB ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();

        IERC20(tokenA).safeTransfer(to, amountA);
        IERC20(tokenB).safeTransfer(to, amountB);
    }

    /// @notice Burn LP tokens of a `token`/ETH pool; the WETH side is unwrapped to ETH.
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        // Withdraw to the router, then split: token to `to`, unwrapped ETH to `to`.
        (uint256 amountA, uint256 amountB) = removeLiquidity(
            token, WETH, liquidity, amountTokenMin, amountETHMin, address(this), deadline
        );
        (amountToken, amountETH) = (amountA, amountB);

        IERC20(token).safeTransfer(to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    // ---------------------------------------------------------------------
    // Swaps — token <-> token
    // ---------------------------------------------------------------------

    /// @notice Swap an exact `amountIn` of `path[0]` for `path[last]`, hopping through
    ///         each intermediate pair, reverting if the final output < `amountOutMin`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Receive an exact `amountOut` of `path[last]`, spending at most `amountInMax`
    ///         of `path[0]`.
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsIn(amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amounts[0]);
        _swap(amounts, path, to);
    }

    // ---------------------------------------------------------------------
    // Swaps — ETH variants (path endpoint must be WETH)
    // ---------------------------------------------------------------------

    /// @notice Swap exact attached ETH for `path[last]`. `path[0]` must be WETH.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256[] memory amounts) {
        if (path[0] != WETH) revert InvalidPath();
        amounts = getAmountsOut(msg.value, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
        IWETH(WETH).deposit{ value: amounts[0] }();
        _swap(amounts, path, to);
    }

    /// @notice Swap an exact `amountIn` of `path[0]` for ETH. `path[last]` must be WETH.
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (path[path.length - 1] != WETH) revert InvalidPath();
        amounts = getAmountsOut(amountIn, path);
        uint256 out = amounts[amounts.length - 1];
        if (out < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(out);
        _safeTransferETH(to, out);
    }

    /// @notice Receive an exact `amountOut` of ETH, spending at most `amountInMax` of
    ///         `path[0]`. `path[last]` must be WETH.
    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (path[path.length - 1] != WETH) revert InvalidPath();
        amounts = getAmountsIn(amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amountOut);
        _safeTransferETH(to, amountOut);
    }

    /// @notice Receive an exact `amountOut` of `path[last]`, paying with attached ETH and
    ///         refunding the remainder. `path[0]` must be WETH.
    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256[] memory amounts) {
        if (path[0] != WETH) revert InvalidPath();
        amounts = getAmountsIn(amountOut, path);
        if (amounts[0] > msg.value) revert ExcessiveInputAmount();
        IWETH(WETH).deposit{ value: amounts[0] }();
        _swap(amounts, path, to);
        if (msg.value > amounts[0]) _safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Cascade `getAmountOut` forward across `path`.
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
            (uint256 reserveIn, uint256 reserveOut) = _reservesFor(path[i], path[i + 1]);
            amounts[i + 1] = SimpleAMM(_pairFor(path[i], path[i + 1])).getAmountOut(
                amounts[i], reserveIn, reserveOut
            );
        }
    }

    /// @notice Cascade `getAmountIn` backward across `path`.
    /// @return amounts amounts[last] == amountOut; amounts[0] is the required input.
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        public
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; --i) {
            (uint256 reserveIn, uint256 reserveOut) = _reservesFor(path[i - 1], path[i]);
            amounts[i - 1] = SimpleAMM(_pairFor(path[i - 1], path[i])).getAmountIn(
                amounts[i], reserveIn, reserveOut
            );
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Approve + deposit balanced amounts into a pair and forward the LP to `to`.
    function _deposit(
        address pair,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address to
    ) private returns (uint256 liquidity) {
        IERC20(tokenA).forceApprove(pair, amountA);
        IERC20(tokenB).forceApprove(pair, amountB);
        // SimpleAMM.addLiquidity takes amounts positionally by sorted (token0,token1).
        (uint256 amount0, uint256 amount1) =
            tokenA < tokenB ? (amountA, amountB) : (amountB, amountA);
        liquidity = SimpleAMM(pair).addLiquidity(amount0, amount1);
        IERC20(pair).safeTransfer(to, liquidity);
    }

    /// @dev Execute a multi-hop swap given pre-computed `amounts`; final hop pays `_to`.
    function _swap(uint256[] memory amounts, address[] calldata path, address _to) private {
        for (uint256 i; i < path.length - 1; ++i) {
            address pair = _pairFor(path[i], path[i + 1]);
            address recipient = i < path.length - 2 ? address(this) : _to;
            IERC20(path[i]).forceApprove(pair, amounts[i]);
            SimpleAMM(pair).swap(path[i], amounts[i], amounts[i + 1], recipient);
        }
    }

    function _pairFor(address tokenA, address tokenB) private view returns (address pair) {
        pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();
    }

    /// @dev Reserves of a pair oriented as (tokenA-side, tokenB-side).
    function _reservesFor(address tokenA, address tokenB)
        private
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (uint256 reserve0, uint256 reserve1) = SimpleAMM(_pairFor(tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA < tokenB ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @dev Compute deposit amounts that respect the current reserve ratio. For an empty
    ///      pool the desired amounts set the initial price; otherwise one side is scaled
    ///      down to match and must clear its `*Min` slippage floor.
    function _balanceAmounts(
        address pair,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) private view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = _reservesForPair(pair, tokenA, tokenB);

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

    /// @dev Reserves for an already-resolved pair, oriented as (tokenA-side, tokenB-side).
    function _reservesForPair(address pair, address tokenA, address tokenB)
        private
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (uint256 reserve0, uint256 reserve1) = SimpleAMM(pair).getReserves();
        (reserveA, reserveB) = tokenA < tokenB ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function _safeTransferETH(address to, uint256 amount) private {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert EthTransferFailed();
    }
}
