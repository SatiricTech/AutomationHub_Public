#Requires -Version 7.4

<#
    Adversarial tests for New-MigrationIdentityPlan.ps1.

    The happy-path suite lives in New-MigrationIdentityPlan.Tests.ps1. This file exists to
    break the planner: names no template was written for, templates with typos in them,
    collisions that cannot be resolved, inventories with duplicated rows, and operator
    files that are subtly wrong. Every case is offline - the fixtures under
    Fixtures/New-MigrationIdentityPlan-Adversarial are read for real and the plan is
    written into TestDrive.

    The fixtures carry the non-ASCII names on purpose; this file stays ASCII so that the
    expectations read as the addresses an operator would see.

    Author: AutomationHub
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:PlanScript = (Resolve-Path (Join-Path $PSScriptRoot '..' 'New-MigrationIdentityPlan.ps1')).ProviderPath
    $script:Fixtures = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'New-MigrationIdentityPlan-Adversarial')).ProviderPath
    $script:ActionableStatuses = @('Planned', 'ManualOverride', 'UpnSmtpDiverge', 'Collision')

    function Invoke-AdversarialPlan {
        <#
        .SYNOPSIS
            Runs the planner into a fresh directory and returns the plan and the log.
        .DESCRIPTION
            Every run gets its own directory so that a failed run - which writes no plan -
            is told apart from the run before it, and so the log can be read back to check
            what the planner warned about.
        .PARAMETER Name
            A directory name under TestDrive for this run.
        .PARAMETER Parameter
            Extra or overriding parameters for the script. -UsersCsv defaults to Names.csv.
        .EXAMPLE
            Invoke-AdversarialPlan -Name 'names'
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,

            [hashtable]$Parameter = @{}
        )

        $outputPath = Join-Path $TestDrive $Name
        if (-not (Test-Path -LiteralPath $outputPath)) {
            $null = New-Item -Path $outputPath -ItemType Directory -Force
        }

        $splat = @{
            UsersCsv     = (Join-Path $script:Fixtures 'Names.csv')
            TargetDomain = 'newco.com'
            OutputPath   = $outputPath
            Verbosity    = 'Low'
        }
        foreach ($key in $Parameter.Keys) { $splat[$key] = $Parameter[$key] }

        & $script:PlanScript @splat 6>$null
        $exitCode = $LASTEXITCODE

        $planFiles = @(Get-ChildItem -Path $outputPath -Filter 'IdentityPlan_*.csv' -ErrorAction SilentlyContinue)
        $logFiles = @(Get-ChildItem -Path $outputPath -Filter '*.log' -ErrorAction SilentlyContinue)

        [pscustomobject]@{
            ExitCode = $exitCode
            Path     = if ($planFiles.Count -gt 0) { $planFiles[0].FullName } else { '' }
            Rows     = if ($planFiles.Count -gt 0) { @(Import-Csv -LiteralPath $planFiles[0].FullName -Encoding utf8) } else { @() }
            Log      = if ($logFiles.Count -gt 0) { (Get-Content -LiteralPath $logFiles[0].FullName -Raw -Encoding utf8) } else { '' }
        }
    }

    function Get-AdversarialRow {
        <#
        .SYNOPSIS
            Finds one plan row by any of its source addresses or its display name.
        .PARAMETER Result
            The object returned by Invoke-AdversarialPlan.
        .PARAMETER Identity
            The source UPN, source primary SMTP address or display name to look for.
        .EXAMPLE
            Get-AdversarialRow -Result $plan -Identity 'zoneil@contoso.com'
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

    function Get-AdversarialAddressMap {
        <#
        .SYNOPSIS
            Reduces a plan to a sorted 'source = target UPN / target SMTP' list.
        .DESCRIPTION
            Row order follows the inventory, so comparing two runs means comparing what
            each source object was named rather than which line it landed on.
        .PARAMETER Result
            The object returned by Invoke-AdversarialPlan.
        .EXAMPLE
            Get-AdversarialAddressMap -Result $plan
        #>
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNull()]
            $Result
        )

        [string[]]@($Result.Rows |
                ForEach-Object { '{0}={1}/{2}' -f $_.SourceUserPrincipalName, $_.TargetUserPrincipalName, $_.TargetPrimarySmtp } |
                Sort-Object)
    }
}

