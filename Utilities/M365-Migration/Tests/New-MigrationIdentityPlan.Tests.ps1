#Requires -Version 7.4

<#
    End-to-end tests for New-MigrationIdentityPlan.ps1.

    The script is entirely offline, so it is exercised for real against the fixture
    inventory rather than mocked: every run reads the CSVs under
    Fixtures/New-MigrationIdentityPlan and writes a plan into TestDrive. Testing the
    whole script is the point - the value of the planner is in how the pieces combine,
    and a mocked unit test of the naming engine already exists elsewhere.

    Author: AutomationHub
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:PlanScript = (Resolve-Path (Join-Path $PSScriptRoot '..' 'New-MigrationIdentityPlan.ps1')).ProviderPath
    $script:Fixtures = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'New-MigrationIdentityPlan')).ProviderPath

    $script:FullParameters = @{
        UserMailboxesCsv      = (Join-Path $script:Fixtures 'UserMailboxes.csv')
        SharedMailboxesCsv    = (Join-Path $script:Fixtures 'SharedMailboxes.csv')
        GroupsCsv             = (Join-Path $script:Fixtures 'Groups.csv')
        ContactsCsv           = (Join-Path $script:Fixtures 'Contacts.csv')
        InterimDomain         = 'newco.onmicrosoft.com'
        SkuMapPath            = (Join-Path $script:Fixtures 'SkuMap.csv')
        ExclusionRulesPath    = (Join-Path $script:Fixtures 'ExclusionRules.csv')
        WaveMapPath           = (Join-Path $script:Fixtures 'WaveMap.csv')
        ReservedAddressesPath = (Join-Path $script:Fixtures 'Reserved.csv')
        DefaultUsageLocation  = 'IE'
        PreserveAliases       = $true
        AliasDomainMap        = @{ 'contoso.com' = 'newco.com' }
    }

    function Invoke-PlanRun {
        <#
        .SYNOPSIS
            Runs the planner into a fresh directory and returns the plan it produced.
        .PARAMETER OutputPath
            Directory to write into; created if it does not exist.
        .PARAMETER Parameter
            Extra or overriding parameters for the script.
        .EXAMPLE
            Invoke-PlanRun -OutputPath $TestDrive/run1
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$OutputPath,

            [hashtable]$Parameter = @{}
        )

        if (-not (Test-Path -LiteralPath $OutputPath)) {
            $null = New-Item -Path $OutputPath -ItemType Directory -Force
        }

        $splat = @{
            UsersCsv     = (Join-Path $script:Fixtures 'Users.csv')
            TargetDomain = 'newco.com'
            OutputPath   = $OutputPath
            Verbosity    = 'Low'
        }
        foreach ($name in $Parameter.Keys) { $splat[$name] = $Parameter[$name] }

        & $script:PlanScript @splat 6>$null
        $exitCode = $LASTEXITCODE

        $files = @(Get-ChildItem -Path $OutputPath -Filter 'IdentityPlan_*.csv' -Recurse -ErrorAction SilentlyContinue)
        $rows = if ($files.Count -gt 0) { @(Import-Csv -LiteralPath $files[0].FullName -Encoding utf8) } else { @() }

        [pscustomobject]@{
            ExitCode = $exitCode
            Path     = if ($files.Count -gt 0) { $files[0].FullName } else { '' }
            Rows     = $rows
        }
    }

    function Get-PlanRow {
        <#
        .SYNOPSIS
            Finds one plan row by any of its source addresses or its display name.
        .PARAMETER Result
            The object returned by Invoke-PlanRun.
        .PARAMETER Identity
            The source UPN, source primary SMTP address or display name to look for.
        .EXAMPLE
            Get-PlanRow -Result $plan -Identity 'jsmith@contoso.com'
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNull()]
            $Result,

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Identity
        )

        @($Result.Rows | Where-Object {
                $_.SourceUserPrincipalName -eq $Identity -or
                $_.SourcePrimarySmtp -eq $Identity -or
                $_.DisplayName -eq $Identity
            }) | Select-Object -First 1
    }
}

