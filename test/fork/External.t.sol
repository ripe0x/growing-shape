// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GameBase} from "./GameBase.sol";
import {GrowingShape} from "../../src/GrowingShape.sol";
import {IFWAClone} from "../../src/interfaces/IFWA.sol";
import {Params} from "../../script/Params.sol";

/// @notice FWA outcomes and governance changes outside the game's control: settlement-time slippage
///         refunds, a non-zero inventory cooldown, and factory withdraw-only / purchase switches.
contract ExternalForkTest is GameBase {
    function _gameParams() internal pure override returns (GrowingShape.GameParams memory p) {
        p = Params.game();
        p.markupBps = 20_000;
    }

    function _buyWithTolerance(address buyer, uint256 negBps) internal returns (uint256 id) {
        (,, uint256 total) = pool.quoteAcquisitionPrice(1);
        vm.deal(buyer, buyer.balance + total);
        uint256 version = pool.inventoryVersion();
        vm.prank(buyer);
        id = pool.acquire{value: total}(buyer, 0, 0, negBps, version, block.timestamp + 600);
    }

    /// @dev An earlier draw takes a 0.1 ETH prize, lowering the fee; a later buyer with zero negative
    ///      tolerance is refunded by FWA. The refund must book nothing.
    function test_slippageRefundBooksNothing() public {
        uint256 first = _buyWithTolerance(alice, 1000);
        uint256 second = _buyWithTolerance(owner, 0);
        uint256 big;
        for (uint256 id = 1; id < 120 && big == 0; ++id) {
            (address c,,, uint256 tokenId,,,, IFWAClone.ListingStatus s) = pool.listings(id);
            if (c == address(SHAPES) && s == IFWAClone.ListingStatus.Active && SHAPES.backingOf(tokenId) == 0.1 ether) {
                big = id;
            }
        }
        _fulfill(first, _wordFor(big));
        _fulfill(second, 1);
        (,,,, IFWAClone.AcquisitionStatus st) = pool.acquisitions(second);
        assertEq(uint8(st), uint8(IFWAClone.AcquisitionStatus.Refunded));
        uint256 live = game.liveOrdinary();
        vm.prank(keeperBot);
        game.book(10);
        assertEq(game.liveOrdinary(), live - 1, "only the first draw consumed a prize");
        assertEq(game.drawsBooked(), 1);
        assertGt(pool.acquisitionRefundCredit(owner), 0);
        _assertIdentity();
    }

    /// @dev With a factory cooldown, each inventory change blocks purchases for that long; the game keeps
    ///      working and buying resumes after it.
    function test_inventoryCooldownDelaysButDoesNotBreakPlay() public {
        vm.mockCall(address(FACTORY), abi.encodeWithSignature("inventoryChangeCooldown()"), abi.encode(uint256(300)));
        _fulfillAll(_tryBuy(alice, 3));
        vm.startPrank(keeperBot);
        game.book(10);
        game.replenish(20); // an inventory change: cooldown restarts
        vm.stopPrank();
        assertEq(_tryBuy(alice, 1).length, 0, "blocked during cooldown");
        vm.warp(block.timestamp + 301);
        assertEq(_tryBuy(alice, 1).length, 1, "resumes after cooldown");
        vm.clearMockedCalls();
    }

    /// @dev Factory withdraw-only blocks relisting, so composition must wait with the Shape listed and the
    ///      growth fund intact; when lifted, it proceeds.
    function test_withdrawOnlyMakesCompositionWait() public {
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
        uint256 growth = game.growthFund();
        uint256 listingId = _featuredListing();
        vm.mockCall(address(FACTORY), abi.encodeWithSignature("globalWithdrawOnly()"), abi.encode(true));
        vm.prank(keeperBot);
        vm.expectRevert();
        game.compose();
        assertEq(game.growthFund(), growth);
        assertEq(_featuredListing(), listingId);
        (,,,,,,, IFWAClone.ListingStatus s) = pool.listings(listingId);
        assertEq(uint8(s), uint8(IFWAClone.ListingStatus.Active), "still listed");
        vm.clearMockedCalls();
        vm.prank(keeperBot);
        game.compose();
        assertEq(_featuredBacking(), 1 ether);
        _assertIdentity();
    }

    /// @dev Global purchase switch off: FWA refuses buys; the game's maintenance still runs.
    function test_factoryPurchasesDisabledOnlyStopsBuying() public {
        _fulfillAll(_tryBuy(alice, 2));
        vm.mockCall(address(FACTORY), abi.encodeWithSignature("globalPurchasesEnabled()"), abi.encode(false));
        assertEq(_tryBuy(alice, 1).length, 0);
        vm.prank(keeperBot);
        game.book(10);
        vm.prank(keeperBot);
        game.replenish(20);
        assertEq(game.replacementDue(), 0);
        vm.clearMockedCalls();
        assertEq(_tryBuy(alice, 1).length, 1);
    }
}
