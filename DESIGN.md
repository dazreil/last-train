---
name: Last Train
description: A departure board for one question — the last train home, and the first one back.
colors:
  last-train-red: "#e4002b"
  service-blue: "#012169"
  paper: "#ffffff"
  ink: "#0b0d10"
  surface: "#14181d"
  surface-raised: "#1c2229"
  hairline: "#2a323b"
  text: "#f2f5f8"
  text-dim: "#9aa7b4"
  text-faint: "#6b7885"
  accent-sky: "#4ea3ff"
typography:
  display:
    fontFamily: "Geist Mono, ui-monospace, monospace"
    fontSize: "44px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "-0.04em"
    fontVariant: "tabular-nums"
  headline:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.06em"
  title:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: 1.4
    letterSpacing: "normal"
  body:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "normal"
  label:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 700
    lineHeight: 1.4
    letterSpacing: "0.11em"
rounded:
  none: "0"
spacing:
  gutter: "16px"
  tap: "48px"
components:
  service-block:
    backgroundColor: "{colors.service-blue}"
    textColor: "{colors.paper}"
    typography: "{typography.display}"
    rounded: "{rounded.none}"
    padding: "11px 16px 10px"
  service-block-last:
    backgroundColor: "{colors.last-train-red}"
    textColor: "{colors.paper}"
    typography: "{typography.display}"
    rounded: "{rounded.none}"
    padding: "11px 16px 10px"
  direction-block:
    backgroundColor: "{colors.service-blue}"
    textColor: "{colors.paper}"
    typography: "{typography.headline}"
    rounded: "{rounded.none}"
    padding: "11px 16px"
    height: "68px"
    width: "72%"
  operator-badge:
    textColor: "{colors.paper}"
    rounded: "{rounded.none}"
    padding: "2px 6px"
  recent-block:
    textColor: "{colors.text-dim}"
    rounded: "{rounded.none}"
    padding: "6px 3px"
    height: "48px"
  recent-block-active:
    backgroundColor: "{colors.service-blue}"
    textColor: "{colors.paper}"
    rounded: "{rounded.none}"
    padding: "6px 3px"
    height: "48px"
  station-input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.title}"
    rounded: "{rounded.none}"
    padding: "22px 14px 7px"
    height: "54px"
---

# Design System: Last Train

## Overview

**Creative North Star: "The Departure Board"**

The board on the platform wall. Institutional rather than branded, built to be read
from a distance by someone who is already moving. It does not introduce itself, it
does not explain, and it has no opinion about how you feel — it states times, and it
states them in an order and a weight that tells you which one matters.

Everything follows from the reading conditions: one hand, outdoors, after dark, in a
hurry, usually around 23:40. That scene outranks every aesthetic preference in the
system. Where legibility and expression have conflicted, expression has lost, and the
record of those losses is in the values — the red was changed because a more
attractive one measured 2.51:1 against the blue beneath it, and the display face was
swapped because a more characterful one was 0.66em wide and pushed station names onto
a second line.

The palette derives from the Great British Railways identity but takes the geometry
and the flat colour rather than the flag-waving. Red, white and blue appear because
three states needed encoding, not because of a flag. That distinction is the whole
reason the system does not read as decorative.

**Key Characteristics:**

- Flat colour blocks, zero radius, zero gaps — the result stack is one object
- Red means exactly one thing, and the system is arranged to protect that
- Monospaced tabular times as the largest element, aligned down a column
- Full-bleed to the edges of the usable area; no cards, no floating surfaces
- Every colour pair verified by computation, not by eye

## Colors

A two-signal palette on a near-black ground: one colour for ordinary services, one
for the end of service, and a neutral ramp that never competes with either.

### Primary

- **Last Train Red** (`#e4002b`): The final departure of the service day, and nothing
  else in the entire product. Not errors, not alerts, not an operator, not emphasis.
  It is deliberately *not* the Union Flag's `#C8102F`, which measures 2.51:1 against
  Service Blue — too close to register as a different block at a glance, in the dark,
  which is the only job it has. This value reaches 3.05:1 while keeping white text at
  4.85:1. Brighter reds separate better and push white below AA; the window is narrow.

### Secondary

- **Service Blue** (`#012169`): Every ordinary departure block, and the active state
  of a recent-search block. Dark enough that white sits on it at 14.76:1, which is
  what allows the secondary line to be held back by opacity without losing legibility.

### Neutral

- **Ink** (`#0b0d10`): The page. Near-black with a blue cast so the blue blocks sit on
  it as tonal siblings rather than as cut-outs.
