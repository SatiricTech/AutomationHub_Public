function Read-MigrationPrompt {
    <#
    .SYNOPSIS
        Asks the operator one question, through the seam a test can answer for them.

    .DESCRIPTION
        The console workbench's only way of asking anything (Docs/Workbench-Design.md,
        section 8). One function, four kinds of question, and a handler
        (Set-MigrationPromptHandler) that can stand in for the host entirely - which is what
        lets the Pester suite drive the whole console flow on macOS with no console.

          Text     Read-Host. An empty answer means "accept the suggestion", so a settings
                   form can put the suggestion in the prompt and let Enter take it.
          Choice   $Host.UI.PromptForChoice, returning the chosen label rather than its
                   index, because the caller wants the value and not a position in a list
                   that a later release may reorder.
          Confirm  A y/n Read-Host returning a boolean. Asked until it is answered: a gate
                   that silently read a typo as "no" would be worse than asking again.
          Secret   Read-Host -AsSecureString. Returned as a SecureString and never echoed,
                   never logged and never written to a driver file.

        Whatever a handler returns is coerced to the type its kind promises, so a handler -
        a test's scripted queue, an answer file, a job definition - may return plain strings
        throughout and every caller still gets a boolean, a SecureString or a known label.

        This is the one file in the module allowed to call Read-Host or $Host.UI: the
        toolkit's own scripts must run unattended, and Tests/M365Migration.Tests.ps1 asserts
        that of every other file. The seam is what makes that rule affordable - the console
        front end asks its questions here and nowhere else.

    .PARAMETER Kind
        Text, Choice, Confirm or Secret.

    .PARAMETER Message
        The question, without a trailing colon or bracketed suggestion - both are added.

    .PARAMETER Choices
        The labels a Choice prompt offers. Ignored by the other kinds.

    .PARAMETER Default
        The suggestion an empty answer accepts, and the pre-selected label of a Choice.

    .EXAMPLE
        Read-MigrationPrompt -Kind 'Text' -Message 'Label' -Default 'Contoso'

        Returns what the operator typed, or 'Contoso' when they just pressed Enter.

    .EXAMPLE
        Read-MigrationPrompt -Kind 'Choice' -Message 'Scenario' -Choices @('TenantToTenant', 'InPlaceRedesign')

        Returns the chosen label.

    .EXAMPLE
        if (Read-MigrationPrompt -Kind 'Confirm' -Message 'Run now?') { 'running' }

        Returns $true or $false.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        Exported so the entry script's workspace picker prompts through the same seam the
        console does, which keeps the repo-wide "no Read-Host" guard meaningful and lets
        tests script every prompt with Set-MigrationPromptHandler.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'This is the console prompt seam; re-asking an unanswered question is host output by design.')]
    # The justification is one string literal rather than a concatenation: PSScriptAnalyzer
    # refuses to read a suppression whose arguments are not string constants, and a suppression
    # it cannot read is a suppression that does not apply.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'This is the prompt seam coercing a handler''s answer (a test''s scripted string) to
        the SecureString the Secret kind promises; the value never comes from a file, an argument or a log,
        and the host branch uses Read-Host -AsSecureString.')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Text', 'Choice', 'Confirm', 'Secret')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Choices = @(),

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Default = ''
    )

    $choiceList = @($Choices | Where-Object { $null -ne $_ })

    if ($null -ne $script:MigrationPromptHandler) {
        $answer = & $script:MigrationPromptHandler $Kind $Message $choiceList $Default

        switch ($Kind) {
            'Confirm' {
                if ($answer -is [bool]) { return $answer }
                return (([string]$answer).Trim() -match '^(y|yes|true|1)$')
            }
            'Secret' {
                if ($answer -is [System.Security.SecureString]) { return $answer }
                $plain = [string]$answer
                # ConvertTo-SecureString refuses an empty string, and "the operator typed
                # nothing" is a real answer the caller has to be able to see as an empty one.
                if ([string]::IsNullOrEmpty($plain)) { return [System.Security.SecureString]::new() }
                return (ConvertTo-SecureString -String $plain -AsPlainText -Force)
            }
            'Choice' {
                $typed = ([string]$answer).Trim()
                $matched = @($choiceList | Where-Object { $_ -ieq $typed })
                # The declared label, in its own casing: the caller compares it against the
                # list it passed in, so 'inplaceredesign' has to come back 'InPlaceRedesign'.
                if ($matched.Count -gt 0) { return $matched[0] }
                if (-not $typed) { return $Default }
                return $typed
            }
            default {
                $typed = [string]$answer
                if ([string]::IsNullOrEmpty($typed)) { return $Default }
                return $typed
            }
        }
    }

    switch ($Kind) {
        'Secret' {
            return (Read-Host -Prompt $Message -AsSecureString)
        }
        'Confirm' {
            $suffix = if ($Default -match '^(y|yes|true|1)$') { '[Y/n]' }
            elseif ($Default) { '[y/N]' }
            else { '[y/n]' }

            # Unbounded on purpose: this branch only ever runs in front of a person, and a
            # gate that took a typo for an answer is the failure mode worth avoiding.
            while ($true) {
                $typed = ([string](Read-Host -Prompt "$Message $suffix")).Trim()
                if (-not $typed -and $Default) { $typed = $Default }
                if ($typed -match '^(y|yes|true|1)$') { return $true }
                if ($typed -match '^(n|no|false|0)$') { return $false }
                Write-Host 'Please answer y or n.'
            }
        }
        'Choice' {
            if ($choiceList.Count -eq 0) { return $Default }

            $descriptions = [System.Collections.ObjectModel.Collection[
                System.Management.Automation.Host.ChoiceDescription]]::new()
            # No '&' hotkeys: the labels are waves, scenarios and verbosity levels, and two of
            # them sharing a first letter would make the hotkeys ambiguous.
            foreach ($label in $choiceList) {
                $descriptions.Add([System.Management.Automation.Host.ChoiceDescription]::new($label, $label))
            }

            $selected = 0
            for ($index = 0; $index -lt $choiceList.Count; $index++) {
                if ($choiceList[$index] -ieq $Default) { $selected = $index; break }
            }

            $answer = $Host.UI.PromptForChoice('', $Message, $descriptions, $selected)
            return $choiceList[$answer]
        }
        default {
            $prompt = if ($Default) { "$Message [$Default]" } else { $Message }
            $typed = [string](Read-Host -Prompt $prompt)
            if ([string]::IsNullOrEmpty($typed)) { return $Default }
            return $typed
        }
    }
}
