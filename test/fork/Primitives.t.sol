// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkBase} from "./ForkBase.sol";
import {IFWAClone, IPurchaseOperator} from "../../src/interfaces/IFWA.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract DenyAll is IPurchaseOperator {
    function canPurchase(address) external pure returns (bool) {
        return false;
    }
}

/// @notice Phase 0: the primitives Growing Shape depends on, exercised on the real mainnet contracts.
///         This test contract plays the pool owner directly, without any Growing Shape code.
contract PrimitivesForkTest is ForkBase {
    IFWAClone internal pool;
    address internal buyer = makeAddr("buyer");
    uint256 internal constant ACQUISITIONS_ENABLED = 41;

    function setUp() public override {
        super.setUp();
        uint256 fee = FACTORY.poolCreationFee();
        deal(FWA_TOKEN, address(this), fee);
        IERC20Approve(FWA_TOKEN).approve(address(FACTORY), fee);
        pool = IFWAClone(FACTORY.createPool(bytes32("phase0"), fee, FWA_IMPLEMENTATION));
        SHAPES.setApprovalForAll(address(pool), true);
        PACKS.setApprovalForAll(address(pool), true);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}

    function _mint(uint256 amount, uint256 qty) internal returns (uint256 first) {
        first = SHAPES.mintBatch{value: (amount + SHAPES.mintFee()) * qty}(amount, qty);
    }

    function _list(uint256 tokenId, uint256 price) internal returns (uint256 listingId) {
        IFWAClone.ListingInput[] memory items = new IFWAClone.ListingInput[](1);
        items[0] = IFWAClone.ListingInput(address(SHAPES), tokenId, price);
        listingId = pool.listNFTs(items)[0];
    }

    /// @dev Ten 0.01 ETH Shapes plus one 0.5 ETH featured Shape, acquisitions enabled.
    function _board() internal returns (uint256 featuredId, uint256 featuredListing) {
        uint256 first = _mint(0.01 ether, 10);
        IFWAClone.ListingInput[] memory items = new IFWAClone.ListingInput[](10);
        for (uint256 i; i < 10; ++i) {
            items[i] = IFWAClone.ListingInput(address(SHAPES), first + i, 0.011 ether);
        }
        pool.listNFTs(items);
        featuredId = _mint(0.5 ether, 1);
        featuredListing = _list(featuredId, 0.5 ether);
        pool.setBool(ACQUISITIONS_ENABLED, true);
    }

    function test_poolOwnershipIsPermanentAndCreationCostsFwa() public {
        assertEq(pool.owner(), address(this));
        assertEq(FACTORY.poolCreationFee(), 50_000 ether);
        assertEq(IERC20Approve(FWA_TOKEN).balanceOf(address(this)), 0);
        (,, uint256 fiveTotal) = pool.quoteAcquisitionPrice(5); // maxAcquisitionsPerTx is internal; 5 quotes, 6 reverts
        assertGt(fiveTotal, 0);
        vm.expectRevert(bytes4(keccak256("InvalidAcquisitionCount()")));
        pool.quoteAcquisitionPrice(6);
        assertEq(pool.MAX_INVENTORY_BATCH(), 20);
        assertEq(SHAPES.mintFee(), 0.001 ether);
    }

    function test_drawSettlesDeliversAndAccruesOwnerProceeds() public {
        _board();
        uint256 fee = pool.acquisitionFee();
        uint256 base = pool.weightedBackingTotal() / pool.totalWeight();
        uint256 requestId = _buy(pool, buyer);
        assertEq(pool.unsettledAcquisitionCount(), 1);
        _fulfill(requestId, uint256(keccak256("word")));
        // Fast path settles inside the VRF callback.
        (address purchaser,,, uint256 listingId, IFWAClone.AcquisitionStatus status) = pool.acquisitions(requestId);
        assertEq(uint8(status), uint8(IFWAClone.AcquisitionStatus.Fulfilled));
        assertEq(purchaser, buyer);
        (,,, uint256 tokenId,,,, IFWAClone.ListingStatus lstatus) = pool.listings(listingId);
        assertEq(uint8(lstatus), uint8(IFWAClone.ListingStatus.Settled));
        assertEq(SHAPES.ownerOf(tokenId), buyer);
        assertEq(pool.unsettledAcquisitionCount(), 0);
        assertEq(pool.ownerProceeds(), fee - (fee - base) / 2);
        uint256 before = address(this).balance;
        pool.withdrawOwnerProceeds();
        assertEq(address(this).balance - before, fee - (fee - base) / 2);
    }

    function test_featuredWithdrawComposeRelist_halfToOneToFive() public {
        (uint256 featuredId, uint256 listingId) = _board();
        bytes32 seed = SHAPES.seedOf(featuredId);

        // 0.5 -> 1: withdraw, mint one 0.5, compose, relist.
        pool.withdrawListing(listingId);
        assertEq(SHAPES.ownerOf(featuredId), address(this));
        uint256[] memory burn = new uint256[](1);
        burn[0] = _mint(0.5 ether, 1);
        assertEq(SHAPES.compose(featuredId, burn), featuredId);
        assertEq(SHAPES.backingOf(featuredId), 1 ether);
        assertEq(SHAPES.seedOf(featuredId), seed);
        assertEq(SHAPES.composeDepth(featuredId), 1);
        listingId = _list(featuredId, 0.65 ether);

        // A draw between compositions, then 1 -> 5 with four 1 ETH Shapes.
        _fulfill(_buy(pool, buyer), 7);
        pool.withdrawListing(listingId);
        uint256 first = _mint(1 ether, 4);
        burn = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            burn[i] = first + i;
        }
        SHAPES.compose(featuredId, burn);
        assertEq(SHAPES.backingOf(featuredId), 5 ether);
        assertEq(SHAPES.seedOf(featuredId), seed);
        assertEq(SHAPES.composeDepth(featuredId), 2);
        _list(featuredId, 3.25 ether);
        assertEq(SHAPES.ownerOf(featuredId), address(pool));
    }

    function test_composeRequiresOwnershipNotApproval() public {
        uint256 survivor = _mint(0.5 ether, 1);
        uint256[] memory burn = new uint256[](1);
        burn[0] = _mint(0.5 ether, 1);
        SHAPES.setApprovalForAll(buyer, true);
        vm.prank(buyer);
        vm.expectRevert();
        SHAPES.compose(survivor, burn);
    }

    function test_unsupportedComposeSumReverts() public {
        uint256 survivor = _mint(0.5 ether, 1);
        uint256[] memory burn = new uint256[](1);
        burn[0] = _mint(0.1 ether, 1);
        vm.expectRevert();
        SHAPES.compose(survivor, burn);
    }

    function test_withdrawAndRepriceLockedWhileRequestUnsettled() public {
        (, uint256 listingId) = _board();
        uint256 requestId = _buy(pool, buyer);
        vm.expectRevert(bytes4(keccak256("WithdrawLocked()")));
        pool.updatePrice(listingId, 0.4 ether);
        vm.expectRevert(bytes4(keccak256("WithdrawLocked()")));
        pool.withdrawListing(listingId);
        // Listing during an unsettled request stages instead of activating.
        uint256 staged = _list(_mint(0.01 ether, 1), 0.011 ether);
        (,,,,,,, IFWAClone.ListingStatus s) = pool.listings(staged);
        assertEq(uint8(s), uint8(IFWAClone.ListingStatus.Staged));
        _fulfill(requestId, 3);
        pool.updatePrice(listingId, 0.4 ether);
    }

    function test_unfulfilledRequestExpiresAndRefunds() public {
        _board();
        uint256 requestId = _buy(pool, buyer);
        (,, uint256 escrowed,,) = pool.acquisitions(requestId);
        vm.roll(block.number + pool.selectionTimeoutBlocks() + 1);
        pool.processAcquisitions(1);
        (,,,, IFWAClone.AcquisitionStatus status) = pool.acquisitions(requestId);
        assertEq(uint8(status), uint8(IFWAClone.AcquisitionStatus.Expired));
        assertEq(pool.acquisitionRefundCredit(buyer), escrowed);
        assertEq(pool.ownerProceeds(), 0);
    }

    function test_inventoryChangeInvalidatesPendingQuote() public {
        _board();
        uint256 version = pool.inventoryVersion();
        _list(_mint(0.01 ether, 1), 0.011 ether);
        (,, uint256 total) = pool.quoteAcquisitionPrice(1);
        vm.deal(buyer, total);
        vm.prank(buyer);
        vm.expectRevert();
        pool.acquire{value: total}(buyer, 0, 0, 1000, version, block.timestamp + 600);
    }

    function test_purchaseOperatorDeniesAndDisableBlocks() public {
        _board();
        pool.setPurchaseOperator(address(new DenyAll()));
        (,, uint256 total) = pool.quoteAcquisitionPrice(1);
        vm.deal(buyer, total);
        uint256 version = pool.inventoryVersion();
        vm.prank(buyer);
        vm.expectRevert(bytes4(keccak256("PurchaseNotAllowed()")));
        pool.acquire{value: total}(buyer, 0, 0, 1000, version, block.timestamp + 600);
        pool.setPurchaseOperator(address(0));
        pool.setBool(ACQUISITIONS_ENABLED, false);
        vm.prank(buyer);
        vm.expectRevert(bytes4(keccak256("AcquisitionsNotEnabled()")));
        pool.acquire{value: total}(buyer, 0, 0, 1000, version, block.timestamp + 600);
    }

    function test_packMinimumIsThreeHundredthsAndPacksList() public {
        assertEq(PACKS.MIN_PACK_VALUE(), 0.03 ether);
        uint32[] memory counts = new uint32[](9);
        counts[0] = 2;
        uint256[] memory none;
        vm.expectRevert();
        PACKS.createPack{value: 0.022 ether}(none, counts);
        counts[0] = 3;
        uint256 packId = PACKS.createPack{value: 0.033 ether}(none, counts);
        assertEq(PACKS.valueOf(packId), 0.03 ether);
        IFWAClone.ListingInput[] memory items = new IFWAClone.ListingInput[](1);
        items[0] = IFWAClone.ListingInput(address(PACKS), packId, 0.036 ether);
        pool.listNFTs(items);
        assertEq(PACKS.ownerOf(packId), address(pool));
    }
}
