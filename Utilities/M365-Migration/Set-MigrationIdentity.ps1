#Requires -Version 7.4

<#
.SYNOPSIS
    Applies the identity plan's target UPN, primary SMTP, aliases, X500, mail nickname and GAL
    visibility to the objects that already exist in the destination (or same) tenant.

.DESCRIPTION
    Phase 4 cutover writer. For every actionable row of IdentityPlan.csv the script locates the
    object in the tenant it is connected to, then applies only the operations named by -Apply:

      Upn           PATCH /users/{id} { userPrincipalName } via Microsoft Graph.
      PrimarySmtp   Set-Mailbox -EmailAddresses @{ Add = 'SMTP:<target>' } - the uppercase prefix is
                    what makes the address primary, and Exchange demotes the previous primary to a
                    lowercase 'smtp:' alias by itself.
      Aliases       Adds every TargetAliases entry that is not already on the object.
      X500          Adds X500:<LegacyExchangeDN> (or each SourceX500 entry) so mail sent to the old
                    address and cached Outlook entries still resolve after the move.
      MailNickname  Set-Mailbox -Alias.
      GalVisibility Set-Mailbox -HiddenFromAddressListsEnabled (True, or False with -Unhide).

    Address handling is deliberately additive. The script computes an add/remove set from the
    object's current EmailAddresses and never removes the tenant routing (MOERA) address, a SIP
    address, or any existing X500 address - removing any of those breaks Teams sign-in, mail
    routing, or reply-ability from cached address entries. The only address it will ever remove is
    the previous primary, and only when you ask for it with -RemoveOldPrimaryAlias.

    Because it can match on the source UPN (-MatchOn Source), the same script performs the in-place
    UPN/address redesign inside a single tenant: build a plan whose Source* columns describe today
    and whose Target* columns describe the new scheme, then run with -MatchOn Source.

    Directory-synced objects are a hard stop. Exchange Online and Entra ID are both read-only for
    UPN and proxyAddresses on an object whose onPremisesSyncEnabled is true; the change has to be
    made on-premises and allowed to sync. Those rows are reported Failed rather than silently
    skipped, because a migration run that quietly leaves half the users behind is worse than one
    that stops and says so.

    Every mutation is wrapped in Invoke-MigrationAction and gated by ShouldProcess, so -DryRun and
    -WhatIf both produce a full results file with Status 'Planned' and change nothing.

.PARAMETER PlanPath
    Path to IdentityPlan.csv.

.PARAMETER Wave
    Only process rows whose Wave column matches one of these values. Omit to process every wave.

.PARAMETER Apply
    Which operations to perform. Any of Upn, PrimarySmtp, Aliases, X500, GalVisibility,
    MailNickname. Defaults to Upn, PrimarySmtp, Aliases, X500.

.PARAMETER MatchOn
    How to find the object in the connected tenant: TargetObjectId, Interim (InterimUserPrincipalName)
    or Source (SourceUserPrincipalName). Omit to try TargetObjectId, then Interim, then Source, per
    row. When given explicitly there is no fallback - a row with an empty column is reported Failed,
    so a mis-typed run cannot quietly write to the wrong object.

.PARAMETER RemoveOldPrimaryAlias
    After promoting the new primary, remove the demoted old primary instead of keeping it as an
    alias. Ignored for MOERA (*.onmicrosoft.com) addresses, which are never removed.

.PARAMETER DisableEmailAddressPolicy
    Set EmailAddressPolicyEnabled to False before touching addresses. Without this, an org that
    still has an email address policy applied can reassert the old primary on the next policy
    application or hybrid configuration run.

.PARAMETER Unhide
    Make GalVisibility set HiddenFromAddressListsEnabled to False rather than True.

.PARAMETER IncludeCollisions
    Also act on rows whose PlanStatus is Collision. By default only Planned, ManualOverride and
    UpnSmtpDiverge rows are actioned.

.PARAMETER TenantId
    Tenant to sign in to for Microsoft Graph. Optional; a partner under an active GDAP relationship
    can pass the customer tenant id here.

.PARAMETER DelegatedOrganization
    Customer tenant for Exchange Online, e.g. contoso.onmicrosoft.com. Required when running as a
    partner against a customer tenant, otherwise every mailbox lookup fails with "no mailbox found"
    because the session landed in your own tenant.

