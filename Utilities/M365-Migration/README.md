# M365 Migration Automation

A set of standalone PowerShell 7 scripts for Microsoft 365 → Microsoft 365
tenant migrations. They cover the repetitive parts of an MSP migration:
exporting source-tenant data, matching users between tenants, and provisioning
users / shared mailboxes / addresses in the destination tenant.

Most third-party migration tools accept CSV user-mapping uploads, so every
script here reads or writes plain CSVs designed to drop straight into those
tools (and into each other).

> **Standalone by design** – each `.ps1` is self-contained. Copy a single file
> to a tech's workstation and it runs on its own.

---

## Common behaviour

| Aspect | Detail |
|--------|--------|
| **PowerShell** | Requires PowerShell 7. |
| **Authentication** | Interactive sign-in via `Connect-MgGraph` / `Connect-ExchangeOnline`. You are prompted at runtime. |
| **Output location** | Every script takes `-OutputPath`. If omitted, it defaults to `%LocalAppData%\Migration-Automations` (always writable by the current user, no roaming), prints that path, and asks you to confirm it or supply another directory. |
| **File naming (Get script)** | `Get-MigrationInventory` takes `-Prefix`. If omitted, it asks whether you want a custom prefix; if not, whether the pull is the **Source** or **Destination** tenant. The chosen label is prepended to every output file (e.g. `Source_Migration-Inventory_...xlsx`, `Destination_M365Users_...csv`) so files are self-describing. |
| **Modules** | Required modules (`Microsoft.Graph.*`, `ExchangeOnlineManagement`, and `ImportExcel` for the inventory workbook) are auto-installed for the current user if missing. |
| **Safety / dry run** | Every script takes `-DryRun`. On the tenant-changing scripts it forces WhatIf mode (each row is evaluated and reported, nothing is changed) and is equivalent to `-WhatIf`/`-Confirm`, which are also supported. On the read-only export/compare scripts it resolves the plan (prefix, output path, row counts) and prints the would-be output files without connecting or writing. Always dry-run first. |
| **Column detection** | CSV-driven scripts auto-detect common headers (UPN/UserPrincipalName, Email/PrimaryEmail, FirstName/GivenName, LastName/Surname, DisplayName), so exports from this toolkit or most migration tools work directly. |

---

## Scripts

### 1. `Get-MigrationInventory.ps1`
The single tenant pull. Connects to Microsoft Graph **and** Exchange Online
once and writes **one Excel workbook** (`.xlsx`) plus a matching CSV per tab.
Mailbox sizing is pulled once from Exchange and reused for the user tabs, so
users are not queried one mailbox at a time. Tabs:

| Tab | Contents |
|-----|----------|
| **User Mailboxes** | Exchange `UserMailbox` rows only (display name, UPN, primary SMTP, size, item count, archive/litigation, forwarding, aliases). |
| **Shared Mailboxes** | Exchange `SharedMailbox` rows only, same columns. |
| **M365 Users** | One row per user, most-relevant fields first: First Name, Last Name, UPN, sign-in status (`AccountEnabled`), Job Title, Licenses, Primary Email, Mailbox Type… less-relevant data farther right. |
| **Summary** | At-a-glance basics: First Name, Last Name, UPN, Primary Email, Mailbox Type, sign-in status, Licenses, Roles. |
| **Teams & Groups** | M365 Groups, Teams, distribution lists and security groups, including the mail addresses created from groups / Teams / SharePoint. |

Storage figures are in **GB**. `-IncludeOneDrive` adds OneDrive used/total
columns to the M365 Users tab (one extra Graph call per user). `-IncludeGuests`
/ `-IncludeDisabled` widen the user set; `-SkipMailboxStats` skips sizing for a
faster run. `-DomainFilter contoso.com` narrows the mailbox and user tabs to
accounts whose UPN is on that domain (Teams & Groups is not filtered).

```powershell
.\Get-MigrationInventory.ps1 -OutputPath C:\Migrations\Contoso -Prefix Source
```

### 2. `Compare-MigrationUserData.ps1`
Compares two user CSVs (e.g. source vs destination exports) and writes one row
per reference user with a **Status** (`Exact Match` / `Partial Match` /
`No Match`) and a **MatchedOn** column listing what matched (UPN, Email,
DisplayName, FirstName+LastName, EmailLocalPart, SimilarName).

