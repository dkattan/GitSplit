<#
GitSplit.psm1

This module contains git-oriented patch/hunk/commit splitting utilities used by ImmyBot tooling.
It intentionally has no external dependencies beyond git being available on PATH.
#>

# Internal helper to run `git` in a way that does not leak informational stderr output to the host
# (which some runners surface as error notifications), while still including stderr when the command fails.
function Invoke-Git {
  [CmdletBinding()]
  param(
    # Optional error message/context used when throwing.
    [Parameter()]
    [string]$ErrorMessage,

    # If set, suppresses output to the host.
    [Parameter()]
    [switch]$Quiet,

    # If set, prints captured output to host in red on failure *before* throwing.
    # This keeps diagnostics out of the PowerShell error stream while still failing fast.
    [Parameter()]
    [switch]$WriteHostOnError,

    # Arguments to pass to git as discrete tokens.
    # Use "ValueFromRemainingArguments" so callers can use normal syntax:
    #   Invoke-Git -Quiet reset --hard HEAD~1
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$GitArgs
  )

  # Capture BOTH stdout+stderr so we can (a) avoid leaking stderr on success and
  # (b) still show useful diagnostics on failure.
  # PowerShell wraps native stderr lines as ErrorRecord objects even when redirected with 2>&1.
  # Normalize everything to plain strings so callers/hosts don't treat stderr text as PowerShell errors.
  # Use the pipeline so we can optionally stream output in real time.
  & git @GitArgs 2>&1 | ForEach-Object {
    if (!$Quiet) {
      if ($WriteHostOnError -and $_ -is [System.Management.Automation.ErrorRecord]) { 
        $_ | Out-String | Write-Host -ForegroundColor Red
      }
      else { 
        # Keep output visible without using the error stream.
        $_ | Out-String | Write-Host
      }
    }
  }
  
  $exitCode = $LASTEXITCODE

  if ($exitCode -ne 0) {
    $ctx = if ($ErrorMessage) { $ErrorMessage } else { "git $($GitArgs -join ' ')" }
    $details = ($output | Where-Object { $_ -ne $null }) -join [Environment]::NewLine

    if (-not $Quiet -and $WriteHostOnError -and -not [string]::IsNullOrWhiteSpace($details)) {
      Write-Host $details -ForegroundColor Red
    }

    if ([string]::IsNullOrWhiteSpace($details) -or $WriteHostOnError) {
      throw "$ctx failed with exit code $exitCode"
    }

    throw "$ctx failed with exit code $exitCode`n$details"
  }
}

# Internal helper to suppress PowerShell progress UI for noisy operations (e.g., Remove-Item).
function Invoke-WithProgressSuppressed {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Script
  )

  $old = $global:ProgressPreference
  try {
    $global:ProgressPreference = 'SilentlyContinue'
    & $Script
  }
  finally {
    $global:ProgressPreference = $old
  }
}

function Invoke-GitQuery {
  [CmdletBinding()]
  param(
    [Parameter()]
    [string]$ErrorMessage,

    [Parameter()]
    [switch]$AllowFailure,

    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$GitArgs
  )

  $records = @(
    & git @GitArgs 2>&1 |
      ForEach-Object {
        if ($null -ne $_) {
          if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.ToString()
          }
          else {
            "$_"
          }
        }
      }
  )

  $exitCode = $LASTEXITCODE
  $output = ($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine

  if ($exitCode -ne 0 -and -not $AllowFailure) {
    $ctx = if ($ErrorMessage) { $ErrorMessage } else { "git $($GitArgs -join ' ')" }
    if ([string]::IsNullOrWhiteSpace($output)) {
      throw "$ctx failed with exit code $exitCode"
    }

    throw "$ctx failed with exit code $exitCode`n$output"
  }

  return [PSCustomObject]@{
    ExitCode = $exitCode
    Output   = $output
    Lines    = $records
  }
}

function Get-GitRepoRoot {
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $repoRoot = (Invoke-GitQuery -ErrorMessage 'Move-Commit must be run inside a git repository.' rev-parse --show-toplevel).Output.Trim()
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw "Move-Commit must be run inside a git repository."
  }

  return $repoRoot
}

function Get-GitCurrentBranch {
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $currentBranch = (Invoke-GitQuery -ErrorMessage 'Failed to get current branch.' rev-parse --abbrev-ref HEAD).Output.Trim()
  if ([string]::IsNullOrWhiteSpace($currentBranch)) {
    throw "Failed to get current branch."
  }

  return $currentBranch
}

function Resolve-GitCommit {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Ref,

    [Parameter()]
    [string]$ErrorMessage
  )

  if (-not $ErrorMessage) {
    $ErrorMessage = "Failed to resolve commit reference '$Ref'."
  }

  $resolvedCommit = (Invoke-GitQuery -ErrorMessage $ErrorMessage rev-parse --verify "$Ref^{commit}").Output.Trim()
  if ($resolvedCommit -notmatch '^[0-9a-f]{40}$') {
    throw $ErrorMessage
  }

  return $resolvedCommit
}

function Test-GitRefExists {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Ref
  )

  $query = Invoke-GitQuery -AllowFailure -GitArgs @('show-ref', '--verify', '--quiet', $Ref)
  if ($query.ExitCode -eq 0) {
    return $true
  }

  if ($query.ExitCode -eq 1) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($query.Output)) {
    throw "Failed to inspect git ref '$Ref'."
  }

  throw "Failed to inspect git ref '$Ref'.`n$($query.Output)"
}

function Test-GitCommitIsAncestor {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Ancestor,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Descendant
  )

  $query = Invoke-GitQuery -AllowFailure -GitArgs @('merge-base', '--is-ancestor', $Ancestor, $Descendant)
  if ($query.ExitCode -eq 0) {
    return $true
  }

  if ($query.ExitCode -eq 1) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($query.Output)) {
    throw "Failed to determine whether '$Ancestor' is an ancestor of '$Descendant'."
  }

  throw "Failed to determine whether '$Ancestor' is an ancestor of '$Descendant'.`n$($query.Output)"
}

function ConvertTo-PowerShellStringLiteral {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()]
    [string]$Value
  )

  if ($null -eq $Value) {
    return '$null'
  }

  return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-PowerShellHereStringLines {
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AssignmentPrefix,

    [Parameter()]
    [AllowEmptyString()]
    [string]$Value = ''
  )

  $normalizedValue = $Value -replace "`r`n", "`n"
  $lines = @("$AssignmentPrefix@'")
  if (-not [string]::IsNullOrEmpty($normalizedValue)) {
    $lines += $normalizedValue.TrimEnd("`n") -split "`n"
  }
  $lines += "'@"
  return $lines
}

$script:GitSplitTestHooks = @{
  GuidProvider      = $null
  TempRootProvider  = $null
  TimestampProvider = $null
  StashNameProvider = $null
}

function Set-GitSplitTestHooks {
  [CmdletBinding()]
  param(
    [Parameter()]
    [AllowNull()]
    [scriptblock]$GuidProvider,

    [Parameter()]
    [AllowNull()]
    [scriptblock]$TempRootProvider,

    [Parameter()]
    [AllowNull()]
    [scriptblock]$TimestampProvider,

    [Parameter()]
    [AllowNull()]
    [scriptblock]$StashNameProvider
  )

  foreach ($providerName in @('GuidProvider', 'TempRootProvider', 'TimestampProvider', 'StashNameProvider')) {
    if ($PSBoundParameters.ContainsKey($providerName)) {
      $script:GitSplitTestHooks[$providerName] = $PSBoundParameters[$providerName]
    }
  }
}

function Reset-GitSplitTestHooks {
  [CmdletBinding()]
  param()

  foreach ($providerName in @('GuidProvider', 'TempRootProvider', 'TimestampProvider', 'StashNameProvider')) {
    $script:GitSplitTestHooks[$providerName] = $null
  }
}

function Get-GitSplitGuid {
  [CmdletBinding()]
  [OutputType([guid])]
  param()

  if ($script:GitSplitTestHooks.GuidProvider) {
    $providedValue = & $script:GitSplitTestHooks.GuidProvider
    if ($providedValue -is [guid]) {
      return $providedValue
    }

    $parsedGuid = [guid]::Empty
    if ([guid]::TryParse("$providedValue", [ref]$parsedGuid)) {
      return $parsedGuid
    }

    throw "GitSplit test Guid provider must return a valid Guid value."
  }

  return [guid]::NewGuid()
}

function Get-GitSplitTimestamp {
  [CmdletBinding()]
  [OutputType([datetime])]
  param()

  if ($script:GitSplitTestHooks.TimestampProvider) {
    $providedValue = & $script:GitSplitTestHooks.TimestampProvider
    if ($providedValue -is [datetime]) {
      return $providedValue
    }

    $parsedTimestamp = [datetime]::MinValue
    if ([datetime]::TryParse("$providedValue", [ref]$parsedTimestamp)) {
      return $parsedTimestamp
    }

    throw "GitSplit test timestamp provider must return a valid DateTime value."
  }

  return Get-Date
}

function Get-GitSplitTempRoot {
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $tempRoot = if ($script:GitSplitTestHooks.TempRootProvider) {
    & $script:GitSplitTestHooks.TempRootProvider
  }
  else {
    [System.IO.Path]::GetTempPath()
  }

  if ([string]::IsNullOrWhiteSpace("$tempRoot")) {
    throw "GitSplit temp root provider returned an empty path."
  }

  return "$tempRoot"
}

function New-GitSplitTempFilePath {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Prefix = 'gitsplit-temp',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Extension = '.tmp'
  )

  $guid = (Get-GitSplitGuid).ToString('N')
  return Join-Path (Get-GitSplitTempRoot) ("$Prefix-$guid$Extension")
}

function New-GitSplitStashName {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Operation = 'operation'
  )

  $stashName = if ($script:GitSplitTestHooks.StashNameProvider) {
    & $script:GitSplitTestHooks.StashNameProvider $Operation
  }
  else {
    "gitsplit-$Operation-$((Get-GitSplitTimestamp).ToString('yyyyMMddHHmmss'))"
  }

  if ([string]::IsNullOrWhiteSpace("$stashName")) {
    throw "GitSplit stash name provider returned an empty value."
  }

  return "$stashName"
}

function New-GitSplitWorktreePath {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RepoRoot
  )

  $worktreeRoot = Join-Path $RepoRoot '.gitsplit-worktrees'
  return Join-Path $worktreeRoot ((Get-GitSplitGuid).ToString())
}

function New-GitStep {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Comment', 'Literal')]
    [string]$Kind,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]]$Lines
  )

  return [PSCustomObject]@{
    Kind  = $Kind
    Lines = @($Lines)
  }
}

function New-GitPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter()]
    [hashtable]$Metadata,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Steps
  )

  return [PSCustomObject]@{
    Name     = $Name
    Metadata = $Metadata
    Steps    = @($Steps)
  }
}

function ConvertTo-GitScript {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Plan
  )

  $lines = @(
    "# Generated by GitSplit: $($Plan.Name)"
    'Set-StrictMode -Version Latest'
    '$ErrorActionPreference = ''Stop'''
    ''
  )

  foreach ($step in $Plan.Steps) {
    switch ($step.Kind) {
      'Comment' {
        foreach ($commentLine in @($step.Lines)) {
          if ([string]::IsNullOrWhiteSpace($commentLine)) {
            $lines += '#'
          }
          else {
            $lines += '# ' + $commentLine
          }
        }
      }

      'Literal' {
        $lines += @($step.Lines)
      }

      default {
        throw "Unsupported git plan step kind '$($step.Kind)'."
      }
    }

    $lines += ''
  }

  return (($lines -join "`n").TrimEnd()) + "`n"
}

function Write-GitScript {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Plan,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path
  )

  $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $parentPath = Split-Path -Parent $resolvedPath
  if (-not [string]::IsNullOrWhiteSpace($parentPath) -and -not (Test-Path -LiteralPath $parentPath)) {
    New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
  }

  Set-Content -Path $resolvedPath -Value (ConvertTo-GitScript -Plan $Plan)
  return $resolvedPath
}

