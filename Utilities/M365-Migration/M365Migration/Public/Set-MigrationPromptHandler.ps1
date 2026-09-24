function Set-MigrationPromptHandler {
    <#
    .SYNOPSIS
        Replaces the console workbench's prompt implementation, or restores the default one.

    .DESCRIPTION
        Every question the console workbench asks goes through one seam,
        Read-MigrationPrompt, and this is what that seam reads (Docs/Workbench-Design.md,
        section 8). With no handler set the seam prompts for real - Read-Host,
        $Host.UI.PromptForChoice, Read-Host -AsSecureString. With a handler set, the handler
        answers instead, and nothing in the module touches the host.

        That is what lets the Pester suite drive the whole console flow on macOS with no
        console at all: a test sets a handler that returns scripted answers in order and
        throws when they run out, so a loop that asks one question too many fails the test
        instead of hanging the run. It is also the seam a future non-interactive front end
        would fill - an answer file, a queue from a job definition - without the workbench
        needing to know which it is talking to.

        The handler is called with four positional arguments and must return the answer:

          param([string]$Kind, [string]$Message, [string[]]$Choices, [string]$Default)

        Kind is 'Text', 'Choice', 'Confirm' or 'Secret'. The seam coerces whatever comes back
        into the type that kind promises - a Confirm into a boolean, a Secret into a
        SecureString, a Choice into the matching entry of Choices whatever case it was typed
        in - so a handler may return plain strings throughout and every caller still gets the
        type it expects.

        The handler is module-scoped and lives as long as the imported module, so a test that
        sets one must clear it again; passing no -Handler (or $null) restores the default.

    .PARAMETER Handler
        The scriptblock to answer prompts with. Omit it, or pass $null, to restore the
        default Read-Host implementation.

    .EXAMPLE
        Set-MigrationPromptHandler -Handler { param($Kind, $Message, $Choices, $Default) 'yes' }

        Answers every prompt with 'yes' - the shape a test or an unattended front end uses.

    .EXAMPLE
        $answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('6', 'D', 'y', '', 'Q'))
        Set-MigrationPromptHandler -Handler {
            if ($answers.Count -eq 0) { throw 'The scripted answers ran out.' }
            $answers.Dequeue()
        }

        Drives the workbench with a scripted queue that throws rather than hanging when a loop
        asks one question too many.

    .EXAMPLE
        Set-MigrationPromptHandler

        Restores the default implementation, which prompts the operator for real.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets a module-scoped scriptblock in memory; nothing on disk or in a tenant changes.')]
    [OutputType([void])]
    param(
        [AllowNull()]
        [scriptblock]$Handler
    )

    # Omitting -Handler and passing $null mean the same thing, deliberately: "go back to
    # asking the operator" should not need a different call from "stop using this handler".
    $script:MigrationPromptHandler = $Handler
}
