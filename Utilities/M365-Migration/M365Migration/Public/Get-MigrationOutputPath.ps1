function Get-MigrationOutputPath {
    <#
    .SYNOPSIS
        Builds the full path for a migration output file, as the single owner of the
        filename contract.

    .DESCRIPTION
        Initialize-MigrationRun, Export-MigrationResult and Export-MigrationReport each
        used to build a filename inline, which meant the shape of the contract
        (<Prefix>_<Name>[-<Suffix>]_<timestamp>.<ext>) lived in three places instead of
        one. This function is that one place: a caller names the file and everything
        else - where it lands, what leads it, when it was written - is resolved here.

        Without -Directory the output folder comes from the run context
        (Get-MigrationRunContext), falling back to the module's default output root
        (Get-MigrationDefaultOutputRoot) when no run has been initialised. Without
        -Prefix the run context's prefix is used, falling back to no prefix at all. This
        is what lets the function be exercised in tests, and lets ad-hoc callers use it,
        without standing up a run first.

        Name, Suffix and Prefix must not contain an underscore: the underscore is the
        separator the parser (ConvertFrom-MigrationOutputPath) relies on to split
        prefix, name and timestamp apart. A hyphen is fine and expected - script and
        function names such as 'Set-Identity' or 'Migration-Inventory' are common Name
        values.

    .PARAMETER Name
        The base name of the file, for example 'Set-Identity' or 'IdentityPlan'. Must not
        contain an underscore.

    .PARAMETER Suffix
        An optional qualifier appended to Name after a hyphen, for example 'Results' or
        'DryRun'. Must not contain an underscore.

    .PARAMETER Extension
        The file extension, without a leading dot required (one is stripped if given).
        Defaults to 'csv'.

    .PARAMETER Timestamp
        The moment to encode in the filename. Defaults to the current time; a fixed value
        makes the function's output deterministic for tests.

    .PARAMETER Directory
        The folder the file will live in. Defaults to the run context's OutputDirectory,
        or the module's default output root when no run is active.

    .PARAMETER Prefix
        Names the client or run; becomes the filename's leading '<Prefix>_'. Defaults to
        the run context's Prefix, or no leader at all when no run is active. Must not
        contain an underscore.

    .EXAMPLE
        Get-MigrationOutputPath -Name 'Set-Identity' -Suffix 'Results'

        Returns '<run output directory>/<run prefix>_Set-Identity-Results_<now>.csv'.

    .EXAMPLE
        Get-MigrationOutputPath -Directory $TestDrive -Prefix 'Contoso' -Name 'IdentityPlan' -Extension 'xlsx'

        Returns '<TestDrive>/Contoso_IdentityPlan_<now>.xlsx', ignoring any active run context.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Suffix,

        [ValidateNotNullOrEmpty()]
        [string]$Extension = 'csv',

        [datetime]$Timestamp,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Directory,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Prefix
    )

    if ($Name -match '_' -or $Suffix -match '_' -or $Prefix -match '_') {
        throw 'Name, Suffix and Prefix must not contain an underscore: it is the separator of the filename contract.'
    }

    $run = Get-MigrationRunContext
    if (-not $PSBoundParameters.ContainsKey('Directory')) {
        $Directory = if ($run) { [string]$run.OutputDirectory } else { Get-MigrationDefaultOutputRoot }
    }
    if (-not $PSBoundParameters.ContainsKey('Prefix')) {
        $Prefix = if ($run) { [string]$run.Prefix } else { '' }
    }
    if (-not $PSBoundParameters.ContainsKey('Timestamp')) {
        $Timestamp = Get-Date
    }

    $leader = if ($Prefix) { "${Prefix}_" } else { '' }
    $qualifier = if ([string]::IsNullOrWhiteSpace($Suffix)) { '' } else { "-$($Suffix.Trim())" }
    $stamp = $Timestamp.ToString('yyyyMMdd-HHmmss')
    $fileName = '{0}{1}{2}_{3}.{4}' -f $leader, $Name, $qualifier, $stamp, $Extension.TrimStart('.')

    return (Join-Path -Path $Directory -ChildPath $fileName)
}
