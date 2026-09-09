#Requires -Version 7.4

<#
.SYNOPSIS
    Creates destination-tenant user accounts from a migration identity plan.

.DESCRIPTION
    Phase 3 of the migration toolkit. The identity plan is the single source of truth for
    who gets created and what they are called; this script turns its User rows into
    Microsoft Entra accounts and writes the resulting object IDs back into the plan so the
    later phases can find the accounts they are about to touch.

    Address choice. A wave is usually staged on the destination tenant's onmicrosoft.com
    domain first, because the vanity domain is still answering mail in the source tenant.
    Each row is created on its TargetUserPrincipalName when that domain is verified in the
    destination tenant, and falls back to the InterimUserPrincipalName with a per-row
    warning when it is not. -UseInterim forces the interim address for the whole run.

    Hiding from the GAL. Freshly created users have no mailbox, so Set-Mailbox has nothing
    to act on. -HideFromAddressLists therefore sets the directory's showInAddressList
    property at creation time. Microsoft documents that as a known issue - Exchange's own
    HiddenFromAddressListsEnabled wins once a mailbox is provisioned - so treat it as a
    pre-mailbox stopgap and re-apply the hide through Set-MigrationIdentity afterwards.

    Licensing. -AssignLicenses assigns each row's TargetLicenses immediately after
    creation. A usage location is mandatory for that call, so a row with no UsageLocation
    and no -DefaultUsageLocation is created but reported as licence-skipped rather than
    failed. Set-MigrationLicenses remains the tool for a licensing-only pass, seat
    pre-checks and removals.

    Managers. -SetManagers runs a second pass once every row has been created, because a
    manager frequently appears later in the plan than the people reporting to them.
    Managers outside the plan are reported, not guessed at.

    Passwords are generated per user and written to the results CSV only. They are never
    logged. Store the results file the way you would store any other password list.

    -DryRun connects read-only, evaluates every row, and writes a results file whose rows
    are all Status 'Planned'.

.PARAMETER PlanPath
    The identity plan CSV from New-MigrationIdentityPlan. Read in full, filtered in
    memory, and written back in place with the object IDs this run created.

.PARAMETER Wave
    Restricts the run to these plan waves. Omit to process every wave in the file.

.PARAMETER UseInterim
    Creates every account on its InterimUserPrincipalName instead of the target UPN.

.PARAMETER HideFromAddressLists
    Sets showInAddressList to false at creation. See the DESCRIPTION for the caveat.

.PARAMETER AssignLicenses
    Assigns each row's TargetLicenses immediately after the account is created.

.PARAMETER SetManagers
    Runs a second pass that resolves ManagerUpn through the plan and sets the manager.

.PARAMETER ForceChangePassword
    Whether the generated password must be changed at first sign-in. Defaults to $true.

.PARAMETER PasswordLength
    Length of the generated password. Defaults to 16.

.PARAMETER DefaultUsageLocation
    Two-letter ISO country code used when a plan row has no UsageLocation.

.PARAMETER TenantId
    The destination tenant to sign in to.

.PARAMETER IncludeCollisions
    Also processes rows whose PlanStatus is 'Collision'.

.PARAMETER OutputPath
    Overrides the output root for the log and results files.

.PARAMETER Prefix
    Names the client or run. Output lands in <root>\<Prefix>\ with '<Prefix>_' filenames.

.PARAMETER LogPath
    Overrides the derived log file path.

.PARAMETER DryRun
    Evaluates every row and writes a '-DryRun_' results file without changing anything.

.PARAMETER Verbosity
    Console verbosity: Low, Medium (default) or High. The log file always gets everything.

.EXAMPLE
    .\New-MigrationUsers.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -DryRun

    Rehearses wave one: reports the UPN each account would be created on and which rows
    are skipped and why. Nothing is created.

.EXAMPLE
    .\New-MigrationUsers.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -UseInterim -HideFromAddressLists -DefaultUsageLocation US -Prefix Contoso

    Stages wave one on newco.onmicrosoft.com, hidden from the destination GAL.

.EXAMPLE
    .\New-MigrationUsers.ps1 -PlanPath .\IdentityPlan.csv -AssignLicenses -SetManagers -DefaultUsageLocation GB -TenantId newco.onmicrosoft.com

    Creates every eligible row on its verified target UPN, assigns the planned licences
    and rebuilds the manager hierarchy in one pass.

