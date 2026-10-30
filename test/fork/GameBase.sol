// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkBase} from "./ForkBase.sol";
import {GrowingShape} from "../../src/GrowingShape.sol";
import {IFWAClone} from "../../src/interfaces/IFWA.sol";
import {Params} from "../../script/Params.sol";

/// @notice A launched Growing Shape on the real mainnet stack, plus a keeper and players.
abstract contract GameBase is ForkBase {
    GrowingShape internal game;
    IFWAClone internal pool;
    address internal owner = makeAddr("owner");
    address internal residual = makeAddr("residual");
    address internal keeperBot = makeAddr("keeperBot");
    address internal alice = makeAddr("alice");
    uint256 internal nonce;

    function setUp() public virtual override {
        super.setUp();
        // Well-known test addresses carry mainnet code (EIP-7702 sweepers forward any ETH they receive).
        // Clear it so balances in assertions are the actors' own.
        address[5] memory actors = [owner, residual, keeperBot, alice, address(this)];
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i].code.length != 0 && actors[i] != address(this)) vm.etch(actors[i], "");
        }
        game = _deploy(_gameParams(), Params.tiers());
        _launch(game, Params.CAPITAL);
        pool = game.pool();
    }

    /// @dev Suites that need many compositions override this with a high markup so growth arrives in
    ///      hundreds of draws instead of thousands. Mechanics are identical; only the rate changes.
    function _gameParams() internal pure virtual returns (GrowingShape.GameParams memory) {
        return Params.game();
    }

    function _deploy(GrowingShape.GameParams memory gp, GrowingShape.TierInput[] memory tiers)
        internal
        returns (GrowingShape g)
    {
        g = new GrowingShape(owner, SHAPES, PACKS, FACTORY, FWA_IMPLEMENTATION, residual, gp, Params.keeper(), tiers);
        // Fork addresses can hold mainnet dust; start from zero so the accounting identity is exact.
        vm.deal(address(g), 0);
    }

    function _launch(GrowingShape g, uint256 capital) internal {
        deal(FWA_TOKEN, address(g), FACTORY.poolCreationFee());
        vm.prank(owner);
        g.openPool(bytes32(uint256(uint160(address(g)))));
        vm.deal(address(this), address(this).balance + capital);
        g.fund{value: capital}();
        while (g.replacementDue() != 0 && g.operating() >= 0.2 ether) {
            vm.prank(keeperBot);
            g.replenish(20);
        }
        vm.prank(keeperBot);
        g.startCycle();
        vm.prank(owner);
        g.setPaused(false);
    }

    /* ------------------------------ players ------------------------------ */

    /// @dev Buys `count` (<= 5) draws for `buyer` at the live quote. Returns request ids, or empty if the
    ///      game's purchase gate or FWA rejected the purchase.
    function _tryBuy(address buyer, uint256 count) internal returns (uint256[] memory ids) {
        (,, uint256 total) = pool.quoteAcquisitionPrice(count);
        vm.deal(buyer, buyer.balance + total);
        uint256 version = pool.inventoryVersion();
        vm.prank(buyer);
        try pool.acquireBatch{value: total}(buyer, count, 0, 0, 1000, version, block.timestamp + 600) returns (
            uint256[] memory r
        ) {
            ids = r;
        } catch {}
    }

    function _fulfillAll(uint256[] memory ids) internal {
        for (uint256 i; i < ids.length; ++i) {
            _fulfill(ids[i], uint256(keccak256(abi.encode(ids[i], ++nonce))));
        }
    }

    /// @dev Plays `draws` successful purchases with random words, running the keeper whenever the gate closes.
    function _play(uint256 draws) internal {
        uint256 done;
        uint256 stuck;
        while (done < draws) {
            uint256 count = draws - done > 5 ? 5 : draws - done;
            uint256[] memory ids = _tryBuy(alice, count);
            if (ids.length == 0) {
                _keep();
                require(++stuck < 5, "gate stayed closed");
                continue;
            }
            stuck = 0;
            _fulfillAll(ids);
            done += ids.length;
            if (done % 25 < 5) _keep();
        }
        _keep();
    }

    /* ------------------------------ keeper ------------------------------- */

    /// @dev What the keeper bot does: book, replenish, start a cycle, compose, publish decay.
    function _keep() internal {
        vm.startPrank(keeperBot);
        if (pool.nextSequenceToProcess() - 1 > game.bookedSequence()) game.book(100);
        if (game.replacementDue() != 0) try game.replenish(20) {} catch {}
        (, uint256 listingId,,,,,,,,,,,,) = game.featured();
        if (listingId == 0) try game.startCycle() {} catch {}
        if (game.compositionDue()) game.compose();
        try game.publishDecay() {} catch {}
        vm.stopPrank();
    }

    /* ---------------------------- selection ------------------------------ */

    /// @dev A VRF word that selects `listingId` in the current pool: FWA picks `word % totalWeight` over
    ///      slot-ordered cumulative weight.
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

    function _featuredListing() internal view returns (uint256 listingId) {
        (, listingId,,,,,,,,,,,,) = game.featured();
    }

    function _featuredBacking() internal view returns (uint256 backing) {
        (,,,, uint96 b,,,,,,,,,) = game.featured();
        backing = b;
    }

    function _featuredNotional() internal view returns (uint256 n) {
        (,,,,, uint96 v,,,,,,,,) = game.featured();
        n = v;
    }

    /// @dev Buys one draw and fulfils it with a word that wins the featured Shape.
    function _winFeatured(address buyer) internal returns (uint256 requestId) {
        uint256 listingId = _featuredListing();
        uint256[] memory ids = _tryBuy(buyer, 1);
        require(ids.length == 1, "buy failed");
        requestId = ids[0];
        _fulfill(requestId, _wordFor(listingId));
    }

    /// @dev balance + inventoryCost + featured cost basis == capital + revenue + recovered - expenses.
    function _assertIdentity() internal view {
        (,, uint256 costBasis,,,,,,,,,,,) = game.featured();
        uint256 lhs = address(game).balance + game.inventoryCost() + (_featuredListing() == 0 ? 0 : costBasis);
        uint256 rhs = game.capitalIn() + game.revenue() + game.recovered() - game.prizeExpense()
            - game.featuredAwarded() - game.keeperPaid();
        assertEq(lhs, rhs, "accounting identity");
    }
}
