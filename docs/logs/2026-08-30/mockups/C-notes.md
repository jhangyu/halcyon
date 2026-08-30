# Settings Panel Mockups — C1/C2/C3 (Round 2, merge of B3+B2+A1)

All three implement the frozen merge directive: B3's shell (top segmented-control tabs, persistent
220px right-hand "at a glance" summary rail with live values), B2's content arrangement inside each
tab (uppercase `section-label` dividers with a trailing rule, `.block` cards on `--pane` background),
export JPEG quality kept as a slider (not the B2/A1 stepper), and A1's typography/text styling lifted
directly (13px/12.5px row labels, 10.5px uppercase 0.06em-letter-spaced section labels and rail
headings, `ui-monospace` captions/values, the `--tier`/`--block` color and radius vocabulary from
`HalcyonTokens.dark`). Same 880×540 dialog frame as B3/A3, same real content as round 1: decode lane
width slider (3/5), export JPEG quality slider (default 90), retention tiers Conservative/Balanced/
Generous at 224/304/384 MiB, 7 shortcuts with per-row Record buttons and the "X" conflict between
Trash-mark and Toggle recycle mode.

**C1 — Baseline merge, 2-column grid throughout.** Performance tab uses B2's `.grid` (2 equal columns)
for the lane-width and export-quality cards side by side; Memory and Shortcuts sections render full-bleed
below in the same scrolling tab content, matching B3's "everything visible for this mockup" convention.
Summary rail is the plain 4-item list carried over from B3 almost verbatim, just re-typeset with A1's
label/value styling. This is the least opinionated of the three — closest literal reading of the
directive with no extra embellishment.

**C2 — Dense/status-strip summary rail.** Same tab content as C1 (2-column grid, B2 card treatment), but
the rail is reinterpreted as a denser "status strip": each item gets a hairline bottom border, an
uppercase micro-label, and a secondary caption line (e.g. "304 MiB · −3 / +8 photos", "Key \"X\" bound
twice") instead of packing everything onto a single value line; the decode-lanes item also gets a thin
progress-style fill bar showing 3-of-5 visually. Trade-off explored: more glanceable detail per item at
the cost of a taller, busier rail — the rail leans further into being a genuine "status panel" rather than
a compact value list.

**C3 — Heavier section dividers, vertical tier list, stacked Performance cards.** Section labels get a
full-width bottom border (not just B2's trailing rule after the text) for a more pronounced rename-dialog
divider feel. Performance tab abandons the 2-column grid for a single stacked column (deliberate
divergence from C1/C2, still within "tasteful interpretation" since B2 itself full-bleeds its larger
sections) — reads as one coherent "Parallelism & Export" group rather than two independent cards. Memory
retention reverts the tier cards to B3's original horizontal list-row treatment (name+detail on the left,
big budget number on the right) instead of B2's 3-column grid, trading tier-to-tier visual comparison for
tighter per-row scanability of the formula caption. Summary rail matches C1's plain list, but the "At a
glance" heading itself gets B2's trailing-rule divider treatment for consistency with the section labels.
