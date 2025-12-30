Describe "GitSplit" {

  BeforeAll {
    Import-Module "$PSScriptRoot/GitSplit.psm1" -Force

    # Shared path, but the repo itself is re-created per test.
    $script:TempRepoPath = Join-Path $PSScriptRoot 'temprepo'
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
  }

  Describe "Move-Commit" {
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

    It "can move HEAD~1 to another branch and remove it from the source branch" {
      Push-Location $script:TempRepoPath
      try {
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

}
