# AI Disclosure — hyperevm-safety

The `hyperevm-safety` library is built and maintained by CaliperForge
under an AI-augmented authoring stack. This document is calm disclosure
of which surfaces are AI-touched and the review discipline that gates
each one.

## What is AI-touched

- **Invariant proposals.** Candidate invariant predicates (the property
  prose, the Solidity property body, the Halmos / Certora spec) are
  drafted by a Claude model (Sonnet 4.6 for ABI / storage-layout
  pattern recognition; Opus 4.6 / Apex for judgment-heavy reasoning
  about precompile and CoreWriter semantics). Every accepted invariant
  is reviewed and edited by the case specialist (`solidity_specialist`,
  occasionally in the FV register) before being committed.
- **Same-source twins.** The reconstructed code in each incident's
  `clean/` and `planted/` subtrees, and the planted-hunk references used
  for the library's own property tests, are authored by a CaliperForge
  specialist against the affected protocol's published post-mortem. The
  reconstruction is faithful to the post-mortem's described bug class;
  it is NOT a fork of the protocol team's production source.
- **READMEs and case write-ups.** Drafted with AI assistance; reviewed
  against CaliperForge's internal anti-AI-ism and register rubric
  before publish.

## What is NOT AI-touched

- The published post-mortem URLs themselves (carried as-cited).
- The CI verdict (pass / fail is a function of the `forge` / `echidna` /
  `medusa` / `halmos` run, not the model).
- The operator-approved positioning paragraph (README.md, the
  §1.1-locked block) — that text is human-locked verbatim across
  surfaces.
- The operator's final-pass sign-off decisions and the milestone
  exit-gate sign-offs.

## Audit trail

- Every incident's `README.md` cites the primary public post-mortem URL
  (re-verified by `research_lead` per the T-9 build ticket; ≥2 primary
  sources per incident before the case is merged).
- Every `hyperevm-safety` commit lists the author (Michael Moffett,
  operator at CaliperForge) and is operator-clean (no
  `Co-Authored-By` trailers).
- The library-properties + incident clean/planted CI legs are uploaded
  as artifacts on every push (see `.github/workflows/ci.yml`).

## Why we disclose

CaliperForge's identity register makes AI-augmented authorship the
default disclosure posture, not the exception. Reviewers should know
which content was AI-drafted so they can apply their own scrutiny at
that surface. See
[caliperforge.com/ai-disclosure](https://caliperforge.com/ai-disclosure)
for the org-level register.

## Contact

Operator: Michael Moffett — michael@caliperforge.com — team@caliperforge.com.
