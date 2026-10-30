// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {GameBase} from "../fork/GameBase.sol";
import {GrowingShape} from "../../src/GrowingShape.sol";
import {IFWAClone, IFWAVRFService} from "../../src/interfaces/IFWA.sol";
import {IShapes} from "../../src/interfaces/IShapes.sol";
import {Addresses} from "../../script/Addresses.sol";
import {Params} from "../../script/Params.sol";

/// @notice Random players, VRF outcomes (on time, late, never, or aimed at the featured Shape), block and
///         time movement, keepers acting in any order, and owner parameter changes within bounds.
contract Handler is Test {
    GrowingShape internal immutable game;
    IFWAClone internal immutable pool;
    address internal immutable keeperBot;
    address internal immutable owner;
    address[3] internal players;
    uint256[] internal pending;
    uint256 public calls;
    uint256 public fullyBookedChecks;
    uint256 public expired;
    uint256 public aimed;

    constructor(GrowingShape g, address keeper_, address owner_) {
        game = g;
        pool = g.pool();
        keeperBot = keeper_;
        owner = owner_;
        players = [address(0xA11CE1), address(0xB0B2), address(0xCA703)];
    }

    /// @dev Buys and, three times in four, resolves every pending request at once.
    function buy(uint256 who, uint256 count) external {
        _buy(who, count);
        if (who % 4 != 0) _fulfillAll(who ^ count);
        vm.startPrank(keeperBot);
        if (count % 3 == 0) try game.book(60) {} catch {}
        if (count % 7 == 0) try game.replenish(20) {} catch {}
        vm.stopPrank();
    }

    function _buy(uint256 who, uint256 count) internal {
        ++calls;
        address p = players[who % 3];
        count = bound(count, 1, 5);
        (,, uint256 total) = pool.quoteAcquisitionPrice(count);
        vm.deal(p, total);
        uint256 version = pool.inventoryVersion();
        vm.prank(p);
        try pool.acquireBatch{value: total}(p, count, 0, 0, 1000, version, block.timestamp + 600) returns (
            uint256[] memory ids
        ) {
            for (uint256 i; i < ids.length; ++i) {
                pending.push(ids[i]);
            }
        } catch {}
    }

    /// @dev Resolves every pending request. Per request, mode 0-5: random word; 6: aim at the featured
    ///      Shape; 7: never answered (expires after FWA's 30-block deadline).
    function fulfill(uint256 seed) external {
        _fulfillAll(seed);
    }

    /// @dev In sequence order, so a word aimed at a listing is evaluated against the pool it was aimed at.
    function _fulfillAll(uint256 seed) internal {
        ++calls;
        vm.roll(block.number + 3);
        bool expireSome;
        for (uint256 k; k < pending.length; ++k) {
            uint256 id = pending[k];
            uint256 mode = uint256(keccak256(abi.encode(seed, id))) % 8;
            if (mode == 7) {
                expireSome = true;
                ++expired;
                continue;
            }
            uint256 word = uint256(keccak256(abi.encode(seed, id, "w")));
            (, uint256 listingId,,,,,,,,,,,,) = game.featured();
            if (mode == 6 && listingId != 0) {
                word = _wordFor(listingId);
                ++aimed;
            }
            uint256[] memory words = new uint256[](1);
            words[0] = word;
            vm.prank(Addresses.CHAINLINK_COORDINATOR);
            Addresses.VRF_SERVICE.rawFulfillRandomWords(id, words);
        }
        delete pending;
        if (expireSome) vm.roll(block.number + 31);
    }

    function keep(uint256 action, uint256 n) external {
        ++calls;
        action = action % 5;
        vm.startPrank(keeperBot);
        if (action == 0) {
            try game.book(bound(n, 1, 60)) {} catch {}
            if (pool.nextSequenceToProcess() - 1 == game.bookedSequence()) _checkBijection();
        } else if (action == 1) {
            try game.replenish(bound(n, 1, 20)) {} catch {}
        } else if (action == 2) {
            try game.startCycle() {} catch {}
        } else if (action == 3) {
            try game.compose() {} catch {}
        } else {
            try game.publishDecay() {} catch {}
        }
        vm.stopPrank();
    }

    function passTime(uint256 blocks, uint256 secs) external {
        ++calls;
        vm.roll(block.number + bound(blocks, 1, 40));
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }

    function tune(uint256 seed) external {
        ++calls;
        GrowingShape.GameParams memory p = Params.game();
        p.markupBps = uint16(bound(seed, 10_000, 20_000));
        p.decayPpm = uint32(bound(seed >> 16, 0, 5_000));
        p.floorBps = uint16(bound(seed >> 32, 500, 10_000));
        p.resetShareBps = uint16(bound(seed >> 48, 2_000, 10_000));
        vm.prank(owner);
        try game.setGameParams(p) {} catch {}
    }

    /// @dev With every processed request booked, the game's live prizes are exactly the pool's listings
    ///      that are Active or Staged.
    function _checkBijection() internal {
        ++fullyBookedChecks;
        uint256 n = _nextListingId();
        uint256 liveSeen;
        for (uint256 id = 1; id < n; ++id) {
            (bool featured, bool live) = _prize(id);
            (,,,,,,, IFWAClone.ListingStatus s) = pool.listings(id);
            bool inPool = s == IFWAClone.ListingStatus.Active || s == IFWAClone.ListingStatus.Staged;
            assertEq(live, inPool, "live prize <-> listed in pool");
            if (live && !featured) ++liveSeen;
        }
        assertEq(liveSeen, game.liveOrdinary(), "liveOrdinary");
    }

    function _prize(uint256 id) internal view returns (bool featured, bool live) {
        (, featured, live,,) = game.prizes(id);
    }

    function _nextListingId() internal view returns (uint256 n) {
        (bool ok, bytes memory r) = address(pool).staticcall(abi.encodeWithSignature("nextListingId()"));
        require(ok);
        n = abi.decode(r, (uint256));
    }

    function _wordFor(uint256 listingId) internal view returns (uint256) {
        (,,,, uint256 weight,, uint256 slot,) = pool.listings(listingId);
        uint256 before;
        for (uint256 s = 1; s < slot; ++s) {
            uint256 id = pool.slotToListing(s);
            if (id == 0) continue;
            (,,,, uint256 w,,, IFWAClone.ListingStatus st) = pool.listings(id);
            if (st == IFWAClone.ListingStatus.Active) before += w;
        }
        return before + weight / 2;
    }
}

