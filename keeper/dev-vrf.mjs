// Local-fork stand-in for Chainlink VRF: fulfils pending FWA requests by impersonating the Chainlink
// coordinator into the FWA VRF service, the same path mainnet uses. Refuses any chain but 31337.
import { readFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, http, parseEther, toHex } from 'viem';
import { randomBytes } from 'node:crypto';
import { gameAbi, poolAbi, serviceAbi, ADDR } from './abi.mjs';

const RPC = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
const GAME = process.env.GAME ?? JSON.parse(readFileSync(new URL('../deployments/31337.json', import.meta.url))).growingShape;
const DELAY_BLOCKS = BigInt(process.env.DEV_VRF_DELAY_BLOCKS ?? 3);
const DROP = Number(process.env.DEV_VRF_DROP ?? 0); // share of requests left unfulfilled, to exercise expiry

const pub = createPublicClient({ transport: http(RPC) });
const coord = createWalletClient({ account: ADDR.chainlinkCoordinator, transport: http(RPC) });
if ((await pub.getChainId()) !== 31337) throw new Error('dev-vrf runs only on a chain-31337 local fork');
await pub.request({ method: 'anvil_setBalance', params: [ADDR.chainlinkCoordinator, toHex(parseEther('100'))] });

const pool = await pub.readContract({ address: GAME, abi: gameAbi, functionName: 'pool' });
const seen = new Set();
console.log(`dev-vrf: fulfilling requests for pool ${pool}`);

for (;;) {
  try {
    const [next, last, head] = await Promise.all([
      pub.readContract({ address: pool, abi: poolAbi, functionName: 'nextSequenceToProcess' }),
      pub.readContract({ address: pool, abi: poolAbi, functionName: 'lastIssuedSequence' }),
      pub.getBlockNumber(),
    ]);
    for (let seq = next; seq <= last; seq++) {
      const id = await pub.readContract({ address: pool, abi: poolAbi, functionName: 'requestIdAtSequence', args: [seq] });
      if (seen.has(id)) continue;
      const [, requestBlock, , , status] = await pub.readContract({ address: pool, abi: poolAbi, functionName: 'acquisitions', args: [id] });
      if (status !== 1 || head < requestBlock + DELAY_BLOCKS) continue; // 1 = Pending
      seen.add(id);
      if (Math.random() < DROP) { console.log(`dropped ${id}`); continue; }
      const word = BigInt(toHex(randomBytes(32)));
      const hash = await coord.writeContract({ chain: null, address: ADDR.vrfService, abi: serviceAbi, functionName: 'rawFulfillRandomWords', args: [id, [word]], gas: 3_000_000n });
      console.log(`fulfilled seq ${seq} request ${id} tx ${hash}`);
    }
  } catch (e) {
    console.error('dev-vrf:', e.shortMessage ?? e.message);
  }
  await new Promise((r) => setTimeout(r, 2000));
}
