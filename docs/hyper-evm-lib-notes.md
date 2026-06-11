# hyper-evm-lib notes (T-3 landing — M1 baseline)

Source: the maintainers' T-2 purrkit-vs-`hyper-evm-lib` evaluation
(2026-06-09). Outcome: default to `hyper-evm-lib`; ≤3-file purrkit
cherry-pick allowed only on a named precompile semantic;
vendor-wholesale rejected (the Jito lesson on unbounded upstream-drift
liability).

## Pin

`hyperliquid-dev/hyper-evm-lib` is pinned to commit
`6abf28fca081f56c43b0f94af23699f1b43d2329` (HEAD as of 2026-04-24, when the T-2
evaluation was performed).

The pin lives in `.github/actions/foundry-setup/action.yml` as the
`hyper-evm-lib-version` default. The library code in `src/` does NOT import
hyper-evm-lib directly — it consumes the precompile addresses + ABI surface
(captured in `src/interfaces/IHyperCorePrecompiles.sol` and
`src/interfaces/IHyperCoreWriter.sol`). The pin governs the simulator-side
behaviour that downstream consumers (and our M2+ tests) depend on.

Bumping the pin requires:

1. Re-running the T-2 decision matrix against the new HEAD.
2. Confirming the precompile ABI surface in `IHyperCorePrecompiles.sol` still
   matches.
3. Updating this file with the new commit + the date of the re-evaluation.

The nightly CI matrix (`.github/workflows/nightly.yml`) runs a `latest` leg in
parallel with the pinned leg; a divergence surfaces upstream drift the morning
after it lands.

## Why M1 invariant tests use Foundry mocks rather than `CoreSimulator`

The M1 property tests under `invariants/*.t.sol` use `vm.mockCall` (via the
`MockPrecompiles` helper at `invariants/mocks/MockPrecompiles.sol`) to drive
the precompile reads, rather than instantiating hyper-evm-lib's `CoreSimulator`.

Rationale:

- The M1 properties exercise reads on 0x806/0x807/0x808/0x809/0x80B. None of
  the M1 invariants require the settlement-side modeling of `CoreWriterSim` or
  `CoreSimulator`'s deferred-order queue.
- Cheatcode mocks are deterministic, byte-stable across foundry releases, and
  carry zero upstream-drift surface.
- Downstream consumers wiring this library into their own Foundry suite can
  reuse these mocks or swap them for `CoreSimulator.setSpotPx` / equivalent —
  both surfaces hit the same precompile addresses; only the test-side control
  plane differs.

M2 (T-7: D-4 and D-5) takes on the settlement-side simulator dependency. The
caveats documented below describe where it is + isn't faithful.

## D-4 (PrecompileGasDoS) — M2 LANDED 2026-06-10 (T-7)

The all-gas-consumed semantic of a failed HyperCore precompile call is
**unmodeled in both hyper-evm-lib and purrkit**. Both libraries simulate
precompile failures via Foundry `vm.etch` + Solidity revert — the EVM caller
does NOT burn the forwarded gas budget the way a real HyperCore precompile
failure does.

This is an EVM-vs-HyperCore boundary neither library can fix without a custom
EVM build.

Implementation in M2 (T-7):

- `src/PrecompileGasGuard.sol` ships `callOrRevert(precompile, data)` and a
  `callOrRevertWithGas(..., gasBound)` variant. Both surface BOTH
  `success=false` (typed `PrecompileCallFailed`) AND `success=true` with
  empty return data (typed `PrecompileEmptyReturn`) — the simulator-visible
  shapes of the all-gas-consumed failure surface. No silent default-return.
- `invariants/PrecompileGasDoS.t.sol` drives a stateful sequence with one
  failed precompile call against a `GuardedConsumer` (uses `callOrRevert`)
  and a reference `BrokenConsumer` (encodes the soft-fail bug class
  inline). The property models the failure at the **call-result level**
  (success=false / empty return data), per the EVM-vs-HyperCore boundary
  noted above — explicitly NOT at the gas-consumption level.
