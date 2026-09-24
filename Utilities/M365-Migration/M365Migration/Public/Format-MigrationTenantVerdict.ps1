function Format-MigrationTenantVerdict {
    <#
    .SYNOPSIS
        Says, in one sentence, which tenant a finished run actually reached.

    .DESCRIPTION
        The post-run tenant check has three outcomes and each needs different words
        (Docs/Workbench-Design.md, section 7.2). The three front ends used to restate them, and
        two of the three restated the worst case wrongly.

          nothing expected   The step signs in to no tenant, so nothing was checked.
          verified           Every connection line in the child's output named the expected
                             tenant.
          a different tenant The child signed in somewhere else. The GUIDs it reached are named,
                             because that is what an operator compares against Settings.
          no line at all     Nothing in the output named a tenant. That is a sign-in failure,
                             not a mismatch: calling it 'signed in to no tenant at all' sends an
                             operator looking for a wrong GUID that was never there, when the
                             step either did not sign in or its connector printed nothing.

        Both failing outcomes come back from TenantVerified = $false, which is why they are told
        apart here rather than in each front end.

    .PARAMETER Result
        The result object from Invoke-MigrationStep. Its TenantVerified, ConnectedTenantIds and
        ExpectedTenantId are read; a hand-built object missing any of them still returns a
        sentence, because this renders a report and must never be the thing that throws.

    .EXAMPLE
        Format-MigrationTenantVerdict -Result $result

        Returns 'Tenant verified.' for a run that reached the tenant it was given.

    .EXAMPLE
        Format-MigrationTenantVerdict -Result $result

        Returns "No tenant line was found in the run's output - the step did not sign in, or its
        connector printed nothing; expected 00000000-0000-0000-0000-000000000000." for a run that
        connected to nothing.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Result
    )

    $verified = Get-MigrationProperty -InputObject $Result -Name 'TenantVerified' -Default $null
    if ($null -eq $verified) { return 'No tenant was expected for this step, so none was checked.' }
    if ([bool]$verified) { return 'Tenant verified.' }

    $connected = @(Get-MigrationProperty -InputObject $Result -Name 'ConnectedTenantIds' -Default @())
    if ($connected.Count -gt 0) {
        return "This run signed in to $($connected -join ', '), which is not the tenant it was given."
    }

    # The expected GUID is on the result, and on the ledger entry it wrote, so a caller holding
    # either object gets the same sentence.
    $expected = [string](Get-MigrationProperty -InputObject $Result -Name 'ExpectedTenantId' -Default '')
    if (-not $expected) {
        $entry = Get-MigrationProperty -InputObject $Result -Name 'LedgerEntry' -Default $null
        $expected = [string](Get-MigrationProperty -InputObject $entry -Name 'TenantId' -Default '')
    }
    if (-not $expected) { $expected = 'the tenant in Settings' }

    return ("No tenant line was found in the run's output — the step did not sign in, or its " +
        "connector printed nothing; expected $expected.")
}
