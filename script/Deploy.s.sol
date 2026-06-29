// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { AMMFactory } from "../src/AMMFactory.sol";
import { AMMRouter } from "../src/AMMRouter.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { WETH9 } from "../src/WETH9.sol";

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

        WETH9 weth = new WETH9();
        AMMFactory factory = new AMMFactory();
        AMMRouter router = new AMMRouter(address(factory), address(weth));

        MockERC20 tokenA = new MockERC20("Demo USD", "dUSD", 18);
        MockERC20 tokenB = new MockERC20("Demo DAI", "dDAI", 18);

        // Seed deployer balances and approve the router to pull them.
        tokenA.mint(deployer, 2 * SEED); // shared across the A/B and A/WETH pools
        tokenB.mint(deployer, SEED);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        uint256 deadline = block.timestamp + 1 hours;
        // Token/token pool (A/B) and a token/ETH pool (A/WETH) for native-ETH swaps.
        router.addLiquidity(address(tokenA), address(tokenB), SEED, SEED, 0, 0, deployer, deadline);
        // 0.1 ETH keeps the testnet deploy faucet-friendly; Anvil has plenty locally.
        router.addLiquidityETH{ value: 0.1 ether }(address(tokenA), SEED, 0, 0, deployer, deadline);

        vm.stopBroadcast();

        console2.log("Deployer:", deployer);
        console2.log("WETH:    ", address(weth));
        console2.log("Factory: ", address(factory));
        console2.log("Router:  ", address(router));
        console2.log("Token A (dUSD):", address(tokenA));
        console2.log("Token B (dDAI):", address(tokenB));
        console2.log("Pair A/B:   ", factory.getPair(address(tokenA), address(tokenB)));
        console2.log("Pair A/WETH:", factory.getPair(address(tokenA), address(weth)));
    }
}