- **Surface** (`#14181d`) and **Surface Raised** (`#1c2229`): Input fields, icon
  buttons, and the suggestion list. The only tonal layering in the system.
- **Hairline** (`#2a323b`): Borders on inputs, chips and recent blocks.
- **Paper** (`#ffffff`): All type on a coloured block, and the focus ring.
- **Text** (`#f2f5f8`), **Text Dim** (`#9aa7b4`), **Text Faint** (`#6b7885`): The
  three-step ramp for type on Ink. Dim carries secondary prose; Faint carries labels
  and disabled states, and measures 6.19:1 on Ink.
- **Accent Sky** (`#4ea3ff`): Interactive tint only — input focus, selected
  suggestion, the distance readout, the active date toggle. Never decorative, and
  never applied to a result block.

In the light appearance the neutral ramp inverts (`#f4f6f8` page, `#ffffff` surfaces,
`#10151a` text, `#0b62c4` accent) and **the two signal colours do not change.** The
blocks read the same in both appearances; only the ground beneath them moves.

### Named Rules

**The One Red Rule.** Red means "this is the last train". The moment it also means
error, alert, operator or emphasis, it means nothing. Two operator badges and three
UI states were recoloured to protect it — Greater Anglia's `#d70428` was within a
whisker of the reserved red and was worn by every service of the operator that runs
the last trains out of Liverpool Street.

**The Measured Palette Rule.** No colour pair enters the system on the strength of
looking right. Compute the contrast ratio, record it, and let the number decide.

**The Opacity Is Not Portable Rule.** Held-back white behaves differently on
different fills: 75% white reaches 8.8:1 on Service Blue but only 3.07:1 on Last Train
Red, and 60% falls to 2.30:1. Text on red is therefore full strength, and only
decorative separators are dimmed. Never reuse an opacity across two fills without
re-measuring.

## Typography

**Display Font:** Geist Mono (with `ui-monospace`, `monospace`)
**Body Font:** Inter Tight (with `system-ui`, `sans-serif`)

Both are self-hosted, cut to single weights and the Latin subset, and loaded with
`display: swap` so times render in a system face rather than waiting on a download.
Rail Alphabet 2 is not licensable; these stand in honestly rather than approximating
it badly.

**Character:** A wide-set grotesque for language and a narrow mono for number. The
pairing is utilitarian by construction — Inter Tight's tight sidebearings let station
names hold their real length beside a very large time, and the mono exists purely so
that digits occupy identical width down the column.

### Hierarchy

- **Display** (700, 44px, line-height 1, `-0.04em`, tabular): Departure times only.
  The largest element on screen by a wide margin, and the only use of the mono face at
  size. 44px rather than a larger figure because at 56px a time plus an untruncated
  station name plus the operator does not fit a 375pt screen.
- **Headline** (700, 24px, uppercase, `0.06em`): The direction block's heading —
  `WESTBOUND`, `EASTBOUND`.
- **Title** (700, 24px): The selected station name in the From field.
- **Body** (700, 18px, line-height 1.15): The destination on a result block. Wraps at
  its real length; never truncated.
- **Label** (700, 12px, uppercase, `0.11em`): Section headings, the masthead, the
  RECENT label, the LAST TRAIN flag. Everything that names a thing rather than being
  the thing.

Secondary block text (`via Ockendon · plat 1 · 2D87`) sits at 14px between Body and
Label, held back by opacity on blue and at full strength on red.

### Named Rules

**The Tabular Rule.** Every time uses `font-variant-numeric: tabular-nums` in a
monospaced face. The result stack is read as a column, and a column only scans if the
digits line up. This is not a preference.

**The Advance Width Rule.** In this layout the mono's advance is a layout constraint,
not a stylistic choice. Geist Mono measures 0.56em; the previously specified Martian
Mono measures 0.66em, which at 44px consumed 145px of a 375pt screen and forced every
station name onto a second line. Measure before substituting a face.

**The Real Length Rule.** Station names are never truncated and never ellipsised. If a
name is long it wraps. "London Fenchurch S…" loses the only word that identifies it —
so London termini drop the "London" for display instead, with the full name kept in
the tooltip and the accessible name.

## Layout

A single column, `34rem` maximum, centred, with a **16px gutter** (`--gutter`) that
everything either respects or deliberately escapes.

The controls occupy the top of the screen and the results fill the rest. The control
stack is budgeted: masthead, From field, direction block, RECENT row — and it ends by
40% of the viewport height so the first departure is visible without scrolling and the
last-train block is fully visible at 81%. Every row added above the results is paid
for out of how much of the answer you can see.

