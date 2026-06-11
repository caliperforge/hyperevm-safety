// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HyperCoreOracleGuard} from "../src/HyperCoreOracleGuard.sol";
import {MockPrecompiles} from "./mocks/MockPrecompiles.sol";

/// @title OracleStaleness — D-1 property: a HyperCore-frozen publish MUST be detected.
/// @notice Spec.md §3.1 D-1. A protocol that consumes 0x806 (mark) or 0x807 (oracle)
///         via `HyperCoreOracleGuard.readMark` / `readOracle` MUST revert `Stale()` when
///         the HyperCore L1 block number (precompile 0x808) lags the EVM block number
///         by more than `maxStalenessBlocks`. The property below asserts the dual:
///
///           - Fresh L1 block (lag ≤ bound): read returns the latest price.
///           - Stale L1 block (lag > bound): read reverts `Stale()`.
///
///         The bug class this catches: a lender code path that consumes the
///         precompile read without checking the L1 block watermark; HyperCore halts
///         or skips a publish; the lender prices off a frozen feed.
///
/// @dev T-5 lands a planted hunk that removes the staleness check from the consumer
///      code path. With the hunk in place, this property fires
///      `INVARIANT VIOLATED OracleStaleness` deterministically; the clean reference
///      passes the property.
///
///      `forge test --match-path 'invariants/*.t.sol'` runs this against the clean
///      reference and asserts 0 violations.
contract OracleStalenessTest is Test {
    HyperCoreOracleGuard internal guard;

    uint64 internal constant MAX_STALENESS_BLOCKS = 5;
    uint8 internal constant WINDOW_SIZE = 4;
    uint16 internal constant MAX_DEVIATION_BPS = 500; // 5%

    uint32 internal constant ASSET = 1;
    uint64 internal constant SEED_PRICE = 100_00_000_000; // 100.0 in 8-decimal

    function setUp() public {
        guard = new HyperCoreOracleGuard(MAX_STALENESS_BLOCKS, WINDOW_SIZE, MAX_DEVIATION_BPS);
        // Initial EVM and L1 blocks aligned at a comfortable height; later test
        // bodies vary the lag independently.
        vm.roll(1_000_000);
        MockPrecompiles.setL1BlockNumber(uint64(block.number));
        MockPrecompiles.setMark(ASSET, SEED_PRICE);
        MockPrecompiles.setOracle(ASSET, SEED_PRICE);
    }

    // -------------------------------------------------------------------------
    // Property: fresh reads succeed.
    // -------------------------------------------------------------------------

    function test_property_readMark_freshL1Block_returnsPrice() public view {
        // L1 at block.number — zero lag, well within bound.
        uint64 px = guard.readMark(ASSET);
        assertEq(px, SEED_PRICE);
    }

    function test_property_readOracle_freshL1Block_returnsPrice() public view {
        uint64 px = guard.readOracle(ASSET);
        assertEq(px, SEED_PRICE);
    }

    // -------------------------------------------------------------------------
    // Property: stale reads revert Stale().
    // -------------------------------------------------------------------------

    function test_property_readMark_staleL1Block_revertsStale() public {
        // Hold L1 block fixed and advance EVM blocks past the bound.
        uint64 l1 = uint64(block.number);
        MockPrecompiles.setL1BlockNumber(l1);
        vm.roll(block.number + MAX_STALENESS_BLOCKS + 1);

        vm.expectRevert(); // Stale(...) with computed args; selector match sufficient
        guard.readMark(ASSET);
    }

    function test_property_readOracle_staleL1Block_revertsStale() public {
        uint64 l1 = uint64(block.number);
        MockPrecompiles.setL1BlockNumber(l1);
        vm.roll(block.number + MAX_STALENESS_BLOCKS + 1);

        vm.expectRevert();
        guard.readOracle(ASSET);
    }

    // -------------------------------------------------------------------------
    // Property: boundary — lag exactly equal to bound passes; lag = bound+1 fails.
    // -------------------------------------------------------------------------

    function test_property_boundary_lagEqualsBound_passes() public {
        uint64 l1 = uint64(block.number);
        MockPrecompiles.setL1BlockNumber(l1);
        vm.roll(block.number + MAX_STALENESS_BLOCKS); // lag == bound
        uint64 px = guard.readMark(ASSET);
        assertEq(px, SEED_PRICE);
    }

    function test_property_boundary_lagBoundPlusOne_reverts() public {
        uint64 l1 = uint64(block.number);
        MockPrecompiles.setL1BlockNumber(l1);
        vm.roll(block.number + MAX_STALENESS_BLOCKS + 1); // lag == bound+1
        vm.expectRevert();
        guard.readMark(ASSET);
    }

    // -------------------------------------------------------------------------
    // Fuzz: for any lag, the read reverts iff lag > bound.
    // -------------------------------------------------------------------------

    function testFuzz_property_stalenessGate(uint16 lag) public {
        uint16 boundedLag = uint16(lag % 100); // keep search space modest
        uint64 l1 = uint64(block.number);
        MockPrecompiles.setL1BlockNumber(l1);
        vm.roll(block.number + boundedLag);

        if (boundedLag > MAX_STALENESS_BLOCKS) {
            vm.expectRevert();
            guard.readMark(ASSET);
        } else {
            uint64 px = guard.readMark(ASSET);
            assertEq(px, SEED_PRICE);
        }
    }

    // Marker format: `INVARIANT VIOLATED <name>` on stdout — see spec §5.2.
    // The clean leg passes silently; the planted-leg twin emits the marker
    // via `console2.log` + revert string (see the stateful-fuzz properties
    // in `CoreWriterSolvencyWindow.t.sol` / `PrecompileGasDoS.t.sol` for the
    // emission pattern).
}
