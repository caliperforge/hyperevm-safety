// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PrecompileGasGuard} from "../src/PrecompileGasGuard.sol";
import {HyperCorePrecompileAddresses} from "../src/interfaces/IHyperCorePrecompiles.sol";
import {MockPrecompiles} from "./mocks/MockPrecompiles.sol";

/// @title PrecompileGasDoS — D-4 property: a failed precompile call MUST NOT mutate caller state.
/// @notice Spec.md §3.1 D-4. The bug class catches consumer code that *soft-handles*
///         a precompile failure: a `try/catch { lastPrice = 0; }` block or an
///         `if (!success) lastPrice = lastKnown;` branch that treats the failure as
///         a default-value assignment and PROCEEDS. The library's `PrecompileGasGuard`
///         refuses — it reverts on `success=false` AND on empty return data, so the
///         calling transaction unwinds cleanly and no consumer state mutates.
///
///         The property below asserts the dual:
///
///           - `GuardedConsumer.updateMark()` (uses `PrecompileGasGuard.callOrRevert`):
///             when the precompile is healthy, state mutates; when the precompile is
///             induced to revert (`vm.mockCallRevert`), the entire `updateMark` call
///             reverts and `lastPrice` / `updateCount` are unchanged.
///
///           - `BrokenConsumer.updateMark()` (soft-handles failure as zero-default):
///             when the precompile reverts, `lastPrice` becomes 0 and `updateCount`
///             increments. The mirror diverges from the guarded consumer's state and
///             `INVARIANT VIOLATED PrecompileGasDoS` fires.
///
/// @dev Same convention as `ChainlinkAdapterDefeats.t.sol` (T-3): the broken-pattern
///      reference contract lives inside the test file, not in `src/`, so consumers
///      cannot accidentally import it by name. The dual leg makes the bug class
///      legible inline and gives the planted-leg twin a single-localized hunk:
///      swap the guarded consumer for the broken consumer at the property's call
///      site.
///
///      **Simulator caveat (per `docs/hyper-evm-lib-notes.md`).** The all-gas-burn
///      shape of a real HyperCore precompile failure is unmodeled by both
///      `hyper-evm-lib` and `purrkit`; we model the bug class at the call-result
///      level (success=false / empty return data) rather than at gas-consumption.
///      A Halmos symbolic spec (planned: T-8 / M2) will be the formal backstop
///      for the EVM-side state-mutation guarantee; not yet in-tree at v0.1.
contract PrecompileGasDoSTest is Test {
    GuardedConsumer internal guarded;
    BrokenConsumer internal broken;

    uint32 internal constant ASSET = 7;
    uint64 internal constant SEED_PRICE = 100_00_000_000; // 100.0 in 8-decimal
    uint64 internal constant ALT_PRICE = 110_00_000_000;  // 110.0

    function setUp() public {
        guarded = new GuardedConsumer(ASSET);
        broken = new BrokenConsumer(ASSET);
        MockPrecompiles.setMark(ASSET, SEED_PRICE);
    }

    // -------------------------------------------------------------------------
    // Property: healthy precompile — both consumers update state identically.
    // -------------------------------------------------------------------------

    function test_property_healthy_bothUpdate() public {
        guarded.updateMark();
        broken.updateMark();

        assertEq(guarded.lastPrice(), SEED_PRICE, "guarded reads seed");
        assertEq(broken.lastPrice(), SEED_PRICE, "broken reads seed");
        assertEq(guarded.updateCount(), 1);
        assertEq(broken.updateCount(), 1);
    }

    // -------------------------------------------------------------------------
    // Property: precompile reverts — guarded consumer's state is UNCHANGED;
    // broken consumer's state mutates (the bug class).
    // -------------------------------------------------------------------------

    function test_property_precompileReverts_guardedStateUnchanged() public {
        // Prime state with one good read so we can detect any subsequent
        // mutation as a divergence.
        guarded.updateMark();
        uint64 priceBefore = guarded.lastPrice();
        uint64 countBefore = guarded.updateCount();
        assertEq(priceBefore, SEED_PRICE);
        assertEq(countBefore, 1);

        // Induce a precompile failure.
        MockPrecompiles.setPrecompileReverts(HyperCorePrecompileAddresses.MARK, abi.encode(ASSET));

        // The library's defense pattern requires that EITHER the call
        // reverts cleanly AND state is unchanged, OR the call succeeds with
        // a real value (no default-zero). Any other outcome — state mutation
        // accompanied by a soft-failure shape — is the bug class. We detect
        // it via manual try/catch (rather than vm.expectRevert) so we can
        // emit the marker on stdout and fail with the marker as the revert
        // reason, matching the §5.2 CI grep convention used by the JELLY
        // and XYZ100 incident planted-leg tests.
        bool reverted;
        try guarded.updateMark() { reverted = false; } catch { reverted = true; }
        uint64 priceAfter = guarded.lastPrice();
        uint64 countAfter = guarded.updateCount();

        bool stateChanged = (priceAfter != priceBefore) || (countAfter != countBefore);
        bool takesDefault = (countAfter > countBefore) && (priceAfter == 0);
        if (!reverted && stateChanged) {
            // Library returned without reverting on a failed precompile call
            // AND consumer state mutated. The single-localized planted hunk
            // (replace `callOrRevert`'s revert with a return of empty bytes)
            // reproduces this leg.
            console2.log("INVARIANT VIOLATED PrecompileGasDoS");
            console2.log("  reverted        =", reverted);
            console2.log("  takesDefault    =", takesDefault);
            console2.log("  priceBefore     =", priceBefore);
            console2.log("  priceAfter      =", priceAfter);
            console2.log("  countBefore     =", countBefore);
            console2.log("  countAfter      =", countAfter);
            revert("INVARIANT VIOLATED PrecompileGasDoS");
        }
        if (reverted && stateChanged) {
            // Library reverted but state somehow mutated — would require a
            // re-entrant write or storage corruption; included for symmetry.
            console2.log("INVARIANT VIOLATED PrecompileGasDoS");
            console2.log("  state mutated despite revert");
            revert("INVARIANT VIOLATED PrecompileGasDoS");
        }
        // Clean leg: the library reverted and state is at the snapshot.
        assertTrue(reverted, "clean leg: callOrRevert MUST revert on precompile failure");
        assertEq(priceAfter, priceBefore, "guarded lastPrice MUST NOT change on failed precompile");
        assertEq(countAfter, countBefore, "guarded updateCount MUST NOT increment on failed precompile");
    }

    function test_property_precompileReverts_brokenStateMutates_violation() public {
        // Prime state.
        broken.updateMark();
        assertEq(broken.lastPrice(), SEED_PRICE);
        assertEq(broken.updateCount(), 1);

        // Induce a precompile failure.
        MockPrecompiles.setPrecompileReverts(HyperCorePrecompileAddresses.MARK, abi.encode(ASSET));

        // The broken path silently consumes the failure as a zero-default
        // assignment — this is the bug class D-4 catches.
        broken.updateMark();

        // The bug manifests: lastPrice is now 0 (the broken consumer's
        // default-on-failure value); updateCount incremented as if the
        // read had succeeded.
        assertEq(broken.lastPrice(), 0, "broken consumer takes default-zero on failure (the bug)");
        assertEq(broken.updateCount(), 2, "broken consumer increments on failure (the bug)");
    }

    // -------------------------------------------------------------------------
    // Property: empty return data is treated as failure (the simulator-
    // visible shape of the all-gas-consumed surface; see T-7 NatSpec).
    // -------------------------------------------------------------------------

    function test_property_emptyReturn_guardedReverts() public {
        // Register an empty-bytes return — distinct from a revert; this
        // is the success=true path with zero-length data.
        vm.mockCall(HyperCorePrecompileAddresses.MARK, abi.encode(ASSET), bytes(""));

        vm.expectRevert(); // PrecompileEmptyReturn(...)
        guarded.updateMark();

        assertEq(guarded.lastPrice(), 0, "no prior write");
        assertEq(guarded.updateCount(), 0, "no increment on empty return");
    }

    // -------------------------------------------------------------------------
    // Stateful property: across an arbitrary read/revert sequence, the
    // guarded consumer's `lastPrice` always reflects a healthy read; never
    // a default-zero.
    // -------------------------------------------------------------------------

    function testFuzz_property_statefulSequence_guardedNeverTakesDefault(uint8 steps, uint64 priceSeed) public {
        uint8 boundedSteps = uint8(steps % 16 + 1);
        uint64 lastHealthyPrice;

        for (uint8 i = 0; i < boundedSteps; i++) {
            // Pseudo-random adversarial selection: every 3rd step toggles the
            // precompile to a revert, then back. The schedule is deterministic
            // given the seed — fuzz reproduces failures.
            bool induceRevert = (uint256(keccak256(abi.encode(priceSeed, i))) % 3) == 0;

            if (induceRevert) {
                MockPrecompiles.setPrecompileReverts(
                    HyperCorePrecompileAddresses.MARK, abi.encode(ASSET)
                );
                vm.expectRevert();
                guarded.updateMark();
            } else {
                // Step a healthy price. Clear any prior revert mock first.
                uint64 px = uint64(uint256(keccak256(abi.encode(priceSeed, i, "px"))) % 1_000_000_000_000) + 1;
                MockPrecompiles.setMark(ASSET, px);
                guarded.updateMark();
                lastHealthyPrice = px;
            }

            // Invariant: at every step, the guarded consumer's `lastPrice` is
            // either zero (no healthy read landed yet) or matches the last
            // healthy read. It is NEVER a default-on-failure value induced by
            // an unhealthy read.
            uint64 obs = guarded.lastPrice();
            if (lastHealthyPrice == 0) {
                assertEq(obs, 0, "no healthy read yet -- lastPrice MUST be zero");
            } else {
                assertEq(obs, lastHealthyPrice, "lastPrice MUST equal most recent healthy read");
            }
        }
    }

    // Marker format: `INVARIANT VIOLATED <name>` on stdout — see spec §5.2.
    // Emitted by the planted-leg twin (a single-localized hunk swap of
    // `guarded` for `broken` at the property call sites) via the stateful-
    // fuzz property's `console2.log` + revert string. The clean leg passes
    // silently.
}

