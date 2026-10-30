// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Subsets of the canonical FWA V2 custom-pool stack, verified against Blockscout source for
///         factory 0xf5a3a153164791ab579c3d9ba5dbecf7cdfd300c, standard clone implementation
///         0xeaa4d032908a9734a2c7939c0d211c35ad51eb31 and VRF service 0xa4adfc35db18326efb3b5d9bf66a8103ec2d5ee2.
interface IFWAFactory {
    function createPool(bytes32 userSalt, uint256 expectedCreationFee, address expectedImplementation)
        external
        returns (address pool);
    function predictPoolAddress(address poolOwner, bytes32 userSalt) external view returns (address);
    function implementation() external view returns (address);
    function poolCreationFee() external view returns (uint256);
    function fwaToken() external view returns (address);
    function edgeBps() external view returns (uint256);
    function inventoryChangeCooldown() external view returns (uint256);
    function globalPurchasesEnabled() external view returns (bool);
    function globalWithdrawOnly() external view returns (bool);
    function vrfRequestsPaused() external view returns (bool);
}

interface IFWAClone {
    enum ListingStatus {
        None,
        Active,
        Allocated,
        Withdrawn,
        Settled,
        Staged,
        DeliveryPending,
        DeliveryRefunded
    }

    enum AcquisitionStatus {
        None,
        Pending,
        Fulfilled,
        Expired,
        Refunded,
        Ready,
        TimedOut,
        DeliveryPending,
        DeliveryRefunded
    }

    struct ListingInput {
        address collection;
        uint256 tokenId;
        uint256 price;
    }

    // owner inventory
    function listNFTs(ListingInput[] calldata items) external returns (uint256[] memory listingIds);
    function withdrawListing(uint256 listingId) external;
    function updatePrice(uint256 listingId, uint256 newPrice) external;
    function recoverRefundedNFT(uint256 listingId) external;
    function withdrawOwnerProceeds() external returns (uint256 amount);
    function setBool(uint256 key, bool value) external;
    function setPurchaseOperator(address newOperator) external;
    function retirePool() external;

    // permissionless
    function processAcquisitions(uint256 maxCount) external returns (uint256 processed);
    function activateListings(uint256 maxCount) external;

    // purchase
    function acquire(
        address purchaser,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable returns (uint256 requestId);
    function acquireBatch(
        address purchaser,
        uint256 count,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable returns (uint256[] memory requestIds);
    function quoteAcquisitionPrice(uint256 count) external view returns (uint256 fee, uint256 vrf, uint256 total);
    function withdrawAcquisitionRefund() external returns (uint256 amount);
    function refundFailedDelivery(uint256 listingId) external;
    function retryNFTDelivery(uint256 listingId) external;

    // views
    function owner() external view returns (address);
    function listings(uint256 listingId)
        external
        view
        returns (
            address collection,
            address depositor,
            address purchaser,
            uint256 tokenId,
            uint256 weight,
            uint256 price,
            uint256 slot,
            ListingStatus status
        );
    function acquisitions(uint256 requestId)
        external
        view
        returns (
            address purchaser,
            uint256 requestBlock,
            uint256 priceEscrowed,
            uint256 listingId,
            AcquisitionStatus status
        );
    function requestIdAtSequence(uint64 sequence) external view returns (uint256);
    function nextSequenceToProcess() external view returns (uint64);
    function lastIssuedSequence() external view returns (uint64);
    function unsettledAcquisitionCount() external view returns (uint256);
    function totalWeight() external view returns (uint256);
    function weightedBackingTotal() external view returns (uint256);
    function activeListingCount() external view returns (uint256);
    function acquisitionFee() external view returns (uint256);
    function inventoryVersion() external view returns (uint256);
    function purchasesResumeAt() external view returns (uint256);
    function ownerProceeds() external view returns (uint256);
    function localPurchasesEnabled() external view returns (bool);
    function purchaseOperator() external view returns (address);
    function retired() external view returns (bool);
    function selectionTimeoutBlocks() external view returns (uint256);
    function MAX_INVENTORY_BATCH() external view returns (uint256);
    function DELIVERY_WINDOW() external view returns (uint256);
    function acquisitionRefundCredit(address purchaser) external view returns (uint256);
    function pendingDeliveries(uint256 listingId) external view returns (uint256 requestId, uint64 deadline);
}

/// @notice The pool calls this with a 100k gas stipend before taking payment. Only an exact ABI `true`
///         admits the purchase; `false`, a revert or a malformed reply rejects it.
interface IPurchaseOperator {
    function canPurchase(address wallet) external view returns (bool allowed);
}

/// @notice The FWA VRF service as the clone's logical coordinator. Its own coordinator is Chainlink VRF v2.5.
interface IFWAVRFService {
    function requestFee() external view returns (uint256);
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
    function maxOutstandingRequestsPerPool() external view returns (uint256);
}
