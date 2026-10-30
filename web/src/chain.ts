import { createPublicClient, http } from "viem";
import type { Abi, Address, Chain, AbiEvent, Log } from "viem";
import { gameAbi, poolAbi, shapesAbi, packsAbi } from "./abi";
import { CHAIN_ID, RPC_URL, GAME_ADDRESS, MULTICALL3, DEPLOY_BLOCK, IS_LOCAL } from "./config";
import { ratio } from "./format";

export const chain = {
  id: CHAIN_ID,
  name: IS_LOCAL ? "Anvil fork" : "Ethereum",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  contracts: { multicall3: { address: MULTICALL3 } },
} as const satisfies Chain;

// batch.multicall aggregates the many concurrent reads below into one eth_call.
export const publicClient = createPublicClient({ chain, transport: http(RPC_URL), batch: { multicall: true } });

function rc<T = unknown>(address: Address, abi: Abi, functionName: string, args: unknown[] = []): Promise<T> {
  return publicClient.readContract({ address, abi, functionName, args }) as Promise<T>;
}
const g = <T = unknown>(fn: string, args: unknown[] = []) => rc<T>(GAME_ADDRESS, gameAbi, fn, args);

function eventItem(name: string): AbiEvent {
  const item = (poolAbi as AbiEvent[]).find((e) => (e as AbiEvent).type === "event" && (e as AbiEvent).name === name);
  if (!item) throw new Error(`event ${name} missing from pool ABI`);
  return item;
}

// Immutable addresses, fetched once.
let addrs: { pool: Address; shapes: Address; packs: Address } | null = null;
export async function addresses() {
  if (!addrs) {
    const [pool, shapes, packs] = await Promise.all([
      g<Address>("pool"),
      g<Address>("SHAPES"),
      g<Address>("PACKS"),
    ]);
    addrs = { pool, shapes, packs };
  }
  return addrs;
}

// --- shapes of multi-output views (viem returns these as positional arrays) ---
type FeaturedRaw = [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, number, number, number, number, bigint];
type TierRaw = { backing: bigint; packShapes: number; target: number; live: number; weight: bigint };
type ListingRaw = [Address, Address, Address, bigint, bigint, bigint, bigint, number];
type AcquisitionRaw = [Address, bigint, bigint, bigint, number];
type CycleResultRaw = { tokenId: bigint; winner: Address; backing: bigint; compositions: number; draws: number; startedBlock: bigint; endedBlock: bigint; requestId: bigint; costBasis: bigint };

export type Tier = { index: number; backing: bigint; packShapes: number; target: number; live: number; weight: bigint; isPack: boolean; chance: number };
export type Featured = {
  listed: boolean; // live and drawable: listing status Active or Staged
  active: boolean; // status Active (contributes selection weight / odds)
  won: boolean; // listingId set but listing no longer Active/Staged -> just won, awaiting keeper booking
  status: number; // pool listing status (0 when no listing)
  tokenId: bigint; listingId: bigint; costBasis: bigint; seedCost: bigint;
  backing: bigint; notional: bigint; resetNotional: bigint; decayPerDraw: bigint; floor: bigint;
  resetShareBps: number; compositions: number; draws: number; cycleDraws: number; startedBlock: bigint;
  weight: bigint;
};
export type GameState = {
  pool: Address; shapes: Address; packs: Address;
  paused: boolean; retired: boolean;
  cycle: bigint; cycleCount: bigint;
  growthFund: bigint; compositionCost: bigint; compositionDue: boolean; desiredNotional: bigint;
  liveOrdinary: bigint; totalWeight: bigint; inventoryVersion: bigint;
  featured: Featured; featuredChance: number;
  tiers: Tier[]; oddsExact: boolean;
  block: bigint;
};

