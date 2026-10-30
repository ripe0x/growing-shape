// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IShapes} from "../../src/interfaces/IShapes.sol";
import {IShapePacks} from "../../src/interfaces/IShapePacks.sol";
import {IFWAFactory, IFWAClone, IFWAVRFService} from "../../src/interfaces/IFWA.sol";
import {Addresses} from "../../script/Addresses.sol";

/// @notice Mainnet fork against the real Shapes, Draw Packs and FWA V2 contracts.
/// @dev FORK_BLOCK defaults to the block the addresses below were verified at. VRF is fulfilled by
///      pranking the Chainlink VRF v2.5 coordinator into the FWA VRF service, so the service's own
///      routing and gas stipend run exactly as on mainnet.
abstract contract ForkBase is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 26_305_681;

    IShapes internal constant SHAPES = Addresses.SHAPES;
    IShapePacks internal constant PACKS = Addresses.PACKS;
    IFWAFactory internal constant FACTORY = Addresses.FACTORY;
    address internal constant FWA_IMPLEMENTATION = Addresses.FWA_IMPLEMENTATION;
    IFWAVRFService internal constant VRF_SERVICE = Addresses.VRF_SERVICE;
    address internal constant CHAINLINK_COORDINATOR = Addresses.CHAINLINK_COORDINATOR;
    address internal constant FWA_TOKEN = Addresses.FWA_TOKEN;

    function setUp() public virtual {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        vm.txGasPrice(1 gwei);
    }

    /// @dev Delivers `word` for `requestId` along the production path: coordinator -> service -> pool.
    function _fulfill(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.roll(block.number + 3);
        vm.prank(CHAINLINK_COORDINATOR);
        VRF_SERVICE.rawFulfillRandomWords(requestId, words);
    }

    function _vrfFee() internal view returns (uint256) {
        return VRF_SERVICE.requestFee();
    }

    /// @dev Buys one draw on `pool` for `buyer` at the live quote, 10% negative slippage, current version.
    function _buy(IFWAClone pool, address buyer) internal returns (uint256 requestId) {
        (,, uint256 total) = pool.quoteAcquisitionPrice(1);
        vm.deal(buyer, buyer.balance + total);
        vm.prank(buyer);
        requestId = pool.acquire{value: total}(buyer, 0, 0, 1000, pool.inventoryVersion(), block.timestamp + 600);
    }
}