function Invoke-GitPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Plan
  )

  $scriptBlock = [scriptblock]::Create((ConvertTo-GitScript -Plan $Plan))
  return & $scriptBlock
}

function New-CommitRemovalRewritePlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$CommitHash,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Branch,

    [Parameter()]
    [switch]$Push,

    [Parameter()]
    [switch]$ForcePush
  )

  if (-not (Test-GitCommitIsAncestor -Ancestor $CommitHash -Descendant $Branch)) {
    throw "Commit $CommitHash is not an ancestor of branch '$Branch'."
  }

  $branchHead = Resolve-GitCommit -Ref $Branch -ErrorMessage "Failed to resolve branch '$Branch'."
  $parentHash = Resolve-GitCommit -Ref "$CommitHash^" -ErrorMessage "Cannot remove the initial commit."

  if ($branchHead -eq $CommitHash) {
    return [PSCustomObject]@{
      Mode       = 'ResetToParent'
      Branch     = $Branch
      BranchHead = $branchHead
      CommitHash = $CommitHash
      ParentHash = $parentHash
      Push       = [bool]$Push
      ForcePush  = [bool]$ForcePush
    }
  }

  return [PSCustomObject]@{
    Mode       = 'RebaseOntoParent'
    Branch     = $Branch
    BranchHead = $branchHead
    CommitHash = $CommitHash
    ParentHash = $parentHash
    Push       = [bool]$Push
    ForcePush  = [bool]$ForcePush
  }
}