.NOTES
    Author:  AutomationHub
    Written with assistance from Claude (Anthropic).

    Graph scopes (delegated):
      User.ReadWrite.All        create users, set manager, assign licences
      Directory.ReadWrite.All   read the tenant's verified domains, write directory objects
      Organization.Read.All     read subscribedSkus - only needed with -AssignLicenses

    Roles: User Administrator is enough for ordinary accounts. Creating or re-parenting an
    account that holds a privileged role needs Privileged Authentication Administrator.

    GDAP: supported - pass -TenantId with the customer tenant. There is no
    -DelegatedOrganization here; that parameter belongs to the Exchange Online scripts.

    Exit codes: 0 success, 1 fatal error, 2 completed with row failures.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [AllowNull()]
    [AllowEmptyCollection()]
    [string[]]$Wave,

    [switch]$UseInterim,

    [switch]$HideFromAddressLists,

    [switch]$AssignLicenses,

    [switch]$SetManagers,

    [bool]$ForceChangePassword = $true,

    [ValidateRange(12, 128)]
    [int]$PasswordLength = 16,

    [AllowEmptyString()]
    [ValidatePattern('^([A-Za-z]{2})?$')]
    [string]$DefaultUsageLocation,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$TenantId,

    [switch]$IncludeCollisions,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$OutputPath,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$Prefix,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$LogPath,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Configuration -----------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Declared here so a reviewer can see the blast radius of a run without reading the body.
# Organization.Read.All is only requested when it is needed: asking for consent to a scope
# the run will not use is how tenants end up over-permissioned.
$requiredGraphScopes = @('User.ReadWrite.All', 'Directory.ReadWrite.All')
if ($AssignLicenses) { $requiredGraphScopes += 'Organization.Read.All' }

$script:results = [System.Collections.Generic.List[object]]::new()

#endregion Configuration --------------------------------------------------------------

#region Functions ---------------------------------------------------------------------

function Resolve-RowIdentity {
    <#
    .SYNOPSIS
        Chooses the UPN and mail nickname a plan row should be created with.

    .DESCRIPTION
        A staged migration creates accounts on the destination's onmicrosoft.com domain and
        re-homes them on the vanity domain at cutover, because the vanity domain cannot be
        verified in two tenants at once. Getting that choice wrong produces a run where
        every row fails with 'Property userPrincipalName is invalid', so the decision is
        made here, once, and reported per row.

    .EXAMPLE
        Resolve-RowIdentity -Row $row -VerifiedDomain $verified

        Returns the target UPN when its domain is verified, otherwise the interim UPN and
        a warning explaining the fallback.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Row,
        [AllowNull()][AllowEmptyCollection()][string[]]$VerifiedDomain,
        [switch]$UseInterim
    )

    $target = Get-MigrationCsvValue -Row $Row -Name 'TargetUserPrincipalName' -Default ''
    $interim = Get-MigrationCsvValue -Row $Row -Name 'InterimUserPrincipalName' -Default ''
    $nickname = Get-MigrationCsvValue -Row $Row -Name 'TargetMailNickname' -Default ''

    $chosen = ''
    $addressSource = ''
    $warning = ''

    if ($UseInterim) {
        if ($interim) {
            $chosen = $interim
            $addressSource = 'Interim'
        }
        elseif ($target) {
            $chosen = $target
            $addressSource = 'Target'
            $warning = 'The plan row has no InterimUserPrincipalName; used the target UPN instead.'
        }
        else {
            $warning = 'The plan row has neither an interim nor a target UPN.'
        }
    }
    else {
        $targetDomain = ''
        if ($target -like '*@*') { $targetDomain = ($target -split '@')[-1].ToLowerInvariant() }

        $targetVerified = $true
        if ($target -and $VerifiedDomain -and @($VerifiedDomain).Count -gt 0) {
            $known = @($VerifiedDomain | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
            $targetVerified = $known -contains $targetDomain
        }

        if ($target -and $targetVerified) {
            $chosen = $target
            $addressSource = 'Target'
        }
        elseif ($interim) {
            $chosen = $interim
            $addressSource = 'Interim'
            $warning = if ($target) {
                "Target domain '$targetDomain' is not verified in the destination tenant; created on the interim UPN."
            }
            else {
                'The plan row has no target UPN; created on the interim UPN.'
            }
        }
        elseif ($target) {
            $chosen = $target
            $addressSource = 'Target'
            $warning = "Target domain '$targetDomain' is not verified in the destination tenant and the row has no interim UPN."
        }
        else {
            $warning = 'The plan row has neither an interim nor a target UPN.'
        }
    }

    # The mail nickname is the mailbox alias. Falling back to the local part keeps a plan
    # that was hand-built in a spreadsheet usable without inventing a second convention.
    if (-not $nickname -and $chosen -like '*@*') { $nickname = ($chosen -split '@')[0] }

    return [pscustomobject]@{
        UserPrincipalName = $chosen
        AddressSource     = $addressSource
        MailNickname      = $nickname
        Warning           = $warning
    }
}

