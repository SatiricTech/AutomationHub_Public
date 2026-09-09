# M365 Migration Toolkit

PowerShell 7 tooling for Microsoft 365 → Microsoft 365 tenant-to-tenant migrations,
built as a companion to **AvePoint Fly**. Fly moves the content. This toolkit does
everything Fly hands back to the MSP: identity design, destination provisioning,
licensing, mail recipients, delegation, domain release, cutover and verification.

## What this is

Seventeen phase scripts plus one shared module (`M365Migration/`). Every script imports
the module, reads and writes plain CSVs, and acts on a single artefact — the **identity
plan** — so no phase has to guess what an earlier phase decided.

| Concern | AvePoint Fly | This toolkit |
|---|---|---|
| Mailboxes, archives, OneDrive, SharePoint, Teams channels/chats, M365 Groups, Planner | Yes | No |
| Destination users with attributes, manager, GAL hiding | Partial (Entra module: no passwords, no manager) | `New-MigrationUsers` |
| Licence assignment, usage location, group-licensing conflicts | Partial (source SKU copy) | `Set-MigrationLicenses` |
| UPN / primary SMTP design, aliases, interim onmicrosoft identities | No (suffix rewrite only) | `New-MigrationIdentityPlan`, `Set-MigrationIdentity` |
| DLs, mail-enabled security groups, dynamic DLs, mail contacts | Partial (members/owners only) | `New-MigrationRecipients` |
| Shared / room / equipment mailboxes | Partial (converts a licensed user) | `New-MigrationRecipients` |
| Full Access / Send As / Send on Behalf / calendar / forwarding | Partial per module | `Set-MigrationMailboxPermissions` |
| X500 / LegacyExchangeDN stamping (missing = NDRs on replies) | No | `Set-MigrationIdentity -Apply X500` |
| Releasing the vanity domain from the source tenant | No | `Remove-MigrationDomainReferences` |
| Passwords and cutover credentials | No | `Reset-MigrationCutoverPasswords` |
| Teams Phone numbers and policies | No | Teams Phone Get / Remove / Set |
| Viva Learning history | No | Viva Get / Import |
| Destination readiness pre-flight | Checklist only | `Test-MigrationReadiness` |
| Mail flow cutover (MX, connectors), Intune re-enrol, eDiscovery, Bookings/Shifts | No | Runbook only — no script |

---

## Requirements

| Item | Detail |
|---|---|
| PowerShell | 7.4 or later (`#Requires -Version 7.4`). Tested on 7.6. |
| Modules | `Microsoft.Graph.Authentication`, `ExchangeOnlineManagement` (v3+), `MicrosoftTeams`, `ImportExcel`. Installed for the current user on demand by `Initialize-MigrationModule`, which logs what it is about to install first. |
| Entra roles | User Administrator for user create/update; **Privileged Authentication Administrator** to change the UPN of, or reset the password of, another admin; Reports Reader or Global Reader for MFA registration counts; Domain Name Administrator to remove a domain. |
| Exchange roles | Exchange Administrator (recipient management, permissions, address policies). |
| Teams roles | Teams Administrator or Teams Communications Administrator. |
| SharePoint | SharePoint Administrator, only if you pre-provision OneDrive with `Request-SPOPersonalSite`. |
| Service account | The account Fly uses must be licensed and **excluded from MFA / Conditional Access** in both tenants, and needs site-collection-admin grants for SPO/OneDrive. |

### GDAP notes

- `Connect-MgGraph -TenantId <customer>` works for a partner user under an active GDAP
  relationship, scoped to whatever roles GDAP granted.
- `Connect-ExchangeOnline -DelegatedOrganization <customer>.onmicrosoft.com` is a
  **delegated/interactive** path, not app-only certificate auth. The two cannot be combined —
  cross-tenant app-only EXO needs a multitenant app with per-customer consent and
  `-Organization`, not `-DelegatedOrganization`.
- Known bug: WAM can drop GDAP claims. Add `-DisableWAM` to the EXO connect if a delegated
  session lands in your own tenant.
- **Every script prints the tenant it actually connected to.** Read that line before you let
  a writer run. Without `-DelegatedOrganization` you connect to *your own* tenant and every
  mailbox lookup fails with "No mailbox found" — or worse, succeeds against the wrong estate.

### Auth matrix