Result blocks, the direction block and notices are **full bleed**: they escape the
gutter by exactly `var(--bleed)`, reaching the edge of the usable area. That token
collapses to `0` at `34rem`, where the container stops growing — past that there is
no screen edge to bleed to, only page either side, and bleeding would just make the
bands wider than the controls above them. Safe-area
insets are applied as custom properties (`--sa-top`, `--sa-right`, `--sa-bottom`,
`--sa-left`) rather than inline `env()`, so behaviour can be exercised in a browser
with no notch. Side insets live on the body, which is what keeps a full-bleed block
from sliding under a landscape notch while still reaching the true edge.

Vertical rhythm is tight and irregular by intent — spacing is tuned per boundary
against the fold budget rather than stepped from a scale.

### Named Rules

**The Fold Rule.** Controls end by 40% of the viewport. The first departure is visible
without scrolling; the last-train block is fully visible without scrolling. Any change
that pushes either below the fold has broken the layout regardless of how it looks.

**The Grow-Never-Clip Rule.** At 200% text the stack grows downward and never
overflows sideways. Result rows wrap the operator badge onto its own line, and the
direction block grows past its 72% anchor rather than clipping — under magnification
the words matter more than the position metaphor.

**The One Column Rule.** Every band in the results area shares one left edge,
whatever the state. A notice is a band, not a card: inset while the blocks bled, the
column visibly changed width between "here are your trains" and "nothing that way".

## Elevation & Depth

**The system is flat.** There are no ambient shadows, no gradients on surfaces, no
translucency, and no blur. Depth is conveyed by two devices only: tonal layering in
the neutral ramp (Ink → Surface → Surface Raised) and flat colour blocks sitting on
the page.

Exactly one shadow exists in the entire system.

### Shadow Vocabulary

- **Dropdown lift** (`box-shadow: 0 12px 32px rgb(0 0 0 / 0.35)`): The station
  suggestion list, and nothing else. It is a temporary layer over content and needs to
  read as one.

### Named Rules

**The One Shadow Rule.** A shadow is permitted only where an element genuinely floats
above content that still exists beneath it. Everything else — blocks, inputs, chips,
buttons — is flat at rest and flat in every state.

## Shapes

**Radius is zero, set once at the root as `--radius: 0`, and never overridden.** Every
block, input, button, badge and chip is a true rectangle. There are no pills, no
capsules, and no rounded cards.

Borders are single-pixel hairlines and appear only on neutral surfaces — inputs, icon
buttons, chips, recent blocks. Coloured blocks carry no border at all; they are
separated from each other by colour change alone.

Where two blocks of the *same* colour meet, a single hairline in white at 20% opacity
(`--signal-rule`) divides them. Where blue meets red, nothing is drawn — the colour
change is the division, and adding a rule there would weaken it.

Adjacent blocks in the RECENT row collapse their shared edge (`border-left-width: 0`,
restored on the first child) so the row reads as one object rather than four.

### Named Rules

**The Zero Radius Rule.** Set once at `:root`, never overridden anywhere. A single
rounded corner would make the whole system look like an accident.

**The No Gaps Rule.** The result stack has `gap: 0`. Blocks butt together into one
solid column, which is what lets the red block register as the end of service from
across a platform rather than as one card among several.

## Components

### Result Block (signature)

The system's primary object. A flat, full-bleed, square block carrying one departure.

- **Shape:** Rectangle, no radius, no border. Full bleed past the gutter.
- **Ordinary service:** Service Blue ground, Paper type, `11px 16px 10px` padding.
- **Last service:** Last Train Red ground, and a `LAST TRAIN` label in 12px uppercase
  above the time. **Colour is never the only signal** — the label carries it for
  anyone who cannot separate the two hues, and the white band reads at a glance even
  before the words do.
- **Composition:** Time (Display) and destination (Body) share a baseline-aligned row
  that wraps under magnification; operator badge pushed to the trailing edge; a 14px
  secondary line beneath carrying route, platform and headcode.
- **Separation:** Hairline between same-coloured neighbours only.

### Direction Block (signature)

Direction expressed as position rather than as a control.

- **Shape:** 72% width, `68px` tall, Service Blue, full bleed, no radius.
- **Behaviour:** Anchored to the left edge for westbound, translated to the right edge
  for eastbound (`translateX(38.889%)`). Tapping toggles.
- **Motion:** `transform 240ms cubic-bezier(0.2, 0, 0, 1)` — the only orchestrated
  movement in the product. Removed entirely under `prefers-reduced-motion`.
- **Mark:** An original two-chevron mark, mirrored per direction. British Rail's
  double arrow is a protected mark and is deliberately not used.
- **Content:** Heading in 24px uppercase, plus a `towards …` line naming up to two
  real destinations — because a compass direction only means something if you know
  where it goes from where you are standing.

