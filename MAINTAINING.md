# Maintaining the Galaxy Fork of SwiftTerm

## Purpose

This repository is a personal fork of
[migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
with Galaxy/Galactic-specific customization patches applied on top. It
exists to:

- Let Galaxy.app consume SwiftTerm via Swift Package Manager instead of
  vendoring an in-tree copy
- Provide a consumable terminal-emulator dependency for the Galactic
  module (`kellyredding/Galactic`) and any other Swift apps in the
  `kellyredding/*` ecosystem
- Keep Galaxy's customization patches in one place where they can be
  managed across upstream version bumps

The fork tracks upstream tagged releases. It is NOT continuously rebased
against upstream `main` — bumps are deliberate operations triggered by a
specific upstream version we want to adopt.

## Repository invariants

- **`main` branch**: always at
  `<latest-upstream-tag> + galaxy-customization-commit`. Force-pushable
  during a bump, but ONLY after tagging the previous state (see Safety
  Rules).
- **Tags**:
  - `v<upstream-version>-galaxy.<rev>` for each Galaxy-patched release
    (e.g., `v1.10.1-galaxy.1`, `v1.13.0-galaxy.1`). `<rev>` increments
    if we re-cut a patched release against the same upstream version.
  - Upstream tags (`v1.10.1`, `v1.13.0`, etc.) preserved verbatim in
    this repo. They anchor diff analysis during bumps and let
    consumers verify the fork's upstream lineage.
- **`upstream` remote**: configured to point at
  `git@github.com:migueldeicaza/SwiftTerm.git`. Used to fetch new
  upstream releases.
- **Source of truth for patches**: the latest commit on `main`. There
  is no separate patches/ directory or patch-file convention — the
  commit IS the patch state.

## Setup (one-time, for a fresh clone)

```bash
git clone git@github.com:kellyredding/SwiftTerm.git
cd SwiftTerm
git remote add upstream git@github.com:migueldeicaza/SwiftTerm.git
git fetch upstream --tags
```

## The bump workflow

Inputs:
- Current fork state (e.g., `main` at `v1.10.1-galaxy.1`)
- Target upstream version (e.g., `v1.13.0`)

Outputs:
- `main` at `<target-upstream-tag> + galaxy-customization-commit`
- New tag `v<target>-galaxy.<rev>`
- Prior `v<previous>-galaxy.<rev>` tag preserved for rollback

### Step 1 — Preserve rollback

Tag the current `main` if the corresponding `v<current>-galaxy.<rev>`
tag does not already exist. This is the irrecoverable-history-loss
defense.

```bash
git tag v1.10.1-galaxy.1   # example — adjust to current state
git push origin v1.10.1-galaxy.1
```

### Step 2 — Fetch upstream

```bash
git fetch upstream --tags
```

### Step 3 — Inventory upstream changes

Read what's coming in before touching anything. Identify supersedes
and conflict areas.

```bash
git log --oneline v<current>..v<target>
git diff --stat v<current>..v<target> -- Package.swift \
    Sources/SwiftTerm/Apple/AppleTerminalView.swift \
    Sources/SwiftTerm/Buffer.swift \
    Sources/SwiftTerm/CharData.swift \
    Sources/SwiftTerm/CircularList.swift \
    Sources/SwiftTerm/Mac/MacCaretView.swift \
    Sources/SwiftTerm/Mac/MacExtensions.swift \
    Sources/SwiftTerm/Mac/MacTerminalView.swift \
    Sources/SwiftTerm/SelectionService.swift \
    Sources/SwiftTerm/Terminal.swift
```

The file list above is the current Galaxy patch surface. Update it as
the patch evolves.

Look specifically for commits whose subject matches a patch we carry —
those are candidates for dropping during conflict resolution. Examples
from the v1.10.1 → v1.13.0 bump: upstream `#476` superseded our
BlockElement boundary fix; upstream `#500` superseded our
`cmdRestoreCursor` Kitty guard.

### Step 4 — Build the bumped state on a branch

```bash
git checkout -b bump/v<target> v<target>
git cherry-pick <galaxy-patch-commit-sha>
```

The cherry-pick will conflict on files where upstream and our patches
overlap. Resolve hunk-by-hunk:

- **Conflict where upstream made the same fix**: take upstream's
  version, drop our hunk. Note the dropped patch in the patch history
  log (Step 8).
- **Conflict where upstream changed surrounding code but our hunk
  still makes sense**: rebase the hunk onto upstream's new line
  numbers. Verify our intent is preserved.
- **Conflict where upstream changed the semantics our patch relied
  on**: re-think the patch. The patch may need a different
  implementation against the new upstream. Or it may need to be
  dropped entirely if the underlying issue is gone.

After resolving:

```bash
git add -A
git cherry-pick --continue
# Or, if you want to amend the message:
# git commit --amend
```

### Step 5 — Verify the fork builds and tests

```bash
swift build
swift test
```

Document any test failures. Some may pre-date the bump (upstream's own
flaky tests). Capture which failures are NEW after our patches — those
are regressions we caused.

### Step 6 — Smoke test in Galaxy

The fork can build and pass `swift test` while still breaking Galaxy.
Galaxy's smoke-test checklist exercises the patched behavior:

1. `cd ~/projects/kellyredding/galaxy/GalaxyApp && xcodegen generate && make build` — must succeed.
2. Open a session — terminal renders normally.
3. Scroll up into scrollback and back down — auto-follow invariants
   hold.
4. Select text and Cmd+C — selection works.
5. Resize the window — terminal reflows correctly.
6. Change theme or default font size — bridge applies through the
   protocol.
7. Toggle the sidebar while a Claude session is streaming output —
   slide remains smooth.

To wire Galaxy at the bump branch temporarily for this smoke test,
either:
- Pre-Phase-3: regenerate the in-tree patch file from the bump branch
  state and run `setup-vendor.sh`.
- Post-Phase-3: point Galaxy's SPM dependency at the bump branch SHA
  via `project.yml`, regenerate, build.

If anything regresses, fix in the bump branch. Don't promote to `main`
until smoke test passes.

### Step 7 — Promote the bump to `main`

```bash
git checkout main
git reset --hard bump/v<target>
git tag v<target>-galaxy.1
git push -f origin main
git push origin v<target>
git push origin v<target>-galaxy.1
git branch -D bump/v<target>
```

The force-push is acceptable here because Step 1 tagged the previous
state. The previous `main` HEAD remains reachable via its galaxy tag.

### Step 8 — Update the patch history log

Append an entry to the "Patch history log" section of this file. List
any patches dropped because upstream superseded them, any new
mitigations the bump required, and any patches whose behavior changed
semantically.

### Step 9 — Update Galaxy's pinned version

Separate Galaxy commit, not part of this fork's bump.

- Pre-Phase-3: regenerate `GalaxyApp/scripts/galaxy-swiftterm-rendering.patch`
  from the new state, run setup-vendor, commit to Galaxy.
- Post-Phase-3: bump the version pin in Galaxy's `project.yml` from
  `v<previous>-galaxy.<rev>` to `v<target>-galaxy.1`, regenerate the
  Xcode project, commit to Galaxy.

## Safety rules

### NEVER force-push `main` without tagging the previous state first

Step 1 of the bump workflow exists to defend against this. The
previous `main` HEAD becomes irrecoverable after a force-push unless
something (a tag, a branch, a remote ref) is keeping it reachable.

### NEVER skip the Galaxy smoke test

A fork that compiles and passes `swift test` can still break Galaxy.
Our patches encode behavior that upstream tests don't cover (auto-
follow invariants, FillStroke rendering, custom scroller, etc.).