function New-MoveCommitPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^HEAD(~\d+)?$|^[0-9a-f]{7,40}$")]
    [string]$CommitRef,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationBranch,

    [Parameter()]
    [switch]$RemoveFromSource,

    [Parameter()]
    [switch]$Push,

    [Parameter()]
    [switch]$ForcePushSource,

    [Parameter()]
    [switch]$AutoStash
  )

  $repoRoot = Get-GitRepoRoot
  $currentBranch = Get-GitCurrentBranch
  if ($currentBranch -eq 'HEAD') {
    throw "You are in a detached HEAD state. Checkout a branch before calling Move-Commit."
  }

  $currentHead = Resolve-GitCommit -Ref 'HEAD' -ErrorMessage 'Failed to resolve HEAD.'
  $commitHash = Resolve-GitCommit -Ref $CommitRef -ErrorMessage "Failed to resolve commit reference '$CommitRef'."

  $branchExists = Test-GitRefExists -Ref "refs/heads/$DestinationBranch"
  $remoteBranchExists = Test-GitRefExists -Ref "refs/remotes/origin/$DestinationBranch"
  if (-not $branchExists -and -not $remoteBranchExists) {
    throw "Destination branch '$DestinationBranch' does not exist locally or on origin. Create it first."
  }

  $destinationRef = if ($branchExists) { "refs/heads/$DestinationBranch" } else { "refs/remotes/origin/$DestinationBranch" }
  $useRemoteTrackingBranch = $remoteBranchExists -and -not $branchExists
  $plannedStashName = New-GitSplitStashName -Operation 'move-commit'
  $plannedDestWorktreePath = New-GitSplitWorktreePath -RepoRoot $repoRoot

  $sourceRemovalPlan = $null
  if ($RemoveFromSource) {
    $sourceRemovalPlan = New-CommitRemovalRewritePlan -CommitHash $commitHash -Branch $currentBranch -Push:$Push -ForcePush:$ForcePushSource
  }

  $steps = @()
  $steps += New-GitStep -Kind Comment -Lines @(
    'Move-Commit execution plan.',
    'Discovery-time values are frozen below; runtime checks ensure the repository has not drifted.'
  )

  $steps += New-GitStep -Kind Literal -Lines @(
    '$expectedRepoRoot = ' + (ConvertTo-PowerShellStringLiteral $repoRoot)
    '$expectedBranch = ' + (ConvertTo-PowerShellStringLiteral $currentBranch)
    '$expectedHead = ' + (ConvertTo-PowerShellStringLiteral $currentHead)
    '$commitHash = ' + (ConvertTo-PowerShellStringLiteral $commitHash)
    '$destinationBranch = ' + (ConvertTo-PowerShellStringLiteral $DestinationBranch)
    '$destinationRef = ' + (ConvertTo-PowerShellStringLiteral $destinationRef)
    '$useRemoteTrackingBranch = ' + $(if ($useRemoteTrackingBranch) { '$true' } else { '$false' })
    '$autoStash = ' + $(if ($AutoStash) { '$true' } else { '$false' })
    '$pushDestination = ' + $(if ($Push) { '$true' } else { '$false' })
    '$plannedStashName = ' + (ConvertTo-PowerShellStringLiteral $plannedStashName)
    '$destWorktreePath = ' + (ConvertTo-PowerShellStringLiteral $plannedDestWorktreePath)
    '$stashed = $false'
    '$stashName = $null'
    '$destWorktreeCreated = $false'
    '$moveSucceeded = $false'
  )

  $steps += New-GitStep -Kind Comment -Lines @(
    'Runtime guards: assert repository, branch, head commit, destination branch availability, and working tree expectations.'
  )

  $guardLines = @(
    '$repoRoot = (& git rev-parse --show-toplevel).Trim()'
    'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {'
    '  throw "Move-Commit must be run inside a git repository."'
    '}'
    'if ($repoRoot -ne $expectedRepoRoot) {'
    '  throw "This script was generated for repo root ''$expectedRepoRoot'' but is running in ''$repoRoot''."'
    '}'
    '$currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()'
    'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentBranch)) {'
    '  throw "Failed to get current branch."'
    '}'
    'if ($currentBranch -ne $expectedBranch) {'
    '  throw "This script expected branch ''$expectedBranch'' but found ''$currentBranch''."'
    '}'
    '$currentHead = (& git rev-parse HEAD).Trim()'
    'if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch ''^[0-9a-f]{40}$'') {'
    '  throw "Failed to resolve HEAD."'
    '}'
    'if ($currentHead -ne $expectedHead) {'
    '  throw "This script expected HEAD ''$expectedHead'' but found ''$currentHead''."'
    '}'
    '& git show-ref --verify --quiet $destinationRef'
    'if ($LASTEXITCODE -ne 0) {'
    '  if ($useRemoteTrackingBranch) {'
    '    throw "Destination branch ''$destinationBranch'' no longer exists on origin."'
    '  }'
    '  throw "Destination branch ''$destinationBranch'' no longer exists locally."'
    '}'
    '$status = @(& git status --porcelain)'
    'if ($LASTEXITCODE -ne 0) {'
    '  throw "Failed to determine git status."'
    '}'
    'if ($status.Count -gt 0) {'
    '  if (-not $autoStash) {'
    '    throw "Uncommitted changes detected. Re-run with -AutoStash, or commit/stash your changes before running this script."'
    '  }'
    '  $stashName = $plannedStashName'
    '  & git stash push -u -m $stashName 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '  if ($LASTEXITCODE -ne 0) {'
    '    throw "git stash push failed"'
    '  }'
    '  $stashed = $true'
    '}'
  )
  $steps += New-GitStep -Kind Literal -Lines $guardLines

  $executionLines = @(
    '$wtRoot = Join-Path $repoRoot ''.gitsplit-worktrees'''
    'if (-not (Test-Path -LiteralPath $wtRoot)) {'
    '  New-Item -Path $wtRoot -ItemType Directory -Force | Out-Null'
    '}'
    'if (Test-Path -LiteralPath $destWorktreePath) {'
    '  throw "Planned destination worktree path ''$destWorktreePath'' already exists."'
    '}'
    'try {'
    '  if ($useRemoteTrackingBranch) {'
    '    & git worktree add -b $destinationBranch $destWorktreePath "origin/$destinationBranch" 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '    if ($LASTEXITCODE -ne 0) {'
    '      throw "git worktree add -b $destinationBranch failed"'
    '    }'
    '  }'
    '  else {'
    '    & git worktree add $destWorktreePath $destinationBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '    if ($LASTEXITCODE -ne 0) {'
    '      throw "git worktree add $destinationBranch failed"'
    '    }'
    '  }'
    '  $destWorktreeCreated = $true'
    '  & git -C $destWorktreePath cherry-pick $commitHash 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '  if ($LASTEXITCODE -ne 0) {'
    '    throw "git -C <worktree> cherry-pick failed for $commitHash"'
    '  }'
    '  if ($pushDestination) {'
    '    & git -C $destWorktreePath push -u origin $destinationBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '    if ($LASTEXITCODE -ne 0) {'
    '      throw "git -C <worktree> push failed for $destinationBranch"'
    '    }'
    '  }'
  )

  if ($sourceRemovalPlan) {
    $executionLines += ''
    $executionLines += '  # Remove the moved commit from the source branch using the strategy chosen at plan time.'
    if ($sourceRemovalPlan.Mode -eq 'ResetToParent') {
      $executionLines += @(
        '  & git reset --hard ' + (ConvertTo-PowerShellStringLiteral $sourceRemovalPlan.ParentHash) + ' 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
        '  if ($LASTEXITCODE -ne 0) {'
        '    throw "git reset --hard failed while removing $commitHash from $expectedBranch"'
        '  }'
      )
    }
    else {
      $executionLines += @(
        '  & git rebase --onto ' + (ConvertTo-PowerShellStringLiteral $sourceRemovalPlan.ParentHash) + ' $commitHash $expectedBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
        '  if ($LASTEXITCODE -ne 0) {'
        '    throw "git rebase --onto failed while removing $commitHash from $expectedBranch"'
        '  }'
      )
    }

    if ($sourceRemovalPlan.Push) {
      if ($sourceRemovalPlan.ForcePush) {
        $executionLines += @(
          '  & git push --force-with-lease origin $expectedBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
          '  if ($LASTEXITCODE -ne 0) {'
          '    throw "git push --force-with-lease origin $expectedBranch failed"'
          '  }'
        )
      }
      else {
        $executionLines += @(
          '  & git push origin $expectedBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
          '  if ($LASTEXITCODE -ne 0) {'
          '    throw "git push origin $expectedBranch failed"'
          '  }'
        )
      }
    }
  }

  $executionLines += @(
    '  $moveSucceeded = $true'
    '}'
    'finally {'
    '  if ($moveSucceeded -and $destWorktreePath -and (Test-Path -LiteralPath $destWorktreePath)) {'
    '    & git worktree remove --force $destWorktreePath 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '    if ($LASTEXITCODE -ne 0) {'
    '      throw "git worktree remove --force failed for ''$destWorktreePath''."'
    '    }'
    '  }'
    '  elseif ($destWorktreeCreated -and $destWorktreePath -and (Test-Path -LiteralPath $destWorktreePath)) {'
    '    Write-Warning "Preserving destination worktree at ''$destWorktreePath'' so conflicts can be resolved manually."'
    '  }'
    ''
    '  if ($stashed) {'
    '    $gitDir = (& git rev-parse --git-dir).Trim()'
    '    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitDir)) {'
    '      throw "Move-Commit created a stash ''$stashName'' but failed to resolve the git directory for restoration."'
    '    }'
    ''
    '    if (-not [System.IO.Path]::IsPathRooted($gitDir)) {'
    '      $gitDir = Join-Path $repoRoot $gitDir'
    '    }'
    ''
    '    $stashLines = @(& git stash list --format="%gd %s")'
    '    if ($LASTEXITCODE -ne 0) {'
    '      throw "Move-Commit created a stash ''$stashName'' but failed to inspect the stash list for restoration."'
    '    }'
    ''
    '    $stashLine = $stashLines | Where-Object { $_ -like "*$stashName*" } | Select-Object -First 1'
    '    if ([string]::IsNullOrWhiteSpace($stashLine)) {'
    '      throw "Move-Commit created a stash ''$stashName'' but could not find it for restoration."'
    '    }'
    ''
    '    $stashRef = ($stashLine -split ''\s+'', 2)[0]'
    '    $inProgress = ('
    '      (Test-Path -LiteralPath (Join-Path $gitDir ''rebase-apply'')) -or'
    '      (Test-Path -LiteralPath (Join-Path $gitDir ''rebase-merge'')) -or'
    '      (Test-Path -LiteralPath (Join-Path $gitDir ''MERGE_HEAD'')) -or'
    '      (Test-Path -LiteralPath (Join-Path $gitDir ''CHERRY_PICK_HEAD'')) -or'
    '      (Test-Path -LiteralPath (Join-Path $gitDir ''REVERT_HEAD''))'
    '    )'
    ''
    '    if ($inProgress) {'
    '      Write-Error @('
    '        "Move-Commit created a stash (''$stashName'' -> $stashRef) but will NOT restore it because git reports an in-progress operation (merge/rebase/cherry-pick/revert)."'
    '        ""'
    '        "How to proceed:"'
    '        "  1) Inspect state:            git status"'
    '        "  2) Finish or abort operation: git rebase --continue | git rebase --abort | git merge --abort | git cherry-pick --abort | git revert --abort"'
    '        "  3) Then restore your changes: git stash pop $stashRef"'
    '        ""'
    '        "How to undo the branch rewrite (if you used -RemoveFromSource):"'
    '        "  - Find the pre-rewrite commit in reflog: git reflog"'
    '        "  - Reset branch back to it:              git reset --hard <sha>"'
    '        "  - If you pushed/force-pushed:           git push --force-with-lease"'
    '      ) -join [Environment]::NewLine'
    '    }'
    '    else {'
    '      & git stash pop $stashRef 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '      if ($LASTEXITCODE -ne 0) {'
    '        throw "Failed to restore stash $stashRef created by Move-Commit."'
    '      }'
    '    }'
    '  }'
    '}'
    '$destinationBranch'
  )

  $steps += New-GitStep -Kind Comment -Lines @(
    'Execute the destination cherry-pick in an isolated worktree, then optionally rewrite the source branch.',
    'Cleanup removes successful temporary worktrees and preserves conflicted ones for manual resolution.'
  )
  $steps += New-GitStep -Kind Literal -Lines $executionLines

  return New-GitPlan -Name 'Move-Commit' -Metadata @{
    CommitHash          = $commitHash
    DestinationBranch   = $DestinationBranch
    SourceBranch        = $currentBranch
    SourceHead          = $currentHead
    RemoveFromSource    = [bool]$RemoveFromSource
    PushDestination     = [bool]$Push
    AutoStash           = [bool]$AutoStash
    OutputScriptCapable = $true
  } -Steps $steps
}

function Split-Patch {
  <#
  .SYNOPSIS
  Splits a unified diff/patch into per-file hunks.

  .DESCRIPTION
  Parses a text patch that contains one or more `diff --git` sections and returns an array of objects
  containing a file path and an array of unified diff hunk strings (each starting with an `@@ ... @@` header).

  This is used by PR/commit tooling to reason about changes at the hunk level.

  .PARAMETER patch
  The full patch text to split. This should be in unified diff format and include `diff --git` lines.

  .OUTPUTS
  System.Management.Automation.PSCustomObject
  Objects with properties:
    - FilePath (string): The path extracted from `a/<path> b/<path>`.
    - Patches  (string[]): The hunks for that file.

  .EXAMPLE
  $patchText = git show --pretty=format: --no-color HEAD
  $files = Split-Patch -patch $patchText
  $files | Format-Table FilePath, @{n='Hunks';e={$_.Patches.Count}}
  #>
  param([string]$patch)

  # Split on diff --git lines first
  $files = $patch -split '(?m)^diff --git'

  # Skip empty first element if patch started with diff --git
  if ($files[0] -eq '') {
    $files = $files[1..$files.Length]
  }

  $result = @()
  foreach ($file in $files) {
    if ([string]::IsNullOrWhiteSpace($file)) { continue }

    # Extract file path from diff header
    if ($file -match 'a/(.+?)\s+b/') {
      $filePath = $matches[1]

      # Find all hunks starting with @@ header.
      # Use a lookahead for "\n@@" so we don't immediately terminate at the current header.
      $patches = [regex]::Matches(
        $file,
        '(?ms)^@@.*?(?=\n@@|\z)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
      ) | ForEach-Object { $_.Value }

      if ($patches.Count -gt 0) {
        $result += [PSCustomObject]@{
          FilePath = $filePath
          Patches  = $patches
        }
      }
    }
  }

  return $result
}

function Split-Hunk {
  <#
  .SYNOPSIS
  Splits a single unified diff hunk into two hunks.

  .DESCRIPTION
  Takes one unified diff hunk (a string beginning with `@@ -a,b +c,d @@`) and splits it into two
  valid hunks.

  You can split either:
  - By NEW-file line number (`-Line`), optionally at a specific column (`-Column`) to support mid-line splitting.
  - By body-line index (`-Index`), where the index is 0-based into the hunk body (not including the `@@` header).

  When splitting by column, this function currently supports mid-line splitting for context (' ') and added ('+') lines
  by converting a single body line into two body lines at the column boundary.

  .PARAMETER Hunk
  A single unified diff hunk string (not a full `diff --git` section).

  .PARAMETER Line
  The 1-based line number in the NEW file at which the second returned hunk should begin.

  .PARAMETER Column
  Optional 1-based column into the NEW-file line specified by `-Line`. When greater than 1, the target
  body line is split into two body lines at the column boundary.

  .PARAMETER Index
  0-based index into the hunk body lines indicating the first body line of the second returned hunk.

  .OUTPUTS
  System.String[]
  Two hunk strings: the first half and the second half.

  .EXAMPLE
  $parts = Split-Hunk -Hunk $hunk -Line 10
  $parts[0] | Out-Host
  $parts[1] | Out-Host

  .EXAMPLE
  # Mid-line split on NEW-file line 5, column 12
  $parts = Split-Hunk -Hunk $hunk -Line 5 -Column 12

  .NOTES
  This function assumes the input hunk header is valid and will throw if it cannot parse it.
  #>
  [CmdletBinding(DefaultParameterSetName = 'ByLine')]
  param(
    # A single unified diff hunk (the strings returned by Split-Patch's Patches array)
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Hunk,

    # Split before this 1-based line number in the NEW file ("+" side).
    [Parameter(Mandatory = $true, ParameterSetName = 'ByLine')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Line,

    # Optional column (currently treated as a hint; split occurs on the specified line boundary).
    [Parameter(Mandatory = $false, ParameterSetName = 'ByLine')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Column = 1,

    # Split at a 0-based index into the hunk BODY lines (not counting the @@ header line).
    # Index indicates the first body line that belongs to the SECOND returned hunk.
    [Parameter(Mandatory = $true, ParameterSetName = 'ByIndex')]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$Index
  )

  $text = $Hunk
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "Hunk is empty or invalid."
  }

  $firstNl = $text.IndexOf("`n")
  $header = if ($firstNl -ge 0) { $text.Substring(0, $firstNl) } else { $text }
  if ($header -notmatch '^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@') {
    throw "Hunk does not start with a valid @@ header: $header"
  }

  $oldStart = [int]$matches[1]
  $newStart = [int]$matches[3]

  # Note: we intentionally don't use the original header counts here; we recompute
  # old/new counts from the body lines when building the split hunks.

  $bodyText = if ($firstNl -ge 0 -and $firstNl -lt ($text.Length - 1)) { $text.Substring($firstNl + 1) } else { '' }
  $body = @()
  if (-not [string]::IsNullOrEmpty($bodyText)) {
    $body = $bodyText -split "`n"
    if ($body.Count -gt 0 -and $body[-1] -eq '') {
      $body = $body[0..($body.Count - 2)]
    }
  }

  # Helper to count how a set of body lines affects old/new line counts.
  function Get-LineDeltas {
    param([string[]]$BodyLines)
    $o = 0
    $n = 0
    foreach ($l in $BodyLines) {
      if ($l.Length -eq 0) {
        # blank context line still counts as context (space prefix), but empty is ambiguous; treat as context.
        $o += 1
        $n += 1
        continue
      }
      $c = $l[0]
      switch ($c) {
        ' ' { $o += 1; $n += 1 }
        '-' { $o += 1 }
        '+' { $n += 1 }
        '\\' { }
        default { $o += 1; $n += 1 }
      }
    }
    return @{ Old = $o; New = $n }
  }

  $splitIndex = $null
  if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
    if ($Index -gt $body.Count) {
      throw "Index $Index is out of range for hunk body length $($body.Count)."
    }
    $splitIndex = $Index
  }
  else {
    # Split based on absolute new-file line. (Column is currently not used beyond validation.)
    $currentOld = $oldStart
    $currentNew = $newStart
    $splitIndex = $body.Count

    $didColumnSplit = $false

    # If Column > 1, we split the specific NEW-file line into two body lines at the column boundary.
    # This enables mid-line splitting by turning one '+' (or ' ') line into two lines.
    if ($Column -gt 1) {
      $targetBodyIndex = $null
      $targetPrefix = $null

      $tmpOld = $oldStart
      $tmpNew = $newStart
      for ($j = 0; $j -lt $body.Count; $j++) {
        $bl = $body[$j]
        if ($bl.Length -gt 0 -and $bl[0] -ne '\\') {
          if ($bl[0] -eq ' ' -or $bl[0] -eq '+') {
            if ($tmpNew -eq $Line) {
              $targetBodyIndex = $j
              $targetPrefix = $bl[0]
              break
            }
          }
        }

        if ($bl.Length -eq 0) {
          $tmpOld += 1
          $tmpNew += 1
          continue
        }
        switch ($bl[0]) {
          ' ' { $tmpOld += 1; $tmpNew += 1 }
          '-' { $tmpOld += 1 }
          '+' { $tmpNew += 1 }
          '\\' { }
          default { $tmpOld += 1; $tmpNew += 1 }
        }
      }

      if ($null -eq $targetBodyIndex) {
        throw "Could not locate NEW-file line $Line inside hunk body to split at Column $Column."
      }

      $original = $body[$targetBodyIndex]
      if ($original.Length -lt 2) {
        throw "Target line for mid-line split is too short to split: '$original'"
      }
      if ($targetPrefix -ne ' ' -and $targetPrefix -ne '+') {
        throw "Mid-line split currently supports only context (' ') or added ('+') lines."
      }

      $content = $original.Substring(1)
      $splitAt = $Column - 1
      if ($splitAt -le 0 -or $splitAt -ge ($content.Length + 1)) {
        throw "Column $Column is out of range for line content length $($content.Length)."
      }

      $left = $content.Substring(0, [Math]::Min($splitAt, $content.Length))
      $right = if ($splitAt -lt $content.Length) { $content.Substring($splitAt) } else { '' }

      $line1 = "$targetPrefix$left"
      $line2 = "$targetPrefix$right"

      # Replace one line with two lines.
      $pre = if ($targetBodyIndex -gt 0) { $body[0..($targetBodyIndex - 1)] } else { @() }
      $post = if ($targetBodyIndex -lt ($body.Count - 1)) { $body[($targetBodyIndex + 1)..($body.Count - 1)] } else { @() }
      $body = @($pre + @($line1, $line2) + $post)

      # The second hunk starts at the inserted second line.
      $splitIndex = $targetBodyIndex + 1

      # We deliberately chose the split boundary; don't let the line-based scan override it.
      $didColumnSplit = $true
    }

    if (-not $didColumnSplit) {
      for ($i = 0; $i -lt $body.Count; $i++) {
        $l = $body[$i]

        # Decide which hunk this line belongs to by the current NEW-file line position.
        # If this line affects a new-file line >= target Line, it starts the second hunk.
        if ($currentNew -ge $Line) {
          $splitIndex = $i
          break
        }

        if ($l.Length -eq 0) {
          $currentOld += 1
          $currentNew += 1
          continue
        }
        switch ($l[0]) {
          ' ' { $currentOld += 1; $currentNew += 1 }
          '-' { $currentOld += 1 }
          '+' { $currentNew += 1 }
          '\\' { }
          default { $currentOld += 1; $currentNew += 1 }
        }
      }
    }
  }

  if ($splitIndex -le 0 -or $splitIndex -ge $body.Count) {
    throw "Split point must be inside the hunk body (cannot split at start or end). Computed splitIndex=$splitIndex for body length $($body.Count)."
  }

  $body1 = @()
  $body2 = @()
  if ($splitIndex -gt 0) {
    $body1 = $body[0..($splitIndex - 1)]
  }
  if ($splitIndex -lt $body.Count) {
    $body2 = $body[$splitIndex..($body.Count - 1)]
  }

  $d1 = Get-LineDeltas -BodyLines $body1
  $oldStart2 = $oldStart + $d1.Old
  $newStart2 = $newStart + $d1.New

  $d2 = Get-LineDeltas -BodyLines $body2

  $h1 = New-Hunk -OldStart $oldStart -OldCount $d1.Old -NewStart $newStart -NewCount $d1.New -BodyLines $body1
  $h2 = New-Hunk -OldStart $oldStart2 -OldCount $d2.Old -NewStart $newStart2 -NewCount $d2.New -BodyLines $body2

  return @($h1, $h2)
}

function New-Hunk {
  <#
  .SYNOPSIS
  Builds a unified diff hunk string from header coordinates and body lines.

  .DESCRIPTION
  Constructs a well-formed unified diff hunk:
    @@ -<OldStart>,<OldCount> +<NewStart>,<NewCount> @@
    <body...>

  This helper centralizes hunk formatting rules, including the important detail that a truly blank
  context line must be represented as a single space character (' '), not an empty string.

  .PARAMETER OldStart
  1-based start line number in the OLD file (the '-' side).

  .PARAMETER OldCount
  Number of old-file lines covered by this hunk.

  .PARAMETER NewStart
  1-based start line number in the NEW file (the '+' side).

  .PARAMETER NewCount
  Number of new-file lines covered by this hunk.

  .PARAMETER BodyLines
  Array of hunk body lines (not including the header). Each element should typically start with:
    ' ' (context), '+' (add), '-' (remove), or '\\' (no-newline marker).

  .OUTPUTS
  System.String
  The constructed hunk text (including a trailing newline).

  .EXAMPLE
  $hunk = New-Hunk -OldStart 1 -OldCount 1 -NewStart 1 -NewCount 2 -BodyLines @(' line1', '+line2')
  #>
  [CmdletBinding()]
  param(
    # 1-based start line in the OLD file (the '-' side).
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$OldStart,

    # Number of lines in the OLD file covered by this hunk.
    [Parameter(Mandatory = $true)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$OldCount,

    # 1-based start line in the NEW file (the '+' side).
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$NewStart,

    # Number of lines in the NEW file covered by this hunk.
    [Parameter(Mandatory = $true)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$NewCount,

    # Body lines of the hunk (not including the @@ header). Typically each line begins with ' ', '+', '-', or '\\'.
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string[]]$BodyLines
  )

  $header = "@@ -$OldStart,$OldCount +$NewStart,$NewCount @@"

  if ($null -eq $BodyLines -or $BodyLines.Count -eq 0) {
    return $header + "`n"
  }

  # Unified diff hunk body lines must start with one of: ' ' (context), '+' (add), '-' (remove), or '\\' (no newline marker).
  # A truly blank context line is represented by a single space character, NOT an empty string.
  return $header + "`n" + (($BodyLines | ForEach-Object {
        if ($null -eq $_) { return ' ' }
        if ($_.Length -eq 0) { return ' ' }
        return $_
      }) -join "`n") + "`n"
}

function New-Range {
  <#
  .SYNOPSIS
  Creates a range object that can convert between (Line, Column) and Index for a file.

  .DESCRIPTION
  Builds a simple range object for a file path that supports conversion between:
  - 1-based (Line, Column) coordinates, and
  - 0-based character Index into the file content.

  The file is read as-is (no newline normalization). This means indexes are based on the exact
  content returned by `Get-Content -Raw`.

  The returned object caches its `ToString()` value to avoid surprises if properties are later mutated.

  .PARAMETER Path
  Path to the file to base the range calculations on.

  .PARAMETER Line
  1-based line number.

  .PARAMETER Column
  1-based column number.

  .PARAMETER Index
  0-based character index into the file content.

  .PARAMETER Length
  Length (in characters). This module currently uses Length primarily for bookkeeping/tests.

  .OUTPUTS
  System.Management.Automation.PSCustomObject
  Object with properties: Path, Line, Column, Index, Length.

  .EXAMPLE
  # From line/column to index
  $r = New-Range -Path './b.txt' -Line 2 -Column 5 -Length 3
  $r.Index

  .EXAMPLE
  # From index to line/column
  $r = New-Range -Path './b.txt' -Index 10 -Length 1
  "$($r.Line):$($r.Column)"
  #>
  [CmdletBinding(DefaultParameterSetName = 'ByLineColumn')]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByLineColumn')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Line,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByLineColumn')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Column,

    # 0-based index into the file contents.
    [Parameter(Mandatory = $true, ParameterSetName = 'ByIndex')]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$Index,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$Length
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Path not found: $Path"
  }

  # Use the file contents as-is (no newline normalization); indexes are in characters.
  $text = Get-Content -LiteralPath $Path -Raw

  # Precompute line starts (0-based indices) for fast conversion.
  $lineStarts = New-Object System.Collections.Generic.List[int]
  $lineStarts.Add(0) | Out-Null

  for ($i = 0; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq "`n") {
      $lineStarts.Add($i + 1) | Out-Null
    }
  }

  function Resolve-IndexFromLineColumn {
    param(
      [int]$InLine,
      [int]$InColumn
    )

    if ($InLine -gt $lineStarts.Count) {
      throw "Line $InLine is out of range for file '$Path' which has $($lineStarts.Count) line(s)."
    }

    $start = $lineStarts[$InLine - 1]
    $idx = $start + ($InColumn - 1)
    if ($idx -lt 0 -or $idx -gt $text.Length) {
      throw "Line/Column ($InLine,$InColumn) resolves to index $idx which is out of range for file '$Path' length $($text.Length)."
    }
    return $idx
  }

  function Resolve-LineColumnFromIndex {
    param(
      [int]$InIndex
    )

    if ($InIndex -lt 0 -or $InIndex -gt $text.Length) {
      throw "Index $InIndex is out of range for file '$Path' length $($text.Length)."
    }

    # Find the last line start <= index.
    $lineNumber = 1
    $lineStart = 0
    for ($j = 0; $j -lt $lineStarts.Count; $j++) {
      $s = $lineStarts[$j]
      if ($s -le $InIndex) {
        $lineNumber = $j + 1
        $lineStart = $s
      }
      else {
        break
      }
    }
    $col = ($InIndex - $lineStart) + 1
    return @{ Line = $lineNumber; Column = $col }
  }

  if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
    $lc = Resolve-LineColumnFromIndex -InIndex $Index
    $Line = [int]$lc.Line
    $Column = [int]$lc.Column
  }
  else {
    $Index = Resolve-IndexFromLineColumn -InLine $Line -InColumn $Column
  }

  $cached = "${Path}:${Line}:${Column}+${Length}"

  $obj = [PSCustomObject]@{
    Path   = $Path
    Line   = $Line
    Column = $Column
    Index  = $Index
    Length = $Length
  }

  # Cache ToString() output so it doesn't depend on later property mutations.
  $obj | Add-Member -MemberType NoteProperty -Name '_ToString' -Value $cached -Force
  $obj | Add-Member -MemberType ScriptMethod -Name 'ToString' -Value { $this._ToString } -Force

  return $obj
}

function Get-GitFileDiffSection {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CombinedPatch,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$FilePath
  )

  $parts = $CombinedPatch -split '(?m)^diff --git '
  if ($parts[0] -eq '') {
    if ($parts.Length -eq 1) {
      return $null
    }

    $parts = $parts[1..($parts.Length - 1)]
  }

  foreach ($part in $parts) {
    if ([string]::IsNullOrWhiteSpace($part)) {
      continue
    }

    $section = "diff --git $part"
    $escapedFilePath = [regex]::Escape($FilePath)
    if ($section -match "(?m)^diff --git a/$escapedFilePath b/$escapedFilePath$") {
      return $section
    }

    if ($section -match 'a/(.+?)\s+b/' -and $matches[1] -eq $FilePath) {
      return $section
    }
  }

  return $null
}

function New-SplitCommitPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Ref,

    [Parameter(Mandatory = $true)]
    [object[]]$NewCommitRanges
  )

  $repoRoot = (Invoke-GitQuery -ErrorMessage 'Split-Commit must be run inside a git repository.' rev-parse --show-toplevel).Output.Trim()
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Split-Commit must be run inside a git repository.'
  }

  $currentRef = (Invoke-GitQuery -ErrorMessage 'Failed to get current ref.' rev-parse --abbrev-ref HEAD).Output.Trim()
  if ([string]::IsNullOrWhiteSpace($currentRef)) {
    throw 'Failed to get current ref.'
  }

  $oldHead = Resolve-GitCommit -Ref 'HEAD' -ErrorMessage 'Unable to determine HEAD.'
  $target = Resolve-GitCommit -Ref $Ref -ErrorMessage "Unable to resolve Ref '$Ref'."
  $parent = Resolve-GitCommit -Ref "$target^" -ErrorMessage "Unable to resolve parent for Ref '$Ref' ($target)."

  $subjectQuery = Invoke-GitQuery -AllowFailure -GitArgs @('log', '-1', '--pretty=format:%s', $target)
  $subject = if ($subjectQuery.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($subjectQuery.Output)) {
    $subjectQuery.Output.Trim()
  }
  else {
    "Split $target"
  }

  $afterTargetQuery = Invoke-GitQuery -ErrorMessage "git rev-list failed for range $target..$oldHead" -GitArgs @('rev-list', '--reverse', "$target..$oldHead")
  $afterTarget = @(
    $afterTargetQuery.Lines |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  $patchLines = @(
    & git show --pretty=format: --no-color $target 2>&1 |
      ForEach-Object {
        if ($null -ne $_) {
          if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.ToString()
          }
          else {
            "$_"
          }
        }
      }
  )
  $patchExitCode = $LASTEXITCODE
  $patchText = $patchLines -join "`n"
  if ($patchExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($patchText)) {
    throw "git show failed to produce patch for $target."
  }

  $filePatches = Split-Patch -patch $patchText
  if (-not $filePatches -or $filePatches.Count -eq 0) {
    throw "No file patches found in commit $target."
  }

  $rangesByPath = @{}
  foreach ($range in $NewCommitRanges) {
    if ($null -eq $range) {
      continue
    }

    $path = $range.Path
    if (-not $path) {
      throw 'NewCommitRanges elements must include Path.'
    }

    if (-not $rangesByPath.ContainsKey($path)) {
      $rangesByPath[$path] = @()
    }

    $rangesByPath[$path] += $range
  }

  $perFilePieces = @{}
  foreach ($filePatch in $filePatches) {
    $path = $filePatch.FilePath
    $hunks = @($filePatch.Patches)
    $splitPoints = @()
    if ($rangesByPath.ContainsKey($path)) {
      $splitPoints = @($rangesByPath[$path] | Where-Object { $_.Line } | Sort-Object { [int]$_.Line })
    }

    if ($splitPoints.Count -gt 0 -and $hunks.Count -ne 1) {
      throw "Split-Commit currently supports splitting only files with exactly 1 hunk. File '$path' has $($hunks.Count)."
    }

    if ($splitPoints.Count -eq 0) {
      $perFilePieces[$path] = @($hunks)
      continue
    }

    $pieces = @($hunks[0])
    foreach ($splitPoint in $splitPoints) {
      if (-not ($splitPoint.PSObject.Properties.Name -contains 'Line') -or $null -eq $splitPoint.Line -or [string]::IsNullOrWhiteSpace([string]$splitPoint.Line)) {
        throw "Split-Commit: NewCommitRanges elements must include Line for path '$path'."
      }

      $line = [int]$splitPoint.Line
      $column = if ($splitPoint.PSObject.Properties.Name -contains 'Column' -and $splitPoint.Column) { [int]$splitPoint.Column } else { 1 }
      $splitResult = Split-Hunk -Hunk $pieces[-1] -Line $line -Column $column
      if ($pieces.Count -le 1) {
        $pieces = @($splitResult)
      }
      else {
        $pieces = @($pieces[0..($pieces.Count - 2)] + $splitResult)
      }
    }

    $perFilePieces[$path] = @($pieces)
  }

  $pieceCount = 1
  foreach ($path in $perFilePieces.Keys) {
    $pathPieceCount = @($perFilePieces[$path]).Count
    if ($pathPieceCount -gt $pieceCount) {
      $pieceCount = $pathPieceCount
    }
  }

  $piecePlans = @()
  for ($i = 0; $i -lt $pieceCount; $i++) {
    $combinedPatch = ''
    foreach ($filePatch in $filePatches) {
      $path = $filePatch.FilePath
      $section = Get-GitFileDiffSection -CombinedPatch $patchText -FilePath $path
      if (-not $section) {
        throw "Unable to locate diff section for '$path' in commit patch."
      }

      $pieces = @($perFilePieces[$path])
      if ($i -ge $pieces.Count) {
        continue
      }

      $pieceHunk = $pieces[$i]
      if ($pieceHunk -notmatch '(?m)^[+-](?![+-]{2})') {
        continue
      }

      $hunkStart = $section.IndexOf('@@')
      if ($hunkStart -lt 0) {
        throw "Diff section for '$path' did not contain a hunk header."
      }

      $prefix = $section.Substring(0, $hunkStart)
      $prefix = $prefix -replace '(?m)^index .*\r?\n', ''
      $combinedPatch += ($prefix + $pieceHunk.TrimEnd("`r", "`n") + "`n")
    }

    if ([string]::IsNullOrWhiteSpace($combinedPatch)) {
      continue
    }

    $piecePlans += [PSCustomObject]@{
      PieceNumber   = $i + 1
      TotalPieces   = $pieceCount
      PatchPath     = New-GitSplitTempFilePath -Prefix ("split-commit-$($i + 1)") -Extension '.patch'
      PatchContent  = $combinedPatch
      CommitMessage = "$subject (split $($i + 1)/$pieceCount)"
    }
  }

  $steps = @()
  $steps += New-GitStep -Kind Comment -Lines @(
    'Split-Commit execution plan.',
    'Split patch artifacts are inlined below as here-strings so the generated script is self-contained and reviewable.'
  )

  $variableLines = @(
    '$expectedRepoRoot = ' + (ConvertTo-PowerShellStringLiteral $repoRoot)
    '$expectedCurrentRef = ' + (ConvertTo-PowerShellStringLiteral $currentRef)
    '$expectedOldHead = ' + (ConvertTo-PowerShellStringLiteral $oldHead)
    '$parentCommit = ' + (ConvertTo-PowerShellStringLiteral $parent)
    '$createdSplitCommits = New-Object System.Collections.Generic.List[string]'
    '$keepSplitPatch = ($env:IMMYBUILD_KEEP_SPLIT_PATCH -eq ''1'') -or ($env:IMMYBUILD_KEEP_TEMPREPO -eq ''1'')'
  )

  if ($afterTarget.Count -gt 0) {
    $variableLines += '$replayCommits = @('
    $variableLines += @($afterTarget | ForEach-Object { '  ' + (ConvertTo-PowerShellStringLiteral $_) })
    $variableLines += ')'
  }
  else {
    $variableLines += '$replayCommits = @()'
  }

  if ($piecePlans.Count -gt 0) {
    foreach ($piecePlan in $piecePlans) {
      $pieceId = $piecePlan.PieceNumber
      $variableLines += '$splitPiece' + $pieceId + 'PatchPath = ' + (ConvertTo-PowerShellStringLiteral $piecePlan.PatchPath)
      $variableLines += '$splitPiece' + $pieceId + 'CommitMessage = ' + (ConvertTo-PowerShellStringLiteral $piecePlan.CommitMessage)
      $variableLines += ConvertTo-PowerShellHereStringLines -AssignmentPrefix ('$splitPiece' + $pieceId + 'PatchContent = ') -Value $piecePlan.PatchContent
    }

    $variableLines += '$splitPieces = @('
    foreach ($piecePlan in $piecePlans) {
      $pieceId = $piecePlan.PieceNumber
      $patchPathVariable = ('$splitPiece{0}PatchPath' -f $pieceId)
      $patchContentVariable = ('$splitPiece{0}PatchContent' -f $pieceId)
      $commitMessageVariable = ('$splitPiece{0}CommitMessage' -f $pieceId)
      $variableLines += @(
        '  @{'
        ('    PatchPath = {0}' -f $patchPathVariable)
        ('    PatchContent = {0}' -f $patchContentVariable)
        ('    CommitMessage = {0}' -f $commitMessageVariable)
        '  }'
      )
    }
    $variableLines += ')'
  }
  else {
    $variableLines += '$splitPieces = @()'
  }

  $steps += New-GitStep -Kind Literal -Lines $variableLines

  $steps += New-GitStep -Kind Comment -Lines @(
    'Runtime guards: ensure the script is run from the same repository state it was planned against.'
  )

  $steps += New-GitStep -Kind Literal -Lines @(
    '$repoRoot = (& git rev-parse --show-toplevel).Trim()',
    'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {',
    '  throw "Split-Commit must be run inside a git repository."',
    '}',
    'if ($repoRoot -ne $expectedRepoRoot) {',
    '  throw "This script was generated for repo root ''$expectedRepoRoot'' but is running in ''$repoRoot''."',
    '}',
    '$currentRef = (& git rev-parse --abbrev-ref HEAD).Trim()',
    'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentRef)) {',
    '  throw "Failed to get current ref."',
    '}',
    'if ($currentRef -ne $expectedCurrentRef) {',
    '  throw "This script expected ref ''$expectedCurrentRef'' but found ''$currentRef''."',
    '}',
    '$currentHead = (& git rev-parse HEAD).Trim()',
    'if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch ''^[0-9a-f]{40}$'') {',
    '  throw "Unable to determine HEAD."',
    '}',
    'if ($currentHead -ne $expectedOldHead) {',
    '  throw "This script expected HEAD ''$expectedOldHead'' but found ''$currentHead''."',
    '}'
  )

  $executionLines = @(
    'try {',
    '  & git reset --hard $parentCommit 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }',
    '  if ($LASTEXITCODE -ne 0) {',
    '    throw "git reset --hard $parentCommit failed with exit code $LASTEXITCODE"',
    '  }',
    '',
    '  foreach ($splitPiece in $splitPieces) {',
    '    $patchParent = Split-Path -Parent $splitPiece.PatchPath',
    '    if (-not [string]::IsNullOrWhiteSpace($patchParent) -and -not (Test-Path -LiteralPath $patchParent)) {',
    '      New-Item -Path $patchParent -ItemType Directory -Force | Out-Null',
    '    }',
    '    $patchContent = $splitPiece.PatchContent.TrimEnd("`r", "`n") + "`n"',
    '    Set-Content -LiteralPath $splitPiece.PatchPath -Value $patchContent -Encoding utf8 -NoNewline',
    '    & git apply --whitespace=nowarn --unidiff-zero $splitPiece.PatchPath 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }',
    '    if ($LASTEXITCODE -ne 0) {',
    '      throw "git apply failed for split patch $($splitPiece.PatchPath)."',
    '    }',
    '    & git add -A 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }',
    '    if ($LASTEXITCODE -ne 0) {',
    '      throw "git add -A failed"',
    '    }',
    '    & git diff --cached --quiet',
    '    if ($LASTEXITCODE -eq 0) {',
    '      continue',
    '    }',
    '    & git commit -m $splitPiece.CommitMessage 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }',
    '    if ($LASTEXITCODE -ne 0) {',
    '      throw "git commit failed while creating split commit ''$($splitPiece.CommitMessage)''."',
    '    }',
    '    $newSha = (& git rev-parse HEAD).Trim()',
    '    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($newSha)) {',
    '      throw "Unable to resolve SHA for newly created split commit ''$($splitPiece.CommitMessage)''."',
    '    }',
    '    $createdSplitCommits.Add($newSha) | Out-Null',
    '  }',
    '',
    '  foreach ($replayCommit in $replayCommits) {',
    '    & git cherry-pick $replayCommit 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }',
    '    if ($LASTEXITCODE -ne 0) {',
    '      throw "git cherry-pick failed for $replayCommit"',
    '    }',
    '  }',
    '}',
    'finally {',
    '  if (-not $keepSplitPatch) {',
    '    foreach ($splitPiece in $splitPieces) {',
    '      if (Test-Path -LiteralPath $splitPiece.PatchPath) {',
    '        Remove-Item -LiteralPath $splitPiece.PatchPath -Force -ErrorAction SilentlyContinue',
    '      }',
    '    }',
    '  }',
    '}',
    '$createdSplitCommits.ToArray()'
  )

  $steps += New-GitStep -Kind Comment -Lines @(
    'Reset to the target parent, materialize each inlined patch, create split commits, then replay later commits.'
  )
  $steps += New-GitStep -Kind Literal -Lines $executionLines

  return New-GitPlan -Name 'Split-Commit' -Metadata @{
    CurrentRef          = $currentRef
    OldHead             = $oldHead
    TargetCommit        = $target
    ParentCommit        = $parent
    PieceCount          = $pieceCount
    OutputScriptCapable = $true
    PatchArtifactMode   = 'InlineHereString'
  } -Steps $steps
}