Describe 'New-MigrationIdentityPlan - hostile source names' {

    BeforeAll {
        $script:Names = Invoke-AdversarialPlan -Name 'names' -Parameter @{
            SkuMapPath = (Join-Path $script:Fixtures 'SkuMap.csv')
        }
    }

    It 'completes the run' {
        $script:Names.ExitCode | Should -Be 0
        $script:Names.Rows.Count | Should -Be 18
    }

    It 'names <Identity> as <Expected>' -ForEach @(
        @{ Identity = 'zoneil@contoso.com'; Expected = 'zoe.oneil-swiatek@newco.com' }
        @{ Identity = 'mconsuelo@contoso.com'; Expected = 'maconsuelo.delacruzjr@newco.com' }
        @{ Identity = 'jpsmith@contoso.com'; Expected = 'johnpaul.smith@newco.com' }
        @{ Identity = 'jdoe@contoso.com'; Expected = 'johntestcontosocom.doe@newco.com' }
        @{ Identity = 'r2unit@contoso.com'; Expected = 'r2.d2unit@newco.com' }
        @{ Identity = 'isik@contoso.com'; Expected = 'isik.istanbullu@newco.com' }
        @{ Identity = 'hweiss@contoso.com'; Expected = 'hans.weiss@newco.com' }
        @{ Identity = 'bjorn@contoso.com'; Expected = 'bjorn.hakonsson@newco.com' }
        @{ Identity = 'lcoeur@contoso.com'; Expected = 'loetitia.coeur@newco.com' }
        @{ Identity = 'thor@contoso.com'; Expected = 'thor.thorlaksson@newco.com' }
        @{ Identity = 'nguyen@contoso.com'; Expected = 'nguyen.dang@newco.com' }
        @{ Identity = 'erocket@contoso.com'; Expected = 'emma.rocket@newco.com' }
        @{ Identity = 'dnewco@contoso.com'; Expected = 'dana.newcocom@newco.com' }
        @{ Identity = 'ivan@contoso.com'; Expected = 'ivan.ivan@newco.com' }
    ) {
        $row = Get-AdversarialRow -Result $script:Names -Identity $Identity
        $row.TargetUserPrincipalName | Should -BeExactly $Expected
        $row.PlanStatus | Should -BeExactly 'Planned'
    }

    It 'sends a surname of "-" to review instead of dropping it from the address' {
        $row = Get-AdversarialRow -Result $script:Names -Identity 'dashiell@contoso.com'
        $row.PlanStatus | Should -BeExactly 'NeedsReview'
        $row.PlanDetail | Should -BeLike '*missing: last*'
        $row.TargetUserPrincipalName | Should -BeExactly ''
        $row.TargetPrimarySmtp | Should -BeExactly ''
    }

    It 'sends a name written only in Han characters to review' {
        $row = Get-AdversarialRow -Result $script:Names -Identity 'liming@contoso.com'
        $row.PlanStatus | Should -BeExactly 'NeedsReview'
        $row.PlanDetail | Should -BeLike '*missing: first, last*'
    }

    It 'marks a 70-character surname Invalid rather than truncating it' {
        $row = Get-AdversarialRow -Result $script:Names -Identity 'allong@contoso.com'
        $row.PlanStatus | Should -BeExactly 'Invalid'
        $row.TargetUserPrincipalName | Should -BeExactly ('al.wolfeschlegelsteinhausenbergerdorff' +
            'vonundzuhohenzollernsigmaringenbach@newco.com')
        $row.PlanDetail | Should -BeLike '*73 characters*'
    }

    It 'leaves no non-ASCII character in any address it built' {
        $addresses = @($script:Names.Rows |
                ForEach-Object { $_.TargetUserPrincipalName, $_.TargetPrimarySmtp, $_.TargetMailNickname } |
                Where-Object { $_ })
        $addresses.Count | Should -BeGreaterThan 0
        @($addresses | Where-Object { $_ -match '[^\x20-\x7e]' }) | Should -BeNullOrEmpty
    }

    It 'maps one source SKU to two targets, drops a blank target and carries an unmapped one through' {
        $row = Get-AdversarialRow -Result $script:Names -Identity 'zoneil@contoso.com'
        $row.TargetLicenses | Should -BeExactly 'SPE_E3;MCOEV;MCOMEETADV;FLOW_FREE'
        $row.PlanDetail | Should -BeLike '*No SKU mapping for FLOW_FREE*'
        $row.PlanDetail | Should -BeLike '*drops POWER_BI_STANDARD*'
    }
}

