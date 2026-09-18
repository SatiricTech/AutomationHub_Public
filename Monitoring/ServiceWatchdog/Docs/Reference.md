# ServiceWatchdog reference

Full configuration, script parameter, HTTP contract and app-setting reference for
ServiceWatchdog. Start with `../README.md` for what the tool does and how to get it
running; come here for every field, parameter, exit code and troubleshooting detail.

## Contents

- [Configuration reference](#configuration-reference)
  - [ServiceWatchdog.json](#servicewatchdogjson)
  - [State and logs on the server](#state-and-logs-on-the-server)
- [Endpoint scripts](#endpoint-scripts)
  - [Invoke-WinServiceWatchdog.ps1](#invoke-winservicewatchdogps1)
  - [Register-WinServiceWatchdogTask.ps1](#register-winservicewatchdogtaskps1)
  - [Unregister-WinServiceWatchdogTask.ps1](#unregister-winservicewatchdogtaskps1)
- [Azure Function](#azure-function)
  - [App settings](#app-settings)
  - [HTTP contract (`POST /api/servicewatchdog/alert`)](#http-contract-post-apiservicewatchdogalert)
  - [Tables and digest](#tables-and-digest)
  - [Install-AzureServiceWatchdogFunction.ps1](#install-azureservicewatchdogfunctionps1)
- [Rotation procedures](#rotation-procedures)
  - [Function key](#function-key-the-value-in-every-servers-servicewatchdogjson)
  - [SMTP2GO API key (or SMTP password)](#smtp2go-api-key-or-smtp-password)
  - [Recovering from a leaked function key](#recovering-from-a-leaked-function-key)
- [Runtime version check](#runtime-version-check)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Ideas for a later version](#ideas-for-a-later-version)

## Configuration reference

### ServiceWatchdog.json

```json
{
  "SchemaVersion": 1,
  "SiteName": "Example Org",
  "Services": [ "Spooler", "W3SVC", "MSSQLSERVER" ],
  "MaxStartAttempts": 5,
  "RetryDelaySeconds": 30,
  "PostStartVerifySeconds": 10,
  "StartPendingWaitSeconds": 60,
  "MaxRunSeconds": 240,
  "Webhook": {
    "Url": "https://REPLACE-ME.azurewebsites.net/api/servicewatchdog/alert",
    "FunctionKey": "REPLACE_WITH_FUNCTION_KEY",
    "TimeoutSeconds": 30
  },
  "Alerting": {
    "ReminderMinutes": 240,
    "NotifyOnRemediation": false,
    "RemediationCooldownMinutes": 60,
    "HeartbeatHours": 24
  },
  "Logging": {
    "LogRoot": "",
    "LogRetentionDays": 30,
    "EventLogHealthyRuns": false
  }
}
```

| Key | Range / default | Meaning |
|---|---|---|
| `SchemaVersion` | must be `1` | Config schema version |
| `SiteName` | 1 to 64 characters | Appears in every email and in the `WatchdogHosts` table; must match `WATCHDOG_ALLOWED_SITES` when that is set |
| `Services` | 1 to 100 unique names | Service **short names** (`Spooler`, not `Print Spooler`); a display name is accepted and resolved, with the short name logged |
| `MaxStartAttempts` | 1 to 20, default 5 | Start rounds per run |
| `RetryDelaySeconds` | 0 to 300, default 30 | Pause between rounds |
| `PostStartVerifySeconds` | 0 to 120, default 10 | Wait for `Running` after each start |
| `StartPendingWaitSeconds` | 0 to 300, default 60 | Wait for a service already in `StartPending` (no new start is issued) |
| `MaxRunSeconds` | 30 to 3600, default 240 | Time budget for checks and start rounds; every wait is capped by what remains |
| `Webhook.Url` | `https://` required | Alert URL printed by the install script |
| `Webhook.FunctionKey` | non-empty | Named function key; sent as a header, never in the URL |
| `Webhook.TimeoutSeconds` | 5 to 120, default 30 | Per-attempt timeout; one retry after 5 s on timeout, network error, 5xx or 429 |
| `Alerting.ReminderMinutes` | 5 to 10080, default 240 | Reminder cadence while a problem persists; also the flapping suppression period |
| `Alerting.NotifyOnRemediation` | default `false` | Email when the worker itself restarted a service |
| `Alerting.RemediationCooldownMinutes` | 0 to 10080, default 60 | Minimum gap between `remediated` emails per service |
| `Alerting.HeartbeatHours` | 1 to 168, default 24 | Heartbeat interval; keep it below `WATCHDOG_STALE_HOURS` |
| `Logging.LogRoot` | default `%ProgramData%\ServiceWatchdog\Logs` | Folder for the daily log |
| `Logging.LogRetentionDays` | 1 to 365, default 30 | Old `ServiceWatchdog-*.log` files are deleted at the start of each run |
| `Logging.EventLogHealthyRuns` | default `false` | Also write event 1000 on healthy runs |

Rules: missing optional keys take the defaults; unknown keys produce a warning, not a
failure; values containing the literal `REPLACE` (case-sensitive) in `SiteName`,
`Webhook.Url` or `Webhook.FunctionKey` fail validation with the key named; every violation
is listed at once (exit 2, event 1020). A warning is logged when
`StartPendingWaitSeconds * count(Services)` exceeds `MaxRunSeconds`.

The worst-case wall time of a run is `MaxRunSeconds + 2 * (2 * TimeoutSeconds + 5) + 15`
seconds (385 with the defaults); the installer refuses an `-ExecutionTimeLimitSeconds`
below it.

### State and logs on the server

- `ServiceWatchdog.state.json` beside the config: per-service status, first-failed and
  last-notified times, flap counters, pending-delivery fields, and the last heartbeat. It is
  written atomically; an unreadable file is treated as empty (event 1021). Do not edit it by
  hand; delete it to reset the watchdog's memory.
- `<LogRoot>\ServiceWatchdog-yyyyMMdd.log`: one file per day, every run appended, format
  `[yyyy-MM-dd HH:mm:ss.fff] [LEVEL] message`. The function key is never logged. When
  `Logging.LogRoot` is set, the first lines of each run (before the config is read) land in
  the default root.
- The installer, uninstaller and Azure install script each write one file per run to
  `%ProgramData%\ServiceWatchdog\Logs\<ScriptName>-<yyyyMMdd-HHmmss>.log` (the Azure
  install script uses `$HOME/.ServiceWatchdog/Logs` on macOS and Linux).

## Endpoint scripts

### Invoke-WinServiceWatchdog.ps1

| Parameter | Default | Purpose |
|---|---|---|
| `-ConfigPath` | `ServiceWatchdog.json` beside the script | JSON config to load |
| `-ServiceName <string[]>` | | Replace the configured service list for this run only (logged as an override) |
| `-ValidateConfig` | | Parse and validate the config, print a summary, exit 0 or 2. No service checks, no POST, no state write |
| `-TestAlert` | | Send a `test` event and exit 0 (delivered), 10 (delivery failed) or 2 (config invalid). State untouched |
| `-SendHeartbeat` | | Force a heartbeat this run |
| `-DryRun` | | Do every check, log every intended action with `[DRYRUN]`, never start a service, POST, write state or the event log |
| `-Verbosity Low\|Medium\|High` | `Low` | Console output level; the log file always gets everything |
| `-LogPath` | derived | Override the log file path |

`-ValidateConfig`, `-TestAlert` and `-SendHeartbeat` are mutually exclusive (exit 2).

Exit codes:

| Code | Meaning |
|---|---|
| `0` | All monitored services healthy, or every problem remediated this run |
| `1` | Unexpected error (event 1099) |
| `2` | Configuration or parameters invalid (event 1020) |
| `10` | Notification or heartbeat delivery failed and is pending; no service failures |
| `50` | One or more services `Failed`, `Missing` or `Disabled` after retries (wins over 10) |

Event log (source `ServiceWatchdog`, log `Application`):

| ID | Level | When |
|---|---|---|
| 1000 | Information | Run completed, all services healthy (only with `EventLogHealthyRuns`) |
| 1001 | Information | Service started successfully, with the attempt count |
| 1002 | Error | Service failed to start after retries (on alert, flapping and reminder cadence) |
| 1003 | Warning | Service not installed (same cadence) |
| 1004 | Warning | Service disabled, skipped (same cadence) |
| 1005 | Information | Service recovered |
| 1006 | Warning | Service removed from the monitored list while unhealthy |
| 1007 | Warning | Service flapping; notifications suppressed until the stated time |
| 1010 | Information | Notification delivered (event type, HTTP status) |
| 1011 | Error | Delivery failed: network, DNS or timeout; will retry |
| 1012 | Information | Heartbeat delivered |
| 1013 | Error | Delivery failed: 401 or 403, check the function key; will retry |
| 1014 | Error | Delivery failed: other 4xx, payload rejected; will retry |
| 1015 | Error | Delivery failed: 5xx or 429; will retry |
| 1020 | Error | Configuration invalid (exit 2) |
| 1021 | Warning | State file unreadable, reset to empty |
| 1030 | Information | Test alert sent |
| 1099 | Error | Unexpected error (exit 1) |

The worker registers the event source itself when it is missing and the process is
elevated; otherwise it logs a warning and continues with file logging only.

### Register-WinServiceWatchdogTask.ps1

Requires elevation (`#Requires -RunAsAdministrator`; PowerShell refuses to start the
script otherwise and reports exit 1).

| Parameter | Default | Purpose |
|---|---|---|
| `-InstallPath` | `%ProgramData%\ServiceWatchdog` | Where the worker, config, state and logs live. Resolved to an absolute path first; a filesystem root or Windows system folder is refused (exit 2), as is an existing folder owned by another account |
| `-SourcePath` | script folder | Where to copy the worker and example config from |
| `-ConfigPath` | `<InstallPath>\ServiceWatchdog.json` | Config to validate and use. **Must be inside `InstallPath`** (any file name, subfolders allowed) because that is the only folder the ACL protects; anything else is refused with exit 2 before any change |
| `-TaskName` | `ServiceWatchdog` | Task name in the root Task Scheduler folder |
| `-IntervalMinutes` | 5 | Repetition interval (1 to 1440) |
| `-StartupDelayMinutes` | 5 | Delay on the boot trigger (0 to 1440) |
| `-ExecutionTimeLimitSeconds` | 420 | Task execution limit (60 to 86400); must cover the worst-case run time |
| `-SetServiceRecovery` | off | `sc.exe failure <svc> reset= 86400 actions= restart/60000/restart/120000/none/0` on each listed service |
| `-RunNow` | off | Start the task after registration |
| `-TestAlert` | off | Run the worker with `-TestAlert` after registration |
| `-Force` | off | Overwrite a worker already present in `InstallPath`; needed on every re-run after the first install |
| `-DryRun`, `-Verbosity`, `-LogPath` | | Standard; the config is still validated under `-DryRun` (the worker is run with `-ValidateConfig -DryRun`, so nothing is registered) |

Re-runs always use `Register-ScheduledTask -Force`, but the script's own `-Force` is
needed on every run after the first install because the worker is already present
(the copy is idempotent), so changing `-IntervalMinutes` or `-ExecutionTimeLimitSeconds`
later is `.\Register-WinServiceWatchdogTask.ps1 -Force -IntervalMinutes 10`. The task
action is
`powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "<InstallPath>\Invoke-WinServiceWatchdog.ps1"`,
with `-ConfigPath` appended only when the config has a non-default name; no argument
carries a secret.

| Code | Meaning |
|---|---|
| `0` | Task registered |
| `1` | Unexpected error (including not elevated, and an install-folder ACL that does not read back as SYSTEM and Administrators only) |
| `2` | Config invalid, config not yet edited, config outside `InstallPath`, `InstallPath` a root or system folder or an existing folder with a foreign owner, worker already present without `-Force`, or execution limit too small |
| `10` | Task registered but the `-TestAlert` delivery failed |
| `50` | Task registered but one or more `-SetServiceRecovery` steps failed (the loop continues past a failing service) |

### Unregister-WinServiceWatchdogTask.ps1

Also elevated. `-TaskName` (default `ServiceWatchdog`), `-InstallPath` (default
`%ProgramData%\ServiceWatchdog`), `-RemoveEventSource`, `-RemoveFiles` (deletes the install
folder including config, state and logs; prompts unless `-Force` or `-Confirm:$false`),
`-DryRun`, `-Verbosity`, `-LogPath`. `-WhatIf` behaves like `-DryRun`. `-InstallPath` is
resolved to an absolute path before anything else, so a `..` segment cannot slip past the
protected-folder check. A task that is already absent is not an error. Service Control Manager failure actions set by
`-SetServiceRecovery` are left in place. Exit codes: `0` success, `1` unexpected, `2`
invalid parameters (for example `-RemoveFiles` pointed at a filesystem root or a Windows
system folder). After decommissioning a server, delete its row from the `WatchdogHosts`
table (Storage browser in the portal); otherwise the daily digest lists it as stale
forever.

```powershell
.\Unregister-WinServiceWatchdogTask.ps1                                   # task only; config kept for later re-registration
.\Unregister-WinServiceWatchdogTask.ps1 -RemoveEventSource -RemoveFiles -Force   # complete unattended removal
```

## Azure Function

### App settings

All settings are prefixed `WATCHDOG_`; the two secrets are Key Vault references resolved
by the app's system-assigned identity (Key Vault Secrets User). Redeploying the template
replaces the whole settings collection, so change settings through the template or the
install script, not only in the portal.

The numeric settings (`WATCHDOG_MAIL_TIMEOUT_SECONDS`, `WATCHDOG_SMTP_PORT`,
`WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR`, `WATCHDOG_MAX_EMAILS_PER_HOUR`,
`WATCHDOG_STALE_HOURS`) have a minimum of 1: a value below 1 or a non-numeric one logs a
warning and falls back to the default shown, rather than failing every send or digest.

| Setting | Default | Notes |
|---|---|---|
| `WATCHDOG_MAIL_PROVIDER` | `Smtp2GoApi` | or `Smtp` |
| `WATCHDOG_MAIL_FROM` | required | `Service Watchdog <alerts@example.com>`; must be a verified sender at the provider |
| `WATCHDOG_MAIL_TO` | required | Semicolon-separated recipients; fixed server-side, nothing in a payload can redirect mail |
| `WATCHDOG_MAIL_SUBJECT_PREFIX` | `[Service Watchdog]` | |
| `WATCHDOG_MAIL_TIMEOUT_SECONDS` | `20` | Provider call timeout per attempt |
| `WATCHDOG_SMTP2GO_API_URL` | `https://api.smtp2go.com/v3/email/send` | Regional override only |
| `WATCHDOG_SMTP2GO_API_KEY` | Key Vault secret `Smtp2GoApiKey` | |
| `WATCHDOG_SMTP_HOST` | | e.g. `mail.smtp2go.com`; `Smtp` provider only |
| `WATCHDOG_SMTP_PORT` | `587` | 587 or 2525 |
| `WATCHDOG_SMTP_USERNAME` | | |
| `WATCHDOG_SMTP_PASSWORD` | Key Vault secret `SmtpPassword` | |
| `WATCHDOG_SMTP_USE_STARTTLS` | `true` | Implicit TLS on 465 is not supported |
| `WATCHDOG_TABLE_ENDPOINT` | from the template | Storage table endpoint, ends with `/` |
| `WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR` | `6` | `recovered` and `heartbeat` are exempt; held in worker memory and keyed on the reported host name, so a backstop rather than a hard cap |
| `WATCHDOG_MAX_EMAILS_PER_HOUR` | `60` | Global cap per UTC clock hour across all hosts and worker instances, counted in the `WatchdogSentEvents` table; applies to every email including `recovered` and `test` events. Minimum 1: a value below 1 or a non-numeric one logs a warning and falls back to `60` rather than blocking every send |
| `WATCHDOG_ALLOWED_SITES` | empty | Optional semicolon list of accepted `SiteName` values; empty allows any |
| `WATCHDOG_STALE_HOURS` | `26` | Digest threshold |
| `WATCHDOG_DIGEST_SCHEDULE` | `0 0 7 * * *` | NCRONTAB, UTC |
| `WATCHDOG_DIGEST_ALWAYS_SEND` | `false` | Also send a daily all-clear |

At startup the function checks only the settings its configured provider needs. A value
still starting with `@Microsoft.KeyVault(` is an unresolved reference: the alert function
answers `500 config_unresolved` and the digest fails visibly in Application Insights;
neither ever hands the literal reference to a mail provider.

### HTTP contract (`POST /api/servicewatchdog/alert`)

Function-level auth (`x-functions-key` header). Every response is JSON.

| Status | `error` | Meaning |
|---|---|---|
| 200 | | `{ accepted: true, emailSent, duplicate, providerMessageId }`; `emailSent` is false for heartbeats and duplicates |
| 400 | `invalid_body`, `invalid_payload` | Body not a JSON object, or schema violations listed in `errors` (unknown top-level keys are rejected) |
| 403 | `site_not_allowed` | `SiteName` not in `WATCHDOG_ALLOWED_SITES` |
| 429 | `rate_limited` | Per-host limit or the global emails-per-hour cap reached (`errors` says which); `Retry-After: 600` |
| 500 | `config_unresolved`, `internal_error` | Unresolved Key Vault reference, or an unexpected exception |
| 502 | `provider_failed` | The mail provider did not accept the message |

Every 400 and 403 logs the caller's IP. The SMTP2GO provider treats a 200 with
`data.succeeded >= 1` as sent (partial failures are logged), retries 429 and 5xx twice
(2 s, then 5 s, honoring `Retry-After` up to 30 s), and does not retry other 4xx or
transport errors.

Email subject: `<prefix> <HostName>: <summary>`, with `[TEST]`, `Reminder:` or `Flapping:`
where applicable. Body: site, host, FQDN, time, event type, a table of every monitored
service (name, display name, status, start type, attempts, first failed, last error, with
`*` marking the services that triggered the email) and a footer with the watchdog version,
run id and event id. HTML and plain text are both sent.

### Tables and digest

`WatchdogHosts` (partition = site, row = host) keeps `LastSeenUtc` (the function's own
receipt time, never the server clock), `LastEventType`, `WatchdogVersion`,
`MonitoredServiceCount`, `ProblemServiceCount`; `test` events never create a row.
`WatchdogSentEvents` holds one row per delivered `EventId` for deduplication plus one
counter row per UTC hour (partition `_RateLimit`) for the global cap. Table writes are best
effort and never change the HTTP response. Nothing cleans old rows in v1.

`SendServiceWatchdogDigest` runs on `WATCHDOG_DIGEST_SCHEDULE` and reads every host row:
no rows at all produces a "no hosts have ever reported" notice; any host older than
`WATCHDOG_STALE_HOURS` produces a digest listing each stale host with its last-seen time
and age plus the count of fresh hosts; otherwise nothing is sent unless
`WATCHDOG_DIGEST_ALWAYS_SEND` is true. The digest bypasses the rate limits and dedup. It
lists at most 200 stale hosts and says how many more there are, and logs a warning when the
table holds more than 1000 rows (see "Recovering from a leaked function key").

### Install-AzureServiceWatchdogFunction.ps1

| Parameter | Default | Purpose |
|---|---|---|
| `-ResourceGroupName`, `-BaseName`, `-MailFrom`, `-MailTo` | mandatory | See above |
| `-SubscriptionId` | current context | Selected with `Set-AzContext` when different |
| `-Location` | | Required only when the resource group must be created |
| `-MailProvider Smtp2GoApi\|Smtp` | `Smtp2GoApi` | |
| `-MailSubjectPrefix` | `[Service Watchdog]` | |
| `-Smtp2GoApiKey <SecureString>` | | Required for `Smtp2GoApi`; stored as Key Vault secret `Smtp2GoApiKey` |
| `-SmtpHost`, `-SmtpPort`, `-SmtpCredential <PSCredential>`, `-SmtpUseStartTls <bool>` | 587, `$true` | Required for `Smtp`; the password is stored as `SmtpPassword` |
| `-PowerShellVersion 7.4\|7.6` | `7.4` | Functions worker version (see [Runtime version check](#runtime-version-check)) |
| `-FunctionKeyName` | `watchdog` | Named key created for the servers; an existing key of that name is reused |
| `-SourcePath` | `../AzureFunction` | Function code folder (`host.json` at its root) |
| `-SendTestEmail` | | POST a `test` event after deployment (sends a real email, never creates a `WatchdogHosts` row). The event carries `SiteName` `ServiceWatchdog deployment`, so it is rejected with 403 (exit 50) if `allowedSites` was set by hand |
| `-DryRun`, `-Verbosity`, `-LogPath` | | Standard |

| Code | Meaning |
|---|---|
| `0` | Deployed |
| `1` | Unexpected error |
| `2` | Prerequisites or parameters (missing module, Bicep CLI, provider secret, `-Location` needed) |
| `20` | Not signed in, or not authorized on the subscription or resource group |
| `50` | Template deployed, but a later step failed (the log names the step; fix the cause and re-run) |

Template parameters not exposed by the script (`maxAlertsPerHostPerHour`,
`maxEmailsPerHour`, `staleHours`, `digestSchedule`, `digestAlwaysSend`, `allowedSites`,
`mailTimeoutSeconds`, `smtp2GoApiUrl`, `tags`) keep their defaults; change them by deploying the template by
hand with a parameters file.

## Rotation procedures

### Function key (the value in every server's `ServiceWatchdog.json`)

Keys are named, and several can be valid at once, so rotation has no outage window.

1. Create a new named key. Either re-run the install script with
   `-FunctionKeyName watchdog-2027q1` (it reuses everything else and prints the new key),
   or create it directly:

   ```powershell
   $site = (Get-AzWebApp -ResourceGroupName 'rg-servicewatchdog' -Name 'func-svcwatchdog-abc123').Id
   $created = Invoke-AzRestMethod -Method PUT -Payload '{"properties":{"name":"watchdog-2027q1"}}' `
       -Path "$site/functions/SendServiceWatchdogAlert/keys/watchdog-2027q1?api-version=2024-04-01"
   ($created.Content | ConvertFrom-Json).properties.value   # the new key; paste it into the vault
   ```

   (`az functionapp function keys set ... --key-name watchdog-2027q1` and `keys list` do
   the same from the Azure CLI.)
2. Update `Webhook.FunctionKey` on every server (RMM script or hand edit) and verify each
   with `.\Invoke-WinServiceWatchdog.ps1 -TestAlert` (exit 0).
3. Delete the old key:
   `Invoke-AzRestMethod -Method DELETE -Path "$site/functions/SendServiceWatchdogAlert/keys/watchdog?api-version=2024-04-01"`.
   A server still using it starts logging event 1013 and exit 10, which is the signal that
   it was missed.

Republishing the function code does **not** rotate its keys (they live in the app's
storage account, not in the package); rotate explicitly.

### SMTP2GO API key (or SMTP password)

1. In SMTP2GO, create a new API key with the same scope (`/email/send` only) and rate
   limit. Do not revoke the old one yet.
2. Store it: `Set-AzKeyVaultSecret -VaultName 'kv-svcwatchdog-abc123' -Name 'Smtp2GoApiKey' -SecretValue (Read-Host -AsSecureString)`
   (`SmtpPassword` for the SMTP provider). Your account needs Key Vault Secrets Officer on
   the vault; the deployer received it from the template.
3. Make the app pick it up now rather than at the next 24-hour refresh:
   `Restart-AzWebApp -ResourceGroupName 'rg-servicewatchdog' -Name 'func-svcwatchdog-abc123'`,
   or `Invoke-AzRestMethod -Method POST -Path "$site/config/configreferences/appsettings/refresh?api-version=2022-03-01"`.
4. Verify with `.\Invoke-WinServiceWatchdog.ps1 -TestAlert` on any server (a `[TEST]` email
   proves the new key works end to end).
5. Revoke the old key in SMTP2GO.

### Recovering from a leaked function key

A leaked function key lets its holder post any payload the schema accepts. Recipients and
the sender are fixed server-side and the global cap bounds the mail volume, but heartbeats
send no mail and cannot be told from a real first contact, so the holder can create
`WatchdogHosts` rows for invented host names until the daily digest is mostly noise (the
digest warns in Application Insights once the table passes 1000 rows and lists at most 200
stale hosts). Recovery:

1. Rotate the function key as above and delete the old one; the rows stop growing at once.
2. Delete the invented rows. In the portal, Storage browser > Tables > `WatchdogHosts`
   lets you filter and delete; from a workstation with the Azure CLI:

   ```powershell
   az storage entity query --account-name 'stsvcwatchdogabc123' --table-name 'WatchdogHosts' `
       --auth-mode login --query "items[].{site:PartitionKey, host:RowKey, seen:LastSeenUtc}" -o table
   az storage entity delete --account-name 'stsvcwatchdogabc123' --table-name 'WatchdogHosts' `
       --auth-mode login --partition-key 'Example Org' --row-key 'FAKE-HOST-01'
   ```

   (Storage Table Data Contributor on the account is required; the deployer does not get
   it from the template, so assign it for the cleanup and remove it afterwards.) A real
   server that is deleted by mistake writes its row again on its next heartbeat.
3. If the digest is not needed for a day, the rows under partition `_RateLimit` in
   `WatchdogSentEvents` can stay; they are one per hour and harmless.

## Runtime version check

**Check before 2026-11-10.** The Function App runs PowerShell 7.4, whose support on Azure
Functions ends on **10 November 2026**. PowerShell 7.6 is the successor and, at the time of
writing, is in preview on Windows plans only. Before that date:

1. Read the current table at
   <https://learn.microsoft.com/azure/azure-functions/supported-languages>.
2. When 7.6 is generally available on Windows Consumption, redeploy with
   `-PowerShellVersion 7.6` (install script) or set the `powerShellVersion` template
   parameter; the one value sets both `FUNCTIONS_WORKER_RUNTIME_VERSION` and
   `siteConfig.powerShellVersion`.
3. Run the install script with `-SendTestEmail`, then `-TestAlert` from a server.

The function ships no Az modules and no managed dependencies, so the version bump is a
parameter change and nothing else. If a later GA version is not `7.4` or `7.6`, extend the
`@allowed` list on `powerShellVersion` in `main.bicep` and the `ValidateSet` on
`-PowerShellVersion` in the install script.

## Troubleshooting

**The portal or `listkeys` does not show a key you just created, or shows one you deleted.**
The Functions host answers key listings from an in-memory cache that is seeded when the
instance starts. The install script requests a trigger sync before it looks for an existing
key so the cache is refreshed; if you manage keys by hand, run
`Invoke-AzRestMethod -Method POST -Path "$site/syncfunctiontriggers?api-version=2024-04-01"`
before listing, or restart the app. A key the listing does not show is still honored by the
function, because authorization re-reads the secret store on a miss.

**`Publish-AzWebApp` fails with 401 (exit 50 at the publish step).** SCM basic
authentication is disabled on the app or by Azure Policy, and this Az version could not
fall back to Entra ID authentication. Either update Az to 9.7.1 or later, or allow basic
auth for the SCM site and re-run:

```powershell
$site = (Get-AzWebApp -ResourceGroupName 'rg-servicewatchdog' -Name 'func-svcwatchdog-abc123').Id
Invoke-AzRestMethod -Method PUT -Payload '{"properties":{"allow":true}}' `
    -Path "$site/basicPublishingCredentialsPolicies/scm?api-version=2024-04-01"
```

(`az resource update --ids "$site/basicPublishingCredentialsPolicies/scm" --set properties.allow=true`
from the Azure CLI.) A policy assignment may set it back; check with your Azure
administrator.

**Redeploying after deleting the resource group fails on the Key Vault** ("a vault with the
same name already exists in a deleted state"). The vault has purge protection, so the
soft-deleted vault cannot be purged and its name is reserved for 90 days. Either recover
it first (recreate a resource group with the original name, then
`Undo-AzKeyVaultRemoval -VaultName 'kv-svcwatchdog-abc123' -ResourceGroupName 'rg-servicewatchdog' -Location 'eastus2'`)
and re-run the install script, which reuses the recovered vault, or deploy with a
different `-BaseName` or resource group name (the vault name is derived from both).

**Redeploying after deleting only the Function App fails with
`RoleAssignmentUpdateNotPermitted`.** The new app has a new managed identity but the old
role assignments still exist under the same deterministic names. Delete the two
assignments that show "Identity not found" (one on the Key Vault, one on the storage
account) in Access control (IAM), then re-run.

**`-TestAlert` works interactively but the scheduled task logs event 1011 (timeout).**
The task runs as SYSTEM, which uses the machine-wide WinHTTP proxy, not the signed-in
user's browser proxy. Check and set it:

```cmd
netsh winhttp show proxy
netsh winhttp set proxy proxy-server="proxy.example.com:8080" bypass-list="<local>"
netsh winhttp import proxy source=ie     :: alternative: copy the current user's settings
```

Also confirm outbound 443 to the Function App host name is allowed from the server and
that `Webhook.TimeoutSeconds` is realistic for the link.

**Event 1013 (401 or 403) on every run.** 401: the function key is wrong or was deleted
during rotation; paste the current key. 403 with `site_not_allowed` in the log: the
config's `SiteName` is not in `WATCHDOG_ALLOWED_SITES`.

**Event 1014 (400) on every run.** The function rejected the payload; the log line carries
the function's `errors` list. Usually a server running an older worker against a newer
function or vice versa; keep both on the same version.

**Function answers `500 config_unresolved`.** A Key Vault reference did not resolve: the
secret is missing (re-run the install script, which seeds it), the app's identity lacks
Key Vault Secrets User, or the app has not restarted since the secret was created
(`Restart-AzWebApp`). The portal's "Key Vault Application Settings Diagnostics" blade
shows which reference failed.

**Alerts resume up to an hour late after a mail provider outage.** The per-host rate limit
counts attempts, not successes, and the endpoint re-posts its pending event every 5
minutes, so a 30-minute provider outage can consume the hourly allowance. Wait it out,
raise `WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR`, or restart the app (the counter lives in
worker memory). The global cap (`WATCHDOG_MAX_EMAILS_PER_HOUR`) counts only emails the
provider accepted; a 429 whose `errors` names the global limit means the whole fleet sent
that many emails in the current UTC hour, which is worth a look on its own.

**Install script exits 50 with "functionsRuntimeAdminIsolationEnabled could not be
confirmed".** The key was already printed; the deployment is usable. The property is
outside the ARM schema, so check it in the portal (Function App > Configuration > General
settings, or `az resource show` on the site and look for
`functionsRuntimeAdminIsolationEnabled`), set it by hand if needed, and re-run the script
to verify. The log line "Site reports functionsRuntimeAdminIsolationEnabled = ..." shows
what ARM returned.

**Digest says "no hosts have ever reported".** No server has reached the function yet:
check the task exists and runs (`Get-ScheduledTaskInfo`), the config, and event 1011/1013
on the servers.

**Installer exits 1 immediately with a message about elevation.** `#Requires
-RunAsAdministrator` stops the script before it runs; open PowerShell as administrator.

**Installer exits 2: "outside the install folder".** `-ConfigPath` must point inside
`-InstallPath`; only that folder is ACLed and the worker writes its state file beside the
config.

**Worker warns that the event source is missing.** The installer registers it; if the
worker is run by hand without elevation it cannot, and continues with file logging only.

**Deploying `main.bicep` by hand fails with `PrincipalNotFound`.** `deployerObjectId` in
the parameters file is still the all-zero placeholder; set it to
`(Get-AzADUser -SignedIn).Id` (or the service principal's object id and
`deployerPrincipalType: ServicePrincipal`).

**PowerShell 7.4 end of support.** See [Runtime version check](#runtime-version-check).

## Development

```powershell
cd Monitoring/ServiceWatchdog/Tests
pwsh -NoProfile -Command "Invoke-Pester -Path . -Output Detailed"                 # all suites (Pester 5.5 syntax)
pwsh -NoProfile -File ./Test-WindowsPowerShellCompat.ps1 -Path ../Endpoint          # no PowerShell 7-only syntax in the endpoint scripts
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path .. -Recurse -Settings PSGallery -Severity Warning,Error"
bicep build ../Deploy/main.bicep --outdir /tmp; bicep lint ../Deploy/main.bicep    # clean apart from the suppressed BCP037
```

`requirements.psd1` produces one expected PSScriptAnalyzer finding
(`PSMissingModuleManifestField`): it is the Functions managed-dependency data file, not a
module manifest. Endpoint scripts must stay Windows PowerShell 5.1 compatible; the
compatibility checker enforces the list in `DESIGN.md` section 4.1.

## Ideas for a later version

Not in v1, deliberately: monitoring plain processes; DPAPI protection of the config file
(SYSTEM has no SecretManagement vault, so the key sits in the ACLed folder); HMAC request
signing; IP restrictions on the function; dead-letter queuing when the mail provider is
down; a cross-server outage digest; a Flex Consumption template (Linux-only, currently 7.4
only); Teams or RMM notification channels; cleanup of old rows in `WatchdogSentEvents`.
