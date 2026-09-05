#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
.SYNOPSIS
    Pester tests for Install-AzureServiceWatchdogFunction.ps1 (DESIGN.md section 7.2).

.DESCRIPTION
    The deployment script declares #Requires -Modules for four Az modules that are not
    installed on every development machine, and PowerShell refuses to dot-source a file
    whose #Requires -Modules cannot be satisfied. The tests therefore copy the script to a
    scratch folder with the #Requires -Modules line removed and dot-source the copy; the
    copy is byte-identical otherwise, so code coverage measured on it reflects the script.

    Every Az cmdlet the script calls is declared as a stub function here and mocked, so
    the suite never touches Azure. Compress-Archive, Invoke-RestMethod, Start-Sleep and
    Get-Command are mocked as well. Invoke-AzRestMethod is driven by a small scenario
    table ($script:Azure) that tests adjust per case (admin isolation state, function
    readiness polls, key PUT status codes, listkeys content).

    File-system effects are confined to a per-run scratch folder under the platform temp
    directory, removed in AfterAll. $env:ProgramData is pointed at that folder before the
    script is dot-sourced so default log paths never touch the host.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Set-/Restart- functions are stubs for Az cmdlets missing on the test machine; all are mocked.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
    Justification = 'Stubs declare SupportsShouldProcess only so -WhatIf binds; they have no body to guard.')]
param ()

BeforeAll {
    $script:TestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath "swd-install-azure-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null

    $script:OriginalProgramData = $env:ProgramData
    $env:ProgramData = Join-Path -Path $script:TestRoot -ChildPath 'ProgramData'

    $script:SourceScriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Deploy',
        'Install-AzureServiceWatchdogFunction.ps1'
    $script:SourceScriptPath = [System.IO.Path]::GetFullPath($script:SourceScriptPath)

    # Copy without the Az #Requires -Modules line (see .DESCRIPTION). A fixed folder name
    # keeps the path predictable for a coverage run: <temp>/ServiceWatchdogTests/<script>.
    $script:LoadedScriptDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'ServiceWatchdogTests'
    New-Item -Path $script:LoadedScriptDir -ItemType Directory -Force | Out-Null
    $script:LoadedScriptPath = Join-Path -Path $script:LoadedScriptDir `
        -ChildPath 'Install-AzureServiceWatchdogFunction.ps1'
    $sourceLines = Get-Content -LiteralPath $script:SourceScriptPath
    $sourceLines | Where-Object { $_ -notmatch '^#Requires\s+-Modules' } |
        Set-Content -LiteralPath $script:LoadedScriptPath

    $script:FunctionKeyValue = 'EXAMPLEKEY0123456789abcdefghijklmnopqrstuvwxyzAB'
    $script:FunctionAppName = 'func-svcwatchdog-abc123'
    $script:FunctionHostName = 'func-svcwatchdog-abc123.azurewebsites.net'
    $script:AlertUrl = "https://$script:FunctionHostName/api/servicewatchdog/alert"
    $script:KeyVaultName = 'kv-svcwatchdog-abc123'
    $script:SubscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:UserObjectId = '22222222-2222-2222-2222-222222222222'
    $script:SpObjectId = '33333333-3333-3333-3333-333333333333'
    $script:SpApplicationId = '55555555-5555-5555-5555-555555555555'

    # Stubs for the Az cmdlets. Pester can only mock a command that exists. Parameter
    # lists mirror what the script passes so binding succeeds under the mock.
    function Get-AzContext {
        [CmdletBinding()]
        param ()
    }

    function Set-AzContext {
        [CmdletBinding()]
        param ($SubscriptionId, $TenantId)
    }

    function Get-AzADUser {
        [CmdletBinding()]
        param ([switch]$SignedIn)
    }

    function Get-AzADServicePrincipal {
        [CmdletBinding()]
        param ($ApplicationId)
    }

    function Get-AzResourceGroup {
        [CmdletBinding()]
        param ($Name)
    }

    function New-AzResourceGroup {
        [CmdletBinding(SupportsShouldProcess)]
        param ($Name, $Location, $Tag, [switch]$Force)
    }

    function New-AzResourceGroupDeployment {
        [CmdletBinding(SupportsShouldProcess)]
        param ($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $Name, $Mode)
    }

    function Set-AzKeyVaultSecret {
        [CmdletBinding(SupportsShouldProcess)]
        param ($VaultName, $Name, [securestring]$SecretValue, $ContentType)
    }

    function Publish-AzWebApp {
        [CmdletBinding(SupportsShouldProcess)]
        param ($ResourceGroupName, $Name, $ArchivePath, [switch]$Force, $Timeout)
    }

    function Restart-AzWebApp {
        [CmdletBinding(SupportsShouldProcess)]
        param ($ResourceGroupName, $Name)
    }

    function Invoke-AzRestMethod {
        [CmdletBinding()]
        param ($Method, $Path, $Payload)
    }

    . $script:LoadedScriptPath -ResourceGroupName 'rg-example' -BaseName 'svcwatchdog' `
        -MailFrom 'Service Watchdog <alerts@example.com>' -MailTo 'it@example.com'

    function Get-RestResponse {
        param ([int]$StatusCode, [string]$Content = '{}')
        [pscustomobject]@{ StatusCode = $StatusCode; Content = $Content }
    }

    function Get-FunctionListContent {
        @{
            value = @(
                @{
                    name       = "$script:FunctionAppName/SendServiceWatchdogAlert"
                    properties = @{ name = 'SendServiceWatchdogAlert' }
                }
            )
        } | ConvertTo-Json -Depth 5
    }

    function Get-DeploymentResult {
        [pscustomobject]@{
            ProvisioningState = 'Succeeded'
            Outputs           = @{
                functionAppName         = @{ Type = 'String'; Value = $script:FunctionAppName }
                functionAppHostName     = @{ Type = 'String'; Value = $script:FunctionHostName }
                alertUrl                = @{ Type = 'String'; Value = $script:AlertUrl }
                keyVaultName            = @{ Type = 'String'; Value = $script:KeyVaultName }
                storageAccountName      = @{ Type = 'String'; Value = 'stsvcwatchdogabc123' }
                applicationInsightsName = @{ Type = 'String'; Value = 'appi-svcwatchdog' }
            }
        }
    }

    function Get-DeployFixture {
        # Builds an isolated AzureFunction source folder and a placeholder main.bicep and
        # returns the argument set for Invoke-WatchdogDeployment with spec 7.2 defaults.
        param (
            [string]$MailProvider = 'Smtp2GoApi',
            [switch]$WithoutSecret,
            [switch]$WithoutTemplate,
            [switch]$WithoutHostJson
        )
        $id = [guid]::NewGuid().ToString('N')
        $source = Join-Path -Path $script:TestRoot -ChildPath "function-$id"
        $deploy = Join-Path -Path $script:TestRoot -ChildPath "deploy-$id"
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path $deploy -ItemType Directory -Force | Out-Null

        if (-not $WithoutHostJson) {
            Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'host.json') -Value '{ "version": "2.0" }'
        }
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'profile.ps1') -Value '# profile'
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'requirements.psd1') -Value '@{ }'
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'local.settings.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'local.settings.example.json') -Value '{}'
        $moduleDir = Join-Path -Path $source -ChildPath 'Modules' -AdditionalChildPath 'ServiceWatchdogAlert'
        New-Item -Path $moduleDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $moduleDir -ChildPath 'ServiceWatchdogAlert.psm1') -Value '# module'
        $functionDir = Join-Path -Path $source -ChildPath 'SendServiceWatchdogAlert'
        New-Item -Path $functionDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $functionDir -ChildPath 'function.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path -Path $functionDir -ChildPath 'run.ps1') -Value '# run'

        $template = Join-Path -Path $deploy -ChildPath 'main.bicep'
        if (-not $WithoutTemplate) {
            Set-Content -LiteralPath $template -Value "targetScope = 'resourceGroup'"
        }

        $arguments = @{
            ResourceGroupName = 'rg-example'
            BaseName          = 'svcwatchdog'
            MailProvider      = $MailProvider
            MailFrom          = 'Service Watchdog <alerts@example.com>'
            MailTo            = 'it@example.com;oncall@example.com'
            MailSubjectPrefix = '[Service Watchdog]'
            SmtpPort          = 587
            SmtpUseStartTls   = $true
            PowerShellVersion = '7.4'
            FunctionKeyName   = 'watchdog'
            SourcePath        = $source
            TemplatePath      = $template
        }
        if (-not $WithoutSecret) {
            if ($MailProvider -eq 'Smtp2GoApi') {
                $arguments.Smtp2GoApiKey = ConvertTo-SecureString -String 'REPLACE_WITH_API_KEY' -AsPlainText -Force
            }
            else {
                $arguments.SmtpHost = 'mail.example.com'
                $password = ConvertTo-SecureString -String 'REPLACE_WITH_PASSWORD' -AsPlainText -Force
                $arguments.SmtpCredential = [pscredential]::new('relay-user@example.com', $password)
            }
        }
        $arguments
    }

    function Get-LogText {
        if (Test-Path -LiteralPath $script:LogPath) {
            return (Get-Content -LiteralPath $script:LogPath -Raw)
        }
        return ''
    }
}

