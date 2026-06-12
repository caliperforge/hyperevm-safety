// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {SzDecimalsLib} from "../../src/SzDecimalsLib.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";

/// @title SzDecimalsRoundTrip (planted) — D-3 planted twin: asymmetric spot/perp
///        precompile lookup breaks the round-trip identity and fires
///        `INVARIANT VIOLATED SzDecimalsRoundTrip`.
///
/// @notice T-5 planted hunk (spec.md §3.1 D-3). Counterpart twin to
///         `invariants/SzDecimalsRoundTrip.t.sol`. The single localized change is
///         in `BrokenSzDecimalsCaller.spotToWei`: it queries the perp precompile
///         (0x809) instead of the spot precompile (0x80B), while `spotFromWei`
///         still queries the spot precompile. This asymmetry breaks the round-trip
///         when the two precompiles carry different `szDecimals` for the same
///         token id — which is the common case in production.
///
///         Round-trip trace (token 7, spot_sz=4, perp_sz=2):
///           toWei:   scalePerpToWei(7, 100, 18) → 100 × 10^(18-2) = 1e18
///           fromWei: scaleSpotFromWei(7, 1e18)  → 1e18 / 10^(18-4) = 10000
///           100 → 1e18 → 10000 ≠ 100  →  INVARIANT VIOLATED SzDecimalsRoundTrip
///
/// @dev CI spec (§5.2): planted leg exits non-zero with at least one
///      `INVARIANT VIOLATED SzDecimalsRoundTrip` line on stdout.
///      Twin diff vs clean file: 1 localized hunk
///      (`BrokenSzDecimalsCaller.spotToWei` calls `scalePerpToWei` not
///      `scaleSpotToWei`).

// ---------------------------------------------------------------------------
// Planted caller — the asymmetric precompile lookup is the single hunk.
// ---------------------------------------------------------------------------

/// @notice Broken caller that routes `spotToWei` through the perp precompile
///         (0x809) while `spotFromWei` still uses the spot precompile (0x80B).
///         The mismatch in szDecimals between the two precompiles for the same
///         token id breaks the round-trip identity.
///
/// @dev NOT in `src/` — this is a documented bug-class model, same convention
///      as `BrokenChainlinkAdapter` and `BrokenConsumer` in the sibling test
///      files.
contract BrokenSzDecimalsCaller {
    /// @notice PLANTED: calls `scalePerpToWei` (0x809) instead of
    ///         `scaleSpotToWei` (0x80B). If the perp szDecimals for `token`
    ///         differ from the spot szDecimals, the scale factor is wrong and
    ///         the round-trip fails.
    function spotToWei(uint32 token, uint256 amountSz) external view returns (uint256) {
        // BUG: wrong precompile. Should be SzDecimalsLib.scaleSpotToWei.
        return SzDecimalsLib.scalePerpToWei(token, amountSz, 18);
    }

    /// @notice Still uses the spot precompile (0x80B) — creating the asymmetry.
    function spotFromWei(uint32 token, uint256 amountWei) external view returns (uint256) {
        return SzDecimalsLib.scaleSpotFromWei(token, amountWei);
    }
}

// ---------------------------------------------------------------------------
// Planted test — the property fires deterministically for any non-zero amount.
// ---------------------------------------------------------------------------

contract SzDecimalsRoundTripPlantedTest is Test {
    BrokenSzDecimalsCaller internal broken;

    // Token 7 registered on spot precompile (0x80B): sz=4, wei=8, evmExtra=10
    // → EVM 18 decimals (8+10).
    uint32 internal constant TOKEN      = 7;
    uint8  internal constant SPOT_SZ    = 4;
    uint8  internal constant SPOT_WEI   = 8;
    int8   internal constant SPOT_EVMX  = 10;

    // Same token id registered on perp precompile (0x809) with sz=2 — the
    // planted deviation that breaks the round-trip.
    uint8 internal constant PERP_SZ = 2;

    function setUp() public {
        broken = new BrokenSzDecimalsCaller();
        MockPrecompiles.setSpotDecimals(TOKEN, SPOT_SZ, SPOT_WEI, SPOT_EVMX); // 0x80B
        MockPrecompiles.setPerpSzDecimals(TOKEN, PERP_SZ);                      // 0x809
    }

    // -------------------------------------------------------------------------
    // Property: the swapped lookup breaks the round-trip — INVARIANT VIOLATED.
    // -------------------------------------------------------------------------

    /// @notice Deterministic witness: 100 sz units route through perp_sz=2 on
    ///         the way up (→ 1e18) but spot_sz=4 on the way back (→ 10000).
    ///         100 ≠ 10000 → marker fires.
    function test_property_planted_spotRoundTrip_invariantViolated() public view {
        uint256 amountSz  = 100;
        uint256 amountWei = broken.spotToWei(TOKEN, amountSz);
        uint256 backToSz  = broken.spotFromWei(TOKEN, amountWei);

        if (backToSz != amountSz) {
            console2.log("INVARIANT VIOLATED SzDecimalsRoundTrip");
            console2.log("  amountSz  =", amountSz);
            console2.log("  amountWei =", amountWei);
            console2.log("  backToSz  =", backToSz);
            console2.log("  (spot_sz=4 != perp_sz=2: asymmetric precompile lookup)");
            revert("INVARIANT VIOLATED SzDecimalsRoundTrip");
        }
    }

    /// @notice Fuzz sweep: for any non-zero amount, the asymmetric lookup
    ///         magnifies by a factor of 100 (10^(18-2) / 10^(18-4) = 10^2),
    ///         so `backToSz = amountSz * 100` ≠ `amountSz`. Marker fires.
    function testFuzz_property_planted_spotRoundTrip_invariantViolated(uint256 amountSz) public view {
        // Bound to prevent overflow: bounded * 10^16 must fit uint256 (<1.16e77).
        // bounded ≤ 1e60, 1e60 * 10^16 = 1e76 < 1.16e77 ✓
        uint256 bounded = amountSz % 1e60;
        vm.assume(bounded > 0); // skip the degenerate zero case

        uint256 amountWei = broken.spotToWei(TOKEN, bounded);
        uint256 backToSz  = broken.spotFromWei(TOKEN, amountWei);

        if (backToSz != bounded) {
            console2.log("INVARIANT VIOLATED SzDecimalsRoundTrip");
            console2.log("  bounded   =", bounded);
            console2.log("  amountWei =", amountWei);
            console2.log("  backToSz  =", backToSz);
            revert("INVARIANT VIOLATED SzDecimalsRoundTrip");
        }
    }
}
