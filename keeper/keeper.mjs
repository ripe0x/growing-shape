// Growing Shape keeper. Finds maintenance the game needs, simulates each call, and sends it only when the
// simulation succeeds and the game's reimbursement covers the gas (unless KEEPER_ALTRUISTIC=1). It holds
// no privilege: every call it makes is permissionless.
//
// Env: RPC_URL, GAME, KEEPER_PRIVATE_KEY (read from the environment only; never logged or written), or
// KEEPER_UNLOCKED=<address> on a chain-31337 fork. Optional: INTERVAL_MS (15000), MAX_GAS_PRICE_GWEI (50),
// KEEPER_ALTRUISTIC (0), DRY_RUN (0), BOOK_BATCH (50), ONCE (0).
import { readFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, http, formatEther, formatGwei, parseGwei } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { gameAbi, poolAbi, serviceAbi, shapesAbi, ADDR } from './abi.mjs';
import { dueJobs, expectedReward, ACQ, VRF_STORED } from './lib.mjs';

const env = process.env;
const RPC = env.RPC_URL ?? 'https://mainnet.gateway.tenderly.co';
const GAME = env.GAME ?? JSON.parse(readFileSync(new URL('../deployments/31337.json', import.meta.url))).growingShape;
const INTERVAL = Number(env.INTERVAL_MS ?? 15_000);
const MAX_GAS_PRICE = parseGwei(env.MAX_GAS_PRICE_GWEI ?? '50');
const ALTRUISTIC = env.KEEPER_ALTRUISTIC === '1';
const DRY_RUN = env.DRY_RUN === '1';
const BOOK_BATCH = BigInt(env.BOOK_BATCH ?? 50);

const pub = createPublicClient({ transport: http(RPC) });
const chainId = await pub.getChainId();
let account;
if (env.KEEPER_PRIVATE_KEY) account = privateKeyToAccount(env.KEEPER_PRIVATE_KEY);
else if (env.KEEPER_UNLOCKED && chainId === 31337) account = env.KEEPER_UNLOCKED;
else if (!DRY_RUN) throw new Error('set KEEPER_PRIVATE_KEY, or KEEPER_UNLOCKED on a chain-31337 fork, or DRY_RUN=1');
const wallet = account ? createWalletClient({ account, transport: http(RPC) }) : null;
const sender = typeof account === 'string' ? account : account?.address;

const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });

async function readState() {
  const pool = await read(GAME, gameAbi, 'pool');
  const g = (fn, args) => read(GAME, gameAbi, fn, args);
  const p = (fn, args) => read(pool, poolAbi, fn, args);
  const [next, last, booked, unsettled, ownerProceeds, block, featured, params, keeper, keeperBudget, lastFlat, operating,
    replacementDue, desired, compositionDue, retiredAt, tierCount] = await Promise.all([
    p('nextSequenceToProcess'), p('lastIssuedSequence'), g('bookedSequence'), p('unsettledAcquisitionCount'),
    p('ownerProceeds'), pub.getBlock(), g('featured'), g('params'), g('keeper'), g('keeperBudget'),
    g('lastFlatRewardAt'), g('operating'), g('replacementDue'), g('desiredNotional'), g('compositionDue'),
    g('retiredAt'), g('tierCount'),
  ]);
  const fee = await read(ADDR.shapes, shapesAbi, 'mintFee');
  let cheapestTierCost = 2n ** 255n;
  for (let i = 0n; i < tierCount; i++) {
    const t = await g('tier', [i]);
    const cost = t.backing + (t.packShapes === 0 ? 1n : BigInt(t.packShapes)) * fee;
    if (t.live < t.target && cost < cheapestTierCost) cheapestTierCost = cost;
  }
  // Pending requests whose word reached the FWA service but whose delivery to the pool ran out of gas.
  const storedUndelivered = [];
  let head = null;
  for (let seq = next; seq <= last; seq++) {
    const id = await p('requestIdAtSequence', [seq]);
    const [, , , , status] = await p('acquisitions', [id]);
    const [, deadline] = await p('acquisitionMeta', [id]);
    if (seq === next) head = { status, deadline: BigInt(deadline) };
    if (status === ACQ.Pending && VRF_STORED.has(await read(ADDR.vrfService, serviceAbi, 'requestStatus', [id]))) {
      storedUndelivered.push(id);
    }
  }
  const [, , , , backing, notional, , , floor] = featured;
  return {
    pool, storedUndelivered, head, block: block.number, baseFee: block.baseFeePerGas ?? 0n, now: block.timestamp,
    processed: next - 1n, booked, unsettled, ownerProceeds, bookBatch: BOOK_BATCH, retired: retiredAt !== 0n,
    replacementDue, operating, cheapestTierCost, seedCost: [0n, 0n, 10n ** 17n, 5n * 10n ** 17n, 10n ** 18n][params[8]] + fee,
    compositionDue, repriceStepBps: params[4], keeperBudget, lastFlatRewardAt: lastFlat,
    keeper: { perDraw: keeper[0], budgetCap: keeper[1], flatReward: keeper[2], flatInterval: BigInt(keeper[3]), gasOverhead: BigInt(keeper[4]), gasPriceCap: keeper[5], priorityCap: keeper[6] },
    featured: { listingId: featured[1], backing, notional, floor, desired },
  };
}