Describe 'New-MigrationIdentityPlan - naming templates' {

    It 'drops an empty middle token and its separator' {
        $result = Invoke-AdversarialPlan -Name 'tpl-middle' -Parameter @{ UpnFormat = '{first}.{m}.{last}' }
        $result.ExitCode | Should -Be 0
        (Get-AdversarialRow -Result $result -Identity 'ivan@contoso.com').TargetUserPrincipalName |
            Should -BeExactly 'ivan.ivan@newco.com'
    }

    It 'suffixes the truncated {f}{last:3} forms of Smith, Smithson and Smithers' {
        $result = Invoke-AdversarialPlan -Name 'tpl-trunc' -Parameter @{
            UsersCsv  = (Join-Path $script:Fixtures 'Collisions.csv')
            UpnFormat = '{f}{last:3}'
        }
        (Get-AdversarialRow -Result $result -Identity 'ssmith@contoso.com').TargetUserPrincipalName |
            Should -BeExactly 'ssmi@newco.com'
        (Get-AdversarialRow -Result $result -Identity 'ssmithson@contoso.com').TargetUserPrincipalName |
            Should -BeExactly 'ssmi2@newco.com'
        (Get-AdversarialRow -Result $result -Identity 'ssmithers@contoso.com').TargetUserPrincipalName |
            Should -BeExactly 'ssmi3@newco.com'
    }

    It 'honours the Last.First preset' {
        $result = Invoke-AdversarialPlan -Name 'tpl-lastfirst' -Parameter @{
            UsersCsv  = (Join-Path $script:Fixtures 'Collisions.csv')
            UpnFormat = 'Last.First'
        }
        (Get-AdversarialRow -Result $result -Identity 'ssmith@contoso.com').TargetUserPrincipalName |
            Should -BeExactly 'smith.sam@newco.com'
    }

    It 'keeps a source local part with dots and a plus for SMTP and refuses it as a UPN' {
        $result = Invoke-AdversarialPlan -Name 'tpl-keep' -Parameter @{ UpnFormat = 'Keep' }
        $row = Get-AdversarialRow -Result $result -Identity 'john+test.q@contoso.com'
        $row.TargetPrimarySmtp | Should -BeExactly 'john+test.q@newco.com'
        (Test-MigrationAddress -Address $row.TargetPrimarySmtp -Kind Smtp).IsValid | Should -BeTrue
        $row.PlanStatus | Should -BeExactly 'Invalid'
        $row.PlanDetail | Should -BeLike "*TargetUserPrincipalName 'john+test.q@newco.com'*"
    }

    It 'refuses a template with an unknown token instead of writing it into the address' {
        $result = Invoke-AdversarialPlan -Name 'tpl-unknown' -Parameter @{ UpnFormat = '{first}.{nick}' }
        $result.ExitCode | Should -Be 1
        $result.Path | Should -BeExactly ''
        $result.Log | Should -BeLike '*unknown token(s) {nick}*'
        $result.Log | Should -BeLike '*Known tokens:*'
    }

    It 'refuses a literal-only template that is not a preset' {
        $result = Invoke-AdversarialPlan -Name 'tpl-literal' -Parameter @{ UpnFormat = 'reception' }
        $result.ExitCode | Should -Be 1
        $result.Path | Should -BeExactly ''
        $result.Log | Should -BeLike "*'reception' is neither a token template nor a known preset*"
        $result.Log | Should -BeLike '*First.Last*'
    }

    It 'marks a row UpnSmtpDiverge when -SmtpFormat differs from -UpnFormat' {
        $result = Invoke-AdversarialPlan -Name 'tpl-diverge' -Parameter @{
            UpnFormat  = 'FLast'
            SmtpFormat = 'First.Last'
        }
        $row = Get-AdversarialRow -Result $result -Identity 'ivan@contoso.com'
        $row.TargetUserPrincipalName | Should -BeExactly 'iivan@newco.com'
        $row.TargetPrimarySmtp | Should -BeExactly 'ivan.ivan@newco.com'
        $row.PlanStatus | Should -BeExactly 'UpnSmtpDiverge'
    }

    It 'derives the mail nickname from the SMTP local part the collision resolver settled on' {
        $result = Invoke-AdversarialPlan -Name 'tpl-nickname-default' -Parameter @{
            UsersCsv = (Join-Path $script:Fixtures 'Collisions.csv')
        }
        $row = Get-AdversarialRow -Result $result -Identity 'alex3@contoso.com'
        $row.TargetPrimarySmtp | Should -BeExactly 'alex.name2@newco.com'
        $row.TargetMailNickname | Should -BeExactly 'alex.name2'
    }

    It 'flags a -MailNicknameFormat that gives two people the same nickname' {
        $result = Invoke-AdversarialPlan -Name 'tpl-nickname-dup' -Parameter @{
            UsersCsv           = (Join-Path $script:Fixtures 'Collisions.csv')
            MailNicknameFormat = '{f}{last}'
        }
        $firstRow = Get-AdversarialRow -Result $result -Identity 'alex1@contoso.com'
        $firstRow.PlanStatus | Should -BeExactly 'Planned'
        $row = Get-AdversarialRow -Result $result -Identity 'alex3@contoso.com'
        $row.TargetMailNickname | Should -BeExactly 'aname3'
        $row.PlanStatus | Should -BeExactly 'Collision'
        $row.PlanDetail | Should -BeLike "*Mail nickname 'aname' is already used by alex1@contoso.com*"
        $firstRow.TargetMailNickname | Should -Not -BeExactly $row.TargetMailNickname
    }
}

