#Requires -Version 7.4

<#
.SYNOPSIS
    Releases a vanity domain in the SOURCE tenant by clearing every object that still references it.

.DESCRIPTION
    Phase 4 of the migration toolkit, and the only script that runs against the tenant being left
    behind. A custom domain cannot be removed from a tenant - and therefore cannot be verified in the
    destination tenant - while any directory object still carries an address on it. This script finds
    those objects, reports them, and (when explicitly acknowledged) moves them off the domain.

    It always runs in two passes:

      Pass 1 - enumerate and report. Every reference is written to a References CSV and every
      unresolvable reference to a Blockers CSV, before a single change is made. That happens even in a
      real run, so the operator has the "before" picture on disk if the run has to be reconstructed.

      Pass 2 - remediate, but only when the run is not -ReportOnly and not -DryRun AND
      -AcknowledgeSourceTenant was supplied. The connected tenant id and display name are logged and
      echoed prominently before the first mutation, because the whole point of failure here is running
      a destructive cleanup against the destination tenant by mistake.

    What it changes, per object class:

      Users     - PATCH userPrincipalName to <localpart>@<FallbackDomain>. The fallback defaults to the
                  tenant's initial .onmicrosoft.com domain, discovered from Get-MgDomain isInitial.
      Recipients- mailboxes, distribution groups, dynamic groups, mail users, mail contacts and
                  Microsoft 365 groups: when the vanity address is the primary, an onmicrosoft address
                  is promoted to primary first (disabling the email address policy first where the
                  recipient type supports the toggle), then every @Domain proxy address is removed.

    What it will not touch, and reports as a blocker instead: directory-synced objects (they must be
    fixed in on-premises AD), soft-deleted users still holding the domain (restore or purge them),
    guests that carry an address on the domain, and any reference Graph reports that this script
    cannot map to a supported object. Guest #EXT# UPNs that merely embed the domain in their mangled
    local part are reported as informational: Entra generates that form itself, it is not a
    domainNameReference, and rewriting it would break the guest.

    After remediation the domain is re-enumerated and anything still blocking is printed. The script
    exits 2 when blockers remain or when any row failed, so a pipeline can tell "domain is clear" from
    "domain still has references" without parsing the CSV.

.PARAMETER Domain
    The vanity domain being released, for example contoso.com. Must be a custom domain on the
    connected tenant; the initial .onmicrosoft.com domain can never be removed and is rejected.

.PARAMETER FallbackDomain
    The domain UPNs and promoted primary addresses move to. Defaults to the tenant's initial
    .onmicrosoft.com domain.

.PARAMETER TenantId
    The tenant to sign in to for Microsoft Graph. Recommended whenever the operator has access to more
    than one tenant, which during a migration is always.

.PARAMETER DelegatedOrganization
    The customer tenant for GDAP delegated Exchange Online access, for example
    contoso.onmicrosoft.com.

.PARAMETER Scope
    Limits which object classes are remediated: Users, Groups, Contacts, Mailboxes. Defaults to all
    four. Objects outside the scope are still enumerated and still reported as blockers, because they
    still block the domain removal - they are simply not modified.

.PARAMETER AcknowledgeSourceTenant
    Required for any change. Without it the script runs as a report even when -ReportOnly and -DryRun
    are absent. It exists so that "I meant to run this against the other tenant" costs a report rather
    than a rebuild.

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

    Produces the References and Blockers CSVs for contoso.com and changes nothing. This is the first
    thing to run: it tells you how much of the domain release is automatable before you commit to it.

.EXAMPLE
    .\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -TenantId fabrikam.onmicrosoft.com -DryRun

    Full rehearsal against the named tenant. Every UPN rewrite and address change is computed and
    logged with a [DRYRUN] prefix, and the results file is written with Status Planned.

.EXAMPLE
    .\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -AcknowledgeSourceTenant -Scope Users,Mailboxes

    Moves user UPNs and mailbox addresses off contoso.com, leaving groups and contacts alone. Groups
    and contacts still on the domain are reported as blockers so nothing is silently missed.