```powershell
.\Compare-MigrationUserData.ps1 -ReferenceCsv .\Source.csv -DifferenceCsv .\Target.csv
```

### 3. `New-MigrationUsers.ps1`
Bulk-creates Entra ID users from a CSV. Generates a complex password where a
row has none, records every result, and writes generated passwords to a results
CSV. Existing UPNs are skipped. Because a source-tenant export carries source
domains, the script lists the **target tenant's verified domains** after
sign-in and asks which one new UPNs should use — or pass
`-TargetDomain newco.com` to skip the prompt, `-KeepCsvDomains` to use the CSV
values unchanged.

```powershell
.\New-MigrationUsers.ps1 -CsvPath .\NewUsers.csv -DryRun
.\New-MigrationUsers.ps1 -CsvPath .\Source_M365Users.csv -TargetDomain newco.com -DryRun
```

### 4. `New-MigrationUserMapping.ps1`
Builds a migration-tool **user mapping file** (source address → target
address) from one or **more** user CSVs — pass the M365Users and
SharedMailboxes exports together and users + shared mailboxes land in one
upload. No tenant connection, pure file transform. The source address prefers
primary SMTP over UPN (shared mailbox UPNs are often onmicrosoft noise);
target addresses come from a `Target*` column in the CSV when present,
otherwise `localpart@TargetDomain`. Formats live in a single registry inside
the script; **AvePoint** ships today — an `.xlsx` reproducing AvePoint's own
`Fly_User_Mapping` template (sheet `Migration mappings`, columns
`Source user/group` / `Destination user/group`) — and adding BitTitan /
ShareGate / etc. is one registry entry.

```powershell
.\New-MigrationUserMapping.ps1 -CsvPath .\Source_M365Users.csv, .\Source_SharedMailboxes.csv -TargetDomain newco.com -DryRun
```

### 5. `New-MigrationSharedMailboxes.ps1`
Bulk-creates Exchange Online shared mailboxes from a CSV, optionally adding
alias addresses and Full Access / Send As permissions. Like the user script,
it lists the **target tenant's accepted domains** (from Exchange) after
sign-in and asks which one new addresses should use — applied to the primary
SMTP, every alias, and the FullAccess/SendAs grantees. `-TargetDomain` skips
the prompt; `-KeepCsvDomains` uses the CSV values unchanged.

```powershell
.\New-MigrationSharedMailboxes.ps1 -CsvPath .\Shared.csv -DryRun
.\New-MigrationSharedMailboxes.ps1 -CsvPath .\Source_SharedMailboxes.csv -TargetDomain newco.com -DryRun
```

### 6. `Set-MigrationUserPrincipalNames.ps1`
Standardises UPNs to a chosen scheme — `First.Last`, `FLast`, `FirstLast` or
`F.Last`. Takes a CSV with current UPN + first + last name, matches the live
account by email/UPN, and rewrites the UPN. Prompts for the scheme if `-Scheme`
is omitted.

```powershell
.\Set-MigrationUserPrincipalNames.ps1 -CsvPath .\Users.csv -Scheme FLast -DryRun
```

### 7. `Set-MailboxPrimaryAddress.ps1`
Sets each mailbox's primary SMTP address independently of the UPN, from a CSV
pairing UPN with the desired primary email. Keeps the old address as an alias
by default.

```powershell
.\Set-MailboxPrimaryAddress.ps1 -CsvPath .\PrimaryMap.csv -DryRun
```

> **Partner / GDAP:** if you manage the tenant as an MSP, pass
> `-DelegatedOrganization <customer>.onmicrosoft.com` so Exchange Online connects
> to the *customer* tenant. Without it you connect to your own tenant and every
> mailbox lookup fails with "No mailbox found". The script prints the tenant it
> actually connected to so you can confirm before running.

