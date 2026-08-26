---
date: 2026-08-26
title: "SOP document relocation — convergence contract"
---

# SOP relocation — convergence contract (FROZEN)

Only the user may amend this contract. Re-paste the terminal state and acceptance
criteria verbatim at every round kickoff.

## Terminal state (one sentence)

The seven project maintenance documents live under `docs/sop/` instead of the repository
root, that directory and the root `CLAUDE.md` are untracked and git-ignored, and no
tracked file in the repository points at a path that no longer exists.

## The user's ruling

Option 2 of three presented on 2026-08-26: move **and** git-ignore. The user additionally
ruled that `CLAUDE.md` is to be `git rm --cached`. The trade-off was stated to the user
before they chose it: the documents leave version control, so an outside contributor
cloning this repository will not receive them, and every reference to them from tracked
files becomes a dangling pointer unless rewritten. That is accepted, which is why
rewriting the references is in scope rather than optional.

## In scope

1. Move these seven files from the repository root into `docs/sop/`:
   `rule.md`, `memory.md`, `task.md`, `plan.md`, `handover.md`, `file_index.md`,
   `unit_test.md`.
2. `CLAUDE.md` stays at the repository root — Claude Code reads it from there — but is
   removed from the index and git-ignored.
3. `.gitignore` gains entries for `docs/sop/` and `CLAUDE.md`.
4. All eight files are removed from the git index with `git rm --cached`, so they remain
   on disk and disappear from version control.
5. Every reference to these documents from a **tracked** file is rewritten so it does not
   name a path that is absent from the repository. Fourteen source/test/tool files carry
   one reference each; `README.md` and `README.zh-TW.md` carry references on 67 lines each.

## Out of scope (do not touch)

- Any behavioural change to Dart code. Comment text only in `lib/` and `test/`.
- The contents of the seven SOP documents themselves. They move; they are not edited.
- `docs/legal/`, `docs/images/`, `docs/logs/` (except this contract), `docs/superpowers/`.
- Committing. The lead commits once, at the end, after sign-off.
- Deleting any file. This task moves and untracks; it destroys nothing.

## How references are to be rewritten

Two different kinds of reference, two different treatments.

**A code comment that cites a decision** — for example `see memory.md AD-014` — keeps the
decision identifier and drops the filename: `see architecture decision AD-014`. The
identifier is what carries the meaning, and it remains findable by anyone who has the SOP
set locally, while no longer pointing at a path the repository does not contain.

**An evidence note in the README pair** — `<!-- evidence: memory.md AD-023 -->` — becomes
`<!-- evidence: docs/sop/memory.md AD-023 -->`. These are HTML comments, invisible to a
reader, and they exist as a provenance trail for whoever maintains the file in a working
tree that does have the documents. They stay accurate for that reader.

**README prose that advertises the SOP documents to contributors** must be rewritten or
removed, because it would be telling a reader to open files their clone does not contain.
This includes the repository-layout tree entries for the seven files and the paragraph
describing the documentation SOP.

## Acceptance criteria (checked one by one at sign-off)

- AC1: `docs/sop/` contains exactly the seven named files; none of the seven remains at
  the repository root.
- AC2: `git ls-files` returns nothing under `docs/sop/` and does not list `CLAUDE.md`.
- AC3: `CLAUDE.md` still exists at the repository root on disk, byte-identical to its
  pre-task content.
- AC4: `.gitignore` contains entries covering `docs/sop/` and `CLAUDE.md`.
- AC5: `git grep -nE '(^|[^/])\b(rule|memory|task|plan|handover|file_index|unit_test|CLAUDE)\.md'`
  returns no hit that names one of these documents as a bare root-level path, in any
  tracked file.
- AC6: `flutter analyze` reports zero issues.
- AC7: `flutter test` passes with no new failures, and the pass/fail count matches the
  pre-task baseline.
- AC8: No tracked file was deleted and no Dart statement was changed — the diff over
  `lib/` and `test/` touches comment lines only.

## Round budget

2 rounds. Exhausting the budget without full acceptance means stopping and reporting the
failure trace, not opening a third round.

## Red lines

- NEVER `git stash`, `git reset`, `git checkout --`, `git clean`, `git add -A`,
  `git add .`, or a bare `git commit`. The working tree holds other members' in-flight
  work at all times.
- Do not commit at all. The lead commits.
- `git mv` must be used for the relocation so the rename is visible to git; when the lead
  later commits, both the old and the new path must appear in the pathspec.
- Do not touch a file outside your ownership list. If you believe a file outside your list
  needs a change, report it; do not make it.

## Parking lot

- (empty at freeze)
