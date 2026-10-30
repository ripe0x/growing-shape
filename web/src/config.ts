// All runtime config comes from Vite env vars (see .env.example). Read once here.
import type { Address } from "viem";

const env = import.meta.env;

export const CHAIN_ID = Number(env.VITE_CHAIN_ID ?? 1);
export const RPC_URL = (env.VITE_RPC_URL as string) ?? "https://mainnet.gateway.tenderly.co";
export const GAME_ADDRESS = (env.VITE_GAME_ADDRESS as string) as Address;
export const DEPLOY_BLOCK = BigInt(env.VITE_DEPLOY_BLOCK ?? 0);
export const WALLETCONNECT_PROJECT_ID = (env.VITE_WALLETCONNECT_PROJECT_ID as string) || "";

// Local anvil fork: unlocked accounts, so we can send via node accounts without a signer.
export const IS_LOCAL = CHAIN_ID === 31337;

// Multicall3 is deployed at the same address on mainnet and on the fork.
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as Address;

export const POLL_MS = 12_000;

// Block explorer for tx links; only mainnet has one we can rely on.
export const EXPLORER_TX = CHAIN_ID === 1 ? "https://etherscan.io/tx/" : "";

// Standard anvil dev accounts offered in local mode (private keys are the public anvil defaults).
export const LOCAL_ACCOUNTS: Address[] = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
];

if (!GAME_ADDRESS) {
  // Surface misconfiguration early rather than failing deep in a read.
  console.error("VITE_GAME_ADDRESS is not set; copy web/.env.example to web/.env and fill it in.");
}