.PARAMETER OutputPath
    Root directory for the log and results file. Defaults to the toolkit's standard root.

.PARAMETER Prefix
    Client or run name. Files land in <root>\<Prefix>\ and their names start with <Prefix>_.

.PARAMETER LogPath
    Override the log file path.

.PARAMETER Verbosity
    Console noise: Low (errors and successes), Medium (adds warnings), High (everything). The log
    file always receives everything.

.PARAMETER DryRun
    Evaluate every row and write a -DryRun_ results file with Status 'Planned' without changing
    anything. Read-only calls still run, so the output reflects the tenant's real state.

.EXAMPLE
    .\Set-MigrationIdentity.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -DryRun -Prefix Contoso

    Rehearses wave 1 against the destination tenant and writes Contoso_Set-Identity-DryRun_*.csv
    listing every operation that would run, without touching a single object.

.EXAMPLE
    .\Set-MigrationIdentity.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -Apply Upn,PrimarySmtp,Aliases,X500 `
        -DisableEmailAddressPolicy -DelegatedOrganization contoso.onmicrosoft.com -Prefix Contoso

    Cutover for wave 1 in a customer tenant managed through GDAP: switches each user from their
    interim newco.onmicrosoft.com identity to the vanity domain and stamps the source X500 so old
    replies keep working.

.EXAMPLE
    .\Set-MigrationIdentity.ps1 -PlanPath .\UpnRedesign.csv -MatchOn Source -Apply Upn,PrimarySmtp `
        -RemoveOldPrimaryAlias -WhatIf

    In-place redesign inside one tenant - rows are matched on their current (source) UPN and the old
    primary is dropped rather than kept as an alias. -WhatIf reports the plan without writing.

.EXAMPLE
    .\Set-MigrationIdentity.ps1 -PlanPath .\IdentityPlan.csv -Apply GalVisibility -Unhide -Wave 2

    Reveals wave 2 in the global address list once their mailboxes are cut over.

.NOTES
    Author       : AutomationHub
    Requires     : PowerShell 7.4, Microsoft.Graph.Authentication, ExchangeOnlineManagement
    Graph scopes : User.ReadWrite.All, Directory.ReadWrite.All
    EXO roles    : Exchange Administrator (or a role group holding the Mail Recipients and
                   Address Lists roles) - needed for Set-Mailbox on EmailAddresses, Alias and
                   HiddenFromAddressListsEnabled.
    Entra roles  : User Administrator is enough to rename an ordinary user. Renaming an
                   administrative or otherwise privileged account is a sensitive action and needs
                   Privileged Authentication Administrator (or Global Administrator); Graph answers
                   403 otherwise and the script surfaces that hint on the row.
    GDAP         : Supported. Pass -DelegatedOrganization <customer>.onmicrosoft.com for Exchange
                   Online and -TenantId <customer tenant id> for Graph. Add -DisableWAM to the
                   Connect-ExchangeOnline call if GDAP claims are dropped on your workstation.
    Exit codes   : 0 success, 1 fatal, 2 completed with row failures.
    AI tools     : Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [Parameter(Mandatory = $false)]
    [string[]]$Wave,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Upn', 'PrimarySmtp', 'Aliases', 'X500', 'GalVisibility', 'MailNickname')]
    [string[]]$Apply = @('Upn', 'PrimarySmtp', 'Aliases', 'X500'),

    [Parameter(Mandatory = $false)]
    [ValidateSet('TargetObjectId', 'Interim', 'Source')]
    [string]$MatchOn,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveOldPrimaryAlias,

    [Parameter(Mandatory = $false)]
    [switch]$DisableEmailAddressPolicy,

    [Parameter(Mandatory = $false)]
    [switch]$Unhide,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeCollisions,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [Alias('Tenant')]
    [string]$DelegatedOrganization,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$Prefix,

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium',

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Configuration ---------------------------------------------------------------------------

# Declared here rather than inline so a reviewer can see the blast radius of the sign-in prompt
# without reading the whole script.
$requiredGraphScopes = @('User.ReadWrite.All', 'Directory.ReadWrite.All')

