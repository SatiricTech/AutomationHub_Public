#Requires -Version 7.4

<#
.SYNOPSIS
    Re-applies the source tenant's mailbox delegation - FullAccess, SendAs, SendOnBehalf, calendar
    folder permissions and forwarding - to the migrated mailboxes in the destination tenant.

.DESCRIPTION
    Phase 4 cutover writer. Mailbox permissions do not travel with a mailbox move: the destination
    tenant has no idea that the practice manager could open the reception mailbox, and every one of
    those relationships has to be recreated against the new objects. This script does that from the
    inventory Get-MigrationInventory captured before the move.

    Both sides of every permission are translated through the identity plan. A row saying
    "reception@contoso.com grants FullAccess to jsmith@contoso.com" only produces a change when the
    plan knows the destination address for both the mailbox and the trustee; a mailbox that is not
    among the selected plan rows is not reported at all, and an unmapped trustee (or an unmapped
    internal forwarding target) is reported Skipped with the address that could not be resolved,
    because guessing at a trustee is how somebody ends up with access to a mailbox they should not
    see.

    The trustee map is deliberately built from the whole plan rather than from the selected wave.
    Delegation crosses waves constantly - a wave 2 mailbox is very often delegated to somebody who
    moved in wave 1 - and building the map from the wave alone would silently drop those.

    Every operation is idempotent. The current state of each destination mailbox is read once and
    cached, and a permission that already exists is reported Skipped 'already present' rather than
    re-applied, so the script can be run repeatedly during a cutover weekend without piling up
    duplicate ACEs or resetting a calendar right an administrator has since adjusted.

    Every mutation is wrapped in Invoke-MigrationAction and gated by ShouldProcess, so -DryRun and
    -WhatIf both produce a full results file with Status 'Planned' and change nothing.

.PARAMETER PlanPath
    Path to IdentityPlan.csv. Supplies the Source to Target address map for both mailboxes and
    trustees.

.PARAMETER MailboxPermissionsCsv
    The MailboxPermissions tab exported by Get-MigrationInventory from the source tenant. Expected
    columns: MailboxPrimarySmtp, MailboxType, Trustee, TrusteeType, Permission, AutoMapping,
    IsInherited. Permission is FullAccess, SendAs, SendOnBehalf or Calendar:<AccessRights>.

.PARAMETER UserMailboxesCsv
    The UserMailboxes tab from the source tenant. Read for ForwardingAddress,
    ForwardingSmtpAddress, DeliverToMailboxAndForward and GrantSendOnBehalfTo.

.PARAMETER SharedMailboxesCsv
    The SharedMailboxes tab from the source tenant, read for the same columns as -UserMailboxesCsv.

.PARAMETER Apply
    Which permission kinds to re-apply: FullAccess, SendAs, SendOnBehalf, Calendar, Forwarding.
    Defaults to everything except Forwarding, which is opt-in because re-creating a forward at
    cutover can loop mail straight back into the source tenant. An unmapped ForwardingAddress
    (an internal recipient the plan does not cover) or a ForwardingSmtpAddress at a source-tenant
    domain is reported Skipped rather than re-created, for the same reason.

.PARAMETER Wave
    Only re-apply permissions for mailboxes whose plan row is in one of these waves. Trustees are
    still resolved from the whole plan.

.PARAMETER AutoMapping
    Whether FullAccess grants are auto-mapped into the delegate's Outlook profile. Defaults to
    $true. Set $false for large or archive-style mailboxes you do not want opening automatically.

.PARAMETER IncludeCollisions
    Also act on mailboxes whose plan row has PlanStatus Collision. By default only Planned,
    ManualOverride and UpnSmtpDiverge rows are actioned.

.PARAMETER DelegatedOrganization
    Customer tenant for Exchange Online, e.g. newco.onmicrosoft.com. Required when running as a
    partner against a customer tenant.

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
    Evaluate every permission and write a -DryRun_ results file with Status 'Planned' without
    changing anything. The destination mailboxes are still read, so the output distinguishes
    permissions that would be added from ones that already exist.