contract GameInvariantsTest is GameBase {
    Handler internal handler;

    function _gameParams() internal pure override returns (GrowingShape.GameParams memory p) {
        p = Params.game();
        p.markupBps = 20_000; // compositions within a run
    }

    function setUp() public override {
        super.setUp();
        handler = new Handler(game, keeperBot, owner);
        targetContract(address(handler));
    }

    function invariant_accountingIdentity() public view {
        _assertIdentity();
    }

    function invariant_featuredCustodyAndPrice() public view {
        (uint256 tokenId, uint256 listingId,,, uint96 backing, uint96 notional,,, uint96 floor,,,,,) = game.featured();
        // A settled but unbooked win leaves the featured record stale until `book`; the game refuses to
        // compose or reprice in that window (NotBooked), so check custody only when fully booked.
        if (listingId == 0 || pool.nextSequenceToProcess() - 1 != game.bookedSequence()) return;
        assertEq(SHAPES.ownerOf(tokenId), address(pool), "featured in escrow");
        assertEq(SHAPES.backingOf(tokenId), backing, "backing");
        (,,,,, uint256 price,,) = pool.listings(listingId);
        assertEq(price, notional, "published notional is the FWA price");
        assertGe(notional, floor, "floor");
        assertLe(notional, backing, "notional <= backing");
    }

    function invariant_fundsAndCounters() public view {
        assertLe(game.growthFund(), address(game).balance, "growth fund backed by ETH");
        assertLe(game.keeperBudget(), Params.keeper().budgetCap, "budget cap");
        uint256 sum;
        for (uint256 i; i < game.tierCount(); ++i) {
            sum += game.tier(i).live;
        }
        assertEq(sum, game.liveOrdinary(), "tier live counts");
        assertLe(game.bookedSequence(), pool.nextSequenceToProcess() - 1, "never books ahead of FWA");
        assertEq(pool.owner(), address(game));
        assertEq(pool.purchaseOperator(), address(game));
    }

    /// @dev Evidence that a run reached the states it claims to cover.
    function afterInvariant() external view {
        (,,,,,,,,,, uint16 compositions,,,) = game.featured();
        console2.log("cycles won", game.cycleCount(), "current compositions", compositions);
        console2.log("draws booked", game.drawsBooked(), "expired", handler.expired());
        console2.log("aimed at featured", handler.aimed(), "bijection checks", handler.fullyBookedChecks());
    }
}