| Script | Graph (`-TenantId`) | EXO (`-DelegatedOrganization`) | Teams (`-TenantId`) | App-only |
|---|---|---|---|---|
| `Get-MigrationInventory` | Yes | Yes | — | — |
| `Get-MigrationTeamsPhoneAssignments` | — | — | Yes | — |
| `Get-MigrationVivaLearningHistory` | Yes (delegated only) | — | — | — |
| `Compare-MigrationUserData` | — | — | — | — |
| `New-MigrationIdentityPlan` | — | — | — | — |
| `Export-MigrationMappingFile` | — | — | — | — |
| `Test-MigrationReadiness` | Yes | Yes | — | — |
| `New-MigrationUsers` | Yes | — | — | — |
| `Set-MigrationLicenses` | Yes | — | — | — |
| `New-MigrationRecipients` | — | Yes | — | — |
| `Remove-MigrationDomainReferences` | Yes | Yes | — | — |
| `Set-MigrationIdentity` | Yes | Yes | — | — |
| `Set-MigrationMailboxPermissions` | — | Yes | — | — |
| `Reset-MigrationCutoverPasswords` | Yes | — | — | — |
| `Set-MigrationTeamsPhoneAssignments` | — | — | Yes | — |
| `Remove-MigrationTeamsPhoneAssignments` | — | — | Yes | — |
| `Import-MigrationVivaLearningHistory` | Yes (provider registration) | — | — | Yes (`-ClientId` + secret/cert for content and activity writes) |

Graph scopes are declared at the top of each script's Configuration region and verified
after sign-in; a missing scope throws by name rather than failing on the first call.

---

## Folder layout

```
Utilities/M365-Migration/
  README.md
  M365Migration/            shared module (manifest + Public/ + Private/); imported by every script
  Templates/                IdentityPlan.sample.csv, SkuMap.sample.csv, ExclusionRules.sample.csv
  Tests/                    Pester 6 suites, one per script and per pure function
  Docs/                     source HTML for the published Hudu article
  *.ps1                     the 17 phase scripts
```

Copy the whole folder to run it; the scripts are no longer individually standalone.

---

## Conventions

