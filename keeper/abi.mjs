import { readFileSync } from 'node:fs';

const load = (name) => JSON.parse(readFileSync(new URL(`../abi/${name}.json`, import.meta.url)));

export const gameAbi = load('GrowingShape');
export const poolAbi = load('IFWAClone');
export const serviceAbi = load('IFWAVRFService');
export const shapesAbi = load('IShapes');

export const ADDR = {
  shapes: '0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0',
  drawPacks: '0xf21514B090Da7dF4390803497d6ae673801E5cA7',
  fwaFactory: '0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c',
  vrfService: '0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2',
  chainlinkCoordinator: '0xD7f86b4b8Cae7D942340FF628F82735b7a20893a',
};
