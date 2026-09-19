function Assert-MigrationDriverArgumentSafe {
    <#
    .SYNOPSIS
        Throws if an argument name reads like a secret, so no driver can be written holding one.

    .DESCRIPTION
        A driver file stays in the workspace beside the log and the results - synced, backed up
        and read by whoever opens the folder next - so a credential written into one outlives
        the run by years. The name is what is checked, against the same deliberately
        over-inclusive pattern the run log and the settings validator use: a false positive
        costs a refusal the operator can see and work around, a false negative leaks a
        credential into a file nobody thinks to look at.

        That pattern on its own is too blunt to be the whole rule, because it matches real
        parameters of real steps: -ForceChangePassword (a switch), -PasswordLength (a count),
        -WordCount's neighbours. A boolean and a number cannot carry a secret whatever they are
        called, so a matching name is only refused when its value is of a type that could hold
        one - a string, a credential, or a collection of them. That is the same judgement
        Resolve-MigrationSettingsData makes when it accepts 'Defaults.PasswordLength' as a
        length rather than a value.

        One name is allowed through despite carrying a string: CertificateThumbprint, which is
        a locator for a certificate in a store, not the certificate or its key - again exactly
        as the settings validator accepts it. The one true secret the toolkit takes, Viva
        Learning's -ClientSecret, is deliberately not on that list: it reaches the child through
        Invoke-MigrationStep -Environment, where it lives only as long as the process.

    .PARAMETER Argument
        The resolved arguments about to be written into a driver: { Name; Value; ... }.

    .EXAMPLE
        Assert-MigrationDriverArgumentSafe -Argument $emitted

        Returns nothing when no argument both reads like a secret and could hold one.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Argument
    )

    $secretPattern = Get-MigrationSecretNamePattern
    $allowed = @('CertificateThumbprint')

    $offenders = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Argument)) {
        $name = [string]$item.Name
        if (-not $name -or $name -notmatch $secretPattern -or $allowed -contains $name) { continue }

        # A value that cannot be a secret: a flag, a count, a length. Nothing else is trusted -
        # an unexpected type is treated as a possible secret, not waved through.
        $value = $item.Value
        $harmless = ($value -is [bool] -or $value -is [System.Management.Automation.SwitchParameter] -or
            $value -is [int] -or $value -is [long] -or $value -is [short] -or $value -is [byte] -or
            $value -is [double] -or $value -is [single] -or $value -is [decimal])
        if (-not $harmless) { $offenders.Add($name) }
    }

    if ($offenders.Count -gt 0) {
        throw ("A driver must never hold a secret, and these parameters read like one: " +
            (($offenders | Sort-Object -Unique) -join ', ') +
            ". Pass the value to the child through Invoke-MigrationStep -Environment instead.")
    }
}
