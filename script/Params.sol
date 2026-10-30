// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GrowingShape} from "../src/GrowingShape.sol";

/// @notice The opening configuration, shared by tests, the fork rehearsal and the deployment script.
/// @dev Values and their evidence: docs/ECONOMICS.md. Change them here only.
library Params {
    uint256 internal constant CAPITAL = 4.2 ether;

    function game() internal pure returns (GrowingShape.GameParams memory) {
        return GrowingShape.GameParams({
            markupBps: 11_000,
            startNotionalBps: 10_000,
            floorBps: 1_000,
            resetShareBps: 7_000,
            repriceStepBps: 500,
            decayPpm: 377,
            minLiveOrdinary: 60,
            maxPendingDraws: 30,
            seedIndex: 3,
            reserveTarget: 0.5 ether
        });
    }

    function keeper() internal pure returns (GrowingShape.KeeperParams memory) {
        return GrowingShape.KeeperParams({
            perDraw: 0.0001 ether,
            budgetCap: 0.05 ether,
            flatReward: 0.0002 ether,
            flatInterval: 600,
            gasOverhead: 30_000,
            gasPriceCap: 20 gwei,
            priorityCap: 1 gwei
        });
    }

    function tiers() internal pure returns (GrowingShape.TierInput[] memory t) {
        t = new GrowingShape.TierInput[](4);
        t[0] = GrowingShape.TierInput({backing: 0.01 ether, packShapes: 0, target: 50});
        t[1] = GrowingShape.TierInput({backing: 0.03 ether, packShapes: 3, target: 35});
        t[2] = GrowingShape.TierInput({backing: 0.05 ether, packShapes: 0, target: 10});
        t[3] = GrowingShape.TierInput({backing: 0.1 ether, packShapes: 0, target: 4});
    }
}
