#Requires -Version 7.4

<#
    Offline tests for New-MigrationRecipients.ps1.

    Same two techniques as New-MigrationUsers.Tests.ps1, and for the same reasons:

    1. The script's functions are loaded by parsing the file and dot-sourcing only its
       FunctionDefinitionAst nodes, so the Main region (and its 'exit') never runs.

    2. The end-to-end DryRun test invokes the script with the call operator while plain
       functions defined in BeforeAll shadow every Exchange Online cmdlet. PowerShell
       resolves commands from the innermost scope outwards, so these win over the real
       cmdlets for anything the script calls, and the real module still provides the run
       context, logging, DryRun gating and results export. 'exit' inside a script invoked
       with '&' ends that script only, so $LASTEXITCODE is readable and Pester carries on.

    Call logs live in $global: because a function defined in BeforeAll does not share the
    $script: scope Pester gives the It blocks.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The call logs must be reachable from the stub functions defined in BeforeAll, and a function defined there does not share the $script: scope Pester gives the It blocks. $global: is the only scope both sides can see.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script passes, including ones a particular test does not assert on; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'These are stand-ins for Exchange Online cmdlets whose names the script under test calls. They exist to record that a call happened and change nothing, so ShouldProcess would be meaningless.')]
param()

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:scriptPath = Join-Path $PSScriptRoot '..' 'New-MigrationRecipients.ps1'
    $script:fixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'New-MigrationRecipients'

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw "New-MigrationRecipients.ps1 failed to parse: $($parseErrors[0].Message)" }
    $functionText = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
            ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    . ([scriptblock]::Create($functionText))

    # --- Stubs for everything that would reach Exchange Online ---------------------------
    $global:recipientMutations = [System.Collections.Generic.List[string]]::new()
    $global:recipientReads = [System.Collections.Generic.List[string]]::new()

    function Connect-MigrationExchange {
        param([string]$DelegatedOrganization, [switch]$Reconnect)
        return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com' }
    }

    function Get-Recipient {
        param([string]$Identity, [string]$ErrorAction)
        $global:recipientReads.Add("Get-Recipient $Identity")
        return @()
    }

    function Get-DistributionGroupMember {
        param([string]$Identity, $ResultSize, [string]$ErrorAction)
        $global:recipientReads.Add("Get-DistributionGroupMember $Identity")
        return @()
    }

    function New-Mailbox { $global:recipientMutations.Add('New-Mailbox') }
    function New-DistributionGroup { $global:recipientMutations.Add('New-DistributionGroup') }
    function New-DynamicDistributionGroup { $global:recipientMutations.Add('New-DynamicDistributionGroup') }
    function New-MailContact {
        param($Name, $DisplayName, $Alias, $ExternalEmailAddress, $PrimarySmtpAddress, $ErrorAction)
        $global:recipientMutations.Add("New-MailContact PrimarySmtpAddress=$PrimarySmtpAddress ExternalEmailAddress=$ExternalEmailAddress")
    }
    function Set-Mailbox { $global:recipientMutations.Add('Set-Mailbox') }
    function Set-DistributionGroup { $global:recipientMutations.Add('Set-DistributionGroup') }
    function Set-DynamicDistributionGroup { $global:recipientMutations.Add('Set-DynamicDistributionGroup') }
    function Set-MailContact { $global:recipientMutations.Add('Set-MailContact') }
    function Add-DistributionGroupMember { $global:recipientMutations.Add('Add-DistributionGroupMember') }
    function Add-MailboxPermission { $global:recipientMutations.Add('Add-MailboxPermission') }
    function Add-RecipientPermission { $global:recipientMutations.Add('Add-RecipientPermission') }

    function Save-MigrationPlan {
        param([string]$Path, [object[]]$Rows)
        $global:recipientMutations.Add("Save-MigrationPlan $Path")
    }

    # --- Shared fixtures ------------------------------------------------------------------
    $script:planRows = @(Import-MigrationPlan -Path (Join-Path $script:fixtureRoot 'IdentityPlan.csv'))
    $script:groupRows = @(Import-MigrationCsv -Path (Join-Path $script:fixtureRoot 'Groups.csv'))
    $script:addressMap = Get-MigrationPlanAddressMap -Rows $script:planRows

    $script:booleanGroupSetting = @('HiddenFromAddressListsEnabled', 'RequireSenderAuthenticationEnabled',
        'ModerationEnabled', 'ReportToManagerEnabled')
    $script:textGroupSetting = @('MemberJoinRestriction', 'MemberDepartRestriction')
    $script:addressGroupSetting = @('ManagedBy', 'ModeratedBy', 'AcceptMessagesOnlyFromSendersOrMembers', 'GrantSendOnBehalfTo')
}

AfterAll {
    Remove-Variable -Name recipientMutations, recipientReads -Scope Global -ErrorAction SilentlyContinue
}