# Canonical execution order. Whatever order -Apply arrives in, the UPN moves first (it is the
# cheapest to reverse), addresses next, cosmetics last.
$actionOrder = @('Upn', 'PrimarySmtp', 'Aliases', 'X500', 'MailNickname', 'GalVisibility')

# Operations that need an Exchange Online session.
$exchangeActions = @('PrimarySmtp', 'Aliases', 'X500', 'MailNickname', 'GalVisibility')

# Operations that manipulate the EmailAddresses multi-value attribute as one change set.
$addressActions = @('PrimarySmtp', 'Aliases', 'X500')

# Only mailbox-bearing object types are handled here; groups and contacts are the business of
# New-MigrationRecipients, which owns their creation and their settings.
$supportedObjectTypes = @('User', 'Shared', 'Room', 'Equipment')

$graphUserSelect = 'id,userPrincipalName,mail,mailNickname,displayName,onPremisesSyncEnabled,proxyAddresses'

$exoMailboxProperties = @(
    'EmailAddresses', 'PrimarySmtpAddress', 'Alias', 'EmailAddressPolicyEnabled',
    'HiddenFromAddressListsEnabled', 'RecipientTypeDetails', 'ExternalDirectoryObjectId'
)

$privilegedRoleHint = 'Graph refused the userPrincipalName change (403). Renaming an administrative ' +
    'or otherwise privileged account is a sensitive action: the caller needs Privileged ' +
    'Authentication Administrator or Global Administrator. User Administrator only covers ' +
    'non-privileged users.'

$upnConflictHint = 'Graph reported a conflict (409). A soft-deleted user can still be holding this ' +
    'userPrincipalName - check /directory/deletedItems/microsoft.graph.user and either purge or ' +
    'restore it before retrying.'

#endregion --------------------------------------------------------------------------------------

#region Functions -------------------------------------------------------------------------------

function Resolve-IdentityMatch {
    <#
    .SYNOPSIS
        Decides which plan column identifies this object in the tenant we are connected to.

    .DESCRIPTION
        The destination object can be addressed three ways depending on where in the migration we
        are: by the object id a previous phase wrote back, by the interim onmicrosoft identity the
        object was created with, or - for an in-place redesign inside one tenant - by the source UPN
        it still has. Without -MatchOn the columns are tried in that order. With -MatchOn there is
        deliberately no fallback, because silently matching on a different column than the operator
        asked for is how the wrong object gets renamed.

    .EXAMPLE
        Resolve-IdentityMatch -Row $row -Strategy 'Source'

        Returns the row's SourceUserPrincipalName as the identity, matched by 'Source'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Row,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Strategy = ''
    )

    $columns = [ordered]@{
        TargetObjectId = 'TargetObjectId'
        Interim        = 'InterimUserPrincipalName'
        Source         = 'SourceUserPrincipalName'
    }

    $order = if ([string]::IsNullOrWhiteSpace($Strategy)) { @($columns.Keys) } else { @($Strategy) }

    foreach ($name in $order) {
        $value = Get-MigrationCsvValue -Row $Row -Name $columns[$name] -Default ''
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{
                Identity   = ([string]$value).Trim()
                MatchedBy  = $name
                IsObjectId = ($name -eq 'TargetObjectId')
                Detail     = ''
            }
        }
    }

    $detail = if ([string]::IsNullOrWhiteSpace($Strategy)) {
        'No TargetObjectId, InterimUserPrincipalName or SourceUserPrincipalName on the plan row.'
    }
    else {
        "-MatchOn $Strategy was requested but the row's $($columns[$Strategy]) column is empty."
    }

    [pscustomobject]@{ Identity = ''; MatchedBy = ''; IsObjectId = $false; Detail = $detail }
}

function Get-PlanX500 {
    <#
    .SYNOPSIS
        Builds the list of X500 addresses that should be stamped on the destination object.

    .DESCRIPTION
        A plan usually carries the source LegacyExchangeDN rather than a ready-made X500 entry, so
        both columns are consulted: explicit SourceX500 values first, then the LegacyExchangeDN
        promoted to an X500 address. ConvertTo-MigrationX500 strips any prefix already present and
        collapses duplicates case-insensitively.

    .EXAMPLE
        Get-PlanX500 -Row $row

        Returns @('/o=ExchangeLabs/ou=.../cn=Recipients/cn=...') for a row that only has a
        LegacyExchangeDN.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Row
    )

    return ConvertTo-MigrationX500 -NoPrefix -Value @(
        (Get-MigrationCsvValue -Row $Row -Name 'SourceX500' -Default ''),
        (Get-MigrationCsvValue -Row $Row -Name 'LegacyExchangeDN' -Default ''))
}

