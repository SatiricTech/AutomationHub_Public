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

function Split-AddressEntry {
    <#
    .SYNOPSIS
        Splits a proxy address into its prefix and address, and classifies it.

    .DESCRIPTION
        Exchange stores proxy addresses as '<prefix>:<value>'. Case matters for SMTP - an uppercase
        'SMTP:' marks the primary and a lowercase 'smtp:' marks an alias - so the prefix is compared
        case-sensitively for that one decision and case-insensitively everywhere else. An entry with
        no prefix at all is treated as a plain SMTP alias, which is how operators usually type them.

    .PARAMETER Entry
        A single proxy address, e.g. 'SMTP:john.smith@contoso.com' or 'X500:/o=ExchangeLabs/...'.

    .EXAMPLE
        Split-AddressEntry -Entry 'SMTP:john.smith@contoso.com'

        Returns Prefix 'SMTP', Address 'john.smith@contoso.com', Kind 'Smtp', IsPrimary true.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Entry
    )

    $text = ([string]$Entry).Trim()
    $prefix = ''
    $address = $text

    $separator = $text.IndexOf(':')
    if ($separator -gt 0) {
        $prefix = $text.Substring(0, $separator)
        $address = $text.Substring($separator + 1)
    }

    $kind = switch -Regex ($prefix) {
        '^$'      { 'Smtp' }
        '^smtp$'  { 'Smtp' }
        '^sip$'   { 'Sip' }
        '^x500$'  { 'X500' }
        '^spo$'   { 'Spo' }
        default   { 'Other' }
    }

    [pscustomobject]@{
        Entry     = $text
        Prefix    = $prefix
        Address   = $address
        Kind      = $kind
        IsPrimary = ($kind -eq 'Smtp' -and $prefix -ceq 'SMTP')
    }
}

function Test-ProtectedAddress {
    <#
    .SYNOPSIS
        Reports whether an address must never be removed from an object.

    .DESCRIPTION
        Three classes of address are load-bearing after a tenant move and are protected here rather
        than at each call site, so no future edit can forget one:
          - the tenant routing address (MOERA, *.onmicrosoft.com), which Exchange uses internally;
          - SIP addresses, which Teams and Skype sign-in are keyed to;
          - X500 addresses, which are the whole reason cached Outlook entries and old replies still
            resolve after a cross-tenant move.

    .PARAMETER AddressEntry
        An object produced by Split-AddressEntry.

    .EXAMPLE
        Test-ProtectedAddress -AddressEntry (Split-AddressEntry -Entry 'smtp:john@contoso.mail.onmicrosoft.com')

        Returns $true - the tenant routing address is never removed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $AddressEntry
    )

    if ($AddressEntry.Kind -in @('Sip', 'X500', 'Spo', 'Other')) { return $true }
    if ($AddressEntry.Address -match '(?i)\.onmicrosoft\.com$') { return $true }
    return $false
}

