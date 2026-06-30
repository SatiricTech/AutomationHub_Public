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
faster run.

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
CSV. Existing UPNs are skipped.

```powershell
.\New-MigrationUsers.ps1 -CsvPath .\NewUsers.csv -DryRun
```

### 4. `New-MigrationSharedMailboxes.ps1`
Bulk-creates Exchange Online shared mailboxes from a CSV, optionally adding
alias addresses and Full Access / Send As permissions.

```powershell
.\New-MigrationSharedMailboxes.ps1 -CsvPath .\Shared.csv -DryRun
```

### 5. `Set-MigrationUserPrincipalNames.ps1`
Standardises UPNs to a chosen scheme — `First.Last`, `FLast`, `FirstLast` or
`F.Last`. Takes a CSV with current UPN + first + last name, matches the live
account by email/UPN, and rewrites the UPN. Prompts for the scheme if `-Scheme`
is omitted.

```powershell
.\Set-MigrationUserPrincipalNames.ps1 -CsvPath .\Users.csv -Scheme FLast -DryRun
```

### 6. `Set-MailboxPrimaryAddress.ps1`
Sets each mailbox's primary SMTP address independently of the UPN, from a CSV
pairing UPN with the desired primary email. Keeps the old address as an alias
by default.

```powershell
.\Set-MailboxPrimaryAddress.ps1 -CsvPath .\PrimaryMap.csv -DryRun
```

---

## Expected CSV columns

Auto-detected aliases are shown in parentheses; only the **bold** columns are
required.

| Script | Columns |
|--------|---------|
| `Compare-MigrationUserData` | UPN *(UserPrincipalName)*, Email *(PrimaryEmail/Mail)*, FirstName *(GivenName)*, LastName *(Surname)*, DisplayName |
| `New-MigrationUsers` | **UPN** *(UserPrincipalName)*, **DisplayName** *(or First+Last)*, FirstName, LastName, MailNickname *(Alias)*, Password, UsageLocation, JobTitle, Department, Office, MobilePhone, City, State, Country |
| `New-MigrationSharedMailboxes` | **PrimarySmtpAddress** *(Email)*, **DisplayName**, Alias, AliasAddresses, FullAccess, SendAs, HiddenFromAddressLists |
| `Set-MigrationUserPrincipalNames` | **UPN** *(current, also matches Email)*, **FirstName**, **LastName** |
| `Set-MailboxPrimaryAddress` | **UPN** *(UserPrincipalName)*, **PrimaryEmail** *(Email/PrimarySmtpAddress)* |

---

## Suggested workflow

1. **Export** source tenant: `Get-MigrationInventory` (one workbook + CSVs).
2. **Export** destination tenant the same way (if it has existing users).
3. **Compare** the two with `Compare-MigrationUserData` (point it at the
   `Summary` or `M365Users` CSVs) to find overlaps.
4. **Provision** the destination: `New-MigrationUsers`, then
   `New-MigrationSharedMailboxes`.
5. **Standardise** identities: `Set-MigrationUserPrincipalNames`.
6. **Fix addressing**: `Set-MailboxPrimaryAddress` where the primary email must
   differ from the UPN.

> Always dry-run tenant-changing scripts with `-DryRun` (or `-WhatIf`) first, and store any
> results CSV containing generated passwords securely.