/** Sends at most one job, the highest-priority one that simulates and pays; returns whether it sent. */
async function tick() {
  const s = await readState();
  const gasPrice = await pub.getGasPrice();
  const jobs = dueJobs(s);
  if (jobs.length === 0) return false;
  if (gasPrice > MAX_GAS_PRICE) {
    console.log(`gas ${formatGwei(gasPrice)} gwei above cap; ${jobs.length} job(s) deferred`);
    return false;
  }
  for (const job of jobs) {
    const [address, abi] = job.target === 'game' ? [GAME, gameAbi] : [ADDR.vrfService, serviceAbi];
    let request;
    let gas;
    try {
      ({ request } = await pub.simulateContract({ address, abi, functionName: job.fn, args: job.args, account: sender ?? GAME }));
      gas = await pub.estimateContractGas({ address, abi, functionName: job.fn, args: job.args, account: sender ?? GAME });
    } catch (e) {
      console.log(`${job.name}: simulation failed (${e.shortMessage ?? e.message}); skipped`);
      continue;
    }
    const cost = gas * gasPrice;
    // `book` accrues budget for the draws it books before paying, so count that accrual (upper bound:
    // every unbooked draw delivered).
    let keeperBudget = s.keeperBudget;
    if (job.name === 'book') {
      const n = s.processed - s.booked < BOOK_BATCH ? s.processed - s.booked : BOOK_BATCH;
      keeperBudget += n * s.keeper.perDraw;
      if (keeperBudget > s.keeper.budgetCap) keeperBudget = s.keeper.budgetCap;
    }
    const reward = job.target === 'game' ? expectedReward({ ...s, keeperBudget, gas, gasPrice }) : 0n;
    if (!ALTRUISTIC && job.target === 'game' && reward * 10n < cost * 9n) {
      console.log(`${job.name}: reward ${formatEther(reward)} < cost ${formatEther(cost)} ETH; skipped`);
      continue;
    }
    if (DRY_RUN) {
      console.log(`[dry] ${job.name} gas ${gas} cost ${formatEther(cost)} reward ${formatEther(reward)}`);
      continue;
    }
    const hash = await wallet.writeContract({ ...request, chain: null, gas: (gas * 12n) / 10n });
    const receipt = await pub.waitForTransactionReceipt({ hash });
    console.log(`${job.name}: ${receipt.status} gas ${receipt.gasUsed} tx ${hash}`);
    // Later jobs depend on fresh state (compose after book, decay after replenish): re-plan.
    return receipt.status === 'success';
  }
  return false;
}

console.log(`keeper for ${GAME} on chain ${chainId}${DRY_RUN ? ' (dry run)' : ''} as ${sender ?? 'nobody'}`);
for (;;) {
  try {
    for (let i = 0; i < 10 && (await tick()); i++);
  } catch (e) {
    console.error('tick failed:', e.shortMessage ?? e.message);
  }
  if (env.ONCE === '1') break;
  await new Promise((r) => setTimeout(r, INTERVAL));
}