function New-IdentityResult {
    <#
    .SYNOPSIS
        Builds one result row for the (Identity, Action) pair.

    .DESCRIPTION
        Every operation the script considers produces exactly one row, whether it ran, was skipped
        or failed, so the results file is a complete record of what was asked of each object rather
        than only of what changed.

    .EXAMPLE
        New-IdentityResult -Identity 'john@newco.com' -Action Upn -Status Succeeded -Detail 'UPN updated.'

        Returns the result row written to the CSV for a completed UPN change.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory result object; it changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Planned', 'Succeeded', 'Skipped', 'Failed')][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detail,
        [Parameter(Mandatory = $false)]$Row,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$MatchedBy = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ObjectId = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$CurrentValue = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$TargetValue = ''
    )

    [pscustomobject][ordered]@{
        Identity     = $Identity
        Action       = $Action
        Status       = $Status
        Detail       = ([string]$Detail).Trim()
        ObjectType   = if ($Row) { Get-MigrationCsvValue -Row $Row -Name 'ObjectType' -Default '' } else { '' }
        Wave         = if ($Row) { Get-MigrationCsvValue -Row $Row -Name 'Wave' -Default '' } else { '' }
        MatchedBy    = $MatchedBy
        ObjectId     = $ObjectId
        CurrentValue = $CurrentValue
        TargetValue  = $TargetValue
    }
}

function Set-MailboxAddress {
    <#
    .SYNOPSIS
        Applies one bucket of the address change set with a single Set-Mailbox call.

    .DESCRIPTION
        Kept separate from the change-set calculation so the mutation has exactly one call site,
        which is what lets the DryRun guarantee be tested. Invoke-MigrationAction short-circuits in
        DryRun mode, so Set-Mailbox is never reached.

    .EXAMPLE
        Set-MailboxAddress -Identity 'john@newco.com' -Address 'SMTP:john.smith@newco.com' -Operation Add

        Promotes john.smith@newco.com to primary and lets Exchange demote the previous primary.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller gates the row with ShouldProcess and Invoke-MigrationAction honours -DryRun.')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Address,
        [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Operation
    )

    if (@($Address).Count -eq 0) { return }

    $change = if ($Operation -eq 'Add') { @{ Add = @($Address) } } else { @{ Remove = @($Address) } }
    $description = "$Operation address on ${Identity}: $(@($Address) -join ', ')"

    Invoke-MigrationAction -Description $description -Action {
        Set-Mailbox -Identity $Identity -EmailAddresses $change -ErrorAction Stop
    }
}

function Set-MailboxAttribute {
    <#
    .SYNOPSIS
        Applies a single scalar Set-Mailbox attribute (Alias, GAL visibility or address policy).

    .DESCRIPTION
        One call site per scalar attribute keeps the DryRun guarantee testable and keeps the
        per-row loop readable. Splatting is used so a $null value can never be passed by accident.

    .EXAMPLE
        Set-MailboxAttribute -Identity 'john@newco.com' -Name Alias -Value 'john.smith' -Description 'Set alias'

        Sets the mail nickname on the destination mailbox.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller gates the row with ShouldProcess and Invoke-MigrationAction honours -DryRun.')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Alias', 'HiddenFromAddressListsEnabled', 'EmailAddressPolicyEnabled')][string]$Name,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Description
    )

    $parameters = @{ Identity = $Identity; ErrorAction = 'Stop' }
    $parameters[$Name] = $Value

    Invoke-MigrationAction -Description $Description -Action {
        Set-Mailbox @parameters
    }
}