Describe 'New-MigrationRecipients - ConvertTo-AddressArray' {

    It 'Splits a delimited cell and strips the smtp prefix' {
        ConvertTo-AddressArray -Value 'ap@contoso.com; smtp:accounts@contoso.com;' |
            Should -Be @('ap@contoso.com', 'accounts@contoso.com')
    }

    It 'Accepts an array as well as a cell' {
        ConvertTo-AddressArray -Value @('a@contoso.com', 'b@contoso.com') | Should -Be @('a@contoso.com', 'b@contoso.com')
    }

    It 'De-duplicates case-insensitively and drops empties' {
        ConvertTo-AddressArray -Value 'A@contoso.com;a@contoso.com;;  ' | Should -Be @('A@contoso.com')
    }

    It 'Returns an empty array for a null value' {
        @(ConvertTo-AddressArray -Value $null).Count | Should -Be 0
    }
}

Describe 'New-MigrationRecipients - ConvertTo-RecipientBoolean' {

    It 'Parses the affirmative spellings' {
        foreach ($value in @('True', 'true', '1', 'yes', 'Enabled')) {
            ConvertTo-RecipientBoolean -Value $value | Should -BeTrue
        }
    }

    It 'Parses the negative spellings' {
        foreach ($value in @('False', '0', 'no', 'Disabled')) {
            ConvertTo-RecipientBoolean -Value $value | Should -BeFalse
        }
    }

    It 'Treats a blank cell as no opinion rather than as false' {
        ConvertTo-RecipientBoolean -Value '' | Should -BeNullOrEmpty
        ConvertTo-RecipientBoolean -Value $null | Should -BeNullOrEmpty
    }
}

Describe 'New-MigrationRecipients - Get-RowTargetAddress' {

    BeforeAll {
        $script:sharedRow = @($script:planRows | Where-Object { $_.ObjectType -eq 'Shared' })[0]
    }

    It 'Prefers the target primary SMTP address' {
        Get-RowTargetAddress -Row $script:sharedRow | Should -BeExactly 'accounts@newco.com'
    }

    It 'Uses the interim address with -UseInterim' {
        Get-RowTargetAddress -Row $script:sharedRow -UseInterim | Should -BeExactly 'accounts@newco.onmicrosoft.com'
    }

    It 'Falls back to the UPN column for a row that only has one' {
        $row = [pscustomobject]@{
            TargetPrimarySmtp = ''; TargetUserPrincipalName = 'a@newco.com'
            InterimPrimarySmtp = ''; InterimUserPrincipalName = ''
        }
        Get-RowTargetAddress -Row $row | Should -BeExactly 'a@newco.com'
    }

    It 'Returns an empty string when the row has no destination address at all' {
        $row = [pscustomobject]@{
            TargetPrimarySmtp = ''; TargetUserPrincipalName = ''
            InterimPrimarySmtp = ''; InterimUserPrincipalName = ''
        }
        Get-RowTargetAddress -Row $row | Should -BeExactly ''
    }
}

Describe 'New-MigrationRecipients - Get-MigrationPlanAddressMap' {

    It 'Maps the source UPN, primary SMTP, aliases and display name onto one target address' {
        $script:addressMap['jsmith@contoso.com'] | Should -BeExactly 'john.smith@newco.com'
        $script:addressMap['john.smith@contoso.com'] | Should -BeExactly 'john.smith@newco.com'
        $script:addressMap['john q. smith'] | Should -BeExactly 'john.smith@newco.com'
    }

    It 'Maps recipients as well as users' {
        $script:addressMap['accounts@contoso.com'] | Should -BeExactly 'accounts@newco.com'
        $script:addressMap['ap@contoso.com'] | Should -BeExactly 'accounts@newco.com'
        $script:addressMap['allstaff@contoso.com'] | Should -BeExactly 'allstaff@newco.com'
    }

    It 'Maps to interim addresses with -UseInterim' {
        $interimMap = Get-MigrationPlanAddressMap -Rows $script:planRows -UseInterim
        $interimMap['jsmith@contoso.com'] | Should -BeExactly 'john.smith@newco.onmicrosoft.com'
        $interimMap['accounts@contoso.com'] | Should -BeExactly 'accounts@newco.onmicrosoft.com'
    }

    It 'Leaves an address that is not in the plan out of the map' {
        $script:addressMap.ContainsKey('gone@contoso.com') | Should -BeFalse
    }
}

