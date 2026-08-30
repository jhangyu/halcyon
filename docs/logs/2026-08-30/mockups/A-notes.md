# Settings Panel Mockups — A1/A2/A3 (variant set A)

All three are self-contained HTML files, dark theme, colors/spacing lifted directly from
`lib/views/theme_tokens.dart`'s `HalcyonTokens.dark` palette (pane `#333333`, dialog `#383838`,
surface `#414141`, input `#262626`, border `#515151`/`#454545`, text `#e0e0e0`/`#9a9a9a`/`#6f6f6f`,
accent `#0a84ff`, danger `#ff453a`), `borderRadius: 5` on blocks/chips and `8` on the dialog shell,
and the rename-dialog header pattern (title + subtitle + pill badge, bottom border). Retention tier
numbers are the real rung values from `retention_policy.dart:67-82` (Conservative 224 MiB / −3+5,
Balanced 304 MiB / −3+8, Generous 384 MiB / −3+11), with the derivation formula shown as a caption
since actual selection is machine-dependent.

**A1 — Single-scroll with sections** (640×640). All four setting groups (Parallelism, Export, Memory
Retention, Keyboard Shortcuts) stacked vertically in one scrollable pane, each under an uppercase
section label, mirroring `RuleEditor`'s section-label pattern from the rename dialog but as a single
full-width column rather than a narrow side pane. Trade-off: simplest to scan top-to-bottom and needs
no interaction model beyond scrolling, but the shortcut conflict state pushes the dialog tall and a
user has to scroll past three sections to reach shortcuts.

**A2 — Tabbed** (600×560, CSS-only radio-driven tabs, no JS). Four top tabs — Performance / Memory /
Export / Shortcuts — each showing one concern at a time in a fixed-height content area below the tab
strip. Trade-off: keeps the dialog compact and each screen focused (good for the dense shortcut list),
but hides the memory/export settings behind a click, so a user can't eyeball everything at once the
way they can in A1.

**A3 — Two-pane master-detail** (880×540, radio-driven left-nav switch, no JS). Directly imitates the
rename dialog's overall silhouette: same 880×540 dialog frame, a 180px `t.pane`-colored left nav list
(Performance/Memory/Export/Shortcuts) separated by a 1px `borderSoft` vertical divider from a wider
detail pane on the right, each detail view getting its own title+description header. Trade-off: most
visually consistent with the existing rename-dialog chrome and gives the retention tiers room to
breathe as a 3-column grid, but is the widest dialog of the three and the left nav is dead space when
only 4 categories exist (would pay off more if the settings list grows later).
