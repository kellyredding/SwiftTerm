# Patch History

This file tracks the Galactic customization patch state at each tagged
release of `kellyredding/SwiftTerm`. Each entry documents the upstream
base, the patches included, any patches dropped relative to the prior
release (because upstream independently fixed the same bug), and the
verification the release passed.

This file is part of commit 4 (the Galactic customization commit) in
the four-commit `main` structure described in `MAINTAINING.md`. It
gains an entry per tagged release — both upstream bumps and re-cuts
against the same upstream, since either can change the patch state.

## v1.13.0-galactic.10 — upstream v1.13.0

Base: upstream at tag `v1.13.0`. Re-cut against the same upstream with
**no code change** — the Swift source tree is byte-identical to
`v1.13.0-galactic.9`. This revision exists solely to correct
`MAINTAINING.md`, which had drifted from the repository it describes in
ways that would have destroyed work on the next upstream bump.

### Documentation corrected

- **The lineage is four commits, not three.** `GalacticApiSmoke/` was
  added as commit 2 and never written into the invariants. `PATCHES.md`
  has asserted the four-commit structure since it was written, so the
  two documents contradicted each other, and the one describing the
  bump procedure was the wrong one.
- **Step 4a branched from the wrong commit.** It resolved the base with
  `git rev-list --max-parents=0`, which returns the orphan root. Every
  bump that followed it literally would have rebuilt the lineage without
  `GalacticApiSmoke/` — 261 lines of compile-only API contract silently
  absent from the release, and nothing in the procedure would have
  noticed. It now branches from commit 2.
- **Step 4b preserved one named file.** It snapshotted `MAINTAINING.md`
  across the tree-replace and restored only that, so `PATCHES.md` — also
  owned by the base — was wiped. Step 4c would then have applied the
  previous release's patch, which carries a `PATCHES.md` delta, against
  a file that no longer existed. The step now restores the base's whole
  tree, because naming files is what caused both losses and would cause
  the next one.
- **The orphan root holds two files, not one**, and the patch-history
  section attributed `PATCHES.md` to commit 3 rather than commit 4.
- **Step 5 quietly rewrote a tracked file.** Verifying with
  `GITHUB_ACTIONS=true` drops the benchmark dependencies from the
  resolved graph, and SwiftPM rewrites `Package.resolved` to match —
  65 pins removed. Found by running the step while cutting this
  revision and diffing before committing. The step now says so and says
  to restore the file.

### Why a revision bump for a documentation change

`v1.13.0-galactic.9` was already published and consumed. Re-pointing it
would have broken SwiftPM's `(URL, version) → revision` mapping in every
consumer, which the safety rules forbid; the same rules prescribe a
revision bump for exactly this case — a post-tag correction to commit 4.
`.9` is not superseded in any functional sense and remains valid: the
engine it ships is identical to this one.

### Verification

- `swift build` on the fork passes.
- `swift test` passes with the same results as `.9`.
- Galactic's smoke test was not re-run, and the reason is stronger than
  running it would have been: `git diff v1.13.0-galactic.9 -- Sources
  Tests Package.swift` is empty, so the surface Galactic compiles
  against is provably unchanged from the revision it already builds on.

## v1.13.0-galactic.9 — upstream v1.13.0

Base: upstream at tag `v1.13.0`. Re-cut against the same upstream (no
version bump) to add the caret blink-restore patch below.

### Patches added in this revision

- **Caret blink survives a cursor hide/show cycle** (`MacTerminalView`,
  `AppleTerminalView`) — both paths that put the caret view back into the
  hierarchy now call `caretView.updateCursorStyle()` after `addSubview`.
  A blinking caret exists only as a repeating `CABasicAnimation` on the
  caret layer's opacity; it is not stored state anywhere. `hideCursor`
  removes the caret from the view hierarchy, which takes its layer out of
  the render tree, and Core Animation cancels the animation when that
  happens (`animationDidStop` reports `finished: false`). The `style`
  property the animation is derived from is untouched, so the property
  observer that rebuilds it never fires, and the caret returns rendering
  the correct shape but permanently steady. Full-screen programs emit
  DECTCEM hide/show around their redraws — Claude Code does so during
  session startup — so in practice a blinking caret never survived past
  the first redraw. The only thing that restored it was an incidental
  `updateCursorStyle()` from focus gain or the became-main observer,
  which made the bug look like a focus problem. Restoring on the
  re-attach branches only, rather than on every refresh, matters: an
  unconditional re-assert would restart the animation continuously and
  hold the caret at full opacity, which reads as a caret that never
  blinks at all.

### Verification

