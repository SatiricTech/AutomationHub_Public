function Read-MigrationFileTail {
    <#
    .SYNOPSIS
        Returns the complete lines appended to a file since a byte offset, without locking it.

    .DESCRIPTION
        This is how the workbench's live log works (Docs/Workbench-Design.md, section 7.3). The
        child process still has stdout.txt open for writing, so the file is opened with
        FileShare ReadWrite,Delete - anything stricter would make the poll fail, or worse, make
        the child's next write fail.

        Only whole lines come back. Reading stops at the last newline in the new bytes and the
        offset is left there, so a line the child is still writing is re-read on the next poll
        instead of reaching the log pane cut in half. That also keeps the offset on a character
        boundary, which is what makes it safe to decode each chunk as UTF-8 on its own: a
        multi-byte character can never straddle two reads.

        -Flush lifts the whole-lines rule for the one call that needs it: the final read after
        the child has exited, when a last line without a trailing newline is all there will
        ever be. Using it while the process is alive would show half-written lines.

        A missing file is not an error - the child may not have written anything yet - and
        neither is a transient sharing failure: both return nothing and leave the offset alone,
        because a poll that fails must cost one poll, not the run.

    .PARAMETER Path
        The file to read.

    .PARAMETER Offset
        A [ref] to the byte offset to resume from, updated to where the next call should start.

    .PARAMETER Flush
        Return a trailing partial line as well. For the final read after the child has exited.

    .EXAMPLE
        $offset = [long]0
        Read-MigrationFileTail -Path $stdout -Offset ([ref]$offset)

        Returns the complete lines written so far and moves the offset past them.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ref]$Offset,

        [switch]$Flush
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    $stream = $null
    try {
        $start = [long]$Offset.Value
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        if ($stream.Length -le $start) { return @() }

        [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $count = [int][System.Math]::Min([long][int]::MaxValue, ($stream.Length - $start))
        $buffer = [byte[]]::new($count)
        $read = $stream.Read($buffer, 0, $count)
        if ($read -le 0) { return @() }

        $usable = $read
        if (-not $Flush) {
            $lastBreak = -1
            for ($index = $read - 1; $index -ge 0; $index--) {
                if ($buffer[$index] -eq 10) { $lastBreak = $index; break }
            }
            if ($lastBreak -lt 0) { return @() }
            $usable = $lastBreak + 1
        }

        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $usable)
        $Offset.Value = $start + $usable

        # A redirect file can open with a byte-order mark; it belongs to the file, not to the
        # first line the operator reads.
        if ($start -eq 0) { $text = $text.TrimStart([char]0xFEFF) }

        $lines = @($text -split "`n")
        # A chunk that ends on a newline leaves an empty final element; one flushed mid-line
        # does not, and that remainder is a real line.
        if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }

        return @($lines | ForEach-Object { $_.TrimEnd("`r") })
    }
    catch {
        return @()
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}
