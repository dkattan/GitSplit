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

## Development

### Run tests

```powershell
Invoke-Pester -Path "./GitSplit.Tests.ps1" -CI
```

## Publishing

Publishing is handled by GitHub Actions:

- CI runs Pester on pushes and PRs.
- Publishing runs on version tags like `v0.1.0` and publishes to the PowerShell Gallery.

You’ll need a repository secret:

- `PSGALLERY_API_KEY`: your PowerShell Gallery API key.
