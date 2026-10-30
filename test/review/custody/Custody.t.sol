// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GameBase} from "../../fork/GameBase.sol";
import {GrowingShape} from "../../../src/GrowingShape.sol";
import {IFWAClone} from "../../../src/interfaces/IFWA.sol";
import {Params} from "../../../script/Params.sol";

/// @notice Independent-review custody/accounting counterexample attempts.
contract CustodyReviewTest is GameBase {
    // Fast surplus so growth actually happens within a few dozen draws.
    function _gameParams() internal pure override returns (GrowingShape.GameParams memory p) {
        p = Params.game();
        p.markupBps = 20_000;
    }

    /// @dev Core owner property: founder capital and forced ETH must never become surplus or fund growth.
    function test_capitalAndForcedEthNeverFundGrowth() public {
        assertEq(game.surplus(), 0);
        assertEq(game.growthFund(), 0);
        assertEq(game.revenue(), 0);

        // Extra founder capital via the sanctioned path.
        vm.deal(address(this), address(this).balance + 50 ether);
        game.fund{value: 50 ether}();
        // Forced ETH (selfdestruct / coinbase) that bypasses receive() and `fund`.
        vm.deal(address(game), address(game).balance + 25 ether);

        // Maintenance runs; with no draws there is no realised revenue.
        vm.prank(keeperBot);
        game.book(50);

        assertEq(game.growthFund(), 0, "growth funded without realised revenue");
        assertLe(game.surplus(), int256(0), "capital/forced ETH became surplus");
        assertFalse(game.compositionDue(), "composition due on capital alone");

        vm.prank(keeperBot);
        vm.expectRevert(GrowingShape.NotDue.selector);
        game.compose();
    }

    /// @dev Growth is only ever funded from realised inflows (revenue + recovered), never from capital,
    ///      across a live session that actually composes.
    function test_growthNeverExceedsRealisedInflows() public {
        for (uint256 i; i < 4; ++i) {
            _play(25);
            assertLe(
                game.growthAllocated(),
                game.revenue() + game.recovered(),
                "growth drew on founder capital"
            );
            _assertIdentity();
        }
        // Prove the test exercised real growth, not a vacuous bound.
        assertGt(game.growthAllocated(), 0, "no growth happened; bound is vacuous");
    }

    /// @dev Anyone may finalize; residual flows only to the immutable recipient, never to the owner,
    ///      even when the owner is the caller. Also records whether residual == owner is possible.
    function test_residualIsImmutableAndOwnerGainsNothing() public {
        _play(40);
        uint256 ownerBefore = owner.balance;
        uint256 residualBefore = residual.balance;

        vm.prank(owner);
        game.retire();

        // Owner-initiated finalize must still pay only the residual recipient.
        vm.prank(owner);
        game.finalize();

        assertEq(owner.balance, ownerBefore, "owner gained ETH on finalize");
        assertGt(residual.balance, residualBefore, "residual recipient not paid");
        assertEq(game.RESIDUAL_RECIPIENT(), residual, "residual recipient mutated");
    }

    /// @dev `startCycle` only guards seed + replacementDue, ignoring reserveTarget and keeperBudget, so it
    ///      can drop operating() below keeperBudget. Probe whether a later partial `finalize` then reverts
    ///      on `operating() - keeperBudget`.
    function test_startCycleCanStrandPartialFinalize() public {
        // Accrue some keeper budget and realised revenue first.
        _play(30);

        // Drive operating down to near the seed requirement by lowering the reserve to zero and letting
        // the keeper sweep surplus into growth.
        GrowingShape.GameParams memory gp = _gameParams();
        gp.reserveTarget = 0;
        vm.prank(owner);
        game.setGameParams(gp);
        _keep();

        emit log_named_int("surplus", game.surplus());
        emit log_named_uint("operating", game.operating());
        emit log_named_uint("keeperBudget", game.keeperBudget());
        emit log_named_uint("growthFund", game.growthFund());

        // Retire and attempt a partial finalize while prizes are still live.
        vm.prank(owner);
        game.retire();
        // Should not revert with an arithmetic underflow; if it does, that is the finding.
        vm.prank(keeperBot);
        game.finalize();
        emit log_named_uint("operating_after", game.operating());
        emit log_named_uint("keeperBudget_after", game.keeperBudget());
    }
}
