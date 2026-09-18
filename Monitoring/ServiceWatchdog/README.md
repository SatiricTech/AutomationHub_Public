# ServiceWatchdog

Keep a named set of Windows services running on a server and email IT when that is not
possible. A scheduled task runs a PowerShell watchdog every 5 minutes (and shortly after
boot) as SYSTEM; it starts stopped services, retries inside a time budget, and reports
state changes to a webhook. The webhook is a small Azure Function that renders and sends
the email through SMTP2GO (REST API) or any authenticated SMTP relay, with the provider
secret held in Azure Key Vault. A daily heartbeat lets the Azure side notice a server whose
watchdog has gone silent.

Version 1.0.0. `DESIGN.md` in this folder is the full specification; this README is the
operator summary.

Full configuration, script parameter, HTTP contract and app-setting reference:
[Docs/Reference.md](Docs/Reference.md).

## What it does

On every run the worker (`Endpoint/Invoke-WinServiceWatchdog.ps1`):

1. Reads `ServiceWatchdog.json`, validates it, and prunes state for services no longer
   listed.
2. Checks every listed service. Services that are not installed (`Missing`) or whose start
   mode is `Disabled` are reported but never touched; the worker never changes a start type.
3. Starts stopped services in up to `MaxStartAttempts` rounds, waiting
   `PostStartVerifySeconds` after each start and `RetryDelaySeconds` between rounds, all
   capped by `MaxRunSeconds`. It calls `ServiceController.Start()` plus `WaitForStatus`
   rather than `Start-Service`, so one stuck service cannot consume the whole budget.
4. Compares the outcome with the previous run's state file and decides whether anything is
   worth an email: a new problem (`alert`), a problem still present after `ReminderMinutes`
   (`reminder`), a problem that cleared (`recovered`), a service the worker itself started
   (`remediated`, off by default), or a service bouncing between states (`flapping`, which
   suppresses further mail for that service until it settles).
5. POSTs at most one JSON event per run to the Azure Function with the function key in the
   `x-functions-key` header. If delivery fails the transition is kept pending and re-sent on
   the next run with the same `EventId`, and the function deduplicates on that id, so a
   webhook outage neither loses nor duplicates an email.