Describe 'New-MigrationIdentityPlan - collisions' {

    BeforeAll {
        $script:CollisionParameters = @{
            UsersCsv              = (Join-Path $script:Fixtures 'Collisions.csv')
            SharedMailboxesCsv    = (Join-Path $script:Fixtures 'SharedMailboxes.csv')
            ReservedAddressesPath = (Join-Path $script:Fixtures 'Reserved-MixedCase.csv')
        }
        $script:Collisions = Invoke-AdversarialPlan -Name 'collisions' -Parameter $script:CollisionParameters
    }

    It 'gives the middle-initial form to the duplicates that have one and numbers the rest' {
        $expected = @{
            'alex1@contoso.com' = 'alex.name@newco.com'
            'alex2@contoso.com' = 'alex.q.name@newco.com'
            'alex3@contoso.com' = 'alex.name2@newco.com'
            'alex4@contoso.com' = 'alex.r.name@newco.com'
            'alex5@contoso.com' = 'alex.name3@newco.com'
        }
        foreach ($identity in $expected.Keys) {
            $row = Get-AdversarialRow -Result $script:Collisions -Identity $identity
            $row.TargetUserPrincipalName | Should -BeExactly $expected[$identity] -Because "$identity is planned by SourceObjectId order"
            $row.TargetPrimarySmtp | Should -BeExactly $expected[$identity]
        }
        (Get-AdversarialRow -Result $script:Collisions -Identity 'alex1@contoso.com').PlanStatus |
            Should -BeExactly 'Planned'
        (Get-AdversarialRow -Result $script:Collisions -Identity 'alex5@contoso.com').PlanStatus |
            Should -BeExactly 'Collision'
    }

    It 'assigns the same addresses when the inventory rows are shuffled' {
        $parameter = $script:CollisionParameters.Clone()
        $parameter['UsersCsv'] = (Join-Path $script:Fixtures 'Collisions-Shuffled.csv')
        $shuffled = Invoke-AdversarialPlan -Name 'collisions-shuffled' -Parameter $parameter
        (Get-AdversarialAddressMap -Result $shuffled) | Should -Be (Get-AdversarialAddressMap -Result $script:Collisions)
    }

    It 'resolves a user against a shared mailbox holding the same local part' {
        $shared = Get-AdversarialRow -Result $script:Collisions -Identity 'ap.desk@contoso.com'
        $user = Get-AdversarialRow -Result $script:Collisions -Identity 'apdesk@contoso.com'
        $shared.TargetPrimarySmtp | Should -BeExactly 'ap.desk@newco.com'
        $user.TargetPrimarySmtp | Should -BeExactly 'ap.desk2@newco.com'
        $user.PlanStatus | Should -BeExactly 'Collision'
        $user.PlanDetail | Should -BeLike '*taken by ap.desk@contoso.com*'
    }

    It 'treats a reserved address in a different letter case as taken' {
        $row = Get-AdversarialRow -Result $script:Collisions -Identity 'casetest@contoso.com'
        $row.TargetUserPrincipalName | Should -BeExactly 'case.test2@newco.com'
        $row.PlanStatus | Should -BeExactly 'Collision'
        $row.PlanDetail | Should -BeLike '*already reserved in the destination*'
    }

    It 'sends a row to review when the suffixed form would pass 64 characters' {
        $winner = Get-AdversarialRow -Result $script:Collisions -Identity 'maxlong1@contoso.com'
        $loser = Get-AdversarialRow -Result $script:Collisions -Identity 'maxlong2@contoso.com'

        $winner.TargetUserPrincipalName.Split('@')[0].Length | Should -Be 64
        $loser.PlanStatus | Should -BeExactly 'NeedsReview'
        $loser.PlanDetail | Should -BeLike '*no free alternative was found*'
        foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'TargetMailNickname',
                'InterimUserPrincipalName', 'InterimPrimarySmtp')) {
            $loser.$column | Should -BeExactly '' -Because 'nothing may be truncated into a usable-looking address'
        }
    }

    It 'reserves an operator ManualOverride carried in from -ExistingPlanPath' {
        $existingPath = Join-Path $TestDrive 'existing-override.csv'
        # Read the plan back rather than editing the rows in memory: they belong to the run every
        # other test in this block asserts against.
        $override = @(Import-Csv -LiteralPath $script:Collisions.Path -Encoding utf8 |
                Where-Object { $_.SourceUserPrincipalName -eq 'alex2@contoso.com' })
        $override[0].PlanStatus = 'ManualOverride'
        $override[0].PlanDetail = 'Operator pinned this address.'
        foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'InterimUserPrincipalName', 'InterimPrimarySmtp')) {
            $override[0].$column = 'alex.name@newco.com'
        }
        $override[0].TargetMailNickname = 'alex.name'
        $override | Export-Csv -LiteralPath $existingPath -NoTypeInformation -Encoding utf8

        $result = Invoke-AdversarialPlan -Name 'collisions-override' -Parameter (
            $script:CollisionParameters + @{ ExistingPlanPath = $existingPath })

        $kept = Get-AdversarialRow -Result $result -Identity 'alex2@contoso.com'
        $kept.PlanStatus | Should -BeExactly 'ManualOverride'
        $kept.TargetUserPrincipalName | Should -BeExactly 'alex.name@newco.com'

        $first = Get-AdversarialRow -Result $result -Identity 'alex1@contoso.com'
        $first.TargetUserPrincipalName | Should -BeExactly 'alex.name2@newco.com'
        $first.PlanStatus | Should -BeExactly 'Collision'

        @($result.Rows | Where-Object { $_.TargetUserPrincipalName -eq 'alex.name@newco.com' }).Count | Should -Be 1
    }

    It 'plans two source rows that share an object ID separately' {
        $result = Invoke-AdversarialPlan -Name 'duplicate-ids' -Parameter @{
            UsersCsv = (Join-Path $script:Fixtures 'DuplicateIds.csv')
        }
        (Get-AdversarialRow -Result $result -Identity 'dup.one@contoso.com').TargetUserPrincipalName |
            Should -BeExactly 'dup.one@newco.com'
        (Get-AdversarialRow -Result $result -Identity 'dup.two@contoso.com').TargetUserPrincipalName |
            Should -BeExactly 'dup.two@newco.com'
        $result.Log | Should -BeLike '*share the identifier*'
    }

    It 'gives no two actionable rows the same target address' {
        foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'TargetMailNickname')) {
            $values = @($script:Collisions.Rows |
                    Where-Object { $_.PlanStatus -in $script:ActionableStatuses -and $_.$column } |
                    ForEach-Object { $_.$column.ToLowerInvariant() })
            @($values | Group-Object | Where-Object { $_.Count -gt 1 }) | Should -BeNullOrEmpty -Because "$column must be unique"
        }
    }
}

