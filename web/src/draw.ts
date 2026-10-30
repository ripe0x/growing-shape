import {
  encodeFunctionData, decodeFunctionResult, decodeEventLog,
  ContractFunctionRevertedError, BaseError,
} from "viem";
import type { Address, WalletClient, PublicClient } from "viem";
import { poolAbi } from "./abi";

const DEFAULT_SLIPPAGE_BPS = 1000n; // task default for maxNegativeSlippageBps
const QUOTE_GAS_HEADROOM = 2n; // quote VRF at 2x the gas price we send; overpayment is refunded
const DEADLINE_SECONDS = 600n;

export type DrawQuote = {
  count: number;
  fee: bigint; vrf: bigint; total: bigint;
  gasPriceSend: bigint; gpQuote: bigint;
  inventoryVersion: bigint;
  gasEstimate: bigint; gasCost: bigint;
};

// Measured player gas (fork): ~610k for 1 draw, ~1.66M for 5. Linear fallback
// used only when an on-chain estimate reverts (e.g. the gate is momentarily closed).
function measuredGas(count: number): bigint {
  return BigInt(347_500 + 262_500 * count);
}

export async function quoteDraw(pub: PublicClient, pool: Address, purchaser: Address, count: number): Promise<DrawQuote> {
  const [inventoryVersion, gasPriceSend] = await Promise.all([
    pub.readContract({ address: pool, abi: poolAbi, functionName: "inventoryVersion" }) as Promise<bigint>,
    pub.getGasPrice(),
  ]);
  const gpQuote = gasPriceSend * QUOTE_GAS_HEADROOM;
  // The VRF part of the quote depends on tx.gasprice, so eth_call at gpQuote.
  const raw = await pub.call({
    to: pool,
    data: encodeFunctionData({ abi: poolAbi, functionName: "quoteAcquisitionPrice", args: [BigInt(count)] }),
    gasPrice: gpQuote,
  });
  const [fee, vrf, total] = decodeFunctionResult({ abi: poolAbi, functionName: "quoteAcquisitionPrice", data: raw.data! }) as [bigint, bigint, bigint];

  let gasEstimate: bigint;
  try {
    const deadline = (await pub.getBlock()).timestamp + DEADLINE_SECONDS;
    gasEstimate = await pub.estimateContractGas({
      address: pool, abi: poolAbi, functionName: "acquireBatch",
      args: [purchaser, BigInt(count), fee, 0n, DEFAULT_SLIPPAGE_BPS, inventoryVersion, deadline],
      account: purchaser, value: total,
    });
  } catch {
    gasEstimate = measuredGas(count);
  }
  return { count, fee, vrf, total, gasPriceSend, gpQuote, inventoryVersion, gasEstimate, gasCost: gasEstimate * gasPriceSend };
}

export class DrawError extends Error {
  retryable: boolean;
  constructor(message: string, retryable = false) {
    super(message);
    this.retryable = retryable;
  }
}

export type DrawResult = { hash: `0x${string}`; requestIds: bigint[]; quote: DrawQuote };

export async function sendDraw(
  pub: PublicClient, wallet: WalletClient, pool: Address, purchaser: Address, count: number, isLocal: boolean,
): Promise<DrawResult> {
  const quote = await quoteDraw(pub, pool, purchaser, count);
  const deadline = (await pub.getBlock()).timestamp + DEADLINE_SECONDS;
  const args = [purchaser, BigInt(count), quote.fee, 0n, DEFAULT_SLIPPAGE_BPS, quote.inventoryVersion, deadline] as const;

  // Always simulate before opening the wallet; translate the revert for humans.
  try {
    await pub.simulateContract({ address: pool, abi: poolAbi, functionName: "acquireBatch", args, account: purchaser, value: quote.total });
  } catch (err) {
    throw translateError(err);
  }

  let hash: `0x${string}`;
  try {
    hash = await wallet.writeContract({
      chain: wallet.chain ?? null,
      account: purchaser,
      address: pool, abi: poolAbi, functionName: "acquireBatch", args: [...args],
      value: quote.total,
      // FWA charges VRF at tx.gasprice, and we paid for it at gpQuote. Cap the fee at gpQuote so the
      // transaction can never pay a higher gas price than the VRF portion covers (InsufficientPayment).
      // Local unlocked accounts use a legacy gas price at the current level.
      ...(isLocal ? { gasPrice: quote.gasPriceSend } : { maxFeePerGas: quote.gpQuote }),
    });
  } catch (err) {
    throw translateError(err);
  }

  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new DrawError("The draw transaction reverted on-chain.");

  const requestIds: bigint[] = [];
  for (const log of receipt.logs) {
    try {
      const ev = decodeEventLog({ abi: poolAbi, data: log.data, topics: log.topics });
      if (ev.eventName === "AcquisitionRequested") {
        const a = ev.args as unknown as { requestId: bigint; purchaser: Address };
        if (a.purchaser.toLowerCase() === purchaser.toLowerCase()) requestIds.push(a.requestId);
      }
    } catch {
      /* non-matching log */
    }
  }
  return { hash, requestIds, quote };
}

// Simple pool write (refund withdrawal, delivery retry/refund): simulate for a
// clean pre-flight error, then send. These calls don't depend on tx.gasprice.
export async function sendWrite(
  pub: PublicClient, wallet: WalletClient, address: Address, abi: typeof poolAbi, functionName: string, args: unknown[], account: Address,
): Promise<`0x${string}`> {
  try {
    const { request } = await pub.simulateContract({ address, abi, functionName, args, account });
    const hash = await wallet.writeContract(request as Parameters<WalletClient["writeContract"]>[0]);
    await pub.waitForTransactionReceipt({ hash });
    return hash;
  } catch (e) {
    throw translateError(e);
  }
}

const ERROR_TEXT: Record<string, { msg: string; retryable?: boolean }> = {
  PurchaseNotAllowed: { msg: "Draws are closed right now — the game may be paused, composing the featured Shape, or catching up on maintenance. Try again shortly." },
  InventoryVersionMismatch: { msg: "The prize pool just changed. Re-quoting and retrying…", retryable: true },
  InventoryChangeCooldownActive: { msg: "The prize pool was just restocked; FWA reopens draws in a few minutes.", retryable: true },
  AcquisitionFeeTooHigh: { msg: "The acquisition fee moved above the quoted limit. Try again.", retryable: true },
  InsufficientPayment: { msg: "Payment fell short because the gas price moved. Try again.", retryable: true },
  TransactionExpired: { msg: "The quote expired before the transaction was mined. Try again.", retryable: true },
  FactoryPurchasesDisabled: { msg: "Purchases are disabled at the factory level. Try again later." },
  VrfRequestsPaused: { msg: "Randomness requests are paused. Try again later." },
  NoActiveListings: { msg: "No prizes are currently listed. Try again shortly.", retryable: true },
};

export function translateError(err: unknown): DrawError {
  if (err instanceof BaseError) {
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name && ERROR_TEXT[name]) return new DrawError(ERROR_TEXT[name].msg, ERROR_TEXT[name].retryable);
    // user rejection
    const msg = (err as BaseError).shortMessage ?? err.message;
    if (/user rejected|denied|rejected the request/i.test(msg)) return new DrawError("You rejected the transaction.");
    if (name) return new DrawError(`Transaction reverted: ${name}.`);
    return new DrawError(msg);
  }
  return new DrawError(err instanceof Error ? err.message : "Unknown error.");
}
