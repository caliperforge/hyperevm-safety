# scorecard.clean — incidents/01-jelly-2025-03 / clean leg

Captured 2026-06-10 from a local `forge clean && forge test -vv` against the
clean twin. The CI job `incident-01-jelly-clean-passes` runs the same command.

## Verdict

**PASS** — the deviation-bounded mark read in `_readGuardedMark` blocks the
JELLY mark-swing attack before any liquidation engages. No
`INVARIANT VIOLATED` marker reaches stdout. `forge test` exits 0.

## Result table

| Field | Value |
|---|---|
| Twin leg | `clean/` |
| Mark read | `HyperCoreOracleGuard.readMarkWithDeviationBound` |
| Deviation bound | 500 bps (5%) |
| TWAP window | 4 samples (warmed at honest seed price during `setUp`) |
| Attack scenario | swing mark from $100.00 → $20.00 (80% delta) |
| Tests run | 2 |
| Tests passed | 2 |
| Tests failed | 0 |
| `INVARIANT VIOLATED` markers on stdout | 0 |
| `forge test` exit code | 0 |
| Foundry profile | `default` (solc 0.8.28, optimizer 200) |

## Captured output

```
Ran 2 tests for tests/JellyMarkSwing.t.sol:JellyMarkSwingTest
[PASS] test_jellyMarkSwing_LiquidationSoundness_holds() (gas: 31064)
[PASS] test_sanity_borrowerSolventAtHonestPrice() (gas: 16973)
Suite result: ok. 2 passed; 0 failed; 0 skipped
```

## Reproduction

```sh
cd incidents/01-jelly-2025-03/clean
forge clean && forge test -vv
```

Expected: identical PASS verdict on any commit at or after T-3 (`src/`
landed) + T-5 (this twin landed). The pinned `hyper-evm-lib` tag
(`6abf28fca081f56c43b0f94af23699f1b43d2329`, per
`docs/hyper-evm-lib-notes.md`) and the Foundry composite action in
`.github/actions/foundry-setup/` keep the toolchain deterministic.
