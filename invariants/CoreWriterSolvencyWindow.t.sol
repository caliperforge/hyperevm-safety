// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CoreWriterSolvency} from "../src/CoreWriterSolvency.sol";

/// @title CoreWriterSolvencyWindow — D-5 property: pre-credited unsettled CoreWriter
///        actions MUST NOT inflate a borrower's solvency view.
/// @notice Spec.md §3.1 D-5. The bug class: a lending protocol treats a CoreWriter
///         submission at block N as if HyperCore-side settlement has already landed,
///         pre-crediting the intended collateral gain on the EVM-side at N. A borrower
///         re-borrows against that inflated state at N+δ (δ < k); HyperCore at N+k
///         later rejects or delays the action; the EVM-side position is now insolvent
///         on the post-rejection accounting view.
///
///         The library's `CoreWriterSolvency.assertSettlementWindowInvariant(user, evmReportedSolvency)`
///         reverts iff `evmReportedSolvency - pendingCredits(user) < 0` — i.e., the
///         user is only solvent because of unsettled credits the protocol pre-counted.
///         A protocol that calls this from every position-mutating entry point cannot
///         be exploited via the settlement-window pre-credit pattern.
///
///         The property below asserts the dual:
///
///           - `GuardedMarket.borrow()` (calls `assertSettlementWindowInvariant`):
///             when an unsettled CoreWriter credit inflates EVM-side collateral, the
///             over-the-honest-line borrow REVERTS. The borrower cannot leverage
///             unsettled credits.
///
///           - `BrokenMarket.borrow()` (no settlement-window check): the inflated
///             borrow lands; when the CoreWriter action is later rejected, the
///             borrower is insolvent on EVM-side accounting AND the protocol's
///             health-factor check at N+k would have failed. The property fires
///             `INVARIANT VIOLATED CoreWriterSolvencyWindow`.
///
/// @dev Same convention as `PrecompileGasDoS.t.sol` and `ChainlinkAdapterDefeats.t.sol`:
///      the broken-pattern reference market lives inside the test file, not `src/`.
///      Both markets share a single share-accounted balance sheet abstraction so
///      the planted-leg twin is a single-localized hunk (call vs no-call to the
///      library's invariant).
///
///      **Simulator caveat (per `docs/hyper-evm-lib-notes.md`).** The property
///      maintains its own pending-action ledger via `CoreWriterSolvency.Ledger`;
///      EVM-block advancement is via `vm.roll`. Neither hyper-evm-lib nor
///      purrkit models the per-action `l1Block` ledger D-5 needs at the test
///      boundary; a Certora CVL spec (planned: T-12 / M3) will be the formal
///      backstop. Not yet in-tree at v0.1.
contract CoreWriterSolvencyWindowTest is Test {
    GuardedMarket internal guarded;
    BrokenMarket internal broken;

    address internal constant ALICE = address(uint160(uint256(keccak256("alice"))));
    address internal constant BOB = address(uint160(uint256(keccak256("bob"))));

    // LTV: borrower can borrow up to 50% of collateral value.
    uint256 internal constant LTV_BPS = 5_000;

    function setUp() public {
        guarded = new GuardedMarket(LTV_BPS);
        broken = new BrokenMarket(LTV_BPS);
        vm.roll(1_000_000);
    }

    // -------------------------------------------------------------------------
    // Property: with no pending CoreWriter actions, both markets behave identically.
    // -------------------------------------------------------------------------

    function test_property_noPending_borrowAtHonestLtv_passes() public {
        // Honest deposit: 1000 collateral, borrow up to 500 (LTV cap).
        guarded.deposit(ALICE, 1_000);
        guarded.borrow(ALICE, 500); // exactly at cap — passes
        assertEq(guarded.debtOf(ALICE), 500);

        broken.deposit(ALICE, 1_000);
        broken.borrow(ALICE, 500);
        assertEq(broken.debtOf(ALICE), 500);
    }

    function test_property_noPending_borrowAboveLtv_revertsOnBoth() public {
        guarded.deposit(ALICE, 1_000);
        vm.expectRevert(); // LTV cap fails — same on both markets
        guarded.borrow(ALICE, 501);

        broken.deposit(ALICE, 1_000);
        vm.expectRevert();
        broken.borrow(ALICE, 501);
    }

    // -------------------------------------------------------------------------
    // Property: with an unsettled CoreWriter credit, the guarded market REVERTS
    // on the inflated borrow; the broken market lets it through (the bug).
    // -------------------------------------------------------------------------

    function test_property_unsettledCredit_guardedRevertsOnInflatedBorrow() public {
        // Alice deposits 1000 honest collateral and the protocol pre-credits
        // an unsettled CoreWriter-incoming-transfer of 1000 — EVM-side total
        // collateral now shows 2000.
        guarded.deposit(ALICE, 1_000);
        bytes32 actionId = keccak256(abi.encode(ALICE, uint256(1)));
        guarded.submitCoreWriterCredit(ALICE, actionId, 1_000);

        // Without the credit, Alice's borrow cap is 500 (50% of 1000 honest).
        // With the credit, the EVM-side view says 1000 (50% of 2000).
        // The guarded market's pessimistic-uncredit check rejects the 750
        // borrow — it would only be solvent because of the unsettled credit.
        // Use try/catch (rather than vm.expectRevert) so the planted-hunk leg
        // — assertSettlementWindowInvariant returns instead of reverting —
        // emits the §5.2 marker on stdout and fails with the marker as the
        // revert reason. Same convention as JellyMarkSwing planted leg.
        bool borrowReverted;
        try guarded.borrow(ALICE, 750) { borrowReverted = false; } catch { borrowReverted = true; }

        if (!borrowReverted) {
            int256 pess = guarded.pessimisticSolvency(ALICE);
            console2.log("INVARIANT VIOLATED CoreWriterSolvencyWindow");
            console2.log("  borrow landed despite unsettled pre-credit inflating capacity");
            console2.log("  alice debt              =", guarded.debtOf(ALICE));
            console2.log("  pessimistic solvency    =", pess);
            revert("INVARIANT VIOLATED CoreWriterSolvencyWindow");
        }
        assertEq(guarded.debtOf(ALICE), 0, "no debt should have accrued");
    }

    function test_property_unsettledCredit_brokenAllowsInflatedBorrow_violation() public {
        broken.deposit(ALICE, 1_000);
        bytes32 actionId = keccak256(abi.encode(ALICE, uint256(1)));
        broken.submitCoreWriterCredit(ALICE, actionId, 1_000);

        // The broken market: no settlement-window check; the inflated borrow
        // lands and Alice walks away with 750 debt against 1000 honest
        // collateral — 75% LTV, above the 50% cap.
        broken.borrow(ALICE, 750);
        assertEq(broken.debtOf(ALICE), 750);

        // Now HyperCore-side settlement REJECTS the CoreWriter action — the
        // pre-credited 1000 never lands. Alice's EVM-side solvency view
        // collapses to (1000 - 750) = 250, well below the 50%-of-1000 cap.
        broken.rejectCoreWriterAction(ALICE, actionId);

        // Alice is now insolvent on the EVM-side honest accounting view that
        // would have been the correct check at borrow time.
        int256 honest = broken.honestSolvency(ALICE);
        assertLt(honest, 0, "broken market: borrower insolvent after rejection (the bug)");
    }

    // -------------------------------------------------------------------------
    // Property: settling the CoreWriter action AFTER it has actually landed
    // makes the credit "real" — the borrow that was previously rejected now
    // passes the guarded check.
    // -------------------------------------------------------------------------

    function test_property_settledCredit_borrowAtElevatedCap_passes() public {
        guarded.deposit(ALICE, 1_000);
        bytes32 actionId = keccak256(abi.encode(ALICE, uint256(1)));
        guarded.submitCoreWriterCredit(ALICE, actionId, 1_000);

        // Advance the chain and mark the action settled — HyperCore confirmed.
        vm.roll(block.number + 2);
        guarded.markCoreWriterSettled(actionId);

        // The credit is no longer "pending" — pessimistic accounting equals
        // EVM-reported. Alice can borrow 750 (still under the 50% cap on
        // 2000 total collateral).
        guarded.borrow(ALICE, 750);
        assertEq(guarded.debtOf(ALICE), 750);
    }

    // -------------------------------------------------------------------------
    // Stateful fuzz: across a randomized submit / borrow / settle sequence,
    // the guarded market NEVER permits a borrower to be insolvent on the
    // pessimistic-uncredit accounting view.
    // -------------------------------------------------------------------------

    function testFuzz_property_statefulSequence_guardedNeverPermitsInsolvency(
        uint8 steps,
        uint256 seed
    ) public {
        uint8 boundedSteps = uint8(steps % 12 + 4);
        // Each user starts with a 1000-unit honest deposit.
        guarded.deposit(ALICE, 1_000);
        guarded.deposit(BOB, 1_000);

        uint256 nonce;
        bytes32[16] memory pendingIds;
        address[16] memory pendingUsers;
        uint8 pendingCount;

        for (uint8 i = 0; i < boundedSteps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address u = (r % 2 == 0) ? ALICE : BOB;
            uint256 action = (r >> 8) % 4;

            if (action == 0) {
                // Submit a pre-credit between 100 and 1000.
                uint256 credit = ((r >> 16) % 901) + 100;
                bytes32 aid = keccak256(abi.encode(u, nonce));
                nonce++;
                guarded.submitCoreWriterCredit(u, aid, int256(credit));
                if (pendingCount < 16) {
                    pendingIds[pendingCount] = aid;
                    pendingUsers[pendingCount] = u;
                    pendingCount++;
                }
            } else if (action == 1) {
                // Try a borrow at a random amount up to the inflated cap.
                uint256 amt = ((r >> 32) % 1_500) + 1;
                try guarded.borrow(u, amt) {
                    // OK: the guard let it through.
                } catch {
                    // OK: the guard rejected it; either above LTV or above
                    // the pessimistic-uncredit threshold.
                }
            } else if (action == 2 && pendingCount > 0) {
                // Settle one pending action.
                uint8 idx = uint8((r >> 40) % pendingCount);
                bytes32 aid = pendingIds[idx];
                try guarded.markCoreWriterSettled(aid) {
                    // Remove from pending list (swap-and-pop).
                    pendingIds[idx] = pendingIds[pendingCount - 1];
                    pendingUsers[idx] = pendingUsers[pendingCount - 1];
                    pendingCount--;
                } catch {
                    // Already settled by a previous duplicate id — tolerate.
                }
            } else {
                // Advance the chain.
                vm.roll(block.number + 1);
            }

            // INVARIANT: at every step, for every user, the pessimistic-
            // uncredit solvency is non-negative on the guarded market.
            // This is the property D-5 codifies.
            int256 pessAlice = guarded.pessimisticSolvency(ALICE);
            int256 pessBob = guarded.pessimisticSolvency(BOB);
            if (pessAlice < 0 || pessBob < 0) {
                console2.log("INVARIANT VIOLATED CoreWriterSolvencyWindow");
                console2.log("  step             =", i);
                console2.log("  pessimistic ALICE=", pessAlice);
                console2.log("  pessimistic BOB  =", pessBob);
                revert("INVARIANT VIOLATED CoreWriterSolvencyWindow");
            }
        }
    }

    // Marker format: `INVARIANT VIOLATED <name>` on stdout — see spec §5.2.
    // The stateful-fuzz property above emits the marker via `console2.log`
    // plus a `revert("INVARIANT VIOLATED ...")` reason on the planted leg.
}

