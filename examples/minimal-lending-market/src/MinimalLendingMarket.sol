// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {HyperCoreOracleGuard} from "hyperevm-safety/src/HyperCoreOracleGuard.sol";
import {ChainlinkCompatAdapter} from "hyperevm-safety/src/ChainlinkCompatAdapter.sol";

/// @dev Minimal ERC20 surface — the market only needs `transferFrom`/`transfer`/
///      `balanceOf`. Keeping the interface local avoids pulling OpenZeppelin
///      into the example (which would otherwise be the only reason for an OZ
///      dep), preserving the "starter project that compiles standalone" framing.
interface IMinimalERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title MinimalLendingMarket — share-accounted single-asset lending market.
/// @notice Canonical reference for a HyperEVM lending market that consumes a
///         HyperCore mark price via the `hyperevm-safety` library. The market is
///         intentionally tiny — one collateral asset, share-accounted deposits,
///         pro-rata withdrawals — so a contributor forking this example can
///         see exactly where each library hook attaches.
///
/// @notice **Why both `HyperCoreOracleGuard` AND `ChainlinkCompatAdapter`?** They
///         serve different purposes and the spec deliberately wires both:
///
///           - `HyperCoreOracleGuard.readMark(asset)` — the **staleness gate**.
///             Reverts `Stale()` when the HyperCore L1 block lag exceeds the
///             configured bound (D-1 of the differentiated taxonomy). Every
///             state-mutating market function calls it before touching shares.
///             This is the load-bearing safety check.
///
///           - `ChainlinkCompatAdapter.latestRoundData()` — the **price read**,
///             surfaced through the `AggregatorV3Interface` shape so the same
///             market integrates cleanly with downstream protocols / aggregators
///             that consume Chainlink-compat feeds. Returns `updatedAt =
///             HyperCore publish-block timestamp` (D-6), so the market's
///             own seconds-bounded staleness check on the adapter actually
///             fires when HyperCore halts (the broken-pattern adapter returns
///             `block.timestamp` and silently defeats this check).
///
///         A fork-from-this-example consumer should keep both wired — dropping
///         either one re-introduces a documented bug class. See the example
///         README for the link to T-3's invariants that catch each class.
///
/// @notice **Pricing semantics.** Deposits and withdrawals are pro-rata against
///         the contract's collateral balance, the standard ERC4626 redemption
///         math for a single-asset vault. The price is NOT used to scale
///         share-mint or share-redeem amounts; it appears in `pricePerShare()`
///         as the USD-denominated value of one share, which is the surface a
///         downstream protocol (or a liquidation engine, in a richer variant)
///         consumes. The staleness gate fires on every state mutation
///         regardless — a stale price reaching an external consumer is the
///         bug class the gate exists to prevent, and the gate has to run on the
///         write path because reads of `pricePerShare()` are external-view-only
///         and can't revert the user's transaction.
contract MinimalLendingMarket {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares(uint256 requested, uint256 held);
    error TransferFailed();
    error InvalidPrice(int256 answer);
    error AdapterStale(uint256 ageSec, uint256 maxAgeSec);
    error InvalidConfig();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Deposit(address indexed user, uint256 amount, uint256 shares, uint256 price, uint256 updatedAt);
    event Withdraw(address indexed user, uint256 sharesBurned, uint256 amountReturned, uint256 price, uint256 updatedAt);

    // -------------------------------------------------------------------------
    // Configuration — immutable, set at construction.
    // -------------------------------------------------------------------------

    /// @notice The single collateral asset the market accepts.
    IMinimalERC20 public immutable collateral;

    /// @notice Decimals of `collateral`. Captured at construction so
    ///         `pricePerShare()` can scale a uint256 amount × uint256 price
    ///         into a stable USD-denominated quote without an on-chain call to
    ///         `collateral.decimals()` per query.
    uint8 public immutable collateralDecimals;

    /// @notice Staleness + deviation guard from the hyperevm-safety library
    ///         (D-1 / D-2). The market calls `guard.readMark(asset)` on every
    ///         state-mutating function purely for the `Stale()` revert
    ///         behaviour — the returned price is not used for share math.
    HyperCoreOracleGuard public immutable guard;

    /// @notice Chainlink-compatible adapter (D-6) routing the HyperCore mark
    ///         read through `AggregatorV3Interface.latestRoundData()`. The
    ///         adapter's `updatedAt` is the HyperCore publish-block timestamp,
    ///         so the seconds-bounded freshness check below actually detects
    ///         a HyperCore halt.
    ChainlinkCompatAdapter public immutable priceFeed;

    /// @notice Perp asset id the guard reads. MUST match the asset the
    ///         priceFeed was constructed against — the example wires the same
    ///         id into both at deployment.
    uint32 public immutable asset;

    /// @notice Maximum acceptable age (in seconds) of the adapter's
    ///         `updatedAt` reading. A second freshness gate at the adapter
    ///         layer that catches the "HyperCore halted, L1 block frozen"
    ///         case via the timestamp difference. Complements the guard's
    ///         block-based staleness check.
    uint64 public immutable maxAdapterAgeSec;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    constructor(
        IMinimalERC20 collateral_,
        uint8 collateralDecimals_,
        HyperCoreOracleGuard guard_,
        ChainlinkCompatAdapter priceFeed_,
        uint32 asset_,
        uint64 maxAdapterAgeSec_
    ) {
        if (
            address(collateral_) == address(0)
                || address(guard_) == address(0)
                || address(priceFeed_) == address(0)
                || collateralDecimals_ == 0
                || collateralDecimals_ > 36
                || maxAdapterAgeSec_ == 0
        ) {
            revert InvalidConfig();
        }
        collateral = collateral_;
        collateralDecimals = collateralDecimals_;
        guard = guard_;
        priceFeed = priceFeed_;
        asset = asset_;
        maxAdapterAgeSec = maxAdapterAgeSec_;
    }

    // -------------------------------------------------------------------------
    // Deposits
    // -------------------------------------------------------------------------

    /// @notice Deposit `amount` of collateral and mint shares pro-rata against
    ///         the current pool balance. Reverts if the oracle is stale or the
    ///         adapter's freshness check fails.
    /// @return mintedShares Shares credited to `msg.sender`.
    function deposit(uint256 amount) external returns (uint256 mintedShares) {
        if (amount == 0) revert ZeroAmount();

        (uint256 price, uint256 updatedAt) = _readGuardedPrice();

        // Pro-rata against current balance. On bootstrap (empty market) mint
        // 1:1 in collateral units. This is the standard ERC4626 shape; the
        // single-asset version doesn't need a virtual-share offset because
        // there's no exchange-rate inflation attack surface (no second asset
        // for an attacker to skim against).
        uint256 balBefore = collateral.balanceOf(address(this));
        if (totalShares == 0) {
            mintedShares = amount;
        } else {
            // balBefore is guaranteed > 0 here: totalShares > 0 implies a
            // prior deposit landed collateral, and the market has no path
            // that decrements balance without burning shares.
            mintedShares = (amount * totalShares) / balBefore;
        }
        if (mintedShares == 0) revert ZeroShares();

        // Effects before interaction (CEI).
        sharesOf[msg.sender] += mintedShares;
        totalShares += mintedShares;

        if (!collateral.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        emit Deposit(msg.sender, amount, mintedShares, price, updatedAt);
    }

    // -------------------------------------------------------------------------
    // Withdrawals
    // -------------------------------------------------------------------------

    /// @notice Burn `shareAmount` of caller's shares and return the pro-rata
    ///         slice of pool collateral.
    /// @return amount Collateral units transferred to `msg.sender`.
    function withdraw(uint256 shareAmount) external returns (uint256 amount) {
        if (shareAmount == 0) revert ZeroShares();
        uint256 held = sharesOf[msg.sender];
        if (shareAmount > held) revert InsufficientShares(shareAmount, held);

        (uint256 price, uint256 updatedAt) = _readGuardedPrice();

        // Pro-rata redemption: amount = shareAmount * balance / totalShares.
        uint256 bal = collateral.balanceOf(address(this));
        amount = (shareAmount * bal) / totalShares;
        if (amount == 0) revert ZeroAmount();

        sharesOf[msg.sender] = held - shareAmount;
        totalShares -= shareAmount;

        if (!collateral.transfer(msg.sender, amount)) revert TransferFailed();

        emit Withdraw(msg.sender, shareAmount, amount, price, updatedAt);
    }

    // -------------------------------------------------------------------------
    // Views — quoted in the priceFeed's decimal precision.
    // -------------------------------------------------------------------------

    /// @notice USD-denominated value of one share, scaled to the priceFeed's
    ///         decimals. Returns 0 on an empty market. Does NOT check
    ///         staleness — `view` functions can't revert state mutations, and
    ///         this is a quote-only surface. Consumers SHOULD pair this with a
    ///         direct call to `priceFeed.latestRoundData()` and check
    ///         `updatedAt` themselves if they consume the quote off-band.
    function pricePerShare() external view returns (uint256) {
        if (totalShares == 0) return 0;
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        if (answer <= 0) return 0;
        uint256 bal = collateral.balanceOf(address(this));
        // value-per-share = (bal * price) / (totalShares * 10**collateralDecimals)
        // result is in priceFeed.decimals() precision.
        // casting answer to uint256 is safe — guard above rejects answer <= 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (bal * uint256(answer)) / (totalShares * (10 ** uint256(collateralDecimals)));
    }

    /// @notice USD-denominated value of `user`'s share holdings.
    function valueOf(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        if (answer <= 0) return 0;
        uint256 bal = collateral.balanceOf(address(this));
        uint256 userBalance = (sharesOf[user] * bal) / totalShares;
        // casting answer to uint256 is safe — guard above rejects answer <= 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (userBalance * uint256(answer)) / (10 ** uint256(collateralDecimals));
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev Run both safety reads on every state mutation:
    ///        (1) `guard.readMark(asset)` — reverts `Stale()` if the HyperCore
    ///            L1 block has lagged past the guard's bound.
    ///        (2) `priceFeed.latestRoundData()` — pulled through the Chainlink
    ///            compat shape; `updatedAt` is the HyperCore publish-block
    ///            timestamp (D-6), so the seconds-bounded check below catches
    ///            a HyperCore halt the broken-pattern adapter would mask.
    ///      Returns the validated price + updatedAt for event emission.
    function _readGuardedPrice() internal view returns (uint256 price, uint256 updatedAt) {
        // (1) Staleness gate via the guard. Discard the returned price —
        //     the adapter is the source of truth for the actual value (it
        //     handles the decimal scaling for us). We call `readMark` purely
        //     for its revert behaviour.
        guard.readMark(asset);

        // (2) Chainlink-compat read. The adapter routes through the same
        //     precompile but exposes the AggregatorV3Interface shape with
        //     `updatedAt = HyperCore publish-block timestamp`.
        (, int256 answer, , uint256 updatedAt_, ) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);

        // Seconds-bounded freshness check against the adapter's updatedAt.
        // This is the layer that actually fires when HyperCore halts —
        // `block.timestamp - updatedAt` only grows if `updatedAt` is the
        // HyperCore publish timestamp (NOT block.timestamp). That's the D-6
        // payoff: the broken-pattern adapter sets `updatedAt = block.timestamp`
        // and this check would silently pass forever.
        //
        // Validator-side block.timestamp manipulation isn't a meaningful
        // threat here: a validator can only nudge timestamp forward (the
        // EIP-1559 rule), which makes this check STRICTER, not looser.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > updatedAt_) {
            // forge-lint: disable-next-line(block-timestamp)
            uint256 ageSec = block.timestamp - updatedAt_;
            if (ageSec > maxAdapterAgeSec) revert AdapterStale(ageSec, maxAdapterAgeSec);
        }

        // casting answer to uint256 is safe — guard above rejects answer <= 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(answer), updatedAt_);
    }
}
