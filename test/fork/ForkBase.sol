// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IShapes} from "../../src/interfaces/IShapes.sol";
import {IShapePacks} from "../../src/interfaces/IShapePacks.sol";
import {IFWAFactory, IFWAClone, IFWAVRFService} from "../../src/interfaces/IFWA.sol";

/// @notice Mainnet fork against the real Shapes, Draw Packs and FWA V2 contracts.
/// @dev FORK_BLOCK defaults to the block the addresses below were verified at. VRF is fulfilled by
///      pranking the Chainlink VRF v2.5 coordinator into the FWA VRF service, so the service's own
///      routing and gas stipend run exactly as on mainnet.
abstract contract ForkBase is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 26_305_681;

    IShapes internal constant SHAPES = IShapes(0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0);
    IShapePacks internal constant PACKS = IShapePacks(0xf21514B090Da7dF4390803497d6ae673801E5cA7);
    IFWAFactory internal constant FACTORY = IFWAFactory(0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c);
    address internal constant FWA_IMPLEMENTATION = 0xEaa4d032908A9734a2c7939c0D211c35ad51eb31;
    IFWAVRFService internal constant VRF_SERVICE = IFWAVRFService(0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2);
    address internal constant CHAINLINK_COORDINATOR = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;
    address internal constant FWA_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;

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