// -----------------------------------------------------------------------------
// Reference markets — the dual leg. Both share a minimal share-accounted
// balance sheet (collateral + debt per user) with an LTV-bounded borrow.
// The ONLY behavioural diff is the call to
// `CoreWriterSolvency.assertSettlementWindowInvariant` in `GuardedMarket.borrow`
// — present in the guarded market, absent in the broken market.
// -----------------------------------------------------------------------------

/// @notice Lending market wired to the library's settlement-window invariant.
/// @dev The CoreWriter action's raw delta is in COLLATERAL units; the library
///      tracks the corresponding SOLVENCY-CAPACITY units (`raw * ltvBps / 10000`)
///      so the pessimistic-uncredit math in `assertSettlementWindowInvariant`
///      composes cleanly. The protocol owns the unit-conversion; the ledger is
///      unit-agnostic. Both submit and reject paths track the raw collateral
///      delta separately so the reject path can unwind the pre-credit cleanly.
contract GuardedMarket {
    using CoreWriterSolvency for CoreWriterSolvency.Ledger;

    error LtvExceeded(address user, uint256 attemptedDebt, uint256 cap);

    uint256 public immutable ltvBps;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;
    CoreWriterSolvency.Ledger internal _ledger;
    mapping(bytes32 => int256) public rawCollateralDelta;

    constructor(uint256 ltvBps_) {
        ltvBps = ltvBps_;
    }

    function deposit(address user, uint256 amount) external {
        collateralOf[user] += amount;
    }

    /// @notice The protocol PRE-CREDITS an in-flight CoreWriter action
    ///         EVM-side, while logging the corresponding solvency-capacity
    ///         credit in the ledger.
    function submitCoreWriterCredit(address user, bytes32 actionId, int256 rawDelta) external {
        int256 solvencyDelta;
        if (rawDelta > 0) {
            collateralOf[user] += uint256(rawDelta);
            solvencyDelta = (rawDelta * int256(ltvBps)) / 10_000;
        } else if (rawDelta < 0) {
            uint256 abs = uint256(-rawDelta);
            require(collateralOf[user] >= abs, "underflow");
            collateralOf[user] -= abs;
            solvencyDelta = (rawDelta * int256(ltvBps)) / 10_000;
        }
        rawCollateralDelta[actionId] = rawDelta;
        _ledger.submit(actionId, user, solvencyDelta);
    }

    function markCoreWriterSettled(bytes32 actionId) external {
        _ledger.markSettled(actionId);
    }

    function rejectCoreWriterAction(address user, bytes32 actionId) external {
        CoreWriterSolvency.PendingAction memory a = _ledger.getAction(actionId);
        require(a.exists && !a.settled, "not pending");
        int256 raw = rawCollateralDelta[actionId];
        if (raw > 0) {
            collateralOf[user] -= uint256(raw);
        } else if (raw < 0) {
            collateralOf[user] += uint256(-raw);
        }
        _ledger.markSettled(actionId);
    }

    function borrow(address user, uint256 amount) external {
        uint256 newDebt = debtOf[user] + amount;
        uint256 cap = (collateralOf[user] * ltvBps) / 10_000;
        if (newDebt > cap) revert LtvExceeded(user, newDebt, cap);
        debtOf[user] = newDebt;
        // evmReportedSolvency = solvency capacity (cap) - debt. The library
        // subtracts unsettled solvency-capacity credits internally.
        int256 evmSolvency = int256(cap) - int256(newDebt);
        _ledger.assertSettlementWindowInvariant(user, evmSolvency);
    }

    function pessimisticSolvency(address user) external view returns (int256) {
        uint256 cap = (collateralOf[user] * ltvBps) / 10_000;
        int256 evm = int256(cap) - int256(debtOf[user]);
        return evm - _ledger.unsettledCreditsOf(user);
    }
}

