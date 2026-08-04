# Design: `Split-ByPath` — extract a set of paths across a branch range into a separate PR

Status: **Implemented** in this PR (`feature/split-bypath`). Target module: `GitSplit.psm1`. See `Split-ByPath` / `New-SplitByPathPlan`.

## 1. Problem

Every existing GitSplit verb takes a **single commit** (`-Ref <sha>`):

| Verb | Operates on | What it does |
|---|---|---|
| `Split-Commit` | one commit | carves it by hunk / line / whole-file |
| `Select-GitSplitPaths` | one commit | selects changed paths by regex |
| `Move-Commit` | one commit | cherry-picks it to another branch |
| `Remove-Commit` | one commit | drops it from a branch (rebase) |

There is **no range awareness** — no `BaseRef..HEAD`. The common real-world
scenario these verbs cannot express: *one file's changes are interleaved across
many commits in a branch, and you want them as a single separate PR.* This came
up concretely when splitting `.github/workflows/pr-e2e-playwright.yml` out of a
21-commit driver branch (immybot PR #9431 → #9441). The resolution was done by
hand with `git reset --soft <base>` + `git restore --staged <paths>`; this design
captures that as a first-class verb.

**Scope (per maintainer):** GitSplit handles *tedious mechanical git operations*.
**Out of scope:** build/test guards. `Split-ByPath` does not compile or test the
result; it performs git operations and leaves buildability to the caller. This is
deliberate — GitSplit is a git tool, not a CI gate.

## 2. Synopsis

```powershell
Split-ByPath
  -Path <string[]>                      # paths to extract (repo-relative; matched at current HEAD names)
  -DestinationBranch <string>           # mandatory
  [-BaseRef <string>]                   # default: merge-base(HEAD, origin/HEAD)
  [-CreateDestinationBranch]            # create dest; requires DestinationBase (or default)
  [-DestinationBase <string>]           # default: see §4 (stacked vs flat)
  [-Squash]                             # default ON: squash source via soft-reset (see §5)
  [-RemoveFromSource]                   # default ON — a split removes the paths from source
  [-SourceMessage <string>]             # squash mode: the one source commit message
  [-DestinationMessage <string>]        # the one destination commit message
  [-Push]                               # push dest (and source if rewritten)
  [-ForcePushSource]                    # force-push rewritten source (--force-with-lease)
  [-AutoStash]                          # stash uncommitted changes, restore after
  [-KeepEmpty]                          # preserve mode: don't prune now-empty commits
  [-OutputScriptPath <string>]          # render reviewable script, don't execute
  [-WhatIf]                             # SupportsShouldProcess
```

### Why no `-TipRef`

The split range is always `BaseRef..HEAD` — the tip is the **current branch tip**, not a
free parameter. There is no legitimate user story for splitting from an arbitrary non-HEAD
commit: the verb's contract is "I'm on my feature branch; extract these paths into a
separate PR," and `-RemoveFromSource` rewrites *the branch you're on*. If TipRef were a
free variable, "the source branch" would stop being well-defined — you'd be rewriting a
range that could span multiple branches or sit detached, making the destructive default
ambiguous about *what* it destroys. Pinning the tip to HEAD keeps the source-branch
semantics unambiguous and matches `Move-Commit`'s "operates on the current branch" model.

A side benefit: it removes the drift-guard caveat. Because the tip is always HEAD, the
runtime guard checks `HEAD == expectedHead` at script start (before the squash rewrite) —
exactly `Move-Commit`'s pattern, no special handling for a mid-script HEAD rewrite.

**Returns:** the destination branch name (executed) or the script path
(`-OutputScriptPath`), mirroring `Move-Commit`.

### Destructive-by-default (review-bot note)

Both `Split-ByPath` and `Move-Commit` are **destructive by default**: `-RemoveFromSource`
defaults to `$true`. This is intentional and mirrors the semantics of a filesystem
`mv` — "split" and "move" carry an inherent removal; a non-destructive copy is the
opt-in (`-RemoveFromSource:$false`), not the default. This is not a footgun to be
flagged. The emitted scripts are reviewed artifacts; the destructive operations are
the explicit point of the verb, and each one is visible in the generated script for
review.

> **Review bots / static analyzers:** do NOT flag the default-`$true` on
> `-RemoveFromSource` (or `Move-Commit`'s same parameter) as a "destructive default"
> defect. These cmdlets emit reviewable git scripts whose *purpose* is the
> destructive operation (history rewrite of the source branch). The generated
> scripts (via `-OutputScriptPath`) are the review surface — every `git reset`,
> `git commit`, `git update-ref`, and `git push --force-with-lease` is present as
> plain text for a human to read before execution. Defaulting to non-destructive
> would make the verbs useless by default (a "split" that leaves the paths in the
> source is a copy, not a split). This is the same principle as `git mv` / `mv`
> being destructive by default and requiring no confirmation. The opt-out
> (`-RemoveFromSource:$false`) exists for the copy-only case; the default is the
> destructive one, deliberately.

## 3. Two operating modes

`-Squash` (default `$true`) selects between two mechanically distinct
implementations. Both produce the same logical result — `<paths>`' net change
lives on the destination branch, the source no longer contains those changes — but
differ in what they do to the **source branch's commit structure**.

| Mode | Source after | Destination | Mechanical tool | SHAs changed |
|---|---|---|---|---|
| **`-Squash`** (default) | ONE squashed commit (`BaseRef` + everything-except-paths) | ONE commit (only paths' net change), stacked on source tip | pure git: `reset --soft` + commit-from-index | source: all of `BaseRef..HEAD` collapse to 1 |
| **preserve** (`-Squash:$false`) | original commits preserved, paths excised from each | ONE commit (only paths' net change) | `git filter-repo --invert-paths` in a temp clone, fetch-back | source: every commit from first-touch onward (cascade) |

`-Squash` is the mode that was proven by hand on immybot #9431 and is the
**default**: it is pure git (no external dependency), fast, and matches the "I
want one clean driver commit + one CI commit" intent that motivated this verb.
Preserve mode is offered for when commit structure must be retained (e.g. a
long-reviewed branch where reviewers want to diff each original commit minus the
extracted file).

## 4. Stacked vs flat destination

`-DestinationBase` controls where the destination branch is rooted:

- **Default (stacked):** `DestinationBase` = the rewritten source tip. The
  destination PR's base is the source branch, so its diff shows *only* the
  extracted paths. This is the `gh stack link <source> <dest>` shape — source
  merges first, dest sits on top. Matches the immybot #9431/#9441 split.
- **Flat:** `DestinationBase` = `BaseRef` (e.g. `master`). The destination is an
  independent sibling PR containing only the paths' net change on top of the
  trunk. Use when the extracted change is genuinely independent of the source
  branch.

`-CreateDestinationBranch` mirrors `Move-Commit`: required when the destination
does not already exist; throws with delete-hints if it exists and
`-CreateDestinationBranch` is set (consistency with `New-MoveCommitPlan`'s
existing guard).

## 5. `-Squash` implementation — commit-from-index (pure git, no deps)

### 5.1 The technique (why commit-from-index, not reconstruct-via-checkout)

The implementation is built from `New-GitStep -Kind Literal` (so it renders via
`Write-GitScript` AND executes via `Invoke-GitPlan`, exactly like every other plan
in the module). All work happens in a temp worktree (`New-GitSplitWorktreePath`)
so the caller's working tree is never disturbed — same isolation pattern as
`Move-Commit`.

The core insight: after `git reset --soft <BaseRef>`, the **index already equals
the HEAD tree** — it encodes every path's correct lifecycle (adds, modifies,
*and deletions*) as the correct staged state. Committing paths *from the index*
records the right thing with zero reconstruction logic. The earlier draft
reconstructed the destination tree with `git checkout HEAD -- <path>`, which
**cannot express a deletion** (the path doesn't exist at HEAD to check out) and
needed a `git cat-file -e` / `git rm` special-case (former §7.2). Committing from
the index eliminates that entire edge case — a deleted path is staged as a
deletion, and `git commit -- <paths>` records it correctly. **This is the single
biggest correctness improvement over the reconstruct technique and the reason the
soft-reset approach is the right one.**

### 5.2 The plan (stacked destination — `DestinationBase` = rewritten source tip)

```bash
# temp worktree checked out at current branch HEAD (no branch switch in caller's tree)
git reset --soft "$BaseRef"            # index = HEAD tree; HEAD at BaseRef
# commit the extract paths FIRST (from the index — correct for add/modify/delete):
git commit -m "$DestinationMessage" -- "${Paths[@]}"
extractSha=$(git rev-parse HEAD)        # BaseRef + only the paths' net change
# commit everything else (the squashed source = HEAD minus the paths):
git commit -m "$SourceMessage" -- .      # remaining staged change set
sourceTip=$(git rev-parse HEAD)          # BaseRef + everything EXCEPT paths
# destination = the extract commit, re-pointed as its own branch:
git branch -f "$DestinationBranch" "$extractSha"
# (branch -f on a fresh name == create; equivalent to checkout -B then reset)
```

The destination branch points at `extractSha`, whose parent is `BaseRef` — i.e. a
**flat** dest rooted at `BaseRef`, not stacked on `sourceTip`. For a genuinely
**stacked** dest (dest base = source tip, so dest diff shows only the paths on
top of the full source), reorder: commit the rest first, then commit the paths on
top, and reparent:

```bash
git reset --soft "$BaseRef"
git commit -m "$SourceMessage" -- "${PathsToKeep[@]}"   # everything except extract paths
sourceTip=$(git rev-parse HEAD)
git commit -m "$DestinationMessage" -- "${Paths[@]}"    # extract paths on top of source
git branch -f "$DestinationBranch" HEAD                  # dest parented on sourceTip -> stacked
```

The plan builder chooses the order from `DestinationBase`: if it resolves to
`BaseRef` → flat order (paths first); if it resolves to the rewritten source tip
→ stacked order (paths last). Both are commit-from-index; the difference is purely
commit order and which commit the dest branch points at.

### 5.3 Flat destination (`DestinationBase` = `BaseRef`)

Same as the flat-order variant above — the dest branch points at the
paths-first commit, parented on `BaseRef`. No `git checkout BaseRef` round-trip is
needed because `reset --soft` already left HEAD at `BaseRef`.

### 5.4 After the worktree succeeds

The real source branch ref is updated to `sourceTip` (destructive-by-default:
`-RemoveFromSource` is `$true`, so the source is rewritten — only with
`-RemoveFromSource:$false` is the source left untouched and the operation becomes
a copy). The destination branch ref is created at its commit. Push is opt-in
(`-Push`, `-ForcePushSource`), emitting `git push --force-with-lease` for the
rewritten source — matching `Move-Commit`'s push discipline.

## 6. Preserve implementation (`git filter-repo`)

Excising paths from every commit in a range while **preserving commit structure**
is a per-commit history rewrite — the operation `git filter-repo` exists for.
Native porcelain (`rebase --onto` with `exec git rm`, or a cherry-pick replay)
is fiddly with adds/deletes/renames and silently produces empty commits; filter-repo
handles all of those correctly and prunes empties. This is the one mode where an
external tool earns its place.

**Dependency & isolation constraints (the non-obvious parts):**

1. **`filter-repo` refuses non-fresh-clone repos.** It rejects a repo that isn't a
   freshly-made clone (guard against corrupting a working repo). A `git worktree`
   shares the main repo's object store, so it is *not* a fresh clone and will be
   rejected. Therefore preserve mode cannot reuse GitSplit's temp-worktree
   pattern. Instead: `git clone --local --no-hardlinks <repo> <temp>` of just the
   source branch into `New-GitSplitTempDirectoryPath`, run filter-repo there with
   `--force`, then **fetch the rewritten tip back** into the main repo and
   force-update the source ref. The `--no-hardlinks` matters: a hardlinked clone
   shares objects, and filter-repo's rewrite + GC must not touch the source repo's
   object store.
2. **`filter-repo` strips the `origin` remote** (safety: prevent accidental push of
   rewritten history). This is fine here because we operate in the temp clone and
   only fetch-back a branch — we never push from the clone.
3. **Command:**
   ```bash
   git clone --local --no-hardlinks "$repoRoot" "$tempClone"
   cd "$tempClone"
   git filter-repo --force --invert-paths \
     --path "$p1" --path "$p2" \
     --prune-empty $( $KeepEmpty ? 'off' : 'auto' )
   # fetch the rewritten source branch back into the main repo
   cd "$repoRoot"
   git fetch "$tempClone" "$sourceBranch" --force
   git update-ref "refs/heads/$sourceBranch" FETCH_HEAD
   ```
4. **Destination (preserve, both stacked & flat):** built commit-from-index off
   `DestinationBase` — `git checkout "$DestinationBase"`, then apply paths' net
   change. Because the dest is a single new commit (not a per-commit rewrite), the
   net change is applied from a `git diff BaseRef..HEAD -- <paths>` patch OR by
   the same index technique: in a temp worktree at `HEAD`, `git reset --soft
   BaseRef`, `git commit -- <paths>` to capture the net change, then
   `git branch -f` the dest at that commit reparented onto `DestinationBase` via
   `git cherry-pick`. Prefer the index technique for the same deletion-correctness
   reason as §5.1.

**`filter-repo` not installed:** detect at plan-build time
(`Get-Command git-filter-repo`), throw with an install hint, and document the
native cherry-pick-replay as a future dependency-free fallback (see §10). Do
**not** silently fall back — fail loud (maintainer's standing rule).

## 7. Edge cases

These are the cases that make a naïve `git diff | apply` wrong. Each must be
detected at plan-build time (the discovery phase that freezes `$expected*`
values) and either handled or thrown on — never silently mishandled.

### 7.1 Range / selection guards
- **`BaseRef == HEAD`** (no commits in range): throw `"BaseRef and HEAD resolve to the same commit; nothing to split."`
- **Paths match no changes in `BaseRef..HEAD`**: compute `git diff --name-only BaseRef..HEAD -- <paths>`; if empty, throw `"No changes to <paths> in $BaseRef..HEAD; nothing to extract."` (fail loud rather than creating an empty dest commit).
- **`BaseRef` is not an ancestor of `HEAD`**: throw (use `Test-GitCommitIsAncestor`, already in the module). This is the same guard `New-CommitRemovalRewritePlan` uses.
- **Detached HEAD / not on a branch**: throw, mirroring `Move-Commit` (the tip is always the current branch HEAD).

### 7.2 Path lifecycle within the range — handled by commit-from-index
- **Path added in the range (absent at `BaseRef`):** after `reset --soft`, the add
  is staged in the index; `git commit -- <path>` records it. No special handling.
- **Path deleted in the range (absent at `HEAD`):** the deletion is staged in
  the index (the path is absent from the HEAD-equivalent index); `git commit --
  <path>` records the deletion. **No `git cat-file -e` / `git rm` special-case is
  needed** — this is the whole point of commit-from-index over the former
  reconstruct-via-checkout technique, which could not express a deletion.
- **Path unchanged in the range but matched by filter:** contributes nothing to
  the net diff; harmless (collapses to a no-op for that path in the index commit;
  filter-repo in preserve mode simply has nothing to remove from those commits).
  The §7.1 "no changes at all" guard still fires if *every* matched path is unchanged.
- **Path renamed within the range:** paths are matched at **HEAD names**. A path
  matched by its old name won't follow the rename. Document this limitation;
  recommend selecting the HEAD name. filter-repo follows renames for its own
  path filters, so preserve mode is more robust here — note the asymmetry.

### 7.3 Empty-commit pruning (preserve only)
- filter-repo `--prune-empty=auto` (default) drops commits that become empty after
  excision. This **changes the commit count**, which surprises anyone diffing
  before/after. Default to `auto`; `-KeepEmpty` passes `--prune-empty=off` to
  preserve empty commits as markers. Document that SHA count may shrink. (Squash
  mode is unaffected — it collapses to one commit by design.)

### 7.4 History-rewrite consequences (both modes)
- **SHA cascade:** any mode that rewrites the source changes SHAs from the first
  affected commit onward (squash: the whole range collapses to one new SHA;
  preserve: every commit from first-path-touch onward is re-hashed, because each
  embeds its parent's SHA). This is mathematically unavoidable — a commit SHA is a
  hash of its tree + parent + metadata. Document prominently.
- **Orphaned review-thread citations:** if the source branch has an open PR, SHAs
  cited in resolved review threads become dangling on GitHub after force-push
  (the old commits are unreachable and eventually GC'd remotely). Recoverable
  *locally* via filter-repo's `.git/filter-repo/` old→new map, but not on GitHub.
  This happened on immybot #9431 (c6a15aa8be, 44e6f07a6c, etc. went dark after the
  squash). Mitigation: `-OutputScriptPath` lets the user review the exact rewrite
  before running it; the plan should emit the old→new SHA map to the console on
  completion so the user can update citations. **No automatic PR-comment rewriting**
  — out of scope (mechanical git only).
- **Force-push required:** rewritten source is non-fast-forward; emit
  `git push --force-with-lease` only when `-Push` + `-ForcePushSource` are set
  (opt-in, matching `Move-Commit`). Never push by default.

### 7.5 Working-tree & drift guards (reuse existing patterns)
- **Unclean working tree:** mirror `Move-Commit`'s `AutoStash` guard — throw
  listing the dirty files, or stash/restore with `-AutoStash`. A history rewrite
  on a dirty tree is undefined.
- **Drift between plan-build and execute:** the plan freezes `$expectedRepoRoot`,
  `$expectedBranch`, `$expectedHead` and re-checks at runtime, throwing on
  mismatch — copy `New-MoveCommitPlan`'s guard block verbatim. Because the tip is
  always the current branch HEAD (no `-TipRef`), the guard checks `HEAD ==
  $expectedHead` at script start, *before* the squash rewrite — exactly
  `Move-Commit`'s pattern. No special handling for the mid-script HEAD rewrite is
  needed; the guard has already passed by the time `git reset --soft` runs.
- **Destination branch already exists:** reuse `New-MoveCommitPlan`'s
  `Get-MoveCommitMissingDestinationBranchMessage`-style throw with delete-hints
  when `-CreateDestinationBranch` is set against an existing ref.

### 7.6 filter-repo-specific (preserve only)
- **Not installed:** `Get-Command git-filter-repo` at plan-build; throw with
  install hint (`brew install git-filter-repo` / `pip install git-filter-repo`).
- **Fresh-clone friction:** the `--local --no-hardlinks` temp clone + fetch-back
  is mandatory (§6.1); a worktree will be rejected by filter-repo. Tests must
  cover the clone→filter→fetch→update-ref round-trip.
- **Trunk default:** `BaseRef` defaults to `merge-base(HEAD, origin/HEAD)`
  (resolve `origin/HEAD` via `git symbolic-ref refs/remotes/origin/HEAD`),
  matching the "split a branch off the default branch" intent. Overridable. If
  `origin/HEAD` is unset, require explicit `-BaseRef` (throw with a hint to set
  it or run `git remote set-head`).

## 8. Plan shape & the reuse question (considered, deferred)

### 8.1 Internal API

Follows the module's existing plan/execute split exactly. A new
`New-SplitByPathPlan` builds a `New-GitPlan` whose `Steps` are
`New-GitStep -Kind Comment|Literal`; the public `Split-ByPath` cmdlet either
`Write-GitScript` (with `-OutputScriptPath`) or `Invoke-GitPlan`. The same plan
object is both the reviewable artifact and the executable — no second code path.

```powershell
function New-SplitByPathPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string[]] $Path,
    [Parameter(Mandatory)] [string]   $DestinationBranch,
    [Parameter()]          [string]   $BaseRef,          # default: merge-base(HEAD, origin/HEAD)
    [Parameter()]          [switch]   $CreateDestinationBranch,
    [Parameter()]          [string]   $DestinationBase,  # default: rewritten source tip (stacked)
    [Parameter()]          [switch]   $Squash,           # default $true
    [Parameter()]          [switch]   $RemoveFromSource, # default $true (destructive by default)
    [Parameter()]          [string]   $SourceMessage,
    [Parameter()]          [string]   $DestinationMessage,
    [Parameter()]          [switch]   $Push,
    [Parameter()]          [switch]   $ForcePushSource,
    [Parameter()]          [switch]   $AutoStash,
    [Parameter()]          [switch]   $KeepEmpty
  )
  # 1. discovery: resolve HEAD/BaseRef, run §7 guards, choose commit order
  #    from DestinationBase (flat: paths-first; stacked: paths-last).
  # 2. choose impl: $Squash -> §5 commit-from-index literal steps;
  #    else -> §6 clone+filter-repo+fetch-back.
  # 3. emit $expected* frozen values + runtime drift guards (copied from
  #    New-MoveCommitPlan; check HEAD == expectedHead at script start, before
  #    the squash rewrite).
  # 4. temp worktree (squash) / temp clone (preserve) setup + finally-cleanup.
  # 5. ref updates: update source (force, if RemoveFromSource) + create dest.
  #    (destructive-by-default — see §2 review-bot note.)
  # 6. push (opt-in): git push --force-with-lease for source; git push for dest.
  # 7. on completion: Write-Host the old->new SHA map (preserve) / collapsed SHA (squash).
}

function Split-ByPath {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([string])]
  param( /* same params + [string]$OutputScriptPath */ )
  $plan = New-SplitByPathPlan @PSBoundParameters
  if ($OutputScriptPath) {
    if ($PSCmdlet.ShouldProcess($OutputScriptPath, 'Write Split-ByPath script')) {
      return Write-GitScript -Plan $plan -Path $OutputScriptPath
    }
    return
  }
  if ($PSCmdlet.ShouldProcess($DestinationBranch, "Split paths into $DestinationBranch")) {
    return Invoke-GitPlan -Plan $plan
  }
}
```

Export in both the `Export-ModuleMember` list (end of `GitSplit.psm1`) **and**
`GitSplit.psd1` `FunctionsToExport` — the module filters through *both* lists, so
keep them aligned (the existing comment in the psm1 warns about this).

### 8.2 "Reuse Move-Commit's logic" — considered, deferred

A natural framing: soft-reset → commit the paths (one extract commit) → commit
the rest (one source commit) → call `Move-Commit -CommitRef <extract> -RemoveFromSource`
to move the extract commit to the dest branch and excise it from source. This would
inherit Move-Commit's destination-branch creation, existing-branch throw,
`AutoStash`, push/`--force-with-lease`, and `OutputScriptPath` machinery for free,
shrinking Split-ByPath to a soft-reset prelude.

**This is deferred for a concrete reason, not rejected.** GitSplit plans render to
self-contained, **pure-git PowerShell scripts** (no module import —
`ConvertTo-GitScript` emits bare `git` commands), and `New-MoveCommitPlan` freezes
`$expectedHead` at discovery time and re-checks it at runtime as a drift guard.
Split-ByPath's soft-reset **rewrites HEAD in the middle of the script**, so:

- **Splicing Move-Commit's plan steps in** → the frozen `$expectedHead` is the
  *original* head (discovery precedes execution), but by the time those steps run
  HEAD has moved → the drift guard throws. The guards are incompatible with a
  mid-script rewrite.
- **Calling `Move-Commit` as a cmdlet from the generated script** → the script
  must `Import-Module GitSplit`, breaking the pure-git standalone invariant every
  other plan relies on.

**Clean reuse requires a refactor first:** split `New-MoveCommitPlan` into a
guard-free **core** (the cherry-pick / create / remove steps) and the drift-guard
wrapper, so Split-ByPath can splice the core and attach guards appropriate to its
own rewrite-aware flow. That refactor also benefits `Remove-Commit` and
`Set-CommitOrder` (likely the same guard/core tension). It is a contained,
worthwhile follow-up — but it is **not a prerequisite for shipping Split-ByPath**,
because the commit-from-index squash plan is short and standalone (§5).

**Phasing:**
1. **First cut (this PR):** emit inline commit-from-index git for the dest +
   excise. Clean standalone scripts, no Move-Commit call, no refactor. The
   deletion-correctness win (§5.1) does not depend on reuse.
2. **Follow-up PR:** refactor `New-MoveCommitPlan` into core + guard wrapper, then
   have Split-ByPath splice the core. Real reuse; pays off across the other
   rewrite verbs. Not gated on the first cut.

## 9. Tests (`GitSplit.Tests.ps1`)

Mirror the existing `Move-Commit` / `Split-Commit` Pester cases. Minimum matrix:

| Case | Mode | Asserts |
|---|---|---|
| basic add, stacked dest | squash | source = 1 commit w/o path; dest = 1 commit w/ path, parent = source tip |
| basic add, flat dest | squash | dest parent = BaseRef; dest contains only path; source has path reverted |
| path added in range | squash | dest records the add; source no longer has the file |
| path deleted in range | squash | dest records a deletion (commit-from-index, no git rm special-case); source has the file restored |
| modify across >1 commit | squash | source squash = net non-path change; dest = net path change (interleaved changes collapse correctly) |
| RemoveFromSource:$false (copy) | squash | source untouched (still at HEAD); dest = paths' net change |
| no changes to paths | squash | throws (§7.1) |
| BaseRef==HEAD | squash | throws |
| dest branch exists + CreateDestinationBranch | squash | throws with delete-hints |
| unclean tree, no AutoStash | squash | throws listing files |
| unclean tree, AutoStash | squash | stashes, splits, restores |
| OutputScriptPath | squash | script renders, is re-runnable, drift guards fire when HEAD changes between generate and execute |
| destructive-by-default | squash | without `-RemoveFromSource:$false`, source ref moves (rewritten); documented as intended |
| preserve: filter-repo absent | preserve | throws with install hint |
| preserve: structure retained | preserve | source commit count preserved (minus pruned empties); paths gone from each commit tree |
| preserve: KeepEmpty | preserve | empty commits kept (`--prune-empty=off`) |
| preserve: path deleted in range | preserve | filter-repo restores the file in earlier commits; dest records deletion |

filter-repo cases are skipped (not failed) if `git-filter-repo` isn't on PATH in
CI — gate with a `BeforeAll` `Get-Command` check so the squash suite still runs
green on runners without filter-repo.

## 10. Future / out of scope

- **Dependency-free preserve mode:** a native cherry-pick-replay (`git cherry-pick
  -n <c>; git restore --staged --worktree -- <paths>; git checkout <c>^ -- <paths>;
  commit -C <c> or skip if empty`) would remove the filter-repo dependency. It's
  more code and slower, and the add/delete/rename edge cases are exactly what
  filter-repo gets right for free. Recommended as a later `-PreserveEngine Native`
  option, not the first cut.
- **Reuse Move-Commit core:** refactor `New-MoveCommitPlan` into core + guard
  wrapper (§8.2), so Split-ByPath (and `Remove-Commit`/`Set-CommitOrder`) splice
  the shared core. Follow-up PR.
- **PR/stack awareness:** after a `-RemoveFromSource` split, auto-run
  `gh stack link <source> <dest>` and update the source PR's head. Out of scope for
  the git-only verb; belongs in a higher-level `pr-auto`-style caller. The verb
  should print the exact `gh stack link` command to run, nothing more.
- **Build/test guards:** explicitly out of scope per maintainer. The verb does not
  compile or test; if the caller wants a buildability check they wrap the call.
- **Review-thread SHA migration:** rewriting cited SHAs in GitHub threads is out of
  scope; the verb only prints the local old→new map.

## 11. Resolved decisions

1. **Default mode:** `-Squash` is the default (no external dep, matches the proven
   immybot flow). Preserve is opt-in via `-Squash:$false`.
2. **Destructive by default:** `-RemoveFromSource` defaults `$true` — a "split"
   removes the paths from the source, consistent with `Move-Commit`'s intended
   destructive-by-default semantics. See §2 review-bot note. The opt-out
   (`-RemoveFromSource:$false`) covers the copy-only case.
3. **Commit-from-index, not reconstruct-via-checkout:** the squash mode commits
   paths from the index after `reset --soft`, eliminating the deletion edge case
   (former §7.2). This supersedes the earlier reconstruct technique.
4. **filter-repo dependency:** accepted for preserve mode in the first cut; the
   native engine (§10) is a later option. filter-repo absent → fail loud with an
   install hint (preserve mode unavailable, squash mode unaffected).
5. **Trunk default:** `merge-base(HEAD, origin/HEAD)`, overridable via `-BaseRef`.
   If `origin/HEAD` is unset, require explicit `-BaseRef`.
6. **No `-TipRef`:** the tip is always the current branch HEAD. Dropped from the
   earlier draft — no legitimate user story for splitting from an arbitrary
   non-HEAD commit, and a free TipRef makes the destructive `-RemoveFromSource`
   ambiguous about *which* branch it rewrites. Pinning to HEAD keeps source-branch
   semantics unambiguous (matches `Move-Commit`) and removes the drift-guard
   caveat (the guard checks `HEAD == expectedHead` at script start, before the
   squash rewrite — no special mid-script handling needed).
6. **Move-Commit reuse:** deferred to a follow-up PR (§8.2) — the first cut emits
   standalone commit-from-index git and does not depend on the
   `New-MoveCommitPlan` core/guard refactor.
