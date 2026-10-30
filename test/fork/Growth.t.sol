// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GameBase} from "./GameBase.sol";
import {GrowingShape} from "../../src/GrowingShape.sol";
import {IFWAClone} from "../../src/interfaces/IFWA.sol";
import {Params} from "../../script/Params.sol";

/// @notice Multi-composition and multi-cycle behaviour on the real stack. Uses the maximum markup so
///         growth arrives in hundreds of draws; every rule is the production one.
contract GrowthForkTest is GameBase {
    function _gameParams() internal pure override returns (GrowingShape.GameParams memory p) {
        p = Params.game();
        p.markupBps = 20_000;
    }

    function _playUntilBacking(uint256 backing) internal {
        uint256 guard;
        while (_featuredBacking() < backing) {
            _play(25);
            require(++guard < 200, "never reached backing");
        }
    }

    function test_composeHalfToOneToFiveThenWin() public {
        uint256 featuredId;
        (featuredId,,,,,,,,,,,,,) = game.featured();
        bytes32 seed = SHAPES.seedOf(featuredId);

        _playUntilBacking(1 ether);
        (,,,,, uint96 notionalAt1, uint96 resetAt1,,,,,,,) = game.featured();
        assertEq(notionalAt1, resetAt1);
        _playUntilBacking(5 ether);

        (,,,,, uint96 notional, uint96 resetNotional, uint96 decayPerDraw, uint96 floor,, uint16 compositions,,,) =
            game.featured();
        assertEq(game.cycleCount(), 0, "featured won early by a random draw");
        assertEq(compositions, 2);
        assertEq(SHAPES.backingOf(featuredId), 5 ether);
        assertEq(SHAPES.seedOf(featuredId), seed);
        assertEq(SHAPES.composeDepth(featuredId), 2);
        // Partial reset: decayed notional at 1 ETH plus 70% of the 4 ETH added, never the full 5 ETH.
        assertLt(resetNotional, 1 ether + 2.8 ether + 1);
        assertGe(resetNotional, 2.8 ether);
        assertEq(decayPerDraw, 5 ether * 377 / 1e6);
        assertEq(floor, 0.5 ether);
        assertLe(notional, resetNotional);

        uint256 growthBefore = game.growthFund();
        _winFeatured(alice);
        _keep();
        assertEq(SHAPES.ownerOf(featuredId), alice);
        assertEq(SHAPES.backingOf(featuredId), 5 ether);
        GrowingShape.CycleResult memory r = game.cycleResult(0);
        assertEq(r.backing, 5 ether);
        assertEq(r.compositions, 2);
        assertEq(r.winner, alice);
        // A new cycle runs; leftover growth carried over to it.
        assertEq(game.cycle(), 2);
        assertEq(_featuredBacking(), 0.5 ether);
        assertGe(game.growthFund(), growthBefore);
        _assertIdentity();

        // The winner holds a real 5 ETH Shape and can redeem it.
        uint256 before = alice.balance;
        vm.prank(alice);
        SHAPES.redeem(featuredId);
        assertEq(alice.balance - before, 5 ether);
    }

    function test_threeCyclesBackToBack() public {
        for (uint256 i; i < 3; ++i) {
            _play(30);
            _winFeatured(alice);
            _keep();
            _assertIdentity();
        }
        assertEq(game.cycleCount(), 3);
        assertEq(game.cycle(), 4);
        for (uint256 i; i < 3; ++i) {
            assertEq(game.cycleResult(i).winner, alice);
        }
    }

    function test_neverRepublishesHigherNotionalBetweenCompositions() public {
        uint256 last = _featuredNotional();
        for (uint256 i; i < 12; ++i) {
            uint256 compositions;
            (,,,,,,,,,, uint16 c,,,) = game.featured();
            compositions = c;
            _play(10);
            (,,,,,,,,,, uint16 c2,,,) = game.featured();
            uint256 n = _featuredNotional();
            if (c2 == compositions) assertLe(n, last, "notional rose without composition");
            last = n;
        }
    }

    function test_deliveryFailureIsBookedThenRecovered() public {
        // Fail delivery of whichever 0.01 Shape is drawn by making Shapes.transferFrom revert for the pool.
        uint256[] memory ids = _tryBuy(alice, 1);
        uint256 target = pool.slotToListing(1);
        (address collection,,, uint256 tokenId,,,,) = pool.listings(target);
        vm.mockCallRevert(collection, abi.encodeWithSignature("transferFrom(address,address,uint256)", address(pool), alice, tokenId), "");
        _fulfill(ids[0], _wordFor(target));
        vm.clearMockedCalls();
        (,,,,,,, IFWAClone.ListingStatus s) = pool.listings(target);
        assertEq(uint8(s), uint8(IFWAClone.ListingStatus.DeliveryPending));

        vm.prank(keeperBot);
        game.book(10);
        assertEq(game.drawsBooked(), 0, "failed delivery is not a settled draw");
        assertEq(game.liveOrdinary(), 98);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        pool.refundFailedDelivery(target);
        uint256 backing = collection == address(SHAPES) ? SHAPES.backingOf(tokenId) : PACKS.valueOf(tokenId);
        vm.prank(keeperBot);
        game.recover(target);
        assertEq(game.recovered(), backing);
        _assertIdentity();
        vm.prank(alice);
        pool.withdrawAcquisitionRefund();
    }

    function test_underfundedRestartKeepsOrdinaryPlayAndRecovers() public {
        // A fresh game funded with only the board and its first featured Shape.
        GrowingShape g = _deploy(_gameParams(), Params.tiers());
        _launch(g, 2.619 ether + 0.501 ether + 0.05 ether);
        game = g;
        pool = g.pool();
        _winFeatured(alice);
        _keep();
        assertEq(_featuredListing(), 0, "no seed money yet");
        vm.prank(keeperBot);
        vm.expectRevert(GrowingShape.InsufficientFunds.selector);
        g.startCycle();
        assertTrue(g.canPurchase(alice), "ordinary draws continue between cycles");
        uint256 guard;
        while (_featuredListing() == 0) {
            _play(20);
            require(++guard < 50, "never restarted");
        }
        assertEq(g.cycle(), 2);
        _assertIdentity();
    }

    function test_retirementKeepsPrizesInPlayAndReleasesOnlyFreeCapital() public {
        _play(40);
        vm.prank(owner);
        game.retire();
        vm.expectRevert(GrowingShape.IsRetired.selector);
        vm.prank(keeperBot);
        game.replenish(1);
        vm.expectRevert(GrowingShape.IsRetired.selector);
        vm.prank(owner);
        game.setPaused(true);

        uint256 listed = game.liveOrdinary();
        uint256 growth = game.growthFund();
        vm.prank(keeperBot);
        game.finalize();
        assertEq(game.liveOrdinary(), listed, "prizes stay listed");
        assertEq(_featuredBacking() != 0 && _featuredListing() != 0, true, "featured stays listed");
        assertGe(game.growthFund(), growth, "growth fund stays committed");
        assertEq(game.operating(), game.keeperBudget(), "only the keeper allowance stays operating");
        assertGt(residual.balance, 0);

        // Play drains the board to players; once empty, everything left goes to the residual recipient.
        uint256 guard;
        while (game.liveOrdinary() != 0 || _featuredListing() != 0) {
            uint256[] memory ids = _tryBuy(alice, 1);
            if (ids.length == 0) {
                _keep();
                require(++guard < 20, "stuck");
                continue;
            }
            _fulfillAll(ids);
            vm.prank(keeperBot);
            game.book(10);
            if (game.compositionDue()) {
                vm.prank(keeperBot);
                game.compose();
            }
        }
        vm.prank(keeperBot);
        game.finalize();
        assertEq(address(game).balance, 0);
        assertTrue(pool.retired());
        assertEq(game.inventoryCost(), 0);
    }
}
