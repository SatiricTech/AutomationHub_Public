function Get-MigrationRunLedgerEntry {
    <#
    .SYNOPSIS
        Reads Workbench/Runs.jsonl into run entries, never throwing on a damaged line.

    .DESCRIPTION
        The ledger is append-only JSON Lines (Docs/Workbench-Design.md, section 7.4) and is
        the workbench's record of what actually ran: the scanner reads it for exit codes and
        tenant verification, and the "Results & logs" view lists it. A run killed mid-append,
        or a file an operator has opened in an editor, leaves a line that is not JSON - and
        that must cost the reader that one line, never the whole ledger, so bad lines come
        back as warnings for the caller to surface.

        Every entry is returned with the full field set of section 7.4 present, defaulted
        where the line omits one, so a caller running under Set-StrictMode can read
        entry.ExitCode or entry.Files without guarding each one. Fields the line carries
        beyond that set are kept as they are. Started and Ended are converted to [datetime]
        when they parse and are $null when they do not, because the scanner uses that window
        to work out which step wrote a results file two instances could both have written.

    .PARAMETER Path
        The Runs.jsonl file. A ledger that does not exist yet is an empty ledger, not an error.

    .EXAMPLE
        (Get-MigrationRunLedgerEntry -Path .\Workbench\Runs.jsonl).Entries | Select-Object StepId, ExitCode

        Lists every recorded run in the order it was appended.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Path = $Path; Entries = @(); Warnings = @() }
    }

    $leaf = [System.IO.Path]::GetFileName($Path)

    try {
        $lines = @(Get-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop)
    }
    catch {
        return [pscustomobject]@{
            Path     = $Path
            Entries  = @()
            Warnings = @("The run ledger '$leaf' could not be read: $($_.Exception.Message)")
        }
    }

    # Every field section 7.4 defines, with the default an absent one takes. The three list
    # fields default to an empty array so a caller can pipe them without a null check.
    $template = [ordered]@{
        Started        = $null
        Ended          = $null
        StepId         = ''
        Script         = ''
        Side           = ''
        TenantId       = ''
        DryRun         = $false
        Wave           = @()
        ExitCode       = $null
        Meaning        = ''
        Aborted        = $false
        TenantVerified = $null
        GateOverrides  = @()
        Driver         = ''
        Files          = @()
        Summary        = $null
    }

    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try { $parsed = $line | ConvertFrom-Json -ErrorAction Stop }
        catch {
            $warnings.Add("Line $lineNumber of the run ledger '$leaf' is not valid JSON and was skipped.")
            continue
        }

        if ($parsed -isnot [pscustomobject]) {
            $warnings.Add("Line $lineNumber of the run ledger '$leaf' is not a run record and was skipped.")
            continue
        }

        $entry = [ordered]@{}
        foreach ($key in $template.Keys) { $entry[$key] = $template[$key] }
        foreach ($property in $parsed.PSObject.Properties) { $entry[$property.Name] = $property.Value }

        foreach ($key in @('Started', 'Ended')) {
            $value = $entry[$key]
            if ($value -is [datetime]) { continue }
            $moment = [datetime]::MinValue
            $readable = $value -and [datetime]::TryParse([string]$value, [ref]$moment)
            $entry[$key] = if ($readable) { $moment } else { $null }
        }

        foreach ($key in @('Wave', 'GateOverrides', 'Files')) { $entry[$key] = @($entry[$key]) }

        $number = 0
        $entry['ExitCode'] = if ($null -ne $entry['ExitCode'] -and
            [int]::TryParse([string]$entry['ExitCode'], [ref]$number)) { $number } else { $null }

        $entry['LineNumber'] = $lineNumber
        $entries.Add([pscustomobject]$entry)
    }

    return [pscustomobject]@{
        Path     = $Path
        Entries  = $entries.ToArray()
        Warnings = $warnings.ToArray()
    }
}