.EXAMPLE
    .\Set-MigrationMailboxPermissions.ps1 -PlanPath .\IdentityPlan.csv `
        -MailboxPermissionsCsv .\Contoso_MailboxPermissions_20260101-120000.csv -DryRun -Prefix Contoso

    Rehearses the whole delegation set and writes Contoso_Set-MailboxPermissions-DryRun_*.csv
    showing what would be added, what already exists and which trustees the plan cannot map.

.EXAMPLE
    .\Set-MigrationMailboxPermissions.ps1 -PlanPath .\IdentityPlan.csv `
        -MailboxPermissionsCsv .\Contoso_MailboxPermissions.csv `
        -UserMailboxesCsv .\Contoso_UserMailboxes.csv -Apply Calendar,Forwarding -Wave 2

    Restores calendar sharing and mailbox forwarding for wave 2 after the mailboxes have finished
    syncing.

.EXAMPLE
    .\Set-MigrationMailboxPermissions.ps1 -PlanPath .\IdentityPlan.csv `
        -MailboxPermissionsCsv .\Contoso_MailboxPermissions.csv -Wave 1 -AutoMapping $false `
        -DelegatedOrganization newco.onmicrosoft.com -Prefix Contoso

    GDAP alternative: re-applies wave 1's delegation in a customer tenant administered through
    GDAP rather than with a Global Admin account in it, without auto-mapping the shared mailboxes
    into everybody's Outlook profile.

.NOTES
    Author       : AutomationHub
    Requires     : PowerShell 7.4, ExchangeOnlineManagement
    EXO roles    : Exchange Administrator, or a role group holding the Mail Recipients role.
                   Add-MailboxPermission, Add-RecipientPermission, Set-Mailbox
                   (GrantSendOnBehalfTo, forwarding) and Add/Set-MailboxFolderPermission are all
                   covered by that role.
    Graph scopes : None - this script is Exchange Online only.
    GDAP         : Supported. Pass -DelegatedOrganization <customer>.onmicrosoft.com. If GDAP
                   claims are dropped, run Connect-ExchangeOnline -DisableWAM
                   -DelegatedOrganization <customer> yourself first; the script reuses the live
                   session rather than opening its own.
    Limits       : Exchange Online caps a mailbox at roughly 500 explicit ACEs. Beyond that, grant
                   FullAccess to a mail-enabled security group instead of to individuals.
    Calendars    : The calendar folder is addressed as <mailbox>:\Calendar. A mailbox created in a
                   non-English language has a localised folder name and is reported Failed with
                   that hint rather than silently skipped.
    Exit codes   : 0 success, 1 fatal, 2 completed with row failures.
    AI tools     : Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$MailboxPermissionsCsv,

    [Parameter(Mandatory = $false)]
    [string]$UserMailboxesCsv,

    [Parameter(Mandatory = $false)]
    [string]$SharedMailboxesCsv,

    [Parameter(Mandatory = $false)]
    [ValidateSet('FullAccess', 'SendAs', 'SendOnBehalf', 'Calendar', 'Forwarding')]
    [string[]]$Apply = @('FullAccess', 'SendAs', 'SendOnBehalf', 'Calendar'),

    [Parameter(Mandatory = $false)]
    [string[]]$Wave,

    [Parameter(Mandatory = $false)]
    [bool]$AutoMapping = $true,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeCollisions,

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

# Canonical execution order, independent of the order -Apply arrives in.
$permissionOrder = @('FullAccess', 'SendAs', 'SendOnBehalf', 'Calendar', 'Forwarding')

# Trustees Exchange reports but that must never be re-created: the mailbox's own principal, the
# built-in NT AUTHORITY accounts, and raw SIDs left behind by deleted objects.
$ignoredTrusteePattern = '^(NT AUTHORITY\\|S-1-5-)'

# Calendar rights that only exist as a folder default and are never granted to a named trustee.
$ignoredCalendarTrustee = @('Default', 'Anonymous')

$calendarFolderHint = 'The calendar folder could not be addressed as <mailbox>:\Calendar. A mailbox ' +
    'created in another language has a localised folder name - check Get-MailboxFolderStatistics ' +
    '-FolderScope Calendar for the real name and grant that folder manually.'

#endregion --------------------------------------------------------------------------------------

#region Functions -------------------------------------------------------------------------------

function ConvertFrom-PermissionEntry {
    <#
    .SYNOPSIS
        Splits the inventory's Permission column into a kind and its access rights.

    .DESCRIPTION
        The inventory stores calendar rights as 'Calendar:<AccessRights>' so a single column can
        carry both the mailbox-level grants and the folder-level ones. Everything else is a bare
        kind with no rights of its own.

    .EXAMPLE
        ConvertFrom-PermissionEntry -Permission 'Calendar:LimitedDetails'

        Returns Kind 'Calendar' and AccessRights 'LimitedDetails'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Permission
    )

    $text = ([string]$Permission).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{ Kind = ''; AccessRights = ''; IsKnown = $false }
    }

    $separator = $text.IndexOf(':')
    $kind = if ($separator -gt 0) { $text.Substring(0, $separator).Trim() } else { $text }
    $rights = if ($separator -gt 0) { $text.Substring($separator + 1).Trim() } else { '' }

    $canonical = switch -Regex ($kind) {
        '^(?i)fullaccess$'   { 'FullAccess' }
        '^(?i)sendas$'       { 'SendAs' }
        '^(?i)sendonbehalf$' { 'SendOnBehalf' }
        '^(?i)calendar$'     { 'Calendar' }
        default              { '' }
    }

    [pscustomobject]@{
        Kind         = $canonical
        AccessRights = $rights
        IsKnown      = [bool]$canonical
    }
}

function Get-CanonicalNameLeaf {
    <#
    .SYNOPSIS
        Returns the leaf segment of an Exchange canonical name.

    .DESCRIPTION
        GrantSendOnBehalfTo returns a canonical name such as contoso.com/Users/Bea Kane rather than
        an address, and the plan map does not key on that shape. The leaf is the object's Exchange
        Name attribute, which usually - but not always, since Exchange appends a uniqueness suffix
        on a Name collision - equals DisplayName, so this is a fallback rather than a guaranteed
        match. A value that is not canonical-name shaped is returned unchanged.

    .EXAMPLE
        Get-CanonicalNameLeaf -Value 'contoso.com/Users/Bea Kane'

        Returns 'Bea Kane'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $text = ([string]$Value).Trim()
    if ($text -match '/') {
        $leaf = $text.Substring($text.LastIndexOf('/') + 1).Trim()
        if ($leaf) { return $leaf }
    }
    return $text
}

function ConvertTo-PermissionPrincipal {
    <#
    .SYNOPSIS
        Reduces an existing-permission object to every identifier it might be matched on.

    .DESCRIPTION
        Exchange names the holder of a permission differently for every cmdlet:
        Get-EXOMailboxPermission returns a UPN string in User, Get-EXORecipientPermission returns an
        address in Trustee, GrantSendOnBehalfTo returns a canonical name, and
        Get-MailboxFolderPermission returns an object whose display name and recipient are nested.
        Rather than special-casing each shape at the comparison site, every plausible identifier is
        flattened into one list here and the comparison becomes a set intersection.

    .EXAMPLE
        ConvertTo-PermissionPrincipal -Entry $folderPermission

        Returns the trustee's display name and primary SMTP address as a single string array.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Entry
    )

    $values = [System.Collections.Generic.List[string]]::new()

    $addValue = {
        param($Candidate)
        if ($null -eq $Candidate) { return }
        $text = ([string]$Candidate).Trim()
        if ($text -and -not ($values | Where-Object { $_ -ieq $text })) { $values.Add($text) }
    }

    if ($Entry -is [string]) {
        & $addValue $Entry
        # GrantSendOnBehalfTo reports the trustee as a canonical name (contoso.com/Users/Bea Kane);
        # the leaf is added too so a comparison against the plan's SMTP address or DisplayName can
        # still match.
        & $addValue (Get-CanonicalNameLeaf -Value $Entry)
        return [string[]]$values.ToArray()
    }

    if ($null -eq $Entry) { return [string[]]@() }

    foreach ($name in @('User', 'Trustee', 'Identity', 'PrimarySmtpAddress', 'UserPrincipalName', 'DisplayName')) {
        if (-not $Entry.PSObject.Properties[$name]) { continue }
        $value = $Entry.PSObject.Properties[$name].Value
        if ($null -eq $value) { continue }

        if ($value -is [string]) { & $addValue $value; continue }

        # Nested shapes: Get-MailboxFolderPermission's User carries DisplayName plus an ADRecipient
        # or RecipientPrincipal holding the real addresses.
        foreach ($nested in @('DisplayName', 'PrimarySmtpAddress', 'UserPrincipalName')) {
            if ($value.PSObject.Properties[$nested]) { & $addValue $value.PSObject.Properties[$nested].Value }
        }
        foreach ($container in @('ADRecipient', 'RecipientPrincipal')) {
            if (-not $value.PSObject.Properties[$container]) { continue }
            $inner = $value.PSObject.Properties[$container].Value
            if ($null -eq $inner) { continue }
            foreach ($nested in @('PrimarySmtpAddress', 'UserPrincipalName', 'DisplayName')) {
                if ($inner.PSObject.Properties[$nested]) { & $addValue $inner.PSObject.Properties[$nested].Value }
            }
        }
        & $addValue $value
    }

    return [string[]]$values.ToArray()
}

function Get-PermissionDiff {
    <#
    .SYNOPSIS
        Decides whether a wanted permission needs adding, updating or nothing at all.

    .DESCRIPTION
        This is the idempotency guarantee, and it is a pure function so it can be proved against a
        fixture instead of against a tenant. A mailbox-level grant either exists or does not; a
        calendar right can also exist with the wrong access level, which is the one case that needs
        Set-MailboxFolderPermission rather than Add-.

        A trustee is considered present when any of its known identifiers matches any identifier on
        an existing entry, because the two sides are rarely expressed the same way.

    .EXAMPLE
        Get-PermissionDiff -Existing $current -TrusteeIdentifier 'john.smith@newco.com' -Kind FullAccess

        Returns Action 'Skip' when the delegate already holds FullAccess.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyCollection()][object[]]$Existing = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$TrusteeIdentifier,
        [Parameter(Mandatory)][ValidateSet('FullAccess', 'SendAs', 'SendOnBehalf', 'Calendar')][string]$Kind,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$AccessRights = ''
    )

    $wanted = @($TrusteeIdentifier | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { ([string]$_).Trim() })

    foreach ($entry in @($Existing)) {
        if ($null -eq $entry) { continue }

        $principals = ConvertTo-PermissionPrincipal -Entry $entry
        $isMatch = @($principals | Where-Object { $identifier = $_; @($wanted | Where-Object { $_ -ieq $identifier }).Count -gt 0 })
        if ($isMatch.Count -eq 0) { continue }

        $rights = @()
        if ($entry -isnot [string] -and $entry.PSObject.Properties['AccessRights']) {
            $rights = @($entry.PSObject.Properties['AccessRights'].Value | ForEach-Object { ([string]$_).Trim() })
        }

        switch ($Kind) {
            'Calendar' {
                if ([string]::IsNullOrWhiteSpace($AccessRights)) {
                    return [pscustomobject]@{ Action = 'Skip'; Detail = 'Calendar permission already present.' }
                }
                $current = ($rights -join ', ')
                # AccessRights can carry more than one right joined with a comma (the inventory
                # writes 'Calendar:ReadItems,FolderVisible'), so the wanted set is compared against
                # the existing set as sets rather than as a single string - otherwise a
                # multi-right entry never matches and is re-applied on every run.
                $wantedRights = @($AccessRights -split '\s*,\s*' | Where-Object { $_ })
                $missing = @($wantedRights | Where-Object {
                    $want = $_; @($rights | Where-Object { $_ -ieq $want }).Count -eq 0
                })
                $sameSet = ($wantedRights.Count -gt 0) -and ($wantedRights.Count -eq $rights.Count) -and
                    ($missing.Count -eq 0)
                if ($sameSet) {
                    return [pscustomobject]@{ Action = 'Skip'; Detail = "Calendar permission already present ($current)." }
                }
                return [pscustomobject]@{
                    Action = 'Update'
                    Detail = "Calendar permission is $current - changing it to $AccessRights."
                }
            }
            'SendOnBehalf' {
                return [pscustomobject]@{ Action = 'Skip'; Detail = 'SendOnBehalf already present.' }
            }
            default {
                if ($rights.Count -eq 0 -or @($rights | Where-Object { $_ -ieq $Kind }).Count -gt 0) {
                    return [pscustomobject]@{ Action = 'Skip'; Detail = "$Kind already present." }
                }
            }
        }
    }

    [pscustomobject]@{ Action = 'Add'; Detail = '' }
}

function New-PermissionResult {
    <#
    .SYNOPSIS
        Builds one result row for a permission the script considered.

    .EXAMPLE
        New-PermissionResult -Identity 'reception@newco.com' -Action FullAccess -Status Succeeded `
            -Detail 'Granted.' -SourceMailbox 'reception@contoso.com' -SourceTrustee 'jsmith@contoso.com'

        Returns the result row written to the CSV for a completed FullAccess grant.
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
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$SourceMailbox = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$SourceTrustee = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Trustee = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$AccessRights = ''
    )

    [pscustomobject][ordered]@{
        Identity      = $Identity
        Action        = $Action
        Status        = $Status
        Detail        = ([string]$Detail).Trim()
        SourceMailbox = $SourceMailbox
        SourceTrustee = $SourceTrustee
        Trustee       = $Trustee
        AccessRights  = $AccessRights
    }
}

