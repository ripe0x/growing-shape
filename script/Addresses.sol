// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IShapes} from "../src/interfaces/IShapes.sol";
import {IShapePacks} from "../src/interfaces/IShapePacks.sol";
import {IFWAFactory, IFWAVRFService} from "../src/interfaces/IFWA.sol";

/// @notice Ethereum mainnet dependencies, verified at block 26,305,681 (2026-10-30). Evidence and
///         re-verification steps: docs/DEPLOY.md and deployments/dependencies.json.
library Addresses {
    IShapes internal constant SHAPES = IShapes(0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0);
    IShapePacks internal constant PACKS = IShapePacks(0xf21514B090Da7dF4390803497d6ae673801E5cA7);
    IFWAFactory internal constant FACTORY = IFWAFactory(0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c);
    address internal constant FWA_IMPLEMENTATION = 0xEaa4d032908A9734a2c7939c0D211c35ad51eb31;
    IFWAVRFService internal constant VRF_SERVICE = IFWAVRFService(0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2);
    address internal constant CHAINLINK_COORDINATOR = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;
    address internal constant FWA_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
}
