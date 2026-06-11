// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {HyperCorePrecompileAddresses} from "./interfaces/IHyperCorePrecompiles.sol";

/// @title HyperCoreOracleGuard — staleness + deviation guards for HyperCore mark/oracle reads.
/// @notice Wraps reads of the HyperCore mark (0x806) and oracle (0x807) precompiles with
///         two checks the underlying precompile does NOT enforce on its own:
///
///           (1) **Staleness** — the HyperCore L1 block number (0x808) advanced no more
///               than `MAX_STALENESS_BLOCKS` ago. A HyperCore halt or skipped publish
///               leaves the read at a frozen value; without a staleness gate, consumers
///               price off a stuck feed. Reverts `Stale()` on violation.
///
///           (2) **Deviation** — the current read deviates from the trailing TWAP
///               window by at most `maxDeviationBps`. Single-block manipulated marks
///               and cross-precompile inconsistency (0x806 vs 0x807 disagreement) are
///               surfaced via this gate. Reverts `Deviation()` on violation.
///
/// @dev D-1 (`OracleStaleness`) and D-2 (`OracleDeviation`) of the differentiated
///      taxonomy (spec.md §3.1). Property tests live at
///      `invariants/OracleStaleness.t.sol` and `invariants/OracleDeviation.t.sol`.
///
///      The TWAP is computed inside this contract over a configurable trailing window;
///      each call to `readMarkWithDeviationBound` / `readOracleWithDeviationBound`
///      records the read into a fixed-size ring buffer keyed by asset. The buffer is
///      stateful, so this contract MUST be deployed (not used as a pure library) when
///      deviation guards are required.
///
///      For staleness-only consumers, the `readMark` / `readOracle` paths are
///      stateless and safe to call from a pure library context — they read the
///      precompiles directly and check the staleness watermark inline.
contract HyperCoreOracleGuard {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The HyperCore L1 block number is older than the staleness bound;
    ///         the read is stale and MUST NOT be consumed.
    ///         `evmBlock` is the EVM-side `block.number` at the read site, used
    ///         to compute the lag against the HyperCore L1 block.
    error Stale(uint64 currentL1Block, uint64 evmBlock, uint64 maxStalenessBlocks);

    /// @notice The current read deviates from the trailing TWAP window by more
    ///         than `maxDeviationBps`. Common cause: single-block mark
    ///         manipulation; cross-precompile inconsistency.
    error Deviation(uint256 current, uint256 twap, uint16 deviationBps, uint16 maxDeviationBps);

    /// @notice The trailing TWAP window has not yet accumulated enough samples
    ///         to enforce a deviation check. Surfaced by the `*Twap` view
    ///         accessors when called against a cold window. The `read*WithDeviationBound`
    ///         path does NOT revert this — it warms the window in place
    ///         (each call pushes a sample, deviation check engages once `count == windowSize`).
    error WindowNotWarm(uint32 asset, uint8 samplesAccumulated, uint8 windowSize);

    /// @notice The configured staleness/deviation parameters are invalid.
    error InvalidConfig();

    /// @notice The underlying precompile call failed. Surfaced rather than
    ///         silently returning a default — see D-4 motivation in spec §3.1.
    error PrecompileFailed(address precompile, uint32 asset);

    // -------------------------------------------------------------------------
    // Configuration — set once at construction; the contract is owner-less by
    // design (per-consumer deployment, not a shared singleton).
    // -------------------------------------------------------------------------

    /// @notice Maximum number of HyperEVM blocks the HyperCore L1 block may lag
    ///         before a read is treated as stale. Typical value: a small number
    ///         of HyperEVM blocks (e.g. 5) — HyperEVM and HyperCore block cadence
    ///         is roughly aligned in steady state; significant lag is the
    ///         signal the staleness gate is designed to surface.
    uint64 public immutable maxStalenessBlocks;

    /// @notice Trailing window length (in samples) used for the deviation TWAP.
    ///         Each `read*WithDeviationBound` call pushes one sample.
    uint8 public immutable windowSize;

    /// @notice Maximum permitted absolute deviation of the current read from
    ///         the trailing TWAP, expressed in basis points (1bp = 0.01%).
    ///         Reverts `Deviation()` above this bound.
    uint16 public immutable maxDeviationBps;

    /// @dev Hard cap on `windowSize` to keep per-asset storage bounded.
    uint8 private constant MAX_WINDOW_SIZE = 64;

    /// @dev Hard cap on `maxDeviationBps` (10_000 bp = 100%); above this
    ///      the deviation check is effectively off — better to fail config
    ///      validation than ship a misconfigured guard.
    uint16 private constant MAX_DEVIATION_BPS_CAP = 10_000;

    // -------------------------------------------------------------------------
    // Per-asset trailing-window state. Two distinct rings: one for mark reads,
    // one for oracle reads. Each ring tracks samples + a running sum so the
    // TWAP computation is O(1) per call.
    // -------------------------------------------------------------------------

    struct Ring {
        uint64[64] samples; // sized to MAX_WINDOW_SIZE; only first windowSize entries used
        uint64 sum;         // sum of the first `count` slots (windowed)
        uint8 head;         // next write index, mod windowSize
        uint8 count;        // number of samples accumulated (≤ windowSize)
    }

    mapping(uint32 => Ring) private _markRing;
    mapping(uint32 => Ring) private _oracleRing;

    constructor(uint64 maxStalenessBlocks_, uint8 windowSize_, uint16 maxDeviationBps_) {
        // Staleness bound of zero is a misconfig (every read would revert).
        // Window size must be in [1, MAX_WINDOW_SIZE]; deviation bps must be
        // strictly positive (zero would treat any sample drift as a violation,
        // which is unusable) and below the cap.
        if (
            maxStalenessBlocks_ == 0
                || windowSize_ == 0
                || windowSize_ > MAX_WINDOW_SIZE
                || maxDeviationBps_ == 0
                || maxDeviationBps_ > MAX_DEVIATION_BPS_CAP
        ) {
            revert InvalidConfig();
        }
        maxStalenessBlocks = maxStalenessBlocks_;
        windowSize = windowSize_;
        maxDeviationBps = maxDeviationBps_;
    }

    // -------------------------------------------------------------------------
    // Staleness-only reads. Stateless w.r.t. the trailing-window rings; safe to
    // call from arbitrary contexts.
    // -------------------------------------------------------------------------

    /// @notice Read the mark price for `asset` from precompile 0x806, checking
    ///         only the staleness watermark. Reverts `Stale()` if the HyperCore
    ///         L1 block lag exceeds `maxStalenessBlocks`.
    function readMark(uint32 asset) external view returns (uint64 markPrice) {
        markPrice = _readPriceWithStaleness(HyperCorePrecompileAddresses.MARK, asset);
    }

    /// @notice Read the oracle price for `asset` from precompile 0x807, checking
    ///         only the staleness watermark.
    function readOracle(uint32 asset) external view returns (uint64 oraclePrice) {
        oraclePrice = _readPriceWithStaleness(HyperCorePrecompileAddresses.ORACLE, asset);
    }

    // -------------------------------------------------------------------------
    // Deviation-bounded reads. Push the current sample into the per-asset ring,
    // then assert |current - twap(window)| / twap ≤ maxDeviationBps after the
    // window is warm.
    // -------------------------------------------------------------------------

    /// @notice Read the mark price for `asset` with both staleness and deviation
    ///         enforcement. The trailing window warms in place — each call
    ///         pushes a sample. The deviation check engages once the window
    ///         is full (`windowSize` samples accumulated); before that, the
    ///         read returns the price unguarded against the trailing TWAP.
    ///         Consumers in critical paths SHOULD seed the window at deploy
    ///         time and check `markSampleCount(asset) == windowSize` before
    ///         trusting the gate.
    function readMarkWithDeviationBound(uint32 asset) external returns (uint64 markPrice) {
        markPrice = _readPriceWithStaleness(HyperCorePrecompileAddresses.MARK, asset);
        _enforceDeviation(_markRing[asset], asset, markPrice);
    }

    /// @notice Read the oracle price for `asset` with both staleness and deviation
    ///         enforcement.
    function readOracleWithDeviationBound(uint32 asset) external returns (uint64 oraclePrice) {
        oraclePrice = _readPriceWithStaleness(HyperCorePrecompileAddresses.ORACLE, asset);
        _enforceDeviation(_oracleRing[asset], asset, oraclePrice);
    }

    // -------------------------------------------------------------------------
    // Read-only accessors — useful for tests + on-chain dashboards. Not part
    // of the guarded surface.
    // -------------------------------------------------------------------------

    /// @notice Current trailing-window TWAP for mark reads on `asset`. Reverts
    ///         `WindowNotWarm` until `windowSize` samples are accumulated.
    function markTwap(uint32 asset) external view returns (uint64) {
        return _twap(_markRing[asset], asset);
    }

    /// @notice Current trailing-window TWAP for oracle reads on `asset`.
    function oracleTwap(uint32 asset) external view returns (uint64) {
        return _twap(_oracleRing[asset], asset);
    }

    /// @notice Number of samples currently in the mark trailing window.
    function markSampleCount(uint32 asset) external view returns (uint8) {
        return _markRing[asset].count;
    }

    /// @notice Number of samples currently in the oracle trailing window.
    function oracleSampleCount(uint32 asset) external view returns (uint8) {
        return _oracleRing[asset].count;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev Read a uint64 price from a HyperCore read precompile + check the
    ///      HyperCore L1 block staleness watermark. The precompile ABI is
    ///      `(uint32 asset) → (uint64 price)`; the L1 block read at 0x808 is
    ///      taken at the point of the call. The staleness check compares the
    ///      EVM-side `block.number` against the HyperCore L1 block — if the lag
    ///      exceeds `maxStalenessBlocks`, the read is stale.
    function _readPriceWithStaleness(address precompile, uint32 asset)
        internal
        view
        returns (uint64 price)
    {
        (bool ok, bytes memory data) = precompile.staticcall(abi.encode(asset));
        if (!ok || data.length < 32) revert PrecompileFailed(precompile, asset);
        price = abi.decode(data, (uint64));

        (bool ok2, bytes memory l1Data) =
            HyperCorePrecompileAddresses.L1_BLOCK_NUMBER.staticcall("");
        if (!ok2 || l1Data.length < 32) {
            revert PrecompileFailed(HyperCorePrecompileAddresses.L1_BLOCK_NUMBER, asset);
        }
        uint64 l1Block = abi.decode(l1Data, (uint64));

        // Staleness model: if EVM block.number exceeds HyperCore L1 block by
        // more than maxStalenessBlocks, treat the read as stale. The relation
        // is "EVM caught up to HyperCore" — when HyperCore halts or skips, EVM
        // keeps producing blocks and this delta grows.
        uint64 evmBlock = uint64(block.number);
        if (evmBlock > l1Block && evmBlock - l1Block > maxStalenessBlocks) {
            revert Stale(l1Block, evmBlock, maxStalenessBlocks);
        }
    }

    /// @dev Push `sample` into the per-asset ring; after the window is warm,
    ///      assert the sample is within `maxDeviationBps` of the trailing TWAP.
    ///
    ///      Order matters: we compute the deviation against the *pre-push* TWAP
    ///      so the current sample is graded against the prior window. This is
    ///      the property D-2 asserts in `invariants/OracleDeviation.t.sol`.
    function _enforceDeviation(Ring storage ring, uint32 /* asset */, uint64 sample) internal {
        uint8 w = windowSize;
        // Pre-push deviation check (only after the window is warm).
        if (ring.count >= w) {
            uint64 twap = ring.sum / w;
            uint256 diff = sample > twap ? sample - twap : twap - sample;
            // bps = diff / twap * 10000 — multiply first to avoid precision loss
            uint256 bps = twap == 0 ? type(uint256).max : (diff * 10_000) / twap;
            if (bps > maxDeviationBps) {
                revert Deviation(sample, twap, uint16(bps > type(uint16).max ? type(uint16).max : bps), maxDeviationBps);
            }
        }

        // Push the new sample after the check; pre-warm callers will see
        // WindowNotWarm on any TWAP read until the buffer fills.
        uint8 head = ring.head;
        if (ring.count == w) {
            // Steady state: subtract the evicted sample, add the new one.
            ring.sum = ring.sum - ring.samples[head] + sample;
        } else {
            // Warming: just add.
            ring.sum = ring.sum + sample;
            ring.count = ring.count + 1;
        }
        ring.samples[head] = sample;
        ring.head = uint8((uint16(head) + 1) % w);
        // No WindowNotWarm revert here — the read path warms the buffer in
        // place. Consumers MUST check `*SampleCount(asset) == windowSize`
        // off-band before trusting the gate (see NatSpec on
        // `readMarkWithDeviationBound` / `readOracleWithDeviationBound`).
    }

    /// @dev Compute the trailing TWAP. Reverts `WindowNotWarm` if the buffer
    ///      hasn't accumulated `windowSize` samples.
    function _twap(Ring storage ring, uint32 asset) internal view returns (uint64) {
        if (ring.count < windowSize) {
            revert WindowNotWarm(asset, ring.count, windowSize);
        }
        return ring.sum / windowSize;
    }
}
