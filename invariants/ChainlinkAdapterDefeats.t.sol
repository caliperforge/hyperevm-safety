// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkCompatAdapter} from "../src/ChainlinkCompatAdapter.sol";
import {HyperCorePrecompileAddresses} from "../src/interfaces/IHyperCorePrecompiles.sol";
import {MockPrecompiles} from "./mocks/MockPrecompiles.sol";

/// @title ChainlinkAdapterDefeats — D-6 property: a HyperCore freeze MUST surface through the adapter.
/// @notice Spec.md §3.1 D-6 — the highest-impact differentiated invariant per the spec.
///
///         The property asserts that the canonical Chainlink-style staleness check
///
///             block.timestamp - adapter.latestRoundData().updatedAt < stalenessBound
///
///         CORRECTLY fires when HyperCore halts. The library's `ChainlinkCompatAdapter`
///         derives `updatedAt` from the HyperCore L1 block (precompile 0x808). The
///         broken pattern in the wild returns `block.timestamp` as `updatedAt`, which
///         makes the consumer's staleness gate ALWAYS PASS — the test below also
///         models that broken adapter (`BrokenChainlinkAdapter` below) and asserts the
///         dual: under the same HyperCore-freeze scenario, the broken adapter's
///         staleness check passes (the bug), and the library's adapter's check fails
///         (the defense fires).
contract ChainlinkAdapterDefeatsTest is Test {
    ChainlinkCompatAdapter internal goodAdapter;
    BrokenChainlinkAdapter internal brokenAdapter;

    uint32 internal constant ASSET = 5;
    uint64 internal constant SEED_PRICE = 100_00_000_000; // 100.0 in 8-decimal
    uint64 internal constant GENESIS_TS = 1_700_000_000;
    uint64 internal constant BLOCK_MS = 70; // HyperCore ~0.07s
    uint256 internal constant STALENESS_BOUND_SECONDS = 60;

    function setUp() public {
        goodAdapter = new ChainlinkCompatAdapter(
            HyperCorePrecompileAddresses.MARK, ASSET, 8, GENESIS_TS, BLOCK_MS, "HYPE/USD mark"
        );
        brokenAdapter = new BrokenChainlinkAdapter(ASSET);

        MockPrecompiles.setMark(ASSET, SEED_PRICE);
        // Initial L1 block aligned to a sane height.
        uint64 l1 = 100_000;
        MockPrecompiles.setL1BlockNumber(l1);

        // Align EVM block.timestamp so that the steady-state staleness check
        // passes for both adapters at setup.
        uint256 publishTs = uint256(GENESIS_TS) + (uint256(l1) * uint256(BLOCK_MS)) / 1000;
        vm.warp(publishTs);
    }

    // -------------------------------------------------------------------------
    // Property: under steady state, both adapters pass the staleness check.
    // -------------------------------------------------------------------------

    function test_property_steadyState_bothPass() public view {
        (, , , uint256 goodUpdatedAt, ) = goodAdapter.latestRoundData();
        (, , , uint256 brokenUpdatedAt, ) = brokenAdapter.latestRoundData();

        assertLt(block.timestamp - goodUpdatedAt, STALENESS_BOUND_SECONDS, "good adapter steady-state");
        assertLt(block.timestamp - brokenUpdatedAt, STALENESS_BOUND_SECONDS, "broken adapter steady-state");
    }

    // -------------------------------------------------------------------------
    // Property: under a HyperCore freeze, the library's adapter surfaces it;
    // the broken adapter does not.
    // -------------------------------------------------------------------------

    function test_property_hyperCoreFreeze_libraryAdapterDetects() public {
        // Freeze HyperCore: don't advance the L1 block. Advance EVM block +
        // wallclock by enough that any sane staleness gate should fire.
        vm.warp(block.timestamp + STALENESS_BOUND_SECONDS + 1);

        (, , , uint256 goodUpdatedAt, ) = goodAdapter.latestRoundData();
        uint256 goodLag = block.timestamp - goodUpdatedAt;

        // The library's adapter correctly reports a lag that exceeds the bound.
        assertGt(goodLag, STALENESS_BOUND_SECONDS, "library adapter MUST detect freeze");
    }

    function test_property_hyperCoreFreeze_brokenAdapterMisses() public {
        vm.warp(block.timestamp + STALENESS_BOUND_SECONDS + 1);

        (, , , uint256 brokenUpdatedAt, ) = brokenAdapter.latestRoundData();
        uint256 brokenLag = block.timestamp - brokenUpdatedAt;

        // The broken adapter reports lag = 0 (it returned block.timestamp).
        // This is the bug class: the staleness gate passes despite the freeze.
        assertEq(brokenLag, 0, "broken adapter returns 0 lag (the bug)");
        assertLt(brokenLag, STALENESS_BOUND_SECONDS, "broken adapter's check passes (bug)");
    }

    // -------------------------------------------------------------------------
    // Property: as HyperCore advances, the library's adapter updates updatedAt.
    // -------------------------------------------------------------------------

    function test_property_l1Advance_libraryAdapterTracksPublishTimestamp() public {
        uint64 l1Before = 100_000;
        MockPrecompiles.setL1BlockNumber(l1Before);
        (, , , uint256 before, ) = goodAdapter.latestRoundData();

        uint64 l1After = l1Before + 1000;
        MockPrecompiles.setL1BlockNumber(l1After);
        (, , , uint256 after_, ) = goodAdapter.latestRoundData();

        // 1000 L1 blocks × 70ms = 70_000ms = 70 seconds.
        assertEq(after_ - before, 70, "publish-timestamp delta MUST equal l1 delta * blockMs");
    }
}

/// @notice Reference broken adapter — models the in-the-wild pattern D-6
///         describes. Used by the property tests above as the negative leg.
///         NOT exported from `src/`; this is test-side only.
contract BrokenChainlinkAdapter {
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
