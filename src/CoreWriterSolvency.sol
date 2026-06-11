// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title CoreWriterSolvency — dual-block-window solvency invariants for CoreWriter actions.
/// @notice D-5 of the differentiated taxonomy (spec.md §3.1). HyperEVM consumers
///         submit actions to the HyperCore CoreWriter sink at block N; HyperCore
///         settles the action at block ≥ N+1 (in practice N+k for some k ≥ 1).
///         The bug class this library guards against: a lending protocol that
///         treats the EVM-side submission as if the HyperCore-side settlement
///         has already landed — pre-crediting collateral or pre-debiting debt
///         based on the *intended* outcome of the unsettled action.
///
///         When a borrower re-borrows or withdraws against the pre-credited
///         state at block N+δ (δ < k), and HyperCore later REJECTS or DELAYS
///         the original action at N+k, the EVM-side accounting view of
///         solvency was a lie. The borrower walks away with a position the
///         pessimistic accounting (action assumed unsettled until confirmed)
///         would never have allowed.
///
///         The defense pattern, encoded by `assertSettlementWindowInvariant`:
///
///           - Track a per-user pending-credit ledger keyed on `actionId`.
///             Each `submit` records the user-intended solvency delta + the
///             EVM-side submission block.
///           - On `markSettled(actionId)`, the credit is removed from the
///             pending bucket — it has been confirmed by HyperCore.
///           - `assertSettlementWindowInvariant(user, evmReportedSolvency)`
///             reverts iff `evmReportedSolvency - pendingCredits(user) < 0`,
///             i.e., the user is only solvent because of unsettled credits
///             the protocol pre-counted.
///
///         The result: a borrower cannot leverage pre-credited collateral
///         from an unsettled CoreWriter action to open a position that would
///         be insolvent if the action is later rejected.
///
/// @dev Property test: `invariants/CoreWriterSolvencyWindow.t.sol`. Across
///      any stateful sequence with a CoreWriter action submitted at block N,
///      no caller is solvent on EVM-side accounting at N+δ if HyperCore-side
///      settlement would render them insolvent at N+k.
///
///      **Simulator caveat (per `docs/hyper-evm-lib-notes.md`).** Neither
///      `hyper-evm-lib` nor `purrkit` models the dual-block window with the
///      per-action `l1Block` ledger D-5 needs at the EVM/test boundary; the
///      property maintains its own ledger here. Advancing the chain via
///      `nextBlock()` (hyper-evm-lib) or `vm.roll` (cheatcode) is the
///      test-side control plane.
///
///      A Certora CVL spec (planned: `formal/certora/CoreWriterSolvency.spec`,
///      T-12 / M3) will be the formal backstop for this invariant; Halmos
///      fallback is per CEO call C1 if CVL cannot model the window cleanly in
///      the spec §6.5 op-hour budget. Neither is in-tree at v0.1.
library CoreWriterSolvency {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The user is insolvent under pessimistic accounting (treat all
    ///         unsettled CoreWriter-credited deltas as if they will not land).
    ///         The signed fields surface the exact arithmetic that breached:
    ///         `evmReportedSolvency` is what the EVM-side accounting reports;
    ///         `pendingCredits` is the sum of unsettled positive deltas for
    ///         the user; the breach is `evmReportedSolvency - pendingCredits < 0`.
    error InsolventInSettlementWindow(
        address user,
        int256 evmReportedSolvency,
        int256 pendingCredits
    );

    /// @notice `submit` was called with an `actionId` that already exists in
    ///         the ledger. Action ids MUST be unique per-submission; the
    ///         submitter is responsible for choosing them (typical pattern:
    ///         `keccak256(abi.encode(user, nonce))`).
    error DuplicateAction(bytes32 actionId);

    /// @notice `markSettled` was called with an `actionId` the ledger does
    ///         not know about. Either the action was never submitted, or it
    ///         has already been settled and pruned.
    error UnknownAction(bytes32 actionId);

    /// @notice `markSettled` was called with an `actionId` already settled.
    ///         The first settlement is the source-of-truth; subsequent ones
    ///         indicate a double-settlement bug in the caller.
    error AlreadySettled(bytes32 actionId);

    // -------------------------------------------------------------------------
    // Ledger — per-user pending-credit tracking. Consumers hold a single
    // `Ledger` storage slot on their own contract and pass a storage pointer
    // into each library call.
    // -------------------------------------------------------------------------

    struct PendingAction {
        address user;
        int256 solvencyDelta;   // signed: positive credits user solvency; negative debits
        uint64 submittedAtBlock; // EVM block.number at submission
        bool exists;             // distinguishes a never-submitted id from a settled one
        bool settled;
    }

    struct Ledger {
        /// @dev Per-action record. Once settled, the entry's `pendingCredits`
        ///      contribution is removed; the record is retained for audit.
        mapping(bytes32 => PendingAction) actions;
        /// @dev Sum of POSITIVE solvencyDelta for unsettled actions per user.
        ///      Only positive deltas count — a negative delta (e.g., a
        ///      withdrawal-style CoreWriter action that REMOVES collateral
        ///      EVM-side and waits for HyperCore confirmation) does not add
        ///      to the pessimistic-uncredit pool; if anything it makes the
        ///      consumer's EVM-side view MORE conservative pre-settlement.
        mapping(address => int256) pendingCredits;
    }

    // -------------------------------------------------------------------------
    // Ledger maintenance
    // -------------------------------------------------------------------------

    /// @notice Record a CoreWriter action submitted at the current EVM block.
    /// @param L Ledger storage pointer.
    /// @param actionId Unique id chosen by the submitter (see error NatSpec).
    /// @param user The user whose solvency is affected by the action.
    /// @param solvencyDelta Signed: positive credits user solvency (e.g., a
    ///        CoreWriter spot-transfer-in the protocol pre-credits EVM-side);
    ///        negative debits (e.g., a withdrawal-style action). Only positive
    ///        deltas contribute to `pendingCredits` — see ledger NatSpec.
    function submit(Ledger storage L, bytes32 actionId, address user, int256 solvencyDelta) internal {
        PendingAction storage a = L.actions[actionId];
        if (a.exists) revert DuplicateAction(actionId);

        a.user = user;
        a.solvencyDelta = solvencyDelta;
        a.submittedAtBlock = uint64(block.number);
        a.exists = true;
        // a.settled remains false.

        if (solvencyDelta > 0) {
            L.pendingCredits[user] += solvencyDelta;
        }
        // Negative deltas (debits) are not added to pendingCredits — they
        // make the EVM-side view MORE conservative pre-settlement; the
        // pessimistic-uncredit math does not need to subtract them again.
    }

    /// @notice Mark `actionId` as settled by HyperCore. Removes its credit
    ///         contribution from the user's `pendingCredits` pool.
    function markSettled(Ledger storage L, bytes32 actionId) internal {
        PendingAction storage a = L.actions[actionId];
        if (!a.exists) revert UnknownAction(actionId);
        if (a.settled) revert AlreadySettled(actionId);

        a.settled = true;
        if (a.solvencyDelta > 0) {
            L.pendingCredits[a.user] -= a.solvencyDelta;
        }
    }

    // -------------------------------------------------------------------------
    // The invariant — the call-site this library exists for.
    // -------------------------------------------------------------------------

    /// @notice Assert that `user` is solvent under pessimistic accounting:
    ///         their EVM-side solvency minus the sum of unsettled positive
    ///         CoreWriter credits MUST be non-negative.
    ///
    ///         A lending protocol calls this from every position-mutating
    ///         entry point (borrow, withdraw, open) AFTER updating the
    ///         EVM-side accounting. If the user is only solvent because of
    ///         unsettled credits, the call reverts and the position-change
    ///         does not land.
    ///
    /// @param L Ledger storage pointer.
    /// @param user The user whose solvency is being asserted.
    /// @param evmReportedSolvency The user's solvency as reported by EVM-side
    ///        accounting (already includes any pre-credited unsettled
    ///        actions). Signed: negative means already insolvent before the
    ///        pessimistic-uncredit step.
    function assertSettlementWindowInvariant(
        Ledger storage L,
        address user,
        int256 evmReportedSolvency
    ) internal view {
        int256 credits = L.pendingCredits[user];
        // If EVM-side accounting is already non-positive, the user is
        // insolvent regardless of the pending bucket.
        // If credits == 0, pessimistic == evmReportedSolvency — same check.
        if (evmReportedSolvency - credits < 0) {
            revert InsolventInSettlementWindow(user, evmReportedSolvency, credits);
        }
    }

    // -------------------------------------------------------------------------
    // Read-only accessors — useful for tests, dashboards, and protocol UIs.
    // -------------------------------------------------------------------------

    /// @notice The sum of unsettled positive solvency-deltas for `user`.
    /// @dev Named `unsettledCreditsOf` (not `pendingCredits`) to avoid the
    ///      argument-dependent-lookup collision with the `Ledger.pendingCredits`
    ///      mapping when consumers wire `using CoreWriterSolvency for Ledger`.
    function unsettledCreditsOf(Ledger storage L, address user) internal view returns (int256) {
        return L.pendingCredits[user];
    }

    /// @notice Read an action record by id. Returns the zero-valued
    ///         `PendingAction` if the id was never submitted (caller MUST
    ///         check the `exists` flag).
    function getAction(Ledger storage L, bytes32 actionId) internal view returns (PendingAction memory) {
        return L.actions[actionId];
    }
}
