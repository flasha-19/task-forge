import { defineChain, isAddress, type Address } from "viem";

export const arcTestnet = defineChain({
  id: 5042002,
  name: "Arc Testnet",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.arc.network"] } },
  blockExplorers: { default: { name: "ArcScan", url: "https://testnet.arcscan.app" } },
  testnet: true,
});

export const FAUCET_URL = "https://faucet.circle.com";
export const EXPLORER = arcTestnet.blockExplorers.default.url;
export const USDC_DECIMALS = 6;

const env = import.meta.env;
const clean = (v: unknown): Address | undefined =>
  typeof v === "string" && isAddress(v) ? (v as Address) : undefined;

export const TASKFORGE_ADDRESS = clean(env.VITE_TASKFORGE_ADDRESS);
// Official Arc Testnet USDC ERC-20 interface (6 decimals), per docs.arc.io.
export const USDC_ADDRESS: Address =
  clean(env.VITE_USDC_ADDRESS) ?? "0x3600000000000000000000000000000000000000";
export const DEPLOY_BLOCK = BigInt(Number(env.VITE_DEPLOY_BLOCK ?? 0) || 0);

export const txUrl = (hash: string) => `${EXPLORER}/tx/${hash}`;
export const addrUrl = (a: string) => `${EXPLORER}/address/${a}`;