export async function readGame(): Promise<GameState> {
  const { pool, shapes, packs } = await addresses();
  const p = <T = unknown>(fn: string, args: unknown[] = []) => rc<T>(pool, poolAbi, fn, args);

  const [
    featuredRaw, cycle, cycleCount, growthFund, compositionCost, compositionDue, desiredNotional,
    liveOrdinary, paused, retiredAt, tierCount, totalWeight, inventoryVersion, block,
  ] = await Promise.all([
    g<FeaturedRaw>("featured"),
    g<bigint>("cycle"),
    g<bigint>("cycleCount"),
    g<bigint>("growthFund"),
    g<bigint>("compositionCost"),
    g<boolean>("compositionDue"),
    g<bigint>("desiredNotional"),
    g<bigint>("liveOrdinary"),
    g<boolean>("paused"),
    g<bigint>("retiredAt"),
    g<bigint>("tierCount"),
    p<bigint>("totalWeight"),
    p<bigint>("inventoryVersion"),
    publicClient.getBlockNumber(),
  ]);

  const n = Number(tierCount);
  const tierRaws = await Promise.all(Array.from({ length: n }, (_, i) => g<TierRaw>("tier", [BigInt(i)])));

  const listingId = featuredRaw[1];
  // featured().listingId stays nonzero after a win until the keeper books the next
  // cycle. The live pool listing status is authoritative: only Active/Staged means
  // the featured is still up for grabs; anything else (Settled/DeliveryPending/...)
  // means it was just won. Only Active contributes selection weight / odds.
  const featuredListing = listingId > 0n ? await p<ListingRaw>("listings", [listingId]) : null;
  const fStatus = featuredListing ? featuredListing[7] : 0;
  const active = fStatus === 1;
  const listed = fStatus === 1 || fStatus === 5;
  const won = listingId > 0n && !listed;
  const featuredWeight = active && featuredListing ? featuredListing[4] : 0n;

  const featured: Featured = {
    listed, active, won, status: fStatus,
    tokenId: featuredRaw[0], listingId, costBasis: featuredRaw[2], seedCost: featuredRaw[3],
    backing: featuredRaw[4], notional: featuredRaw[5], resetNotional: featuredRaw[6],
    decayPerDraw: featuredRaw[7], floor: featuredRaw[8], resetShareBps: featuredRaw[9],
    compositions: featuredRaw[10], draws: featuredRaw[11], cycleDraws: featuredRaw[12], startedBlock: featuredRaw[13],
    weight: featuredWeight,
  };

  const tiers: Tier[] = tierRaws.map((t, i) => ({
    index: i, backing: t.backing, packShapes: t.packShapes, target: t.target, live: t.live, weight: t.weight,
    isPack: t.packShapes > 0, chance: ratio(t.weight, totalWeight),
  }));

  const sumWeight = tiers.reduce((a, t) => a + t.weight, 0n) + featuredWeight;
  return {
    pool, shapes, packs,
    paused, retired: retiredAt > 0n,
    cycle, cycleCount, growthFund, compositionCost, compositionDue, desiredNotional,
    liveOrdinary, totalWeight, inventoryVersion,
    featured, featuredChance: active ? ratio(featuredWeight, totalWeight) : 0,
    tiers, oddsExact: sumWeight === totalWeight,
    block,
  };
}

export async function canPurchase(wallet: Address): Promise<boolean> {
  return g<boolean>("canPurchase", [wallet]);
}

// --- Your draws / outcomes ---
// Acquisition status: 0 None,1 Pending,2 Fulfilled,3 Expired,4 Refunded,5 Ready,6 TimedOut,7 DeliveryPending,8 DeliveryRefunded
// Listing status:     0 None,1 Active,2 Allocated,3 Withdrawn,4 Settled,5 Staged,6 DeliveryPending,7 DeliveryRefunded
export type OutcomeKind = "pending" | "delivering" | "delivered" | "refunded" | "failed";
export type Outcome = {
  requestId: bigint;
  acqStatus: number;
  kind: OutcomeKind;
  listingId: bigint;
  collection?: Address;
  tokenId?: bigint;
  isPack?: boolean;
  blockNumber?: bigint;
};
export type OutcomesResult = { outcomes: Outcome[]; refundCredit: bigint };

