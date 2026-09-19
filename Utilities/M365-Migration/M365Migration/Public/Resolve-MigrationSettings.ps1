function Resolve-MigrationSettingsData {
    <#
        Internal engine shared by Resolve-MigrationSettings and Save-MigrationSettings, so the
        two report exactly the same errors for exactly the same document. Not exported -
        Export-ModuleMember only exports names matching a Public/*.ps1 file's own basename, so
        this stays module-private even though it is dot-sourced from a Public file. It lives
        here, next to Resolve-MigrationSettings, because the module already shares helpers
        this way across files (Get-MigrationDictionaryValue backs Get-MigrationProperty the
        same way) and the two callers cannot validate consistently without sharing this code.

        Accepts anything Save-MigrationSettings' -Settings parameter accepts (an [ordered] or
        plain hashtable, or a [pscustomobject], at any nesting level) as well as the hashtable
        ConvertFrom-Json -AsHashtable produces. Normalises it to nested [ordered] hashtables,
        walks Get-MigrationSettingsSchema to fill missing keys from their defaults, detects
        unknown keys, flags secret-shaped key names, type-checks every value, and applies the
        SchemaVersion and Label rules that are not expressible as a per-key type.

        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        $Data
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    # ConvertFrom-Json -AsHashtable already returns nested hashtables, but -Settings may
    # arrive as a [pscustomobject] tree (New-MigrationSettings' own shape mutated by a
    # caller, or a document built by hand). Normalising both to the same nested [ordered]
    # hashtable shape lets everything below assume one representation.
    function ConvertTo-MigrationSettingsPlainNode {
        param([AllowNull()]$Node)

        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($key in @($Node.Keys)) {
                $out[[string]$key] = ConvertTo-MigrationSettingsPlainNode -Node $Node[$key]
            }
            return $out
        }
        if ($Node -is [System.Management.Automation.PSCustomObject]) {
            $out = [ordered]@{}
            foreach ($property in $Node.PSObject.Properties) {
                $out[$property.Name] = ConvertTo-MigrationSettingsPlainNode -Node $property.Value
            }
            return $out
        }
        return $Node
    }

    $parsed = ConvertTo-MigrationSettingsPlainNode -Node $Data
    if ($null -eq $parsed -or $parsed -isnot [System.Collections.IDictionary]) {
        $errors.Add('Settings must be a JSON object.')
        $parsed = [ordered]@{}
    }

    $schema = @(Get-MigrationSettingsSchema)

    # Group the flattened schema back into "which top-level keys exist, and which of those
    # are objects with a fixed set of children" so unknown-key detection does not have to
    # special-case each section by name.
    $sections = [ordered]@{}
    foreach ($entry in $schema) {
        $segments = $entry.Key -split '\.', 2
        $top = $segments[0]
        if ($segments.Count -eq 1) {
            if (-not $sections.Contains($top)) { $sections[$top] = $null }
        }
        else {
            if (-not $sections.Contains($top)) { $sections[$top] = [System.Collections.Generic.List[string]]::new() }
            $sections[$top].Add($segments[1])
        }
    }

    $validTopKeys = @($sections.Keys)
    foreach ($key in @($parsed.Keys)) {
        if (-not $sections.Contains([string]$key)) {
            $errors.Add("Unknown key '$key'. Valid keys: $($validTopKeys -join ', ').")
        }
    }

    foreach ($top in $sections.Keys) {
        $children = $sections[$top]
        if ($null -eq $children) { continue }
        if (-not $parsed.Contains($top) -or $null -eq $parsed[$top]) { continue }

        $section = $parsed[$top]
        if ($section -isnot [System.Collections.IDictionary]) {
            $errors.Add("Key '$top' must be an object.")
            continue
        }

        $validChildKeys = @($children | ForEach-Object { "$top.$_" })
        foreach ($childKey in @($section.Keys)) {
            if ($children -notcontains [string]$childKey) {
                $errors.Add("Unknown key '$top.$childKey'. Valid keys: $($validChildKeys -join ', ').")
            }
        }
    }

    # No key the operator introduces may look like a secret. This does not run against the
    # schema's own recognised leaf paths - Get-MigrationSettingsSchema is reviewed code, and
    # 'Defaults.PasswordLength' (a length, not a value) is accepted the same way
    # 'VivaLearning.CertificateThumbprint' (a locator, not a value) is; both happen to match
    # the pattern's broad, deliberately-over-inclusive words. What this must still catch is a
    # key an operator invented that is not in the schema at all (VivaLearning.ClientSecret,
    # which the unknown-key check above also flags, for a second, clearer reason) and one
    # buried inside the opaque Plan.AliasDomainMap, whose contents the unknown-key check
    # deliberately never inspects.
    $secretPattern = 'password|passphrase|secret|credential|token|apikey|api-key|certificate|thumbprint|key$'
    $knownPaths = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($schema | ForEach-Object Key), [System.StringComparer]::Ordinal)

    function Find-MigrationSettingsSecretKey {
        param([AllowNull()]$Node, [string]$Prefix)

        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($key in @($Node.Keys)) {
                $dotted = if ($Prefix) { "$Prefix.$key" } else { [string]$key }
                if (([string]$key) -match $secretPattern -and -not $knownPaths.Contains($dotted)) {
                    $errors.Add("Key '$dotted' looks like a secret and must not be stored in settings.")
                }
                Find-MigrationSettingsSecretKey -Node $Node[$key] -Prefix $dotted
            }
        }
        elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            foreach ($item in @($Node)) { Find-MigrationSettingsSecretKey -Node $item -Prefix $Prefix }
        }
    }
    Find-MigrationSettingsSecretKey -Node $parsed -Prefix ''

    function Test-MigrationSettingsEntryValue {
        param(
            [Parameter(Mandatory)]$Entry,
            [AllowNull()]$Value
        )

        switch ($Entry.Type) {
            'String' {
                if ($Value -isnot [string]) { return "Key '$($Entry.Key)' must be a string." }
            }
            'Path' {
                if ($Value -isnot [string]) { return "Key '$($Entry.Key)' must be a string path." }
            }
            'Domain' {
                if ($Value -isnot [string]) { return "Key '$($Entry.Key)' must be a string." }
                if ($Value -and $Value -notmatch '^@?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$') {
                    return "Key '$($Entry.Key)' must be empty or a valid domain (got '$Value')."
                }
            }
            'Guid' {
                if ($Value -isnot [string]) { return "Key '$($Entry.Key)' must be a string." }
                if ($Value) {
                    $parsedGuid = [guid]::Empty
                    if (-not [guid]::TryParse($Value, [ref]$parsedGuid)) {
                        return "Key '$($Entry.Key)' must be empty or a valid GUID (got '$Value')."
                    }
                }
            }
            'Bool' {
                if ($Value -isnot [bool]) { return "Key '$($Entry.Key)' must be a boolean (got '$Value')." }
            }
            'Int' {
                $isInt = ($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or
                    ($Value -is [double] -and [double]$Value -eq [Math]::Truncate([double]$Value))
                if (-not $isInt) { return "Key '$($Entry.Key)' must be an integer (got '$Value')." }
            }
            'Choice' {
                if ($Value -isnot [string] -or $Entry.Choices -notcontains $Value) {
                    return "Key '$($Entry.Key)' must be one of: $($Entry.Choices -join ', ') (got '$Value')."
                }
            }
            'Map' {
                if ($Value -isnot [System.Collections.IDictionary]) {
                    return "Key '$($Entry.Key)' must be an object."
                }
            }
        }
        return $null
    }

    # Fill every schema key from the parsed document, or its default when absent - the rule
    # that lets a settings file written by an older minor version keep loading - while
    # rebuilding as [ordered] in the schema's own order so the canonical order is what gets
    # written back on the next save regardless of how the input was ordered.
    $ordered = [ordered]@{}
    foreach ($entry in $schema) {
        $segments = $entry.Key -split '\.', 2
        if ($segments.Count -eq 1) {
            $top = $segments[0]
            $hasValue = $parsed.Contains($top) -and $null -ne $parsed[$top]
            $value = if ($hasValue) { $parsed[$top] } else { $entry.Default }
            $ordered[$top] = $value
        }
        else {
            $top = $segments[0]
            $leaf = $segments[1]
            if (-not $ordered.Contains($top)) { $ordered[$top] = [ordered]@{} }
            $section = if ($parsed.Contains($top) -and $parsed[$top] -is [System.Collections.IDictionary]) {
                $parsed[$top]
            }
            else { $null }
            $hasValue = $section -and $section.Contains($leaf) -and $null -ne $section[$leaf]
            $value = if ($hasValue) { $section[$leaf] } else { $entry.Default }
            $ordered[$top][$leaf] = $value
        }

        $entryError = Test-MigrationSettingsEntryValue -Entry $entry -Value $value
        if ($entryError) { $errors.Add($entryError) }
    }

    if ($ordered['SchemaVersion'] -ne 1) {
        $errors.Add("Key 'SchemaVersion' must be 1 (got '$($ordered['SchemaVersion'])').")
    }

    $label = [string]$ordered['Label']
    if ([string]::IsNullOrWhiteSpace($label)) {
        $errors.Add("Key 'Label' must not be empty.")
    }
    else {
        $formattedLabel = Format-MigrationPrefix -Value $label
        if ($formattedLabel -ne $label) {
            $errors.Add(
                "Key 'Label' must equal Format-MigrationPrefix -Value Label " +
                "(got '$label', expected '$formattedLabel').")
        }
    }

    return [pscustomobject]@{
        Ordered = $ordered
        Errors  = $errors.ToArray()
    }
}

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
        number, a Choice key one of its Choices, a Domain key empty or domain-shaped); Label
        must be non-empty and already normalised by Format-MigrationPrefix; and no key name
        the operator introduces - anything not already one of Get-MigrationSettingsSchema's
        own recognised paths, including a key buried inside the opaque Plan.AliasDomainMap -
        may match the module's secret-name pattern. The schema's own two matches
        (VivaLearning.CertificateThumbprint, a locator, and Defaults.PasswordLength, a length)
        are accepted because they are reviewed code, not operator input. A key the schema
        defines but the file omits is filled from its default - the mechanism that lets a
        settings file written by an older minor version keep loading.

        Settings is populated only when the document is valid, so a caller never has to
        check IsValid before deciding whether Settings is trustworthy.

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
            Errors   = @('No settings file yet.')
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
            Errors   = @("'$Path' could not be read as settings JSON: $($_.Exception.Message)")
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