function Add-MailboxAccessRight {
    <#
    .SYNOPSIS
        Grants one mailbox-level permission.

    .DESCRIPTION
        One call site per permission kind, so the DryRun guarantee has a single place to hold.
        Invoke-MigrationAction short-circuits in DryRun mode and the Add-/Set- cmdlet is never
        reached.

    .EXAMPLE
        Add-MailboxAccessRight -Mailbox 'reception@newco.com' -Trustee 'john.smith@newco.com' -Kind FullAccess

        Grants FullAccess with auto-mapping left at its default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Mailbox,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Trustee,
        [Parameter(Mandatory)][ValidateSet('FullAccess', 'SendAs', 'SendOnBehalf')][string]$Kind,
        [Parameter(Mandatory = $false)][bool]$AutoMapping = $true
    )

    switch ($Kind) {
        'FullAccess' {
            Invoke-MigrationAction -Description "Grant FullAccess on $Mailbox to $Trustee (AutoMapping $AutoMapping)" -Action {
                $null = Add-MailboxPermission -Identity $Mailbox -User $Trustee -AccessRights FullAccess `
                    -AutoMapping:$AutoMapping -Confirm:$false -ErrorAction Stop
            }
        }
        'SendAs' {
            Invoke-MigrationAction -Description "Grant SendAs on $Mailbox to $Trustee" -Action {
                $null = Add-RecipientPermission -Identity $Mailbox -Trustee $Trustee -AccessRights SendAs `
                    -Confirm:$false -ErrorAction Stop
            }
        }
        'SendOnBehalf' {
            Invoke-MigrationAction -Description "Grant SendOnBehalf on $Mailbox to $Trustee" -Action {
                Set-Mailbox -Identity $Mailbox -GrantSendOnBehalfTo @{ Add = $Trustee } -ErrorAction Stop
            }
        }
    }
}

