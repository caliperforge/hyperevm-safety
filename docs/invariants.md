# Invariants — hyperevm-safety v0.1

One page per invariant: prose statement, bug class it catches, surface
(precompile / CoreWriter action it targets), defense pattern in `src/`,
and the property bundle in `invariants/` that exercises it. The in-code
NatSpec is the single source of truth for the precise predicate; this
page is the human-readable index.

The taxonomy mirrors `spec.md` §3.1 (differentiated layer, the product)
and §3.2 (table-stakes layer, planned for M3).

---

## Differentiated layer (HyperEVM-specific — in-tree at v0.1)

| ID | Invariant | Bug class it catches | Surface | Defense pattern (`src/`) | Property (`invariants/`) |
|---|---|---|---|---|---|
| **D-1** | OracleStaleness | Stale-price lending: a protocol consumes a HyperCore mark/oracle precompile read unchecked; HyperCore halts or skips a publish; the protocol prices off a frozen feed. | `0x806` (mark), `0x807` (oracle), with `0x808` (L1 block number) as the watermark. | `HyperCoreOracleGuard.read{Mark,Oracle}` checks the EVM `block.number` vs the published HyperCore L1 block; reverts `Stale()` when the lag exceeds `maxStalenessBlocks`. | `OracleStaleness.t.sol` |
| **D-2** | OracleDeviation | Single-block manipulated mark feeding a liquidation engine, or cross-precompile inconsistency (`0x806` vs `0x807`) consumed without sanity check. | `0x806`, `0x807`. | `HyperCoreOracleGuard.read*WithDeviationBound` pushes each sample into a trailing-window ring; reverts `Deviation()` when the current read exceeds `maxDeviationBps` of the trailing TWAP. | `OracleDeviation.t.sol` |
| **D-3** | SzDecimalsScaling | szDecimals miscount in token-amount math: shares mint at wrong scale, liquidation thresholds compare at wrong scale, fees accrue at wrong scale. Spot-vs-perp `szDecimals` differ. | `0x80B` (spot info), perp `szDecimals` constants. | `SzDecimalsLib.scale{To,From}Wei` round-trips on the asset-resolved `szDecimals`; the property asserts exact round-trip. | `SzDecimalsRoundTrip.t.sol` |
| **D-4** | PrecompileGasDoS | "Soft" failure paths in protocol code that consume an all-gas precompile error as `success=false` and proceed (e.g., default to last-known price). | Any precompile in 0x800–0x80B. | `PrecompileGasGuard.callOrRevert{,WithGas}` surfaces BOTH `success=false` (typed `PrecompileCallFailed`) and `success=true` with empty return data (typed `PrecompileEmptyReturn`) as reverts. | `PrecompileGasDoS.t.sol` |
| **D-5** | CoreWriterSolvencyWindow | Lending protocol counts a CoreWriter-submitted action as "settled" at submission block N; a borrower re-borrows against the assumed-settled state; HyperCore later rejects/delays settlement; the assumed-settled state inflated collateralization. | CoreWriter action surface (perp orders, spot transfers). | `CoreWriterSolvency` ledger + `assertSettlementWindowInvariant` checks the pessimistic-uncredit solvency view at every borrow before the action settles. | `CoreWriterSolvencyWindow.t.sol` |
| **D-6** | ChainlinkAdapterDefeatsStaleness | Chainlink-compat `AggregatorV3Interface` shim that sets `updatedAt = block.timestamp` rather than the HyperCore publish block timestamp. Downstream Chainlink-style staleness guards then always pass, defeating the staleness defense at the adapter layer. | Any contract exposing an `AggregatorV3Interface` wrapper around `0x806` / `0x807`. | `ChainlinkCompatAdapter` is the correct pattern — `updatedAt` reflects the HyperCore publish block. The property exercises the broken pattern (a `BrokenChainlinkAdapter` reference in the test) against the staleness guard. | `ChainlinkAdapterDefeats.t.sol` |

D-6 is the highest-impact differentiated invariant. The broken pattern
is in production today on multiple HyperEVM-lending-style integrations;
generic EVM auditors approve it because the Chainlink-on-Ethereum
pattern looks identical to the eye.

---

## Table-stakes layer (classic lending invariants — planned, M3)

These eight invariants exist so a protocol can wire the whole suite in
and get coverage at the lending-protocol layer too. None are
differentiated; they exist for completeness. **Planned for M3 (ticket
T-11); not in-tree at v0.1.** The property file
(`invariants/LendingTableStakes.t.sol`) lands with M3.

| ID | Invariant | One-line statement |
|---|---|---|
| **T-1** | Solvency | `sum(user balances) == contract-side accounting` at every step. |
| **T-2** | ShareMonotonic | Under no-rebase, no-loss conditions, `pricePerShare` is non-decreasing. |
| **T-3** | LiquidationSoundness | A user with `health_factor < 1` after price update is liquidatable; a user with `health_factor ≥ 1` is not. |
| **T-4** | NoZeroSharesMint | Empty-market or post-truncation, no path mints zero shares for a non-zero deposit (zkLend-class). |
| **T-5** | NoNegativeCollateral | Per-asset collateral balance is bounded below by zero across every transition. |
| **T-6** | RoundTripConservation | For every user `u`, `withdrawn(u) ≤ deposited(u) + accrued_yield(u)` at every step. |
| **T-7** | InterestAccrualMonotone | Interest accumulator is non-decreasing across blocks (zkLend-class accumulator inflation guard). |
| **T-8** | AccessControl | Privileged functions revert when called by non-`AUTHORIZED_SET`. |

T-3 is already exercised in-tree by the JELLY incident's planted leg
(`incidents/01-jelly-2025-03/planted/`), which fires
`INVARIANT VIOLATED LiquidationSoundness`. The full T-1..T-8 bundle
under `invariants/LendingTableStakes.t.sol` is M3 work.

---

## HIP-3.1 extension layer (parked, activation-gated)

`src/extensions/` carries five HIP-3.1-dependent invariants (H-1..H-5)
designed at spec level. None are implemented at v0.1; HIP-3.1
(`SetOracleConfig`, multi-sig `oracleUpdaters`) is not confirmed active
on Hyperliquid mainnet. The directory ships with an activation-probe
workflow (`.github/workflows/hip3-1-activation-probe.yml`); the H-table
lives in `src/extensions/README.md`.

---

## Formal backstops

Symbolic / formal specs are **planned, not yet in-tree at v0.1**:

- **Halmos** symbolic specs under `formal/halmos/` — planned (T-8 / M2)
  for D-1, D-3, D-4.
- **Certora CVL** specs under `formal/certora/` — planned (T-12 / M3)
  for D-5 (`CoreWriterSolvency.spec`) and the HIP-3.1 extension
  (`verifyHip3_1Extension.spec`).

Both directories at v0.1 contain only `.gitkeep`. See
`docs/hyper-evm-lib-notes.md` for the Halmos / Certora framing notes
the implementation will inherit.

---

## CI mapping

Per `spec.md` §5.1 and §5.2, every in-tree invariant has at least:

- A clean leg under `invariants/*.t.sol` that passes silently (no
  `INVARIANT VIOLATED` marker on stdout).
- A documented planted hunk that fires
  `INVARIANT VIOLATED <name>` on stdout and exits non-zero.

For incident-class invariants (currently: JELLY → D-1, D-2, T-3), the
twin discipline ships as a separate clean/planted directory pair under
`incidents/`. The CI jobs (`.github/workflows/ci.yml`) assert each leg's
behavior independently.
