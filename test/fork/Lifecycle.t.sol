// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GameBase} from "./GameBase.sol";
import {GrowingShape} from "../../src/GrowingShape.sol";
import {IFWAClone} from "../../src/interfaces/IFWA.sol";
import {Params} from "../../script/Params.sol";

/// @notice The game's main lifecycle on the real Shapes, Draw Packs and FWA contracts.
contract LifecycleForkTest is GameBase {
    function test_launchListsBoardAndFeatured() public view {
        assertEq(pool.owner(), address(game));
        assertEq(pool.purchaseOperator(), address(game));
        assertTrue(pool.localPurchasesEnabled());
        assertEq(game.liveOrdinary(), 99);
        assertEq(pool.activeListingCount(), 100);
        assertEq(game.replacementDue(), 0);
        assertEq(game.cycle(), 1);
        assertEq(_featuredBacking(), 0.5 ether);
        assertEq(_featuredNotional(), 0.5 ether);
        uint256 featuredId;
        (featuredId,,,,,,,,,,,,,) = game.featured();
        assertEq(SHAPES.ownerOf(featuredId), address(pool));
        // 50 x 0.011 + 35 x 0.033 + 10 x 0.051 + 4 x 0.101 ETH at the live 0.001 ETH mint fee.
        assertEq(game.inventoryCost(), 2.619 ether);
        _assertIdentity();
    }

    function test_ladderMatchesShapes() public view {
        uint256[9] memory ladder =
            [uint256(0.01 ether), 0.05 ether, 0.1 ether, 0.5 ether, 1 ether, 5 ether, 10 ether, 50 ether, 100 ether];
        for (uint256 i; i < 9; ++i) {
            (bool ok, bytes memory r) =
                address(SHAPES).staticcall(abi.encodeWithSignature("denominationAt(uint8)", uint8(i)));
            assertTrue(ok);
            assertEq(abi.decode(r, (uint256)), ladder[i]);
        }
    }

    function test_drawBooksPrizeProceedsAndDecayCredit() public {
        uint256[] memory ids = _tryBuy(alice, 1);
        assertEq(ids.length, 1);
        _fulfillAll(ids);
        uint256 proceeds = pool.ownerProceeds();
        assertGt(proceeds, 0);
        vm.prank(keeperBot);
        game.book(10);
        assertEq(game.bookedSequence(), 1);
        assertEq(game.revenue(), proceeds);
        assertEq(game.liveOrdinary() + 1, 99);
        assertEq(game.drawsBooked(), 1);
        (,,,,,,,,,,, uint32 draws,,) = game.featured();
        assertEq(draws, 1);
        assertGt(game.keeperPaid(), 0);
        _assertIdentity();
    }

    function test_expiredDrawBooksNothing() public {
        uint256[] memory ids = _tryBuy(alice, 1);
        vm.roll(block.number + 40);
        pool.processAcquisitions(1);
        uint256 live = game.liveOrdinary();
        vm.prank(keeperBot);
        game.book(10);
        assertEq(game.liveOrdinary(), live);
        assertEq(game.revenue(), 0);
        assertEq(game.drawsBooked(), 0);
        assertGt(pool.acquisitionRefundCredit(alice), 0);
        ids;
    }

    function test_decayPublishesInStepsAndOnlyWhenIdle() public {
        _play(140); // 140 * 377ppm * 0.5 ETH = 0.0264 ETH, past one 5% step
        uint256 desired = game.desiredNotional();
        assertLt(desired, 0.5 ether);
        assertLe(_featuredNotional(), 0.5 ether);
        // A pending request blocks repricing.
        uint256[] memory ids = _tryBuy(alice, 1);
        vm.prank(keeperBot);
        vm.expectRevert();
        game.publishDecay();
        _fulfillAll(ids);
        _keep();
        (,,,, uint256 weight, uint256 price,,) = pool.listings(_featuredListing());
        assertEq(price, _featuredNotional());
        assertEq(weight, 1e36 / price);
        _assertIdentity();
    }

    function test_firstCompositionHalfToOne() public {
        uint256 featuredId;
        (featuredId,,,,,,,,,,,,,) = game.featured();
        bytes32 seed = SHAPES.seedOf(featuredId);
        uint256 guard;
        while (_featuredBacking() == 0.5 ether) {
            _play(50);
            require(++guard < 40, "no composition");
        }
        assertEq(_featuredBacking(), 1 ether);
        assertEq(SHAPES.backingOf(featuredId), 1 ether);
        assertEq(SHAPES.seedOf(featuredId), seed);
        assertEq(SHAPES.ownerOf(featuredId), address(pool));
        (,,,,,, uint96 resetNotional,,, , uint16 compositions,,,) = game.featured();
        assertEq(compositions, 1);
        assertGt(resetNotional, 0.5 ether);
        assertLt(resetNotional, 1 ether);
        _assertIdentity();
    }

    function test_featuredWinRecordsCycleAndRestarts() public {
        assertGe(game.operating(), 0.501 ether + game.replacementDue(), "capital funds the next seed");
        uint256 featuredId;
        (featuredId,,,,,,,,,,,,,) = game.featured();
        uint256 requestId = _winFeatured(alice);
        assertEq(SHAPES.ownerOf(featuredId), alice);
        _keep();
        assertEq(game.cycleCount(), 1);
        GrowingShape.CycleResult memory r = game.cycleResult(0);
        assertEq(r.winner, alice);
        assertEq(r.tokenId, featuredId);
        assertEq(r.backing, 0.5 ether);
        assertEq(r.requestId, requestId);
        assertEq(game.cycle(), 2);
        assertTrue(_featuredListing() != 0);
        uint256 nextId;
        (nextId,,,,,,,,,,,,,) = game.featured();
        assertTrue(nextId != featuredId);
        assertEq(game.surplus(), int256(game.revenue()) - int256(game.prizeExpense()) - int256(game.keeperPaid())
            - int256(game.growthAllocated()) - 0.501 ether);
        _assertIdentity();
    }

    function test_gateClosesWhileCompositionDueAndReopensAfter() public {
        uint256 guard;
        while (!game.compositionDue()) {
            uint256[] memory ids = _tryBuy(alice, 5);
            _fulfillAll(ids);
            vm.prank(keeperBot);
            game.book(100);
            vm.startPrank(keeperBot);
            if (game.replacementDue() != 0) game.replenish(20);
            try game.publishDecay() {} catch {}
            vm.stopPrank();
            require(++guard < 200, "never due");
        }
        assertFalse(game.canPurchase(alice));
        assertEq(_tryBuy(alice, 1).length, 0);
        vm.prank(keeperBot);
        game.compose();
        assertTrue(game.canPurchase(alice));
        assertEq(_tryBuy(alice, 1).length, 1);
    }

    function test_gateClosesWhenBookingFallsBehind() public {
        uint256 cap = Params.game().maxPendingDraws;
        uint256 bought;
        while (bought < cap) {
            uint256[] memory ids = _tryBuy(alice, 5);
            if (ids.length == 0) break;
            _fulfillAll(ids);
            bought += ids.length;
        }
        assertEq(bought, cap);
        assertFalse(game.canPurchase(alice));
        vm.prank(keeperBot);
        game.book(100);
        assertTrue(game.canPurchase(alice));
    }

    function test_gateRejectsAddressesThatBreakDelivery() public view {
        assertFalse(game.canPurchase(address(game)));
        assertFalse(game.canPurchase(address(SHAPES)));
        assertFalse(game.canPurchase(address(PACKS)));
        assertFalse(game.canPurchase(address(pool)));
        assertTrue(game.canPurchase(alice));
    }

    function test_packPrizeDeliversToPlayer() public {
        // Find a pack listing and draw it.
        uint256 packListing;
        for (uint256 id = 1; id < 120 && packListing == 0; ++id) {
            (address collection,,,,,,, IFWAClone.ListingStatus s) = pool.listings(id);
            if (collection == address(PACKS) && s == IFWAClone.ListingStatus.Active) packListing = id;
        }
        (,,, uint256 packId,,,,) = pool.listings(packListing);
        uint256[] memory ids = _tryBuy(alice, 1);
        _fulfill(ids[0], _wordFor(packListing));
        assertEq(PACKS.ownerOf(packId), alice);
        assertEq(PACKS.valueOf(packId), 0.03 ether);
    }
}