function Get-AddressChangeSet {
    <#
    .SYNOPSIS
        Computes the EmailAddresses add/remove set for one object from its current addresses and
        the plan's targets.

    .DESCRIPTION
        Pure function - no tenant calls, which is what makes the risky part of this script testable
        offline. It returns three ordered buckets because the order matters to Exchange:

          RemoveBeforeAdd  A lowercase 'smtp:' entry that already holds the address we are about to
                           promote. Exchange rejects an add of an address the object already has, so
                           the alias is released first and re-added as the uppercase primary.
          Add              'SMTP:' primary, then 'smtp:' aliases, then 'X500:' entries.
          RemoveAfterAdd   The demoted old primary, only with -RemoveOldPrimaryAlias, and never when
                           it is a protected address. It cannot be removed before the add because an
                           object may not be left without a primary.

        Nothing else is ever removed. Aliases present on the object but absent from the plan are
        left alone: this script's job is to add the new identity, not to prune whatever the previous
        administrator had good reason to leave behind.

    .PARAMETER CurrentAddress
        The object's current EmailAddresses / proxyAddresses values.

    .PARAMETER TargetPrimarySmtp
        The plan's TargetPrimarySmtp. Ignored when 'PrimarySmtp' is not in -Apply.

    .PARAMETER TargetAlias
        The plan's TargetAliases entries, with or without an 'smtp:' prefix.

    .PARAMETER TargetX500
        X500 values, with or without an 'X500:' prefix. Usually the source LegacyExchangeDN.

    .PARAMETER Apply
        Which of PrimarySmtp, Aliases and X500 to include in the change set.

    .PARAMETER RemoveOldPrimaryAlias
        Remove the demoted old primary rather than keeping it as an alias.

    .EXAMPLE
        Get-AddressChangeSet -CurrentAddress @('SMTP:jsmith@contoso.com','smtp:j@contoso.mail.onmicrosoft.com') `
            -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp

        Returns Add = @('SMTP:john.smith@newco.com') and no removals - the old primary is demoted by
        Exchange and the routing address is protected.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$CurrentAddress = @(),

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$TargetPrimarySmtp = '',

        [Parameter(Mandatory = $false)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$TargetAlias = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$TargetX500 = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Apply = @('PrimarySmtp', 'Aliases', 'X500'),

        [Parameter(Mandatory = $false)]
        [switch]$RemoveOldPrimaryAlias
    )

    $apply = @($Apply | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $entries = @(@($CurrentAddress) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Split-AddressEntry -Entry $_ })

    $currentPrimaryEntry = @($entries | Where-Object { $_.IsPrimary }) | Select-Object -First 1
    $currentPrimary = if ($currentPrimaryEntry) { $currentPrimaryEntry.Address } else { '' }

    $removeBefore = [System.Collections.Generic.List[string]]::new()
    $add = [System.Collections.Generic.List[string]]::new()
    $removeAfter = [System.Collections.Generic.List[string]]::new()
    $aliasAdded = [System.Collections.Generic.List[string]]::new()
    $x500Added = [System.Collections.Generic.List[string]]::new()

    $newPrimary = ''
    $primaryDetail = ''

    if ($apply -contains 'PrimarySmtp') {
        $wanted = ([string]$TargetPrimarySmtp).Trim() -replace '^(?i)smtp:', ''
        if ([string]::IsNullOrWhiteSpace($wanted)) {
            $primaryDetail = 'The plan row has no TargetPrimarySmtp.'
        }
        elseif ($wanted -ieq $currentPrimary) {
            $primaryDetail = "Primary SMTP is already $currentPrimary."
        }
        else {
            $held = @($entries | Where-Object { $_.Kind -eq 'Smtp' -and -not $_.IsPrimary -and $_.Address -ieq $wanted }) |
                Select-Object -First 1
            if ($held) {
                # Exchange will not add an address the object already carries, so the alias form is
                # released in a separate call and immediately re-added as the uppercase primary.
                $removeBefore.Add("smtp:$($held.Address)")
            }

            $add.Add("SMTP:$wanted")
            $newPrimary = $wanted
            $primaryDetail = "Primary SMTP set to $wanted."

            if ($RemoveOldPrimaryAlias -and $currentPrimaryEntry) {
                if (Test-ProtectedAddress -AddressEntry $currentPrimaryEntry) {
                    $primaryDetail += " Kept $currentPrimary - protected address."
                }
                else {
                    $removeAfter.Add("smtp:$currentPrimary")
                    $primaryDetail += " Removed the demoted $currentPrimary."
                }
            }
        }
    }

    $effectivePrimary = if ($newPrimary) { $newPrimary } else { $currentPrimary }

    if ($apply -contains 'Aliases') {
        foreach ($candidate in @($TargetAlias)) {
            $alias = ([string]$candidate).Trim() -replace '^(?i)smtp:', ''
            if ([string]::IsNullOrWhiteSpace($alias)) { continue }
            if ($alias -ieq $effectivePrimary) { continue }
            if (@($entries | Where-Object { $_.Kind -eq 'Smtp' -and $_.Address -ieq $alias }).Count -gt 0) { continue }
            if (@($add | Where-Object { $_ -imatch '^smtp:' -and ($_ -replace '^(?i)smtp:', '') -ieq $alias }).Count -gt 0) { continue }

            $add.Add("smtp:$alias")
            $aliasAdded.Add($alias)
        }
    }

    if ($apply -contains 'X500') {
        foreach ($candidate in @($TargetX500)) {
            $dn = ([string]$candidate).Trim() -replace '^(?i)x500:', ''
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }
            if (@($entries | Where-Object { $_.Kind -eq 'X500' -and $_.Address -ieq $dn }).Count -gt 0) { continue }
            if (@($x500Added | Where-Object { $_ -ieq $dn }).Count -gt 0) { continue }

            $add.Add("X500:$dn")
            $x500Added.Add($dn)
        }
    }

    [pscustomobject]@{
        CurrentPrimary  = $currentPrimary
        NewPrimary      = $newPrimary
        PrimaryChanged  = [bool]$newPrimary
        PrimaryDetail   = $primaryDetail
        RemoveBeforeAdd = $removeBefore.ToArray()
        Add             = $add.ToArray()
        RemoveAfterAdd  = $removeAfter.ToArray()
        AliasAdded      = $aliasAdded.ToArray()
        X500Added       = $x500Added.ToArray()
    }
}

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

    .PARAMETER Row
        A plan row.

    .PARAMETER Strategy
        TargetObjectId, Interim or Source. Empty means auto.

    .EXAMPLE
        Resolve-IdentityMatch -Row $row -Strategy 'Source'

        Returns the row's SourceUserPrincipalName as the identity, matched by 'Source'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Row,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Strategy = ''
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
        promoted to an X500 address. Duplicates are collapsed case-insensitively.

    .PARAMETER Row
        A plan row.

    .EXAMPLE
        Get-PlanX500 -Row $row

        Returns @('/o=ExchangeLabs/ou=.../cn=Recipients/cn=...') for a row that only has a
        LegacyExchangeDN.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Row
    )

    $values = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in (Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'SourceX500' -Default ''))) {
        $dn = ([string]$entry).Trim() -replace '^(?i)x500:', ''
        if ($dn -and -not ($values | Where-Object { $_ -ieq $dn })) { $values.Add($dn) }
    }

    $legacyDn = ([string](Get-MigrationCsvValue -Row $Row -Name 'LegacyExchangeDN' -Default '')).Trim()
    $legacyDn = $legacyDn -replace '^(?i)x500:', ''
    if ($legacyDn -and -not ($values | Where-Object { $_ -ieq $legacyDn })) { $values.Add($legacyDn) }

    return [string[]]$values.ToArray()
}

function Get-RowBlock {
    <#
    .SYNOPSIS
        Decides whether a whole plan row is disqualified before any operation is attempted.

    .DESCRIPTION
        Four things stop a row dead, and they are collected here so the ordering is explicit and can
        be proved offline rather than being buried in the per-row loop:

          PlanStatus     the planning phase has not signed the row off;
          ObjectType     the object is a group or contact, which New-MigrationRecipients owns;
          MatchDetail    no plan column identified the object in this tenant;
          IsSynced       the object is directory-synced.

        The last two are Failed rather than Skipped. A row nobody can locate, and a row whose
        attributes Entra ID and Exchange Online will both refuse to write, are unfinished work - and
        a migration that quietly leaves users behind is worse than one that stops and says so.

        Pure function - no tenant calls.

    .PARAMETER PlanStatus
        The row's PlanStatus.

    .PARAMETER ObjectType
        The row's ObjectType.

    .PARAMETER ActionableStatus
        The statuses this run is willing to act on.

    .PARAMETER SupportedObjectType
        The object types this script handles.

    .PARAMETER MatchDetail
        The reason Resolve-IdentityMatch gave for finding no identity, or an empty string.

    .PARAMETER IsSynced
        The object's onPremisesSyncEnabled value, once it is known.

    .EXAMPLE
        Get-RowBlock -PlanStatus Planned -ObjectType User -ActionableStatus Planned `
            -SupportedObjectType User -IsSynced $true

        Returns IsBlocked $true with Status 'Failed' and the directory-sync explanation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PlanStatus,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ObjectType,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ActionableStatus,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$SupportedObjectType,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$MatchDetail = '',
        [Parameter(Mandatory = $false)][bool]$IsSynced = $false
    )

    $blocked = { param([string]$Status, [string]$Detail)
        [pscustomobject]@{ IsBlocked = $true; Status = $Status; Detail = $Detail } }

    if ($ActionableStatus -notcontains $PlanStatus) {
        return & $blocked 'Skipped' ("PlanStatus is '$PlanStatus' - this script only acts on " +
            "$($ActionableStatus -join ', ').")
    }

    if ($SupportedObjectType -notcontains $ObjectType) {
        return & $blocked 'Skipped' ("ObjectType '$ObjectType' is not a mailbox object - groups and " +
            'contacts are handled by New-MigrationRecipients.')
    }

    if (-not [string]::IsNullOrWhiteSpace($MatchDetail)) {
        return & $blocked 'Failed' $MatchDetail
    }

    if ($IsSynced) {
        return & $blocked 'Failed' ('Object is directory-synced (onPremisesSyncEnabled). ' +
            'UserPrincipalName and proxyAddresses must be changed on-premises and allowed to sync - ' +
            'Entra ID and Exchange Online both reject the write.')
    }

    [pscustomobject]@{ IsBlocked = $false; Status = ''; Detail = '' }
}