function Split-Commit {
  <#
  .SYNOPSIS
  Splits a single git commit into multiple commits by splitting hunks.

  .DESCRIPTION
  Rewrites git history by taking the commit identified by `-Ref`, splitting one or more file hunks
  at specified NEW-file line/column split points, then recreating the original commit as multiple
  commits ("split pieces").

  After the split commits are created, any commits that were originally after the target commit are
  cherry-picked back on top, preserving the overall history (but with a different commit graph).

  This is intended for developer workflow tooling and should be used with care.

  .PARAMETER Ref
  The commit-ish to split (e.g. 'HEAD' or a SHA).

  .PARAMETER NewCommitRanges
  One or more split point objects. Each object must include:
    - Path   : file path (as seen in the patch, e.g. 'src/file.txt')
    - Line   : 1-based NEW-file line number where the next split piece begins
  Optional:
    - Column : 1-based column for mid-line splitting (defaults to 1)
    - Length : currently ignored (reserved for future range splitting)

  .PARAMETER OutputScriptPath
  If specified, writes a reviewable PowerShell script with inline split patch artifacts
  instead of executing the rewrite immediately.

  .OUTPUTS
  System.String[]
  An array of SHAs for the split commits created (in creation order).

  .EXAMPLE
  # Split HEAD's b.txt changes so NEW-file line 2 begins a new commit
  $created = Split-Commit -Ref HEAD -NewCommitRanges @(
    [pscustomobject]@{ Path = 'b.txt'; Line = 2 }
  )
  $created

  .NOTES
  - This command performs `git reset --hard` and `git cherry-pick`, and will rewrite commits.
  - Run this only on local branches (or be prepared to force push).
  - Currently supports splitting only files that have exactly one hunk in the target commit.
  #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([string[]])]
  param(
    # Commit to split (commit-ish). Typically use HEAD.
    [Parameter(Mandatory = $true)]
    [string]$Ref,

    # One or more split points.
    # Each element must include:
    #  - Path
    #  - Line (1-based, NEW-file line number)
    # Optional:
    #  - Column (1-based; defaults to 1)
    #  - Length (currently ignored; reserved for future range splitting)
    [Parameter(Mandatory = $true)]
    [object[]]$NewCommitRanges,

    [Parameter()]
    [string]$OutputScriptPath
  )

  $plan = New-SplitCommitPlan -Ref $Ref -NewCommitRanges $NewCommitRanges

  if ($OutputScriptPath) {
    if ($PSCmdlet.ShouldProcess($OutputScriptPath, 'Write Split-Commit execution script')) {
      return Write-GitScript -Plan $plan -Path $OutputScriptPath
    }

    return
  }

  $action = "Split commit $($plan.Metadata.TargetCommit) from $($plan.Metadata.CurrentRef)"
  if ($PSCmdlet.ShouldProcess($plan.Metadata.CurrentRef, $action)) {
    return Invoke-GitPlan -Plan $plan
  }
}

