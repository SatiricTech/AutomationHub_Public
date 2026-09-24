#Requires -Version 7.4

<#
    Test double for the 17 toolkit scripts: it does nothing but report how it was bound.

    New-MigrationStepDriver and Invoke-MigrationStep are only trustworthy if a value survives
    the trip from the resolver, through a generated driver file, into a real child pwsh - so
    the tests run this through that whole path and read the JSON back. -ExitWith gives the
    exit-code meanings something to look up, -SleepSeconds gives the cancel test something to
    kill, and the tenant line is the exact wording Connect-MigrationGraph writes, which is what
    Invoke-MigrationStep scrapes for tenant verification.

    -ClientSecret stands in for the one secret the toolkit takes. It is reported by type and
    length only - never by value - because the test that proves the secret reached the child
    must not be the thing that writes it to a transcript.

    Author: AutomationHub
    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The parameters exist to be echoed through $PSBoundParameters, not to be used.')]
param([string]$PlanPath, [string[]]$Wave, [switch]$DryRun, [bool]$ForceChangePassword = $true,
    [hashtable]$AliasDomainMap, [string]$Prefix, [string]$OutputPath, [int]$ExitWith = 0, [string]$TenantId,
    [string]$Verbosity, [switch]$Confirm, [int]$SleepSeconds = 0, [securestring]$ClientSecret,
    [ValidateSet('Graph', 'Exchange', 'ExchangeCached')][string]$ConnectAs = 'Graph')

# A SecureString is never serialised: its type and length are the proof that it bound, and
# they are all a test needs.
$bound = $PSBoundParameters
if ($PSBoundParameters.ContainsKey('ClientSecret')) {
    $bound = @{}
    foreach ($name in $PSBoundParameters.Keys) {
        if ($name -ne 'ClientSecret') { $bound[$name] = $PSBoundParameters[$name] }
    }
}
$bound | ConvertTo-Json -Depth 4 -Compress
if ($PSBoundParameters.ContainsKey('ClientSecret')) {
    "ClientSecretType=$($ClientSecret.GetType().Name)"
    "ClientSecretLength=$($ClientSecret.Length)"
}
if ($env:M365MIGRATION_TEST) { "M365MIGRATION_TEST=$env:M365MIGRATION_TEST" }
if ($TenantId) {
    # The exact wording each connector logs, which is what Invoke-MigrationStep scrapes.
    switch ($ConnectAs) {
        'Exchange' {
            'Connected to Exchange Online - organisation contoso.onmicrosoft.com ' +
            "(tenant $TenantId) as echo@contoso.com."
        }
        'ExchangeCached' { "Reusing the cached Exchange Online session for tenant $TenantId as echo@contoso.com." }
        default { "Connected to Microsoft Graph - tenant $TenantId (Echo) as echo@contoso.com." }
    }
}
if ($SleepSeconds -gt 0) { Start-Sleep -Seconds $SleepSeconds }
exit $ExitWith
