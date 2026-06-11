// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IHyperCoreWriter — typed surface for the HyperEVM → HyperCore CoreWriter.
/// @notice CoreWriter is the single sink address HyperEVM contracts call to submit
///         actions (perp orders, spot transfers, etc.) that HyperCore settles on its
///         own L1. Submission is `sendRawAction(bytes)`; settlement happens at
///         HyperCore-side block ≥ N+1 relative to the EVM-side submission block N.
///
///         Canonical docs: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore
///
/// @dev The dual-block window (submit at N, settle at ≥ N+1) is the load-bearing
///      semantic D-5 (`CoreWriterSolvencyWindow`) guards against. EVM-side accounting
///      MUST NOT treat a CoreWriter submission as settled in the same block — the
///      `HyperCoreOracleGuard` + `CoreWriterSolvency` (M2) library code enforces this
///      at the consumer layer.
///
///      Per T-2 evaluation: hyper-evm-lib's `CoreWriterLib` ABI matches this surface;
///      we depend on the wire ABI, not on the simulator's settlement-modelling depth.
///      The dual-block coverage caveat is documented in `docs/hyper-evm-lib-notes.md`.
interface IHyperCoreWriter {
    /// @notice The CoreWriter address — well-known on HyperEVM mainnet + testnet.
    /// @dev Documented in the Hyperliquid HyperEVM docs (see link above).
    function CORE_WRITER_ADDRESS() external pure returns (address);

    /// @notice Submit a raw HyperCore action. Settlement is asynchronous; the
    ///         transaction MAY succeed on EVM-side without the action having
    ///         settled on HyperCore-side. Callers MUST NOT treat success here as
    ///         settlement — see `CoreWriterSolvency.assertSettlementWindowInvariant()`
    ///         (M2 ticket T-7).
    /// @param rawAction Action ABI-encoded per the HyperCore action ABI.
    function sendRawAction(bytes calldata rawAction) external;
}

/// @title HyperCoreWriterAddress — the well-known CoreWriter sink address.
/// @notice Pinned to the value documented at the link above. Wrap in a library
///         so library code references it by name.
library HyperCoreWriterAddress {
    /// @notice HyperCore CoreWriter address (HyperEVM mainnet + testnet share this
    ///         well-known sink).
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
}