AfterAll {
    $env:ProgramData = $script:OriginalProgramData
    if ($script:TestRoot -and (Test-Path -LiteralPath $script:TestRoot)) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Install-AzureServiceWatchdogFunction' {

    BeforeEach {
        # Fresh log file per test so assertions on log content are isolated; console output
        # is swallowed so the test run stays quiet.
        $script:LogPath = Join-Path -Path $script:TestRoot -ChildPath "install-$([guid]::NewGuid().ToString('N')).log"
        $script:Verbosity = 'Low'
        $script:DryRun = $false
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Show-WatchdogSummary { }

        # Happy-path Azure: signed-in user on the requested subscription, resource group
        # present, deployment succeeds, secrets seed first time, publish and restart
        # succeed, admin isolation already on, function listed at once, key PUT 200.
        $script:Azure = @{
            AdminIsolation            = $true
            PatchApplies              = $true
            FunctionPollsBeforeListed = 0
            KeyPutStatuses            = [System.Collections.Generic.List[int]]::new()
            KeyExists                 = $false
            KeyPutOmitsValue          = $false
            ListKeysContent           = $null
            DeploymentParameters      = $null
        }

        Mock Get-WatchdogModuleVersion { [version]'5.0.0' }
        Mock Get-Command { [pscustomobject]@{ Name = 'bicep'; Source = '/usr/local/bin/bicep' } } `
            -ParameterFilter { $Name -eq 'bicep' }
        Mock Get-WatchdogBicepVersion { 'Bicep CLI version 0.46.1 (0000000000)' }

        Mock Get-AzContext {
            [pscustomobject]@{
                Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
                Subscription = [pscustomobject]@{ Id = $script:SubscriptionId; Name = 'Example Subscription' }
                Tenant       = [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' }
            }
        }
        Mock Set-AzContext {
            [pscustomobject]@{
                Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
                Subscription = [pscustomobject]@{ Id = $SubscriptionId; Name = 'Other Subscription' }
                Tenant       = [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' }
            }
        }
        Mock Get-AzADUser { [pscustomobject]@{ Id = $script:UserObjectId; UserPrincipalName = 'operator@example.com' } }
        Mock Get-AzADServicePrincipal { [pscustomobject]@{ Id = $script:SpObjectId } }
        Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = $Name; Location = 'eastus2' } }
        Mock New-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = $Name; Location = $Location } }
        Mock New-AzResourceGroupDeployment {
            if ($WhatIf) { return $null }
            $script:Azure.DeploymentParameters = $TemplateParameterObject
            Get-DeploymentResult
        }
        Mock Set-AzKeyVaultSecret { [pscustomobject]@{ Name = $Name; Version = 'abc' } }
        Mock Compress-Archive { Set-Content -LiteralPath $DestinationPath -Value 'zip' }
        Mock Publish-AzWebApp { [pscustomobject]@{ Name = $Name; State = 'Running' } }
        Mock Restart-AzWebApp { }
        Mock Invoke-AzRestMethod {
            switch -Regex ("$Method $Path") {
                '^GET .*/functions\?' {
                    if ($script:Azure.FunctionPollsBeforeListed -gt 0) {
                        $script:Azure.FunctionPollsBeforeListed--
                        return (Get-RestResponse -StatusCode 200 -Content '{ "value": [] }')
                    }
                    return (Get-RestResponse -StatusCode 200 -Content (Get-FunctionListContent))
                }
                '^GET .*/sites/[^/?]+\?' {
                    $content = @{
                        properties = @{ functionsRuntimeAdminIsolationEnabled = $script:Azure.AdminIsolation }
                    } | ConvertTo-Json -Depth 3
                    return (Get-RestResponse -StatusCode 200 -Content $content)
                }
                '^PATCH .*/sites/[^/?]+\?' {
                    if ($script:Azure.PatchApplies) { $script:Azure.AdminIsolation = $true }
                    return (Get-RestResponse -StatusCode 200)
                }
                '^PUT .*/keys/' {
                    # Like ARM (verified live 2026-09-04): the key must be wrapped in a properties
                    # object, or the service answers 400 before looking at anything else.
                    $bodyObject = $null
                    if ($Payload) { $bodyObject = $Payload | ConvertFrom-Json }
                    if (-not ($bodyObject -and $bodyObject.PSObject.Properties['properties'])) {
                        $content = @{ Code = 'BadRequest'; Message = 'Properties object is not present in the request body.' } |
                            ConvertTo-Json
                        return (Get-RestResponse -StatusCode 400 -Content $content)
                    }
                    $status = 200
                    if ($script:Azure.KeyPutStatuses.Count -gt 0) {
                        $status = $script:Azure.KeyPutStatuses[0]
                        $script:Azure.KeyPutStatuses.RemoveAt(0)
                    }
                    # Like the service: the key exists (and listkeys shows it) only once a PUT succeeded.
                    if ($status -in 200, 201) { $script:Azure.KeyExists = $true }
                    if ($status -ge 400) {
                        # Like ARM: a failed PUT carries a DefaultErrorResponse body explaining why.
                        $content = @{ error = @{ code = 'BadRequest'; message = "Simulated ARM error $status" } } |
                            ConvertTo-Json -Depth 3
                        return (Get-RestResponse -StatusCode $status -Content $content)
                    }
                    $keyProperties = @{ name = 'watchdog'; value = $script:FunctionKeyValue }
                    if ($script:Azure.KeyPutOmitsValue) { $keyProperties.Remove('value') }
                    $content = @{ properties = $keyProperties } | ConvertTo-Json -Depth 3
                    return (Get-RestResponse -StatusCode $status -Content $content)
                }
                '^POST .*/listkeys\?' {
                    $content = $script:Azure.ListKeysContent
                    if (-not $content) {
                        # Like the live service (verified 2026-09-04): a flat name-to-value dictionary
                        # with no properties wrapper, despite what the REST reference implies.
                        $keys = @{ default = 'DEFAULTKEY0123456789' }
                        if ($script:Azure.KeyExists) { $keys.watchdog = $script:FunctionKeyValue }
                        $content = $keys | ConvertTo-Json -Depth 3
                    }
                    return (Get-RestResponse -StatusCode 200 -Content $content)
                }
                default { return (Get-RestResponse -StatusCode 200) }
            }
        }
        # The script calls Invoke-RestMethod with -SkipHttpErrorCheck -StatusCodeVariable, so a
        # mock hands back the body and publishes the status the way the cmdlet would. The
        # script's Action reads the variable by dynamic scoping, so Script scope is visible.
        Mock Invoke-RestMethod {
            Set-Variable -Name $StatusCodeVariable -Value 200 -Scope Script
            [pscustomobject]@{ accepted = $true; emailSent = $true; duplicate = $false; providerMessageId = 'msg-1' }
        }
    }

    Context 'Script contract' {
        BeforeAll {
            $tokens = $null
            $errors = $null
            $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:SourceScriptPath, [ref]$tokens, [ref]$errors)
            $script:ScriptCommand = Get-Command -Name $script:SourceScriptPath
        }

        It 'requires PowerShell 7.4 and the four Az modules' {
            $script:ScriptAst.ScriptRequirements.RequiredPSVersion | Should -Be ([version]'7.4')
            $moduleNames = @($script:ScriptAst.ScriptRequirements.RequiredModules | ForEach-Object { $_.Name })
            foreach ($name in @('Az.Accounts', 'Az.Resources', 'Az.Websites', 'Az.KeyVault')) {
                $moduleNames | Should -Contain $name
            }
        }

        It 'exposes the 7.2 parameter set with spec defaults' {
            $parameters = $script:ScriptCommand.Parameters
            foreach ($name in @('SubscriptionId', 'ResourceGroupName', 'Location', 'BaseName', 'MailProvider',
                    'MailFrom', 'MailTo', 'MailSubjectPrefix', 'Smtp2GoApiKey', 'SmtpHost', 'SmtpPort',
                    'SmtpCredential', 'SmtpUseStartTls', 'PowerShellVersion', 'FunctionKeyName', 'SourcePath',
                    'SendTestEmail', 'DryRun', 'Verbosity', 'LogPath')) {
                $parameters.ContainsKey($name) | Should -BeTrue -Because "parameter $name is in the spec"
            }
            $parameters['Smtp2GoApiKey'].ParameterType | Should -Be ([securestring])
            $parameters['SmtpCredential'].ParameterType | Should -Be ([pscredential])
            $verbositySet = $parameters['Verbosity'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $verbositySet.ValidValues | Should -Be @('Low', 'Medium', 'High')
            $providerSet = $parameters['MailProvider'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $providerSet.ValidValues | Should -Be @('Smtp2GoApi', 'Smtp')
        }

        It 'defaults the function key name to watchdog and the PowerShell version to 7.4' {
            $paramBlock = $script:ScriptAst.ParamBlock.Parameters
            $keyName = $paramBlock | Where-Object { $_.Name.VariablePath.UserPath -eq 'FunctionKeyName' }
            $keyName.DefaultValue.Value | Should -Be 'watchdog'
            $version = $paramBlock | Where-Object { $_.Name.VariablePath.UserPath -eq 'PowerShellVersion' }
            $version.DefaultValue.Value | Should -Be '7.4'
        }

        It 'does not run the script body when dot-sourced' {
            Test-Path -LiteralPath 'Function:\Invoke-WatchdogDeployment' | Should -BeTrue
        }
    }

    Context 'Parameters and prerequisites (exit 2)' {
        It 'exits 2 when the Smtp2GoApi provider has no -Smtp2GoApiKey' {
            $fixture = Get-DeployFixture -WithoutSecret

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'Smtp2GoApiKey'
            Should -Invoke Get-AzContext -Times 0
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'exits 2 when the Smtp provider has no -SmtpHost or -SmtpCredential' {
            $fixture = Get-DeployFixture -MailProvider 'Smtp' -WithoutSecret

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'SmtpHost'
            Get-LogText | Should -Match 'SmtpCredential'
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'exits 2 naming the path when main.bicep is missing' {
            $fixture = Get-DeployFixture -WithoutTemplate

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match ([regex]::Escape($fixture.TemplatePath))
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'exits 2 when the source folder has no host.json' {
            $fixture = Get-DeployFixture -WithoutHostJson

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'host\.json'
        }

        It 'exits 2 when the Bicep CLI is not on PATH' {
            $fixture = Get-DeployFixture
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'bicep' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'bicep'
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'exits 2 when bicep --version fails' {
            $fixture = Get-DeployFixture
            Mock Get-WatchdogBicepVersion { throw 'bicep: command failed' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'bicep'
        }

        It 'exits 2 naming the module when an Az module is missing' {
            $fixture = Get-DeployFixture
            Mock Get-WatchdogModuleVersion { $null } -ParameterFilter { $Name -eq 'Az.KeyVault' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'Az\.KeyVault'
            Should -Invoke Get-AzContext -Times 0
        }
    }

    Context 'Sign-in and deployer (exit 20)' {
        It 'exits 20 with a Connect-AzAccount hint when there is no context' {
            $fixture = Get-DeployFixture
            Mock Get-AzContext { $null }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 20
            Get-LogText | Should -Match 'Connect-AzAccount'
            Should -Invoke Get-AzResourceGroup -Times 0
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'resolves a user deployer through Get-AzADUser -SignedIn' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Get-AzADUser -Times 1 -Exactly -ParameterFilter { $SignedIn -eq $true }
            Should -Invoke Get-AzADServicePrincipal -Times 0
            $script:Azure.DeploymentParameters.deployerObjectId | Should -Be $script:UserObjectId
            $script:Azure.DeploymentParameters.deployerPrincipalType | Should -Be 'User'
        }

        It 'resolves a service principal deployer through Get-AzADServicePrincipal -ApplicationId' {
            $fixture = Get-DeployFixture
            Mock Get-AzContext {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = $script:SpApplicationId; Type = 'ServicePrincipal' }
                    Subscription = [pscustomobject]@{ Id = $script:SubscriptionId; Name = 'Example Subscription' }
                    Tenant       = [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' }
                }
            }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Get-AzADServicePrincipal -Times 1 -Exactly -ParameterFilter {
                $ApplicationId -eq $script:SpApplicationId
            }
            Should -Invoke Get-AzADUser -Times 0
            $script:Azure.DeploymentParameters.deployerObjectId | Should -Be $script:SpObjectId
            $script:Azure.DeploymentParameters.deployerPrincipalType | Should -Be 'ServicePrincipal'
        }

        It 'exits 20 when the context has no subscription' {
            $fixture = Get-DeployFixture
            Mock Get-AzContext {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
                    Subscription = $null
                    Tenant       = [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' }
                }
            }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 20
            Get-LogText | Should -Match 'subscription'
            Should -Invoke Get-AzADUser -Times 0
        }

        It 'exits 20 when the signed-in user cannot be resolved' {
            $fixture = Get-DeployFixture
            Mock Get-AzADUser { throw 'Insufficient privileges to complete the operation.' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 20
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'exits 20 when the service principal lookup returns nothing' {
            $fixture = Get-DeployFixture
            Mock Get-AzContext {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = $script:SpApplicationId; Type = 'ServicePrincipal' }
                    Subscription = [pscustomobject]@{ Id = $script:SubscriptionId; Name = 'Example Subscription' }
                    Tenant       = [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' }
                }
            }
            Mock Get-AzADServicePrincipal { $null }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 20
        }

        It 'switches subscription with Set-AzContext when -SubscriptionId differs from the context' {
            $fixture = Get-DeployFixture
            $other = '99999999-9999-9999-9999-999999999999'

            $exitCode = Invoke-WatchdogDeployment @fixture -SubscriptionId $other

            $exitCode | Should -Be 0
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $other }
            Should -Invoke Invoke-AzRestMethod -ParameterFilter { $Path -like "/subscriptions/$other/*" }
        }

        It 'does not call Set-AzContext when the context already targets -SubscriptionId' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture -SubscriptionId $script:SubscriptionId

            $exitCode | Should -Be 0
            Should -Invoke Set-AzContext -Times 0
        }

        It 'exits 20 when the subscription cannot be selected' {
            $fixture = Get-DeployFixture
            Mock Set-AzContext { throw 'Subscription was not found' }

            $exitCode = Invoke-WatchdogDeployment @fixture -SubscriptionId '99999999-9999-9999-9999-999999999999'

            $exitCode | Should -Be 20
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }
    }

    Context 'Resource group' {
        It 'leaves an existing resource group alone' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke New-AzResourceGroup -Times 0
        }

        It 'creates a missing resource group at -Location' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup { $null }

            $exitCode = Invoke-WatchdogDeployment @fixture -Location 'eastus2'

            $exitCode | Should -Be 0
            Should -Invoke New-AzResourceGroup -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'rg-example' -and $Location -eq 'eastus2'
            }
        }

        It 'exits 1 when the resource group cannot be created' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup { $null }
            Mock New-AzResourceGroup { throw 'LocationNotAvailableForResourceGroup' }

            $exitCode = Invoke-WatchdogDeployment @fixture -Location 'eastus2'

            $exitCode | Should -Be 1
            Get-LogText | Should -Match 'LocationNotAvailableForResourceGroup'
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'exits 20 when creating the resource group is not authorized' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup { $null }
            Mock New-AzResourceGroup { throw 'AuthorizationFailed: The client does not have authorization' }

            $exitCode = Invoke-WatchdogDeployment @fixture -Location 'eastus2'

            $exitCode | Should -Be 20
        }

        It 'exits 2 when the resource group is missing and no -Location was given' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup { $null }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'Location'
            Should -Invoke New-AzResourceGroup -Times 0
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'treats a "does not exist" error from Get-AzResourceGroup as a missing group' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup { throw 'Provided resource group does not exist.' }

            $exitCode = Invoke-WatchdogDeployment @fixture -Location 'eastus2'

            $exitCode | Should -Be 0
            Should -Invoke New-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'rg-example' }
        }

        It 'exits 20 without creating anything when Get-AzResourceGroup is not authorized' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup {
                throw "AuthorizationFailed: The client 'operator@example.com' does not have authorization to perform " +
                    "action 'Microsoft.Resources/subscriptions/resourcegroups/read'."
            }

            $exitCode = Invoke-WatchdogDeployment @fixture -Location 'eastus2'

            $exitCode | Should -Be 20
            Get-LogText | Should -Match 'AuthorizationFailed'
            Get-LogText | Should -Not -Match 'pass -Location'
            Should -Invoke New-AzResourceGroup -Times 0
            Should -Invoke New-AzResourceGroupDeployment -Times 0
        }

        It 'exits 20 when the sign-in token has expired during the resource group lookup' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup {
                throw 'ExpiredAuthenticationToken: The access token expiry UTC time is earlier than current UTC time.'
            }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 20
            Should -Invoke New-AzResourceGroup -Times 0
        }

        It 'exits 1 when Get-AzResourceGroup fails for a reason that is neither missing nor authorization' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup { throw 'No such host is known.' }

            $exitCode = Invoke-WatchdogDeployment @fixture -Location 'eastus2'

            $exitCode | Should -Be 1
            Get-LogText | Should -Match 'No such host'
            Should -Invoke New-AzResourceGroup -Times 0
        }
    }

    Context 'DryRun' {
        It 'runs the deployment with -WhatIf and mutates nothing' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture -DryRun

            $exitCode | Should -Be 0
            Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
            Should -Invoke New-AzResourceGroup -Times 0
            Should -Invoke Set-AzKeyVaultSecret -Times 0
            Should -Invoke Compress-Archive -Times 0
            Should -Invoke Publish-AzWebApp -Times 0
            Should -Invoke Restart-AzWebApp -Times 0
            Should -Invoke Invoke-AzRestMethod -Times 0
            Should -Invoke Invoke-RestMethod -Times 0
            Should -Invoke Show-WatchdogSummary -Times 0
            Get-LogText | Should -Match '\[DRYRUN\]'
        }

        It 'logs the resource group it would create and skips what-if when the group is missing' {
            $fixture = Get-DeployFixture
            Mock Get-AzResourceGroup { $null }

            $exitCode = Invoke-WatchdogDeployment @fixture -Location 'eastus2' -DryRun

            $exitCode | Should -Be 0
            Should -Invoke New-AzResourceGroup -Times 0
            Should -Invoke New-AzResourceGroupDeployment -Times 0
            Get-LogText | Should -Match '\[DRYRUN\].*rg-example'
            Get-LogText | Should -Match '\[WARNING\].*what-if'
        }
    }

    Context 'Template deployment' {
        It 'passes the Bicep parameters by their template names' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly -ParameterFilter {
                $ResourceGroupName -eq 'rg-example' -and $TemplateFile -eq $fixture.TemplatePath
            }
            $parameters = $script:Azure.DeploymentParameters
            $parameters.baseName | Should -Be 'svcwatchdog'
            $parameters.powerShellVersion | Should -Be '7.4'
            $parameters.mailProvider | Should -Be 'Smtp2GoApi'
            $parameters.mailFrom | Should -Be 'Service Watchdog <alerts@example.com>'
            $parameters.mailTo | Should -Be 'it@example.com;oncall@example.com'
            $parameters.mailSubjectPrefix | Should -Be '[Service Watchdog]'
            $parameters.smtpHost | Should -Be ''
            $parameters.smtpPort | Should -Be 587
            $parameters.smtpUsername | Should -Be ''
            $parameters.smtpUseStartTls | Should -BeTrue
            $parameters.Keys | Should -Not -Contain 'smtpPassword'
            $parameters.Keys | Should -Not -Contain 'smtp2GoApiKey'
        }

        It 'passes the SMTP host and user name but never the password for the Smtp provider' {
            $fixture = Get-DeployFixture -MailProvider 'Smtp'

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            $parameters = $script:Azure.DeploymentParameters
            $parameters.mailProvider | Should -Be 'Smtp'
            $parameters.smtpHost | Should -Be 'mail.example.com'
            $parameters.smtpUsername | Should -Be 'relay-user@example.com'
            ($parameters.Values -join ' ') | Should -Not -Match 'REPLACE_WITH_PASSWORD'
        }

        It 'exits 1 when the deployment fails' {
            $fixture = Get-DeployFixture
            Mock New-AzResourceGroupDeployment { throw 'Deployment failed: InvalidTemplate' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 1
            Get-LogText | Should -Match 'InvalidTemplate'
            Should -Invoke Set-AzKeyVaultSecret -Times 0
        }

        It 'exits 20 when the deployment is refused for authorization' {
            $fixture = Get-DeployFixture
            Mock New-AzResourceGroupDeployment {
                throw "AuthorizationFailed: The client does not have authorization to perform action"
            }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 20
        }

        It 'exits 50 when the deployment returns no function app name' {
            $fixture = Get-DeployFixture
            Mock New-AzResourceGroupDeployment { [pscustomobject]@{ ProvisioningState = 'Succeeded'; Outputs = @{} } }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Get-LogText | Should -Match 'functionAppName'
        }
    }

    Context 'Key Vault secrets' {
        It 'seeds only Smtp2GoApiKey for the Smtp2GoApi provider' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $VaultName -eq $script:KeyVaultName -and $Name -eq 'Smtp2GoApiKey' -and
                $SecretValue -is [securestring]
            }
        }

        It 'seeds only SmtpPassword for the Smtp provider' {
            $fixture = Get-DeployFixture -MailProvider 'Smtp'

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
                $VaultName -eq $script:KeyVaultName -and $Name -eq 'SmtpPassword' -and
                $SecretValue -is [securestring]
            }
        }

        It 'retries on 403 while the role assignment propagates' {
            $fixture = Get-DeployFixture
            $script:secretAttempts = 0
            Mock Set-AzKeyVaultSecret {
                $script:secretAttempts++
                if ($script:secretAttempts -le 2) { throw 'Operation returned an invalid status code Forbidden (403)' }
                [pscustomobject]@{ Name = $Name }
            }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Set-AzKeyVaultSecret -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 2
            Get-LogText | Should -Match '\[WARNING\].*403'
        }

        It 'exits 50 without retrying on a non-403 failure' {
            $fixture = Get-DeployFixture
            Mock Set-AzKeyVaultSecret { throw 'The vault was not found (404)' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Should -Invoke Set-AzKeyVaultSecret -Times 1 -Exactly
            Should -Invoke Publish-AzWebApp -Times 0
            Get-LogText | Should -Match 'Smtp2GoApiKey'
        }

        It 'exits 50 after the 5-minute window when 403 persists' {
            $fixture = Get-DeployFixture
            Mock Set-AzKeyVaultSecret { throw 'Forbidden (403)' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Should -Invoke Set-AzKeyVaultSecret -Times 20 -Exactly
            Should -Invoke Publish-AzWebApp -Times 0
        }
    }

    Context 'Package and publish' {
        It 'zips the function folder contents without local.settings*.json' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Compress-Archive -Times 1 -Exactly -ParameterFilter {
                $names = @($Path | ForEach-Object { Split-Path -Path $_ -Leaf })
                $names -contains 'host.json' -and
                $names -contains 'profile.ps1' -and
                $names -contains 'Modules' -and
                $names -contains 'SendServiceWatchdogAlert' -and
                $names -notcontains 'local.settings.json' -and
                $names -notcontains 'local.settings.example.json' -and
                $DestinationPath -like '*.zip'
            }
        }

        It 'publishes the archive with Publish-AzWebApp -Force and removes it afterwards' {
            $fixture = Get-DeployFixture
            $script:publishedArchive = $null
            Mock Publish-AzWebApp {
                $script:publishedArchive = $ArchivePath
                [pscustomobject]@{ Name = $Name }
            }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Publish-AzWebApp -Times 1 -Exactly -ParameterFilter {
                $ResourceGroupName -eq 'rg-example' -and $Name -eq $script:FunctionAppName -and $Force -eq $true
            }
            $script:publishedArchive | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $script:publishedArchive | Should -BeFalse
        }

        It 'exits 50 with the basic-auth hint when the SCM endpoint returns 401' {
            $fixture = Get-DeployFixture
            Mock Publish-AzWebApp { throw 'Response status code does not indicate success: 401 (Unauthorized).' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Get-LogText | Should -Match 'basicPublishingCredentialsPolicies'
            Should -Invoke Restart-AzWebApp -Times 0
        }
    }

    Context 'Restart and admin isolation' {
        It 'restarts the app after publishing so Key Vault references resolve' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Restart-AzWebApp -Times 1 -Exactly -ParameterFilter {
                $ResourceGroupName -eq 'rg-example' -and $Name -eq $script:FunctionAppName
            }
        }

        It 'leaves admin isolation alone when it is already enabled' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 1 -ParameterFilter {
                $Method -eq 'GET' -and $Path -like "*/sites/${script:FunctionAppName}?api-version=2024-04-01"
            }
            Should -Invoke Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'patches admin isolation on and re-checks when it is off' {
            $fixture = Get-DeployFixture
            $script:Azure.AdminIsolation = $false

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'PATCH' -and
                $Path -like "*/sites/${script:FunctionAppName}?api-version=2024-04-01" -and
                ($Payload | ConvertFrom-Json).properties.functionsRuntimeAdminIsolationEnabled -eq $true
            }
            Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly -ParameterFilter {
                $Method -eq 'GET' -and $Path -like "*/sites/${script:FunctionAppName}?api-version=2024-04-01"
            }
        }

        It 'exits 50 when admin isolation is still off after the patch, but only after the key was shown' {
            $fixture = Get-DeployFixture
            $script:Azure.AdminIsolation = $false
            $script:Azure.PatchApplies = $false

            $exitCode = Invoke-WatchdogDeployment @fixture -SendTestEmail

            $exitCode | Should -Be 50
            Get-LogText | Should -Match 'functionsRuntimeAdminIsolationEnabled'
            Get-LogText | Should -Match 'function key was shown above'
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            Should -Invoke Show-WatchdogSummary -Times 1 -Exactly -ParameterFilter {
                $FunctionKey -eq $script:FunctionKeyValue
            }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }

        It 'treats a response without the property as not enabled and logs that it was absent' {
            $fixture = Get-DeployFixture
            $script:Azure.PatchApplies = $false
            Mock Invoke-AzRestMethod {
                return (Get-RestResponse -StatusCode 200 -Content '{ "properties": { "state": "Running" } }')
            } -ParameterFilter { $Method -eq 'GET' -and $Path -match '/sites/[^/?]+\?api-version=' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Get-LogText | Should -Match 'absent from the response'
            Should -Invoke Show-WatchdogSummary -Times 1 -Exactly
        }

        It 'verifies isolation after the key is created rather than before' {
            $script:CallOrder = [System.Collections.Generic.List[string]]::new()
            Mock Show-WatchdogSummary { $script:CallOrder.Add('summary') }
            Mock Confirm-WatchdogAdminIsolation { $script:CallOrder.Add('isolation') }
            $fixture = Get-DeployFixture

            Invoke-WatchdogDeployment @fixture | Should -Be 0

            $script:CallOrder | Should -Be @('summary', 'isolation')
        }
    }

    Context 'Function readiness and key' {
        It 'polls the functions list until SendServiceWatchdogAlert appears' {
            $fixture = Get-DeployFixture
            $script:Azure.FunctionPollsBeforeListed = 2

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 3 -Exactly -ParameterFilter {
                $Method -eq 'GET' -and $Path -like '*/functions?api-version=2024-04-01'
            }
            Should -Invoke Start-Sleep -Times 2 -ParameterFilter { $Seconds -eq 15 }
        }

        It 'exits 50 without creating a key when the function never appears' {
            $fixture = Get-DeployFixture
            $script:Azure.FunctionPollsBeforeListed = 1000

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Should -Invoke Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -eq 'PUT' }
            Should -Invoke Invoke-AzRestMethod -Times 20 -Exactly -ParameterFilter {
                $Method -eq 'GET' -and $Path -like '*/functions?api-version=2024-04-01'
            }
            Get-LogText | Should -Match 'SendServiceWatchdogAlert'
        }

        It 'creates the named key with a properties-wrapped name-only body and retries the PUT on 404' {
            $fixture = Get-DeployFixture
            $script:Azure.KeyPutStatuses.Add(404)

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly -ParameterFilter {
                $Method -eq 'PUT' -and
                $Path -like '*/functions/SendServiceWatchdogAlert/keys/watchdog?api-version=2024-04-01' -and
                ($Payload | ConvertFrom-Json).properties.name -eq 'watchdog' -and
                -not (($Payload | ConvertFrom-Json).properties.PSObject.Properties.Name -contains 'value')
            }
        }

        It 'retries the PUT on 5xx' {
            $fixture = Get-DeployFixture
            $script:Azure.KeyPutStatuses.Add(503)
            $script:Azure.KeyPutStatuses.Add(500)

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 3 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'exits 50 without retrying when the PUT is forbidden' {
            $fixture = Get-DeployFixture
            $script:Azure.KeyPutStatuses.Add(403)

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            # Only the pre-check listkeys ran; nothing is read back after the refused PUT.
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
            Should -Invoke Show-WatchdogSummary -Times 0
        }

        It 'logs the ARM error code and message when the PUT is rejected' {
            $fixture = Get-DeployFixture
            $script:Azure.KeyPutStatuses.Add(400)

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            Get-LogText | Should -Match 'HTTP 400'
            Get-LogText | Should -Match 'BadRequest: Simulated ARM error 400'
        }

        It 'takes the key from the PUT response and hands it to the console summary only' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            # listkeys once before the PUT (is it already there?); the value comes from the PUT itself.
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and
                $Path -like '*/functions/SendServiceWatchdogAlert/listkeys?api-version=2024-04-01'
            }
            Should -Invoke Show-WatchdogSummary -Times 1 -Exactly -ParameterFilter {
                $FunctionKey -eq $script:FunctionKeyValue -and
                $AlertUrl -eq $script:AlertUrl -and
                $KeyVaultName -eq $script:KeyVaultName
            }
            Get-LogText | Should -Match "Function key 'watchdog' created"
            Get-LogText | Should -Not -Match ([regex]::Escape($script:FunctionKeyValue))
            Get-LogText | Should -Not -Match 'DEFAULTKEY'
        }

        It 'reuses an existing key on a re-run instead of regenerating it' {
            $fixture = Get-DeployFixture
            $script:Azure.KeyExists = $true

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -eq 'PUT' }
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and
                $Path -like '*/functions/SendServiceWatchdogAlert/listkeys?api-version=2024-04-01'
            }
            Should -Invoke Show-WatchdogSummary -Times 1 -Exactly -ParameterFilter {
                $FunctionKey -eq $script:FunctionKeyValue
            }
            Get-LogText | Should -Match "Existing function key 'watchdog' reused"
            Get-LogText | Should -Not -Match ([regex]::Escape($script:FunctionKeyValue))
        }

        It 'creates the key when the pre-check listkeys fails with a non-200' {
            $fixture = Get-DeployFixture
            $script:listKeysCalls = 0
            Mock Invoke-AzRestMethod {
                $script:listKeysCalls++
                if ($script:listKeysCalls -eq 1) { return (Get-RestResponse -StatusCode 503 -Content '') }
                $content = @{ properties = @{ watchdog = $script:FunctionKeyValue } } | ConvertTo-Json -Depth 3
                Get-RestResponse -StatusCode 200 -Content $content
            } -ParameterFilter { $Method -eq 'POST' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            Get-LogText | Should -Match 'listkeys on SendServiceWatchdogAlert returned HTTP 503'
        }

        It 'exits 50 when neither the PUT response nor listkeys yields the key value' {
            $fixture = Get-DeployFixture
            $script:Azure.KeyPutOmitsValue = $true
            $script:Azure.ListKeysContent = '{ "default": "OTHERKEY" }'

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            Get-LogText | Should -Match 'watchdog'
            Get-LogText | Should -Not -Match 'OTHERKEY'
            Should -Invoke Show-WatchdogSummary -Times 0
        }

        It 'accepts a listkeys response wrapped in a properties object' {
            $fixture = Get-DeployFixture
            $script:Azure.ListKeysContent = ('{ "properties": { "default": "OTHERKEY", "watchdog": "' +
                $script:FunctionKeyValue + '" } }')

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -eq 'PUT' }
            Should -Invoke Show-WatchdogSummary -Times 1 -Exactly -ParameterFilter {
                $FunctionKey -eq $script:FunctionKeyValue
            }
        }

        It 'falls back to a listkeys read-back when the PUT response carries no value' {
            $fixture = Get-DeployFixture
            $script:Azure.KeyPutOmitsValue = $true

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and $Path -like '*/listkeys?api-version=2024-04-01'
            }
            Should -Invoke Show-WatchdogSummary -Times 1 -Exactly -ParameterFilter {
                $FunctionKey -eq $script:FunctionKeyValue
            }
        }

        It 'never writes the key to the log even when the test email fails' {
            $fixture = Get-DeployFixture
            Mock Invoke-RestMethod {
                throw "401 Unauthorized for key $script:FunctionKeyValue"
            }

            $exitCode = Invoke-WatchdogDeployment @fixture -SendTestEmail

            $exitCode | Should -Be 50
            Get-LogText | Should -Not -Match ([regex]::Escape($script:FunctionKeyValue))
        }
    }

    Context 'Test email' {
        It 'posts a test payload with the key in the x-functions-key header' {
            $fixture = Get-DeployFixture
            $script:testRequest = $null
            Mock Invoke-RestMethod {
                $script:testRequest = @{ Method = $Method; Uri = [string]$Uri; Headers = $Headers; Body = $Body }
                Set-Variable -Name $StatusCodeVariable -Value 200 -Scope Script
                [pscustomobject]@{ accepted = $true; emailSent = $true; duplicate = $false; providerMessageId = 'm-1' }
            }

            $exitCode = Invoke-WatchdogDeployment @fixture -SendTestEmail

            $exitCode | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Post' -and
                [string]$Uri -eq $script:AlertUrl -and
                $Headers['x-functions-key'] -eq $script:FunctionKeyValue -and
                $ContentType -like 'application/json*' -and
                $SkipHttpErrorCheck -eq $true -and
                -not [string]::IsNullOrEmpty($StatusCodeVariable)
            }
            Get-LogText | Should -Match 'HTTP 200'
            $payload = $script:testRequest.Body | ConvertFrom-Json
            $payload.SchemaVersion | Should -Be 1
            $payload.EventType | Should -Be 'test'
            $payload.WatchdogVersion | Should -Be '1.0.0'
            $payload.EventId | Should -Match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
            $payload.RunId | Should -Match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
            # ConvertFrom-Json turns ISO timestamps into [datetime]; check the wire format on the raw body.
            $script:testRequest.Body | Should -Match '"TimestampUtc": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
            $payload.HostName | Should -Match '^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}$'
            $payload.SiteName | Should -Not -BeNullOrEmpty
            @($payload.Services).Count | Should -Be 0
            Get-LogText | Should -Match 'emailSent'
        }

        It 'does not post anything without -SendTestEmail' {
            $fixture = Get-DeployFixture

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 0
        }

        It 'exits 50 and logs the HTTP status and the error code when the function rejects the payload' {
            # Spec 6.4: a rejection is a non-200 with { accepted: false, error, errors }; the
            # script must surface that body, which Invoke-RestMethod hides unless the HTTP
            # error check is skipped.
            $fixture = Get-DeployFixture
            Mock Invoke-RestMethod {
                Set-Variable -Name $StatusCodeVariable -Value 403 -Scope Script
                [pscustomobject]@{
                    accepted = $false
                    error    = 'site_not_allowed'
                    errors   = @('SiteName is not in the allowed list')
                }
            }

            $exitCode = Invoke-WatchdogDeployment @fixture -SendTestEmail

            $exitCode | Should -Be 50
            Get-LogText | Should -Match 'HTTP 403'
            Get-LogText | Should -Match 'site_not_allowed'
            Get-LogText | Should -Match 'not in the allowed list'
        }

        It 'exits 50 with the status when the response carries no accepted field (host-level 401)' {
            $fixture = Get-DeployFixture
            Mock Invoke-RestMethod {
                Set-Variable -Name $StatusCodeVariable -Value 401 -Scope Script
                ''
            }

            $exitCode = Invoke-WatchdogDeployment @fixture -SendTestEmail

            $exitCode | Should -Be 50
            Get-LogText | Should -Match 'HTTP 401'
            Should -Invoke Show-WatchdogSummary -Times 1
        }

        It 'exits 50 with a trimmed body excerpt when the response is not JSON' {
            $fixture = Get-DeployFixture
            Mock Invoke-RestMethod {
                Set-Variable -Name $StatusCodeVariable -Value 503 -Scope Script
                "<html>Service Unavailable`n</html>"
            }

            $exitCode = Invoke-WatchdogDeployment @fixture -SendTestEmail

            $exitCode | Should -Be 50
            Get-LogText | Should -Match 'HTTP 503 \(body: <html>Service Unavailable </html>\)'
        }

        It 'exits 50 when the POST throws' {
            $fixture = Get-DeployFixture
            Mock Invoke-RestMethod { throw 'The operation has timed out.' }

            $exitCode = Invoke-WatchdogDeployment @fixture -SendTestEmail

            $exitCode | Should -Be 50
            Get-LogText | Should -Match 'timed out'
        }
    }

    Context 'Post-deployment failures (exit 50)' {
        It 'exits 50 naming the step when Restart-AzWebApp fails' {
            $fixture = Get-DeployFixture
            Mock Restart-AzWebApp { throw 'Restart failed' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Get-LogText | Should -Match '(?i)restart'
            Should -Invoke Invoke-AzRestMethod -Times 0
        }

        It 'exits 50 when the archive cannot be built' {
            $fixture = Get-DeployFixture
            Mock Compress-Archive { throw 'Access to the path is denied.' }

            $exitCode = Invoke-WatchdogDeployment @fixture

            $exitCode | Should -Be 50
            Should -Invoke Publish-AzWebApp -Times 0
        }

        It 'returns a single integer exit code' {
            $fixture = Get-DeployFixture

            $result = Invoke-WatchdogDeployment @fixture

            @($result).Count | Should -Be 1
            $result | Should -BeOfType [int]
        }
    }

}

