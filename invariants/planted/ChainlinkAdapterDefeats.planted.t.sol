// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {HyperCorePrecompileAddresses} from "../../src/interfaces/IHyperCorePrecompiles.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";

/// @title ChainlinkAdapterDefeats (planted) — D-6 planted twin: the broken
///        adapter's `updatedAt = block.timestamp` silently defeats the
///        downstream staleness check under a HyperCore freeze, and the test
///        fires `INVARIANT VIOLATED ChainlinkAdapterDefeatsStaleness`.
///
/// @notice D-6 planted twin (spec.md §3.1 D-6). Counterpart to
///         `invariants/ChainlinkAdapterDefeats.t.sol`. The `BrokenChainlinkAdapter`
///         defined here is identical to the one in the clean file (redefined
///         inline for self-containment). The planted leg exercises the freeze
///         scenario and asserts the broken adapter's staleness check PASSES when
///         it should FAIL — that silence is the invariant violation.
///
///         Scenario (steady state → freeze):
///           1. L1 block = 100_000; EVM timestamp aligned to publish ts.
///           2. Freeze: advance EVM wall-clock by stalenessBound+1 seconds,
///              L1 block FROZEN.
///           3. `brokenAdapter.latestRoundData().updatedAt == block.timestamp`
///              → `lag = block.timestamp - updatedAt = 0 < STALENESS_BOUND`.
///           4. A downstream consumer's staleness gate PASSES — the bug.
///           5. Marker fires: `INVARIANT VIOLATED ChainlinkAdapterDefeatsStaleness`.
///
/// @dev CI spec (§5.2): planted leg exits non-zero with at least one
///      `INVARIANT VIOLATED ChainlinkAdapterDefeatsStaleness` line on stdout.
///      Twin diff vs clean file: 1 new planted test method; `BrokenChainlinkAdapter`
///      redefined inline (no cross-file import, keeps the planted file
///      self-contained).

// ---------------------------------------------------------------------------
// Reference broken adapter — identical to the one in ChainlinkAdapterDefeats.t.sol.
// Redefined here so this file is self-contained (no test-to-test import).
// ---------------------------------------------------------------------------

/// @notice Models the in-the-wild pattern D-6 describes: returns `block.timestamp`
///         as `updatedAt` regardless of HyperCore publish state. The downstream
///         staleness check `block.timestamp - updatedAt < bound` ALWAYS passes —
///         even when HyperCore has halted and the price has been stale for hours.
///
/// @dev NOT in `src/`. Present for documentation and planted-twin CI only.
///      Same contract as `BrokenChainlinkAdapter` in the sibling clean file.
contract BrokenChainlinkAdapterPlanted {
    uint32 public immutable asset;

    constructor(uint32 asset_) {
        asset = asset_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80)
    {
        // BROKEN: returns block.timestamp regardless of HyperCore publish state.
        (bool ok, bytes memory data) =
            HyperCorePrecompileAddresses.MARK.staticcall(abi.encode(asset));
        require(ok, "mark precompile failed");
        uint64 raw = abi.decode(data, (uint64));
        return (
            uint80(0),
            int256(uint256(raw)),
            block.timestamp, // bug: should be HyperCore publish ts
            block.timestamp, // bug: should be HyperCore publish ts
            uint80(0)
        );
    }
}

// ---------------------------------------------------------------------------
// Planted test.
// ---------------------------------------------------------------------------

contract ChainlinkAdapterDefeatsPlantedTest is Test {
    BrokenChainlinkAdapterPlanted internal brokenAdapter;

    uint32  internal constant ASSET               = 5;
    uint64  internal constant SEED_PRICE          = 100_00_000_000; // 100.0 in 8-decimal
    uint64  internal constant GENESIS_TS          = 1_700_000_000;
    uint64  internal constant BLOCK_MS            = 70;
    uint256 internal constant STALENESS_BOUND_SECONDS = 60;

    function setUp() public {
        brokenAdapter = new BrokenChainlinkAdapterPlanted(ASSET);

        MockPrecompiles.setMark(ASSET, SEED_PRICE);
        uint64 l1 = 100_000;
        MockPrecompiles.setL1BlockNumber(l1);

        // Align EVM timestamp so steady-state staleness check passes.
        uint256 publishTs = uint256(GENESIS_TS) + (uint256(l1) * uint256(BLOCK_MS)) / 1000;
        vm.warp(publishTs);
    }

    // -------------------------------------------------------------------------
    // Planted property: under a HyperCore freeze, the broken adapter returns
    // lag=0 (the downstream staleness check PASSES when it MUST FAIL).
    // INVARIANT VIOLATED fires.
    // -------------------------------------------------------------------------

    function test_property_planted_hyperCoreFreeze_brokenAdapterDefeatsCheck() public {
        // Simulate HyperCore freeze: advance EVM wall-clock past the staleness
        // bound but do NOT advance the L1 block. The good adapter (not under
        // test here) would surface lag > STALENESS_BOUND_SECONDS; the broken
        // adapter returns lag = 0 regardless.
        vm.warp(block.timestamp + STALENESS_BOUND_SECONDS + 1);

        (, , , uint256 brokenUpdatedAt, ) = brokenAdapter.latestRoundData();
        uint256 lag = block.timestamp - brokenUpdatedAt;

        // The invariant: a correct staleness check requires lag >= stalenessBound
        // to surface the freeze. The broken adapter defeats this: lag = 0.
        // That silence is the violation — the downstream consumer's guard PASSES
        // when it should have REJECTED the stale price.
        if (lag < STALENESS_BOUND_SECONDS) {
            console2.log("INVARIANT VIOLATED ChainlinkAdapterDefeatsStaleness");
            console2.log("  lag (broken)    =", lag);
            console2.log("  stalenessBound  =", STALENESS_BOUND_SECONDS);
            console2.log("  brokenUpdatedAt =", brokenUpdatedAt);
            console2.log("  block.timestamp =", block.timestamp);
            console2.log("  (broken adapter returns block.timestamp as updatedAt;");
            console2.log("   downstream staleness gate silently passes on frozen price)");
            revert("INVARIANT VIOLATED ChainlinkAdapterDefeatsStaleness");
        }
    }

    /// @notice Fuzz sweep: for any freeze duration above the staleness bound,
    ///         the broken adapter always returns lag=0.  Marker fires on every run.
    function testFuzz_property_planted_freeze_brokenAlwaysDefeats(uint64 freezeExtra) public {
        uint256 delta = uint256(freezeExtra % 10_000) + STALENESS_BOUND_SECONDS + 1;
        vm.warp(block.timestamp + delta);

        (, , , uint256 brokenUpdatedAt, ) = brokenAdapter.latestRoundData();
        uint256 lag = block.timestamp - brokenUpdatedAt;

        if (lag < STALENESS_BOUND_SECONDS) {
            console2.log("INVARIANT VIOLATED ChainlinkAdapterDefeatsStaleness");
            console2.log("  lag (broken) =", lag);
            console2.log("  delta        =", delta);
            revert("INVARIANT VIOLATED ChainlinkAdapterDefeatsStaleness");
        }
    }
}
