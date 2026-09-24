function Get-MigrationScriptSynopsisText {
    <#
    .SYNOPSIS
        Reads a script's one-line synopsis, memoised for the session.

    .DESCRIPTION
        The all-tools view puts each script's own words beside its name, and the only place
        those words exist is the script's comment-based help. Get-Help parses the whole file
        to find them, which is far too expensive to repeat every time the view is drawn, so
        the answer is cached per path and modification time - the same rule
        Get-MigrationScriptParameter caches by.

        The text is flattened to one line, because a synopsis carries the source file's own
        wrapping, and truncated, because the view is a list and a paragraph in it would push
        the next script off the screen.

    .PARAMETER Path
        The script whose synopsis is read.

    .PARAMETER MaximumLength
        Where to truncate. 72 characters by default.

    .EXAMPLE
        Get-MigrationScriptSynopsisText -Path ./New-MigrationUsers.ps1

        Returns 'Creates destination-tenant user accounts from a migration identity plan.'

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateRange(20, 200)]
        [int]$MaximumLength = 72
    )

    $stamp = ''
    try { $stamp = (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc.Ticks.ToString() }
    catch { $stamp = '' }
    $key = "$Path|$stamp|$MaximumLength"

    if ($script:MigrationScriptSynopsisCache.ContainsKey($key)) {
        return $script:MigrationScriptSynopsisCache[$key]
    }

    $text = ''
    try {
        $help = Get-Help -Name $Path -ErrorAction Stop
        $text = [string](Get-MigrationProperty -InputObject $help -Name 'Synopsis' -Default '')
    }
    catch {
        # A script whose help block is missing or malformed still belongs in the list; it just
        # arrives without a description.
        Write-Debug "No synopsis for '$Path': $($_.Exception.Message)"
    }

    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt $MaximumLength) { $text = $text.Substring(0, $MaximumLength - 1).TrimEnd() + '…' }

    $script:MigrationScriptSynopsisCache[$key] = $text
    return $text
}
