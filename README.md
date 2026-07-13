# hyperevm-safety (v0.1)

[![ci](https://github.com/caliperforge/hyperevm-safety/actions/workflows/ci.yml/badge.svg)](https://github.com/caliperforge/hyperevm-safety/actions/workflows/ci.yml)

**Status.** v0.1 in-tree. All six differentiated invariants implemented in
`src/` with paired property tests in `invariants/`. The JELLY (Mar 2025)
incident reproduction ships as clean + planted twins under
`incidents/01-jelly-2025-03/`. An example lending market lives under
`examples/minimal-lending-market/`. CI is wired in `.github/workflows/`.
Roadmap items not yet in-tree are listed at the end of this README and
marked **future**.

---

## What this library is

> **What this is.** `hyperevm-safety` is an open-source library of invariants and CI-runnable property tests for HyperEVM lending protocols that consume HyperCore oracle reads. All six invariants run as CI-runnable property tests against a clean reference where the property holds under fuzz. Three marker-firing counterparts run on the same CI run: the **D-3 SzDecimalsRoundTrip** and **D-6 ChainlinkAdapterDefeatsStaleness** planted twins (landed M2) and the **JELLY (Mar 2025) mark-price manipulation reproduction** (covering **D-1 OracleStaleness** + **D-2 OracleDeviation** against a minimal lending-market reference). **D-4 PrecompileGasDoS** and **D-5 CoreWriterSolvencyWindow** carry inline broken-reference tests that demonstrate the bug class deterministically, with marker-armed properties whose planted hunks are documented in NatSpec but not yet wired as CI-firing twins. The library is built on `hyperliquid-dev/hyper-evm-lib` (the HyperCore precompile/CoreWriter simulator the ecosystem already uses) and on the CaliperForge `chimera-template-pack` (Foundry + Recon Chimera, Echidna/Medusa stateful fuzz). **What this isn't.** Not an audit. Not a runtime monitor. Not a HIP-3 oracle-update verifier (that layer is owned by HIP3Radar / Hypernative / Chaos Labs Edge / Pyth's HIP-3aaS, and the HyperCore-side guards aren't reachable from EVM). Not a SaaS product. The thesis is reputation → grant upside + consulting referrals with second-tier deployers; the artifact ships as a public good under Apache-2.0.

---

## What this library does NOT claim

- **Not an audit.** A passing CI run on a fork of this library against a
  protocol's contracts does not certify the protocol is safe. The library
  catches the bug classes the invariants encode; the residual surface is
  the protocol's.
- **Not a runtime monitor.** The properties are pre-deploy CI gates. The
  monitoring lane is owned by other actors (see the paragraph above) and
  is explicitly out of scope.
- **Not formal verification of HyperCore.** HyperCore precompile and
  CoreWriter behavior is *simulated* via `hyper-evm-lib` on the EVM side.
  Where the simulator diverges from observed HyperCore behavior, the
  library says so and pins a version (`docs/hyper-evm-lib-notes.md`).
- **Not a HIP-3 oracle-update verifier.** That layer is owned (see
  paragraph above). HIP-3.1 (`SetOracleConfig`, multi-sig
  `oracleUpdaters`) is NOT confirmed active on mainnet as of v0.1;
  HIP-3.1-dependent invariants live as a gated extension module
  (`src/extensions/`) that activates only when the on-chain signal flips.

---

## Differentiated invariants (the product)

The six HyperEVM-specific invariants land at the HyperCore-↔-HyperEVM
boundary. Each row maps a defense pattern in `src/` to a property bundle
in `invariants/` that exercises it. Full prose is in
[`docs/invariants.md`](docs/invariants.md); the in-code NatSpec is the
single source of truth for the precise statements.

| ID | Invariant | `src/` defense pattern | `invariants/` property bundle |
|---|---|---|---|
| **D-1** | OracleStaleness | [`HyperCoreOracleGuard.sol`](src/HyperCoreOracleGuard.sol) | [`OracleStaleness.t.sol`](invariants/OracleStaleness.t.sol) |
| **D-2** | OracleDeviation | [`HyperCoreOracleGuard.sol`](src/HyperCoreOracleGuard.sol) | [`OracleDeviation.t.sol`](invariants/OracleDeviation.t.sol) |
| **D-3** | SzDecimalsScaling | [`SzDecimalsLib.sol`](src/SzDecimalsLib.sol) | [`SzDecimalsRoundTrip.t.sol`](invariants/SzDecimalsRoundTrip.t.sol) |
| **D-4** | PrecompileGasDoS | [`PrecompileGasGuard.sol`](src/PrecompileGasGuard.sol) | [`PrecompileGasDoS.t.sol`](invariants/PrecompileGasDoS.t.sol) |
| **D-5** | CoreWriterSolvencyWindow | [`CoreWriterSolvency.sol`](src/CoreWriterSolvency.sol) | [`CoreWriterSolvencyWindow.t.sol`](invariants/CoreWriterSolvencyWindow.t.sol) |
| **D-6** | ChainlinkAdapterDefeatsStaleness | [`ChainlinkCompatAdapter.sol`](src/ChainlinkCompatAdapter.sol) | [`ChainlinkAdapterDefeats.t.sol`](invariants/ChainlinkAdapterDefeats.t.sol) |

D-6 is the highest-impact differentiated invariant. The broken pattern
(a Chainlink-compat shim that sets `updatedAt = block.timestamp` so
downstream staleness guards always pass) is in production today on
multiple HyperEVM-lending-style integrations.

The precompile-address + ABI surface this library targets is the single
source of truth at [`src/interfaces/IHyperCorePrecompiles.sol`](src/interfaces/IHyperCorePrecompiles.sol)
and [`src/interfaces/IHyperCoreWriter.sol`](src/interfaces/IHyperCoreWriter.sol).

## Incident reproduction — JELLY (Mar 2025)

The library's credibility payload is a paired clean / planted-bug
reconstruction of the JELLY mark-price manipulation event. The bug class
("thin-liquidity HIP-1 perp mark consumed unchecked by a downstream
lender, cascading into unsound liquidations") is reproduced on a
minimal lending-market reference under
[`incidents/01-jelly-2025-03/`](incidents/01-jelly-2025-03/). The case
maps to **D-1**, **D-2**, and **T-3**.

- **Clean leg:** `JellyLendingMarket` consumes the mark through
  `HyperCoreOracleGuard.readMarkWithDeviationBound`. The mark-swing
  attack fires `Deviation()` before any liquidation engages; no
  `INVARIANT VIOLATED` marker on stdout; `forge test` exits 0.
- **Planted leg:** identical source, **one-line** swap in
  `_readGuardedMark` to the unguarded `readMark`. The mark-swing now
  cascades into an unsound liquidation; the test fires
  `INVARIANT VIOLATED LiquidationSoundness` and `forge test` exits
  non-zero.

Primary-source citations (Hyperliquid Foundation statement; CoinDesk;
Halborn; OAK Research) live in the case
[`README.md`](incidents/01-jelly-2025-03/README.md).

## Example lending market

[`examples/minimal-lending-market/`](examples/minimal-lending-market/)
shows how a protocol wires the library in: deposit, borrow, liquidate
against a HyperCore mark via `HyperCoreOracleGuard`. Three property tests
pass against the example.

## CI

`.github/workflows/` runs the library-build, library-properties,
fuzz-echidna, JELLY clean-passes / planted-fires, and twin-diff jobs
that spec.md §5.1 + §5.2 define. The path-existence gates on each job
keep the workflow green at HEAD; gates flip to real-work-green as each
M2/M3 deliverable lands. The composite Foundry setup
(`.github/actions/foundry-setup/`) pins the `hyper-evm-lib` commit
(`6abf28f…`) and a `nightly` Foundry tag; the nightly workflow runs
the matrix.

Every active planted twin is also certified on a fixed 16-seed set as
a standing merge gate (`reachability-multi-seed` job). Every seed must
FAIL the twin with an `INVARIANT VIOLATED` marker; if any seed passes
on any twin, CI turns red. Verdict from the local run on 2026-07-13:

```
reachability certified: yes (all active twins, 16/16 failed as required)
```

Per-twin k / 16 numbers, the seed list, and the merge-gate rule are in
[`docs/reachability.md`](docs/reachability.md).

---

## Repo layout

```
src/                # library — defense patterns + interfaces + HIP-3.1 extensions
invariants/         # Foundry stateful properties for the six D-invariants
incidents/          # JELLY twin pair + scorecards
  01-jelly-2025-03/{clean,planted,scorecard.clean.md,scorecard.planted.md}
examples/           # minimal-lending-market reference
docs/               # invariants.md, hyper-evm-lib-notes.md
.github/            # CI + nightly + HIP-3.1 activation probe
LICENSE NOTICE README.md SECURITY.md CONTRIBUTING.md AI_DISCLOSURE.md spec.md
foundry.toml remappings.txt echidna.yaml medusa.json
```

The HIP-3.1 extension module under `src/extensions/` is parked and
activation-gated; see [`src/extensions/README.md`](src/extensions/README.md).

---

## Roadmap — what's not yet in-tree (M2 / M3)

These items are designed and ticketed but **not yet in-tree**:

- **XYZ100 (trade.xyz, Dec 2025) incident reproduction** under
  `incidents/02-xyz100-2025-12/` — planned with T-10 (M3).
- **Formal specs.** Halmos symbolic specs (`formal/halmos/`) — planned
  with T-8 (M2). Certora CVL specs (`formal/certora/`) — planned with
  T-12 (M3). Neither directory contains a spec at v0.1; both
  directories are placeholder-only.
- **Table-stakes layer.** T-1..T-8 lending-protocol invariants
  (`LendingTableStakes.t.sol`) — planned with M3.
- **HIP-3.1 extension activation.** `src/extensions/` ships parked at
  v0.1; the H-1..H-5 designs land when HIP-3.1 is primary-source
  confirmed active on mainnet (probe lives at
  `.github/workflows/hip3-1-activation-probe.yml`).

---

## License

Apache-2.0. See `LICENSE` and `NOTICE`.

## AI disclosure

Built with AI assistance under the CaliperForge org-level disclosure
register. See `AI_DISCLOSURE.md`.

## Security

Responsible disclosure: see `SECURITY.md`. This library is **not an
audit**; `INVARIANT VIOLATED` markers in the library's own planted twins
are the library working as intended, not vulnerabilities.

## Contributing

See `CONTRIBUTING.md`. Every new invariant ships with clean + planted
twins + scorecards + primary post-mortem citation (for incident-class
cases).

---

*Apache-2.0 licensed. Built with AI assistance. Authored and reviewed
by Michael Moffett, operator at CaliperForge. Full policy at
[caliperforge.com/ai-disclosure](https://caliperforge.com/ai-disclosure).*