/// @notice Reference broken market — pre-credits unsettled CoreWriter actions
///         EVM-side WITHOUT consulting the settlement-window invariant. This
///         is the bug class D-5 catches. Present in this test file for
///         documentation purposes ONLY.
contract BrokenMarket {
    error LtvExceeded(address user, uint256 attemptedDebt, uint256 cap);

    uint256 public immutable ltvBps;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    // Track per-user unsettled positive credits so the test can compute the
    // post-rejection honest view. The broken market itself does NOT use
    // these for its borrow check — that's the whole point.
    mapping(address => int256) public unsettledCredits;
    mapping(bytes32 => int256) public actionDelta;
    mapping(bytes32 => address) public actionUser;

    constructor(uint256 ltvBps_) {
        ltvBps = ltvBps_;
    }

    function deposit(address user, uint256 amount) external {
        collateralOf[user] += amount;
    }

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
        actionUser[actionId] = user;
    }

    function rejectCoreWriterAction(address user, bytes32 actionId) external {
        int256 delta = actionDelta[actionId];
        if (delta > 0) {
            collateralOf[user] -= uint256(delta);
            unsettledCredits[user] -= delta;
        } else if (delta < 0) {
            collateralOf[user] += uint256(-delta);
        }
        delete actionDelta[actionId];
        delete actionUser[actionId];
    }

    function borrow(address user, uint256 amount) external {
        // The bug: LTV check uses INFLATED collateral (pre-credited), no
        // pessimistic-uncredit guard.
        uint256 newDebt = debtOf[user] + amount;
        uint256 cap = (collateralOf[user] * ltvBps) / 10_000;
        if (newDebt > cap) revert LtvExceeded(user, newDebt, cap);
        debtOf[user] = newDebt;
    }

    function honestSolvency(address user) external view returns (int256) {
        // The pessimistic-uncredit view the protocol SHOULD have used.
        uint256 cap = (collateralOf[user] * ltvBps) / 10_000;
        int256 evm = int256(cap) - int256(debtOf[user]);
        return evm - unsettledCredits[user];
    }
}
