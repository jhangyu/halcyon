---
date: 2026-08-26
title: "README rewrite — shared briefing for all writers"
---

# Shared briefing — read this first

You are one of nine writers producing section drafts for a complete rewrite of Halcyon's
`README.md`. The lead (main agent) integrates all sections into the final file. You write
ONE section. Do not write anyone else's section, and do not write the final README.

## The contract

The frozen convergence contract is at
`docs/logs/2026-08-26/readme-rewrite-contract.md`. Read it. Its acceptance criteria bind
your work. The two that fail people most often:

- **AC2** — every behavioural claim carries an inline evidence note
  `<!-- evidence: path/to/file.dart:123 -->` right after the paragraph or table row it
  supports. A claim you cannot locate in code, config, or a recorded artifact is deleted,
  not softened into a vague sentence.
- **AC3** — no invented numbers. Timings, sizes, thresholds, counts, format lists: only
  what is actually present in the tree. Anything you cannot source is written as
  `TBD (not measured)` and listed in your report.

## Audience and register

The reader is a photographer-developer evaluating whether to use or build on this
project, or a contributor about to touch the code. Write like the sister project's
README at `/Users/jhangyu/project/ceyx/README.md` — read it before you start. That
document is the register to match: technical, specific, honest about limitations, no
marketing adjectives, no emoji headings, no exclamation marks. It states what is
implemented and what is not, and it says so plainly.

Language: **English**. A Traditional Chinese translation happens in a later round; do not
write Chinese.

## What Halcyon is

A Flutter RAW/JPG photo triage tool for photographers. Open a folder, browse it with the
arrow keys, mark photos with a star or a trash flag, then batch-copy the starred ones,
export them at social-media size, or move the trashed ones away. It targets a wide
desktop screen and a 3:2 frame, keeping the preview area as large as possible. RAW decode
is delegated to the sister project Ceyx, a GPU-accelerated decoding engine.

Name lineage worth knowing (the identity writer owns this section, but everyone benefits
from the context): *Halcyon* and *Ceyx* are both kingfisher genera, and in Greek myth
Alcyone and Ceyx were transformed into kingfishers — the two repositories are named as a
pair.

## Where things live

- `CLAUDE.md` — the architectural summary of this repo. Accurate and current. Start here.
- `file_index.md` — the full file/directory map with per-file one-line descriptions.
  Use it to locate code instead of searching blind.
- `memory.md` — architecture decisions `AD-001`..`AD-030` and gotchas `G-001`..`G-021`.
  This is where the *reasons* behind the design live. Cite it as
  `<!-- evidence: memory.md AD-023 -->` when the claim is a design rationale rather than
  a code behaviour.
- `plan.md` — phase milestones and their completion state.
- `unit_test.md` — test strategy and the TC-NNN test-case matrix.
- `lib/` — Dart source, layered `views/` → `providers/app_state.dart` → `services/`
  (`image_pipeline/`, `library/`, `rename/`, `platform/`) → `models/`.
- `macos/Runner/AppDelegate.swift` — the only place native bridges are registered.
  Claims about native bridges MUST be grep-verified against this file (AC4).
- `scripts/build_apps.py` — the single build entry point for all targets.
- `docs/logs/YYYY-MM-DD/` — task logs; recorded measurements live here.
- `/Users/jhangyu/project/ceyx/` — the sister decoding engine, read-only for you.
  Its `README.md`, `docs/` and `plugin/` are the source of truth for decode claims.

## Output rules

- Write exactly one file, at the path given in your task. Nothing else.
- Start the file at heading level `##`. Use `###` for subsections. Never `#`.
- Markdown tables are preferred over prose lists for anything enumerable (keyboard
  shortcuts, format support, platform status, thresholds).
- Screenshots: if your section calls for one, write the image reference against
  `docs/images/<descriptive-name>.png` with a real caption. The image files do not exist
  yet; the user supplies them later. Do not create placeholder image files.
- Target length is whatever the evidence supports. A short honest section beats a long
  padded one.
- Anchor-friendly headings: the lead builds a table of contents from your `##`/`###`
  headings, so make them descriptive and stable.

## Red lines

- Do NOT modify `README.md`, any file under `lib/ test/ tool/ scripts/ macos/ windows/
  linux/ android/ ios/ web/`, or any of `rule.md memory.md task.md plan.md handover.md
  file_index.md unit_test.md CLAUDE.md`. All read-only.
- Do NOT modify anything in `/Users/jhangyu/project/ceyx/`. Read-only.
- Do NOT run builds, benchmarks, tests, or the app. No new measurements this round.
- Git: never `git stash`, `git reset`, `git checkout --`, `git clean`, `git add -A`,
  `git add .`, or a bare `git commit`. Do not commit at all — the lead commits.
- You may NOT spawn agents, teams, or workflows. If your task seems to need delegation,
  stop and report to the lead.

## Instrumentation discipline

This repository has an expensive history of false confidence from measurement artifacts.
Two rules that apply even to documentation work:

- Grepping a keyword is not evidence that a behaviour exists — prose, comments, and dead
  code all match keywords. Read the actual code path before asserting it runs.
- A document making a claim is not evidence the claim is true. `memory.md` and
  `plan.md` are good sources for *rationale*; for *behaviour*, cite the code.

## Reporting

End your turn with a SendMessage to `team-lead` containing:

1. Your conclusions and key findings, each with `file:line`.
2. The path of the file you wrote.
3. Each acceptance criterion (AC1–AC6) marked pass or fail.
4. Every claim you wanted to make but dropped for lack of evidence, and anything you are
   unsure about.

Do not paste your section content into the message — the lead reads the file. Anything
over 30 lines goes in a file, not a message.

Your report ends with `READY_FOR_SIGNOFF`. Do not mark your own task completed; the lead
signs off and closes it.
