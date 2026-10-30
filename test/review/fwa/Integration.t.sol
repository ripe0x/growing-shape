// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GameBase} from "../../fork/GameBase.sol";
import {GrowingShape} from "../../../src/GrowingShape.sol";
import {IFWAClone} from "../../../src/interfaces/IFWA.sol";

/// @notice Independent review probes for the FWA V2 integration. See the review report for context.
contract IntegrationReviewTest is GameBase {
    function _featuredDraws() internal view returns (uint32 d) {
        (,,,,,,,,,,, uint32 draws,,) = game.featured();
        d = draws;
    }

    function _activeOrdinary() internal view returns (uint256 n) {
        // Every active listing that is not the featured one.
        uint256 fl = _featuredListing();
        for (uint256 id = 1; id < game.liveOrdinary() + 50; ++id) {
            (,,,,,,, IFWAClone.ListingStatus s) = pool.listings(id);
            if (s == IFWAClone.ListingStatus.Active && id != fl) ++n;
        }
    }

    function _firstActiveOrdinary() internal view returns (uint256) {
        uint256 fl = _featuredListing();
        for (uint256 slot = 1; slot < 260; ++slot) {
            uint256 id = pool.slotToListing(slot);
            if (id == 0 || id == fl) continue;
            (,,,,,,, IFWAClone.ListingStatus s) = pool.listings(id);
            if (s == IFWAClone.ListingStatus.Active) return id;
        }
        revert("no active ordinary");
    }

    /* ------------------------------------------------------------------ */
    /* F-A: canPurchase must fit inside FWA's 100k gas stipend             */
    /* ------------------------------------------------------------------ */

    function test_canPurchaseFitsIn100kStipend() public {
        // Heaviest live branch: featured listed, so the hook also runs compositionDue()
        // (external SHAPES.mintFee + ladder math) and the stale-decay check.
        assertGt(_featuredListing(), 0, "featured should be listed after launch");

        // COLD first touch (fresh access list, as the first buyer in a block sees it).
        // Exactly mirror FWA's forwarded stipend: staticcall with 100k gas, require a clean ABI true.
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) =
            address(game).staticcall{gas: 100_000}(abi.encodeWithSelector(game.canPurchase.selector, alice));
        uint256 coldUsed = g0 - gasleft();
        assertTrue(ok, "canPurchase reverted / ran out of gas within the 100k stipend");
        assertEq(ret.length, 32, "non-canonical return");
        assertEq(abi.decode(ret, (bool)), true, "canPurchase denied under the stipend");
        emit log_named_uint("canPurchase gas used incl staticcall (cold)", coldUsed);

        // WARM repeat for comparison.
        uint256 g1 = gasleft();
        game.canPurchase(alice);
        emit log_named_uint("canPurchase gas used (warm)", g1 - gasleft());
    }

    /* ------------------------------------------------------------------ */
    /* F-B: replenish while a draw is unsettled STAGES the replacements,   */
    /*      so liveOrdinary over-reports the selectable board depth.       */
    /* ------------------------------------------------------------------ */

    function test_replenishWhilePendingInflatesLiveOrdinary() public {
        // 1. Win one ordinary prize and book it -> a tier is now short one prize.
        uint256 ord = _firstActiveOrdinary();
        uint256[] memory ids = _tryBuy(alice, 1);
        require(ids.length == 1, "buy failed");
        _fulfill(ids[0], _wordFor(ord));
        vm.prank(keeperBot);
        game.book(10);

        uint256 liveBefore = game.liveOrdinary();
        uint256 activeOrdBefore = _activeOrdinary();
        assertGt(game.replacementDue(), 0, "a replacement is now due");
        assertEq(liveBefore, activeOrdBefore, "game count matches active board before the race");

        // 2. Open a pending draw and leave it unsettled so the pool is busy.
        uint256[] memory pend = _tryBuy(alice, 1);
        require(pend.length == 1, "pending buy failed");
        assertEq(pool.unsettledAcquisitionCount(), 1, "one unsettled acquisition");

        // 3. Replenish now: FWA STAGES the freshly minted replacement (not Active),
        //    yet the game immediately counts it in liveOrdinary.
        vm.prank(keeperBot);
        game.replenish(20);

        uint256 liveAfter = game.liveOrdinary();
        uint256 activeOrdAfter = _activeOrdinary();

        assertEq(liveAfter, liveBefore + 1, "game counts the staged replacement as live");
        assertEq(activeOrdAfter, activeOrdBefore, "FWA did not activate it: it is staged, not selectable");
        assertGt(liveAfter, activeOrdAfter, "liveOrdinary over-reports selectable depth by the staged count");
    }

    /* ------------------------------------------------------------------ */
    /* F-C: startCycle has no idle guard, so a new featured can be listed  */
    /*      as Staged (not selectable) while the pool is busy.             */
    /* ------------------------------------------------------------------ */

    function test_startCycleStagesFeaturedWhilePoolBusy() public {
        vm.deal(address(this), address(this).balance + 2 ether);
        game.fund{value: 2 ether}(); // guarantee operating ETH for the next seed

        // End the current cycle: win the featured and book it.
        uint256 req = _winFeatured(alice);
        req; // silence unused
        vm.prank(keeperBot);
        game.book(10);
        assertEq(_featuredListing(), 0, "cycle ended");

        // Open a pending ordinary draw so the pool is not idle.
        uint256[] memory pend = _tryBuy(alice, 1);
        require(pend.length == 1, "pending buy failed");
        assertGt(pool.unsettledAcquisitionCount(), 0, "pool busy");

        // startCycle lists the new featured while busy -> FWA stages it.
        vm.prank(keeperBot);
        game.startCycle();
        uint256 fl = _featuredListing();
        assertGt(fl, 0, "featured relisted");
        (,,,,,,, IFWAClone.ListingStatus s) = pool.listings(fl);
        assertEq(uint8(s), uint8(IFWAClone.ListingStatus.Staged), "new featured is Staged, not Active");

        // The game still admits buyers, who cannot possibly select the staged featured.
        assertTrue(game.canPurchase(alice), "purchases continue against an un-winnable featured");

        // Self-heals: once the pending draw resolves and the pool is idle, a permissionless
        // activateListings promotes the staged featured to Active. So this is transient, not a trap.
        _fulfill(pend[0], _wordFor(_firstActiveOrdinary()));
        vm.prank(keeperBot);
        game.book(10);
        pool.activateListings(20);
        (,,,,,,, IFWAClone.ListingStatus s2) = pool.listings(fl);
        assertEq(uint8(s2), uint8(IFWAClone.ListingStatus.Active), "featured recovers to Active");
    }

    /* ------------------------------------------------------------------ */
    /* F-D: a draw that fails atomic delivery (booked DeliveryPending) and */
    /*      later succeeds (Fulfilled) is never credited to featured decay.*/
    /* ------------------------------------------------------------------ */

    function test_deliveryPendingThenFulfilledNeverCreditsDecay() public {
        uint256 ord = _firstActiveOrdinary();
        (address coll,,, uint256 tok,,,,) = pool.listings(ord);

        uint256[] memory ids = _tryBuy(alice, 1);
        require(ids.length == 1, "buy failed");
        // Make the atomic delivery fail so the draw settles as DeliveryPending.
        vm.mockCallRevert(
            coll, abi.encodeWithSignature("transferFrom(address,address,uint256)", address(pool), alice, tok), ""
        );
        _fulfill(ids[0], _wordFor(ord));
        vm.clearMockedCalls();
        (,,,,,,, IFWAClone.ListingStatus s0) = pool.listings(ord);
        assertEq(uint8(s0), uint8(IFWAClone.ListingStatus.DeliveryPending), "delivery failed -> DeliveryPending");

        uint32 drawsBefore = _featuredDraws();
        vm.prank(keeperBot);
        game.book(10);
        assertEq(game.drawsBooked(), 0, "failed delivery is not booked as a settled draw");
        assertEq(_featuredDraws(), drawsBefore, "no decay credit for the failed delivery");

        // Delivery now succeeds on a permissionless retry: a real, paid, settled draw.
        pool.retryNFTDelivery(ord);
        (,,,,,,, IFWAClone.ListingStatus s1) = pool.listings(ord);
        assertEq(uint8(s1), uint8(IFWAClone.ListingStatus.Settled), "delivery completed -> Settled/Fulfilled");

        // Booking again cannot revisit the sequence (bookedSequence already advanced),
        // so this settled paid draw never advances the featured decay schedule.
        vm.prank(keeperBot);
        game.book(10);
        assertEq(game.drawsBooked(), 0, "settled paid draw remains uncredited to decay");
        assertEq(_featuredDraws(), drawsBefore, "decay still not advanced for the now-Fulfilled draw");
    }
}
