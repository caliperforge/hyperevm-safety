// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SzDecimalsLib} from "../src/SzDecimalsLib.sol";
import {MockPrecompiles} from "./mocks/MockPrecompiles.sol";

/// @title SzDecimalsRoundTrip — D-3 property: szDecimals scaling is round-trip-safe.
/// @notice Spec.md §3.1 D-3. For every spot token + every perp asset under the
///         configured decimals, the round trip
///
///             scaleFromWei(scaleToWei(x)) == x  (lossless variant)
///
///         holds exactly. The spot vs perp distinction is exercised separately —
///         spot decimals come from precompile 0x80B, perp from 0x809.
///
/// @dev The wrapper contract below routes calls into `SzDecimalsLib` (which is a
///      library) so Foundry can invoke them as external calls. T-5 lands a planted
///      hunk that swaps the spot/perp lookups; the round-trip property fires
///      `INVARIANT VIOLATED SzDecimalsRoundTrip` on the planted hunk.
contract SzDecimalsCaller {
    function spotToWei(uint32 token, uint256 amountSz) external view returns (uint256) {
        return SzDecimalsLib.scaleSpotToWei(token, amountSz);
    }

    function spotFromWei(uint32 token, uint256 amountWei) external view returns (uint256) {
        return SzDecimalsLib.scaleSpotFromWei(token, amountWei);
    }

    function perpToWei(uint32 asset, uint256 amountSz, uint8 targetWei) external view returns (uint256) {
        return SzDecimalsLib.scalePerpToWei(asset, amountSz, targetWei);
    }

    function perpFromWei(uint32 asset, uint256 amountWei, uint8 sourceWei) external view returns (uint256) {
        return SzDecimalsLib.scalePerpFromWei(asset, amountWei, sourceWei);
    }
}

contract SzDecimalsRoundTripTest is Test {
    SzDecimalsCaller internal caller;

    // Spot token: szDecimals=4, weiDecimals=8, evmExtra=10 → EVM-side 18-decimal
    uint32 internal constant SPOT_TOKEN = 7;
    uint8 internal constant SPOT_SZ = 4;
    uint8 internal constant SPOT_WEI = 8;
    int8 internal constant SPOT_EVM_EXTRA = 10; // EVM ERC20 decimals = 8 + 10 = 18

    // Perp asset: szDecimals=4 (e.g. BTC-PERP 0.0001 size precision)
    uint32 internal constant PERP_ASSET = 3;
    uint8 internal constant PERP_SZ = 4;
    uint8 internal constant PERP_TARGET_WEI = 18;

    function setUp() public {
        caller = new SzDecimalsCaller();
        MockPrecompiles.setSpotDecimals(SPOT_TOKEN, SPOT_SZ, SPOT_WEI, SPOT_EVM_EXTRA);
        MockPrecompiles.setPerpSzDecimals(PERP_ASSET, PERP_SZ);
    }

    // -------------------------------------------------------------------------
    // Spot round-trip
    // -------------------------------------------------------------------------

    function test_property_spot_roundTrip_atSzGranularity() public view {
        uint256 amountSz = 12_345; // representable exactly at szDecimals=4
        uint256 amountWei = caller.spotToWei(SPOT_TOKEN, amountSz);
        uint256 backToSz = caller.spotFromWei(SPOT_TOKEN, amountWei);
        assertEq(backToSz, amountSz);
    }

    function testFuzz_property_spot_roundTrip(uint256 amountSz) public view {
        // Cap so scaleToWei * factor doesn't overflow uint256.
        // amount * 10^(18-4) = amount * 10^14; cap amount at ~10^60.
        uint256 bounded = amountSz % (1e60);
        uint256 amountWei = caller.spotToWei(SPOT_TOKEN, bounded);
        uint256 backToSz = caller.spotFromWei(SPOT_TOKEN, amountWei);
        assertEq(backToSz, bounded);
    }

    // -------------------------------------------------------------------------
    // Perp round-trip
    // -------------------------------------------------------------------------

    function test_property_perp_roundTrip_atSzGranularity() public view {
        uint256 amountSz = 54_321;
        uint256 amountWei = caller.perpToWei(PERP_ASSET, amountSz, PERP_TARGET_WEI);
        uint256 backToSz = caller.perpFromWei(PERP_ASSET, amountWei, PERP_TARGET_WEI);
        assertEq(backToSz, amountSz);
    }

    function testFuzz_property_perp_roundTrip(uint256 amountSz) public view {
        uint256 bounded = amountSz % (1e60);
        uint256 amountWei = caller.perpToWei(PERP_ASSET, bounded, PERP_TARGET_WEI);
        uint256 backToSz = caller.perpFromWei(PERP_ASSET, amountWei, PERP_TARGET_WEI);
        assertEq(backToSz, bounded);
    }

    // -------------------------------------------------------------------------
    // Spot vs perp distinction — using the wrong precompile for a kind must
    // either misroute (returns a different number) or revert. The library
    // makes this safe by using a distinct precompile per kind; the planted
    // hunk in T-5 swaps the lookup, which this asserts against.
    // -------------------------------------------------------------------------

    function test_property_spotAndPerp_decimalsAreIndependent() public {
        // Register the same id under different decimals on the two precompiles.
        // Reads through the correct path return the correct decimals.
        uint32 sharedId = 42;
        MockPrecompiles.setSpotDecimals(sharedId, 6, 10, 8); // EVM = 18
        MockPrecompiles.setPerpSzDecimals(sharedId, 2);

        // 1.0 unit at spot szDecimals=6 → 1_000_000 sz; at EVM 18 → 1e18.
        uint256 spotWei = caller.spotToWei(sharedId, 1_000_000);
        assertEq(spotWei, 1e18);

        // 1.0 unit at perp szDecimals=2 → 100 sz; at EVM 18 → 1e18 also, but
        // via a different scaling chain (perp uses caller-supplied target).
        uint256 perpWei = caller.perpToWei(sharedId, 100, 18);
        assertEq(perpWei, 1e18);

        // Crossed calls would compute wrong — this is what the planted hunk in
        // T-5 swaps and what the property catches.
    }

    // -------------------------------------------------------------------------
    // PrecisionLoss is signalled (not silently truncated) on lossless paths.
    // -------------------------------------------------------------------------

    function test_property_lossless_revertsOnTruncation() public {
        // 1 wei at EVM 18-decimal can't be represented at szDecimals=4.
        vm.expectRevert();
        caller.spotFromWei(SPOT_TOKEN, 1);
    }
}
