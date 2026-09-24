#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    # MicrosoftTeams is not installed on a build agent, so the cmdlet the function wraps is
    # stubbed into the module scope for Mock to replace.
    InModuleScope M365Migration {
        if (-not (Get-Command -Name 'Get-CsOnlineUser' -ErrorAction SilentlyContinue)) {
            function script:Get-CsOnlineUser {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'A signature-only stub so Mock has a command to replace; the parameters exist to be matched by -ParameterFilter, not used.')]
                param([string]$Identity, [string]$Filter)
                return $null
            }
        }
    }
}

Describe 'Resolve-MigrationTeamsUser' {

    It 'Returns the user the cmdlet found' {
        InModuleScope M365Migration {
            Mock Get-CsOnlineUser { [pscustomobject]@{ UserPrincipalName = 'john.smith@contoso.com' } }

            $user = Resolve-MigrationTeamsUser -Identity 'john.smith@contoso.com'
            $user.UserPrincipalName | Should -BeExactly 'john.smith@contoso.com'
        }
    }

    It 'Rethrows a failure that is not a missing user' {
        InModuleScope M365Migration {
            Mock Get-CsOnlineUser { throw 'The access token has expired' }

            { Resolve-MigrationTeamsUser -Identity 'john.smith@contoso.com' } |
                Should -Throw -ExpectedMessage '*access token*'
        }
    }

    It 'Names the identity it could not resolve in the rethrown message' {
        InModuleScope M365Migration {
            Mock Get-CsOnlineUser { throw 'Request throttled (429)' }

            { Resolve-MigrationTeamsUser -Identity 'john.smith@contoso.com' } |
                Should -Throw -ExpectedMessage (
                    "*Could not resolve Teams user 'john.smith@contoso.com': Request throttled (429)*")
        }
    }

    It 'Returns $null for a missing user: <Message>' -ForEach @(
        @{ Message = 'User not found' }
        @{ Message = 'The user could not be found in the tenant.' }
        @{ Message = 'Identity does not exist.' }
        @{ Message = 'Cannot find the requested object.' }
        @{ Message = 'Unable to find the user in this tenant.' }
        @{ Message = 'USER NOT FOUND' }
    ) {
        InModuleScope M365Migration -Parameters @{ NotFoundMessage = $Message } {
            param($NotFoundMessage)

            Mock Get-CsOnlineUser { throw $NotFoundMessage }

            Resolve-MigrationTeamsUser -Identity 'jane.doe@contoso.com' |
                Should -BeNullOrEmpty -Because "'$NotFoundMessage' means the user is absent, not that the lookup broke"
        }
    }
}
