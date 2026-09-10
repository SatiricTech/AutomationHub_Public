function Resolve-MigrationCollision {
    <#
    .SYNOPSIS
        Resolves duplicate local parts deterministically within each domain.

    .DESCRIPTION
        Two John Smiths cannot share john.smith@contoso.com, and the toolkit will not
        let a re-run reshuffle who gets which address. Candidates are therefore sorted
        by Key (the source object ID) before anything is decided, so the same input
        always produces the same output no matter what order the caller collected the
        rows in - a plan regenerated after a mid-migration edit never renames someone
        who has already been provisioned.

        Within each domain, the first candidate by Key keeps the local part. Each later
        candidate tries the middle-initial form first (john.smith becomes john.m.smith),
        because a real middle initial reads better than a digit, and falls back to a
        numeric suffix (john.smith2, john.smith3) when there is no middle initial or the
        local part has no dot to insert one into. The Reserved list seeds the taken set
        with addresses that already exist in the destination, were assigned in an earlier
        wave, or were pinned by the operator.

        Every changed candidate is flagged Collided with the Resolution that was used, so
        the plan can surface all of them for review. If no free form fits inside the
        64-character local-part limit the candidate comes back Unresolved rather than
        being given an address that Entra ID would reject.

    .PARAMETER Candidates
        Objects exposing Key, LocalPart, MiddleInitial and Domain. Extra properties are
        carried through to the output untouched.

    .PARAMETER Reserved
        Addresses already taken. Full addresses ('john.smith@contoso.com') are reserved
        in that domain only; bare local parts are reserved across every domain.

    .EXAMPLE
        $resolved = Resolve-MigrationCollision -Candidates $candidates -Reserved $existingUpns

        Returns each candidate with ResolvedLocalPart, Collided and Resolution added.

    .EXAMPLE
        $resolved | Where-Object Resolution -eq 'Unresolved'

        Lists the rows a human has to name by hand.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Candidates,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Reserved
    )

    $maxLocalPartLength = 64

    $takenAddresses = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $takenEverywhere = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in @($Reserved)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $trimmed = $entry.Trim()
        if ($trimmed.Contains('@')) { [void]$takenAddresses.Add($trimmed) }
        else { [void]$takenEverywhere.Add($trimmed) }
    }

    $isTaken = {
        param([string]$LocalPart, [string]$Domain)
        if ($takenEverywhere.Contains($LocalPart)) { return $true }
        return $takenAddresses.Contains("$LocalPart@$Domain")
    }

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($candidate in (@($Candidates) | Sort-Object -Property @{ Expression = { [string]$_.Key } })) {
        $localPart = ([string]$candidate.LocalPart).Trim().ToLowerInvariant()
        $domain = ([string]$candidate.Domain).Trim().ToLowerInvariant()
        $middleInitial = ''
        if ($candidate.PSObject.Properties['MiddleInitial'] -and $candidate.MiddleInitial) {
            $middleInitial = (ConvertTo-MigrationTokenText -Value ([string]$candidate.MiddleInitial))
            if ($middleInitial) { $middleInitial = $middleInitial.Substring(0, 1) }
        }

        $resolvedLocalPart = $localPart
        $collided = $false
        $resolution = 'None'

        if ([string]::IsNullOrWhiteSpace($localPart)) {
            # Nothing to resolve; the naming engine already flagged this row for review.
            $resolution = 'Unresolved'
            $collided = $false
        }
        elseif (& $isTaken $localPart $domain) {
            $collided = $true
            $resolution = 'Unresolved'
            $resolvedLocalPart = $localPart

            # A middle initial only helps when the local part has a dotted tail to insert it before.
            $segments = $localPart.Split('.')
            if ($middleInitial -and $segments.Count -ge 2) {
                $withInitial = (@($segments[0..($segments.Count - 2)]) + $middleInitial + $segments[-1]) -join '.'
                if ($withInitial.Length -le $maxLocalPartLength -and -not (& $isTaken $withInitial $domain)) {
                    $resolvedLocalPart = $withInitial
                    $resolution = 'MiddleInitial'
                }
            }

            if ($resolution -eq 'Unresolved') {
                for ($suffix = 2; $suffix -le 999; $suffix++) {
                    $withSuffix = "$localPart$suffix"
                    if ($withSuffix.Length -gt $maxLocalPartLength) { break }
                    if (-not (& $isTaken $withSuffix $domain)) {
                        $resolvedLocalPart = $withSuffix
                        $resolution = 'Suffix'
                        break
                    }
                }
            }
        }

        if ($resolution -ne 'Unresolved') {
            [void]$takenAddresses.Add("$resolvedLocalPart@$domain")
        }

        $output = $candidate.PSObject.Copy()
        foreach ($property in @('ResolvedLocalPart', 'Collided', 'Resolution')) {
            if ($output.PSObject.Properties[$property]) { $output.PSObject.Properties.Remove($property) }
        }
        Add-Member -InputObject $output -NotePropertyName 'ResolvedLocalPart' -NotePropertyValue $resolvedLocalPart
        Add-Member -InputObject $output -NotePropertyName 'Collided' -NotePropertyValue $collided
        Add-Member -InputObject $output -NotePropertyName 'Resolution' -NotePropertyValue $resolution

        $results.Add($output)
    }

    return $results.ToArray()
}
