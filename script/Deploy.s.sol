// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { AMMFactory } from "../src/AMMFactory.sol";
import { AMMRouter } from "../src/AMMRouter.sol";
import { MockERC20 } from "../src/MockERC20.sol";

/// @notice Deploys the full DEX stack — factory, router, three demo tokens — and seeds
///         two pools (A/B and B/C) so a multi-hop A->B->C swap works out of the box.
/// @dev    Run against local Anvil:
///         forge script script/Deploy.s.sol --rpc-url local --broadcast
contract Deploy is Script {
    uint256 internal constant SEED = 100_000 ether;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        AMMFactory factory = new AMMFactory();
        AMMRouter router = new AMMRouter(address(factory));

        MockERC20 tokenA = new MockERC20("Demo USD", "dUSD", 18);
        MockERC20 tokenB = new MockERC20("Demo ETH", "dETH", 18);
        MockERC20 tokenC = new MockERC20("Demo DAI", "dDAI", 18);

        // Seed deployer balances and approve the router to pull them.
        tokenA.mint(deployer, SEED);
        tokenB.mint(deployer, 2 * SEED); // shared across both pools
        tokenC.mint(deployer, SEED);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);

        uint256 deadline = block.timestamp + 1 hours;
        router.addLiquidity(address(tokenA), address(tokenB), SEED, SEED, 0, 0, deployer, deadline);
        router.addLiquidity(address(tokenB), address(tokenC), SEED, SEED, 0, 0, deployer, deadline);

        vm.stopBroadcast();

        console2.log("Deployer:", deployer);
        console2.log("Factory: ", address(factory));
        console2.log("Router:  ", address(router));
        console2.log("Token A (dUSD):", address(tokenA));
        console2.log("Token B (dETH):", address(tokenB));
        console2.log("Token C (dDAI):", address(tokenC));
        console2.log("Pair A/B:", factory.getPair(address(tokenA), address(tokenB)));
        console2.log("Pair B/C:", factory.getPair(address(tokenB), address(tokenC)));
    }
}
