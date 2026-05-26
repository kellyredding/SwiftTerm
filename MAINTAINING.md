# Maintaining the Galactic Fork of SwiftTerm

## Purpose

This repository is a personal fork of
[migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
with Galactic-specific customization patches applied on top. It exists to:

- Provide a SwiftPM-installable terminal-emulator dependency for
  [`kellyredding/Galactic`](https://github.com/kellyredding/Galactic)
- Keep Galactic's customization patches in one place where they can be
  managed across upstream version bumps

Galactic is the direct consumer of this fork; what Galactic does with
it (which apps it serves, how it surfaces the engine) is Galactic's
concern, not this fork's.

The fork tracks upstream tagged releases. It is NOT continuously rebased
against upstream `main` — bumps are deliberate operations triggered by a
specific upstream version we want to adopt.

## Repository invariants

- **`main` branch**: exactly three commits in fixed order, none of
  which come from upstream's lineage.
  1. **Orphan root**: MAINTAINING.md only. Truly stable across bumps —
     same SHA on every release.
  2. **Upstream import**: imports the targeted upstream SwiftTerm tag
     as a single tree-replace commit. Replaced each bump.
  3. **Galactic customization**: applies the Galactic patch on top, plus
     updates `PATCHES.md` with the release's entry. HEAD always points
     here; rewordable via `git commit --amend` during a bump.

  Force-pushable during a bump, but ONLY after tagging the previous
  state (see Safety Rules). Upstream's fine-grained commit history is
  intentionally not part of `main`'s lineage — it's accessible via the
  preserved upstream tags (`git checkout v1.13.0` reaches upstream's
  full history at that release).
- **Tags**:
  - `v<upstream-version>-galactic.<rev>` for each Galactic-patched release
    (e.g., `v1.10.1-galactic.1`, `v1.13.0-galactic.1`). `<rev>` increments
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
- Current fork state (e.g., `main` at `v1.10.1-galactic.1`)
- Target upstream version (e.g., `v1.13.0`)

Outputs:
- `main` at `<target-upstream-tag> + galactic-customization-commit`
- New tag `v<target>-galactic.<rev>`
- Prior `v<previous>-galactic.<rev>` tag preserved for rollback

### Step 1 — Preserve rollback

Tag the current `main` if the corresponding `v<current>-galactic.<rev>`
tag does not already exist. This is the irrecoverable-history-loss
defense.

```bash
git tag v1.10.1-galactic.1   # example — adjust to current state
git push origin v1.10.1-galactic.1
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

The file list above is the current Galactic patch surface. Update it as
the patch evolves.

Look specifically for commits whose subject matches a patch we carry —
those are candidates for dropping during conflict resolution. Examples
from the v1.10.1 → v1.13.0 bump: upstream `#476` superseded our
BlockElement boundary fix; upstream `#500` superseded our
`cmdRestoreCursor` Kitty guard.

### Step 4 — Build the bumped state on a branch

The bump rebuilds commits 2 and 3 on top of commit 1 (the orphan
MAINTAINING.md root). Three sub-steps:

#### 4a — Branch off commit 1

```bash
# Commit 1 is the orphan root — same SHA on every release.
COMMIT_1=$(git rev-list --max-parents=0 main)
git checkout -b bump/v<target> $COMMIT_1
```

#### 4b — Build commit 2 (upstream import)

Replace the working tree with the new upstream tag's content while
preserving MAINTAINING.md:

```bash
# Snapshot MAINTAINING.md (read-tree --reset wipes it)
cp MAINTAINING.md /tmp/maint.bak

# Replace tree with upstream's
git read-tree --reset -u v<target>

# Restore MAINTAINING.md
cp /tmp/maint.bak MAINTAINING.md
git add MAINTAINING.md

# Commit
git commit -m "Import SwiftTerm v<target> from upstream"
```

#### 4c — Build commit 3 (Galactic customization patch)

Extract the previous bump's patch and apply it with 3-way merge:

```bash
# Get the patch from the previous galactic commit. Commit 3 of the prior
# bump IS the patch — its diff against its parent is the customization.
git format-patch --stdout v<previous>-galactic.<rev>~1..v<previous>-galactic.<rev> > /tmp/galactic.patch

# Apply with 3-way merge for graceful context shifts
git apply --3way /tmp/galactic.patch
```

The apply will conflict on files where upstream and our patches
overlap. Resolve hunk-by-hunk:

- **Conflict where upstream made the same fix**: take upstream's
  version, drop our hunk. Note the dropped patch in `PATCHES.md`
  below.
- **Conflict where upstream changed surrounding code but our hunk
  still makes sense**: rebase the hunk onto upstream's new line
  numbers. Verify our intent is preserved.
- **Conflict where upstream changed the semantics our patch relied
  on**: re-think the patch. The patch may need a different
  implementation against the new upstream, or be dropped entirely if
  the underlying issue is gone.

**Then update `PATCHES.md` _before_ committing.** Append a new entry
whose heading uses the target tag name (`## v<target>-galactic.<rev>
— upstream v<target>`). Document any patches dropped, any new
mitigations introduced this bump, and any preserved patches whose
integration with upstream's changes required substantive rework.

`PATCHES.md` lives _in this commit_ because the heading binds the
patch state to the tag we are about to create. Updating it later
(Step 8 or beyond) would require either re-committing this commit
or adding a follow-up commit, both of which break the four-commit
invariant and force re-tagging — which the SPM-tag-immutability
rule (Safety rules) forbids.

Once `PATCHES.md` is updated, commit:

```bash
git add -A
git commit -m "Apply Galactic customization patch on top of v<target>"
```

### Step 5 — Verify the fork builds and tests

```bash
swift build
swift test
```

Document any test failures. Some may pre-date the bump (upstream's own
flaky tests). Capture which failures are NEW after our patches — those
are regressions we caused.

### Step 6 — Verify Galactic builds against the bump

The fork can build and pass `swift test` while still breaking behavior
that Galactic relies on. Point Galactic's SwiftTerm pin at the bump
branch and verify:

```bash
cd ~/projects/kellyredding/Galactic
# Edit Package.swift to point SwiftTerm at the bump branch
# (e.g., `.branch("bump/v<target>")` or a specific commit SHA)
swift build
swift test
```

Galactic's package tests are a minimal public-surface smoke check —
they catch missing-public-surface and obvious-API regressions but
cannot exercise rendering behavior, auto-follow invariants, focus
handling, or scroll inertia. Those behaviors require a chrome-hosting
consumer of Galactic, and that verification belongs in Galactic's
[MAINTAINING.md](https://github.com/kellyredding/Galactic/blob/main/MAINTAINING.md) —
performed by Galactic's maintainer before Galactic itself cuts a new
release tag.

If Galactic's `swift build` or `swift test` regresses against the
bump branch, fix here on the bump branch. Don't promote to `main`
until Galactic compiles and its package tests pass.

### Step 7 — Promote the bump to `main`

```bash
git checkout main
git reset --hard bump/v<target>
git tag v<target>-galactic.1
git push -f origin main
git push origin v<target>
git push origin v<target>-galactic.1
git branch -D bump/v<target>
```

The force-push is acceptable here because Step 1 tagged the previous
state. The previous `main` HEAD remains reachable via its galactic tag.

### Step 8 — Update Galactic's pinned version

Separate Galactic commit, not part of this fork's bump.

Bump the SwiftTerm pin in Galactic's `Package.swift` from
`v<previous>-galactic.<rev>` to the freshly-tagged `v<target>-galactic.1`,
run `swift build && swift test`, commit on Galactic's `main`, then cut a
new Galactic release tag. From there Galactic's downstream consumers
adopt the new Galactic release on their own cadence — that handoff is
documented in Galactic's
[MAINTAINING.md](https://github.com/kellyredding/Galactic/blob/main/MAINTAINING.md).

## Safety rules

### NEVER force-push `main` without tagging the previous state first

Step 1 of the bump workflow exists to defend against this. The
previous `main` HEAD becomes irrecoverable after a force-push unless
something (a tag, a branch, a remote ref) is keeping it reachable.

### NEVER skip the Galactic smoke test

A fork that compiles and passes `swift test` can still break Galactic.
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

The fork's contract is "Galactic works against this." Anything else
breaks that contract.

### NEVER re-point a published `v<target>-galactic.<rev>` tag

Once a Galactic release tag has been pushed and consumed by any
downstream (Galactic, a teammate's checkout, even your own SPM
cache), it is **immutable**. SwiftPM records `(URL, version) →
revision` in its manifest cache. If a re-tag changes that mapping,
every consumer fails resolution with `Revision X for swiftterm
version Y does not match previously recorded value Z` until each
SPM cache is wiped.

If a forgotten doc update, typo in `PATCHES.md`, or any other
post-tag change to commit 4 needs to ship, **bump the revision
number** (`v<target>-galactic.<rev+1>`) and re-do the promote
+ tag dance on the new revision. Then delete the old tag if it
never went out — or, if it did, leave it in place and document
the supersede in `PATCHES.md`.

This is why Step 4c folds `PATCHES.md` into commit 4 before the
tag exists: all doc state must be final at tag-creation time.

### NEVER add patches directly to `main` outside the bump workflow

If a new patch needs to be added (e.g., Galactic hits a new SwiftTerm
issue mid-development), follow the same workflow:

1. Tag the current `v<current>-galactic.<rev>` state.
2. Create a `bump/<current>-galactic.<next>` branch (no upstream
   version change — just a re-cut against the same upstream).
3. Amend or extend the customization commit.
4. Verify build + smoke test.
5. Promote to `main`, tag `v<current>-galactic.<next>`.

## Patch history

Per-release patch state lives in `PATCHES.md` at the repo root.
That file is part of commit 3 (the customization commit) and gains
a new entry on every bump. Each entry documents the upstream base,
which patches were dropped (because upstream independently fixed
the same bug), and what verification the release passed.

Commit 1 (this MAINTAINING.md) intentionally does NOT carry release
metadata so its tree stays stable across bumps.