| Aspect | Detail |
|---|---|
| Output root | `%LOCALAPPDATA%\Migration-Automations` on Windows, `~/Migration-Automations` elsewhere. Override with `-OutputPath`. |
| `-Prefix` | Names the client or run. Output lands in `<root>\<Prefix>\` and every filename starts with `<Prefix>_`. Use `Source` and `Destination` for the two inventories. |
| Logging | `Initialize-MigrationRun` opens `<ScriptName>_<yyyyMMdd-HHmmss>.log` in the output directory and records the parameters (never secrets). `-LogPath` overrides. `-Verbosity Low\|Medium\|High` controls the console only — the log always gets everything. |
| DryRun | One semantic everywhere: connect read-only, compute everything, write the results file with Status `Planned`, change nothing. `-WhatIf` is honoured independently at the row level on every writer. |
| Results CSV | `<Prefix>_<Name>-Results_<ts>.csv`, or `-DryRun_` in place of `-Results_`. Columns always begin `Identity, Action, Status, Detail`; script-specific columns follow. Status ∈ `Planned \| Succeeded \| Skipped \| Failed`. |
| Exit codes | `0` clean, `1` fatal error, `2` completed with row failures (or, for `Test-MigrationReadiness`, failed checks). |
| Waves | Every writer takes `-Wave <label[]>` and processes only matching plan rows. Waves are labels, not numbers — `1`, `Pilot`, `Finance` all work. |
| Passwords | Generated credentials go to the results CSV only, never to the log. Store that file the way you would store any other password list. |

---

## The identity plan

`New-MigrationIdentityPlan` reads the source inventory CSVs and writes one
`<Prefix>_IdentityPlan_<ts>.csv`. Every later phase reads it; several write back into it.
`Templates/IdentityPlan.sample.csv` carries the exact column order.

| Column group | Filled by | Notes |
|---|---|---|
| `ObjectType`, `Wave` | Plan / wave map | `User`, `Guest`, `Shared`, `Room`, `Equipment`, `Distribution`, `MailEnabledSecurity`, `DynamicDistribution`, `Contact`, `M365Group` (informational — Fly owns those) |
| `SourceObjectId`, `SourceUserPrincipalName`, `SourcePrimarySmtp`, `SourceAliases`, `LegacyExchangeDN`, `SourceX500` | Plan | `;`-separated lists; aliases stored as `smtp:alias@domain`, X500 as `X500:/o=...` |
| `DisplayName`, `FirstName`, `MiddleName`, `LastName`, `JobTitle`, `Department`, `Office`, `MobilePhone`, `UsageLocation`, `ManagerUpn` | Plan | Passthrough. `ManagerUpn` is re-resolved to the target account at provisioning. |
| `MailboxType`, `AccountEnabled`, `IsSynced`, `SourceLicenses` | Plan | `IsSynced=True` blocks every identity write |
| `InterimUserPrincipalName`, `InterimPrimarySmtp` | Plan | onmicrosoft addresses used while the vanity domain is still in the source tenant |
| `TargetUserPrincipalName`, `TargetPrimarySmtp`, `TargetAliases`, `TargetMailNickname` | Plan / **operator** | Operator edits win — mark the row `ManualOverride` |
| `TargetLicenses` | Plan via SkuMap | `;`-separated SKU part numbers |
| `PlanStatus`, `PlanDetail`, `ExcludeReason` | Plan | See below |
| `TargetObjectId`, `MailboxProvisioned`, `OneDriveProvisioned`, `ProvisionStatus`, `ProvisionDetail` | Writers | Written back in place (a `.bak` is taken once per run) |

### PlanStatus

| Status | Meaning | Writers act? |
|---|---|---|
| `Planned` | Named, validated, ready | Yes |
| `ManualOverride` | An operator set the target addresses by hand | Yes — and re-running the planner will not touch them |
| `UpnSmtpDiverge` | UPN and primary SMTP differ deliberately | Yes |
| `Collision` | Another object wanted the same address; a suffix or middle initial was applied | Only with `-IncludeCollisions` |
| `NeedsReview` | The template could not be completed (no surname, non-Latin script) — target columns left empty | No |
| `Invalid` | The produced address failed validation (length, characters, dots) | No |
| `Excluded` | Break-glass, service account, synced, disabled, guest, or a group Fly owns — see `ExcludeReason` | No |
| `ExistsInDestination` | An object with that identity is already there | No |

### How operators edit it

Open the CSV in Excel, fix what needs fixing, save as CSV, set `PlanStatus` to
`ManualOverride` on every row you touched. Re-run the planner with
`-ExistingPlanPath <that file>` and those rows — plus any row that already has a
`TargetObjectId` — keep their identities verbatim and are treated as reserved so nothing
new can take them. Collision suffixes are assigned in `SourceObjectId` order, so a re-run
never reshuffles names that are already provisioned.

### Interim vs target domain

The target vanity UPN cannot exist in the destination until the domain is verified there,
which cannot happen until the source releases it. So the plan carries both. Provision on
`Interim*` (`-UseInterim`), release the domain, verify it in the destination, then apply
`Target*` with `Set-MigrationIdentity`. Pass `-InterimDomain newco.onmicrosoft.com`; omit
it and the `Interim*` columns simply mirror `Target*` (fine when the domain has already
moved, or for an in-place redesign).

### UPN and SMTP formats

`-UpnFormat`, `-SmtpFormat` and `-MailNicknameFormat` each take a preset name or a raw
template. `-SmtpFormat` defaults to the UPN format; setting it separately is what produces
`jsmith@newco.onmicrosoft.com` sign-in with `john.smith@newco.com` mail — flagged
`UpnSmtpDiverge`, because those users then sign in with an address that is not their email
and the service desk needs to know.

Tokens: `{first} {last} {middle} {f} {m} {l} {source} {display}`, with truncation as
`{last:5}`. Names are NFD-decomposed and stripped of diacritics, lowercased, apostrophes
and spaces removed, hyphens kept (`O'Brien` → `obrien`, `van der Berg` → `vanderberg`,
`Smith-Jones` → `smith-jones`). An empty `{m}`/`{middle}` disappears along with its
separator; any other empty token means `NeedsReview` — the tool never guesses.

| Preset | Template | `John Andrew Smith` → |
|---|---|---|
| `First.Last` (default) | `{first}.{last}` | `john.smith` |
| `FLast` | `{f}{last}` | `jsmith` |
| `F.Last` | `{f}.{last}` | `j.smith` |
| `FirstLast` | `{first}{last}` | `johnsmith` |
| `First` | `{first}` | `john` |
| `First.L` | `{first}.{l}` | `john.s` |
| `FirstL` | `{first}{l}` | `johns` |
| `First.M.Last` | `{first}.{m}.{last}` | `john.a.smith` |
| `FMLast` | `{f}{m}{last}` | `jasmith` |
| `Last.First` | `{last}.{first}` | `smith.john` |
| `Keep` | `{source}` | source local part unchanged |

