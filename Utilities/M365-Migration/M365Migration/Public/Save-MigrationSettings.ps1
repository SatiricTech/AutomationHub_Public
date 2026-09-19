function Save-MigrationSettings {
    <#
    .SYNOPSIS
        Validates and atomically writes the migration settings file.

    .DESCRIPTION
        Runs -Settings through the same validation Resolve-MigrationSettings applies to a
        file already on disk - Resolve-MigrationSettingsData is the shared engine behind
        both - and refuses to write an invalid document. A missing key is filled from its
        schema default and the result is rebuilt as [ordered] in
        Get-MigrationSettingsSchema's own order, so what lands on disk is always canonical
        regardless of how the caller built -Settings.

        The write is atomic: the JSON is written to '<Path>.tmp' first, the file already at
        Path (if any) is moved to '<Path>.bak', and only then is the temp file moved onto
        Path. A reader can never observe a half-written settings file, and the version just
        replaced is always one rename away. The file is UTF-8 without a byte-order mark,
        because a BOM in front of '{' is the kind of thing a hand-edited settings file
        acquires from one text editor and then fails to parse in another.

    .PARAMETER Path
        The settings file to write.

    .PARAMETER Settings
        The document to write - an [ordered] or plain hashtable, or a [pscustomobject], as
        returned by New-MigrationSettings or read back from Resolve-MigrationSettings'
        Settings property.

    .EXAMPLE
        Save-MigrationSettings -Path .\M365Migration.settings.json -Settings (New-MigrationSettings -Label 'Contoso')

        Writes a fresh settings file for a new migration.

    .EXAMPLE
        $current = (Resolve-MigrationSettings -Path $path).Settings
        $current.Domains.Target = 'newco.com'
        Save-MigrationSettings -Path $path -Settings $current

        Updates one field and re-saves, keeping the previous version as '<path>.bak'.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The name is fixed by the settings file contract (Docs/Workbench-Design.md).')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        $Settings
    )

    $result = Resolve-MigrationSettingsData -Data $Settings
    if ($result.Errors.Count -gt 0) {
        throw "The settings document is invalid and was not written: $($result.Errors -join '; ')"
    }

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        try {
            $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
        }
        catch {
            throw "Could not create the settings directory '$directory': $($_.Exception.Message)"
        }
    }

    $json = $result.Ordered | ConvertTo-Json -Depth 6
    $tmpPath = "$Path.tmp"
    $backupPath = "$Path.bak"

    try {
        [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        throw "Could not write '$tmpPath': $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            Move-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop
        }
        catch {
            throw "Could not back up '$Path' to '$backupPath': $($_.Exception.Message)"
        }
    }

    try {
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force -ErrorAction Stop
    }
    catch {
        throw "Could not move '$tmpPath' to '$Path': $($_.Exception.Message)"
    }

    Write-MigrationLog -Message "Settings written to $Path" -Level SUCCESS
    return $Path
}