- Single-line planted hunk in `callOrRevert` (return `abi.encode(uint256(0))`
  on failure instead of reverting) reproduces `INVARIANT VIOLATED
  PrecompileGasDoS` on stdout + as the test revert reason; clean leg passes
  silently.
- A Halmos symbolic spec (planned: `formal/halmos/PrecompileGasDoS.t.sol`,
  T-8 / M2) will be the formal backstop for the EVM-side state-mutation
  guarantee. Not yet in-tree at v0.1.
- The README's "what this library does NOT claim" section retains the
  HyperCore-fidelity caveat that covers this.

## D-5 (CoreWriterSolvencyWindow) — M2 LANDED 2026-06-10 (T-7)

hyper-evm-lib's CoreWriter-side simulation models the dual-block window
**coarse-grain**: `nextBlock()` advances the chain, and precompiles return data
"from the start of the block" (per the lib's README). There is no per-action
`l1Block` ledger native to the lib.

purrkit's `CoreSimulatorLib` does carry a finer-grain deferred-order queue
with per-request `l1Block` and explicit settlement (`applyBridgeActionResult`,
`applyPerpBridgeActionResult`, `consumeAllAndReturn`). The T-2 evaluation
showed this would be the only place where a purrkit cherry-pick could add
fidelity — and the cherry-pick was rejected on three grounds (file-count cap,
path-collision becoming wholesale-replacement, NUM_PRECOMPILES regression
17 vs 20).

Implementation in M2 (T-7):

- `src/CoreWriterSolvency.sol` ships a `Ledger` storage type plus `submit`,
  `markSettled`, `unsettledCreditsOf`, `getAction`, and the headline
  `assertSettlementWindowInvariant(L, user, evmReportedSolvency)`. The
  library is unit-agnostic (consumer chooses raw-collateral vs
  solvency-capacity units) and the ledger is owned by the consumer
  contract via storage pointer — same convention as OZ
  `EnumerableSet.AddressSet`.
- `invariants/CoreWriterSolvencyWindow.t.sol` keeps the per-action `l1Block`
  ledger in the test scaffold (in-library `Ledger`); EVM-block advancement
  uses `vm.roll`. The property asserts no EVM-side borrow against
  pre-credited unsettled CoreWriter state lands without first surviving the
  pessimistic-uncredit check.
- Both a `GuardedMarket` (calls `assertSettlementWindowInvariant`) and a
  reference `BrokenMarket` (encodes the pre-credit bug class without the
  guard) live inside the test file — same convention as
  `BrokenChainlinkAdapter` / `BrokenConsumer` from M1 + T-7's D-4.
- Single-line planted hunk in `assertSettlementWindowInvariant` (no-op
  instead of conditional revert) reproduces `INVARIANT VIOLATED
  CoreWriterSolvencyWindow` on stdout + as the test revert reason; clean
  leg passes silently across 1000 fuzz runs of the stateful sequence
  property.
- A Certora CVL spec (planned: `formal/certora/CoreWriterSolvency.spec`,
  T-12 / M3) will be the formal backstop; Halmos fallback per CEO call
  C1. Not yet in-tree at v0.1.

### `pendingCredits` naming note

The library exposes the per-user unsettled-credits accessor as
`unsettledCreditsOf(L, user)` rather than `pendingCredits(L, user)`. The
`Ledger` struct's internal mapping is named `pendingCredits` — Solidity's
argument-dependent-lookup makes the `using ... for Ledger` clause flag a
collision between the function and the mapping selector. Renaming the
accessor sidesteps the collision without altering the public storage shape.

## Reference: precompile addresses + ABIs

Captured in `src/interfaces/IHyperCorePrecompiles.sol` (read precompiles) and
`src/interfaces/IHyperCoreWriter.sol` (CoreWriter sink). Canonical docs URL:
<https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore>.

The addresses + ABI shapes are the contract this library presents to consuming
protocols. The pinned hyper-evm-lib simulator is the test-side complement;
both sides MUST agree at this boundary.
