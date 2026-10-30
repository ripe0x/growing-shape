import type { Abi } from "viem";
import GrowingShape from "../../abi/GrowingShape.json";
import IFWAClone from "../../abi/IFWAClone.json";

export const gameAbi = GrowingShape as Abi;
// IFWAClone.json carries FWA's verified custom errors, so viem names pool reverts directly.
export const poolAbi = IFWAClone as Abi;

// tokenURI/svg aren't in the vendored IShapes/IShapePacks interface ABIs, so add
// the read fragments the UI needs for art and ownership.
export const shapesAbi: Abi = [
  { type: "function", stateMutability: "view", name: "tokenURI", inputs: [{ type: "uint256", name: "id" }], outputs: [{ type: "string" }] },
  { type: "function", stateMutability: "view", name: "svg", inputs: [{ type: "uint256", name: "id" }], outputs: [{ type: "string" }] },
  { type: "function", stateMutability: "view", name: "backingOf", inputs: [{ type: "uint256", name: "id" }], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "ownerOf", inputs: [{ type: "uint256", name: "id" }], outputs: [{ type: "address" }] },
];

export const packsAbi: Abi = [
  { type: "function", stateMutability: "view", name: "tokenURI", inputs: [{ type: "uint256", name: "id" }], outputs: [{ type: "string" }] },
  { type: "function", stateMutability: "view", name: "valueOf", inputs: [{ type: "uint256", name: "id" }], outputs: [{ type: "uint256" }] },
  { type: "function", stateMutability: "view", name: "ownerOf", inputs: [{ type: "uint256", name: "id" }], outputs: [{ type: "address" }] },
];
