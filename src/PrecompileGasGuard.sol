// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title PrecompileGasGuard — DoS-resilient wrapper for HyperCore precompile reads.
/// @notice D-4 of the differentiated taxonomy (spec.md §3.1). HyperCore precompile
///         failures carry an **all-gas-consumed** semantic: a failed read does NOT
///         return a clean `success=false` with the forwarded gas budget intact —
///         it burns the gas slice the caller forwarded and surfaces as an
///         out-of-gas-shaped revert.
///
///         The bug class this library catches is consumer code that *soft-handles*
///         a precompile failure: a `try ... catch { lastPrice = 0; }` block or an
///         `if (!success) lastPrice = lastKnown;` branch that treats the failure
///         path as a default-value assignment and PROCEEDS with stale or zero data.
///         When the underlying read can be DoS'd or rate-limited, that branch
///         becomes the attacker's foothold — the protocol prices off a default
///         the attacker chose the timing of.
///
///         The defense pattern, encoded by `callOrRevert`:
///
///           (1) Forward `gasBound` gas (or all remaining if unspecified) to the
///               precompile via low-level `staticcall`.
///           (2) On `success=false`, REVERT with the original return data bubbled
///               up where present; structured `PrecompileCallFailed(precompile,
///               data, ret)` otherwise. NEVER return a default value.
///           (3) On `success=true` with empty return data, REVERT
///               `PrecompileEmptyReturn`. The all-gas-consumed semantic on real
///               HyperCore produces this shape on certain failure modes the EVM
///               simulator cannot otherwise reproduce; this guard surfaces it.
///
/// @dev Property test: `invariants/PrecompileGasDoS.t.sol`. Across any stateful
///      sequence with one failed precompile call, no caller state is mutated.
///      The planted-hunk twin replaces `callOrRevert` with a try/catch-default
///      pattern and fires `INVARIANT VIOLATED PrecompileGasDoS` on the same
///      sequence.
///
///      **Simulator caveat.** Per `docs/hyper-evm-lib-notes.md`, neither
///      `hyper-evm-lib` nor `purrkit` reproduce the gas-burn shape of a real
///      HyperCore precompile failure (an EVM-vs-HyperCore boundary). The
///      property models the bug class at the call-result level (success=false
///      OR empty return data) rather than at the gas-consumption level. A
///      Halmos symbolic spec (planned, T-8 / M2) will be the formal backstop
///      for the EVM-side state-mutation guarantee; not yet in-tree at v0.1.
library PrecompileGasGuard {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The precompile call returned `success=false`. The `returnData`
    ///         field carries whatever the precompile wrote to the return
    ///         buffer before the failure (often empty under all-gas-consumed).
    error PrecompileCallFailed(address precompile, bytes callData, bytes returnData);

    /// @notice The precompile call returned `success=true` but with a
    ///         zero-length return buffer. Under HyperCore's all-gas-consumed
    ///         semantic this is a known failure shape on simulator paths that
    ///         cannot reproduce a gas burn. Treating an empty buffer as a
    ///         zero-valued default is the bug class — the guard refuses to
    ///         do so.
    error PrecompileEmptyReturn(address precompile, bytes callData);

    // -------------------------------------------------------------------------
    // Wrappers
    // -------------------------------------------------------------------------

    /// @notice Static-call `precompile` with `data`, forwarding all remaining
    ///         gas. On failure, REVERTS — never returns a default. On empty
    ///         return data, REVERTS `PrecompileEmptyReturn`.
    /// @param precompile The HyperCore precompile address (0x800–0x80B).
    /// @param data ABI-encoded precompile argument bytes.
    /// @return ret The precompile's return buffer (guaranteed non-empty).
    function callOrRevert(address precompile, bytes memory data) internal view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = precompile.staticcall(data);
        if (!ok) {
            // Bubble the precompile's return data through as the revert reason
            // when it is non-empty (preserves any structured error the
            // simulator surfaced); else revert with the typed error so the
            // call-site receives a stable selector.
            if (ret.length > 0) {
                /// @solidity memory-safe-assembly
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            revert PrecompileCallFailed(precompile, data, ret);
        }
        if (ret.length == 0) {
            revert PrecompileEmptyReturn(precompile, data);
        }
    }

    /// @notice Static-call `precompile` with `data`, forwarding at most
    ///         `gasBound` gas. The caller retains `gasleft() - gasBound` for
    ///         post-call work even if the precompile consumes its slice
    ///         entirely (all-gas-consumed semantic). Same failure-surfacing
    ///         contract as `callOrRevert` — no silent `success=false`.
    /// @dev The DoS-resilient pattern. Use this when the call site MUST
    ///      continue execution (e.g., a liquidation loop that should skip the
    ///      affected position rather than revert the whole transaction); the
    ///      bounded slice contains the gas burn and the typed revert lets the
    ///      outer call site decide whether to skip or propagate.
    function callOrRevertWithGas(address precompile, bytes memory data, uint256 gasBound)
        internal
        view
        returns (bytes memory ret)
    {
        bool ok;
        (ok, ret) = precompile.staticcall{gas: gasBound}(data);
        if (!ok) {
            if (ret.length > 0) {
                /// @solidity memory-safe-assembly
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            revert PrecompileCallFailed(precompile, data, ret);
        }
        if (ret.length == 0) {
            revert PrecompileEmptyReturn(precompile, data);
        }
    }
}
