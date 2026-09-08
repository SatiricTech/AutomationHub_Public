function Get-MigrationTargetDomain {
    <#
    .SYNOPSIS
        Resolves the target domain, prompting the technician when it was not supplied.

    .DESCRIPTION
        Picking the wrong destination domain silently rewrites every address in the wave,
        so the domain is either stated explicitly or chosen from the tenant's verified
        list in front of a human. A requested domain is validated against that list rather
        than trusted, which catches the typo and the not-yet-verified domain before any
        address is built on it.

        Under -DryRun with no domain supplied this throws instead of prompting: a
        rehearsal has to be reproducible and unattended, and a prompt makes it neither.

    .PARAMETER Domains
        The verified domains available in the destination tenant.

    .PARAMETER Requested
        The domain the operator asked for. When supplied it is validated and returned
        without prompting.

    .EXAMPLE
        $domain = Get-MigrationTargetDomain -Domains $verified -Requested 'newco.com'

        Validates the requested domain against the verified list.

    .EXAMPLE
        $domain = Get-MigrationTargetDomain -Domains $verified

        Prompts the technician to choose from the verified domains.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Domains,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Requested
    )

    $available = @($Domains | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $match = $available | Where-Object { $_ -ieq $Requested.Trim() } | Select-Object -First 1
        if (-not $match) {
            throw ("The requested domain '$Requested' is not verified in the destination tenant. Verified domains: " +
                (($available | Sort-Object) -join ', ') + '.')
        }
        return $match
    }

    if ($available.Count -eq 0) {
        throw 'No verified domains were found in the destination tenant, and none was supplied with -TargetDomain.'
    }

    $isDryRun = $script:MigrationRun -and $script:MigrationRun.DryRun
    if ($isDryRun) {
        throw ('A target domain must be supplied with -TargetDomain when running with -DryRun; ' +
            'a rehearsal must not depend on an interactive prompt. Verified domains: ' +
            (($available | Sort-Object) -join ', ') + '.')
    }

    if ($available.Count -eq 1) {
        Write-MigrationLog -Message "Using the only verified domain in the destination tenant: $($available[0])" -Level INFO
        return $available[0]
    }

    Write-MigrationLog -Message 'Select the target domain:' -Level SUCCESS
    for ($index = 0; $index -lt $available.Count; $index++) {
        Write-MigrationLog -Message ('  [{0}] {1}' -f ($index + 1), $available[$index]) -Level SUCCESS
    }

    while ($true) {
        $answer = Read-Host -Prompt "Enter a number between 1 and $($available.Count)"
        $choice = 0
        if ([int]::TryParse(($answer ?? '').Trim(), [ref]$choice) -and $choice -ge 1 -and $choice -le $available.Count) {
            $selected = $available[$choice - 1]
            Write-MigrationLog -Message "Target domain: $selected" -Level SUCCESS
            return $selected
        }
        Write-MigrationLog -Message 'That is not one of the listed numbers.' -Level WARNING
    }
}
