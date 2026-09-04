#Requires -Version 7.4

<#
.SYNOPSIS
    Timer-triggered Azure Function that emails a digest of servers whose watchdog has gone silent.

.DESCRIPTION
    Entry point for the SendServiceWatchdogDigest function (DESIGN.md section 6.5). Runs on
    the NCRONTAB schedule in WATCHDOG_DIGEST_SCHEDULE and receives every WatchdogHosts row
    through the table input binding. Flow:

      - zero rows: email a distinct "no hosts have ever reported" notice regardless of
        WATCHDOG_DIGEST_ALWAYS_SEND
      - otherwise Get-WatchdogStaleHosts with WATCHDOG_STALE_HOURS; if any host is stale,
        email one digest listing each stale host with its last-seen time and age plus the
        fresh-host count; else, if WATCHDOG_DIGEST_ALWAYS_SEND, email an all-clear summary
      - log the counts either way

    A mail failure is logged as Error and does not throw. An unresolved configuration
    (Get-WatchdogConfig) propagates so the invocation fails visibly in Application Insights.
    The digest is exempt from the per-host rate limit and the dedup check.

.PARAMETER Timer
    The TimerInfo supplied by the Functions runtime (IsPastDue, ScheduleStatus).

.PARAMETER Hosts
    Every row of the WatchdogHosts table, from the table input binding.

.EXAMPLE
    # Invoked by the Functions runtime on the WATCHDOG_DIGEST_SCHEDULE cron expression.
    # Trigger by hand from the portal (Code + Test, Run) or the admin endpoint:
    # POST https://REPLACE-ME.azurewebsites.net/admin/functions/SendServiceWatchdogDigest

.EXAMPLE
    # Local dry run: dot-source with fake rows and Send-WatchdogMail mocked, as
    # Tests/SendServiceWatchdogDigest.Tests.ps1 does. Nothing is sent; this is the DryRun
    # path for the function.
    . .\run.ps1 -Timer @{ IsPastDue = $false } -Hosts @()

.NOTES
    Version : 1.0.0
    Created : 2026-09-04

    Checklist deviations from the powershell-authoring skill (Enterprise tier):
      - 2.1/2.2/2.3/2.4 (-Verbosity, -DryRun, Invoke-Action): the Functions runtime owns
        this script's parameter contract (Timer and Hosts only) and there is no console or
        operator. Dry runs are done by mocking Send-WatchdogMail in the Pester suite.
      - 4.2/4.6/4.7 (Write-Log, file log under $env:ProgramData): no durable filesystem in
        the worker; Write-WatchdogLog writes structured lines that the host forwards to
        Application Insights, which is the log of record for the function app.
      - 5.2 (SecretManagement): secrets arrive as Key Vault references resolved into app
        settings; an unresolved reference makes the invocation fail visibly.
      - 5.7 (code signing): shipped unsigned in the public repository.
      - 6.6/6.7: the operator acceptance run (DESIGN.md section 9) is the integration test;
        run time is bounded by the provider timeout and the host functionTimeout.

    Developed with AI assistance (Claude); reviewed before publication.
#>

[CmdletBinding()]
param (
    [AllowNull()]
    [object]$Timer,

    [AllowNull()]
    [object]$Hosts
)

#region Configuration

$ErrorActionPreference = 'Stop'
$script:DigestFunctionName = 'SendServiceWatchdogDigest'
$script:DigestTimestampFormat = 'yyyy-MM-ddTHH:mm:ssZ'

#endregion

#region Helper Functions

function ConvertTo-DigestHtml {
    <#
    .SYNOPSIS
        HTML-encodes a value for the digest body; null renders as '-'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return '-'
    }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-DigestRowArray {
    <#
    .SYNOPSIS
        Normalizes the table input binding value into an array of rows.

    .DESCRIPTION
        The binding delivers an array for several rows, a single hashtable for one row and
        $null for none. All three become a plain array with nulls removed.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [AllowNull()]
        [object]$Hosts
    )

    if ($null -eq $Hosts) {
        return , @()
    }
    $rows = @(@($Hosts) | Where-Object { $null -ne $_ })
    return , $rows
}

