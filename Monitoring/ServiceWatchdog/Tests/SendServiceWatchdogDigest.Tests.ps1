<#
.SYNOPSIS
    Pester tests for the SendServiceWatchdogDigest timer function (run.ps1).

.DESCRIPTION
    Exercises the flow in DESIGN.md section 6.5 by dot-sourcing run.ps1 with a fake $Timer
    and a fake $Hosts table-input array. Send-WatchdogMail, Get-WatchdogConfig and
    Write-WatchdogLog are mocked so no mail is sent and nothing leaves the process.
#>

BeforeAll {
    $script:ModuleName = 'ServiceWatchdogAlert'
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'AzureFunction' 'Modules' $script:ModuleName `
        "$($script:ModuleName).psd1"
    Import-Module $script:ModulePath -Force
    $script:RunPath = Join-Path $PSScriptRoot '..' 'AzureFunction' 'SendServiceWatchdogDigest' 'run.ps1'
    $script:FunctionJsonPath = Join-Path $PSScriptRoot '..' 'AzureFunction' 'SendServiceWatchdogDigest' 'function.json'

    function New-HostRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory hashtable.'
        )]
        param (
            [Parameter(Mandatory)]
            [string]$HostName,

            [Parameter(Mandatory)]
            [int]$AgeHours,

            [string]$SiteName = 'Example Org'
        )

        return @{
            PartitionKey          = $SiteName
            RowKey                = $HostName
            LastSeenUtc           = [datetime]::UtcNow.AddHours(-$AgeHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
            LastEventType         = 'heartbeat'
            WatchdogVersion       = '1.0.0'
            MonitoredServiceCount = 3
            ProblemServiceCount   = 0
        }
    }

    function Invoke-DigestFunction {
        param (
            [object[]]$Hosts = @()
        )

        $timer = @{
            IsPastDue      = $false
            ScheduleStatus = @{ Last = '2026-09-03T07:00:00Z'; Next = '2026-09-05T07:00:00Z' }
        }
        . $script:RunPath -Timer $timer -Hosts $Hosts
    }

    function New-DigestConfig {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory object.'
        )]
        param (
            [bool]$AlwaysSend = $false,

            [int]$StaleHours = 26
        )

        # Runs inside the module scope so the real Get-WatchdogConfig is used even while the
        # test scope has it mocked.
        $module = Get-Module -Name $script:ModuleName
        return (& $module { param($Environment) Get-WatchdogConfig -Environment $Environment } @{
            WATCHDOG_MAIL_PROVIDER      = 'Smtp2GoApi'
            WATCHDOG_MAIL_FROM          = 'Service Watchdog <alerts@example.com>'
            WATCHDOG_MAIL_TO            = 'it@example.com'
            WATCHDOG_SMTP2GO_API_KEY    = 'unit-test-api-key'
            WATCHDOG_TABLE_ENDPOINT     = 'https://example.table.core.windows.net/'
            WATCHDOG_STALE_HOURS        = "$StaleHours"
            WATCHDOG_DIGEST_ALWAYS_SEND = $AlwaysSend.ToString().ToLowerInvariant()
        })
    }
}

Describe 'SendServiceWatchdogDigest run.ps1' {

    BeforeEach {
        $script:TestConfig = New-DigestConfig
        Mock Write-WatchdogLog { }
        Mock Get-WatchdogConfig { $script:TestConfig }
        Mock Send-WatchdogMail { @{ Sent = $true; ProviderMessageId = 'email-123'; Error = $null; StatusCode = 200 } }
    }

    Context 'function.json' {

        It 'declares the timer trigger and the WatchdogHosts table input' {
            $json = Get-Content -LiteralPath $script:FunctionJsonPath -Raw | ConvertFrom-Json
            $timer = $json.bindings | Where-Object { $_.type -eq 'timerTrigger' }
            $timer.schedule | Should -Be '%WATCHDOG_DIGEST_SCHEDULE%'
            $timer.runOnStartup | Should -BeFalse
            $timer.name | Should -Be 'Timer'
            $table = $json.bindings | Where-Object { $_.type -eq 'table' }
            $table.direction | Should -Be 'in'
            $table.name | Should -Be 'Hosts'
            $table.tableName | Should -Be 'WatchdogHosts'
            $table.connection | Should -Be 'AzureWebJobsStorage'
            foreach ($property in 'partitionKey', 'rowKey', 'filter', 'take') {
                $table.PSObject.Properties.Name | Should -Not -Contain $property
            }
        }
    }

    Context 'No hosts have ever reported' {

        It 'sends the distinct notice when always-send is <AlwaysSend>' -ForEach @(
            @{ AlwaysSend = $false }
            @{ AlwaysSend = $true }
        ) {
            $script:TestConfig = New-DigestConfig -AlwaysSend $AlwaysSend
            Invoke-DigestFunction -Hosts @()
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly -ParameterFilter {
                $TextBody -like '*no hosts have ever reported*' -and $Subject -like '[[]Service Watchdog]*'
            }
        }

        It 'treats a null input binding as zero rows' {
            Invoke-DigestFunction -Hosts $null
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly -ParameterFilter {
                $TextBody -like '*no hosts have ever reported*'
            }
        }
    }

    Context 'Stale hosts' {

        It 'sends one digest listing every stale host with its age and the fresh count' {
            $rows = @(
                (New-HostRow -HostName 'SRV-STALE-01' -AgeHours 50)
                (New-HostRow -HostName 'SRV-STALE-02' -AgeHours 30 -SiteName 'Other Org')
                (New-HostRow -HostName 'SRV-FRESH-01' -AgeHours 2)
            )
            Invoke-DigestFunction -Hosts $rows
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly -ParameterFilter {
                $Subject -like '*2 stale host*' -and
                $TextBody -like '*SRV-STALE-01*' -and $TextBody -like '*SRV-STALE-02*' -and
                $TextBody -notlike '*SRV-FRESH-01*' -and
                $TextBody -like '*Other Org*' -and
                $TextBody -match 'SRV-STALE-01.*\b(49|50)(\.\d+)? h' -and
                $TextBody -like '*1 fresh host*' -and
                $HtmlBody -like '*SRV-STALE-01*' -and $HtmlBody -like '*SRV-STALE-02*'
            }
        }

        It 'HTML-encodes host and site names in the digest' {
            $rows = @((New-HostRow -HostName 'SRV<b>1' -AgeHours 50 -SiteName 'Site<i>X'))
            Invoke-DigestFunction -Hosts $rows
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly -ParameterFilter {
                $HtmlBody -like '*SRV&lt;b&gt;1*' -and
                $HtmlBody -notlike '*SRV<b>1*' -and
                $HtmlBody -like '*Site&lt;i&gt;X*'
            }
        }

        It 'lists at most 200 stale hosts and says how many more there are' {
            $rows = @(1..205 | ForEach-Object { New-HostRow -HostName ('SRV-STALE-{0:000}' -f $_) -AgeHours 50 })
            Invoke-DigestFunction -Hosts $rows
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly -ParameterFilter {
                $Subject -like '*205 stale hosts*' -and
                $TextBody -like '*SRV-STALE-200*' -and
                $TextBody -notlike '*SRV-STALE-201*' -and
                $TextBody -like '*and 5 more stale hosts not listed*' -and
                $HtmlBody -like '*and 5 more stale hosts not listed*'
            }
        }

        It 'warns when the table holds more rows than any fleet should produce' {
            $rows = @(1..1001 | ForEach-Object { New-HostRow -HostName ('SRV-{0:0000}' -f $_) -AgeHours 1 })
            Invoke-DigestFunction -Hosts $rows
            Should -Invoke Write-WatchdogLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*1001 rows*' -and $Message -like '*leaked function key*'
            }
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
        }

        It 'accepts a single row that arrives as one hashtable rather than an array' {
            $row = New-HostRow -HostName 'SRV-STALE-01' -AgeHours 50
            $timer = @{ IsPastDue = $false }
            . $script:RunPath -Timer $timer -Hosts $row
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly -ParameterFilter { $TextBody -like '*SRV-STALE-01*' }
        }
    }

    Context 'Nothing stale' {

        It 'sends nothing when always-send is off' {
            Invoke-DigestFunction -Hosts @((New-HostRow -HostName 'SRV-FRESH-01' -AgeHours 2))
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
            Should -Invoke Write-WatchdogLog -ParameterFilter { $Message -like '*stale=0*' }
        }

        It 'sends an all-clear summary when always-send is on' {
            $script:TestConfig = New-DigestConfig -AlwaysSend $true
            $rows = @(
                (New-HostRow -HostName 'SRV-FRESH-01' -AgeHours 2)
                (New-HostRow -HostName 'SRV-FRESH-02' -AgeHours 1)
            )
            Invoke-DigestFunction -Hosts $rows
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly -ParameterFilter {
                $Subject -like '*all clear*' -and $TextBody -like '*2 host*' -and $TextBody -like '*SRV-FRESH-01*'
            }
        }
    }

    Context 'Failures' {

        It 'logs an error and does not throw when the mail provider fails' {
            Mock Send-WatchdogMail {
                @{ Sent = $false; ProviderMessageId = $null; Error = 'sender not verified'; StatusCode = 400 }
            }
            { Invoke-DigestFunction -Hosts @() } | Should -Not -Throw
            Should -Invoke Write-WatchdogLog -ParameterFilter {
                $Level -eq 'Error' -and $Message -like '*sender not verified*'
            }
        }

        It 'logs an error and does not throw when the mail call throws' {
            Mock Send-WatchdogMail { throw 'boom' }
            { Invoke-DigestFunction -Hosts @() } | Should -Not -Throw
            Should -Invoke Write-WatchdogLog -ParameterFilter { $Level -eq 'Error' -and $Message -like '*boom*' }
        }

        It 'lets an unresolved configuration propagate' {
            Mock Get-WatchdogConfig {
                throw 'App setting WATCHDOG_SMTP2GO_API_KEY is an unresolved Key Vault reference'
            }
            { Invoke-DigestFunction -Hosts @() } | Should -Throw -ExpectedMessage '*WATCHDOG_SMTP2GO_API_KEY*'
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
        }

        It 'logs when the timer fired late' {
            $timer = @{ IsPastDue = $true }
            . $script:RunPath -Timer $timer -Hosts @()
            Should -Invoke Write-WatchdogLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*past due*' }
        }
    }
}
