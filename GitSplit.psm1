<#
GitSplit.psm1

This module contains git-oriented patch/hunk/commit splitting utilities used by ImmyBot tooling.
It intentionally has no external dependencies beyond git being available on PATH.
#>

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
    git reset --hard $parent | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "git reset --hard $parent failed with exit code $LASTEXITCODE"
    }

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
      git apply --whitespace=nowarn --unidiff-zero $tmp | Out-Null
      if ($LASTEXITCODE -ne 0) {
        if (-not $keepSplitPatch) {
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw "git apply failed for split patch piece $i (file $tmp) with exit code $LASTEXITCODE"
      }
      if (-not $keepSplitPatch) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      }

      git add -A | Out-Null

      # If the split piece results in no changes (can happen depending on split points), skip creating a commit.
      git diff --cached --quiet
      if ($LASTEXITCODE -eq 0) {
        continue
      }

      $msg = "$subject (split $($i + 1)/$pieceCount)"
      git commit -m $msg | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "git commit failed while creating split commit piece $i with exit code $LASTEXITCODE"
      }

      $newSha = (git rev-parse HEAD)
      if ($LASTEXITCODE -ne 0 -or -not $newSha) {
        throw "Unable to resolve SHA for newly created split commit piece $i."
      }
      $createdSplitCommits.Add($newSha.Trim()) | Out-Null
    }

    foreach ($c in $afterTarget) {
      git cherry-pick $c | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "git cherry-pick failed for $c with exit code $LASTEXITCODE"
      }
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
      throw "git reset --hard $After failed with exit code $LASTEXITCODE"
    }

    if ($olderCommit) {
      git cherry-pick $olderCommit | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "git cherry-pick (older) failed for $olderCommit with exit code $LASTEXITCODE"
      }
    }

    git cherry-pick $newerCommit | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "git cherry-pick (newer) failed for $newerCommit with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path $PatchFile)) {
      throw "Patch file not found: $PatchFile"
    }

    # Apply patch in a way that tolerates rewritten history (index/blob hashes may differ).
    git apply --whitespace=nowarn $PatchFile | Out-Null
    if ($LASTEXITCODE -ne 0) {
      git apply --whitespace=nowarn --3way $PatchFile | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "git apply failed for $PatchFile with exit code $LASTEXITCODE"
      }
    }

    git add -A | Out-Null
    git commit -m $CommitMessage | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "git commit failed for patch $PatchFile (message: $CommitMessage) with exit code $LASTEXITCODE"
    }

    foreach ($c in $remainingCommits) {
      git cherry-pick $c | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "git cherry-pick (remaining) failed for $c with exit code $LASTEXITCODE"
      }
    }
  }
  finally {
    Pop-Location
    $env:GIT_SEQUENCE_EDITOR = $oldSeq
    $env:GIT_EDITOR = $oldEd
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
      git stash push -u -m $stashName | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to stash changes."
      }
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
        git worktree add -b $DestinationBranch $destWorktreePath "origin/$DestinationBranch" | Out-Null
      }
      else {
        git worktree add $destWorktreePath $DestinationBranch | Out-Null
      }
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to add worktree for destination branch '$DestinationBranch'."
      }

      # Apply commit to destination.
      git -C $destWorktreePath cherry-pick $commitHash | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to cherry-pick commit $commitHash onto '$DestinationBranch'. Resolve conflicts in worktree '$destWorktreePath' and run 'git -C <path> cherry-pick --continue' or '--abort'."
      }

      if ($Push) {
        git -C $destWorktreePath push -u origin $DestinationBranch | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to push destination branch '$DestinationBranch' to origin."
        }
      }
    }

    if ($RemoveFromSource) {
      # Ensure the commit is on the current branch.
      git merge-base --is-ancestor $commitHash HEAD | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Commit $commitHash is not an ancestor of current branch '$currentBranch'. Move-Commit can only remove commits from the current branch."
      }

      $headHash = (git rev-parse HEAD).Trim()
      if ($headHash -eq $commitHash) {
        # Remove latest commit.
        if ($PSCmdlet.ShouldProcess($currentBranch, "Remove HEAD commit (reset --hard HEAD~1)")) {
          git reset --hard HEAD~1 | Out-Null
          if ($LASTEXITCODE -ne 0) {
            throw "Failed to reset and remove HEAD commit from '$currentBranch'."
          }
        }
      }
      else {
        # Remove non-HEAD commit by rebasing commits after it onto its parent.
        git rev-parse --verify "$commitHash^" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Cannot remove the initial commit via rebase."
        }

        if ($PSCmdlet.ShouldProcess($currentBranch, "Remove commit via rebase --onto")) {
          git rebase --onto "$commitHash^" $commitHash HEAD | Out-Null
          if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebase and remove commit $commitHash from '$currentBranch'. Resolve conflicts and run 'git rebase --continue' or abort with 'git rebase --abort'."
          }
        }
      }

      if ($Push) {
        if ($ForcePushSource) {
          git push --force-with-lease origin $currentBranch | Out-Null
        }
        else {
          git push origin $currentBranch | Out-Null
        }
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to push updated source branch '$currentBranch' to origin."
        }
      }
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
      # Use pop so we don't leak stashes.
      git stash list | Select-String -SimpleMatch $stashName | Out-Null
      if ($LASTEXITCODE -eq 0) {
        git stash pop | Out-Null
      }
    }
  }
}


Export-ModuleMember -Function Split-Commit, Add-Commit