**Firstname-only source tenant → first.last target.** The source addresses are `john@`,
the destination wants `john.smith@`. The templates never read the source local part unless
you ask them to, so as long as the `Users` inventory carries `FirstName` and `LastName`
this is just the default:

```powershell
.\New-MigrationIdentityPlan.ps1 -UsersCsv .\Source_Users_*.csv -TargetDomain newco.com `
    -UpnFormat First.Last -SmtpFormat First.Last -Prefix Contoso
```

Rows with a blank surname come out `NeedsReview` with empty target columns — fill those in
by hand and mark them `ManualOverride`.

---

## Runbook

Each step is one command. Dry-run everything first.

**1. Inventory the source tenant** (read-only)

```powershell
.\Get-MigrationInventory.ps1 -Prefix Source -DelegatedOrganization contoso.onmicrosoft.com -IncludeAuthMethods
```

Nine tabs as CSVs plus one workbook: `Users`, `UserMailboxes`, `SharedMailboxes`,
`MailboxPermissions`, `Groups`, `Contacts`, `Domains`, `Licenses`, `Summary`.

**2. Inventory the destination tenant** (read-only)

```powershell
.\Get-MigrationInventory.ps1 -Prefix Destination -DelegatedOrganization newco.onmicrosoft.com
```

**3. Build the identity plan** (offline)

```powershell
.\New-MigrationIdentityPlan.ps1 -UsersCsv .\Source_Users_*.csv `
    -UserMailboxesCsv .\Source_UserMailboxes_*.csv -SharedMailboxesCsv .\Source_SharedMailboxes_*.csv `
    -GroupsCsv .\Source_Groups_*.csv -ContactsCsv .\Source_Contacts_*.csv `
    -TargetDomain newco.com -InterimDomain newco.onmicrosoft.com `
    -UpnFormat First.Last -SkuMapPath .\SkuMap.csv -ExclusionRulesPath .\ExclusionRules.csv `
    -ReservedAddressesPath .\Destination_Users_*.csv -Prefix Contoso
```

Review the plan with the client. Fix `NeedsReview`, `Collision` and `Invalid` rows.

**4. Export the Fly mapping file** (offline)

```powershell
.\Export-MigrationMappingFile.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Tool AvePoint -UseInterim -Prefix Contoso
```

**5. Readiness — Pre**

```powershell
.\Test-MigrationReadiness.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Stage Pre `
    -TenantId newco.onmicrosoft.com -DelegatedOrganization newco.onmicrosoft.com -Prefix Contoso
```

Must exit 0 before you provision anything.

**6. Provision users**

```powershell
.\New-MigrationUsers.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Wave 1 -UseInterim `
    -HideFromAddressLists -SetManagers -Prefix Contoso -DryRun
```

Drop `-DryRun` when the results file looks right; passwords land in the results CSV.

**7. Licence them**

```powershell
.\Set-MigrationLicenses.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Wave 1 -DefaultUsageLocation US -Prefix Contoso
```

Usage location first; group-assigned SKUs refused; the seat pre-check stops the run before
the first write if the tenant is short.

**8. Create mail recipients**

```powershell
.\New-MigrationRecipients.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Wave 1 -Mode CreateAndUpdate `
    -GroupsCsv .\Source_Groups_*.csv -ContactsCsv .\Source_Contacts_*.csv `
    -SharedMailboxesCsv .\Source_SharedMailboxes_*.csv -DelegatedOrganization newco.onmicrosoft.com -Prefix Contoso
```

Use `-Mode UpdateSettings` alone to patch settings onto groups Fly already created.

**9. Readiness — Provisioned**

```powershell
.\Test-MigrationReadiness.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Stage Provisioned `
    -SourceMailboxesCsv .\Source_UserMailboxes_*.csv -TenantId newco.onmicrosoft.com `
    -DelegatedOrganization newco.onmicrosoft.com -Prefix Contoso
```

Writes `MailboxProvisioned` / `OneDriveProvisioned` back to the plan.

**10. Run the Fly content jobs** — in the Fly console, using the mapping file from step 4.
Mailboxes, archives, OneDrive, SharePoint, Teams and M365 Groups. Let the pre-cutover
passes finish and re-run deltas until the deltas are small.

**11. Release the domain in the source tenant**

```powershell
# Report first - always
.\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -ReportOnly `
    -TenantId contoso.onmicrosoft.com -DelegatedOrganization contoso.onmicrosoft.com -Prefix Contoso

