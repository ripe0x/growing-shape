// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {GameBase} from "./GameBase.sol";
import {GrowingShape} from "../../src/GrowingShape.sol";
import {Params} from "../../script/Params.sol";

/// @notice Gas of every player and keeper operation on the real stack. Figures feed docs/ECONOMICS.md.
/// @dev Measured as execution gas inside the test (no intrinsic 21k or calldata); add those for a
///      transaction estimate. Run with -vv to print.
contract GasForkTest is GameBase {
    function _gameParams() internal pure override returns (GrowingShape.GameParams memory p) {
        p = Params.game();
        p.markupBps = 20_000; // fast growth so compositions arrive within the test
    }

    function _measure(string memory label, uint256 g) internal view returns (uint256 used) {
        used = g - gasleft();
        console2.log(label, used);
    }

    function test_gas_operations() public {
        uint256 version = pool.inventoryVersion();
        (,, uint256 total1) = pool.quoteAcquisitionPrice(1);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 id = pool.acquire{value: total1}(alice, 0, 0, 1000, version, block.timestamp + 60);
        _measure("player acquire(1)", g);

        uint256[] memory words = new uint256[](1);
        words[0] = 12345;
        vm.roll(block.number + 3);
        vm.prank(CHAINLINK_COORDINATOR);
        g = gasleft();
        VRF_SERVICE.rawFulfillRandomWords(id, words);
        _measure("VRF callback incl. settle+deliver", g);

        (,, uint256 total5) = pool.quoteAcquisitionPrice(5);
        version = pool.inventoryVersion();
        vm.prank(alice);
        g = gasleft();
        uint256[] memory ids = pool.acquireBatch{value: total5}(alice, 5, 0, 0, 1000, version, block.timestamp + 60);
        _measure("player acquireBatch(5)", g);
        _fulfillAll(ids);

        vm.prank(keeperBot);
        g = gasleft();
        game.book(1);
        _measure("keeper book(1) incl. collect", g);
        vm.prank(keeperBot);
        g = gasleft();
        game.book(5);
        _measure("keeper book(5) incl. collect", g);

        g = gasleft();
        game.canPurchase(alice);
        _measure("canPurchase (FWA stipend 100k)", g);

        vm.prank(keeperBot);
        g = gasleft();
        game.replenish(6);
        _measure("keeper replenish(6 replacements)", g);

        _play(200);
        // publishDecay when due
        if (game.desiredNotional() * 10_000 <= _featuredNotional() * 9_500) {
            vm.prank(keeperBot);
            g = gasleft();
            game.publishDecay();
            _measure("keeper publishDecay", g);
        }
        uint256 guard;
        while (_featuredBacking() < 5 ether && guard++ < 60) {
            _playUntilDue();
            uint256 b = _featuredBacking();
            vm.prank(keeperBot);
            g = gasleft();
            game.compose();
            _measure(b == 0.5 ether ? "keeper compose 0.5->1" : "keeper compose 1->5", g);
        }
        assertEq(_featuredBacking(), 5 ether);

        _winFeatured(alice);
        vm.prank(keeperBot);
        game.book(10);
        while (game.replacementDue() != 0) {
            vm.prank(keeperBot);
            game.replenish(20);
        }
        vm.prank(keeperBot);
        g = gasleft();
        game.startCycle();
        _measure("keeper startCycle", g);

        // A full board refill of 20.
        GrowingShape fresh = _deploy(Params.game(), Params.tiers());
        deal(FWA_TOKEN, address(fresh), FACTORY.poolCreationFee());
        vm.prank(owner);
        fresh.openPool("gas");
        fresh.fund{value: 4.2 ether}();
        vm.prank(keeperBot);
        g = gasleft();
        fresh.replenish(20);
        _measure("replenish(20 x 0.01 Shapes)", g);
        vm.prank(keeperBot);
        fresh.replenish(20);
        vm.prank(keeperBot);
        g = gasleft();
        fresh.replenish(20);
        _measure("replenish(10 x 0.01 + 10 packs)", g);
    }

    function _playUntilDue() internal {
        uint256 guard;
        while (!game.compositionDue()) {
            uint256[] memory ids = _tryBuy(alice, 5);
            _fulfillAll(ids);
            vm.startPrank(keeperBot);
            game.book(100);
            if (game.replacementDue() != 0) game.replenish(20);
            try game.publishDecay() {} catch {}
            vm.stopPrank();
            require(++guard < 400, "never due");
        }
    }
}
