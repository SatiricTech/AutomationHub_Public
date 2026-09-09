#Requires -Version 7.4

<#
.SYNOPSIS
    Releases a vanity domain in the SOURCE tenant by clearing every object that still references it.

.DESCRIPTION
    Phase 4 of the toolkit, and the only script that runs against the tenant being left behind. A
    custom domain cannot be removed from a tenant - and so cannot be verified in the destination -
    while any directory object still carries an address on it.

    Pass 1 enumerates and reports: every reference to a References CSV and every unresolvable one to
    a Blockers CSV, before a single change is made, even in a real run.

    Pass 2 remediates, but only when the run is not -ReportOnly and not -DryRun AND
    -AcknowledgeSourceTenant was supplied. The connected tenant is logged prominently first, because
    the failure that matters here is running a destructive cleanup against the destination tenant by
    mistake. Users have their userPrincipalName PATCHed onto the fallback domain; recipients get an
    onmicrosoft address promoted to primary (after disabling the email address policy where the type
    supports it) and then every @Domain proxy address removed.

    Reported as blockers rather than touched: directory-synced objects, soft-deleted users still
    holding the domain, guests carrying an address on it, and any reference Graph cannot map to a
    supported object. A guest whose #EXT# UPN merely embeds the domain in its generated local part is
    informational - Entra owns that form and rewriting it would break the guest.

    After remediation the domain is re-enumerated. The script exits 2 when blockers remain or any row
    failed, so a pipeline can tell "domain is clear" from "domain still has references".

.PARAMETER Domain
    The vanity domain being released, for example contoso.com. Must be a custom domain on the
    connected tenant; the initial .onmicrosoft.com domain can never be removed and is rejected.

.PARAMETER FallbackDomain
    The domain UPNs and promoted primary addresses move to. Defaults to the tenant's initial
    .onmicrosoft.com domain.

.PARAMETER TenantId
    The tenant to sign in to for Microsoft Graph. Recommended whenever the operator has access to
    more than one tenant, which during a migration is always.

.PARAMETER DelegatedOrganization
    The customer tenant for GDAP delegated Exchange Online access.

.PARAMETER Scope
    Limits which object classes are remediated: Users, Groups, Contacts, Mailboxes (default: all
    four). Objects outside the scope are still enumerated and still reported as blockers - they
    block the domain removal either way - they are simply not modified.

.PARAMETER AcknowledgeSourceTenant
    Required for any change. Without it the script runs as a report, so that "I meant to run this
    against the other tenant" costs a report rather than a rebuild.

.PARAMETER ReportOnly
    Enumerates and reports without changing anything. Identical in effect to -DryRun; it exists
    because "report" is what an operator asks for at this stage of a cutover.

.PARAMETER OutputPath
    Overrides the output root for the log, the reports and the results CSV.

.PARAMETER Prefix
    Names the client or run. Output lands in <root>\<Prefix>\ and filenames start with '<Prefix>_'.

.PARAMETER LogPath
    Overrides the derived log file path.

.PARAMETER DryRun
    Connects, enumerates and computes every change, writes the reports and a results file whose rows
    are all Planned, and mutates nothing.

.PARAMETER Verbosity
    Console output level: Low, Medium (default) or High. The log file always receives everything.

.EXAMPLE
    .\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -ReportOnly -Prefix Contoso

    Produces the References and Blockers CSVs and changes nothing. Run this first: it says how much
    of the domain release is automatable before you commit to it.

.EXAMPLE
    .\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -TenantId fabrikam.onmicrosoft.com -DryRun

    Full rehearsal against the named tenant, logging every computed change with a [DRYRUN] prefix.

.EXAMPLE
    .\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -AcknowledgeSourceTenant -Scope Users,Mailboxes

    Moves user UPNs and mailbox addresses off contoso.com, reporting groups and contacts still on the
    domain as blockers so nothing is silently missed.