# Then remediate, with the acknowledgement
.\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -AcknowledgeSourceTenant `
    -TenantId contoso.onmicrosoft.com -DelegatedOrganization contoso.onmicrosoft.com -Prefix Contoso
```

Then remove the domain from the source tenant and verify it in the destination.

**12. Identity cutover**

```powershell
.\Set-MigrationIdentity.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Wave 1 `
    -Apply Upn,PrimarySmtp,Aliases,X500,MailNickname,GalVisibility -Unhide `
    -MatchOn TargetObjectId -DisableEmailAddressPolicy `
    -TenantId newco.onmicrosoft.com -DelegatedOrganization newco.onmicrosoft.com -Prefix Contoso
```

**13. Mailbox delegation**

```powershell
.\Set-MigrationMailboxPermissions.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv `
    -MailboxPermissionsCsv .\Source_MailboxPermissions_*.csv `
    -UserMailboxesCsv .\Source_UserMailboxes_*.csv -SharedMailboxesCsv .\Source_SharedMailboxes_*.csv `
    -Apply FullAccess,SendAs,SendOnBehalf,Calendar,Forwarding -Wave 1 -Prefix Contoso
```

**14. Cutover passwords**

```powershell
.\Reset-MigrationCutoverPasswords.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Wave 1 -Prefix Contoso
```

Credentials go to the results CSV only. Distribute them out of band.

**15. Teams Phone** — release in the source, reassign in the destination once numbers port.

```powershell
.\Get-MigrationTeamsPhoneAssignments.ps1 -Prefix Source -TenantId contoso.onmicrosoft.com -IncludeUnassignedNumbers
.\Remove-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Source_TeamsPhoneAssignments_*.csv -TenantId contoso.onmicrosoft.com
.\Set-MigrationTeamsPhoneAssignments.ps1 -ListUnassigned -TenantId newco.onmicrosoft.com
.\Set-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Source_TeamsPhoneAssignments_*.csv -TenantId newco.onmicrosoft.com
```

**16. Viva Learning** — optional.

```powershell
.\Get-MigrationVivaLearningHistory.ps1 -Prefix Source -TenantId contoso.onmicrosoft.com
.\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\Source_VivaLearningHistory_*.csv `
    -TenantId <destination-tenant-id> -ClientId <app-id> -ClientSecret (Read-Host -AsSecureString 'Secret') `
    -PlanPath .\Contoso_IdentityPlan_*.csv -Prefix Contoso -DryRun
```

**17. Readiness — Post**

```powershell
.\Test-MigrationReadiness.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -Stage Post `
    -TenantId newco.onmicrosoft.com -DelegatedOrganization newco.onmicrosoft.com -Prefix Contoso
```

**18. Compare** — inventory the destination again and diff it against the plan.

```powershell
.\Get-MigrationInventory.ps1 -Prefix Post -DelegatedOrganization newco.onmicrosoft.com
.\Compare-MigrationUserData.ps1 -PlanPath .\Contoso_IdentityPlan_*.csv -DifferenceCsv .\Post_Users_*.csv -Prefix Contoso
```

---

## In-place UPN redesign inside a single tenant

No second tenant, no Fly — just standardising an existing tenant's addressing.

```powershell
.\Get-MigrationInventory.ps1 -Prefix Fabrikam -DelegatedOrganization fabrikam.onmicrosoft.com
.\New-MigrationIdentityPlan.ps1 -UsersCsv .\Fabrikam_Users_*.csv `
    -UserMailboxesCsv .\Fabrikam_UserMailboxes_*.csv `
    -TargetDomain fabrikam.com -UpnFormat First.Last -Prefix Fabrikam
# review and edit the plan, then apply against the CURRENT addresses
.\Set-MigrationIdentity.ps1 -PlanPath .\Fabrikam_IdentityPlan_*.csv `
    -Apply Upn,PrimarySmtp,Aliases -MatchOn Source -DisableEmailAddressPolicy `
    -DelegatedOrganization fabrikam.onmicrosoft.com -Prefix Fabrikam -DryRun