Describe 'New-MigrationIdentityPlan - guests and exclusions' {

    BeforeAll {
        $script:GuestParameters = @{ UsersCsv = (Join-Path $script:Fixtures 'Guests.csv') }
        $script:GuestUpn = 'raj_fabrikam.com#EXT#@contoso.onmicrosoft.com'
    }

    It 'leaves the target/interim UPN empty for a guest, carrying only the external mail' {
        $result = Invoke-AdversarialPlan -Name 'guests-included' -Parameter ($script:GuestParameters + @{ IncludeGuests = $true })
        $row = Get-AdversarialRow -Result $result -Identity $script:GuestUpn
        $row.ObjectType | Should -BeExactly 'Guest'
        $row.TargetUserPrincipalName | Should -BeExactly ''
        $row.InterimUserPrincipalName | Should -BeExactly ''
        $row.TargetPrimarySmtp | Should -BeExactly 'raj@fabrikam.com'
    }

    It 'excludes a guest by default' {
        $result = Invoke-AdversarialPlan -Name 'guests-excluded' -Parameter $script:GuestParameters
        $row = Get-AdversarialRow -Result $result -Identity $script:GuestUpn
        $row.PlanStatus | Should -BeExactly 'Excluded'
        $row.ExcludeReason | Should -BeExactly 'Guest account'
    }

    It 'treats a regular expression written as a wildcard rule as a literal pattern' {
        $result = Invoke-AdversarialPlan -Name 'exclude-wildcard' -Parameter ($script:GuestParameters + @{
                ExclusionRulesPath = (Join-Path $script:Fixtures 'ExclusionRules-Wildcard.csv')
            })
        (Get-AdversarialRow -Result $result -Identity 'break-glass-01@contoso.com').PlanStatus |
            Should -BeExactly 'Excluded'
        (Get-AdversarialRow -Result $result -Identity 'svc-backup@contoso.com').PlanStatus |
            Should -BeExactly 'Planned'
    }

    It 'applies the same pattern as a regular expression when MatchType is Regex' {
        $result = Invoke-AdversarialPlan -Name 'exclude-regex' -Parameter ($script:GuestParameters + @{
                ExclusionRulesPath = (Join-Path $script:Fixtures 'ExclusionRules-Regex.csv')
            })
        $row = Get-AdversarialRow -Result $result -Identity 'svc-backup@contoso.com'
        $row.PlanStatus | Should -BeExactly 'Excluded'
        $row.ExcludeReason | Should -BeExactly 'Service account matched by regular expression'
    }

    It 'fails with a readable message on an invalid regular expression' {
        $parameter = $script:GuestParameters.Clone()
        $parameter['ExclusionRulesPath'] = (Join-Path $script:Fixtures 'ExclusionRules-BadRegex.csv')
        $result = Invoke-AdversarialPlan -Name 'exclude-badregex' -Parameter $parameter

        $result.ExitCode | Should -Be 1
        $result.Path | Should -BeExactly ''
        # -match, not -BeLike: the pattern under test is itself full of wildcard metacharacters.
        $result.Log | Should -Match "invalid regular expression 'svc-\[a-z' on line 2"
        $result.Log | Should -Match 'Unterminated'
    }

    It 'excludes a directory-synced user unless -IncludeSynced is supplied' {
        $default = Invoke-AdversarialPlan -Name 'synced-default' -Parameter $script:GuestParameters
        $included = Invoke-AdversarialPlan -Name 'synced-included' -Parameter ($script:GuestParameters + @{ IncludeSynced = $true })

        (Get-AdversarialRow -Result $default -Identity 'sync.user@contoso.com').ExcludeReason |
            Should -BeExactly 'Directory-synced'
        $row = Get-AdversarialRow -Result $included -Identity 'sync.user@contoso.com'
        $row.PlanStatus | Should -BeExactly 'Planned'
        $row.IsSynced | Should -BeExactly 'True'
        $row.TargetUserPrincipalName | Should -BeExactly 'sync.user@newco.com'
    }
}

