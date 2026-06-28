import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
// hardhat-foundry makes Hardhat read foundry.toml + remappings.txt, so contracts
// in src/ and the lib/ dependencies are shared across both toolchains.
import "@nomicfoundation/hardhat-foundry";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true, // router functions exceed the stack limit without the IR pipeline
      evmVersion: "cancun",
    },
  },
  paths: {
    sources: "./src",
    tests: "./test-hardhat", // keep TS tests separate from Foundry's .t.sol files
    cache: "./cache_hardhat",
    artifacts: "./artifacts",
  },
  networks: {
    // `anvil` (or `hardhat node`) listening on the default port.
    localhost: {
      url: process.env.LOCAL_RPC_URL ?? "http://127.0.0.1:8545",
    },
    // Add testnets here when you deploy beyond local, e.g.:
    // sepolia: {
    //   url: process.env.SEPOLIA_RPC_URL ?? "",
    //   accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    // },
  },
};

export default config;
