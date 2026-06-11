// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {HyperCorePrecompileAddresses} from "./interfaces/IHyperCorePrecompiles.sol";

/// @title SzDecimalsLib — szDecimals-aware amount scaling for HyperEVM lending protocols.
/// @notice HyperCore tracks token amounts in `szDecimals` (the on-HyperCore amount
///         precision); HyperEVM contracts denominate token amounts in `wei` (18-decimal
///         or evmContract-decimal). The two are NOT interchangeable; the round-trip
///         conversion is the bug class this library catches at compile-spec time.
///
///         The wire surface:
///
///           **Perp assets** (precompile 0x809): `szDecimals` is the position-size
///           precision (e.g. 4 for BTC-PERP → 0.0001 BTC units). NO `weiDecimals` — a
///           perp position is not a token, so the EVM-side representation is a
///           consumer-chosen scale.
///
///           **Spot tokens** (precompile 0x80B): `szDecimals` is the spot-order size
///           precision (typically smaller than `weiDecimals`); `weiDecimals` is the
///           wire decimal count HyperCore uses for the token's balance fields;
///           `evmExtraWeiDecimals` is the *signed* delta between HyperCore's
///           wei representation and the deployed EVM ERC20 contract's `decimals()`
///           (positive → EVM uses more decimals than HyperCore; negative → fewer).
///
///         The library converts amounts between the EVM-side wei representation and
///         the HyperCore-side szDecimals representation, asserting the round-trip
///         identity that D-3 (`SzDecimalsScaling`) guards against. The spot vs perp
///         distinction is enforced at the type level via the explicit `scaleSpot*` /
///         `scalePerp*` function pair — a caller cannot accidentally use a perp
///         `szDecimals` for a spot token, because the lookups go to different
///         precompiles.
///
/// @dev D-3 of the differentiated taxonomy (spec.md §3.1).
///      Property test: `invariants/SzDecimalsRoundTrip.t.sol`.
///
///      All conversions use uint256 internally to avoid intermediate truncation;
///      the final cast back to the requested width reverts on overflow via the
///      built-in `SafeCast` pattern (explicit branch + revert).
library SzDecimalsLib {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The configured `szDecimals` and `weiDecimals` produce an
    ///         out-of-range conversion (overflow on multiply, or scaling factor
    ///         exceeds the supported max).
    error ScalingOverflow();

    /// @notice The amount is finer-grained than `szDecimals` permits — a
    ///         conversion to szDecimals representation would lose precision.
    ///         Conversion paths that allow precision loss MUST go through the
    ///         `scale*Round*` variants and acknowledge the loss explicitly.
    error PrecisionLoss(uint256 amount, uint8 szDecimals, uint8 weiDecimals);

    /// @notice The precompile call to fetch token / perp info failed.
    error PrecompileFailed(address precompile, uint32 asset);

    // -------------------------------------------------------------------------
    // Constants — hard caps on supported decimal widths. HyperCore's wire
    // surface uses `uint8` decimal fields; we cap at 30 to keep the scaling
    // factor 10**(diff) bounded under uint256.
    // -------------------------------------------------------------------------

    uint8 internal constant MAX_DECIMALS = 30;

    // -------------------------------------------------------------------------
    // Spot — uses precompile 0x80B (TOKEN_INFO).
    // -------------------------------------------------------------------------

    /// @notice Scale a spot-token amount from its HyperCore szDecimals
    ///         representation into wei. The wei target is the EVM ERC20
    ///         contract's `decimals()`, which equals
    ///         `weiDecimals + evmExtraWeiDecimals` per the HyperCore token
    ///         info. The conversion is loss-less (multiplying up).
    function scaleSpotToWei(uint32 token, uint256 amountSz) internal view returns (uint256 amountWei) {
        (uint8 szDecimals, uint8 weiDecimals, int8 evmExtra) = _spotDecimals(token);
        uint256 evmDecimals = _combineEvmDecimals(weiDecimals, evmExtra);
        amountWei = _scaleUp(amountSz, szDecimals, evmDecimals);
    }

    /// @notice Scale a spot-token wei amount back into HyperCore szDecimals
    ///         representation. Reverts `PrecisionLoss` if the wei amount has
    ///         finer granularity than szDecimals permits. For an
    ///         explicit-rounding variant see `scaleSpotFromWeiRoundDown`.
    function scaleSpotFromWei(uint32 token, uint256 amountWei) internal view returns (uint256 amountSz) {
        (uint8 szDecimals, uint8 weiDecimals, int8 evmExtra) = _spotDecimals(token);
        uint256 evmDecimals = _combineEvmDecimals(weiDecimals, evmExtra);
        amountSz = _scaleDownLossless(amountWei, evmDecimals, szDecimals);
    }

    /// @notice Lossy variant: scale a spot wei amount into szDecimals, rounding
    ///         toward zero. Used by paths that explicitly accept truncation —
    ///         e.g. order-submission code that rounds the user's intent to the
    ///         exchange-tradable lot size.
    function scaleSpotFromWeiRoundDown(uint32 token, uint256 amountWei) internal view returns (uint256 amountSz) {
        (uint8 szDecimals, uint8 weiDecimals, int8 evmExtra) = _spotDecimals(token);
        uint256 evmDecimals = _combineEvmDecimals(weiDecimals, evmExtra);
        amountSz = _scaleDownLossy(amountWei, evmDecimals, szDecimals);
    }

    // -------------------------------------------------------------------------
    // Perp — uses precompile 0x809 (PERP_ASSET_INFO).
    //
    // Perp positions don't have a `weiDecimals` field; the EVM-side scale is
    // the consuming protocol's choice (typically 18-decimal). The caller MUST
    // supply the target wei-decimals for the EVM-side denomination.
    // -------------------------------------------------------------------------

    /// @notice Scale a perp position size from HyperCore szDecimals into the
    ///         consumer's EVM-side wei representation. `targetWeiDecimals` is
    ///         the EVM-side scale the consumer denominates positions in (e.g.
    ///         18).
    function scalePerpToWei(uint32 asset, uint256 amountSz, uint8 targetWeiDecimals)
        internal
        view
        returns (uint256 amountWei)
    {
        uint8 szDecimals = _perpSzDecimals(asset);
        amountWei = _scaleUp(amountSz, szDecimals, targetWeiDecimals);
    }

    /// @notice Scale a perp position size from EVM-side wei back into HyperCore
    ///         szDecimals. Reverts `PrecisionLoss` on truncation.
    function scalePerpFromWei(uint32 asset, uint256 amountWei, uint8 sourceWeiDecimals)
        internal
        view
        returns (uint256 amountSz)
    {
        uint8 szDecimals = _perpSzDecimals(asset);
        amountSz = _scaleDownLossless(amountWei, sourceWeiDecimals, szDecimals);
    }

    // -------------------------------------------------------------------------
    // Generic `scale{To,From}Wei` — convenience wrappers that route to spot/perp
    // based on caller-provided market kind. Discouraged for new code (the
    // explicit `scaleSpot*` / `scalePerp*` pair is preferred), but ergonomically
    // useful for protocol layers that genuinely treat the two markets as the
    // same abstraction in some paths. The market-kind flag is the audit-trail
    // anchor for which precompile was consulted.
    // -------------------------------------------------------------------------

    enum MarketKind {
        Spot,
        Perp
    }

    /// @notice Generic szDecimals → wei scaling. For Perp markets `extra` is the
    ///         consumer's target wei decimal count (e.g. 18); for Spot it's
    ///         unused (the spot-side weiDecimals comes from precompile 0x80B).
    function scaleToWei(MarketKind kind, uint32 asset, uint256 amountSz, uint8 extra)
        internal
        view
        returns (uint256)
    {
        if (kind == MarketKind.Spot) return scaleSpotToWei(asset, amountSz);
        return scalePerpToWei(asset, amountSz, extra);
    }

    /// @notice Generic wei → szDecimals scaling (lossless variant). See
    ///         `scaleToWei` for the `extra` parameter convention.
    function scaleFromWei(MarketKind kind, uint32 asset, uint256 amountWei, uint8 extra)
        internal
        view
        returns (uint256)
    {
        if (kind == MarketKind.Spot) return scaleSpotFromWei(asset, amountWei);
        return scalePerpFromWei(asset, amountWei, extra);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev Combine `weiDecimals` + `evmExtraWeiDecimals` into the EVM-side
    ///      decimal count. Reverts `ScalingOverflow` if the sum is negative
    ///      (would mean fewer decimals than zero) or exceeds `MAX_DECIMALS`.
    function _combineEvmDecimals(uint8 weiDecimals, int8 evmExtra) private pure returns (uint256) {
        int256 combined = int256(uint256(weiDecimals)) + int256(evmExtra);
        if (combined < 0 || combined > int256(uint256(MAX_DECIMALS))) revert ScalingOverflow();
        // casting to 'uint256' is safe because the prior bound check ensures
        // combined ∈ [0, MAX_DECIMALS].
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(combined);
    }

    /// @dev Read (szDecimals, weiDecimals, evmExtraWeiDecimals) for a spot
    ///      token from precompile 0x80B.
    function _spotDecimals(uint32 token)
        private
        view
        returns (uint8 szDecimals, uint8 weiDecimals, int8 evmExtra)
    {
        (bool ok, bytes memory data) =
            HyperCorePrecompileAddresses.TOKEN_INFO.staticcall(abi.encode(token));
        if (!ok) revert PrecompileFailed(HyperCorePrecompileAddresses.TOKEN_INFO, token);
        // Decode only the three decimal fields. The wire struct is
        //   (string name, uint64[] spots, uint64 deployerTradingFeeShare,
        //    address deployer, address evmContract, uint8 szDecimals,
        //    uint8 weiDecimals, int8 evmExtraWeiDecimals)
        // We decode the full tuple and pull the three trailing fields.
        (, , , , , szDecimals, weiDecimals, evmExtra) = abi.decode(
            data,
            (string, uint64[], uint64, address, address, uint8, uint8, int8)
        );
        if (szDecimals > MAX_DECIMALS || weiDecimals > MAX_DECIMALS) revert ScalingOverflow();
    }

    /// @dev Read szDecimals for a perp asset from precompile 0x809.
    function _perpSzDecimals(uint32 asset) private view returns (uint8 szDecimals) {
        (bool ok, bytes memory data) =
            HyperCorePrecompileAddresses.PERP_ASSET_INFO.staticcall(abi.encode(asset));
        if (!ok) revert PrecompileFailed(HyperCorePrecompileAddresses.PERP_ASSET_INFO, asset);
        // Wire: (string name, uint32 marginTableId, uint8 szDecimals,
        //        uint8 maxLeverage, bool onlyIsolated)
        (, , szDecimals, , ) = abi.decode(data, (string, uint32, uint8, uint8, bool));
        if (szDecimals > MAX_DECIMALS) revert ScalingOverflow();
    }

    /// @dev Multiply `amount` by 10**(toDecimals - fromDecimals). Reverts
    ///      `ScalingOverflow` if toDecimals < fromDecimals (caller used the
    ///      wrong direction) or the multiply overflows uint256.
    function _scaleUp(uint256 amount, uint8 fromDecimals, uint256 toDecimals)
        private
        pure
        returns (uint256)
    {
        if (toDecimals < uint256(fromDecimals)) revert ScalingOverflow();
        uint256 diff = toDecimals - uint256(fromDecimals);
        if (diff > MAX_DECIMALS) revert ScalingOverflow();
        if (diff == 0) return amount;
        uint256 factor = 10 ** diff;
        // Solidity 0.8 reverts on multiply overflow — no manual check needed.
        return amount * factor;
    }

    /// @dev Divide `amount` by 10**(fromDecimals - toDecimals). Reverts
    ///      `PrecisionLoss` if any low-order digit would be truncated, i.e.
    ///      enforces a lossless round-trip.
    function _scaleDownLossless(uint256 amount, uint256 fromDecimals, uint8 toDecimals)
        private
        pure
        returns (uint256)
    {
        if (fromDecimals < uint256(toDecimals)) revert ScalingOverflow();
        uint256 diff = fromDecimals - uint256(toDecimals);
        if (diff > MAX_DECIMALS) revert ScalingOverflow();
        if (diff == 0) return amount;
        uint256 factor = 10 ** diff;
        uint256 scaled = amount / factor;
        if (scaled * factor != amount) {
            // casting to 'uint8' is safe because both decimal arguments are
            // capped at MAX_DECIMALS (30) by the entry points.
            // forge-lint: disable-next-line(unsafe-typecast)
            revert PrecisionLoss(amount, toDecimals, uint8(fromDecimals));
        }
        return scaled;
    }

    /// @dev Lossy round-down variant of `_scaleDownLossless`. Returns truncated
    ///      result without reverting.
    function _scaleDownLossy(uint256 amount, uint256 fromDecimals, uint8 toDecimals)
        private
        pure
        returns (uint256)
    {
        if (fromDecimals < uint256(toDecimals)) revert ScalingOverflow();
        uint256 diff = fromDecimals - uint256(toDecimals);
        if (diff > MAX_DECIMALS) revert ScalingOverflow();
        if (diff == 0) return amount;
        return amount / (10 ** diff);
    }
}
