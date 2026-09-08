#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Invoke-MigrationGraphRequest' {

    Context 'Response shaping' {

        It 'Returns the value array for a collection response' {
            InModuleScope M365Migration {
                Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = '1' }, [pscustomobject]@{ id = '2' }) } }

                $result = Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users'
                $result | Should -HaveCount 2
                @($result.id) | Should -Be @('1', '2')
            }
        }

        It 'Returns the object itself for a single-object response' {
            InModuleScope M365Migration {
                Mock Invoke-MgGraphRequest { [pscustomobject]@{ id = '1'; userPrincipalName = 'john@contoso.com' } }

                $result = Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users/1'
                $result.userPrincipalName | Should -BeExactly 'john@contoso.com'
            }
        }

        It 'Serialises a body to JSON' {
            InModuleScope M365Migration {
                Mock Invoke-MgGraphRequest { [pscustomobject]@{ ok = $true } } -ParameterFilter {
                    $Body -is [string] -and $Body -match '"usageLocation"' -and $ContentType -eq 'application/json'
                }

                $null = Invoke-MigrationGraphRequest -Method PATCH -Uri '/v1.0/users/1' -Body @{ usageLocation = 'US' }
                Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
            }
        }
    }

    Context 'Paging' {

        It 'Concatenates every page when -All is given' {
            InModuleScope M365Migration {
                Mock Invoke-MgGraphRequest {
                    switch ($Uri) {
                        '/v1.0/users' {
                            [pscustomobject]@{
                                value            = @([pscustomobject]@{ id = '1' }, [pscustomobject]@{ id = '2' })
                                '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=page2'
                            }
                        }
                        'https://graph.microsoft.com/v1.0/users?$skiptoken=page2' {
                            [pscustomobject]@{
                                value            = @([pscustomobject]@{ id = '3' })
                                '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=page3'
                            }
                        }
                        default { [pscustomobject]@{ value = @([pscustomobject]@{ id = '4' }) } }
                    }
                }

                $result = Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users' -All
                @($result.id) | Should -Be @('1', '2', '3', '4')
                Should -Invoke Invoke-MgGraphRequest -Times 3 -Exactly
            }
        }

        It 'Returns only the first page without -All' {
            InModuleScope M365Migration {
                Mock Invoke-MgGraphRequest {
                    [pscustomobject]@{
                        value            = @([pscustomobject]@{ id = '1' })
                        '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=page2'
                    }
                }

                $result = Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users'
                $result | Should -HaveCount 1
                Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
            }
        }
    }

    Context 'Throttling and retry' {

        BeforeAll {
            # Defined in the module's own script scope so the InModuleScope blocks below
            # can call it directly - a Graph HTTP failure carrying a status code and,
            # optionally, a Retry-After header.
            InModuleScope M365Migration {
                function script:New-GraphHttpError {
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                        Justification = 'Pester helper that builds an in-memory exception.')]
                    param([int]$StatusCode, $RetryAfter)

                    $exception = [System.Exception]::new("Response status code does not indicate success: $StatusCode.")
                    $headers = @{}
                    if ($null -ne $RetryAfter) { $headers['Retry-After'] = $RetryAfter }
                    $response = [pscustomobject]@{ StatusCode = $StatusCode; Headers = $headers }
                    Add-Member -InputObject $exception -NotePropertyName 'Response' -NotePropertyValue $response
                    return $exception
                }
            }
        }

        It 'Waits for the number of seconds the Retry-After header asks for' {
            InModuleScope M365Migration {
                $script:attempts = 0
                Mock Start-Sleep { }
                Mock Invoke-MgGraphRequest {
                    $script:attempts++
                    if ($script:attempts -eq 1) { throw (New-GraphHttpError -StatusCode 429 -RetryAfter '7') }
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }) }
                }

                $result = Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users'
                $result | Should -HaveCount 1
                Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
            }
        }

        It 'Backs off exponentially when no Retry-After is supplied' {
            InModuleScope M365Migration {
                $script:attempts = 0
                Mock Start-Sleep { }
                Mock Invoke-MgGraphRequest {
                    $script:attempts++
                    if ($script:attempts -le 2) { throw (New-GraphHttpError -StatusCode 503) }
                    return [pscustomobject]@{ value = @() }
                }

                $null = Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users'
                Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
                Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
            }
        }

        It 'Retries a 504 as well' {
            InModuleScope M365Migration {
                $script:attempts = 0
                Mock Start-Sleep { }
                Mock Invoke-MgGraphRequest {
                    $script:attempts++
                    if ($script:attempts -eq 1) { throw (New-GraphHttpError -StatusCode 504) }
                    return [pscustomobject]@{ ok = $true }
                }

                (Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users/1').ok | Should -BeTrue
            }
        }

        It 'Does not retry a 403' {
            InModuleScope M365Migration {
                Mock Start-Sleep { }
                Mock Invoke-MgGraphRequest { throw (New-GraphHttpError -StatusCode 403) }

                { Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users' } | Should -Throw
                Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
                Should -Invoke Start-Sleep -Times 0 -Exactly
            }
        }

        It 'Gives up after MaxRetry attempts' {
            InModuleScope M365Migration {
                Mock Start-Sleep { }
                Mock Invoke-MgGraphRequest { throw (New-GraphHttpError -StatusCode 429 -RetryAfter '1') }

                { Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users' -MaxRetry 3 } | Should -Throw
                Should -Invoke Invoke-MgGraphRequest -Times 3 -Exactly
            }
        }
    }
}
