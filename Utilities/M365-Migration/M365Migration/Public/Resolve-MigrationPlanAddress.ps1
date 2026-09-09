function Resolve-MigrationPlanAddress {
    <#
    .SYNOPSIS
        Translates one source address into its destination address using the plan map.

    .DESCRIPTION
        Returns a verdict rather than throwing, because an unmapped address is an ordinary
        and expected outcome - a departed employee, a service account that was never in
        scope, a group the plan does not cover - and each one has to be reported on its own
        result row rather than aborting the run.

        An 'smtp:' prefix on the input is stripped before the lookup, so a raw proxy
        address from an inventory works as-is.

    .PARAMETER Map
        The hashtable from Get-MigrationPlanAddressMap.

    .PARAMETER Address
        The source address, UPN, object ID or display name to translate.

    .PARAMETER Role
        What the address represents - 'mailbox', 'trustee', 'manager'. Used only to word
        the skip reason so a results file says which side of the row was unmapped.

    .EXAMPLE
        Resolve-MigrationPlanAddress -Map $map -Address 'jsmith@contoso.com' -Role trustee

        Returns IsMapped $true and the destination address for a trustee the plan covers.

    .EXAMPLE
        (Resolve-MigrationPlanAddress -Map $map -Address 'gone@contoso.com').Detail

        Returns the sentence that goes straight into the result row's Detail column.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Map,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address,

        [ValidateNotNullOrEmpty()]
        [string]$Role = 'object'
    )

    $source = ([string]$Address).Trim() -replace '^(?i)smtp:', ''

    if ([string]::IsNullOrWhiteSpace($source)) {
        return [pscustomobject]@{
            Source   = ''
            Address  = ''
            IsMapped = $false
            Detail   = "The row has no $Role address."
        }
    }

    if ($Map.ContainsKey($source)) {
        return [pscustomobject]@{
            Source   = $source
            Address  = [string]$Map[$source]
            IsMapped = $true
            Detail   = ''
        }
    }

    [pscustomobject]@{
        Source   = $source
        Address  = ''
        IsMapped = $false
        Detail   = "The plan has no destination address for the $Role '$source'."
    }
}
