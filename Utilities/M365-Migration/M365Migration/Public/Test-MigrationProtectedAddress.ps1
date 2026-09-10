function Test-MigrationProtectedAddress {
    <#
    .SYNOPSIS
        Reports whether an address must never be removed from an object.

    .DESCRIPTION
        Four classes of address are load-bearing after a tenant move, and they are
        protected here rather than at each call site so no future edit can forget one:

          - the tenant routing address (MOERA, *.onmicrosoft.com), which Exchange Online
            uses internally and will not let you delete cleanly;
          - SIP addresses, which Teams and Skype sign-in are keyed to;
          - SPO addresses, which SharePoint owns;
          - X500 addresses, which are the whole reason cached Outlook entries and replies
            to old mail still resolve after a cross-tenant move.

        Anything with an unrecognised prefix (EUM, for instance) is protected too. The
        migration's job is to add the new identity, not to prune what a previous
        administrator had a reason to leave behind.

    .PARAMETER Address
        A raw proxy address, with or without a prefix - 'smtp:john@contoso.mail.onmicrosoft.com',
        'SIP:john@contoso.com' or a bare 'john@contoso.com'.

    .PARAMETER AddressEntry
        An already-split entry from Split-MigrationProxyAddress, when the caller has one
        in hand and does not want to parse it twice.

    .EXAMPLE
        Test-MigrationProtectedAddress -Address 'smtp:john@contoso.mail.onmicrosoft.com'

        Returns $true - the tenant routing address is never removed.

    .EXAMPLE
        Test-MigrationProtectedAddress -AddressEntry (Split-MigrationProxyAddress -Entry 'smtp:jsmith@contoso.com')

        Returns $false - an ordinary vanity alias may be demoted or removed.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Address')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Address', Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address,

        [Parameter(Mandatory, ParameterSetName = 'Parsed')]
        [ValidateNotNull()]
        $AddressEntry
    )

    process {
        $entry = if ($PSCmdlet.ParameterSetName -eq 'Parsed') {
            $AddressEntry
        }
        else {
            Split-MigrationProxyAddress -Entry $Address
        }

        $kind = [string](Get-MigrationProperty -InputObject $entry -Name 'Kind' -Default 'Smtp')
        if ($kind -in @('Sip', 'X500', 'Spo', 'Other')) { return $true }

        $value = [string](Get-MigrationProperty -InputObject $entry -Name 'Address' -Default '')
        if ($value -match '(?i)\.onmicrosoft\.com$') { return $true }

        return $false
    }
}
