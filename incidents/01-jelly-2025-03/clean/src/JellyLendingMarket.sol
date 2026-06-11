// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {HyperCoreOracleGuard} from "hyperevm-safety/src/HyperCoreOracleGuard.sol";

/// @dev Minimal ERC20 surface used by the JELLY twin — `transferFrom` /
///      `transfer` / `balanceOf` are the only methods the market needs. Kept
///      inline so the incident has zero external deps beyond `forge-std` and
///      the parent `hyperevm-safety` library.
interface IMinimalERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title JellyLendingMarket — minimal lending market wired against a
///        HyperCore perp mark for collateral valuation + liquidation decisions.
/// @notice Spec §T-5 — the canonical surface the JELLY twin pair exercises.
///         A borrower deposits collateral, draws debt against an LTV cap, and
///         can be liquidated when their health factor falls below the
///         liquidation threshold. Both LTV checks AND the liquidation
///         decision are priced off `_readGuardedMark()` — the same internal
///         function whose body is the **only line the clean→planted twin
///         differs on**.
///
///         The bug class JELLY exercises (spec §4.1): an attacker self-trades
///         a thin-liquidity HIP-1 perp to swing the mark, then forces
///         downstream lending protocols that consumed `0x806` unguarded to
///         liquidate borrowers who were actually solvent at the honest price.
///
///         Clean leg (this file): `_readGuardedMark()` calls
///         `HyperCoreOracleGuard.readMarkWithDeviationBound(asset)` — a
///         TWAP-bounded read that reverts `Deviation()` when the current
///         sample falls outside `maxDeviationBps` of the trailing window.
///         A manipulated-mark swing trips the gate before any liquidation
///         engages.
///
///         Planted leg (sibling `../planted/src/JellyLendingMarket.sol`):
///         single localized hunk swaps `readMarkWithDeviationBound` for the
///         staleness-only `readMark` — the deviation gate is removed. The
///         manipulated mark passes through and the liquidation engages on a
///         price the borrower's collateral never honestly traded at.
///
/// @dev **NOT production code.** No access control, no interest accrual, no
///      partial-liquidation incentives, no per-asset configuration. The
///      market is a reproduction-grade scaffold for the bug class only.
///
///      Health-factor convention: `health_bps = collateralValue_bps / debt`
///      where both numerator and denominator are USD-denominated at the
///      mark's 8-decimal precision. A borrower is liquidatable when
///      `health_bps < LIQ_THRESHOLD_BPS`. At deposit/borrow time, debt is
///      capped at `MAX_LTV_BPS * collateralValue / 10_000`.
contract JellyLendingMarket {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAmount();
    error InsufficientCollateral(uint256 requested, uint256 held);
    error TransferFailed();
    error InvalidConfig();
    error LtvExceeded(uint256 wouldBeDebt, uint256 maxDebt);
    error Healthy(uint256 healthBps, uint256 threshold);
    error NoDebt();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 usdAmount, uint64 markUsed);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 seizedCollateral,
        uint256 clearedDebt,
        uint64 markUsed
    );

    // -------------------------------------------------------------------------
    // Configuration — immutable, set at construction.
    // -------------------------------------------------------------------------

    IMinimalERC20 public immutable collateral;
    uint8 public immutable collateralDecimals;
    HyperCoreOracleGuard public immutable guard;
    uint32 public immutable asset;

    /// @notice Maximum LTV at borrow time. 5000 bps = 50% — a borrower with
    ///         $10k of collateral can draw up to $5k of debt.
    uint16 public immutable maxLtvBps;

    /// @notice Health below which liquidation is permitted. 8000 bps = 80% —
    ///         once collateralValue / debt drops below this, the borrower is
    ///         eligible for liquidation. Strictly higher than `maxLtvBps`
    ///         leaves a buffer between healthy and liquidatable.
    uint16 public immutable liquidationThresholdBps;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    mapping(address => uint256) public collateralOf;
    /// @notice Debt denominated in USD * 1e8 (matches the HyperCore mark's
    ///         8-decimal answer precision, so health-factor math is
    ///         scale-clean).
    mapping(address => uint256) public debtOf;

    constructor(
        IMinimalERC20 collateral_,
        uint8 collateralDecimals_,
        HyperCoreOracleGuard guard_,
        uint32 asset_,
        uint16 maxLtvBps_,
        uint16 liquidationThresholdBps_
    ) {
        if (
            address(collateral_) == address(0)
                || address(guard_) == address(0)
                || collateralDecimals_ == 0
                || collateralDecimals_ > 36
                || maxLtvBps_ == 0
                || maxLtvBps_ > 10_000
                || liquidationThresholdBps_ <= maxLtvBps_
                || liquidationThresholdBps_ > 10_000
        ) {
            revert InvalidConfig();
        }
        collateral = collateral_;
        collateralDecimals = collateralDecimals_;
        guard = guard_;
        asset = asset_;
        maxLtvBps = maxLtvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
    }

    // -------------------------------------------------------------------------
    // Collateral lifecycle
    // -------------------------------------------------------------------------

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        collateralOf[msg.sender] += amount;
        if (!collateral.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Deposit(msg.sender, amount);
    }

    /// @notice Withdraw collateral. Reverts if the withdrawal would drop the
    ///         borrower's health below the liquidation threshold (a debt
    ///         holder can't withdraw themselves into a liquidatable state).
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 held = collateralOf[msg.sender];
        if (amount > held) revert InsufficientCollateral(amount, held);

        uint256 remainingCollateral = held - amount;
        if (debtOf[msg.sender] > 0) {
            uint64 mark = _readGuardedMark();
            uint256 healthBps = _healthBps(remainingCollateral, debtOf[msg.sender], mark);
            if (healthBps < liquidationThresholdBps) {
                revert LtvExceeded(debtOf[msg.sender], _maxDebtAtMark(remainingCollateral, mark));
            }
        }

        collateralOf[msg.sender] = remainingCollateral;
        if (!collateral.transfer(msg.sender, amount)) revert TransferFailed();
        emit Withdraw(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Borrow / liquidate — both consume the guarded mark.
    // -------------------------------------------------------------------------

    /// @notice Draw `usdAmount` of debt against the caller's collateral. The
    ///         resulting debt must satisfy `debt <= maxLtvBps * collateralValue`.
    ///         A real protocol would transfer a borrow asset here; the twin
    ///         tracks debt as an internal counter only — sufficient for the
    ///         bug-class reproduction.
    function borrow(uint256 usdAmount) external {
        if (usdAmount == 0) revert ZeroAmount();
        uint64 mark = _readGuardedMark();
        uint256 wouldBeDebt = debtOf[msg.sender] + usdAmount;
        uint256 maxDebt = _maxDebtAtMark(collateralOf[msg.sender], mark);
        if (wouldBeDebt > maxDebt) revert LtvExceeded(wouldBeDebt, maxDebt);

        debtOf[msg.sender] = wouldBeDebt;
        emit Borrow(msg.sender, usdAmount, mark);
    }

    /// @notice Liquidate `borrower` when their health factor falls below the
    ///         threshold. Simplified seizure: the liquidator takes all of the
    ///         borrower's collateral, and the borrower's debt is cleared.
    ///         (A real protocol partial-liquidates and pays a bonus — the
    ///         twin's all-or-nothing form is sufficient to surface the
    ///         "liquidation succeeded against a manipulated mark" invariant
    ///         violation in the planted leg.)
    function liquidate(address borrower) external {
        if (debtOf[borrower] == 0) revert NoDebt();
        uint64 mark = _readGuardedMark();
        uint256 healthBps = _healthBps(collateralOf[borrower], debtOf[borrower], mark);
        if (healthBps >= liquidationThresholdBps) revert Healthy(healthBps, liquidationThresholdBps);

        uint256 seized = collateralOf[borrower];
        uint256 clearedDebt = debtOf[borrower];
        collateralOf[borrower] = 0;
        debtOf[borrower] = 0;
        if (!collateral.transfer(msg.sender, seized)) revert TransferFailed();
        emit Liquidate(msg.sender, borrower, seized, clearedDebt, mark);
    }

    // -------------------------------------------------------------------------
    // Views — the property test calls `healthBpsAtPrice` to compute the
    // borrower's honest health at a known-good mark and compare against the
    // outcome the manipulated mark produced. This is the test-side reference
    // for the LiquidationSoundness invariant.
    // -------------------------------------------------------------------------

    function healthBpsAtPrice(address user, uint64 honestPrice) external view returns (uint256) {
        if (debtOf[user] == 0) return type(uint256).max;
        return _healthBps(collateralOf[user], debtOf[user], honestPrice);
    }

    function maxDebtAtPrice(address user, uint64 mark) external view returns (uint256) {
        return _maxDebtAtMark(collateralOf[user], mark);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev The one and only mark-read function. The clean leg uses the
    ///      deviation-bounded path; the planted leg swaps to the
    ///      staleness-only path. This is the localized hunk the twin
    ///      diff targets.
    ///
    ///      Clean: `readMarkWithDeviationBound` warms the guard's trailing
    ///      window in place and reverts `Deviation()` if the sample falls
    ///      outside `maxDeviationBps` of the TWAP.
    function _readGuardedMark() internal returns (uint64) {
        return guard.readMarkWithDeviationBound(asset);
    }

    function _healthBps(uint256 amountCollateral, uint256 debt, uint64 markPrice)
        internal
        view
        returns (uint256)
    {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = (amountCollateral * uint256(markPrice)) / (10 ** uint256(collateralDecimals));
        return (collateralValue * 10_000) / debt;
    }

    function _maxDebtAtMark(uint256 amountCollateral, uint64 markPrice) internal view returns (uint256) {
        uint256 collateralValue = (amountCollateral * uint256(markPrice)) / (10 ** uint256(collateralDecimals));
        return (collateralValue * uint256(maxLtvBps)) / 10_000;
    }
}
