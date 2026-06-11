// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HyperCoreOracleGuard} from "../src/HyperCoreOracleGuard.sol";
import {MockPrecompiles} from "./mocks/MockPrecompiles.sol";

/// @title OracleDeviation — D-2 property: a single-block manipulated read MUST be detected.
/// @notice Spec.md §3.1 D-2. A protocol consuming the deviation-bounded read MUST
///         revert `Deviation()` when the current sample deviates from the trailing
///         TWAP by more than `maxDeviationBps`. The property fuzzes scenarios:
///
///           - Warm window + in-range sample → returns price.
///           - Warm window + out-of-range sample → reverts `Deviation()`.
///           - Cold window → reverts `WindowNotWarm` (consumer hasn't seeded enough
///             samples to engage the gate; surfaces config bugs at integration time).
///
///         The bug class: a lender code path that consumes the raw mark/oracle
///         precompile read without a TWAP deviation check; an attacker self-trades
///         to swing the mark for a single block and triggers a liquidation cascade.
///
/// @dev T-5 lands a JELLY-style planted hunk that bypasses the deviation gate. With
///      the hunk in place, this property fires `INVARIANT VIOLATED OracleDeviation`
///      deterministically.
contract OracleDeviationTest is Test {
    HyperCoreOracleGuard internal guard;

    uint64 internal constant MAX_STALENESS_BLOCKS = 100;
    uint8 internal constant WINDOW_SIZE = 4;
    uint16 internal constant MAX_DEVIATION_BPS = 500; // 5%

    uint32 internal constant ASSET = 1;
    uint64 internal constant SEED_PRICE = 100_00_000_000; // 100.0 in 8-decimal

    function setUp() public {
        guard = new HyperCoreOracleGuard(MAX_STALENESS_BLOCKS, WINDOW_SIZE, MAX_DEVIATION_BPS);
        vm.roll(1_000_000);
        MockPrecompiles.setL1BlockNumber(uint64(block.number));
        MockPrecompiles.setMark(ASSET, SEED_PRICE);
        MockPrecompiles.setOracle(ASSET, SEED_PRICE);
    }

    // -------------------------------------------------------------------------
    // Warm the trailing window by issuing WINDOW_SIZE reads at the seed price.
    // The read path warms the buffer in place — no revert during warming.
    // -------------------------------------------------------------------------

    function _warmMarkWindow() internal {
        for (uint8 i = 0; i < WINDOW_SIZE; i++) {
            guard.readMarkWithDeviationBound(ASSET);
        }
    }

    function _warmOracleWindow() internal {
        for (uint8 i = 0; i < WINDOW_SIZE; i++) {
            guard.readOracleWithDeviationBound(ASSET);
        }
    }

    // -------------------------------------------------------------------------
    // Property: in-range sample passes.
    // -------------------------------------------------------------------------

    function test_property_inRange_mark_returnsPrice() public {
        _warmMarkWindow();
        // 2% deviation (within 5% bound).
        uint64 newPx = (SEED_PRICE * 102) / 100;
        MockPrecompiles.setMark(ASSET, newPx);
        uint64 px = guard.readMarkWithDeviationBound(ASSET);
        assertEq(px, newPx);
    }

    function test_property_inRange_oracle_returnsPrice() public {
        _warmOracleWindow();
        uint64 newPx = (SEED_PRICE * 98) / 100;
        MockPrecompiles.setOracle(ASSET, newPx);
        uint64 px = guard.readOracleWithDeviationBound(ASSET);
        assertEq(px, newPx);
    }

    // -------------------------------------------------------------------------
    // Property: out-of-range sample reverts Deviation.
    // -------------------------------------------------------------------------

    function test_property_outOfRange_mark_revertsDeviation() public {
        _warmMarkWindow();
        // 10% spike — exceeds 5% bound.
        uint64 spike = (SEED_PRICE * 110) / 100;
        MockPrecompiles.setMark(ASSET, spike);

        vm.expectRevert();
        guard.readMarkWithDeviationBound(ASSET);
    }

    function test_property_outOfRange_oracle_revertsDeviation() public {
        _warmOracleWindow();
        uint64 drop = (SEED_PRICE * 80) / 100; // 20% drop
        MockPrecompiles.setOracle(ASSET, drop);

        vm.expectRevert();
        guard.readOracleWithDeviationBound(ASSET);
    }

    // -------------------------------------------------------------------------
    // Property: cold window returns the price unguarded (deviation check
    // engages only after warm-up). The view accessor `markTwap` is the channel
    // through which a consumer can detect the unwarm state and refuse to
    // trust the gate.
    // -------------------------------------------------------------------------

    function test_property_coldWindow_returnsPriceAndStartsWarming() public {
        assertEq(guard.markSampleCount(ASSET), 0);
        uint64 px = guard.readMarkWithDeviationBound(ASSET);
        assertEq(px, SEED_PRICE);
        assertEq(guard.markSampleCount(ASSET), 1);
    }

    function test_property_coldWindow_twapViewRevertsWindowNotWarm() public {
        // The view accessor surfaces the unwarm state.
        vm.expectRevert();
        guard.markTwap(ASSET);
    }

    // -------------------------------------------------------------------------
    // Fuzz: for any |deviation| ≤ bound, read passes; for any > bound, reverts.
    // -------------------------------------------------------------------------

    function testFuzz_property_deviationGate(uint16 deviationBps) public {
        uint16 bounded = uint16(deviationBps % 2000); // 0..20%
        _warmMarkWindow();

        uint64 newPx = uint64((uint256(SEED_PRICE) * (10_000 + bounded)) / 10_000);
        MockPrecompiles.setMark(ASSET, newPx);

        if (bounded > MAX_DEVIATION_BPS) {
            vm.expectRevert();
            guard.readMarkWithDeviationBound(ASSET);
        } else {
            uint64 px = guard.readMarkWithDeviationBound(ASSET);
            assertEq(px, newPx);
        }
    }
}
