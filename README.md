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

Rewrites history by splitting a commit into multiple commits based on hunk split points or whole-file piece assignments.

> Warning: this rewrites history. Use on local branches (or be prepared to force push).

```powershell
$created = Split-Commit -Ref HEAD -NewCommitRanges @(
  [pscustomobject]@{ Path = 'b.txt'; Line = 5 }
)
$created

# Move an entire file diff into the second split piece
$created = Split-Commit -Ref HEAD~1 -NewCommitRanges @(
  [pscustomobject]@{ Path = 'b.txt'; PieceNumber = 2 }
)
$created

# Generate a reviewable split script now and execute it later
Split-Commit -Ref HEAD -NewCommitRanges @(
  [pscustomobject]@{ Path = 'b.txt'; Line = 5 }
) -OutputScriptPath ./split-commit.ps1
```

### `New-Hunk`

Helper to construct a unified diff hunk string.

### `New-Range`

Creates a range object that converts between (Line, Column) and 0-based Index for a file.

### `Add-Commit`

Deterministically inserts a new commit by applying a patch while replaying history.

### `Remove-Commit`

Removes a commit from a branch by rewriting history.

- If the commit is `HEAD`, it uses a hard reset to remove the latest commit.
- If the commit is not `HEAD`, it uses a rebase to drop that commit while keeping later commits.

> Warning: this rewrites history. If you already pushed the branch, you will likely need to force push.

```powershell
# Remove the latest commit from the current branch
Remove-Commit -CommitRef HEAD

# Remove a non-HEAD commit (by SHA) from a specific branch
Remove-Commit -CommitRef 0123abcd -Branch feature/my-branch

# Rewrite and push the branch update (safer force push)
Remove-Commit -CommitRef HEAD~1 -Push -ForcePush

# Generate a reviewable script now and execute it later
Remove-Commit -CommitRef HEAD~1 -OutputScriptPath ./remove-commit.ps1
```

### `Move-Commit`

Applies a commit to another branch (via cherry-pick) **without switching branches** in your current working directory.

This is meant to pair with `Split-Commit`:

1) Use `Split-Commit` to break a big change into multiple commits.
2) Use `Move-Commit` to move one of those commits to a different branch.

> Note: `Move-Commit -RemoveFromSource` rewrites history.
>
> By default, `Move-Commit` fails if the destination branch does not already exist.
> To create it intentionally, use `-CreateDestinationBranch -BaseRef <ref>`.

```powershell
# Copy HEAD to another branch (no branch switching in your current worktree)
Move-Commit -CommitRef HEAD -DestinationBranch feature/extracted

# Move HEAD to another branch and remove it from the current branch
Move-Commit -CommitRef HEAD -DestinationBranch feature/extracted -RemoveFromSource

# Create the destination branch from origin/main, then move HEAD onto it
Move-Commit -CommitRef HEAD -DestinationBranch feature/extracted -CreateDestinationBranch -BaseRef origin/main

# Generate a reviewable script now and execute it later
Move-Commit -CommitRef HEAD~1 -DestinationBranch feature/extracted -OutputScriptPath ./move-commit.ps1
```

### `Set-CommitOrder`

Reorders commits in the current branch by driving `git rebase -i` with a generated
sequence editor, so you do not need to edit the todo list manually.

`GitSplit` does not depend on Graphite or `gt`. If you pass `-Absorb`, it creates
dependency-free `fixup!` commits from staged changes and runs the reorder with
`--autosquash`.

```powershell
# Reorder the last two commits
Set-CommitOrder -OrderedCommits @(
  'abc1234'
  'def5678'
) -BaseRef HEAD~2

# Stage feedback fixes, absorb them into earlier commits, then reorder
git add c.txt
Set-CommitOrder -OrderedCommits @('def5678', 'abc1234') -BaseRef HEAD~2 -Absorb

# Generate a reviewable reorder script now and execute it later
Set-CommitOrder -OrderedCommits @('def5678', 'abc1234') -BaseRef HEAD~2 -OutputScriptPath ./set-commit-order.ps1
```

### `Invoke-GitSplitAbsorb`

Creates direct `fixup!` commits from staged changes without running the reorder step yet.

This is the primitive behind `Set-CommitOrder -Absorb`, and it is useful when you want to inspect
or debug absorb targeting before running a full reorder/autosquash flow.

```powershell
git add c.txt
Invoke-GitSplitAbsorb -From (git merge-base HEAD origin/main)
```

### Suggested extraction workflow

When you need to peel part of a mixed change onto another branch without losing reviewability:

1. Use `Split-Commit` to break the source commit into smaller commits. If you want a reviewable artifact first, use `-OutputScriptPath` so the generated script carries its split patches inline.
2. Use `Move-Commit` to apply the extracted commit to the destination branch without switching branches in your current worktree. Again, `-OutputScriptPath` lets you review the exact move plan before running it.
3. If the source branch still needs cleanup, use `Move-Commit -RemoveFromSource` or `Remove-Commit` to rewrite away the extracted commit from the source side.
4. Use `Set-CommitOrder` to reorder the resulting commits, and `-Absorb` when you have staged follow-up fixes that should be folded back into earlier commits with `fixup!` commits.

This keeps the entire extraction flow script-capable: split, move/remove, and reorder can all be planned first and executed later from reviewable PowerShell scripts.

### `Get-CommitMessageFromChanges`

Suggests a commit message based on your current repo changes.

Notes:

- If there are **no staged or unstaged changes**, it returns `$null`.
- If there **are** changes, it currently requires an Anthropic API key to be set (future enhancement).

Set one of:

- `AnthropicKey`
- `ANTHROPIC_TOKEN`

```powershell
$msg = Get-CommitMessageFromChanges
if ($msg) {
  git commit -am $msg
}
```

## Development

### Run tests

```powershell
$config = New-PesterConfiguration
$config.Run.Path = "./GitSplit.Tests.ps1"
$config.Output.Verbosity = "Detailed"

Invoke-Pester -Configuration $config
```

### Run tests with coverage

```powershell
$config = New-PesterConfiguration
$config.Run.Path = "./GitSplit.Tests.ps1"
$config.Run.PassThru = $true
$config.Output.Verbosity = "Detailed"
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = "./GitSplit.psm1"

$result = Invoke-Pester -Configuration $config
$result.CodeCoverage.CoveragePercent
```

## Publishing

Publishing is handled by GitHub Actions:

- CI runs Pester on PRs.
- On every push to `main`, a workflow runs Pester, bumps the patch version in `GitSplit.psd1`, commits it, and creates a GitHub Release.
- Publishing runs when the GitHub Release is published and publishes to the PowerShell Gallery.

You’ll need a repository secret:

- `PSGALLERY_API_KEY`: your PowerShell Gallery API key.