function Set-MailboxCalendarPermission {
    <#
    .SYNOPSIS
        Grants or changes a calendar folder permission.

    .DESCRIPTION
        Add- fails when the trustee already has any right on the folder, and Set- fails when they
        have none, so the caller's diff decides which one to use rather than the script catching an
        error and guessing.

    .EXAMPLE
        Set-MailboxCalendarPermission -Mailbox 'jane@newco.com' -Trustee 'john.smith@newco.com' `
            -AccessRights 'Editor' -Mode Add

        Grants Editor on Jane's calendar.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller gates the row with ShouldProcess and Invoke-MigrationAction honours -DryRun.')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Mailbox,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Trustee,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccessRights,
        [Parameter(Mandatory)][ValidateSet('Add', 'Update')][string]$Mode
    )

    $folder = "${Mailbox}:\Calendar"
    $rights = @($AccessRights -split '\s*,\s*' | Where-Object { $_ })

    if ($Mode -eq 'Add') {
        Invoke-MigrationAction -Description "Grant $AccessRights on $folder to $Trustee" -Action {
            $null = Add-MailboxFolderPermission -Identity $folder -User $Trustee -AccessRights $rights -ErrorAction Stop
        }
    }
    else {
        Invoke-MigrationAction -Description "Change $Trustee to $AccessRights on $folder" -Action {
            $null = Set-MailboxFolderPermission -Identity $folder -User $Trustee -AccessRights $rights -ErrorAction Stop
        }
    }
}

function Set-MailboxForwarding {
    <#
    .SYNOPSIS
        Re-applies a mailbox's forwarding configuration.

    .DESCRIPTION
        The caller always applies the destination address through this cmdlet's
        -ForwardingSmtpAddress parameter, whether the source row's forward was originally an
        internal ForwardingAddress or a literal ForwardingSmtpAddress: once the target has been
        translated through the plan it is a destination-tenant SMTP address either way, and using
        -ForwardingSmtpAddress avoids a recipient lookup that can fail mid-cutover. The distinction
        between the two source columns is made by the caller, before this is reached - an
        unmapped internal ForwardingAddress is skipped rather than passed through here, and an
        unmapped ForwardingSmtpAddress is rejected when it sits at a source-tenant domain, because
        re-creating either verbatim can loop mail straight back into the source tenant.

    .EXAMPLE
        Set-MailboxForwarding -Mailbox 'jane@newco.com' -ForwardingSmtpAddress 'team@fabrikam.com' `
            -DeliverToMailboxAndForward $true

        Forwards Jane's mail to an external address and keeps a copy in her mailbox.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller gates the row with ShouldProcess and Invoke-MigrationAction honours -DryRun.')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Mailbox,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ForwardingAddress = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ForwardingSmtpAddress = '',
        [Parameter(Mandatory = $false)][bool]$DeliverToMailboxAndForward = $false
    )

    $parameters = @{ Identity = $Mailbox; DeliverToMailboxAndForward = $DeliverToMailboxAndForward; ErrorAction = 'Stop' }
    $described = [System.Collections.Generic.List[string]]::new()

    if ($ForwardingAddress) {
        $parameters['ForwardingAddress'] = $ForwardingAddress
        $described.Add("ForwardingAddress $ForwardingAddress")
    }
    if ($ForwardingSmtpAddress) {
        $parameters['ForwardingSmtpAddress'] = $ForwardingSmtpAddress
        $described.Add("ForwardingSmtpAddress $ForwardingSmtpAddress")
    }
    if ($described.Count -eq 0) { return }

    $description = "Set forwarding on ${Mailbox}: $($described -join ', ') " +
        "(DeliverToMailboxAndForward $DeliverToMailboxAndForward)"

    Invoke-MigrationAction -Description $description -Action {
        Set-Mailbox @parameters
    }
}