Describe 'Install-AzureServiceWatchdogFunction helpers' {

    BeforeEach {
        $script:LogPath = Join-Path -Path $script:TestRoot -ChildPath "helper-$([guid]::NewGuid().ToString('N')).log"
        $script:Verbosity = 'Low'
        $script:DryRun = $false
        Mock Write-Host { }
        Mock Start-Sleep { }
    }

    Context 'Console summary' {
        It 'prints the alert URL, the key, the vault and the two config lines once' {
            $script:consoleLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host { $script:consoleLines.Add([string]$Object) }

            Show-WatchdogSummary -FunctionAppName $script:FunctionAppName -AlertUrl $script:AlertUrl `
                -FunctionKey $script:FunctionKeyValue -KeyVaultName $script:KeyVaultName

            $text = $script:consoleLines -join "`n"
            $text | Should -Match ([regex]::Escape($script:AlertUrl))
            $text | Should -Match ([regex]::Escape($script:KeyVaultName))
            $text | Should -Match ([regex]::Escape("`"Url`": `"$script:AlertUrl`","))
            $text | Should -Match ([regex]::Escape("`"FunctionKey`": `"$script:FunctionKeyValue`","))
            ([regex]::Matches($text, [regex]::Escape($script:FunctionKeyValue))).Count | Should -Be 2
            Get-LogText | Should -Not -Match ([regex]::Escape($script:FunctionKeyValue))
        }
    }

    Context 'Write-Log' {
        It 'writes every level to the file and only errors and success to a Low console' {
            $script:consoleLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host { $script:consoleLines.Add([string]$Object) }

            Write-Log -Message 'info line' -Level 'INFO'
            Write-Log -Message 'warning line' -Level 'WARNING'
            Write-Log -Message 'error line' -Level 'ERROR'
            Write-Log -Message 'success line' -Level 'SUCCESS'

            $logText = Get-LogText
            $logText | Should -Match '\[INFO\] info line'
            $logText | Should -Match '\[WARNING\] warning line'
            $logText | Should -Match '\[ERROR\] error line'
            $logText | Should -Match '\[SUCCESS\] success line'
            $logText | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[INFO\]'
            ($script:consoleLines -join "`n") | Should -Not -Match 'info line'
            ($script:consoleLines -join "`n") | Should -Not -Match 'warning line'
            ($script:consoleLines -join "`n") | Should -Match 'error line'
            ($script:consoleLines -join "`n") | Should -Match 'success line'
        }

        It 'shows warnings at Medium and everything at High' {
            $script:consoleLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host { $script:consoleLines.Add([string]$Object) }

            $script:Verbosity = 'Medium'
            Write-Log -Message 'medium info' -Level 'INFO'
            Write-Log -Message 'medium warning' -Level 'WARNING'
            $script:Verbosity = 'High'
            Write-Log -Message 'high debug' -Level 'DEBUG'

            $console = $script:consoleLines -join "`n"
            $console | Should -Not -Match 'medium info'
            $console | Should -Match 'medium warning'
            $console | Should -Match 'high debug'
        }
    }

    Context 'Invoke-WatchdogRetry' {
        It 'returns the first non-null result without sleeping' {
            $result = Invoke-WatchdogRetry -Description 'probe' -TimeoutSeconds 60 -IntervalSeconds 15 `
                -Action { 'ready' }

            $result | Should -Be 'ready'
            Should -Invoke Start-Sleep -Times 0
        }

        It 'sleeps between null results and returns once the action produces a value' {
            $script:retryCalls = 0

            $result = Invoke-WatchdogRetry -Description 'probe' -TimeoutSeconds 60 -IntervalSeconds 15 -Action {
                $script:retryCalls++
                if ($script:retryCalls -lt 3) { return $null }
                'ready'
            }

            $result | Should -Be 'ready'
            $script:retryCalls | Should -Be 3
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 15 }
        }

        It 'throws naming the description when the window is exhausted' {
            $call = {
                Invoke-WatchdogRetry -Description 'never ready' -TimeoutSeconds 45 -IntervalSeconds 15 -Action { $null }
            }
            $call | Should -Throw '*never ready*'
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }

        It 'retries errors accepted by -RetryOn and rethrows the others at once' {
            $script:retryCalls = 0
            $retryOn = { param ($ErrorRecord) $ErrorRecord.Exception.Message -match 'transient' }

            $result = Invoke-WatchdogRetry -Description 'probe' -TimeoutSeconds 60 -IntervalSeconds 15 `
                -RetryOn $retryOn -Action {
                    $script:retryCalls++
                    if ($script:retryCalls -eq 1) { throw 'transient glitch' }
                    'ready'
                }
            $result | Should -Be 'ready'

            { Invoke-WatchdogRetry -Description 'probe' -TimeoutSeconds 60 -IntervalSeconds 15 -RetryOn $retryOn `
                    -Action { throw 'permanent failure' } } | Should -Throw '*permanent failure*'
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }
    }
}
