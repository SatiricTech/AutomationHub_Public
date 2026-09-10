function Get-MigrationPhoneNumberInventory {
    <#
    .SYNOPSIS
        Returns the tenant's whole telephone number inventory, paging until it is exhausted.

    .DESCRIPTION
        Get-CsPhoneNumberAssignment returns a bounded page and gives no indication that
        more numbers exist, so a caller that does not page itself silently loses the tail
        on any tenant with more numbers than the page size. That is the failure this
        wrapper exists to prevent: it walks -Skip until a short page comes back, which is
        the only reliable end-of-inventory signal the cmdlet offers.

        -Filter splats extra named arguments onto the cmdlet, so any server-side filter it
        supports is available without this function having to know about it.

    .PARAMETER Filter
        Named arguments passed straight to Get-CsPhoneNumberAssignment, for example
        @{ PstnAssignmentStatus = 'Unassigned' } or @{ CapabilitiesContain = 'UserAssignment' }.

    .PARAMETER PageSize
        Numbers per request. 1000 is the largest value the cmdlet accepts today; lowering
        it only helps when a tenant times out on the larger page.

    .EXAMPLE
        $numbers = Get-MigrationPhoneNumberInventory

        Returns every number in the tenant's inventory.

    .EXAMPLE
        Get-MigrationPhoneNumberInventory -Filter @{ PstnAssignmentStatus = 'Unassigned' }

        Returns only the numbers no one holds - the pool a wave can draw from.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        Requires an active MicrosoftTeams session; call Connect-MigrationTeams first.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [hashtable]$Filter = @{},

        [ValidateRange(1, 1000)]
        [int]$PageSize = 1000
    )

    $arguments = if ($null -ne $Filter) { $Filter } else { @{} }

    $all = [System.Collections.Generic.List[object]]::new()
    $skip = 0
    while ($true) {
        try {
            $page = @(Get-CsPhoneNumberAssignment @arguments -Top $PageSize -Skip $skip -ErrorAction Stop)
        }
        catch {
            throw "Could not read the telephone number inventory at offset ${skip}: $($_.Exception.Message)"
        }

        if ($page.Count -gt 0) { $all.AddRange($page) }
        if ($page.Count -lt $PageSize) { break }
        $skip += $PageSize
    }

    return $all.ToArray()
}
