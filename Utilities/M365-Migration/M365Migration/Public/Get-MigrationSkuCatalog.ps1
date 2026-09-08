function Get-MigrationSkuCatalog {
    <#
    .SYNOPSIS
        Returns the tenant's subscribed SKUs with friendly names and seat counts.

    .DESCRIPTION
        Licence planning needs three facts per SKU that Graph splits across two shapes:
        the GUID a licence assignment actually uses, the part number a human recognises,
        and how many seats are left. This returns all three, plus the friendly product
        name, in one object per SKU.

        The result is cached for the life of the session because seat counts are read
        many times during a wave and the numbers do not move between reads of the same
        run. -Refresh forces a re-read after licences have been purchased or assigned.

        Available seats are enabled minus consumed. A SKU with warning or suspended
        units still reports its enabled count, which is what Microsoft 365 will actually
        let you assign.

    .PARAMETER Refresh
        Discards the cache and re-reads from Graph.

    .EXAMPLE
        $catalog = Get-MigrationSkuCatalog

        Returns every subscribed SKU in the connected tenant.

    .EXAMPLE
        Get-MigrationSkuCatalog -Refresh | Where-Object Available -lt 5

        Re-reads and lists the SKUs close to running out of seats.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        Requires an active Graph session with at least Organization.Read.All.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$Refresh
    )

    if ($script:SkuCatalog -and -not $Refresh) {
        return $script:SkuCatalog
    }

    $skus = @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/subscribedSkus' -All)

    $catalog = [System.Collections.Generic.List[object]]::new()
    foreach ($sku in $skus) {
        $partNumber = [string]$sku.skuPartNumber
        $enabled = 0
        $consumed = 0
        if ($sku.PSObject.Properties['prepaidUnits'] -and $sku.prepaidUnits) {
            $enabled = [int]$sku.prepaidUnits.enabled
        }
        if ($sku.PSObject.Properties['consumedUnits']) {
            $consumed = [int]$sku.consumedUnits
        }

        $servicePlans = @()
        if ($sku.PSObject.Properties['servicePlans'] -and $sku.servicePlans) {
            $servicePlans = @($sku.servicePlans | ForEach-Object { [string]$_.servicePlanName })
        }

        $catalog.Add([pscustomobject]@{
            SkuId         = [string]$sku.skuId
            SkuPartNumber = $partNumber
            FriendlyName  = Get-MigrationSkuFriendlyName -SkuPartNumber $partNumber
            Enabled       = $enabled
            Consumed      = $consumed
            Available     = ($enabled - $consumed)
            ServicePlans  = $servicePlans
        })
    }

    $script:SkuCatalog = $catalog.ToArray()
    Write-MigrationLog -Message "Read $($script:SkuCatalog.Count) subscribed SKU(s) from the tenant." -Level INFO
    return $script:SkuCatalog
}
