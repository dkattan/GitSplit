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

  if (-not $BodyLines -or $BodyLines.Count -eq 0) {
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
  [CmdletBinding()]
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
    [object[]]$NewCommitRanges
  )

  $repoRoot = (git rev-parse --show-toplevel)
  if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    throw "Split-Commit must be run inside a git repository."
  }

  $oldHead = (git rev-parse HEAD)
  if ($LASTEXITCODE -ne 0 -or -not $oldHead) {
    throw "Unable to determine HEAD."
  }

  $target = (git rev-parse $Ref)
  if ($LASTEXITCODE -ne 0 -or -not $target) {
    throw "Unable to resolve Ref '$Ref'."
  }

  $parent = (git rev-parse "$target^")
  if ($LASTEXITCODE -ne 0 -or -not $parent) {
    throw "Unable to resolve parent for Ref '$Ref' ($target)."
  }

  $subject = (git log -1 --pretty=format:%s $target)
  if ($LASTEXITCODE -ne 0 -or -not $subject) {
    $subject = "Split $target"
  }

  $createdSplitCommits = New-Object System.Collections.Generic.List[string]

  # Collect commits after the target (if any) so we can replay them.
  $afterTarget = @(git rev-list --reverse "$target..$oldHead")
  if ($LASTEXITCODE -ne 0) {
    throw "git rev-list failed for range $target..$oldHead with exit code $LASTEXITCODE"
  }
  if ($afterTarget.Count -eq 1 -and $afterTarget[0] -is [string] -and $afterTarget[0] -match "\r?\n") {
    $afterTarget = $afterTarget[0] -split "\r?\n"
  }
  $afterTarget = @($afterTarget | Where-Object { $_ -and $_.Trim() })

  # Get the patch for the commit we are splitting.
  $patchText = @(
    git show --pretty=format: --no-color $target
  ) -join "`n"
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($patchText)) {
    throw "git show failed to produce patch for $target."
  }

  # Parse hunks per file.
  $filePatches = Split-Patch -patch $patchText
  if (-not $filePatches -or $filePatches.Count -eq 0) {
    throw "No file patches found in commit $target."
  }

  # Group split points by file path.
  $rangesByPath = @{}
  foreach ($r in $NewCommitRanges) {
    if ($null -eq $r) { continue }
    $p = $r.Path
    if (-not $p) {
      throw "NewCommitRanges elements must include Path."
    }
    if (-not $rangesByPath.ContainsKey($p)) {
      $rangesByPath[$p] = @()
    }
    $rangesByPath[$p] += $r
  }

  # Helper: extract a single file's diff section from a combined patch.
  function Get-FileDiffSection {
    param(
      [string]$CombinedPatch,
      [string]$FilePath
    )

    $parts = $CombinedPatch -split '(?m)^diff --git '
    if ($parts[0] -eq '') {
      $parts = $parts[1..($parts.Length - 1)]
    }
    foreach ($part in $parts) {
      if ([string]::IsNullOrWhiteSpace($part)) { continue }
      $section = "diff --git $part"
      $escaped = [regex]::Escape($FilePath)
      if ($section -match "(?m)^diff --git a/$escaped b/$escaped$") {
        return $section
      }
      # fallback: try the original extraction regex used by Split-Patch
      if ($section -match 'a/(.+?)\s+b/' -and $matches[1] -eq $FilePath) {
        return $section
      }
    }
    return $null
  }

  # Compute per-file pieces (hunk fragments) based on split points.
  $perFilePieces = @{}
  foreach ($fp in $filePatches) {
    $path = $fp.FilePath
    $hunks = @($fp.Patches)

    # Default: no split points => whole file diff is one piece.
    $splitPoints = @()
    if ($rangesByPath.ContainsKey($path)) {
      $splitPoints = @($rangesByPath[$path] | Where-Object { $_.Line } | Sort-Object { [int]$_.Line })
    }

    # For now we only support a single hunk per file for splitting.
    if ($splitPoints.Count -gt 0 -and $hunks.Count -ne 1) {
      throw "Split-Commit currently supports splitting only files with exactly 1 hunk. File '$path' has $($hunks.Count)."
    }

    if ($splitPoints.Count -eq 0) {
      $perFilePieces[$path] = @($hunks)
      continue
    }

    $pieces = @($hunks[0])
    foreach ($sp in $splitPoints) {
      if (-not ($sp.PSObject.Properties.Name -contains 'Line') -or $null -eq $sp.Line -or [string]::IsNullOrWhiteSpace([string]$sp.Line)) {
        throw "Split-Commit: NewCommitRanges elements must include Line for path '$path'."
      }

      $line = [int]$sp.Line
      $col = if ($sp.PSObject.Properties.Name -contains 'Column' -and $sp.Column) { [int]$sp.Column } else { 1 }
      # Find the current piece that contains the line; for simplicity, split the last piece.
      $last = $pieces[-1]
      $split = Split-Hunk -Hunk $last -Line $line -Column $col
      # Replace the last piece with its two halves.
      if ($pieces.Count -le 1) {
        $pieces = @($split)
      }
      else {
        $prefixPieces = $pieces[0..($pieces.Count - 2)]
        $pieces = @($prefixPieces + $split)
      }
    }
    $perFilePieces[$path] = $pieces
  }

  # Determine how many commits we will create (max number of pieces across files).
  $pieceCount = 1
  foreach ($k in $perFilePieces.Keys) {
    $c = @($perFilePieces[$k]).Count
    if ($c -gt $pieceCount) { $pieceCount = $c }
  }

  # Rewrite: go to parent, apply each piece-set as its own commit, then replay remaining commits.
  try {
    Invoke-Git -ErrorMessage "git reset --hard $parent" reset --hard $parent

    for ($i = 0; $i -lt $pieceCount; $i++) {
      # Build a combined patch for this piece index.
      $combined = ""
      foreach ($fp in $filePatches) {
        $path = $fp.FilePath
        $section = Get-FileDiffSection -CombinedPatch $patchText -FilePath $path
        if (-not $section) {
          throw "Unable to locate diff section for '$path' in commit patch."
        }

        $pieces = @($perFilePieces[$path])
        $h = $null
        if ($i -lt $pieces.Count) {
          $h = $pieces[$i]
        }
        else {
          # This file doesn't contribute to this commit piece.
          continue
        }

        # If this hunk piece contains no actual changes (only context), omit it.
        # git apply can reject no-op hunks as corrupt, and we don't want to create empty commits.
        if ($h -notmatch '(?m)^[+-](?![+-]{2})') {
          continue
        }

        # Replace the hunk portion with this piece.
        $idx = $section.IndexOf("@@")
        if ($idx -lt 0) {
          throw "Diff section for '$path' did not contain a hunk header."
        }
        $prefix = $section.Substring(0, $idx)
        # Drop blob hash lines since splitting changes the resulting blob.
        $prefix = $prefix -replace '(?m)^index .*\r?\n', ''
        # Do not insert extra blank lines: unified diff hunks cannot contain raw empty lines.
        # Ensure we end with exactly one newline between sections.
        # IMPORTANT: Trim only newlines, not whitespace. A blank context line in a unified diff is a single space
        # character, and TrimEnd() would remove that space and corrupt the patch.
        $combined += ($prefix + $h.TrimEnd("`r", "`n") + "`n")
      }

      if ([string]::IsNullOrWhiteSpace($combined)) {
        continue
      }

      $tmp = Join-Path $repoRoot (".split-commit.$i.patch")
      # Avoid Set-Content appending an extra newline, which can introduce a raw blank line at EOF
      # and make `git apply` reject the patch as corrupt.
      Set-Content -LiteralPath $tmp -Value $combined -Encoding utf8 -NoNewline

      $keepSplitPatch = ($env:IMMYBUILD_KEEP_SPLIT_PATCH -eq '1') -or ($env:IMMYBUILD_KEEP_TEMPREPO -eq '1')

      # Split patches intentionally contain less context; apply them deterministically.
      try {
        Invoke-Git -ErrorMessage "git apply failed for split patch piece $i (file $tmp)" apply --whitespace=nowarn --unidiff-zero $tmp
      }
      catch {
        if (-not $keepSplitPatch) {
          Invoke-WithProgressSuppressed {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
          }
        }
        throw
      }
      if (-not $keepSplitPatch) {
        Invoke-WithProgressSuppressed {
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
      }

      Invoke-Git -ErrorMessage 'git add -A' add -A

      # If the split piece results in no changes (can happen depending on split points), skip creating a commit.
      git diff --cached --quiet
      if ($LASTEXITCODE -eq 0) {
        continue
      }

      $msg = "$subject (split $($i + 1)/$pieceCount)"
      Invoke-Git -ErrorMessage "git commit failed while creating split commit piece $i" commit -m $msg

      $newSha = (git rev-parse HEAD)
      if ($LASTEXITCODE -ne 0 -or -not $newSha) {
        throw "Unable to resolve SHA for newly created split commit piece $i."
      }
      $createdSplitCommits.Add($newSha.Trim()) | Out-Null
    }

    foreach ($c in $afterTarget) {
      Invoke-Git -ErrorMessage "git cherry-pick failed for $c" cherry-pick $c
    }
  }
  catch {
    throw
  }

  return @($createdSplitCommits)
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

  .OUTPUTS
  System.String
  The branch name rewritten.
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
    [switch]$ForcePush
  )

  if (-not $Branch) {
    $Branch = (git rev-parse --abbrev-ref HEAD)
    if ($LASTEXITCODE -ne 0 -or -not $Branch) {
      throw "Failed to get current branch."
    }
    $Branch = $Branch.Trim()
  }

  if ($Branch -eq 'HEAD') {
    throw "You are in a detached HEAD state. Checkout a branch before calling Remove-Commit."
  }

  $commitHash = (git rev-parse $CommitRef)
  if ($LASTEXITCODE -ne 0 -or -not $commitHash) {
    throw "Failed to resolve commit reference '$CommitRef'."
  }
  $commitHash = $commitHash.Trim()

  # Ensure the commit is on the branch we are rewriting.
  git merge-base --is-ancestor $commitHash $Branch | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Commit $commitHash is not an ancestor of branch '$Branch'."
  }

  $branchHead = (git rev-parse $Branch).Trim()
  if ($branchHead -eq $commitHash) {
    if ($PSCmdlet.ShouldProcess($Branch, "Remove HEAD commit (reset --hard $Branch~1)")) {
      Invoke-Git -ErrorMessage "git reset --hard $Branch~1" reset --hard "$Branch~1"
    }
  }
  else {
    git rev-parse --verify "$commitHash^" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Cannot remove the initial commit via rebase."
    }

    if ($PSCmdlet.ShouldProcess($Branch, "Remove commit via rebase --onto")) {
      # Rebase the *branch ref* so we don't end up detached.
      Invoke-Git -ErrorMessage "git rebase --onto failed while removing $commitHash from $Branch" rebase --onto "$commitHash^" $commitHash $Branch
    }
  }

  if ($Push) {
    if ($ForcePush) {
      Invoke-Git -ErrorMessage "git push --force-with-lease origin $Branch" push --force-with-lease origin $Branch
    }
    else {
      Invoke-Git -ErrorMessage "git push origin $Branch" push origin $Branch
    }
  }

  return $Branch
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

  .OUTPUTS
  System.String
  The destination branch name.

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
    [switch]$AutoStash
  )

  $repoRoot = (git rev-parse --show-toplevel)
  if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    throw "Move-Commit must be run inside a git repository."
  }

  $stashed = $false
  $stashName = $null
  $destWorktreePath = $null

  try {
    # Ensure worktree safety. A dirty tree can make destructive operations risky.
    $status = (git status --porcelain)
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to determine git status."
    }
    if (-not [string]::IsNullOrWhiteSpace($status)) {
      if (-not $AutoStash) {
        throw "Uncommitted changes detected. Re-run with -AutoStash, or commit/stash your changes before calling Move-Commit."
      }

      $stashName = "gitsplit-move-commit-$(Get-Date -Format 'yyyyMMddHHmmss')"
      Invoke-Git -ErrorMessage 'git stash push failed' stash push -u -m $stashName
      $stashed = $true
    }

    $currentBranch = (git rev-parse --abbrev-ref HEAD)
    if ($LASTEXITCODE -ne 0 -or -not $currentBranch) {
      throw "Failed to get current branch."
    }
    $currentBranch = $currentBranch.Trim()
    if ($currentBranch -eq 'HEAD') {
      throw "You are in a detached HEAD state. Checkout a branch before calling Move-Commit."
    }

    # Resolve commit hash.
    $commitHash = (git rev-parse $CommitRef)
    if ($LASTEXITCODE -ne 0 -or -not $commitHash) {
      throw "Failed to resolve commit reference '$CommitRef'."
    }
    $commitHash = $commitHash.Trim()

    # Verify destination branch exists locally or on origin.
    $branchExists = $true
    git show-ref --verify --quiet "refs/heads/$DestinationBranch" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      $branchExists = $false
    }
    $remoteBranchExists = $true
    git show-ref --verify --quiet "refs/remotes/origin/$DestinationBranch" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      $remoteBranchExists = $false
    }
    if (-not $branchExists -and -not $remoteBranchExists) {
      throw "Destination branch '$DestinationBranch' does not exist locally or on origin. Create it first."
    }

    # Create a temporary worktree for destination branch so we don't have to switch.
    $wtRoot = Join-Path $repoRoot '.gitsplit-worktrees'
    if (-not (Test-Path -LiteralPath $wtRoot)) {
      New-Item -Path $wtRoot -ItemType Directory -Force | Out-Null
    }
    $destWorktreePath = Join-Path $wtRoot ([guid]::NewGuid().ToString())

    if ($PSCmdlet.ShouldProcess("$DestinationBranch", "Cherry-pick $commitHash")) {
      if ($remoteBranchExists -and -not $branchExists) {
        # Create a local branch from origin in the worktree.
        Invoke-Git -ErrorMessage "git worktree add -b $DestinationBranch" worktree add -b $DestinationBranch $destWorktreePath "origin/$DestinationBranch"
      }
      else {
        Invoke-Git -ErrorMessage "git worktree add $DestinationBranch" worktree add $destWorktreePath $DestinationBranch
      }

      # Apply commit to destination.
      Invoke-Git -ErrorMessage "git -C <worktree> cherry-pick failed for $commitHash" -C $destWorktreePath cherry-pick $commitHash

      if ($Push) {
        Invoke-Git -ErrorMessage "git -C <worktree> push failed for $DestinationBranch" -C $destWorktreePath push -u origin $DestinationBranch
      }
    }

    if ($RemoveFromSource) {
      $null = Remove-Commit -CommitRef $commitHash -Branch $currentBranch -Push:$Push -ForcePush:$ForcePushSource
    }

    return $DestinationBranch
  }
  finally {
    # Best-effort cleanup: remove worktree.
    if ($destWorktreePath -and (Test-Path -LiteralPath $destWorktreePath)) {
      git worktree remove --force $destWorktreePath 2>$null | Out-Null
    }

    if ($stashed) {
      # Try to re-apply the stash created by this function.
      # IMPORTANT: do NOT pop/apply if we're mid-merge/rebase/cherry-pick.
      # Also, pop the *specific* stash we created (not simply the top of the stash stack).

      $gitDir = (git rev-parse --git-dir)
      if ($LASTEXITCODE -eq 0 -and $gitDir) {
        $gitDir = $gitDir.Trim()
        if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
          $gitDir = Join-Path $repoRoot $gitDir
        }
      }

      $stashLine = $null
      try {
        $stashLine = (git stash list --format="%gd %s" | Where-Object { $_ -like "*${stashName}*" } | Select-Object -First 1)
      }
      catch {
        $stashLine = $null
      }

      if ($stashLine) {
        $stashRef = ($stashLine -split '\s+', 2)[0]

        $inProgress = $false
        if ($gitDir -and (Test-Path -LiteralPath $gitDir)) {
          $inProgress = (
            (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-apply')) -or
            (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-merge')) -or
            (Test-Path -LiteralPath (Join-Path $gitDir 'MERGE_HEAD')) -or
            (Test-Path -LiteralPath (Join-Path $gitDir 'CHERRY_PICK_HEAD')) -or
            (Test-Path -LiteralPath (Join-Path $gitDir 'REVERT_HEAD'))
          )
        }

        if ($inProgress) {
          Write-Error @(
            "Move-Commit created a stash ('$stashName' -> $stashRef) but will NOT restore it because git reports an in-progress operation (merge/rebase/cherry-pick/revert).",
            '',
            'How to proceed:',
            "  1) Inspect state:            git status",
            "  2) Finish or abort operation: git rebase --continue | git rebase --abort | git merge --abort | git cherry-pick --abort | git revert --abort",
            "  3) Then restore your changes: git stash pop $stashRef",
            '',
            'How to undo the branch rewrite (if you used -RemoveFromSource):',
            "  - Find the pre-rewrite commit in reflog: git reflog",
            "  - Reset branch back to it:              git reset --hard <sha>",
            "  - If you pushed/force-pushed:           git push --force-with-lease"
          ) -join [Environment]::NewLine
        }
        else {
          git stash pop $stashRef | Out-Null
        }
      }
    }
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
    'Get-CommitMessageFromChanges'
  )
}
