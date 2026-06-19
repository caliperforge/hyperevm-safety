// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CoreWriterSolvency} from "../../src/CoreWriterSolvency.sol";

/// @title CoreWriterSolvencyWindow (planted) — D-5 planted twin: omitting the
///        `assertSettlementWindowInvariant` guard lets an unsettled CoreWriter
///        pre-credit inflate borrower capacity, firing
///        `INVARIANT VIOLATED CoreWriterSolvencyWindow`.
///
/// @notice D-5 planted twin (spec.md §3.1 D-5). Counterpart to
///         `invariants/CoreWriterSolvencyWindow.t.sol`. The `BrokenMarketPlanted`
///         contract defined here is equivalent to `BrokenMarket` in the clean
///         file (redefined inline for self-containment — same convention as the
///         sibling planted twins for D-3, D-4, D-6).
///
///         The planted hunk is the single-localized omission:
///
///           clean: `GuardedMarket.borrow()` calls
///                  `_ledger.assertSettlementWindowInvariant(user, evmSolvency)`
///                  after the LTV check → borrow REVERTS if unsettled credits
///                  inflate capacity above the honest bound.
///           planted: `BrokenMarketPlanted.borrow()` omits that call → the
///                    inflated borrow lands → pessimistic solvency goes
///                    negative → marker fires.
///
///         Scenario:
///           1. ALICE deposits 1000 honest collateral (honest cap = 500 at 50% LTV).
///           2. Protocol pre-credits an unsettled CoreWriter transfer of 1000
///              EVM-side: inflated collateral = 2000, inflated cap = 1000.
///           3. ALICE borrows 750 (> honest cap of 500, < inflated cap of 1000).
///           4. Clean (guarded) market: `assertSettlementWindowInvariant` fires,
///              borrow reverts.
///           5. Planted (broken) market: no guard, borrow lands, debt = 750.
///              Pessimistic solvency = (1000−750) − 1000 unsettled = −750 < 0.
///           6. Marker fires: `INVARIANT VIOLATED CoreWriterSolvencyWindow`.
///
/// @dev CI spec (§5.2): planted leg exits non-zero with at least one
///      `INVARIANT VIOLATED CoreWriterSolvencyWindow` line on stdout.
///      Twin diff vs clean file: 1 localized hunk — `assertSettlementWindowInvariant`
///      call absent from `BrokenMarketPlanted.borrow()`.

// ---------------------------------------------------------------------------
// Reference broken market — equivalent to BrokenMarket in the clean file.
// Redefined inline so this file is self-contained (no test-to-test import).
// Minimal interface: only the functions exercised by the planted tests below.
// ---------------------------------------------------------------------------

/// @notice Lending market that pre-credits CoreWriter actions EVM-side WITHOUT
///         consulting the settlement-window invariant. Encodes the D-5 bug class.
///         NOT in `src/` — present for planted-twin CI only.
///         Equivalent to `BrokenMarket` in `CoreWriterSolvencyWindow.t.sol`.
contract BrokenMarketPlanted {
    error LtvExceeded(address user, uint256 attemptedDebt, uint256 cap);

    uint256 public immutable ltvBps;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    // Track per-user unsettled positive credits so `pessimisticSolvency` can
    // report the correct pessimistic view (matching GuardedMarket's predicate).
    mapping(address => int256) public unsettledCredits;
    mapping(bytes32 => int256) public actionDelta;

    constructor(uint256 ltvBps_) {
        ltvBps = ltvBps_;
    }

    function deposit(address user, uint256 amount) external {
        collateralOf[user] += amount;
    }

    /// @notice Pre-credits an in-flight CoreWriter action EVM-side and logs
    ///         the unsettled credit.  Identical to `BrokenMarket.submitCoreWriterCredit`.
    function submitCoreWriterCredit(address user, bytes32 actionId, int256 delta) external {
        if (delta > 0) {
            collateralOf[user] += uint256(delta);
            unsettledCredits[user] += delta;
        } else if (delta < 0) {
            uint256 abs = uint256(-delta);
            require(collateralOf[user] >= abs, "underflow");
            collateralOf[user] -= abs;
        }
        actionDelta[actionId] = delta;
    }

    /// @notice PLANTED: LTV check uses INFLATED collateral; no
    ///         `assertSettlementWindowInvariant` call. This is the single
    ///         localized hunk that the clean counterpart (`GuardedMarket.borrow`)
    ///         closes with the library guard.
    function borrow(address user, uint256 amount) external {
        uint256 newDebt = debtOf[user] + amount;
        uint256 cap = (collateralOf[user] * ltvBps) / 10_000;
        if (newDebt > cap) revert LtvExceeded(user, newDebt, cap);
        // BUG: no `_ledger.assertSettlementWindowInvariant(user, evmSolvency)`.
        // The inflated collateral (pre-credited but unsettled) is treated as real.
        debtOf[user] = newDebt;
    }

    /// @notice Pessimistic solvency: EVM-reported solvency capacity minus ALL
    ///         unsettled credits — the check `assertSettlementWindowInvariant`
    ///         enforces in the guarded market.
    function pessimisticSolvency(address user) external view returns (int256) {
        uint256 cap = (collateralOf[user] * ltvBps) / 10_000;
        int256 evm = int256(cap) - int256(debtOf[user]);
        return evm - unsettledCredits[user];
    }
}

