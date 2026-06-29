// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title WETH9
/// @notice Minimal canonical wrapped-ether: deposit native ETH to mint 1:1 WETH,
///         withdraw to burn WETH and receive ETH back. Lets the AMM (which only
///         speaks ERC20) trade against native ETH via the router.
contract WETH9 is ERC20 {
    event Deposit(address indexed dst, uint256 amount);
    event Withdrawal(address indexed src, uint256 amount);

    error EthTransferFailed();

    constructor() ERC20("Wrapped Ether", "WETH") { }

    /// @notice Wrap the attached ETH into an equal amount of WETH.
    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Burn `amount` WETH and send the underlying ETH back to the caller.
    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert EthTransferFailed();
        emit Withdrawal(msg.sender, amount);
    }

    /// @notice Plain ETH transfers are treated as deposits.
    receive() external payable {
        deposit();
    }
}