```

`-MatchOn Source` is the whole trick: the objects already exist, so the plan's `Source*`
columns describe today and `Target*` describes the new scheme. The old primary is kept as
an alias unless you pass `-RemoveOldPrimaryAlias`. Directory-synced users are reported
`Failed` — those have to change in on-premises AD.

---

## Script reference

Columns: what it does; the parameters beyond the common `-OutputPath -Prefix -LogPath
-DryRun -Verbosity` set; what it reads; what it writes.

### Phase 1 — Discover (read-only)

| Script | Purpose | Key parameters | In → Out |
|---|---|---|---|
| `Get-MigrationInventory.ps1` | One read-only pull of a whole tenant | `-TenantId`, `-DelegatedOrganization`, `-DomainFilter`, `-IncludeGuests`, `-IncludeDisabled`, `-IncludeOneDrive`, `-IncludeAuthMethods`, `-SkipMailboxPermissions`, `-SkipMailboxStats`, `-SkipExcel` | Tenant → nine `<Prefix>_<Tab>_<ts>.csv` files plus one `.xlsx` |
| `Get-MigrationTeamsPhoneAssignments.ps1` | One row per user: number, type (`CallingPlan`/`OperatorConnect`/`DirectRouting`), enterprise voice, voice routing policy, dial plan, calling policy, emergency location | `-TenantId`, `-OnlyUsersWithNumbers`, `-IncludeUnassignedNumbers` | Tenant → `TeamsPhoneAssignments` CSV (+ unassigned-number CSV) |
| `Get-MigrationVivaLearningHistory.ps1` | Learner history: assignments and self-initiated courses, with course metadata. Delegated sign-in only | `-TenantId`, `-User`, `-IncludeGuests`, `-SkipCourseMetadata` | Tenant → `VivaLearningHistory` CSV + raw-JSON backup |
| `Compare-MigrationUserData.ps1` | Two modes: fuzzy CSV-to-CSV match, or destination inventory checked against the plan. Offline either way | `-ReferenceCsv` + `-DifferenceCsv` (+ `-SimilarityThreshold`), or `-PlanPath` + `-DifferenceCsv` (+ `-Wave`, `-ObjectType`) | Two CSVs → comparison CSV with `Status` and `MatchedOn` |

### Phase 2 — Plan (offline, no tenant connection)

| Script | Purpose | Key parameters | In → Out |
|---|---|---|---|
| `New-MigrationIdentityPlan.ps1` | Decides every destination identity: naming, collisions, validation, SKU map, X500 carry-across, waves | Inputs: `-UsersCsv` (required), `-UserMailboxesCsv`, `-SharedMailboxesCsv`, `-GroupsCsv`, `-ContactsCsv`, `-SkuMapPath`, `-ExclusionRulesPath`, `-WaveMapPath`, `-ReservedAddressesPath`, `-ExistingPlanPath`. Design: `-TargetDomain` (required), `-InterimDomain`, `-UpnFormat`, `-SmtpFormat`, `-MailNicknameFormat`, `-DefaultWave`, `-DefaultUsageLocation`, `-PreserveAliases`, `-AliasDomainMap`, `-IncludeDisabled`, `-IncludeGuests`, `-IncludeSynced` | Inventory CSVs → `<Prefix>_IdentityPlan_<ts>.csv` |
| `Export-MigrationMappingFile.ps1` | The mover's source→destination mapping file. Unmappable rows are reported `Skipped`, never dropped silently | `-PlanPath` (required), `-Tool` (default `AvePoint`), `-Wave`, `-ObjectType`, `-UseInterim`, `-SkipExcel` | Plan → mapping workbook + CSV twin |

### Phase 3 — Prepare the destination

| Script | Purpose | Key parameters | In → Out |
|---|---|---|---|
| `Test-MigrationReadiness.ps1` | `Pre`: domains verified, seats, usage locations, UPN/SMTP/alias/mailNickname clashes including soft-deleted holders, plan cleanliness. `Provisioned`: user, mailbox, archive, litigation hold, OneDrive, quota. `Post`: UPN, primary SMTP, aliases, X500, unhidden, enabled. Exits 2 on any failed check | `-PlanPath` (required), `-Stage Pre\|Provisioned\|Post`, `-Wave`, `-SourceMailboxesCsv`, `-TenantId`, `-DelegatedOrganization` | Plan + tenant → checks CSV; `Provisioned` writes `MailboxProvisioned` / `OneDriveProvisioned` back to the plan |
| `New-MigrationUsers.ps1` | Creates Entra accounts from the plan's `User` rows | `-PlanPath` (required), `-Wave`, `-UseInterim`, `-HideFromAddressLists`, `-AssignLicenses`, `-SetManagers`, `-ForceChangePassword`, `-PasswordLength`, `-DefaultUsageLocation`, `-IncludeCollisions`, `-TenantId` | Plan → accounts; writes `TargetObjectId` back; passwords to the results CSV only |
| `Set-MigrationLicenses.ps1` | Usage location first, then `assignLicense`. Refuses group-assigned SKUs both ways; seat pre-check stops the run unless `-Force` | `-PlanPath` (required), `-Wave`, `-SkuMapPath` (recomputes from `SourceLicenses` without regenerating the plan), `-RemoveUnplanned`, `-DefaultUsageLocation`, `-Force`, `-IncludeCollisions`, `-TenantId` | Plan (+ SKU map) → licence assignments, results CSV |
| `New-MigrationRecipients.ps1` | Shared/room/equipment mailboxes, DLs, mail-enabled security groups, dynamic DLs, mail contacts. Members, owners, moderators and delivery restrictions are translated through the plan; unmapped ones are reported, not guessed. Stamps X500 | `-PlanPath` (required), `-Type`, `-Mode Create\|UpdateSettings\|CreateAndUpdate`, `-Wave`, `-UseInterim`, `-GroupsCsv`, `-ContactsCsv`, `-SharedMailboxesCsv`, `-MailboxPermissionsCsv`, `-IncludeCollisions`, `-DelegatedOrganization` | Plan + source inventory → recipients, results CSV |

### Phase 4 — Cutover

| Script | Purpose | Key parameters | In → Out |
|---|---|---|---|
| `Remove-MigrationDomainReferences.ps1` | Source-side domain release. Always reports first and only remediates with `-AcknowledgeSourceTenant`. Exits 2 while blockers remain | `-Domain` (required), `-FallbackDomain` (default: the tenant's initial onmicrosoft domain), `-Scope Users,Groups,Contacts,Mailboxes`, `-ReportOnly`, `-AcknowledgeSourceTenant`, `-TenantId`, `-DelegatedOrganization` | Source tenant → References CSV + Blockers CSV, then remediation |
| `Set-MigrationIdentity.ps1` | Applies the plan's target identity. Additive by design: never removes the MOERA routing address, a SIP address or an existing X500. Directory-synced objects are a hard `Failed` | `-PlanPath` (required), `-Apply Upn,PrimarySmtp,Aliases,X500,GalVisibility,MailNickname`, `-MatchOn TargetObjectId\|Interim\|Source`, `-Wave`, `-RemoveOldPrimaryAlias`, `-DisableEmailAddressPolicy`, `-Unhide`, `-IncludeCollisions`, `-TenantId`, `-DelegatedOrganization` | Plan → tenant identities, results CSV |
| `Set-MigrationMailboxPermissions.ps1` | Re-applies delegation. Both sides mapped through the plan; the trustee map is built from the whole plan, not the wave. Idempotent — safe to re-run all weekend | `-PlanPath` and `-MailboxPermissionsCsv` (both required), `-UserMailboxesCsv`, `-SharedMailboxesCsv`, `-Apply FullAccess,SendAs,SendOnBehalf,Calendar,Forwarding`, `-Wave`, `-AutoMapping`, `-IncludeCollisions`, `-DelegatedOrganization` | Plan + source permission inventory → destination ACEs, results CSV |
| `Reset-MigrationCutoverPasswords.ps1` | Passphrase reset with change-at-next-sign-in | One of `-PlanPath` (+ `-Wave`, `-IncludeCollisions`), `-CsvPath`, `-Group` (object ID or display name, **not** the group's email) or `-TestUser`; plus `-WordCount`, `-ForceChangePassword`, `-TenantId` | Plan/CSV/group → resets; credentials to the results CSV only |
| `Set-MigrationTeamsPhoneAssignments.ps1` | Assigns numbers. Normalises `tel:`, spaces, dashes, a missing `+`, and preserves `;ext=`. A number already on a different user fails rather than being stolen | One of `-CsvPath`, `-User` + `-PhoneNumber` (+ `-PhoneNumberType`, `-LocationId`, `-VoiceRoutingPolicy`), or `-ListUnassigned`; plus `-TenantId` | CSV → assignments, results CSV |
| `Remove-MigrationTeamsPhoneAssignments.ps1` | Releases numbers, capturing number, type and policy first so the results CSV is the reassignment input. Hybrid `OnPremLineURI` numbers report `Failed` | One of `-User`, `-CsvPath` or `-All`; plus `-TenantId` | Tenant/CSV → removals, reassignment-ready results CSV |
| `Import-MigrationVivaLearningHistory.ps1` | Replays learner history under a **custom** provider (built-ins cannot be written to). Idempotent by external activity ID. Split auth: delegated for provider registration, app-only for content and activity writes | `-CsvPath`, `-TenantId`, `-ClientId` (all required), `-ClientSecret` or `-CertificateThumbprint`, `-LearningProviderId` (skips the interactive step), `-PlanPath`, `-TargetDomain`, `-KeepCsvDomains`, `-ProviderDisplayName`, `-LogoUrl`, `-DefaultLanguageTag` | History CSV + plan → destination learning records |

---

## Testing

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path Utilities/M365-Migration/Tests -Output Detailed"
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path Utilities/M365-Migration -Recurse -Severity Warning"
```

