# Round 2 mockups — D1/D2/D3

All three implement the frozen merge directive: B3's top segmented-control tabs + persistent right-hand
"at a glance" summary rail, B2's section-label dividers (uppercase label + trailing hairline) and
responsive 2-column grid arranged inside each tab, export JPEG quality kept as a slider, and A1's
typography (15px/600 header, 10.5px/0.06em uppercase section labels, 12.5px row labels, monospace
captions/values, A1's tier-card and shortcut-row proportions). Same content as round 1 throughout:
decode lane width slider, export JPEG quality slider (default 90), Conservative/Balanced/Generous
retention tiers at 224/304/384 MiB, and the 7-shortcut list with Record affordances and the X-key
conflict warning.

- **D1** — baseline refinement: rail items are full two-line label/value blocks (matches B3's original
  rail density), grid gap 16px, dialog widened to 920×560 to give the grid breathing room alongside the
  224px rail. Closest of the three to a literal B3+B2+A1 splice.
- **D2** — compact rail: each rail entry collapses to a single label:value line (5 entries fit in less
  vertical space, abbreviated labels like "Lanes"/"Tier"), grid gap tightened to 12px, block padding and
  font sizes trimmed ~1px across the board. Reads denser/more information-per-inch; dialog narrows to
  900×552 rail down to 188px.
- **D3** — spacious/context rail: each rail item keeps B3's label/value pair but adds a one-line
  contextual sentence underneath (e.g. "Capped by this machine's core count."), so the rail doubles as a
  glanceable explainer, not just a value readout. Grid gap opens to 22px, block corner radius bumps to
  6px, and captions merge the row-caption text directly under each slider (dropping the separate small
  numeric label) for a more generous, editorial feel. Dialog grows to 940×580 to host the wider rail
  (250px) and extra caption lines.