function Format-DigestAge {
    <#
    .SYNOPSIS
        Renders an age in hours for display.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$AgeHours
    )

    if ($null -eq $AgeHours) {
        return 'unknown age'
    }
    return ('{0:0.0} h ago' -f [double]$AgeHours)
}

function ConvertTo-DigestEmail {
    <#
    .SYNOPSIS
        Renders the digest subject, plain-text body and HTML body for one of three cases.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('NoHosts', 'Stale', 'AllClear')]
        [string]$Kind,

        [AllowEmptyCollection()]
        [object[]]$Stale = @(),

        [AllowEmptyCollection()]
        [object[]]$Fresh = @(),

        [Parameter(Mandatory)]
        [object]$Config,

        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $prefix = ([string]$Config.MailSubjectPrefix) -replace '[\r\n]', ''
    $generated = $NowUtc.ToString($script:DigestTimestampFormat, [System.Globalization.CultureInfo]::InvariantCulture)
    $text = [System.Text.StringBuilder]::new()
    $html = [System.Text.StringBuilder]::new()
    [void]$html.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"></head>')
    [void]$html.AppendLine('<body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222">')

    switch ($Kind) {
        'NoHosts' {
            $subject = "$prefix Watchdog digest: no hosts have ever reported"
            $line = ('No hosts have ever reported to this watchdog relay. Either no server has the watchdog ' +
                'installed yet, or every server is failing to reach the function; check the endpoint logs and ' +
                'the function key.')
            [void]$text.AppendLine($line)
            [void]$html.AppendLine('<h2>Watchdog digest</h2><p>' + (ConvertTo-DigestHtml -Value $line) + '</p>')
        }
        'Stale' {
            $staleWord = if ($Stale.Count -eq 1) { 'host' } else { 'hosts' }
            $freshWord = if ($Fresh.Count -eq 1) { 'host' } else { 'hosts' }
            $subject = "$prefix Watchdog digest: $($Stale.Count) stale $staleWord"
            $intro = "$($Stale.Count) stale $staleWord (no report in more than $($Config.StaleHours) hours):"
            [void]$text.AppendLine($intro)
            [void]$html.AppendLine('<h2>Watchdog digest</h2><p>' + (ConvertTo-DigestHtml -Value $intro) + '</p>')
            $tableTag = '<table cellpadding="4" cellspacing="0" border="1" style="border-collapse:collapse">'
            [void]$html.AppendLine($tableTag)
            $headerCells = @('Host', 'Site', 'Last seen (UTC)', 'Age', 'Last event' | ForEach-Object {
                    '<th align="left">' + $_ + '</th>'
                })
            [void]$html.AppendLine('<tr>' + ($headerCells -join '') + '</tr>')
            foreach ($item in $Stale) {
                $age = Format-DigestAge -AgeHours $item.AgeHours
                $lastSeen = if ($null -eq $item.LastSeenUtc) { 'never' } else { [string]$item.LastSeenUtc }
                [void]$text.AppendLine("  $($item.HostName) ($($item.SiteName)): last seen $lastSeen, $age; " +
                    "last event $($item.LastEventType)")
                $cells = @($item.HostName, $item.SiteName, $lastSeen, $age, $item.LastEventType | ForEach-Object {
                        '<td>' + (ConvertTo-DigestHtml -Value $_) + '</td>'
                    })
                [void]$html.AppendLine('<tr>' + ($cells -join '') + '</tr>')
            }
            [void]$html.AppendLine('</table>')
            $freshLine = "$($Fresh.Count) fresh $freshWord reported within the threshold."
            [void]$text.AppendLine('')
            [void]$text.AppendLine($freshLine)
            [void]$html.AppendLine('<p>' + (ConvertTo-DigestHtml -Value $freshLine) + '</p>')
        }
        'AllClear' {
            $freshWord = if ($Fresh.Count -eq 1) { 'host' } else { 'hosts' }
            $subject = "$prefix Watchdog digest: all clear ($($Fresh.Count) $freshWord fresh)"
            $intro = "All clear: $($Fresh.Count) $freshWord reported within the last $($Config.StaleHours) hours."
            [void]$text.AppendLine($intro)
            [void]$html.AppendLine('<h2>Watchdog digest</h2><p>' + (ConvertTo-DigestHtml -Value $intro) + '</p><ul>')
            foreach ($item in $Fresh) {
                $age = Format-DigestAge -AgeHours $item.AgeHours
                $line = "$($item.HostName) ($($item.SiteName)): last seen $($item.LastSeenUtc), $age"
                [void]$text.AppendLine("  $line")
                [void]$html.AppendLine('<li>' + (ConvertTo-DigestHtml -Value $line) + '</li>')
            }
            [void]$html.AppendLine('</ul>')
        }
    }

    $footer = "ServiceWatchdog digest generated $generated"
    [void]$text.AppendLine('')
    [void]$text.AppendLine($footer)
    $footerHtml = ConvertTo-DigestHtml -Value $footer
    [void]$html.AppendLine('<hr><p style="color:#666;font-size:12px">' + $footerHtml + '</p></body></html>')

    return @{
        Subject  = $subject
        TextBody = $text.ToString()
        HtmlBody = $html.ToString()
    }
}

