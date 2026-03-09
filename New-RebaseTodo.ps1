param(
  [Parameter(Position = 0)]
  [string]$Path,

  [Parameter(Position = 1)]
  [ValidateNotNullOrEmpty()]
  [string]$From = "HEAD~6",

  [Parameter()]
  [string[]]$OrderedCommits
)

$ErrorActionPreference = "Stop"

if ($null -eq $OrderedCommits) {
  $OrderedCommits = @()
}
else {
  $OrderedCommits = @(
    $OrderedCommits |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
}

function Get-TodoCommandInfo {
  param([string]$Line)

  if ($Line -match '^(pick|reword|edit|drop|fixup|squash)\s+([0-9a-f]{7,40})\b') {
    return [PSCustomObject]@{
      Command = $matches[1]
      Hash = $matches[2]
    }
  }

  if ($Line -match '^merge\s+-(c|C)\s+([0-9a-f]{7,40})\b') {
    return [PSCustomObject]@{
      Command = 'merge'
      Hash = $matches[2]
    }
  }

  return $null
}

$resolvedFromOutput = git rev-parse $From
$resolvedFromExitCode = $LASTEXITCODE
$resolvedFrom = if ($resolvedFromExitCode -eq 0 -and $null -ne $resolvedFromOutput) { "$resolvedFromOutput".Trim() } else { $null }
if ($resolvedFromExitCode -ne 0 -or $resolvedFrom -notmatch '^[0-9a-f]{40}$') {
  throw "Failed to resolve ref '$From' to a commit SHA."
}

$orderedFullHashes = @()
foreach ($orderedCommit in $OrderedCommits) {
  $resolvedOrderedCommitOutput = git rev-parse --verify "$orderedCommit^{commit}" 2>$null
  $resolvedOrderedCommitExitCode = $LASTEXITCODE
  $resolvedOrderedCommit = if ($resolvedOrderedCommitExitCode -eq 0 -and $null -ne $resolvedOrderedCommitOutput) { "$resolvedOrderedCommitOutput".Trim() } else { $null }
  if ($resolvedOrderedCommitExitCode -ne 0 -or $resolvedOrderedCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Failed to resolve ordered commit '$orderedCommit' to a commit SHA."
  }

  if ($resolvedOrderedCommit -notin $orderedFullHashes) {
    $orderedFullHashes += $resolvedOrderedCommit
  }
}

if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
  return
}

$todoLines = @(Get-Content -Path $Path)
if ($orderedFullHashes.Count -eq 0) {
  return
}

$groups = @()
$currentGroup = $null
$nonCommandLines = @()

foreach ($todoLine in $todoLines) {
  $commandInfo = Get-TodoCommandInfo $todoLine
  if ($null -eq $commandInfo) {
    $nonCommandLines += $todoLine
    continue
  }

  $todoCommitOutput = git rev-parse --verify "$($commandInfo.Hash)^{commit}" 2>$null
  $todoCommitExitCode = $LASTEXITCODE
  $todoCommitFullHash = if ($todoCommitExitCode -eq 0 -and $null -ne $todoCommitOutput) { "$todoCommitOutput".Trim() } else { $null }
  if ($todoCommitExitCode -ne 0 -or $todoCommitFullHash -notmatch '^[0-9a-f]{40}$') {
    throw "Failed to resolve todo commit '$($commandInfo.Hash)' from line '$todoLine'."
  }

  if ($commandInfo.Command -in @('fixup', 'squash') -and $null -ne $currentGroup) {
    $currentGroup.Lines += $todoLine
    continue
  }

  $currentGroup = [PSCustomObject]@{
    ParentFullHash = $todoCommitFullHash
    Lines = @($todoLine)
  }
  $groups += $currentGroup
}

$groupParentHashes = @($groups | ForEach-Object { $_.ParentFullHash })
foreach ($orderedFullHash in $orderedFullHashes) {
  if ($orderedFullHash -notin $groupParentHashes) {
    throw "Ordered commit '$orderedFullHash' is not present in existing rebase todo."
  }
}

$selectedGroups = @()
$remainingGroups = @($groups)
foreach ($orderedFullHash in $orderedFullHashes) {
  $match = $remainingGroups | Where-Object { $_.ParentFullHash -eq $orderedFullHash } | Select-Object -First 1
  if ($null -ne $match) {
    $selectedGroups += $match
    $remainingGroups = @($remainingGroups | Where-Object { $_.ParentFullHash -ne $orderedFullHash })
  }
}

$reorderedLines = @(
  foreach ($group in @($selectedGroups + $remainingGroups)) {
    foreach ($groupLine in $group.Lines) {
      $groupLine
    }
  }
)

if ($nonCommandLines.Count -gt 0) {
  $reorderedLines += $nonCommandLines
}

Set-Content -Path $Path -Value $reorderedLines