- `GITHUB_ACTIONS=true swift build` on the fork passes.
- `GITHUB_ACTIONS=true swift test`: 376 tests, 33 suites, 2 pre-existing
  issues — both in `ColorTests.testTerminalAnsi256PaletteStrategyRuntimeToggle`,
  which asserts upstream's `.base16Lab` default against the deliberate
  `.xterm` override carried since `galactic.4`. Confirmed identical on
  `v1.13.0-galactic.8` with this revision's patch stashed, so not a
  regression from it.
- Galactic smoke test on `v1.13.0-galactic.9`: (filled in after promote).

## v1.13.0-galactic.8 — upstream v1.13.0

Base: upstream at tag `v1.13.0`. Re-cut against the same upstream (no
version bump) to add the auto-follow intent and selection-freeze
correctness patches below.

### Patches added in this revision

- **Gesture-sourced follow intent (`Terminal.scrolledUpByUser`)** — a new
  flag distinct from `userScrolling`. `userScrolling` is written by both
  scroll gestures and selection, so a transient selection could strand it
  true while the viewport sat at the live bottom, silently disabling
  auto-follow. `scrolledUpByUser` is written ONLY by `scrollTo` — the funnel
  every wheel / knob / page scroll passes through — from the resulting
  position; selection and output never touch it. This gives recovery a
  single-writer intent signal to distinguish a genuine scroll-up from a
  stranded freeze.
- **`scrollTo` reconciles `scrolledUpByUser` ungated by selection**
  (`AppleTerminalView`) — reconciled on every scroll movement regardless of
  selection state, so scrolling back to the bottom during an active
  selection still clears follow intent. The adjacent `userScrolling`
  reconciliation is skipped during selection, which is what left the gate
  stranded.
- **`feedPrepare` recovery keys off `scrolledUpByUser`**
  (`AppleTerminalView`) — clears a stranded `userScrolling` whenever the
  user has not gesture-scrolled up, regardless of current scroll position.
  The prior guard required `yDisp >= yBase`, so once drift opened up it
  could never recover. Still gated on `!selection.active`, preserving the
  selection-freeze invariant.
- **`selectionChanged` freezes the viewport only on a non-empty selection**
  (`MacTerminalView`) — gates on `selection.active && selection.hasSelectionRange`.
  An empty soft-start selection (`start == end`, produced by a click with a
  hair of mouse movement) no longer freezes the viewport and disables
  auto-follow.
- **`mouseUp` clears an empty selection** (`MacTerminalView`) — a drag that
  ends with no range (`!hasSelectionRange`) clears `selection.active` on
  release. `mouseUp` otherwise never cleared it, so a stray micro-drag left
  `selection.active` stranded true and froze auto-follow until a later
  click.

### Verification

- `GITHUB_ACTIONS=true swift build` on the fork passes.
- Galactic smoke test on `v1.13.0-galactic.8`: Galactic `swift build` +
  `swift test` green against this tag.

## v1.13.0-galactic.7 — upstream v1.13.0

Base: upstream at tag `v1.13.0`. Re-cut against the same upstream (no
version bump) to add the caret patches below.

Note: `.5` and `.6` were prior re-cuts against this same upstream and did
not receive PATCHES entries — `.6` added the `scrollTo` reorder (sets
`userScrolling` before invalidating the view, closing the
following-but-drifted transient). `.7` carries everything `.6` had plus
the caret patches below.

### Patches added in this revision

- **Caret reposition on focus gain** — `becomeFirstResponder` and the
  `NSWindowDidBecomeMainNotification` handler now call
  `updateCursorPosition()` after restyling. Focus-gain alone restyled the
  caret (shape/blink) but never repositioned it, so a cursor that moved
  while the window was unfocused painted at a stale cell until the next
  output. Repositioning on focus eliminates that drift.
- **`repositionCaret()` public method** — public wrapper over the internal
  `updateCursorPosition()` on `AppleTerminalView`, so a Galactic subclass
  can force a caret reposition after it mutates the viewport (e.g. snapping
  to the live bottom on focus), where the internal display cycle would
  otherwise leave the caret frame stale until the next output.

### Verification

- `swift build` on the fork passes.
- Galactic smoke test on `v1.13.0-galactic.7`: (filled in Phase 2).

## v1.13.0-galactic.4 — upstream v1.13.0

Base: upstream `migueldeicaza/SwiftTerm` at tag `v1.13.0`.