#endregion

#region Main Functions

function Invoke-WatchdogDigestFlow {
    <#
    .SYNOPSIS
        Runs the 6.5 flow: decide which digest (if any) to send, send it, log the counts.
    #>
    [CmdletBinding()]
    param (
        [AllowNull()]
        [object]$Timer,

        [AllowNull()]
        [object]$Hosts,

        [Parameter(Mandatory)]
        [string]$RunId
    )

    $isPastDue = $false
    try {
        $isPastDue = [bool]$Timer.IsPastDue
    }
    catch {
        $isPastDue = $false
    }
    if ($isPastDue) {
        Write-WatchdogLog -Level Warning -RunId $RunId -Message 'Digest timer is running past due'
    }

    # Deliberately not caught: an unresolved configuration must fail the invocation visibly.
    $config = Get-WatchdogConfig

    $rows = ConvertTo-DigestRowArray -Hosts $Hosts
    $email = $null
    $staleCount = 0
    $freshCount = 0
    if ($rows.Count -eq 0) {
        Write-WatchdogLog -Level Warning -RunId $RunId -Message 'Digest: no hosts have ever reported'
        $email = ConvertTo-DigestEmail -Kind NoHosts -Config $config
    }
    else {
        $sets = Get-WatchdogStaleHosts -Rows $rows -StaleHours $config.StaleHours
        $stale = @($sets.Stale)
        $fresh = @($sets.Fresh)
        $staleCount = $stale.Count
        $freshCount = $fresh.Count
        if ($staleCount -gt 0) {
            $email = ConvertTo-DigestEmail -Kind Stale -Stale $stale -Fresh $fresh -Config $config
        }
        elseif ($config.DigestAlwaysSend) {
            $email = ConvertTo-DigestEmail -Kind AllClear -Fresh $fresh -Config $config
        }
    }
    Write-WatchdogLog -RunId $RunId -Message ("Digest: rows=$($rows.Count) stale=$staleCount fresh=$freshCount " +
        "threshold=$($config.StaleHours)h alwaysSend=$($config.DigestAlwaysSend) mail=$($null -ne $email)")

    if ($null -eq $email) {
        return
    }
    try {
        $result = Send-WatchdogMail -Config $config -Subject $email.Subject -TextBody $email.TextBody `
            -HtmlBody $email.HtmlBody
        if ($result.Sent) {
            Write-WatchdogLog -RunId $RunId -Message ("Digest sent via $($config.MailProvider) " +
                "(provider id $($result.ProviderMessageId))")
        }
        else {
            Write-WatchdogLog -Level Error -RunId $RunId -Message "Digest mail failed: $($result.Error)"
        }
    }
    catch {
        Write-WatchdogLog -Level Error -RunId $RunId -Message "Digest mail failed: $($_.Exception.Message)"
    }
}

#endregion

#region Script Body

# The Modules folder is on PSModulePath in the worker; an already-loaded module (tests) is reused.
if (-not (Get-Module -Name 'ServiceWatchdogAlert')) {
    Import-Module -Name 'ServiceWatchdogAlert' -ErrorAction Stop
}
$runId = [guid]::NewGuid().ToString()
Invoke-WatchdogDigestFlow -Timer $Timer -Hosts $Hosts -RunId $runId

#endregion

#region Cleanup

# Nothing to release: no files, connections or temporary resources are held open.

#endregion
