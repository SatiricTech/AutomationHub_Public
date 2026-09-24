function New-MigrationSettingsError {
    <#
    .SYNOPSIS
        Builds one settings validation error: the message, and the schema key it is about.

    .DESCRIPTION
        A settings error has always had a message. What it lacked was the one thing a form
        needs from it - which key to ask about again - and the console's first version of that
        was a wildcard match against the prose. Prose is the wrong thing to parse: the day a
        message is reworded, a settings form silently stops re-asking the question it was the
        whole point of.

        So each error carries a Key. It is the dotted schema key where the error is about one
        ('Domains.Target', 'Label'), and an empty string where it is about the document rather
        than a key - a file that is not an object at all, a key the schema does not define, a
        section that should have been an object. A form re-asks the keys it recognises and
        gives up honestly on the rest, which is what the operator wants: a question they can
        answer, or a plain statement that this one needs the file editing.

        ToString returns the message, so every existing reader - a '-join', a Write-Warning,
        an interpolated string - keeps working exactly as it did when these were strings.

    .PARAMETER Message
        The sentence an operator reads.

    .PARAMETER Key
        The dotted schema key this error is about, or '' for a file-level problem.

    .EXAMPLE
        New-MigrationSettingsError -Message "Key 'Label' must not be empty." -Key 'Label'

        Returns the error the settings form re-asks Label for.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only; nothing is written to disk or to a tenant.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [AllowEmptyString()]
        [string]$Key = ''
    )

    $entry = [pscustomobject]@{
        PSTypeName = 'M365Migration.SettingsError'
        Key        = $Key
        Message    = $Message
    }

    # -Force because PSObject already has a ToString; this is what keeps every caller that
    # joined or interpolated these when they were plain strings working unchanged.
    Add-Member -InputObject $entry -MemberType ScriptMethod -Name 'ToString' -Force -Value {
        return $this.Message
    }

    return $entry
}