Describe 'New-MigrationIdentityPlan - waves' {

    It 'ignores a wave map entry that names nobody in the inventory and says so in the log' {
        $result = Invoke-AdversarialPlan -Name 'wave-unknown' -Parameter @{
            WaveMapPath = (Join-Path $script:Fixtures 'WaveMap.csv')
        }
        $result.ExitCode | Should -Be 0
        $result.Log | Should -BeLike '*not in the inventory*ghost@contoso.com*'
        @($result.Rows | Where-Object { $_.Wave -eq '7' }) | Should -BeNullOrEmpty
    }

    It 'keeps a wave value containing a space and trims the padding off another' {
        $result = Invoke-AdversarialPlan -Name 'wave-spaces' -Parameter @{
            WaveMapPath = (Join-Path $script:Fixtures 'WaveMap.csv')
        }
        (Get-AdversarialRow -Result $result -Identity 'zoneil@contoso.com').Wave | Should -BeExactly 'Wave 2'
        (Get-AdversarialRow -Result $result -Identity 'hweiss@contoso.com').Wave | Should -BeExactly '3'
        (Get-AdversarialRow -Result $result -Identity 'ivan@contoso.com').Wave | Should -BeExactly '1'
    }

    It 'fails with a readable message when the wave map has no Wave column' {
        $result = Invoke-AdversarialPlan -Name 'wave-nocolumn' -Parameter @{
            WaveMapPath = (Join-Path $script:Fixtures 'WaveMap-NoWaveColumn.csv')
        }
        $result.ExitCode | Should -Be 1
        $result.Log | Should -BeLike '*missing required column(s): Wave*'
    }
}

Describe 'New-MigrationIdentityPlan - SKU map' {

    It 'fails when the SKU map lists the same source SKU twice' {
        $result = Invoke-AdversarialPlan -Name 'sku-duplicate' -Parameter @{
            SkuMapPath = (Join-Path $script:Fixtures 'SkuMap-Duplicate.csv')
        }
        $result.ExitCode | Should -Be 1
        $result.Path | Should -BeExactly ''
        $result.Log | Should -BeLike "*maps 'ENTERPRISEPACK' more than once*"
    }

    It 'carries every source SKU through unchanged when no map is supplied' {
        $result = Invoke-AdversarialPlan -Name 'sku-none'
        (Get-AdversarialRow -Result $result -Identity 'zoneil@contoso.com').TargetLicenses |
            Should -BeExactly 'ENTERPRISEPACK;MCOEV;POWER_BI_STANDARD;FLOW_FREE'
        (Get-AdversarialRow -Result $result -Identity 'zoneil@contoso.com').PlanDetail |
            Should -BeExactly ''
    }
}