.EXAMPLE
    .\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -FallbackDomain newco.onmicrosoft.com `
        -DelegatedOrganization contoso.onmicrosoft.com -AcknowledgeSourceTenant -Verbosity High

    A GDAP run against a customer tenant with an explicit fallback domain.

.NOTES
    Author: AutomationHub
    Written with assistance from Claude (Anthropic).

    Graph scopes: Domain.Read.All (the domain and its domainNameReferences), User.ReadWrite.All
    (users, soft-deleted users, PATCH userPrincipalName), Directory.Read.All.

    EXO roles: Recipient Management (Exchange Administrator covers it); the Set-UnifiedGroup path
    also needs Groups management rights. Changing an administrator's UPN needs Privileged
    Authentication Administrator; a 403 there is reported with that hint, not as a generic failure.

    GDAP: supported. -DelegatedOrganization goes to Connect-ExchangeOnline and -TenantId to
    Connect-MgGraph. Certificate app-only auth cannot be combined with -DelegatedOrganization.

    Hybrid tenants: Exchange Online refuses EmailAddresses edits on directory-synced recipients
    ("out of the current user's write scope"). Those are reported as blockers - fix proxyAddresses
    on-premises and let Entra Connect sync the change.

    Exit codes: 0 clear, 1 fatal, 2 completed with blockers remaining or rows failed.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?i)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')]
    [string]$Domain,

    [ValidatePattern('^(?i)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')]
    [string]$FallbackDomain,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$TenantId,

    [Alias('Tenant')]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$DelegatedOrganization,

    [ValidateSet('Users', 'Groups', 'Contacts', 'Mailboxes')]
    [string[]]$Scope = @('Users', 'Groups', 'Contacts', 'Mailboxes'),

    [switch]$AcknowledgeSourceTenant,

    [switch]$ReportOnly,

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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Configuration

$requiredGraphScopes = @(
    'Domain.Read.All'
    'User.ReadWrite.All'
    'Directory.Read.All'
)

# Graph page size for the directory enumerations. 999 is the documented maximum for /users.
$graphPageSize = 999

#endregion Configuration

#region Functions

function ConvertTo-DomainReferenceRecord {
    <#
        The canonical record every later stage reads. Enumeration pulls from three shapes - Graph
        users, Exchange recipients and Graph deleted items - and the classifier has to treat them
        identically, so one factory defines the schema. An unknown property name throws rather than
        being absorbed: a typo in a fixture that produced a record the classifier then read as "no
        addresses" would be a test passing for the wrong reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Properties
    )

    $record = [ordered]@{
        Kind                      = ''
        Source                    = ''
        ObjectId                  = ''
        Identity                  = ''
        DisplayName               = ''
        ObjectType                = ''
        RecipientTypeDetails      = ''
        UserPrincipalName         = ''
        PrimarySmtpAddress        = ''
        ExternalEmailAddress      = ''
        Addresses                 = @()
        IsSynced                  = $false
        SyncStateKnown            = $true
        IsGuest                   = $false
        EmailAddressPolicyEnabled = $true
        ReferenceKinds            = @()
    }

    foreach ($key in $Properties.Keys) {
        if (-not $record.Contains($key)) {
            throw "Unknown domain reference property '$key'. Valid names: $($record.Keys -join ', ')."
        }
        $record[$key] = $Properties[$key]
    }

    return [pscustomobject]$record
}

function Split-AddressEntry {
    <#
        Split-MigrationProxyAddress plus the two things this script decides on: the domain of the
        address, and a lowercase type. A prefix the recipient model does not define is not a type -
        the whole entry is treated as a bare SMTP address, which is how operators type them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Entry
    )

    $parsed = Split-MigrationProxyAddress -Entry ([string]$Entry)
    $isKnown = $parsed.Prefix -match '^(?i)(smtp|sip|spo|x500|x400|eum|eai|mailto)$'
    $address = if ($isKnown) { $parsed.Address } else { $parsed.Entry }
    $at = $address.LastIndexOf('@')

    [pscustomobject]@{
        Entry     = [string]$Entry
        Prefix    = if ($isKnown) { $parsed.Prefix } else { '' }
        # Only SMTP uses case to mark the primary; a bare address is assumed to be an alias.
        Type      = if ($isKnown) { $parsed.Prefix.ToLowerInvariant() } else { 'smtp' }
        IsPrimary = $parsed.IsPrimary
        Address   = $address
        Domain    = if ($at -ge 0 -and $at -lt ($address.Length - 1)) {
            $address.Substring($at + 1).ToLowerInvariant()
        }
        else { '' }
    }
}

function ConvertTo-FallbackUpn {
    <#
        Rewrites a UPN onto the fallback domain, keeping the local part verbatim: this script
        releases a domain, it does not redesign identity - renaming belongs to Set-MigrationIdentity,
        where the plan says what the new name should be. Guest #EXT# UPNs return an empty string,
        which the caller turns into a blocker: Entra owns that form and rewriting it breaks the guest.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FallbackDomain
    )

    if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) { return '' }

    $value = $UserPrincipalName.Trim()
    $at = $value.LastIndexOf('@')
    if ($at -lt 1) { return '' }

    $local = $value.Substring(0, $at)
    if ($local -match '(?i)#ext#$') { return '' }

    return ('{0}@{1}' -f $local, $FallbackDomain).ToLowerInvariant()
}

function Resolve-RecipientCmdlet {
    <#
        Maps an Exchange recipient type to the Set-* cmdlet that edits its addresses and says whether
        that cmdlet exposes -EmailAddressPolicyEnabled. Address edits are not one cmdlet, and binding
        a parameter the cmdlet does not have fails halfway through a cutover, so the mapping is data
        and unit tested rather than a chain of if statements at the call site.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecipientTypeDetails
    )

    # Contacts are not subject to email address policies, and Set-UnifiedGroup exposes no toggle.
    $map = @{
        'UserMailbox'                    = @('Set-Mailbox', $true)
        'SharedMailbox'                  = @('Set-Mailbox', $true)
        'RoomMailbox'                    = @('Set-Mailbox', $true)
        'EquipmentMailbox'               = @('Set-Mailbox', $true)
        'SchedulingMailbox'              = @('Set-Mailbox', $true)
        'TeamMailbox'                    = @('Set-Mailbox', $true)
        'LinkedMailbox'                  = @('Set-Mailbox', $true)
        'DiscoveryMailbox'               = @('Set-Mailbox', $true)
        'MailUser'                       = @('Set-MailUser', $true)
        'GuestMailUser'                  = @('Set-MailUser', $true)
        'MailContact'                    = @('Set-MailContact', $false)
        'MailUniversalDistributionGroup' = @('Set-DistributionGroup', $true)
        'MailUniversalSecurityGroup'     = @('Set-DistributionGroup', $true)
        'MailNonUniversalGroup'          = @('Set-DistributionGroup', $true)
        'RoomList'                       = @('Set-DistributionGroup', $true)
        'DynamicDistributionGroup'       = @('Set-DynamicDistributionGroup', $true)
        'GroupMailbox'                   = @('Set-UnifiedGroup', $false)
    }

    $entry = $map[([string]$RecipientTypeDetails).Trim()]

    [pscustomobject]@{
        RecipientTypeDetails = [string]$RecipientTypeDetails
        SetCmdlet            = if ($entry) { [string]$entry[0] } else { '' }
        SupportsPolicyToggle = [bool]($entry -and $entry[1])
        IsSupported          = [bool]$entry
    }
}

function Resolve-DomainReferenceScope {
    <# The -Scope token that governs a reference record, or '' when no token applies. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Reference
    )

    if ($Reference.Kind -in @('UserUpn', 'UserProxy', 'GuestReference', 'DeletedUser')) { return 'Users' }
    if ($Reference.Kind -ne 'RecipientAddress') { return '' }

    $type = ([string]$Reference.RecipientTypeDetails).Trim()
    $groups = @(
        'MailUniversalDistributionGroup', 'MailUniversalSecurityGroup', 'MailNonUniversalGroup'
        'RoomList', 'DynamicDistributionGroup', 'GroupMailbox'
    )

    if ($type -eq 'MailContact') { return 'Contacts' }
    if ($groups -contains $type) { return 'Groups' }
    return 'Mailboxes'
}

function Resolve-DomainAddressPlan {
    <#
        Works out offline exactly which address changes a recipient needs. The order is load-bearing:
        the email address policy has to be disabled before the primary changes or it can reassert the
        vanity address, the promotion has to precede the removal or Exchange refuses to remove the
        primary, and SMTP entries are removed by bare address because the promotion demotes the old
        primary to a lowercase alias, which makes a literal 'SMTP:...' removal miss.

        The plan is deliberately allowed to come back incomplete - nothing to promote, an unsupported
        recipient type, a contact whose external address is on the domain - so the caller reports a
        blocker instead of half-applying a change.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Reference,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Domain,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FallbackDomain
    )

    $domainLower = $Domain.ToLowerInvariant()
    $fallbackLower = $FallbackDomain.ToLowerInvariant()
    $cmdlet = Resolve-RecipientCmdlet -RecipientTypeDetails $Reference.RecipientTypeDetails

    $plan = [pscustomobject]@{
        Identity              = [string]$Reference.Identity
        SetCmdlet             = $cmdlet.SetCmdlet
        VanityAddresses       = @()
        RemoveAddresses       = @()
        PromoteAddress        = ''
        PrimaryIsVanity       = $false
        RequiresPolicyDisable = $false
        Steps                 = @()
        IsComplete            = $true
        Reason                = ''
    }

    if (-not $cmdlet.IsSupported) {
        $plan.IsComplete = $false
        $plan.Reason = "No Exchange Online cmdlet covers recipient type '$($Reference.RecipientTypeDetails)'."
        return $plan
    }

    $parsed = @(
        foreach ($entry in @($Reference.Addresses)) {
            $item = Split-AddressEntry -Entry ([string]$entry)
            if ($item.Address) { $item }
        }
    )

    $vanity = @($parsed | Where-Object { $_.Domain -eq $domainLower -and $_.Type -notin @('x500', 'x400') })
    $plan.VanityAddresses = @($vanity | ForEach-Object { $_.Entry })

    if ($vanity.Count -eq 0) {
        $plan.Reason = "No addresses on $Domain."
        return $plan
    }

    $primary = [string]$Reference.PrimarySmtpAddress
    $plan.PrimaryIsVanity = [bool](
        @($vanity | Where-Object { $_.IsPrimary }).Count -gt 0 -or
        ($primary -and $primary.ToLowerInvariant().EndsWith("@$domainLower"))
    )

    # A mail contact exists to point at an external address. If that address is on the domain being
    # released, promoting an onmicrosoft address would silently repoint mail at the wrong place.
    $external = [string]$Reference.ExternalEmailAddress
    if ($external -and (Split-AddressEntry -Entry $external).Domain -eq $domainLower) {
        $plan.IsComplete = $false
        $plan.Reason = "The external address is on $Domain; repoint or delete this contact by hand."
        return $plan
    }

    $steps = [System.Collections.Generic.List[string]]::new()

    if ($plan.PrimaryIsVanity) {
        # Prefer the fallback domain, then the initial onmicrosoft domain, then the mail routing
        # domain; anything else is a last resort.
        $rank = {
            param($item)
            if ($item.Domain -eq $fallbackLower) { return 0 }
            if ($item.Domain -like '*.mail.onmicrosoft.com') { return 2 }
            if ($item.Domain -like '*.onmicrosoft.com') { return 1 }
            return 3
        }

        $candidates = @(
            $parsed |
                Where-Object { $_.Type -eq 'smtp' -and $_.Domain -and $_.Domain -ne $domainLower } |
                Sort-Object -Property @{ Expression = { & $rank $_ } }, @{ Expression = { $_.Address } }
        )

        if ($candidates.Count -eq 0) {
            $plan.IsComplete = $false
            $plan.Reason = "The primary address is on $Domain and there is no other address to promote."
            return $plan
        }

        $plan.PromoteAddress = $candidates[0].Address
        if ($cmdlet.SupportsPolicyToggle -and $Reference.EmailAddressPolicyEnabled) {
            $plan.RequiresPolicyDisable = $true
            $steps.Add('DisableEmailAddressPolicy')
        }
        $steps.Add('PromotePrimary')
    }

    $plan.RemoveAddresses = @(
        $vanity | ForEach-Object {
            if ($_.Type -eq 'smtp') { $_.Address } else { '{0}:{1}' -f $_.Type, $_.Address }
        }
    )
    $steps.Add('RemoveAddresses')
    $plan.Steps = $steps.ToArray()

    return $plan
}

function Resolve-DomainReferenceClass {
    <#
        Decides whether a reference is fixable here, a blocker, or informational - the judgement the
        whole script turns on, so it is a pure function over a record and is tested without a tenant.

        Blocker means the domain cannot be removed until a human does something this script must not
        do on their behalf: change an object on-premises AD owns, deal with a soft-deleted user, or
        decide what a guest's identity should become. Informational means the reference is real but
        harmless - notably a guest whose #EXT# UPN embeds the domain in its generated local part.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Reference,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Domain,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FallbackDomain,

        [ValidateSet('Users', 'Groups', 'Contacts', 'Mailboxes')]
        [string[]]$Scope = @('Users', 'Groups', 'Contacts', 'Mailboxes'),

        [AllowNull()]
        [psobject]$AddressPlan
    )

    $result = [pscustomobject]@{
        Class                = 'Blocker'
        Reason               = 'UnknownReferenceKind'
        Detail               = "Reference kind '$($Reference.Kind)' is not one this script can act on."
        Action               = 'None'
        NewUserPrincipalName = ''
    }

    $set = {
        param([string]$Class, [string]$Reason, [string]$Detail, [string]$Action)
        $result.Class = $Class
        $result.Reason = $Reason
        $result.Detail = $Detail
        $result.Action = $Action
    }

    if ($Reference.Kind -eq 'DeletedUser') {
        & $set 'Blocker' 'SoftDeletedUser' ("A soft-deleted user still holds an address on $Domain. " +
            'Restore it and rerun, or permanently delete it from the Entra recycle bin.') 'None'
        return $result
    }

    $scopeToken = Resolve-DomainReferenceScope -Reference $Reference
    if ($scopeToken -and $Scope -notcontains $scopeToken) {
        & $set 'Blocker' 'OutOfScope' ("Still references $Domain but -Scope does not include $scopeToken. " +
            'Rerun including that scope, or clear the object by hand.') 'None'
        return $result
    }

    # A degraded recipient scan could not read IsDirSynced, so IsSynced here means "not known",
    # not "not synced". Treating that as fixable would rewrite addresses on an object Exchange
    # Online is read-only for and report success for writes the tenant rejected.
    if (-not $Reference.SyncStateKnown) {
        & $set 'Blocker' 'SyncStateUnknown' `
            'Sync state unknown (property set unavailable); verify manually' 'None'
        return $result
    }

    if ($Reference.IsSynced) {
        & $set 'Blocker' 'DirectorySynced' ('Directory-synced object: Entra and Exchange Online are ' +
            'read-only for it. Change the on-premises userPrincipalName or proxyAddresses and let ' +
            'Entra Connect sync the change.') 'None'
        return $result
    }

    switch ($Reference.Kind) {
        'GuestReference' {
            if (@($Reference.ReferenceKinds) -contains 'Address') {
                & $set 'Blocker' 'GuestDomainAddress' ("This guest carries an address on $Domain. " +
                    'Remove or re-invite the guest; its #EXT# UPN must never be rewritten.') 'None'
            }
            else {
                & $set 'Informational' 'GuestExternalUpn' ('The domain only appears inside the ' +
                    'generated #EXT# local part. Entra owns that form, it is not a domain name ' +
                    'reference, and it does not block the removal.') 'None'
            }
        }
        'UserUpn' {
            $newUpn = ConvertTo-FallbackUpn -UserPrincipalName $Reference.UserPrincipalName `
                -FallbackDomain $FallbackDomain
            if ([string]::IsNullOrWhiteSpace($newUpn)) {
                & $set 'Blocker' 'InvalidTargetUpn' ("Could not derive a fallback UPN from " +
                    "'$($Reference.UserPrincipalName)'.") 'None'
                break
            }
            $validation = Test-MigrationAddress -Address $newUpn -Kind Upn
            if (-not $validation.IsValid) {
                & $set 'Blocker' 'InvalidTargetUpn' "'$newUpn' is not a valid UPN: $($validation.Reason)" 'None'
                break
            }
            if ($newUpn -eq ([string]$Reference.UserPrincipalName).ToLowerInvariant()) {
                & $set 'Informational' 'AlreadyOffDomain' 'The UPN is already on the fallback domain.' 'None'
                break
            }
            $result.NewUserPrincipalName = $newUpn
            & $set 'Fixable' 'UpnOnDomain' "UPN moves to $newUpn." 'SetUpn'
        }
        'UserProxy' {
            & $set 'Blocker' 'ProxyAddressWithoutRecipient' ("The user holds an address on $Domain but " +
                'is not an Exchange Online recipient, so there is no supported way to edit ' +
                'proxyAddresses. License the mailbox and rerun, or clear the address in Entra.') 'None'
        }
        'RecipientAddress' {
            if ($null -eq $AddressPlan) {
                & $set 'Blocker' 'NoAddressPlan' 'No address plan was computed for this recipient.' 'None'
                break
            }
            if (-not $AddressPlan.IsComplete) {
                & $set 'Blocker' 'AddressPlanIncomplete' $AddressPlan.Reason 'None'
                break
            }
            if (@($AddressPlan.Steps).Count -eq 0) {
                & $set 'Informational' 'NoDomainAddresses' $AddressPlan.Reason 'None'
                break
            }
            $detail = "Removes $(@($AddressPlan.RemoveAddresses).Count) address(es)"
            if ($AddressPlan.PromoteAddress) { $detail += "; promotes $($AddressPlan.PromoteAddress) to primary" }
            & $set 'Fixable' 'AddressesOnDomain' "$detail." 'UpdateAddresses'
        }
        'UnresolvedReference' {
            & $set 'Blocker' 'UnresolvedReference' ('Microsoft Graph reports this object as a domain ' +
                'name reference, but it is not a user, recipient or contact this script handles. ' +
                'Inspect it in the portal before removing the domain.') 'None'
        }
    }

    return $result
}

function Get-DomainReferenceErrorDetail {
    <#
        Three failures dominate this script and each has a specific remedy a raw exception message
        does not convey: a 403 on a UPN change means the caller lacks Privileged Authentication
        Administrator for a privileged target, a 409 means a soft-deleted object holds the target
        UPN, and Exchange's "write scope" refusal means the recipient is directory-synced.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Action
    )

    $text = [string]$Message

    if ($text -match '(?i)out of the current user''s write scope|isn''t within your current write scope') {
        return "$text -- the recipient is directory-synced; change proxyAddresses on-premises instead."
    }
    if ($Action -eq 'SetUpn' -and $text -match '(?i)\b403\b|Authorization_RequestDenied|Insufficient privileges') {
        return "$text -- changing the UPN of a privileged user needs Privileged Authentication Administrator."
    }
    if ($text -match '(?i)\b409\b|already exists|ObjectConflict') {
        return "$text -- a soft-deleted object may hold the target address; purge or restore it first."
    }

    return $text
}

function Repair-DomainReference {
    <#
        Applies the computed change for one reference and returns its result row. Every mutation the
        script makes happens here, wrapped in Invoke-MigrationAction and gated by ShouldProcess,
        which is what makes the DryRun promise checkable: in a dry run Invoke-MigrationAction never
        invokes the scriptblock, so nothing can reach Graph or Exchange whatever the plan says. Steps
        run in the order the plan lists them - see Resolve-DomainAddressPlan for why that matters.

        -AsPlanned labels the row Planned rather than Succeeded, for dry runs.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Reference,

        [Parameter(Mandatory)]
        [psobject]$Classification,

        [AllowNull()]
        [psobject]$AddressPlan,

        [switch]$AsPlanned
    )

    $identity = [string]$Reference.Identity
    $steps = if ($null -ne $AddressPlan) { @($AddressPlan.Steps) } else { @() }

    $row = [pscustomobject]@{
        Identity      = $identity
        Action        = [string]$Classification.Action
        Status        = if ($AsPlanned) { 'Planned' } else { 'Succeeded' }
        Detail        = [string]$Classification.Detail
        ObjectType    = [string]$Reference.ObjectType
        ObjectId      = [string]$Reference.ObjectId
        ReferenceKind = [string]$Reference.Kind
        Reason        = [string]$Classification.Reason
        Current       = ''
        Target        = ''
        Steps         = ($steps -join ';')
    }

    if (-not $PSCmdlet.ShouldProcess($identity, "$($Classification.Action) to release the domain")) {
        # -DryRun already produced a Planned row above and left it that way; a declined prompt in a
        # live run is a skip, because nothing was attempted.
        if (-not $AsPlanned) {
            $row.Status = 'Skipped'
            $row.Detail = 'Declined at the confirmation prompt.'
        }
        return $row
    }

    try {
        switch ([string]$Classification.Action) {
            'SetUpn' {
                $objectId = [string]$Reference.ObjectId
                $target = [string]$Classification.NewUserPrincipalName
                $row.Current = [string]$Reference.UserPrincipalName
                $row.Target = $target

                Invoke-MigrationAction -Description "Set UPN for $identity to $target" -Action {
                    $null = Invoke-MigrationGraphRequest -Method PATCH -Uri "/v1.0/users/$objectId" `
                        -Body @{ userPrincipalName = $target }
                }
            }
            'UpdateAddresses' {
                $setCmdlet = [string]$AddressPlan.SetCmdlet
                $objectId = [string]$Reference.ObjectId
                if ([string]::IsNullOrWhiteSpace($objectId)) { $objectId = $identity }
                $row.Current = (@($AddressPlan.VanityAddresses) -join ';')
                $row.Target = [string]$AddressPlan.PromoteAddress

                foreach ($step in $steps) {
                    switch ($step) {
                        'DisableEmailAddressPolicy' {
                            Invoke-MigrationAction -Description "Disable the email address policy on $identity" -Action {
                                & $setCmdlet -Identity $objectId -EmailAddressPolicyEnabled $false -ErrorAction Stop
                            }
                        }
                        'PromotePrimary' {
                            $promote = [string]$AddressPlan.PromoteAddress
                            Invoke-MigrationAction -Description "Promote $promote to primary on $identity" -Action {
                                & $setCmdlet -Identity $objectId -PrimarySmtpAddress $promote -ErrorAction Stop
                            }
                        }
                        'RemoveAddresses' {
                            $remove = @($AddressPlan.RemoveAddresses)
                            Invoke-MigrationAction -Description "Remove $($remove -join ', ') from $identity" -Action {
                                & $setCmdlet -Identity $objectId -EmailAddresses @{ remove = $remove } -ErrorAction Stop
                            }
                        }
                    }
                }
            }
            default {
                $row.Status = 'Skipped'
                $row.Detail = "No action is defined for '$($Classification.Action)'."
            }
        }
    }
    catch {
        $row.Status = 'Failed'
        $row.Detail = Get-DomainReferenceErrorDetail -Message $_.Exception.Message -Action $Classification.Action
    }

    return $row
}

