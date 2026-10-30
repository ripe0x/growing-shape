// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {GrowingShape} from "../src/GrowingShape.sol";
import {IFWAClone} from "../src/interfaces/IFWA.sol";
import {Addresses} from "./Addresses.sol";
import {Params} from "./Params.sol";

/// @notice Step 1: deploy GrowingShape with the opening configuration in `Params`.
/// @dev Env: GS_OWNER, GS_RESIDUAL_RECIPIENT. Refuses chains other than mainnet (1) and a local
///      mainnet fork (31337), and refuses if any dependency's runtime code differs from the reviewed one.
contract Deploy is Script {
    bytes32 internal constant FACTORY_CODEHASH = 0x7defffa3d081aef4ac1739a0dde22f38f191e89c6db225d9589b54c07cd29c3d;
    bytes32 internal constant IMPLEMENTATION_CODEHASH =
        0x84dee03dd3af8ee9fb96df379991b881988526db09cb7e294c136fedf9a011c5;

    function run() external returns (GrowingShape game) {
        require(block.chainid == 1 || block.chainid == 31337, "unsupported chain");
        address owner = vm.envAddress("GS_OWNER");
        address residual = vm.envAddress("GS_RESIDUAL_RECIPIENT");
        require(owner != address(0) && residual != address(0), "owner and residual recipient required");
        checkDependencies();

        vm.startBroadcast();
        game = new GrowingShape(
            owner,
            Addresses.SHAPES,
            Addresses.PACKS,
            Addresses.FACTORY,
            Addresses.FWA_IMPLEMENTATION,
            residual,
            Params.game(),
            Params.keeper(),
            Params.tiers()
        );
        vm.stopBroadcast();

        console2.log("GrowingShape", address(game));
        string memory json = vm.serializeAddress("d", "growingShape", address(game));
        json = vm.serializeAddress("d", "owner", owner);
        json = vm.serializeAddress("d", "residualRecipient", residual);
        json = vm.serializeUint("d", "deployBlock", block.number);
        string memory path = vm.envOr(
            "GS_DEPLOYMENT_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json")
        );
        vm.writeJson(json, path);
    }

    function checkDependencies() public view {
        require(address(Addresses.FACTORY).codehash == FACTORY_CODEHASH, "FWA factory code changed");
        require(Addresses.FWA_IMPLEMENTATION.codehash == IMPLEMENTATION_CODEHASH, "FWA clone code changed");
        require(Addresses.FACTORY.implementation() == Addresses.FWA_IMPLEMENTATION, "FWA implementation rotated");
        require(Addresses.FACTORY.fwaToken() == Addresses.FWA_TOKEN, "FWA token changed");
        require(address(Addresses.SHAPES).code.length != 0 && address(Addresses.PACKS).code.length != 0, "no Shapes");
        require(Addresses.PACKS.MIN_PACK_VALUE() <= 0.03 ether, "pack minimum changed");
        require(Addresses.SHAPES.mintFee() <= 0.002 ether, "mint fee above modelled range");
    }
}

/// @notice Step 2, run by the owner once 50,000 FWA (the live creation fee) has been sent to the game:
///         open the pool, fund capital, list the board and the first featured Shape. Purchases stay
///         paused until the owner calls `setPaused(false)` after `Postflight` passes.
/// @dev Env: GS_GAME, GS_CAPITAL_WEI (defaults to Params.CAPITAL).
contract Launch is Script {
    function run() external {
        GrowingShape game = GrowingShape(payable(vm.envAddress("GS_GAME")));
        uint256 capital = vm.envOr("GS_CAPITAL_WEI", Params.CAPITAL);
        vm.startBroadcast();
        if (address(game.pool()) == address(0)) game.openPool(keccak256("growing-shape"));
        if (game.capitalIn() == 0) game.fund{value: capital}();
        for (uint256 i; i < 10 && game.replacementDue() != 0; ++i) {
            game.replenish(20);
        }
        (, uint256 listingId,,,,,,,,,,,,) = game.featured();
        if (listingId == 0) game.startCycle();
        vm.stopBroadcast();
    }
}

/// @notice Step 3: read-only postflight. Reverts on the first failed check.
/// @dev Env: GS_GAME, GS_OWNER, GS_RESIDUAL_RECIPIENT.
contract Postflight is Script {
    function run() external view {
        GrowingShape game = GrowingShape(payable(vm.envAddress("GS_GAME")));
        IFWAClone pool = game.pool();
        require(game.owner() == vm.envAddress("GS_OWNER"), "owner");
        require(game.RESIDUAL_RECIPIENT() == vm.envAddress("GS_RESIDUAL_RECIPIENT"), "residual recipient");
        require(address(game.SHAPES()) == address(Addresses.SHAPES), "shapes");
        require(address(game.PACKS()) == address(Addresses.PACKS), "packs");
        require(address(game.FACTORY()) == address(Addresses.FACTORY), "factory");
        require(address(pool) != address(0), "pool not open");
        require(pool.owner() == address(game), "pool owner");
        require(pool.purchaseOperator() == address(game), "purchase operator");
        require(pool.localPurchasesEnabled(), "acquisitions disabled");
        require(!pool.retired(), "pool retired");
        require(game.replacementDue() == 0, "board incomplete");
        (uint256 tokenId, uint256 listingId,,, uint96 backing, uint96 notional,,,,,,,,) = game.featured();
        require(listingId != 0 && game.cycle() == 1, "featured not listed");
        require(Addresses.SHAPES.ownerOf(tokenId) == address(pool), "featured not escrowed");
        (,,,,, uint256 price,,) = pool.listings(listingId);
        require(price == notional && backing == Addresses.SHAPES.backingOf(tokenId), "featured mismatch");
        require(game.operating() >= game.requiredLiquid() - game.replacementDue(), "reserve below target");
        require(game.surplus() == 0 && game.growthFund() == 0 && game.revenue() == 0, "fresh ledger");
        console2.log("postflight ok; paused =", game.paused());
        console2.log("pool", address(pool));
        console2.log("operating wei", game.operating());
        console2.log("inventory cost wei", game.inventoryCost());
    }
}