function ConvertTo-UserRequestBody {
    <#
    .SYNOPSIS
        Turns a plan row into the body of a POST /users request.

    .DESCRIPTION
        Optional attributes are omitted rather than sent empty: Graph accepts an empty
        string for givenName, and an account created that way looks populated in the admin
        centre while the attribute is in fact blank. showInAddressList is only emitted when
        the caller asked to hide the account, so an unhidden account is left at the
        directory default rather than pinned to a value Exchange will later disagree with.

    .EXAMPLE
        ConvertTo-UserRequestBody -Row $row -UserPrincipalName 'john.smith@newco.com' -MailNickname 'john.smith' -UsageLocation 'US' -Password $generated

        Returns the ordered hashtable posted to /v1.0/users.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Graph POST /users requires passwordProfile.password as a plain string in the JSON body; a SecureString would have to be unwrapped here anyway. The value is generated in-process, never logged, and reaches disk only in the results CSV the operator is told to protect.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'These are not sign-in credentials. UserPrincipalName is the address the account is being created on and Password is the generated initial password for that new account; a PSCredential cannot express the pair being sent to Graph in one JSON body.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserPrincipalName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MailNickname,
        [AllowEmptyString()][string]$UsageLocation = '',
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [bool]$ForceChangePassword = $true,
        [switch]$HideFromAddressLists
    )

    $firstName = Get-MigrationCsvValue -Row $Row -Name 'FirstName' -Default ''
    $lastName = Get-MigrationCsvValue -Row $Row -Name 'LastName' -Default ''

    $displayName = Get-MigrationCsvValue -Row $Row -Name 'DisplayName' -Default ''
    if (-not $displayName) {
        $displayName = (@($firstName, $lastName) | Where-Object { $_ }) -join ' '
    }
    if (-not $displayName) {
        throw 'The plan row has no DisplayName and no first or last name to build one from.'
    }

    $body = [ordered]@{
        accountEnabled    = $true
        displayName       = $displayName
        userPrincipalName = $UserPrincipalName
        mailNickname      = $MailNickname
        passwordProfile   = [ordered]@{
            password                      = $Password
            forceChangePasswordNextSignIn = $ForceChangePassword
        }
    }

    if ($firstName) { $body['givenName'] = $firstName }
    if ($lastName) { $body['surname'] = $lastName }

    $optional = [ordered]@{
        jobTitle       = 'JobTitle'
        department     = 'Department'
        officeLocation = 'Office'
        mobilePhone    = 'MobilePhone'
    }
    foreach ($graphName in $optional.Keys) {
        $value = Get-MigrationCsvValue -Row $Row -Name $optional[$graphName] -Default ''
        if ($value) { $body[$graphName] = $value }
    }

    if ($UsageLocation) { $body['usageLocation'] = $UsageLocation.ToUpperInvariant() }
    if ($HideFromAddressLists) { $body['showInAddressList'] = $false }

    return $body
}

