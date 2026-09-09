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

        ServicePlans is a list of objects - ServicePlanId, ServicePlanName and
        ProvisioningStatus - not bare names. The GUID is what a licence assignment's
        disabledPlans array actually contains, and the provisioning status is what tells a
        licence report the difference between a plan the tenant owns and one that is
        pending or suspended, so an inventory no longer has to make its own second call to
        /subscribedSkus to recover them.

    .PARAMETER Refresh
        Discards the cache and re-reads from Graph.

    .EXAMPLE
        $catalog = Get-MigrationSkuCatalog

        Returns every subscribed SKU in the connected tenant.

    .EXAMPLE
        Get-MigrationSkuCatalog -Refresh | Where-Object Available -lt 5

        Re-reads and lists the SKUs close to running out of seats.

    .EXAMPLE
        (Get-MigrationSkuCatalog | Where-Object SkuPartNumber -eq 'SPE_E3').ServicePlans |
            Select-Object ServicePlanName, ServicePlanId

        Lists the service plans inside a SKU, with the GUIDs a disabledPlans array needs.

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
        $partNumber = [string](Get-MigrationProperty -InputObject $sku -Name 'skuPartNumber' -Default '')
        $enabled = 0
        $consumed = 0
        $prepaid = Get-MigrationProperty -InputObject $sku -Name 'prepaidUnits'
        if ($null -ne $prepaid) {
            $enabled = [int](Get-MigrationProperty -InputObject $prepaid -Name 'enabled' -Default 0)
        }
        $consumed = [int](Get-MigrationProperty -InputObject $sku -Name 'consumedUnits' -Default 0)

        # Kept as objects: the GUID is what disabledPlans is built from and the status is
        # what separates an owned plan from a pending or suspended one.
        $servicePlans = [System.Collections.Generic.List[object]]::new()
        foreach ($plan in @(Get-MigrationProperty -InputObject $sku -Name 'servicePlans' -Default @())) {
            $servicePlans.Add([pscustomobject]@{
                ServicePlanId      = [string](Get-MigrationProperty -InputObject $plan -Name 'servicePlanId' -Default '')
                ServicePlanName    = [string](Get-MigrationProperty -InputObject $plan -Name 'servicePlanName' -Default '')
                ProvisioningStatus = [string](Get-MigrationProperty -InputObject $plan -Name 'provisioningStatus' -Default '')
            })
        }

        $catalog.Add([pscustomobject]@{
            SkuId         = [string](Get-MigrationProperty -InputObject $sku -Name 'skuId' -Default '')
            SkuPartNumber = $partNumber
            FriendlyName  = Get-MigrationSkuFriendlyName -SkuPartNumber $partNumber
            Enabled       = $enabled
            Consumed      = $consumed
            Available     = ($enabled - $consumed)
            ServicePlans  = $servicePlans.ToArray()
        })
    }

    $script:SkuCatalog = $catalog.ToArray()
    Write-MigrationLog -Message "Read $($script:SkuCatalog.Count) subscribed SKU(s) from the tenant." -Level INFO
    return $script:SkuCatalog
}
