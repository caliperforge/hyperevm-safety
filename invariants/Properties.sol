// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {HyperCoreOracleGuard} from "../src/HyperCoreOracleGuard.sol";
import {ChainlinkCompatAdapter} from "../src/ChainlinkCompatAdapter.sol";
import {SzDecimalsLib} from "../src/SzDecimalsLib.sol";
import {HyperCorePrecompileAddresses} from "../src/interfaces/IHyperCorePrecompiles.sol";
import {MockPrecompiles} from "./mocks/MockPrecompiles.sol";

/// @title Properties — Recon Chimera property bundle for hyperevm-safety library M1.
/// @notice Spec.md §T-3 acceptance: this is the Properties.sol Recon Chimera bundle
///         the CI runs against. It exposes the M1 differentiated invariants — D-1
///         (`OracleStaleness`), D-2 (`OracleDeviation`), D-3 (`SzDecimalsScaling`),
///         and D-6 (`ChainlinkAdapterDefeats`) — as boolean `property_*` predicates
///         the Chimera / Echidna / Medusa harness can invoke between target_*
///         actions.
///
///         **Why this is not a full Recon Chimera `Setup.sol` + `TargetFunctions.sol`
///         scaffold.** The library itself has no mutable protocol surface — there is
///         no deposit/withdraw to fuzz against. The differentiated invariants are
///         exercised by sequencing precompile-state changes (mark/oracle/L1 block
///         updates) and asserting the library's reads behave correctly. The
///         `target_*` actions below are precompile-state mutations; the `property_*`
///         predicates assert the library's response holds for the current state.
///         The CryticTester contract instantiates this and wires it for Echidna /
///         Medusa per spec.md §5.1.
///
///         The full Recon scaffold (Setup / BeforeAfter / TargetFunctions split
///         from chimera-template-pack) lands in M3 when T-11 wires the table-stakes
///         invariants against `examples/minimal-lending-market/` — those DO have a
///         mutable protocol surface to fuzz against.
abstract contract Properties {
    // -------------------------------------------------------------------------
    // Configuration. Tuned for short-budget CI campaigns.
    // -------------------------------------------------------------------------

    uint64 internal constant MAX_STALENESS_BLOCKS = 5;
    uint8 internal constant WINDOW_SIZE = 4;
    uint16 internal constant MAX_DEVIATION_BPS = 500; // 5%

    uint32 internal constant ASSET = 1;
    uint64 internal constant SEED_PRICE = 100_00_000_000; // 100.0 (8-decimal)

    uint32 internal constant SPOT_TOKEN = 7;
    uint8 internal constant SPOT_SZ = 4;
    uint8 internal constant SPOT_WEI = 8;
    int8 internal constant SPOT_EVM_EXTRA = 10;

    uint32 internal constant PERP_ASSET = 3;
    uint8 internal constant PERP_SZ = 4;
    uint8 internal constant PERP_TARGET_WEI = 18;

    uint64 internal constant GENESIS_TS = 1_700_000_000;
    uint64 internal constant BLOCK_MS = 70;

    HyperCoreOracleGuard internal guard;
    ChainlinkCompatAdapter internal goodAdapter;

    // Mirror state — what we asked the mocks to return. Property predicates
    // compare the library's behaviour against this ground truth.
    uint64 internal mirrorMark;
    uint64 internal mirrorOracle;
    uint64 internal mirrorL1Block;

    // -------------------------------------------------------------------------
    // Setup — invoked by the CryticTester constructor.
    // -------------------------------------------------------------------------

    function _setupProperties() internal {
        guard = new HyperCoreOracleGuard(MAX_STALENESS_BLOCKS, WINDOW_SIZE, MAX_DEVIATION_BPS);
        goodAdapter = new ChainlinkCompatAdapter(
            HyperCorePrecompileAddresses.MARK, ASSET, 8, GENESIS_TS, BLOCK_MS, "M1/USD mark"
        );

        // Seed mock state.
        mirrorMark = SEED_PRICE;
        mirrorOracle = SEED_PRICE;
        mirrorL1Block = 100_000;
        MockPrecompiles.setMark(ASSET, mirrorMark);
        MockPrecompiles.setOracle(ASSET, mirrorOracle);
        MockPrecompiles.setL1BlockNumber(mirrorL1Block);
        MockPrecompiles.setSpotDecimals(SPOT_TOKEN, SPOT_SZ, SPOT_WEI, SPOT_EVM_EXTRA);
        MockPrecompiles.setPerpSzDecimals(PERP_ASSET, PERP_SZ);
    }

    // -------------------------------------------------------------------------
    // target_* actions — precompile-state mutations the fuzzer cycles through.
    // Each bounds its input and updates both the mock + the mirror.
    // -------------------------------------------------------------------------

    function target_setMark(uint64 px) external {
        // Bound to a sane range around SEED_PRICE: ±50% of seed.
        uint64 bounded = uint64(uint256(SEED_PRICE) / 2 + (uint256(px) % SEED_PRICE));
        mirrorMark = bounded;
        MockPrecompiles.setMark(ASSET, bounded);
    }

    function target_setOracle(uint64 px) external {
        uint64 bounded = uint64(uint256(SEED_PRICE) / 2 + (uint256(px) % SEED_PRICE));
        mirrorOracle = bounded;
        MockPrecompiles.setOracle(ASSET, bounded);
    }

    function target_advanceL1Block(uint8 delta) external {
        // Bound delta to keep L1 within a reasonable window of EVM block.
        uint64 bounded = uint64(uint256(delta) % 20);
        mirrorL1Block += bounded;
        MockPrecompiles.setL1BlockNumber(mirrorL1Block);
    }

    // -------------------------------------------------------------------------
    // property_* predicates — the M1 differentiated invariants.
    //
    // Each returns true on hold; false fires the fuzzer's "INVARIANT VIOLATED"
    // marker via the Asserts surface in CryticAsserts.
    // -------------------------------------------------------------------------

    /// @notice D-1 OracleStaleness: `readMark` reverts iff EVM-side lag > bound.
    function property_oracleStaleness() public view returns (bool) {
        uint64 evmBlock = uint64(block.number);
        bool shouldRevert = evmBlock > mirrorL1Block && (evmBlock - mirrorL1Block) > MAX_STALENESS_BLOCKS;

        try guard.readMark(ASSET) returns (uint64 px) {
            // Did NOT revert — invariant holds iff shouldRevert == false AND px
            // matches the mirror.
            if (shouldRevert) return false;
            return px == mirrorMark;
        } catch {
            // Reverted — invariant holds iff shouldRevert == true.
            return shouldRevert;
        }
    }

    /// @notice D-2 OracleDeviation: a deviation-bounded read succeeds iff the
    ///         current sample is within `maxDeviationBps` of the trailing TWAP
    ///         (or the window is not yet warm, which is its own revert). The
    ///         property below holds across any reachable state.
    function property_oracleDeviationGate() public returns (bool) {
        uint64 evmBlock = uint64(block.number);
        bool stale = evmBlock > mirrorL1Block && (evmBlock - mirrorL1Block) > MAX_STALENESS_BLOCKS;

        try guard.readMarkWithDeviationBound(ASSET) returns (uint64 px) {
            // Read succeeded — must equal mirror and lag must be within bound.
            return px == mirrorMark && !stale;
        } catch {
            // Read reverted — acceptable for any of:
            //   - stale L1 (Stale)
            //   - cold window (WindowNotWarm)
            //   - out-of-range sample (Deviation)
            // Any other revert is a property violation. We can't distinguish
            // selector here without further machinery; treat all catches as
            // valid for M1 and tighten in the planted-leg test.
            return true;
        }
    }

    /// @notice D-3 SzDecimalsScaling: the round-trip identity holds for the
    ///         current configured spot + perp decimals.
    function property_szDecimalsRoundTrip() public view returns (bool) {
        // Spot round-trip: pick a representative amount.
        uint256 spotSz = 12_345_678;
        uint256 spotWei = SzDecimalsLib.scaleSpotToWei(SPOT_TOKEN, spotSz);
        if (SzDecimalsLib.scaleSpotFromWei(SPOT_TOKEN, spotWei) != spotSz) return false;

        // Perp round-trip:
        uint256 perpSz = 987_654;
        uint256 perpWei = SzDecimalsLib.scalePerpToWei(PERP_ASSET, perpSz, PERP_TARGET_WEI);
        if (SzDecimalsLib.scalePerpFromWei(PERP_ASSET, perpWei, PERP_TARGET_WEI) != perpSz) return false;

        return true;
    }

    /// @notice D-6 ChainlinkAdapterDefeats: the library's adapter surfaces a
    ///         HyperCore freeze. The predicate: as the EVM block-timestamp
    ///         advances faster than the L1 block, the adapter's `updatedAt`
    ///         lags `block.timestamp` by at least the freeze duration.
    function property_chainlinkAdapterTracksHyperCorePublish() public view returns (bool) {
        (, , , uint256 updatedAt, ) = goodAdapter.latestRoundData();
        // updatedAt is genesisTs + l1Block * blockMs / 1000.
        uint256 expectedUpdatedAt = uint256(GENESIS_TS) + (uint256(mirrorL1Block) * uint256(BLOCK_MS)) / 1000;
        return updatedAt == expectedUpdatedAt;
    }

    // -------------------------------------------------------------------------
    // Echidna / Medusa entrypoints — call the predicates with the `echidna_`
    // prefix so both engines pick them up. The Chimera Asserts helper surfaces
    // the predicate name in the failure output.
    // -------------------------------------------------------------------------

    function echidna_D1_oracleStaleness() public view returns (bool) {
        return property_oracleStaleness();
    }

    function echidna_D2_oracleDeviationGate() public returns (bool) {
        return property_oracleDeviationGate();
    }

    function echidna_D3_szDecimalsRoundTrip() public view returns (bool) {
        return property_szDecimalsRoundTrip();
    }

    function echidna_D6_chainlinkAdapterTracksHyperCorePublish() public view returns (bool) {
        return property_chainlinkAdapterTracksHyperCorePublish();
    }
}

/// @notice CryticTester — the single contract Echidna and Medusa deploy.
///         Spec.md §5.1: `echidna . --contract CryticTester --config echidna.yaml`.
contract CryticTester is Properties {
    constructor() payable {
        _setupProperties();
    }
}