function ConvertTo-FailureDetail {
    <#
    .SYNOPSIS
        Turns a Graph error into a sentence a technician can act on.

    .DESCRIPTION
        The four failures that account for almost every red row in a provisioning run
        arrive as the same shape of Graph error, and the raw message names none of the
        fixes. Anything unrecognised is passed through unchanged so no detail is lost.

    .EXAMPLE
        ConvertTo-FailureDetail -Message $_.Exception.Message -UserPrincipalName $upn

        Returns an actionable message, or the original when no rule matches.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [AllowEmptyString()][string]$UserPrincipalName = ''
    )

    $text = [string]$Message

    if ($text -match 'already exist|ObjectConflict|Request_MultipleObjectsWithSameKeyValue') {
        return ("Another object already holds '$UserPrincipalName'. A soft-deleted user can hold it too - " +
            "check GET /directory/deletedItems/microsoft.graph.user and either restore or permanently delete it. " +
            "Original error: $text")
    }
    if ($text -match 'Authorization_RequestDenied|Insufficient privileges') {
        return ("Access denied. The signed-in account needs User Administrator (or Privileged Authentication " +
            "Administrator for privileged accounts) and consent to User.ReadWrite.All. Original error: $text")
    }
    if ($text -match 'Property userPrincipalName is invalid|domain.*(not|isn''t) verified|unverified domain') {
        return ("'$UserPrincipalName' uses a domain that is not verified in the destination tenant. Run with " +
            "-UseInterim until the domain is moved across. Original error: $text")
    }
    if ($text -match 'password') {
        return "The generated password was rejected by the tenant password policy. Original error: $text"
    }

    return $text
}

function Invoke-LicenseAssignment {
    <#
    .SYNOPSIS
        Assigns planned licences to one freshly created account.

    .DESCRIPTION
        A local copy of the assignLicense call rather than a dependency on
        Set-MigrationLicenses: creating a user and licensing it are separate phases with
        separate failure modes. Part numbers that are not in the tenant's SKU catalogue are
        returned rather than thrown, so one mistyped licence in the plan does not fail the
        account that was successfully created.

    .EXAMPLE
        Invoke-LicenseAssignment -UserId $id -SkuPartNumber @('SPE_E3') -Catalog $catalog -Identity 'john.smith@newco.com'

        Assigns the E3 SKU and returns which part numbers were assigned and which were unknown.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'UserId is consumed inside the Invoke-MigrationAction scriptblock, which the analyzer does not follow. The scriptblock exists so the call can be suppressed under -DryRun.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SkuPartNumber,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity
    )

    $addLicenses = [System.Collections.Generic.List[object]]::new()
    $assigned = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()

    foreach ($partNumber in $SkuPartNumber) {
        $match = @($Catalog | Where-Object { $_.SkuPartNumber -eq $partNumber })
        if ($match.Count -eq 0) {
            $unknown.Add($partNumber)
            continue
        }
        $addLicenses.Add(@{ skuId = $match[0].SkuId; disabledPlans = @() })
        $assigned.Add($partNumber)
    }

    if ($addLicenses.Count -gt 0) {
        $body = @{ addLicenses = $addLicenses.ToArray(); removeLicenses = @() }
        $null = Invoke-MigrationAction -Description "Assign licence(s) $($assigned -join ', ') to $Identity" -Action {
            Invoke-MigrationGraphRequest -Method POST -Uri "/v1.0/users/$UserId/assignLicense" -Body $body
        }
    }

    return [pscustomobject]@{
        Assigned = $assigned.ToArray()
        Unknown  = $unknown.ToArray()
    }
}

function Add-ResultRow {
    <#
    .SYNOPSIS
        Appends one row to the run's results collection in the toolkit's standard shape.

    .DESCRIPTION
        Every results file in the toolkit leads with Identity, Action, Status and Detail so
        a technician reading a migration folder does not have to learn a new layout per
        script. Building the rows in one place is what keeps that promise true across the
        places this script reports an outcome from.

    .EXAMPLE
        Add-ResultRow -Identity $identity -Action 'CreateUser' -Status 'Succeeded' -Detail 'Account created.'

        Records a successful creation.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'GeneratedPassword carries an already-generated value into the results CSV column of the same name; converting it to a SecureString here would only be unwrapped again by Export-Csv.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'The function builds a CSV row, not a sign-in. TargetUserPrincipalName and GeneratedPassword are two columns of the results file and are never used to authenticate.')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Planned', 'Succeeded', 'Skipped', 'Failed')][string]$Status,
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$ObjectType = '',
        [AllowEmptyString()][string]$PlanStatus = '',
        [AllowEmptyString()][string]$TargetUserPrincipalName = '',
        [AllowEmptyString()][string]$TargetObjectId = '',
        [AllowEmptyString()][string]$UsageLocation = '',
        [AllowEmptyString()][string]$LicensesAssigned = '',
        [AllowEmptyString()][string]$GeneratedPassword = ''
    )

    $script:results.Add([pscustomobject][ordered]@{
            Identity                = $Identity
            Action                  = $Action
            Status                  = $Status
            Detail                  = $Detail
            ObjectType              = $ObjectType
            PlanStatus              = $PlanStatus
            TargetUserPrincipalName = $TargetUserPrincipalName
            TargetObjectId          = $TargetObjectId
            UsageLocation           = $UsageLocation
            LicensesAssigned        = $LicensesAssigned
            GeneratedPassword       = $GeneratedPassword
        })
}