function Test-MigrationSourceDomainAddress {
    <#
    .SYNOPSIS
        True when an SMTP address's domain is one the plan lists as a source domain.

    .DESCRIPTION
        A ForwardingSmtpAddress the plan does not map is normally passed through as-is - it is
        usually an external partner. But when its domain matches a source domain seen in the
        plan, passing it through re-creates exactly the loop the -Apply help warns about: the
        address still lives in the source tenant while migration is under way, and even in a
        vanity-domain migration where the domain eventually moves to the destination, an address
        the plan does not map is still wrong once it lands there.

    .EXAMPLE
        Test-MigrationSourceDomainAddress -Address 'dl@contoso.com' -SourceDomain $domains

        Returns $true when contoso.com is one of the plan's source domains.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Address,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$SourceDomain
    )

    if ($null -eq $SourceDomain -or $SourceDomain.Count -eq 0) { return $false }

    $at = $Address.LastIndexOf('@')
    if ($at -lt 0) { return $false }

    return $SourceDomain.Contains($Address.Substring($at + 1))
}

function Get-DestinationPermissionState {
    <#
    .SYNOPSIS
        Reads the destination mailbox's current delegation once and caches it.

    .DESCRIPTION
        A mailbox usually appears on several permission rows, and re-reading it for each one turns a
        few hundred rows into a few thousand Exchange calls. Reading once per mailbox and caching is
        both faster and kinder to the throttling limits. The REST-based Get-EXO* cmdlets are used
        because the older RPS equivalents fail on large tenants with a 500MB session limit.

        Only the kinds actually requested are read, so a Calendar-only run never touches
        Get-EXOMailboxPermission.

    .EXAMPLE
        Get-DestinationPermissionState -Mailbox 'reception@newco.com' -Kind FullAccess,Calendar

        Returns the mailbox's current FullAccess ACEs and calendar folder permissions.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Mailbox,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Kind
    )

    $state = @{
        FullAccess   = @()
        SendAs       = @()
        SendOnBehalf = @()
        Calendar     = @()
        Mailbox      = $null
        Errors       = @{}
    }

    if ($Kind -contains 'FullAccess') {
        try {
            $state.FullAccess = @(Get-EXOMailboxPermission -Identity $Mailbox -ErrorAction Stop |
                Where-Object { [string]$_.User -notmatch $ignoredTrusteePattern })
        }
        catch { $state.Errors['FullAccess'] = $_.Exception.Message }
    }

    if ($Kind -contains 'SendAs') {
        try {
            $state.SendAs = @(Get-EXORecipientPermission -Identity $Mailbox -ErrorAction Stop |
                Where-Object { [string]$_.Trustee -notmatch $ignoredTrusteePattern })
        }
        catch { $state.Errors['SendAs'] = $_.Exception.Message }
    }

    if (($Kind -contains 'SendOnBehalf') -or ($Kind -contains 'Forwarding')) {
        try {
            $state.Mailbox = Get-EXOMailbox -Identity $Mailbox -Properties GrantSendOnBehalfTo, ForwardingAddress,
                ForwardingSmtpAddress, DeliverToMailboxAndForward -ErrorAction Stop
            if ($state.Mailbox.PSObject.Properties['GrantSendOnBehalfTo']) {
                $state.SendOnBehalf = @($state.Mailbox.GrantSendOnBehalfTo)
            }
        }
        catch { $state.Errors['SendOnBehalf'] = $_.Exception.Message; $state.Errors['Forwarding'] = $_.Exception.Message }
    }

    if ($Kind -contains 'Calendar') {
        try {
            $state.Calendar = @(Get-MailboxFolderPermission -Identity "${Mailbox}:\Calendar" -ErrorAction Stop |
                Where-Object { $ignoredCalendarTrustee -notcontains [string]$_.User })
        }
        catch { $state.Errors['Calendar'] = "$($_.Exception.Message) $calendarFolderHint" }
    }

    return $state
}

#endregion --------------------------------------------------------------------------------------

#region Main ------------------------------------------------------------------------------------

$exitCode = 0
$results = [System.Collections.Generic.List[object]]::new()

