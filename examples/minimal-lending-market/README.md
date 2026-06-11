# minimal-lending-market

A canonical reference for a HyperEVM lending market that consumes a HyperCore
mark price safely, using the [`hyperevm-safety`](../../) library.

> **Status.** Spec §T-4 — landed at Milestone 1. Smoke test exercises the full
> deposit → price update → withdraw round-trip and the staleness gate
> integration. ~250 lines of Solidity.

---

## What this example shows

A share-accounted, single-asset lending vault that:

1. **Reads a HyperCore mark price** for collateral valuation, through the
   `ChainlinkCompatAdapter` (the `AggregatorV3Interface` shape downstream
   protocols already know how to integrate).
2. **Enforces the staleness gate** via `HyperCoreOracleGuard.readMark(asset)` on
   every state-mutating function — `Stale()` reverts before any share math
   touches storage.
3. **Backstops with a seconds-bounded adapter age check** against the adapter's
   `updatedAt` field. Because `ChainlinkCompatAdapter` returns
   `updatedAt = HyperCore_publish_block_timestamp` (NOT `block.timestamp`),
   this seconds-level gate actually fires when HyperCore halts — the broken
   adapter pattern this library exists to flag silently defeats it.

The market itself is intentionally tiny — one asset, pro-rata shares, no
borrowing path. The point is to show the **library integration wiring** in
isolation; production lending protocols add liquidation engines, LTV checks,
interest accrual on top of this same shape.

---

## Run it

```sh
cd examples/minimal-lending-market
forge build
forge test
```

Expected output: clean compile, 3/3 tests pass.

```
[PASS] test_smoke_deposit_priceUpdate_withdraw_roundTrip()
[PASS] test_smoke_staleHyperCoreL1Block_revertsDeposit()
[PASS] test_smoke_adapterUpdatedAtTooOld_revertsDeposit()
```

---

## File map

| Path | Purpose |
|---|---|
| `src/MinimalLendingMarket.sol` | The vault. ~200 lines including NatSpec. |
| `tests/Smoke.t.sol` | Deposit → price update → withdraw round-trip + two staleness-gate negative tests. |
| `foundry.toml` | Standalone sub-project config. Library deps shared with the parent at `../../lib/` (forge-std, hyper-evm-lib, chimera). |
| `remappings.txt` | Mirrors `foundry.toml` so editors/static-analysis pick up the same paths. |

---

## Wiring the library's invariants in (if you fork this example)

This example demonstrates the **happy path**: deposit, price update, withdraw.
Production confidence comes from the library's [property tests](../../invariants/)
firing against the same surface.

When forking this example as a starter, **wire in the library's invariants
against your protocol's deposit/withdraw flow**:

- [`invariants/OracleStaleness.t.sol`](../../invariants/OracleStaleness.t.sol)
  — D-1 *OracleStaleness*. Asserts the guarded read reverts `Stale()` iff
  HyperCore L1 block lag exceeds the bound. Re-target the test's `guard`
  reference at your protocol's deployed guard instance.
- [`invariants/OracleDeviation.t.sol`](../../invariants/OracleDeviation.t.sol)
  — D-2 *OracleDeviation*. Asserts the TWAP-bounded read rejects
  manipulated single-block marks. Re-target similarly.
- [`invariants/SzDecimalsRoundTrip.t.sol`](../../invariants/SzDecimalsRoundTrip.t.sol)
  — D-3 *SzDecimalsScaling*. Required reading if your protocol scales
  between HyperCore `szDecimals` and EVM `wei`. The minimal market in this
  example doesn't (it uses the 8-decimal answer from the adapter directly),
  but most real lending protocols do.
- [`invariants/ChainlinkAdapterDefeats.t.sol`](../../invariants/ChainlinkAdapterDefeats.t.sol)
  — D-6 *ChainlinkAdapterDefeats*. The highest-impact invariant per the spec:
  asserts your adapter actually surfaces a HyperCore freeze through the
  `AggregatorV3Interface.updatedAt` field. The example wires
  `ChainlinkCompatAdapter` (the correct pattern); the property catches the
  broken pattern in any deployed adapter you swap in.
- [`invariants/Properties.sol`](../../invariants/Properties.sol)
  — The Recon Chimera bundle. Compose into your own `Properties.sol` if you
  run Echidna / Medusa stateful fuzz.

Pre-deploy CI gate (the library's own
[`ci.yml`](../../.github/workflows/ci.yml) is a reference): run all four
invariant suites against your test harness in a `forge test --match-path
'invariants/*.t.sol'` job and assert zero violations.

---

## What this example is NOT

- **Not production code.** No access control, no pause path, no liquidation
  engine, no interest accrual. The market is a teaching artifact.
- **Not an audit.** A passing `forge test` here does not certify any forked
  variant — see the library's [SECURITY.md](../../SECURITY.md).
- **Not a runtime monitor.** The staleness gates are pre-deploy CI gates +
  on-chain reverts; they do not page anyone when they fire. Runtime
  monitoring is owned by a different lane (HIP3Radar / Hypernative /
  Chaos Labs Edge / Pyth HIP-3aaS — see the library README).

---

## License

Apache-2.0, same as the parent library.
