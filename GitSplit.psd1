@{
  RootModule        = 'GitSplit.psm1'
  ModuleVersion     = '2026.04.24.28'
  GUID              = '7f9e2f0f-3e87-4cf0-9aa6-e1121916ff4e'
  Author            = 'Darren Kattan'
  CompanyName       = ''
  Copyright         = '(c) 2025 Darren Kattan. All rights reserved.'
  Description       = 'Git-oriented patch/hunk/commit splitting utilities.'

  PowerShellVersion = '5.1'

  FunctionsToExport = @(
    'Select-GitSplitPaths'
    'Test-GitSplitSelection'
    'Wait-GitSplitPullRequestChecks'
    'Get-GitSplitClosure'
    'Get-GitSplitHunks'
    'Split-Patch'
    'Split-Hunk'
    'Split-Commit'
    'New-Hunk'
    'New-Range'
    'Add-Commit'
    'Remove-Commit'
    'Move-Commit'
    'Set-CommitOrder'
    'Invoke-GitSplitAbsorb'
    'Get-CommitMessageFromChanges'
  )
  CmdletsToExport   = @()
  VariablesToExport = @()
  AliasesToExport   = @()

  PrivateData       = @{
    PSData = @{
      Tags         = @('git', 'diff', 'patch', 'hunk', 'pester')
      LicenseUri   = 'https://opensource.org/license/mit/'
      ProjectUri   = 'https://github.com/dkattan/GitSplit'
      ReleaseNotes = 'Add deterministic selection, closure, hunk ID, and PR check helpers for advanced PR splitting workflows.'
    }
  }
}

