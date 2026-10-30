// Local-fork player bot for rehearsals: unlocked anvil accounts buy random 1-5 draw batches at the live
// quote until TARGET_CYCLES featured Shapes have been won or MAX_DRAWS are bought. Chain 31337 only.
import { createPublicClient, createWalletClient, http, parseEther, toHex } from 'viem';
import { gameAbi, poolAbi } from './abi.mjs';

const RPC = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
const GAME = process.env.GAME;
const TARGET_CYCLES = BigInt(process.env.TARGET_CYCLES ?? 3);
const MAX_DRAWS = Number(process.env.MAX_DRAWS ?? 12000);
const PACE_MS = Number(process.env.PACE_MS ?? 800);
const PLAYERS = [
  '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65', '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc',
  '0x976EA74026E726554dB657fA54763abd0C3a0aa9', '0x14dC79964da2C08b23698B3D3cc7Ca32193d9955',
];

const pub = createPublicClient({ transport: http(RPC) });
if ((await pub.getChainId()) !== 31337) throw new Error('players.mjs runs only on a chain-31337 local fork');
const pool = await pub.readContract({ address: GAME, abi: gameAbi, functionName: 'pool' });
for (const p of PLAYERS) await pub.request({ method: 'anvil_setBalance', params: [p, toHex(parseEther('100000'))] });

let bought = 0;
const errors = {};
for (let i = 0; bought < MAX_DRAWS; i++) {
  const cycles = await pub.readContract({ address: GAME, abi: gameAbi, functionName: 'cycleCount' });
  if (cycles >= TARGET_CYCLES) break;
  const who = PLAYERS[i % PLAYERS.length];
  const count = BigInt(1 + Math.floor(Math.random() * 5));
  try {
    const gasPrice = await pub.getGasPrice();
    const [fee, , total] = await pub.readContract({ address: pool, abi: poolAbi, functionName: 'quoteAcquisitionPrice', args: [count], gasPrice });
    const version = await pub.readContract({ address: pool, abi: poolAbi, functionName: 'inventoryVersion' });
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
    const { request } = await pub.simulateContract({
      account: who, address: pool, abi: poolAbi, functionName: 'acquireBatch',
      args: [who, count, fee, 0n, 1000n, version, deadline], value: total + total / 50n, gasPrice,
    });
    const wallet = createWalletClient({ account: who, transport: http(RPC) });
    await wallet.writeContract({ ...request, chain: null });
    bought += Number(count);
    if (bought % 100 < Number(count)) console.log(`bought ${bought} draws, cycles won ${cycles}`);
  } catch (e) {
    const key = e.cause?.data?.errorName ?? e.shortMessage?.split('\n')[0] ?? 'error';
    errors[key] = (errors[key] ?? 0) + 1;
  }
  await new Promise((r) => setTimeout(r, PACE_MS));
}
console.log(JSON.stringify({ bought, errors }));
