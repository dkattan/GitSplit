# GitSplit

Git-oriented patch/hunk/commit splitting utilities.

This module intentionally has **no PowerShell dependencies** beyond having `git` available on `PATH`.

## Installation

### PowerShell Gallery (once published)

```powershell
Install-Module GitSplit -Scope CurrentUser
```

### From source

```powershell
Import-Module "./GitSplit.psm1" -Force
# or
Import-Module "./GitSplit.psd1" -Force
```

## Commands

### `Split-Patch`

Splits a unified diff (containing one or more `diff --git` sections) into per-file hunks.

```powershell
$patchText = git show --pretty=format: --no-color HEAD
$files = Split-Patch -patch $patchText
$files | Format-Table FilePath, @{n='Hunks';e={$_.Patches.Count}}
```

### `Split-Hunk`

Splits a single unified diff hunk into two valid hunks.

```powershell
$parts = Split-Hunk -Hunk $hunk -Line 10
$parts[0]
$parts[1]
```

Mid-line (column) split:

```powershell
$parts = Split-Hunk -Hunk $hunk -Line 5 -Column 12
```

### `Split-Commit`

Rewrites history by splitting a commit into multiple commits based on hunk split points.

> Warning: this rewrites history. Use on local branches (or be prepared to force push).

```powershell
$created = Split-Commit -Ref HEAD -NewCommitRanges @(
  [pscustomobject]@{ Path = 'b.txt'; Line = 5 }
)
$created
```

### `New-Hunk`

Helper to construct a unified diff hunk string.

### `New-Range`

Creates a range object that converts between (Line, Column) and 0-based Index for a file.

### `Add-Commit`

Deterministically inserts a new commit by applying a patch while replaying history.

### `Move-Commit`

Applies a commit to another branch (via cherry-pick) **without switching branches** in your current working directory.

This is meant to pair with `Split-Commit`:

1) Use `Split-Commit` to break a big change into multiple commits.
2) Use `Move-Commit` to move one of those commits to a different branch.

> Note: `Move-Commit -RemoveFromSource` rewrites history.

```powershell
# Copy HEAD to another branch (no branch switching in your current worktree)
Move-Commit -CommitRef HEAD -DestinationBranch feature/extracted

# Move HEAD to another branch and remove it from the current branch
Move-Commit -CommitRef HEAD -DestinationBranch feature/extracted -RemoveFromSource
```

## Development

### Run tests

```powershell
Invoke-Pester -Path "./GitSplit.Tests.ps1" -CI
```

## Publishing

Publishing is handled by GitHub Actions:

- CI runs Pester on PRs.
- On every push to `main`, a workflow runs Pester, bumps the patch version in `GitSplit.psd1`, commits it, and creates a GitHub Release.
- Publishing runs when the GitHub Release is published and publishes to the PowerShell Gallery.

You’ll need a repository secret:

- `PSGALLERY_API_KEY`: your PowerShell Gallery API key.
