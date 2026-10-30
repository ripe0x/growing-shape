import { formatEther } from "viem";

// ETH with trimmed trailing zeros, capped to `dp` significant decimals.
export function eth(wei: bigint, dp = 4): string {
  const s = formatEther(wei);
  const [int, frac = ""] = s.split(".");
  if (!frac) return int;
  const trimmed = frac.slice(0, dp).replace(/0+$/, "");
  return trimmed ? `${int}.${trimmed}` : int;
}

export function ethUnit(wei: bigint, dp = 4): string {
  return `${eth(wei, dp)} ETH`;
}

// Probability in [0,1] -> readable percent. Tiny chances keep more precision.
export function pct(p: number): string {
  if (!isFinite(p) || p <= 0) return "0%";
  if (p < 0.0001) return "<0.01%";
  if (p < 0.01) return `${(p * 100).toFixed(3)}%`;
  if (p < 0.1) return `${(p * 100).toFixed(2)}%`;
  return `${(p * 100).toFixed(1)}%`;
}

// weightA / weightB as a float ratio, guarding divide-by-zero.
export function ratio(a: bigint, b: bigint): number {
  if (b === 0n) return 0;
  // scale to keep precision for very small ratios
  return Number((a * 1_000_000_000n) / b) / 1_000_000_000;
}

export function shortAddr(a?: string): string {
  if (!a) return "";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
