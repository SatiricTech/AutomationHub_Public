function Get-MigrationSecretNamePattern {
    <#
    .SYNOPSIS
        Returns the one regex that decides whether a name reads like a secret.

    .DESCRIPTION
        Three places in the toolkit have to answer the same question - "could a thing with this
        name be a credential?" - and they must answer it identically:

          Initialize-MigrationRun            masks the value in the run log.
          Resolve-MigrationSettingsData      refuses the key in the settings file.
          Assert-MigrationDriverArgumentSafe refuses to write it into a driver.

        They used to carry three copies of the same expression, which is one copy too many for
        a rule whose whole job is to be exhaustive: a word added to one copy and not the others
        is a leak that nobody notices. It lives here instead.

        The pattern is deliberately over-inclusive. A false positive costs a masked log line or
        a refusal the operator can see; a false negative writes a credential into a file that
        is synced, backed up and read by whoever opens the folder next. Each caller narrows it
        where it can defend the exception - a known schema key, a boolean, a length - and
        documents why on its own terms.

    .EXAMPLE
        'ClientSecret' -match (Get-MigrationSecretNamePattern)

        Returns $true.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return 'password|passphrase|secret|credential|token|apikey|api-key|certificate|thumbprint|key$'
}
