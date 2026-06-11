# Contributing to hyperevm-safety

Thanks for your interest. `hyperevm-safety` is an Apache-2.0 library of
invariants and CI-runnable property tests for HyperEVM lending protocols
that consume HyperCore oracle reads. Contributions that sharpen the
library on real protocol code are welcome.

## How decisions get made

Single human operator-of-record (Michael Moffett, at CaliperForge)
reviews and merges. AI specialists draft and review under final human
pass. No separate maintainer group.

## What we accept

| Contribution shape | Default response | Notes |
|---|---|---|
| Bug reports with a reproducer | Welcome | Open a GitHub issue with `forge` / `hyper-evm-lib` tag / `echidna` / `medusa` versions; the closer to a minimal reproducer, the faster the turn |
| Documentation fixes | Welcome | Typos, broken links, README clarifications: PR directly |
| New invariants (`src/*.sol` + `invariants/*.t.sol`) | Discuss first in an issue | Must ship as **clean + planted twins + scorecards**; see below |
| New incident reproductions under `incidents/` | Discuss first in an issue | Must cite a primary public post-mortem and pass primary-source re-verification |
| Refactors with no behavior change | Discuss first | Land if they meaningfully reduce surface; large rewrites without an issue first will likely be closed |
| Security reports | Do **not** open a public issue | See `SECURITY.md` |

## The PR checklist for a new invariant

Every new invariant ships with all of the following or the PR will be
held:

1. **`src/<InvariantName>.sol`** — the library-side defense pattern (a
   library, helper, or guard contract) that protocols import.
2. **`invariants/<InvariantName>.t.sol`** — the Foundry stateful
   property bundle, wired into `invariants/Properties.sol`.
3. **A clean reference** — either inside `examples/minimal-lending-market/`
   or, for incident-class invariants, under
   `incidents/<n>/clean/`. The property holds 0-violation under fuzz
   against the clean reference.
4. **A planted twin** — either the documented planted-hunk file referenced
   from the property's NatSpec, or, for incident-class invariants, the
   `incidents/<n>/planted/` twin. The diff between clean and planted is
   localized (`diff -r clean planted` ≤ 3 files for incident cases).
5. **`scorecard.clean.md` + `scorecard.planted.md`** for incident cases —
   captured from a verified local run.
6. **Primary post-mortem citation** for incident-class invariants — at
   least one primary source URL in the case `README.md` plus one
   corroborating second source. `research_lead` re-verifies before
   merge.
7. **`docs/invariants.md` entry** — one page: prose statement, the bug
   class it catches, the formal coverage (Halmos / Certora) if any,
   the surface (which precompile / CoreWriter action).
8. **PR description names the bug class.** Not "improves safety" — the
   exact failure mode (e.g. "Chainlink-compat adapter sets
   `updatedAt = block.timestamp`, defeating downstream staleness
   guards").

## Local development

The repo is a Foundry project with Echidna + Medusa hooks (Halmos +
Certora specs land with M2 / M3). The pinned toolchain lives in
`foundry.toml`, `echidna.yaml`, and `medusa.json`; the `hyper-evm-lib`
commit pin lives in `.github/actions/foundry-setup/action.yml`.

Quick build / test:

```sh
forge build
forge test --match-path invariants/*.t.sol
echidna invariants/Properties.sol --config echidna.yaml
medusa fuzz --config medusa.json
# Halmos symbolic specs (planned: T-8 / M2): not yet in-tree at v0.1.
# halmos --match-test 'formal/halmos/*.t.sol'
```

Per-incident:

```sh
cd incidents/01-jelly-2025-03/clean   && forge test   # exits 0, no `INVARIANT VIOLATED` markers
cd incidents/01-jelly-2025-03/planted && forge test   # exits non-zero, `INVARIANT VIOLATED <name>` on stdout
```

## AI-assisted contributions

This library is built with AI assistance; we **disclose and document it
rather than conceal it.** If you used an AI assistant to draft code,
tests, or prose in your PR, please say so in the PR description. A
one-line note is enough. The bar is the same for AI-assisted and
hand-authored work: the operator-of-record signs everything, and the
project's reputation rests on what the code actually does. See
`AI_DISCLOSURE.md`.

## Commit and PR style

- Imperative subject line, ≤ 72 chars (`add OracleStaleness property`),
  not `Added` and not `adding`.
- A body paragraph when the why is non-obvious.
- Reference the issue number (`Fixes #N`) when applicable.
- One logical change per PR. If you find an unrelated cleanup while
  you're in there, file a follow-up PR.

## Reporting security issues

Do not file a public issue or PR for a security report. Use the
private path in `SECURITY.md`.

---

*Apache-2.0 licensed. Built with AI assistance. Authored and reviewed
by Michael Moffett, operator at CaliperForge. Full policy at
[caliperforge.com/ai-disclosure](https://caliperforge.com/ai-disclosure).*
