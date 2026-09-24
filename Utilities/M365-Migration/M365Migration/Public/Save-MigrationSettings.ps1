function Save-MigrationSettings {
    <#
    .SYNOPSIS
        Validates and atomically writes the migration settings file.

    .DESCRIPTION
        Runs -Settings through the same validation Resolve-MigrationSettings applies to a
        file already on disk - Resolve-MigrationSettingsData (Private) is the shared engine
        behind both - and refuses to write an invalid document. A missing key is filled from
        its schema default, every Domain value is normalised (trim, strip a leading '@',
        lower-case) before it is validated and written, and the result is rebuilt as
        [ordered] in Get-MigrationSettingsSchema's own order, so what lands on disk is always
        canonical regardless of how the caller built -Settings.

        The parent folder must already exist; this function never creates it. The workbench's
        new-workspace flow creates the folder itself before it ever calls here, and a missing
        folder at save time is more likely a typo the operator should see than something to
        paper over.

        The write is atomic: the JSON is written to '<Path>.tmp' first, the file already at
        Path (if any) is copied - not moved - to '<Path>.bak' so the original is untouched if
        anything below fails, and only then is the temp file moved onto Path in the one step
        that actually replaces it. A reader can never observe a half-written settings file,
        the file at Path is never left missing even if the final move fails, and the version
        just replaced is always one copy away. Any '.bak' from an earlier save is overwritten
        - only the immediately preceding version is kept. The file is UTF-8 without a
        byte-order mark, because a BOM in front of '{' is the kind of thing a hand-edited
        settings file acquires from one text editor and then fails to parse in another.

    .PARAMETER Path
        The settings file to write. Its parent folder must already exist.

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

    # The workbench's new-workspace flow is the only thing that creates a workspace folder;
    # a save whose folder is missing is more likely a typo than a workspace nobody set up yet,
    # so this refuses rather than quietly creating a folder the operator did not ask for.
    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Cannot save settings: the folder '$directory' does not exist. Create the workspace folder first."
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

    # Copy, not move: the file at Path must still exist, complete and untouched, if the final
    # move below fails for any reason. Only the rename onto Path is allowed to remove it.
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop
        }
        catch {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
            throw "Could not back up '$Path' to '$backupPath': $($_.Exception.Message)"
        }
    }

    try {
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        throw "Could not move '$tmpPath' to '$Path': $($_.Exception.Message)"
    }

    Write-MigrationLog -Message "Settings written to $Path" -Level SUCCESS
    return $Path
}