try {
    $run = Initialize-MigrationRun -ScriptName 'Set-MigrationMailboxPermissions' -OutputPath $OutputPath `
        -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters
    $isDryRun = [bool]$run.DryRun

    # A declined ShouldProcess is not a rehearsal: -WhatIf, or answering No at the prompt, means the
    # call was never made and the row must not read as Planned (which the contract reserves for
    # -DryRun) or as Succeeded. Both of those would put a change in the results file that the tenant
    # never saw.
    $declinedDetail = 'Declined at the confirmation prompt.'

    $requestedKinds = @($permissionOrder | Where-Object { $Apply -contains $_ })
    if ($requestedKinds.Count -eq 0) {
        throw 'No permission kinds were requested. Pass at least one value to -Apply.'
    }
    Write-MigrationLog -Message "Permission kinds: $($requestedKinds -join ', ')" -Level INFO

    # The map spans every wave on purpose: delegation crosses waves, and a trustee who moved in an
    # earlier wave must still resolve while a later wave is being processed.
    $allPlanRows = @(Import-MigrationPlan -Path $PlanPath)
    $addressMap = Get-MigrationPlanAddressMap -Rows $allPlanRows
    Write-MigrationLog -Message "Address map holds $($addressMap.Count) source identifier(s)." -Level INFO

    # Domains the plan names as source-tenant domains. Used to catch a ForwardingSmtpAddress the
    # plan does not map but that still points back at the source tenant - passing that through
    # would re-create the mail loop the -Apply help warns about.
    $sourceDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $allPlanRows) {
        foreach ($column in @('SourcePrimarySmtp', 'SourceUserPrincipalName')) {
            $value = [string](Get-MigrationCsvValue -Row $row -Name $column -Default '')
            $at = $value.LastIndexOf('@')
            if ($at -ge 0) { [void]$sourceDomains.Add($value.Substring($at + 1)) }
        }
    }

    # Mailboxes are restricted to the selected wave and to actionable plan statuses.
    $selectedRows = @(Select-MigrationPlanRows -Rows $allPlanRows -Wave $Wave |
        Where-Object { (Test-MigrationPlanRowActionable -Row $_ -IncludeCollisions:$IncludeCollisions -AllowSynced).Actionable })
    $selectedMailbox = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $selectedRows) {
        foreach ($column in @('SourceUserPrincipalName', 'SourcePrimarySmtp')) {
            $value = ([string](Get-MigrationCsvValue -Row $row -Name $column -Default '')).Trim()
            if ($value) { [void]$selectedMailbox.Add($value) }
        }
        foreach ($alias in (Split-MigrationList -Value (Get-MigrationCsvValue -Row $row -Name 'SourceAliases' -Default ''))) {
            $value = ([string]$alias).Trim() -replace '^(?i)smtp:', ''
            if ($value) { [void]$selectedMailbox.Add($value) }
        }
    }
    Write-MigrationLog -Message "$($selectedRows.Count) plan row(s) selected for this run." -Level INFO

    # Build the wanted permission set from the inventory before connecting, so a malformed CSV fails
    # before an operator has sat through a sign-in prompt.
    $wanted = [System.Collections.Generic.List[object]]::new()

    $permissionRows = @(Import-MigrationCsv -Path $MailboxPermissionsCsv `
        -RequiredColumns @('MailboxPrimarySmtp', 'Trustee', 'Permission'))

    foreach ($row in $permissionRows) {
        $isInherited = ([string](Get-MigrationCsvValue -Row $row -Name 'IsInherited' -Default 'False')).Trim()
        if ($isInherited -ieq 'True') { continue }

        $trustee = ([string](Get-MigrationCsvValue -Row $row -Name 'Trustee' -Default '')).Trim()
        if ($trustee -match $ignoredTrusteePattern) { continue }
        if ($ignoredCalendarTrustee -contains $trustee) { continue }

        $parsed = ConvertFrom-PermissionEntry -Permission (Get-MigrationCsvValue -Row $row -Name 'Permission' -Default '')
        if (-not $parsed.IsKnown) { continue }
        if ($requestedKinds -notcontains $parsed.Kind) { continue }

        if ($parsed.Kind -eq 'SendOnBehalf') {
            # The MailboxPermissions tab writes this trustee straight from GrantSendOnBehalfTo, in
            # canonical-name form (contoso.com/Users/Bea Kane) - the plan map does not key on that
            # shape, so the leaf is used instead of leaving every one of these unmapped.
            $trustee = Get-CanonicalNameLeaf -Value $trustee
        }

        $wanted.Add([pscustomobject]@{
            SourceMailbox = ([string](Get-MigrationCsvValue -Row $row -Name 'MailboxPrimarySmtp' -Default '')).Trim()
            SourceTrustee = $trustee
            Kind          = $parsed.Kind
            AccessRights  = $parsed.AccessRights
            AutoMapping   = ([string](Get-MigrationCsvValue -Row $row -Name 'AutoMapping' -Default '')).Trim()
        })
    }

    # The mailbox tabs carry GrantSendOnBehalfTo and the forwarding columns, neither of which the
    # permissions tab reports.
    $mailboxRows = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @($UserMailboxesCsv, $SharedMailboxesCsv)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        foreach ($row in (Import-MigrationCsv -Path $path -RequiredColumns @('PrimarySmtpAddress'))) {
            $mailboxRows.Add($row)
        }
    }

    foreach ($row in $mailboxRows) {
        $sourceMailbox = ([string](Get-MigrationCsvValue -Row $row -Name 'PrimarySmtpAddress' -Default '')).Trim()
        if (-not $sourceMailbox) { continue }

        if ($requestedKinds -contains 'SendOnBehalf') {
            foreach ($entry in (Split-MigrationList -Value (Get-MigrationCsvValue -Row $row -Name 'GrantSendOnBehalfTo' -Default ''))) {
                $trustee = Get-CanonicalNameLeaf -Value (([string]$entry).Trim())
                if (-not $trustee -or $trustee -match $ignoredTrusteePattern) { continue }

                # A delegation reported here and on the permissions tab rarely arrives in the same
                # shape (this column can be a resolved SMTP address, the permissions tab a raw
                # canonical name), so a raw-string comparison alone misses the duplicate. Falling
                # back to comparing where both sides resolve in the plan collapses the two onto one
                # item instead of producing an extra live row.
                $resolvedTrustee = Resolve-MigrationPlanAddress -Map $addressMap -Address $trustee -Role 'trustee'
                $duplicate = @($wanted | Where-Object {
                    if ($_.Kind -ne 'SendOnBehalf' -or -not ($_.SourceMailbox -ieq $sourceMailbox)) { return $false }
                    if ($_.SourceTrustee -ieq $trustee) { return $true }
                    if (-not $resolvedTrustee.IsMapped) { return $false }
                    $otherResolved = Resolve-MigrationPlanAddress -Map $addressMap -Address $_.SourceTrustee -Role 'trustee'
                    return ($otherResolved.IsMapped -and $otherResolved.Address -ieq $resolvedTrustee.Address)
                })
                if ($duplicate.Count -gt 0) { continue }
                $wanted.Add([pscustomobject]@{
                    SourceMailbox = $sourceMailbox; SourceTrustee = $trustee
                    Kind = 'SendOnBehalf'; AccessRights = ''; AutoMapping = ''
                    ForwardingAddress = ''; ForwardingSmtpAddress = ''
                })
            }
        }

        if ($requestedKinds -contains 'Forwarding') {
            $forwardingAddress = ([string](Get-MigrationCsvValue -Row $row -Name 'ForwardingAddress' -Default '')).Trim()
            $forwardingSmtp = ([string](Get-MigrationCsvValue -Row $row -Name 'ForwardingSmtpAddress' -Default '')).Trim()
            if ($forwardingAddress -or $forwardingSmtp) {
                $wanted.Add([pscustomobject]@{
                    SourceMailbox = $sourceMailbox
                    # Kept only for reporting - the two columns are resolved separately below,
                    # because an unmapped internal ForwardingAddress and an unmapped external
                    # ForwardingSmtpAddress are not the same risk.
                    SourceTrustee = if ($forwardingSmtp) { $forwardingSmtp } else { $forwardingAddress }
                    Kind          = 'Forwarding'
                    AccessRights  = ([string](Get-MigrationCsvValue -Row $row -Name 'DeliverToMailboxAndForward' -Default 'False')).Trim()
                    AutoMapping   = ''
                    ForwardingAddress = $forwardingAddress
                    ForwardingSmtpAddress = $forwardingSmtp
                })
            }
        }
    }

    Write-MigrationLog -Message "$($wanted.Count) permission(s) to evaluate." -Level INFO

    $connection = Connect-MigrationExchange -DelegatedOrganization $DelegatedOrganization
    $connectedOrganization = if ($connection -and $connection.PSObject.Properties['Organization']) {
        [string]$connection.Organization
    } else { '' }

    # Connect-MigrationExchange reuses whatever session is already live, which in a chained
    # cutover shell can be the source tenant's session left open by an earlier script. Confirming
    # the connected organisation actually accepts a destination domain is a cheap check against
    # writing into the wrong tenant; it degrades to a warning rather than a hard stop when the
    # read itself is unavailable, so a permissions gap on Get-AcceptedDomain does not block a run
    # the operator can see is fine.
    $targetDomain = ''
    foreach ($value in $addressMap.Values) {
        $at = ([string]$value).LastIndexOf('@')
        if ($at -ge 0) { $targetDomain = ([string]$value).Substring($at + 1); break }
    }
    if ($targetDomain) {
        $acceptedDomains = @()
        try {
            $acceptedDomains = @(Get-AcceptedDomain -ErrorAction Stop | ForEach-Object { [string]$_.DomainName })
        }
        catch {
            Write-MigrationLog -Message ("Could not read accepted domains from '$connectedOrganization' to confirm " +
                "it is the destination tenant: $($_.Exception.Message)") -Level WARNING
        }
        if ($acceptedDomains.Count -gt 0 -and -not ($acceptedDomains | Where-Object { $_ -ieq $targetDomain })) {
            throw ("Connected to '$connectedOrganization', which does not accept mail for '$targetDomain' - is " +
                'this the destination tenant? Pass -DelegatedOrganization for the customer tenant, or sign in ' +
                'directly to it.')
        }
        Write-MigrationLog -Message "Connected to Exchange Online organisation '$connectedOrganization'." -Level INFO
    }
    else {
        Write-MigrationLog -Message ("Connected to Exchange Online organisation '$connectedOrganization'. No mapped " +
            'destination address was available to confirm this is the destination tenant.') -Level WARNING
    }

    $stateCache = @{}
    $ordered = @($wanted | Sort-Object -Property SourceMailbox, @{ Expression = { $permissionOrder.IndexOf($_.Kind) } }, SourceTrustee)
    $index = 0

    foreach ($item in $ordered) {
        $index++
        Write-Progress -Activity 'Re-applying mailbox permissions' `
            -Status "$index of $($ordered.Count): $($item.SourceMailbox) - $($item.Kind)" `
            -PercentComplete (($index / [Math]::Max($ordered.Count, 1)) * 100)

        if (-not $selectedMailbox.Contains($item.SourceMailbox)) {
            # Not an error - the mailbox simply belongs to another wave or is not in the plan.
            continue
        }

        $mailboxMap = Resolve-MigrationPlanAddress -Map $addressMap -Address $item.SourceMailbox -Role 'mailbox'
        if (-not $mailboxMap.IsMapped) {
            $results.Add((New-PermissionResult -Identity $item.SourceMailbox -Action $item.Kind -Status 'Skipped' `
                -Detail $mailboxMap.Detail -SourceMailbox $item.SourceMailbox -SourceTrustee $item.SourceTrustee `
                -AccessRights $item.AccessRights))
            continue
        }
        $mailbox = $mailboxMap.Address

        if ($item.Kind -eq 'Forwarding') {
            # ForwardingAddress names an internal recipient - re-creating it verbatim when the
            # plan does not map it points the destination mailbox straight back at a source-tenant
            # object, so it is skipped rather than passed through. ForwardingSmtpAddress may well
            # be an external partner the plan was never going to know about, so it is passed
            # through when unmapped - unless its domain is one of the plan's own source domains,
            # in which case passing it through is the same loop by another name.
            $forwardTrustee = ''
            $forwardSkipped = $false
            $forwardDetail = ''

            if ($item.ForwardingSmtpAddress) {
                $smtpMap = Resolve-MigrationPlanAddress -Map $addressMap -Address $item.ForwardingSmtpAddress -Role 'trustee'
                if ($smtpMap.IsMapped) {
                    $forwardTrustee = $smtpMap.Address
                }
                elseif ($item.ForwardingSmtpAddress -notmatch '@') {
                    $forwardSkipped = $true
                    $forwardDetail = "The forwarding target '$($item.ForwardingSmtpAddress)' is not a resolvable SMTP address."
                }
                elseif (Test-MigrationSourceDomainAddress -Address $item.ForwardingSmtpAddress -SourceDomain $sourceDomains) {
                    $forwardSkipped = $true
                    $forwardDetail = "Forward target is a source-domain address the plan does not map: $($item.ForwardingSmtpAddress)."
                }
                else {
                    $forwardTrustee = $item.ForwardingSmtpAddress
                }
            }
            elseif ($item.ForwardingAddress) {
                $addressResult = Resolve-MigrationPlanAddress -Map $addressMap -Address $item.ForwardingAddress -Role 'trustee'
                if ($addressResult.IsMapped) {
                    $forwardTrustee = $addressResult.Address
                }
                else {
                    $forwardSkipped = $true
                    $forwardDetail = $addressResult.Detail
                }
            }

            if ($forwardSkipped) {
                $results.Add((New-PermissionResult -Identity $mailbox -Action $item.Kind -Status 'Skipped' `
                    -Detail $forwardDetail -SourceMailbox $item.SourceMailbox -SourceTrustee $item.SourceTrustee `
                    -AccessRights $item.AccessRights))
                continue
            }
            $trustee = $forwardTrustee
        }
        else {
            $trusteeMap = Resolve-MigrationPlanAddress -Map $addressMap -Address $item.SourceTrustee -Role 'trustee'
            if (-not $trusteeMap.IsMapped) {
                $results.Add((New-PermissionResult -Identity $mailbox -Action $item.Kind -Status 'Skipped' `
                    -Detail $trusteeMap.Detail -SourceMailbox $item.SourceMailbox -SourceTrustee $item.SourceTrustee `
                    -AccessRights $item.AccessRights))
                continue
            }
            $trustee = $trusteeMap.Address
        }

        if (-not $stateCache.ContainsKey($mailbox)) {
            $stateCache[$mailbox] = Get-DestinationPermissionState -Mailbox $mailbox -Kind $requestedKinds
        }
        $state = $stateCache[$mailbox]

        if ($state.Errors.ContainsKey($item.Kind)) {
            $results.Add((New-PermissionResult -Identity $mailbox -Action $item.Kind -Status 'Failed' `
                -Detail "Could not read the destination mailbox: $($state.Errors[$item.Kind])" `
                -SourceMailbox $item.SourceMailbox -SourceTrustee $item.SourceTrustee -Trustee $trustee `
                -AccessRights $item.AccessRights))
            $exitCode = 2
            continue
        }

        $status = if ($isDryRun) { 'Planned' } else { 'Succeeded' }
        $detail = ''

        try {
            if ($item.Kind -eq 'Forwarding') {
                $deliverAndForward = ($item.AccessRights -ieq 'True')
                $currentSmtp = ''
                $currentAddress = ''
                if ($state.Mailbox) {
                    if ($state.Mailbox.PSObject.Properties['ForwardingSmtpAddress']) {
                        $currentSmtp = ([string]$state.Mailbox.ForwardingSmtpAddress) -replace '^(?i)smtp:', ''
                    }
                    if ($state.Mailbox.PSObject.Properties['ForwardingAddress']) {
                        $currentAddress = [string]$state.Mailbox.ForwardingAddress
                    }
                }

                if ($currentSmtp -ieq $trustee -or ($currentAddress -and $currentAddress -ieq $trustee)) {
                    $status = 'Skipped'; $detail = "Forwarding to $trustee is already configured."
                }
                elseif (-not $PSCmdlet.ShouldProcess($mailbox, "Forward to $trustee")) {
                    if ($isDryRun) { $detail = "Would forward to $trustee." }
                    else { $status = 'Skipped'; $detail = $declinedDetail }
                }
                else {
                    # ForwardingSmtpAddress covers both cases: it accepts an internal address too,
                    # and using it avoids a recipient lookup that can fail mid-cutover.
                    Set-MailboxForwarding -Mailbox $mailbox -ForwardingSmtpAddress $trustee `
                        -DeliverToMailboxAndForward $deliverAndForward
                    $detail = "Forwarding to $trustee (DeliverToMailboxAndForward $deliverAndForward)."
                }
            }
            else {
                $identifiers = [System.Collections.Generic.List[string]]::new()
                $identifiers.Add($trustee)
                $trusteeRow = @($allPlanRows | Where-Object {
                    (Get-MigrationCsvValue -Row $_ -Name 'SourcePrimarySmtp' -Default '') -ieq $item.SourceTrustee -or
                    (Get-MigrationCsvValue -Row $_ -Name 'SourceUserPrincipalName' -Default '') -ieq $item.SourceTrustee
                }) | Select-Object -First 1
                if ($trusteeRow) {
                    $displayName = ([string](Get-MigrationCsvValue -Row $trusteeRow -Name 'DisplayName' -Default '')).Trim()
                    if ($displayName) { $identifiers.Add($displayName) }
                }

                $existing = @($state[$item.Kind])
                $diff = Get-PermissionDiff -Existing $existing -TrusteeIdentifier $identifiers.ToArray() `
                    -Kind $item.Kind -AccessRights $item.AccessRights

                if ($diff.Action -eq 'Skip') {
                    $status = 'Skipped'; $detail = $diff.Detail
                }
                elseif (-not $PSCmdlet.ShouldProcess($mailbox, "Grant $($item.Kind) to $trustee")) {
                    if ($isDryRun) { $detail = "Would grant $($item.Kind) to $trustee." }
                    else { $status = 'Skipped'; $detail = $declinedDetail }
                }
                elseif ($item.Kind -eq 'Calendar') {
                    if ([string]::IsNullOrWhiteSpace($item.AccessRights)) {
                        $status = 'Skipped'; $detail = 'The permission row has no calendar access rights.'
                    }
                    else {
                        Set-MailboxCalendarPermission -Mailbox $mailbox -Trustee $trustee `
                            -AccessRights $item.AccessRights -Mode $diff.Action
                        $detail = "$($diff.Action) calendar permission $($item.AccessRights) for $trustee. $($diff.Detail)"
                    }
                }
                else {
                    $autoMapping = $AutoMapping
                    if ($item.AutoMapping -ieq 'False') { $autoMapping = $false }
                    Add-MailboxAccessRight -Mailbox $mailbox -Trustee $trustee -Kind $item.Kind -AutoMapping $autoMapping
                    $detail = "Granted $($item.Kind) to $trustee."
                }
            }
        }
        catch {
            $status = 'Failed'
            $detail = $_.Exception.Message
        }

        if ($status -eq 'Failed') { $exitCode = 2 }

        $results.Add((New-PermissionResult -Identity $mailbox -Action $item.Kind -Status $status -Detail $detail `
            -SourceMailbox $item.SourceMailbox -SourceTrustee $item.SourceTrustee -Trustee $trustee `
            -AccessRights $item.AccessRights))
    }

    Write-Progress -Activity 'Re-applying mailbox permissions' -Completed
    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Set-MailboxPermissions'
}
catch {
    Write-MigrationLog -Message "Fatal error: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message $_.ScriptStackTrace -Level DEBUG
    if ($results.Count -gt 0) {
        try {
            $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Set-MailboxPermissions'
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

# The Exchange session is intentionally left open: cutover runs are a chain of scripts and
# re-authenticating between each one is the slowest part of the evening.
exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion --------------------------------------------------------------------------------------