function Add-Commit {
  <#
  .SYNOPSIS
  Deterministically inserts a new commit by applying a patch while replaying history.

  .DESCRIPTION
  Rewrites history starting "after" a given commit-ish by:
    1) resetting to the `-After` commit,
    2) cherry-picking a small number of subsequent commits to reach the intended insertion point,
    3) applying `-PatchFile` and committing it with `-CommitMessage`,
    4) cherry-picking any remaining commits.

  This avoids interactive rebase editor flows, which can be brittle across environments.

  .PARAMETER RepoPath
  Path to the git repository to operate on. Defaults to the current directory.

  .PARAMETER After
  The commit-ish *before* the range to rewrite (e.g. 'HEAD~2'). The rewrite starts from this commit.

  .PARAMETER PatchFile
  Path to a patch file to apply (unified diff).

  .PARAMETER CommitMessage
  Commit message to use for the inserted patch commit.

  .EXAMPLE
  Add-Commit -After HEAD~3 -PatchFile ./fix.patch -CommitMessage "Fix lint"

  .NOTES
  This command rewrites history and may require force pushing if run on a published branch.
  #>
  [CmdletBinding()]
  param(
    # Path to the git repository to operate on.
    [Parameter(Mandatory = $false)]
    [string]$RepoPath,

    # The commit-ish *before* the range we want to rewrite (e.g. HEAD~2)
    [Parameter(Mandatory = $true)]
    [string]$After,

    # Patch file to apply while paused at the newer commit.
    [Parameter(Mandatory = $true)]
    [string]$PatchFile,

    # Commit message for the patch commit.
    [Parameter(Mandatory = $true)]
    [string]$CommitMessage
  )

  if (-not $RepoPath) {
    $RepoPath = (Get-Location).Path
  }

  $oldSeq = $env:GIT_SEQUENCE_EDITOR
  $oldEd = $env:GIT_EDITOR

  Push-Location $RepoPath
  try {
    # Implement the desired "stop at newer commit" behavior deterministically without relying on
    # interactive rebase editors (which can be brittle in CI / different git versions).
    #
    # 1) Enumerate commits to replay (oldest -> newest)
    # 2) Reset to Upstream
    # 3) Cherry-pick the older commit(s)
    # 4) Cherry-pick the newer commit (our "stop" point)
    # 5) Apply patches + commit
    # 6) Cherry-pick any remaining commits

    $env:GIT_SEQUENCE_EDITOR = $null
    $env:GIT_EDITOR = ':'

    $commits = @(git rev-list --reverse "$After..HEAD")
    if ($LASTEXITCODE -ne 0) {
      throw "git rev-list failed for range $After..HEAD with exit code $LASTEXITCODE"
    }
    if ($commits.Count -eq 1 -and $commits[0] -is [string] -and $commits[0] -match "\r?\n") {
      $commits = $commits[0] -split "\r?\n"
    }
    $commits = @($commits | Where-Object { $_ -and $_.Trim() })
    if ($commits.Count -lt 1) {
      throw "Expected at least 1 commit to replay in range $After..HEAD, found $($commits.Count)."
    }

    $olderCommit = $null
    $newerCommit = $commits[0]
    $remainingCommits = @()
    if ($commits.Count -ge 2) {
      $olderCommit = $commits[0]
      $newerCommit = $commits[1]
      if ($commits.Count -gt 2) {
        $remainingCommits = $commits[2..($commits.Count - 1)]
      }
    }
    elseif ($commits.Count -eq 1) {
      # With only one commit in the range, that commit is effectively the "newer" stop point.
      $olderCommit = $null
      $newerCommit = $commits[0]
      $remainingCommits = @()
    }

    git reset --hard $After | Out-Null
    if ($LASTEXITCODE -ne 0) {
      # Preserve existing behavior for callers that rely on stdout/stderr of reset.
      throw "git reset --hard $After failed with exit code $LASTEXITCODE"
    }

    if ($olderCommit) {
      Invoke-Git -ErrorMessage "git cherry-pick (older) failed for $olderCommit" cherry-pick $olderCommit
    }

    Invoke-Git -ErrorMessage "git cherry-pick (newer) failed for $newerCommit" cherry-pick $newerCommit

    if (-not (Test-Path $PatchFile)) {
      throw "Patch file not found: $PatchFile"
    }

    # Apply patch in a way that tolerates rewritten history (index/blob hashes may differ).
    try {
      Invoke-Git -ErrorMessage "git apply failed for $PatchFile" apply --whitespace=nowarn $PatchFile
    }
    catch {
      # Retry with 3-way apply; if this fails, bubble up diagnostics.
      Invoke-Git -ErrorMessage "git apply --3way failed for $PatchFile" apply --whitespace=nowarn --3way $PatchFile
    }

    Invoke-Git -ErrorMessage 'git add -A' add -A
    Invoke-Git -ErrorMessage "git commit failed for patch $PatchFile (message: $CommitMessage)" commit -m $CommitMessage

    foreach ($c in $remainingCommits) {
      Invoke-Git -ErrorMessage "git cherry-pick (remaining) failed for $c" cherry-pick $c
    }
  }
  finally {
    Pop-Location
    $env:GIT_SEQUENCE_EDITOR = $oldSeq
    $env:GIT_EDITOR = $oldEd
  }
}