Pester 6. Pure functions (template engine, collision resolver, address validator, plan
reader/writer) are tested without mocks; anything touching Graph, Exchange or Teams is mocked
inside `InModuleScope`. The analyzer run must come back clean.

---

## Gotchas

| Gotcha | What happens | What to do |
|---|---|---|
| Missing X500 | Replies from cached Outlook entries and old calendar items bounce with an IMCEAEX NDR | Stamp `X500:<LegacyExchangeDN>` on every migrated recipient — `Set-MigrationIdentity -Apply X500`, and `New-MigrationRecipients` does it at creation |
| Email address policy | The org policy re-asserts the primary SMTP after you set it | Run with `-DisableEmailAddressPolicy`, which sets `EmailAddressPolicyEnabled $false` before the address write |
| Graph `PATCH /users {mail}` | Silently cosmetic on a mailbox-enabled user; Exchange owns `proxyAddresses` | Primary SMTP always goes through `Set-Mailbox -EmailAddresses`, never Graph. The toolkit does this for you |
| Group-based licensing | `assignLicense` cannot remove a group-inherited SKU, and re-adding one quietly doubles the assignment | `Set-MigrationLicenses` detects `assignedByGroup` and skips both directions. Remove the user from the group instead |
| Missing usage location | `assignLicense` fails, surfacing in the admin center as a vague "invalid usage location" | Set `UsageLocation` in the plan, or pass `-DefaultUsageLocation` |
| Soft-deleted users | Hold their UPN and proxy addresses; create and rename both return 409 "already exists" | `Test-MigrationReadiness -Stage Pre` finds them. Purge or restore them before provisioning |
| Renaming an admin's UPN | 403 `Authorization_RequestDenied` with only User Administrator | Use Privileged Authentication Administrator (or Global Admin) for admin accounts |
| Directory-synced objects | EXO and Entra are read-only for UPN and `proxyAddresses`; "out of the current user's write scope" | Change on-premises and let AAD Connect sync. Those rows report `Failed`, not `Skipped` |
| GAL hiding before a mailbox exists | `Set-Mailbox` has nothing to act on; Graph `showInAddressList` is a documented known issue and Exchange wins once a mailbox exists | Use `New-MigrationUsers -HideFromAddressLists` as a stopgap, then re-apply with `Set-MigrationIdentity -Apply GalVisibility` after licensing |
| Fly service account under MFA/CA | Content jobs fail to authenticate mid-run | Exclude it from MFA and Conditional Access in both tenants, and license it |
| Fly auto-licensing | Only works when there are **both** spare seats and a usage location | Run `Set-MigrationLicenses` first rather than relying on it |
| Teams chat migration | Mode-dependent and lossy — no reactions, no external chats, authorship shifts | Agree the chat mode with the client in writing before the job runs |
| Exchange Web Services retirement, 1 Oct 2026 | Any EWS-based mover path stops working | Confirm Fly is on its Graph-based path before scheduling a cutover near that date |
| Litigation hold | Movers refuse mailboxes that are on hold | `Test-MigrationReadiness -Stage Provisioned` reports it; clear the hold for the move window |
| Domain removal blockers | The domain will not delete while any user UPN, proxy address, group, mailbox or contact still references it | `Remove-MigrationDomainReferences -ReportOnly` lists every one. Guest `#EXT#` UPNs embed the *resource* tenant's domain and are informational, not blockers. The initial `.onmicrosoft.com` domain can never be removed |
| OneDrive not provisioned | `GET /users/{id}/drive` returns 404 and the mover has nowhere to write | Pre-provision with `Request-SPOPersonalSite -UserEmails <email>` (SharePoint Admin, user already licensed) |
| `Get-MailboxPermission` on a large tenant | "data exceeded max permitted by session (500MB)" | The inventory uses the REST-based `Get-EXOMailboxPermission`; keep `-SkipMailboxPermissions` in reserve for very large estates |