// ---------------------------------------------------------------------------
// Planted test — the property fires deterministically for any above-cap borrow.
// ---------------------------------------------------------------------------

contract CoreWriterSolvencyWindowPlantedTest is Test {
    BrokenMarketPlanted internal broken;

    address internal constant ALICE = address(uint160(uint256(keccak256("alice"))));
    uint256 internal constant LTV_BPS = 5_000; // 50%

    function setUp() public {
        broken = new BrokenMarketPlanted(LTV_BPS);
        vm.roll(1_000_000);
    }

    // -------------------------------------------------------------------------
    // Planted property: broken market allows inflated borrow; pessimistic
    // solvency is negative; marker fires.
    // Single-hunk change from clean: `guarded` → `broken` (which omits the
    // `assertSettlementWindowInvariant` call from `borrow()`).
    // -------------------------------------------------------------------------

    /// @notice Deterministic witness: ALICE deposits 1000, pre-credits 1000,
    ///         borrows 750 (above honest cap 500, below inflated cap 1000).
    ///         Broken market lets the borrow land; marker fires.
    function test_property_planted_unsettledCredit_borrowLands_invariantViolated() public {
        broken.deposit(ALICE, 1_000);
        bytes32 actionId = keccak256(abi.encode(ALICE, uint256(1)));
        broken.submitCoreWriterCredit(ALICE, actionId, int256(1_000));

        // 750 > honest cap (500) but < inflated cap (1000).
        // The guarded market would revert here; the broken market lets it through.
        bool borrowReverted;
        try broken.borrow(ALICE, 750) { borrowReverted = false; } catch { borrowReverted = true; }

        if (!borrowReverted) {
            int256 pess = broken.pessimisticSolvency(ALICE);
            console2.log("INVARIANT VIOLATED CoreWriterSolvencyWindow");
            console2.log("  borrow of 750 landed on inflated collateral");
            console2.log("  honest deposit      = 1000");
            console2.log("  unsettled credit    = 1000  (inflated collateral to 2000)");
            console2.log("  alice debt          =", broken.debtOf(ALICE));
            console2.log("  pessimistic solvency=", pess);
            console2.log("  (broken market: no assertSettlementWindowInvariant call in borrow)");
            revert("INVARIANT VIOLATED CoreWriterSolvencyWindow");
        }
    }

    /// @notice Fuzz sweep: for any borrow amount in (honestCap, inflatedCap],
    ///         the broken market lets it through. Marker fires every run
    ///         because the inflated cap is always 1000 and honest cap is 500.
    function testFuzz_property_planted_borrowAboveHonestCap_invariantViolated(
        uint64 overCap
    ) public {
        // honestCap = 500 (50% of 1000 honest collateral)
        // inflatedCap = 1000 (50% of 2000 including pre-credit of 1000)
        // overCap: amount above the honest cap; bounded so borrow ≤ inflatedCap.
        uint256 borrowOver = uint256(overCap % 499) + 1; // 1..499 → borrow 501..999
        uint256 borrowAmt = 500 + borrowOver;

        broken.deposit(ALICE, 1_000);
        bytes32 actionId = keccak256(abi.encode(ALICE, uint256(1)));
        broken.submitCoreWriterCredit(ALICE, actionId, int256(1_000));
        // inflated cap = 1000; borrowAmt ≤ 999 < 1000 → always passes LTV check

        bool borrowReverted;
        try broken.borrow(ALICE, borrowAmt) { borrowReverted = false; } catch { borrowReverted = true; }

        if (!borrowReverted) {
            int256 pess = broken.pessimisticSolvency(ALICE);
            console2.log("INVARIANT VIOLATED CoreWriterSolvencyWindow");
            console2.log("  borrowAmt        =", borrowAmt);
            console2.log("  overCap          =", borrowOver);
            console2.log("  pessimistic pess =", pess);
            revert("INVARIANT VIOLATED CoreWriterSolvencyWindow");
        }
    }
}
