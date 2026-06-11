// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {HyperCorePrecompileAddresses} from "./interfaces/IHyperCorePrecompiles.sol";

/// @title ChainlinkCompatAdapter — correct `AggregatorV3Interface` shim over HyperCore.
/// @notice Lender code that consumes price feeds via Chainlink's `AggregatorV3Interface`
///         checks `block.timestamp - updatedAt < stalenessBound` to refuse stale prices.
///         The interface assumes `updatedAt` is the timestamp at which the upstream
///         oracle produced the value — not the timestamp of the EVM block that exposed
///         it.
///
/// @notice **The broken pattern this replaces.** A naive HyperCore-on-HyperEVM
///         shim that does:
///
///         ```solidity
///         function latestRoundData() returns (..., uint256 updatedAt, ...) {
///             // BROKEN: always returns the current block timestamp; the
///             // downstream staleness gate ALWAYS PASSES because every read
///             // looks fresh — even when HyperCore has halted and the price
///             // is frozen.
///             return (..., block.timestamp, ...);
///         }
///         ```
///
///         This pattern is in production today on multiple HyperEVM-lending
///         integrations. Generic EVM auditors approve it because the
///         Chainlink-on-Ethereum reference looks identical to the eye —
///         Ethereum has no separate publication-block notion to expose. On
///         HyperEVM, the publication block IS observable (via the HyperCore L1
///         block precompile 0x808) and the adapter MUST surface it.
///
/// @notice **What this adapter does instead.** `latestRoundData` returns
///         `updatedAt = block_to_timestamp(HyperCore_L1_block_number)`. The
///         HyperCore L1 block number is read from precompile 0x808 at call
///         time; the consumer's existing `block.timestamp - updatedAt`
///         staleness check now correctly fires when HyperCore halts or skips a
///         publication.
///
/// @dev D-6 of the differentiated taxonomy (spec.md §3.1) — the highest-impact
///      differentiated invariant per the spec's own characterisation.
///      Property test: `invariants/ChainlinkAdapterDefeats.t.sol`.
///
///      The conversion `HyperCore L1 block → timestamp` requires a block-cadence
///      assumption. HyperCore's block time is ~0.07s in steady state; we expose
///      it as an immutable constructor parameter rather than hardcode, so a
///      future block-time change is a redeployment (not a silent drift).
///
///      Decimals: HyperCore returns prices in 8-decimal precision (per the docs
///      surface); Chainlink consumers typically expect 8 (USD feeds) or 18.
///      `decimals` is set at construction so the adapter can be parameterised
///      per feed; `latestRoundData`'s `answer` is the raw HyperCore uint64
///      cast to int256 with the configured decimals.
contract ChainlinkCompatAdapter {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The underlying precompile call failed (mark/oracle read or L1
    ///         block read). Surfaced rather than silently returning a sentinel
    ///         (D-4 motivation — failed precompiles MUST NOT pass through as
    ///         success).
    error PrecompileFailed(address precompile);

    /// @notice Decimal configuration overflow (the configured decimals would
    ///         exceed int256's safe range when scaling the raw price).
    error DecimalsOverflow();

    /// @notice The constructor was passed an invalid configuration.
    error InvalidConfig();

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    /// @notice Which precompile to read. Set at construction to either
    ///         `HyperCorePrecompileAddresses.MARK` (0x806) or
    ///         `HyperCorePrecompileAddresses.ORACLE` (0x807).
    address public immutable priceSource;

    /// @notice HyperCore perp asset / spot token id this adapter is bound to.
    uint32 public immutable asset;

    /// @notice Decimals of `answer` returned by `latestRoundData`. Typical
    ///         values: 8 (Chainlink USD-feed convention) or 18.
    uint8 public immutable decimals;

    /// @notice Genesis timestamp of HyperCore's L1 block 0. Used to translate
    ///         the L1 block number returned by precompile 0x808 into a
    ///         block-publish timestamp. Set at construction so a future
    ///         block-cadence change is an explicit redeployment.
    uint64 public immutable hyperCoreGenesisTimestamp;

    /// @notice HyperCore L1 block cadence, in milliseconds. Used to translate
    ///         the L1 block number into a publish timestamp.
    uint64 public immutable hyperCoreBlockMs;

    /// @notice Description string returned by `description()`.
    string private _description;

    /// @notice AggregatorV3Interface protocol version. Chainlink's reference
    ///         returns 4; we return the same to keep downstream guards happy.
    uint256 public constant version = 4;

    constructor(
        address priceSource_,
        uint32 asset_,
        uint8 decimals_,
        uint64 hyperCoreGenesisTimestamp_,
        uint64 hyperCoreBlockMs_,
        string memory description_
    ) {
        if (priceSource_ != HyperCorePrecompileAddresses.MARK && priceSource_ != HyperCorePrecompileAddresses.ORACLE)
        {
            revert InvalidConfig();
        }
        if (decimals_ == 0 || decimals_ > 30 || hyperCoreBlockMs_ == 0) revert InvalidConfig();
        priceSource = priceSource_;
        asset = asset_;
        decimals = decimals_;
        hyperCoreGenesisTimestamp = hyperCoreGenesisTimestamp_;
        hyperCoreBlockMs = hyperCoreBlockMs_;
        _description = description_;
    }

    // -------------------------------------------------------------------------
    // AggregatorV3Interface surface
    // -------------------------------------------------------------------------

    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice Returns the latest round data. Critically, `updatedAt` is the
    ///         **HyperCore publication-block timestamp** (derived from the L1
    ///         block number precompile), NOT `block.timestamp`. This is the
    ///         entire reason the adapter exists — see the contract NatSpec.
    /// @return roundId Always equal to `answeredInRound`; HyperCore doesn't
    ///                 expose round-id semantics, so we surface the L1 block
    ///                 number as the round id (monotonic and unique).
    /// @return answer  Raw HyperCore price, sign-cast to int256, scaled by the
    ///                 configured decimals.
    /// @return startedAt Same as `updatedAt` — HyperCore doesn't distinguish
    ///                 round-start from round-publish.
    /// @return updatedAt **HyperCore publication-block timestamp.** Computed as
    ///                 `genesisTimestamp + L1_block * blockMs / 1000`. NOT
    ///                 `block.timestamp`.
    /// @return answeredInRound Same as `roundId`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Read the price precompile.
        (bool okPrice, bytes memory priceData) = priceSource.staticcall(abi.encode(asset));
        if (!okPrice || priceData.length < 32) revert PrecompileFailed(priceSource);
        uint64 rawPrice = abi.decode(priceData, (uint64));

        // Read the L1 block number precompile — this is the load-bearing read.
        (bool okBlock, bytes memory blockData) =
            HyperCorePrecompileAddresses.L1_BLOCK_NUMBER.staticcall("");
        if (!okBlock || blockData.length < 32) {
            revert PrecompileFailed(HyperCorePrecompileAddresses.L1_BLOCK_NUMBER);
        }
        uint64 l1Block = abi.decode(blockData, (uint64));

        // Translate L1 block → publish timestamp.
        // updatedAt = genesisTimestamp + (l1Block * blockMs) / 1000
        uint256 publishMs = uint256(l1Block) * uint256(hyperCoreBlockMs);
        uint256 publishTs = uint256(hyperCoreGenesisTimestamp) + (publishMs / 1000);

        // Scale the price to the configured decimals. HyperCore returns 8-decimal
        // precision; if the consumer wants more (e.g. 18), pad with zeros.
        // If they want less (rare), drop digits — this is integer truncation
        // and the adapter MUST be configured to match the consumer's expected
        // feed decimals.
        int256 scaledAnswer = _scaleToDecimals(rawPrice, 8, decimals);

        // Round-id surfaces the L1 block (unique + monotonic).
        roundId = uint80(l1Block);
        answer = scaledAnswer;
        startedAt = publishTs;
        updatedAt = publishTs;
        answeredInRound = uint80(l1Block);
    }

    /// @notice Historical round data is NOT supported. HyperCore doesn't expose
    ///         historical reads via the precompile surface; callers that
    ///         require a Chainlink-compatible `getRoundData` MUST use the
    ///         `latestRoundData` surface and snapshot off-chain. Reverting here
    ///         is deliberate — silently returning the latest round under a
    ///         "historical" call would mask bugs in consumer code that thinks
    ///         it's reading an older round.
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("HyperCore: historical rounds unavailable");
    }

    /// @notice Chainlink reference adapters also expose `latestAnswer`,
    ///         `latestTimestamp` etc. (the legacy V2 surface). We omit them by
    ///         design — the broken-pattern variant of this adapter typically
    ///         re-uses `latestAnswer` to return raw price and `latestTimestamp`
    ///         to return `block.timestamp`. Consumers MUST use the V3 surface
    ///         (`latestRoundData`) to pick up the corrected `updatedAt`.

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev Scale `raw` from `fromDecimals` to `toDecimals` and sign-cast.
    function _scaleToDecimals(uint64 raw, uint8 fromDecimals, uint8 toDecimals)
        private
        pure
        returns (int256)
    {
        uint256 v = uint256(raw);
        if (toDecimals > fromDecimals) {
            uint256 diff = uint256(toDecimals) - uint256(fromDecimals);
            if (diff > 30) revert DecimalsOverflow();
            v = v * (10 ** diff);
        } else if (fromDecimals > toDecimals) {
            uint256 diff = uint256(fromDecimals) - uint256(toDecimals);
            if (diff > 30) revert DecimalsOverflow();
            v = v / (10 ** diff);
        }
        if (v > uint256(type(int256).max)) revert DecimalsOverflow();
        // casting to 'int256' is safe because the prior bound check ensures v
        // fits int256's positive range.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(v);
    }
}
