# scorecard.planted — incidents/01-jelly-2025-03 / planted leg

Captured 2026-06-10 from a local `forge clean && forge test -vv` against the
planted twin. The CI job `incident-01-jelly-planted-fires` runs the same
command and gates on (a) `INVARIANT VIOLATED` marker on stdout AND (b)
non-zero exit code.

## Verdict

**FIRES** (as intended) — the planted hunk that swaps
`readMarkWithDeviationBound` for the staleness-only `readMark` removes the
deviation gate. The manipulated mark passes through, the liquidation
succeeds against a borrower who was actually solvent at the honest price,
and the test fires `INVARIANT VIOLATED LiquidationSoundness`.

## Result table

| Field | Value |
|---|---|
| Twin leg | `planted/` |
| Mark read | `HyperCoreOracleGuard.readMark` (deviation gate **removed**) |
| Localized hunk | `src/JellyLendingMarket.sol::_readGuardedMark` — one line swapped |
| Attack scenario | swing mark from $100.00 → $20.00 (80% delta) |
| Tests run | 2 |
| Tests passed | 1 (`test_sanity_borrowerSolventAtHonestPrice`) |
| Tests failed | 1 (`test_jellyMarkSwing_LiquidationSoundness_holds`) |
| `INVARIANT VIOLATED` markers on stdout | 3 (one each from `console2.log`, the duplicated diagnostic log line preamble, and the revert reason in the test summary) |
| `forge test` exit code | 1 (non-zero) |
| Borrower honest health (bps) at attack time | 20_000 (200%) |
| Liquidation threshold (bps) | 8_000 (80%) |
| Manipulated mark (8-decimal) | 2_000_000_000 ($20.00) |
| Honest mark (8-decimal) | 10_000_000_000 ($100.00) |
| Foundry profile | `default` (solc 0.8.28, optimizer 200) |

## Captured output

```
[FAIL: INVARIANT VIOLATED LiquidationSoundness] test_jellyMarkSwing_LiquidationSoundness_holds() (gas: 73716)
Logs:
  INVARIANT VIOLATED LiquidationSoundness
    honest_health_bps = 20000
    liquidation_threshold_bps = 8000
    manipulated_mark = 2000000000
    honest_mark = 10000000000

[PASS] test_sanity_borrowerSolventAtHonestPrice() (gas: 16973)
Suite result: FAILED. 1 passed; 1 failed; 0 skipped
```

## Compile-time note

The planted leg's `_readGuardedMark` body calls only the view-mode `readMark`
plus immutable + view ops. Solc emits informational warning 2018 ("Function
state mutability can be restricted to view"). The warning is left in place
deliberately — adding `view` to the function signature would expand the twin
diff beyond the single-line localized hunk, defeating the same-source-twin
discipline (spec §T-5 acceptance). The warning is non-blocking; both `forge
build` and `forge test` operate as intended.

## Reproduction

```sh
cd incidents/01-jelly-2025-03/planted
forge clean && forge test -vv
```

Expected: identical FIRES verdict on any commit at or after T-3 + T-5.
Pinned toolchain per `docs/hyper-evm-lib-notes.md`.
