#Requires -Version 5.1
<#
.SYNOPSIS
    Detects named user logons on Windows systems, including both local and NLA logons.
.DESCRIPTION
    This script monitors Windows Event Logs for user logon events, filtering out system accounts
    and focusing on actual user logons. It captures both local and network logons.
.NOTES
    Author: Ramon DeWitt
    Version: 1.5
    Date: 2024-03-19
#>

# Check for administrative privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "This script requires administrative privileges to access the Security event log."
    Write-Warning "Please run PowerShell as Administrator and try again."
    exit
}

# Define the event IDs we want to monitor
### Note: This is a list of the relevant IDs but does not include all possible IDs nor does it guarantee those event logs are enabled. For example, 4800 and 4801 are not enabled by default on most systems.
$eventIds = @(
    4624,  # Successful logon
    4625,  # Failed logon
    4647,  # User initiated logoff
    4648,  # Explicit logon
    4778,  # Session reconnection
    4779,  # Session disconnection
    4800,  # Workstation locked (Security log)
    4801   # Workstation unlocked (Security log)
)
$workstationEventIds = @(7001, 7002) # Workstation lock/unlock (System log)

# Define system accounts to filter out
$systemAccounts = @(
    "SYSTEM",
    "LOCAL SERVICE",
    "NETWORK SERVICE",
    "ANONYMOUS LOGON",
    "WORKGROUP"
)

$logonTypeNames = @{
    2  = 'Interactive'
    3  = 'Network'
    4  = 'Batch'
    5  = 'Service'
    7  = 'Unlock'
    8  = 'NetworkCleartext'
    9  = 'NewCredentials'
    10 = 'RemoteInteractive'
    11 = 'CachedInteractive'
}

# Set the time window for log search (in hours)
### Note: This time window is still dependent on how long the logon events are stored in the event log. Many times this is less than 24 hours.
$TimeWindowHours = 24