Describe 'New-MigrationIdentityPlan' {

    Context 'A full offline run over the fixture inventory' {

        BeforeAll {
            $script:Full = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'full') -Parameter $script:FullParameters
        }

        It 'Exits 0 even though some rows need an operator decision' {
            $script:Full.ExitCode | Should -Be 0
            $script:Full.Path | Should -Not -BeNullOrEmpty
        }

        It 'Writes every plan column in canonical order' {
            $expected = @((New-MigrationPlanRow).PSObject.Properties.Name)
            @($script:Full.Rows[0].PSObject.Properties.Name) | Should -Be $expected
        }

        It 'Plans one row per source object' {
            $script:Full.Rows.Count | Should -Be 17
        }

        It 'Gives the first John Smith the unsuffixed name' {
            $row = Get-PlanRow -Result $script:Full -Identity 'jsmith@contoso.com'
            $row.TargetUserPrincipalName | Should -BeExactly 'john.smith@newco.com'
            $row.TargetPrimarySmtp | Should -BeExactly 'john.smith@newco.com'
            $row.TargetMailNickname | Should -BeExactly 'john.smith'
            $row.PlanStatus | Should -BeExactly 'Planned'
        }

        It 'Resolves the second John Smith with his middle initial and explains why' {
            $row = Get-PlanRow -Result $script:Full -Identity 'jqsmith@contoso.com'
            $row.TargetUserPrincipalName | Should -BeExactly 'john.q.smith@newco.com'
            $row.PlanStatus | Should -BeExactly 'Collision'
            $row.PlanDetail | Should -BeLike '*john.smith@newco.com is taken by jsmith@contoso.com*'
        }

        It 'Transliterates accented names' {
            (Get-PlanRow -Result $script:Full -Identity 'rdubois@contoso.com').TargetUserPrincipalName |
                Should -BeExactly 'renee.dubois@newco.com'
        }

        It 'Keeps hyphens and suffixes a name already reserved in the destination' {
            $row = Get-PlanRow -Result $script:Full -Identity 'aschmidt@contoso.com'
            $row.TargetUserPrincipalName | Should -BeExactly 'anna-maria.schmidt-braun2@newco.com'
            $row.PlanStatus | Should -BeExactly 'Collision'
            $row.PlanDetail | Should -BeLike '*already reserved in the destination*'
        }

        It 'Drops the apostrophe from an Irish surname' {
            (Get-PlanRow -Result $script:Full -Identity 'sobrien@contoso.com').TargetUserPrincipalName |
                Should -BeExactly 'sean.obrien@newco.com'
        }

        It 'Refuses to guess an address for a user with no surname' {
            $row = Get-PlanRow -Result $script:Full -Identity 'prince@contoso.com'
            $row.PlanStatus | Should -BeExactly 'NeedsReview'
            $row.TargetUserPrincipalName | Should -BeExactly ''
            $row.TargetPrimarySmtp | Should -BeExactly ''
            $row.InterimPrimarySmtp | Should -BeExactly ''
            $row.PlanDetail | Should -BeLike '*missing: last*'
        }

        It 'Refuses to guess an address for a name written only in a non-Latin script' {
            $row = Get-PlanRow -Result $script:Full -Identity 'wwei@contoso.com'
            $row.PlanStatus | Should -BeExactly 'NeedsReview'
            $row.TargetUserPrincipalName | Should -BeExactly ''
        }

        It 'Excludes the guest and keeps it typed as a Guest' {
            $row = Get-PlanRow -Result $script:Full -Identity 'dana.lee_fabrikam.com#EXT#@contoso.onmicrosoft.com'
            $row.ObjectType | Should -BeExactly 'Guest'
            $row.PlanStatus | Should -BeExactly 'Excluded'
            $row.ExcludeReason | Should -BeExactly 'Guest account'
        }

        It 'Excludes the directory-synced user' {
            (Get-PlanRow -Result $script:Full -Identity 'psynced@contoso.com').ExcludeReason |
                Should -BeExactly 'Directory-synced'
        }

        It 'Excludes the disabled user' {
            (Get-PlanRow -Result $script:Full -Identity 'ddisabled@contoso.com').ExcludeReason |
                Should -BeExactly 'Account disabled'
        }

        It 'Excludes the break-glass admin by exclusion rule' {
            $row = Get-PlanRow -Result $script:Full -Identity 'break-glass-admin@contoso.com'
            $row.PlanStatus | Should -BeExactly 'Excluded'
            $row.ExcludeReason | Should -BeLike 'Emergency access account*'
        }

        It 'Plans the shared mailbox from its source local part and leaves its UPN empty' {
            $row = Get-PlanRow -Result $script:Full -Identity 'accounts@contoso.com'
            $row.ObjectType | Should -BeExactly 'Shared'
            $row.TargetPrimarySmtp | Should -BeExactly 'accounts@newco.com'
            $row.TargetUserPrincipalName | Should -BeExactly ''
            $row.PlanStatus | Should -BeExactly 'Planned'
        }

        It 'Types a room mailbox as Room' {
            (Get-PlanRow -Result $script:Full -Identity 'boardroom@contoso.com').ObjectType | Should -BeExactly 'Room'
        }

        It 'Plans the mail-enabled groups and excludes the Microsoft 365 group' {
            (Get-PlanRow -Result $script:Full -Identity 'allstaff@contoso.com').ObjectType | Should -BeExactly 'Distribution'
            (Get-PlanRow -Result $script:Full -Identity 'secteam@contoso.com').ObjectType | Should -BeExactly 'MailEnabledSecurity'

            $m365 = Get-PlanRow -Result $script:Full -Identity 'projectx@contoso.com'
            $m365.ObjectType | Should -BeExactly 'M365Group'
            $m365.PlanStatus | Should -BeExactly 'Excluded'
            $m365.ExcludeReason | Should -BeExactly 'Migrated by Fly'
        }

        It 'Plans the mail contact' {
            $row = Get-PlanRow -Result $script:Full -Identity 'marcus.vendor@contoso.com'
            $row.ObjectType | Should -BeExactly 'Contact'
            $row.TargetPrimarySmtp | Should -BeExactly 'marcus.vendor@newco.com'
        }

        It 'Builds the interim addresses in the interim domain' {
            $row = Get-PlanRow -Result $script:Full -Identity 'jsmith@contoso.com'
            $row.InterimUserPrincipalName | Should -BeExactly 'john.smith@newco.onmicrosoft.com'
            $row.InterimPrimarySmtp | Should -BeExactly 'john.smith@newco.onmicrosoft.com'
        }

        It 'Maps licences through the SKU map, expanding one source SKU into two' {
            (Get-PlanRow -Result $script:Full -Identity 'jsmith@contoso.com').TargetLicenses |
                Should -BeExactly 'SPE_E3;MCOEV;MCOMEETADV'
        }

        It 'Drops a SKU the map maps to nothing' {
            (Get-PlanRow -Result $script:Full -Identity 'rdubois@contoso.com').TargetLicenses | Should -BeExactly 'SPE_E3'
        }

        It 'Carries an unmapped SKU through and says so' {
            $row = Get-PlanRow -Result $script:Full -Identity 'sobrien@contoso.com'
            $row.TargetLicenses | Should -BeExactly 'EXCHANGESTANDARD'
            $row.PlanDetail | Should -BeLike '*No SKU mapping for EXCHANGESTANDARD*'
        }

        It 'Re-domains the old primary address as an alias' {
            $aliases = @(Split-MigrationList -Value (Get-PlanRow -Result $script:Full -Identity 'jsmith@contoso.com').TargetAliases)
            $aliases | Should -Contain 'smtp:jsmith@newco.com'
        }

        It 'Carries the legacy Exchange DN across as an X500 address' {
            $aliases = @(Split-MigrationList -Value (Get-PlanRow -Result $script:Full -Identity 'jsmith@contoso.com').TargetAliases)
            @($aliases | Where-Object { $_ -like 'X500:/o=ExchangeLabs/*-jsmith' }).Count | Should -Be 1
        }

        It 'Carries an existing source X500 address across as well' {
            $aliases = @(Split-MigrationList -Value (Get-PlanRow -Result $script:Full -Identity 'rdubois@contoso.com').TargetAliases)
            @($aliases | Where-Object { $_ -like 'X500:*-rdubois-old' }).Count | Should -Be 1
        }

        It 'Never lists the target primary address as one of its own aliases' {
            foreach ($row in $script:Full.Rows) {
                if (-not $row.TargetPrimarySmtp) { continue }
                @(Split-MigrationList -Value $row.TargetAliases) |
                    Should -Not -Contain ('smtp:' + $row.TargetPrimarySmtp)
            }
        }

        It 'Applies the wave map and falls back to the default wave' {
            (Get-PlanRow -Result $script:Full -Identity 'jsmith@contoso.com').Wave | Should -BeExactly '2'
            (Get-PlanRow -Result $script:Full -Identity 'accounts@contoso.com').Wave | Should -BeExactly '3'
            (Get-PlanRow -Result $script:Full -Identity 'rdubois@contoso.com').Wave | Should -BeExactly '1'
        }

        It 'Applies the default usage location only where the source had none' {
            (Get-PlanRow -Result $script:Full -Identity 'sobrien@contoso.com').UsageLocation | Should -BeExactly 'IE'
            (Get-PlanRow -Result $script:Full -Identity 'rdubois@contoso.com').UsageLocation | Should -BeExactly 'FR'
        }
    }

    Context 'Re-running the planner' {

        It 'Produces a byte-identical plan from identical inputs' {
            $first = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'repeat-a') -Parameter $script:FullParameters
            $second = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'repeat-b') -Parameter $script:FullParameters

            $first.Path | Should -Not -BeNullOrEmpty
            $second.Path | Should -Not -BeNullOrEmpty
            (Get-Content -LiteralPath $second.Path -Raw) | Should -BeExactly (Get-Content -LiteralPath $first.Path -Raw)
        }
    }

    Context 'Interim addresses without an interim domain' {

        BeforeAll {
            $parameters = @{} + $script:FullParameters
            $parameters.Remove('InterimDomain')
            $script:NoInterim = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'nointerim') -Parameter $parameters
        }

        It 'Mirrors the target addresses' {
            $row = Get-PlanRow -Result $script:NoInterim -Identity 'jsmith@contoso.com'
            $row.InterimUserPrincipalName | Should -BeExactly $row.TargetUserPrincipalName
            $row.InterimPrimarySmtp | Should -BeExactly $row.TargetPrimarySmtp
        }
    }

    Context 'A SMTP format that differs from the UPN format' {

        BeforeAll {
            $script:Diverged = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'diverge') -Parameter @{
                SmtpFormat = 'FLast'
            }
        }

        It 'Marks the row UpnSmtpDiverge and sets both addresses' {
            $row = Get-PlanRow -Result $script:Diverged -Identity 'rdubois@contoso.com'
            $row.PlanStatus | Should -BeExactly 'UpnSmtpDiverge'
            $row.TargetUserPrincipalName | Should -BeExactly 'renee.dubois@newco.com'
            $row.TargetPrimarySmtp | Should -BeExactly 'rdubois@newco.com'
        }

        It 'Leaves matching addresses as Planned' {
            $matched = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'nodiverge')
            (Get-PlanRow -Result $matched -Identity 'rdubois@contoso.com').PlanStatus | Should -BeExactly 'Planned'
        }
    }

    Context 'Re-planning against an existing plan' {

        BeforeAll {
            $baseline = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'baseline') -Parameter $script:FullParameters

            # Stand in for a phase-3 run: one row provisioned, one hand-corrected by the operator.
            $edited = @(Import-Csv -LiteralPath $baseline.Path -Encoding utf8)
            foreach ($row in $edited) {
                if ($row.SourceUserPrincipalName -eq 'jsmith@contoso.com') {
                    $row.TargetUserPrincipalName = 'j.smith@newco.com'
                    $row.TargetPrimarySmtp = 'j.smith@newco.com'
                    $row.TargetObjectId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                    $row.ProvisionStatus = 'Provisioned'
                    $row.MailboxProvisioned = 'True'
                }
                if ($row.SourceUserPrincipalName -eq 'rdubois@contoso.com') {
                    $row.PlanStatus = 'ManualOverride'
                    $row.TargetUserPrincipalName = 'renee@newco.com'
                    $row.TargetPrimarySmtp = 'renee@newco.com'
                    $row.Wave = '9'
                }
            }

            $script:ExistingPlanPath = Join-Path $TestDrive 'existing-plan.csv'
            $edited | Export-Csv -LiteralPath $script:ExistingPlanPath -NoTypeInformation -Encoding utf8

            $parameters = @{} + $script:FullParameters
            $parameters['ExistingPlanPath'] = $script:ExistingPlanPath
            $script:Replanned = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'replan') -Parameter $parameters
        }

        It 'Keeps the identity and the provisioning state of a provisioned row' {
            $row = Get-PlanRow -Result $script:Replanned -Identity 'jsmith@contoso.com'
            $row.TargetUserPrincipalName | Should -BeExactly 'j.smith@newco.com'
            $row.TargetObjectId | Should -BeExactly 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $row.ProvisionStatus | Should -BeExactly 'Provisioned'
            $row.MailboxProvisioned | Should -BeExactly 'True'
        }

        It 'Keeps a ManualOverride row exactly as the operator left it' {
            $row = Get-PlanRow -Result $script:Replanned -Identity 'rdubois@contoso.com'
            $row.PlanStatus | Should -BeExactly 'ManualOverride'
            $row.TargetUserPrincipalName | Should -BeExactly 'renee@newco.com'
            $row.Wave | Should -BeExactly '9'
        }

        It 'Refreshes the source attributes of a preserved row from the new inventory' {
            (Get-PlanRow -Result $script:Replanned -Identity 'jsmith@contoso.com').JobTitle |
                Should -BeExactly 'Operations Manager'
        }

        It 'Lets a newly planned row take the name the preserved row released' {
            $row = Get-PlanRow -Result $script:Replanned -Identity 'jqsmith@contoso.com'
            $row.TargetUserPrincipalName | Should -BeExactly 'john.smith@newco.com'
            $row.PlanStatus | Should -BeExactly 'Planned'
        }

        It 'Is idempotent: re-planning against its own output changes nothing' {
            $parameters = @{} + $script:FullParameters
            $parameters['ExistingPlanPath'] = $script:ExistingPlanPath
            $again = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'replan-again') -Parameter $parameters
            (Get-Content -LiteralPath $again.Path -Raw) | Should -BeExactly (Get-Content -LiteralPath $script:Replanned.Path -Raw)
        }
    }

    Context 'Reserved addresses supplied as a plain list' {

        BeforeAll {
            $listPath = Join-Path $TestDrive 'reserved-list.txt'
            @('# addresses already live in the destination', 'john.smith@newco.com') |
                Set-Content -LiteralPath $listPath -Encoding utf8

            $script:PlainList = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'plainlist') -Parameter @{
                ReservedAddressesPath = $listPath
            }
        }

        It 'Suffixes the user who wanted the reserved name' {
            $row = Get-PlanRow -Result $script:PlainList -Identity 'jsmith@contoso.com'
            $row.TargetUserPrincipalName | Should -BeExactly 'john.smith2@newco.com'
            $row.PlanStatus | Should -BeExactly 'Collision'
        }

        It 'Still gives the John Smith with a middle name his initial form' {
            (Get-PlanRow -Result $script:PlainList -Identity 'jqsmith@contoso.com').TargetUserPrincipalName |
                Should -BeExactly 'john.q.smith@newco.com'
        }
    }

    Context 'Include switches' {

        BeforeAll {
            $script:Inclusive = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'inclusive') -Parameter @{
                IncludeGuests   = $true
                IncludeDisabled = $true
                IncludeSynced   = $true
            }
        }

        It 'Keeps the guest UPN verbatim rather than templating it' {
            $row = Get-PlanRow -Result $script:Inclusive -Identity 'dana.lee_fabrikam.com#EXT#@contoso.onmicrosoft.com'
            $row.PlanStatus | Should -Not -BeExactly 'Excluded'
            $row.TargetUserPrincipalName | Should -BeExactly 'dana.lee_fabrikam.com#EXT#@contoso.onmicrosoft.com'
            $row.TargetPrimarySmtp | Should -BeExactly 'dana.lee@fabrikam.com'
        }

        It 'Plans the disabled and the synced user' {
            (Get-PlanRow -Result $script:Inclusive -Identity 'ddisabled@contoso.com').PlanStatus | Should -BeExactly 'Planned'
            (Get-PlanRow -Result $script:Inclusive -Identity 'psynced@contoso.com').PlanStatus | Should -BeExactly 'Planned'
        }
    }

    Context 'DryRun' {

        It 'Computes the plan and writes no plan file' {
            $outputPath = Join-Path $TestDrive 'dryrun'
            $result = Invoke-PlanRun -OutputPath $outputPath -Parameter (@{} + $script:FullParameters + @{ DryRun = $true })

            $result.ExitCode | Should -Be 0
            $result.Path | Should -BeExactly ''
            @(Get-ChildItem -Path $outputPath -Filter '*.log' -Recurse).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Bad input' {

        It 'Exits 1 when the users CSV does not exist' {
            $result = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'missing') -Parameter @{
                UsersCsv = (Join-Path $TestDrive 'no-such-file.csv')
            }
            $result.ExitCode | Should -Be 1
            $result.Path | Should -BeExactly ''
        }

        It 'Exits 1 when the naming template names an unknown preset' {
            $result = Invoke-PlanRun -OutputPath (Join-Path $TestDrive 'badformat') -Parameter @{ UpnFormat = 'NotAPreset' }
            $result.ExitCode | Should -Be 1
        }
    }
}
