// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockERC20
/// @notice A freely-mintable ERC20 for local development, testing, and demos.
/// @dev DO NOT deploy to mainnet — the owner can mint unlimited supply.
contract MockERC20 is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint tokens to any address. Open to owner for seeding test liquidity.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Anyone can grab test tokens from the faucet (local/testnet convenience).
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}
