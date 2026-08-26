---
date: 2026-08-26
title: "README rewrite — convergence contract"
---

# README rewrite — convergence contract (FROZEN)

Only the user may amend this contract. Re-paste the terminal state and acceptance
criteria verbatim at every round kickoff.

## Terminal state (one sentence)

`README.md` (English) and `README.zh-TW.md` (Traditional Chinese) at the repository
root describe Halcyon completely and truthfully — product identity, the photographer
triage workflow, RAW format/decode support via Ceyx, measured performance, the cache
and memory design, the full architecture, and per-platform build instructions — with
every factual claim traceable to code, config, or a recorded measurement.

## In scope

1. Two root README files, cross-linked at the top of each.
2. Section drafts written by the team under `docs/logs/2026-08-26/readme-draft/`.
3. Screenshot references pointing at `docs/images/` paths that the user will fill in
   later; captions written now, image files not created by the team.

## Out of scope (do not touch)

- Any file under `lib/`, `test/`, `tool/`, `scripts/`, `macos/`, `windows/`, `linux/`,
  `android/`, `ios/`, `web/`.
- `rule.md`, `memory.md`, `task.md`, `plan.md`, `handover.md`, `file_index.md`,
  `unit_test.md`, `CLAUDE.md` — read-only for this task.
- The existing `README.md` — only the lead writes it, in the integration step.
- The Ceyx repository (`../ceyx`) — read-only.
- Running builds, benchmarks, or the app. No new measurements this round.

## Acceptance criteria (checked one by one at sign-off)

- AC1: Each assigned section file exists at its declared path and contains only that
  section's content in English Markdown, starting at heading level `##`.
- AC2: Every factual claim about behaviour carries an inline evidence note in the form
  `<!-- evidence: path/to/file.dart:123 -->` immediately after the claim's paragraph or
  table row. Claims with no locatable evidence are deleted, not softened.
- AC3: No invented numbers. Any performance, size, timing, threshold, or count value
  appears only if it is present in source, config, or a recorded artifact, and the
  evidence note names that source. Missing values are written as `TBD (not measured)`.
- AC4: Native-bridge and platform-support claims are grep-verified against
  `macos/Runner/AppDelegate.swift` and the platform runner directories before being
  written (see lessons: doc claims about native bridges must be grep-checked).
- AC5: `flutter analyze` and the test suite are untouched and unaffected — the team
  writes no code.
- AC6: Each member's report states, per acceptance criterion, pass or fail, and lists
  any claim they wanted to make but dropped for lack of evidence.

## Round budget

3 rounds. Round 1: English section drafts. Round 2: lead integration + gap fixes.
Round 3: Traditional Chinese translation. Exhausting the budget without full acceptance
means stopping and reporting the failure trace, not opening a fourth round.

## Parking lot

New findings during the rounds (including reviewer findings and "more urgent" items) go
here, are not promoted into acceptance criteria, and are reported to the user at the end.

- (empty at freeze)
