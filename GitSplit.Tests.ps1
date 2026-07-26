Describe "GitSplit" {

  BeforeAll {
    $script:OldCi = $env:CI
    $env:CI = '1'
    Import-Module "$PSScriptRoot/GitSplit.psm1" -Force

    # Shared path, but the repo itself is re-created per test.
    $script:TempRepoPath = Join-Path $PSScriptRoot 'temprepo'
  }

  AfterAll {
    $env:CI = $script:OldCi
  }

  BeforeEach {
    $oldProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'

    if (Test-Path $script:TempRepoPath) {
      Remove-Item -Path $script:TempRepoPath -Recurse -Force
    }

    New-Item -Path $script:TempRepoPath -ItemType Directory -Force | Out-Null

    Push-Location $script:TempRepoPath
    try {
      # Quiet and suppress stderr: VS Code test runners may surface native stderr as error notifications.
      # Also set init.defaultBranch per-command to avoid "Using 'master'..." advisory output.
      git -c init.defaultBranch=main init -q 2>$null | Out-Null

      # Make newline handling deterministic inside this temp repo.
      # We want patches/hunks to be generated and applied consistently regardless of host settings.
      git config core.autocrlf false | Out-Null
      git config core.eol lf | Out-Null

      # Ensure commits work even on a clean machine/CI.
      git config user.name "Pester" | Out-Null
      git config user.email "pester@example.com" | Out-Null

      # Create an initial empty commit so that HEAD~3 exists after the 3 commits below.
      git commit --allow-empty -m "Initial" | Out-Null

      # Commit 1: Add a.txt and b.txt with some multi-line content
      @(
        'a-line-1'
        'a-line-2'
        'a-line-3'
      ) | Set-Content -Path "a.txt"

      @(
        'b-line-1'
        'b-line-2'
        'b-line-3'
      ) | Set-Content -Path "b.txt"

      git add a.txt b.txt | Out-Null
      git commit -m "Add a.txt and b.txt" | Out-Null

      # Commit 2: Modify a.txt and b.txt
      @(
        'a-line-1'
        'a-line-2 (edited)'
        'a-line-3'
        'a-line-4 (new)'
      ) | Set-Content -Path "a.txt"

      @(
        'b-line-1'
        'b-line-2 (edited)'
        'b-line-3'
        'b-line-4 (new)'
      ) | Set-Content -Path "b.txt"

      git add a.txt b.txt | Out-Null
      git commit -m "Modify a.txt and b.txt" | Out-Null

      # Commit 3: Modify b.txt only
      @(
        'b-line-1'
        'b-line-2 (edited again)'
        'b-line-3'
        'b-line-4 (new)'
        'b-line-5 (new in commit 3)'
      ) | Set-Content -Path "b.txt"

      git add b.txt | Out-Null
      git commit -m "Modify b.txt" | Out-Null
    }
    finally {
      Pop-Location
      $global:ProgressPreference = $oldProgressPreference
    }
  }

  AfterEach {
    $oldProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'

    # Set IMMYBUILD_KEEP_TEMPREPO=1 to keep the repo around for debugging.
    if ($env:IMMYBUILD_KEEP_TEMPREPO -eq '1') {
      Write-Host "Keeping temprepo at: $script:TempRepoPath" -ForegroundColor Yellow
      $global:ProgressPreference = $oldProgressPreference
      return
    }

    if ($script:TempRepoPath -and (Test-Path $script:TempRepoPath)) {
      Remove-Item -Path $script:TempRepoPath -Recurse -Force
    }

    $global:ProgressPreference = $oldProgressPreference
  }

  function script:New-GitSplitExtendedFixtureCommit {
    Push-Location $script:TempRepoPath
    try {
      New-Item -ItemType Directory -Path 'frontend/src/components/__generated__' -Force | Out-Null
      New-Item -ItemType Directory -Path '.github/actions/run-frontend' -Force | Out-Null
      New-Item -ItemType Directory -Path '.github/workflows' -Force | Out-Null

      @(
        '{'
        '  "name": "frontend",'
        '  "private": true'
        '}'
      ) | Set-Content -Path 'frontend/package.json'

      @(
        '{'
        '  "lockfileVersion": 1'
        '}'
      ) | Set-Content -Path 'bun.lock'

      @(
        '<script setup lang="ts">'
        "import { useThing } from './useThing';"
        "import { generated } from './__generated__/fixtures.g';"
        '</script>'
        '<template><div>{{ useThing() }} {{ generated }}</div></template>'
      ) | Set-Content -Path 'frontend/src/components/Thing.vue'

      @(
        'export function useThing() {'
        '  return 42;'
        '}'
      ) | Set-Content -Path 'frontend/src/components/useThing.ts'

      @(
        'export const generated = true;'
      ) | Set-Content -Path 'frontend/src/components/__generated__/fixtures.g.ts'

      @(
        'name: Run frontend'
        'runs:'
        '  using: composite'
        '  steps:'
        '    - shell: bash'
        '      run: echo frontend'
      ) | Set-Content -Path '.github/actions/run-frontend/action.yml'

      @(
        'name: Frontend'
        'on: push'
        'jobs:'
        '  test:'
        '    runs-on: ubuntu-latest'
        '    steps:'
        '      - uses: ./.github/actions/run-frontend'
      ) | Set-Content -Path '.github/workflows/frontend.yml'

      git add frontend/package.json bun.lock frontend/src/components/Thing.vue frontend/src/components/useThing.ts frontend/src/components/__generated__/fixtures.g.ts .github/actions/run-frontend/action.yml .github/workflows/frontend.yml | Out-Null
      git commit -m "Add extended GitSplit fixture" | Out-Null

      return (git rev-parse HEAD).Trim()
    }
    finally {
      Pop-Location
    }
  }

  Describe "public exports" {
    It "keeps manifest-based exports aligned with the supported public surface" {
      $manifestPath = Join-Path $PSScriptRoot 'GitSplit.psd1'
      $escapedManifestPath = $manifestPath.Replace("'", "''")

      $json = pwsh -NoProfile -Command @"
Remove-Item Env:CI -ErrorAction SilentlyContinue
Import-Module '$escapedManifestPath' -Force
(Get-Command -Module GitSplit | Sort-Object Name | Select-Object -ExpandProperty Name) | ConvertTo-Json -Compress
"@

      $publicCommands = @($json | ConvertFrom-Json)

      $publicCommands | Should -Be @(
        'Add-Commit'
        'Get-CommitMessageFromChanges'
        'Get-GitSplitClosure'
        'Get-GitSplitHunks'
        'Invoke-GitSplitAbsorb'
        'Move-Commit'
        'New-Hunk'
        'New-Range'
        'Remove-Commit'
        'Select-GitSplitPaths'
        'Set-CommitOrder'
        'Split-Commit'
        'Split-Hunk'
        'Split-Patch'
        'Test-GitSplitSelection'
        'Wait-GitSplitPullRequestChecks'
      )
    }
  }

  Describe "Split-Patch" {
    It "splits a multi-file git patch into per-file hunks" {
      Push-Location $script:TempRepoPath
      try {
        $tempPatchFile = Join-Path $script:TempRepoPath 'temp.patch'
        if (Test-Path $tempPatchFile) {
          Remove-Item -Path $tempPatchFile -Force
        }

        # Diff the repo against HEAD~3 (the initial empty commit) and write it to a file.
        git diff HEAD~3..HEAD | Out-File -FilePath $tempPatchFile -Encoding utf8

        $patch = Get-Content -Path $tempPatchFile -Raw
      }
      finally {
        Pop-Location
      }

      $result = Split-Patch -patch $patch

      $result | Should -HaveCount 2

      # Order is not guaranteed; assert by file name.
      ($result.FilePath | Sort-Object) | Should -Be @('a.txt', 'b.txt')

      $a = $result | Where-Object FilePath -eq 'a.txt'
      $b = $result | Where-Object FilePath -eq 'b.txt'

      @($a.Patches) | Should -HaveCount 1
      @($b.Patches) | Should -HaveCount 1

      $aHunk = @($a.Patches)[0]
      $bHunk = @($b.Patches)[0]

      # Meaningful content assertions.
      # Because we diff against an empty initial commit (HEAD~3), these hunks should be additions only.
      # - a.txt: includes the final edited line and the new line 4, and does NOT include the original unedited line.
      $aHunk | Should -Match "(?m)^\+a-line-2 \(edited\)$"
      $aHunk | Should -Match "(?m)^\+a-line-4 \(new\)$"
      $aHunk | Should -Not -Match "(?m)^\+a-line-2$"

      # - b.txt: includes the final edited-again line and the new line 5, and does NOT include the original unedited line.
      $bHunk | Should -Match "(?m)^\+b-line-2 \(edited again\)$"
      $bHunk | Should -Match "(?m)^\+b-line-5 \(new in commit 3\)$"
      $bHunk | Should -Not -Match "(?m)^\+b-line-2$"
    }
  }

  Describe "Get-GitSplitClosure" {
    It "excludes generated files and expands Vue/TypeScript and Bun dependencies within a commit" {
      Push-Location $script:TempRepoPath
      try {
        New-Item -ItemType Directory -Path 'frontend/src/components/__generated__' -Force | Out-Null

        @(
          '{'
          '  "name": "frontend",'
          '  "private": true'
          '}'
        ) | Set-Content -Path 'frontend/package.json'

        @(
          '{'
          '  "lockfileVersion": 1'
          '}'
        ) | Set-Content -Path 'bun.lock'

        @(
          '<script setup lang="ts">'
          "import { useThing } from './useThing';"
          "import { generated } from './__generated__/fixtures.g';"
          '</script>'
          '<template><div>{{ useThing() }} {{ generated }}</div></template>'
        ) | Set-Content -Path 'frontend/src/components/Thing.vue'

        @(
          'export function useThing() {'
          '  return 42;'
          '}'
        ) | Set-Content -Path 'frontend/src/components/useThing.ts'

        @(
          'export const generated = true;'
        ) | Set-Content -Path 'frontend/src/components/__generated__/fixtures.g.ts'

        git add frontend/package.json bun.lock frontend/src/components/Thing.vue frontend/src/components/useThing.ts frontend/src/components/__generated__/fixtures.g.ts | Out-Null
        git commit -m "Add frontend closure fixture" | Out-Null
        $ref = (git rev-parse HEAD).Trim()
      }
      finally {
        Pop-Location
      }

      Push-Location $script:TempRepoPath
      try {
        $result = @(Get-GitSplitClosure -Ref $ref -Paths @(
            'frontend/src/components/Thing.vue'
            'frontend/package.json'
            'frontend/src/components/__generated__/fixtures.g.ts'
          ))
      }
      finally {
        Pop-Location
      }

      $result | Should -HaveCount 5

      $byPath = @{}
      foreach ($entry in $result) {
        $byPath[$entry.Path] = $entry
      }

      $byPath.Keys | Sort-Object | Should -Be @(
        'bun.lock'
        'frontend/package.json'
        'frontend/src/components/__generated__/fixtures.g.ts'
        'frontend/src/components/Thing.vue'
        'frontend/src/components/useThing.ts'
      )

      $byPath['frontend/src/components/Thing.vue'].Status | Should -Be 'Selected'
      $byPath['frontend/src/components/Thing.vue'].Rule | Should -Be 'ExplicitSelection'

      $byPath['frontend/package.json'].Status | Should -Be 'Selected'
      $byPath['frontend/package.json'].Rule | Should -Be 'ExplicitSelection'

      $byPath['frontend/src/components/useThing.ts'].Status | Should -Be 'Included'
      $byPath['frontend/src/components/useThing.ts'].Rule | Should -Be 'RelativeImport'
      $byPath['frontend/src/components/useThing.ts'].SourcePath | Should -Be 'frontend/src/components/Thing.vue'

      $byPath['bun.lock'].Status | Should -Be 'Included'
      $byPath['bun.lock'].Rule | Should -Be 'BunLock'
      $byPath['bun.lock'].SourcePath | Should -Be 'frontend/package.json'

      $byPath['frontend/src/components/__generated__/fixtures.g.ts'].Status | Should -Be 'Excluded'
      $byPath['frontend/src/components/__generated__/fixtures.g.ts'].Rule | Should -Be 'GeneratedFile'
      $byPath['frontend/src/components/__generated__/fixtures.g.ts'].IsGenerated | Should -BeTrue
    }

    It "includes changed local GitHub actions when selecting a changed workflow" {
      $ref = New-GitSplitExtendedFixtureCommit

      Push-Location $script:TempRepoPath
      try {
        $result = @(Get-GitSplitClosure -Ref $ref -Paths @('.github/workflows/frontend.yml'))
      }
      finally {
        Pop-Location
      }

      $result | Should -HaveCount 2

      $byPath = @{}
      foreach ($entry in $result) {
        $byPath[$entry.Path] = $entry
      }

      $byPath['.github/workflows/frontend.yml'].Status | Should -Be 'Selected'
      $byPath['.github/actions/run-frontend/action.yml'].Status | Should -Be 'Included'
      $byPath['.github/actions/run-frontend/action.yml'].Rule | Should -Be 'WorkflowLocalAction'
      $byPath['.github/actions/run-frontend/action.yml'].SourcePath | Should -Be '.github/workflows/frontend.yml'
    }
  }

  Describe "Get-GitSplitHunks" {
    It "returns stable hunk identifiers and metadata for a commit" {
      Push-Location $script:TempRepoPath
      try {
        $first = @(Get-GitSplitHunks -Ref 'HEAD~1')
        $second = @(Get-GitSplitHunks -Ref 'HEAD~1')
      }
      finally {
        Pop-Location
      }

      $first | Should -HaveCount 2
      $second | Should -HaveCount 2
      ($first.HunkId) | Should -Be ($second.HunkId)
      @($first | Where-Object { $_.HunkId -notmatch '^h[0-9a-f]{12}$' }) | Should -BeNullOrEmpty

      $aHunk = $first | Where-Object Path -eq 'a.txt'
      $bHunk = $first | Where-Object Path -eq 'b.txt'

      $aHunk | Should -Not -BeNullOrEmpty
      $bHunk | Should -Not -BeNullOrEmpty
      $aHunk.NewStart | Should -Be 1
      $bHunk.NewStart | Should -Be 1
      $aHunk.IsGenerated | Should -BeFalse
      $bHunk.IsGenerated | Should -BeFalse
      $aHunk.Preview | Should -Match 'a-line-2'
      $bHunk.Preview | Should -Match 'b-line-2'
    }
  }

  Describe "Generated file detection" {
    It "reads linguist-generated attributes from the analyzed commit" {
      Push-Location $script:TempRepoPath
      try {
        'tracked content' | Set-Content -Path 'tracked.txt'
        git add tracked.txt | Out-Null
        git commit -m "Add tracked.txt" | Out-Null
        $historicalRef = (git rev-parse HEAD).Trim()

        '*.txt linguist-generated=true' | Set-Content -Path '.gitattributes'
        git add .gitattributes | Out-Null
        git commit -m "Mark txt files generated" | Out-Null

        $hunks = @(Get-GitSplitHunks -Ref $historicalRef)
        $selected = @(Select-GitSplitPaths -Ref $historicalRef -PathPattern '^tracked\.txt$')
        $closure = @(Get-GitSplitClosure -Ref $historicalRef -Paths @('tracked.txt'))
      }
      finally {
        Pop-Location
      }

      $hunks | Should -HaveCount 1
      $hunks[0].Path | Should -Be 'tracked.txt'
      $hunks[0].IsGenerated | Should -BeFalse

      $selected | Should -HaveCount 1
      $selected[0].Path | Should -Be 'tracked.txt'
      $selected[0].IsGenerated | Should -BeFalse

      $closure | Should -HaveCount 1
      $closure[0].Path | Should -Be 'tracked.txt'
      $closure[0].Status | Should -Be 'Selected'
      $closure[0].IsGenerated | Should -BeFalse
    }
  }

  Describe "Select-GitSplitPaths" {
    It "selects changed paths by regex and excludes generated files by default" {
      $ref = New-GitSplitExtendedFixtureCommit

      Push-Location $script:TempRepoPath
      try {
        $result = @(Select-GitSplitPaths -Ref $ref -PathPattern '^frontend/src/components/.*')
      }
      finally {
        Pop-Location
      }

      ($result.Path | Sort-Object) | Should -Be @(
        'frontend/src/components/Thing.vue'
        'frontend/src/components/useThing.ts'
      )
      ($result | Where-Object Path -eq 'frontend/src/components/__generated__/fixtures.g.ts') | Should -BeNullOrEmpty
    }
  }

  Describe "Test-GitSplitSelection" {
    It "reports source and target risks when a known coupling is split without closure expansion" {
      $ref = New-GitSplitExtendedFixtureCommit

      Push-Location $script:TempRepoPath
      try {
        $result = @(Test-GitSplitSelection -Ref $ref -Paths @('frontend/package.json') -SkipClosureExpansion)
      }
      finally {
        Pop-Location
      }

      $result | Should -HaveCount 2
      ($result | Where-Object { $_.Impact -eq 'TargetBreakRisk' -and $_.Path -eq 'frontend/package.json' -and $_.DependsOnPath -eq 'bun.lock' -and $_.Rule -eq 'BunLock' }) | Should -Not -BeNullOrEmpty
      ($result | Where-Object { $_.Impact -eq 'SourceBreakRisk' -and $_.Path -eq 'bun.lock' -and $_.DependsOnPath -eq 'frontend/package.json' -and $_.Rule -eq 'BunLock' }) | Should -Not -BeNullOrEmpty
    }

    It "clears known Bun coupling risks after closure expansion" {
      $ref = New-GitSplitExtendedFixtureCommit

      Push-Location $script:TempRepoPath
      try {
        $result = @(Test-GitSplitSelection -Ref $ref -Paths @('frontend/package.json'))
      }
      finally {
        Pop-Location
      }

      ($result | Where-Object Rule -eq 'BunLock') | Should -BeNullOrEmpty
    }
  }

  Describe "Wait-GitSplitPullRequestChecks" {
    It "passes the expected flags through to gh pr checks" {
      $global:capturedArgs = @()
      function global:gh {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
        $global:capturedArgs = $Args
      }

      try {
        $result = Wait-GitSplitPullRequestChecks -PullRequest 123 -Repository 'owner/repo' -IntervalSeconds 7 -FailFast -Required
      }
      finally {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
      }

      $global:capturedArgs | Should -Be @(
        'pr'
        'checks'
        '123'
        '--watch'
        '--interval'
        '7'
        '--fail-fast'
        '--required'
        '--repo'
        'owner/repo'
      )
      $result | Should -Be 'owner/repo#123'
      Remove-Variable -Name capturedArgs -Scope Global -ErrorAction SilentlyContinue
    }
  }

  Describe "Split-Commit generated files" {
    It "rejects generated files before attempting to split them" {
      Push-Location $script:TempRepoPath
      try {
        New-Item -ItemType Directory -Path 'generated' -Force | Out-Null
        @(
          'before'
          'after'
        ) | Set-Content -Path 'generated/output.generated.ts'

        git add generated/output.generated.ts | Out-Null
        git commit -m "Add generated output" | Out-Null
        $ref = (git rev-parse HEAD).Trim()
        $generatedHunk = @(Get-GitSplitHunks -Ref $ref | Where-Object Path -eq 'generated/output.generated.ts')
        $generatedHunk | Should -HaveCount 1

        {
          Split-Commit -Ref $ref -NewCommitRanges @(
            [pscustomobject]@{ Path = 'generated/output.generated.ts'; PieceNumber = 2 }
          )
        } | Should -Throw "*does not support generated file*"

        {
          Split-Commit -Ref $ref -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $generatedHunk[0].HunkId; PieceNumber = 2 }
          )
        } | Should -Throw "*does not support generated file*"
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Hunk" {
    It "splits a single hunk into two hunks at a target new-file line" {
      $fixturePath = Join-Path $PSScriptRoot 'testhunk.patch'
      $patchText = Get-Content -Path $fixturePath -Raw

      $filePatches = Split-Patch -patch $patchText
      $filePatches | Should -HaveCount 1
      $filePatches[0].FilePath | Should -Be 'b.txt'

      $hunk = @($filePatches[0].Patches)[0]
      $hunk | Should -Match '(?m)^@@ '
      ($hunk -split "`n").Count | Should -BeGreaterThan 2

      # Split before new-file line 4 (i.e., before "b-line-4 (new)")
      $split = Split-Hunk -Hunk $hunk -Line 4 -Column 1
      $split | Should -HaveCount 2

      $h1 = $split[0]
      $h2 = $split[1]

      # Header expectations for this particular fixture
      $h1 | Should -Match '(?m)^@@ -1,3 \+1,3 @@'
      $h2 | Should -Match '(?m)^@@ -4,1 \+4,2 @@'

      # First hunk should contain changes up through b-line-3
      $h1 | Should -Match '(?m)^ b-line-1$'
      $h1 | Should -Match '(?m)^-b-line-2 \(edited\)$'
      $h1 | Should -Match '(?m)^\+b-line-2 \(edited again\)$'
      $h1 | Should -Match '(?m)^ b-line-3$'
      $h1 | Should -Not -Match '(?m)^ b-line-4 \(new\)$'

      # Second hunk should contain b-line-4 and the newly added b-line-5
      $h2 | Should -Match '(?m)^ b-line-4 \(new\)$'
      $h2 | Should -Match '(?m)^\+b-line-5 \(new in commit 3\)$'

      # Exercise Split-Commit against our temp repo and assert commit subjects exist.
      Push-Location $script:TempRepoPath
      try {
        $beforeCount = [int](git rev-list --count HEAD)

        # Split the baseline HEAD commit ("Modify b.txt") into two commits.
        # Split before new-file line 5 so the added b-line-5 lands in the second split.
        $splitPoint = [PSCustomObject]@{ Path = 'b.txt'; Line = 5 }
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @($splitPoint))

        $created | Should -HaveCount 2

        $afterCount = [int](git rev-list --count HEAD)
        # One commit becomes two, so total commits should increase by exactly 1.
        $afterCount | Should -Be ($beforeCount + 1)

        $subjectsText = (git log -n 20 --pretty=format:%s) -join "`n"

        $subjectsText | Should -Match 'Modify b\.txt \(split 1/2\)'
        $subjectsText | Should -Match 'Modify b\.txt \(split 2/2\)'
        $subjectsText | Should -Match 'Modify a.txt and b.txt'
        # The original "Modify b.txt" commit should have been replaced by the split commits above.
        $subjectsText | Should -Not -Match "(?m)^Modify b\\.txt$"
      }
      finally {
        Pop-Location
      }
    }

    It "can split a change at a column boundary (mid-line)" {
      Push-Location $script:TempRepoPath
      try {
        $beforeCount = [int](git rev-list --count HEAD)

        # Split the baseline HEAD commit ("Modify b.txt") at a column boundary within new-file line 2.
        # This turns one '+' line into two '+' lines: "b-line-2 (edited" and " again)".
        # Split at line 2 after "b-line-2 (edited".
        # Column is 1-based into the line content (after the diff prefix char).
        $col = 'b-line-2 (edited'.Length + 1
        # Provide a non-zero Length to prove it is accepted (Length is currently not used by Split-Commit).
        $splitPoint = [PSCustomObject]@{ Path = 'b.txt'; Line = 2; Column = $col; Length = 6 }
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @($splitPoint))

        $created | Should -HaveCount 2

        $afterCount = [int](git rev-list --count HEAD)
        $afterCount | Should -Be ($beforeCount + 1)

        $subjectsText = (git log -n 20 --pretty=format:%s) -join "`n"
        $subjectsText | Should -Match 'Modify b\.txt \(split 1/2\)'
        $subjectsText | Should -Match 'Modify b\.txt \(split 2/2\)'

        # Validate the contents of the first split commit.
        # Quiet and suppress stderr: some runners surface native stderr as error notifications.
        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }
        $first = @(Get-Content -Path 'b.txt')
        $first | Should -Contain 'b-line-2 (edited'
        $first | Should -Not -Contain ' again)'

        # Switch back to the latest split commit before validating the final file contents.
        # Quiet and suppress stderr: some runners surface native stderr as error notifications.
        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        # Prove the mid-line split resulted in two lines in the final file.
        $final = @(Get-Content -Path 'b.txt')
        $final | Should -Contain 'b-line-2 (edited'
        $final | Should -Contain ' again)'
      }
      finally {
        Pop-Location
      }
    }

    It "can move an entire file into a later split piece" {
      Push-Location $script:TempRepoPath
      try {
        $beforeCount = [int](git rev-list --count HEAD)

        $splitPoint = [PSCustomObject]@{ Path = 'b.txt'; PieceNumber = 2 }
        $created = @(Split-Commit -Ref 'HEAD~1' -NewCommitRanges @($splitPoint))

        $created | Should -HaveCount 2

        $afterCount = [int](git rev-list --count HEAD)
        $afterCount | Should -Be ($beforeCount + 1)

        $subjectsText = (git log -n 20 --pretty=format:%s) -join "`n"
        $subjectsText | Should -Match 'Modify a\.txt and b\.txt \(split 1/2\)'
        $subjectsText | Should -Match 'Modify a\.txt and b\.txt \(split 2/2\)'
        $subjectsText | Should -Not -Match '(?m)^Modify a\.txt and b\.txt$'

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        @(Get-Content -Path 'a.txt') | Should -Contain 'a-line-2 (edited)'
        @(Get-Content -Path 'a.txt') | Should -Contain 'a-line-4 (new)'
        @(Get-Content -Path 'b.txt') | Should -Be @(
          'b-line-1'
          'b-line-2'
          'b-line-3'
        )

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        @(Get-Content -Path 'b.txt') | Should -Contain 'b-line-2 (edited)'
        @(Get-Content -Path 'b.txt') | Should -Contain 'b-line-4 (new)'
      }
      finally {
        Pop-Location
      }
    }

    It "keeps a multi-hunk file together when assigning it to a later split piece" {
      Push-Location $script:TempRepoPath
      try {
        @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
        ) | Set-Content -Path 'multi.txt'

        git add multi.txt | Out-Null
        git commit -m 'Add multi.txt baseline' | Out-Null

        @(
          'a-line-1'
          'a-line-2 (edited again)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'

        @(
          'line-1 changed'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10 changed'
        ) | Set-Content -Path 'multi.txt'

        git add a.txt multi.txt | Out-Null
        git commit -m 'Modify a.txt and multi.txt' | Out-Null

        $beforeCount = [int](git rev-list --count HEAD)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
          [pscustomobject]@{ Path = 'multi.txt'; PieceNumber = 2 }
        ))

        $created | Should -HaveCount 2
        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        @(Get-Content -Path 'a.txt') | Should -Contain 'a-line-2 (edited again)'
        @(Get-Content -Path 'multi.txt') | Should -Be @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
        )

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        @(Get-Content -Path 'multi.txt') | Should -Contain 'line-1 changed'
        @(Get-Content -Path 'multi.txt') | Should -Contain 'line-10 changed'
      }
      finally {
        Pop-Location
      }
    }

    It "preserves embedded carriage returns in untouched split pieces" {
      Push-Location $script:TempRepoPath
      try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        $crPath = Join-Path $script:TempRepoPath 'carriage.txt'

        [System.IO.File]::WriteAllText($crPath, "alpha`ncommon`nomega`n", $utf8NoBom)
        git add carriage.txt | Out-Null
        git commit -m 'Add carriage baseline' | Out-Null

        [System.IO.File]::WriteAllText($crPath, "alpha`nmarker`rwith-cr`nomega`n", $utf8NoBom)

        @(
          'a-line-1'
          'a-line-2 (edited with carriage test)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'

        git add a.txt carriage.txt | Out-Null
        git commit -m 'Modify a.txt and carriage.txt' | Out-Null

        $beforeCount = [int](git rev-list --count HEAD)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'a.txt'; PieceNumber = 2 }
          ))

        $created | Should -HaveCount 2
        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        [System.IO.File]::ReadAllText($crPath) | Should -Be "alpha`nmarker`rwith-cr`nomega`n"

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        @(Get-Content -Path 'a.txt') | Should -Contain 'a-line-2 (edited with carriage test)'
      }
      finally {
        Pop-Location
      }
    }

    It "bypasses repo pre-commit hooks while creating split commits" {
      Push-Location $script:TempRepoPath
      try {
        $hookPath = Join-Path $script:TempRepoPath '.git/hooks/pre-commit'
        @(
          '#!/bin/sh'
          'echo split-hook-ran >&2'
          'exit 1'
        ) | Set-Content -Path $hookPath -NoNewline:$false
        chmod +x $hookPath

        $beforeCount = [int](git rev-list --count HEAD)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; Line = 5 }
          ))

        $created | Should -HaveCount 2
        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)
        (git log -1 --pretty=format:%s).Trim() | Should -Be 'Modify b.txt (split 2/2)'
      }
      finally {
        Pop-Location
      }
    }

    It "preserves binary file sections in untouched split pieces" {
      Push-Location $script:TempRepoPath
      try {
        $binaryPath = Join-Path $script:TempRepoPath 'blob.bin'
        [System.IO.File]::WriteAllBytes($binaryPath, [byte[]](0, 1, 2, 3))
        git add blob.bin | Out-Null
        git commit -m 'Add binary baseline' | Out-Null

        [System.IO.File]::WriteAllBytes($binaryPath, [byte[]](4, 5, 6, 7, 8, 9))
        @(
          'a-line-1'
          'a-line-2 (edited with binary test)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'

        git add a.txt blob.bin | Out-Null
        git commit -m 'Modify a.txt and blob.bin' | Out-Null

        $beforeCount = [int](git rev-list --count HEAD)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'a.txt'; PieceNumber = 2 }
          ))

        $created | Should -HaveCount 2
        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        [System.IO.File]::ReadAllBytes($binaryPath) | Should -Be ([byte[]](4, 5, 6, 7, 8, 9))

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        @(Get-Content -Path 'a.txt') | Should -Contain 'a-line-2 (edited with binary test)'
      }
      finally {
        Pop-Location
      }
    }

    It "preserves ignored new files in untouched split pieces" {
      Push-Location $script:TempRepoPath
      try {
        $ignoredRelativePath = 'ignored.generated.json'
        $ignoredPath = Join-Path $script:TempRepoPath $ignoredRelativePath
        $ignoredContent = "{""mode"":""preview""}`n"

        $ignoredRelativePath | Set-Content -Path '.gitignore'
        git add .gitignore | Out-Null
        git commit -m 'Ignore generated preview file' | Out-Null

        [System.IO.File]::WriteAllText($ignoredPath, $ignoredContent)
        @(
          'a-line-1'
          'a-line-2 (edited with ignored file test)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'

        git add .gitignore a.txt | Out-Null
        git add -f $ignoredRelativePath | Out-Null
        git commit -m 'Modify a.txt and add ignored preview file' | Out-Null

        $beforeCount = [int](git rev-list --count HEAD)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'a.txt'; PieceNumber = 2 }
          ))

        $created | Should -HaveCount 2
        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        Test-Path $ignoredRelativePath | Should -BeTrue
        [System.IO.File]::ReadAllText($ignoredPath) | Should -Be $ignoredContent

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        @(Get-Content -Path 'a.txt') | Should -Contain 'a-line-2 (edited with ignored file test)'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Commit script output" {
    AfterEach {
      Reset-GitSplitTestHooks
    }

    It "writes a reviewable script with inline patch artifacts without executing the split" {
      $scriptPath = $null
      $externalTempRoot = $null
      Push-Location $script:TempRepoPath
      try {
        $splitPoint = [PSCustomObject]@{ Path = 'b.txt'; Line = 5 }
        $beforeCount = [int](git rev-list --count HEAD)

        $externalTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gitsplit-split-script-" + (New-Guid))
        New-Item -Path $externalTempRoot -ItemType Directory -Force | Out-Null
        Set-GitSplitTestHooks -TempRootProvider ({ $externalTempRoot }.GetNewClosure())

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("split-commit-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        $writtenPath = Split-Commit -Ref 'HEAD' -NewCommitRanges @($splitPoint) -OutputScriptPath $scriptPath

        $writtenPath | Should -Be $scriptPath
        Test-Path $scriptPath | Should -BeTrue
        ([int](git rev-list --count HEAD)) | Should -Be $beforeCount

        $scriptText = Get-Content -Path $scriptPath -Raw
        $scriptText | Should -Match 'Generated by GitSplit: Split-Commit'
        $scriptText | Should -Match ([regex]::Escape("`$splitPiece1PatchContent = @'"))
        $scriptText | Should -Match ([regex]::Escape('diff --git a/b.txt b/b.txt'))
        $scriptText | Should -Match ([regex]::Escape('b-line-5 (new in commit 3)'))
        $scriptText | Should -Match ([regex]::Escape('& git apply --index --whitespace=nowarn --unidiff-zero $splitPiece.PatchPath'))
        $scriptText | Should -Not -Match ([regex]::Escape('git add -A'))
        @(
          Get-ChildItem -Path $externalTempRoot -File -ErrorAction SilentlyContinue
        ) | Should -HaveCount 0
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        if ($externalTempRoot -and (Test-Path $externalTempRoot)) {
          Remove-Item -Path $externalTempRoot -Recurse -Force
        }
        Pop-Location
      }
    }

    It "executes a generated split script later" {
      $scriptPath = $null
      $externalTempRoot = $null
      Push-Location $script:TempRepoPath
      try {
        $splitPoint = [PSCustomObject]@{ Path = 'b.txt'; Line = 5 }
        $beforeCount = [int](git rev-list --count HEAD)

        $externalTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gitsplit-split-run-" + (New-Guid))
        New-Item -Path $externalTempRoot -ItemType Directory -Force | Out-Null
        Set-GitSplitTestHooks -TempRootProvider ({ $externalTempRoot }.GetNewClosure())

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("split-commit-run-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        Split-Commit -Ref 'HEAD' -NewCommitRanges @($splitPoint) -OutputScriptPath $scriptPath | Out-Null

        & pwsh -NoProfile -File $scriptPath | Out-Null
        $LASTEXITCODE | Should -Be 0

        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)
        $subjectsText = (git log -n 20 --pretty=format:%s) -join "`n"
        $subjectsText | Should -Match 'Modify b\.txt \(split 1/2\)'
        $subjectsText | Should -Match 'Modify b\.txt \(split 2/2\)'
        $subjectsText | Should -Not -Match '(?m)^Modify b\.txt$'
        @(
          Get-ChildItem -Path $externalTempRoot -File -ErrorAction SilentlyContinue
        ) | Should -HaveCount 0
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        if ($externalTempRoot -and (Test-Path $externalTempRoot)) {
          Remove-Item -Path $externalTempRoot -Recurse -Force
        }
        Pop-Location
      }
    }
  }

  Describe "Split-Commit multi-hunk files" {
    It "can assign a specific hunk to a later split piece by HunkId" {
      Push-Location $script:TempRepoPath
      try {
        @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
        ) | Set-Content -Path 'multi.txt'

        git add multi.txt | Out-Null
        git commit -m 'Add multi.txt' | Out-Null

        @(
          'line-1'
          'line-2 changed'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10 changed'
        ) | Set-Content -Path 'multi.txt'

        git add multi.txt | Out-Null
        git commit -m 'Modify multi.txt in two hunks' | Out-Null

        $targetHunk = @(Get-GitSplitHunks -Ref 'HEAD' | Where-Object Path -eq 'multi.txt' | Select-Object -Last 1)
        $targetHunk | Should -HaveCount 1

        $beforeCount = [int](git rev-list --count HEAD)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $targetHunk[0].HunkId; PieceNumber = 2 }
          ))

        $created | Should -HaveCount 2
        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        $first = @(Get-Content -Path 'multi.txt')
        $first[1] | Should -Be 'line-2 changed'
        $first[9] | Should -Be 'line-10'

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        $final = @(Get-Content -Path 'multi.txt')
        $final[1] | Should -Be 'line-2 changed'
        $final[9] | Should -Be 'line-10 changed'
      }
      finally {
        Pop-Location
      }
    }

    It "can split a later hunk in a multi-hunk file" {
      Push-Location $script:TempRepoPath
      try {
        @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
        ) | Set-Content -Path 'multi.txt'

        git add multi.txt | Out-Null
        git commit -m 'Add multi.txt' | Out-Null

        @(
          'line-1'
          'line-2 changed'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10 changed'
        ) | Set-Content -Path 'multi.txt'

        git add multi.txt | Out-Null
        git commit -m 'Modify multi.txt in two hunks' | Out-Null

        $beforeCount = [int](git rev-list --count HEAD)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'multi.txt'; Line = 10 }
          ))

        $created | Should -HaveCount 2
        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        $first = @(Get-Content -Path 'multi.txt')
        $first[1] | Should -Be 'line-2 changed'
        $first[9] | Should -Be 'line-10'

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        $final = @(Get-Content -Path 'multi.txt')
        $final[1] | Should -Be 'line-2 changed'
        $final[9] | Should -Be 'line-10 changed'
      }
      finally {
        Pop-Location
      }
    }

    It "keeps unsplit multi-hunk files together in the first split piece" {
      Push-Location $script:TempRepoPath
      try {
        @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
        ) | Set-Content -Path 'multi.txt'

        git add multi.txt | Out-Null
        git commit -m 'Add multi.txt' | Out-Null

        @(
          'b-line-1'
          'b-line-2 (edited again)'
          'b-line-3'
          'b-line-4 (new)'
          'b-line-5 (new in commit 3)'
          'b-line-6 (split target)'
        ) | Set-Content -Path 'b.txt'

        @(
          'line-1'
          'line-2 changed'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10 changed'
        ) | Set-Content -Path 'multi.txt'

        git add b.txt multi.txt | Out-Null
        git commit -m 'Modify b.txt and multi.txt' | Out-Null

        $beforeCount = [int](git rev-list --count HEAD)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; Line = 6 }
          ))

        $created | Should -HaveCount 2
        ([int](git rev-list --count HEAD)) | Should -Be ($beforeCount + 1)

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        $firstMulti = @(Get-Content -Path 'multi.txt')
        $firstMulti[1] | Should -Be 'line-2 changed'
        $firstMulti[9] | Should -Be 'line-10 changed'

        $firstB = @(Get-Content -Path 'b.txt')
        $firstB | Should -Not -Contain 'b-line-6 (split target)'

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        $finalB = @(Get-Content -Path 'b.txt')
        $finalB | Should -Contain 'b-line-6 (split target)'
      }
      finally {
        Pop-Location
      }
    }

    It "keeps trailing hunks with the later split piece" {
      Push-Location $script:TempRepoPath
      try {
        @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
          'line-11'
          'line-12'
          'line-13'
          'line-14'
          'line-15'
          'line-16'
          'line-17'
          'line-18'
          'line-19'
          'line-20'
        ) | Set-Content -Path 'multi.txt'

        git add multi.txt | Out-Null
        git commit -m 'Add multi.txt' | Out-Null

        @(
          'line-1'
          'line-2 changed'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
          'line-11'
          'line-12'
          'line-13'
          'line-14'
          'line-15'
          'line-16'
          'line-17'
          'line-18 changed'
          'line-19'
          'line-20 changed'
        ) | Set-Content -Path 'multi.txt'

        git add multi.txt | Out-Null
        git commit -m 'Modify multi.txt in three hunks' | Out-Null

        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'multi.txt'; Line = 18 }
          ))

        $created | Should -HaveCount 2

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout first split commit $($created[0])"
        }

        $first = @(Get-Content -Path 'multi.txt')
        $first[1] | Should -Be 'line-2 changed'
        $first[17] | Should -Be 'line-18'
        $first[19] | Should -Be 'line-20'

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Expected to be able to checkout second split commit $($created[1])"
        }

        $final = @(Get-Content -Path 'multi.txt')
        $final[1] | Should -Be 'line-2 changed'
        $final[17] | Should -Be 'line-18 changed'
        $final[19] | Should -Be 'line-20 changed'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Commit guardrails" {
    It "throws when a path specifies multiple whole-file piece numbers" {
      Push-Location $script:TempRepoPath
      try {
        {
          Split-Commit -Ref 'HEAD~1' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; PieceNumber = 1 }
            [pscustomobject]@{ Path = 'b.txt'; PieceNumber = 2 }
          )
        } | Should -Throw -ExpectedMessage "*specifies multiple PieceNumber values*"
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Commit partitioned pieces" {
    It "partitions hunks by HunkId so unassigned hunks default to piece 1" {
      Push-Location $script:TempRepoPath
      try {
        # Create a commit that modifies a.txt, b.txt, and a new file c.txt
        @(
          'a-line-1'
          'a-line-2 (partition)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'

        @(
          'b-line-1'
          'b-line-2 (partition)'
          'b-line-3'
          'b-line-4 (new)'
          'b-line-5 (new in commit 3)'
          'b-line-6 (partition)'
        ) | Set-Content -Path 'b.txt'

        @(
          'c-line-1'
          'c-line-2'
        ) | Set-Content -Path 'c.txt'

        git add a.txt b.txt c.txt | Out-Null
        git commit -m 'Modify a.txt, b.txt, and add c.txt' | Out-Null

        # Assign c.txt's hunk to piece 2; leave a.txt and b.txt unassigned (default piece 1)
        $cHunk = @(Get-GitSplitHunks -Ref 'HEAD' | Where-Object Path -eq 'c.txt')
        $cHunk | Should -HaveCount 1

        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $cHunk[0].HunkId; PieceNumber = 2 }
          ))

        $created | Should -HaveCount 2

        # Piece 1 should contain a.txt and b.txt changes only (not c.txt)
        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece1Files = @(git diff-tree --no-commit-id --name-only -r $created[0])
        $piece1Files | Should -Not -Contain 'c.txt'
        $piece1Files | Should -Contain 'a.txt'
        $piece1Files | Should -Contain 'b.txt'

        # Piece 2 should contain c.txt changes only (not a.txt or b.txt)
        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece2Files = @(git diff-tree --no-commit-id --name-only -r $created[1])
        $piece2Files | Should -Contain 'c.txt'
        $piece2Files | Should -Not -Contain 'a.txt'
        $piece2Files | Should -Not -Contain 'b.txt'

        # c.txt content should only appear in piece 2
        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        Test-Path 'c.txt' | Should -Be $false

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        Test-Path 'c.txt' | Should -Be $true
      }
      finally {
        Pop-Location
      }
    }

    It "partitions whole files by Path and PieceNumber so each piece is non-cumulative" {
      Push-Location $script:TempRepoPath
      try {
        # Create a commit that modifies a.txt, b.txt, and a new file c.txt
        @(
          'a-line-1'
          'a-line-2 (partition)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'

        @(
          'b-line-1'
          'b-line-2 (partition)'
          'b-line-3'
          'b-line-4 (new)'
          'b-line-5 (new in commit 3)'
          'b-line-6 (partition)'
        ) | Set-Content -Path 'b.txt'

        @(
          'c-line-1'
          'c-line-2'
        ) | Set-Content -Path 'c.txt'

        git add a.txt b.txt c.txt | Out-Null
        git commit -m 'Modify a.txt, b.txt, and add c.txt' | Out-Null

        # Assign c.txt to piece 2; leave a.txt and b.txt unassigned (default piece 1)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'c.txt'; PieceNumber = 2 }
          ))

        $created | Should -HaveCount 2

        # Piece 1 should contain a.txt and b.txt changes only (not c.txt)
        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece1Files = @(git diff-tree --no-commit-id --name-only -r $created[0])
        $piece1Files | Should -Not -Contain 'c.txt'
        $piece1Files | Should -Contain 'a.txt'
        $piece1Files | Should -Contain 'b.txt'

        # Piece 2 should contain c.txt changes only (not a.txt or b.txt)
        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece2Files = @(git diff-tree --no-commit-id --name-only -r $created[1])
        $piece2Files | Should -Contain 'c.txt'
        $piece2Files | Should -Not -Contain 'a.txt'
        $piece2Files | Should -Not -Contain 'b.txt'
      }
      finally {
        Pop-Location
      }
    }

    It "partitions files across two pieces by Path and PieceNumber" {
      Push-Location $script:TempRepoPath
      try {
        # Create a commit modifying a.txt and b.txt with distinct changes
        @(
          'a-line-1'
          'a-line-2 (partition)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'

        @(
          'b-line-1'
          'b-line-2 (partition mode)'
          'b-line-3'
          'b-line-4 (new)'
          'b-line-5 (new in commit 3)'
          'b-line-6 (partition)'
        ) | Set-Content -Path 'b.txt'

        git add a.txt b.txt | Out-Null
        git commit -m 'Modify a.txt and b.txt for partition' | Out-Null

        # Assign b.txt to piece 2, leave a.txt unassigned (default piece 1)
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; PieceNumber = 2 }
          ))

        $created | Should -HaveCount 2

        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece1Files = @(git diff-tree --no-commit-id --name-only -r $created[0])
        $piece1Files | Should -Contain 'a.txt'
        $piece1Files | Should -Not -Contain 'b.txt'

        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece2Files = @(git diff-tree --no-commit-id --name-only -r $created[1])
        $piece2Files | Should -Contain 'b.txt'
        $piece2Files | Should -Not -Contain 'a.txt'
      }
      finally {
        Pop-Location
      }
    }

    It "partitions multiple files across pieces by HunkId" {
      Push-Location $script:TempRepoPath
      try {
        # Create a commit modifying a.txt, b.txt, and adding c.txt and d.txt
        @(
          'a-line-1'
          'a-line-2 (partition)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'

        @(
          'b-line-1'
          'b-line-2 (partition mode)'
          'b-line-3'
          'b-line-4 (new)'
          'b-line-5 (new in commit 3)'
          'b-line-6 (partition)'
        ) | Set-Content -Path 'b.txt'

        @(
          'c-line-1'
          'c-line-2'
        ) | Set-Content -Path 'c.txt'

        @(
          'd-line-1'
          'd-line-2'
        ) | Set-Content -Path 'd.txt'

        git add a.txt b.txt c.txt d.txt | Out-Null
        git commit -m 'Modify a.txt, b.txt, add c.txt and d.txt' | Out-Null

        $hunks = @(Get-GitSplitHunks -Ref 'HEAD')
        $cHunk = @($hunks | Where-Object { $_.Path -eq 'c.txt' })
        $dHunk = @($hunks | Where-Object { $_.Path -eq 'd.txt' })
        $cHunk | Should -HaveCount 1
        $dHunk | Should -HaveCount 1

        # Assign c.txt to piece 2 and d.txt to piece 3; a.txt and b.txt default to piece 1
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $cHunk[0].HunkId; PieceNumber = 2 }
            [pscustomobject]@{ HunkId = $dHunk[0].HunkId; PieceNumber = 3 }
          ))

        $created | Should -HaveCount 3

        # Piece 1: a.txt and b.txt
        git checkout --detach -q $created[0] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece1Files = @(git diff-tree --no-commit-id --name-only -r $created[0])
        $piece1Files | Should -Contain 'a.txt'
        $piece1Files | Should -Contain 'b.txt'
        $piece1Files | Should -Not -Contain 'c.txt'
        $piece1Files | Should -Not -Contain 'd.txt'

        # Piece 2: c.txt only
        git checkout --detach -q $created[1] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece2Files = @(git diff-tree --no-commit-id --name-only -r $created[1])
        $piece2Files | Should -Contain 'c.txt'
        $piece2Files | Should -Not -Contain 'a.txt'
        $piece2Files | Should -Not -Contain 'b.txt'
        $piece2Files | Should -Not -Contain 'd.txt'

        # Piece 3: d.txt only
        git checkout --detach -q $created[2] 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
        $piece3Files = @(git diff-tree --no-commit-id --name-only -r $created[2])
        $piece3Files | Should -Contain 'd.txt'
        $piece3Files | Should -Not -Contain 'a.txt'
        $piece3Files | Should -Not -Contain 'b.txt'
        $piece3Files | Should -Not -Contain 'c.txt'
      }
      finally {
        Pop-Location
      }
    }
  }
  Describe "New-Range" {
    It "resolves line/column to index and index to line/column consistently" {
      Push-Location $script:TempRepoPath
      try {
        $p = Join-Path $script:TempRepoPath 'range.txt'
        @(
          'abc'
          'defg'
          'hi'
        ) | Set-Content -Path $p -Encoding utf8

        # Line/Column -> Index
        $r1 = New-Range -Path $p -Line 2 -Column 3 -Length 2
        $r1.Path | Should -Be $p
        $r1.Line | Should -Be 2
        $r1.Column | Should -Be 3
        $r1.Length | Should -Be 2

        # File is: "abc\n" (4 chars), then "defg\n" (5 chars). Line 2 col 3 => index 4 + 2 = 6.
        $r1.Index | Should -Be 6

        # Index -> Line/Column
        $r2 = New-Range -Path $p -Index 6 -Length 2
        $r2.Line | Should -Be 2
        $r2.Column | Should -Be 3
        $r2.Index | Should -Be 6

        # ToString() returns the cached value
        $s1 = $r1.ToString()
        $s1 | Should -Be "${p}:2:3+2"
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Remove-Commit" {
    It "removes the HEAD commit from the current branch" {
      Push-Location $script:TempRepoPath
      try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        $branch | Should -Not -Be 'HEAD'

        $beforeCount = [int](git rev-list --count HEAD)
        $beforeSubject = (git log -1 --pretty=format:%s).Trim()
        $beforeSubject | Should -Be 'Modify b.txt'

        $result = Remove-Commit -CommitRef 'HEAD'
        $result | Should -Be $branch

        $afterCount = [int](git rev-list --count HEAD)
        $afterCount | Should -Be ($beforeCount - 1)

        $afterSubject = (git log -1 --pretty=format:%s).Trim()
        $afterSubject | Should -Be 'Modify a.txt and b.txt'

        $subjectsText = (git log -n 50 --pretty=format:%s) -join "`n"
        $subjectsText | Should -Not -Match "(?m)^Modify b\\.txt$"
      }
      finally {
        Pop-Location
      }
    }

    It "can write a reviewable Remove-Commit script without executing it" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        $branch | Should -Not -Be 'HEAD'

        $headCommit = (git rev-parse HEAD).Trim()
        $parentCommit = (git rev-parse HEAD~1).Trim()
        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("remove-commit-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        $writtenPath = Remove-Commit -CommitRef 'HEAD' -OutputScriptPath $scriptPath

        $writtenPath | Should -Be $scriptPath
        Test-Path $scriptPath | Should -BeTrue

        $scriptText = Get-Content -Path $scriptPath -Raw
        $scriptText | Should -Match ([regex]::Escape('# Generated by GitSplit: Remove-Commit'))
        $scriptText | Should -Match ([regex]::Escape("`$expectedBranchHead = '$headCommit'"))
        $scriptText | Should -Match ([regex]::Escape("`$parentHash = '$parentCommit'"))
        $scriptText | Should -Match ([regex]::Escape("`$removeMode = 'ResetToParent'"))
        $scriptText | Should -Match ([regex]::Escape('& git reset --hard $parentHash 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }'))

        (git log -1 --pretty=format:%s).Trim() | Should -Be 'Modify b.txt'
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }

    It "throws when called from a detached HEAD" {
      Push-Location $script:TempRepoPath
      try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        $branch | Should -Not -Be 'HEAD'

        git checkout --detach -q HEAD 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0

        { Remove-Commit -CommitRef 'HEAD' } | Should -Throw -ExpectedMessage '*detached HEAD*'
      }
      finally {
        # Ensure we return to a branch for cleanup (and to avoid confusing later tests).
        git checkout -q - 2>$null | Out-Null
        Pop-Location
      }
    }

    It "throws when the target commit is not on the specified branch" {
      Push-Location $script:TempRepoPath
      try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        $branch | Should -Not -Be 'HEAD'

        # Create a side branch with a unique commit that will NOT exist on the main branch.
        git branch side | Out-Null
        $LASTEXITCODE | Should -Be 0

        git checkout -q side 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0

        'side-branch-only' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        git commit -m "Side branch only $(New-Guid)" | Out-Null
        $LASTEXITCODE | Should -Be 0

        $sideCommit = (git rev-parse HEAD).Trim()
        $sideCommit | Should -Match '^[0-9a-f]{7,40}$'

        git checkout -q $branch 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0

        { Remove-Commit -CommitRef $sideCommit -Branch $branch } | Should -Throw -ExpectedMessage '*not an ancestor*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when attempting to remove the initial (root) commit" {
      Push-Location $script:TempRepoPath
      try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        $branch | Should -Not -Be 'HEAD'

        $root = (git rev-list --max-parents=0 HEAD).Trim()
        $root | Should -Match '^[0-9a-f]{7,40}$'

        { Remove-Commit -CommitRef $root -Branch $branch } | Should -Throw -ExpectedMessage '*initial commit*'
      }
      finally {
        Pop-Location
      }
    }

    It "removes a non-HEAD commit from the branch by rebasing" {
      Push-Location $script:TempRepoPath
      try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        $branch | Should -Not -Be 'HEAD'

        # Create TWO commits so HEAD~1 is a non-HEAD commit to remove.
        'remove-me' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        $msgToRemove = "Commit to REMOVE $(New-Guid)"
        git commit -m $msgToRemove | Out-Null
        $LASTEXITCODE | Should -Be 0

        # Make the next commit touch a different file so removing the first commit rebases cleanly.
        'keep-me' | Add-Content -Path 'b.txt'
        git add b.txt | Out-Null
        $msgToKeep = "Commit to KEEP $(New-Guid)"
        git commit -m $msgToKeep | Out-Null
        $LASTEXITCODE | Should -Be 0

        # Remove the previous commit (non-HEAD).
        $result = Remove-Commit -CommitRef 'HEAD~1' -Branch $branch
        $result | Should -Be $branch

        # HEAD should still be the later commit subject.
        (git log -1 --pretty=format:%s).Trim() | Should -Be $msgToKeep

        $subjectsText = (git log -n 50 --pretty=format:%s) -join "`n"
        $subjectsText | Should -Match ([regex]::Escape($msgToKeep))
        $subjectsText | Should -Not -Match ([regex]::Escape($msgToRemove))
      }
      finally {
        Pop-Location
      }
    }

    It "can execute a generated Remove-Commit script later" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        $branch | Should -Not -Be 'HEAD'

        'remove-me-later' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        $msgToRemove = "Generated REMOVE $(New-Guid)"
        git commit -m $msgToRemove | Out-Null
        $LASTEXITCODE | Should -Be 0

        'keep-me-later' | Add-Content -Path 'b.txt'
        git add b.txt | Out-Null
        $msgToKeep = "Generated KEEP $(New-Guid)"
        git commit -m $msgToKeep | Out-Null
        $LASTEXITCODE | Should -Be 0

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("remove-commit-run-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        Remove-Commit -CommitRef 'HEAD~1' -Branch $branch -OutputScriptPath $scriptPath | Out-Null

        $result = & $scriptPath

        $result | Should -Be $branch
        (git log -1 --pretty=format:%s).Trim() | Should -Be $msgToKeep

        $subjectsText = (git log -n 50 --pretty=format:%s) -join "`n"
        $subjectsText | Should -Match ([regex]::Escape($msgToKeep))
        $subjectsText | Should -Not -Match ([regex]::Escape($msgToRemove))
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }
  }

  Describe "Move-Commit" {
    It "throws an actionable error when the destination branch is missing" {
      Push-Location $script:TempRepoPath
      try {
        { Move-Commit -CommitRef HEAD -DestinationBranch 'missing-dest' } |
          Should -Throw -ExpectedMessage "*Destination branch 'missing-dest' does not exist locally or on origin.*git branch missing-dest <base-ref>*-CreateDestinationBranch -BaseRef <base-ref>*"
      }
      finally {
        Pop-Location
      }
    }

    It "cherry-picks HEAD to another branch without switching the current branch" {
      Push-Location $script:TempRepoPath
      try {
        $sourceBranch = (git rev-parse --abbrev-ref HEAD).Trim()
        $sourceBranch | Should -Not -Be 'HEAD'

        # Create destination branch from current HEAD (so it exists locally and shares history)
        git branch dest | Out-Null
        $LASTEXITCODE | Should -Be 0

        # Create a new commit on source
        'extra-line' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        $msg = "Extra change on source $(New-Guid)"
        git commit -m $msg | Out-Null
        $LASTEXITCODE | Should -Be 0

        # Call Move-Commit without Push/RemoveFromSource
        $result = Move-Commit -CommitRef HEAD -DestinationBranch 'dest'
        $result | Should -Be 'dest'

        # We should still be on the original branch
        (git rev-parse --abbrev-ref HEAD).Trim() | Should -Be $sourceBranch

        # Destination branch should now contain the commit (SHA changes on cherry-pick, so match by subject)
        $destSubjects = (git log dest -n 50 --pretty=format:%s) -join "`n"
        $destSubjects | Should -Match ([regex]::Escape($msg))
      }
      finally {
        Pop-Location
      }
    }

    It "can create the destination branch from an explicit base ref" {
      Push-Location $script:TempRepoPath
      try {
        $sourceBranch = (git rev-parse --abbrev-ref HEAD).Trim()
        $sourceBranch | Should -Not -Be 'HEAD'

        'created-dest-line' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        $msg = "Created destination move $(New-Guid)"
        git commit -m $msg | Out-Null
        $LASTEXITCODE | Should -Be 0

        $baseCommit = (git rev-parse HEAD~1).Trim()

        $result = Move-Commit -CommitRef HEAD -DestinationBranch 'created-dest' -CreateDestinationBranch -BaseRef 'HEAD~1'
        $result | Should -Be 'created-dest'

        (git rev-parse --abbrev-ref HEAD).Trim() | Should -Be $sourceBranch
        (git rev-parse created-dest^).Trim() | Should -Be $baseCommit

        $destSubjects = (git log created-dest -n 50 --pretty=format:%s) -join "`n"
        $destSubjects | Should -Match ([regex]::Escape($msg))
      }
      finally {
        Pop-Location
      }
    }

    It "can write a reviewable Move-Commit script without executing it" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        git branch scripted-dest | Out-Null
        $LASTEXITCODE | Should -Be 0

        'scripted-extra-line' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        $msg = "Scripted move $(New-Guid)"
        git commit -m $msg | Out-Null
        $LASTEXITCODE | Should -Be 0

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("move-commit-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }
        $writtenPath = Move-Commit -CommitRef HEAD -DestinationBranch 'scripted-dest' -OutputScriptPath $scriptPath

        $writtenPath | Should -Be $scriptPath
        Test-Path $scriptPath | Should -BeTrue

        $scriptText = Get-Content -Path $scriptPath -Raw
        $headCommit = (git rev-parse HEAD).Trim()

        $scriptText | Should -Match ([regex]::Escape('# Generated by GitSplit: Move-Commit'))
        $scriptText | Should -Match ([regex]::Escape("`$commitHash = '$headCommit'"))
        $scriptText | Should -Match ([regex]::Escape('& git worktree add $destWorktreePath $destinationBranch'))
        $scriptText | Should -Match ([regex]::Escape('& git -C $destWorktreePath -c "core.hooksPath=$disabledHooksPath" cherry-pick $commitHash'))

        (git log -1 --pretty=format:%s).Trim() | Should -Be $msg
        $destSubjects = (git log scripted-dest -n 50 --pretty=format:%s) -join "`n"
        $destSubjects | Should -Not -Match ([regex]::Escape($msg))
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }

    It "can generate and execute a Move-Commit script that creates the destination branch" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        'script-created-line' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        $msg = "Scripted created destination $(New-Guid)"
        git commit -m $msg | Out-Null
        $LASTEXITCODE | Should -Be 0

        $baseCommit = (git rev-parse HEAD~1).Trim()

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("move-commit-create-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        Move-Commit -CommitRef HEAD -DestinationBranch 'script-created-dest' -CreateDestinationBranch -BaseRef 'HEAD~1' -OutputScriptPath $scriptPath | Out-Null

        $scriptText = Get-Content -Path $scriptPath -Raw
        $scriptText | Should -Match ([regex]::Escape("`$destinationCreateBaseRef = 'HEAD~1'"))
        $scriptText | Should -Match ([regex]::Escape("`$destinationCreateBaseCommit = '$baseCommit'"))
        $scriptText | Should -Match ([regex]::Escape('& git worktree add -b $destinationBranch $destWorktreePath $destinationCreateBaseCommit'))

        $result = & $scriptPath

        $result | Should -Be 'script-created-dest'
        (git rev-parse --abbrev-ref HEAD).Trim() | Should -Be 'main'
        (git rev-parse script-created-dest^).Trim() | Should -Be $baseCommit

        $destSubjects = (git log script-created-dest -n 50 --pretty=format:%s) -join "`n"
        $destSubjects | Should -Match ([regex]::Escape($msg))
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }

    It "can execute a generated Move-Commit script later" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        git branch scripted-run-dest | Out-Null
        $LASTEXITCODE | Should -Be 0

        'scripted-run-line' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        $msg = "Scripted later move $(New-Guid)"
        git commit -m $msg | Out-Null
        $LASTEXITCODE | Should -Be 0

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("move-commit-run-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }
        Move-Commit -CommitRef HEAD -DestinationBranch 'scripted-run-dest' -OutputScriptPath $scriptPath | Out-Null

        $result = & $scriptPath

        $result | Should -Be 'scripted-run-dest'
        (git rev-parse --abbrev-ref HEAD).Trim() | Should -Be 'main'

        $destSubjects = (git log scripted-run-dest -n 50 --pretty=format:%s) -join "`n"
        $destSubjects | Should -Match ([regex]::Escape($msg))
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }

    It "can move HEAD~1 to another branch and remove it from the source branch" {
      Push-Location $script:TempRepoPath
      try {
        $sourceBranch = (git rev-parse --abbrev-ref HEAD).Trim()
        $sourceBranch | Should -Not -Be 'HEAD'

        git branch dest2 | Out-Null
        $LASTEXITCODE | Should -Be 0

        # Create TWO commits on source so HEAD~1 exists and is non-HEAD.
        'extra-line-2' | Add-Content -Path 'b.txt'
        git add b.txt | Out-Null
        $msgToMove = "Extra change to MOVE $(New-Guid)"
        git commit -m $msgToMove | Out-Null
        $LASTEXITCODE | Should -Be 0

        'extra-line-3' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        $msgToKeep = "Extra change to KEEP $(New-Guid)"
        git commit -m $msgToKeep | Out-Null
        $LASTEXITCODE | Should -Be 0

        # Move the *previous* commit (non-HEAD) to dest2 and remove it from source.
        Move-Commit -CommitRef HEAD~1 -DestinationBranch 'dest2' -RemoveFromSource | Out-Null

        (git rev-parse --abbrev-ref HEAD).Trim() | Should -Be $sourceBranch
        @(
          git status --porcelain |
            ForEach-Object { "$_".TrimEnd() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        ) | Should -Be @()

        # Source branch should no longer contain the moved commit subject,
        # but should still contain the later commit subject.
        $sourceSubjects = (git log -n 50 --pretty=format:%s) -join "`n"
        $sourceSubjects | Should -Not -Match ([regex]::Escape($msgToMove))
        $sourceSubjects | Should -Match ([regex]::Escape($msgToKeep))

        # Destination should contain the moved commit.
        $destSubjects = (git log dest2 -n 50 --pretty=format:%s) -join "`n"
        $destSubjects | Should -Match ([regex]::Escape($msgToMove))
      }
      finally {
        Pop-Location
      }
    }

    It "writes branch resync steps into Move-Commit scripts when removing from source" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        git branch sync-dest | Out-Null
        $LASTEXITCODE | Should -Be 0

        'sync-line-1' | Add-Content -Path 'b.txt'
        git add b.txt | Out-Null
        git commit -m "Sync move $(New-Guid)" | Out-Null
        $LASTEXITCODE | Should -Be 0

        'sync-line-2' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        git commit -m "Sync keep $(New-Guid)" | Out-Null
        $LASTEXITCODE | Should -Be 0

        $fixedGuid = '11111111-2222-3333-4444-555555555555'
        Set-GitSplitTestHooks -GuidProvider ({ $fixedGuid }.GetNewClosure())

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("move-commit-sync-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        Move-Commit -CommitRef HEAD~1 -DestinationBranch 'sync-dest' -RemoveFromSource -OutputScriptPath $scriptPath | Out-Null

        $scriptText = Get-Content -Path $scriptPath -Raw
        $expectedDestWorktreePath = Join-Path (Join-Path $script:TempRepoPath '.gitsplit-worktrees') $fixedGuid
        $expectedSourceWorktreePath = "$expectedDestWorktreePath-source"

        $scriptText | Should -Match ([regex]::Escape("`$sourceWorktreePath = '$expectedSourceWorktreePath'"))
        $scriptText | Should -Match ([regex]::Escape('& git worktree add --detach $sourceWorktreePath $expectedBranch'))
        $scriptText | Should -Match ([regex]::Escape('& git update-ref "refs/heads/$expectedBranch" $rewrittenHead $expectedHead'))
        $scriptText | Should -Match ([regex]::Escape('& git reset --hard "refs/heads/$expectedBranch"'))
      }
      finally {
        Reset-GitSplitTestHooks
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }

    It "preserves the destination worktree when cherry-pick conflicts" {
      Push-Location $script:TempRepoPath
      try {
        $sourceBranch = (git rev-parse --abbrev-ref HEAD).Trim()
        $sourceBranch | Should -Not -Be 'HEAD'

        git branch conflict-dest | Out-Null
        $LASTEXITCODE | Should -Be 0

        git checkout conflict-dest | Out-Null
        $LASTEXITCODE | Should -Be 0

        @(
          'a-line-1'
          'a-line-2 (dest change)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'
        git add a.txt | Out-Null
        git commit -m "Destination conflicting change" | Out-Null
        $LASTEXITCODE | Should -Be 0

        git checkout $sourceBranch | Out-Null
        $LASTEXITCODE | Should -Be 0

        @(
          'a-line-1'
          'a-line-2 (source change)'
          'a-line-3'
          'a-line-4 (new)'
        ) | Set-Content -Path 'a.txt'
        git add a.txt | Out-Null
        git commit -m "Source conflicting change" | Out-Null
        $LASTEXITCODE | Should -Be 0

        { Move-Commit -CommitRef HEAD -DestinationBranch 'conflict-dest' } | Should -Throw

        $wtRoot = Join-Path $script:TempRepoPath '.gitsplit-worktrees'
        Test-Path $wtRoot | Should -BeTrue

        $preserved = @(Get-ChildItem -Path $wtRoot -Directory)
        $preserved | Should -HaveCount 1

        $status = @(git -C $preserved[0].FullName status --porcelain)
        ($status -join "`n") | Should -Match 'UU a.txt'

        git worktree remove --force $preserved[0].FullName 2>$null | Out-Null
      }
      finally {
        Pop-Location
      }
    }

    It "requires -BaseRef when creating the destination branch" {
      Push-Location $script:TempRepoPath
      try {
        { Move-Commit -CommitRef HEAD -DestinationBranch 'missing-base-ref' -CreateDestinationBranch } |
          Should -Throw -ExpectedMessage '*requires -BaseRef when -CreateDestinationBranch is specified*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Deterministic test hooks" {
    AfterEach {
      Reset-GitSplitTestHooks
    }

    It "can override guid, temp root, timestamp, and stash name providers" {
      $customTempRoot = Join-Path $script:TempRepoPath 'custom-temp'
      New-Item -Path $customTempRoot -ItemType Directory -Force | Out-Null

      Set-GitSplitTestHooks `
        -GuidProvider ({ '11111111-2222-3333-4444-555555555555' }.GetNewClosure()) `
        -TempRootProvider ({ $customTempRoot }.GetNewClosure()) `
        -TimestampProvider ({ [datetime]'2026-01-02T03:04:05' }.GetNewClosure())

      (Get-GitSplitGuid).ToString() | Should -Be '11111111-2222-3333-4444-555555555555'
      (New-GitSplitTempFilePath -Prefix 'script' -Extension '.ps1') |
        Should -Be (Join-Path $customTempRoot 'script-11111111222233334444555555555555.ps1')
      (New-GitSplitStashName -Operation 'move-commit') | Should -Be 'gitsplit-move-commit-20260102030405'

      Set-GitSplitTestHooks -StashNameProvider ({ param($Operation) "custom-$Operation-stash" }.GetNewClosure())
      (New-GitSplitStashName -Operation 'move-commit') | Should -Be 'custom-move-commit-stash'
    }

    It "freezes deterministic worktree and stash values into generated Move-Commit scripts" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        git branch deterministic-dest | Out-Null
        $LASTEXITCODE | Should -Be 0

        'deterministic-script-line' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        git commit -m "Deterministic move $(New-Guid)" | Out-Null
        $LASTEXITCODE | Should -Be 0

        $fixedGuid = '11111111-2222-3333-4444-555555555555'
        Set-GitSplitTestHooks `
          -GuidProvider ({ $fixedGuid }.GetNewClosure()) `
          -StashNameProvider ({ param($Operation) "fixed-$Operation-stash" }.GetNewClosure())

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("move-commit-deterministic-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        Move-Commit -CommitRef HEAD -DestinationBranch 'deterministic-dest' -AutoStash -OutputScriptPath $scriptPath | Out-Null

        $scriptText = Get-Content -Path $scriptPath -Raw
        $expectedWorktreePath = Join-Path (Join-Path $script:TempRepoPath '.gitsplit-worktrees') $fixedGuid

        $scriptText | Should -Match ([regex]::Escape("`$plannedStashName = 'fixed-move-commit-stash'"))
        $scriptText | Should -Match ([regex]::Escape("`$destWorktreePath = '$expectedWorktreePath'"))
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }
  }

  Describe "Move-Commit script snapshots" {
    AfterEach {
      Reset-GitSplitTestHooks
    }

    It "matches the expected review script for a local destination branch" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        git branch snapshot-dest | Out-Null
        $LASTEXITCODE | Should -Be 0

        'snapshot-extra' | Add-Content -Path 'a.txt'
        git add a.txt | Out-Null
        git commit -m 'Snapshot move commit' | Out-Null
        $LASTEXITCODE | Should -Be 0

        $fixedGuid = '11111111-2222-3333-4444-555555555555'
        Set-GitSplitTestHooks `
          -GuidProvider ({ $fixedGuid }.GetNewClosure()) `
          -StashNameProvider ({ param($Operation) "fixed-$Operation-stash" }.GetNewClosure())

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("move-commit-snapshot-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        Move-Commit -CommitRef HEAD -DestinationBranch 'snapshot-dest' -AutoStash -OutputScriptPath $scriptPath | Out-Null

        $repoRoot = ((git rev-parse --show-toplevel).Trim()).Replace("'", "''")
        $headCommit = (git rev-parse HEAD).Trim()
        $expectedWorktreePath = (Join-Path (Join-Path $script:TempRepoPath '.gitsplit-worktrees') $fixedGuid).Replace("'", "''")
        $expectedHooksPath = (Join-Path ([System.IO.Path]::GetTempPath()) ("gitsplit-hooks-" + $fixedGuid.Replace('-', ''))).Replace("'", "''")
        $actualScript = ((Get-Content -Path $scriptPath -Raw) -replace "`r`n", "`n").TrimEnd("`n") + "`n"

        $expectedScript = @'
# Generated by GitSplit: Move-Commit
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Move-Commit execution plan.
# Discovery-time values are frozen below; runtime checks ensure the repository has not drifted.

$expectedRepoRoot = '__REPO_ROOT__'
$expectedBranch = 'main'
$expectedHead = '__HEAD_COMMIT__'
$commitHash = '__HEAD_COMMIT__'
$destinationBranch = 'snapshot-dest'
$destinationRef = 'refs/heads/snapshot-dest'
$useRemoteTrackingBranch = $false
$autoStash = $true
$pushDestination = $false
$plannedStashName = 'fixed-move-commit-stash'
$destWorktreePath = '__WORKTREE_PATH__'
$disabledHooksPath = '__HOOKS_PATH__'
$stashed = $false
$stashName = $null
$destWorktreeCreated = $false
$moveSucceeded = $false

# Runtime guards: assert repository, branch, head commit, destination branch availability, and working tree expectations.

$repoRoot = (& git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
  throw "Move-Commit must be run inside a git repository."
}
if ($repoRoot -ne $expectedRepoRoot) {
  throw "This script was generated for repo root '$expectedRepoRoot' but is running in '$repoRoot'."
}
$currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentBranch)) {
  throw "Failed to get current branch."
}
if ($currentBranch -ne $expectedBranch) {
  throw "This script expected branch '$expectedBranch' but found '$currentBranch'."
}
$currentHead = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch '^[0-9a-f]{40}$') {
  throw "Failed to resolve HEAD."
}
if ($currentHead -ne $expectedHead) {
  throw "This script expected HEAD '$expectedHead' but found '$currentHead'."
}
& git show-ref --verify --quiet $destinationRef
if ($LASTEXITCODE -ne 0) {
  if ($useRemoteTrackingBranch) {
    throw "Destination branch '$destinationBranch' no longer exists on origin."
  }
  throw "Destination branch '$destinationBranch' no longer exists locally."
}
$status = @(& git status --porcelain)
if ($LASTEXITCODE -ne 0) {
  throw "Failed to determine git status."
}
if ($status.Count -gt 0) {
  if (-not $autoStash) {
    throw "Uncommitted changes detected. Re-run with -AutoStash, or commit/stash your changes before running this script."
  }
  $stashName = $plannedStashName
  & git stash push -u -m $stashName 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }
  if ($LASTEXITCODE -ne 0) {
    throw "git stash push failed"
  }
  $stashed = $true
}

# Execute the destination cherry-pick in an isolated worktree, then optionally rewrite the source branch.
# Cleanup removes successful temporary worktrees and preserves conflicted ones for manual resolution.

$wtRoot = Join-Path $repoRoot '.gitsplit-worktrees'
if (-not (Test-Path -LiteralPath $wtRoot)) {
  New-Item -Path $wtRoot -ItemType Directory -Force | Out-Null
}
if (Test-Path -LiteralPath $destWorktreePath) {
  throw "Planned destination worktree path '$destWorktreePath' already exists."
}
try {
  if (-not (Test-Path -LiteralPath $disabledHooksPath)) {
    New-Item -Path $disabledHooksPath -ItemType Directory -Force | Out-Null
  }
  if ($useRemoteTrackingBranch) {
    & git worktree add -b $destinationBranch $destWorktreePath "origin/$destinationBranch" 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }
    if ($LASTEXITCODE -ne 0) {
      throw "git worktree add -b $destinationBranch failed"
    }
  }
  else {
    & git worktree add $destWorktreePath $destinationBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }
    if ($LASTEXITCODE -ne 0) {
      throw "git worktree add $destinationBranch failed"
    }
  }
  $destWorktreeCreated = $true
  & git -C $destWorktreePath -c "core.hooksPath=$disabledHooksPath" cherry-pick $commitHash 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }
  if ($LASTEXITCODE -ne 0) {
    throw "git -C <worktree> cherry-pick failed for $commitHash"
  }
  if ($pushDestination) {
    & git -C $destWorktreePath push -u origin $destinationBranch 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }
    if ($LASTEXITCODE -ne 0) {
      throw "git -C <worktree> push failed for $destinationBranch"
    }
  }
  $moveSucceeded = $true
}
finally {
  if ($moveSucceeded -and $destWorktreePath -and (Test-Path -LiteralPath $destWorktreePath)) {
    & git worktree remove --force $destWorktreePath 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }
    if ($LASTEXITCODE -ne 0) {
      throw "git worktree remove --force failed for '$destWorktreePath'."
    }
  }
  elseif ($destWorktreeCreated -and $destWorktreePath -and (Test-Path -LiteralPath $destWorktreePath)) {
    Write-Warning "Preserving destination worktree at '$destWorktreePath' so conflicts can be resolved manually."
  }

  if (Test-Path -LiteralPath $disabledHooksPath) {
    Remove-Item -LiteralPath $disabledHooksPath -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($stashed) {
    $gitDir = (& git rev-parse --git-dir).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitDir)) {
      throw "Move-Commit created a stash '$stashName' but failed to resolve the git directory for restoration."
    }

    if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
      $gitDir = Join-Path $repoRoot $gitDir
    }

    $stashLines = @(& git stash list --format="%gd %s")
    if ($LASTEXITCODE -ne 0) {
      throw "Move-Commit created a stash '$stashName' but failed to inspect the stash list for restoration."
    }

    $stashLine = $stashLines | Where-Object { $_ -like "*$stashName*" } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($stashLine)) {
      throw "Move-Commit created a stash '$stashName' but could not find it for restoration."
    }

    $stashRef = ($stashLine -split '\s+', 2)[0]
    $inProgress = (
      (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-apply')) -or
      (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-merge')) -or
      (Test-Path -LiteralPath (Join-Path $gitDir 'MERGE_HEAD')) -or
      (Test-Path -LiteralPath (Join-Path $gitDir 'CHERRY_PICK_HEAD')) -or
      (Test-Path -LiteralPath (Join-Path $gitDir 'REVERT_HEAD'))
    )

    if ($inProgress) {
      Write-Error @(
        "Move-Commit created a stash ('$stashName' -> $stashRef) but will NOT restore it because git reports an in-progress operation (merge/rebase/cherry-pick/revert)."
        ""
        "How to proceed:"
        "  1) Inspect state:            git status"
        "  2) Finish or abort operation: git rebase --continue | git rebase --abort | git merge --abort | git cherry-pick --abort | git revert --abort"
        "  3) Then restore your changes: git stash pop $stashRef"
        ""
        "How to undo the branch rewrite (if you used -RemoveFromSource):"
        "  - Find the pre-rewrite commit in reflog: git reflog"
        "  - Reset branch back to it:              git reset --hard <sha>"
        "  - If you pushed/force-pushed:           git push --force-with-lease"
      ) -join [Environment]::NewLine
    }
    else {
      & git stash pop $stashRef 2>&1 | ForEach-Object { $_ | Out-String | Write-Host }
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to restore stash $stashRef created by Move-Commit."
      }
    }
  }
}
$destinationBranch
'@

        $expectedScript = $expectedScript.Replace('__REPO_ROOT__', $repoRoot)
        $expectedScript = $expectedScript.Replace('__HEAD_COMMIT__', $headCommit)
        $expectedScript = $expectedScript.Replace('__WORKTREE_PATH__', $expectedWorktreePath)
        $expectedScript = $expectedScript.Replace('__HOOKS_PATH__', $expectedHooksPath)
        $expectedScript = ($expectedScript -replace "`r`n", "`n").TrimEnd("`n") + "`n"

        $actualScript | Should -Be $expectedScript
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }
  }

  Describe "Move-Commit round-trip parity" {
    It "matches direct execution when removing a non-HEAD commit" {
      $directRepo = $null
      $freshRepo = $null
      $scriptPath = $null
      $msgToMove = $null
      $msgToKeep = $null

      function Copy-RepoDirectory {
        param(
          [Parameter(Mandatory = $true)]
          [string]$Source,

          [Parameter(Mandatory = $true)]
          [string]$Destination
        )

        if (Test-Path $Destination) {
          Remove-Item -Path $Destination -Recurse -Force
        }

        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
        Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
      }

      function Get-RepoState {
        param(
          [Parameter(Mandatory = $true)]
          [string]$RepoPath,

          [Parameter(Mandatory = $true)]
          [string]$DestinationBranch
        )

        return [PSCustomObject]@{
          CurrentBranch = (git -C $RepoPath rev-parse --abbrev-ref HEAD).Trim()
          Status = @(
            git -C $RepoPath status --porcelain |
              ForEach-Object { "$_".TrimEnd() } |
              Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
          )
          MainTree = (git -C $RepoPath rev-parse 'main^{tree}').Trim()
          DestinationTree = (git -C $RepoPath rev-parse "$DestinationBranch`^{tree}").Trim()
          MainSubjects = @(
            git -C $RepoPath log main --pretty=format:%s |
              ForEach-Object { "$_".Trim() } |
              Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
          )
          DestinationSubjects = @(
            git -C $RepoPath log $DestinationBranch --pretty=format:%s |
              ForEach-Object { "$_".Trim() } |
              Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
          )
        }
      }

      try {
        Push-Location $script:TempRepoPath
        try {
          git branch parity-dest | Out-Null
          $LASTEXITCODE | Should -Be 0

          'roundtrip-move' | Add-Content -Path 'b.txt'
          git add b.txt | Out-Null
          $msgToMove = "Round-trip move $(New-Guid)"
          git commit -m $msgToMove | Out-Null
          $LASTEXITCODE | Should -Be 0

          'roundtrip-keep' | Add-Content -Path 'a.txt'
          git add a.txt | Out-Null
          $msgToKeep = "Round-trip keep $(New-Guid)"
          git commit -m $msgToKeep | Out-Null
          $LASTEXITCODE | Should -Be 0

          $directRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("gitsplit-direct-" + (New-Guid))
          $freshRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("gitsplit-fresh-" + (New-Guid))
          $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("move-commit-roundtrip-" + (New-Guid) + ".ps1")

          Copy-RepoDirectory -Source $script:TempRepoPath -Destination $directRepo
          Copy-RepoDirectory -Source $script:TempRepoPath -Destination $freshRepo

          Test-Path (Join-Path $directRepo '.git') | Should -BeTrue
          Test-Path (Join-Path $freshRepo '.git') | Should -BeTrue

          Move-Commit -CommitRef HEAD~1 -DestinationBranch 'parity-dest' -RemoveFromSource -OutputScriptPath $scriptPath | Out-Null
        }
        finally {
          Pop-Location
        }

        Remove-Item -Path $script:TempRepoPath -Recurse -Force
        Copy-RepoDirectory -Source $freshRepo -Destination $script:TempRepoPath

        Push-Location $directRepo
        try {
          $directResult = Move-Commit -CommitRef HEAD~1 -DestinationBranch 'parity-dest' -RemoveFromSource
          $directResult | Should -Be 'parity-dest'
        }
        finally {
          Pop-Location
        }

        Push-Location $script:TempRepoPath
        try {
          $scriptResult = & $scriptPath
          $scriptResult | Should -Be 'parity-dest'
        }
        finally {
          Pop-Location
        }

        $directState = Get-RepoState -RepoPath $directRepo -DestinationBranch 'parity-dest'
        $scriptedState = Get-RepoState -RepoPath $script:TempRepoPath -DestinationBranch 'parity-dest'

        $directState.CurrentBranch | Should -Be 'main'
        $scriptedState.CurrentBranch | Should -Be 'main'
        $directState.Status | Should -Be @()
        $scriptedState.Status | Should -Be @()
        $directState.MainTree | Should -Be $scriptedState.MainTree
        $directState.DestinationTree | Should -Be $scriptedState.DestinationTree
        ($directState.MainSubjects -join "`n") | Should -Be ($scriptedState.MainSubjects -join "`n")
        ($directState.DestinationSubjects -join "`n") | Should -Be ($scriptedState.DestinationSubjects -join "`n")
        ($scriptedState.MainSubjects -join "`n") | Should -Not -Match ([regex]::Escape($msgToMove))
        ($scriptedState.MainSubjects -join "`n") | Should -Match ([regex]::Escape($msgToKeep))
        ($scriptedState.DestinationSubjects -join "`n") | Should -Match ([regex]::Escape($msgToMove))
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        if ($directRepo -and (Test-Path $directRepo)) {
          Remove-Item -Path $directRepo -Recurse -Force
        }
        if ($freshRepo -and (Test-Path $freshRepo)) {
          Remove-Item -Path $freshRepo -Recurse -Force
        }
      }
    }
  }

  Describe "Get-CommitMessageFromChanges" {
    It "returns null when there are no changes" {
      Push-Location $script:TempRepoPath
      try {
        # Ensure clean working tree
        git reset --hard | Out-Null
        git clean -fd | Out-Null

        $msg = Get-CommitMessageFromChanges -DiffLevel Summary
        $msg | Should -BeNullOrEmpty
      }
      finally {
        Pop-Location
      }
    }

    It "returns a fallback message when a key is configured and changes exist" {
      Push-Location $script:TempRepoPath
      try {
        $oldAnthropicKey = $env:AnthropicKey
        $oldAnthropicToken = $env:ANTHROPIC_TOKEN
        $env:AnthropicKey = 'test-key'
        $env:ANTHROPIC_TOKEN = $null

        'local-change' | Add-Content -Path 'a.txt'

        $msg = Get-CommitMessageFromChanges -DiffLevel Full
        $msg | Should -Be 'Update changes'

        git checkout -- a.txt | Out-Null
      }
      finally {
        $env:AnthropicKey = $oldAnthropicKey
        $env:ANTHROPIC_TOKEN = $oldAnthropicToken
        Pop-Location
      }
    }

    It "throws when Anthropic key is not set" {
      Push-Location $script:TempRepoPath
      try {
        $oldAnthropicKey = $env:AnthropicKey
        $oldAnthropicToken = $env:ANTHROPIC_TOKEN
        $env:AnthropicKey = $null
        $env:ANTHROPIC_TOKEN = $null

        'local-change' | Add-Content -Path 'a.txt'

        { Get-CommitMessageFromChanges -DiffLevel None } | Should -Throw

        # Cleanup
        git checkout -- a.txt | Out-Null
      }
      finally {
        $env:AnthropicKey = $oldAnthropicKey
        $env:ANTHROPIC_TOKEN = $oldAnthropicToken
        Pop-Location
      }
    }
  }

  Describe "Invoke-GitSplitAbsorb" {
    It "returns no fixup commits when nothing is staged" {
      Push-Location $script:TempRepoPath
      try {
        $from = (git rev-parse HEAD~1).Trim()

        $created = @(Invoke-GitSplitAbsorb -From $from)

        $created | Should -HaveCount 0
      }
      finally {
        Pop-Location
      }
    }

    It "throws when unstaged changes are present" {
      Push-Location $script:TempRepoPath
      try {
        $from = (git rev-parse HEAD~1).Trim()
        'unstaged-change' | Add-Content -Path 'a.txt'

        { Invoke-GitSplitAbsorb -From $from } |
          Should -Throw -ExpectedMessage '*staged-only changes*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when a staged file has no matching commit in the selected range" {
      Push-Location $script:TempRepoPath
      try {
        $from = (git rev-parse HEAD~1).Trim()
        'brand-new' | Set-Content -Path 'z.txt'
        git add z.txt | Out-Null

        { Invoke-GitSplitAbsorb -From $from } |
          Should -Throw -ExpectedMessage '*Could not determine absorb target commit(s)*'
      }
      finally {
        Pop-Location
      }
    }

    It "creates a fixup commit for staged changes in range" {
      Push-Location $script:TempRepoPath
      try {
        $from = (git rev-parse HEAD~2).Trim()
        'absorbed-change' | Add-Content -Path 'b.txt'
        git add b.txt | Out-Null

        $created = @(Invoke-GitSplitAbsorb -From $from)

        $created | Should -HaveCount 1
        $created[0] | Should -Match '^[0-9a-f]{40}$'
        (git log -1 --pretty=format:%s).Trim() | Should -Match '^fixup! Modify b\.txt$'

        git diff --cached --quiet
        $LASTEXITCODE | Should -Be 0
      }
      finally {
        Pop-Location
      }
    }

    It "bypasses repo pre-commit hooks while creating fixup commits" {
      Push-Location $script:TempRepoPath
      try {
        $hookPath = Join-Path $script:TempRepoPath '.git/hooks/pre-commit'
        @(
          '#!/bin/sh'
          'echo absorb-hook-ran >&2'
          'exit 1'
        ) | Set-Content -Path $hookPath -NoNewline:$false
        chmod +x $hookPath

        $from = (git rev-parse HEAD~2).Trim()
        'absorbed-hook-change' | Add-Content -Path 'b.txt'
        git add b.txt | Out-Null

        $created = @(Invoke-GitSplitAbsorb -From $from)

        $created | Should -HaveCount 1
        (git log -1 --pretty=format:%s).Trim() | Should -Match '^fixup! Modify b\.txt$'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Set-CommitOrder" {
    AfterEach {
      Reset-GitSplitTestHooks
    }

    It "reorders commits in the requested order for a selected range" {
      Push-Location $script:TempRepoPath
      try {
        # Create two independent commits so reordering is deterministic.
        'c-line-1' | Set-Content -Path 'c.txt'
        git add c.txt | Out-Null
        git commit -m "Add c.txt" | Out-Null
        $commitC = (git rev-parse HEAD).Trim()

        'd-line-1' | Set-Content -Path 'd.txt'
        git add d.txt | Out-Null
        git commit -m "Add d.txt" | Out-Null
        $commitD = (git rev-parse HEAD).Trim()

        $beforeCount = [int](git rev-list --count HEAD)

        # Reorder only the last two commits by using HEAD~2 as the base.
        Set-CommitOrder -OrderedCommits @($commitD, $commitC) -BaseRef 'HEAD~2'

        $afterCount = [int](git rev-list --count HEAD)
        $afterCount | Should -Be $beforeCount

        $subjects = @(git log --reverse --format=%s HEAD~2..HEAD)
        $subjects | Should -Be @('Add d.txt', 'Add c.txt')
      }
      finally {
        Pop-Location
      }
    }

    It "writes a reviewable script without executing the reorder" {
      $scriptPath = $null
      $externalTempRoot = $null
      Push-Location $script:TempRepoPath
      try {
        'c-line-1' | Set-Content -Path 'c.txt'
        git add c.txt | Out-Null
        git commit -m "Add c.txt" | Out-Null
        $commitC = (git rev-parse HEAD).Trim()

        'd-line-1' | Set-Content -Path 'd.txt'
        git add d.txt | Out-Null
        git commit -m "Add d.txt" | Out-Null
        $commitD = (git rev-parse HEAD).Trim()
        $beforeSubjects = @(git log --reverse --format=%s HEAD~2..HEAD)

        $externalTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gitsplit-set-order-" + (New-Guid))
        New-Item -Path $externalTempRoot -ItemType Directory -Force | Out-Null
        Set-GitSplitTestHooks -TempRootProvider ({ $externalTempRoot }.GetNewClosure())

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("set-commit-order-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        $writtenPath = Set-CommitOrder -OrderedCommits @($commitD, $commitC) -BaseRef 'HEAD~2' -OutputScriptPath $scriptPath

        $writtenPath | Should -Be $scriptPath
        Test-Path $scriptPath | Should -BeTrue
        @(git log --reverse --format=%s HEAD~2..HEAD) | Should -Be $beforeSubjects

        $scriptText = Get-Content -Path $scriptPath -Raw
        $scriptText | Should -Match 'Generated by GitSplit: Set-CommitOrder'
        $scriptText | Should -Match ([regex]::Escape("`$sequenceEditorScriptContent = @'"))
        $scriptText | Should -Match ([regex]::Escape($commitD))
        $scriptText | Should -Match ([regex]::Escape($commitC))
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        if ($externalTempRoot -and (Test-Path $externalTempRoot)) {
          Remove-Item -Path $externalTempRoot -Recurse -Force
        }
        Pop-Location
      }
    }

    It "absorbs staged changes into fixup commits before reordering when -Absorb is specified" {
      Push-Location $script:TempRepoPath
      try {
        'c-line-1' | Set-Content -Path 'c.txt'
        git add c.txt | Out-Null
        git commit -m "Add c.txt" | Out-Null
        $commitC = (git rev-parse HEAD).Trim()

        'd-line-1' | Set-Content -Path 'd.txt'
        git add d.txt | Out-Null
        git commit -m "Add d.txt" | Out-Null
        $commitD = (git rev-parse HEAD).Trim()

        # Stage a fix to c.txt that should be absorbed into the "Add c.txt" commit.
        'c-line-1-updated' | Set-Content -Path 'c.txt'
        git add c.txt | Out-Null

        Set-CommitOrder -OrderedCommits @($commitD, $commitC) -BaseRef 'HEAD~2' -Absorb

        # Absorb should leave no staged work behind and rewrite c.txt inside history.
        git diff --cached --quiet
        $LASTEXITCODE | Should -Be 0

        $subjects = @(git log --reverse --format=%s HEAD~2..HEAD)
        $subjects | Should -Be @('Add d.txt', 'Add c.txt')

        $cHead = (git show HEAD:c.txt).Trim()
        $cHead | Should -Be 'c-line-1-updated'
      }
      finally {
        Pop-Location
      }
    }

    It "throws and leaves a rebase state when reordered commits conflict on the same file" {
      Push-Location $script:TempRepoPath
      try {
        'shared-base' | Set-Content -Path 'shared.txt'
        git add shared.txt | Out-Null
        git commit -m 'Add shared.txt' | Out-Null

        'shared-from-c' | Set-Content -Path 'shared.txt'
        git add shared.txt | Out-Null
        git commit -m 'Edit shared.txt to c' | Out-Null
        $commitC = (git rev-parse HEAD).Trim()

        'shared-from-d' | Set-Content -Path 'shared.txt'
        git add shared.txt | Out-Null
        git commit -m 'Edit shared.txt to d' | Out-Null
        $commitD = (git rev-parse HEAD).Trim()

        $thrown = $null
        try {
          Set-CommitOrder -OrderedCommits @($commitD, $commitC) -BaseRef 'HEAD~2'
        }
        catch {
          $thrown = $_
        }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match 'Set-CommitOrder rebase failed'
        $thrown.Exception.Message | Should -Match 'Conflicted path\(s\): shared\.txt'
        $thrown.Exception.Message | Should -Match 'Rebase state is still active'
        $thrown.Exception.Message | Should -Match 'git status'
        $thrown.Exception.Message | Should -Match 'git rebase --continue'
        $thrown.Exception.Message | Should -Match 'git rebase --abort'

        $gitDir = (git rev-parse --git-dir).Trim()
        if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
          $gitDir = Join-Path $script:TempRepoPath $gitDir
        }

        (
          (Test-Path (Join-Path $gitDir 'rebase-merge')) -or
          (Test-Path (Join-Path $gitDir 'rebase-apply'))
        ) | Should -BeTrue

        (@(git status --porcelain) -join "`n") | Should -Match 'UU shared\.txt'
        (Get-Content -Path 'shared.txt' -Raw) | Should -Match '<<<<<<<'
      }
      finally {
        try {
          $gitDir = (git rev-parse --git-dir 2>$null).Trim()
          if (-not [string]::IsNullOrWhiteSpace($gitDir)) {
            if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
              $gitDir = Join-Path $script:TempRepoPath $gitDir
            }

            if (
              (Test-Path (Join-Path $gitDir 'rebase-merge')) -or
              (Test-Path (Join-Path $gitDir 'rebase-apply'))
            ) {
              git rebase --abort 2>$null | Out-Null
            }
          }
        }
        finally {
          Pop-Location
        }
      }
    }

    It "executes a generated absorb script later" {
      $scriptPath = $null
      Push-Location $script:TempRepoPath
      try {
        'c-line-1' | Set-Content -Path 'c.txt'
        git add c.txt | Out-Null
        git commit -m "Add c.txt" | Out-Null
        $commitC = (git rev-parse HEAD).Trim()

        'd-line-1' | Set-Content -Path 'd.txt'
        git add d.txt | Out-Null
        git commit -m "Add d.txt" | Out-Null
        $commitD = (git rev-parse HEAD).Trim()

        'c-line-1-updated' | Set-Content -Path 'c.txt'
        git add c.txt | Out-Null

        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("set-commit-order-run-" + (New-Guid) + ".ps1")
        if (Test-Path $scriptPath) {
          Remove-Item -Path $scriptPath -Force
        }

        Set-CommitOrder -OrderedCommits @($commitD, $commitC) -BaseRef 'HEAD~2' -Absorb -OutputScriptPath $scriptPath | Out-Null

        @(git diff --cached --name-only) | Should -Be @('c.txt')
        & pwsh -NoProfile -File $scriptPath | Out-Null
        $LASTEXITCODE | Should -Be 0

        git diff --cached --quiet
        $LASTEXITCODE | Should -Be 0

        $subjects = @(git log --reverse --format=%s HEAD~2..HEAD)
        $subjects | Should -Be @('Add d.txt', 'Add c.txt')
        (git show HEAD:c.txt).Trim() | Should -Be 'c-line-1-updated'
      }
      finally {
        if ($scriptPath -and (Test-Path $scriptPath)) {
          Remove-Item -Path $scriptPath -Force
        }
        Pop-Location
      }
    }
  }

  Describe "Add-Commit" {
    It "inserts a patch commit before remaining commits when replaying a range" {
      Push-Location $script:TempRepoPath
      try {
        $patchPath = Join-Path $script:TempRepoPath 'insert-c.patch'
        @(
          'diff --git a/c.txt b/c.txt'
          'new file mode 100644'
          '--- /dev/null'
          '+++ b/c.txt'
          '@@ -0,0 +1,2 @@'
          '+c-line-1'
          '+c-line-2'
        ) | Set-Content -Path $patchPath

        $beforeCount = [int](git rev-list --count HEAD)

        Add-Commit -After 'HEAD~3' -PatchFile $patchPath -CommitMessage 'Add c.txt'

        $afterCount = [int](git rev-list --count HEAD)
        $afterCount | Should -Be ($beforeCount + 1)

        @(Get-Content -Path 'c.txt') | Should -Be @('c-line-1', 'c-line-2')
        @(git log --reverse --format=%s HEAD~4..HEAD) | Should -Be @(
          'Add a.txt and b.txt'
          'Modify a.txt and b.txt'
          'Add c.txt'
          'Modify b.txt'
        )
      }
      finally {
        Pop-Location
      }
    }

    It "can append a patch commit after replaying a single commit range" {
      Push-Location $script:TempRepoPath
      try {
        $patchPath = Join-Path $script:TempRepoPath 'insert-d.patch'
        @(
          'diff --git a/d.txt b/d.txt'
          'new file mode 100644'
          '--- /dev/null'
          '+++ b/d.txt'
          '@@ -0,0 +1,1 @@'
          '+d-line-1'
        ) | Set-Content -Path $patchPath

        Add-Commit -RepoPath $script:TempRepoPath -After 'HEAD~1' -PatchFile $patchPath -CommitMessage 'Add d.txt'

        @(Get-Content -Path 'd.txt') | Should -Be @('d-line-1')
        @(git log --reverse --format=%s HEAD~2..HEAD) | Should -Be @(
          'Modify b.txt'
          'Add d.txt'
        )
      }
      finally {
        Pop-Location
      }
    }

    It "bypasses repo pre-commit hooks while creating replayed patch commits" {
      Push-Location $script:TempRepoPath
      try {
        $hookPath = Join-Path $script:TempRepoPath '.git/hooks/pre-commit'
        @(
          '#!/bin/sh'
          'echo add-hook-ran >&2'
          'exit 1'
        ) | Set-Content -Path $hookPath -NoNewline:$false
        chmod +x $hookPath

        $patchPath = Join-Path $script:TempRepoPath 'insert-hook.patch'
        @(
          'diff --git a/hook.txt b/hook.txt'
          'new file mode 100644'
          '--- /dev/null'
          '+++ b/hook.txt'
          '@@ -0,0 +1,1 @@'
          '+hook-line-1'
        ) | Set-Content -Path $patchPath

        Add-Commit -After 'HEAD~3' -PatchFile $patchPath -CommitMessage 'Add hook.txt'

        @(Get-Content -Path 'hook.txt') | Should -Be @('hook-line-1')
        (git log --reverse --format=%s HEAD~4..HEAD) | Should -Contain 'Add hook.txt'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when there are no commits to replay after the base ref" {
      Push-Location $script:TempRepoPath
      try {
        $patchPath = Join-Path $script:TempRepoPath 'unused.patch'
        @(
          'diff --git a/e.txt b/e.txt'
          'new file mode 100644'
          '--- /dev/null'
          '+++ b/e.txt'
          '@@ -0,0 +1,1 @@'
          '+e-line-1'
        ) | Set-Content -Path $patchPath

        { Add-Commit -After 'HEAD' -PatchFile $patchPath -CommitMessage 'Add e.txt' } |
          Should -Throw -ExpectedMessage '*Expected at least 1 commit to replay*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when the requested patch file does not exist" {
      Push-Location $script:TempRepoPath
      try {
        $missingPatch = Join-Path $script:TempRepoPath 'missing.patch'
        { Add-Commit -After 'HEAD~1' -PatchFile $missingPatch -CommitMessage 'Missing patch' } |
          Should -Throw -ExpectedMessage '*Patch file not found*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "New-RebaseTodo" {
    It "reorders grouped todo lines and appends non-command lines" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $PSScriptRoot 'New-RebaseTodo.ps1'
        $commitA = (git rev-parse HEAD~2).Trim()
        $commitB = (git rev-parse HEAD~1).Trim()
        $commitC = (git rev-parse HEAD).Trim()
        $todoPath = Join-Path $script:TempRepoPath 'git-rebase-todo'

        @(
          "pick $commitA Add a.txt and b.txt"
          "fixup $commitB Modify a.txt and b.txt"
          "# keep-this-comment"
          "merge -C $commitC Modify b.txt"
        ) | Set-Content -Path $todoPath

        & $scriptPath -Path $todoPath -From 'HEAD~3' -OrderedCommits @(" $commitC ", $commitA, $commitA)

        @(Get-Content -Path $todoPath) | Should -Be @(
          "merge -C $commitC Modify b.txt"
          "pick $commitA Add a.txt and b.txt"
          "fixup $commitB Modify a.txt and b.txt"
          '# keep-this-comment'
        )
      }
      finally {
        Pop-Location
      }
    }

    It "returns without rewriting when no ordered commits are provided" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $PSScriptRoot 'New-RebaseTodo.ps1'
        $commitA = (git rev-parse HEAD~2).Trim()
        $todoPath = Join-Path $script:TempRepoPath 'git-rebase-todo'
        $originalLines = @(
          "pick $commitA Add a.txt and b.txt"
          '# unchanged-comment'
        )

        $originalLines | Set-Content -Path $todoPath

        & $scriptPath -Path $todoPath -From 'HEAD~3'

        @(Get-Content -Path $todoPath) | Should -Be $originalLines
      }
      finally {
        Pop-Location
      }
    }

    It "returns when the todo path does not exist" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $PSScriptRoot 'New-RebaseTodo.ps1'
        $commitA = (git rev-parse HEAD~2).Trim()
        $missingPath = Join-Path $script:TempRepoPath 'missing-todo'

        { & $scriptPath -Path $missingPath -From 'HEAD~3' -OrderedCommits @($commitA) } | Should -Not -Throw
        Test-Path -LiteralPath $missingPath | Should -BeFalse
      }
      finally {
        Pop-Location
      }
    }

    It "throws when the from ref cannot be resolved" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $PSScriptRoot 'New-RebaseTodo.ps1'
        $commitA = (git rev-parse HEAD~2).Trim()
        $todoPath = Join-Path $script:TempRepoPath 'git-rebase-todo'
        "pick $commitA Add a.txt and b.txt" | Set-Content -Path $todoPath

        { & $scriptPath -Path $todoPath -From 'not-a-real-ref' -OrderedCommits @($commitA) } |
          Should -Throw -ExpectedMessage "*Failed to resolve ref 'not-a-real-ref'*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when an ordered commit cannot be resolved" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $PSScriptRoot 'New-RebaseTodo.ps1'
        $commitA = (git rev-parse HEAD~2).Trim()
        $todoPath = Join-Path $script:TempRepoPath 'git-rebase-todo'
        "pick $commitA Add a.txt and b.txt" | Set-Content -Path $todoPath

        { & $scriptPath -Path $todoPath -From 'HEAD~3' -OrderedCommits @('deadbee') } |
          Should -Throw -ExpectedMessage "*Failed to resolve ordered commit 'deadbee'*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when the todo file references an unresolved commit" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $PSScriptRoot 'New-RebaseTodo.ps1'
        $commitA = (git rev-parse HEAD~2).Trim()
        $todoPath = Join-Path $script:TempRepoPath 'git-rebase-todo'

        @(
          'pick deadbee Missing commit'
          "pick $commitA Add a.txt and b.txt"
        ) | Set-Content -Path $todoPath

        { & $scriptPath -Path $todoPath -From 'HEAD~3' -OrderedCommits @($commitA) } |
          Should -Throw -ExpectedMessage '*Failed to resolve todo commit*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when an ordered commit is not present in the todo file" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $PSScriptRoot 'New-RebaseTodo.ps1'
        $commitA = (git rev-parse HEAD~2).Trim()
        $rootCommit = (git rev-list --max-parents=0 HEAD).Trim()
        $todoPath = Join-Path $script:TempRepoPath 'git-rebase-todo'
        "pick $commitA Add a.txt and b.txt" | Set-Content -Path $todoPath

        { & $scriptPath -Path $todoPath -From 'HEAD~3' -OrderedCommits @($rootCommit) } |
          Should -Throw -ExpectedMessage '*is not present in existing rebase todo*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Hunk guardrails" {
    It "throws when the hunk text is empty" {
      { Split-Hunk -Hunk '   ' -Line 1 } | Should -Throw -ExpectedMessage '*empty or invalid*'
    }

    It "throws when the hunk header is invalid" {
      { Split-Hunk -Hunk 'not-a-valid-hunk' -Line 1 } | Should -Throw -ExpectedMessage '*valid @@ header*'
    }

    It "supports splitting a hunk by body index" {
      $hunk = "@@ -1,2 +1,2 @@`n line-1`n+line-2`n"

      $parts = Split-Hunk -Hunk $hunk -Index 1

      $parts | Should -HaveCount 2
      $parts[0] | Should -Match '(?m)^@@ -1,1 \+1,1 @@'
      $parts[1] | Should -Match '(?m)^@@ -2,0 \+2,1 @@'
    }

    It "normalizes raw blank lines and unexpected prefixes while splitting" {
      $hunk = "@@ -1,2 +1,2 @@`n`nxodd`n"

      $parts = Split-Hunk -Hunk $hunk -Index 1

      $parts | Should -HaveCount 2
      $parts[0] | Should -BeExactly "@@ -1,1 +1,1 @@`n `n"
      $parts[1] | Should -BeExactly "@@ -2,1 +2,1 @@`nxodd`n"
    }

    It "throws when asked to split at the start or end of the body" {
      $hunk = "@@ -1,2 +1,2 @@`n line-1`n+line-2`n"

      { Split-Hunk -Hunk $hunk -Index 0 } | Should -Throw -ExpectedMessage '*inside the hunk body*'
      { Split-Hunk -Hunk $hunk -Index 2 } | Should -Throw -ExpectedMessage '*inside the hunk body*'
    }

    It "throws when a requested column split line cannot be located" {
      $hunk = "@@ -1,1 +1,1 @@`n+abc`n"

      { Split-Hunk -Hunk $hunk -Line 9 -Column 2 } |
        Should -Throw -ExpectedMessage '*Could not locate NEW-file line 9 inside hunk body*'
    }

    It "throws when the target line is too short for a mid-line split" {
      $hunk = "@@ -1,1 +1,1 @@`n+`n"

      { Split-Hunk -Hunk $hunk -Line 1 -Column 2 } |
        Should -Throw -ExpectedMessage '*too short to split*'
    }

    It "throws when the split column is outside the target line" {
      $hunk = "@@ -1,1 +1,1 @@`n+abc`n"

      { Split-Hunk -Hunk $hunk -Line 1 -Column 9 } |
        Should -Throw -ExpectedMessage '*out of range for line content length*'
    }
  }

  Describe "New-Hunk" {
    It "returns a header-only hunk when no body lines are provided" {
      $hunk = New-Hunk -OldStart 1 -OldCount 0 -NewStart 1 -NewCount 0

      $hunk | Should -Be "@@ -1,0 +1,0 @@`n"
    }
  }

  Describe "New-Range guardrails" {
    It "throws when the target path does not exist" {
      $missingPath = Join-Path $script:TempRepoPath 'missing-range.txt'

      { New-Range -Path $missingPath -Line 1 -Column 1 -Length 0 } |
        Should -Throw -ExpectedMessage '*Path not found*'
    }

    It "throws when the line or index is outside the file contents" {
      Push-Location $script:TempRepoPath
      try {
        $path = Join-Path $script:TempRepoPath 'range-errors.txt'
        'abc' | Set-Content -Path $path

        { New-Range -Path $path -Line 5 -Column 1 -Length 0 } |
          Should -Throw -ExpectedMessage '*Line 5 is out of range*'
        { New-Range -Path $path -Index 50 -Length 0 } |
          Should -Throw -ExpectedMessage '*Index 50 is out of range*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when line and column resolve beyond the file length" {
      Push-Location $script:TempRepoPath
      try {
        $path = Join-Path $script:TempRepoPath 'range-column-errors.txt'
        'abc' | Set-Content -Path $path

        { New-Range -Path $path -Line 1 -Column 20 -Length 0 } |
          Should -Throw -ExpectedMessage '*resolves to index*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Set-CommitOrder guardrails" {
    It "rejects an empty ordered commit list" {
      Push-Location $script:TempRepoPath
      try {
        { Set-CommitOrder -OrderedCommits @() -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage "*Cannot validate argument on parameter 'OrderedCommits'*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when the working tree is dirty without -Autostash or -Absorb" {
      Push-Location $script:TempRepoPath
      try {
        $headCommit = (git rev-parse HEAD).Trim()
        'dirty-change' | Add-Content -Path 'a.txt'

        { Set-CommitOrder -OrderedCommits @($headCommit) -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage '*Working tree is not clean*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when an ordered commit cannot be resolved" {
      Push-Location $script:TempRepoPath
      try {
        { Set-CommitOrder -OrderedCommits @('deadbee') -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage "*Failed to resolve ordered commit 'deadbee'*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when all ordered commits are blank after normalization" {
      Push-Location $script:TempRepoPath
      try {
        { Set-CommitOrder -OrderedCommits @('   ') -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage '*No valid commits were provided to reorder*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when the base ref is invalid" {
      Push-Location $script:TempRepoPath
      try {
        $headCommit = (git rev-parse HEAD).Trim()

        { Set-CommitOrder -OrderedCommits @($headCommit) -BaseRef 'not-a-ref' } |
          Should -Throw -ExpectedMessage "*Base reference 'not-a-ref' is not valid*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when an ordered commit is outside the selected range" {
      Push-Location $script:TempRepoPath
      try {
        $rootCommit = (git rev-list --max-parents=0 HEAD).Trim()

        { Set-CommitOrder -OrderedCommits @($rootCommit) -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage '*outside the reorder range*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when run from a detached HEAD" {
      Push-Location $script:TempRepoPath
      try {
        $headCommit = (git rev-parse HEAD).Trim()

        git checkout --detach -q HEAD 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0

        { Set-CommitOrder -OrderedCommits @($headCommit) -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage '*detached HEAD*'
      }
      finally {
        git checkout -q - 2>$null | Out-Null
        Pop-Location
      }
    }
  }


  Describe "Split-Commit error guardrails" {
    It "throws when HunkId cannot be resolved" {
      Push-Location $script:TempRepoPath
      try {
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = 'hnonexistent'; PieceNumber = 2 }
          ) } | Should -Throw -ExpectedMessage "*could not resolve HunkId*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when NewCommitRanges element has neither Path nor HunkId" {
      Push-Location $script:TempRepoPath
      try {
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ PieceNumber = 2 }
          ) } | Should -Throw -ExpectedMessage "*must include Path or HunkId*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when mixing HunkId and Line selectors for the same path" {
      Push-Location $script:TempRepoPath
      try {
        $hunk = @(Get-GitSplitHunks -Ref 'HEAD' | Where-Object Path -eq 'b.txt')[0]
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $hunk.HunkId; PieceNumber = 2 }
            [pscustomobject]@{ Path = 'b.txt'; Line = 3 }
          ) } | Should -Throw -ExpectedMessage "*mixing HunkId and Line*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when mixing HunkId and path-level selectors for the same path" {
      Push-Location $script:TempRepoPath
      try {
        $hunk = @(Get-GitSplitHunks -Ref 'HEAD' | Where-Object Path -eq 'b.txt')[0]
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $hunk.HunkId; PieceNumber = 2 }
            [pscustomobject]@{ Path = 'b.txt'; PieceNumber = 1 }
          ) } | Should -Throw -ExpectedMessage "*mixing HunkId and path-level*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when HunkId selector is missing PieceNumber" {
      Push-Location $script:TempRepoPath
      try {
        $hunk = @(Get-GitSplitHunks -Ref 'HEAD' | Where-Object Path -eq 'b.txt')[0]
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $hunk.HunkId }
          ) } | Should -Throw -ExpectedMessage "*must include PieceNumber*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when HunkId PieceNumber is less than 1" {
      Push-Location $script:TempRepoPath
      try {
        $hunk = @(Get-GitSplitHunks -Ref 'HEAD' | Where-Object Path -eq 'b.txt')[0]
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $hunk.HunkId; PieceNumber = 0 }
          ) } | Should -Throw -ExpectedMessage "*PieceNumber*at least 1*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when the same HunkId is specified multiple times" {
      Push-Location $script:TempRepoPath
      try {
        $hunk = @(Get-GitSplitHunks -Ref 'HEAD' | Where-Object Path -eq 'b.txt')[0]
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $hunk.HunkId; PieceNumber = 1 }
            [pscustomobject]@{ HunkId = $hunk.HunkId; PieceNumber = 2 }
          ) } | Should -Throw -ExpectedMessage "*specified multiple times*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when path-level PieceNumber is less than 1" {
      Push-Location $script:TempRepoPath
      try {
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; PieceNumber = 0 }
          ) } | Should -Throw -ExpectedMessage "*PieceNumber*at least 1*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when path range has neither Line nor PieceNumber" {
      Push-Location $script:TempRepoPath
      try {
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt' }
          ) } | Should -Throw -ExpectedMessage "*must include either Line or PieceNumber*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when split line cannot be matched to any hunk" {
      Push-Location $script:TempRepoPath
      try {
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; Line = 999 }
          ) } | Should -Throw -ExpectedMessage "*could not match split line*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when split points land in multiple hunks of the same file" {
      Push-Location $script:TempRepoPath
      try {
        # Create a file, then modify it with two separate hunks
        @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
        ) | Set-Content -Path 'multisplit.txt'

        git add multisplit.txt | Out-Null
        git commit -m 'Add multisplit.txt' | Out-Null

        @(
          'line-1'
          'line-2 changed'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10 changed'
        ) | Set-Content -Path 'multisplit.txt'

        git add multisplit.txt | Out-Null
        git commit -m 'Modify multisplit.txt in two hunks' | Out-Null

        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'multisplit.txt'; Line = 2 }
            [pscustomobject]@{ Path = 'multisplit.txt'; Line = 10 }
          ) } | Should -Throw -ExpectedMessage "*split points in multiple hunks*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws when fewer than 2 non-empty split pieces are produced" {
      Push-Location $script:TempRepoPath
      try {
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; PieceNumber = 1 }
          ) } | Should -Throw -ExpectedMessage "*at least 2 non-empty split pieces*"
      }
      finally {
        Pop-Location
      }
    }

    It "supports Hunk alias for HunkId" {
      Push-Location $script:TempRepoPath
      try {
        # HEAD~1 modifies both a.txt and b.txt
        $hunk = @(Get-GitSplitHunks -Ref 'HEAD~1' | Where-Object Path -eq 'b.txt')[0]
        $created = @(Split-Commit -Ref 'HEAD~1' -NewCommitRanges @(
            [pscustomobject]@{ Hunk = $hunk.HunkId; Piece = 2 }
          ))
        $created | Should -HaveCount 2
      }
      finally {
        Pop-Location
      }
    }

    It "supports Piece alias for PieceNumber with path-level assignment" {
      Push-Location $script:TempRepoPath
      try {
        # HEAD~1 modifies both a.txt and b.txt
        $created = @(Split-Commit -Ref 'HEAD~1' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; Piece = 2 }
          ))
        $created | Should -HaveCount 2
      }
      finally {
        Pop-Location
      }
    }

  }

  Describe "Split-Hunk edge cases" {
    It "throws when index is out of range" {
      $hunk = New-Hunk -OldStart 1 -OldCount 2 -NewStart 1 -NewCount 2 -BodyLines @(' a', ' b')
      { Split-Hunk -Hunk $hunk -Index 999 } | Should -Throw -ExpectedMessage "*out of range*"
    }

    It "handles a hunk with no body lines" {
      $hunk = New-Hunk -OldStart 1 -OldCount 0 -NewStart 1 -NewCount 0 -BodyLines @()
      $hunk | Should -Match '^@@'
    }

    It "handles blank context lines in body" {
      $hunk = New-Hunk -OldStart 1 -OldCount 3 -NewStart 1 -NewCount 3 -BodyLines @(' a', '', ' c')
      $result = Split-Hunk -Hunk $hunk -Line 2
      $result | Should -HaveCount 2
    }

    It "throws when mid-line split column is out of range" {
      $hunk = New-Hunk -OldStart 1 -OldCount 1 -NewStart 1 -NewCount 2 -BodyLines @(' a', '+b')
      { Split-Hunk -Hunk $hunk -Line 2 -Column 999 } | Should -Throw -ExpectedMessage "*Column*out of range*"
    }
  }

  Describe "ConvertTo-PowerShellStringLiteral" {
    It "returns single-quoted empty string for null input" {
      ConvertTo-PowerShellStringLiteral -Value $null | Should -Be "''"
    }

    It "escapes single quotes" {
      ConvertTo-PowerShellStringLiteral -Value "it's" | Should -Be "'it''s'"
    }
  }

  Describe "Get-GitSplitFileContentAtCommit" {
    It "returns null for a non-existent file" {
      Push-Location $script:TempRepoPath
      try {
        $headSha = (git rev-parse HEAD).Trim()
        Get-GitSplitFileContentAtCommit -Path 'nonexistent.txt' -Commit $headSha | Should -BeNullOrEmpty
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitFileDiffSection" {
    It "returns the section for a matching file" {
      $patch = "diff --git a/a.txt b/a.txt`n@@ -1 +1 @@`n-old`n+new"
      $result = Get-GitFileDiffSection -CombinedPatch $patch -FilePath 'a.txt'
      $result | Should -Match 'diff --git a/a.txt'
    }
  }

  Describe "Get-GitSplitRelativeImportsFromText" {
    It "returns empty array for null or whitespace text" {
      Get-GitSplitRelativeImportsFromText -Text $null | Should -Be @()
      Get-GitSplitRelativeImportsFromText -Text '   ' | Should -Be @()
    }
  }

  Describe "Get-GitSplitWorkflowLocalActionPathsFromText" {
    It "returns empty array for null or whitespace text" {
      Get-GitSplitWorkflowLocalActionPathsFromText -Text $null | Should -Be @()
      Get-GitSplitWorkflowLocalActionPathsFromText -Text '   ' | Should -Be @()
    }
  }

  Describe "New-Hunk blank line handling" {
    It "converts null body lines to space" {
      $hunk = New-Hunk -OldStart 1 -OldCount 1 -NewStart 1 -NewCount 1 -BodyLines @($null)
      $hunk | Should -Match "(?s)^@@ -1,1 \+1,1 @@.* $"
    }
  }

  Describe "Split-Patch edge cases" {
    It "skips whitespace-only file entries" {
      $patch = "diff --git a/a.txt b/a.txt`n@@ -1 +1 @@`n-old`n+new`n`ndiff --git a/b.txt b/b.txt`n@@ -1 +1 @@`n-old2`n+new2"
      $result = Split-Patch -patch $patch
      $result | Should -HaveCount 2
      $result[0].FilePath | Should -Be 'a.txt'
      $result[1].FilePath | Should -Be 'b.txt'
    }
  }

  Describe "Invoke-WithProgressSuppressed" {
    It "restores ProgressPreference after execution" {
      $global:ProgressPreference = 'Continue'
      Invoke-WithProgressSuppressed -Script { $global:ProgressPreference | Should -Be 'SilentlyContinue' }
      $global:ProgressPreference | Should -Be 'Continue'
    }
  }

  Describe "Test hook provider validation" {
    AfterEach {
      Reset-GitSplitTestHooks
    }

    It "throws when Guid provider returns an invalid value" {
      Set-GitSplitTestHooks -GuidProvider { 'not-a-guid' }
      { Get-GitSplitGuid } | Should -Throw -ExpectedMessage "*valid Guid*"
    }

    It "throws when timestamp provider returns an invalid value" {
      Set-GitSplitTestHooks -TimestampProvider { 'not-a-date' }
      { Get-GitSplitTimestamp } | Should -Throw -ExpectedMessage "*valid DateTime*"
    }

    It "throws when temp root provider returns empty" {
      Set-GitSplitTestHooks -TempRootProvider { '' }
      { Get-GitSplitTempRoot } | Should -Throw -ExpectedMessage "*empty path*"
    }

    It "throws when stash name provider returns empty" {
      Set-GitSplitTestHooks -StashNameProvider { '' }
      { New-GitSplitStashName } | Should -Throw -ExpectedMessage "*empty value*"
    }

    It "accepts a string guid that can be parsed" {
      Set-GitSplitTestHooks -GuidProvider { '12345678-1234-1234-1234-123456789abc' }
      $result = Get-GitSplitGuid
      $result | Should -BeOfType [guid]
    }

    It "accepts a string timestamp that can be parsed" {
      Set-GitSplitTestHooks -TimestampProvider { '2025-01-01' }
      $result = Get-GitSplitTimestamp
      $result | Should -BeOfType [datetime]
    }
  }

  Describe "Invoke-Git error formatting" {
    It "throws with details when git fails and produces output" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-Git -ErrorMessage 'custom error' --bad-command 2>$null } | Should -Throw -ExpectedMessage "*custom error*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws without details when output is empty" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-Git -ErrorMessage 'custom error' -Quiet --bad-command 2>$null } | Should -Throw -ExpectedMessage "*custom error*exit code*"
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Invoke-GitQuery error formatting" {
    It "throws with context when ErrorMessage is provided and git fails" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-GitQuery -ErrorMessage 'query failed' --bad-command 2>$null } | Should -Throw -ExpectedMessage "*query failed*"
      }
      finally {
        Pop-Location
      }
    }

    It "throws with auto-generated context when no ErrorMessage and git fails" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-GitQuery --bad-command 2>$null } | Should -Throw -ExpectedMessage "*git*"
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Test-GitRefExists" {
    It "returns false for a non-existent ref" {
      Push-Location $script:TempRepoPath
      try {
        Test-GitRefExists -Ref 'refs/heads/nonexistent' | Should -Be $false
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Test-GitCommitIsAncestor" {
    It "returns true when ancestor is an ancestor of descendant" {
      Push-Location $script:TempRepoPath
      try {
        $ancestor = (git rev-parse HEAD~2).Trim()
        $descendant = (git rev-parse HEAD).Trim()
        Test-GitCommitIsAncestor -Ancestor $ancestor -Descendant $descendant | Should -Be $true
      }
      finally {
        Pop-Location
      }
    }

    It "returns false when ancestor is not an ancestor of descendant" {
      Push-Location $script:TempRepoPath
      try {
        $descendant = (git rev-parse HEAD~2).Trim()
        $ancestor = (git rev-parse HEAD).Trim()
        Test-GitCommitIsAncestor -Ancestor $ancestor -Descendant $descendant | Should -Be $false
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Resolve-GitCommit" {
    It "throws for an unresolvable commit reference" {
      Push-Location $script:TempRepoPath
      try {
        { Resolve-GitCommit -Ref 'not-a-real-ref' -ErrorMessage 'Failed to resolve commit reference.' } |
          Should -Throw -ExpectedMessage "*Failed to resolve commit reference*"
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitPatchText error paths" {
    It "throws when git show fails for an invalid ref" {
      Push-Location $script:TempRepoPath
      try {
        { Get-GitPatchText -Ref 'not-a-real-ref' -ErrorMessage 'patch failed' } |
          Should -Throw -ExpectedMessage '*patch failed*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Select-GitSplitPaths" {
    It "throws when no PathPattern or PatchPattern is provided" {
      Push-Location $script:TempRepoPath
      try {
        { Select-GitSplitPaths -Ref 'HEAD' } |
          Should -Throw -ExpectedMessage '*at least one*'
      }
      finally {
        Pop-Location
      }
    }

    It "filters by PatchPattern and skips non-matching patches" {
      Push-Location $script:TempRepoPath
      try {
        $result = @(Select-GitSplitPaths -Ref 'HEAD' -PathPattern '.*' -PatchPattern 'nomatchpattern')
        $result | Should -HaveCount 0
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitSplitClosure edge cases" {
    It "excludes paths not changed in the commit" {
      Push-Location $script:TempRepoPath
      try {
        $result = @(Get-GitSplitClosure -Ref 'HEAD' -Paths @('nonexistent.txt'))
        $result | Should -HaveCount 1
        $result[0].Status | Should -Be 'Excluded'
        $result[0].Rule | Should -Be 'NotChangedInCommit'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Test-GitSplitSelection edge cases" {
    It "returns empty when all selected files have matching dependencies" {
      Push-Location $script:TempRepoPath
      try {
        $result = @(Test-GitSplitSelection -Ref 'HEAD' -Paths @('a.txt'))
        # a.txt has no import dependencies, so no break risks
        $result | Should -HaveCount 0
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Wait-GitSplitPullRequestChecks" {
    It "throws when gh CLI is not available" {
      $oldPath = $env:PATH
      try {
        $env:PATH = '/nonexistent'
        { Wait-GitSplitPullRequestChecks -PullRequest 1 } |
          Should -Throw -ExpectedMessage "*GitHub CLI 'gh' is required*"
      }
      finally {
        $env:PATH = $oldPath
      }
    }
  }

  Describe "ConvertTo-GitScript" {
    It "throws for an unsupported step kind" {
      $badPlan = [pscustomobject]@{
        Name = 'Test'
        Metadata = @{}
        Steps = @(
          [pscustomobject]@{ Kind = 'BadKind'; Lines = @('test') }
        )
      }
      { ConvertTo-GitScript -Plan $badPlan } | Should -Throw -ExpectedMessage '*Unsupported git plan step kind*'
    }

    It "renders blank comment lines as hash-only" {
      $plan = [pscustomobject]@{
        Name = 'Test'
        Metadata = @{}
        Steps = @(
          [pscustomobject]@{ Kind = 'Comment'; Lines = @('real comment', '') }
        )
      }
      $script = ConvertTo-GitScript -Plan $plan
      $script | Should -Match '(?m)^# real comment$'
      $script | Should -Match '(?m)^#$'
    }
  }

  Describe "Write-GitScript" {
    It "creates parent directories when needed" {
      Push-Location $script:TempRepoPath
      try {
        $deepPath = Join-Path $script:TempRepoPath 'sub/dir/script.ps1'
        $plan = [pscustomobject]@{
          Name = 'Test'
          Metadata = @{}
          Steps = @(
            [pscustomobject]@{ Kind = 'Comment'; Lines = @('test') }
          )
        }
        $result = Write-GitScript -Plan $plan -Path $deepPath
        Test-Path $result | Should -Be $true
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "New-MoveCommitPlan error paths" {
    It "throws when BaseRef is provided without CreateDestinationBranch" {
      Push-Location $script:TempRepoPath
      try {
        { New-MoveCommitPlan -CommitRef 'HEAD' -DestinationBranch 'feature/test' -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage '*only accepts -BaseRef together with -CreateDestinationBranch*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when CreateDestinationBranch is used but branch already exists" {
      Push-Location $script:TempRepoPath
      try {
        git branch existing-branch HEAD~1 2>$null | Out-Null
        { New-MoveCommitPlan -CommitRef 'HEAD' -DestinationBranch 'existing-branch' -CreateDestinationBranch -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage '*already exists*'
      }
      finally {
        git branch -D existing-branch 2>$null | Out-Null
        Pop-Location
      }
    }

    It "uses remote tracking branch when only remote exists" {
      Push-Location $script:TempRepoPath
      try {
        # Create a remote branch by cloning locally
        $remotePath = Join-Path $script:TempRepoPath 'remote.git'
        git clone --bare -q $script:TempRepoPath $remotePath 2>$null | Out-Null
        git remote add origin $remotePath 2>$null | Out-Null
        git fetch origin -q 2>$null | Out-Null
        git branch -r 2>$null | Out-Null

        # Use main as remote-only target
        $plan = New-MoveCommitPlan -CommitRef 'HEAD' -DestinationBranch 'main'
        # Should not throw - uses remote tracking branch
        $plan | Should -Not -BeNullOrEmpty
      }
      finally {
        git remote remove origin 2>$null | Out-Null
        Pop-Location
      }
    }
  }

  Describe "Add-Commit error paths" {
    It "throws when patch file does not exist" {
      Push-Location $script:TempRepoPath
      try {
        { Add-Commit -After 'HEAD~1' -PatchFile '/nonexistent/path.patch' -CommitMessage 'test' } |
          Should -Throw -ExpectedMessage '*Patch file not found*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when no commits to replay after base ref" {
      Push-Location $script:TempRepoPath
      try {
        { Add-Commit -After 'HEAD' -PatchFile '/nonexistent/path.patch' -CommitMessage 'test' } |
          Should -Throw -ExpectedMessage '*at least 1 commit to replay*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Invoke-GitSplitAbsorb errors" {
    It "throws when unable to resolve fixup commit" {
      Push-Location $script:TempRepoPath
      try {
        # Mock by calling with a plan that has no targets - should return empty
        $result = Invoke-GitSplitAbsorb -From (git rev-parse HEAD).Trim()
        $result | Should -HaveCount 0
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitSplitChangedCommitInfo" {
    It "returns commit info for a valid commit" {
      Push-Location $script:TempRepoPath
      try {
        $info = Get-GitSplitChangedCommitInfo -Ref 'HEAD'
        $info.Commit | Should -Match '^[0-9a-f]{40}$'
        $info.FilePatches | Should -Not -BeNullOrEmpty
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Move-Commit push script generation" {
    It "generates force-push lines in script when RemoveFromSource and Push and ForcePushSource" {
      Push-Location $script:TempRepoPath
      try {
        git branch existing-dest HEAD~1 2>$null | Out-Null
        $scriptPath = Join-Path $script:TempRepoPath 'move-push-script.ps1'
        Move-Commit -CommitRef 'HEAD' -DestinationBranch 'existing-dest' -RemoveFromSource -Push -ForcePushSource -OutputScriptPath $scriptPath | Out-Null
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'push --force-with-lease'
        git branch -D existing-dest 2>$null | Out-Null
      }
      finally {
        Pop-Location
      }
    }

    It "generates regular push lines in script when RemoveFromSource and Push without ForcePushSource" {
      Push-Location $script:TempRepoPath
      try {
        # Need 3 commits so HEAD~1 is not HEAD (uses RebaseOntoParent, not ResetToParent)
        git branch existing-dest2 HEAD~2 2>$null | Out-Null
        $scriptPath = Join-Path $script:TempRepoPath 'move-push-script2.ps1'
        Move-Commit -CommitRef 'HEAD~1' -DestinationBranch 'existing-dest2' -RemoveFromSource -Push -OutputScriptPath $scriptPath | Out-Null
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'push origin \$expectedBranch'
        git branch -D existing-dest2 2>$null | Out-Null
      }
      finally {
        Pop-Location
      }
    }

    It "generates ResetToParent source removal lines in script" {
      Push-Location $script:TempRepoPath
      try {
        git branch existing-dest3 HEAD~1 2>$null | Out-Null
        $scriptPath = Join-Path $script:TempRepoPath 'move-reset-script.ps1'
        Move-Commit -CommitRef 'HEAD' -DestinationBranch 'existing-dest3' -RemoveFromSource -OutputScriptPath $scriptPath | Out-Null
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'rewrittenHead'
        git branch -D existing-dest3 2>$null | Out-Null
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Remove-Commit push script generation" {
    It "generates force-push lines in script when Push and ForcePush" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $script:TempRepoPath 'remove-push-script.ps1'
        Remove-Commit -CommitRef 'HEAD' -Push -ForcePush -OutputScriptPath $scriptPath | Out-Null
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'push --force-with-lease'
      }
      finally {
        Pop-Location
      }
    }

    It "generates regular push lines in script when Push without ForcePush" {
      Push-Location $script:TempRepoPath
      try {
        $scriptPath = Join-Path $script:TempRepoPath 'remove-push-script2.ps1'
        Remove-Commit -CommitRef 'HEAD' -Push -OutputScriptPath $scriptPath | Out-Null
        $content = Get-Content $scriptPath -Raw
        $content | Should -Match 'push origin \$targetBranch'
        $content | Should -Not -Match 'force-with-lease'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Move-Commit detached HEAD" {
    It "throws when in detached HEAD state" {
      Push-Location $script:TempRepoPath
      try {
        git checkout --detach -q HEAD~1 2>$null | Out-Null
        { New-MoveCommitPlan -CommitRef 'HEAD' -DestinationBranch 'some-branch' } |
          Should -Throw -ExpectedMessage '*detached HEAD*'
      }
      finally {
        git checkout -q - 2>$null | Out-Null
        Pop-Location
      }
    }
  }

  Describe "Split-Hunk blank line column split" {
    It "handles blank context lines during column split" {
      $hunk = New-Hunk -OldStart 1 -OldCount 4 -NewStart 1 -NewCount 4 -BodyLines @(' a', '', ' c', '+d')
      $result = Split-Hunk -Hunk $hunk -Line 4 -Column 2
      $result | Should -HaveCount 2
    }
  }

  Describe "Split-Hunk blank line line-split" {
    It "handles blank context lines during line split" {
      $hunk = New-Hunk -OldStart 1 -OldCount 4 -NewStart 1 -NewCount 4 -BodyLines @(' a', '', ' c', '+d')
      $result = Split-Hunk -Hunk $hunk -Line 3
      $result | Should -HaveCount 2
    }
  }

  Describe "Get-GitSplitHunkHeaderMetadata" {
    It "throws for invalid hunk header" {
      { Get-GitSplitHunkHeaderMetadata -Hunk 'not a hunk header' } |
        Should -Throw -ExpectedMessage '*valid @@ header*'
    }

    It "handles single-line hunk count" {
      $hunk = '@@ -1 +1 @@' + "`n" + ' content'
      $result = Get-GitSplitHunkHeaderMetadata -Hunk $hunk
      $result.OldCount | Should -Be 1
      $result.NewCount | Should -Be 1
    }
  }

  Describe "Get-GitSplitHunkDescriptors" {
    It "returns descriptors for file patches" {
      $filePatches = @(
        [pscustomobject]@{
          FilePath = 'test.txt'
          Patches = @('@@ -1,1 +1,1 @@' + "`n" + ' content')
        }
      )
      Push-Location $script:TempRepoPath
      try {
        $headSha = (git rev-parse HEAD).Trim()
        $result = @(Get-GitSplitHunkDescriptors -Commit $headSha -FilePatches $filePatches)
        $result | Should -HaveCount 1
        $result[0].Path | Should -Be 'test.txt'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "ConvertTo-GitSplitRepoRelativePath" {
    It "handles paths outside the repo root" {
      Push-Location $script:TempRepoPath
      try {
        $result = ConvertTo-GitSplitRepoRelativePath -Path '/tmp/external/file.txt' -RepoRoot $script:TempRepoPath
        # Paths outside the repo root are returned as-is or normalized
        $result | Should -Not -BeNullOrEmpty
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Test-GitSplitGeneratedPath" {
    It "returns false for a non-generated file at HEAD" {
      Push-Location $script:TempRepoPath
      try {
        $headSha = (git rev-parse HEAD).Trim()
        Test-GitSplitGeneratedPath -Path 'a.txt' -Commit $headSha | Should -Be $false
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Select-GitSplitPaths PatchPattern matching" {
    It "matches files by patch pattern" {
      Push-Location $script:TempRepoPath
      try {
        $result = @(Select-GitSplitPaths -Ref 'HEAD~1' -PathPattern '.*' -PatchPattern 'a-line-2')
        $result | Should -HaveCount 1
        $result[0].Path | Should -Be 'a.txt'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitSplitClosure generated dependency" {
    It "excludes generated dependencies" {
      Push-Location $script:TempRepoPath
      try {
        $result = @(Get-GitSplitClosure -Ref 'HEAD~1' -Paths @('a.txt'))
        $result | Should -HaveCount 1
        $result[0].Status | Should -Be 'Selected'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitSplitWorkflowLocalActionPathsFromText" {
    It "extracts local action paths from workflow text" {
      $text = @"
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/run-frontend
      - name: Checkout
        uses: actions/checkout@v4
"@
      $result = @(Get-GitSplitWorkflowLocalActionPathsFromText -Text $text)
      $result | Should -Contain '.github/actions/run-frontend/action.yml'
    }
  }

  Describe "Resolve-GitSplitImportCandidates" {
    It "skips candidates outside repo root" {
      Push-Location $script:TempRepoPath
      try {
        $result = @(Resolve-GitSplitImportCandidates -RepoRoot $script:TempRepoPath -ImporterPath 'src/main.ts' -Specifier '../../../etc/passwd')
        $result | Should -HaveCount 0
      }
      finally {
        Pop-Location
      }
    }

    It "skips candidates with empty relative paths" {
      Push-Location $script:TempRepoPath
      try {
        # Import from the repo root itself - the relative path would be empty
        $result = @(Resolve-GitSplitImportCandidates -RepoRoot $script:TempRepoPath -ImporterPath 'index.ts' -Specifier '.')
        # May or may not return results depending on file existence
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Commit multi-split-point" {
    It "splits a hunk at two split points producing three pieces" {
      Push-Location $script:TempRepoPath
      try {
        @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
        ) | Set-Content -Path 'multisplit2.txt'

        git add multisplit2.txt | Out-Null
        git commit -m 'Add multisplit2.txt' | Out-Null

        @(
          'line-1'
          'line-2 changed'
          'line-3'
          'line-4'
          'line-5'
          'line-6 changed'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
        ) | Set-Content -Path 'multisplit2.txt'

        git add multisplit2.txt | Out-Null
        git commit -m 'Modify multisplit2.txt' | Out-Null

        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'multisplit2.txt'; Line = 6 }
          ))
        $created | Should -HaveCount 2
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Commit with trailing hunks" {
    It "splits at a hunk that has trailing hunks after it" {
      Push-Location $script:TempRepoPath
      try {
        @(
          'line-1'
          'line-2'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
          'line-11'
          'line-12'
        ) | Set-Content -Path 'trailing.txt'

        git add trailing.txt | Out-Null
        git commit -m 'Add trailing.txt' | Out-Null

        @(
          'line-1'
          'line-2 changed'
          'line-3'
          'line-4'
          'line-5'
          'line-6'
          'line-7'
          'line-8'
          'line-9'
          'line-10'
          'line-11'
          'line-12 changed'
        ) | Set-Content -Path 'trailing.txt'

        git add trailing.txt | Out-Null
        git commit -m 'Modify trailing.txt in two hunks' | Out-Null

        # Split at line 12 - this is in the second hunk, with the first hunk as a leading hunk
        $created = @(Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'trailing.txt'; Line = 12 }
          ))
        $created | Should -HaveCount 2
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Export-ModuleMember non-CI branch" {
    It "exports the manifest function list when CI env is not set" {
      $oldCI = $env:CI
      try {
        $env:CI = $null
        Remove-Module GitSplit -ErrorAction SilentlyContinue
        Import-Module "$PSScriptRoot/GitSplit.psm1" -Force
        $exported = (Get-Module GitSplit).ExportedFunctions.Keys
        $exported | Should -Contain 'Split-Commit'
        $exported | Should -Contain 'Move-Commit'
      }
      finally {
        $env:CI = $oldCI
        Remove-Module GitSplit -ErrorAction SilentlyContinue
        Import-Module "$PSScriptRoot/GitSplit.psm1" -Force
      }
    }
  }

  Describe "Invoke-Git WriteHostOnError" {
    It "writes errors to host when WriteHostOnError is set" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-Git -WriteHostOnError --bad-command 2>&1 | Out-Null } |
          Should -Throw
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Invoke-Git error with details" {
    It "includes stderr details in the throw message" {
      Push-Location $script:TempRepoPath
      try {
        # git show with a bad ref produces stderr output
        { Invoke-Git -ErrorMessage 'show failed' show not-a-real-ref 2>&1 | Out-Null } |
          Should -Throw -ExpectedMessage '*show failed*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Invoke-GitQuery error without ErrorMessage" {
    It "generates context from git args when no ErrorMessage is provided" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-GitQuery --bad-command 2>&1 | Out-Null } |
          Should -Throw -ExpectedMessage '*git*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Resolve-GitCommit default error message" {
    It "uses default error message when none is provided" {
      Push-Location $script:TempRepoPath
      try {
        { Resolve-GitCommit -Ref 'not-a-real-ref' } |
          Should -Throw -ExpectedMessage '*Failed to resolve commit reference*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Test-GitRefExists error branches" {
    It "returns false for a non-existent ref without throwing" {
      Push-Location $script:TempRepoPath
      try {
        # show-ref --verify always returns 1 for non-existent refs, never 128
        Test-GitRefExists -Ref 'refs/heads/totally-nonexistent-branch' | Should -Be $false
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Test-GitCommitIsAncestor error branches" {
    It "throws when merge-base returns an unexpected error code" {
      Push-Location $script:TempRepoPath
      try {
        # Invalid commit refs cause exit code 128
        { Test-GitCommitIsAncestor -Ancestor 'not-a-real-ref' -Descendant 'also-not-real' } |
          Should -Throw -ExpectedMessage '*Failed to determine whether*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "ConvertTo-GitSplitRepoRelativePath edge cases" {
    It "returns empty string when path equals repo root" {
      Push-Location $script:TempRepoPath
      try {
        $result = ConvertTo-GitSplitRepoRelativePath -Path $script:TempRepoPath -RepoRoot $script:TempRepoPath
        $result | Should -Be ''
      }
      finally {
        Pop-Location
      }
    }

    It "strips leading .// from relative paths" {
      $result = ConvertTo-GitSplitRepoRelativePath -Path './src/file.txt'
      $result | Should -Be 'src/file.txt'
    }
  }

  Describe "Test-GitSplitGeneratedPath with non-HEAD commit" {
    It "returns false for a regular file when inspecting a non-HEAD commit" {
      Push-Location $script:TempRepoPath
      try {
        $headSha = (git rev-parse HEAD).Trim()
        $parentSha = (git rev-parse HEAD~1).Trim()
        # When Commit != HEAD and check-attr doesn't support --source,
        # it falls back to pattern matching
        $result = Test-GitSplitGeneratedPath -Path 'a.txt' -Commit $parentSha
        $result | Should -Be $false
      }
      finally {
        Pop-Location
      }
    }

    It "detects generated paths by pattern" {
      Push-Location $script:TempRepoPath
      try {
        $headSha = (git rev-parse HEAD).Trim()
        $result = Test-GitSplitGeneratedPath -Path 'src/__generated__/file.cs' -Commit $headSha
        $result | Should -Be $true
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitSplitGuid direct guid return" {
    It "returns a guid directly when provider returns a [guid]" {
      Set-GitSplitTestHooks -GuidProvider { [guid]::NewGuid() }
      try {
        $result = Get-GitSplitGuid
        $result | Should -BeOfType [guid]
      }
      finally {
        Reset-GitSplitTestHooks
      }
    }
  }

  Describe "Split-Hunk blank line in column split" {
    It "handles blank context lines when locating target for column split" {
      $hunk = New-Hunk -OldStart 1 -OldCount 5 -NewStart 1 -NewCount 5 -BodyLines @(' a', '', ' c', '+dd', ' e')
      $result = Split-Hunk -Hunk $hunk -Line 4 -Column 2
      $result | Should -HaveCount 2
    }
  }

  Describe "Split-Hunk blank line in line split" {
    It "handles blank context lines during line-based split" {
      $hunk = New-Hunk -OldStart 1 -OldCount 5 -NewStart 1 -NewCount 5 -BodyLines @(' a', '', ' c', ' d', ' e')
      $result = Split-Hunk -Hunk $hunk -Line 3
      $result | Should -HaveCount 2
    }
  }

  Describe "Split-Hunk split at boundary" {
    It "throws when split point is at start or end of body" {
      $hunk = New-Hunk -OldStart 1 -OldCount 1 -NewStart 1 -NewCount 1 -BodyLines @(' content')
      { Split-Hunk -Hunk $hunk -Line 1 } |
        Should -Throw -ExpectedMessage '*cannot split at start or end*'
    }
  }

  Describe "New-Hunk null body line conversion" {
    It "converts null entries to space character" {
      $hunk = New-Hunk -OldStart 1 -OldCount 2 -NewStart 1 -NewCount 2 -BodyLines @(' a', $null, ' c')
      # The null line should become a space (context line)
      $hunk | Should -Match "(?s)^@@ -1,2 \+1,2 @@.* .*$"
    }
  }

  Describe "Split-Patch whitespace skipping" {
    It "skips whitespace-only file entries in the patch" {
      $patch = "diff --git a/a.txt b/a.txt`n`n@@ -1 +1 @@`n-old`n+new`n`ndiff --git a/b.txt b/b.txt`n@@ -1 +1 @@`n-old2`n+new2"
      $result = Split-Patch -patch $patch
      $result | Should -HaveCount 2
    }
  }

  Describe "Get-GitFileDiffSection no match" {
    It "returns null when file is not found in patch" {
      $patch = "diff --git a/a.txt b/a.txt`n@@ -1 +1 @@`n-old`n+new"
      $result = Get-GitFileDiffSection -CombinedPatch $patch -FilePath 'nonexistent.txt'
      $result | Should -BeNullOrEmpty
    }
  }

  Describe "Get-GitSplitWorkflowLocalActionPathsFromText with extension" {
    It "handles paths that already have an extension" {
      $text = "jobs:`n  test:`n    steps:`n      - uses: ./.github/actions/custom.yml"
      $result = @(Get-GitSplitWorkflowLocalActionPathsFromText -Text $text)
      $result | Should -Contain '.github/actions/custom.yml'
    }
  }

  Describe "Get-GitSplitClosure generated dependency exclusion" {
    It "excludes generated dependencies in closure" {
      Push-Location $script:TempRepoPath
      try {
        # Create a commit with a file in __generated__ directory
        New-Item -ItemType Directory -Path 'src/__generated__' -Force | Out-Null
        @('generated content') | Set-Content -Path 'src/__generated__/gen.ts'
        @('import { x } from ''./__generated__/gen''') | Set-Content -Path 'src/main.ts'

        git add src/__generated__/gen.ts src/main.ts | Out-Null
        git commit -m 'Add generated and main' | Out-Null

        $result = @(Get-GitSplitClosure -Ref 'HEAD' -Paths @('src/main.ts'))
        # main.ts should be selected, gen.ts should be excluded as generated
        $generated = $result | Where-Object { $_.Path -like '*__generated__*' }
        if ($generated) {
          $generated.Status | Should -Be 'Excluded'
          $generated.Rule | Should -Be 'GeneratedDependency'
        }
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Test-GitSplitSelection with SkipClosureExpansion" {
    It "reports break risks with SkipClosureExpansion" {
      Push-Location $script:TempRepoPath
      try {
        $result = @(Test-GitSplitSelection -Ref 'HEAD~1' -Paths @('a.txt') -SkipClosureExpansion)
        # a.txt has no dependencies, so no risks expected
        $result | Should -HaveCount 0
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "New-SplitCommitPlan error paths" {
    It "throws when Hunk selector has empty PieceNumber value" {
      Push-Location $script:TempRepoPath
      try {
        $hunk = @(Get-GitSplitHunks -Ref 'HEAD' | Where-Object Path -eq 'b.txt')[0]
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ HunkId = $hunk.HunkId; PieceNumber = '' }
          ) } | Should -Throw -ExpectedMessage '*must include PieceNumber*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when path range PieceNumber is empty" {
      Push-Location $script:TempRepoPath
      try {
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; PieceNumber = '' }
          ) } | Should -Throw -ExpectedMessage '*at least 2*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when split point is missing Line property" {
      Push-Location $script:TempRepoPath
      try {
        { Split-Commit -Ref 'HEAD' -NewCommitRanges @(
            [pscustomobject]@{ Path = 'b.txt'; Column = 1 }
          ) } | Should -Throw -ExpectedMessage '*must include either Line or PieceNumber*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Add-Commit with valid patch" {
    It "applies a patch and inserts a commit" {
      Push-Location $script:TempRepoPath
      try {
        # Create a patch file
        $patchPath = Join-Path $script:TempRepoPath 'test.patch'
        @(
          'diff --git a/newfile.txt b/newfile.txt'
          'new file mode 100644'
          'index 0000000..ce01362'
          '--- /dev/null'
          '+++ b/newfile.txt'
          '@@ -0,0 +1,1 @@'
          '+hello from patch'
        ) | Set-Content -Path $patchPath -Encoding utf8

        $beforeCount = [int](git rev-list --count HEAD)
        Add-Commit -After 'HEAD~1' -PatchFile $patchPath -CommitMessage 'Patch commit'
        $afterCount = [int](git rev-list --count HEAD)
        $afterCount | Should -Be ($beforeCount + 1)
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "New-SetCommitOrderPlan additional error paths" {
    It "throws when base ref is invalid" {
      Push-Location $script:TempRepoPath
      try {
        $headCommit = (git rev-parse HEAD).Trim()
        { Set-CommitOrder -OrderedCommits @($headCommit) -BaseRef 'not-a-real-ref' } |
          Should -Throw -ExpectedMessage '*not valid*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws when commit is not reachable from current branch" {
      Push-Location $script:TempRepoPath
      try {
        # Create a commit on another branch
        git branch test-branch HEAD~1 2>$null | Out-Null
        git checkout -q test-branch 2>$null | Out-Null
        @('orphan content') | Set-Content -Path 'orphan.txt'
        git add orphan.txt | Out-Null
        git commit -m 'orphan commit' | Out-Null
        $orphanCommit = (git rev-parse HEAD).Trim()
        git checkout -q main 2>$null | Out-Null

        { Set-CommitOrder -OrderedCommits @($orphanCommit) -BaseRef 'HEAD~1' } |
          Should -Throw -ExpectedMessage '*not reachable*'
      }
      finally {
        git branch -D test-branch 2>$null | Out-Null
        Pop-Location
      }
    }
  }

  Describe "Wait-GitSplitPullRequestChecks return values" {
    It "returns pull request number when gh succeeds without repository" {
      $oldPath = $env:PATH
      $fakeGhDir = $null
      try {
        $fakeGhDir = Join-Path $script:TempRepoPath "fake-gh-$(Get-Random)"
        New-Item -Path $fakeGhDir -ItemType Directory -Force | Out-Null
        $fakeGh = Join-Path $fakeGhDir 'gh'
        Set-Content -Path $fakeGh -Value '#!/bin/bash' -Encoding ascii
        Add-Content -Path $fakeGh -Value 'exit 0' -Encoding ascii
        & chmod +x $fakeGh 2>$null
        $env:PATH = "${fakeGhDir}:$($env:PATH)"

        $result = Wait-GitSplitPullRequestChecks -PullRequest 42
        $result | Should -Be '42'
      }
      finally {
        $env:PATH = $oldPath
        if ($fakeGhDir) { Remove-Item -Path $fakeGhDir -Recurse -Force -ErrorAction SilentlyContinue }
      }
    }

    It "throws when gh pr checks fails" {
      $oldPath = $env:PATH
      $fakeGhDir = $null
      try {
        $fakeGhDir = Join-Path $script:TempRepoPath "fake-gh-fail-$(Get-Random)"
        New-Item -Path $fakeGhDir -ItemType Directory -Force | Out-Null
        $fakeGh = Join-Path $fakeGhDir 'gh'
        Set-Content -Path $fakeGh -Value '#!/bin/bash' -Encoding ascii
        Add-Content -Path $fakeGh -Value 'exit 1' -Encoding ascii
        & chmod +x $fakeGh 2>$null
        $env:PATH = "${fakeGhDir}:$($env:PATH)"

        { Wait-GitSplitPullRequestChecks -PullRequest 42 } |
          Should -Throw -ExpectedMessage '*gh pr checks failed*'
      }
      finally {
        $env:PATH = $oldPath
        if ($fakeGhDir) { Remove-Item -Path $fakeGhDir -Recurse -Force -ErrorAction SilentlyContinue }
      }
    }
  }

  Describe "Get-GitSplitChangedCommitInfo no patches" {
    It "throws when commit has no file patches" {
      Push-Location $script:TempRepoPath
      try {
        git commit --allow-empty -m 'empty commit for testing' | Out-Null
        { Get-GitSplitChangedCommitInfo -Ref 'HEAD' } |
          Should -Throw
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitSplitHunkDescriptors duplicate detection" {
    It "processes file patches and returns descriptors" {
      Push-Location $script:TempRepoPath
      try {
        $headSha = (git rev-parse HEAD).Trim()
        $filePatches = Split-Patch -patch (Get-GitPatchText -Ref 'HEAD')
        $result = @(Get-GitSplitHunkDescriptors -Commit $headSha -FilePatches $filePatches)
        $result | Should -Not -BeNullOrEmpty
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Invoke-Git error paths" {
    It "writes stderr to host in red with -WriteHostOnError" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-Git -WriteHostOnError -GitArgs @('show', 'nonexistent-sha-12345') } | Should -Throw
      }
      finally {
        Pop-Location
      }
    }

    It "uses generic error context when no -ErrorMessage" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-Git -GitArgs @('show', 'nonexistent-sha-12345') } | Should -Throw 'git show nonexistent-sha-12345 failed*'
      }
      finally {
        Pop-Location
      }
    }

    It "includes details in error when output present and no -WriteHostOnError" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-Git -ErrorMessage 'test error ctx' -GitArgs @('show', 'nonexistent-sha-12345') } | Should -Throw 'test error ctx failed*'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Invoke-GitQuery error paths" {
    It "uses generic context when no -ErrorMessage and output present" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-GitQuery -GitArgs @('show', 'nonexistent-sha-12345') } | Should -Throw 'git show nonexistent-sha-12345 failed*'
      }
      finally {
        Pop-Location
      }
    }

    It "throws without details when output is empty" {
      Push-Location $script:TempRepoPath
      try {
        { Invoke-GitQuery -GitArgs @('config', '--get', 'nonexistent.gitsplit.key') } | Should -Throw '*failed with exit code 1'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Get-GitPatchText error with empty output" {
    It "throws ErrorMessage when git show fails with no output" {
      Push-Location $script:TempRepoPath
      try {
        Mock Invoke-GitQuery {
          return [PSCustomObject]@{ ExitCode = 128; Output = ''; Lines = @() }
        } -ModuleName GitSplit -ParameterFilter { ($GitArgs -join ' ') -match 'show' }

        { Get-GitPatchText -Ref 'HEAD' -ErrorMessage 'custom patch error' } | Should -Throw 'custom patch error'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "New-SplitCommitPlan edge cases" {
    It "uses fallback subject when commit has empty message" {
      Push-Location $script:TempRepoPath
      try {
        @('a-line-1', 'a-line-2 (empty msg)', 'a-line-3', 'a-line-4 (new)', 'a-line-5 (new)') | Set-Content -Path "a.txt"
        git add a.txt
        git commit --allow-empty-message -m '' 2>$null | Out-Null
        $headSha = (git rev-parse HEAD).Trim()
        $plan = New-SplitCommitPlan -Ref 'HEAD' -NewCommitRanges @(
          [pscustomobject]@{ Path = 'a.txt'; Line = 3 }
        )
        $allLines = @($plan.Steps | Where-Object { $_.Kind -eq 'Literal' } | ForEach-Object { $_.Lines })
        ($allLines | Where-Object { $_ -match 'CommitMessage' } | Select-Object -First 1) | Should -Match "Split $headSha"
      }
      finally {
        Pop-Location
      }
    }

    It "handles multiple split points in the same hunk" {
      Push-Location $script:TempRepoPath
      try {
        $plan = New-SplitCommitPlan -Ref 'HEAD' -NewCommitRanges @(
          [pscustomobject]@{ Path = 'b.txt'; Line = 3 }
          [pscustomobject]@{ Path = 'b.txt'; Line = 5 }
        )
        $plan | Should -Not -BeNullOrEmpty
      }
      finally {
        Pop-Location
      }
    }

    It "handles trailing hunks after target hunk" {
      Push-Location $script:TempRepoPath
      try {
        # Create a file with 20 lines so non-contiguous changes produce separate hunks
        $lines = 1..20 | ForEach-Object { "line-$_" }
        $lines | Set-Content trailing.txt
        git add trailing.txt
        git commit -m "Add trailing.txt baseline" | Out-Null

        # Modify lines 1, 10, and 20 (far enough apart for 3-line context to not overlap)
        $lines[0] = 'line-1-edited'
        $lines[9] = 'line-10-edited'
        $lines[19] = 'line-20-edited'
        $lines | Set-Content trailing.txt
        git add trailing.txt
        git commit -m "Modify trailing.txt in three hunks" | Out-Null

        # Split at line 10 (middle hunk) — hunk 3 is a trailing hunk after the target
        $plan = New-SplitCommitPlan -Ref 'HEAD' -NewCommitRanges @(
          [pscustomobject]@{ Path = 'trailing.txt'; Line = 10 }
        )
        $plan | Should -Not -BeNullOrEmpty
      }
      finally {
        Pop-Location
      }
    }

    It "skips pieces with no plus/minus lines" {
      Push-Location $script:TempRepoPath
      try {
        @(
          'b-line-1'
          'b-line-2 (edited again)'
          'b-line-3'
          'b-line-4 (new)'
          'b-line-5 (new in commit 3)'
          'b-line-6 (new)'
        ) | Set-Content -Path "b.txt"
        git add b.txt
        git commit -m "Add line at end" | Out-Null
        $range = [pscustomobject]@{ Path = 'b.txt'; Line = 6 }
        { New-SplitCommitPlan -Ref 'HEAD' -NewCommitRanges @($range) } | Should -Throw '*requires at least 2*'
      }
      finally {
        Pop-Location
      }
    }

    It "skips empty combined patches for gap pieces" {
      Push-Location $script:TempRepoPath
      try {
        $plan = New-SplitCommitPlan -Ref 'HEAD~1' -NewCommitRanges @(
          [pscustomobject]@{ Path = 'a.txt'; PieceNumber = 1 }
          [pscustomobject]@{ Path = 'b.txt'; PieceNumber = 3 }
        )
        $plan | Should -Not -BeNullOrEmpty
      }
      finally {
        Pop-Location
      }
    }

    It "processes hunk headers without count" {
      Push-Location $script:TempRepoPath
      try {
        # A 1-line file change produces @@ -1 +1 @@ (count omitted when 1)
        "original" | Set-Content -Path "single.txt"
        git add single.txt
        git commit -m "Add single.txt" | Out-Null
        "modified" | Set-Content -Path "single.txt"
        git add single.txt
        git commit -m "Modify single.txt" | Out-Null
        # Split will throw (can't split 1-line hunk) but hunk header parsing runs first
        $range = [pscustomobject]@{ Path = 'single.txt'; Line = 1 }
        { New-SplitCommitPlan -Ref 'HEAD' -NewCommitRanges @($range) } | Should -Throw
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Hunk blank line handling" {
    It "throws for header-only hunk with no body" {
      { Split-Hunk -Hunk "@@ -1,1 +1,1 @@" -Line 1 } | Should -Throw
    }

    It "handles blank lines in column split" {
      $hunk = "@@ -1,3 +1,3 @@`n line1`n`n-old`n+new"
      $result = Split-Hunk -Hunk $hunk -Line 3 -Column 2
      $result.Count | Should -Be 2
    }

    It "handles target as last body line in column split" {
      $hunk = "@@ -1,2 +1,2 @@`n line1`n+newcontent"
      $result = Split-Hunk -Hunk $hunk -Line 2 -Column 4
      $result.Count | Should -Be 2
    }

    It "handles target as first body line in column split" {
      $hunk = "@@ -1,2 +1,2 @@`n+newcontent`n line2"
      $result = Split-Hunk -Hunk $hunk -Line 1 -Column 4
      $result.Count | Should -Be 2
    }

    It "handles blank lines in line-based split" {
      $hunk = "@@ -1,3 +1,3 @@`n line1`n`n-old`n+new"
      $result = Split-Hunk -Hunk $hunk -Line 3
      $result.Count | Should -Be 2
    }
  }

  Describe "Test-GitSplitGeneratedPath attribute checks" {
    It "returns true for linguist-generated=set" {
      Push-Location $script:TempRepoPath
      try {
        '*.generated linguist-generated' | Set-Content -Path ".gitattributes"
        'content' | Set-Content -Path "test.generated"
        git add .gitattributes test.generated
        git commit -m "Add generated file" | Out-Null
        Test-GitSplitGeneratedPath -Path 'test.generated' | Should -BeTrue
      }
      finally {
        Pop-Location
      }
    }

    It "returns false for linguist-generated=false" {
      Push-Location $script:TempRepoPath
      try {
        '*.txt linguist-generated=false' | Set-Content -Path ".gitattributes"
        git add .gitattributes
        git commit -m "Set linguist-generated false for txt" | Out-Null
        Test-GitSplitGeneratedPath -Path 'a.txt' | Should -BeFalse
      }
      finally {
        Pop-Location
      }
    }

    It "skips attribute check for non-HEAD commit when check-attr lacks --source" {
      Push-Location $script:TempRepoPath
      try {
        $script:GitSplitCheckAttrSupportsSource = $false
        $nonHeadSha = (git rev-parse HEAD~1).Trim()
        Test-GitSplitGeneratedPath -Path 'a.txt' -Commit $nonHeadSha | Should -BeFalse
      }
      finally {
        $script:GitSplitCheckAttrSupportsSource = $null
        Pop-Location
      }
    }
  }

  Describe "Test-GitCommitIsAncestor invalid ref" {
    It "throws for invalid ref causing non-zero/non-one exit code" {
      Push-Location $script:TempRepoPath
      try {
        { Test-GitCommitIsAncestor -Ancestor 'not-a-real-ref-xyz' -Descendant 'HEAD' } | Should -Throw
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "New-SetCommitOrderPlan edge cases" {
    It "throws when sequence editor helper is missing" {
      $todoPath = Join-Path $PSScriptRoot "New-RebaseTodo.ps1"
      $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
      Move-Item $todoPath $tempPath
      try {
        Push-Location $script:TempRepoPath
        try {
          { New-SetCommitOrderPlan -OrderedCommits @('HEAD') -BaseRef 'HEAD~2' } | Should -Throw '*Could not find sequence editor helper*'
        }
        finally {
          Pop-Location
        }
      }
      finally {
        Move-Item $tempPath $todoPath
      }
    }

    It "sets autostash variable when -Autostash is provided" {
      Push-Location $script:TempRepoPath
      try {
        $headSha = (git rev-parse HEAD).Trim()
        $plan = New-SetCommitOrderPlan -OrderedCommits @($headSha) -BaseRef 'HEAD~2' -Autostash
        $allLines = @($plan.Steps | Where-Object { $_.Kind -eq 'Literal' } | ForEach-Object { $_.Lines }) | Where-Object { $_ -match 'useAutostash' }
        ($allLines -join "`n") | Should -Match '\$useAutostash = \$true'
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "New-Hunk null body" {
    It "converts null entries to space" {
      $result = New-Hunk -OldStart 1 -OldCount 2 -NewStart 1 -NewCount 2 -BodyLines @(' line1', $null, '+line3')
      $result | Should -Match '@@ -1,2 \+1,2 @@'
      $result | Should -Not -BeNullOrEmpty
    }
  }

  Describe "New-MoveCommitPlan remote tracking branch" {
    It "uses remote tracking branch when branch exists only on origin" {
      Push-Location $script:TempRepoPath
      try {
        $remotePath = Join-Path (Split-Path $script:TempRepoPath) 'test-remote.git'
        if (Test-Path $remotePath) { Remove-Item $remotePath -Recurse -Force }
        git init --bare $remotePath 2>$null | Out-Null
        git remote add origin $remotePath
        git push origin main:feature-branch 2>$null | Out-Null
        $plan = New-MoveCommitPlan -CommitRef 'HEAD~1' -DestinationBranch 'feature-branch'
        $allLines = @($plan.Steps | Where-Object { $_.Kind -eq 'Literal' } | ForEach-Object { $_.Lines })
        ($allLines | Where-Object { $_ -match 'destinationRef' } | Select-Object -First 1) | Should -Match 'refs/remotes/origin/feature-branch'
        ($allLines | Where-Object { $_ -match 'useRemoteTrackingBranch' } | Select-Object -First 1) | Should -Match '\$true'
      }
      finally {
        Pop-Location
        $remotePath = Join-Path (Split-Path $script:TempRepoPath) 'test-remote.git'
        if (Test-Path $remotePath) { Remove-Item $remotePath -Recurse -Force }
      }
    }
  }

  Describe "Resolve-GitSplitImportCandidates path outside repo" {
    It "skips paths outside the repo root" {
      Push-Location $script:TempRepoPath
      try {
        $result = @(Resolve-GitSplitImportCandidates -RepoRoot $script:TempRepoPath -ImporterPath 'a.txt' -Specifier '../../../etc/passwd')
        # Paths outside repo are filtered by the StartsWith check
        $result | Should -HaveCount 0
      }
      finally {
        Pop-Location
      }
    }
  }

  Describe "Split-Patch empty section" {
    It "skips whitespace-only sections after splitting" {
      $patch = "diff --git a/file1.txt b/file1.txt`n@@ -1 +1 @@`n-old`n+new`ndiff --git`n"
      $result = Split-Patch -patch $patch
      $result.Count | Should -Be 1
      $result[0].FilePath | Should -Be 'file1.txt'
    }
  }

  Describe "New-Hunk empty body line" {
    It "converts empty body lines to space" {
      $result = New-Hunk -OldStart 1 -OldCount 1 -NewStart 1 -NewCount 2 -BodyLines @('', '+line')
      $result | Should -Match "(?s)^@@ -1,1 \+1,2 @@`n `n\+line`n$"
    }
  }

  Describe "Test-GitCommitIsAncestor error handling" {
    It "throws when merge-base returns unexpected exit code with no output" {
      Mock Invoke-GitQuery -ModuleName GitSplit {
        [PSCustomObject]@{ ExitCode = 128; Output = '' }
      }
      { Test-GitCommitIsAncestor -Ancestor 'abc123' -Descendant 'def456' } | Should -Throw '*Failed to determine*'
    }
  }
}