### 8. `Reset-MigrationCutoverPasswords.ps1`
Cutover password reset. Targets users either from a **CSV** or from an **Entra
security group** (by object ID or display name — *not* the group's email), and
resets each to a freshly generated **passphrase** (at least 3 words, one word
capitalised, one number, one special character — e.g. `Silver-Copper-lantern74!`).
Every reset account is set to **change password at next sign-in**, and every
changed credential (username + passphrase) is logged to a CSV in the current
directory. Each user gets a unique passphrase. `-TestUser` rehearses the flow
against a single account; `-DryRun` reports who would be affected without
changing anything or emitting a credential.

```powershell
# Preview from a CSV - no changes
.\Reset-MigrationCutoverPasswords.ps1 -CsvPath .\CutoverUsers.csv -DryRun

# Reset every user member of a security group (by name or object ID)
.\Reset-MigrationCutoverPasswords.ps1 -Group "Migration Wave 1"

# Rehearse against one user
.\Reset-MigrationCutoverPasswords.ps1 -TestUser john.smith@contoso.com
```

> **Permissions** – resetting a password writes `user.passwordProfile`, which
> needs the dedicated `User-PasswordProfile.ReadWrite.All` scope (consented at
> sign-in) *plus* an admin role that can reset the targets — `User Administrator`
> for members, `Privileged Authentication Administrator` to reset other admins.
> `User.ReadWrite.All` on its own returns `403 Authorization_RequestDenied`.

### 9. `Get-MigrationTeamsPhoneAssignments.ps1`
The Teams Phone pull. Connects to Microsoft Teams and exports **every user**
to a CSV — UPN, display name, number (E.164), extension, number type
(`CallingPlan` / `OperatorConnect` / `DirectRouting`), enterprise-voice
status, voice routing policy, dial plan, calling policy and emergency
location. Users without a phone number are included with blank phone columns,
so the export doubles as the list of who still needs a number;
`-OnlyUsersWithNumbers` narrows it to assigned users. The number inventory is
pulled once and joined locally, so users are not queried one at a time.
Read-only. Takes the same `-Prefix` prompting as the inventory script.
`-IncludeUnassignedNumbers` writes a second CSV of every number in the tenant
not assigned to anyone.

```powershell
.\Get-MigrationTeamsPhoneAssignments.ps1 -OutputPath C:\Migrations\Contoso -Prefix Source -IncludeUnassignedNumbers
```

### 10. `Remove-MigrationTeamsPhoneAssignments.ps1`
Bulk-unassigns Teams phone numbers in the **source** tenant. Targets either a
single user (`-User`), users from a CSV by UPN (`-CsvPath` — the export from
`Get-MigrationTeamsPhoneAssignments` works directly), or every user with a
number (`-All`). Each user's number, type and voice routing policy are
captured *before* removal and logged to a results CSV whose columns match what
`Set-MigrationTeamsPhoneAssignments` reads, so the log doubles
as your rollback / reassignment input. Policies are left in place; only the
number assignment is removed. Hybrid numbers synced from on-prem AD
(`OnPremLineURI`) can't be removed here and are reported as `Failed`.

```powershell
# Preview what -All would remove - no changes
.\Remove-MigrationTeamsPhoneAssignments.ps1 -All -DryRun

# Unassign the users in a CSV
.\Remove-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Source_TeamsPhoneAssignments.csv

# Rehearse against one user
.\Remove-MigrationTeamsPhoneAssignments.ps1 -User john.smith@contoso.com
```

### 11. `Set-MigrationTeamsPhoneAssignments.ps1`
The destination-side opposite: bulk-assigns Teams phone numbers, either to a
single user (`-User` + `-PhoneNumber`) or to users from a CSV by UPN
(`-CsvPath` — every row is processed, so "all users" is simply the full export
from `Get-MigrationTeamsPhoneAssignments` or the removal log from
`Remove-MigrationTeamsPhoneAssignments`). Numbers are normalised
automatically (`tel:`, spaces, dashes stripped; missing `+` added; `;ext=`
preserved) and the number type is auto-detected from the tenant inventory when
the CSV doesn't provide one (numbers not in the inventory are treated as
Direct Routing). A number already assigned to a *different* user fails rather
than being stolen. An `OnlineVoiceRoutingPolicy` column (or
`-VoiceRoutingPolicy`) is granted after assignment — Direct Routing numbers
need one. `-ListUnassigned` is a read-only mode that lists **every available
(unassigned) phone number** in the tenant and exports it to a CSV.

```powershell
# What numbers are free in the destination tenant?
.\Set-MigrationTeamsPhoneAssignments.ps1 -ListUnassigned

# Preview a bulk assignment from the source export
.\Set-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Source_TeamsPhoneAssignments.csv -DryRun

# Assign one number to one user
.\Set-MigrationTeamsPhoneAssignments.ps1 -User john.smith@contoso.com -PhoneNumber +15551234567
```

