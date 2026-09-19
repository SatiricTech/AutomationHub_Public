function Get-MigrationAddressChangeSet {
    <#
    .SYNOPSIS
        Computes the EmailAddresses add/remove set for one object from its current
        addresses and the plan's targets.

    .DESCRIPTION
        Pure function - no tenant calls, which is what makes the riskiest decision in the
        toolkit testable offline. Promoting an address the object already carries and adding
        one it does not are different Exchange calls, so the result describes both:

          PromoteInPlace   True when the wanted primary is already on the object as a
                           lowercase 'smtp:' alias.
          ReplaceWith      The object's whole address list for that case - every entry
                           unchanged except the wanted address recased to 'SMTP:' and the old
                           primary recased to 'smtp:' (dropped with -RemoveOldPrimary unless
                           it is protected). Written in one Set-Mailbox -EmailAddresses call,
                           which replaces every proxy address at once, so the address is never
                           absent from the object. Empty in every other case.
          Add              'SMTP:' primary - add case only, because the promote case carries
                           it in ReplaceWith - then 'smtp:' aliases, then 'X500:' entries.
          RemoveAfterAdd   The demoted old primary, only with -RemoveOldPrimary, never when it
                           is a protected address, and never in the promote case, where the
                           demotion is part of ReplaceWith. It cannot be removed before the add
                           because an object may not be left without a primary.
          RemoveBeforeAdd  Always empty. Kept on the output object for compatibility with
                           callers written against the older release-then-re-add shape.

        Nothing else is ever removed. Aliases present on the object but absent from the
        plan are left alone, and Test-MigrationProtectedAddress keeps the tenant routing
        address, SIP, SPO and X500 entries out of the removal list in every case.

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
        Get-MigrationAddressChangeSet -CurrentAddress @('SMTP:jsmith@contoso.com', 'smtp:john.smith@newco.com') `
            -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp

        The object already carries the target as an alias, so PromoteInPlace is true and
        ReplaceWith is @('smtp:jsmith@contoso.com', 'SMTP:john.smith@newco.com') - one call.

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

    # Indexes rather than object references: the replacement list below has to rebuild the
    # object's addresses in their original order, recasing exactly two of them.
    $currentPrimaryIndex = -1
    for ($position = 0; $position -lt $entries.Count; $position++) {
        if ($entries[$position].IsPrimary) { $currentPrimaryIndex = $position; break }
    }
    $currentPrimaryEntry = if ($currentPrimaryIndex -ge 0) { $entries[$currentPrimaryIndex] } else { $null }
    $currentPrimary = if ($currentPrimaryEntry) { $currentPrimaryEntry.Address } else { '' }

    $removeBefore = [System.Collections.Generic.List[string]]::new()
    $replaceWith = [System.Collections.Generic.List[string]]::new()
    $add = [System.Collections.Generic.List[string]]::new()
    $removeAfter = [System.Collections.Generic.List[string]]::new()
    $aliasAdded = [System.Collections.Generic.List[string]]::new()
    $x500Added = [System.Collections.Generic.List[string]]::new()

    $newPrimary = ''
    $primaryDetail = ''
    $promoteInPlace = $false

    if ($applied -contains 'PrimarySmtp') {
        $wanted = ([string]$TargetPrimarySmtp).Trim() -replace '^(?i)smtp:', ''
        if ([string]::IsNullOrWhiteSpace($wanted)) {
            $primaryDetail = 'The plan row has no TargetPrimarySmtp.'
        }
        elseif ($wanted -ieq $currentPrimary) {
            $primaryDetail = "Primary SMTP is already $currentPrimary."
        }
        else {
            $heldIndex = -1
            for ($position = 0; $position -lt $entries.Count; $position++) {
                $entry = $entries[$position]
                if ($entry.Kind -eq 'Smtp' -and -not $entry.IsPrimary -and $entry.Address -ieq $wanted) {
                    $heldIndex = $position
                    break
                }
            }

            $newPrimary = $wanted
            $primaryDetail = "Primary SMTP set to $wanted."

            $dropOldPrimary = $false
            if ($RemoveOldPrimary -and $currentPrimaryEntry) {
                if (Test-MigrationProtectedAddress -AddressEntry $currentPrimaryEntry) {
                    $primaryDetail += " Kept $currentPrimary - protected address."
                }
                else {
                    $dropOldPrimary = $true
                    $primaryDetail += " Removed the demoted $currentPrimary."
                }
            }

            if ($heldIndex -ge 0) {
                # Exchange will not add an address the object already carries, and releasing the
                # alias in its own call would leave the mailbox with no vanity address at all if
                # the re-add then failed. So the whole list is rewritten in a single
                # Set-Mailbox -EmailAddresses call, which replaces every proxy address at once:
                # the address is never absent from the object, not even for an instant.
                $promoteInPlace = $true
                for ($position = 0; $position -lt $entries.Count; $position++) {
                    if ($position -eq $heldIndex) { $replaceWith.Add("SMTP:$wanted"); continue }
                    if ($position -eq $currentPrimaryIndex) {
                        if (-not $dropOldPrimary) { $replaceWith.Add("smtp:$currentPrimary") }
                        continue
                    }
                    # Everything else is carried over byte for byte: Exchange compares addresses
                    # case-insensitively, but the operator reads this list back.
                    $replaceWith.Add($entries[$position].Entry)
                }
            }
            else {
                $add.Add("SMTP:$wanted")
                if ($dropOldPrimary) { $removeAfter.Add("smtp:$currentPrimary") }
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
        PromoteInPlace  = $promoteInPlace
        ReplaceWith     = $replaceWith.ToArray()
        RemoveBeforeAdd = $removeBefore.ToArray()
        Add             = $add.ToArray()
        RemoveAfterAdd  = $removeAfter.ToArray()
        AliasAdded      = $aliasAdded.ToArray()
        X500Added       = $x500Added.ToArray()
    }
}
