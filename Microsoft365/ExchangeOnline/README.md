# Exchange Online archive scripts

Two scripts that work as a pair:

| Script | What it does |
|---|---|
| `Enable-M365ArchiveAutoExpand.ps1` | Turns on auto-expanding archiving, org-wide (default) or per mailbox. Can enable the main archive first. |
| `Start-M365ManagedFolderAssistant.ps1` | Runs `Start-ManagedFolderAssistant` on every in-scope mailbox, so retention and archive policies apply now instead of within Exchange's normal cycle (up to 7 days). |

Typical sequence:

```powershell
Connect-ExchangeOnline

./Enable-M365ArchiveAutoExpand.ps1 -EnableArchive -DryRun -Verbosity High   # review
./Enable-M365ArchiveAutoExpand.ps1 -EnableArchive                           # prompts, then applies
./Start-M365ManagedFolderAssistant.ps1 -ArchiveEnabledOnly
```

Both scripts reuse an existing Exchange Online session, including an app-only session. If
no session exists, they start an interactive sign-in and disconnect at the end. If more than
one Exchange Online session is open, they stop with exit code 2, because the Exchange
cmdlets use the most recent connection and the scripts can't be sure which tenant they change.

## Before you enable auto-expanding archiving

> **This change cannot be undone.**

- After you turn it on, for the organization or for a mailbox, you can't turn it off.
- A mailbox with auto-expanding archiving can't be recovered or restored as an inactive
  mailbox later. The only recovery path is a Purview content search export.
- In hybrid, a cloud archive with auto-expansion can't be off-boarded to on-premises.
- Auto-expansion applies only to mailboxes whose **main archive is enabled**. The archive
  needs a license that includes archiving. See the
  [Exchange Online Archiving service description](https://learn.microsoft.com/office365/servicedescriptions/exchange-online-archiving-service-description/exchange-online-archiving-service-description)
  for current license coverage.
- The archive converts to auto-expanding when it reaches 90 GB. Provisioning can take up to
  30 days.

Source: [Enable auto-expanding archiving](https://learn.microsoft.com/purview/enable-autoexpanding-archiving).

## Organization scope or Mailbox scope

| | `-Scope Organization` (default) | `-Scope Mailbox` |
|---|---|---|
| Command | `Set-OrganizationConfig -AutoExpandingArchive` | `Enable-Mailbox -AutoExpandingArchive` per mailbox |
| New mailboxes | Covered automatically | Not covered; run again |
| Hybrid (on-prem primary, cloud archive) | Works | **Does not work** |
| Extra 10 GB buffer while storage provisions | No | Yes |
| Mailbox property `AutoExpandingArchiveEnabled` | Stays `False` | Set to `True` |

`-UserPrincipalName` works only with `-Scope Mailbox`. With `-Scope Organization` (the
default) the script refuses it and exits 2, because an org-wide change can't be narrowed to
named users.

You can run both. With org-wide already on, `-Scope Mailbox` still adds the 10 GB buffer.
Exchange returns an "already enabled" error in that case, and the script records the row as
`BufferAdded`.

## Enable-M365ArchiveAutoExpand.ps1

| Parameter | Purpose |
|---|---|
| `-Scope` | `Organization` (default) or `Mailbox` |
| `-UserPrincipalName` | Target named mailboxes only |
| `-IncludeSharedMailboxes` | Add shared mailboxes (user mailboxes only by default) |
| `-EnableArchive` | Enable the main archive where it is missing, before auto-expansion |
| `-Force` | Skip the confirmation prompt. **Required for non-interactive runs** |
| `-DryRun` | Read and report only. No prompt, no change |
| `-Verbosity` | `Low` (default), `Medium`, `High` |
| `-OutputPath` / `-LogPath` | CSV report and log locations |

Report `Result` values: `Changed`, `WouldChange` (DryRun), `NoChange`, `BufferAdded`,
`SkippedNoArchive`, `Skipped`, `Failed`.

With `-EnableArchive -Scope Mailbox`, the script enables auto-expansion right after it
enables the main archive. If a new archive has not replicated yet, that mailbox can show
`Failed` for `EnableAutoExpand`. Run the script again later; mailboxes already done show
`NoChange`.

Both scripts show the tenant of the Exchange Online session on the console at every
verbosity level, including `Low`. The auto-expand script also shows it in the confirmation
prompt. Check it before you answer. The prompt defaults to No.

Permissions: Global Administrator or Organization Management for org scope. A role group
with the Mail Recipients role for mailbox scope and `-EnableArchive`.

## Start-M365ManagedFolderAssistant.ps1

| Parameter | Purpose |
|---|---|
| `-UserPrincipalName` | Process named mailboxes only |
| `-IncludeSharedMailboxes` | Add shared mailboxes |
| `-ArchiveEnabledOnly` | Skip mailboxes with no main archive |
| `-HoldCleanup` | Clean up duplicate item versions in Recoverable Items for mailboxes on hold |
| `-DelayMilliseconds` | Pause between mailboxes (0-60000) for large tenants |
| `-DryRun` | List mailboxes only. Queue nothing |
| `-Verbosity` | `Low` (default), `Medium`, `High` |
| `-OutputPath` / `-LogPath` | CSV report and log locations |

`Start-ManagedFolderAssistant` only queues a processing request. The assistant then applies
the retention policies that already exist, which can move or delete items. One failed
mailbox does not stop the run. Throttling errors are retried with backoff.

`-FullCrawl` is not offered. In the cmdlet reference it binds only together with a
selector switch such as `-HoldCleanup`, not on its own.

## Logs, reports, and exit codes

Logs go to `%ProgramData%\{mspname}\Logs` on Windows. Set `$MSPName` at the top of each
script. On macOS and Linux, logs go to `~/.local/state/{mspname}/Logs`. The CSV report is written next
to the log unless you pass `-OutputPath`.

| Exit code | Meaning |
|---|---|
| 0 | Success |
| 1 | Fatal error (MFA script: every mailbox failed) |
| 2 | More than one Exchange Online session open (both scripts). Auto-expand script also: confirmation declined, confirmation needed without `-Force`, or `-UserPrincipalName` with `-Scope Organization` |
| 20 | Exchange Online connection failed |
| 50 | Partial success; see the CSV report |

## Tests

Offline Pester tests (5.x or later) with every Exchange cmdlet mocked:

```powershell
Invoke-Pester ./Tests
```