Note: tags `v1.13.0-galactic.1`, `v1.13.0-galactic.2`, and
`v1.13.0-galactic.3` were created and abandoned during this bump's
development. `.1` shipped before the FillStroke / cell-width /
palette-strategy patches were final. `.2` was a tag-refresh that
worked around an SPM cache conflict but left `PATCHES.md` and
`MAINTAINING.md` outdated. `.3` corrected those docs but stored the
`MAINTAINING.md` updates in commit 4 instead of commit 1, breaking
the four-commit invariant where MAINTAINING.md lives in the orphan
root. `.4` is the first revision with proper commit-1 placement of
MAINTAINING.md and final patch content. SwiftPM's tag-to-commit
cache forbids retargeting a published tag in-place (see "Safety
rules" in `MAINTAINING.md`), so the revision is bumped each time
rather than the tag being re-pointed.

### Patches dropped relative to v1.10.1-galactic.1

Two patches retired because upstream independently fixed the same
bugs in the v1.10.1..v1.13.0 range:

- BlockElement boundary inclusion of U+2580 and U+259F — upstream
  fixed in PR #476 with the same `>=` / `<=` semantics, different
  syntax (single combined where-clause with `&&` vs. our two
  comma-separated where-clauses). Took upstream's version.
- `cmdRestoreCursor` Kitty-keyboard guard — upstream fixed in
  PR #500 with `guard collect.isEmpty` (equivalent to our
  `guard collect.count == 0`). Took upstream's version.

### Patches preserved (and how they integrated with upstream's changes)

- **Memory leak fix in `CircularList.trimStart` and
  `CircularBufferLineList.trimStart`** (nil out vacated slots).
  Verified upstream did NOT independently fix this in v1.13.0 —
  patch still needed. Auto-merged cleanly; only the GALACTIC PATCH
  comment block had a conflict.
- **`CircularBufferLineList` subscript visibility opens** combined
  with upstream's new `_read` accessor (Swift ownership-based read,
  performance improvement). Public modifier preserved; `_read`
  accepted.
- **FillStroke text thickening**, **`galacticBoldForegroundColor`**,
  **`galacticBold` attribute pipeline**, **sRGB color space**,
  **background CALayer sync on OSC 11** — all rendering patches
  preserved. Combined with upstream's `bgColor` pre-computation
  refactor in `getAttributes`.
- **`processSizeChange` yDisp re-pin** (Invariant 1: bottom-stick
  across reflow) — preserved.
- **`feedPrepare`** stuck-`userScrolling` recovery and
  **`linefeed`** selection-on-following-only — both preserved.
  Drop upstream's new `allowMouseReporting`-gated clears in favor
  of Galactic's stricter `userScrolling`-based gates (Invariant 2
  is finer-grained than mouse-reporting state).
- **`feedFinish` + `adjustForTrimmedLines`** — selection follows
  buffer trims. Preserved.
- **`scroll(toPosition:)`** no longer overrides `userScrolling`,
  **`scrollTo`** updates `userScrolling` based on resulting
  position guarded by `selection.active` — preserved. Upstream
  made `scrollTo` public; we kept that and added our docstring.
- **`selectionChanged`** freezes viewport while selection active
  (Invariant 2) — preserved.
- **`SelectionService.adjustForTrimmedLines`** new method —
  preserved.
- **`GalacticScroller`** class — layered into upstream's new
  Auto Layout scroller setup (was frame-based pre-v1.13.0).
  Custom scroller's transparent track + pill knob preserved.
- **Auto-hide scroller** (flash, schedule-hide, hold, release,
  tracking area) — preserved. Combined with upstream's new
  link-highlight cleanup in `mouseExited` (dingus).
- **Resize throttling** (~30fps coalesced during live drag) —
  preserved. Runs alongside upstream's new MetalKit redraw
  dispatch (the Metal renderer has its own per-frame throttle).
- **Mouse-drag autoscroll fixes** (raw unclamped screen row,
  autoscroll timer lifecycle, bottom-edge boost) — preserved.
  Combined with upstream's new dingus link detection in
  `mouseUp`: upstream's `linkForClick(at:hasCommandModifier:)`
  takes over from our older `getPayload`-based path. `open`
  visibility preserved for cross-module override.
- **Accumulated fractional `scrollWheel` delta** for smooth
  trackpad sub-line scrolling — preserved.
- **`scrollingTimerElapsed` direction fix** (`scrollDown` for
  positive delta, was `scrollUp`) — preserved.
- **`mouseUp`/`mouseDown`/`mouseDragged`** auto-scroll
  integration — preserved.
- **Visibility opens across `Buffer`, `CharData`, `CircularList`,
  `CircularBufferLineList`, `MacCaretView`, `SelectionService`,
  `Terminal`** — all preserved through auto-merge. Spot-checked
  post-merge.
- **`MacExtensions.NSColor.make`** uses sRGB instead of device
  RGB — preserved.
- **`CaretView.makeBackingLayer()` override visibility** — NEW
  fix introduced by this bump. Upstream added an
  `override func makeBackingLayer()` in v1.13.0 for cursor
  transparency support, but the override is at default
  (internal) access. Since Galactic's patch makes `CaretView`
  public, Swift requires the override to be at least public.
  Added `public` modifier to the override in this bump.
