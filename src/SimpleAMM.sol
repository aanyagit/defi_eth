// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SimpleAMM
/// @notice A constant-product (x*y=k) automated market maker for a single token pair,
///         in the style of Uniswap V2. The contract is itself the LP (ERC20) token.
/// @dev    Charges a 0.3% swap fee that accrues to liquidity providers. Reserves are
///         tracked internally and synced from balances, so fee-on-transfer or rebasing
///         tokens are NOT supported. Intended as a hackathon-grade primitive.
contract SimpleAMM is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Permanently locked liquidity minted on the first deposit. Prevents the
    ///      pool from being fully drained and the price-per-share being inflated.
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    /// @dev Fee numerator/denominator: amountIn is taxed 0.3% (997/1000 reaches the curve).
    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1_000;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    event LiquidityAdded(
        address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity
    );
    event LiquidityRemoved(
        address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity
    );
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to
    );

    error IdenticalTokens();
    error ZeroAddress();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InvalidToken();
    error InsufficientLiquidity();

    constructor(address tokenA, address tokenB) ERC20("SimpleAMM LP", "SAMM-LP") {
        if (tokenA == tokenB) revert IdenticalTokens();
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        // Order tokens deterministically so token0/token1 are stable regardless of input order.
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        token0 = IERC20(t0);
        token1 = IERC20(t1);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @notice Deposit `amount0Desired`/`amount1Desired` of token0/token1 and mint LP shares.
    /// @dev    On a non-empty pool, deposits must match the current reserve ratio; the excess
    ///         of one side is implicitly ignored by the min() share calculation, so callers
    ///         should pre-compute balanced amounts (see `quote`). Caller must approve first.
    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired)
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        if (amount0Desired == 0 || amount1Desired == 0) revert InsufficientInputAmount();

        token0.safeTransferFrom(msg.sender, address(this), amount0Desired);
        token1.safeTransferFrom(msg.sender, address(this), amount1Desired);

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0Desired * amount1Desired) - MINIMUM_LIQUIDITY;
            // Lock the minimum liquidity forever by minting it to address(1) (address(0) is
            // disallowed by ERC20._mint).
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(
                (amount0Desired * _totalSupply) / reserve0,
                (amount1Desired * _totalSupply) / reserve1
            );
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(msg.sender, liquidity);
        _sync();

        emit LiquidityAdded(msg.sender, amount0Desired, amount1Desired, liquidity);
    }

    /// @notice Burn `liquidity` LP shares and withdraw the proportional underlying reserves.
    function removeLiquidity(uint256 liquidity)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) revert InsufficientLiquidityBurned();

        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * reserve0) / _totalSupply;
        amount1 = (liquidity * reserve1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(msg.sender, liquidity);

        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);
        _sync();

        emit LiquidityRemoved(msg.sender, amount0, amount1, liquidity);
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    /// @notice Swap an exact `amountIn` of `tokenIn` for as much of the other token as
    ///         the curve allows, reverting if output is below `minAmountOut`.
    /// @param  tokenIn  Address of the input token (must be token0 or token1).
    /// @param  to       Recipient of the output tokens.
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (to == address(0)) revert ZeroAddress();

        bool zeroForOne = tokenIn == address(token0);
        if (!zeroForOne && tokenIn != address(token1)) revert InvalidToken();

        (IERC20 input, IERC20 output, uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (token0, token1, reserve0, reserve1) : (token1, token0, reserve1, reserve0);

        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut < minAmountOut) revert InsufficientOutputAmount();

        input.safeTransferFrom(msg.sender, address(this), amountIn);
        output.safeTransfer(to, amountOut);
        _sync();

        emit Swap(msg.sender, tokenIn, amountIn, amountOut, to);
    }

    // ---------------------------------------------------------------------
    // Views / pricing
    // ---------------------------------------------------------------------

    /// @notice Constant-product output for a given input, net of the 0.3% fee.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee;
        return numerator / denominator;
    }

    /// @notice Given an amount of one asset, the equal-value amount of the other at
    ///         the current reserve ratio (no fee) — useful for balanced deposits.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external
        pure
        returns (uint256)
    {
        if (amountA == 0) revert InsufficientInputAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        return (amountA * reserveB) / reserveA;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Sync cached reserves to actual balances after any state-changing action.
    function _sync() private {
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));
    }
}
