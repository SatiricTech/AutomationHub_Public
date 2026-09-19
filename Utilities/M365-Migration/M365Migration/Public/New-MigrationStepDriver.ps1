function New-MigrationStepDriver {
    <#
    .SYNOPSIS
        Writes the driver script that runs one step, and the command line that starts it.

    .DESCRIPTION
        Every workbench run goes through a generated file:
        <workspace>/Workbench/Runs/<yyyyMMdd-HHmmss>_<StepId>/driver.ps1
        (Docs/Workbench-Design.md, sections 3 and 7.3). Two reasons, and both matter.

        Binding. 'pwsh -File' hands every argument to the script as a string: -Wave @('1','2')
        arrives as the single string '1 2', -AliasDomainMap @{...} as its type name, and
        -ForceChangePassword $false as the string 'False', which binds to $true. A splat inside
        a file does not - the values are PowerShell literals by the time the parameter binder
        sees them, which is what ConvertTo-MigrationPowerShellLiteral renders.

        Evidence. The driver is the artefact of exactly what ran, left in the workspace beside
        the log and the results. An operator who wants to repeat a run, or explain one to
        somebody six months later, has the command in front of them - so the header says which
        workbench wrote it, when, and how to run it again by hand.

        Only arguments whose Source is not 'Default' are written. A default is the script's own
        business; re-stating it here would freeze today's value into a file that outlives the
        script. An argument with no value is left out for the same reason.

        The run folder is named for the second the run started, which is the same resolution the
        ledger and the toolkit's filenames use. A second run of the same step inside that second
        would otherwise land in the same folder and overwrite the first one's driver, so it is
        given the next free suffix instead: -2, then -3.

        Failure. The driver does not end at the call: it sets $ErrorActionPreference to Stop,
        wraps the splat in try/catch and exits 1 from the catch, then exits [int]$LASTEXITCODE.
        A call that never reaches the script - an unknown parameter, a value its ValidateSet
        rejects, a mandatory one missing - leaves $LASTEXITCODE unset, and an unset
        $LASTEXITCODE exits 0. Without the guard the workbench would record 'Completed' for a
        step that did nothing, and the folder scanner would then show it as done. A script that
        exits with a code of its own still propagates it, so 2 and 3 keep their meaning.

        Secrets. Nothing that reads like one is ever written. The driver stays in the workspace,
        which is synced and backed up like any other folder, so a credential in it outlives the
        run by years; the one secret the toolkit takes (the Viva Learning client secret) reaches
        the child through Invoke-MigrationStep -Environment instead, where it lives only as long
        as the process. The rule Assert-MigrationDriverArgumentSafe applies is the shared
        secret-name pattern AND a value of a type that could hold a secret: a switch, a boolean
        or a number is passed whatever it is called, which is what keeps -ForceChangePassword
        and -PasswordLength - real parameters of real steps - out of the refusal. The one
        name-based exception is -CertificateThumbprint, a locator for a certificate rather than
        the certificate, accepted here exactly as the settings validator accepts it.
        -ClientSecret, -ApiKey and anything else carrying a string still refuse.

        Which leaves the question the refusal does not answer: how a secret that genuinely has
        to be passed ever reaches the script. -SecretEnvironmentVariable is that join. The
        driver is the only thing in the chain that runs inside the child, so it is the only
        place a SecureString can be built - a SecureString cannot cross a process boundary,
        and -Environment can only carry text. Given 'ClientSecret=M365MIGRATION_CLIENT_SECRET'
        the driver reads $env:M365MIGRATION_CLIENT_SECRET and converts it, inside the try
        block so an unset variable exits 1 rather than binding nothing, and the value itself
        is never written: it exists in the child's environment for the life of that process
        and nowhere else.

    .PARAMETER Step
        The step instance from Get-MigrationStep.

    .PARAMETER Arguments
        The result of Resolve-MigrationStepArguments for this run.

    .PARAMETER Workspace
        The workspace scan from Get-MigrationWorkspace. Its Path is where Workbench/Runs lives.

    .PARAMETER Timestamp
        The moment that names the run folder. Defaults to now; passed in by the tests, and by
        any caller that has already stamped the run.

    .PARAMETER Version
        The workbench version recorded in the header. Defaults to the module's version.

    .PARAMETER PwshPath
        The pwsh the runner will start. Defaults to the one this process is running, which is
        what keeps a workbench started from 7.4 from handing its step to some other pwsh on
        PATH; passed in only by the tests and by a launcher that pins its own.

    .PARAMETER SecretEnvironmentVariable
        'ParameterName=ENVIRONMENT_VARIABLE' pairs. The driver builds each named parameter
        from that environment variable in the child rather than from a value written here.
        The parameter must be one the script declares and must take a SecureString.

    .EXAMPLE
        $resolved = Resolve-MigrationStepArguments -Step $step -Workspace $ws -DryRun
        New-MigrationStepDriver -Step $step -Arguments $resolved -Workspace $ws

        Writes the rehearsal driver and returns { RunId; RunFolder; DriverPath; PwshPath;
        CommandLine; DisplayLine }.

    .EXAMPLE
        (New-MigrationStepDriver -Step $step -Arguments $resolved -Workspace $ws).DisplayLine

        Returns the human-readable equivalent the command preview shows before the operator
        commits - the same run, written the way they would have typed it.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Step,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Arguments,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [datetime]$Timestamp = [datetime]::Now,

        [ValidateNotNullOrEmpty()]
        [string]$Version,

        [ValidateNotNullOrEmpty()]
        [string]$PwshPath,

        [AllowEmptyCollection()]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z_][A-Za-z0-9_]*$')]
        [string[]]$SecretEnvironmentVariable = @()
    )

    if (-not $PSBoundParameters.ContainsKey('Version')) {
        $moduleVersion = $MyInvocation.MyCommand.Module.Version
        $Version = if ($moduleVersion) { [string]$moduleVersion } else { 'unknown' }
    }

    # The same pwsh the workbench is running in: a workbench started from 7.4 must not hand its
    # step to whatever 'pwsh' resolves to on PATH.
    if (-not $PSBoundParameters.ContainsKey('PwshPath')) {
        $PwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    }

    $workspacePath = [string]$Workspace.Path
    if (-not $workspacePath) { throw 'The workspace has no Path; nowhere to write the driver.' }

    $emitted = @($Arguments.Arguments |
            Where-Object { $_.Source -ne 'Default' -and $null -ne $_.Value })

    # Checked before anything is created: a refusal must leave no run folder behind, or the
    # workspace fills with empty evidence of runs that never happened.
    Assert-MigrationDriverArgumentSafe -Argument $emitted

    # Same rule for the secret mappings: a mapping naming a parameter the script does not have,
    # or one that does not take a SecureString, would produce a driver that fails in the child
    # with a binding error, long after the operator has typed the secret.
    $secretBindings = [System.Collections.Generic.List[object]]::new()
    foreach ($mapping in @($SecretEnvironmentVariable)) {
        $pair = ([string]$mapping -split '=', 2)
        $parameter = @(@($Step.Parameters) | Where-Object { $_.Name -eq $pair[0] })
        if ($parameter.Count -eq 0) {
            throw ("'$($pair[0])' is not a parameter of $($Step.Script), so its secret cannot be " +
                'passed through the environment.')
        }
        if ([string]$parameter[0].TypeName -ne 'SecureString') {
            throw ("-SecretEnvironmentVariable only builds SecureString parameters, and " +
                "$($Step.Script)'s -$($pair[0]) is a $($parameter[0].TypeName).")
        }
        $secretBindings.Add([pscustomobject]@{ Name = $pair[0]; Variable = $pair[1] })
    }

    # Run ids are stamped to the second because that is what the ledger and the filenames carry.
    # Two runs of one step inside the same second would otherwise share a folder and overwrite
    # each other's driver, so the second one is -2, the third -3.
    $runsRoot = Join-Path $workspacePath 'Workbench' 'Runs'
    $baseId = '{0}_{1}' -f $Timestamp.ToString('yyyyMMdd-HHmmss', [cultureinfo]::InvariantCulture), $Step.Id
    $runId = $baseId
    $attempt = 1
    while (Test-Path -LiteralPath (Join-Path $runsRoot $runId) -PathType Container) {
        $attempt++
        $runId = '{0}-{1}' -f $baseId, $attempt
    }

    $runFolder = Join-Path $runsRoot $runId
    $driverPath = Join-Path $runFolder 'driver.ps1'

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('#Requires -Version 7.4')
    $lines.Add(('# Generated by Start-MigrationWorkbench {0} on {1} for {2}.' -f $Version,
            $Timestamp.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture), $workspacePath))
    $lines.Add(('# Re-run by hand: pwsh -NoProfile -File "{0}"' -f $driverPath))
    # The child inherits neither the parent's console encoding nor its $OutputEncoding, and the
    # toolkit writes display names and addresses that are not ASCII.
    $lines.Add('[Console]::OutputEncoding = [System.Text.Encoding]::UTF8')
    $lines.Add('$OutputEncoding = [System.Text.Encoding]::UTF8')

    if ($emitted.Count -eq 0) {
        $lines.Add('$parameters = @{}')
    }
    else {
        $width = (@($emitted | ForEach-Object { ([string]$_.Name).Length }) | Measure-Object -Maximum).Maximum
        $lines.Add('$parameters = @{')
        foreach ($argument in $emitted) {
            $name = [string]$argument.Name
            $lines.Add(('    {0} = {1}' -f $name.PadRight($width),
                    (ConvertTo-MigrationPowerShellLiteral -Value $argument.Value)))
        }
        $lines.Add('}')
    }

    # A call that never reaches the script - an unknown parameter, a value the script's
    # ValidateSet rejects, a mandatory one missing - leaves $LASTEXITCODE untouched, and an
    # unset $LASTEXITCODE exits 0. A workbench that reported that as 'Completed' would be
    # telling an operator mid-migration that a step they must not skip had run. So the call is
    # guarded, and silence exits 1.
    $lines.Add('')
    $lines.Add('$ErrorActionPreference = ''Stop''')
    $lines.Add('try {')
    if ($secretBindings.Count -gt 0) {
        # Inside the try, so an environment variable that never arrived exits 1 with a message
        # rather than reaching the script with nothing bound.
        $lines.Add('    # The secret comes from this process''s own environment, never from this file.')
        foreach ($binding in $secretBindings) {
            $lines.Add(('    $parameters.{0} = ConvertTo-SecureString $env:{1} -AsPlainText -Force' -f
                    $binding.Name, $binding.Variable))
        }
    }
    $lines.Add(('    & {0} @parameters' -f (ConvertTo-MigrationPowerShellLiteral -Value ([string]$Step.ScriptPath))))
    $lines.Add('}')
    $lines.Add('catch {')
    $lines.Add('    Write-Error $_')
    $lines.Add('    exit 1')
    $lines.Add('}')
    $lines.Add('exit ([int]$LASTEXITCODE)')

    if ($PSCmdlet.ShouldProcess($driverPath, 'Write step driver')) {
        New-Item -ItemType Directory -Path $runFolder -Force -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $driverPath -Value $lines.ToArray() -Encoding utf8 -ErrorAction Stop
    }

    # Both paths are rendered as literals rather than interpolated: 'C:\Program Files\PowerShell\
    # 7\pwsh.exe' holds a space and an operator's workspace can hold an apostrophe, and a command
    # line an operator cannot paste back into a prompt is worse than no command line at all. The
    # runner reads PwshPath rather than splitting this string back apart.
    $commandLine = '& {0} -NoProfile -NonInteractive -ExecutionPolicy Bypass -File {1}' -f
        (ConvertTo-MigrationPowerShellLiteral -Value $PwshPath),
    (ConvertTo-MigrationPowerShellLiteral -Value $driverPath)

    # The display line has to account for the secret too: an operator reading a preview with no
    # -ClientSecret on it would reasonably conclude the step was about to run without one.
    $displayLine = Format-MigrationStepCommandLine -Step $Step -Argument $emitted
    foreach ($binding in $secretBindings) {
        $displayLine = '{0} -{1} $env:{2}' -f $displayLine, $binding.Name, $binding.Variable
    }

    return [pscustomobject]@{
        RunId       = $runId
        RunFolder   = $runFolder
        DriverPath  = $driverPath
        PwshPath    = $PwshPath
        CommandLine = $commandLine
        DisplayLine = $displayLine
    }
}