// -----------------------------------------------------------------------------
// Reference consumers — the dual leg. The guarded consumer uses
// `PrecompileGasGuard.callOrRevert` (the library's defense pattern); the
// broken consumer encodes the bug class (`try/catch { default; }`).
//
// These live in the test file, NOT in `src/`, for the same reason
// `BrokenChainlinkAdapter` does in `ChainlinkAdapterDefeats.t.sol`: they are
// documented bug-class models, not part of the library's public surface.
// -----------------------------------------------------------------------------

/// @notice Consumer that routes its precompile read through the library's
///         DoS-resilient wrapper. Per D-4 NatSpec: a failed precompile reverts
///         the calling transaction and no state mutates.
contract GuardedConsumer {
    uint64 public lastPrice;
    uint64 public updateCount;
    uint32 public immutable asset;

    constructor(uint32 asset_) {
        asset = asset_;
    }

    function updateMark() external {
        bytes memory ret = PrecompileGasGuard.callOrRevert(
            HyperCorePrecompileAddresses.MARK, abi.encode(asset)
        );
        uint64 px = abi.decode(ret, (uint64));
        lastPrice = px;
        updateCount = updateCount + 1;
    }
}

/// @notice Reference broken consumer — encodes the bug class D-4 catches.
///         The `try/catch` block treats a failed precompile read as a default
///         zero and proceeds with state mutation. PRESENT IN THE TEST FILE
///         FOR DOCUMENTATION PURPOSES ONLY.
contract BrokenConsumer {
    uint64 public lastPrice;
    uint64 public updateCount;
    uint32 public immutable asset;

    constructor(uint32 asset_) {
        asset = asset_;
    }

    function updateMark() external {
        // The bug: success=false (or any revert) is silently absorbed into
        // a default-zero assignment. The state STILL mutates.
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