function New-RemoveCommitPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^HEAD(~\d+)?$|^[0-9a-f]{7,40}$")]
    [string]$CommitRef,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Branch,

    [Parameter()]
    [switch]$Push,

    [Parameter()]
    [switch]$ForcePush
  )

  $repoRoot = Get-GitRepoRoot
  $currentBranch = Get-GitCurrentBranch
  $currentHead = Resolve-GitCommit -Ref 'HEAD' -ErrorMessage 'Failed to resolve HEAD.'

  if (-not $Branch) {
    $Branch = $currentBranch
  }

  if ($Branch -eq 'HEAD') {
    throw "You are in a detached HEAD state. Checkout a branch before calling Remove-Commit."
  }

  $commitHash = Resolve-GitCommit -Ref $CommitRef -ErrorMessage "Failed to resolve commit reference '$CommitRef'."
  $rewritePlan = New-CommitRemovalRewritePlan -CommitHash $commitHash -Branch $Branch -Push:$Push -ForcePush:$ForcePush
  $usesCurrentBranchReset = ($rewritePlan.Mode -eq 'ResetToParent' -and $currentBranch -eq $Branch)

  $steps = @()
  $steps += New-GitStep -Kind Comment -Lines @(
    'Remove-Commit execution plan.',
    'Discovery-time values are frozen below; runtime checks ensure the repository and branch state have not drifted.'
  )

  $steps += New-GitStep -Kind Literal -Lines @(
    '$expectedRepoRoot = ' + (ConvertTo-PowerShellStringLiteral $repoRoot)
    '$expectedCurrentBranch = ' + (ConvertTo-PowerShellStringLiteral $currentBranch)
    '$expectedCurrentHead = ' + (ConvertTo-PowerShellStringLiteral $currentHead)
    '$targetBranch = ' + (ConvertTo-PowerShellStringLiteral $Branch)
    '$expectedBranchHead = ' + (ConvertTo-PowerShellStringLiteral $rewritePlan.BranchHead)
    '$commitHash = ' + (ConvertTo-PowerShellStringLiteral $rewritePlan.CommitHash)
    '$parentHash = ' + (ConvertTo-PowerShellStringLiteral $rewritePlan.ParentHash)
    '$removeMode = ' + (ConvertTo-PowerShellStringLiteral $rewritePlan.Mode)
    '$usesCurrentBranchReset = ' + $(if ($usesCurrentBranchReset) { '$true' } else { '$false' })
    '$pushBranch = ' + $(if ($rewritePlan.Push) { '$true' } else { '$false' })
    '$forcePush = ' + $(if ($rewritePlan.ForcePush) { '$true' } else { '$false' })
  )

  $steps += New-GitStep -Kind Comment -Lines @(
    'Runtime guards: assert repository, current HEAD, current branch, and target branch head before rewriting history.'
  )

  $guardLines = @(
    '$repoRoot = (& git rev-parse --show-toplevel).Trim()'
    'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {'
    '  throw "Remove-Commit must be run inside a git repository."'
    '}'
    'if ($repoRoot -ne $expectedRepoRoot) {'
    '  throw "This script was generated for repo root ''$expectedRepoRoot'' but is running in ''$repoRoot''."'
    '}'
    '$currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()'
    'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentBranch)) {'
    '  throw "Failed to get current branch."'
    '}'
    'if ($currentBranch -ne $expectedCurrentBranch) {'
    '  throw "This script expected current branch ''$expectedCurrentBranch'' but found ''$currentBranch''."'
    '}'
    '$currentHead = (& git rev-parse HEAD).Trim()'
    'if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch ''^[0-9a-f]{40}$'') {'
    '  throw "Failed to resolve HEAD."'
    '}'
    'if ($currentHead -ne $expectedCurrentHead) {'
    '  throw "This script expected HEAD ''$expectedCurrentHead'' but found ''$currentHead''."'
    '}'
    '$branchHead = (& git rev-parse $targetBranch).Trim()'
    'if ($LASTEXITCODE -ne 0 -or $branchHead -notmatch ''^[0-9a-f]{40}$'') {'
    '  throw "Failed to resolve branch ''$targetBranch''."'
    '}'
    'if ($branchHead -ne $expectedBranchHead) {'
    '  throw "This script expected branch ''$targetBranch'' at ''$expectedBranchHead'' but found ''$branchHead''."'
    '}'
  )
  $steps += New-GitStep -Kind Literal -Lines $guardLines

  $executionLines = @(
    'if ($removeMode -eq ''ResetToParent'') {'
    '  if ($usesCurrentBranchReset) {'
    '    & git reset --hard $parentHash 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '    if ($LASTEXITCODE -ne 0) {'
    '      throw "git reset --hard failed while removing $commitHash from $targetBranch"'
    '    }'
    '  }'
    '  else {'
    '    & git branch -f $targetBranch $parentHash 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '    if ($LASTEXITCODE -ne 0) {'
    '      throw "git branch -f failed while removing $commitHash from $targetBranch"'
    '    }'
    '  }'
    '}'
    'elseif ($removeMode -eq ''RebaseOntoParent'') {'
    '  & git rebase --onto $parentHash $commitHash $targetBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '  if ($LASTEXITCODE -ne 0) {'
    '    throw "git rebase --onto failed while removing $commitHash from $targetBranch"'
    '  }'
    '}'
    'else {'
    '  throw "Unsupported remove mode ''$removeMode''."'
    '}'
  )

  if ($rewritePlan.Push) {
    if ($rewritePlan.ForcePush) {
      $executionLines += @(
        'if ($pushBranch) {'
        '  & git push --force-with-lease origin $targetBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
        '  if ($LASTEXITCODE -ne 0) {'
        '    throw "git push --force-with-lease origin $targetBranch failed"'
        '  }'
        '}'
      )
    }
    else {
      $executionLines += @(
        'if ($pushBranch) {'
        '  & git push origin $targetBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
        '  if ($LASTEXITCODE -ne 0) {'
        '    throw "git push origin $targetBranch failed"'
        '  }'
        '}'
      )
    }
  }

  $executionLines += '$targetBranch'

  $steps += New-GitStep -Kind Comment -Lines @(
    'Rewrite the target branch using the plan-time-selected strategy, then optionally push the updated ref.'
  )
  $steps += New-GitStep -Kind Literal -Lines $executionLines

  return New-GitPlan -Name 'Remove-Commit' -Metadata @{
    Branch                 = $Branch
    CommitHash             = $rewritePlan.CommitHash
    BranchHead             = $rewritePlan.BranchHead
    ParentHash             = $rewritePlan.ParentHash
    Mode                   = $rewritePlan.Mode
    UsesCurrentBranchReset = $usesCurrentBranchReset
    Push                   = [bool]$rewritePlan.Push
    ForcePush              = [bool]$rewritePlan.ForcePush
    OutputScriptCapable    = $true
  } -Steps $steps
}

function Remove-Commit {
  <#
  .SYNOPSIS
  Removes a commit from a branch by rewriting history.

  .DESCRIPTION
  Removes a commit from a given branch.

  - If the commit is HEAD, this uses `git reset --hard HEAD~1`.
  - If the commit is not HEAD, this uses `git rebase --onto <commit^> <commit> <branch>`
    which replays commits after the target commit onto its parent.

  This command rewrites history and may require force pushing.

  .PARAMETER CommitRef
  Commit-ish to remove (SHA, HEAD, etc.).

  .PARAMETER Branch
  Branch to remove the commit from. Defaults to the current branch.

  .PARAMETER Push
  If specified, pushes the rewritten branch to origin.

  .PARAMETER ForcePush
  If specified and -Push is set, uses --force-with-lease.

  .PARAMETER OutputScriptPath
  If specified, writes a reviewable PowerShell script that performs the planned removal later
  instead of executing it immediately.

  .OUTPUTS
  System.String
  The rewritten branch name when executed immediately, or the written script path when
  -OutputScriptPath is used.
  #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([string])]
  param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidatePattern("^HEAD(~\d+)?$|^[0-9a-f]{7,40}$")]
    [string]$CommitRef,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Branch,

    [Parameter()]
    [switch]$Push,

    [Parameter()]
    [switch]$ForcePush,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputScriptPath
  )

  $planArgs = @{
    CommitRef = $CommitRef
    Push      = $Push
    ForcePush = $ForcePush
  }
  if (-not [string]::IsNullOrWhiteSpace($Branch)) {
    $planArgs.Branch = $Branch
  }

  $plan = New-RemoveCommitPlan @planArgs

  if ($OutputScriptPath) {
    if ($PSCmdlet.ShouldProcess($OutputScriptPath, 'Write Remove-Commit execution script')) {
      return Write-GitScript -Plan $plan -Path $OutputScriptPath
    }

    return
  }

  $action = if ($plan.Metadata.Mode -eq 'ResetToParent') {
    "Remove branch tip commit $($plan.Metadata.CommitHash) from $($plan.Metadata.Branch)"
  }
  else {
    "Remove historical commit $($plan.Metadata.CommitHash) from $($plan.Metadata.Branch)"
  }

  if ($PSCmdlet.ShouldProcess($plan.Metadata.Branch, $action)) {
    return Invoke-GitPlan -Plan $plan
  }
}

