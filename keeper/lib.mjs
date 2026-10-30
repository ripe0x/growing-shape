// Pure decision logic for the keeper, kept free of RPC so it can be unit-tested.

export const ACQ = { None: 0, Pending: 1, Fulfilled: 2, Expired: 3, Refunded: 4, Ready: 5, TimedOut: 6, DeliveryPending: 7, DeliveryRefunded: 8 };
export const VRF_STORED = new Set([2, 3]); // service RequestStatus WordStored, EmptyWordArrayStored
const BPS = 10_000n;

/**
 * Jobs worth sending now, in priority order. `s` is a snapshot read by `readState`.
 * Each job names a contract call; the caller simulates it before sending.
 */
export function dueJobs(s) {
  const jobs = [];
  for (const id of s.storedUndelivered) jobs.push({ name: 'deliverRandomness', target: 'service', fn: 'deliverRandomness', args: [id] });

  const headProcessable =
    s.head !== null &&
    (s.head.status === ACQ.Ready || s.head.status === ACQ.TimedOut || (s.head.status === ACQ.Pending && s.block > s.head.deadline));
  if (headProcessable || s.processed > s.booked || s.ownerProceeds > 0n) {
    jobs.push({ name: 'book', target: 'game', fn: 'book', args: [s.bookBatch] });
  }

  const idle = s.unsettled === 0n && s.processed === s.booked && !headProcessable;
  if (!s.retired && s.replacementDue > 0n && s.operating >= s.cheapestTierCost) {
    jobs.push({ name: 'replenish', target: 'game', fn: 'replenish', args: [20n] });
  }
  if (!s.retired && s.featured.listingId === 0n && s.operating >= s.seedCost + s.replacementDue) {
    jobs.push({ name: 'startCycle', target: 'game', fn: 'startCycle', args: [] });
  }
  if (s.compositionDue && idle) jobs.push({ name: 'compose', target: 'game', fn: 'compose', args: [] });
  if (s.featured.listingId !== 0n && idle && decayDue(s)) {
    jobs.push({ name: 'publishDecay', target: 'game', fn: 'publishDecay', args: [] });
  }
  return jobs;
}

/** Mirrors `GrowingShape.publishDecay`'s step rule. */
export function decayDue(s) {
  const { desired, notional, floor } = s.featured;
  if (desired >= notional) return false;
  return desired === floor || desired * BPS <= notional * (BPS - BigInt(s.repriceStepBps));
}

/**
 * The game's reimbursement for a call using `gas`: measured gas at
 * min(gasPrice, basefee + priorityCap, gasPriceCap), plus the flat reward when its interval has
 * passed, capped by the keeper budget and operating ETH. Mirrors `_payKeeper`.
 */
export function expectedReward({ gas, gasPrice, baseFee, now, keeper, keeperBudget, operating, lastFlatRewardAt }) {
  let price = gasPrice;
  let cap = baseFee + keeper.priorityCap;
  if (cap > keeper.gasPriceCap) cap = keeper.gasPriceCap;
  if (price > cap) price = cap;
  let amount = (gas + keeper.gasOverhead) * price;
  if (keeper.flatReward !== 0n && now >= lastFlatRewardAt + keeper.flatInterval) amount += keeper.flatReward;
  let limit = keeperBudget < operating ? keeperBudget : operating;
  return amount > limit ? limit : amount;
}
