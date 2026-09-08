#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Sku-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null

    function New-SkuMapFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds a fixture inside the test workspace.')]
        param([string]$Name, [string]$Content)
        $path = Join-Path $script:workspace $Name
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8
        return $path
    }
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-MigrationSkuMap' {

    It 'Maps one source SKU to one target' {
        $path = New-SkuMapFile -Name 'simple.csv' -Content @'
SourceSkuPartNumber,TargetSkuPartNumber
ENTERPRISEPACK,SPE_E3
'@
        $map = Resolve-MigrationSkuMap -Path $path
        $map['ENTERPRISEPACK'] | Should -Be @('SPE_E3')
    }

    It 'Fans one source SKU out to several targets' {
        $path = New-SkuMapFile -Name 'fanout.csv' -Content @'
SourceSkuPartNumber,TargetSkuPartNumber
ENTERPRISEPACK,SPE_E3;MCOEV
'@
        (Resolve-MigrationSkuMap -Path $path)['ENTERPRISEPACK'] | Should -Be @('SPE_E3', 'MCOEV')
    }

    It 'Treats a blank target as a deliberate drop' {
        $path = New-SkuMapFile -Name 'drop.csv' -Content @'
SourceSkuPartNumber,TargetSkuPartNumber
POWER_BI_STANDARD,
'@
        $map = Resolve-MigrationSkuMap -Path $path
        $map.ContainsKey('POWER_BI_STANDARD') | Should -BeTrue
        $map['POWER_BI_STANDARD'].Count | Should -Be 0
    }

    It 'Throws when a required column is missing' {
        $path = New-SkuMapFile -Name 'bad-header.csv' -Content @'
SourceSku,TargetSku
ENTERPRISEPACK,SPE_E3
'@
        { Resolve-MigrationSkuMap -Path $path } |
            Should -Throw -ExpectedMessage "*missing the required column 'SourceSkuPartNumber'*"
    }

    It 'Throws on a duplicate source SKU rather than silently merging' {
        $path = New-SkuMapFile -Name 'duplicate.csv' -Content @'
SourceSkuPartNumber,TargetSkuPartNumber
ENTERPRISEPACK,SPE_E3
ENTERPRISEPACK,SPE_E5
'@
        { Resolve-MigrationSkuMap -Path $path } | Should -Throw -ExpectedMessage '*more than once*'
    }

    It 'Throws on an empty source SKU' {
        $path = New-SkuMapFile -Name 'empty-source.csv' -Content @'
SourceSkuPartNumber,TargetSkuPartNumber
,SPE_E3
'@
        { Resolve-MigrationSkuMap -Path $path } | Should -Throw -ExpectedMessage '*empty SourceSkuPartNumber*'
    }

    It 'Throws when the file does not exist' {
        { Resolve-MigrationSkuMap -Path (Join-Path $script:workspace 'nope.csv') } |
            Should -Throw -ExpectedMessage '*not found*'
    }

    It 'Reads the shipped sample without complaint' {
        $sample = Join-Path $PSScriptRoot '..' 'Templates' 'SkuMap.sample.csv'
        $map = Resolve-MigrationSkuMap -Path $sample
        $map.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-MigrationSkuCatalog' {

    It 'Shapes each SKU with friendly name and seat counts' {
        InModuleScope M365Migration {
            $script:SkuCatalog = $null
            Mock Invoke-MigrationGraphRequest {
                @(
                    [pscustomobject]@{
                        skuId = '11111111-1111-1111-1111-111111111111'
                        skuPartNumber = 'SPE_E3'
                        prepaidUnits = [pscustomobject]@{ enabled = 25 }
                        consumedUnits = 20
                        servicePlans = @([pscustomobject]@{ servicePlanName = 'EXCHANGE_S_ENTERPRISE' })
                    }
                )
            }

            $catalog = Get-MigrationSkuCatalog -Refresh
            $catalog | Should -HaveCount 1
            $catalog[0].SkuPartNumber | Should -BeExactly 'SPE_E3'
            $catalog[0].FriendlyName | Should -BeExactly 'Microsoft 365 E3'
            $catalog[0].Available | Should -Be 5
            $catalog[0].ServicePlans | Should -Be @('EXCHANGE_S_ENTERPRISE')
        }
    }

    It 'Falls back to the part number for an unmapped SKU' {
        InModuleScope M365Migration {
            $script:SkuCatalog = $null
            Mock Invoke-MigrationGraphRequest {
                @([pscustomobject]@{
                    skuId = '2'; skuPartNumber = 'SOME_NEW_SKU'
                    prepaidUnits = [pscustomobject]@{ enabled = 1 }; consumedUnits = 0; servicePlans = @() })
            }

            (Get-MigrationSkuCatalog -Refresh)[0].FriendlyName | Should -BeExactly 'SOME_NEW_SKU'
        }
    }

    It 'Serves the cache on the second call and re-reads with -Refresh' {
        InModuleScope M365Migration {
            $script:SkuCatalog = $null
            Mock Invoke-MigrationGraphRequest {
                @([pscustomobject]@{
                    skuId = '3'; skuPartNumber = 'SPB'
                    prepaidUnits = [pscustomobject]@{ enabled = 1 }; consumedUnits = 0; servicePlans = @() })
            }

            $null = Get-MigrationSkuCatalog
            $null = Get-MigrationSkuCatalog
            Should -Invoke Invoke-MigrationGraphRequest -Times 1 -Exactly

            $null = Get-MigrationSkuCatalog -Refresh
            Should -Invoke Invoke-MigrationGraphRequest -Times 2 -Exactly
        }
    }
}

Describe 'Get-MigrationTargetDomain' {

    It 'Returns a requested domain that is verified' {
        Get-MigrationTargetDomain -Domains @('newco.com', 'newco.onmicrosoft.com') -Requested 'newco.com' |
            Should -BeExactly 'newco.com'
    }

    It 'Matches a requested domain case-insensitively' {
        Get-MigrationTargetDomain -Domains @('newco.com') -Requested 'NewCo.COM' | Should -BeExactly 'newco.com'
    }

    It 'Throws when the requested domain is not verified' {
        { Get-MigrationTargetDomain -Domains @('newco.com') -Requested 'contoso.com' } |
            Should -Throw -ExpectedMessage '*not verified*'
    }

    It 'Returns the only verified domain without prompting' {
        Get-MigrationTargetDomain -Domains @('newco.com') | Should -BeExactly 'newco.com'
    }

    It 'Throws under DryRun rather than prompting' {
        InModuleScope M365Migration {
            $script:MigrationRun = @{ DryRun = $true; Verbosity = 'Medium'; LogPath = $null }
            try {
                { Get-MigrationTargetDomain -Domains @('newco.com', 'other.com') } |
                    Should -Throw -ExpectedMessage '*must be supplied with -TargetDomain*'
            }
            finally {
                $script:MigrationRun = $null
            }
        }
    }

    It 'Throws when the tenant has no verified domains' {
        { Get-MigrationTargetDomain -Domains @() } | Should -Throw -ExpectedMessage '*No verified domains*'
    }
}
