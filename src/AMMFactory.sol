// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SimpleAMM } from "./SimpleAMM.sol";

/// @title AMMFactory
/// @notice Deploys and registers SimpleAMM pairs, one per unordered token pair.
/// @dev    Pairs are keyed by sorted (token0 < token1) addresses so lookups are
///         order-independent. Mirrors the Uniswap V2 factory registry.
contract AMMFactory {
    /// @dev getPair[tokenA][tokenB] == getPair[tokenB][tokenA] for any created pair.
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(
        address indexed token0, address indexed token1, address pair, uint256 pairCount
    );

    error IdenticalTokens();
    error ZeroAddress();
    error PairExists();

    /// @notice Deploy a new pool for `tokenA`/`tokenB`. Reverts if one already exists.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalTokens();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        pair = address(new SimpleAMM(token0, token1));

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}
