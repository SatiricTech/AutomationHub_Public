function Resolve-MigrationSettings {
    <#
    .SYNOPSIS
        Reads and validates the migration settings file, never throwing.

    .DESCRIPTION
        The settings file is entirely operator-maintained JSON, so a missing file, a stale
        file from an older minor version, or a hand-edited typo are all routine - never a
        reason for a script to abort. Every failure mode collapses to the same shape:
        Exists, IsValid, Errors and Settings, so a caller (the workbench today, a future
        script) can render "no settings yet" and "settings are broken" the same way it
        renders "here is your document".

        Validation, in order: the file must parse as JSON; SchemaVersion must be 1; no key
        may appear that Get-MigrationSettingsSchema does not define, at either nesting level
        (the error names the valid keys); every typed value must match its schema Type
        (a GUID key empty or a real GUID, a Bool key a real boolean, an Int key a whole
        number, a Choice key one of its Choices, a Domain key empty or domain-shaped after
        normalisation - see Get-MigrationSettingsSchema); Label must be non-empty and already
        normalised by Format-MigrationPrefix; and no key name the operator introduces -
        anything not already one of Get-MigrationSettingsSchema's own recognised paths,
        including a key buried inside the opaque Plan.AliasDomainMap - may match the module's
        secret-name pattern. The schema's own two matches (VivaLearning.CertificateThumbprint,
        a locator, and Defaults.PasswordLength, a length) are accepted because they are
        reviewed code, not operator input. A key the schema defines but the file omits is
        filled from its default - the mechanism that lets a settings file written by an older
        minor version keep loading. Resolve-MigrationSettingsData (Private) does the work, so
        this and Save-MigrationSettings always report the same errors for the same document.

        Settings is populated only when the document is valid, so a caller never has to
        check IsValid before deciding whether Settings is trustworthy.

        Each entry of Errors carries the sentence an operator reads and, as Key, the dotted
        schema key it is about - or '' where the problem is with the document rather than one
        key. A settings form re-asks by Key rather than by matching the wording of a message,
        which is the difference between a re-prompt that survives a reworded sentence and one
        that silently stops happening. An error renders as its own message wherever a string
        would, so '-join', Write-Warning and string interpolation all read as they always did.

    .PARAMETER Path
        The settings file to read.

    .EXAMPLE
        Resolve-MigrationSettings -Path .\M365Migration.settings.json

        Returns { Path; Exists; IsValid; Errors; Settings } for the workspace's settings file.

    .EXAMPLE
        $r = Resolve-MigrationSettings -Path $path
        if (-not $r.IsValid) { $r.Errors | ForEach-Object { Write-Warning $_ } }

        The standard "load and report problems" pattern; never throws.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The name is fixed by the settings file contract (Docs/Workbench-Design.md).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Path     = $Path
            Exists   = $false
            IsValid  = $false
            Errors   = @(New-MigrationSettingsError -Message 'No settings file yet.')
            Settings = $null
        }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $data = if ([string]::IsNullOrWhiteSpace($raw)) {
            [ordered]@{}
        }
        else {
            $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        $result = Resolve-MigrationSettingsData -Data $data
    }
    catch {
        return [pscustomobject]@{
            Path     = $Path
            Exists   = $true
            IsValid  = $false
            Errors   = @(New-MigrationSettingsError -Message (
                    "'$Path' could not be read as settings JSON: $($_.Exception.Message)"))
            Settings = $null
        }
    }

    return [pscustomobject]@{
        Path     = $Path
        Exists   = $true
        IsValid  = ($result.Errors.Count -eq 0)
        Errors   = $result.Errors
        Settings = if ($result.Errors.Count -eq 0) { $result.Ordered } else { $null }
    }
}
