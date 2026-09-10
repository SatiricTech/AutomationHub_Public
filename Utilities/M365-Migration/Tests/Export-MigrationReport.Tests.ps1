#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Report-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null

    $script:sampleRows = @(
        [pscustomobject]@{ Recipient = 'a@contoso.com'; Reference = 'PrimarySmtp'; Domain = 'contoso.com' }
        [pscustomobject]@{ Recipient = 'b@contoso.com'; Reference = 'Alias';       Domain = 'contoso.com' }
    )
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Export-MigrationReport' {

    Context 'File naming' {

        It 'Names the file Name_timestamp.csv in the run output directory' {
            $null = Initialize-MigrationRun -ScriptName 'Remove-DomainReferences' -OutputPath $script:workspace
            $path = Export-MigrationReport -Rows $script:sampleRows -Name 'DomainReferences'
            [System.IO.Path]::GetFileName($path) | Should -Match '^DomainReferences_\d{8}-\d{6}\.csv$'
            (Split-Path -Path $path -Parent) | Should -BeExactly $script:workspace
            Test-Path -LiteralPath $path | Should -BeTrue
        }

        It 'Prefixes the filename and folder when the run has a prefix' {
            $null = Initialize-MigrationRun -ScriptName 'Get-Inventory' -OutputPath $script:workspace -Prefix 'Contoso'
            $path = Export-MigrationReport -Rows $script:sampleRows -Name 'Mailboxes'
            [System.IO.Path]::GetFileName($path) | Should -Match '^Contoso_Mailboxes_\d{8}-\d{6}\.csv$'
            (Split-Path -Path $path -Parent) | Should -BeExactly (Join-Path $script:workspace 'Contoso')
        }

        It 'Appends a suffix after a hyphen' {
            $null = Initialize-MigrationRun -ScriptName 'Get-TeamsPhone' -OutputPath $script:workspace -Prefix 'Contoso'
            $path = Export-MigrationReport -Rows $script:sampleRows -Name 'TeamsPhoneNumbers' -Suffix 'Unassigned'
            [System.IO.Path]::GetFileName($path) |
                Should -Match '^Contoso_TeamsPhoneNumbers-Unassigned_\d{8}-\d{6}\.csv$'
        }

        It 'Ignores a blank suffix' {
            $null = Initialize-MigrationRun -ScriptName 'Get-Inventory' -OutputPath $script:workspace
            $path = Export-MigrationReport -Rows $script:sampleRows -Name 'Mailboxes' -Suffix '  '
            [System.IO.Path]::GetFileName($path) | Should -Match '^Mailboxes_\d{8}-\d{6}\.csv$'
        }

        It 'Writes the report in a dry run as well - a report is a read, not a mutation' {
            $null = Initialize-MigrationRun -ScriptName 'Get-Inventory' -OutputPath $script:workspace -DryRun
            $path = Export-MigrationReport -Rows $script:sampleRows -Name 'Mailboxes'
            Test-Path -LiteralPath $path | Should -BeTrue
            [System.IO.Path]::GetFileName($path) | Should -Not -Match 'DryRun'
        }
    }

    Context 'Content' {

        It 'Writes every row and column as given, with no Status summary block' {
            $null = Initialize-MigrationRun -ScriptName 'Remove-DomainReferences' -OutputPath $script:workspace
            $path = Export-MigrationReport -Rows $script:sampleRows -Name 'Content'
            $written = @(Import-Csv -LiteralPath $path)
            $written | Should -HaveCount 2
            @($written[0].PSObject.Properties.Name) | Should -Be @('Recipient', 'Reference', 'Domain')
            $written[0].Recipient | Should -BeExactly 'a@contoso.com'
        }

        It 'Writes an informational row for an empty report rather than an unreadable file' {
            $null = Initialize-MigrationRun -ScriptName 'Remove-DomainReferences' -OutputPath $script:workspace
            $path = Export-MigrationReport -Rows @() -Name 'Blockers'
            $written = @(Import-Csv -LiteralPath $path)
            $written | Should -HaveCount 1
            $written[0].Info | Should -BeExactly 'No Blockers records found.'
        }

        It 'Returns the full path' {
            $null = Initialize-MigrationRun -ScriptName 'Remove-DomainReferences' -OutputPath $script:workspace
            $path = Export-MigrationReport -Rows $script:sampleRows -Name 'Returned'
            $path | Should -BeOfType [string]
            [System.IO.Path]::IsPathRooted($path) | Should -BeTrue
        }
    }
}

Describe 'Get-MigrationRunContext' {

    It 'Returns the context Initialize-MigrationRun stored' {
        $run = Initialize-MigrationRun -ScriptName 'Set-Identity' -OutputPath $script:workspace -Prefix 'Contoso' -DryRun
        $context = Get-MigrationRunContext
        $context.ScriptName | Should -BeExactly 'Set-Identity'
        $context.Prefix | Should -BeExactly 'Contoso'
        $context.DryRun | Should -BeTrue
        $context.OutputDirectory | Should -BeExactly $run.OutputDirectory
        $context.LogPath | Should -BeExactly $run.LogPath
    }

    It 'Returns $null when no run has been initialised' {
        InModuleScope M365Migration {
            $saved = $script:MigrationRun
            try {
                $script:MigrationRun = $null
                Get-MigrationRunContext | Should -BeNullOrEmpty
            }
            finally {
                $script:MigrationRun = $saved
            }
        }
    }
}
