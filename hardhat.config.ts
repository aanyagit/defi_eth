import "dotenv/config";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
// hardhat-foundry makes Hardhat read foundry.toml + remappings.txt, so contracts
// in src/ and the lib/ dependencies are shared across both toolchains.
import "@nomicfoundation/hardhat-foundry";

const PRIVATE_KEY = process.env.PRIVATE_KEY;
const accounts = PRIVATE_KEY ? [PRIVATE_KEY] : [];

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
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL ?? "",
      chainId: 11155111,
      accounts,
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL ?? "",
      chainId: 84532,
      accounts,
    },
  },
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY ?? "",
      baseSepolia: process.env.BASESCAN_API_KEY ?? "",
    },
    customChains: [
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
    ],
  },
};

export default config;
