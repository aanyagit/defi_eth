// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Deploys two mock tokens + a SimpleAMM pool and seeds initial liquidity.
/// @dev    Run against local Anvil:
///         forge script script/Deploy.s.sol --rpc-url local --broadcast
contract Deploy is Script {
    uint256 internal constant SEED_A = 100_000 ether;
    uint256 internal constant SEED_B = 100_000 ether;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        MockERC20 tokenA = new MockERC20("Demo USD", "dUSD", 18);
        MockERC20 tokenB = new MockERC20("Demo ETH", "dETH", 18);
        SimpleAMM amm = new SimpleAMM(address(tokenA), address(tokenB));

        // Seed deployer balances and initial liquidity so the pool is tradeable.
        tokenA.mint(deployer, SEED_A);
        tokenB.mint(deployer, SEED_B);
        tokenA.approve(address(amm), SEED_A);
        tokenB.approve(address(amm), SEED_B);
        uint256 liquidity = amm.addLiquidity(SEED_A, SEED_B);

        vm.stopBroadcast();

        console2.log("Deployer:  ", deployer);
        console2.log("Token A:   ", address(tokenA));
        console2.log("Token B:   ", address(tokenB));
        console2.log("SimpleAMM: ", address(amm));
        console2.log("LP minted: ", liquidity);
    }
}