6. Sends a `heartbeat` event once every `HeartbeatHours` (never emailed; it only updates the
   host's last-seen time on the Azure side).
7. Writes every decision to a daily log file and to the `ServiceWatchdog` source in the
   Application event log, and exits with a code an RMM can act on.

The Azure Function (`AzureFunction/`) validates the payload strictly, deduplicates on
`EventId`, rate-limits per host, renders an HTML plus plain-text email with every field
HTML-encoded, sends it, and records the host's last-seen time in a storage table. A timer
function emails a digest of hosts that have not reported within `WATCHDOG_STALE_HOURS`
(default 26). The Azure side never inspects or controls services; it only relays and
correlates what the endpoint reports.

## Architecture

```
Windows Server                                     Azure                              Mail
+---------------------------------+  HTTPS POST   +-----------------------------+   +---------+
| Task Scheduler (SYSTEM)         | x-functions-  | Function App (PowerShell)   |   | SMTP2GO |
|  every 5 min + boot + 5 min     | key header    |  SendServiceWatchdogAlert   |-->| API or  |
|   -> Invoke-WinServiceWatchdog  | ------------> |   validate, dedup, render,  |   | SMTP    |
|      reads ServiceWatchdog.json |               |   send, record last-seen    |   +----+----+
|      starts services, retries   |               |  SendServiceWatchdogDigest  |        |
|      writes state + event log   |               |   timer: stale hosts        |        v
+---------------------------------+               |  Key Vault refs -> secrets  |     IT list
                                                  |  Tables: WatchdogHosts,     |
                                                  |          WatchdogSentEvents |
                                                  +-----------------------------+
```

Event types sent by the endpoint: `alert`, `flapping`, `reminder`, `recovered`,
`remediated`, `test`, `heartbeat`. Only `heartbeat` never produces an email.

## Repository layout

| Path | Purpose |
|---|---|
| `Endpoint/Invoke-WinServiceWatchdog.ps1` | The 5-minute worker (Windows PowerShell 5.1 or PowerShell 7) |
| `Endpoint/Register-WinServiceWatchdogTask.ps1` | Installs the worker, locks down its folder, validates the config, registers the task |
| `Endpoint/Unregister-WinServiceWatchdogTask.ps1` | Removes the task and, optionally, the event source and files |
| `Endpoint/ServiceWatchdog.example.json` | Copy to `ServiceWatchdog.json` and edit |
| `AzureFunction/` | Function app: `host.json`, `Modules/ServiceWatchdogAlert`, `SendServiceWatchdogAlert`, `SendServiceWatchdogDigest` |
| `Deploy/main.bicep` | Infrastructure: Function App, storage tables, Key Vault, Application Insights, role assignments |
| `Deploy/Install-AzureServiceWatchdogFunction.ps1` | One-shot Azure deployment from an operator workstation |
| `Deploy/main.parameters.example.json` | Parameter file for deploying the template by hand |
| `Docs/Hudu-ServiceWatchdog.html` | Knowledge-base article draft (callout and table classes from the house stylesheet) |
| `Docs/Hudu-ServiceWatchdog-ServerInstall.html` | Server registration hand-off guide for the staff who register servers, with fill-in fields for the URL, key and site name |
| `Tests/` | Pester suites for every script and the module, the worker-to-function payload contract check, and the Windows PowerShell 5.1 compatibility checker |

`.gitignore` excludes the real `ServiceWatchdog.json`, `*.state.json`,
`local.settings.json`, `Deploy/main.parameters.json`, zips and test output, so a real
function key or API key is never committed by accident.

## Requirements

**Monitored servers**

- Windows Server 2016 or later, Windows PowerShell 5.1 (PowerShell 7 also works).
- Local administrator rights to run the installer once. The task itself runs as SYSTEM.
- Outbound HTTPS (TCP 443) to the Function App host name. If the server reaches the
  internet through a proxy, it must be the machine-wide WinHTTP proxy (see
  [Troubleshooting](Docs/Reference.md#troubleshooting)); SYSTEM does not use a user's browser proxy.

**Operator workstation (Azure deployment)**

- PowerShell 7.4 or later on Windows, macOS or Linux.
- Az modules 9.7.1 or later: `Az.Accounts`, `Az.Resources`, `Az.Websites`, `Az.KeyVault`
  (`Install-Module Az -Scope CurrentUser`).
- The [Bicep CLI](https://aka.ms/bicep-install) on `PATH` (`bicep --version` must work;
  Azure PowerShell does not install it).
- Contributor plus User Access Administrator (or Owner) on the target resource group, and
  permission to read your own user or service principal object in Entra ID.

**Azure**

- A subscription where a Windows Consumption Function App can be created. The template
  deploys: Log Analytics workspace, Application Insights, storage account with two tables,
  Key Vault (RBAC, soft delete, purge protection), Consumption plan, Function App with a
  system-assigned identity, and three role assignments. At watchdog volumes (a few hundred
  small requests a day per server) the Consumption plan stays inside its free grant; the
  Log Analytics and Application Insights ingestion is the main recurring cost.

**Mail provider**

- An SMTP2GO account (default provider), or any SMTP relay that accepts authenticated
  STARTTLS on 587 or 2525. Port 25 is blocked on most Azure subscriptions; implicit TLS on
  465 is not supported by the function.

## Quick start

Do the Azure side first; the servers need its URL and key.

### 1. SMTP2GO setup

1. Add a **verified sender domain** (Sending > Verified Senders > Sender domains) and
   publish the three CNAME records it gives you (SPF, DKIM, tracking). A single verified
   sender address also works, but the account-level cap of 25 emails per hour is lifted
   only once a sender domain is verified, and a busy site can exceed it. The `-MailFrom`
   address must be on that domain.
2. Create a dedicated **API key** (Settings > API Keys) with only the **Emails**
   permission (`/email/send`) enabled. Give it a name that identifies this deployment.
3. Set a **per-key rate limit** on that key (for example 60 per hour). This is a required
   step, not a suggestion: the function enforces its own global cap
   (`WATCHDOG_MAX_EMAILS_PER_HOUR`, 60 per hour by default), but the provider-side limit is
   the one that still holds if the function app itself is misused or bypassed.
4. Do **not** enable the account-level API IP allowlist: a Consumption Function App has no
   fixed outbound IP and would block itself.

For an SMTP relay instead of the REST API, create an SMTP user at the relay, apply the
relay's equivalent per-account sending limit, and note the host, port and credential;
pass `-MailProvider Smtp` below.

### 2. Deploy the Azure side

```powershell
Connect-AzAccount
$apiKey = Read-Host -Prompt 'SMTP2GO API key' -AsSecureString

cd Monitoring/ServiceWatchdog/Deploy
./Install-AzureServiceWatchdogFunction.ps1 `
    -ResourceGroupName 'rg-servicewatchdog' -Location 'eastus2' -BaseName 'svcwatchdog' `
    -MailFrom 'Service Watchdog <alerts@example.com>' -MailTo 'it@example.com;oncall@example.com' `
    -Smtp2GoApiKey $apiKey -SendTestEmail -Verbosity Medium
```

The script checks prerequisites, creates the resource group if needed, deploys
`main.bicep`, seeds the provider secret in Key Vault (retrying while the role assignment
propagates), zips and publishes the function code, restarts the app so the Key Vault
references resolve, waits for the function to appear, creates a named function key
(`watchdog` by default), prints the alert URL and key to the console **once**, and only
then verifies admin endpoint isolation (a failure there is reported as exit 50 after the
key was shown, never before). The key is never written to the log file. `-SendTestEmail`
posts a `test` event and reports the function's verdict; test events never create a
`WatchdogHosts` row, so the workstation you deploy from does not turn up in the stale-host
digest.

Re-running the script is safe: every step is idempotent, an existing key of the same name
is reused rather than regenerated, and a re-run is the way to change recipients or push
new function code. `-DryRun` runs the template with `-WhatIf` and changes nothing.

Resource names are derived from `-BaseName` (3 to 14 lowercase letters, digits or hyphens):
`log-<base>`, `appi-<base>`, `asp-<base>`, and, with a six-character suffix unique to the
resource group, `func-<base>-<suffix>`, `kv-<base>-<suffix>` and `st<base><suffix>`
(hyphens dropped). The script and template only check length and character set, so avoid
a leading or trailing hyphen: `kv-<base>--<suffix>` has consecutive hyphens, which Key
Vault rejects at deployment time.

Deploying by hand instead: copy `main.parameters.example.json` to `main.parameters.json`
(git-ignored), replace `deployerObjectId` with `(Get-AzADUser -SignedIn).Id` (the all-zero
value is a placeholder and fails with `PrincipalNotFound`), run
`az deployment group create -g <rg> -f main.bicep -p main.parameters.json`, then seed the
Key Vault secret (`Smtp2GoApiKey` or `SmtpPassword`), zip the contents of `AzureFunction/`
with `host.json` at the archive root, publish it, restart the app, and create a function
key. The install script does all of that for you.

### Changing who receives the emails

Recipients live in one Function App setting, `WATCHDOG_MAIL_TO`, as a semicolon-separated
list. Alerts and the daily digest both go to it. Two ways to change it:

1. **Re-run the install script** with the new list in `-MailTo`. Everything else is reused,
   including the existing function key; it asks for the SMTP2GO key again because it
   re-seeds the vault secret. Add `-SendTestEmail` to confirm the new list works.
2. **Edit it in the portal**: Function App, Settings, Environment variables,
   `WATCHDOG_MAIL_TO`, Save. The app restarts and the next email uses the new list.

```powershell
./Install-AzureServiceWatchdogFunction.ps1 `
    -ResourceGroupName 'rg-servicewatchdog' -Location 'eastus2' -BaseName 'svcwatchdog' `
    -MailFrom 'Service Watchdog <alerts@example.com>' `
    -MailTo 'it@example.com;helpdesk@example.com' `
    -Smtp2GoApiKey $apiKey -SendTestEmail
```

> **A portal edit is wiped by the next install script run.** Every run writes all settings
> from the template, including the recipient list. If you change recipients in the portal
> and later run the script with a different `-MailTo`, the portal change is lost. Whenever
> the script runs, pass the full current list in `-MailTo`.

### 3. Install on each server

> **Where the files go.** The folder you copy `Endpoint/` to is only the source. The
> installer creates and uses **`C:\ProgramData\ServiceWatchdog`** for the config file, the
> state file, the logs and its own copy of the worker, unless you pass `-InstallPath` on
> every run. After the first run, the file to edit is
> **`C:\ProgramData\ServiceWatchdog\ServiceWatchdog.json`**; it does not appear next to
> the scripts you ran. The source folder can be deleted once the task is registered.

> **Service Name, not Display Name.** `Services` takes the short service name, the one
> `Get-Service` shows as `Name`: `Spooler`, not `Print Spooler`; `W3SVC`, not `World Wide
> Web Publishing Service`. Look one up with `(Get-Service -DisplayName 'Print Spooler').Name`.
> A display name is resolved as a courtesy, but the short name is what the logs, emails and
> state file key on.

For a step-by-step page to hand to the people who register servers, with fill-in fields
for the URL, key and site name, see `Docs/Hudu-ServiceWatchdog-ServerInstall.html`.

Copy the `Endpoint/` folder to the server and, in an elevated PowerShell:

```powershell
cd C:\Temp\Endpoint
.\Register-WinServiceWatchdogTask.ps1
# First run: creates C:\ProgramData\ServiceWatchdog, locks it down to SYSTEM and
# Administrators, copies the example config into it and exits 2 asking you to edit
# ServiceWatchdog.json.

notepad C:\ProgramData\ServiceWatchdog\ServiceWatchdog.json
# Set SiteName, Services, Webhook.Url and Webhook.FunctionKey (the two lines the
# install script printed). Values containing REPLACE fail validation.

.\Register-WinServiceWatchdogTask.ps1 -TestAlert -RunNow
```

The second run re-applies the folder lockdown (`icacls`: explicit entries reset,
inheritance removed, SYSTEM and Administrators only, ownership taken), copies the worker,
validates the config by running the worker with `-ValidateConfig`, checks the task's
execution limit against the config's worst-case run time, registers the event log source,
registers the `ServiceWatchdog` task (SYSTEM, every 5 minutes, plus 5 minutes after boot),
starts the task and sends a test alert. If `C:\ProgramData\ServiceWatchdog` already exists
and is owned by an account other than SYSTEM or Administrators, the installer refuses it
(exit 2): remove the folder or take ownership as an administrator first. Add `-SetServiceRecovery` to also set Service
Control Manager failure actions (restart after 1 and 2 minutes) on every listed service.

One-pass alternative: put a filled-in `ServiceWatchdog.json` next to the script in the
source folder and the first run seeds the install folder from it and goes straight through
validation and registration (an existing config in the install folder is never overwritten;
keep that source copy out of source control, it holds the function key).

Check the inbox for the `[TEST]` email, then see [Testing an installation](#testing-an-installation).

Full configuration, script parameter, HTTP contract and app-setting reference:
[Docs/Reference.md](Docs/Reference.md).

## Testing an installation

The Pester suites run every code path against mocks; nothing in this repository has been
executed against a live Windows server or Functions worker, so this acceptance run on the
first server is the real integration test.

1. `.\Invoke-WinServiceWatchdog.ps1 -ValidateConfig -Verbosity High` from the install
   folder: exit 0 and a summary of the effective settings.
2. `.\Invoke-WinServiceWatchdog.ps1 -TestAlert`: exit 0, a `[TEST]` email arrives, event
   1030 in the Application log.
3. `.\Invoke-WinServiceWatchdog.ps1 -DryRun -Verbosity High`: every service listed with its
   observed status and start type; nothing changed.
4. Stop a non-critical listed service (`Stop-Service Spooler`) and start the task:
   `Start-ScheduledTask -TaskName ServiceWatchdog`. Within a minute the service is running
   again, event 1001 is logged, and no email is sent (unless `NotifyOnRemediation` is on).
5. Disable a listed service (`Set-Service Spooler -StartupType Disabled; Stop-Service Spooler`)
   and start the task: an `alert` email arrives naming the service as `Disabled`, event 1004
   and 1010 are logged, the run exits 50. Leave it for `ReminderMinutes` to see a
   `Reminder:` email, or restore it (`Set-Service Spooler -StartupType Automatic`) and run
   the task again to see the `recovered` email and event 1005.
6. `.\Invoke-WinServiceWatchdog.ps1 -SendHeartbeat`: event 1012, and a row for the host in
   the `WatchdogHosts` table (Storage browser in the portal).
7. Temporarily set `Webhook.FunctionKey` to a wrong value and run
   `.\Invoke-WinServiceWatchdog.ps1 -TestAlert`: exit 10 and event 1013. With the key still
   wrong, disable a listed service and start the task: event 1013 again, exit 50, and the
   log says the alert is pending. Restore the key and start the task once more: the alert
   is delivered with the same `EventId` as the failed attempt (compare the two `POST`
   lines in the log), and event 1010 is written. Re-enable the service afterwards.
8. Watch the run in Application Insights: `traces | where message has "ServiceWatchdog"`,
   or `requests | where name == "SendServiceWatchdogAlert"`. Requests and exceptions are
   never sampled.
9. Digest: wait for the next scheduled run (07:00 UTC by default), or temporarily set
   `WATCHDOG_DIGEST_SCHEDULE` to a time a few minutes ahead (changing an app setting
   restarts the app) and set it back afterwards.

Useful queries on the server:

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'ServiceWatchdog' } -MaxEvents 20
Get-Content "$env:ProgramData\ServiceWatchdog\Logs\ServiceWatchdog-$(Get-Date -Format yyyyMMdd).log" -Tail 50
Get-ScheduledTaskInfo -TaskName ServiceWatchdog
```

### Checkup: has it restarted anything?

A successful restart is silent by default (no email), so this is the quickest way to see
the watchdog doing its job. Event 1001 is written every time it starts a service:

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'ServiceWatchdog'; Id = 1001 } -MaxEvents 25
```

Each entry names the service and the attempt it succeeded on. Use `Id = 1002` for failed
starts instead, or drop the `Id` filter for the last 25 events of any kind. To hear about
restarts by email, set `Alerting.NotifyOnRemediation` to `true` in the config.

## Where to look when something is wrong

Start with the daily log (`<LogRoot>\ServiceWatchdog-yyyyMMdd.log`) and the
`ServiceWatchdog` source in the Application event log on the server; on the Azure side,
Application Insights (`traces | where message has "ServiceWatchdog"`). For exit codes,
event IDs, HTTP error codes, and specific symptoms and fixes, see
[Troubleshooting in Docs/Reference.md](Docs/Reference.md#troubleshooting).
