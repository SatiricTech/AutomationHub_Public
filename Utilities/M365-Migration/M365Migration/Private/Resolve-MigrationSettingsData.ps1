function Resolve-MigrationSettingsData {
    <#
    .SYNOPSIS
        Fills, normalises and validates a settings document against the schema.

    .DESCRIPTION
        Shared engine behind Resolve-MigrationSettings and Save-MigrationSettings, so the two
        report exactly the same errors for exactly the same document - the two callers cannot
        validate consistently without sharing this code, the same reason
        Get-MigrationDictionaryValue backs Get-MigrationProperty from a different file.

        Accepts anything Save-MigrationSettings' -Settings parameter accepts (an [ordered] or
        plain hashtable, or a [pscustomobject], at any nesting level) as well as the hashtable
        ConvertFrom-Json -AsHashtable produces. Normalises it to nested [ordered] hashtables -
        without unrolling an array value onto the pipeline, which would silently turn an
        empty JSON array into $null and hide a wrong-shaped value - then walks
        Get-MigrationSettingsSchema to fill missing keys from their defaults, detects unknown
        keys, flags secret-shaped key names, normalises every Domain value (trim, strip a
        leading '@', lowercase) before type-checking it, and applies the SchemaVersion and
        Label rules that are not expressible as a per-key type.

    .PARAMETER Data
        The settings data to resolve: a nested hashtable, [ordered] hashtable, or
        [pscustomobject] tree, or $null.

    .EXAMPLE
        Resolve-MigrationSettingsData -Data (Get-Content $path -Raw | ConvertFrom-Json -AsHashtable)

        Returns { Ordered; Errors } for a settings file already parsed from JSON.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
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
    # hashtable shape lets everything below assume one representation. An array value (a
    # correctly- or wrongly-shaped 'Plan.AliasDomainMap', or an entire section written as
    # '[]') must come back as that same array, not be unrolled onto the pipeline: an empty
    # array unrolls to zero objects, which an ordinary 'return $Node' would hand back as
    # $null - indistinguishable from "the key was never set" - so a bad shape would silently
    # pass validation instead of failing the Map/object type check below. ',$Node' (the
    # unary comma) forces the array through as a single output object.
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
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            return , $Node
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
            $errors.Add("$top must be an object.")
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
                    return "$($Entry.Key) must be an object."
                }
            }
        }
        return $null
    }

    # Fill every schema key from the parsed document, or its default when absent - the rule
    # that lets a settings file written by an older minor version keep loading - while
    # rebuilding as [ordered] in the schema's own order so the canonical order is what gets
    # written back on the next save regardless of how the input was ordered. A Domain value
    # is normalised (trimmed, a leading '@' stripped, lower-cased) before it is stored or
    # validated, on both a load (Resolve-MigrationSettings) and a save
    # (Save-MigrationSettings) - both go through this one function - so '@Contoso.COM' is
    # accepted and is thereafter always 'contoso.com', on disk and in memory alike.
    $ordered = [ordered]@{}
    foreach ($entry in $schema) {
        $segments = $entry.Key -split '\.', 2
        $top = $segments[0]

        if ($segments.Count -eq 1) {
            $hasValue = $parsed.Contains($top) -and $null -ne $parsed[$top]
            $value = if ($hasValue) { $parsed[$top] } else { $entry.Default }
        }
        else {
            $leaf = $segments[1]
            if (-not $ordered.Contains($top)) { $ordered[$top] = [ordered]@{} }
            $section = if ($parsed.Contains($top) -and $parsed[$top] -is [System.Collections.IDictionary]) {
                $parsed[$top]
            }
            else { $null }
            $hasValue = $section -and $section.Contains($leaf) -and $null -ne $section[$leaf]
            $value = if ($hasValue) { $section[$leaf] } else { $entry.Default }
        }

        if ($entry.Type -eq 'Domain' -and $value -is [string] -and $value) {
            $value = $value.Trim()
            if ($value.StartsWith('@')) { $value = $value.Substring(1) }
            $value = $value.ToLowerInvariant()
        }

        if ($segments.Count -eq 1) { $ordered[$top] = $value } else { $ordered[$top][$segments[1]] = $value }

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