Describe 'New-MigrationRecipients - member mapping' {

    It 'Maps the members it can and reports the ones it cannot' {
        $members = Resolve-MappedAddressList -Value $script:groupRows[0].Members -Map $script:addressMap
        $members.Mapped | Should -Be @('john.smith@newco.com', 'alice.dean@newco.com')
        $members.Unmapped | Should -Be @('gone@contoso.com')
    }

    It 'Never falls back to the source address for an unmappable member' {
        $members = Resolve-MappedAddressList -Value 'gone@contoso.com' -Map $script:addressMap
        $members.Mapped.Count | Should -Be 0
        $members.Unmapped | Should -Be @('gone@contoso.com')
    }

    It 'Resolves a single address and returns empty for an unknown one' {
        (Resolve-MigrationPlanAddress -Map $script:addressMap -Address 'JSmith@Contoso.com').Address |
            Should -BeExactly 'john.smith@newco.com'
        (Resolve-MigrationPlanAddress -Map $script:addressMap -Address 'smtp:ap@contoso.com').Address |
            Should -BeExactly 'accounts@newco.com'
        (Resolve-MigrationPlanAddress -Map $script:addressMap -Address 'nobody@contoso.com').Address |
            Should -BeExactly ''
    }
}

Describe 'New-MigrationRecipients - group settings diff' {

    BeforeAll {
        $script:desired = ConvertTo-GroupSettingState -InputObject $script:groupRows[0] `
            -BooleanSetting $script:booleanGroupSetting -TextSetting $script:textGroupSetting `
            -AddressSetting $script:addressGroupSetting -Map $script:addressMap
    }

    It 'Reads the inventory spelling of each setting' {
        $script:desired.Settings['RequireSenderAuthenticationEnabled'] | Should -BeTrue
        $script:desired.Settings['HiddenFromAddressListsEnabled'] | Should -BeFalse
        $script:desired.Settings['MemberJoinRestriction'] | Should -BeExactly 'Closed'
        $script:desired.Settings['AcceptMessagesOnlyFromSendersOrMembers'] | Should -Be @('alice.dean@newco.com')
        $script:desired.Settings['ManagedBy'] | Should -Be @('john.smith@newco.com')
        $script:desired.Settings['ReportToManagerEnabled'] | Should -BeFalse
    }

    It 'Leaves a setting the inventory says nothing about out of the desired state' {
        $script:desired.Settings.Contains('ModeratedBy') | Should -BeFalse
        $script:desired.Settings.Contains('GrantSendOnBehalfTo') | Should -BeFalse
    }

    It 'Treats everything as a change against a group that does not exist yet' {
        $changes = Get-GroupSettingChange -Desired $script:desired.Settings -Current @{}
        @($changes.Keys | Sort-Object) | Should -Be @('AcceptMessagesOnlyFromSendersOrMembers', 'HiddenFromAddressListsEnabled',
            'ManagedBy', 'MemberDepartRestriction', 'MemberJoinRestriction', 'ModerationEnabled', 'ReportToManagerEnabled',
            'RequireSenderAuthenticationEnabled')
    }

    It 'Returns only what actually differs from the destination group' {
        $current = ConvertTo-GroupSettingState -InputObject ([pscustomobject]@{
                HiddenFromAddressListsEnabled          = $false
                RequireSenderAuthenticationEnabled     = $false
                ModerationEnabled                      = $false
                ReportToManagerEnabled                 = $false
                MemberJoinRestriction                  = 'Closed'
                MemberDepartRestriction                = 'Open'
                ManagedBy                              = @('john.smith@newco.com')
                AcceptMessagesOnlyFromSendersOrMembers = @('alice.dean@newco.com')
            }) -BooleanSetting $script:booleanGroupSetting -TextSetting $script:textGroupSetting `
            -AddressSetting $script:addressGroupSetting

        $changes = Get-GroupSettingChange -Desired $script:desired.Settings -Current $current.Settings
        @($changes.Keys) | Should -Be @('RequireSenderAuthenticationEnabled')
        $changes['RequireSenderAuthenticationEnabled'] | Should -BeTrue
    }

    It 'Reports nothing to do when the destination already matches' {
        $changes = Get-GroupSettingChange -Desired $script:desired.Settings -Current $script:desired.Settings
        $changes.Count | Should -Be 0
    }

    It 'Does not treat a reordered or differently cased address list as a change' {
        $desired = ConvertTo-GroupSettingState -InputObject ([pscustomobject]@{ ManagedBy = @('a@newco.com', 'b@newco.com') }) `
            -AddressSetting @('ManagedBy')
        $current = ConvertTo-GroupSettingState -InputObject ([pscustomobject]@{ ManagedBy = @('B@newco.com', 'A@newco.com') }) `
            -AddressSetting @('ManagedBy')
        (Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings).Count | Should -Be 0
    }

    It 'Carries the unmappable owners and senders out for the results file' {
        $state = ConvertTo-GroupSettingState -InputObject ([pscustomobject]@{ ManagedBy = 'gone@contoso.com' }) `
            -AddressSetting @('ManagedBy') -Map $script:addressMap
        $state.Settings.Contains('ManagedBy') | Should -BeFalse
        $state.Unmapped | Should -Be @('ManagedBy: gone@contoso.com')
    }

    It 'Reads a single-address or empty setting under strict mode when neither -Map nor -Resolver is given' {
        # ConvertTo-AddressArray emits through the pipeline, so one address unrolls to a bare string
        # and none to $null; the caller must wrap it or .Count throws under strict mode.
        Set-StrictMode -Version Latest
        try {
            $one = ConvertTo-GroupSettingState -InputObject ([pscustomobject]@{ ManagedBy = 'solo@newco.com' }) `
                -AddressSetting @('ManagedBy')
            $one.Settings['ManagedBy'] | Should -Be @('solo@newco.com')

            $none = ConvertTo-GroupSettingState -InputObject ([pscustomobject]@{ ManagedBy = '' }) `
                -AddressSetting @('ManagedBy')
            $none.Settings.Contains('ManagedBy') | Should -BeFalse
        }
        finally { Set-StrictMode -Off }
    }

    It 'Resolves a canonical Exchange identity to an address through -Resolver, so the diff can match it' {
        $resolver = { param($id) if ($id -eq 'newco.com/Users/John Smith') { 'john.smith@newco.com' } else { [string]$id } }
        $current = ConvertTo-GroupSettingState -InputObject ([pscustomobject]@{ ManagedBy = @('newco.com/Users/John Smith') }) `
            -AddressSetting @('ManagedBy') -Resolver $resolver
        $current.Settings['ManagedBy'] | Should -Be @('john.smith@newco.com')

        $changes = Get-GroupSettingChange -Desired @{ ManagedBy = @('john.smith@newco.com') } -Current $current.Settings
        $changes.Count | Should -Be 0
    }
}

Describe 'New-MigrationRecipients - Get-PlanAliasAddress' {

    BeforeAll {
        $script:sharedRow = @($script:planRows | Where-Object { $_.ObjectType -eq 'Shared' })[0]
    }

    It 'Prefixes bare aliases and appends the X500 built from the LegacyExchangeDN' {
        $addresses = Get-PlanAliasAddress -Row $script:sharedRow -PrimaryAddress 'accounts@newco.com'
        $addresses | Should -Contain 'smtp:ap@newco.com'
        @($addresses | Where-Object { $_ -like 'X500:*' }).Count | Should -Be 1
        $addresses[-1] | Should -BeExactly ('X500:' + $script:sharedRow.LegacyExchangeDN)
    }

    It 'Never asks Exchange to add the address the object already holds as primary' {
        $row = [pscustomobject]@{ TargetAliases = 'smtp:accounts@newco.com;ap@newco.com'; SourceX500 = ''; LegacyExchangeDN = '' }
        Get-PlanAliasAddress -Row $row -PrimaryAddress 'accounts@newco.com' | Should -Be @('smtp:ap@newco.com')
    }

    It 'Prefers an explicit SourceX500 over rebuilding one' {
        $row = [pscustomobject]@{ TargetAliases = ''; SourceX500 = 'X500:/o=Old'; LegacyExchangeDN = '/o=Ignored' }
        Get-PlanAliasAddress -Row $row -PrimaryAddress 'a@newco.com' | Should -Be @('X500:/o=Old')
    }

    It 'Returns nothing when the row has no aliases and no legacy DN' {
        $row = [pscustomobject]@{ TargetAliases = ''; SourceX500 = ''; LegacyExchangeDN = '' }
        @(Get-PlanAliasAddress -Row $row -PrimaryAddress 'a@newco.com').Count | Should -Be 0
    }
}

Describe 'New-MigrationRecipients - inventory lookup' {

    It 'Finds the inventory row for a plan row by its source primary SMTP address' {
        $index = Get-CsvIndex -Rows $script:groupRows -KeyColumn 'PrimarySmtpAddress', 'DisplayName'
        $planRow = @($script:planRows | Where-Object { $_.ObjectType -eq 'Distribution' })[0]
        $found = Find-IndexedRow -Row $planRow -Index $index
        $found | Should -Not -BeNullOrEmpty
        $found.DisplayName | Should -BeExactly 'All Staff'
    }

    It 'Returns nothing when the inventory has no row for the plan row' {
        $index = Get-CsvIndex -Rows $script:groupRows -KeyColumn 'PrimarySmtpAddress'
        $planRow = @($script:planRows | Where-Object { $_.ObjectType -eq 'Shared' })[0]
        Find-IndexedRow -Row $planRow -Index $index | Should -BeNullOrEmpty
    }
}

Describe 'New-MigrationRecipients - Resolve-ContactExternalAddress' {

    It 'Prefers the ExternalEmailAddress from the Contacts inventory' {
        $planRow = [pscustomobject]@{
            SourceUserPrincipalName = 'plan@fabrikam.com'; SourcePrimarySmtp = 'auditor@contoso.com'
        }
        $inventoryRow = [pscustomobject]@{ ExternalEmailAddress = 'auditor@fabrikam.com' }
        Resolve-ContactExternalAddress -PlanRow $planRow -InventoryRow $inventoryRow |
            Should -BeExactly 'auditor@fabrikam.com'
    }

    It 'Falls back to the plan column the planner parks the external address in' {
        $planRow = [pscustomobject]@{
            SourceUserPrincipalName = 'auditor@fabrikam.com'; SourcePrimarySmtp = 'auditor@contoso.com'
        }
        Resolve-ContactExternalAddress -PlanRow $planRow -InventoryRow $null |
            Should -BeExactly 'auditor@fabrikam.com'
    }

    It 'Falls back to SourcePrimarySmtp for a hand-built plan row' {
        $planRow = [pscustomobject]@{ SourceUserPrincipalName = ''; SourcePrimarySmtp = 'auditor@fabrikam.com' }
        Resolve-ContactExternalAddress -PlanRow $planRow -InventoryRow $null |
            Should -BeExactly 'auditor@fabrikam.com'
    }

    It 'Returns nothing when no source names an address' {
        $planRow = [pscustomobject]@{ SourceUserPrincipalName = ''; SourcePrimarySmtp = '' }
        Resolve-ContactExternalAddress -PlanRow $planRow -InventoryRow $null | Should -BeNullOrEmpty
    }
}

Describe 'New-MigrationRecipients - DryRun end to end' {

    BeforeAll {
        $script:runWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Recipients-Run-$([guid]::NewGuid())"
        New-Item -Path $script:runWorkspace -ItemType Directory -Force | Out-Null

        $script:planFile = Join-Path $script:runWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:planFile
        $script:planHashBefore = (Get-FileHash -LiteralPath $script:planFile -Algorithm SHA256).Hash

        $global:recipientMutations.Clear()
        $global:recipientReads.Clear()

        & $script:scriptPath -PlanPath $script:planFile -Wave '1' `
            -GroupsCsv (Join-Path $script:fixtureRoot 'Groups.csv') `
            -OutputPath $script:runWorkspace -Verbosity Low -DryRun
        $script:runExitCode = $LASTEXITCODE

        $script:resultFile = @(Get-ChildItem -LiteralPath $script:runWorkspace -Filter 'New-Recipients-DryRun_*.csv')
        $script:rows = if ($script:resultFile.Count -eq 1) { @(Import-Csv -LiteralPath $script:resultFile[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:runWorkspace -and (Test-Path -LiteralPath $script:runWorkspace)) {
            Remove-Item -LiteralPath $script:runWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits successfully' {
        $script:runExitCode | Should -Be 0
    }

    It 'Writes exactly one DryRun results file' {
        $script:resultFile.Count | Should -Be 1
    }

    It 'Calls no creating, setting, adding or saving cmdlet' {
        $global:recipientMutations | Should -BeNullOrEmpty
    }

    It 'Still performs the read-only existence checks a real run would' {
        @($global:recipientReads | Where-Object { $_ -like 'Get-Recipient*' }).Count | Should -BeGreaterThan 0
    }

    It 'Leaves the plan file byte-for-byte unchanged and takes no backup' {
        (Get-FileHash -LiteralPath $script:planFile -Algorithm SHA256).Hash | Should -BeExactly $script:planHashBefore
        Test-Path -LiteralPath "$($script:planFile).bak" | Should -BeFalse
    }

    It 'Reports every row as Planned or Skipped, never Succeeded or Failed' {
        $script:rows.Count | Should -BeGreaterThan 0
        @($script:rows | Where-Object { $_.Status -notin @('Planned', 'Skipped') }).Count | Should -Be 0
    }

    It 'Plans a creation for the shared mailbox and the distribution list' {
        $planned = @($script:rows | Where-Object { $_.Action -eq 'CreateRecipient' -and $_.Status -eq 'Planned' })
        @($planned | ForEach-Object { $_.ObjectType } | Sort-Object) | Should -Be @('Distribution', 'Shared')
        $planned[0].Detail | Should -Match 'Would create'
    }

    It 'Names the destination address each recipient would be created on' {
        $row = @($script:rows | Where-Object { $_.Identity -eq 'allstaff@contoso.com' -and $_.Action -eq 'CreateRecipient' })[0]
        $row.TargetAddress | Should -BeExactly 'allstaff@newco.com'
    }

    It 'Skips a row whose plan status is not actionable' {
        $row = @($script:rows | Where-Object { $_.ObjectType -eq 'Contact' })[0]
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match "PlanStatus is 'NeedsReview'"
    }

    It 'Leaves user rows to New-MigrationUsers' {
        @($script:rows | Where-Object { $_.ObjectType -eq 'User' }).Count | Should -Be 0
    }

    It 'Plans the settings pass for each recipient it would create' {
        @($script:rows | Where-Object { $_.Action -eq 'UpdateSettings' -and $_.Status -eq 'Planned' }).Count | Should -Be 2
    }
}

Describe 'New-MigrationRecipients - a declined confirmation is a Skip, not a Plan' {

    BeforeAll {
        $script:whatIfWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Recipients-WhatIf-$([guid]::NewGuid())"
        New-Item -Path $script:whatIfWorkspace -ItemType Directory -Force | Out-Null

        $script:whatIfPlan = Join-Path $script:whatIfWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:whatIfPlan

        $global:recipientMutations.Clear()
        $global:recipientReads.Clear()

        & $script:scriptPath -PlanPath $script:whatIfPlan -Wave '1' `
            -GroupsCsv (Join-Path $script:fixtureRoot 'Groups.csv') `
            -OutputPath $script:whatIfWorkspace -Verbosity Low -WhatIf
        $script:whatIfExitCode = $LASTEXITCODE

        $script:whatIfFile = @(Get-ChildItem -LiteralPath $script:whatIfWorkspace -Filter 'New-Recipients-Results_*.csv')
        $script:whatIfRows = if ($script:whatIfFile.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:whatIfFile[0].FullName)
        }
        else { @() }
    }

    AfterAll {
        if ($script:whatIfWorkspace -and (Test-Path -LiteralPath $script:whatIfWorkspace)) {
            Remove-Item -LiteralPath $script:whatIfWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Writes a Results file, not a DryRun file, because -WhatIf is not a rehearsal' {
        $script:whatIfFile.Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:whatIfWorkspace -Filter 'New-Recipients-DryRun_*.csv').Count | Should -Be 0
    }

    It 'Reports the declined creations as Skipped rather than Planned or Succeeded' {
        $declined = @($script:whatIfRows |
            Where-Object { $_.Action -eq 'CreateRecipient' -and $_.Detail -eq 'Declined at the confirmation prompt.' })
        $declined.Count | Should -BeGreaterThan 0
        @($declined | Where-Object { $_.Status -ne 'Skipped' }).Count | Should -Be 0
    }

    It 'Leaves no row claiming an outcome the tenant never saw' {
        @($script:whatIfRows | Where-Object { $_.Status -in @('Planned', 'Succeeded') }).Count | Should -Be 0
    }

    It 'Creates nothing' {
        $global:recipientMutations | Should -BeNullOrEmpty
    }
}

Describe 'New-MigrationRecipients - a fatal error still leaves the plan and the results file' {

    BeforeAll {
        # Test-MigrationPlanRowActionable is called outside the per-row try, so throwing from it is
        # the cheapest way to reach the script's top-level catch. Shadowing it here keeps the
        # failure inside this Describe.
        function Test-MigrationPlanRowActionable {
            param($Row, [switch]$IncludeCollisions, [switch]$AllowSynced, [string[]]$SupportedObjectType, $IsSynced)
            if ((Get-MigrationCsvValue -Row $Row -Name 'SourcePrimarySmtp' -Default '') -eq 'allstaff@contoso.com') {
                throw 'The Exchange Online session dropped between rows.'
            }
            return [pscustomobject]@{ Actionable = $true; Status = 'Planned'; Reason = '' }
        }

        $script:fatalWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Recipients-Fatal-$([guid]::NewGuid())"
        New-Item -Path $script:fatalWorkspace -ItemType Directory -Force | Out-Null

        $script:fatalPlan = Join-Path $script:fatalWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:fatalPlan

        $global:recipientMutations.Clear()
        $global:recipientReads.Clear()

        & $script:scriptPath -PlanPath $script:fatalPlan -Wave '1' `
            -GroupsCsv (Join-Path $script:fixtureRoot 'Groups.csv') `
            -OutputPath $script:fatalWorkspace -Verbosity Low
        $script:fatalExitCode = $LASTEXITCODE

        $script:fatalFile = @(Get-ChildItem -LiteralPath $script:fatalWorkspace -Filter 'New-Recipients-Results_*.csv')
        $script:fatalRows = if ($script:fatalFile.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:fatalFile[0].FullName)
        }
        else { @() }
    }

    AfterAll {
        if ($script:fatalWorkspace -and (Test-Path -LiteralPath $script:fatalWorkspace)) {
            Remove-Item -LiteralPath $script:fatalWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits 1' {
        $script:fatalExitCode | Should -Be 1
    }

    It 'Logs the failure as an error' {
        $log = @(Get-ChildItem -LiteralPath $script:fatalWorkspace -Filter 'New-MigrationRecipients_*.log')
        $log.Count | Should -Be 1
        (Get-Content -LiteralPath $log[0].FullName -Raw) |
            Should -Match '\[ERROR\].*The Exchange Online session dropped between rows'
    }

    It 'Writes exactly one results file, carrying the rows processed before the failure' {
        $script:fatalFile.Count | Should -Be 1
        $script:fatalRows.Count | Should -BeGreaterThan 0
    }

    It 'Still writes the plan back so nothing the run recorded is lost' {
        @($global:recipientMutations | Where-Object { $_ -like 'Save-MigrationPlan*' }).Count | Should -Be 1
    }
}

Describe 'New-MigrationRecipients - a declined UpdateSettings confirmation makes no Exchange call' {

    BeforeAll {
        # An adopted recipient with the right type and target address, so the row reaches the
        # settings phase instead of being turned away by the type/name adoption guard.
        function Get-Recipient {
            param([string]$Identity, [string]$ErrorAction)
            $global:recipientReads.Add("Get-Recipient $Identity")
            if ($Identity -eq 'allstaff@newco.com') {
                return @([pscustomobject]@{
                        PrimarySmtpAddress       = 'allstaff@newco.com'
                        ExternalDirectoryObjectId = 'dl-object-id'
                        RecipientTypeDetails      = 'MailUniversalDistributionGroup'
                        DisplayName               = 'All Staff'
                    })
            }
            return @()
        }

        $script:updateSettingsWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Recipients-UpdateSettingsWhatIf-$([guid]::NewGuid())"
        New-Item -Path $script:updateSettingsWorkspace -ItemType Directory -Force | Out-Null

        $script:updateSettingsPlan = Join-Path $script:updateSettingsWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:updateSettingsPlan

        $global:recipientMutations.Clear()
        $global:recipientReads.Clear()

        & $script:scriptPath -PlanPath $script:updateSettingsPlan -Wave '1' -Type Distribution -Mode UpdateSettings `
            -GroupsCsv (Join-Path $script:fixtureRoot 'Groups.csv') `
            -OutputPath $script:updateSettingsWorkspace -Verbosity Low -WhatIf
        $script:updateSettingsExitCode = $LASTEXITCODE

        $script:updateSettingsFile = @(Get-ChildItem -LiteralPath $script:updateSettingsWorkspace -Filter 'New-Recipients-Results_*.csv')
        $script:updateSettingsRows = if ($script:updateSettingsFile.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:updateSettingsFile[0].FullName)
        }
        else { @() }
    }

    AfterAll {
        if ($script:updateSettingsWorkspace -and (Test-Path -LiteralPath $script:updateSettingsWorkspace)) {
            Remove-Item -LiteralPath $script:updateSettingsWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits successfully' {
        $script:updateSettingsExitCode | Should -Be 0
    }

    It 'Reports the row as Skipped, not Succeeded' {
        $row = @($script:updateSettingsRows | Where-Object { $_.Action -eq 'UpdateSettings' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -BeExactly 'Skipped'
        $row[0].Detail | Should -BeExactly 'Declined at the confirmation prompt.'
    }

    It 'Calls no Exchange write cmdlet - the alias, settings and member steps never ran' {
        $global:recipientMutations | Should -BeNullOrEmpty
    }
}

Describe 'New-MigrationRecipients - a mail contact is created with PrimarySmtpAddress set' {

    BeforeAll {
        $script:contactWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Recipients-Contact-$([guid]::NewGuid())"
        New-Item -Path $script:contactWorkspace -ItemType Directory -Force | Out-Null

        # A lone Contact row with an actionable PlanStatus - the shared fixture's Contact row is
        # deliberately NeedsReview, so this test builds its own single-row plan rather than
        # disturbing the counts other Describes assert on the shared fixture.
        $script:contactPlan = Join-Path $script:contactWorkspace 'IdentityPlan.csv'
        $contactRow = @($script:planRows | Where-Object { $_.ObjectType -eq 'Contact' })[0].PSObject.Copy()
        $contactRow.PlanStatus = 'Planned'
        $contactRow | Export-Csv -LiteralPath $script:contactPlan -NoTypeInformation

        $global:recipientMutations.Clear()
        $global:recipientReads.Clear()

        & $script:scriptPath -PlanPath $script:contactPlan -Wave '1' -Type Contact -Mode Create `
            -OutputPath $script:contactWorkspace -Verbosity Low
        $script:contactExitCode = $LASTEXITCODE
    }

    AfterAll {
        if ($script:contactWorkspace -and (Test-Path -LiteralPath $script:contactWorkspace)) {
            Remove-Item -LiteralPath $script:contactWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits successfully' {
        $script:contactExitCode | Should -Be 0
    }

    It 'Creates the contact with its own target address as PrimarySmtpAddress, not just ExternalEmailAddress' {
        $call = @($global:recipientMutations | Where-Object { $_ -like 'New-MailContact*' })
        $call.Count | Should -Be 1
        $call[0] | Should -Match 'PrimarySmtpAddress=auditor@newco\.com'
        $call[0] | Should -Match 'ExternalEmailAddress=auditor@fabrikam\.com'
    }
}

Describe 'New-MigrationRecipients - a mismatched -TenantId stops the run before any row' {

    BeforeAll {
        function Connect-MigrationExchange {
            param([string]$DelegatedOrganization, [switch]$Reconnect)
            return [pscustomobject]@{ Organization = 'contoso.onmicrosoft.com'; TenantId = 'contoso-tenant-id' }
        }

        $script:wrongTenantWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Recipients-WrongTenant-$([guid]::NewGuid())"
        New-Item -Path $script:wrongTenantWorkspace -ItemType Directory -Force | Out-Null

        $script:wrongTenantPlan = Join-Path $script:wrongTenantWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:wrongTenantPlan

        $global:recipientMutations.Clear()
        $global:recipientReads.Clear()

        & $script:scriptPath -PlanPath $script:wrongTenantPlan -Wave '1' -TenantId 'newco.onmicrosoft.com' `
            -OutputPath $script:wrongTenantWorkspace -Verbosity Low -DryRun
        $script:wrongTenantExitCode = $LASTEXITCODE
    }

    AfterAll {
        if ($script:wrongTenantWorkspace -and (Test-Path -LiteralPath $script:wrongTenantWorkspace)) {
            Remove-Item -LiteralPath $script:wrongTenantWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits 1 without touching any row' {
        $script:wrongTenantExitCode | Should -Be 1
        $global:recipientReads | Should -BeNullOrEmpty
    }

    It 'Logs which organisation it connected to instead' {
        $log = @(Get-ChildItem -LiteralPath $script:wrongTenantWorkspace -Filter 'New-MigrationRecipients_*.log')
        $log.Count | Should -Be 1
        (Get-Content -LiteralPath $log[0].FullName -Raw) | Should -Match "contoso\.onmicrosoft\.com.*-TenantId asked for 'newco\.onmicrosoft\.com'"
    }
}

Describe 'New-MigrationRecipients - an alias hit with a mismatched type is not adopted' {

    BeforeAll {
        # 'allstaff' (the alias) resolves to an unrelated shared mailbox that happens to share the
        # nickname - a SharedMailbox is not a MailUniversalDistributionGroup, so the row must fail
        # rather than record that object as this row's TargetObjectId.
        function Get-Recipient {
            param([string]$Identity, [string]$ErrorAction)
            $global:recipientReads.Add("Get-Recipient $Identity")
            if ($Identity -eq 'allstaff') {
                return @([pscustomobject]@{
                        PrimarySmtpAddress       = 'allstaff@newco.com'
                        ExternalDirectoryObjectId = 'wrong-type-object-id'
                        RecipientTypeDetails      = 'SharedMailbox'
                        DisplayName               = 'Some Other Mailbox'
                    })
            }
            return @()
        }

        $script:typeMismatchWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Recipients-TypeMismatch-$([guid]::NewGuid())"
        New-Item -Path $script:typeMismatchWorkspace -ItemType Directory -Force | Out-Null

        $script:typeMismatchPlan = Join-Path $script:typeMismatchWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:typeMismatchPlan

        $global:recipientMutations.Clear()
        $global:recipientReads.Clear()

        & $script:scriptPath -PlanPath $script:typeMismatchPlan -Wave '1' -Type Distribution -Mode UpdateSettings `
            -GroupsCsv (Join-Path $script:fixtureRoot 'Groups.csv') `
            -OutputPath $script:typeMismatchWorkspace -Verbosity Low
        $script:typeMismatchExitCode = $LASTEXITCODE

        $script:typeMismatchFile = @(Get-ChildItem -LiteralPath $script:typeMismatchWorkspace -Filter 'New-Recipients-Results_*.csv')
        $script:typeMismatchRows = if ($script:typeMismatchFile.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:typeMismatchFile[0].FullName)
        }
        else { @() }
    }

    AfterAll {
        if ($script:typeMismatchWorkspace -and (Test-Path -LiteralPath $script:typeMismatchWorkspace)) {
            Remove-Item -LiteralPath $script:typeMismatchWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Fails the row instead of adopting the mismatched object' {
        $row = @($script:typeMismatchRows | Where-Object { $_.Identity -eq 'allstaff@contoso.com' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -BeExactly 'Failed'
        $row[0].Detail | Should -Match 'not the Distribution type'
    }

    It 'Calls no Exchange write cmdlet - only the plan write-back records the failure' {
        @($global:recipientMutations | Where-Object { $_ -notlike 'Save-MigrationPlan*' }) | Should -BeNullOrEmpty
    }
}
