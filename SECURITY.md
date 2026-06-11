# Security Policy

`hyperevm-safety` is a library of pre-deploy CI invariants and property
tests for HyperEVM lending protocols. We take security reports against
the library itself seriously and aim to acknowledge every credible
report within seven days.

## This library is NOT an audit

Before filing a report, please read:

- A passing CI run of `hyperevm-safety` against a protocol's contracts
  does NOT certify the protocol is safe. The library catches the bug
  classes the invariants encode (see `docs/invariants.md`); the
  residual surface is the protocol's.
- An `INVARIANT VIOLATED <name>` marker firing in the library's own
  `incidents/<n>/planted/` twin (or in any documented planted-hunk
  reference) is the library **working as intended**. That output is
  not a vulnerability in `hyperevm-safety`.
- `hyperevm-safety` is not a runtime monitor and not a HIP-3
  oracle-update verifier. Those are separate threat models owned by
  other actors; see `README.md`.

## Reporting a vulnerability

**Email:** [security@caliperforge.com](mailto:security@caliperforge.com)

Please **do not** open a public GitHub issue, pull request, discussion
post, or social-media thread for a real vulnerability. Use the private
email path above.

For a report, please include:

- The `hyperevm-safety` commit hash (or release tag) you are running
  against, plus the pinned `hyper-evm-lib` tag, the `forge` /
  `echidna` / `medusa` / `halmos` versions, and the host OS.
- A short description of the issue and the impact you believe it has.
- Steps to reproduce, or a minimal reproducer repo / Foundry project
  if you have one.
- Whether you would like credit in the advisory; if so, the name or
  handle to credit.

A PGP key for `security@caliperforge.com` is available on request.

### What to expect after a report

| Step | SLA | Notes |
|---|---|---|
| Acknowledgement of receipt | **7 days** | If you do not hear back within seven days, email a second time before assuming the report did not arrive |
| Triage and initial severity call | **14 days** | Operator-of-record (Michael Moffett) triages; AI-specialist review may be used in drafting the response, but the operator signs |
| Fix, advisory, or "not a vulnerability" response | as fast as the fix safely allows | Coordinated-disclosure timing negotiated with the reporter |
| Public advisory + patched release | on the same day where feasible | Released via GitHub Security Advisories on this repo |

## Scope

In scope:

- The library contracts under `src/` (`HyperCoreOracleGuard`,
  `SzDecimalsLib`, `PrecompileGasGuard`, `CoreWriterSolvency`,
  `ChainlinkCompatAdapter`, the interfaces, and the gated extensions).
- The Foundry stateful properties under `invariants/` and the
  `Properties.sol` Recon Chimera bundle.
- The formal specs under `formal/halmos/` and `formal/certora/` once they
  land (planned: M2 / M3). Neither is in-tree at v0.1; the directories
  are placeholder-only.
- The CI configuration where a vulnerability there would mask a real
  invariant violation (e.g. a workflow that swallows a non-zero exit
  code).
- The `examples/minimal-lending-market/` reference insofar as it is
  used as the scaffolding base for protocols evaluating the library.

Out of scope:

- **Bugs that we planted on purpose** in the `incidents/<n>/planted/`
  trees and in any documented planted-hunk reference. The
  planted-bug-finds-real-bug discipline is the library's evidence,
  not a vulnerability.
- Vulnerabilities in `hyper-evm-lib`, `chimera-template-pack`,
  `forge`, `echidna`, `medusa`, `halmos`, or other upstream tooling.
  Please report those upstream; we will coordinate if the surface
  reaches `hyperevm-safety`.
- Issues that depend on a contributor running a malicious local
  toolchain (a malicious `forge` binary, a tampered
  `hyper-evm-lib` checkout).
- Behavioral divergence between `hyper-evm-lib`'s EVM-side simulator
  and observed HyperCore behavior is a **documentation issue** (we
  pin a tag and note the deltas in `docs/hyper-evm-lib-notes.md`),
  not a `hyperevm-safety` vulnerability.

## Soundness — what IS a real report

A reproducer that demonstrates a **missed detection** is in scope:
no `INVARIANT VIOLATED` marker firing where the library's documented
bug class should fire, or a marker firing in the `clean/` reference
where none should. That is a soundness issue and we want to know.

A reproducer that demonstrates the library's pattern matches a single
literal instead of the bug class (e.g. a Chainlink-compat adapter
that defeats staleness via a path the property does not catch) is in
scope.

## Disclosure and credit

Default posture is **coordinated disclosure**: we work with the
reporter to fix the issue before public disclosure, then publish a
GitHub Security Advisory crediting the reporter (unless the reporter
prefers to remain anonymous). We do not offer cash bounties at this
time; we do offer credit in the advisory and a public thank-you on
the project's release notes.

## What we will not do

- We will not threaten legal action against good-faith reporters.
- We will not silently downgrade a finding's severity to avoid an
  advisory.
- We will not ship a fix without an advisory unless the reporter asks
  us to.

---

*Apache-2.0 licensed. Built with AI assistance. Authored and reviewed
by Michael Moffett, operator at CaliperForge. Full policy at
[caliperforge.com/ai-disclosure](https://caliperforge.com/ai-disclosure).*