function New-GitSplitAbsorbPlan {
  [CmdletBinding()]
  [OutputType([psobject])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$From
  )

  $unstagedFiles = @(
    git diff --name-only |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to inspect unstaged changes before absorb."
  }
  if ($unstagedFiles.Count -gt 0) {
    throw "Invoke-GitSplitAbsorb requires staged-only changes. Stage or stash unstaged changes before using -Absorb."
  }

  $stagedFiles = @(
    git diff --cached --name-only |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to inspect staged changes before absorb."
  }
  if ($stagedFiles.Count -eq 0) {
    return [PSCustomObject]@{
      From        = $From
      StagedFiles = @()
      Targets     = @()
    }
  }

  $targetByFile = @{}
  $unmatchedFiles = @()
  foreach ($file in $stagedFiles) {
    $targetCommit = @(
      git log --format=%H "$From..HEAD" -- "$file" |
        Select-Object -First 1 |
        ForEach-Object { $_.Trim() }
    )
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to determine absorb target for '$file'."
    }

    if ($targetCommit.Count -eq 0 -or [string]::IsNullOrWhiteSpace($targetCommit[0])) {
      $unmatchedFiles += $file
      continue
    }

    $targetByFile[$file] = $targetCommit[0]
  }

  if ($unmatchedFiles.Count -gt 0) {
    throw "Could not determine absorb target commit(s) for staged file(s): $($unmatchedFiles -join ', ')"
  }

  $orderedTargets = @(
    git rev-list --reverse "$From..HEAD" |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Where-Object { $_ -in $targetByFile.Values }
  )
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to enumerate commit order for absorb."
  }

  $targets = @()
  foreach ($targetCommit in $orderedTargets) {
    $targetFiles = @(
      $targetByFile.GetEnumerator() |
        Where-Object { $_.Value -eq $targetCommit } |
        Sort-Object Name |
        ForEach-Object { $_.Name }
    )
    if ($targetFiles.Count -eq 0) {
      continue
    }

    $targets += [PSCustomObject]@{
      CommitHash = $targetCommit
      Files      = @($targetFiles)
    }
  }

  return [PSCustomObject]@{
    From        = $From
    StagedFiles = @($stagedFiles)
    Targets     = @($targets)
  }
}

function Invoke-GitSplitAbsorb {
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$From
  )

  $plan = New-GitSplitAbsorbPlan -From $From
  $createdFixups = @()
  foreach ($target in @($plan.Targets)) {
    $targetCommit = $target.CommitHash
    $targetFiles = @($target.Files)

    Invoke-Git -Quiet -ErrorMessage "Failed to create fixup commit for absorb target '$targetCommit'." commit --fixup $targetCommit -- @targetFiles

    $fixupCommit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $fixupCommit -notmatch '^[0-9a-f]{40}$') {
      throw "Failed to resolve absorb fixup commit for target '$targetCommit'."
    }
    $createdFixups += $fixupCommit
  }

  return $createdFixups
}

function New-SetCommitOrderSequenceEditorContent {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TodoScriptPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$From,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$OrderedCommits
  )

  $escapedTodoScriptPath = $TodoScriptPath.Replace("'", "''")
  $escapedFrom = $From.Replace("'", "''")
  $scriptLines = @(
    'param([string]$TodoPath)',
    '$ErrorActionPreference = "Stop"',
    "& '$escapedTodoScriptPath' `$TodoPath -From '$escapedFrom' -OrderedCommits @("
  ) + @(
    $OrderedCommits | ForEach-Object { "  '" + $_.Replace("'", "''") + "'" }
  ) + @(
    ')'
  )

  return (($scriptLines -join "`n").TrimEnd()) + "`n"
}

function New-SetCommitOrderPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$OrderedCommits,

    [Parameter()]
    [switch]$Autostash,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BaseRef = "origin/main",

    [Parameter()]
    [switch]$Absorb
  )

  if ($OrderedCommits.Count -eq 0) {
    throw "Provide at least one commit hash to reorder."
  }

  $repoRoot = Get-GitRepoRoot
  $currentBranch = Get-GitCurrentBranch
  if ($currentBranch -eq 'HEAD') {
    throw "Set-CommitOrder must run on a branch (detached HEAD is not supported)."
  }

  $currentHead = Resolve-GitCommit -Ref 'HEAD' -ErrorMessage 'Failed to resolve HEAD.'
  $status = @(
    git status --porcelain |
      ForEach-Object { "$_".TrimEnd() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to determine git status."
  }
  if ($status.Count -gt 0 -and -not $Autostash -and -not $Absorb) {
    throw "Working tree is not clean. Commit/stash changes or re-run with -Autostash."
  }

  $null = Resolve-GitCommit -Ref $BaseRef -ErrorMessage "Base reference '$BaseRef' is not valid."
  $from = (Invoke-GitQuery -ErrorMessage "Failed to determine merge-base between HEAD and '$BaseRef'." merge-base HEAD $BaseRef).Output.Trim()
  if ($from -notmatch '^[0-9a-f]{40}$') {
    throw "Failed to determine merge-base between HEAD and '$BaseRef'."
  }

  $resolvedOrderedCommits = @()
  foreach ($orderedCommit in $OrderedCommits) {
    if ([string]::IsNullOrWhiteSpace($orderedCommit)) {
      continue
    }

    $resolvedCommit = Resolve-GitCommit -Ref $orderedCommit -ErrorMessage "Failed to resolve ordered commit '$orderedCommit'."
    if (-not (Test-GitCommitIsAncestor -Ancestor $resolvedCommit -Descendant 'HEAD')) {
      throw "Commit '$orderedCommit' ($resolvedCommit) is not reachable from current branch '$currentBranch'."
    }
    if (-not (Test-GitCommitIsAncestor -Ancestor $from -Descendant $resolvedCommit)) {
      throw "Commit '$orderedCommit' ($resolvedCommit) is outside the reorder range '$from..HEAD'."
    }

    if ($resolvedCommit -notin $resolvedOrderedCommits) {
      $resolvedOrderedCommits += $resolvedCommit
    }
  }

  if ($resolvedOrderedCommits.Count -eq 0) {
    throw "No valid commits were provided to reorder."
  }

  $absorbPlan = if ($Absorb) { New-GitSplitAbsorbPlan -From $from } else { $null }
  $sequenceEditorScriptPath = New-GitSplitTempFilePath -Prefix 'gitsplit-seq-editor' -Extension '.ps1'
  $todoScriptPath = Join-Path $PSScriptRoot "New-RebaseTodo.ps1"
  if (-not (Test-Path -LiteralPath $todoScriptPath)) {
    throw "Could not find sequence editor helper '$todoScriptPath'."
  }

  $sequenceEditorScriptContent = New-SetCommitOrderSequenceEditorContent -TodoScriptPath $todoScriptPath -From $from -OrderedCommits $resolvedOrderedCommits

  $steps = @()
  $steps += New-GitStep -Kind Comment -Lines @(
    'Set-CommitOrder execution plan.',
    'Discovery-time inputs, helper script contents, and optional absorb targets are frozen below for reviewability.'
  )

  $variableLines = @(
    '$expectedRepoRoot = ' + (ConvertTo-PowerShellStringLiteral $repoRoot)
    '$expectedCurrentBranch = ' + (ConvertTo-PowerShellStringLiteral $currentBranch)
    '$expectedCurrentHead = ' + (ConvertTo-PowerShellStringLiteral $currentHead)
    '$from = ' + (ConvertTo-PowerShellStringLiteral $from)
    '$useAutostash = ' + $(if ($Autostash) { '$true' } else { '$false' })
    '$useAbsorb = ' + $(if ($Absorb) { '$true' } else { '$false' })
    '$sequenceEditorScriptPath = ' + (ConvertTo-PowerShellStringLiteral $sequenceEditorScriptPath)
  )
  $variableLines += ConvertTo-PowerShellHereStringLines -AssignmentPrefix '$sequenceEditorScriptContent = ' -Value $sequenceEditorScriptContent

  if ($absorbPlan -and $absorbPlan.StagedFiles.Count -gt 0) {
    $variableLines += '$expectedAbsorbFiles = @('
    $variableLines += @($absorbPlan.StagedFiles | ForEach-Object { '  ' + (ConvertTo-PowerShellStringLiteral $_) })
    $variableLines += ')'
  }
  else {
    $variableLines += '$expectedAbsorbFiles = @()'
  }

  $steps += New-GitStep -Kind Literal -Lines $variableLines

  $steps += New-GitStep -Kind Comment -Lines @(
    'Runtime guards: assert repository, branch, head commit, and (when absorbing) the exact staged file set.'
  )

  $guardLines = @(
    '$repoRoot = (& git rev-parse --show-toplevel).Trim()'
    'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {'
    '  throw "Set-CommitOrder must be run inside a git repository."'
    '}'
    'if ($repoRoot -ne $expectedRepoRoot) {'
    '  throw "This script was generated for repo root ''$expectedRepoRoot'' but is running in ''$repoRoot''."'
    '}'
    '$currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()'
    'if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentBranch)) {'
    '  throw "Failed to get current branch."'
    '}'
    'if ($currentBranch -ne $expectedCurrentBranch) {'
    '  throw "This script expected branch ''$expectedCurrentBranch'' but found ''$currentBranch''."'
    '}'
    '$currentHead = (& git rev-parse HEAD).Trim()'
    'if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch ''^[0-9a-f]{40}$'') {'
    '  throw "Failed to resolve HEAD."'
    '}'
    'if ($currentHead -ne $expectedCurrentHead) {'
    '  throw "This script expected HEAD ''$expectedCurrentHead'' but found ''$currentHead''."'
    '}'
    '$status = @(& git status --porcelain)'
    'if ($LASTEXITCODE -ne 0) {'
    '  throw "Failed to determine git status."'
    '}'
    '$status = @($status | ForEach-Object { "$_".TrimEnd() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })'
    'if ($status.Count -gt 0 -and -not $useAutostash -and -not $useAbsorb) {'
    '  throw "Working tree is not clean. Commit/stash changes or re-run with -Autostash."'
    '}'
  )

  if ($Absorb) {
    $guardLines += @(
      '$unstagedFiles = @(& git diff --name-only)'
      'if ($LASTEXITCODE -ne 0) {'
      '  throw "Failed to inspect unstaged changes before absorb."'
      '}'
      '$unstagedFiles = @($unstagedFiles | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })'
      'if ($unstagedFiles.Count -gt 0) {'
      '  throw "Invoke-GitSplitAbsorb requires staged-only changes. Stage or stash unstaged changes before using -Absorb."'
      '}'
      '$stagedFiles = @(& git diff --cached --name-only)'
      'if ($LASTEXITCODE -ne 0) {'
      '  throw "Failed to inspect staged changes before absorb."'
      '}'
      '$stagedFiles = @($stagedFiles | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })'
      'if ((($stagedFiles | Sort-Object) -join "`n") -ne (($expectedAbsorbFiles | Sort-Object) -join "`n")) {'
      '  throw "Staged files changed since this script was generated."'
      '}'
    )
  }

  $steps += New-GitStep -Kind Literal -Lines $guardLines

  $executionLines = @(
    '$previousSequenceEditor = $env:GIT_SEQUENCE_EDITOR'
    'try {'
    '  Set-Content -Path $sequenceEditorScriptPath -Value $sequenceEditorScriptContent'
  )

  if ($absorbPlan) {
    foreach ($target in @($absorbPlan.Targets)) {
      $targetFiles = @($target.Files | ForEach-Object { ConvertTo-PowerShellStringLiteral $_ }) -join ' '
      $executionLines += @(
        '  & git commit --fixup ' + (ConvertTo-PowerShellStringLiteral $target.CommitHash) + ' -- ' + $targetFiles + ' 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
        '  if ($LASTEXITCODE -ne 0) {'
        '    throw "Failed to create fixup commit for absorb target ' + $target.CommitHash + '."'
        '  }'
      )
    }
  }

  $executionLines += @(
    '  $env:GIT_SEQUENCE_EDITOR = "pwsh -NoProfile -File `"$sequenceEditorScriptPath`""'
    '  $rebaseArgs = @(''rebase'', ''-i'')'
    '  if ($useAutostash) {'
    '    $rebaseArgs += ''--autostash'''
    '  }'
    '  if ($useAbsorb) {'
    '    $rebaseArgs += ''--autosquash'''
    '  }'
    '  $rebaseArgs += $from'
    '  & git @rebaseArgs 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'
    '  if ($LASTEXITCODE -ne 0) {'
    '    throw "Set-CommitOrder rebase failed. Resolve conflicts and continue/abort rebase manually."'
    '  }'
    '}'
    'finally {'
    '  if ($null -ne $previousSequenceEditor) {'
    '    $env:GIT_SEQUENCE_EDITOR = $previousSequenceEditor'
    '  }'
    '  else {'
    '    Remove-Item Env:GIT_SEQUENCE_EDITOR -ErrorAction SilentlyContinue'
    '  }'
    ''
    '  if (Test-Path -LiteralPath $sequenceEditorScriptPath) {'
    '    Remove-Item -Path $sequenceEditorScriptPath -Force -ErrorAction SilentlyContinue'
    '  }'
    '}'
    '@('
    '  git log --reverse --format=%H "$from..HEAD" |'
    '    ForEach-Object { $_.Trim() } |'
    '    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }'
    ')'
  )

  $steps += New-GitStep -Kind Comment -Lines @(
    'Write the generated sequence editor helper, optionally create absorb fixups, then run the deterministic interactive rebase.'
  )
  $steps += New-GitStep -Kind Literal -Lines $executionLines

  return New-GitPlan -Name 'Set-CommitOrder' -Metadata @{
    CurrentBranch         = $currentBranch
    CurrentHead           = $currentHead
    From                  = $from
    OrderedCommits        = @($resolvedOrderedCommits)
    UseAutostash          = [bool]$Autostash
    UseAbsorb             = [bool]$Absorb
    SequenceEditorPath    = $sequenceEditorScriptPath
    OutputScriptCapable   = $true
  } -Steps $steps
}