### NEVER auto-resolve a conflicting hunk without understanding what changed

Each hunk in our patch encodes an intent. Conflicts mean upstream
changed the code near or inside that hunk. Accept upstream's version
of a hunk we patched only when you can articulate why the intent of
our patch is now either preserved (upstream made an equivalent fix)
or obsolete (the underlying issue is gone). "It looks like upstream's
code makes sense" is not a sufficient reason.

### NEVER promote a bump branch to `main` without Step 6's smoke test passing

The fork's contract is "Galaxy works against this." Anything else
breaks that contract.

### NEVER add patches directly to `main` outside the bump workflow

If a new patch needs to be added (e.g., Galaxy hits a new SwiftTerm
issue mid-development), follow the same workflow:

1. Tag the current `v<current>-galaxy.<rev>` state.
2. Create a `bump/<current>-galaxy.<next>` branch (no upstream
   version change — just a re-cut against the same upstream).
3. Amend or extend the customization commit.
4. Verify build + smoke test.
5. Promote to `main`, tag `v<current>-galaxy.<next>`.

## Patch history log

Each entry documents the patch state at a tagged release. Include the
upstream base, the size of the Galaxy customization, and any patches
dropped relative to the previous tag.

### v1.10.1-galaxy.1 — initial fork release

Base: upstream v1.10.1.

Patch surface: full patch from
`GalaxyApp/scripts/galaxy-swiftterm-rendering.patch` applied verbatim.

Patches included (categories, not exhaustive):
- Memory leak fix in `CircularList.trimStart` and
  `CircularBufferLineList.trimStart` (nil out vacated slots)
- `CircularList.maxLength` resize copies only live entries
- `Buffer.resize` iterates `lines.count` not `lines.maxLength`
- `cmdRestoreCursor` distinguishes `CSI u` (SCORC) from
  `CSI > Ps u` (Kitty keyboard) — superseded upstream by `v1.13.0`
- BlockElement boundary inclusive of U+2580 and U+259F — superseded
  upstream by `v1.13.0`
- FillStroke text thickening (rendering quality)
- `galaxyBoldForegroundColor` for theme-driven bold rendering
- `galaxyBold` attribute carried through to drawing pipeline
- sRGB color space in `NSColor.make` (P3 display correctness)
- Background CALayer sync on OSC 11
- `processSizeChange` re-pins `yDisp` to `yBase` if pre-reflow was
  live-following (Invariant 1)
- `feedPrepare` recovers from stuck `userScrolling`; only clears
  selection when following live output
- `feedFinish` plus `adjustForTrimmedLines` keeps selection pointing
  at the same buffer content as the circular buffer trims
- `linefeed` delegate only clears selection when following — may be
  superseded by upstream `#471`-style work in `v1.13.0`
- `scroll(toPosition:)` doesn't override `userScrolling`
- `scrollTo` updates `userScrolling` based on resulting position,
  guarded by `selection.active`
- `selectionChanged` freezes the viewport while selection active
  (Invariant 2)
- `selectionService.adjustForTrimmedLines` (new method)
- `GalaxyScroller` class, auto-hide + tracking-area integration
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

Verification: `swift build` passes on the fork; Galaxy smoke test
passes on v1.10.1-galaxy.1 as confirmed during Phase 1 of the
Galactic extraction effort.
