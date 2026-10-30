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

    // Custom errors (verbatim from the verified clone source), so clients can decode reverts.
    error ZeroPrice();
    error PriceTooHigh();
    error InvalidCollection();
    error ListingNotActive();
    error NotDepositor();
    error NoActiveListings();
    error WithdrawLocked();
    error InvalidTreeResult();
    error ActiveListingCapacityReached();
    error StagingQueueFull();
    error NFTTransferFailed();
    error InsufficientPayment();
    error AcquisitionFeeTooHigh();
    error InvalidAcquisitionCount();
    error InvalidInventoryBatch();
    error PoolValueTooLow();
    error InvalidConfig();
    error NoProceeds();
    error DeliveryNotPending();
    error DeliveryNotRefunded();
    error DeliveryWindowNotElapsed();
    error DeliveryWindowElapsed();
    error NotPurchaser();
    error OnlySelf();
    error NFTAlreadyControlled();
    error StaleNFTController();
    error AcquisitionsNotEnabled();
    error NoProtocolFees();
    error OnlyCoordinator();
    error SequenceInvariantBroken();
    error NoAcquisitionRefund();
    error AcquisitionStateLocked();
    error OnlyVrfService();
    error VrfRequestsPending();
    error DuplicateRequestId();
    error OnlyFactory();
    error OwnerOnlyInventory();
    error FactoryPurchasesDisabled();
    error FactoryWithdrawOnly();
    error VrfRequestsPaused();
    error ConsumerNotReady();
    error FactoryManagedConfig();
    error InventoryVersionMismatch(uint256 expected, uint256 actual);
    error InventoryChangeCooldownActive(uint256 purchasesResumeAt);
    error TransactionExpired(uint256 deadline);
    error OwnershipLocked();
    error PoolAlreadyRetired();
    error InvalidPurchaseOperator();
    error PurchaseNotAllowed();
    error PurchaseOperatorCheckFailed();
    error Unauthorized();

    // Events the keeper and web app read (verbatim from the verified clone source).
    event NFTListed(
        uint256 indexed listingId,
        uint256 indexed slot,
        address indexed depositor,
        address collection,
        uint256 tokenId,
        uint256 weight,
        uint256 price
    );
    event ListingWithdrawn(uint256 indexed listingId, address indexed depositor, uint256 price);
    event PriceUpdated(
        uint256 indexed listingId, address indexed depositor, uint256 oldPrice, uint256 newPrice, uint256 newWeight
    );
    event InventoryChanged(uint256 indexed version, uint64 changedAt);
    event AcquisitionRequested(
        uint256 indexed requestId, address indexed purchaser, uint256 acquisitionFee, uint256 totalWeight
    );
    event AcquisitionSequenced(
        uint256 indexed requestId, uint64 indexed sequence, uint64 wordDeadlineBlock, uint256 reservedCount
    );
    event RandomnessTimedOut(
        uint256 indexed requestId, uint64 indexed sequence, uint64 wordDeadlineBlock, uint256 callbackBlock
    );
    event AcquisitionProcessed(
        uint256 indexed requestId, uint64 indexed sequence, AcquisitionStatus status, address indexed processor
    );
    event AcquisitionRefundWithdrawn(address indexed purchaser, uint256 amount);
    event AcquisitionExpired(uint256 indexed requestId, uint64 indexed sequence, address indexed purchaser, uint256 refund);
    event AcquisitionRefundedNoListing(uint256 indexed requestId, address indexed purchaser, uint256 refund);
    event AcquisitionRefundedSlippage(
        uint256 indexed requestId, address indexed purchaser, uint256 refund, uint256 escrowedFee, uint256 liveFee
    );
    event NFTAllocated(
        uint256 indexed requestId,
        uint256 indexed listingId,
        address indexed purchaser,
        address depositor,
        uint256 price,
        uint256 randomWord
    );
    event NFTDeliveryFailed(uint256 indexed listingId, address indexed recipient, address collection, uint256 tokenId);
    event NFTDeliveryCompleted(uint256 indexed listingId, uint256 indexed requestId, address indexed purchaser);
    event NFTDeliveryRefunded(
        uint256 indexed listingId, uint256 indexed requestId, address indexed purchaser, uint256 amount
    );
    event RefundedNFTRecovered(uint256 indexed listingId, address indexed owner);

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
    function slotToListing(uint256 slot) external view returns (uint256);
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
    function acquisitionMeta(uint256 requestId)
        external
        view
        returns (
            uint64 sequence,
            uint64 wordDeadlineBlock,
            uint64 rewardEpoch,
            uint16 maxPositiveSlippageBps,
            uint16 maxNegativeSlippageBps,
            uint256 randomWord
        );
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
    /// @dev Permissionless retry when a stored word's delivery to the pool ran out of gas.
    function deliverRandomness(uint256 requestId) external returns (bool delivered);
    /// @dev 0 None, 1 CoordinatorOutstanding, 2 WordStored, 3 EmptyWordArrayStored, 4 Delivered, 5 CallbackLost.
    function requestStatus(uint256 requestId) external view returns (uint8);
    function maxOutstandingRequestsPerPool() external view returns (uint256);
}