function Get-DomainReferenceSet {
    <#
        Enumerates every object in the connected tenant that references the domain. Four passes,
        because no single source is complete:

          Exchange Online recipients - the only reliable source for proxy addresses, and the only
          place they can be edited. Filtered server-side on EmailAddresses.
          Graph users - UPNs on the domain, addresses Exchange does not know about, and guests. The
          advanced query (endsWith, ConsistencyLevel eventual, $count=true) keeps this off a full
          directory walk; if the tenant rejects it the full walk is still there as a fallback.
          Graph deleted items - soft-deleted users still holding the domain, which block the removal
          and cannot be fixed by editing anything live.
          domainNameReferences - Microsoft's own answer to "what is still using this domain".
          Anything it returns the first three passes did not explain becomes an UnresolvedReference,
          so the operator is never told the domain is clear when Graph disagrees.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Domain,

        [ValidateRange(1, 999)]
        [int]$PageSize = 999
    )

    $domainLower = $Domain.ToLowerInvariant()
    $suffix = "@$domainLower"
    $escaped = ConvertTo-MigrationODataString -Value $domainLower
    $records = [System.Collections.Generic.List[object]]::new()
    $exchangeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    Write-MigrationLog -Message "Enumerating Exchange Online recipients with an address on $Domain" -Level INFO
    $filter = "EmailAddresses -like '*@$escaped'"
    # The retry drops IsDirSynced and EmailAddressPolicyEnabled from the response, so the sync
    # state of every recipient it returns is unknown rather than false. The flag carries that fact
    # to the classifier instead of letting a missing property read as "not synced".
    $syncStateKnown = $true
    try {
        $recipients = @(Get-EXORecipient -Filter $filter -ResultSize Unlimited -Properties `
                EmailAddresses, ExternalEmailAddress, EmailAddressPolicyEnabled, IsDirSynced -ErrorAction Stop)
    }
    catch {
        Write-MigrationLog -Message ("Recipient scan with extended properties failed " +
            "($($_.Exception.Message)); retrying with the default property set. Sync state cannot be " +
            'read from that set, so every recipient it returns is reported as a blocker to verify ' +
            'by hand.') -Level WARNING
        $recipients = @(Get-EXORecipient -Filter $filter -ResultSize Unlimited -ErrorAction Stop)
        $syncStateKnown = $false
    }
    Write-MigrationLog -Message "Exchange Online returned $($recipients.Count) recipient(s)" -Level INFO

    foreach ($recipient in $recipients) {
        $objectId = [string](Get-MigrationProperty $recipient 'ExternalDirectoryObjectId' '')
        $identity = [string](Get-MigrationProperty $recipient 'PrimarySmtpAddress' '')
        if (-not $identity) { $identity = [string](Get-MigrationProperty $recipient 'Identity' '') }
        if ($objectId) { $null = $exchangeIds.Add($objectId) }

        $records.Add((ConvertTo-DomainReferenceRecord -Properties @{
                    Kind                      = 'RecipientAddress'
                    Source                    = 'ExchangeOnline'
                    ObjectId                  = $objectId
                    Identity                  = $identity
                    DisplayName               = [string](Get-MigrationProperty $recipient 'DisplayName' '')
                    ObjectType                = 'Recipient'
                    RecipientTypeDetails      = [string](Get-MigrationProperty $recipient 'RecipientTypeDetails' '')
                    PrimarySmtpAddress        = $identity
                    ExternalEmailAddress      = [string](Get-MigrationProperty $recipient 'ExternalEmailAddress' '')
                    Addresses                 = @(Get-MigrationProperty $recipient 'EmailAddresses' @())
                    IsSynced                  = [bool](Get-MigrationProperty $recipient 'IsDirSynced' $false)
                    SyncStateKnown            = $syncStateKnown
                    EmailAddressPolicyEnabled = [bool](Get-MigrationProperty $recipient 'EmailAddressPolicyEnabled' $true)
                    ReferenceKinds            = @('Address')
                }))
    }

    Write-MigrationLog -Message 'Enumerating Entra users that touch the domain' -Level INFO
    $select = 'id,displayName,userPrincipalName,mail,proxyAddresses,onPremisesSyncEnabled,userType'
    $userFilter = @(
        "endsWith(userPrincipalName,'@$escaped')"
        "endsWith(mail,'@$escaped')"
        "proxyAddresses/any(p:endsWith(p,'@$escaped'))"
        "otherMails/any(o:endsWith(o,'@$escaped'))"
    ) -join ' or '

    try {
        # endsWith on a directory property is an advanced query: it needs ConsistencyLevel eventual
        # and $count=true, and Graph rejects it without both.
        $users = @(Invoke-MigrationGraphRequest -Method GET -All -Headers @{ ConsistencyLevel = 'eventual' } -Uri (
                "/v1.0/users?`$select=$select&`$top=$PageSize&`$count=true&`$filter=" +
                [uri]::EscapeDataString($userFilter)))
    }
    catch {
        Write-MigrationLog -Message ("The advanced user query failed ($($_.Exception.Message)); " +
            'falling back to enumerating every user.') -Level WARNING
        $users = @(Invoke-MigrationGraphRequest -Method GET -All -Uri "/v1.0/users?`$select=$select&`$top=$PageSize")
    }
    Write-MigrationLog -Message "Graph returned $($users.Count) user(s)" -Level INFO

    foreach ($user in $users) {
        $upn = [string](Get-MigrationProperty $user 'userPrincipalName' '')
        $userId = [string](Get-MigrationProperty $user 'id' '')
        $proxies = @(Get-MigrationProperty $user 'proxyAddresses' @())
        $userType = [string](Get-MigrationProperty $user 'userType' '')
        $upnLower = $upn.ToLowerInvariant()
        $isGuest = ($userType -eq 'Guest') -or ($upnLower -match '(?i)#ext#@')

        $vanityProxies = @(
            foreach ($entry in $proxies) {
                if ((Split-AddressEntry -Entry ([string]$entry)).Domain -eq $domainLower) { [string]$entry }
            }
        )
        $upnOnDomain = $upnLower.EndsWith($suffix)
        $guestEmbeds = $isGuest -and ($upnLower -match ('(?i)' + [regex]::Escape($domainLower) + '#ext#@'))

        if (-not ($upnOnDomain -or $vanityProxies.Count -gt 0 -or $guestEmbeds)) { continue }

        $kinds = [System.Collections.Generic.List[string]]::new()
        if ($upnOnDomain) { $kinds.Add('Upn') }
        if ($vanityProxies.Count -gt 0) { $kinds.Add('Address') }
        if ($guestEmbeds) { $kinds.Add('GuestUpnEmbed') }

        $kind = if ($isGuest) { 'GuestReference' } elseif ($upnOnDomain) { 'UserUpn' } else { 'UserProxy' }

        # An address the mailbox already accounted for is not a second reference to report.
        if ($kind -eq 'UserProxy' -and $exchangeIds.Contains($userId)) { continue }

        $records.Add((ConvertTo-DomainReferenceRecord -Properties @{
                    Kind               = $kind
                    Source             = 'Graph'
                    ObjectId           = $userId
                    Identity           = $upn
                    DisplayName        = [string](Get-MigrationProperty $user 'displayName' '')
                    ObjectType         = if ($isGuest) { 'Guest' } else { 'User' }
                    UserPrincipalName  = $upn
                    PrimarySmtpAddress = [string](Get-MigrationProperty $user 'mail' '')
                    Addresses          = @($vanityProxies)
                    IsSynced           = [bool](Get-MigrationProperty $user 'onPremisesSyncEnabled' $false)
                    IsGuest            = $isGuest
                    ReferenceKinds     = $kinds.ToArray()
                }))
        $null = $seenIds.Add($userId)
    }

    Write-MigrationLog -Message 'Enumerating soft-deleted users' -Level INFO
    try {
        $deleted = @(Invoke-MigrationGraphRequest -Method GET -All -Uri (
                '/v1.0/directory/deletedItems/microsoft.graph.user' +
                "?`$select=id,displayName,userPrincipalName,proxyAddresses&`$top=$PageSize"))
        foreach ($item in $deleted) {
            $upn = [string](Get-MigrationProperty $item 'userPrincipalName' '')
            $proxies = @(Get-MigrationProperty $item 'proxyAddresses' @())
            $hasDomain = $upn.ToLowerInvariant().Contains($suffix) -or @(
                foreach ($entry in $proxies) {
                    if ((Split-AddressEntry -Entry ([string]$entry)).Domain -eq $domainLower) { $entry }
                }
            ).Count -gt 0
            if (-not $hasDomain) { continue }

            $records.Add((ConvertTo-DomainReferenceRecord -Properties @{
                        Kind              = 'DeletedUser'
                        Source            = 'GraphDeleted'
                        ObjectId          = [string](Get-MigrationProperty $item 'id' '')
                        Identity          = $upn
                        DisplayName       = [string](Get-MigrationProperty $item 'displayName' '')
                        ObjectType        = 'DeletedUser'
                        UserPrincipalName = $upn
                        Addresses         = @($proxies)
                        ReferenceKinds    = @('Upn')
                    }))
        }
    }
    catch {
        Write-MigrationLog -Message ('Could not enumerate soft-deleted users: ' +
            "$($_.Exception.Message). A deleted user holding the domain would still block the removal.") -Level WARNING
        $script:domainScanIncomplete = $true
    }

    Write-MigrationLog -Message 'Reading domainNameReferences from Microsoft Graph' -Level INFO
    try {
        $graphReferences = @(Invoke-MigrationGraphRequest -Method GET -All `
                -Uri "/v1.0/domains/$domainLower/domainNameReferences")
        Write-MigrationLog -Message "Graph reports $($graphReferences.Count) domain name reference(s)" -Level INFO

        foreach ($item in $graphReferences) {
            $referenceId = [string](Get-MigrationProperty $item 'id' '')
            if (-not $referenceId) { continue }
            if ($seenIds.Contains($referenceId) -or $exchangeIds.Contains($referenceId)) { continue }

            $records.Add((ConvertTo-DomainReferenceRecord -Properties @{
                        Kind        = 'UnresolvedReference'
                        Source      = 'DomainNameReference'
                        ObjectId    = $referenceId
                        Identity    = $referenceId
                        DisplayName = [string](Get-MigrationProperty $item 'displayName' '')
                        ObjectType  = [string](Get-MigrationProperty $item '@odata.type' 'directoryObject')
                    }))
        }
    }
    catch {
        Write-MigrationLog -Message ("Could not read domainNameReferences: $($_.Exception.Message). " +
            'The enumeration below may be incomplete.') -Level WARNING
        $script:domainScanIncomplete = $true
    }

    return $records.ToArray()
}

