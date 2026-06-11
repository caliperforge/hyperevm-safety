// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IHyperCorePrecompiles — typed surface for HyperEVM read precompiles.
/// @notice Address-keyed read precompiles HyperCore exposes to HyperEVM contracts.
///         Canonical docs: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore
///
/// @dev The precompile contract addresses are constants below. Each read is performed
///      via low-level `staticcall` on the address with an ABI-encoded argument; HyperCore
///      returns ABI-encoded data per the docs surface. The interface methods below are
///      provided as a typed wrapper convention — the actual call is staticcall at the
///      consuming-library layer (`HyperCoreOracleGuard`, `SzDecimalsLib`). This file is
///      the single source of truth for precompile addresses + ABI shapes used across
///      `src/`.
///
///      Per the T-2 purrkit-vs-hyper-evm-lib evaluation (see
///      `docs/hyper-evm-lib-notes.md`): this interface is what `hyper-evm-lib`'s
///      `PrecompileLib` ABI surface compiles
///      against on the consumer side. The simulator side (`CoreSimulator` etc.) is a
///      test-only concern; we depend on the precompile address + ABI pair, not on a
///      specific simulator implementation. The simulator is pinned via
///      `.github/actions/foundry-setup/action.yml` for CI determinism.
interface IHyperCorePrecompiles {
    // -------------------------------------------------------------------------
    // Precompile addresses — Hyperliquid HyperCore read surface.
    // -------------------------------------------------------------------------
    // The addresses below are mirrored as Solidity `address` constants in
    // `HyperCorePrecompileAddresses` (see below) so library code can reference
    // them by name. Keep this list in sync with the canonical Hyperliquid docs
    // URL above.
    //
    // 0x800: position info (perp positions by user + asset)
    // 0x801: spot balance (user + token)
    // 0x802: vault equity
    // 0x803: withdrawable USDC
    // 0x804: delegations (HYPE staking)
    // 0x805: delegator summary
    // 0x806: mark price (perp mark, per asset)
    // 0x807: oracle price (perp oracle, per asset)
    // 0x808: L1 block number (HyperCore-side block height observable from EVM)
    // 0x809: perp asset info (szDecimals, etc. for perps)
    // 0x80A: spot info (token pair info for spot markets)
    // 0x80B: token info (szDecimals + weiDecimals for spot tokens)

    /// @notice Mark price for a perp asset (precompile 0x806).
    /// @param asset Perp asset index (Hyperliquid asset id).
    /// @return markPrice Mark price in 8-decimal precision (HyperCore convention).
    function readMark(uint32 asset) external view returns (uint64 markPrice);

    /// @notice Oracle price for a perp asset (precompile 0x807).
    /// @param asset Perp asset index.
    /// @return oraclePrice Oracle price in 8-decimal precision.
    function readOracle(uint32 asset) external view returns (uint64 oraclePrice);

    /// @notice HyperCore L1 block number (precompile 0x808). The HyperCore-side
    ///         block height as observed from HyperEVM at the start of the current
    ///         EVM block. Used as the staleness watermark — a read that returns
    ///         an L1 block older than `block.number - MAX_STALENESS_BLOCKS` is
    ///         stale.
    /// @return l1Block HyperCore L1 block number.
    function readL1BlockNumber() external view returns (uint64 l1Block);

    /// @notice Perp asset info (precompile 0x809).
    /// @param asset Perp asset index.
    function readPerpAssetInfo(uint32 asset) external view returns (PerpAssetInfo memory);

    /// @notice Spot token info (precompile 0x80B).
    /// @param token Spot token index.
    function readTokenInfo(uint32 token) external view returns (TokenInfo memory);

    // -------------------------------------------------------------------------
    // Struct shapes — wire-compatible with HyperCore docs. Only the fields the
    // library reads are materialised here; the unused tail of the wire struct
    // is decoded but not exposed to keep this interface minimal.
    // -------------------------------------------------------------------------

    /// @notice Perp asset info as returned by precompile 0x809.
    struct PerpAssetInfo {
        string name;
        uint32 marginTableId;
        uint8 szDecimals; // perp szDecimals (distinct from spot — see SzDecimalsLib)
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    /// @notice Spot token info as returned by precompile 0x80B.
    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals; // spot szDecimals
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }
}

/// @title HyperCorePrecompileAddresses — address constants for the precompile surface.
/// @notice Library code references these by name (e.g. `HyperCorePrecompileAddresses.MARK`)
///         rather than re-declaring the hex literal at the call site. Keep in sync with
///         the address comments in `IHyperCorePrecompiles`.
library HyperCorePrecompileAddresses {
    address internal constant POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant VAULT_EQUITY = 0x0000000000000000000000000000000000000802;
    address internal constant WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant DELEGATIONS = 0x0000000000000000000000000000000000000804;
    address internal constant DELEGATOR_SUMMARY = 0x0000000000000000000000000000000000000805;
    address internal constant MARK = 0x0000000000000000000000000000000000000806;
    address internal constant ORACLE = 0x0000000000000000000000000000000000000807;
    address internal constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000808;
    address internal constant PERP_ASSET_INFO = 0x0000000000000000000000000000000000000809;
    address internal constant SPOT_INFO = 0x000000000000000000000000000000000000080a;
    address internal constant TOKEN_INFO = 0x000000000000000000000000000000000000080b;
}
