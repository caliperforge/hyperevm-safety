// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {HyperCorePrecompileAddresses} from "../../src/interfaces/IHyperCorePrecompiles.sol";

/// @title MockPrecompiles — controllable HyperCore precompile mocks for invariant tests.
/// @notice The library code in `src/` calls real HyperCore precompile addresses via
///         low-level staticcall. For invariant tests we need to drive those reads
///         deterministically — set a mark price, freeze the L1 block, etc. — without
///         depending on the full hyper-evm-lib simulator's settlement machinery.
///
///         This library uses Foundry's `vm.mockCall` cheatcode to register precompile
///         responses. Each `set*` registers a mock at the canonical precompile address
///         (0x806 / 0x807 / 0x808 / 0x809 / 0x80B) with the specified return value;
///         subsequent staticcalls to that address return the mock data.
///
///         **Why not hyper-evm-lib's `CoreSimulator` here.** Per the T-2
///         purrkit-vs-`hyper-evm-lib` evaluation (see
///         `docs/hyper-evm-lib-notes.md`), hyper-evm-lib is the canonical
///         simulator for downstream protocols. For the
///         library's own M1 invariant tests we keep the read surface a Foundry-cheatcode
///         mock so the tests are deterministic, buildable without taking on simulator
///         API drift, and free of any settlement-machinery coupling the M1 properties
///         don't need. Downstream consumers wiring this library into their own Foundry
///         suite can either reuse these mocks or swap them for `CoreSimulator.setSpotPx`
///         — both surfaces hit the same precompile addresses. The trade-off is documented
///         at `docs/hyper-evm-lib-notes.md`.
library MockPrecompiles {
    address private constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));

    function _vm() private pure returns (Vm) {
        return Vm(HEVM_ADDRESS);
    }

    // -------------------------------------------------------------------------
    // Mark / oracle / L1-block setters
    // -------------------------------------------------------------------------

    /// @notice Register a mark-price response for `asset` on precompile 0x806.
    ///         Subsequent staticcalls to 0x806 with `abi.encode(asset)` return
    ///         `abi.encode(price)`.
    function setMark(uint32 asset, uint64 price) internal {
        _vm().mockCall(HyperCorePrecompileAddresses.MARK, abi.encode(asset), abi.encode(price));
    }

    /// @notice Register an oracle-price response for `asset` on precompile 0x807.
    function setOracle(uint32 asset, uint64 price) internal {
        _vm().mockCall(HyperCorePrecompileAddresses.ORACLE, abi.encode(asset), abi.encode(price));
    }

    /// @notice Register the HyperCore L1 block number returned by precompile 0x808.
    function setL1BlockNumber(uint64 b) internal {
        // L1 block precompile takes no input; mock with empty calldata.
        _vm().mockCall(HyperCorePrecompileAddresses.L1_BLOCK_NUMBER, bytes(""), abi.encode(b));
    }

    /// @notice Register spot-token decimals on precompile 0x80B.
    function setSpotDecimals(uint32 token, uint8 szDecimals, uint8 weiDecimals, int8 evmExtra) internal {
        uint64[] memory spots = new uint64[](0);
        bytes memory ret = abi.encode(
            string("MOCK-TOKEN"),
            spots,
            uint64(0),
            address(0),
            address(0),
            szDecimals,
            weiDecimals,
            evmExtra
        );
        _vm().mockCall(HyperCorePrecompileAddresses.TOKEN_INFO, abi.encode(token), ret);
    }

    /// @notice Register perp asset szDecimals on precompile 0x809.
    function setPerpSzDecimals(uint32 asset, uint8 szDecimals) internal {
        bytes memory ret = abi.encode(
            string("MOCK-PERP"),
            uint32(0),
            szDecimals,
            uint8(1),
            false
        );
        _vm().mockCall(HyperCorePrecompileAddresses.PERP_ASSET_INFO, abi.encode(asset), ret);
    }

    // -------------------------------------------------------------------------
    // Failure-mode setters — induce a precompile revert. Used by the readers'
    // PrecompileFailed assertions.
    // -------------------------------------------------------------------------

    /// @notice Make subsequent calls to `precompile` with `data` revert.
    function setPrecompileReverts(address precompile, bytes memory data) internal {
        _vm().mockCallRevert(precompile, data, "precompile: induced revert");
    }
}
