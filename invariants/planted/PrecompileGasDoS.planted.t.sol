// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PrecompileGasGuard} from "../../src/PrecompileGasGuard.sol";
import {HyperCorePrecompileAddresses} from "../../src/interfaces/IHyperCorePrecompiles.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";

/// @title PrecompileGasDoS (planted) — D-4 planted twin: soft-handling a failed
///        precompile call allows caller state to mutate and fires
///        `INVARIANT VIOLATED PrecompileGasDoS`.
///
/// @notice D-4 planted twin (spec.md §3.1 D-4). Counterpart to
///         `invariants/PrecompileGasDoS.t.sol`. The `BrokenConsumerPlanted`
///         defined here is identical to `BrokenConsumer` in the clean file
///         (redefined inline for self-containment — same convention as
///         `BrokenChainlinkAdapterPlanted` in the D-6 planted twin).
///
///         The planted hunk is the single-localized swap:
///
///           clean: `try guarded.updateMark() { ... } catch { ... }`
///                   → guarded consumer REVERTS on failure, state unchanged ✓
///           planted: `try broken.updateMark() { ... } catch { ... }`
///                    → broken consumer absorbs failure as zero-default,
///                      state mutates, marker fires ✗
///
///         Scenario:
///           1. Prime `BrokenConsumerPlanted` with SEED_PRICE via a healthy
///              precompile call.
///           2. Induce a precompile failure (`MockPrecompiles.setPrecompileReverts`).
///           3. The broken consumer's `updateMark()`: bare `staticcall` returns
///              `success=false`; the `if (ok && ret.length >= 32)` branch is
///              skipped; `lastPrice` becomes 0 and `updateCount` increments.
///           4. `reverted=false`, `stateChanged=true` → marker fires.
///
/// @dev CI spec (§5.2): planted leg exits non-zero with at least one
///      `INVARIANT VIOLATED PrecompileGasDoS` line on stdout.
///      Twin diff vs clean file: 1 localized hunk — `guarded` → `broken`
///      in `test_property_planted_precompileReverts_stateViolated()` and its
///      fuzz companion.

// ---------------------------------------------------------------------------
// Reference broken consumer — identical to BrokenConsumer in the clean file.
// Redefined inline so this file is self-contained (no test-to-test import).
// ---------------------------------------------------------------------------

/// @notice Encodes the D-4 bug class: a failed precompile call is silently
///         absorbed as a zero-default assignment and the caller's state still
///         mutates.  NOT in `src/` — present for planted-twin CI only.
///         Same logic as `BrokenConsumer` in `PrecompileGasDoS.t.sol`.
contract BrokenConsumerPlanted {
    uint64 public lastPrice;
    uint64 public updateCount;
    uint32 public immutable asset;

    constructor(uint32 asset_) {
        asset = asset_;
    }

    /// @notice PLANTED: bare staticcall; `success=false` or empty-return
    ///         absorbs as a zero-default; state STILL mutates.
    function updateMark() external {
        // BUG: success=false (or any revert) is silently absorbed as a
        // zero-default assignment. updateCount still increments.
        (bool ok, bytes memory ret) =
            HyperCorePrecompileAddresses.MARK.staticcall(abi.encode(asset));
        uint64 px;
        if (ok && ret.length >= 32) {
            px = abi.decode(ret, (uint64));
        }
        // px stays 0 on failure — the bug class. updateCount still ticks.
        lastPrice = px;
        updateCount = updateCount + 1;
    }
}

// ---------------------------------------------------------------------------
// Planted test — the property fires deterministically for any primed-price.
// ---------------------------------------------------------------------------

contract PrecompileGasDoSPlantedTest is Test {
    BrokenConsumerPlanted internal broken;

    uint32 internal constant ASSET      = 7;
    uint64 internal constant SEED_PRICE = 100_00_000_000; // 100.0 in 8-decimal

    function setUp() public {
        broken = new BrokenConsumerPlanted(ASSET);
        MockPrecompiles.setMark(ASSET, SEED_PRICE);
    }

    // -------------------------------------------------------------------------
    // Planted property: precompile reverts → broken consumer's state mutates.
    // D-4 invariant requires state MUST NOT change on a failed precompile call.
    // Single-hunk change from clean: `guarded` → `broken`.
    // -------------------------------------------------------------------------

    /// @notice Deterministic witness: prime SEED_PRICE, induce failure, broken
    ///         consumer absorbs it as default-zero — state mutates, marker fires.
    function test_property_planted_precompileReverts_stateViolated() public {
        // Prime state with one healthy read.
        broken.updateMark();
        uint64 priceBefore = broken.lastPrice();
        uint64 countBefore = broken.updateCount();
        assertEq(priceBefore, SEED_PRICE, "primed to seed price");
        assertEq(countBefore, 1,          "update count = 1 after healthy read");

        // Induce a precompile failure.
        MockPrecompiles.setPrecompileReverts(
            HyperCorePrecompileAddresses.MARK, abi.encode(ASSET)
        );

        // PLANTED: `try broken.updateMark()` instead of `try guarded.updateMark()`.
        // The broken consumer does NOT revert — it absorbs the failure as zero-default.
        bool reverted;
        try broken.updateMark() { reverted = false; } catch { reverted = true; }
        uint64 priceAfter = broken.lastPrice();
        uint64 countAfter = broken.updateCount();

        bool stateChanged = (priceAfter != priceBefore) || (countAfter != countBefore);

        // Invariant: any consumer that does NOT revert on a failed precompile call
        // AND mutates state has violated D-4.
        if (!reverted && stateChanged) {
            console2.log("INVARIANT VIOLATED PrecompileGasDoS");
            console2.log("  reverted        =", reverted);
            console2.log("  priceBefore     =", priceBefore);
            console2.log("  priceAfter      =", priceAfter);
            console2.log("  countBefore     =", countBefore);
            console2.log("  countAfter      =", countAfter);
            console2.log("  (broken consumer absorbed failure as zero-default; state mutated)");
            revert("INVARIANT VIOLATED PrecompileGasDoS");
        }
    }

    /// @notice Fuzz sweep: for any primed price, the broken consumer always
    ///         mutates state on a precompile failure.  Marker fires every run.
    function testFuzz_property_planted_anyPrice_stateViolated(uint64 seedPrice) public {
        // Bound to non-zero so we can detect the zero-default mutation.
        uint64 bounded = uint64(uint256(seedPrice) % 1_000_000_000_000) + 1;
        MockPrecompiles.setMark(ASSET, bounded);

        broken.updateMark();
        uint64 priceBefore = broken.lastPrice();
        uint64 countBefore = broken.updateCount();

        MockPrecompiles.setPrecompileReverts(
            HyperCorePrecompileAddresses.MARK, abi.encode(ASSET)
        );

        bool reverted;
        try broken.updateMark() { reverted = false; } catch { reverted = true; }
        uint64 priceAfter = broken.lastPrice();
        uint64 countAfter = broken.updateCount();

        bool stateChanged = (priceAfter != priceBefore) || (countAfter != countBefore);

        if (!reverted && stateChanged) {
            console2.log("INVARIANT VIOLATED PrecompileGasDoS");
            console2.log("  seedPrice   =", bounded);
            console2.log("  priceBefore =", priceBefore);
            console2.log("  priceAfter  =", priceAfter);
            console2.log("  countBefore =", countBefore);
            console2.log("  countAfter  =", countAfter);
            revert("INVARIANT VIOLATED PrecompileGasDoS");
        }
    }
}
