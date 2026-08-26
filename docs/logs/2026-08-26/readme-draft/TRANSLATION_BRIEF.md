---
date: 2026-08-26
title: "README zh-TW translation — shared brief"
---

# Translation brief — Traditional Chinese README

Round 3 of the README rewrite. The English `README.md` is finished and signed off. We now
produce `README.zh-TW.md`, a Traditional Chinese counterpart. You translate the section
you already wrote; nobody translates someone else's section blind.

## Register

Traditional Chinese as used in Taiwan (繁體中文，台灣用語). Technical, plain, direct — the
same register as the English original. Not Simplified Chinese, and not mainland technical
vocabulary (use 程式 not 程序, 記憶體 not 内存, 資料夾 not 文件夹, 檔案 not 文件,
快取 not 缓存, 解析度 not 分辨率, 預設 not 默认, 相依 not 依赖).

Write for a photographer-developer who reads Chinese but works in an English-named
codebase. That means the prose is Chinese while the identifiers stay English.

## What to translate and what to leave alone

**Translate:** all prose, headings, table header cells, table cells that are natural
language, captions, and bullet text.

**Leave byte-identical, do NOT translate:**

- Every code identifier, type name, method name, constant name, and file path
  (`AppState`, `PhotoPayloadCache`, `tierTwoNavigationDebounce`,
  `lib/services/image_pipeline/photo_source.dart`, `.halcyon_status.json`).
- Every fenced code block: the `yaml`, `bash` and directory-tree blocks.
- **Every ```mermaid block, in full.** The three diagrams were rendered and validated
  against a real Mermaid renderer; retranslating node labels risks breaking syntax that
  has already been proven to work. Copy the diagram blocks across unchanged. You may and
  should translate the caption, legend table and evidence list that surround them.
- Every `<!-- evidence: ... -->` comment. Copy them across unchanged — they are the
  provenance trail and must stay identical between the two language versions.
- Numbers, units, licence identifiers (`LGPL-2.1`, `BSD-3-Clause`), and `TBD (not
  measured)` markers. You may render the marker as `TBD（未量測）`, but do not invent a
  value for it.

## Discipline

This is a translation, not a rewrite. Do not add claims the English version does not
make, do not drop claims it does make, and do not soften anything. Where the English text
states a limitation bluntly — an unimplemented decode path, an unmeasured number, an
open legal question — the Chinese must state it just as bluntly. Understating a
limitation in translation is the failure mode to avoid.

If you find an actual error in the English text while translating, do not fix it silently
in the Chinese. Report it to the lead and translate what is there.

## Output

Write to the path given in your task, one file per section, mirroring the English section
file's structure exactly: same heading levels, same number of headings, same table shapes,
same order. The lead assembles them and generates the table of contents.

## Red lines

Unchanged from round 1: you own only the file named in your task. Do not touch
`README.md`, the English drafts, anything under `lib/ test/ tool/ scripts/` or the
platform runner directories, or anything in `/Users/jhangyu/project/ceyx/`. No git
commands. You may not spawn agents, teams or workflows.

## Reporting

SendMessage to `team-lead` with: the path you wrote, confirmation that the Mermaid blocks
and evidence comments were copied unchanged (if your section has any), any English error
you found, and anything you were unsure how to render. End with `READY_FOR_SIGNOFF`.
