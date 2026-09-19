function Get-MigrationScriptParameter {
    <#
    .SYNOPSIS
        Reads one toolkit script's parameters, sets, defaults and help text.

    .DESCRIPTION
        The workbench builds a form and a command line for each of the 17 scripts. Hand-copying
        17 param blocks into a catalogue rots the moment a script gains a parameter, so the
        catalogue overlay (StepCatalog.psd1) holds only what a script cannot say about itself -
        phase, side, bindings, artefacts - and everything else is read from the script here.

        Three sources are combined, because no single one carries all of it:

        - Get-Command supplies the parameter list, .NET types, parameter-set membership,
          mandatory flags, aliases and the validation attributes (ValidateSet, ValidateRange,
          ValidatePattern).
        - The script's ParamBlockAst supplies default values. Get-Command does not expose them
          at all: a default lives in the param block's expression, never in the metadata.
        - Get-Help supplies the .PARAMETER description, which is the only human-readable text
          a generated form can show beside a field.

        Parameter sets are reported by their declared names. PowerShell models a parameter that
        belongs to every set with the sentinel set '__AllParameterSets'; that sentinel is never
        surfaced. Instead such a parameter lists every named set the script declares, and a
        script that declares no named sets reports an empty Names list - it has exactly one
        implicit set, so naming it would be inventing a name no operator ever typed.

        Common is true for the five options every toolkit script shares (-OutputPath, -Prefix,
        -LogPath, -Verbosity, -DryRun) and for PowerShell's own common and ShouldProcess
        parameters. The workbench sets those itself from the workspace and the settings file,
        so they never reach the generated step form; the catalogue's drift guard uses the same
        flag to decide which parameters an overlay entry must account for.

        Results are cached per session in $script:MigrationScriptParameterCache, keyed by the
        script's full path and its LastWriteTimeUtc, so editing a script during a session is
        picked up on the next call rather than serving a stale param block.

    .PARAMETER ScriptPath
        Path to the .ps1 file to read. Must exist.

    .EXAMPLE
        Get-MigrationScriptParameter -ScriptPath ./New-MigrationUsers.ps1

        Returns { Parameters; ParameterSets } for the user-provisioning script.

    .EXAMPLE
        (Get-MigrationScriptParameter -ScriptPath ./Set-MigrationIdentity.ps1).Parameters |
            Where-Object { -not $_.Common } | Select-Object Name, TypeName, Default

        Lists the parameters an operator has to fill in, with their types and defaults.

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
        [string]$ScriptPath
    )

    $file = Get-Item -LiteralPath $ScriptPath -ErrorAction Stop
    $cacheKey = '{0}|{1:o}' -f $file.FullName, $file.LastWriteTimeUtc
    if ($script:MigrationScriptParameterCache.ContainsKey($cacheKey)) {
        return $script:MigrationScriptParameterCache[$cacheKey]
    }

    $command = Get-Command -Name $file.FullName -CommandType ExternalScript -ErrorAction Stop

    # PowerShell's own name for "belongs to every set", spelled '__AllParameterSets'. It is a
    # modelling artefact, never something an operator typed, so it is filtered out everywhere.
    $allSets = [System.Management.Automation.ParameterAttribute]::AllParameterSets

    # IsDefault is set on the sentinel set too, so a script without named sets reports ''.
    $namedSets = @($command.ParameterSets | Where-Object { $_.Name -ne $allSets } | ForEach-Object Name)
    $defaultSet = @($command.ParameterSets | Where-Object { $_.IsDefault } | ForEach-Object Name)
    $defaultSetName = ''
    if (@($defaultSet).Count -gt 0 -and @($defaultSet)[0] -ne $allSets) { $defaultSetName = @($defaultSet)[0] }

    $commonNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('OutputPath', 'Prefix', 'LogPath', 'Verbosity', 'DryRun') +
        @([System.Management.Automation.PSCmdlet]::CommonParameters) +
        @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)) {
        $null = $commonNames.Add($name)
    }

    $defaults = Get-MigrationScriptParameterDefault -Command $command
    $helpText = Get-MigrationScriptParameterHelp -Path $file.FullName -Name @($command.Parameters.Keys)

    $parameters = foreach ($entry in $command.Parameters.GetEnumerator()) {
        $metadata = $entry.Value
        $name = $metadata.Name

        # ParameterSets is keyed by set name; the sentinel means "every set the script has".
        $declaredSets = @($metadata.ParameterSets.Keys)
        $inAllSets = $declaredSets -contains $allSets
        $mandatorySets = @($declaredSets | Where-Object { $metadata.ParameterSets[$_].IsMandatory })

        $sets = if ($inAllSets) { $namedSets } else { @($declaredSets) }
        $mandatoryIn = if ($inAllSets) {
            # Mandatory in the sentinel set means mandatory in all of them.
            if (@($mandatorySets).Count -gt 0) { $namedSets } else { @() }
        }
        else { $mandatorySets }

        $validValues = @($metadata.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                ForEach-Object { $_.ValidValues })

        $patternAttribute = @($metadata.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] })
        $rangeAttribute = @($metadata.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })

        $pattern = $null
        if (@($patternAttribute).Count -gt 0) { $pattern = @($patternAttribute)[0].RegexPattern }

        $range = $null
        if (@($rangeAttribute).Count -gt 0) {
            # A ValidateRange declared with a RangeKind (Positive, NonNegative, ...) rather than
            # two bounds leaves MinRange and MaxRange null; the object still says "constrained".
            $range = [pscustomobject]@{
                Min = @($rangeAttribute)[0].MinRange
                Max = @($rangeAttribute)[0].MaxRange
            }
        }

        [pscustomobject]@{
            Name          = $name
            TypeName      = $metadata.ParameterType.Name
            IsSwitch      = [bool]$metadata.SwitchParameter
            IsBool        = ($metadata.ParameterType -eq [bool])
            IsArray       = [bool]$metadata.ParameterType.IsArray
            IsHashtable   = [System.Collections.IDictionary].IsAssignableFrom($metadata.ParameterType)
            Mandatory     = (@($mandatorySets).Count -gt 0)
            MandatoryIn   = @($mandatoryIn)
            ParameterSets = @($sets)
            ValidValues   = $validValues
            Pattern       = $pattern
            Range         = $range
            Default       = if ($defaults.ContainsKey($name)) { $defaults[$name] } else { $null }
            Aliases       = @($metadata.Aliases)
            Help          = if ($helpText.ContainsKey($name)) { $helpText[$name] } else { '' }
            Common        = $commonNames.Contains($name)
        }
    }

    $result = [pscustomobject]@{
        Parameters    = @($parameters)
        ParameterSets = [pscustomobject]@{
            Names   = @($namedSets)
            Default = $defaultSetName
        }
    }

    $script:MigrationScriptParameterCache[$cacheKey] = $result
    return $result
}
