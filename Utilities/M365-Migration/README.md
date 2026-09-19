# M365 Migration Toolkit

PowerShell 7 tooling for Microsoft 365 → Microsoft 365 tenant-to-tenant migrations,
built as a companion to **AvePoint Fly**. Fly moves the content. This toolkit does
everything Fly hands back to the MSP: identity design, destination provisioning,
licensing, mail recipients, delegation, domain release, cutover and verification.

## What this is

Seventeen phase scripts plus one shared module (`M365Migration/`). Every script imports
the module, reads and writes plain CSVs, and acts on a single artefact — the **identity
plan** — so no phase has to guess what an earlier phase decided.

Toolkit version **1.2.0**. The module manifest and every script's `.NOTES` block carry that
number, so a runbook can name the version it was written against and an operator can check what
they actually have in front of them.

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
| Modules | `Microsoft.Graph.Authentication`, `ExchangeOnlineManagement` (v3+), `MicrosoftTeams` (5.7.0+), `ImportExcel`. Installed for the current user on demand by `Initialize-MigrationModule`, which logs what it is about to install first. |
| Entra roles | User Administrator for user create/update; **Privileged Authentication Administrator** to change the UPN of, or reset the password of, another admin; Reports Reader or Global Reader for MFA registration counts; Domain Name Administrator to remove a domain. |
| Exchange roles | Exchange Administrator (recipient management, permissions, address policies). |
| Teams roles | Teams Administrator or Teams Communications Administrator. |
| SharePoint | SharePoint Administrator, only if you pre-provision OneDrive with `Request-SPOPersonalSite`. |
| Fly authorisation | A Global Admin in each tenant grants consent to Fly's app when the tenants are connected in the Fly console. A service account is *optional* — only needed when a specific Fly module asks for one (some Teams chat modes do). If you use one, license it and exclude it from MFA / Conditional Access for the duration of the project. Fly also needs site-collection-admin grants for the SPO/OneDrive sites it touches. |

### Signing in

The normal path is a **dedicated Global Admin account in the source tenant and a second one
in the destination tenant**, signed in to directly with each. Each account lives in the
tenant it administers, so nothing has to be delegated.

- **Every script prints the tenant id and display name it actually connected to.** Read that
  line before you let a writer run.
- The scripts reuse a cached session when one is open. Switching between the two accounts on
  one workstation means tearing the old session down first: `Disconnect-MgGraph` and
  `Disconnect-ExchangeOnline`. The module's `Connect-MigrationGraph` and
  `Connect-MigrationExchange` also accept `-Reconnect`, which signs out of the cached session
  before connecting.
- Pass `-TenantId <tenant>` where a script offers it — every script except the three offline
  ones (`Compare-MigrationUserData`, `New-MigrationIdentityPlan`, `Export-MigrationMappingFile`).
  It pins the sign-in, so a leftover session from the other tenant fails loudly instead of
  being reused silently. A GUID is compared as-is; a domain such as
  `contoso.onmicrosoft.com` is first resolved to its tenant GUID through the public,
  unauthenticated OIDC discovery document — one HTTPS call per connection the run checks, so
  a script holding both a Graph and an Exchange session makes two. Pass the GUID to avoid them.
- The four scripts that hold a Graph **and** an Exchange session (`Get-MigrationInventory`,
  `Test-MigrationReadiness`, `Set-MigrationIdentity`, `Remove-MigrationDomainReferences`) hold
  Exchange to the same tenant Graph signed in to even when you pass no `-TenantId`: a cached
  Exchange session belonging to another tenant is dropped and reconnected, and the run aborts if
  the two still disagree. `Set-MigrationMailboxPermissions` does the same for the one Exchange
  session it opens. `New-MigrationRecipients` connects first and checks afterwards — it aborts on
  a mismatch rather than reconnecting, so use `-DelegatedOrganization` or
  `Disconnect-ExchangeOnline` when switching tenants there.

**Landing in the wrong tenant is the expensive mistake.** A stale cached session, or a GDAP
connection made without `-DelegatedOrganization`, connects you somewhere you did not intend:
at best every mailbox lookup fails with "No mailbox found", at worst a cleanup script runs
against the wrong estate.

#### GDAP alternative

Where you administer a customer tenant as a partner through a GDAP relationship rather than
holding an account in it, sign in with your own partner credentials and point each connection
at the customer tenant.

- `Connect-MgGraph -TenantId <customer>` works for a partner user under an active GDAP
  relationship, scoped to whatever roles GDAP granted.
- `Connect-ExchangeOnline -DelegatedOrganization <customer>.onmicrosoft.com` is a
  **delegated/interactive** path, not app-only certificate auth. The two cannot be combined —
  cross-tenant app-only EXO needs a multitenant app with per-customer consent and
  `-Organization`, not `-DelegatedOrganization`.
- Known bug: WAM can drop GDAP claims. Add `-DisableWAM` to the EXO connect if a delegated
  session lands in your own tenant.

### Auth matrix

| Script | Graph (supports `-TenantId`) | EXO (supports GDAP `-DelegatedOrganization`) | Teams (supports `-TenantId`) | App-only |
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

"Yes" means the script connects to that service and accepts the parameter — it is a
capability column, not an instruction to sign in that way. With a dedicated Global Admin in
the tenant you need neither `-DelegatedOrganization` nor, strictly, `-TenantId`; pass
`-TenantId` anyway as the pin against a cached session.

`Set-MigrationMailboxPermissions` gained `-TenantId` in 1.2.0. It connects to Exchange Online
only, so the parameter pins that session rather than a Graph one; the rule is the same
everywhere — `-TenantId` names the tenant the script is allowed to touch.

Graph scopes are declared at the top of each script's Configuration region and verified
after sign-in; a missing scope throws by name rather than failing on the first call.

---

## Folder layout

```
Utilities/M365-Migration/
  README.md
  M365Migration/            shared module (manifest + Public/ + Private/); imported by every script
  Templates/                IdentityPlan.sample.csv, SkuMap.sample.csv,
                            ExclusionRules.sample.csv, WaveMap.sample.csv
  Tests/                    Pester 6 suites, one per script and per pure function
  Docs/                     source HTML for the published Hudu article, plus the two backlogs
  *.ps1                     the 17 phase scripts
```

Copy the whole folder to run it; the scripts are no longer individually standalone.

