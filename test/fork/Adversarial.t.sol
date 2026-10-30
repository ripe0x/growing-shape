// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GameBase} from "./GameBase.sol";
import {GrowingShape} from "../../src/GrowingShape.sol";
import {IFWAClone} from "../../src/interfaces/IFWA.sol";
import {Params} from "../../script/Params.sol";

/// @dev A keeper whose ETH receipt tries to re-enter maintenance.
contract ReentrantKeeper {
    GrowingShape internal immutable game;
    bool public reentered;

    constructor(GrowingShape g) {
        game = g;
    }

    function run() external {
        game.book(50);
    }

    receive() external payable {
        try game.book(50) {
            reentered = true;
        } catch {}
    }
}

/// @notice Administrative bounds, attempted owner extraction, keeper-reward abuse and custody edges.
contract AdversarialForkTest is GameBase {
    address internal mallory = makeAddr("mallory");

    function setUp() public override {
        super.setUp();
        if (mallory.code.length != 0) vm.etch(mallory, "");
    }

    function _gameParams() internal pure override returns (GrowingShape.GameParams memory p) {
        p = Params.game();
        p.markupBps = 20_000;
    }

    /* ---------------------------- authority ----------------------------- */

    function test_everyAdminFunctionIsOwnerOnly() public {
        GrowingShape.GameParams memory gp = Params.game();
        GrowingShape.KeeperParams memory kp = Params.keeper();
        vm.startPrank(mallory);
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.openPool("x");
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.setGameParams(gp);
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.setKeeperParams(kp);
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.addTier(GrowingShape.TierInput(0.01 ether, 0, 1));
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.setTierTarget(0, 1);
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.setPaused(true);
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.setGrowthPaused(true);
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.retire();
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.transferOwnership(mallory);
        vm.expectRevert(GrowingShape.Unauthorized.selector);
        game.acceptOwnership();
        vm.stopPrank();
    }

    function test_ownershipTransferIsTwoStep() public {
        vm.prank(owner);
        game.transferOwnership(mallory);
        assertEq(game.owner(), owner);
        vm.prank(mallory);
        game.acceptOwnership();
        assertEq(game.owner(), mallory);
        assertEq(game.pendingOwner(), address(0));
    }

    function test_gameParamBounds() public {
        GrowingShape.GameParams memory ok = Params.game();
        GrowingShape.GameParams[] memory bad = new GrowingShape.GameParams[](16);
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = Params.game();
        }
        bad[0].markupBps = 9_999; // below cost: players could profit on ordinary prizes
        bad[1].markupBps = 20_001;
        bad[2].startNotionalBps = 4_999;
        bad[3].startNotionalBps = 10_001;
        bad[4].floorBps = 499;
        bad[5].floorBps = 10_001;
        bad[6].resetShareBps = 1_999;
        bad[7].resetShareBps = 10_001;
        bad[8].repriceStepBps = 99;
        bad[9].repriceStepBps = 5_001;
        bad[10].decayPpm = 5_001;
        bad[11].maxPendingDraws = 0;
        bad[12].maxPendingDraws = 101;
        bad[13].seedIndex = 1;
        bad[14].seedIndex = 5;
        bad[15].reserveTarget = 20 ether + 1;
        vm.startPrank(owner);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(GrowingShape.BadParams.selector);
            game.setGameParams(bad[i]);
        }
        game.setGameParams(ok);
        vm.stopPrank();
    }

    function test_keeperParamBounds() public {
        GrowingShape.KeeperParams[] memory bad = new GrowingShape.KeeperParams[](7);
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = Params.keeper();
        }
        bad[0].perDraw = 0.005 ether + 1;
        bad[1].budgetCap = 0.5 ether + 1;
        bad[2].flatReward = 0.002 ether + 1;
        bad[3].flatInterval = 59;
        bad[4].gasOverhead = 100_001;
        bad[5].gasPriceCap = 200 gwei + 1;
        bad[6].priorityCap = 10 gwei + 1;
        vm.startPrank(owner);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(GrowingShape.BadParams.selector);
            game.setKeeperParams(bad[i]);
        }
        vm.stopPrank();
    }

    function test_tierBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(GrowingShape.BadTier.selector);
        game.addTier(GrowingShape.TierInput(0.5 ether, 0, 1)); // featured-sized ordinary prize
        vm.expectRevert(GrowingShape.BadTier.selector);
        game.addTier(GrowingShape.TierInput(0.02 ether, 0, 1)); // not a Shapes denomination
        vm.expectRevert(GrowingShape.BadTier.selector);
        game.addTier(GrowingShape.TierInput(0.05 ether, 4, 1)); // pack backing must be packShapes * 0.01
        vm.expectRevert(GrowingShape.BadTier.selector);
        game.setTierTarget(0, 200); // board above 240
        vm.stopPrank();
    }

    /// @dev The owner uses every lever at its most extreme legal setting and every pool entrypoint
    ///      directly. None moves value to the owner; the pool rejects the owner outright.
    function test_ownerCannotReachAssets() public {
        _play(40);
        uint256 ownerEth = owner.balance;
        GrowingShape.GameParams memory gp = Params.game();
        gp.markupBps = 10_000;
        gp.decayPpm = 5_000;
        gp.floorBps = 500;
        gp.resetShareBps = 2_000;
        gp.reserveTarget = 0;
        GrowingShape.KeeperParams memory kp = GrowingShape.KeeperParams({
            perDraw: 0.005 ether,
            budgetCap: 0.5 ether,
            flatReward: 0.002 ether,
            flatInterval: 60,
            gasOverhead: 100_000,
            gasPriceCap: 200 gwei,
            priorityCap: 10 gwei
        });
        uint256 listingId = _featuredListing();
        vm.startPrank(owner);
        game.setGameParams(gp);
        game.setKeeperParams(kp);
        game.setPaused(true);
        game.setGrowthPaused(true);
        game.setTierTarget(0, 0);
        // The pool is owned by the game; the owner's address has no standing there.
        vm.expectRevert();
        pool.withdrawListing(listingId);
        vm.expectRevert();
        pool.updatePrice(listingId, 1);
        vm.expectRevert();
        pool.withdrawOwnerProceeds();
        vm.expectRevert();
        pool.setPurchaseOperator(address(0));
        vm.expectRevert();
        pool.retirePool();
        vm.stopPrank();
        assertEq(owner.balance, ownerEth);
        uint256 featuredId;
        (featuredId,,,,,,,,,,,,,) = game.featured();
        assertEq(SHAPES.ownerOf(featuredId), address(pool));
        // Featured economics changed only for the next reset; the live schedule is the snapshot.
        (,,,,,,, uint96 decayPerDraw,,,,,,) = game.featured();
        assertEq(decayPerDraw, uint96(uint256(_featuredBacking()) * 377 / 1e6));
        _assertIdentity();
    }

    /* ------------------------- keeper compensation ----------------------- */

    function test_noRewardWithoutWork() public {
        vm.prank(keeperBot);
        game.book(10); // nothing to settle, book or collect
        assertEq(game.keeperPaid(), 0);
        vm.prank(keeperBot);
        vm.expectRevert(GrowingShape.NotDue.selector);
        game.publishDecay();
        vm.prank(keeperBot);
        vm.expectRevert(GrowingShape.NotDue.selector);
        game.compose();
        vm.prank(keeperBot);
        vm.expectRevert(GrowingShape.FeaturedActive.selector);
        game.startCycle();
    }

    function test_rewardCappedByGasPriceFlatIntervalAndBudget() public {
        _fulfillAll(_tryBuy(alice, 5));
        vm.fee(1 gwei);
        vm.txGasPrice(500 gwei);
        uint256 before = keeperBot.balance;
        vm.prank(keeperBot);
        game.book(50);
        uint256 paid = keeperBot.balance - before;
        assertGt(paid, 0);
        // At most budget accrued by the five draws: 5 * perDraw.
        assertLe(paid, 5 * Params.keeper().perDraw);
        // A second useful call in the same interval earns no flat reward, and an exhausted budget pays nothing.
        assertEq(game.keeperBudget(), 5 * Params.keeper().perDraw - paid);
        _fulfillAll(_tryBuy(alice, 1));
        before = keeperBot.balance;
        vm.txGasPrice(1 gwei);
        vm.prank(keeperBot);
        game.book(50);
        uint256 second = keeperBot.balance - before;
        assertLe(second, (400_000 + 30_000) * 2 gwei, "no flat reward within the interval");
    }

    function test_keeperCannotReenterThroughRewardReceipt() public {
        ReentrantKeeper k = new ReentrantKeeper(game);
        _fulfillAll(_tryBuy(alice, 5));
        uint256 booked = game.bookedSequence();
        k.run();
        assertFalse(k.reentered());
        assertGt(game.bookedSequence(), booked);
        _assertIdentity();
    }

    /* ------------------------------ custody ------------------------------ */

    function test_rejectsStrayEthAndNfts() public {
        vm.deal(mallory, 1 ether);
        vm.prank(mallory);
        (bool ok,) = address(game).call{value: 0.1 ether}("");
        assertFalse(ok, "plain ETH from a stranger");
        vm.prank(mallory);
        uint256 id = SHAPES.mintBatch{value: 0.011 ether}(0.01 ether, 1);
        vm.prank(mallory);
        (ok,) = address(SHAPES).call(
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", mallory, address(game), id)
        );
        assertFalse(ok, "unsolicited Shape");
        assertEq(SHAPES.ownerOf(id), mallory);
    }

    function test_composeRefusesWhileAFeaturedWinIsUnbooked() public {
        uint256 guard;
        while (!game.compositionDue()) {
            _fulfillAll(_tryBuy(alice, 5));
            vm.startPrank(keeperBot);
            game.book(100);
            if (game.replacementDue() != 0) game.replenish(20);
            try game.publishDecay() {} catch {}
            vm.stopPrank();
            require(++guard < 300, "never due");
        }
        // Purchases are paused now; force one in-flight win that was requested just before the pause.
        vm.prank(owner);
        game.setGrowthPaused(true);
        uint256 featuredId;
        (featuredId,,,,,,,,,,,,,) = game.featured();
        _winFeatured(alice);
        vm.prank(owner);
        game.setGrowthPaused(false);
        assertEq(SHAPES.ownerOf(featuredId), alice);
        vm.prank(keeperBot);
        vm.expectRevert(GrowingShape.NotBooked.selector);
        game.compose();
        vm.prank(keeperBot);
        game.book(10);
        assertEq(game.cycleCount(), 1);
        vm.prank(keeperBot);
        vm.expectRevert(GrowingShape.NotDue.selector);
        game.compose();
        _assertIdentity();
    }

    function test_growthPauseReopensPurchasesWhenCompositionCannotRun() public {
        uint256 guard;
        while (!game.compositionDue()) {
            _fulfillAll(_tryBuy(alice, 5));
            vm.startPrank(keeperBot);
            game.book(100);
            if (game.replacementDue() != 0) game.replenish(20);
            try game.publishDecay() {} catch {}
            vm.stopPrank();
            require(++guard < 300, "never due");
        }
        assertFalse(game.canPurchase(alice));
        vm.prank(owner);
        game.setGrowthPaused(true);
        assertTrue(game.canPurchase(alice));
        assertGt(game.growthFund(), 0);
    }
}