### Operator Badge

- **Style:** White 1px outline, transparent ground, Paper type, 12px uppercase,
  `0.06em` tracking, no radius.
- **Never filled with a brand colour.** Filled operator badges were removed precisely
  because one of them was almost exactly the reserved red.

### Recent Block

- **Style:** Transparent with a hairline border, `48px` minimum height, collapsed
  shared edges so the row reads as a single object.
- **Content:** CRS code at 15px over a direction marker at 11px — a recent search is a
  station *and* a direction, and a block that carried only the code would restore a
  query the user did not ask for.
- **Active:** Service Blue fill, Paper type, `aria-current`.

### Inputs

- **Style:** Surface ground, hairline border, no radius, `54px` minimum height. The
  field label sits inside the box, 12px uppercase, positioned above the value.
- **Focus:** 2px Accent Sky outline, inset.
- **Suggestions:** Surface Raised list, the system's only shadow, 48px minimum rows,
  hairline dividers, selected row tinted with Accent Sky at 18%.

### Notices

- **Style:** A full-bleed band on Surface ground with hairline top and bottom rules,
  no radius — the same silhouette as a result block, because it occupies the same
  slot. Side borders return at `34rem`, where there is a real edge again. Used for
  the empty state and the error state alike.
- **Error:** Distinguished by a **2px** border in Text Dim and an uppercase heading —
  never by colour. Red is spoken for, and an error is not the last train.
- **Empty:** Identical treatment to any other notice. "Nothing eastbound" is a real
  answer and must never be dressed as a failure.

### Skeleton

- **Style:** Three rows at `5.6rem` — the exact height of a single-line result block
  — shimmering Surface → Surface Raised over 1.2s. Static under
  `prefers-reduced-motion`.
- The height is the point: the layout must not jump when the answer lands. Revisit
  the value if block padding or the time size changes.

### Icons

Drawn, never borrowed and never a Unicode glyph. One stroke language throughout:
square caps, no fill, `currentColor`, and a weight that steps down with size — the
direction block's double chevron at 4.5, a recent block's single chevron at 2.75.

- **Crosshair:** nearest station. A reticle rather than a map pin, because it means
  "where I am", not "a place".
- **Chevron down:** the date control's affordance.
- **Single chevron:** direction on a recent block, echoing the direction block's mark.

Every icon sits inside a control that already carries its own accessible name, so all
are `aria-hidden`.

### Named Rules

**The Drawn Mark Rule.** No glyph stands in for an icon. A pasted `◎` is a type
designer's idea of a reticle sitting next to a mark drawn for this app, at a stroke
weight nothing else shares — and it cannot be referenced from copy without the two
drifting apart.

**The Position Is The Answer Rule.** The direction block's meaning is where it sits,
not what it says. Any replacement must preserve that — a segmented control would be
more conventional and would throw away the only pre-linguistic thing in the interface.

## Do's and Don'ts

### Do:

- **Do** reserve `#e4002b` exclusively for the last departure of the service day, and
  give it a visible `LAST TRAIN` label as well as the fill.
- **Do** compute contrast for every new colour pair and record the ratio. The palette
  already changed once because a chosen value measured 2.51:1.
- **Do** re-measure opacity when moving muted text between fills — 75% white is 8.8:1
  on Service Blue and 3.07:1 on Last Train Red.
- **Do** set every time in Geist Mono with `tabular-nums`, so the column scans.
- **Do** let station names wrap at their real length, and drop "London" from London
  termini rather than truncating them.
- **Do** keep the control stack inside 40% of the viewport, and check that the
  last-train block is still fully visible after any change above it.
- **Do** apply safe-area insets on all four edges via the `--sa-*` custom properties.
- **Do** let result rows wrap under magnification; verify at 200% text.

### Don't:

- **Don't** use red for errors, alerts, operators, emphasis, or anything else. There
  is no `--danger` token in this project, deliberately.
- **Don't** fill an operator badge with its brand colour. Outline only.
- **Don't** introduce a border radius anywhere. `--radius: 0` is set once at the root.
- **Don't** add gaps between result blocks, or a rule between the blue and red blocks.
  The colour change is the division.
- **Don't** add a second shadow. The suggestion dropdown is the only element in the
  system that floats.
- **Don't** truncate or ellipsise a station name.
- **Don't** substitute the mono face without measuring its advance width; above about
  0.6em the layout breaks.
- **Don't** let this drift toward dashboard or analytics UI — no charts, no sparklines,
  no KPI tiles, no dense multi-column data. This is read standing up, in the dark, in
  under two seconds.