function Get-UpnFailureDetail {
    <#
    .SYNOPSIS
        Turns a failed Graph UPN change into a message an operator can act on.

    .DESCRIPTION
        The two failures that actually happen in the field - a privileged-account rename refused
        with 403, and a soft-deleted user still squatting the target UPN returning 409 - are
        indistinguishable from generic noise in the raw Graph error, so they are named explicitly.

    .EXAMPLE
        Get-UpnFailureDetail -ErrorRecord $_ -PrivilegedHint $privilegedRoleHint -ConflictHint $upnConflictHint

        Returns the Graph message with the Privileged Authentication Administrator hint appended
        when Graph answered 403.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [Parameter(Mandatory)][string]$PrivilegedHint,
        [Parameter(Mandatory)][string]$ConflictHint
    )

    $message = [string]$ErrorRecord.Exception.Message

    if ($message -match '(?i)\b403\b|forbidden|authorization_requestdenied|insufficient privileges') {
        return "$message $PrivilegedHint"
    }
    if ($message -match '(?i)\b409\b|conflict|already exist') {
        return "$message $ConflictHint"
    }

    return $message
}

#endregion --------------------------------------------------------------------------------------

#region Main ------------------------------------------------------------------------------------

$exitCode = 0
$results = [System.Collections.Generic.List[object]]::new()