function Get-NamedLogons {
    param (
        [int]$Hours = $TimeWindowHours,
        [string]$ComputerName = $env:COMPUTERNAME,
        [switch]$ShowAll = $false
    )

    $startTime = (Get-Date).AddHours(-$Hours)
    $userLogonTypes = @(2, 7, 10, 11) # Interactive, Unlock, RemoteInteractive, CachedInteractive

    try {
        Write-Host "Searching for events from $startTime to $(Get-Date)" -ForegroundColor Yellow

        $securityEvents = Get-WinEvent -LogName Security -Force |
            Where-Object { $_.Id -in $eventIds -and $_.TimeCreated -ge $startTime }

        $systemEvents = Get-WinEvent -LogName System -Force |
            Where-Object { $_.Id -in $workstationEventIds -and $_.TimeCreated -ge $startTime }

        $logonEvents = @()

        foreach ($event in $securityEvents) {
            $eventData = $event.Properties
            $addEvent = $true

            if ($event.Id -eq 4624) {
                $username = $eventData[5].Value
                $domain = $eventData[6].Value
                $logonType = $eventData[8].Value
                if ($logonType -match '^[0-9]+$') {
                    $logonTypeName = $logonTypeNames[[int]$logonType]
                    if (-not $logonTypeName) { $logonTypeName = $logonType }
                } else {
                    $logonTypeName = $logonType
                }
                $workstation = $eventData[11].Value
                $ipAddress = $eventData[18].Value
                $logonProcess = $eventData[8].Value
                $authenticationPackage = $eventData[9].Value

                if (-not $ShowAll) {
                    $addEvent = (
                        $logonType -match '^[0-9]+$' -and
                        -not ($systemAccounts -contains $username) -and
                        -not ($systemAccounts -contains $domain) -and
                        ($userLogonTypes -contains [int]$logonType)
                    )
                }

                if ($addEvent) {
                    $logonEvents += [PSCustomObject]@{
                        TimeCreated = $event.TimeCreated
                        EventID = $event.Id
                        Username = "$domain\$username"
                        LogonType = $logonTypeName
                        Workstation = $workstation
                        IPAddress = $ipAddress
                        Status = "Success"
                        EventType = "Logon"
                        LogonProcess = $logonProcess
                        AuthPackage = $authenticationPackage
                    }
                }
            }
            elseif ($event.Id -eq 4625) {
                $username = $eventData[5].Value
                $domain = $eventData[6].Value
                $logonType = $eventData[8].Value
                if ($logonType -match '^[0-9]+$') {
                    $logonTypeName = $logonTypeNames[[int]$logonType]
                    if (-not $logonTypeName) { $logonTypeName = $logonType }
                } else {
                    $logonTypeName = $logonType
                }
                $workstation = $eventData[11].Value
                $ipAddress = $eventData[18].Value
                $logonProcess = $eventData[8].Value
                $authenticationPackage = $eventData[9].Value

                if (-not $ShowAll) {
                    $addEvent = (
                        $logonType -match '^[0-9]+$' -and
                        -not ($systemAccounts -contains $username) -and
                        -not ($systemAccounts -contains $domain) -and
                        ($userLogonTypes -contains [int]$logonType)
                    )
                }

                if ($addEvent) {
                    $logonEvents += [PSCustomObject]@{
                        TimeCreated = $event.TimeCreated
                        EventID = $event.Id
                        Username = "$domain\$username"
                        LogonType = $logonTypeName
                        Workstation = $workstation
                        IPAddress = $ipAddress
                        Status = "Failed"
                        EventType = "Logon"
                        LogonProcess = $logonProcess
                        AuthPackage = $authenticationPackage
                    }
                }
            }
            elseif ($event.Id -eq 4648) {
                $username = $eventData[5].Value
                $domain = $eventData[6].Value
                $logonType = $eventData[8].Value
                if ($logonType -match '^[0-9]+$') {
                    $logonTypeName = $logonTypeNames[[int]$logonType]
                    if (-not $logonTypeName) { $logonTypeName = $logonType }
                } else {
                    $logonTypeName = $logonType
                }
                $workstation = $eventData[11].Value
                $ipAddress = $eventData[12].Value
                $processName = $eventData[13].Value

                if (-not $ShowAll) {
                    $addEvent = (
                        $logonType -match '^[0-9]+$' -and
                        -not ($systemAccounts -contains $username) -and
                        -not ($systemAccounts -contains $domain) -and
                        ($userLogonTypes -contains [int]$logonType)
                    )
                }

                if ($addEvent) {
                    $logonEvents += [PSCustomObject]@{
                        TimeCreated = $event.TimeCreated
                        EventID = $event.Id
                        Username = "$domain\$username"
                        LogonType = $logonTypeName
                        Workstation = $workstation
                        IPAddress = $ipAddress
                        Status = "Success"
                        EventType = "Explicit Logon"
                        ProcessName = $processName
                    }
                }
            }
            elseif ($event.Id -eq 4647) {
                $username = $eventData[1].Value
                $domain = $eventData[2].Value

                if (-not $ShowAll) {
                    $addEvent = (
                        -not ($systemAccounts -contains $username) -and
                        -not ($systemAccounts -contains $domain)
                    )
                }

                if ($addEvent) {
                    $logonEvents += [PSCustomObject]@{
                        TimeCreated = $event.TimeCreated
                        EventID = $event.Id
                        Username = "$domain\\$username"
                        LogonType = "N/A"
                        Workstation = "N/A"
                        IPAddress = "N/A"
                        Status = "Logoff"
                        EventType = "Logoff"
                    }
                }
            }
            elseif ($event.Id -eq 4800) {
                # Workstation locked (Security log)
                $username = $eventData[1].Value
                $domain = $eventData[2].Value
                if (-not $ShowAll) {
                    $addEvent = (
                        -not ($systemAccounts -contains $username) -and
                        -not ($systemAccounts -contains $domain)
                    )
                }
                if ($addEvent) {
                    $logonEvents += [PSCustomObject]@{
                        TimeCreated = $event.TimeCreated
                        EventID = $event.Id
                        Username = "$domain\$username"
                        LogonType = "Workstation"
                        Workstation = $env:COMPUTERNAME
                        IPAddress = "N/A"
                        Status = "Locked"
                        EventType = "Workstation (Security)"
                    }
                }
            }
            elseif ($event.Id -eq 4801) {
                # Workstation unlocked (Security log)
                $username = $eventData[1].Value
                $domain = $eventData[2].Value
                if (-not $ShowAll) {
                    $addEvent = (
                        -not ($systemAccounts -contains $username) -and
                        -not ($systemAccounts -contains $domain)
                    )
                }
                if ($addEvent) {
                    $logonEvents += [PSCustomObject]@{
                        TimeCreated = $event.TimeCreated
                        EventID = $event.Id
                        Username = "$domain\$username"
                        LogonType = "Workstation"
                        Workstation = $env:COMPUTERNAME
                        IPAddress = "N/A"
                        Status = "Unlocked"
                        EventType = "Workstation (Security)"
                    }
                }
            }
        }

        foreach ($event in $systemEvents) {
            $eventData = $event.Properties
            $username = $eventData[1].Value
            $domain = $env:USERDOMAIN

            $addEvent = $true
            if (-not $ShowAll) {
                $addEvent = (
                    -not ($systemAccounts -contains $username) -and
                    -not ($systemAccounts -contains $domain)
                )
            }

            if ($addEvent) {
                $status = switch ($event.Id) {
                    7001 { "Locked" }
                    7002 { "Unlocked" }
                }

                $logonEvents += [PSCustomObject]@{
                    TimeCreated = $event.TimeCreated
                    EventID = $event.Id
                    Username = "$domain\\$username"
                    LogonType = "Workstation"
                    Workstation = $env:COMPUTERNAME
                    IPAddress = "N/A"
                    Status = $status
                    EventType = "Workstation"
                }
            }
        }

        if ($logonEvents.Count -eq 0) {
            Write-Warning "No logon events found in the specified time period."
            return
        }

        Write-Host "`nFound $($logonEvents.Count) logon events" -ForegroundColor Green
        $logonEvents | Sort-Object TimeCreated -Descending

    }
    catch {
        Write-Error "Error retrieving logon events: $_"
    }
}

# Example usage WITHOUT debug
$logons = Get-NamedLogons -Hours $TimeWindowHours
$logons | Format-Table -Property TimeCreated,EventID,Username,LogonType,Workstation,IPAddress,Status,EventType,LogonProcess,AuthPackage,ProcessName -AutoSize

# Export to CSV if needed
# $logons | Export-Csv -Path \"LogonEvents.csv\" -NoTypeInformation