#endregion Functions ------------------------------------------------------------------

#region Main --------------------------------------------------------------------------

$null = Initialize-MigrationRun -ScriptName 'New-MigrationUsers' -OutputPath $OutputPath -Prefix $Prefix `
    -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    # The whole plan is read, not just the wave: Save-MigrationPlan rewrites the file in
    # full, so writing back a filtered set would delete every row this run did not touch.
    $planRows = @(Import-MigrationPlan -Path $PlanPath)
}
catch {
    Write-MigrationLog -Message $_.Exception.Message -Level ERROR
    exit (Complete-MigrationRun -ExitCode 1)
}

$waveRows = @(Select-MigrationPlanRows -Rows $planRows -Wave $Wave -IncludeExcluded)
if ($waveRows.Count -eq 0) {
    Write-MigrationLog -Message "No plan rows match wave '$($Wave -join ', ')'. Check the wave values in $PlanPath." -Level ERROR
    exit (Complete-MigrationRun -ExitCode 1)
}
Write-MigrationLog -Message "Processing $($waveRows.Count) plan row(s)." -Level INFO

try {
    $null = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId
}
catch {
    Write-MigrationLog -Message $_.Exception.Message -Level ERROR
    exit (Complete-MigrationRun -ExitCode 1)
}

# Read the verified domains once. Without them every row on an unverified vanity domain
# fails individually with a message that does not name the fix.
$verifiedDomains = @()
if (-not $UseInterim) {
    try {
        $domains = @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/domains?$select=id,isVerified' -All)
        $verifiedDomains = @($domains |
                Where-Object { [string](Get-MigrationProperty -InputObject $_ -Name 'isVerified' -Default '') -eq 'True' } |
                ForEach-Object { ([string](Get-MigrationProperty -InputObject $_ -Name 'id' -Default '')).ToLowerInvariant() } |
                Where-Object { $_ })
        Write-MigrationLog -Message "Destination tenant has $($verifiedDomains.Count) verified domain(s)." -Level INFO
    }
    catch {
        Write-MigrationLog -Message ("Could not read the destination tenant's verified domains; every target domain " +
            "will be accepted as-is. $($_.Exception.Message)") -Level WARNING
    }
}

$skuCatalog = @()
if ($AssignLicenses) {
    try {
        $skuCatalog = @(Get-MigrationSkuCatalog)
        Write-MigrationLog -Message "Loaded $($skuCatalog.Count) subscribed SKU(s)." -Level INFO
    }
    catch {
        Write-MigrationLog -Message "Could not read the tenant SKU catalogue; licences will be reported as unassignable. $($_.Exception.Message)" -Level WARNING
    }
}

$planChanged = $false
$planSaveFailed = $false
$rowIndex = 0

foreach ($row in $waveRows) {
    $rowIndex++

    $objectType = Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default ''
    $planStatus = Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default ''

    $identity = Get-MigrationCsvValue -Row $row -Name 'SourceUserPrincipalName' -Default ''
    if (-not $identity) { $identity = Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default '' }
    if (-not $identity) { $identity = Get-MigrationCsvValue -Row $row -Name 'DisplayName' -Default "(plan row $rowIndex)" }

    Write-Progress -Activity 'Creating destination accounts' -Status "$rowIndex of $($waveRows.Count): $identity" `
        -PercentComplete (($rowIndex / [math]::Max($waveRows.Count, 1)) * 100)

    $common = @{ Identity = $identity; ObjectType = $objectType; PlanStatus = $planStatus }

    if ($objectType -eq 'Guest') {
        Add-ResultRow @common -Action 'CreateUser' -Status 'Skipped' -Detail ('Guest accounts are not created here. ' +
            'Re-invite the guest in the destination tenant so the invitation redemption stays with the guest, ' +
            'then record the new object ID in the plan.')
        continue
    }

    if ($objectType -ne 'User') {
        Add-ResultRow @common -Action 'CreateUser' -Status 'Skipped' `
            -Detail "ObjectType '$objectType' is not created by this script; New-MigrationRecipients handles mail recipients."
        continue
    }

    # -AllowSynced: a directory-synced source object is no reason not to create a fresh
    # cloud account in the destination tenant. The gate's sync check belongs to the scripts
    # that write back to an existing object.
    $gate = Test-MigrationPlanRowActionable -Row $row -IncludeCollisions:$IncludeCollisions -AllowSynced
    if (-not $gate.Actionable) {
        $detail = $gate.Reason
        if ($planStatus -eq 'Collision') { $detail += ' Re-run with -IncludeCollisions to process it.' }
        Add-ResultRow @common -Action 'CreateUser' -Status $gate.Status -Detail $detail
        continue
    }

    $alreadyProvisioned = Get-MigrationCsvValue -Row $row -Name 'TargetObjectId' -Default ''
    if ($alreadyProvisioned) {
        Add-ResultRow @common -Action 'CreateUser' -Status 'Skipped' -Detail 'Already provisioned; the plan row carries a TargetObjectId.' `
            -TargetObjectId $alreadyProvisioned
        continue
    }

    $generatedPassword = ''
    $usageLocation = ''
    $upn = ''

    try {
        $chosen = Resolve-RowIdentity -Row $row -VerifiedDomain $verifiedDomains -UseInterim:$UseInterim
        $upn = $chosen.UserPrincipalName
        if (-not $upn) { throw $chosen.Warning }
        if (-not $chosen.MailNickname) { throw 'The plan row has no TargetMailNickname and the chosen UPN has no local part to fall back on.' }

        $upnCheck = Test-MigrationAddress -Address $upn -Kind 'Upn'
        if (-not $upnCheck.IsValid) { throw "'$upn' is not a usable UPN: $($upnCheck.Reason)" }

        $usageLocation = Get-MigrationCsvValue -Row $row -Name 'UsageLocation' -Default ''
        if (-not $usageLocation) { $usageLocation = $DefaultUsageLocation }

        # Existing-object check before the create, so a re-run after a partial failure
        # adopts what is already there instead of failing every row with a conflict.
        $filterValue = ConvertTo-MigrationODataString -Value $upn
        $existing = @(Invoke-MigrationGraphRequest -Method GET `
                -Uri "/v1.0/users?`$filter=userPrincipalName eq '$filterValue'&`$select=id,userPrincipalName")

        if ($existing.Count -gt 0) {
            $existingId = [string](Get-MigrationProperty -InputObject $existing[0] -Name 'id' -Default '')
            $row.TargetObjectId = $existingId
            $row.ProvisionStatus = 'Exists'
            $row.ProvisionDetail = "Account already present in the destination tenant as $upn."
            $planChanged = $true
            Add-ResultRow @common -Action 'CreateUser' -Status 'Skipped' -Detail 'Account already exists in the destination tenant; recorded its object ID.' `
                -TargetUserPrincipalName $upn -TargetObjectId $existingId -UsageLocation $usageLocation
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($upn, 'Create Microsoft 365 user')) {
            Add-ResultRow @common -Action 'CreateUser' -Status 'Skipped' -Detail 'Declined at the confirmation prompt.' `
                -TargetUserPrincipalName $upn -UsageLocation $usageLocation
            continue
        }

        # A password is only minted for a run that will actually create something, so a
        # rehearsal never leaves a live credential in a DryRun results file.
        $password = if ($DryRun) { '' } else { New-MigrationRandomPassword -Length $PasswordLength }

        $body = ConvertTo-UserRequestBody -Row $row -UserPrincipalName $upn -MailNickname $chosen.MailNickname `
            -UsageLocation $usageLocation -Password $password -ForceChangePassword $ForceChangePassword `
            -HideFromAddressLists:$HideFromAddressLists

        $created = Invoke-MigrationAction -Description "Create user $upn" -PassThru -Action {
            Invoke-MigrationGraphRequest -Method POST -Uri '/v1.0/users' -Body $body
        }

        $detail = [System.Collections.Generic.List[string]]::new()
        if ($chosen.Warning) { $detail.Add($chosen.Warning) }
        if ($HideFromAddressLists) {
            $detail.Add('showInAddressList set to false; re-apply the GAL hide with Set-MigrationIdentity once the mailbox exists.')
        }

        if ($DryRun) {
            $detail.Insert(0, "Would create $upn on the $($chosen.AddressSource.ToLowerInvariant()) address.")
            if ($AssignLicenses) {
                $planned = @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $row -Name 'TargetLicenses' -Default ''))
                if ($planned.Count -gt 0) { $detail.Add("Would assign: $($planned -join ', ').") }
            }
            Add-ResultRow @common -Action 'CreateUser' -Status 'Planned' -Detail ($detail -join ' ') `
                -TargetUserPrincipalName $upn -UsageLocation $usageLocation
            continue
        }

        $generatedPassword = $password
        $newObjectId = [string](Get-MigrationProperty -InputObject $created -Name 'id' -Default '')
        if (-not $newObjectId) {
            throw ("The account may have been created, but Graph returned no object ID for $upn, so " +
                'the plan cannot record it. Check the destination tenant for the account and fill in ' +
                'TargetObjectId by hand before running the next phase.')
        }
        $detail.Insert(0, "Account created on the $($chosen.AddressSource.ToLowerInvariant()) address.")

        $row.TargetObjectId = $newObjectId
        $row.ProvisionStatus = 'Created'
        $planChanged = $true

        $licensesAssigned = ''
        if ($AssignLicenses) {
            $planned = @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $row -Name 'TargetLicenses' -Default ''))
            if ($planned.Count -eq 0) {
                $detail.Add('No TargetLicenses on the plan row; nothing assigned.')
            }
            elseif (-not $usageLocation) {
                $detail.Add('Licences skipped: assignLicense requires a usage location. Set UsageLocation on the row or pass -DefaultUsageLocation.')
            }
            elseif (-not $newObjectId) {
                $detail.Add('Licences skipped: the create call returned no object ID.')
            }
            else {
                try {
                    $licenceResult = Invoke-LicenseAssignment -UserId $newObjectId -SkuPartNumber $planned `
                        -Catalog $skuCatalog -Identity $upn
                    $licensesAssigned = Join-MigrationList -Values $licenceResult.Assigned
                    if ($licenceResult.Unknown.Count -gt 0) {
                        $detail.Add("Not in the tenant SKU catalogue: $($licenceResult.Unknown -join ', ').")
                    }
                }
                catch {
                    $detail.Add("Licence assignment failed: $($_.Exception.Message)")
                }
            }
        }

        $row.ProvisionDetail = ($detail -join ' ')
        Add-ResultRow @common -Action 'CreateUser' -Status 'Succeeded' -Detail ($detail -join ' ') `
            -TargetUserPrincipalName $upn -TargetObjectId $newObjectId -UsageLocation $usageLocation `
            -LicensesAssigned $licensesAssigned -GeneratedPassword $generatedPassword
    }
    catch {
        $mapped = ConvertTo-FailureDetail -Message $_.Exception.Message -UserPrincipalName $upn
        $row.ProvisionStatus = 'Failed'
        $row.ProvisionDetail = $mapped
        $planChanged = $true
        Write-MigrationLog -Message "$identity - $mapped" -Level ERROR
        Add-ResultRow @common -Action 'CreateUser' -Status 'Failed' -Detail $mapped `
            -TargetUserPrincipalName $upn -UsageLocation $usageLocation
    }
}