- **`TerminalOptions.default.ansi256PaletteStrategy = .xterm`** —
  NEW Galactic patch introduced by this bump. Upstream PR #519
  (commit 36642aa) added an `Ansi256PaletteStrategy` enum and
  defaulted new `TerminalOptions` to `.base16Lab`, which derives
  256-color palette entries by interpolating between the theme's
  base16 colors and bg/fg in LAB space. The result is visually
  muted, theme-cohesive colors — but it dims Claude's heavy use
  of 256-color codes for tool labels, gray separators, and SGR-2
  dim/faint text. Galactic flips the default back to `.xterm`
  (historical xterm-256 cube + grayscale ramp) so Claude's output
  renders with its intended bright fixed-RGB values. Mirrored in
  the `GalacticApiSmoke` test via `testAnsi256PaletteStrategyApi`
  so future bumps catch any API rename or removal at compile time.
- **Relocation of `resize(cols:rows:)` and `send(data:)` from
  AppleTerminalView extension to MacTerminalView class body**
  (marked `open` for cross-module override) — preserved.
  Upstream's new `changeScrollback(_:)` function kept in
  AppleTerminalView's extension where it lives.
- **Package.swift cosmetic SPM-compat tweaks** — dropped, no
  longer needed (upstream's Package.swift includes the
  `resources:` declaration for the Metal shader, which is the
  shape we need for the GPU backend).

### Verification

- `GITHUB_ACTIONS=true swift build` on the fork passes. The
  `GITHUB_ACTIONS=true` env var is upstream's mechanism for
  excluding the `package-benchmark` dependency, which requires
  jemalloc to be installed system-wide. Galactic is unaffected —
  it pulls in only the `SwiftTerm` product, which has no benchmark
  dependency at all.
- `swift test` results: <to be filled in after first run>
- Galactic smoke test on `v1.13.0-galactic.1`: passed (Galactic
  `swift build` + `swift test` green against this tag).

## v1.10.1-galactic.1 — upstream v1.10.1 (initial fork release)

Base: upstream `migueldeicaza/SwiftTerm` at tag `v1.10.1`.

### Patches included

Full patch from Galactic's prior in-tree consumer applied verbatim.
Patches included (categories, not exhaustive):

- Memory leak fix in `CircularList.trimStart` and
  `CircularBufferLineList.trimStart` (nil out vacated slots)
- `CircularList.maxLength` resize copies only live entries
- `Buffer.resize` iterates `lines.count` not `lines.maxLength`
- `cmdRestoreCursor` distinguishes `CSI u` (SCORC) from
  `CSI > Ps u` (Kitty keyboard)
- BlockElement boundary inclusive of U+2580 and U+259F
- FillStroke text thickening (rendering quality)
- `galacticBoldForegroundColor` for theme-driven bold rendering
- `galacticBold` attribute carried through to drawing pipeline
- sRGB color space in `NSColor.make` (P3 display correctness)
- Background CALayer sync on OSC 11
- `processSizeChange` re-pins `yDisp` to `yBase` if pre-reflow was
  live-following (Invariant 1)
- `feedPrepare` recovers from stuck `userScrolling`; only clears
  selection when following live output
- `feedFinish` plus `adjustForTrimmedLines` keeps selection pointing
  at the same buffer content as the circular buffer trims
- `linefeed` delegate only clears selection when following
- `scroll(toPosition:)` doesn't override `userScrolling`
- `scrollTo` updates `userScrolling` based on resulting position,
  guarded by `selection.active`
- `selectionChanged` freezes the viewport while selection active
  (Invariant 2)
- `selectionService.adjustForTrimmedLines` (new method)
- `GalacticScroller` class, auto-hide + tracking-area integration
- Resize throttling (~30fps coalesced during live drag)
- `mouseDragged` autoscroll velocity uses raw unclamped screen row;
  `mouseUp` stops timer; bottom-boost for edge geometry
- Accumulated fractional `scrollWheel` delta for smooth trackpad
  sub-line scrolling
- `scrollingTimerElapsed` direction fix (`scrollDown` was `scrollUp`)
- Various visibility opens (`internal` → `public`, `private(set)` →
  `public`) across `Buffer`, `CharData`, `CircularList`,
  `CircularBufferLineList`, `MacCaretView`, `SelectionService`,
  `Terminal` to support cross-module subclassing and chrome reads
- `MacExtensions.NSColor.make` uses sRGB instead of device RGB
- Package.swift formatting reverts (trailing-comma / parser-tolerant
  syntax disabled for older SPM parsers)

### Verification

- `swift build` on the fork passed.
- Galactic smoke test on `v1.10.1-galactic.1` passed (confirmed during
  Phase 1 of the Galactic extraction effort, 2026-05-17).