`ExclusionRules.sample.csv` shows the optional fourth column, `MatchType` — `Wildcard` (the
default when the column is absent) or `Regex`. `WaveMap.sample.csv` is the
`UserPrincipalName,Wave` file `-WaveMapPath` takes; every address it does not name gets
`-DefaultWave`.

`Docs/KnownDocGaps.md` lists the places this README and the runbook are known to mislead a
first-time operator, each one found during a live migration. Read it before following the
runbook, and add to it whenever a run is lost to something the docs should have said.

`Docs/EnhancementBacklog.md` collects wanted behaviour changes noticed while running the
toolkit for real - friction rather than defects.

---

## Conventions

| Aspect | Detail |
|---|---|
| Output root | `%LOCALAPPDATA%\Migration-Automations` on Windows, `~/Migration-Automations` elsewhere. Override with `-OutputPath`. |
| `-Prefix` | Names the client or run. Output lands in `<root>\<Prefix>\` and every filename starts with `<Prefix>_`. Use `Source` and `Destination` for the two inventories. Anything a filename cannot carry is replaced with a hyphen, underscores included — `_` is the filename contract's separator, so `-Prefix Client_A` becomes `Client-A`. |
| Logging | `Initialize-MigrationRun` opens `<Prefix>_<ScriptName>_<yyyyMMdd-HHmmss>.log` in the output directory and records the parameters (never secrets). The `<Prefix>_` leader is dropped when no `-Prefix` was given. `-LogPath` overrides the whole path, except on the two Viva Learning scripts, which have no `-LogPath` at all. `-Verbosity Low\|Medium\|High` controls the console only — the log always gets everything. |
| DryRun | One semantic on every writer: compute everything, write the results file with Status `Planned`, change nothing. Every mutation goes through `Invoke-MigrationAction`, which is the single place a write can happen, so the promise holds regardless of which scopes the sign-in asked for. It is **not** a read-only sign-in: only `New-MigrationUsers`, `Remove-MigrationDomainReferences` and `Import-MigrationVivaLearningHistory` narrow their Graph scopes under `-DryRun`; `Set-MigrationIdentity`, `Set-MigrationLicenses` and `Reset-MigrationCutoverPasswords` request the same `ReadWrite` scopes as a live run, and Exchange and Teams sessions are role-based with no read-only mode. `-WhatIf` is honoured independently at the row level on every writer, and a declined row is reported as `Skipped` with the detail `Declined at the confirmation prompt.` - `Planned` is reserved for `-DryRun`. Two exceptions: `Get-MigrationInventory -DryRun` writes only the log, never a results CSV (discovery, not a writer); `Test-MigrationReadiness`'s checks are already read-only, so `-DryRun` there only suppresses the Provisioned-stage plan writeback and the OneDrive read that would provision a drive — its rows keep their normal Succeeded/Failed/Skipped status. |
| Results CSV | `<Prefix>_<Name>-Results_<ts>.csv`, or `-DryRun_` in place of `-Results_`. `<Name>` is the script's own name with `Migration` removed: `Set-MigrationIdentity.ps1` writes `Set-Identity`, `New-MigrationUsers.ps1` writes `New-Users`. A **second** output from the same script takes a `-Suffix` rather than a new name — `TeamsPhoneNumbers-Unassigned`. `Get-MigrationOutputPath` owns the whole contract, which is why prefix, name and suffix may not contain an underscore: the underscore is what separates them. Columns always begin `Identity, Action, Status, Detail`; script-specific columns follow. Status ∈ `Planned \| Succeeded \| Skipped \| Failed`. Exception: `Compare-MigrationUserData` never writes those four — see its Phase 1 table row. |
| Mapping workbook | `Export-MigrationMappingFile` writes `<Prefix>_Fly_User_Mapping_<ts>.xlsx` and its CSV twin. That name is deliberately **off** the filename contract: it is the name AvePoint Fly's import expects, underscores and all, so it is left alone rather than renamed to fit. Its results file (`<Prefix>_Export-MappingFile-Results_<ts>.csv`) is on the contract like every other. |
| Exit codes | `0` completed · `1` fatal error · `2` some rows failed · `3` work remains. `2` also covers failed checks in `Test-MigrationReadiness` and any `Missing`/`Mismatch` row for `Compare-MigrationUserData` in plan mode (its CSV mode always exits 0). `3` is used by `Remove-MigrationDomainReferences` alone — references to the domain remain, or the scan did not finish — and a row failure outranks it, so that script exits `2` when both are true. |
| Waves | Every writer takes `-Wave <label[]>` and processes only matching plan rows. Waves are labels, not numbers — `1`, `Pilot`, `Finance` all work. |
| Passwords | Generated credentials go to the results CSV only, never to the log. Store that file the way you would store any other password list — and read "Credentials and the rescue copy" below. |

### Where output lands, and the paths in these examples

Each `-Prefix` gets its own folder under the output root, so the source inventory, the
destination inventory and the run's own artefacts live in **different folders**. No single
working directory makes a relative path work, which is why every example below uses an absolute
path built from these variables. Set them once per run:

```powershell
$Root      = Join-Path $env:LOCALAPPDATA 'Migration-Automations'  # ~/Migration-Automations off Windows
$SourceDir = Join-Path $Root 'Source'       # written by Get-MigrationInventory -Prefix Source
$DestDir   = Join-Path $Root 'Destination'  # written by Get-MigrationInventory -Prefix Destination
$RunDir    = Join-Path $Root 'Contoso'      # everything run with -Prefix Contoso
```

The `20260401-090000` stamps in the examples are placeholders. Every output filename carries
the timestamp of the run that wrote it, so substitute the ones actually on disk.

### Renamed output files in 1.2.0

The results-name rule above is new, so four filenames changed. Nothing reads these by name
today, but a saved runbook, a scheduled cleanup or a folder full of earlier runs might.

| Was (1.1.x) | Now (1.2.0) | Written by |
|---|---|---|
| `<Prefix>_Set-MigrationLicenses-Results_<ts>.csv` | `<Prefix>_Set-Licenses-Results_<ts>.csv` | `Set-MigrationLicenses.ps1` |
| `<Prefix>_Test-MigrationReadiness-Results_<ts>.csv` | `<Prefix>_Test-Readiness-Results_<ts>.csv` | `Test-MigrationReadiness.ps1` |
| `<Prefix>_MappingFile-Results_<ts>.csv` | `<Prefix>_Export-MappingFile-Results_<ts>.csv` | `Export-MigrationMappingFile.ps1` |
| `<Prefix>_Set-TeamsPhoneNumbers-Unassigned-Results_<ts>.csv` | `<Prefix>_Set-TeamsPhoneAssignments-Results_<ts>.csv` | `Set-MigrationTeamsPhoneAssignments.ps1 -ListUnassigned` |

One more rename, this time driven by the `-Prefix` you pass rather than by a script's name:
an underscore in a prefix is now replaced with a hyphen, because `_` is what separates the
parts of a filename. `-Prefix Client_A` therefore writes `Client-A_...` files into
`<root>\Client-A\`, not `<root>\Client_A\` — the **run folder moves** for such a prefix, so
earlier runs stay in the old folder.

The unassigned-number listing itself is **unchanged**: both Teams scripts still write
`<Prefix>_TeamsPhoneNumbers-Unassigned_<ts>.csv`, so their output stays interchangeable. Every
other results file — `New-Users`, `Set-Identity`, `New-Recipients`, `Reset-CutoverPasswords`,
`Remove-DomainReferences`, `Compare-UserData` and the rest — already followed the rule and
kept its name.

### Credentials and the rescue copy

`New-MigrationUsers` and `Reset-MigrationCutoverPasswords` mint credentials, and a minted
credential exists nowhere but the results file. Both write that file from a `finally` block, so
a session that drops mid-run still produces the list for the rows that already succeeded.

If the run folder cannot be written to — read-only, full, or gone — the rows go to the system
temp folder instead, under the same filename contract, and the run logs:

```
Results could not be written to <run folder>; a copy was saved to <temp path>. Move it into
the run folder. Original error: <the original error>
```

**That rescue copy is a password list sitting in the machine's temp folder, and the toolkit
never deletes it.** Move it into the run folder and secure it yourself. If the temp write
fails too, the run exits `1` and logs how many credentials were lost — never the credentials
themselves.

The `GeneratedPassword` column is the one cell exempt from the formula-prefix sanitiser every
other value passes through: the generators draw from a pool containing `-`, `=`, `+` and `@`,
and a sanitised copy would not be the password the account actually has. The warning that the
results file is a password list fires for **any** row carrying one, including a `Failed` row
whose write may still have landed.

---

## The identity plan

`New-MigrationIdentityPlan` reads the source inventory CSVs and writes one
`<Prefix>_IdentityPlan_<ts>.csv`. Every later phase reads it; several write back into it.
`Templates/IdentityPlan.sample.csv` carries the exact column order.

| Column group | Filled by | Notes |
|---|---|---|
| `ObjectType`, `Wave` | Plan / wave map | `User`, `Guest`, `Shared`, `Room`, `Equipment`, `Distribution`, `MailEnabledSecurity`, `DynamicDistribution`, `Contact`, `M365Group` (informational — Fly owns those) |
| `SourceObjectId`, `SourceUserPrincipalName`, `SourcePrimarySmtp`, `SourceAliases`, `LegacyExchangeDN`, `SourceX500` | Plan | `;`-separated lists; aliases stored as `smtp:alias@domain`, X500 as `X500:/o=...` |
| `DisplayName`, `FirstName`, `MiddleName`, `LastName`, `JobTitle`, `Department`, `Office`, `MobilePhone`, `City`, `State`, `Country`, `PostalCode`, `StreetAddress`, `CompanyName`, `EmployeeId`, `EmployeeType`, `BusinessPhone`, `FaxNumber`, `PreferredLanguage`, `UsageLocation`, `ManagerUpn` | Plan | Passthrough from the source Entra profile. `ManagerUpn` is re-resolved to the target account at provisioning. `BusinessPhone` is the first entry of the source's `businessPhones`. |
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
| `Collision` | Another object wanted the same address (a suffix or middle initial was applied), or two rows would share a `TargetMailNickname` (the later one is renamed with a numeric suffix) | Only with `-IncludeCollisions` |
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

**The one-line test: if `-TargetDomain` already appears in the destination inventory's
`Domains` CSV, omit `-InterimDomain`.** An interim domain is needed only while the target
domain is still held by the source tenant and therefore cannot be verified in the
destination. Passing one when the domain is already verified there buys nothing but a
provision-then-rename cycle you will have to run and check. The runbook's main example
omits it for that reason; the interim case is the variant below it.

### UPN and SMTP formats

`-UpnFormat`, `-SmtpFormat` and `-MailNicknameFormat` each take a preset name or a raw
template. `-SmtpFormat` defaults to the UPN format; setting it separately is what produces
`jsmith@newco.com` sign-in with `john.smith@newco.com` mail — flagged `UpnSmtpDiverge`,
because those users then sign in with an address that is not their email and the service
desk needs to know.

#### One domain, or two

By default `-TargetDomain` builds the UPN **and** the primary SMTP address, so the two always
share a domain and `-SmtpFormat` can only make them differ in the local part. Pass
`-SmtpDomain` and they split by domain as well: the UPN is built in `-TargetDomain`, the
primary SMTP address in `-SmtpDomain`. That is the destination whose convention is "sign in on
the parent domain, receive mail on the acquired company's domain".

```powershell
.\New-MigrationIdentityPlan.ps1 -UsersCsv "$SourceDir\Source_Users_20260401-090000.csv" `
    -TargetDomain newco.com -SmtpDomain mail.newco.com -UpnFormat First.Last -Prefix Contoso
```

