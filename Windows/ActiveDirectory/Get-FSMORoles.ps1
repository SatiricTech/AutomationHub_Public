# Get Forest FSMO roles
Write-Host "`nForest FSMO Roles:" -ForegroundColor Green
$forest = Get-ADForest
Write-Host "Schema Master: $($forest.SchemaMaster)"
Write-Host "Domain Naming Master: $($forest.DomainNamingMaster)"

# Get Domain FSMO roles
Write-Host "`nDomain FSMO Roles:" -ForegroundColor Green
$domain = Get-ADDomain
Write-Host "PDC Emulator: $($domain.PDCEmulator)"
Write-Host "RID Master: $($domain.RIDMaster)"
Write-Host "Infrastructure Master: $($domain.InfrastructureMaster)"

# Get Detailed Domain Controller Information from AD
Write-Host "`nDetailed Domain Controller Information:" -ForegroundColor Green
$DCs = Get-ADDomainController -Filter * | ForEach-Object {
    $computerInfo = Get-ADComputer $_.Name -Properties *
    [PSCustomObject]@{
        'Server Name' = $_.Name
        'Site' = $_.Site
        'IP Address' = $_.IPv4Address
        'Operating System' = $computerInfo.OperatingSystem
        'OS Version' = $computerInfo.OperatingSystemVersion
        'Enabled' = $computerInfo.Enabled
        'Global Catalog' = $_.IsGlobalCatalog
        'Read-only DC' = $_.IsReadOnly
        'Created Date' = $computerInfo.Created
        'Last Logon Timestamp' = [datetime]::FromFileTime($computerInfo.lastLogonTimestamp)
    }
}

# Display results in a formatted table
$DCs | Format-Table -AutoSize -Wrap

# Display Global Catalog Servers
Write-Host "`nGlobal Catalog Servers:" -ForegroundColor Green
Get-ADForest | Select-Object -ExpandProperty GlobalCatalogs