function New-IdentityResult {
    <#
    .SYNOPSIS
        Builds one result row for the (Identity, Action) pair.

    .DESCRIPTION
        Every operation the script considers produces exactly one row, whether it ran, was skipped
        or failed, so the results file is a complete record of what was asked of each object rather
        than only of what changed.

    .PARAMETER Identity
        The identity the script used to address the object.

    .PARAMETER Action
        Upn, PrimarySmtp, Aliases, X500, MailNickname or GalVisibility.

    .PARAMETER Status
        Planned, Succeeded, Skipped or Failed.

    .PARAMETER Detail
        Human-readable outcome.

    .PARAMETER Row
        The plan row, used for the ObjectType and Wave columns.

    .PARAMETER MatchedBy
        Which plan column produced the identity.

    .PARAMETER ObjectId
        The destination object id, when it is known.

    .PARAMETER CurrentValue
        The value found on the object before the change.

    .PARAMETER TargetValue
        The value the plan asked for.

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

    .PARAMETER Identity
        The mailbox to change.

    .PARAMETER Address
        The proxy address entries to add or remove, prefix included.

    .PARAMETER Operation
        Add or Remove.

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

    .PARAMETER Identity
        The mailbox to change.

    .PARAMETER Name
        Alias, HiddenFromAddressListsEnabled or EmailAddressPolicyEnabled.

    .PARAMETER Value
        The value to set.

    .PARAMETER Description
        The text logged for the action.

    .EXAMPLE
        Set-MailboxAttribute -Identity 'john@newco.com' -Name Alias -Value 'john.smith' -Description 'Set alias'

        Sets the mail nickname on the destination mailbox.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller gates the row with ShouldProcess and Invoke-MigrationAction honours -DryRun.')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Alias', 'HiddenFromAddressListsEnabled', 'EmailAddressPolicyEnabled')]
        [string]$Name,
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

    .PARAMETER ErrorRecord
        The ErrorRecord caught around the PATCH.

    .PARAMETER PrivilegedHint
        Text to append for a 403.

    .PARAMETER ConflictHint
        Text to append for a 409.

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

    $actionableStatuses = @('Planned', 'ManualOverride', 'UpnSmtpDiverge')
    if ($IncludeCollisions) { $actionableStatuses += 'Collision' }

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
        $objectType = Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default ''
        $planStatus = Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default ''
        $match = Resolve-IdentityMatch -Row $row -Strategy $MatchOn
        $label = if ($match.Identity) { $match.Identity } else { Get-MigrationCsvValue -Row $row -Name 'DisplayName' -Default "row $index" }

        Write-Progress -Activity 'Applying identity changes' -Status "$index of $($planRows.Count): $label" `
            -PercentComplete (($index / [Math]::Max($planRows.Count, 1)) * 100)

        # A whole-object verdict still emits one row per requested action, so the CSV can be pivoted
        # on Action without some objects mysteriously missing from a column.
        $block = Get-RowBlock -PlanStatus $planStatus -ObjectType $objectType `
            -ActionableStatus $actionableStatuses -SupportedObjectType $supportedObjectTypes `
            -MatchDetail $match.Detail

        if ($block.IsBlocked) {
            foreach ($action in $requestedActions) {
                $results.Add((New-IdentityResult -Identity $label -Action $action -Status $block.Status `
                    -Detail $block.Detail -Row $row -MatchedBy $match.MatchedBy))
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
        $syncBlock = Get-RowBlock -PlanStatus $planStatus -ObjectType $objectType `
            -ActionableStatus $actionableStatuses -SupportedObjectType $supportedObjectTypes -IsSynced $isSynced

        if ($syncBlock.IsBlocked) {
            foreach ($action in $requestedActions) {
                $results.Add((New-IdentityResult -Identity $identity -Action $action -Status $syncBlock.Status `
                    -Detail $syncBlock.Detail -Row $row -MatchedBy $match.MatchedBy -ObjectId $objectId))
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
            $changeSet = Get-AddressChangeSet -CurrentAddress @($mailbox.EmailAddresses) `
                -TargetPrimarySmtp (Get-MigrationCsvValue -Row $row -Name 'TargetPrimarySmtp' -Default '') `
                -TargetAlias (Split-MigrationList -Value (Get-MigrationCsvValue -Row $row -Name 'TargetAliases' -Default '')) `
                -TargetX500 (Get-PlanX500 -Row $row) `
                -Apply $addressActionsRequested `
                -RemoveOldPrimaryAlias:$RemoveOldPrimaryAlias
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