`John Smith` is then planned as `john.smith@newco.com` to sign in with and
`john.smith@mail.newco.com` to receive mail on. Three consequences before you reach for it:

- **`-InterimDomain` then applies to the sign-in address only.** `InterimPrimarySmtp` comes out
  equal to `TargetPrimarySmtp`, because the mail address is planned directly on `-SmtpDomain`
  and never routed through the interim domain. The planner says so in a warning rather than
  leaving you to infer it from the plan.
- **Collisions and reserved addresses are judged per domain** — the UPN against `-TargetDomain`,
  the SMTP address against `-SmtpDomain` — so a name already taken in the sign-in domain does
  not put a suffix on the mail address, or the other way round.
- **Every row whose two domains differ is marked `UpnSmtpDiverge`**, exactly as a local-part
  divergence is.

Both domains have to be verified in the destination tenant before those addresses can be
applied, so a mail domain still held by the source tenant is a release-the-domain problem
first (runbook step 11) and a planning problem second.

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
.\New-MigrationIdentityPlan.ps1 -UsersCsv "$SourceDir\Source_Users_20260401-090000.csv" `
    -TargetDomain newco.com -UpnFormat First.Last -SmtpFormat First.Last -Prefix Contoso
```

Rows with a blank surname come out `NeedsReview` with empty target columns — fill those in
by hand and mark them `ManualOverride`.