> **Teams Phone notes** – all three scripts use the `MicrosoftTeams` module
> (auto-installed) and need a Teams Administrator / Teams Communications
> Administrator role. Assigning a number requires the user to already hold a
> Teams Phone license. For MSP / multi-tenant admins, pass `-TenantId` so the
> sign-in lands in the intended tenant — each script prints the tenant it
> actually connected to.

### 12. `Get-MigrationVivaLearningHistory.ps1`
The Viva Learning pull. Exports every user's **learner history** — course
assignments and self-initiated courses from the Graph employee learning API —
to a CSV (one row per activity) plus a raw-JSON fidelity backup. The API has
no tenant-wide endpoint, so users are read one at a time; where the tenant has
API-registered learning providers, each row is enriched with the course
metadata (title, URL, duration, skill tags…) the import script needs. Rows
pointing at content of built-in providers (LinkedIn Learning, Microsoft
Learn…) export with blank `Course*` columns — fill in at least `CourseTitle`
and `CourseWebUrl` before importing those. `-User` narrows the pull for a
rehearsal; `-IncludeGuests` widens it; `-SkipCourseMetadata` skips the catalog
read (and its extra scopes).

```powershell
.\Get-MigrationVivaLearningHistory.ps1 -OutputPath C:\Migrations\Contoso -Prefix Source
.\Get-MigrationVivaLearningHistory.ps1 -User john.smith@contoso.com -Prefix Test
```

> **Read-permission quirks** — listing course activities only works with
> *delegated* sign-in, and Microsoft's docs contradict themselves on the exact
> delegated scope names, so the script tries both documented sets. Whether a
> delegated admin token can read *other* users' activities is undocumented; if
> every cross-user read comes back 403, the script says so and points at the
> fallback (each user runs the script themselves with `-User`, or the Viva
> Learning admin tab's "Download learner completion records" export).

### 13. `Import-MigrationVivaLearningHistory.ps1`
The destination-side opposite: replays the exported CSV into the target tenant
under a **custom learning provider** — records cannot be written into built-in
providers. Three steps in one run: register or reuse the provider (with
course-activity sync enabled), upsert one catalog item per distinct course,
then create one activity per row against the mapped target user. Re-runs are
idempotent — rows whose activity already exists under the provider (matched by
external activity ID) are skipped, not duplicated. User mapping follows the
toolkit convention: a `TargetUserPrincipalName` column wins, otherwise
`localpart@TargetDomain` (prompted once if omitted), or `-KeepCsvDomains`.
Every row's outcome is appended to a results CSV as it happens (so the audit
trail survives an interrupted run); like the cutover password log, it defaults
to the **current directory** rather than the shared output location.

The employee learning API forces a **split auth model**, so the script signs in
twice: provider registration is delegated-only (interactive, needs a
Viva-licensed **Knowledge Administrator**), while content + activity writes are
application-only (an app registration with a secret or certificate). Pass
`-LearningProviderId` for an already-registered provider and the interactive
step is skipped entirely — with `-Confirm:$false` added the run is then fully
unattended (without it, each change still raises a confirmation prompt).

```powershell
# Preview - resolves provider, users and rows, changes nothing
.\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\Source_VivaLearningHistory.csv `
    -TenantId <target-tenant-guid> -ClientId <app-id> -ClientSecret (Read-Host -AsSecureString 'Secret') `
    -TargetDomain newco.com -DryRun

# Unattended re-run under an existing provider registration
.\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\Source_VivaLearningHistory.csv `
    -TenantId <target-tenant-guid> -ClientId <app-id> -CertificateThumbprint <thumbprint> `
    -LearningProviderId <registration-guid> -TargetDomain newco.com -Confirm:$false
```

> **Viva Learning notes** – the app registration needs admin-consented
> *application* permissions `LearningContent.ReadWrite.All`,
> `LearningAssignedCourse.ReadWrite.All`,
> `LearningSelfInitiatedCourse.ReadWrite.All` and `User.Read.All`. Registering
> a provider requires publicly reachable logo image URLs (one `-LogoUrl` covers
> all four slots). Each target learner must hold a Viva Learning premium
> license — rows for unlicensed users fail with a licensing 403 and are
> recorded in the results CSV. Imported records appear on My Learning;
> catalog content can take up to 24 hours to show in search/browse. The
> employee learning API exists in the Global cloud only (no GCC High/DoD/21Vianet).

---

## Expected CSV columns