export async function readOutcomes(purchaser: Address): Promise<OutcomesResult> {
  const { pool, packs } = await addresses();
  const p = <T = unknown>(fn: string, args: unknown[] = []) => rc<T>(pool, poolAbi, fn, args);

  const [requested, failed, refundCredit] = await Promise.all([
    publicClient.getLogs({ address: pool, event: eventItem("AcquisitionRequested"), args: { purchaser }, fromBlock: DEPLOY_BLOCK, toBlock: "latest" }),
    publicClient.getLogs({ address: pool, event: eventItem("NFTDeliveryFailed"), args: { recipient: purchaser }, fromBlock: DEPLOY_BLOCK, toBlock: "latest" }),
    p<bigint>("acquisitionRefundCredit", [purchaser]),
  ]);

  const failedListings = new Set<bigint>();
  for (const f of failed as Log[]) {
    const a = (f as unknown as { args: { listingId?: bigint } }).args;
    if (a?.listingId !== undefined) failedListings.add(a.listingId);
  }

  // newest first, de-duplicated
  const seen = new Set<string>();
  const reqs = (requested as Log[])
    .map((l) => ({ id: (l as unknown as { args: { requestId: bigint } }).args.requestId, blockNumber: l.blockNumber ?? undefined }))
    .filter((r) => (seen.has(r.id.toString()) ? false : seen.add(r.id.toString())))
    .reverse();

  const acqs = await Promise.all(reqs.map((r) => p<AcquisitionRaw>("acquisitions", [r.id])));
  const listingIds = acqs.map((a) => a[3]);
  const listings = await Promise.all(listingIds.map((id) => (id > 0n ? p<ListingRaw>("listings", [id]) : Promise.resolve(null))));

  const outcomes: Outcome[] = reqs.map((r, i) => {
    const acq = acqs[i];
    const acqStatus = acq[4];
    const listingId = acq[3];
    const listing = listings[i];
    let kind: OutcomeKind;
    if (acqStatus === 1) kind = "pending";
    else if (acqStatus === 3 || acqStatus === 4 || acqStatus === 6 || acqStatus === 8) kind = "refunded";
    else if (listing) {
      const lStatus = listing[7];
      if (listingId > 0n && (failedListings.has(listingId) || lStatus === 7)) kind = "failed";
      else if (lStatus === 4) kind = "delivered";
      else kind = "delivering"; // allocated / delivery pending
    } else kind = "delivering";

    const collection = listing ? listing[0] : undefined;
    const tokenId = listing ? listing[3] : undefined;
    return {
      requestId: r.id, acqStatus, kind, listingId,
      collection, tokenId,
      isPack: collection ? collection.toLowerCase() === packs.toLowerCase() : undefined,
      blockNumber: r.blockNumber,
    };
  });

  return { outcomes, refundCredit };
}

// --- History ---
export type CycleEntry = {
  index: number;
  tokenId: bigint; winner: Address; backing: bigint; compositions: number; draws: number;
  startedBlock: bigint; endedBlock: bigint; requestId: bigint; costBasis: bigint;
  txHash?: `0x${string}`;
};

export async function readHistory(): Promise<CycleEntry[]> {
  const count = await g<bigint>("cycleCount");
  const n = Number(count);
  if (n === 0) return [];
  const results = await Promise.all(Array.from({ length: n }, (_, i) => g<CycleResultRaw>("cycleResult", [BigInt(i)])));
  // Map cycle index -> winning tx via CycleWon logs (cycle is indexed, 1-based in the event).
  const won = await publicClient.getLogs({ address: GAME_ADDRESS, event: (gameAbi as AbiEvent[]).find((e) => e.type === "event" && e.name === "CycleWon")!, fromBlock: DEPLOY_BLOCK, toBlock: "latest" });
  const txByCycle = new Map<string, `0x${string}`>();
  for (const l of won as Log[]) {
    const a = (l as unknown as { args: { cycle: bigint } }).args;
    if (a?.cycle !== undefined && l.transactionHash) txByCycle.set(a.cycle.toString(), l.transactionHash);
  }
  return results.map((r, i) => ({
    index: i,
    tokenId: r.tokenId, winner: r.winner, backing: r.backing, compositions: r.compositions, draws: r.draws,
    startedBlock: r.startedBlock, endedBlock: r.endedBlock, requestId: r.requestId, costBasis: r.costBasis,
    // CycleWon cycle is 1-based (first completed cycle = 1); cycleResult index is 0-based.
    txHash: txByCycle.get(String(i + 1)),
  }));
}

// --- Art: decode an onchain tokenURI to its image data-URI. Cached per token. ---
const artCache = new Map<string, string | null>();

function b64ToStr(b64: string): string {
  const bin = atob(b64);
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

export async function fetchArt(collection: Address, tokenId: bigint, isPack = false): Promise<string | null> {
  const key = `${collection}:${tokenId}`;
  if (artCache.has(key)) return artCache.get(key)!;
  try {
    const uri = await rc<string>(collection, isPack ? packsAbi : shapesAbi, "tokenURI", [tokenId]);
    const image = extractImage(uri);
    artCache.set(key, image);
    return image;
  } catch {
    artCache.set(key, null);
    return null;
  }
}

function extractImage(uri: string): string | null {
  const json = decodeDataUriJson(uri);
  if (json && typeof json.image === "string") return json.image;
  return null;
}

function decodeDataUriJson(uri: string): { image?: string } | null {
  const m = /^data:application\/json(;[^,]*)?,(.*)$/s.exec(uri);
  if (!m) return null;
  const meta = m[1] ?? "";
  const payload = m[2];
  try {
    const text = meta.includes("base64") ? b64ToStr(payload) : decodeURIComponent(payload);
    return JSON.parse(text);
  } catch {
    try {
      return JSON.parse(payload);
    } catch {
      return null;
    }
  }
}
