# incidents/01-jelly-2025-03 — JELLY mark-price manipulation (Mar 2025)

> **Status.** Spec §T-5 — landed at Milestone 1. Clean + planted twins green
> locally. Primary-source URL re-verification is T-9's M2 ticket
> (`research_lead`) per spec §4.1.

## Bug class

Thin-liquidity HIP-1 / perp **mark price manipulated** by an attacker
self-trading (or coordinated thin-book activity) → cascading liquidations on
any downstream protocol that consumed precompile `0x806` (mark) **without a
TWAP-bounded deviation gate**. The HyperCore mark itself is correct under the
exchange's own rules — the mark *was* what the manipulated order book said it
was — but a lending protocol consuming the mark verbatim as the basis for
liquidation decisions inherits the manipulation as protocol-level loss.

In the actual on-chain event (Hyperliquid, Mar 2025), the principal loss
landed on Hyperliquid's HLP (HyperLiquidity Provider) backstop after it
auto-absorbed a large short JELLY position. This library's reproduction
abstracts the **bug class** ("manipulable mark consumed unchecked") onto a
generic lending-market reference (spec §4 framing — the incident is a
*minimal reconstruction of the bug class*, NOT a fork of any affected
protocol). The forward-projection the spec makes is: if a HyperEVM lending
protocol read `0x806` without a deviation bound, the same mark swing would
cascade into unsound liquidations.

That forward-projection is the property this twin pair exercises.

## What the twins assert

- **`clean/`** — `JellyLendingMarket` consumes the mark through
  `HyperCoreOracleGuard.readMarkWithDeviationBound` with a 4-sample TWAP
  window and a 500 bps (5%) deviation bound. Test scenario: warm the
  window at the honest mark, then swing the mark to a manipulated value
  60% outside the band, then attempt to liquidate a position that is
  honestly solvent. The guard fires `Deviation()` before any liquidation
  state engages — no `INVARIANT VIOLATED` marker on stdout, `forge test`
  exits 0.

- **`planted/`** — same source, single localized hunk that swaps
  `readMarkWithDeviationBound` for the staleness-only `readMark`
  (deviation gate removed; spec §4.1 "raw `0x806` read" — interpreted as
  *deviation-unguarded* read, isolating the D-2 surface). Same test
  scenario, same fuzz seed, same fixtures. Without the gate, the
  manipulated mark passes through; the liquidation engages on a
  manipulated price against a borrower who was actually solvent at the
  honest price; the test fires `INVARIANT VIOLATED LiquidationSoundness`
  on stdout and `forge test` exits non-zero.

The diff between clean and planted is **one line** in
`src/JellyLendingMarket.sol::_readGuardedMark`.

## Maps to invariants

| Invariant | Where |
|---|---|
| **D-2 OracleDeviation** | the underlying mechanism the planted hunk disables |
| **T-3 LiquidationSoundness** | the headline assertion the planted leg violates |
| **D-1 OracleStaleness** | wired in both legs (L1-block staleness check stays even in planted leg, since `readMark` still enforces it — the swap deliberately isolates D-2, not D-1) |

This is the same `D-{1,2}` + `T-3` mapping spec §4.1 calls.

## Run it

```sh
# Clean leg — exits 0, no INVARIANT VIOLATED marker.
cd incidents/01-jelly-2025-03/clean && forge test -vv

# Planted leg — exits non-zero with INVARIANT VIOLATED LiquidationSoundness.
cd incidents/01-jelly-2025-03/planted && forge test -vv
```

These are the same commands the CI jobs
`incident-01-jelly-{clean-passes,planted-fires,twin-diff}`
(`.github/workflows/ci.yml`) run.

Verify the diff bound:

```sh
cd incidents/01-jelly-2025-03 && diff -r clean/src planted/src
# Expected: 1 differing file (JellyLendingMarket.sol), single-line hunk.
```

## File map

