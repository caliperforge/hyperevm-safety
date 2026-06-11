# src/extensions/ — HIP-3.1 activation-gated invariants (parked at v0.1)

Contracts landing in this directory (v0.2) will depend on the
**HIP-3.1** Hyperliquid upgrade (`SetOracleConfig` action + multi-sig
`oracleUpdaters`). At v0.1 the directory carries this README only; the
H-1..H-5 designs land when HIP-3.1 is primary-source confirmed active.

**HIP-3.1 is NOT confirmed active on Hyperliquid mainnet as of the
scaffold commit (2026-06-09).** See `docs/hip3-1-gating.md` (lands per
build-ticket T-12) for the activation gate and the on-chain signal the
extension reads.

## The gate

Each extension contract's constructor will check a published HIP-3.1
activation signal (precompile read against a documented mainnet block,
or a hardcoded chain-id + block bound the maintainer flips when
activation lands). The corresponding properties (planned under
`invariants/` and `formal/certora/`) will be `vm.skip()`-guarded against
the same signal. At v0.1 no extension contracts, properties, or specs
are in-tree.

## CI behavior

- Default: `extensions/` tests are skipped (not failed) in `ci.yml`.
- Nightly: `.github/workflows/hip3-1-activation-probe.yml` checks the
  activation signal and uploads a `probe-status.json` artifact
  recording the result; the probe is the only workflow that runs
  against this directory before activation lands. (A README badge
  linked off the probe is planned with T-15 / M4 once the public flip
  surfaces a stable Actions URL.)

## Design — what lives here after activation

| ID | Invariant | Status |
|---|---|---|
| H-1 | `OracleUpdaterMultisigQuorum` — an `oracleUpdaters` quorum write must carry signatures from ≥ K of N authorized updaters. | Designed; deferred to v0.2 (lands after activation). |
| H-2 | `SetOracleConfigEffectiveBlockMonotone` — `effective_block` on a `SetOracleConfig` action is strictly increasing per market. | Designed; deferred to v0.2. |
| H-3 | `OracleConfigDeviationCap` — `SetOracleConfig` cannot rotate a market's price source by more than `MAX_CONFIG_DEVIATION_BPS` per quorum vote. | Designed; deferred to v0.2. |
| H-4 | `NoOracleConfigDuringLiquidationStorm` — `oracleUpdaters` quorum write is blocked when the per-market liquidation rate-of-change exceeds `LIQUIDATION_STORM_THRESHOLD`. | Designed; deferred to v0.2. |
| H-5 | `OracleUpdatersSetTransitionPath` — `oracleUpdaters` set transitions only through documented `addUpdater` / `removeUpdater` paths. | Designed; deferred to v0.2. |

A Certora CVL spec at `formal/certora/verifyHip3_1Extension.spec` is
planned (T-12, M3) as the formal backstop for this directory. The spec
is NOT yet in-tree; the `formal/certora/` directory is placeholder-only
at v0.1.

See `spec.md` §3.3 and §1.3 for why HIP-3.1-dependent invariants are
deliberately not in v0.1.