try {
    $run = Initialize-MigrationRun -ScriptName 'Set-MigrationIdentity' -OutputPath $OutputPath -Prefix $Prefix `
        -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters
    $isDryRun = [bool]$run.DryRun

    $requestedActions = @($actionOrder | Where-Object { $Apply -contains $_ })
    if ($requestedActions.Count -eq 0) {
        throw 'No operations were requested. Pass at least one value to -Apply.'
    }
    Write-MigrationLog -Message "Operations: $($requestedActions -join ', ')" -Level INFO

    $planRows = @(Import-MigrationPlan -Path $PlanPath -Wave $Wave)
    Write-MigrationLog -Message "Loaded $($planRows.Count) plan row(s) from $PlanPath" -Level INFO

    $null = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId

    $needsExchange = @($requestedActions | Where-Object { $exchangeActions -contains $_ }).Count -gt 0
    if ($needsExchange) {
        $null = Connect-MigrationExchange -DelegatedOrganization $DelegatedOrganization
    }

    $index = 0
    foreach ($row in $planRows) {
        $index++
        $match = Resolve-IdentityMatch -Row $row -Strategy $MatchOn
        $label = if ($match.Identity) { $match.Identity } else { Get-MigrationCsvValue -Row $row -Name 'DisplayName' -Default "row $index" }

        Write-Progress -Activity 'Applying identity changes' -Status "$index of $($planRows.Count): $label" `
            -PercentComplete (($index / [Math]::Max($planRows.Count, 1)) * 100)

        # A whole-object verdict still emits one row per requested action, so the CSV can be pivoted
        # on Action without some objects mysteriously missing from a column.
        # -AllowSynced here: the object's real onPremisesSyncEnabled is only known after the Graph
        # lookup below, and the plan's own IsSynced column describes the *source* object.
        $block = Test-MigrationPlanRowActionable -Row $row -IncludeCollisions:$IncludeCollisions `
            -SupportedObjectType $supportedObjectTypes -AllowSynced
        if ($block.Actionable -and $match.Detail) {
            $block = [pscustomobject]@{ Actionable = $false; Status = 'Failed'; Reason = $match.Detail }
        }

        if (-not $block.Actionable) {
            foreach ($action in $requestedActions) {
                $results.Add((New-IdentityResult -Identity $label -Action $action -Status $block.Status `
                    -Detail $block.Reason -Row $row -MatchedBy $match.MatchedBy))
            }
            if ($block.Status -eq 'Failed') { $exitCode = 2 }
            continue
        }

        $identity = $match.Identity
        $graphUser = $null
        $lookupError = ''

        try {
            $lookupPath = if ($match.IsObjectId) { $identity } else { [uri]::EscapeDataString($identity) }
            $graphUser = Invoke-MigrationGraphRequest -Method GET `
                -Uri ('/v1.0/users/' + $lookupPath + '?$select=' + $graphUserSelect)
        }
        catch {
            $lookupError = "Could not read the object from Graph: $($_.Exception.Message)"
        }

        if (-not $graphUser) {
            if (-not $lookupError) { $lookupError = "No object matching '$identity' exists in this tenant." }
            foreach ($action in $requestedActions) {
                $results.Add((New-IdentityResult -Identity $identity -Action $action -Status 'Failed' `
                    -Detail $lookupError -Row $row -MatchedBy $match.MatchedBy))
            }
            $exitCode = 2
            continue
        }

        $objectId = [string]$graphUser.id
        $currentUpn = [string]$graphUser.userPrincipalName

        $isSynced = $false
        if ($graphUser.PSObject.Properties['onPremisesSyncEnabled']) {
            $isSynced = [bool]$graphUser.onPremisesSyncEnabled
        }

        # Hard stop rather than a skip: EXO and Entra are both read-only for these attributes on a
        # synced object, so reporting the row as "not applicable" would hide real work.
        $syncBlock = Test-MigrationPlanRowActionable -Row $row -IncludeCollisions:$IncludeCollisions `
            -SupportedObjectType $supportedObjectTypes -IsSynced $isSynced

        if (-not $syncBlock.Actionable) {
            foreach ($action in $requestedActions) {
                $results.Add((New-IdentityResult -Identity $identity -Action $action -Status $syncBlock.Status `
                    -Detail $syncBlock.Reason -Row $row -MatchedBy $match.MatchedBy -ObjectId $objectId))
            }
            $exitCode = 2
            continue
        }

        $mailbox = $null
        $mailboxError = ''
        if ($needsExchange) {
            try {
                $mailbox = Get-EXOMailbox -Identity $objectId -Properties $exoMailboxProperties -ErrorAction Stop
            }
            catch {
                $mailboxError = "No mailbox found for '$identity': $($_.Exception.Message)"
            }
        }

        $changeSet = $null
        $addressActionsRequested = @($requestedActions | Where-Object { $addressActions -contains $_ })
        if ($mailbox -and $addressActionsRequested.Count -gt 0) {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @($mailbox.EmailAddresses) `
                -TargetPrimarySmtp (Get-MigrationCsvValue -Row $row -Name 'TargetPrimarySmtp' -Default '') `
                -TargetAlias (Split-MigrationList -Value (Get-MigrationCsvValue -Row $row -Name 'TargetAliases' -Default '')) `
                -TargetX500 (Get-PlanX500 -Row $row) `
                -Apply $addressActionsRequested `
                -RemoveOldPrimary:$RemoveOldPrimaryAlias
        }

        # The address policy is disabled once per object, before any address is touched, because a
        # policy that is still enabled can reassert the old primary the next time it is applied.
        $policyNote = ''
        $policyHandled = $false

        foreach ($action in $requestedActions) {
            $status = if ($isDryRun) { 'Planned' } else { 'Succeeded' }
            $detail = ''
            $currentValue = ''
            $targetValue = ''

            try {
                switch ($action) {

                    'Upn' {
                        $targetValue = Get-MigrationCsvValue -Row $row -Name 'TargetUserPrincipalName' -Default ''
                        $currentValue = $currentUpn

                        if ([string]::IsNullOrWhiteSpace($targetValue)) {
                            $status = 'Skipped'; $detail = 'The plan row has no TargetUserPrincipalName.'
                            break
                        }
                        if ($targetValue -ieq $currentUpn) {
                            $status = 'Skipped'; $detail = "UserPrincipalName is already $currentUpn."
                            break
                        }

                        $validation = Test-MigrationAddress -Address $targetValue -Kind Upn
                        if (-not $validation.IsValid) {
                            $status = 'Failed'; $detail = "TargetUserPrincipalName is not valid: $($validation.Reason)"
                            break
                        }

                        if (-not $PSCmdlet.ShouldProcess($identity, "Set userPrincipalName to $targetValue")) {
                            $status = 'Planned'; $detail = "Would set userPrincipalName to $targetValue."
                            break
                        }

                        try {
                            $null = Invoke-MigrationAction -Description "Set userPrincipalName on $identity to $targetValue" -Action {
                                Invoke-MigrationGraphRequest -Method PATCH -Uri ('/v1.0/users/' + $objectId) `
                                    -Body @{ userPrincipalName = $targetValue }
                            }
                            $detail = if ($isDryRun) { "Would set userPrincipalName to $targetValue." }
                                      else { "UserPrincipalName set to $targetValue." }
                        }
                        catch {
                            $status = 'Failed'
                            $detail = Get-UpnFailureDetail -ErrorRecord $_ -PrivilegedHint $privilegedRoleHint `
                                -ConflictHint $upnConflictHint
                        }
                    }

                    default {
                        if ($mailboxError) {
                            $status = 'Failed'; $detail = $mailboxError
                            break
                        }

                        if (-not $policyHandled -and $DisableEmailAddressPolicy -and ($addressActions -contains $action)) {
                            $policyHandled = $true
                            $policyEnabled = $false
                            if ($mailbox.PSObject.Properties['EmailAddressPolicyEnabled']) {
                                $policyEnabled = [bool]$mailbox.EmailAddressPolicyEnabled
                            }
                            if ($policyEnabled -and $PSCmdlet.ShouldProcess($identity, 'Disable the email address policy')) {
                                Set-MailboxAttribute -Identity $objectId -Name 'EmailAddressPolicyEnabled' -Value $false `
                                    -Description "Disable the email address policy on $identity"
                                $policyNote = 'Disabled the email address policy.'
                            }
                            elseif (-not $policyEnabled) {
                                $policyNote = 'The email address policy was already disabled.'
                            }
                        }

                        switch ($action) {

                            'PrimarySmtp' {
                                $targetValue = Get-MigrationCsvValue -Row $row -Name 'TargetPrimarySmtp' -Default ''
                                $currentValue = $changeSet.CurrentPrimary

                                if (-not $changeSet.PrimaryChanged) {
                                    $status = 'Skipped'; $detail = $changeSet.PrimaryDetail
                                    break
                                }

                                $validation = Test-MigrationAddress -Address $changeSet.NewPrimary -Kind Smtp
                                if (-not $validation.IsValid) {
                                    $status = 'Failed'; $detail = "TargetPrimarySmtp is not valid: $($validation.Reason)"
                                    break
                                }

                                if (-not $PSCmdlet.ShouldProcess($identity, "Set primary SMTP to $($changeSet.NewPrimary)")) {
                                    $status = 'Planned'; $detail = "Would set the primary SMTP to $($changeSet.NewPrimary)."
                                    break
                                }

                                if ($changeSet.RemoveBeforeAdd.Count -gt 0) {
                                    Set-MailboxAddress -Identity $objectId -Address $changeSet.RemoveBeforeAdd -Operation Remove
                                }
                                Set-MailboxAddress -Identity $objectId -Address @("SMTP:$($changeSet.NewPrimary)") -Operation Add
                                if ($changeSet.RemoveAfterAdd.Count -gt 0) {
                                    Set-MailboxAddress -Identity $objectId -Address $changeSet.RemoveAfterAdd -Operation Remove
                                }
                                $detail = $changeSet.PrimaryDetail
                            }

                            'Aliases' {
                                $targetValue = @($changeSet.AliasAdded) -join '; '
                                $currentValue = @(@($mailbox.EmailAddresses) | Where-Object { $_ -cmatch '^smtp:' }) -join '; '

                                if ($changeSet.AliasAdded.Count -eq 0) {
                                    $status = 'Skipped'; $detail = 'Every planned alias is already present.'
                                    break
                                }
                                if (-not $PSCmdlet.ShouldProcess($identity, "Add alias: $targetValue")) {
                                    $status = 'Planned'; $detail = "Would add alias: $targetValue."
                                    break
                                }

                                $aliasEntries = @($changeSet.AliasAdded | ForEach-Object { "smtp:$_" })
                                Set-MailboxAddress -Identity $objectId -Address $aliasEntries -Operation Add
                                $detail = "Added alias: $targetValue."
                            }

                            'X500' {
                                $targetValue = @($changeSet.X500Added) -join '; '
                                $currentValue = @(@($mailbox.EmailAddresses) | Where-Object { $_ -imatch '^x500:' }) -join '; '

                                if ($changeSet.X500Added.Count -eq 0) {
                                    $status = 'Skipped'
                                    $detail = if (@(Get-PlanX500 -Row $row).Count -eq 0) {
                                        'The plan row has no SourceX500 or LegacyExchangeDN.'
                                    }
                                    else { 'Every planned X500 address is already present.' }
                                    break
                                }
                                if (-not $PSCmdlet.ShouldProcess($identity, "Add X500: $targetValue")) {
                                    $status = 'Planned'; $detail = "Would add X500: $targetValue."
                                    break
                                }

                                $x500Entries = @($changeSet.X500Added | ForEach-Object { "X500:$_" })
                                Set-MailboxAddress -Identity $objectId -Address $x500Entries -Operation Add
                                $detail = "Added X500: $targetValue."
                            }

                            'MailNickname' {
                                $targetValue = Get-MigrationCsvValue -Row $row -Name 'TargetMailNickname' -Default ''
                                $currentValue = [string]$mailbox.Alias

                                if ([string]::IsNullOrWhiteSpace($targetValue)) {
                                    $status = 'Skipped'; $detail = 'The plan row has no TargetMailNickname.'
                                    break
                                }
                                if ($targetValue -ieq $currentValue) {
                                    $status = 'Skipped'; $detail = "Alias is already $currentValue."
                                    break
                                }

                                $validation = Test-MigrationAddress -Address $targetValue -Kind MailNickname
                                if (-not $validation.IsValid) {
                                    $status = 'Failed'; $detail = "TargetMailNickname is not valid: $($validation.Reason)"
                                    break
                                }
                                if (-not $PSCmdlet.ShouldProcess($identity, "Set alias to $targetValue")) {
                                    $status = 'Planned'; $detail = "Would set the alias to $targetValue."
                                    break
                                }

                                Set-MailboxAttribute -Identity $objectId -Name 'Alias' -Value $targetValue `
                                    -Description "Set the alias on $identity to $targetValue"
                                $detail = "Alias set to $targetValue."
                            }

                            'GalVisibility' {
                                $desired = -not $Unhide
                                $targetValue = [string]$desired
                                $currentHidden = $false
                                if ($mailbox.PSObject.Properties['HiddenFromAddressListsEnabled']) {
                                    $currentHidden = [bool]$mailbox.HiddenFromAddressListsEnabled
                                }
                                $currentValue = [string]$currentHidden

                                if ($currentHidden -eq $desired) {
                                    $status = 'Skipped'
                                    $detail = "HiddenFromAddressListsEnabled is already $desired."
                                    break
                                }
                                if (-not $PSCmdlet.ShouldProcess($identity, "Set HiddenFromAddressListsEnabled to $desired")) {
                                    $status = 'Planned'; $detail = "Would set HiddenFromAddressListsEnabled to $desired."
                                    break
                                }

                                Set-MailboxAttribute -Identity $objectId -Name 'HiddenFromAddressListsEnabled' -Value $desired `
                                    -Description "Set HiddenFromAddressListsEnabled on $identity to $desired"
                                $detail = "HiddenFromAddressListsEnabled set to $desired."
                            }
                        }
                    }
                }
            }
            catch {
                $status = 'Failed'
                $detail = $_.Exception.Message
            }

            if ($policyNote -and ($addressActions -contains $action)) {
                $detail = "$policyNote $detail"
                $policyNote = ''
            }

            if ($status -eq 'Failed') { $exitCode = 2 }

            $results.Add((New-IdentityResult -Identity $identity -Action $action -Status $status -Detail $detail `
                -Row $row -MatchedBy $match.MatchedBy -ObjectId $objectId -CurrentValue $currentValue `
                -TargetValue $targetValue))
        }
    }

    Write-Progress -Activity 'Applying identity changes' -Completed
    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Set-Identity'
}
catch {
    Write-MigrationLog -Message "Fatal error: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message $_.ScriptStackTrace -Level DEBUG
    if ($results.Count -gt 0) {
        try {
            $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Set-Identity'
        }
        catch {
            # The run is already failing; a results file that cannot be written must not mask the
            # original error, so the reason is logged and the fatal exit code stands.
            Write-MigrationLog -Message "Could not write the partial results file: $($_.Exception.Message)" -Level ERROR
        }
    }
    exit (Complete-MigrationRun -ExitCode 1)
}

#endregion --------------------------------------------------------------------------------------

#region Cleanup ---------------------------------------------------------------------------------

# Connections are intentionally left open: cutover runs are usually a chain of scripts and
# re-authenticating between each one is the slowest part of the evening.
exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion --------------------------------------------------------------------------------------