| Path | Purpose |
|---|---|
| `clean/src/JellyLendingMarket.sol` | Vault + borrow + liquidate; deviation-bounded mark read. |
| `clean/tests/JellyMarkSwing.t.sol` | The mark-swing attack scenario asserting LiquidationSoundness. |
| `clean/foundry.toml`, `clean/remappings.txt` | Standalone sub-project config. |
| `planted/src/JellyLendingMarket.sol` | Same source, one-line `_readGuardedMark` swap (deviation gate removed). |
| `planted/tests/JellyMarkSwing.t.sol` | Identical to clean. |
| `planted/foundry.toml`, `planted/remappings.txt` | Identical to clean. |
| `scorecard.clean.md`, `scorecard.planted.md` | Captured from a verified-2026-06-10 local run. |

## Primary sources

The bug-class characterization "thin-liquidity perp mark price
manipulation feeding a downstream consumer" is publicly documented by
the following primary and secondary sources, re-verified 2026-06-10.

- **Hyperliquid Foundation, official X statement, 2025-03-26** —
  primary. https://x.com/HyperliquidX/status/1904923137684496784
- **CoinDesk, "HyperLiquid Delists JELLY After Vault Squeezed in $13M
  Tussle," 2025-03-26** —
  https://www.coindesk.com/markets/2025/03/26/hyperliquid-delists-jellyjelly-after-vault-squeezed-in-usd13m-tussle
- **Halborn, "Explained: The Hyperliquid Hack (March 2025)"** —
  technical post-mortem.
  https://www.halborn.com/blog/post/explained-the-hyperliquid-hack-march-2025
- **OAK Research, "Hyperliquid and the JELLY attack: Context,
  vulnerability and team solution"** — technical post-mortem.
  https://oakresearch.io/en/analyses/investigations/hyperliquid-jelly-attack-context-vulnerability-team-solution

**Loss figure:** HLP unrealized peaked at ~$12M–$13.5M before the
validator-vote-driven settlement made HLP whole at the attacker's
short-leg price. The ~$13M framing in this README and in spec §4.1
is consistent with the primary record.

**Mechanism (per primary sources):** an attacker opened a short on
JELLY perp on Hyperliquid (paired with self-funded long legs),
coordinated a spot-market pump of JELLY across Solana DEXs (and a
subsequent Binance / OKX listing), then withdrew margin to force
self-liquidation of the short. Thin perp order-book depth prevented
the liquidator vault from unwinding, transferring the inherited short
into the HLP backstop, which held it against a spiking spot price.
The mark feeding HyperEVM-side consumers was driven by the manipulated
spot index, not by perp-to-perp self-trading.

**What this case asserts as a forward-projection:** if a HyperEVM
lending protocol consumed `0x806` (mark) without a deviation bound or
TWAP floor, the same mark swing would cascade into unsound liquidations
on the lender. The principal real-world loss landed on HLP, not on
third-party lenders; the library reproduces the bug class onto a
generic lending-market reference (the `clean/` and `planted/` twins
above) per spec §4.1.

**Kill-register status (T-9 re-verification 2026-06-10):** kill
criterion §7.1.4 **NOT TRIGGERED**. Bug class and dollar figure
cross-confirmed by ≥3 primary/secondary sources. Spec §4.1 prose
contains one colloquial gloss ("self-traded JELLY perps to swing the
mark") that the T-9 memo flags for optional precision refinement; the
actual mechanism was margin-withdrawal-forced self-liquidation +
cross-venue spot pump rather than literal self-trading. This precision
issue does NOT invalidate the bug class or require this twin pair to
be re-scoped — the forward-projection above remains the load-bearing
property the twins exercise.

## What this case is NOT

- **Not a fork of any affected protocol's source.** The lending market
  here is the generic `MinimalLendingMarket`-style reference, extended
  with a borrow/liquidate surface. The bug class is reproduced on this
  reference, not on the production code of any specific protocol.
- **Not a full incident chronology.** This is a property-test twin —
  the credibility payload is "the library catches this bug class," not
  "this is how Hyperliquid handled the event in real time."
- **Not an audit.** See the parent library's `SECURITY.md`.

## License

Apache-2.0, same as the parent library.
