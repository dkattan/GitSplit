@{
  RootModule        = 'GitSplit.psm1'
  ModuleVersion     = '2025.12.29.2'
  GUID              = '7f9e2f0f-3e87-4cf0-9aa6-e1121916ff4e'
  Author            = 'Darren Kattan'
  CompanyName       = ''
  Copyright         = '(c) 2025 Darren Kattan. All rights reserved.'
  Description       = 'Git-oriented patch/hunk/commit splitting utilities.'

  PowerShellVersion = '5.1'

  FunctionsToExport = @(
    'Split-Patch'
    'Split-Hunk'
    'New-Hunk'
    'New-Range'
    'Split-Commit'
    'Add-Commit'
  )
  CmdletsToExport   = @()
  VariablesToExport = @()
  AliasesToExport   = @()

  PrivateData = @{
    PSData = @{
      Tags       = @('git', 'diff', 'patch', 'hunk', 'pester')
      LicenseUri = 'https://opensource.org/license/mit/'
      ProjectUri = 'https://github.com/dkattan/GitSplit'
      ReleaseNotes = 'Initial release.'
    }
  }
}