Write-Progress -Activity 'Creating destination accounts' -Completed

if ($SetManagers) {
    Write-MigrationLog -Message 'Second pass: setting managers.' -Level INFO

    # Built from the whole plan, not the wave: a manager is frequently in an earlier wave
    # that this run is not touching, and their object ID is already recorded there. This is
    # an address -> object ID index, which is not what Get-MigrationPlanAddressMap returns.
    $objectIdByAddress = @{}
    foreach ($planRow in $planRows) {
        $planRowObjectId = Get-MigrationCsvValue -Row $planRow -Name 'TargetObjectId' -Default ''
        if (-not $planRowObjectId) { continue }
        foreach ($column in @('SourceUserPrincipalName', 'SourcePrimarySmtp', 'TargetUserPrincipalName', 'InterimUserPrincipalName')) {
            $address = Get-MigrationCsvValue -Row $planRow -Name $column -Default ''
            if ($address) { $objectIdByAddress[$address.ToLowerInvariant()] = $planRowObjectId }
        }
    }

    foreach ($row in $waveRows) {
        $objectType = Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default ''
        if ($objectType -ne 'User') { continue }

        $managerUpn = Get-MigrationCsvValue -Row $row -Name 'ManagerUpn' -Default ''
        if (-not $managerUpn) { continue }

        $identity = Get-MigrationCsvValue -Row $row -Name 'SourceUserPrincipalName' -Default ''
        if (-not $identity) { $identity = Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default '(unnamed row)' }

        $common = @{
            Identity   = $identity
            ObjectType = $objectType
            PlanStatus = (Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default '')
        }

        $userObjectId = Get-MigrationCsvValue -Row $row -Name 'TargetObjectId' -Default ''
        if (-not $userObjectId) {
            $status = if ($DryRun) { 'Planned' } else { 'Skipped' }
            Add-ResultRow @common -Action 'SetManager' -Status $status `
                -Detail "The account has no target object ID yet, so manager '$managerUpn' cannot be set on this pass."
            continue
        }

        $managerObjectId = ''
        if ($objectIdByAddress.ContainsKey($managerUpn.ToLowerInvariant())) {
            $managerObjectId = $objectIdByAddress[$managerUpn.ToLowerInvariant()]
        }

        if (-not $managerObjectId) {
            Add-ResultRow @common -Action 'SetManager' -Status 'Skipped' -TargetObjectId $userObjectId `
                -Detail ("Manager '$managerUpn' has no provisioned account in the plan. Provision the manager first, " +
                    'or set the relationship by hand if the manager is outside the migration.')
            continue
        }

        try {
            if (-not $PSCmdlet.ShouldProcess($identity, "Set manager to $managerUpn")) {
                Add-ResultRow @common -Action 'SetManager' -Status 'Skipped' -Detail 'Declined at the confirmation prompt.' `
                    -TargetObjectId $userObjectId
                continue
            }

            $managerReference = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$managerObjectId" }
            $managerUri = "/v1.0/users/$userObjectId/manager/`$ref"

            $null = Invoke-MigrationAction -Description "Set manager of $identity to $managerUpn" -Action {
                Invoke-MigrationGraphRequest -Method PUT -Uri $managerUri -Body $managerReference
            }

            $status = if ($DryRun) { 'Planned' } else { 'Succeeded' }
            $verb = if ($DryRun) { 'Would set' } else { 'Set' }
            Add-ResultRow @common -Action 'SetManager' -Status $status -Detail "$verb manager to $managerUpn." `
                -TargetObjectId $userObjectId
        }
        catch {
            $mapped = ConvertTo-FailureDetail -Message $_.Exception.Message -UserPrincipalName $identity
            Write-MigrationLog -Message "$identity - manager not set: $mapped" -Level ERROR
            Add-ResultRow @common -Action 'SetManager' -Status 'Failed' -Detail $mapped -TargetObjectId $userObjectId
        }
    }
}

#endregion Main -----------------------------------------------------------------------

#region Cleanup -----------------------------------------------------------------------

if ($planChanged) {
    try {
        $null = Invoke-MigrationAction -Description "Write provisioning results back to $PlanPath" -Action {
            Save-MigrationPlan -Path $PlanPath -Rows $planRows
        }
    }
    catch {
        # Losing the write-back loses the TargetObjectIds this run just earned, so it is a failed
        # run even when every row succeeded.
        Write-MigrationLog -Message ("Could not write the plan back to $PlanPath, so the object IDs " +
            "recorded by this run are only in the results file: $($_.Exception.Message)") -Level ERROR
        $planSaveFailed = $true
    }
}

$null = Export-MigrationResult -Rows $script:results.ToArray() -Name 'New-Users'

if (@($script:results | Where-Object { $_.Status -eq 'Succeeded' -and $_.GeneratedPassword }).Count -gt 0) {
    Write-MigrationLog -Message 'Initial passwords were written to the results file. Store it as you would any password list.' -Level WARNING
}

$exitCode = if ($planSaveFailed -or @($script:results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { 2 } else { 0 }
exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion Cleanup --------------------------------------------------------------------
