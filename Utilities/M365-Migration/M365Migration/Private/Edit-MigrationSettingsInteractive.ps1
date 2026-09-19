function Edit-MigrationSettingsInteractive {
    <#
    .SYNOPSIS
        Walks the operator through the settings document, key by key, and saves it.

    .DESCRIPTION
        The console's settings form (Docs/Workbench-Design.md, sections 4 and 8). It asks for
        every key Get-MigrationSettingsSchema defines, in the schema's own order, with a
        suggestion the Enter key accepts - so a first run is mostly Enter, and an edit is one
        answer among thirty-odd defaults rather than a retype of the whole document.

        The one key it does not ask for is SchemaVersion. That is the file format's own
        version, not a choice an operator has, and a form that asked for it would be inviting
        the one answer that makes the document unloadable.

        Each type is asked in the way that type deserves: a Choice key as a pick-list, a
        boolean as a yes/no, the alias domain map as 'old=new;old2=new2' text, and everything
        else as free text. A tenant key takes either a GUID or a domain and resolves the domain
        through Resolve-MigrationTenantId; where that fails - no network, a typo, a domain in
        no tenant - the error is shown and the typed value is kept rather than dropped, because
        the validator naming a bad value is far more use to the operator than a field that
        silently emptied itself.

        Validation is the same engine the loader and the writer use, so the form cannot accept
        a document Resolve-MigrationSettings would later reject. When it fails, only the keys
        the errors name are asked again: re-walking the whole form to fix one domain is how an
        operator comes to dread the settings screen. Five rounds of that and the form gives up
        rather than trapping them in it.

        Nothing is written until the document validates, and then it goes through
        Save-MigrationSettings, which writes atomically and keeps the previous version.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace. Its Settings pre-fill the form and its
        SettingsPath is what gets written.

    .EXAMPLE
        Edit-MigrationSettingsInteractive -Workspace $workspace

        Asks for every settings key and saves the result, returning the saved document.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'This is the console front end; the form is host output by definition.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The operator confirms every value at the prompt; a second -Confirm would be noise.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace
    )

    # Walk a dotted key on a settings document. The document is always built here, so the two
    # shapes it can have - a top-level key and a one-level-deep section - are all there is.
    function Get-MigrationFormValue {
        param([AllowNull()]$Document, [string]$Key)
        if ($null -eq $Document) { return $null }
        $segments = $Key -split '\.', 2
        $value = Get-MigrationProperty -InputObject $Document -Name $segments[0] -Default $null
        if ($segments.Count -eq 1) { return $value }
        return (Get-MigrationProperty -InputObject $value -Name $segments[1] -Default $null)
    }

    function Set-MigrationFormValue {
        param($Document, [string]$Key, [AllowNull()]$Value)
        $segments = $Key -split '\.', 2
        if ($segments.Count -eq 1) { $Document[$segments[0]] = $Value; return }
        if (-not $Document.Contains($segments[0])) { $Document[$segments[0]] = [ordered]@{} }
        $Document[$segments[0]][$segments[1]] = $Value
    }

    $schema = @(Get-MigrationSettingsSchema)
    $asked = @($schema | Where-Object { $_.Key -ne 'SchemaVersion' })

    # A fresh document filled from what is on disk, rather than the scan's own object: the form
    # must not edit the workspace the caller is still holding.
    $document = New-MigrationSettings
    foreach ($entry in $schema) {
        $current = Get-MigrationFormValue -Document $Workspace.Settings -Key $entry.Key
        if ($null -ne $current) { Set-MigrationFormValue -Document $document -Key $entry.Key -Value $current }
    }

    $ask = {
        param($Entry)

        $key = [string]$Entry.Key
        $current = Get-MigrationFormValue -Document $document -Key $key
        $hint = Get-MigrationSettingsHint -Workspace $Workspace -Key $key -Document $document
        $message = if ($hint) { "$key ($hint)" } else { $key }

        Write-Host ('  ' + [string]$Entry.Description) -ForegroundColor DarkGray

        switch ($Entry.Type) {
            'Choice' {
                # A blank pre-selection would let Enter store an empty string in a key that
                # only accepts one of its own choices, so the schema's default stands in.
                $default = [string]$current
                if (-not $default) { $default = [string]$Entry.Default }
                $answer = Read-MigrationPrompt -Kind 'Choice' -Message $message -Choices @($Entry.Choices) `
                    -Default $default
                Set-MigrationFormValue -Document $document -Key $key -Value ([string]$answer)
            }

            'Bool' {
                $default = if ([bool]$current) { 'y' } else { 'n' }
                $answer = Read-MigrationPrompt -Kind 'Confirm' -Message $message -Default $default
                Set-MigrationFormValue -Document $document -Key $key -Value ([bool]$answer)
            }

            'Map' {
                $pairs = @()
                if ($current -is [System.Collections.IDictionary]) {
                    $pairs = @(@($current.Keys) | ForEach-Object { '{0}={1}' -f $_, $current[$_] })
                }
                $answer = [string](Read-MigrationPrompt -Kind 'Text' -Message "$message (old=new;old2=new2)" `
                        -Default ($pairs -join ';'))

                $map = [ordered]@{}
                foreach ($pair in @($answer -split ';')) {
                    $parts = $pair -split '=', 2
                    if ($parts.Count -ne 2) { continue }
                    $left = $parts[0].Trim()
                    if (-not $left) { continue }
                    $map[$left] = $parts[1].Trim()
                }
                Set-MigrationFormValue -Document $document -Key $key -Value $map
            }

            'Int' {
                $answer = [string](Read-MigrationPrompt -Kind 'Text' -Message $message -Default ([string]$current))
                $parsed = 0
                if ([int]::TryParse($answer, [ref]$parsed)) {
                    Set-MigrationFormValue -Document $document -Key $key -Value $parsed
                }
                else {
                    # Kept as typed so the validator names the key and the value; silently
                    # substituting a number would hide the operator's own typo from them.
                    Set-MigrationFormValue -Document $document -Key $key -Value $answer
                }
            }

            default {
                $suggestion = Get-MigrationSettingsSuggestion -Workspace $Workspace -Key $key `
                    -Current ([string]$current)
                $answer = [string](Read-MigrationPrompt -Kind 'Text' -Message $message -Default $suggestion)

                if ($key -like '*.TenantId' -and $answer) {
                    try {
                        $answer = [string](Resolve-MigrationTenantId -Tenant $answer)
                    }
                    catch {
                        Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Yellow
                        Write-Host '  Keeping what you typed; the validator will say if it cannot be used.'
                    }
                }
                Set-MigrationFormValue -Document $document -Key $key -Value $answer
            }
        }
    }

    Write-Host ''
    Write-Host "Settings for $($Workspace.Path)"
    Write-Host 'Press Enter to accept the suggestion in brackets.'
    Write-Host ''

    foreach ($entry in $asked) { & $ask $entry }

    $validated = $null
    $round = 0
    while ($true) {
        $validated = Resolve-MigrationSettingsData -Data $document
        if (@($validated.Errors).Count -eq 0) { break }

        Write-Host ''
        Write-Host 'These settings are not valid yet:' -ForegroundColor Yellow
        foreach ($problem in @($validated.Errors)) { Write-Host "  - $problem" -ForegroundColor Yellow }

        $round++
        $failing = @($asked | Where-Object {
                $key = [string]$_.Key
                @(@($validated.Errors) | Where-Object { $_ -like "*'$key'*" -or $_ -like "$key *" }).Count -gt 0
            })

        # Five rounds, or an error that names no key at all: the form has stopped being the
        # way out and the operator should be allowed to leave and edit the file by hand.
        if ($failing.Count -eq 0 -or $round -ge 5) {
            Write-Host 'The settings were not saved.' -ForegroundColor Red
            return $null
        }

        Write-Host ''
        foreach ($entry in $failing) { & $ask $entry }
    }

    try {
        Save-MigrationSettings -Path ([string]$Workspace.SettingsPath) -Settings $document | Out-Null
    }
    catch {
        Write-Host "The settings could not be saved: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    Write-Host "Settings saved to $($Workspace.SettingsPath)"
    return $validated.Ordered
}