.EXAMPLE
    .\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -FallbackDomain newco.onmicrosoft.com `
        -DelegatedOrganization contoso.onmicrosoft.com -AcknowledgeSourceTenant -Verbosity High

    A GDAP run against a customer tenant with an explicit fallback domain.

.NOTES
    Author: AutomationHub
    Written with assistance from Claude (Anthropic).

    Required Microsoft Graph scopes:
      Domain.Read.All      - read the domain and its domainNameReferences
      User.ReadWrite.All   - read users and soft-deleted users, PATCH userPrincipalName
      Directory.Read.All   - resolve directory objects returned by domainNameReferences

    Required Exchange Online roles: Recipient Management (Exchange Administrator covers it). The
    Set-UnifiedGroup path additionally needs Groups management rights.

    Changing the UPN of an administrator is a sensitive action: Privileged Authentication
    Administrator or Global Administrator is required, and a 403 on that call is reported with that
    hint rather than as a generic failure.

    GDAP: supported. -DelegatedOrganization is passed through to Connect-ExchangeOnline and -TenantId
    to Connect-MgGraph. Certificate app-only auth cannot be combined with -DelegatedOrganization.

    Hybrid tenants: Exchange Online refuses EmailAddresses edits on directory-synced recipients
    ("out of the current user's write scope"). Those objects are reported as blockers - fix
    proxyAddresses on-premises and let Entra Connect sync the change.

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

# Graph page size for the two full-directory enumerations. 999 is the documented maximum for /users.
$graphPageSize = 999

#endregion Configuration

#region Functions

function Get-ReferenceProperty {
    <#
    .SYNOPSIS
        Reads a property from a Graph or Exchange object without assuming it is there.
    .DESCRIPTION
        Graph omits properties that are null and Exchange varies its property set by cmdlet and by
        module version. Under Set-StrictMode -Version Latest a missing property is a terminating
        error, so every read of an externally supplied object goes through here. The raw value is
        returned - unlike Get-MigrationCsvValue, which stringifies - because proxy address lists and
        boolean flags both matter here.
    .PARAMETER Object
        The object to read from.
    .PARAMETER Name
        The property name.
    .PARAMETER Default
        Returned when the property is absent or null.
    .EXAMPLE
        $addresses = Get-ReferenceProperty -Object $recipient -Name 'EmailAddresses' -Default @()
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Object,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        $Default = $null
    )

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $Default }
        $value = $Object[$Name]
        if ($null -eq $value) { return $Default }
        return $value
    }

    if (-not $Object.PSObject.Properties[$Name]) { return $Default }
    $value = $Object.PSObject.Properties[$Name].Value
    if ($null -eq $value) { return $Default }
    return $value
}

function ConvertTo-DomainReferenceRecord {
    <#
    .SYNOPSIS
        Builds the canonical reference record every later stage reads.
    .DESCRIPTION
        Enumeration pulls from three different shapes - Graph users, Exchange recipients and Graph
        deleted items - and the classifier has to treat them identically. This factory is the single
        place that defines the record schema, so the classifier can use plain property access under
        StrictMode and the tests can build fixtures that are guaranteed to match production records.

        An unknown property name throws rather than being silently absorbed: a typo in a fixture that
        produced a record the classifier then treated as "no addresses" would be a test that passes
        for the wrong reason.
    .PARAMETER Properties
        The subset of the schema to populate; everything else takes its default.
    .EXAMPLE
        $record = ConvertTo-DomainReferenceRecord -Properties @{ Kind = 'UserUpn'; Identity = 'sam@contoso.com' }
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
    .SYNOPSIS
        Parses one proxy address entry into its prefix, address and domain.
    .DESCRIPTION
        Exchange stores addresses as '<type>:<address>' where an uppercase SMTP prefix marks the
        primary. Everything this script decides - what is on the domain, what is primary, what may be
        promoted - comes from that split, so it is done once, here, rather than with a regex at each
        decision point.
    .PARAMETER Entry
        The raw entry, for example 'SMTP:sam@contoso.com', 'smtp:sam@newco.onmicrosoft.com',
        'sip:sam@contoso.com' or a bare 'sam@contoso.com'.
    .EXAMPLE
        (Split-AddressEntry -Entry 'SMTP:sam@contoso.com').IsPrimary
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Entry
    )

    $result = [pscustomobject]@{
        Entry     = [string]$Entry
        Prefix    = ''
        Type      = 'smtp'
        IsPrimary = $false
        Address   = ''
        Domain    = ''
    }

    if ([string]::IsNullOrWhiteSpace($Entry)) { return $result }

    $value = $Entry.Trim()
    $address = $value
    $separator = $value.IndexOf(':')
    if ($separator -gt 0) {
        $candidate = $value.Substring(0, $separator)
        if ($candidate -match '^(?i)(smtp|sip|spo|x500|x400|eum|eai|mailto)$') {
            $result.Prefix = $candidate
            $result.Type = $candidate.ToLowerInvariant()
            # Only SMTP uses case to mark the primary; a bare address is assumed to be an alias.
            $result.IsPrimary = ($candidate -ceq 'SMTP')
            $address = $value.Substring($separator + 1)
        }
    }

    $result.Address = $address
    $at = $address.LastIndexOf('@')
    if ($at -ge 0 -and $at -lt ($address.Length - 1)) {
        $result.Domain = $address.Substring($at + 1).ToLowerInvariant()
    }

    return $result
}

function ConvertTo-FallbackUpn {
    <#
    .SYNOPSIS
        Rewrites a UPN onto the fallback domain, keeping the local part.
    .DESCRIPTION
        The local part is preserved verbatim: this script is releasing a domain, not redesigning
        identity, and any renaming belongs to Set-MigrationIdentity where the plan says what the new
        name should be. Guest #EXT# UPNs return an empty string - Entra owns that form and rewriting
        it breaks the guest - which the caller turns into a blocker.
    .PARAMETER UserPrincipalName
        The current UPN.
    .PARAMETER FallbackDomain
        The domain to move it to.
    .EXAMPLE
        ConvertTo-FallbackUpn -UserPrincipalName 'sam@contoso.com' -FallbackDomain 'newco.onmicrosoft.com'
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
    .SYNOPSIS
        Maps an Exchange recipient type to the Set-* cmdlet that edits its addresses.
    .DESCRIPTION
        Address edits are not one cmdlet: mailboxes, distribution groups, dynamic groups, mail users,
        contacts and Microsoft 365 groups each have their own, and only some of them expose
        -EmailAddressPolicyEnabled. Getting that wrong produces a parameter-binding error halfway
        through a cutover, so the mapping is data rather than a chain of if statements at the call
        site - and it is unit tested.
    .PARAMETER RecipientTypeDetails
        The RecipientTypeDetails value from Get-EXORecipient.
    .EXAMPLE
        (Resolve-RecipientCmdlet -RecipientTypeDetails 'SharedMailbox').SetCmdlet
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecipientTypeDetails
    )

    $result = [pscustomobject]@{
        RecipientTypeDetails = [string]$RecipientTypeDetails
        SetCmdlet            = ''
        SupportsPolicyToggle = $false
        IsSupported          = $false
    }

    $type = ([string]$RecipientTypeDetails).Trim()

    $mailboxes = @(
        'UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox'
        'SchedulingMailbox', 'TeamMailbox', 'LinkedMailbox', 'DiscoveryMailbox'
    )
    $distributionGroups = @(
        'MailUniversalDistributionGroup', 'MailUniversalSecurityGroup'
        'MailNonUniversalGroup', 'RoomList'
    )

    if ($mailboxes -contains $type) {
        $result.SetCmdlet = 'Set-Mailbox'
        $result.SupportsPolicyToggle = $true
    }
    elseif (@('MailUser', 'GuestMailUser') -contains $type) {
        $result.SetCmdlet = 'Set-MailUser'
        $result.SupportsPolicyToggle = $true
    }
    elseif ($type -eq 'MailContact') {
        # Contacts are not subject to email address policies, so there is no toggle to disable.
        $result.SetCmdlet = 'Set-MailContact'
    }
    elseif ($distributionGroups -contains $type) {
        $result.SetCmdlet = 'Set-DistributionGroup'
        $result.SupportsPolicyToggle = $true
    }
    elseif ($type -eq 'DynamicDistributionGroup') {
        $result.SetCmdlet = 'Set-DynamicDistributionGroup'
        $result.SupportsPolicyToggle = $true
    }
    elseif ($type -eq 'GroupMailbox') {
        $result.SetCmdlet = 'Set-UnifiedGroup'
    }

    $result.IsSupported = [bool]$result.SetCmdlet
    return $result
}

function Resolve-DomainReferenceScope {
    <#
    .SYNOPSIS
        Returns the -Scope token that governs a reference record.
    .PARAMETER Reference
        A record from ConvertTo-DomainReferenceRecord.
    .EXAMPLE
        Resolve-DomainReferenceScope -Reference $record
    #>
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
    .SYNOPSIS
        Works out, offline, exactly which address changes a recipient needs.
    .DESCRIPTION
        The order matters and is the reason this is computed up front rather than improvised in the
        loop. Disabling the email address policy has to happen before the primary changes, or the
        policy can reassert the vanity address on its next application; the promotion has to happen
        before the removal, or Exchange refuses to remove the primary address; and the removal list
        uses bare addresses for SMTP entries because the old primary is demoted to a lowercase alias
        by the promotion, which makes a literal 'SMTP:...' removal miss.

        The plan is deliberately allowed to come back incomplete - no non-vanity address to promote, an
        unsupported recipient type, a contact whose external address is on the domain - so the caller
        can report a blocker instead of half-applying a change.
    .PARAMETER Reference
        A record from ConvertTo-DomainReferenceRecord.
    .PARAMETER Domain
        The domain being released.
    .PARAMETER FallbackDomain
        The preferred domain for the promoted primary address.
    .EXAMPLE
        $plan = Resolve-DomainAddressPlan -Reference $record -Domain contoso.com -FallbackDomain newco.onmicrosoft.com
        $plan.Steps
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

    # SMTP entries are removed by bare address: after the promotion the old primary is a lowercase
    # alias, so removing the 'SMTP:' form Exchange reported a moment ago would no longer match.
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
    .SYNOPSIS
        Decides whether a reference is fixable here, a blocker, or informational.
    .DESCRIPTION
        This is the judgement the whole script turns on, so it is a pure function over a record and
        can be tested without a tenant.

        Blocker means the domain cannot be removed until a human does something this script must not
        do on their behalf: change an object that on-premises AD owns, deal with a soft-deleted user,
        or decide what a guest's identity should become.

        Informational means the reference is real but harmless - notably a guest whose #EXT# UPN
        embeds the domain in its mangled local part. Entra generates that form for a guest invited
        from an address on the domain; it is not returned by domainNameReferences, it does not block
        the removal, and rewriting it would break the guest's sign-in.
    .PARAMETER Reference
        A record from ConvertTo-DomainReferenceRecord.
    .PARAMETER Domain
        The domain being released.
    .PARAMETER FallbackDomain
        The domain UPNs move to.
    .PARAMETER Scope
        The object classes the operator allowed this run to change.
    .PARAMETER AddressPlan
        The plan from Resolve-DomainAddressPlan, for recipient records.
    .EXAMPLE
        $class = Resolve-DomainReferenceClass -Reference $record -Domain contoso.com `
            -FallbackDomain newco.onmicrosoft.com
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
    .SYNOPSIS
        Turns an Exchange or Graph failure into a message that says what to do next.
    .DESCRIPTION
        Three failures dominate this script and all three have a specific remedy that a raw exception
        message does not convey: a 403 on a UPN change means the caller lacks Privileged
        Authentication Administrator for a privileged target, a 409 means a soft-deleted object holds
        the target UPN, and Exchange's "write scope" refusal means the recipient is directory-synced.
    .PARAMETER Message
        The exception message.
    .PARAMETER Action
        The action that failed, used to pick the UPN-specific hints.
    .EXAMPLE
        Get-DomainReferenceErrorDetail -Message $_.Exception.Message -Action 'SetUpn'
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
    .SYNOPSIS
        Applies the computed change for one reference and returns its result row.
    .DESCRIPTION
        Every mutation the script makes happens here, wrapped in Invoke-MigrationAction and gated by
        ShouldProcess, which is what makes the DryRun promise checkable: in a dry run
        Invoke-MigrationAction never invokes the scriptblock, so nothing can reach Graph or Exchange
        no matter what the plan says.

        The steps run in the order the plan lists them - policy off, promote, remove - because that
        order is load-bearing rather than cosmetic (see Resolve-DomainAddressPlan).
    .PARAMETER Reference
        The record being repaired.
    .PARAMETER Classification
        The result of Resolve-DomainReferenceClass; only Fixable records should be passed.
    .PARAMETER AddressPlan
        The plan from Resolve-DomainAddressPlan, required for UpdateAddresses.
    .PARAMETER AsPlanned
        Labels the row Status 'Planned' rather than 'Succeeded'. Set for dry runs, where the actions
        are computed and logged but never invoked.
    .EXAMPLE
        $row = Repair-DomainReference -Reference $record -Classification $class -AddressPlan $plan
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
        Status        = 'Succeeded'
        Detail        = [string]$Classification.Detail
        ObjectType    = [string]$Reference.ObjectType
        ObjectId      = [string]$Reference.ObjectId
        ReferenceKind = [string]$Reference.Kind
        Reason        = [string]$Classification.Reason
        Current       = ''
        Target        = ''
        Steps         = ($steps -join ';')
    }
    if ($AsPlanned) { $row.Status = 'Planned' }

    if (-not $PSCmdlet.ShouldProcess($identity, "$($Classification.Action) to release the domain")) {
        $row.Status = 'Skipped'
        $row.Detail = 'Skipped by -WhatIf or a declined confirmation.'
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
                            $message = "Disable the email address policy on $identity"
                            Invoke-MigrationAction -Description $message -Action {
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
                            $joined = $remove -join ', '
                            Invoke-MigrationAction -Description "Remove $joined from $identity" -Action {
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

function Export-DomainReferenceReport {
    <#
    .SYNOPSIS
        Writes one of the two-pass report CSVs into the run's output folder.
    .DESCRIPTION
        These are reports rather than results - they describe the tenant, not what the script did - so
        they are written alongside the results file with the same prefix and timestamp convention
        instead of through Export-MigrationResult.
    .PARAMETER Rows
        The report rows.
    .PARAMETER Name
        The report name, for example 'DomainReferences'.
    .PARAMETER Directory
        The run's output directory, from the context Initialize-MigrationRun returned. It is passed in
        rather than read from the module, whose run context lives in its own module scope.
    .PARAMETER Prefix
        The run prefix, from the same context.
    .EXAMPLE
        Export-DomainReferenceReport -Rows $references -Name 'DomainReferences' -Directory $run.OutputDirectory
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Directory,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Prefix
    )

    $directory = $Directory
    $prefix = [string]$Prefix
    $leader = if ($prefix) { "${prefix}_" } else { '' }
    $fileName = '{0}{1}_{2}.csv' -f $leader, $Name, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $filePath = Join-Path -Path $directory -ChildPath $fileName

    try {
        if (@($Rows).Count -eq 0) {
            # An empty report is still evidence: it says the enumeration ran and found nothing.
            Set-Content -LiteralPath $filePath -Value '' -Encoding utf8 -ErrorAction Stop
        }
        else {
            @($Rows) | Export-Csv -LiteralPath $filePath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
        }
    }
    catch {
        throw "Could not write the report '$filePath': $($_.Exception.Message)"
    }

    Write-MigrationLog -Message "$Name report written to $filePath ($(@($Rows).Count) row(s))" -Level SUCCESS
    return $filePath
}

function Get-DomainReferenceSet {
    <#
    .SYNOPSIS
        Enumerates every object in the connected tenant that references the domain.
    .DESCRIPTION
        Four passes, because no single source is complete:

          Exchange Online recipients - the only reliable source for proxy addresses, and the only
          place they can be edited. Filtered server-side on EmailAddresses.
          Graph users - UPNs on the domain, guests whose #EXT# form embeds it, and users holding an
          address on the domain that Exchange does not know about. Enumerated in full rather than with
          an endsWith filter, which would require the ConsistencyLevel=eventual advanced query header.
          Graph deleted items - soft-deleted users still holding the domain, which block the removal
          and cannot be fixed by editing anything live.
          domainNameReferences - Microsoft's own answer to "what is still using this domain". Anything
          it returns that the first three passes did not explain becomes an UnresolvedReference, so
          the operator is never told the domain is clear when Graph disagrees.
    .PARAMETER Domain
        The domain being released.
    .PARAMETER PageSize
        Graph page size for the two full-directory enumerations.
    .EXAMPLE
        $references = Get-DomainReferenceSet -Domain contoso.com
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
    $records = [System.Collections.Generic.List[object]]::new()
    $exchangeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    Write-MigrationLog -Message "Enumerating Exchange Online recipients with an address on $Domain" -Level INFO
    $filter = "EmailAddresses -like '*@$(ConvertTo-MigrationODataString -Value $domainLower)'"
    $recipients = @()
    try {
        $recipients = @(Get-EXORecipient -Filter $filter -ResultSize Unlimited -Properties `
                EmailAddresses, ExternalEmailAddress, EmailAddressPolicyEnabled, IsDirSynced -ErrorAction Stop)
    }
    catch {
        Write-MigrationLog -Message ("Recipient scan with extended properties failed " +
            "($($_.Exception.Message)); retrying with the default property set.") -Level WARNING
        $recipients = @(Get-EXORecipient -Filter $filter -ResultSize Unlimited -ErrorAction Stop)
    }
    Write-MigrationLog -Message "Exchange Online returned $($recipients.Count) recipient(s)" -Level INFO

    foreach ($recipient in $recipients) {
        $objectId = [string](Get-ReferenceProperty -Object $recipient -Name 'ExternalDirectoryObjectId' -Default '')
        $identity = [string](Get-ReferenceProperty -Object $recipient -Name 'PrimarySmtpAddress' -Default '')
        if (-not $identity) {
            $identity = [string](Get-ReferenceProperty -Object $recipient -Name 'Identity' -Default '')
        }
        if ($objectId) { $null = $exchangeIds.Add($objectId) }
        $policyEnabled = [bool](Get-ReferenceProperty $recipient 'EmailAddressPolicyEnabled' $true)

        $records.Add((ConvertTo-DomainReferenceRecord -Properties @{
                    Kind                      = 'RecipientAddress'
                    Source                    = 'ExchangeOnline'
                    ObjectId                  = $objectId
                    Identity                  = $identity
                    DisplayName               = [string](Get-ReferenceProperty $recipient 'DisplayName' '')
                    ObjectType                = 'Recipient'
                    RecipientTypeDetails      = [string](Get-ReferenceProperty $recipient 'RecipientTypeDetails' '')
                    PrimarySmtpAddress        = $identity
                    ExternalEmailAddress      = [string](Get-ReferenceProperty $recipient 'ExternalEmailAddress' '')
                    Addresses                 = @(Get-ReferenceProperty $recipient 'EmailAddresses' @())
                    IsSynced                  = [bool](Get-ReferenceProperty $recipient 'IsDirSynced' $false)
                    EmailAddressPolicyEnabled = $policyEnabled
                    ReferenceKinds            = @('Address')
                }))
    }

    Write-MigrationLog -Message 'Enumerating Entra users' -Level INFO
    $select = 'id,displayName,userPrincipalName,mail,proxyAddresses,onPremisesSyncEnabled,userType'
    $users = @(Invoke-MigrationGraphRequest -Method GET -All `
            -Uri "/v1.0/users?`$select=$select&`$top=$PageSize")
    Write-MigrationLog -Message "Graph returned $($users.Count) user(s)" -Level INFO

    foreach ($user in $users) {
        $upn = [string](Get-ReferenceProperty -Object $user -Name 'userPrincipalName' -Default '')
        $userId = [string](Get-ReferenceProperty -Object $user -Name 'id' -Default '')
        $proxies = @(Get-ReferenceProperty -Object $user -Name 'proxyAddresses' -Default @())
        $userType = [string](Get-ReferenceProperty -Object $user -Name 'userType' -Default '')
        $isSynced = [bool](Get-ReferenceProperty -Object $user -Name 'onPremisesSyncEnabled' -Default $false)
        $upnLower = $upn.ToLowerInvariant()
        $isGuest = ($userType -eq 'Guest') -or ($upnLower -match '(?i)#ext#@')

        $vanityProxies = @(
            foreach ($entry in $proxies) {
                $parsed = Split-AddressEntry -Entry ([string]$entry)
                if ($parsed.Domain -eq $domainLower) { [string]$entry }
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
                    DisplayName        = [string](Get-ReferenceProperty -Object $user -Name 'displayName' -Default '')
                    ObjectType         = if ($isGuest) { 'Guest' } else { 'User' }
                    UserPrincipalName  = $upn
                    PrimarySmtpAddress = [string](Get-ReferenceProperty -Object $user -Name 'mail' -Default '')
                    Addresses          = @($vanityProxies)
                    IsSynced           = $isSynced
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
            $upn = [string](Get-ReferenceProperty -Object $item -Name 'userPrincipalName' -Default '')
            $proxies = @(Get-ReferenceProperty -Object $item -Name 'proxyAddresses' -Default @())
            $hasDomain = $upn.ToLowerInvariant().Contains($suffix) -or @(
                foreach ($entry in $proxies) {
                    if ((Split-AddressEntry -Entry ([string]$entry)).Domain -eq $domainLower) { $entry }
                }
            ).Count -gt 0
            if (-not $hasDomain) { continue }

            $records.Add((ConvertTo-DomainReferenceRecord -Properties @{
                        Kind              = 'DeletedUser'
                        Source            = 'GraphDeleted'
                        ObjectId          = [string](Get-ReferenceProperty -Object $item -Name 'id' -Default '')
                        Identity          = $upn
                        DisplayName       = [string](Get-ReferenceProperty $item 'displayName' '')
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
    }

    Write-MigrationLog -Message 'Reading domainNameReferences from Microsoft Graph' -Level INFO
    try {
        $graphReferences = @(Invoke-MigrationGraphRequest -Method GET -All `
                -Uri "/v1.0/domains/$domainLower/domainNameReferences")
        Write-MigrationLog -Message "Graph reports $($graphReferences.Count) domain name reference(s)" -Level INFO

        foreach ($item in $graphReferences) {
            $referenceId = [string](Get-ReferenceProperty -Object $item -Name 'id' -Default '')
            if (-not $referenceId) { continue }
            if ($seenIds.Contains($referenceId) -or $exchangeIds.Contains($referenceId)) { continue }

            $records.Add((ConvertTo-DomainReferenceRecord -Properties @{
                        Kind        = 'UnresolvedReference'
                        Source      = 'DomainNameReference'
                        ObjectId    = $referenceId
                        Identity    = $referenceId
                        DisplayName = [string](Get-ReferenceProperty -Object $item -Name 'displayName' -Default '')
                        ObjectType  = [string](Get-ReferenceProperty $item '@odata.type' 'directoryObject')
                    }))
        }
    }
    catch {
        Write-MigrationLog -Message ("Could not read domainNameReferences: $($_.Exception.Message). " +
            'The enumeration below may be incomplete.') -Level WARNING
    }

    return $records.ToArray()
}

#endregion Functions

#region Main

$exitCode = 0

try {
    # ReportOnly, DryRun and a missing acknowledgement all mean the same thing to the run context:
    # compute everything, write everything, change nothing. Routing them into one flag keeps
    # Invoke-MigrationAction as the single gate on every mutation.
    $effectiveDryRun = [bool]($DryRun -or $ReportOnly -or (-not $AcknowledgeSourceTenant))

    $run = Initialize-MigrationRun -ScriptName 'Remove-MigrationDomainReferences' -OutputPath $OutputPath `
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
        [string](Get-ReferenceProperty -Object $organization[0] -Name 'displayName' -Default '(unknown)')
    }
    else { '(unknown)' }
    $tenantIdentifier = [string](Get-ReferenceProperty -Object $graphContext -Name 'TenantId' -Default '(unknown)')
    $tenantLabel = "$tenantName ($tenantIdentifier)"

    # This banner is the last line of defence against running a destructive cleanup on the wrong
    # tenant, so it is logged at WARNING and repeated in the confirmation prompt below.
    Write-MigrationLog -Message '==========================================================' -Level WARNING
    Write-MigrationLog -Message "SOURCE TENANT: $tenantLabel" -Level WARNING
    Write-MigrationLog -Message "Releasing domain: $Domain" -Level WARNING
    Write-MigrationLog -Message '==========================================================' -Level WARNING

    $domains = @(Invoke-MigrationGraphRequest -Method GET -All -Uri '/v1.0/domains?$select=id,isInitial,isVerified')
    $domainEntry = $domains |
        Where-Object { [string](Get-ReferenceProperty -Object $_ -Name 'id' -Default '') -eq $Domain } |
        Select-Object -First 1
    if ($null -eq $domainEntry) {
        throw "Domain '$Domain' is not present on tenant $tenantLabel. Check -TenantId and the spelling."
    }
    if ([bool](Get-ReferenceProperty -Object $domainEntry -Name 'isInitial' -Default $false)) {
        throw "'$Domain' is the tenant's initial onmicrosoft.com domain and can never be removed."
    }

    $resolvedFallback = $FallbackDomain
    if ([string]::IsNullOrWhiteSpace($resolvedFallback)) {
        $initial = $domains | Where-Object {
            [bool](Get-ReferenceProperty -Object $_ -Name 'isInitial' -Default $false)
        } | Select-Object -First 1
        if ($null -eq $initial) {
            throw 'Could not find the tenant initial onmicrosoft.com domain; supply -FallbackDomain.'
        }
        $resolvedFallback = [string](Get-ReferenceProperty -Object $initial -Name 'id' -Default '')
        Write-MigrationLog -Level INFO -Message (
            "Fallback domain defaulted to the tenant initial domain $resolvedFallback")
    }
    if ($resolvedFallback -eq $Domain) {
        throw 'The fallback domain cannot be the domain being released.'
    }
    $fallbackEntry = $domains | Where-Object {
        [string](Get-ReferenceProperty -Object $_ -Name 'id' -Default '') -eq $resolvedFallback
    } | Select-Object -First 1
    if ($null -eq $fallbackEntry) {
        throw "Fallback domain '$resolvedFallback' is not present on tenant $tenantLabel."
    }
    if (-not [bool](Get-ReferenceProperty -Object $fallbackEntry -Name 'isVerified' -Default $false)) {
        throw "Fallback domain '$resolvedFallback' is not verified; a UPN cannot be moved onto it."
    }

    Write-MigrationLog -Message "Scope: $($Scope -join ', ')" -Level INFO

    # --- Pass 1: enumerate and report, before anything is touched. -------------------------------
    $references = @(Get-DomainReferenceSet -Domain $Domain -PageSize $graphPageSize)

    $assessed = [System.Collections.Generic.List[object]]::new()
    foreach ($reference in $references) {
        $plan = $null
        if ($reference.Kind -eq 'RecipientAddress') {
            $plan = Resolve-DomainAddressPlan -Reference $reference -Domain $Domain -FallbackDomain $resolvedFallback
        }
        $classification = Resolve-DomainReferenceClass -Reference $reference -Domain $Domain `
            -FallbackDomain $resolvedFallback -Scope $Scope -AddressPlan $plan
        $assessed.Add([pscustomobject]@{
                Reference      = $reference
                Plan           = $plan
                Classification = $classification
            })
    }

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
    $null = Export-DomainReferenceReport -Rows @($reportRows) -Name 'DomainReferences' `
        -Directory $run.OutputDirectory -Prefix $run.Prefix
    $null = Export-DomainReferenceReport -Rows @($reportRows | Where-Object { $_.Class -eq 'Blocker' }) `
        -Name 'DomainBlockers' -Directory $run.OutputDirectory -Prefix $run.Prefix

    $fixable = @($assessed | Where-Object { $_.Classification.Class -eq 'Fixable' })
    $blocked = @($assessed | Where-Object { $_.Classification.Class -eq 'Blocker' })
    Write-MigrationLog -Message ("References: $($assessed.Count) total, $($fixable.Count) fixable, " +
        "$($blocked.Count) blocking") -Level INFO

    # --- Pass 2: remediate. ----------------------------------------------------------------------
    $results = [System.Collections.Generic.List[object]]::new()

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
            $detail = 'The tenant confirmation was declined; no change was attempted.'
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

    # --- Re-enumerate so the operator is told the truth about what is left. ----------------------
    $remaining = @($blocked)
    $changed = @($results | Where-Object { $_.Status -eq 'Succeeded' })
    if ($changed.Count -gt 0) {
        Write-MigrationLog -Message 'Re-enumerating the domain after the changes' -Level INFO
        $after = @(Get-DomainReferenceSet -Domain $Domain -PageSize $graphPageSize)
        $remaining = @(
            foreach ($reference in $after) {
                $plan = $null
                if ($reference.Kind -eq 'RecipientAddress') {
                    $plan = Resolve-DomainAddressPlan -Reference $reference -Domain $Domain `
                        -FallbackDomain $resolvedFallback
                }
                $classification = Resolve-DomainReferenceClass -Reference $reference -Domain $Domain `
                    -FallbackDomain $resolvedFallback -Scope $Scope -AddressPlan $plan
                if ($classification.Class -ne 'Informational') {
                    [pscustomobject]@{ Reference = $reference; Plan = $plan; Classification = $classification }
                }
            }
        )
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
        $null = Export-DomainReferenceReport -Rows @($recheckRows) -Name 'DomainBlockers-Recheck' `
            -Directory $run.OutputDirectory -Prefix $run.Prefix
    }

    if (@($remaining).Count -eq 0) {
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
    $exitCode = 1
}

#endregion Main

#region Cleanup

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion Cleanup