---

## Runbook

Each step is one command. Dry-run everything first. The examples use the `$Root` / `$SourceDir`
/ `$DestDir` / `$RunDir` variables defined under
[Where output lands](#where-output-lands-and-the-paths-in-these-examples).

**Wildcards.** `-PlanPath` — and `-ExistingPlanPath` in the planner — go through
`Import-MigrationPlan`, which resolves a wildcard when it matches exactly one file; zero
matches or more than one is an error. Every other CSV input (`-UsersCsv`, `-CsvPath`,
`-DifferenceCsv`, `-MailboxPermissionsCsv`, `-SharedMailboxesCsv`, `-GroupsCsv`,
`-ContactsCsv`, `-SourceMailboxesCsv`, `-ReservedAddressesPath`, etc. — via
`Import-MigrationCsv`) is read with `-LiteralPath` and does **not** expand a wildcard. Name
the file or tab-complete it. That is why only the `-PlanPath` examples below carry a `*`.

**Empty optional inventories.** A tenant with no shared mailboxes, or no contacts, still gets
a header-only CSV from the inventory. `New-MigrationIdentityPlan` treats a header-only
*optional* input as empty and says so in a warning; every other script still rejects one with
"contains no data rows". Outside the planner, drop the argument rather than passing the empty
file.

**Confirmation.** Every writer supports `-WhatIf` and `-Confirm`. Seven of them prompt at the
default `$ConfirmPreference` of `High`:

| Script | Prompts |
|---|---|
| `Set-MigrationIdentity` | once per operation, per row |
| `Set-MigrationMailboxPermissions` | once per permission |
| `Reset-MigrationCutoverPasswords` | once per user |
| `Set-MigrationTeamsPhoneAssignments` | once per number |
| `Remove-MigrationTeamsPhoneAssignments` | once per number |
| `Import-MigrationVivaLearningHistory` | per provider step, course and activity |
| `Remove-MigrationDomainReferences` | once per run, immediately before it remediates |

`Set-MigrationLicenses` also declares `ConfirmImpact = 'High'` in 1.2.0 — a licence change is
billable, and removing one is destructive — but its per-row gate sits in a helper at the
default impact, so a default-configured session is not actually prompted. Pass
`-Confirm:$false` there too: a lowered inherited `$ConfirmPreference` does reach that helper.
`-AcknowledgeLicenseRemoval` is the real gate on `-RemoveUnplanned`, not the prompt.

Pass `-Confirm:$false` on any unattended run. A `-DryRun` rehearsal can prompt as well —
`-DryRun` and `ShouldProcess` are independent gates, and only some scripts skip the prompt when
they already know they will change nothing — so the examples below carry `-Confirm:$false` even
where they carry `-DryRun`.

**1. Inventory the source tenant** (read-only)

```powershell
.\Get-MigrationInventory.ps1 -Prefix Source -TenantId contoso.onmicrosoft.com -IncludeAuthMethods
```

Nine tabs as CSVs plus one workbook: `Users`, `UserMailboxes`, `SharedMailboxes`,
`MailboxPermissions`, `Groups`, `Contacts`, `Domains`, `Licenses`, `Summary`.

**2. Inventory the destination tenant** (read-only)

```powershell
.\Get-MigrationInventory.ps1 -Prefix Destination -TenantId newco.onmicrosoft.com
```

**3. Build the identity plan** (offline)

```powershell
.\New-MigrationIdentityPlan.ps1 `
    -UsersCsv "$SourceDir\Source_Users_20260401-090000.csv" `
    -UserMailboxesCsv "$SourceDir\Source_UserMailboxes_20260401-090000.csv" `
    -SharedMailboxesCsv "$SourceDir\Source_SharedMailboxes_20260401-090000.csv" `
    -GroupsCsv "$SourceDir\Source_Groups_20260401-090000.csv" `
    -ContactsCsv "$SourceDir\Source_Contacts_20260401-090000.csv" `
    -ReservedAddressesPath "$DestDir\Destination_Users_20260401-093000.csv" `
    -SkuMapPath "$RunDir\SkuMap.csv" -ExclusionRulesPath "$RunDir\ExclusionRules.csv" `
    -TargetDomain newco.com -UpnFormat First.Last -Prefix Contoso
```

Review the plan with the client. Fix `NeedsReview`, `Collision` and `Invalid` rows.

> **Interim-domain variant.** For when `newco.com` is still held by the source tenant — that
> is, when it is *not* in the destination inventory's `Domains` CSV. Add
> `-InterimDomain newco.onmicrosoft.com` to the command above, then `-UseInterim` in steps 4,
> 6 and 8 so the mapping file, the new accounts and the new recipients all use the routing
> address. Step 12 puts the vanity addresses on afterwards. If the domain is already verified
> in the destination, leave all four off.

**4. Export the Fly mapping file** (offline)

```powershell
.\Export-MigrationMappingFile.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" `
    -Tool AvePoint -Prefix Contoso
```

Add `-UseInterim` when the plan was built with an interim domain.

**5. Readiness — Pre**

```powershell
.\Test-MigrationReadiness.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Stage Pre `
    -TenantId newco.onmicrosoft.com -Prefix Contoso
```

Must exit 0 before you provision anything.

**6. Provision users**

```powershell
.\New-MigrationUsers.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Wave 1 `
    -HideFromAddressLists -SetManagers -TenantId newco.onmicrosoft.com `
    -Prefix Contoso -Confirm:$false -DryRun
```

Drop `-DryRun` when the results file looks right; passwords land in the results CSV (and
nowhere else — see "Credentials and the rescue copy"). Add `-UseInterim` for the interim
variant.

**7. Licence them**

```powershell
.\Set-MigrationLicenses.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Wave 1 `
    -DefaultUsageLocation US -TenantId newco.onmicrosoft.com -Prefix Contoso -Confirm:$false
```

Usage location first; group-assigned SKUs refused; the seat pre-check stops the run before
the first write if the tenant is short. This script became `ConfirmImpact` High in 1.2.0, so
`-Confirm:$false` belongs on any unattended run even though a default-configured session is
not prompted (see Confirmation above). `-RemoveUnplanned` refuses to start at all without
`-AcknowledgeLicenseRemoval`: stripping the Exchange licence starts the 30-day clock after
which Microsoft 365 deletes the mailbox.

**8. Create mail recipients**

```powershell
.\New-MigrationRecipients.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Wave 1 `
    -Mode CreateAndUpdate `
    -GroupsCsv "$SourceDir\Source_Groups_20260401-090000.csv" `
    -ContactsCsv "$SourceDir\Source_Contacts_20260401-090000.csv" `
    -SharedMailboxesCsv "$SourceDir\Source_SharedMailboxes_20260401-090000.csv" `
    -TenantId newco.onmicrosoft.com -Prefix Contoso -Confirm:$false
```

Use `-Mode UpdateSettings` alone to patch settings onto groups Fly already created. Add
`-UseInterim` for the interim variant.

**9. Readiness — Provisioned**

```powershell
.\Test-MigrationReadiness.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Stage Provisioned `
    -SourceMailboxesCsv "$SourceDir\Source_UserMailboxes_20260401-090000.csv" `
    -TenantId newco.onmicrosoft.com -Prefix Contoso
```

Writes `MailboxProvisioned` / `OneDriveProvisioned` back to the plan.

**10. Run the Fly content jobs** — in the Fly console, using the mapping file from step 4.
Mailboxes, archives, OneDrive, SharePoint, Teams and M365 Groups. Let the pre-cutover
passes finish and re-run deltas until the deltas are small.

**11. Release the domain in the source tenant**

```powershell
# Report first - always
.\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -ReportOnly `
    -TenantId contoso.onmicrosoft.com -Prefix Contoso

# Then remediate, with the acknowledgement
.\Remove-MigrationDomainReferences.ps1 -Domain contoso.com -AcknowledgeSourceTenant `
    -TenantId contoso.onmicrosoft.com -Prefix Contoso -Confirm:$false
```

Exit `3` means references to the domain are still there, or the scan did not finish — re-run
the report and work through the Blockers CSV. Exit `2` means a row failed. Only exit `0` means
the domain is clear. Then remove it from the source tenant and verify it in the destination.

**12. Identity cutover**

```powershell
.\Set-MigrationIdentity.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Wave 1 `
    -Apply Upn,PrimarySmtp,Aliases,X500,MailNickname,GalVisibility -Unhide `
    -MatchOn TargetObjectId -Confirm:$false `
    -TenantId newco.onmicrosoft.com -Prefix Contoso
```

**13. Mailbox delegation**

```powershell
.\Set-MigrationMailboxPermissions.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" `
    -MailboxPermissionsCsv "$SourceDir\Source_MailboxPermissions_20260401-090000.csv" `
    -UserMailboxesCsv "$SourceDir\Source_UserMailboxes_20260401-090000.csv" `
    -SharedMailboxesCsv "$SourceDir\Source_SharedMailboxes_20260401-090000.csv" `
    -Apply FullAccess,SendAs,SendOnBehalf,Calendar,Forwarding -Wave 1 `
    -TenantId newco.onmicrosoft.com -Prefix Contoso -Confirm:$false
```

`-Confirm:$false` is needed here too — same High `ConfirmImpact`, per-object prompts as
step 12. `-TenantId` arrived in 1.2.0: this script connects to Exchange Online only, and the
parameter pins that session so a leftover source-tenant session cannot be reused silently.

**14. Cutover passwords**

```powershell
.\Reset-MigrationCutoverPasswords.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Wave 1 `
    -TenantId newco.onmicrosoft.com -Prefix Contoso -Confirm:$false
```

Same `-Confirm:$false` reason as steps 12-13: `ConfirmImpact` is High with a per-user
prompt. Credentials go to the results CSV only. Distribute them out of band.

**15. Teams Phone** — release in the source, reassign in the destination once numbers port.

```powershell
.\Get-MigrationTeamsPhoneAssignments.ps1 -Prefix Source -TenantId contoso.onmicrosoft.com `
    -IncludeUnassignedNumbers

.\Remove-MigrationTeamsPhoneAssignments.ps1 `
    -CsvPath "$SourceDir\Source_TeamsPhoneAssignments_20260401-091500.csv" `
    -TenantId contoso.onmicrosoft.com -Prefix Source -Confirm:$false

.\Set-MigrationTeamsPhoneAssignments.ps1 -ListUnassigned -TenantId newco.onmicrosoft.com `
    -Prefix Destination

.\Set-MigrationTeamsPhoneAssignments.ps1 `
    -CsvPath "$SourceDir\Source_TeamsPhoneAssignments_20260401-091500.csv" `
    -TenantId newco.onmicrosoft.com -Prefix Destination -Confirm:$false
```

`-ListUnassigned` makes no changes and needs no confirmation; the other two are
`ConfirmImpact` High with a per-number prompt, hence `-Confirm:$false`.

`Remove-MigrationTeamsPhoneAssignments -All` releases every number in the tenant, so it
refuses to start without `-AcknowledgeSourceTenant` — the switch that says the tenant in
`-TenantId` is the one being decommissioned. Nothing in the run puts the numbers back
automatically, so only use it on a tenant you are certain of:

```powershell
.\Remove-MigrationTeamsPhoneAssignments.ps1 -All -TenantId contoso.onmicrosoft.com `
    -AcknowledgeSourceTenant -Prefix Source -Confirm:$false
```

**16. Viva Learning** — optional.

```powershell
.\Get-MigrationVivaLearningHistory.ps1 -Prefix Source -TenantId contoso.onmicrosoft.com

.\Import-MigrationVivaLearningHistory.ps1 `
    -CsvPath "$SourceDir\Source_VivaLearningHistory_20260401-092000.csv" `
    -TenantId newco.onmicrosoft.com `
    -ClientId 00000000-0000-0000-0000-000000000001 `
    -ClientSecret (Read-Host -AsSecureString 'Secret') `
    -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Prefix Contoso -Confirm:$false -DryRun
```

`-ClientId` is the app registration you created for the custom learning provider; the GUID
above is a placeholder. Neither Viva script takes `-LogPath`.

**17. Readiness — Post**

```powershell
.\Test-MigrationReadiness.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" -Stage Post `
    -TenantId newco.onmicrosoft.com -Prefix Contoso
```

**18. Compare** — inventory the destination again and diff it against the plan.

```powershell
$PostDir = Join-Path $Root 'Post'
.\Get-MigrationInventory.ps1 -Prefix Post -TenantId newco.onmicrosoft.com
.\Compare-MigrationUserData.ps1 -PlanPath "$RunDir\Contoso_IdentityPlan_*.csv" `
    -DifferenceCsv "$PostDir\Post_Users_20260415-140000.csv" -Prefix Contoso
```

---

## In-place UPN redesign inside a single tenant

No second tenant, no Fly — just standardising an existing tenant's addressing.

```powershell
$FabrikamDir = Join-Path $Root 'Fabrikam'

.\Get-MigrationInventory.ps1 -Prefix Fabrikam -TenantId fabrikam.onmicrosoft.com
.\New-MigrationIdentityPlan.ps1 `
    -UsersCsv "$FabrikamDir\Fabrikam_Users_20260401-090000.csv" `
    -UserMailboxesCsv "$FabrikamDir\Fabrikam_UserMailboxes_20260401-090000.csv" `
    -TargetDomain fabrikam.com -UpnFormat First.Last -Prefix Fabrikam

# review and edit the plan, then apply against the CURRENT addresses
.\Set-MigrationIdentity.ps1 -PlanPath "$FabrikamDir\Fabrikam_IdentityPlan_*.csv" `
    -Apply Upn,PrimarySmtp,Aliases -MatchOn Source `
    -TenantId fabrikam.onmicrosoft.com -Prefix Fabrikam -Confirm:$false -DryRun
```

`-MatchOn Source` is the whole trick: the objects already exist, so the plan's `Source*`
columns describe today and `Target*` describes the new scheme. The old primary is kept as
an alias unless you pass `-RemoveOldPrimaryAlias`. Directory-synced users are reported
`Failed` — those have to change in on-premises AD. `ConfirmImpact` is High, so the run
prompts per operation unless you pass `-Confirm:$false` as above — a `-DryRun` rehearsal
included.

---

## Script reference

Columns: what it does; the parameters beyond the common `-OutputPath -Prefix -DryRun
-Verbosity` set (every script also takes `-LogPath` except the two Viva Learning scripts,
`Get-MigrationVivaLearningHistory` and `Import-MigrationVivaLearningHistory`, which have no
`-LogPath` at all); what it reads; what it writes.

### Phase 1 — Discover (read-only)

| Script | Purpose | Key parameters | In → Out |
|---|---|---|---|
| `Get-MigrationInventory.ps1` | One read-only pull of a whole tenant | `-TenantId`, `-DelegatedOrganization`, `-DomainFilter`, `-IncludeGuests`, `-IncludeDisabled`, `-IncludeOneDrive`, `-IncludeAuthMethods`, `-SkipMailboxPermissions`, `-SkipMailboxStats`, `-SkipExcel` | Tenant → nine `<Prefix>_<Tab>_<ts>.csv` files plus one `.xlsx` |
| `Get-MigrationTeamsPhoneAssignments.ps1` | One row per user: number, type (`CallingPlan`/`OperatorConnect`/`OCMobile`/`DirectRouting`), enterprise voice, voice routing policy, dial plan, calling policy, emergency location | `-TenantId`, `-OnlyUsersWithNumbers`, `-IncludeUnassignedNumbers` | Tenant → `TeamsPhoneAssignments` CSV (+ unassigned-number CSV) |
| `Get-MigrationVivaLearningHistory.ps1` | Learner history: assignments and self-initiated courses, with course metadata. Delegated sign-in only | `-TenantId`, `-User`, `-IncludeGuests`, `-SkipCourseMetadata` | Tenant → `VivaLearningHistory` CSV + raw-JSON backup |
| `Compare-MigrationUserData.ps1` | Two modes: fuzzy CSV-to-CSV match, or destination inventory checked against the plan. Offline either way | `-ReferenceCsv` + `-DifferenceCsv` (+ `-SimilarityThreshold`), or `-PlanPath` + `-DifferenceCsv` (+ `-Wave`, `-ObjectType`) | CSV mode → comparison CSV, `Status` ∈ `Exact Match \| Partial Match \| No Match`; plan mode → `Status` ∈ `Match \| Mismatch \| Missing \| Extra \| Skipped`, exit 2 on any `Missing`/`Mismatch` |

### Phase 2 — Plan (offline, no tenant connection)

| Script | Purpose | Key parameters | In → Out |
|---|---|---|---|
| `New-MigrationIdentityPlan.ps1` | Decides every destination identity: naming, collisions, validation, SKU map, X500 carry-across, waves | Inputs: `-UsersCsv` (required), `-UserMailboxesCsv`, `-SharedMailboxesCsv`, `-GroupsCsv`, `-ContactsCsv`, `-SkuMapPath`, `-ExclusionRulesPath`, `-WaveMapPath`, `-ReservedAddressesPath`, `-ExistingPlanPath`. Design: `-TargetDomain` (required), `-SmtpDomain` (mail in a different domain from the UPN — marks the rows `UpnSmtpDiverge` and judges collisions per domain), `-InterimDomain`, `-UpnFormat`, `-SmtpFormat`, `-MailNicknameFormat`, `-DefaultWave`, `-DefaultUsageLocation`, `-PreserveAliases`, `-AliasDomainMap`, `-IncludeDisabled`, `-IncludeGuests`, `-IncludeSynced` | Inventory CSVs → `<Prefix>_IdentityPlan_<ts>.csv` |
| `Export-MigrationMappingFile.ps1` | The mover's source→destination mapping file. Maps only `Planned`, `ManualOverride` and `UpnSmtpDiverge` rows (`Collision` too with `-IncludeCollisions`); everything else is reported `Skipped`, never dropped silently | `-PlanPath` (required), `-Tool` (default `AvePoint`), `-Wave`, `-ObjectType`, `-UseInterim`, `-IncludeCollisions`, `-SkipExcel` | Plan → mapping workbook + CSV twin |

### Phase 3 — Prepare the destination

| Script | Purpose | Key parameters | In → Out |
|---|---|---|---|
| `Test-MigrationReadiness.ps1` | `Pre`: domains verified, seats, usage locations, UPN/SMTP/alias/mailNickname clashes including soft-deleted holders (UPN and primary address only), plan cleanliness. `Provisioned`: user, mailbox, archive, litigation hold, OneDrive, quota. `Post`: UPN, primary SMTP, aliases, X500, unhidden, enabled. Exits 2 on any failed check | `-PlanPath` (required), `-Stage Pre\|Provisioned\|Post`, `-Wave`, `-SourceMailboxesCsv`, `-TenantId`, `-DelegatedOrganization` | Plan + tenant → checks CSV; `Provisioned` writes `MailboxProvisioned` / `OneDriveProvisioned` back to the plan |
| `New-MigrationUsers.ps1` | Creates Entra accounts from the plan's `User` rows, carrying over job title, department, office, mobile phone, postal address (city/state/country/postal code/street), company name, employee ID/type, business phone, fax number and preferred language when the plan row has them | `-PlanPath` (required), `-Wave`, `-UseInterim`, `-HideFromAddressLists`, `-AssignLicenses`, `-SetManagers`, `-ForceChangePassword`, `-PasswordLength`, `-DefaultUsageLocation`, `-IncludeCollisions`, `-TenantId` | Plan → accounts; writes `TargetObjectId` back; passwords to the results CSV only |
| `Set-MigrationLicenses.ps1` | Usage location first, then `assignLicense`. Refuses group-assigned SKUs both ways; seat pre-check stops the run unless `-Force`. `ConfirmImpact` High since 1.2.0 — pass `-Confirm:$false` unattended | `-PlanPath` (required), `-Wave`, `-SkuMapPath` (recomputes from `SourceLicenses` without regenerating the plan), `-RemoveUnplanned`, `-AcknowledgeLicenseRemoval` (required by `-RemoveUnplanned`; without it the run refuses before it reads or connects to anything, because removing the Exchange licence starts the 30-day mailbox-deletion clock), `-DefaultUsageLocation`, `-Force`, `-IncludeCollisions`, `-TenantId` | Plan (+ SKU map) → licence assignments, results CSV |
| `New-MigrationRecipients.ps1` | Shared/room/equipment mailboxes, DLs, mail-enabled security groups, dynamic DLs, mail contacts. Members, owners, moderators and delivery restrictions are translated through the plan; unmapped ones are reported, not guessed. Stamps X500 | `-PlanPath` (required), `-Type`, `-Mode Create\|UpdateSettings\|CreateAndUpdate`, `-Wave`, `-UseInterim`, `-GroupsCsv`, `-ContactsCsv`, `-SharedMailboxesCsv`, `-MailboxPermissionsCsv`, `-IncludeCollisions`, `-TenantId`, `-DelegatedOrganization` | Plan + source inventory → recipients, results CSV |

### Phase 4 — Cutover

| Script | Purpose | Key parameters | In → Out |
|---|---|---|---|
| `Remove-MigrationDomainReferences.ps1` | Source-side domain release. Always reports first and only remediates with `-AcknowledgeSourceTenant`. Exits `3` while any reference remains (blockers, or fixable references a report-mode run did not apply) or the scan did not finish, `2` when a row failed (which outranks `3`), `0` when the domain is clear and `1` on a fatal error | `-Domain` (required), `-FallbackDomain` (default: the tenant's initial onmicrosoft domain — must be verified on the *source* tenant), `-Scope Users,Groups,Contacts,Mailboxes`, `-ReportOnly`, `-AcknowledgeSourceTenant`, `-TenantId`, `-DelegatedOrganization` | Source tenant → References CSV + Blockers CSV, then remediation |
| `Set-MigrationIdentity.ps1` | Applies the plan's target identity. Additive by design: never removes the MOERA routing address, a SIP address or an existing X500. Directory-synced objects are a hard `Failed` | `-PlanPath` (required), `-Apply Upn,PrimarySmtp,Aliases,X500,GalVisibility,MailNickname`, `-MatchOn TargetObjectId\|Interim\|Source`, `-Wave`, `-RemoveOldPrimaryAlias`, `-Unhide`, `-IncludeCollisions`, `-TenantId`, `-DelegatedOrganization` | Plan → tenant identities, results CSV |
| `Set-MigrationMailboxPermissions.ps1` | Re-applies delegation. Both sides mapped through the plan; the trustee map is built from the whole plan, not the wave. Idempotent — safe to re-run all weekend | `-PlanPath` and `-MailboxPermissionsCsv` (both required), `-UserMailboxesCsv`, `-SharedMailboxesCsv`, `-Apply FullAccess,SendAs,SendOnBehalf,Calendar,Forwarding`, `-Wave`, `-AutoMapping`, `-IncludeCollisions`, `-TenantId` (new in 1.2.0 — pins the Exchange session), `-DelegatedOrganization` | Plan + source permission inventory → destination ACEs, results CSV |
| `Reset-MigrationCutoverPasswords.ps1` | Passphrase reset with change-at-next-sign-in | One of `-PlanPath` (+ `-Wave`, `-IncludeCollisions`), `-CsvPath`, `-Group` (object ID or display name, **not** the group's email) or `-TestUser`; plus `-WordCount`, `-ForceChangePassword`, `-TenantId` | Plan/CSV/group → resets; credentials to the results CSV only |
| `Set-MigrationTeamsPhoneAssignments.ps1` | Assigns numbers. Normalises `tel:`, spaces, dashes, a missing `+`, and preserves `;ext=`. A number already on a different user fails rather than being stolen | One of `-CsvPath`, `-User` + `-PhoneNumber` (+ `-PhoneNumberType`, `-LocationId`, `-VoiceRoutingPolicy`), or `-ListUnassigned`; plus `-TenantId` | CSV → assignments, results CSV |
| `Remove-MigrationTeamsPhoneAssignments.ps1` | Releases numbers, capturing number, type and policy first so the results CSV is the reassignment input. Hybrid `OnPremLineURI` numbers report `Failed` | One of `-User`, `-CsvPath` or `-All`; plus `-AcknowledgeSourceTenant` (required by `-All`, which otherwise refuses to run — releasing every number in the wrong tenant takes the phone system down for a client who is not migrating, and nothing here puts them back) and `-TenantId` | Tenant/CSV → removals, reassignment-ready results CSV |
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

`*.Main.Tests.ps1` files drive a script's whole `Main` region end to end against stub cmdlets
— `Set-MigrationLicenses`, `Test-MigrationReadiness` and `Remove-MigrationDomainReferences`
have one each — so exit codes and results files are asserted on the real control flow rather
than on a lifted function.

The Graph tests do not need the Microsoft SDKs installed: `Connect-MigrationGraph.Tests.ps1`
and `Invoke-MigrationGraphRequest.Tests.ps1` define their own stub cmdlets and fail loudly if
a real one is reached. To prove it, run them with a module path that contains nothing but
PowerShell's own modules and Pester:

```powershell
pwsh -NoProfile -Command '
$pester = (Get-Module Pester -ListAvailable | Select-Object -First 1).ModuleBase
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "hermetic-$(New-Guid)"
$null = New-Item -ItemType Directory -Path $sandbox
$null = New-Item -ItemType SymbolicLink -Path (Join-Path $sandbox "Pester") -Target (Split-Path $pester -Parent)
$env:PSModulePath = (Join-Path $PSHOME "Modules") + [IO.Path]::PathSeparator + $sandbox
"Graph/EXO/Teams visible: {0}/{1}/{2}" -f
    [bool](Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue),
    [bool](Get-Command Get-ConnectionInformation -ErrorAction SilentlyContinue),
    [bool](Get-Command Get-CsTenant -ErrorAction SilentlyContinue)
Invoke-Pester -Path Utilities/M365-Migration/Tests/Connect-MigrationGraph.Tests.ps1,
    Utilities/M365-Migration/Tests/Invoke-MigrationGraphRequest.Tests.ps1
'
```

It should print `Graph/EXO/Teams visible: False/False/False` and still pass. Symlinking Pester
in rather than adding the user module directory back is the point — that directory is usually
where the SDKs live too, and re-adding it makes the proof pass for the wrong reason.

---

## Documented deviations from the authoring standard

Four places where this toolkit knowingly departs from the house PowerShell standard. They are
listed so a reviewer does not re-raise them as defects.

| Deviation | Why |
|---|---|
| The log root is the per-migration output folder, not `%ProgramData%` | The log belongs with the CSVs of the run that produced it. A migration folder is the unit an operator archives, hands over or attaches to a ticket, and splitting the log away from its results makes both harder to read six months later. |
| No explicit TLS assertion | The standard's `[Net.ServicePointManager]::SecurityProtocol` line is a Windows PowerShell 5.1 remedy. These scripts require PowerShell 7.4+, which uses the OS TLS defaults; setting it there pins a policy rather than raising one. |
| `[bool]` rather than `[switch]` for default-on options | A switch cannot default to on and still be turned off. Three parameters default to `$true` — `-ForceChangePassword` in `New-MigrationUsers` and `Reset-MigrationCutoverPasswords`, and `-AutoMapping` in `Set-MigrationMailboxPermissions` — so `-ForceChangePassword $false` has to be expressible. They keep their type. |
| `-Verbosity` defaults to `Medium`, not `Low` | These are long, unattended-ish runs an operator watches. Silence until the summary makes a stalled Graph call indistinguishable from a slow one; the log file always gets everything either way. |

---

## Gotchas

| Gotcha | What happens | What to do |
|---|---|---|
| Missing X500 | Replies from cached Outlook entries and old calendar items bounce with an IMCEAEX NDR | Stamp `X500:<LegacyExchangeDN>` on every migrated recipient — `Set-MigrationIdentity -Apply X500`, and `New-MigrationRecipients` does it at creation |
| Primary SMTP looks reasserted to the old address | Exchange Online has no per-mailbox email address policy for a user mailbox to reassert it | A reasserted primary means the object is hybrid/directory-synced — `Set-MigrationIdentity` already hard-stops those rows as `Failed`; fix the address on-premises |
| Graph `PATCH /users {mail}` | Silently cosmetic on a mailbox-enabled user; Exchange owns `proxyAddresses` | Primary SMTP always goes through `Set-Mailbox -EmailAddresses`, never Graph. The toolkit does this for you |
| Group-based licensing | `assignLicense` cannot remove a group-inherited SKU, and re-adding one quietly doubles the assignment | `Set-MigrationLicenses` detects `assignedByGroup` and skips both directions. Remove the user from the group instead |
| Missing usage location | `assignLicense` fails, surfacing in the admin center as a vague "invalid usage location" | Set `UsageLocation` in the plan, or pass `-DefaultUsageLocation` |
| Soft-deleted users | Hold their UPN and proxy addresses; create and rename both return 409 "already exists" | `Test-MigrationReadiness -Stage Pre` finds them. Purge or restore them before provisioning |
| Renaming an admin's UPN | 403 `Authorization_RequestDenied` with only User Administrator | Use Privileged Authentication Administrator (or Global Admin) for admin accounts |
| Directory-synced objects | EXO and Entra are read-only for UPN and `proxyAddresses`; "out of the current user's write scope" | Change on-premises and let AAD Connect sync. Those rows report `Failed`, not `Skipped` |
| GAL hiding before a mailbox exists | `Set-Mailbox` has nothing to act on; Graph `showInAddressList` is a documented known issue and Exchange wins once a mailbox exists | Use `New-MigrationUsers -HideFromAddressLists` as a stopgap, then re-apply with `Set-MigrationIdentity -Apply GalVisibility` after licensing |
| Fly authorisation lapses mid-run | Content jobs fail to authenticate part-way through: the app consent was revoked or expired, or an optional service account hit MFA / Conditional Access | Re-authorise Fly in the console as the Global Admin in the affected tenant. If a Fly module required a service account, license it and exclude it from MFA and Conditional Access for the duration of the project |
| Fly auto-licensing | Only works when there are **both** spare seats and a usage location | Run `Set-MigrationLicenses` first rather than relying on it |
| Teams chat migration | Mode-dependent and lossy — no reactions, no external chats, authorship shifts | Agree the chat mode with the client in writing before the job runs |
| Exchange Web Services retirement, 1 Oct 2026 | Any EWS-based mover path stops working | Confirm Fly is on its Graph-based path before scheduling a cutover near that date |
| Litigation hold | Movers refuse mailboxes that are on hold | `Test-MigrationReadiness -Stage Provisioned` reports it; clear the hold for the move window |
| Domain removal blockers | The domain will not delete while any user UPN, proxy address, group, mailbox or contact still references it | `Remove-MigrationDomainReferences -ReportOnly` lists every one. Guest `#EXT#` UPNs embed the *resource* tenant's domain and are informational, not blockers. The initial `.onmicrosoft.com` domain can never be removed |
| OneDrive not provisioned | `GET /users/{id}/drive` returns 404 and the mover has nowhere to write | Pre-provision with `Request-SPOPersonalSite -UserEmails <email>` (SharePoint Admin, user already licensed) |
| `Get-MailboxPermission` on a large tenant | "data exceeded max permitted by session (500MB)" | The inventory uses the REST-based `Get-EXOMailboxPermission`; keep `-SkipMailboxPermissions` in reserve for very large estates |
