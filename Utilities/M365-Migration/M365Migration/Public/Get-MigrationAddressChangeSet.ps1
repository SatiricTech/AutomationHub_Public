function Get-MigrationAddressChangeSet {
    <#
    .SYNOPSIS
        Computes the EmailAddresses add/remove set for one object from its current
        addresses and the plan's targets.

    .DESCRIPTION
        Pure function - no tenant calls, which is what makes the riskiest decision in the
        toolkit testable offline. It returns three ordered buckets because the order
        matters to Exchange:

          RemoveBeforeAdd  A lowercase 'smtp:' entry that already holds the address we are
                           about to promote. Exchange rejects an add of an address the
                           object already carries, so the alias is released first and
                           re-added immediately as the uppercase primary.
          Add              'SMTP:' primary, then 'smtp:' aliases, then 'X500:' entries.
          RemoveAfterAdd   The demoted old primary, only with -RemoveOldPrimary, and never
                           when it is a protected address. It cannot be removed before the
                           add because an object may not be left without a primary.

        Nothing else is ever removed. Aliases present on the object but absent from the
        plan are left alone, and Test-MigrationProtectedAddress keeps the tenant routing
        address, SIP, SPO and X500 entries out of both removal lists in every case.

        Address values are compared case-insensitively - SMTP addresses are not
        case-sensitive in practice and a plan typed in mixed case must not produce a
        duplicate - while the prefixes written out follow Exchange's convention exactly:
        uppercase 'SMTP:' for the primary, lowercase 'smtp:' for aliases, 'X500:' for
        legacy DNs.

    .PARAMETER CurrentAddress
        The object's current EmailAddresses / proxyAddresses values.

    .PARAMETER TargetPrimarySmtp
        The plan's TargetPrimarySmtp, with or without an 'smtp:' prefix. Ignored when
        'PrimarySmtp' is not in -Apply.

    .PARAMETER TargetAlias
        The plan's TargetAliases entries, with or without an 'smtp:' prefix.

    .PARAMETER TargetX500
        X500 values, with or without an 'X500:' prefix. Usually the source LegacyExchangeDN,
        normalised by ConvertTo-MigrationX500.

    .PARAMETER Apply
        Which of PrimarySmtp, Aliases and X500 to include in the change set.

    .PARAMETER RemoveOldPrimary
        Remove the demoted old primary rather than keeping it as an alias. Protected
        addresses are kept regardless.

    .EXAMPLE
        Get-MigrationAddressChangeSet -CurrentAddress @('SMTP:jsmith@contoso.com', 'smtp:j@contoso.mail.onmicrosoft.com') `
            -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp

        Returns Add = @('SMTP:john.smith@newco.com') and no removals - the old primary is
        demoted to an alias by Exchange and the routing address is protected.

    .EXAMPLE
        Get-MigrationAddressChangeSet -CurrentAddress $mailbox.EmailAddresses `
            -TargetPrimarySmtp $row.TargetPrimarySmtp -TargetAlias (Split-MigrationList -Value $row.TargetAliases) `
            -TargetX500 (ConvertTo-MigrationX500 -Value $row.LegacyExchangeDN) -RemoveOldPrimary

        Full change set for a plan row, dropping the old vanity primary.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$CurrentAddress = @(),

        [AllowEmptyString()]
        [string]$TargetPrimarySmtp = '',

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$TargetAlias = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$TargetX500 = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [ValidateScript({
            $unknown = @($_ | Where-Object { $_ -and $_ -notin @('PrimarySmtp', 'Aliases', 'X500') })
            if ($unknown.Count -gt 0) { throw "Unknown -Apply value(s): $($unknown -join ', '). Use PrimarySmtp, Aliases or X500." }
            $true
        })]
        [string[]]$Apply = @('PrimarySmtp', 'Aliases', 'X500'),

        [switch]$RemoveOldPrimary
    )

    $applied = @($Apply | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $entries = @(@($CurrentAddress) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Split-MigrationProxyAddress -Entry $_ })

    $currentPrimaryEntry = @($entries | Where-Object { $_.IsPrimary }) | Select-Object -First 1
    $currentPrimary = if ($currentPrimaryEntry) { $currentPrimaryEntry.Address } else { '' }

    $removeBefore = [System.Collections.Generic.List[string]]::new()
    $add = [System.Collections.Generic.List[string]]::new()
    $removeAfter = [System.Collections.Generic.List[string]]::new()
    $aliasAdded = [System.Collections.Generic.List[string]]::new()
    $x500Added = [System.Collections.Generic.List[string]]::new()

    $newPrimary = ''
    $primaryDetail = ''

    if ($applied -contains 'PrimarySmtp') {
        $wanted = ([string]$TargetPrimarySmtp).Trim() -replace '^(?i)smtp:', ''
        if ([string]::IsNullOrWhiteSpace($wanted)) {
            $primaryDetail = 'The plan row has no TargetPrimarySmtp.'
        }
        elseif ($wanted -ieq $currentPrimary) {
            $primaryDetail = "Primary SMTP is already $currentPrimary."
        }
        else {
            $held = @($entries | Where-Object { $_.Kind -eq 'Smtp' -and -not $_.IsPrimary -and $_.Address -ieq $wanted }) |
                Select-Object -First 1
            if ($held) {
                # Exchange will not add an address the object already carries, so the alias
                # form is released in a separate call and immediately re-added below as the
                # uppercase primary. The address itself is never absent from the object.
                $removeBefore.Add("smtp:$($held.Address)")
            }

            $add.Add("SMTP:$wanted")
            $newPrimary = $wanted
            $primaryDetail = "Primary SMTP set to $wanted."

            if ($RemoveOldPrimary -and $currentPrimaryEntry) {
                if (Test-MigrationProtectedAddress -AddressEntry $currentPrimaryEntry) {
                    $primaryDetail += " Kept $currentPrimary - protected address."
                }
                else {
                    $removeAfter.Add("smtp:$currentPrimary")
                    $primaryDetail += " Removed the demoted $currentPrimary."
                }
            }
        }
    }

    $effectivePrimary = if ($newPrimary) { $newPrimary } else { $currentPrimary }

    if ($applied -contains 'Aliases') {
        foreach ($candidate in @($TargetAlias)) {
            $alias = ([string]$candidate).Trim() -replace '^(?i)smtp:', ''
            if ([string]::IsNullOrWhiteSpace($alias)) { continue }
            if ($alias -ieq $effectivePrimary) { continue }
            if (@($entries | Where-Object { $_.Kind -eq 'Smtp' -and $_.Address -ieq $alias }).Count -gt 0) { continue }
            if (@($aliasAdded | Where-Object { $_ -ieq $alias }).Count -gt 0) { continue }

            $add.Add("smtp:$alias")
            $aliasAdded.Add($alias)
        }
    }

    if ($applied -contains 'X500') {
        foreach ($candidate in @($TargetX500)) {
            $dn = ([string]$candidate).Trim() -replace '^(?i)x500:', ''
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }
            if (@($entries | Where-Object { $_.Kind -eq 'X500' -and $_.Address -ieq $dn }).Count -gt 0) { continue }
            if (@($x500Added | Where-Object { $_ -ieq $dn }).Count -gt 0) { continue }

            $add.Add("X500:$dn")
            $x500Added.Add($dn)
        }
    }

    [pscustomobject]@{
        CurrentPrimary  = $currentPrimary
        NewPrimary      = $newPrimary
        PrimaryChanged  = [bool]$newPrimary
        PrimaryDetail   = $primaryDetail
        RemoveBeforeAdd = $removeBefore.ToArray()
        Add             = $add.ToArray()
        RemoveAfterAdd  = $removeAfter.ToArray()
        AliasAdded      = $aliasAdded.ToArray()
        X500Added       = $x500Added.ToArray()
    }
}
