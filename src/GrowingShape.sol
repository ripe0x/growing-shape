// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IShapes} from "./interfaces/IShapes.sol";
import {IShapePacks} from "./interfaces/IShapePacks.sol";
import {IFWAFactory, IFWAClone, IPurchaseOperator} from "./interfaces/IFWA.sol";

/// @title Growing Shape
/// @notice Owns one FWA V2 custom pool of ETH-backed Shapes and Draw Packs. Players buy draws from the
///         pool directly. One featured Shape grows by composition from realised surplus, its FWA notional
///         decays with settled draws, and whoever draws it receives the token with all its backing.
/// @dev Custody boundary. This contract is the permanent FWA pool owner and the only lister. No function
///      sends an NFT anywhere except into the pool, into Shapes `compose`, or into Shapes/Packs redemption,
///      and ETH leaves only to Shapes/Packs mints, capped keeper reimbursement, and `RESIDUAL_RECIPIENT`
///      after retirement. The owner sets bounded policy and cannot reach assets.
///
///      Accounting identity (see `docs/SECURITY.md`), exact absent forced ETH:
///        balance + inventoryCost + featured.costBasis
///          == capitalIn + revenue + recovered - prizeExpense - featuredAwarded - keeperPaid
///      Growth is funded only from `surplus`: realised revenue net of prize costs, keeper pay, growth already
///      allocated and the seed of every featured Shape already won. Capital never becomes surplus.
contract GrowingShape is ReentrancyGuardTransient, IPurchaseOperator {
    /* ------------------------------------------------------------------ */
    /*                               Types                                */
    /* ------------------------------------------------------------------ */

    /// @dev An ordinary prize kind. `packShapes == 0` is one Shape of `backing`; otherwise a Draw Pack of
    ///      `packShapes` 0.01 ETH Shapes, so `backing == packShapes * 0.01 ether`.
    struct Tier {
        uint96 backing;
        uint16 packShapes;
        uint16 target;
        uint16 live;
        uint128 weight;
    }

    struct TierInput {
        uint96 backing;
        uint16 packShapes;
        uint16 target;
    }

    /// @dev One record per FWA listing this contract created. `live` until booked as won or redeemed.
    struct Prize {
        uint8 tier;
        bool featured;
        bool live;
        uint96 cost;
        uint128 weight;
    }

    struct Featured {
        uint256 tokenId;
        uint256 listingId; // 0 when no featured Shape is listed
        uint256 costBasis; // ETH spent on it: seed plus compositions, including mint fees
        uint256 seedCost;
        uint96 backing;
        uint96 notional; // the price published to FWA
        uint96 resetNotional; // notional at the latest cycle start or composition
        uint96 decayPerDraw; // snapshot at reset
        uint96 floor; // snapshot at reset
        uint16 resetShareBps; // snapshot at reset, applied at the next composition
        uint16 compositions;
        uint32 draws; // settled draws credited since the latest reset
        uint32 cycleDraws;
        uint64 startedBlock;
    }

    struct CycleResult {
        uint256 tokenId;
        address winner;
        uint96 backing;
        uint16 compositions;
        uint32 draws;
        uint64 startedBlock;
        uint64 endedBlock;
        uint256 requestId;
        uint256 costBasis;
    }

    /// @dev Bounded by `_checkGameParams`. Featured fields apply from the next reset; ordinary markup
    ///      applies to listings made afterwards.
    struct GameParams {
        uint16 markupBps; // ordinary notional = cost * markupBps / BPS
        uint16 startNotionalBps; // new featured notional as a share of its seed backing
        uint16 floorBps; // featured notional floor as a share of backing
        uint16 resetShareBps; // share of added backing added to notional at composition
        uint16 repriceStepBps; // publish decay once it reaches this fraction of the published notional
        uint32 decayPpm; // featured notional decay per settled draw, in millionths of backing
        uint16 minLiveOrdinary; // purchases pause when worst-case board depth falls below this
        uint16 maxPendingDraws; // purchases pause when this many issued draws are unbooked
        uint8 seedIndex; // Shapes denomination index of a new featured Shape
        uint96 reserveTarget; // operating ETH kept before surplus funds growth
    }

    struct KeeperParams {
        uint96 perDraw; // budget accrued per booked draw
        uint96 budgetCap;
        uint96 flatReward; // paid at most once per `flatInterval`
        uint32 flatInterval;
        uint32 gasOverhead; // added to measured gas: intrinsic and calldata cost
        uint64 gasPriceCap;
        uint64 priorityCap; // reimbursed price <= basefee + priorityCap
    }

    /* ------------------------------------------------------------------ */
    /*                             Constants                              */
    /* ------------------------------------------------------------------ */

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PPM = 1_000_000;
    /// @dev FWA's `INVERSE_WEIGHT_NUMERATOR`: weight = 1e36 / price, truncated.
    uint256 internal constant WEIGHT_NUMERATOR = 1e36;
    uint256 internal constant ACQUISITIONS_ENABLED = 41;
    uint256 internal constant MAX_BATCH = 20; // FWA MAX_INVENTORY_BATCH
    uint256 internal constant MAX_TIERS = 8;
    uint256 internal constant MAX_BOARD = 240;
    uint256 internal constant DENOMINATIONS = 9;

    IShapes public immutable SHAPES;
    IShapePacks public immutable PACKS;
    IFWAFactory public immutable FACTORY;
    address public immutable FWA_IMPLEMENTATION;
    address public immutable RESIDUAL_RECIPIENT;

    /* ------------------------------------------------------------------ */
    /*                               State                                */
    /* ------------------------------------------------------------------ */

    address public owner;
    address public pendingOwner;
    IFWAClone public pool;
    bool public paused;
    bool public growthPaused;
    uint64 public retiredAt;
    uint64 public bookedSequence;

    GameParams public params;
    KeeperParams public keeper;

    Tier[] internal _tiers;
    uint256 public liveOrdinary;
    mapping(uint256 listingId => Prize) public prizes;

    Featured public featured;
    uint256 public cycle;
    CycleResult[] internal _cycles;

    uint256 public growthFund;
    uint256 public keeperBudget;
    uint256 public lastFlatRewardAt;
    int256 public surplus;
    uint256 public inventoryCost;

    uint256 public capitalIn;
    uint256 public revenue;
    uint256 public recovered;
    uint256 public prizeExpense;
    uint256 public featuredAwarded;
    uint256 public keeperPaid;
    uint256 public growthAllocated;
    uint256 public drawsBooked;

    /* ------------------------------------------------------------------ */
    /*                           Events / errors                          */
    /* ------------------------------------------------------------------ */

    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PoolOpened(address indexed pool);
    event Funded(address indexed from, uint256 amount);
    event Booked(uint64 fromSequence, uint64 toSequence);
    event PrizeWon(uint256 indexed listingId, uint256 indexed requestId, address indexed winner, uint8 tier, bool delivered);
    event ProceedsCollected(uint256 amount);
    event GrowthAllocated(uint256 amount, uint256 growthFund);
    event PrizesListed(uint256 count, uint256 cost);
    event CycleStarted(uint256 indexed cycle, uint256 tokenId, uint256 listingId, uint256 backing, uint256 notional);
    event DecayPublished(uint256 indexed cycle, uint256 oldNotional, uint256 newNotional, uint256 draws);
    event Composed(
        uint256 indexed cycle, uint256 tokenId, uint256 oldBacking, uint256 newBacking, uint256 notional, uint256 listingId
    );
    event CycleWon(
        uint256 indexed cycle, uint256 tokenId, address indexed winner, uint256 backing, uint256 compositions, uint256 draws
    );
    event Recovered(uint256 indexed listingId, uint256 amount);
    event KeeperPaid(address indexed keeper, uint256 amount);
    event GameParamsSet(GameParams p);
    event KeeperParamsSet(KeeperParams k);
    event TierSet(uint256 indexed tier, uint96 backing, uint16 packShapes, uint16 target);
    event PausedSet(bool paused);
    event GrowthPausedSet(bool paused);
    event Retired();
    event Finalized(uint256 amount);

    error Unauthorized();
    error AlreadyOpen();
    error NoPool();
    error IsRetired();
    error NotRetired();
    error BadParams();
    error BadTier();
    error UnexpectedSender();
    error UnexpectedNFT();
    error PendingRequests();
    error NotBooked();
    error FeaturedActive();
    error NoFeatured();
    error NotDue();
    error InsufficientFunds();
    error CompositionFailed();
    error NotRecoverable();

    /* ------------------------------------------------------------------ */
    /*                            Construction                            */
    /* ------------------------------------------------------------------ */

    constructor(
        address owner_,
        IShapes shapes,
        IShapePacks packs,
        IFWAFactory factory,
        address fwaImplementation,
        address residualRecipient,
        GameParams memory gameParams,
        KeeperParams memory keeperParams,
        TierInput[] memory tiers
    ) {
        if (residualRecipient == address(0) || fwaImplementation == address(0)) revert BadParams();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        SHAPES = shapes;
        PACKS = packs;
        FACTORY = factory;
        FWA_IMPLEMENTATION = fwaImplementation;
        RESIDUAL_RECIPIENT = residualRecipient;
        paused = true; // the owner launches by unpausing once the board and featured Shape are listed
        _setGameParams(gameParams);
        _setKeeperParams(keeperParams);
        for (uint256 i; i < tiers.length; ++i) {
            _addTier(tiers[i]);
        }
    }

    /// @notice Create the FWA pool this contract owns forever. The FWA creation fee must already be held here.
    /// @dev Pins the implementation so a factory rotation cannot hand the game an unreviewed pool.
    function openPool(bytes32 salt) external onlyOwner {
        if (address(pool) != address(0)) revert AlreadyOpen();
        uint256 fee = FACTORY.poolCreationFee();
        if (fee != 0) SafeTransferLib.safeApprove(FACTORY.fwaToken(), address(FACTORY), fee);
        IFWAClone p = IFWAClone(FACTORY.createPool(salt, fee, FWA_IMPLEMENTATION));
        pool = p;
        p.setPurchaseOperator(address(this));
        SHAPES.setApprovalForAll(address(p), true);
        PACKS.setApprovalForAll(address(p), true);
        // FWA purchases are on from here; `canPurchase` admits nothing while `paused` (set at
        // construction) or before the board reaches `minLiveOrdinary`.
        p.setBool(ACQUISITIONS_ENABLED, true);
        emit PoolOpened(address(p));
    }

    /* ------------------------------------------------------------------ */
    /*                        Bounded administration                      */
    /* ------------------------------------------------------------------ */

    /// @notice Two-step ownership transfer. Setting `address(0)` as pending cancels; ownership cannot be renounced
    ///         to zero, but an owner may hand it to a contract that never acts.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function setGameParams(GameParams calldata p) external onlyOwner notRetired {
        _setGameParams(p);
    }

    function setKeeperParams(KeeperParams calldata k) external onlyOwner notRetired {
        _setKeeperParams(k);
    }

    function addTier(TierInput calldata t) external onlyOwner notRetired {
        _addTier(t);
    }

    /// @notice Change how many of a tier the board keeps. Lowering it only stops replacement.
    function setTierTarget(uint256 index, uint16 target) external onlyOwner notRetired {
        Tier storage t = _tiers[index];
        uint256 total = _boardTarget() - t.target + target;
        if (total > MAX_BOARD) revert BadTier();
        t.target = target;
        emit TierSet(index, t.backing, t.packShapes, target);
    }

    /// @notice Pause or resume new purchases. Settlement, refunds, deliveries and maintenance are unaffected.
    function setPaused(bool p) external onlyOwner notRetired {
        paused = p;
        emit PausedSet(p);
    }

    /// @notice Stop compositions (growth keeps accumulating) if composing becomes impossible.
    function setGrowthPaused(bool p) external onlyOwner notRetired {
        growthPaused = p;
        emit GrowthPausedSet(p);
    }

    /// @notice Irreversibly wind the game down. No new prizes or cycles. Every listed prize and the featured
    ///         Shape stay winnable; see `finalize` for the ETH no player claim needs.
    function retire() external onlyOwner notRetired {
        retiredAt = uint64(block.timestamp);
        paused = false;
        growthPaused = false;
        emit Retired();
    }

    function _setGameParams(GameParams memory p) internal {
        if (
            p.markupBps < BPS || p.markupBps > 2 * BPS || p.startNotionalBps < 5_000 || p.startNotionalBps > BPS
                || p.floorBps < 500 || p.floorBps > BPS || p.resetShareBps < 2_000 || p.resetShareBps > BPS
                || p.repriceStepBps < 100 || p.repriceStepBps > 5_000 || p.decayPpm > 5_000 || p.maxPendingDraws == 0
                || p.maxPendingDraws > 100 || p.minLiveOrdinary > MAX_BOARD || p.seedIndex < 2 || p.seedIndex > 4
                || p.reserveTarget > 20 ether
        ) revert BadParams();
        params = p;
        emit GameParamsSet(p);
    }

    function _setKeeperParams(KeeperParams memory k) internal {
        if (
            k.perDraw > 0.001 ether || k.budgetCap > 0.5 ether || k.flatReward > 0.002 ether || k.flatInterval < 60
                || k.gasOverhead > 100_000 || k.gasPriceCap > 200 gwei || k.priorityCap > 10 gwei
        ) revert BadParams();
        keeper = k;
        emit KeeperParamsSet(k);
    }

    function _addTier(TierInput memory t) internal {
        if (_tiers.length >= MAX_TIERS || _boardTarget() + t.target > MAX_BOARD) revert BadTier();
        if (t.packShapes == 0) {
            if (_denomIndex(t.backing) > 2) revert BadTier(); // ordinary Shapes are 0.01, 0.05 or 0.1
        } else if (t.packShapes > 20 || uint256(t.backing) != uint256(t.packShapes) * 0.01 ether) {
            revert BadTier();
        }
        _tiers.push(Tier(t.backing, t.packShapes, t.target, 0, 0));
        emit TierSet(_tiers.length - 1, t.backing, t.packShapes, t.target);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier notRetired() {
        if (retiredAt != 0) revert IsRetired();
        _;
    }

    modifier hasPool() {
        if (address(pool) == address(0)) revert NoPool();
        _;
    }

    /* ------------------------------------------------------------------ */
    /*                          Purchase admission                        */
    /* ------------------------------------------------------------------ */

    /// @notice FWA purchase operator hook, called with a 100k gas stipend before payment is taken.
    /// @dev Denies purchasers whose delivery would fail or loop back into custody, and pauses buying while
    ///      maintenance is required: unbooked draws at the cap, worst-case board depth below the minimum,
    ///      a due composition, or published decay at least two steps stale. Retirement ignores the owner
    ///      pause and the depth floor so play can drain the board.
    function canPurchase(address wallet) external view returns (bool) {
        IFWAClone p = pool;
        if (wallet == address(this) || wallet == address(SHAPES) || wallet == address(PACKS) || wallet == address(p)) {
            return false;
        }
        bool retired = retiredAt != 0;
        if (paused && !retired) return false;
        GameParams memory gp = params;
        uint256 pending = p.lastIssuedSequence() - bookedSequence;
        if (pending >= gp.maxPendingDraws) return false;
        if (!retired && liveOrdinary < pending + gp.minLiveOrdinary) return false;
        if (featured.listingId != 0) {
            if (compositionDue()) return false;
            uint256 n = featured.notional;
            if (desiredNotional() * BPS <= n * (BPS - 2 * uint256(gp.repriceStepBps))) return false;
        }
        return true;
    }

    /* ------------------------------------------------------------------ */
    /*                    Permissionless maintenance                       */
    /* ------------------------------------------------------------------ */

    /// @notice Add operating capital. Never counted as revenue or surplus.
    function fund() external payable {
        capitalIn += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Book up to `maxCount` processed FWA acquisitions in sequence order, collect owner proceeds,
    ///         and move eligible surplus into the growth fund.
    function book(uint256 maxCount) external nonReentrant hasPool {
        uint256 g = gasleft();
        IFWAClone p = pool;
        uint64 from = bookedSequence;
        uint64 processed = p.nextSequenceToProcess() - 1;
        uint64 to = processed - from > maxCount ? from + uint64(maxCount) : processed;
        for (uint64 seq = from + 1; seq <= to; ++seq) {
            uint256 requestId = p.requestIdAtSequence(seq);
            (address purchaser,,, uint256 listingId, IFWAClone.AcquisitionStatus s) = p.acquisitions(requestId);
            // Only a selected NFT consumes a prize. Expired and refunded draws book nothing. A selection
            // whose delivery failed has still left the pool; `recover` redeems it if its purchaser refunds.
            if (s == IFWAClone.AcquisitionStatus.Fulfilled) {
                _consume(listingId, requestId, purchaser, true);
            } else if (s == IFWAClone.AcquisitionStatus.DeliveryPending) {
                _consume(listingId, requestId, purchaser, false);
            } else if (s == IFWAClone.AcquisitionStatus.DeliveryRefunded) {
                _consume(listingId, requestId, address(0), false);
            }
        }
        bookedSequence = to;
        if (to != from) emit Booked(from + 1, to);
        bool collected = _collect();
        _allocateGrowth();
        _payKeeper(g, to != from || collected);
    }

    /// @notice Mint and list up to `maxCount` missing ordinary prizes in tier order, as operating ETH allows.
    function replenish(uint256 maxCount) external nonReentrant hasPool notRetired {
        uint256 g = gasleft();
        if (maxCount > MAX_BATCH) maxCount = MAX_BATCH;
        IFWAClone.ListingInput[] memory items = new IFWAClone.ListingInput[](maxCount);
        uint256[] memory tierOf = new uint256[](maxCount);
        uint256 fee = SHAPES.mintFee();
        uint256 budget = operating();
        uint256 n;
        for (uint256 i; i < _tiers.length && n < maxCount; ++i) {
            (n, budget) = _mintTier(i, fee, budget, maxCount, n, items, tierOf);
        }
        if (n != 0) _listOrdinary(items, tierOf, n, fee);
        _payKeeper(g, n != 0);
    }

    /// @notice Mint and list a new featured Shape when none is active and operating ETH covers its seed
    ///         after every missing ordinary prize.
    function startCycle() external nonReentrant hasPool notRetired {
        uint256 g = gasleft();
        if (featured.listingId != 0) revert FeaturedActive();
        GameParams memory gp = params;
        uint256 seed = _denom(gp.seedIndex);
        uint256 cost = seed + SHAPES.mintFee();
        if (operating() < cost + replacementDue()) revert InsufficientFunds();
        uint256 tokenId = SHAPES.mintBatch{value: cost}(seed, 1);
        uint256 notional = seed * gp.startNotionalBps / BPS;
        uint256 listingId = _listFeatured(tokenId, notional);
        uint256 c = ++cycle;
        Featured storage f = featured;
        f.tokenId = tokenId;
        f.listingId = listingId;
        f.costBasis = cost;
        f.seedCost = cost;
        f.backing = uint96(seed);
        f.compositions = 0;
        f.cycleDraws = 0;
        f.startedBlock = uint64(block.number);
        _reset(f, notional);
        emit CycleStarted(c, tokenId, listingId, seed, notional);
        _payKeeper(g, true);
    }

    /// @notice Publish the featured Shape's decayed notional to FWA once it has fallen one step.
    /// @dev FWA only reprices with no acquisition unsettled; while two steps stale `canPurchase` pauses
    ///      buying so that window always arrives.
    function publishDecay() external nonReentrant hasPool {
        uint256 g = gasleft();
        Featured storage f = featured;
        if (f.listingId == 0) revert NoFeatured();
        uint256 desired = desiredNotional();
        uint256 n = f.notional;
        if (desired >= n || (desired != f.floor && desired * BPS > n * (BPS - params.repriceStepBps))) revert NotDue();
        _requireIdle();
        pool.activateListings(MAX_BATCH);
        pool.updatePrice(f.listingId, desired);
        f.notional = uint96(desired);
        prizes[f.listingId].weight = uint128(WEIGHT_NUMERATOR / desired);
        emit DecayPublished(cycle, n, desired, f.draws);
        _payKeeper(g, true);
    }

    /// @notice Compose the featured Shape up to the next denomination once the growth fund covers it.
    /// @dev Atomic: withdraw from FWA, mint the inputs, compose into the same token, verify, relist. If any
    ///      step cannot run, the whole call reverts and the Shape stays listed with its growth fund intact.
    function compose() external nonReentrant hasPool {
        uint256 g = gasleft();
        if (!compositionDue()) revert NotDue();
        _requireIdle();
        Featured storage f = featured;
        uint256 oldBacking = f.backing;
        uint256 newBacking = _nextDenom(oldBacking);
        (uint256 cost, uint256[] memory inputs) = _mintCompositionInputs(newBacking - oldBacking);
        uint256 desired = desiredNotional();

        uint256 oldListing = f.listingId;
        pool.withdrawListing(oldListing);
        SHAPES.compose(f.tokenId, inputs);
        if (SHAPES.backingOf(f.tokenId) != newBacking || SHAPES.ownerOf(f.tokenId) != address(this)) {
            revert CompositionFailed();
        }

        uint256 notional = desired + (newBacking - oldBacking) * f.resetShareBps / BPS;
        if (notional > newBacking) notional = newBacking;
        delete prizes[oldListing];
        f.listingId = _listFeatured(f.tokenId, notional);
        growthFund -= cost;
        f.costBasis += cost;
        f.backing = uint96(newBacking);
        ++f.compositions;
        _reset(f, notional);
        emit Composed(cycle, f.tokenId, oldBacking, newBacking, notional, f.listingId);
        _payKeeper(g, true);
    }

    /// @notice Recover a prize whose purchaser took FWA's failed-delivery refund, and redeem it for ETH.
    ///         Its cost was expensed when booked; the redeemed backing returns as `recovered`.
    function recover(uint256 listingId) external nonReentrant hasPool {
        uint256 g = gasleft();
        (address collection,,, uint256 tokenId,,,, IFWAClone.ListingStatus s) = pool.listings(listingId);
        if (s != IFWAClone.ListingStatus.DeliveryRefunded) revert NotRecoverable();
        pool.recoverRefundedNFT(listingId);
        uint256 amount = _redeem(collection, tokenId);
        recovered += amount;
        surplus += int256(amount);
        emit Recovered(listingId, amount);
        _payKeeper(g, true);
    }

    /* ------------------------------------------------------------------ */
    /*                              Retirement                            */
    /* ------------------------------------------------------------------ */

    /// @notice After retirement, send operating ETH that no player claim or keeper allowance needs to
    ///         `RESIDUAL_RECIPIENT`. Surplus is first added to the growth fund while a featured Shape is listed.
    ///         Listed prizes, the featured Shape and its growth fund stay in play. Once nothing is listed or
    ///         unsettled, the pool is closed and every remaining wei is sent. Repeatable.
    function finalize() external nonReentrant hasPool {
        if (retiredAt == 0) revert NotRetired();
        _requireIdle();
        _collect();
        IFWAClone p = pool;
        if (featured.listingId == 0 && liveOrdinary == 0) {
            if (!p.retired()) p.retirePool();
            growthFund = 0;
            keeperBudget = 0;
        } else {
            _allocateGrowth();
        }
        uint256 amount = operating() - keeperBudget;
        if (amount != 0) SafeTransferLib.forceSafeTransferETH(RESIDUAL_RECIPIENT, amount);
        emit Finalized(amount);
    }

    /* ------------------------------------------------------------------ */
    /*                                Views                               */
    /* ------------------------------------------------------------------ */

    /// @notice ETH not committed to the growth fund.
    function operating() public view returns (uint256) {
        return address(this).balance - growthFund;
    }

    /// @notice Cost of minting every ordinary prize currently missing from the board at the live mint fee.
    function replacementDue() public view returns (uint256 due) {
        uint256 fee = SHAPES.mintFee();
        for (uint256 i; i < _tiers.length; ++i) {
            Tier storage t = _tiers[i];
            if (t.target > t.live) due += uint256(t.target - t.live) * _tierCost(t, fee);
        }
    }

    /// @notice Operating ETH held back before any surplus moves to growth: reserve, next seed, missing
    ///         prizes and the keeper allowance.
    function requiredLiquid() public view returns (uint256) {
        if (retiredAt != 0) return keeperBudget;
        return params.reserveTarget + _denom(params.seedIndex) + SHAPES.mintFee() + replacementDue() + keeperBudget;
    }

    /// @notice The featured notional the decay schedule calls for now. Published only in steps.
    function desiredNotional() public view returns (uint256) {
        Featured storage f = featured;
        uint256 decay = uint256(f.draws) * f.decayPerDraw;
        uint256 n = f.resetNotional > decay ? f.resetNotional - decay : 0;
        return n > f.floor ? n : f.floor;
    }

    /// @notice ETH a composition to the next denomination costs now, including mint fees. 0 at the top.
    function compositionCost() public view returns (uint256) {
        if (featured.listingId == 0) return 0;
        uint256 b = featured.backing;
        uint256 next = _nextDenom(b);
        if (next == 0) return 0;
        (uint256 count, uint256 delta) = _inputCount(next - b);
        return delta + count * SHAPES.mintFee();
    }

    function compositionDue() public view returns (bool) {
        if (featured.listingId == 0 || growthPaused) return false;
        uint256 cost = compositionCost();
        return cost != 0 && growthFund >= cost;
    }

    function tierCount() external view returns (uint256) {
        return _tiers.length;
    }

    function tier(uint256 i) external view returns (Tier memory) {
        return _tiers[i];
    }

    function cycleCount() external view returns (uint256) {
        return _cycles.length;
    }

    function cycleResult(uint256 i) external view returns (CycleResult memory) {
        return _cycles[i];
    }

    /* ------------------------------------------------------------------ */
    /*                         Receiving ETH and NFTs                      */
    /* ------------------------------------------------------------------ */

    /// @dev Owner proceeds from the pool and redemptions from Shapes. Capital uses `fund`.
    receive() external payable {
        if (msg.sender != address(pool) && msg.sender != address(SHAPES)) revert UnexpectedSender();
    }

    /// @dev Accepts only Shapes and Packs this contract mints, or the pool returns.
    function onERC721Received(address operator, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(SHAPES) && msg.sender != address(PACKS)) revert UnexpectedNFT();
        if (operator != address(this) && operator != address(pool)) revert UnexpectedNFT();
        return this.onERC721Received.selector;
    }

    /* ------------------------------------------------------------------ */
    /*                               Internal                             */
    /* ------------------------------------------------------------------ */

    /// @dev Books one selected listing exactly once. A delivered or delivery-pending prize leaves the board;
    ///      only a delivered one is a settled draw for decay credit.
    function _consume(uint256 listingId, uint256 requestId, address winner, bool delivered) internal {
        Prize memory pr = prizes[listingId];
        if (!pr.live) revert BadTier();
        delete prizes[listingId];
        if (pr.featured) {
            _endCycle(winner, requestId);
        } else {
            _removeOrdinary(pr);
            prizeExpense += pr.cost;
            surplus -= int256(uint256(pr.cost));
        }
        if (delivered) {
            ++drawsBooked;
            Featured storage f = featured;
            if (f.listingId != 0) {
                ++f.draws;
                ++f.cycleDraws;
            }
            KeeperParams memory k = keeper;
            uint256 b = keeperBudget + k.perDraw;
            keeperBudget = b > k.budgetCap ? k.budgetCap : b;
        }
        emit PrizeWon(listingId, requestId, winner, pr.tier, delivered);
    }

    /// @dev Mints as many of tier `i`'s missing prizes as fit in the batch and `budget`, appending them.
    function _mintTier(
        uint256 i,
        uint256 fee,
        uint256 budget,
        uint256 maxCount,
        uint256 n,
        IFWAClone.ListingInput[] memory items,
        uint256[] memory tierOf
    ) internal returns (uint256, uint256) {
        Tier storage t = _tiers[i];
        if (t.live >= t.target) return (n, budget);
        uint256 cost = _tierCost(t, fee);
        uint256 q = t.target - t.live;
        if (q > maxCount - n) q = maxCount - n;
        if (q > budget / cost) q = budget / cost;
        if (q == 0) return (n, budget);
        uint256 price = cost * params.markupBps / BPS;
        if (t.packShapes == 0) {
            uint256 first = SHAPES.mintBatch{value: q * cost}(t.backing, q);
            for (uint256 j; j < q; ++j) {
                items[n] = IFWAClone.ListingInput(address(SHAPES), first + j, price);
                tierOf[n++] = i;
            }
        } else {
            uint32[] memory counts = new uint32[](DENOMINATIONS);
            counts[0] = t.packShapes;
            for (uint256 j; j < q; ++j) {
                items[n] = IFWAClone.ListingInput(address(PACKS), PACKS.createPack{value: cost}(new uint256[](0), counts), price);
                tierOf[n++] = i;
            }
        }
        return (n, budget - q * cost);
    }

    /// @dev Lists the first `n` minted prizes in one FWA inventory version and records them.
    function _listOrdinary(IFWAClone.ListingInput[] memory items, uint256[] memory tierOf, uint256 n, uint256 fee)
        internal
    {
        assembly ("memory-safe") {
            mstore(items, n)
        }
        uint256[] memory ids = pool.listNFTs(items);
        uint256 spent;
        for (uint256 k; k < n; ++k) {
            Tier storage t = _tiers[tierOf[k]];
            uint256 cost = _tierCost(t, fee);
            uint128 w = uint128(WEIGHT_NUMERATOR / items[k].price);
            prizes[ids[k]] = Prize(uint8(tierOf[k]), false, true, uint96(cost), w);
            ++t.live;
            t.weight += w;
            spent += cost;
        }
        liveOrdinary += n;
        inventoryCost += spent;
        emit PrizesListed(n, spent);
    }

    function _endCycle(address winner, uint256 requestId) internal {
        Featured storage f = featured;
        ++f.cycleDraws; // the winning draw
        _cycles.push(
            CycleResult({
                tokenId: f.tokenId,
                winner: winner,
                backing: f.backing,
                compositions: f.compositions,
                draws: f.cycleDraws,
                startedBlock: f.startedBlock,
                endedBlock: uint64(block.number),
                requestId: requestId,
                costBasis: f.costBasis
            })
        );
        emit CycleWon(cycle, f.tokenId, winner, f.backing, f.compositions, f.cycleDraws);
        featuredAwarded += f.costBasis;
        // Each cycle must earn back the seed it consumed before surplus funds more growth.
        surplus -= int256(f.seedCost);
        f.costBasis = 0;
        f.listingId = 0;
    }

    function _removeOrdinary(Prize memory pr) internal {
        Tier storage t = _tiers[pr.tier];
        --t.live;
        t.weight -= pr.weight;
        --liveOrdinary;
        inventoryCost -= pr.cost;
    }

    function _collect() internal returns (bool) {
        IFWAClone p = pool;
        if (p.ownerProceeds() == 0) return false;
        uint256 amount = p.withdrawOwnerProceeds();
        revenue += amount;
        surplus += int256(amount);
        emit ProceedsCollected(amount);
        return true;
    }

    /// @dev Surplus moves to growth only while operating ETH stays above everything held back.
    function _allocateGrowth() internal {
        if (surplus <= 0 || (retiredAt != 0 && featured.listingId == 0)) return;
        uint256 op = operating();
        uint256 req = requiredLiquid();
        if (op <= req) return;
        uint256 amount = op - req;
        if (amount > uint256(surplus)) amount = uint256(surplus);
        growthFund += amount;
        growthAllocated += amount;
        surplus -= int256(amount);
        emit GrowthAllocated(amount, growthFund);
    }

    function _reset(Featured storage f, uint256 notional) internal {
        GameParams memory gp = params;
        f.notional = uint96(notional);
        f.resetNotional = uint96(notional);
        f.decayPerDraw = uint96(uint256(f.backing) * gp.decayPpm / PPM);
        f.floor = uint96(uint256(f.backing) * gp.floorBps / BPS);
        f.resetShareBps = gp.resetShareBps;
        f.draws = 0;
    }

    function _listFeatured(uint256 tokenId, uint256 notional) internal returns (uint256 listingId) {
        IFWAClone.ListingInput[] memory items = new IFWAClone.ListingInput[](1);
        items[0] = IFWAClone.ListingInput(address(SHAPES), tokenId, notional);
        listingId = pool.listNFTs(items)[0];
        prizes[listingId] = Prize(0, true, true, 0, uint128(WEIGHT_NUMERATOR / notional));
    }

    /// @dev Mints the fewest Shapes summing to `delta` (greedy over the ladder) and pays from growth.
    function _mintCompositionInputs(uint256 delta) internal returns (uint256 cost, uint256[] memory ids) {
        (uint256 count,) = _inputCount(delta);
        ids = new uint256[](count);
        uint256 fee = SHAPES.mintFee();
        uint256 n;
        for (uint256 i = DENOMINATIONS; i > 0 && delta != 0; --i) {
            uint256 d = _denom(i - 1);
            uint256 q = delta / d;
            if (q == 0) continue;
            delta -= q * d;
            uint256 first = SHAPES.mintBatch{value: q * (d + fee)}(d, q);
            cost += q * (d + fee);
            for (uint256 j; j < q; ++j) {
                ids[n++] = first + j;
            }
        }
    }

    function _inputCount(uint256 delta) internal pure returns (uint256 count, uint256 total) {
        total = delta;
        for (uint256 i = DENOMINATIONS; i > 0 && delta != 0; --i) {
            uint256 d = _denom(i - 1);
            count += delta / d;
            delta %= d;
        }
    }

    function _redeem(address collection, uint256 tokenId) internal returns (uint256 amount) {
        uint256 before = address(this).balance;
        if (collection == address(SHAPES)) SHAPES.redeem(tokenId);
        else PACKS.redeem(tokenId);
        amount = address(this).balance - before;
    }

    /// @dev FWA locks withdrawal and repricing while any acquisition is unsettled, and every processed
    ///      acquisition must be booked so a featured Shape already won is never touched.
    function _requireIdle() internal view {
        IFWAClone p = pool;
        if (p.unsettledAcquisitionCount() != 0) revert PendingRequests();
        if (p.nextSequenceToProcess() - 1 != bookedSequence) revert NotBooked();
    }

    /// @dev Pays measured gas at a capped price plus an interval-limited flat reward, from the keeper
    ///      allowance only, and only for calls that did work.
    function _payKeeper(uint256 gasStart, bool worked) internal {
        if (!worked) return;
        KeeperParams memory k = keeper;
        uint256 price = tx.gasprice;
        uint256 cap = block.basefee + k.priorityCap;
        if (cap > k.gasPriceCap) cap = k.gasPriceCap;
        if (price > cap) price = cap;
        uint256 amount = (gasStart - gasleft() + k.gasOverhead) * price;
        if (k.flatReward != 0 && block.timestamp >= lastFlatRewardAt + k.flatInterval) {
            amount += k.flatReward;
            lastFlatRewardAt = block.timestamp;
        }
        uint256 limit = keeperBudget;
        uint256 op = operating();
        if (limit > op) limit = op;
        if (amount > limit) amount = limit;
        if (amount == 0) return;
        keeperBudget -= amount;
        keeperPaid += amount;
        surplus -= int256(amount);
        SafeTransferLib.forceSafeTransferETH(msg.sender, amount, SafeTransferLib.GAS_STIPEND_NO_STORAGE_WRITES);
        emit KeeperPaid(msg.sender, amount);
    }

    function _tierCost(Tier storage t, uint256 fee) internal view returns (uint256) {
        return uint256(t.backing) + (t.packShapes == 0 ? 1 : uint256(t.packShapes)) * fee;
    }

    function _boardTarget() internal view returns (uint256 total) {
        for (uint256 i; i < _tiers.length; ++i) {
            total += _tiers[i].target;
        }
    }

    /// @dev The mainnet Shapes ladder 0.01, 0.05, 0.1, 0.5 ... 100 ETH: alternating 1 and 5 times a power
    ///      of ten. `test/fork` asserts it matches `Shapes.denominationAt`.
    function _denom(uint256 i) internal pure returns (uint256) {
        if (i >= DENOMINATIONS) revert BadParams();
        return (i % 2 == 0 ? 1 : 5) * 10 ** (i / 2) * 0.01 ether;
    }

    function _denomIndex(uint256 amount) internal pure returns (uint256) {
        for (uint256 i; i < DENOMINATIONS; ++i) {
            if (_denom(i) == amount) return i;
        }
        return type(uint256).max;
    }

    function _nextDenom(uint256 amount) internal pure returns (uint256) {
        uint256 i = _denomIndex(amount);
        return i < DENOMINATIONS - 1 ? _denom(i + 1) : 0;
    }
}