function Get-DomainReferenceAssessment {
    <#
        One enumerate-and-classify pass. Both the "before" report and the post-change recheck need
        the same reference, plan and classification triple; only what they report differs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Domain,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FallbackDomain,

        [Parameter(Mandatory)]
        [string[]]$Scope,

        [ValidateRange(1, 999)]
        [int]$PageSize = 999
    )

    foreach ($reference in @(Get-DomainReferenceSet -Domain $Domain -PageSize $PageSize)) {
        $plan = $null
        if ($reference.Kind -eq 'RecipientAddress') {
            $plan = Resolve-DomainAddressPlan -Reference $reference -Domain $Domain -FallbackDomain $FallbackDomain
        }
        [pscustomobject]@{
            Reference      = $reference
            Plan           = $plan
            Classification = Resolve-DomainReferenceClass -Reference $reference -Domain $Domain `
                -FallbackDomain $FallbackDomain -Scope $Scope -AddressPlan $plan
        }
    }
}

#endregion Functions

#region Main

$exitCode = 0
# Declared out here so the fatal handler can still write whatever the run got through.
$results = [System.Collections.Generic.List[object]]::new()
$resultsExported = $false
# Set by Get-DomainReferenceSet when one of its passes fails; the run may then be looking at a
# partial picture and must not report the domain as clear.
$script:domainScanIncomplete = $false

try {
    # ReportOnly, DryRun and a missing acknowledgement all mean the same thing to the run context:
    # compute everything, write everything, change nothing. Routing them into one flag keeps
    # Invoke-MigrationAction as the single gate on every mutation.
    $effectiveDryRun = [bool]($DryRun -or $ReportOnly -or (-not $AcknowledgeSourceTenant))

    $null = Initialize-MigrationRun -ScriptName 'Remove-MigrationDomainReferences' -OutputPath $OutputPath `
        -Prefix $Prefix -LogPath $LogPath -DryRun:$effectiveDryRun -Verbosity $Verbosity `
        -BoundParameters $PSBoundParameters

    if ($effectiveDryRun -and -not ($DryRun -or $ReportOnly)) {
        Write-MigrationLog -Message ('-AcknowledgeSourceTenant was not supplied, so this run reports ' +
            'only. Nothing will be changed.') -Level WARNING
    }

    $graphContext = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId
    Connect-MigrationExchange -DelegatedOrganization $DelegatedOrganization | Out-Null

    $organization = @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/organization?$select=id,displayName')
    $tenantName = if ($organization.Count -gt 0) {
        [string](Get-MigrationProperty $organization[0] 'displayName' '(unknown)')
    }
    else { '(unknown)' }
    $tenantLabel = "$tenantName ($([string](Get-MigrationProperty $graphContext 'TenantId' '(unknown)')))"

    # This banner is the last line of defence against running a destructive cleanup on the wrong
    # tenant, so it is logged at WARNING and repeated in the confirmation prompt below.
    Write-MigrationLog -Message '==========================================================' -Level WARNING
    Write-MigrationLog -Message "SOURCE TENANT: $tenantLabel" -Level WARNING
    Write-MigrationLog -Message "Releasing domain: $Domain" -Level WARNING
    Write-MigrationLog -Message '==========================================================' -Level WARNING

    $domains = @(Invoke-MigrationGraphRequest -Method GET -All -Uri '/v1.0/domains?$select=id,isInitial,isVerified')
    $domainEntry = $domains |
        Where-Object { [string](Get-MigrationProperty $_ 'id' '') -eq $Domain } |
        Select-Object -First 1
    if ($null -eq $domainEntry) {
        throw "Domain '$Domain' is not present on tenant $tenantLabel. Check -TenantId and the spelling."
    }
    if ([bool](Get-MigrationProperty $domainEntry 'isInitial' $false)) {
        throw "'$Domain' is the tenant's initial onmicrosoft.com domain and can never be removed."
    }

    $resolvedFallback = $FallbackDomain
    if ([string]::IsNullOrWhiteSpace($resolvedFallback)) {
        $initial = $domains |
            Where-Object { [bool](Get-MigrationProperty $_ 'isInitial' $false) } |
            Select-Object -First 1
        if ($null -eq $initial) {
            throw 'Could not find the tenant initial onmicrosoft.com domain; supply -FallbackDomain.'
        }
        $resolvedFallback = [string](Get-MigrationProperty $initial 'id' '')
        Write-MigrationLog -Level INFO -Message (
            "Fallback domain defaulted to the tenant initial domain $resolvedFallback")
    }
    if ($resolvedFallback -eq $Domain) {
        throw 'The fallback domain cannot be the domain being released.'
    }
    $fallbackEntry = $domains |
        Where-Object { [string](Get-MigrationProperty $_ 'id' '') -eq $resolvedFallback } |
        Select-Object -First 1
    if ($null -eq $fallbackEntry) {
        throw "Fallback domain '$resolvedFallback' is not present on tenant $tenantLabel."
    }
    if (-not [bool](Get-MigrationProperty $fallbackEntry 'isVerified' $false)) {
        throw "Fallback domain '$resolvedFallback' is not verified; a UPN cannot be moved onto it."
    }

    Write-MigrationLog -Message "Scope: $($Scope -join ', ')" -Level INFO

    # --- Pass 1: enumerate and report, before anything is touched. -------------------------------
    $assessed = @(Get-DomainReferenceAssessment -Domain $Domain -FallbackDomain $resolvedFallback `
            -Scope $Scope -PageSize $graphPageSize)

    $reportRows = foreach ($item in $assessed) {
        [pscustomobject]@{
            Identity             = $item.Reference.Identity
            Class                = $item.Classification.Class
            Reason               = $item.Classification.Reason
            Detail               = $item.Classification.Detail
            Action               = $item.Classification.Action
            ObjectType           = $item.Reference.ObjectType
            RecipientTypeDetails = $item.Reference.RecipientTypeDetails
            ReferenceKind        = $item.Reference.Kind
            ObjectId             = $item.Reference.ObjectId
            DisplayName          = $item.Reference.DisplayName
            IsSynced             = $item.Reference.IsSynced
            Addresses            = (@($item.Reference.Addresses) -join ';')
            Target               = $item.Classification.NewUserPrincipalName
            Source               = $item.Reference.Source
        }
    }
    $null = Export-MigrationReport -Rows @($reportRows) -Name 'DomainReferences'
    $null = Export-MigrationReport -Rows @($reportRows | Where-Object { $_.Class -eq 'Blocker' }) -Name 'DomainBlockers'

    $fixable = @($assessed | Where-Object { $_.Classification.Class -eq 'Fixable' })
    $blocked = @($assessed | Where-Object { $_.Classification.Class -eq 'Blocker' })
    Write-MigrationLog -Message ("References: $($assessed.Count) total, $($fixable.Count) fixable, " +
        "$($blocked.Count) blocking") -Level INFO

    # --- Pass 2: remediate. ----------------------------------------------------------------------
    $proceed = $true
    if (-not $effectiveDryRun -and $fixable.Count -gt 0) {
        $proceed = $PSCmdlet.ShouldProcess($tenantLabel,
            "Release $Domain by changing $($fixable.Count) object(s) in this tenant")
    }

    foreach ($item in $assessed) {
        if ($item.Classification.Class -eq 'Fixable' -and $proceed) {
            $results.Add((Repair-DomainReference -Reference $item.Reference -Classification $item.Classification `
                        -AddressPlan $item.Plan -AsPlanned:$effectiveDryRun))
            continue
        }

        # Blockers, informational rows and (when the prompt was declined) fixable rows all land here
        # so the results file is a complete account of every reference the run saw.
        $detail = $item.Classification.Detail
        $reason = $item.Classification.Reason
        if ($item.Classification.Class -eq 'Fixable' -and -not $proceed) {
            $detail = 'Declined at the confirmation prompt; no change was attempted.'
            $reason = 'ConfirmationDeclined'
        }
        $results.Add([pscustomobject]@{
                Identity      = $item.Reference.Identity
                Action        = $item.Classification.Action
                Status        = 'Skipped'
                Detail        = $detail
                ObjectType    = $item.Reference.ObjectType
                ObjectId      = $item.Reference.ObjectId
                ReferenceKind = $item.Reference.Kind
                Reason        = $reason
                Current       = $item.Reference.UserPrincipalName
                Target        = $item.Classification.NewUserPrincipalName
                Steps         = ''
            })
    }

    $null = Export-MigrationResult -Rows @($results) -Name 'Remove-DomainReferences'
    $resultsExported = $true

    # --- Re-enumerate so the operator is told the truth about what is left. ----------------------
    $remaining = @($blocked)
    if (@($results | Where-Object { $_.Status -eq 'Succeeded' }).Count -gt 0) {
        Write-MigrationLog -Message 'Re-enumerating the domain after the changes' -Level INFO
        $remaining = @(Get-DomainReferenceAssessment -Domain $Domain -FallbackDomain $resolvedFallback `
                -Scope $Scope -PageSize $graphPageSize |
                Where-Object { $_.Classification.Class -ne 'Informational' })

        $recheckRows = foreach ($item in $remaining) {
            [pscustomobject]@{
                Identity      = $item.Reference.Identity
                Class         = $item.Classification.Class
                Reason        = $item.Classification.Reason
                Detail        = $item.Classification.Detail
                ObjectType    = $item.Reference.ObjectType
                ReferenceKind = $item.Reference.Kind
                ObjectId      = $item.Reference.ObjectId
            }
        }
        $null = Export-MigrationReport -Rows @($recheckRows) -Name 'DomainBlockers' -Suffix 'Recheck'
    }

    if (@($remaining).Count -eq 0 -and $script:domainScanIncomplete) {
        # Telling an operator the domain is clear on the strength of a scan that partly failed is
        # how a domain removal fails at the portal with no explanation.
        Write-MigrationLog -Level ERROR -Message (
            "No remaining references to $Domain were found, but part of the enumeration failed - see " +
            'the warnings above. Re-run once the failing pass succeeds before trying to remove the domain.')
        $exitCode = 2
    }
    elseif (@($remaining).Count -eq 0) {
        Write-MigrationLog -Level SUCCESS -Message (
            "Nothing references $Domain any more; it can be removed from the tenant.")
    }
    else {
        Write-MigrationLog -Level WARNING -Message (
            "$Domain still has $(@($remaining).Count) reference(s) blocking removal:")
        foreach ($item in @($remaining)) {
            Write-MigrationLog -Message ("  {0,-45} {1} - {2}" -f $item.Reference.Identity,
                $item.Classification.Reason, $item.Classification.Detail) -Level WARNING
        }
        $exitCode = 2
    }

    if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { $exitCode = 2 }
}
catch {
    Write-MigrationLog -Message "Fatal: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message $_.ScriptStackTrace -Level DEBUG
    if (-not $resultsExported -and $results.Count -gt 0) {
        try {
            $null = Export-MigrationResult -Rows @($results) -Name 'Remove-DomainReferences'
        }
        catch {
            # The run is already failing; a results file that cannot be written must not mask the
            # original error, so the reason is logged and the fatal exit code stands.
            Write-MigrationLog -Message "Could not write the partial results file: $($_.Exception.Message)" -Level ERROR
        }
    }
    $exitCode = 1
}

#endregion Main

#region Cleanup

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion Cleanup