function Set-CommitOrder {
  <#
  .SYNOPSIS
  Reorders commits in the current branch without requiring interactive editing.

  .DESCRIPTION
  Reorders commits reachable from the current branch by driving `git rebase -i`
  with a generated sequence editor script.

  When `-Absorb` is specified, staged changes are first converted into `fixup!`
  commits targeting the most recent commit in the selected range that touched each
  staged file, and the rebase runs with `--autosquash`.

  .PARAMETER OutputScriptPath
  If specified, writes a reviewable PowerShell script for the planned reorder
  instead of executing it immediately.
  #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$OrderedCommits,

    [Parameter()]
    [switch]$Autostash,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BaseRef = "origin/main",

    [Parameter()]
    [switch]$Absorb,

    [Parameter()]
    [string]$OutputScriptPath
  )

  try {
    $plan = New-SetCommitOrderPlan -OrderedCommits $OrderedCommits -Autostash:$Autostash -BaseRef $BaseRef -Absorb:$Absorb

    if ($OutputScriptPath) {
      if ($PSCmdlet.ShouldProcess($OutputScriptPath, 'Write Set-CommitOrder execution script')) {
        return Write-GitScript -Plan $plan -Path $OutputScriptPath
      }

      return
    }

    $action = "Reorder commits from $($plan.Metadata.From)..HEAD on $($plan.Metadata.CurrentBranch)"
    if ($plan.Metadata.UseAbsorb) {
      $action += ' with absorb'
    }

    if ($PSCmdlet.ShouldProcess($plan.Metadata.CurrentBranch, $action)) {
      return Invoke-GitPlan -Plan $plan
    }
  }
  catch {
    Write-Error "Failed to set commit order: $_"
    throw
  }
}

function Move-Commit {
  <#
  .SYNOPSIS
  Moves (or copies) a commit from the current branch to another branch.

  .DESCRIPTION
  Applies a commit to a destination branch via cherry-pick.

  To avoid disrupting the caller's working directory, this function uses a temporary
  `git worktree` for the destination branch, so it does NOT need to checkout/switch
  branches in the current working tree.

  Optionally, the commit can be removed from the current branch (history rewrite).
  Removing a non-HEAD commit requires a rebase operation and therefore assumes the
  current branch contains the commit and that you are okay with rewriting history.

  .PARAMETER CommitRef
  Commit-ish to move/copy. Defaults to HEAD.

  .PARAMETER DestinationBranch
  The destination branch to receive the commit. Must exist locally or on origin.

  .PARAMETER RemoveFromSource
  If specified, removes the commit from the current branch after applying it to the destination.
  This rewrites history.

  .PARAMETER Push
  If specified, pushes the destination branch (and source branch if RemoveFromSource) to origin.

  .PARAMETER ForcePushSource
  If specified and RemoveFromSource is set, force-pushes the rewritten source branch.

  .PARAMETER AutoStash
  If specified, stashes uncommitted changes at the start and restores them at the end.
  Without AutoStash, the working tree must be clean.

  .PARAMETER OutputScriptPath
  If specified, writes a reviewable PowerShell script that performs the planned move later
  instead of executing it immediately.

  .OUTPUTS
  System.String
  The destination branch name when executed immediately, or the written script path when
  -OutputScriptPath is used.

  .NOTES
  This command can rewrite history when -RemoveFromSource is specified.
  Prefer using on local/unpublished branches (or be prepared to force push).
  #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([string])]
  param(
    [Parameter(Position = 0)]
    [ValidatePattern("^HEAD(~\d+)?$|^[0-9a-f]{7,40}$")]
    [string]$CommitRef = "HEAD",

    [Parameter(Position = 1, Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationBranch,

    [Parameter()]
    [switch]$RemoveFromSource,

    [Parameter()]
    [switch]$Push,

    [Parameter()]
    [switch]$ForcePushSource,

    [Parameter()]
    [switch]$AutoStash,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputScriptPath
  )

  $plan = New-MoveCommitPlan `
    -CommitRef $CommitRef `
    -DestinationBranch $DestinationBranch `
    -RemoveFromSource:$RemoveFromSource `
    -Push:$Push `
    -ForcePushSource:$ForcePushSource `
    -AutoStash:$AutoStash

  if ($OutputScriptPath) {
    if ($PSCmdlet.ShouldProcess($OutputScriptPath, 'Write Move-Commit execution script')) {
      return Write-GitScript -Plan $plan -Path $OutputScriptPath
    }

    return
  }

  $action = if ($RemoveFromSource) {
    "Move $($plan.Metadata.CommitHash) to $DestinationBranch and remove it from $($plan.Metadata.SourceBranch)"
  }
  else {
    "Copy $($plan.Metadata.CommitHash) to $DestinationBranch"
  }

  if ($PSCmdlet.ShouldProcess($DestinationBranch, $action)) {
    return Invoke-GitPlan -Plan $plan
  }
}

function Get-CommitMessageFromChanges {
  <#
  .SYNOPSIS
  Generates a commit message suggestion from current repo changes.

  .DESCRIPTION
  This function is intentionally lightweight and dependency-free.
  - If there are no changes in the working tree or index, returns $null.
  - If there are changes but no Anthropic API key/token is configured, throws.

  NOTE: The full "AI-generated message" behavior is intentionally not implemented here.
  The module's tests currently validate only the no-changes and no-key guardrails.

  .PARAMETER DiffLevel
  Controls how much diff context would be used for generation (reserved for future use).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('None', 'Summary', 'Full')]
    [string]$DiffLevel = 'Summary'
  )

  # Detect changes (staged or unstaged). git diff --quiet returns exit code 1 when there are changes.
  git diff --quiet | Out-Null
  $hasUnstaged = ($LASTEXITCODE -ne 0)

  git diff --cached --quiet | Out-Null
  $hasStaged = ($LASTEXITCODE -ne 0)

  if (-not $hasUnstaged -and -not $hasStaged) {
    return $null
  }

  $key = $env:AnthropicKey
  if (-not $key) { $key = $env:ANTHROPIC_TOKEN }
  if ([string]::IsNullOrWhiteSpace($key)) {
    throw "Anthropic key is not set. Set env:AnthropicKey or env:ANTHROPIC_TOKEN."
  }

  # Placeholder: a deterministic fallback until an LLM-backed implementation is added.
  return "Update changes"
}

if ($env:CI) {
  Write-Host "Exporting all module members for CI environment."
  Export-ModuleMember *
}
else {
  # NOTE: The module manifest (GitSplit.psd1) also declares FunctionsToExport.
  # PowerShell effectively filters exports through BOTH lists, so keep them aligned
  # to avoid surprising "only the intersection" exports.
  Export-ModuleMember -Function @(
    'Split-Commit'
    'Add-Commit'
    'Remove-Commit'
    'Move-Commit'
    'Set-CommitOrder'
    'Get-CommitMessageFromChanges'
  )
}
