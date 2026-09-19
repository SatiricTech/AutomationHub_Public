function Get-MigrationSettingsSuggestion {
    <#
    .SYNOPSIS
        Suggests a value for one settings key, from the workspace itself.

    .DESCRIPTION
        The settings form's first job is to be answerable with the Enter key
        (Docs/Workbench-Design.md, section 4), and that only works when the suggestions come
        from what is already in the folder rather than from a list of plausible defaults.

        A value the operator has already set is always the suggestion - editing settings must
        never mean retyping them. Where there is none:

          Label           the workspace folder's own name, normalised the way every output
                          filename will normalise it, because that is what the operator called
                          this migration when they made the folder.
          Domains.Target  the sign-in domain most of the destination tenant's users already
                          have, read from the newest Destination_Users inventory. Only the
                          UserPrincipalName column is read - nothing else in that file is the
                          settings form's business - and onmicrosoft.com domains are passed
                          over, since the vanity domain is the whole point of the key.

        Everything else suggests nothing, on purpose: a guessed tenant GUID or a guessed
        release domain is worse than an empty field, because Enter would accept it.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .PARAMETER Key
        The dotted settings key, for example 'Domains.Target'.

    .PARAMETER Current
        The value the document already holds, as text. Returned unchanged when it is not empty.

    .EXAMPLE
        Get-MigrationSettingsSuggestion -Workspace $ws -Key 'Domains.Target' -Current ''

        Returns the commonest vanity sign-in domain in the destination inventory, or ''.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Current = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Current)) { return $Current }

    switch ($Key) {
        'Label' {
            $leaf = Split-Path -Path ([string]$Workspace.Path) -Leaf
            if (-not $leaf) { return '' }
            return (Format-MigrationPrefix -Value $leaf)
        }

        'Domains.Target' {
            $inventory = @(@($Workspace.Artefacts) |
                    Where-Object { $_.Prefix -eq 'Destination' -and $_.Name -eq 'Users' -and $_.Extension -eq 'csv' } |
                    Sort-Object -Property Timestamp -Descending)
            if ($inventory.Count -eq 0) { return '' }

            try { $rows = @(Import-Csv -LiteralPath ([string]$inventory[0].Path) -ErrorAction Stop) }
            catch {
                Write-Debug "The destination inventory could not be read: $($_.Exception.Message)"
                return ''
            }

            $domains = foreach ($row in $rows) {
                $upn = [string](Get-MigrationCsvValue -Row $row -Name 'UserPrincipalName' -Default '')
                if ($upn -notlike '*@*') { continue }
                $domain = ($upn -split '@')[-1].Trim().ToLowerInvariant()
                # The tenant's own onmicrosoft domain is never the vanity domain the identities
                # are meant to land on, and every tenant has one.
                if (-not $domain -or $domain -like '*.onmicrosoft.com') { continue }
                $domain
            }

            $ranked = @(@($domains) | Group-Object | Sort-Object -Property Count, Name -Descending)
            if ($ranked.Count -eq 0) { return '' }
            return [string]$ranked[0].Name
        }
    }

    return ''
}