Auto-detected aliases are shown in parentheses; only the **bold** columns are
required.

| Script | Columns |
|--------|---------|
| `Compare-MigrationUserData` | UPN *(UserPrincipalName)*, Email *(PrimaryEmail/Mail)*, FirstName *(GivenName)*, LastName *(Surname)*, DisplayName |
| `New-MigrationUsers` | **UPN** *(UserPrincipalName)*, **DisplayName** *(or First+Last)*, FirstName, LastName, MailNickname *(Alias)*, Password, UsageLocation, JobTitle, Department, Office, MobilePhone, City, State, Country |
| `New-MigrationUserMapping` | **UPN/Email** *(UserPrincipalName/UPN/PrimaryEmail/Email/Mail/PrimarySmtpAddress)*, Target *(TargetUserPrincipalName/TargetUPN/TargetEmail — optional per-row override)* |
| `New-MigrationSharedMailboxes` | **PrimarySmtpAddress** *(Email)*, **DisplayName**, Alias, AliasAddresses, FullAccess, SendAs, HiddenFromAddressLists |
| `Set-MigrationUserPrincipalNames` | **UPN** *(current, also matches Email)*, **FirstName**, **LastName** |
| `Set-MailboxPrimaryAddress` | **UPN** *(UserPrincipalName)*, **PrimaryEmail** *(Email/PrimarySmtpAddress)* |
| `Reset-MigrationCutoverPasswords` | **UPN** *(UserPrincipalName/UPN/Email/PrimaryEmail/Mail/UserName)* — only when using `-CsvPath`; `-Group`/`-TestUser` need no CSV |
| `Remove-MigrationTeamsPhoneAssignments` | **UPN** *(UserPrincipalName/UPN/Email/PrimaryEmail/Mail/UserName)* — only when using `-CsvPath`; `-User`/`-All` need no CSV |
| `Set-MigrationTeamsPhoneAssignments` | **UPN** *(UserPrincipalName/UPN/Email/...)*, **PhoneNumber** *(TelephoneNumber/Phone/Number/LineUri)*, PhoneNumberType *(NumberType/Type)*, Extension, LocationId, OnlineVoiceRoutingPolicy *(VoiceRoutingPolicy)* |
| `Import-MigrationVivaLearningHistory` | **UserPrincipalName** *(UPN/Email)*, **ActivityType** *(Assignment/SelfInitiated)*, **Status** *(notStarted/inProgress/completed)*, **CourseTitle**, **CourseWebUrl**, plus the rest of the export's columns (CompletionPercentage, CompletedDateTime, AssignmentType, DueDateTime, CourseExternalId…) and an optional TargetUserPrincipalName override — the CSV from `Get-MigrationVivaLearningHistory` works directly |

---

## Suggested workflow

1. **Export** source tenant: `Get-MigrationInventory` (one workbook + CSVs).
2. **Export** destination tenant the same way (if it has existing users).
3. **Compare** the two with `Compare-MigrationUserData` (point it at the
   `Summary` or `M365Users` CSVs) to find overlaps.
4. **Provision** the destination: `New-MigrationUsers` (pick the target domain
   when prompted), then `New-MigrationSharedMailboxes`.
5. **Map** users for your migration tool: `New-MigrationUserMapping` turns the
   source exports (users + shared mailboxes) into one mapping file (AvePoint
   today; other tools are one registry entry).
6. **Standardise** identities: `Set-MigrationUserPrincipalNames`.
7. **Fix addressing**: `Set-MailboxPrimaryAddress` where the primary email must
   differ from the UPN.
8. **Teams Phone**: export source assignments with
   `Get-MigrationTeamsPhoneAssignments`, release them with
   `Remove-MigrationTeamsPhoneAssignments`, then (after the numbers land in the
   destination tenant) reassign from the same CSV with
   `Set-MigrationTeamsPhoneAssignments` — check what's available first with
   `-ListUnassigned`.
9. **Viva Learning**: export learner history from the source with
   `Get-MigrationVivaLearningHistory`, fill in any blank
   `CourseTitle`/`CourseWebUrl` cells, then replay it into the destination with
   `Import-MigrationVivaLearningHistory` (dry-run first — it validates the
   user mapping and course catalog without writing).

> Always dry-run tenant-changing scripts with `-DryRun` (or `-WhatIf`) first, and store any
> results CSV containing generated passwords securely.