Describe 'New-MigrationIdentityPlan - interim domain' {

    It 'mirrors the target columns when -InterimDomain is the target domain, and warns' {
        $result = Invoke-AdversarialPlan -Name 'interim-same' -Parameter @{ InterimDomain = 'newco.com' }
        $row = Get-AdversarialRow -Result $result -Identity 'ivan@contoso.com'
        $row.InterimUserPrincipalName | Should -BeExactly $row.TargetUserPrincipalName
        $row.InterimPrimarySmtp | Should -BeExactly $row.TargetPrimarySmtp
        $result.Log | Should -BeLike '*same as -TargetDomain*'
    }

    It 'accepts an interim domain that is not a routing domain but warns about it' {
        $result = Invoke-AdversarialPlan -Name 'interim-vanity' -Parameter @{ InterimDomain = 'routing.newco.com' }
        $result.ExitCode | Should -Be 0
        (Get-AdversarialRow -Result $result -Identity 'ivan@contoso.com').InterimUserPrincipalName |
            Should -BeExactly 'ivan.ivan@routing.newco.com'
        $result.Log | Should -BeLike '*not an onmicrosoft.com routing domain*'
    }
}

Describe 'New-MigrationIdentityPlan - re-runs' {

    It 'writes the same plan twice from the same inventory' {
        $first = Invoke-AdversarialPlan -Name 'idempotent-1' -Parameter @{
            SkuMapPath  = (Join-Path $script:Fixtures 'SkuMap.csv')
            WaveMapPath = (Join-Path $script:Fixtures 'WaveMap.csv')
        }
        $second = Invoke-AdversarialPlan -Name 'idempotent-2' -Parameter @{
            SkuMapPath  = (Join-Path $script:Fixtures 'SkuMap.csv')
            WaveMapPath = (Join-Path $script:Fixtures 'WaveMap.csv')
        }
        (Get-Content -LiteralPath $second.Path -Raw -Encoding utf8) |
            Should -BeExactly (Get-Content -LiteralPath $first.Path -Raw -Encoding utf8)
    }

    It 'keeps a hand-edited target address and changes nothing else' {
        $first = Invoke-AdversarialPlan -Name 'edit-1'
        $existingPath = Join-Path $TestDrive 'existing-edited.csv'

        $rows = @(Import-Csv -LiteralPath $first.Path -Encoding utf8)
        $edited = @($rows | Where-Object { $_.SourceUserPrincipalName -eq 'zoneil@contoso.com' })[0]
        $edited.TargetUserPrincipalName = 'zoe.oneil@newco.com'
        $edited.TargetPrimarySmtp = 'zoe.oneil@newco.com'
        $edited.InterimUserPrincipalName = 'zoe.oneil@newco.com'
        $edited.InterimPrimarySmtp = 'zoe.oneil@newco.com'
        $edited.TargetMailNickname = 'zoe.oneil'
        $edited.PlanStatus = 'ManualOverride'
        $rows | Export-Csv -LiteralPath $existingPath -NoTypeInformation -Encoding utf8

        $second = Invoke-AdversarialPlan -Name 'edit-2' -Parameter @{ ExistingPlanPath = $existingPath }

        $kept = Get-AdversarialRow -Result $second -Identity 'zoneil@contoso.com'
        $kept.PlanStatus | Should -BeExactly 'ManualOverride'
        $kept.TargetUserPrincipalName | Should -BeExactly 'zoe.oneil@newco.com'
        $kept.TargetMailNickname | Should -BeExactly 'zoe.oneil'

        $describe = {
            param($Row)
            ($Row.PSObject.Properties | Sort-Object -Property Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|'
        }
        foreach ($row in $second.Rows) {
            if ($row.SourceUserPrincipalName -eq 'zoneil@contoso.com') { continue }
            $before = @($first.Rows | Where-Object { $_.SourceObjectId -eq $row.SourceObjectId })[0]
            (& $describe $row) | Should -BeExactly (& $describe $before) -Because "$($row.SourceUserPrincipalName) was not edited"
        }
    }

    It 'sends a preserved row that lost its PlanStatus to review rather than leaving it blank' {
        $first = Invoke-AdversarialPlan -Name 'blankstatus-1'
        $existingPath = Join-Path $TestDrive 'existing-blank-status.csv'

        $rows = @(Import-Csv -LiteralPath $first.Path -Encoding utf8)
        $blanked = @($rows | Where-Object { $_.SourceUserPrincipalName -eq 'ivan@contoso.com' })[0]
        $blanked.PlanStatus = ''
        $blanked.TargetObjectId = '99999999-0000-0000-0000-000000000099'
        $rows | Export-Csv -LiteralPath $existingPath -NoTypeInformation -Encoding utf8

        $second = Invoke-AdversarialPlan -Name 'blankstatus-2' -Parameter @{ ExistingPlanPath = $existingPath }
        $row = Get-AdversarialRow -Result $second -Identity 'ivan@contoso.com'
        $row.PlanStatus | Should -BeExactly 'NeedsReview'
        $row.TargetUserPrincipalName | Should -BeExactly 'ivan.ivan@newco.com'
    }
}

Describe 'New-MigrationIdentityPlan - output hygiene' {

    BeforeAll {
        $script:HygieneRuns = @(
            (Invoke-AdversarialPlan -Name 'hygiene-names' -Parameter @{
                    SharedMailboxesCsv    = (Join-Path $script:Fixtures 'SharedMailboxes.csv')
                    ReservedAddressesPath = (Join-Path $script:Fixtures 'Reserved-MixedCase.csv')
                    SkuMapPath            = (Join-Path $script:Fixtures 'SkuMap.csv')
                    WaveMapPath           = (Join-Path $script:Fixtures 'WaveMap.csv')
                    InterimDomain         = 'newco.onmicrosoft.com'
                    PreserveAliases       = $true
                    AliasDomainMap        = @{ 'contoso.com' = 'newco.com' }
                }),
            (Invoke-AdversarialPlan -Name 'hygiene-collisions' -Parameter @{
                    UsersCsv              = (Join-Path $script:Fixtures 'Collisions.csv')
                    SharedMailboxesCsv    = (Join-Path $script:Fixtures 'SharedMailboxes.csv')
                    ReservedAddressesPath = (Join-Path $script:Fixtures 'Reserved-MixedCase.csv')
                }),
            (Invoke-AdversarialPlan -Name 'hygiene-guests' -Parameter @{
                    UsersCsv           = (Join-Path $script:Fixtures 'Guests.csv')
                    ExclusionRulesPath = (Join-Path $script:Fixtures 'ExclusionRules-Regex.csv')
                    IncludeGuests      = $true
                    IncludeSynced      = $true
                })
        )
        $script:HygieneRows = @($script:HygieneRuns | ForEach-Object { $_.Rows })
    }

    It 'wrote every run' {
        @($script:HygieneRuns | Where-Object { $_.ExitCode -ne 0 }) | Should -BeNullOrEmpty
        $script:HygieneRows.Count | Should -BeGreaterThan 20
    }

    It 'gives every row an ObjectType and a PlanStatus from the plan vocabulary' {
        $types = @('User', 'Guest', 'Shared', 'Room', 'Equipment', 'Distribution',
            'MailEnabledSecurity', 'Contact', 'DynamicDistribution', 'M365Group')
        $statuses = @('Planned', 'Collision', 'NeedsReview', 'Invalid', 'ManualOverride',
            'Excluded', 'ExistsInDestination', 'UpnSmtpDiverge')

        @($script:HygieneRows | Where-Object { $_.ObjectType -notin $types }) | Should -BeNullOrEmpty
        @($script:HygieneRows | Where-Object { $_.PlanStatus -notin $statuses }) | Should -BeNullOrEmpty
    }

    It 'produces only addresses that Test-MigrationAddress accepts on actionable rows' {
        $checks = @(
            @{ Column = 'TargetUserPrincipalName'; Kind = 'Upn' }
            @{ Column = 'InterimUserPrincipalName'; Kind = 'Upn' }
            @{ Column = 'TargetPrimarySmtp'; Kind = 'Smtp' }
            @{ Column = 'InterimPrimarySmtp'; Kind = 'Smtp' }
            @{ Column = 'TargetMailNickname'; Kind = 'MailNickname' }
        )
        $rejected = [System.Collections.Generic.List[string]]::new()

        foreach ($row in $script:HygieneRows) {
            if ($row.PlanStatus -notin $script:ActionableStatuses) { continue }
            foreach ($check in $checks) {
                $value = [string]$row.($check.Column)
                if (-not $value) { continue }
                $verdict = Test-MigrationAddress -Address $value -Kind $check.Kind
                if (-not $verdict.IsValid) {
                    $rejected.Add("$($row.DisplayName) $($check.Column)='$value': $($verdict.Reason)")
                }
            }
            foreach ($alias in @($row.TargetAliases -split ';' | Where-Object { $_ -like 'smtp:*' })) {
                $verdict = Test-MigrationAddress -Address ($alias -replace '^smtp:', '') -Kind Smtp
                if (-not $verdict.IsValid) { $rejected.Add("$($row.DisplayName) alias '$alias': $($verdict.Reason)") }
            }
        }

        $rejected | Should -BeNullOrEmpty
    }

    It 'never leaks an exception or a stack trace into PlanDetail' {
        $leaked = @($script:HygieneRows | Where-Object {
                $_.PlanDetail -match 'Exception|ScriptStackTrace|\.ps1:\d+|at line \d+|System\.'
            })
        $leaked | Should -BeNullOrEmpty
    }

    It 'leaves the target columns empty on every row an operator still has to name' {
        $unfinished = @($script:HygieneRows | Where-Object { $_.PlanStatus -eq 'NeedsReview' -and $_.TargetUserPrincipalName })
        $unfinished | Should -BeNullOrEmpty
    }
}
