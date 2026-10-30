// Read-only state report for a deployed game: cycles, ledger, and the accounting identity.
import { createPublicClient, http, formatEther } from 'viem';
import { gameAbi, poolAbi } from './abi.mjs';

const pub = createPublicClient({ transport: http(process.env.RPC_URL ?? 'http://127.0.0.1:8545') });
const GAME = process.env.GAME;
const g = (functionName, args = []) => pub.readContract({ address: GAME, abi: gameAbi, functionName, args });
const pool = await g('pool');
const p = (functionName, args = []) => pub.readContract({ address: pool, abi: poolAbi, functionName, args });

const names = ['capitalIn', 'revenue', 'recovered', 'prizeExpense', 'featuredAwarded', 'keeperPaid', 'growthAllocated',
  'growthFund', 'keeperBudget', 'inventoryCost', 'surplus', 'drawsBooked', 'liveOrdinary', 'bookedSequence', 'cycle', 'cycleCount'];
const v = Object.fromEntries(await Promise.all(names.map(async (n) => [n, await g(n)])));
const f = await g('featured');
const balance = await pub.getBalance({ address: GAME });
const featuredCost = f[1] === 0n ? 0n : f[2];
const lhs = balance + v.inventoryCost + featuredCost;
const rhs = v.capitalIn + v.revenue + v.recovered - v.prizeExpense - v.featuredAwarded - v.keeperPaid;

const cycles = [];
for (let i = 0n; i < v.cycleCount; i++) {
  const r = await g('cycleResult', [i]);
  cycles.push({ tokenId: r.tokenId, winner: r.winner, backingEth: formatEther(r.backing), compositions: r.compositions, draws: r.draws, endedBlock: r.endedBlock });
}
const eth = (x) => formatEther(x);
const out = {
  game: GAME, pool, block: await pub.getBlockNumber(),
  processed: (await p('nextSequenceToProcess')) - 1n, issued: await p('lastIssuedSequence'), booked: v.bookedSequence,
  drawsBooked: v.drawsBooked, liveOrdinary: v.liveOrdinary, cycle: v.cycle, cycles,
  featured: { tokenId: f[0], listingId: f[1], backingEth: eth(f[4]), notionalEth: eth(f[5]), compositions: f[10], draws: f[11], cycleDraws: f[12] },
  ledgerEth: { balance: eth(balance), capitalIn: eth(v.capitalIn), revenue: eth(v.revenue), recovered: eth(v.recovered), prizeExpense: eth(v.prizeExpense),
    featuredAwarded: eth(v.featuredAwarded), keeperPaid: eth(v.keeperPaid), growthAllocated: eth(v.growthAllocated), growthFund: eth(v.growthFund),
    keeperBudget: eth(v.keeperBudget), inventoryCost: eth(v.inventoryCost), surplus: formatEther(v.surplus) },
  identity: { lhsWei: lhs, rhsWei: rhs, exact: lhs === rhs },
};
console.log(JSON.stringify(out, (_, x) => (typeof x === 'bigint' ? x.toString() : x), 2));
