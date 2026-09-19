#Requires -Version 7.4

<#
    The catalogue overlay (M365Migration/StepCatalog.psd1) holds what a script cannot say about
    itself. Everything it does say - parameter names, types, sets, ValidateSet values - is read
    back off the scripts here and compared, so an overlay key that names a parameter which no
    longer exists, or a parameter that no overlay accounts for, fails the build rather than
    surfacing as an empty field in the workbench months later.

    The file lists are built at Describe scope rather than inside BeforeAll because Pester's
    -ForEach needs them during the discovery pass; a BeforeAll only runs later, during Run.
#>

Describe 'StepCatalog drift guard' {

    $toolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptFiles = @(Get-ChildItem -LiteralPath $toolkitRoot -Filter '*-Migration*.ps1' -File |
            Where-Object { $_.Name -ne 'Start-MigrationWorkbench.ps1' })
    $scriptCases = @($scriptFiles | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } })

    <#
        The ruled runbook, pinned row by row. This is the one place the catalogue is not
        allowed to be self-consistent: renaming an instance, moving it in the runbook, pointing
        it at the other tenant or changing what it is allowed to do to that tenant are all
        decisions taken outside this file, so each has to be restated here to be changed.
    #>
    $ruledInstances = @(
        @{ Id = 'Inventory-Source'; Order = 1; Side = 'Source'; Impact = 'Read' }
        @{ Id = 'Inventory-Destination'; Order = 2; Side = 'Destination'; Impact = 'Read' }
        @{ Id = 'New-IdentityPlan'; Order = 3; Side = 'Offline'; Impact = 'Read' }
        @{ Id = 'Export-MappingFile'; Order = 4; Side = 'Offline'; Impact = 'Read' }
        @{ Id = 'Readiness-Pre'; Order = 5; Side = 'Destination'; Impact = 'Read' }
        @{ Id = 'New-Users'; Order = 6; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'Set-Licenses'; Order = 7; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'New-Recipients'; Order = 8; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'Readiness-Provisioned'; Order = 9; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'DomainReferences-Report'; Order = 11; Side = 'Source'; Impact = 'Read' }
        @{ Id = 'DomainReferences-Remediate'; Order = 11.5; Side = 'Source'; Impact = 'Destructive' }
        @{ Id = 'Set-Identity'; Order = 12; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'Set-Identity-InPlace'; Order = 12; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'Set-MailboxPermissions'; Order = 13; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'Reset-CutoverPasswords'; Order = 14; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'TeamsPhone-Export'; Order = 15.1; Side = 'Source'; Impact = 'Read' }
        @{ Id = 'TeamsPhone-Remove'; Order = 15.2; Side = 'Source'; Impact = 'Destructive' }
        @{ Id = 'TeamsPhone-ListUnassigned'; Order = 15.3; Side = 'Destination'; Impact = 'Read' }
        @{ Id = 'TeamsPhone-Assign'; Order = 15.4; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'VivaLearning-Export'; Order = 16.1; Side = 'Source'; Impact = 'Read' }
        @{ Id = 'VivaLearning-Import'; Order = 16.2; Side = 'Destination'; Impact = 'Write' }
        @{ Id = 'Readiness-Post'; Order = 17; Side = 'Destination'; Impact = 'Read' }
        @{ Id = 'Inventory-Post'; Order = 18; Side = 'Destination'; Impact = 'Read' }
        @{ Id = 'Compare-Plan'; Order = 18.5; Side = 'Offline'; Impact = 'Read' }
    )
    $ruledIdCase = @(@{ Ids = @($ruledInstances | ForEach-Object { $_.Id }) })

    # The scenario views, exactly. An 'is not in the list' assertion alone would pass against
    # an empty view, so both lists are stated in full.
    $inPlaceIdCase = @(@{
            Ids = @(
                'Inventory-Source', 'New-IdentityPlan', 'Readiness-Pre', 'Readiness-Provisioned',
                'Set-Identity-InPlace', 'Set-MailboxPermissions', 'Readiness-Post', 'Inventory-Post',
                'Compare-Plan')
        })

    BeforeAll {
        # Match the scripts, which run under Set-StrictMode -Version Latest.
        Set-StrictMode -Version Latest

        Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

        $script:toolkit = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:scripts = @(Get-ChildItem -LiteralPath $script:toolkit -Filter '*-Migration*.ps1' -File |
                Where-Object { $_.Name -ne 'Start-MigrationWorkbench.ps1' })
        $script:catalog = Import-PowerShellDataFile (Join-Path $script:toolkit 'M365Migration' 'StepCatalog.psd1')
        $script:settingsKeys = @((Get-MigrationSettingsSchema).Key)

        $script:inventoryPrefixes = @('Source', 'Destination', 'Post')
        $script:inventoryTabs = @(
            'Users', 'UserMailboxes', 'SharedMailboxes', 'MailboxPermissions', 'Groups',
            'Contacts', 'Domains', 'Licenses', 'Summary')
        $script:artefactKinds = @('Results', 'Inventory', 'Plan', 'Mapping', 'Log')

        # The token a step's results file is named with is a string literal inside the script,
        # so the only honest way to check the overlay's ResultId is to read the literal back.
        # Compare-MigrationUserData picks between two tokens in a variable, so a -Name argument
        # that is a variable is followed to that variable's assignments.
        function script:Get-MigrationResultNameLiteral {
            [CmdletBinding()]
            [OutputType([string[]])]
            param([Parameter(Mandatory)][string]$Path)

            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            $calls = @($ast.FindAll({
                        $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                        $args[0].GetCommandName() -eq 'Export-MigrationResult'
                    }, $true))

            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($call in $calls) {
                $elements = @($call.CommandElements)
                for ($index = 0; $index -lt $elements.Count; $index++) {
                    $element = $elements[$index]
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    if ($element.ParameterName -ne 'Name') { continue }

                    $argument = $element.Argument
                    if ($null -eq $argument -and ($index + 1) -lt $elements.Count) {
                        $argument = $elements[$index + 1]
                    }
                    if ($null -eq $argument) { continue }

                    if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $names.Add($argument.Value)
                        continue
                    }

                    if ($argument -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        $variableName = $argument.VariablePath.UserPath
                        $assignments = @($ast.FindAll({
                                    $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                                    $args[0].Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                    $args[0].Left.VariablePath.UserPath -eq $variableName
                                }, $true))
                        foreach ($assignment in $assignments) {
                            $literals = @($assignment.Right.FindAll({
                                        $args[0] -is
                                        [System.Management.Automation.Language.StringConstantExpressionAst]
                                    }, $true))
                            foreach ($literal in $literals) { $names.Add($literal.Value) }
                        }
                    }
                }
            }

            return @($names | Sort-Object -Unique)
        }

        # Read as calls, not as text: a raw regex over the source would also match the word
        # inside a comment or a help block, so a connector nobody calls could still "pass".
        function script:Get-MigrationConnectorCall {
            [CmdletBinding()]
            [OutputType([string[]])]
            param([Parameter(Mandatory)][string]$Path)

            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            $calls = @($ast.FindAll({
                        $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                        $args[0].GetCommandName() -match '^Connect-Migration(Graph|Exchange|Teams)$'
                    }, $true))

            $connectors = foreach ($call in $calls) {
                ($call.GetCommandName() -replace '^Connect-Migration', '')
            }

            return @($connectors | Sort-Object -Unique)
        }

        function script:Test-MigrationScriptConfirmImpactHigh {
            [CmdletBinding()]
            [OutputType([bool])]
            param([Parameter(Mandatory)][string]$Path)

            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            if ($null -eq $ast.ParamBlock) { return $false }

            foreach ($attribute in $ast.ParamBlock.Attributes) {
                if ($attribute -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
                if ($attribute.TypeName.Name -ne 'CmdletBinding') { continue }

                foreach ($named in $attribute.NamedArguments) {
                    if ($named.ArgumentName -eq 'ConfirmImpact' -and $named.Argument.Extent.Text -match 'High') {
                        return $true
                    }
                }
            }

            return $false
        }

        function script:Get-MigrationCatalogEntryValue {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][hashtable]$Entry,
                [Parameter(Mandatory)][string]$Key,
                [AllowNull()]$Default = $null
            )

            if ($Entry.ContainsKey($Key)) { return $Entry[$Key] }
            return $Default
        }
    }

    It 'has an overlay entry for every script and no entry without a script' {
        @($script:catalog.Keys | Sort-Object) | Should -Be @($script:scripts.BaseName | Sort-Object)
    }

    It '<Name>: states Bind, Resolve, Fixed, Ignore and Instances even when they are empty' -ForEach $scriptCases {
        # The checks below read these directly. Under Set-StrictMode an absent key is an error,
        # not an empty answer, so every entry declares all five rather than failing obscurely.
        foreach ($key in @('Bind', 'Resolve', 'Fixed', 'Ignore', 'Instances')) {
            $script:catalog[$Name].ContainsKey($key) | Should -BeTrue -Because "$Name needs a $key key"
        }
    }

    It '<Name>: every Bind target, Resolve key, Fixed key and Ignore entry is a real parameter' -ForEach $scriptCases {
        $entry = $script:catalog[$Name]
        $params = @((Get-Command $Path).Parameters.Keys)
        foreach ($k in @($entry.Bind.Values) + @($entry.Resolve.Keys) + @($entry.Ignore) + @($entry.Fixed.Keys)) {
            $params | Should -Contain $k
        }
        # An instance states only its differences, so its maps are read through ContainsKey.
        foreach ($inst in @($entry.Instances)) {
            $fixed = Get-MigrationCatalogEntryValue -Entry $inst -Key 'Fixed' -Default @{}
            $resolve = Get-MigrationCatalogEntryValue -Entry $inst -Key 'Resolve' -Default @{}
            $bind = Get-MigrationCatalogEntryValue -Entry $inst -Key 'Bind' -Default @{}
            foreach ($k in @($fixed.Keys) + @($resolve.Keys) + @($bind.Values)) {
                $params | Should -Contain $k
            }
        }
    }

    It '<Name>: every Bind source is a settings key' -ForEach $scriptCases {
        foreach ($k in @($script:catalog[$Name].Bind.Keys)) { $script:settingsKeys | Should -Contain $k }
        foreach ($inst in @($script:catalog[$Name].Instances)) {
            $bind = Get-MigrationCatalogEntryValue -Entry $inst -Key 'Bind' -Default @{}
            foreach ($k in @($bind.Keys)) { $script:settingsKeys | Should -Contain $k }
        }
    }

    It '<Name>: every non-common parameter is bound, resolved, fixed or ignored' -ForEach $scriptCases {
        $step = Get-MigrationStep -Script $Name
        $covered = @($step.Bind.Values) + @($step.Resolve.Keys) + @($step.Fixed.Keys) + @($step.Ignore) +
        @($step.Instances | ForEach-Object { @($_.Fixed.Keys) + @($_.Resolve.Keys) })
        foreach ($p in ($step.Parameters | Where-Object { -not $_.Common })) {
            $covered | Should -Contain $p.Name -Because "$Name -$($p.Name) must be accounted for"
        }
    }

    It '<Name>: no parameter is both ignored and supplied' -ForEach $scriptCases {
        $step = Get-MigrationStep -Script $Name
        $supplied = @($step.Bind.Values) + @($step.Resolve.Keys) +
        @($step.Instances | ForEach-Object { @($_.Fixed.Keys) + @($_.Resolve.Keys) + @($_.Bind.Values) })
        foreach ($ignored in @($step.Ignore)) {
            $supplied | Should -Not -Contain $ignored -Because "$Name -$ignored cannot be ignored and supplied"
        }
    }

    It '<Name>: Fixed values satisfy ValidateSet' -ForEach $scriptCases {
        foreach ($inst in (Get-MigrationStep -Script $Name).Instances) {
            foreach ($k in @($inst.Fixed.Keys)) {
                # Matched to an array first: a key that names no parameter must fail saying so,
                # not throw a PropertyNotFoundException off $null under strict mode.
                $p = @((Get-MigrationStep -Script $Name).Parameters | Where-Object Name -eq $k)
                $p.Count | Should -Be 1 -Because "$($inst.Id) fixes -$k, which must be a real parameter"
                if ($p[0].ValidValues) { $p[0].ValidValues | Should -Contain $inst.Fixed[$k] }
            }
        }
    }

    It '<Name>: a Fixed switch or bool carries a boolean, not a string' -ForEach $scriptCases {
        $step = Get-MigrationStep -Script $Name
        foreach ($inst in $step.Instances) {
            foreach ($k in @($inst.Fixed.Keys)) {
                $p = @($step.Parameters | Where-Object Name -eq $k)
                $p.Count | Should -Be 1 -Because "$($inst.Id) fixes -$k, which must be a real parameter"
                if ($p[0].IsSwitch -or $p[0].IsBool) {
                    $inst.Fixed[$k] | Should -BeOfType [bool] -Because "$($inst.Id) fixes -$k"
                }
            }
        }
    }

    It '<Name>: a side-scoped Bind source matches the step''s own side' -ForEach $scriptCases {
        # A Destination-side writer that reads the source tenant's GUID would connect to the
        # wrong tenant and the run would look entirely normal, so the side and the settings
        # section a binding draws from have to agree. Offline steps bind neither section.
        $steps = @(Get-MigrationStep -Script $Name) + @((Get-MigrationStep -Script $Name).Instances)
        foreach ($step in $steps) {
            foreach ($key in @($step.Bind.Keys)) {
                if ($key -like 'Source.*') {
                    $step.Side | Should -BeExactly 'Source' `
                        -Because "$($step.Id) binds $key -> -$($step.Bind[$key])"
                }
                elseif ($key -like 'Destination.*') {
                    $step.Side | Should -BeExactly 'Destination' `
                        -Because "$($step.Id) binds $key -> -$($step.Bind[$key])"
                }
            }
        }
    }

    It '<Name>: no parameter is both fixed and bound' -ForEach $scriptCases {
        # Two sources for one parameter is a silent precedence question. Where every instance
        # fixes a parameter, the script's entry must not also bind it.
        foreach ($inst in (Get-MigrationStep -Script $Name).Instances) {
            foreach ($k in @($inst.Fixed.Keys)) {
                @($inst.Bind.Values) | Should -Not -Contain $k `
                    -Because "$($inst.Id) fixes -$k, so nothing may bind it as well"
            }
        }
    }

    It '<Name>: ResultId names the token the script really exports' -ForEach $scriptCases {
        $entry = $script:catalog[$Name]
        $exported = @(Get-MigrationResultNameLiteral -Path $Path)

        $declared = @()
        if ($entry.ContainsKey('ResultIds')) { $declared = @($entry.ResultIds) }
        elseif ($entry.ContainsKey('ResultId')) { $declared = @($entry.ResultId) }

        (@($declared | Sort-Object -Unique) -join ',') | Should -BeExactly ($exported -join ',') `
            -Because "$Name exports results named '$($exported -join ", ")'"

        foreach ($inst in @($entry.Instances)) {
            if ($inst.ContainsKey('ResultId')) { $declared | Should -Contain $inst.ResultId }
        }
    }

    It '<Name>: Confirm is set exactly when the script declares ConfirmImpact High' -ForEach $scriptCases {
        $declared = [bool](Get-MigrationCatalogEntryValue -Entry $script:catalog[$Name] -Key 'Confirm' -Default $false)
        $declared | Should -Be (Test-MigrationScriptConfirmImpactHigh -Path $Path) `
            -Because "Confirm means 'pass -Confirm:`$false because ConfirmImpact is High'"
    }

    It '<Name>: Phase, Side, Impact and Scenario use the documented vocabulary' -ForEach $scriptCases {
        foreach ($step in @((Get-MigrationStep -Script $Name)) + @((Get-MigrationStep -Script $Name).Instances)) {
            $step.Phase | Should -BeIn @('Discover', 'Plan', 'Prepare', 'Cutover')
            $step.Side | Should -BeIn @('Source', 'Destination', 'Offline')
            $step.Impact | Should -BeIn @('Read', 'Write', 'Destructive')
            foreach ($connection in @($step.Connects)) {
                $connection | Should -BeIn @('Graph', 'Exchange', 'Teams')
            }
            foreach ($scenario in @($step.Scenario)) {
                $scenario | Should -BeIn @('TenantToTenant', 'InPlaceRedesign')
            }
        }
    }

    It '<Name>: Connects names the connectors the script actually calls' -ForEach $scriptCases {
        $expected = @(Get-MigrationConnectorCall -Path $Path)
        $declared = @((Get-MigrationStep -Script $Name).Connects)
        ($declared | Sort-Object) -join ',' | Should -BeExactly ($expected -join ',')
    }

    It 'gives every instance a unique Id and a title' {
        $steps = @(Get-MigrationStep)
        @($steps.Id | Sort-Object -Unique).Count | Should -Be $steps.Count
        foreach ($step in $steps) {
            $step.Title | Should -Not -BeNullOrEmpty -Because "$($step.Id) needs a title"
            $step.Order | Should -BeGreaterThan 0 -Because "$($step.Id) needs a runbook order"
        }
    }

    It 'names an existing step instance or a known artefact in every Requires' {
        $ids = @((Get-MigrationStep).Id)
        foreach ($step in Get-MigrationStep) {
            foreach ($requirement in @($step.Requires)) {
                $known = ($ids -contains $requirement) -or ($script:artefactKinds -contains $requirement) -or
                    ($requirement -like 'Report:*') -or ($requirement -like 'Export:*')
                $known | Should -BeTrue -Because "$($step.Id) requires '$requirement'"
            }
        }
    }

    It 'uses the artefact vocabulary in every Produces' {
        foreach ($step in Get-MigrationStep) {
            @($step.Produces).Count | Should -BeGreaterThan 0 -Because "$($step.Id) must say what it writes"
            foreach ($artefact in @($step.Produces)) {
                $known = ($script:artefactKinds -contains $artefact) -or ($artefact -like 'Report:*')
                $known | Should -BeTrue -Because "$($step.Id) produces '$artefact'"
            }
        }
    }

    It 'names a known resolver in every Resolve' {
        $resultIds = @(Get-MigrationStep | ForEach-Object ResultId | Where-Object { $_ })
        foreach ($step in Get-MigrationStep) {
            foreach ($resolver in @($step.Resolve.Values)) {
                switch -Regex ($resolver) {
                    '^(Plan|ExistingPlan)$' { break }
                    '^Settings:.+$' { break }
                    '^Export:(?<id>.+)$' {
                        $resultIds | Should -Contain $Matches['id'] -Because "$($step.Id) resolves '$resolver'"
                        break
                    }
                    '^Inventory:(?<prefix>[^:]+):(?<tab>[^:]+)$' {
                        $script:inventoryPrefixes | Should -Contain $Matches['prefix']
                        $script:inventoryTabs | Should -Contain $Matches['tab']
                        break
                    }
                    default { throw "$($step.Id) resolves '$resolver', which is not a known resolver" }
                }
            }
        }
    }

    It 'maps every exit code to a meaning, starting from the shared vocabulary' {
        foreach ($step in Get-MigrationStep) {
            $step.ExitCodes[0] | Should -BeExactly 'Completed' -Because "$($step.Id) exit 0"
            $step.ExitCodes.Keys | Should -Contain 1 -Because "$($step.Id) needs a meaning for exit 1"
        }
    }

    It 'gives <Id> exit <Code> the ruled meaning "<Meaning>"' -ForEach @(
        @{ Id = 'DomainReferences-Report'; Code = 3; Meaning = 'References remain' }
        @{ Id = 'DomainReferences-Remediate'; Code = 3; Meaning = 'References remain' }
        @{ Id = 'Compare-Plan'; Code = 2; Meaning = 'Differences found' }
        @{ Id = 'Readiness-Pre'; Code = 2; Meaning = 'Checks failed' }
        @{ Id = 'Readiness-Provisioned'; Code = 2; Meaning = 'Checks failed' }
        @{ Id = 'Readiness-Post'; Code = 2; Meaning = 'Checks failed' }
        @{ Id = 'Set-Licenses'; Code = 1; Meaning = 'Failed or seat shortfall' }
    ) {
        (Get-MigrationStep -Id $Id).ExitCodes[$Code] | Should -BeExactly $Meaning
    }

    It 'leaves every other step on the shared 0/1/2 vocabulary' {
        $overridden = @(
            'DomainReferences-Report', 'DomainReferences-Remediate', 'Compare-Plan',
            'Readiness-Pre', 'Readiness-Provisioned', 'Readiness-Post', 'Set-Licenses')
        foreach ($step in (Get-MigrationStep | Where-Object { $overridden -notcontains $_.Id })) {
            @($step.ExitCodes.Keys | Sort-Object) | Should -Be @(0, 1, 2) -Because "$($step.Id)"
            $step.ExitCodes[1] | Should -BeExactly 'Failed'
            $step.ExitCodes[2] | Should -BeExactly 'Some rows failed'
        }
    }

    It 'pins <Id> at order <Order>, side <Side>, impact <Impact>' -ForEach $ruledInstances {
        $step = Get-MigrationStep -Id $Id
        $step.Order | Should -Be $Order
        $step.Side | Should -BeExactly $Side
        $step.Impact | Should -BeExactly $Impact
    }

    It 'has exactly the ruled instances and no others' -ForEach $ruledIdCase {
        @((Get-MigrationStep).Id | Sort-Object) | Should -Be @($Ids | Sort-Object)
    }

    It 'orders the phase view like the runbook' {
        $ids = (Get-MigrationStep | Sort-Object Order).Id
        $ids[0] | Should -Be 'Inventory-Source'
        $ids | Should -Contain 'New-Users'
        $ids[-1] | Should -Be 'Compare-Plan'
    }

    It 'hides tenant-to-tenant-only steps for InPlaceRedesign' {
        (Get-MigrationStep -Scenario 'InPlaceRedesign').Id | Should -Not -Contain 'DomainReferences-Report'
    }

    It 'shows exactly the nine in-place steps, in runbook order' -ForEach $inPlaceIdCase {
        @((Get-MigrationStep -Scenario 'InPlaceRedesign') | Sort-Object Order | ForEach-Object Id) |
            Should -Be $Ids
    }

    It 'shows every instance but the in-place identity cutover for TenantToTenant' -ForEach $ruledIdCase {
        $expected = @($Ids | Where-Object { $_ -ne 'Set-Identity-InPlace' } | Sort-Object)
        @((Get-MigrationStep -Scenario 'TenantToTenant').Id | Sort-Object) | Should -Be $expected
    }

    It 'keeps <Id> out of the InPlaceRedesign phase view' -ForEach @(
        @{ Id = 'Inventory-Destination' }
        @{ Id = 'Export-MappingFile' }
        @{ Id = 'DomainReferences-Remediate' }
        @{ Id = 'New-Users' }
        @{ Id = 'Set-Licenses' }
        @{ Id = 'New-Recipients' }
        @{ Id = 'Reset-CutoverPasswords' }
        @{ Id = 'TeamsPhone-Export' }
        @{ Id = 'TeamsPhone-Assign' }
        @{ Id = 'VivaLearning-Import' }
        @{ Id = 'Set-Identity' }
    ) {
        @((Get-MigrationStep -Scenario 'InPlaceRedesign').Id) | Should -Not -Contain $Id
    }

    It 'keeps <Id> in the InPlaceRedesign phase view' -ForEach @(
        @{ Id = 'Inventory-Source' }
        @{ Id = 'New-IdentityPlan' }
        @{ Id = 'Readiness-Pre' }
        @{ Id = 'Set-Identity-InPlace' }
        @{ Id = 'Set-MailboxPermissions' }
        @{ Id = 'Readiness-Post' }
        @{ Id = 'Inventory-Post' }
        @{ Id = 'Compare-Plan' }
    ) {
        @((Get-MigrationStep -Scenario 'InPlaceRedesign').Id) | Should -Contain $Id
    }

    It 'matches the plan on MatchOn for the two identity-cutover instances' {
        (Get-MigrationStep -Id 'Set-Identity').Fixed['MatchOn'] | Should -BeExactly 'TargetObjectId'
        (Get-MigrationStep -Id 'Set-Identity-InPlace').Fixed['MatchOn'] | Should -BeExactly 'Source'
    }

    It 'never requires a step that its own scenario hides' {
        foreach ($scenario in @('TenantToTenant', 'InPlaceRedesign')) {
            $visible = @(Get-MigrationStep -Scenario $scenario)
            $visibleIds = @($visible.Id)
            foreach ($step in $visible) {
                foreach ($requirement in @($step.Requires)) {
                    # An artefact kind is satisfied by a file, not by a step, so only step ids
                    # can strand a step behind something the scenario has hidden.
                    if ($script:artefactKinds -contains $requirement) { continue }
                    $visibleIds | Should -Contain $requirement `
                        -Because "$($step.Id) requires $requirement, hidden in $scenario"
                }
            }
        }
    }
}

Describe 'Get-MigrationStep' {

    BeforeAll {
        Set-StrictMode -Version Latest
        Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
        $script:toolkit = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }

    It 'returns every instance when asked for nothing in particular' {
        $steps = @(Get-MigrationStep)
        $steps.Count | Should -BeGreaterThan 17
        foreach ($step in $steps) { $step.IsInstance | Should -BeTrue }
    }

    It 'returns a single instance by Id, with its fixed values applied' {
        $step = Get-MigrationStep -Id 'Inventory-Destination'
        @($step).Count | Should -Be 1
        $step.Script | Should -BeExactly 'Get-MigrationInventory'
        $step.Fixed['Prefix'] | Should -BeExactly 'Destination'
        $step.Side | Should -BeExactly 'Destination'
        $step.Order | Should -Be 2
        Test-Path -LiteralPath $step.ScriptPath | Should -BeTrue
    }

    It 'gives a script with no instances one instance named after it' {
        $step = Get-MigrationStep -Id 'New-Users'
        $step.Script | Should -BeExactly 'New-MigrationUsers'
        $step.ResultId | Should -BeExactly 'New-Users'
        @($step.Fixed.Keys) | Should -BeNullOrEmpty
    }

    It 'returns the bare script entry, with no fixed values, for the all-tools view' {
        $step = Get-MigrationStep -Script 'Test-MigrationReadiness'
        $step.IsInstance | Should -BeFalse
        @($step.Fixed.Keys) | Should -BeNullOrEmpty
        @($step.Instances).Count | Should -Be 3
        @($step.Instances.Id) | Should -Be @('Readiness-Pre', 'Readiness-Provisioned', 'Readiness-Post')
    }

    It 'carries the Task 2 introspection on every step' {
        $step = Get-MigrationStep -Id 'Readiness-Provisioned'
        @($step.Parameters | Where-Object Name -eq 'Stage').Count | Should -Be 1
        (@($step.Parameters | Where-Object Name -eq 'Stage')[0]).ValidValues | Should -Contain 'Provisioned'
        $step.ParameterSets.Names | Should -BeNullOrEmpty
        $step.Resolve['SourceMailboxesCsv'] | Should -BeExactly 'Inventory:Source:UserMailboxes'
    }

    It 'lets an instance override a side-dependent binding without leaving both bindings behind' {
        $source = Get-MigrationStep -Id 'Inventory-Source'
        $destination = Get-MigrationStep -Id 'Inventory-Destination'

        @($source.Bind.Keys | Where-Object { $source.Bind[$_] -eq 'TenantId' }) | Should -Be @('Source.TenantId')
        @($destination.Bind.Keys | Where-Object { $destination.Bind[$_] -eq 'TenantId' }) |
            Should -Be @('Destination.TenantId')
    }

    It 'reads the catalog from an explicit -ToolkitPath' {
        $steps = @(Get-MigrationStep -ToolkitPath $script:toolkit)
        @($steps.Id) | Should -Contain 'Inventory-Source'
    }

    It 'throws for an unknown Id, naming what is available' {
        $caught = $null
        try { $null = Get-MigrationStep -Id 'No-Such-Step' } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -BeLike '*No-Such-Step*'
        $caught.Exception.Message | Should -BeLike '*Inventory-Source*'
    }

    It 'throws for an unknown script' {
        $caught = $null
        try { $null = Get-MigrationStep -Script 'Get-MigrationNothing' } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -BeLike '*Get-MigrationNothing*'
    }
}
