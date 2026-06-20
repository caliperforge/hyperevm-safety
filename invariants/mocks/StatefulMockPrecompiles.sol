// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

// ── Stateful mock precompile contracts — echidna-compatible (no Foundry cheatcodes) ──
//
// These contracts are deployed by echidna at the canonical HyperCore precompile addresses
// (0x806 / 0x807 / 0x808 / 0x809 / 0x80B) via the `deployContracts` stanza in
// echidna.yaml, BEFORE CryticTester is deployed.
//
// Each mock has two surfaces:
//   READ  — the precompile's native interface: staticcall(abi.encode(input)) → raw bytes.
//            Handled by fallback() because the library sends raw ABI-encoded data with no
//            function selector. The EVM routes selector-less calldata to fallback().
//   WRITE — named setter functions called by Properties.sol during setup and target_* actions.
//            These have normal Solidity selectors that never collide with the uint32 read
//            calldata (which opens with bytes like 0x00000001, 0x00000007 etc., not
//            the pseudo-random keccak-based selector space).
//
// Foundry unit tests (*.t.sol) are UNAFFECTED: they import MockPrecompiles.sol
// (the vm.mockCall path) directly and do not reference Properties.sol.

/// @title MockMarkPrecompile — stateful mock for HyperCore mark-price precompile (0x806).
/// @notice Echidna pre-deploys this at 0x806 via deployContracts. Properties.sol calls
///         setMark() to prime values; HyperCoreOracleGuard and ChainlinkCompatAdapter
///         read via staticcall(abi.encode(asset)) which is routed to fallback().
contract MockMarkPrecompile {
    mapping(uint32 => uint64) private _prices;

    /// @notice Set the mock mark price for `asset`. Called by Properties during
    ///         _setupProperties() and target_setMark().
    function setMark(uint32 asset, uint64 price) external {
        _prices[asset] = price;
    }

    /// @notice Precompile read surface. Library call: staticcall(abi.encode(uint32 asset)).
    ///         Returns abi.encode(uint64 price). Calldata is 32 bytes, no function selector
    ///         → EVM routes to fallback().
    fallback() external {
        // Minimum 32 bytes: the library encodes a uint32 asset padded to one EVM word.
        require(msg.data.length >= 32, "MockMarkPrecompile: calldata too short");
        uint32 asset = abi.decode(msg.data, (uint32));
        bytes memory ret = abi.encode(_prices[asset]);
        // Return raw bytes, bypassing Solidity's return ABI wrapper.
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}

/// @title MockOraclePrecompile — stateful mock for HyperCore oracle-price precompile (0x807).
contract MockOraclePrecompile {
    mapping(uint32 => uint64) private _prices;

    /// @notice Set the mock oracle price for `asset`.
    function setOracle(uint32 asset, uint64 price) external {
        _prices[asset] = price;
    }

    /// @notice Precompile read surface — same ABI shape as MockMarkPrecompile.
    fallback() external {
        require(msg.data.length >= 32, "MockOraclePrecompile: calldata too short");
        uint32 asset = abi.decode(msg.data, (uint32));
        bytes memory ret = abi.encode(_prices[asset]);
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}

/// @title MockL1BlockPrecompile — stateful mock for HyperCore L1-block precompile (0x808).
/// @notice Library call: staticcall("") (empty calldata) → abi.encode(uint64 blockNum).
///         With empty calldata and no receive() function, EVM routes to fallback().
contract MockL1BlockPrecompile {
    uint64 private _blockNum;

    /// @notice Set the mock L1 block number.
    function setL1Block(uint64 b) external {
        _blockNum = b;
    }

    /// @notice Precompile read surface. Handles both 0-byte calldata (L1 block query from
    ///         library: staticcall("")) and any non-matching calldata gracefully.
    fallback() external {
        bytes memory ret = abi.encode(_blockNum);
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}

/// @title MockPerpAssetInfoPrecompile — stateful mock for precompile 0x809.
/// @notice Wire shape (per IHyperCorePrecompiles.PerpAssetInfo):
///         (string name, uint32 marginTableId, uint8 szDecimals, uint8 maxLeverage,
///          bool onlyIsolated)
///         SzDecimalsLib decodes: (, , szDecimals, , ) — fields 0,1,3,4 are ignored.
contract MockPerpAssetInfoPrecompile {
    struct PerpInfo {
        uint8 szDecimals;
        // Other fields kept at zero defaults; library only reads szDecimals.
    }
    mapping(uint32 => PerpInfo) private _info;

    /// @notice Set szDecimals for a perp asset. Called by Properties during
    ///         _setupProperties() and any future target_* that changes perp decimals.
    function setPerpAssetInfo(uint32 asset, uint8 szDecimals) external {
        _info[asset].szDecimals = szDecimals;
    }

    /// @notice Precompile read surface — returns the full 5-field tuple so the library's
    ///         abi.decode(data, (string, uint32, uint8, uint8, bool)) succeeds.
    fallback() external {
        require(msg.data.length >= 32, "MockPerpAssetInfoPrecompile: calldata too short");
        uint32 asset = abi.decode(msg.data, (uint32));
        uint8 sz = _info[asset].szDecimals;
        bytes memory ret = abi.encode(
            string("MOCK-PERP"), // name (ignored by library)
            uint32(0),           // marginTableId (ignored)
            sz,                  // szDecimals — the only field SzDecimalsLib reads
            uint8(1),            // maxLeverage (ignored)
            false                // onlyIsolated (ignored)
        );
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}

/// @title MockTokenInfoPrecompile — stateful mock for precompile 0x80B.
/// @notice Wire shape (per IHyperCorePrecompiles.TokenInfo):
///         (string name, uint64[] spots, uint64 deployerTradingFeeShare,
///          address deployer, address evmContract, uint8 szDecimals,
///          uint8 weiDecimals, int8 evmExtraWeiDecimals)
///         SzDecimalsLib decodes: (, , , , , szDecimals, weiDecimals, evmExtra).
contract MockTokenInfoPrecompile {
    struct TokenInfo {
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
        // Other fields kept at zero/empty defaults; library only reads the three decimal fields.
    }
    mapping(uint32 => TokenInfo) private _info;

    /// @notice Set decimal fields for a spot token.
    function setTokenInfo(uint32 token, uint8 szDecimals, uint8 weiDecimals, int8 evmExtra) external {
        _info[token] = TokenInfo({
            szDecimals: szDecimals,
            weiDecimals: weiDecimals,
            evmExtraWeiDecimals: evmExtra
        });
    }

    /// @notice Precompile read surface — returns the full 8-field tuple so the library's
    ///         abi.decode(data, (string, uint64[], uint64, address, address, uint8, uint8, int8))
    ///         succeeds.
    fallback() external {
        require(msg.data.length >= 32, "MockTokenInfoPrecompile: calldata too short");
        uint32 token = abi.decode(msg.data, (uint32));
        TokenInfo storage t = _info[token];
        uint64[] memory spots = new uint64[](0); // empty array — library ignores this field
        bytes memory ret = abi.encode(
            string("MOCK-TOKEN"),     // name (ignored)
            spots,                    // spots (ignored)
            uint64(0),                // deployerTradingFeeShare (ignored)
            address(0),               // deployer (ignored)
            address(0),               // evmContract (ignored)
            t.szDecimals,             // szDecimals — read by SzDecimalsLib
            t.weiDecimals,            // weiDecimals — read by SzDecimalsLib
            t.evmExtraWeiDecimals     // evmExtraWeiDecimals — read by SzDecimalsLib
        );
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}
