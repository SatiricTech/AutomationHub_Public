# ServiceWatchdog Design

Version 1.0.0 design specification. This document is the source of truth for the
implementation; the README is the operator-facing summary.

## 1. Purpose

Keep a named set of Windows services running on a server and tell IT when that is not
possible. A scheduled task runs a PowerShell watchdog every 5 minutes and shortly after
boot. The watchdog starts stopped services, retries, and reports outcomes to a webhook.
The webhook is an Azure Function that renders and sends an email through SMTP2GO (REST
API) or any SMTP relay, with credentials held in Azure Key Vault. A daily heartbeat lets
the Azure side notice when a server's watchdog has gone silent. The Azure side never
inspects or controls services; it only relays and correlates what the endpoint reports.

Non-goals for v1: monitoring plain processes, DPAPI-protecting the config file, HMAC
request signing, IP restrictions on the function, dead-letter queuing when the mail
provider is down, cross-server outage digests, a Flex Consumption template, Teams or RMM
notification channels, cleanup of old rows in the sent-events table.

## 2. Components and data flow

```
Windows Server VM                                Azure                          Mail
+--------------------------------+   HTTPS POST  +--------------------------+   +--------+
| Task Scheduler (SYSTEM)        |  x-functions- | Function App (PS 7.4)    |   | SMTP2GO|
|  every 5 min + boot+5 min      |  key header   |  SendServiceWatchdogAlert |-->| API or |
|   -> Invoke-WinServiceWatchdog | ------------> |   validate, dedup, render,|   | SMTP   |
|      reads ServiceWatchdog.json|               |   send, record last-seen  |   +---+----+
|      starts services, retries  |               |  SendServiceWatchdogDigest|       |
|      writes state + event log  |               |   timer: stale hosts      |       v
+--------------------------------+               |  Key Vault refs -> secrets|   IT list
                                                 |  Tables: WatchdogHosts,   |
                                                 |          WatchdogSentEvents|
                                                 +--------------------------+
```

Event types sent by the endpoint: `alert`, `flapping`, `reminder`, `recovered`,
`remediated`, `test`, `heartbeat`. Only `heartbeat` never produces an email.

## 3. Repository layout

```
Monitoring/ServiceWatchdog/
├── README.md                          operator documentation (PerUserMfaAudit precedent)
├── DESIGN.md                          this document
├── .gitignore                         ServiceWatchdog.json, *.state.json, local.settings.json,
│                                      Deploy/main.parameters.json, *.zip, test output
├── Endpoint/
│   ├── Invoke-WinServiceWatchdog.ps1          the 5-minute worker
│   ├── Register-WinServiceWatchdogTask.ps1    installer
│   ├── Unregister-WinServiceWatchdogTask.ps1  uninstaller
│   └── ServiceWatchdog.example.json           copy to ServiceWatchdog.json and edit
├── AzureFunction/
│   ├── host.json
│   ├── local.settings.example.json
│   ├── profile.ps1                            minimal, no Az modules
│   ├── requirements.psd1                      empty managed-dependency manifest
│   ├── Modules/ServiceWatchdogAlert/
│   │   ├── ServiceWatchdogAlert.psd1
│   │   └── ServiceWatchdogAlert.psm1          config, validation, rendering, providers, tables
│   ├── SendServiceWatchdogAlert/
│   │   ├── function.json                      HTTP POST, authLevel function
│   │   └── run.ps1
│   └── SendServiceWatchdogDigest/
│       ├── function.json                      timer + table input
│       └── run.ps1
├── Deploy/
│   ├── main.bicep
│   ├── main.parameters.example.json           copy to main.parameters.json (ignored) if deploying by hand
│   └── Install-AzureServiceWatchdogFunction.ps1
├── Docs/
│   └── Hudu-ServiceWatchdog.html              knowledge-base article draft
└── Tests/
    ├── Test-WindowsPowerShellCompat.ps1       AST scan for PowerShell 7-only syntax
    ├── Test-WindowsPowerShellCompat.Tests.ps1
    ├── Invoke-WinServiceWatchdog.Tests.ps1
    ├── Register-WinServiceWatchdogTask.Tests.ps1
    ├── Unregister-WinServiceWatchdogTask.Tests.ps1
    ├── ServiceWatchdogAlert.Tests.ps1
    ├── SendServiceWatchdogAlert.Tests.ps1
    ├── SendServiceWatchdogDigest.Tests.ps1
    └── Install-AzureServiceWatchdogFunction.Tests.ps1
```

Naming follows the `powershell-naming` skill: `Win` is the Windows OS scope token,
`Azure` is the Microsoft Azure scope token (not `Az`, `AzFunc`). All artifacts share the
concept name `ServiceWatchdog` so they sort together and read consistently in Task
Scheduler, the event log, Azure, and Hudu.

Default log path for every script other than the worker (see 4.9 for the worker):
`$env:ProgramData\ServiceWatchdog\Logs\<ScriptName>-<yyyyMMdd-HHmmss>.log`, one file per
run per checklist 4.7. The `$MSPName` root is not used for the reason in 4.9; each script
states the deviation in `.NOTES`.

## 4. Endpoint: Invoke-WinServiceWatchdog.ps1

### 4.1 Runtime and tier

- `#Requires -Version 5.1`. Must run unchanged on Windows PowerShell 5.1 and PowerShell 7.
  No ternary, null-coalescing, null-conditional, pipeline chain operators,
  `ForEach-Object -Parallel`, `-SslProtocol`, `-MaximumRetryCount`, `-SkipHttpErrorCheck`,
  `Join-Path` with more than two positional segments, or `.StartType` on service objects.
- Windows-only, declared in the header.
- Enterprise tier: full comment-based help, `[CmdletBinding()]`, `-DryRun`, `-Verbosity`
  (`Low|Medium|High`), `-LogPath`, `Write-Log`, `Invoke-Action`, regions in the standard
  order, semantic version, AI disclosure in `.NOTES`, Pester tests at 80%+ coverage.
- Checklist deviations, stated in each script's `.NOTES`: 3.1 (Windows PowerShell 5.1
  target, endpoint scripts only, because Windows Server ships only 5.1); 4.6/4.7 (log root
  and daily log file, see 4.9); 5.2 (the function key lives in the ACLed config file
  because SYSTEM has no SecretManagement vault; DPAPI is a v2 item); 5.7 (scripts ship
  unsigned in the public repo; adopters sign with their own certificate); 6.6 (the
  integration test is the operator acceptance run in section 9); 6.7 (not applicable; run
  time is bounded by `MaxRunSeconds`).
- Runs as SYSTEM under Task Scheduler; must also work when run interactively as an admin.

### 4.2 Parameters

| Parameter | Type | Default | Purpose |
|---|---|---|---|
| `-ConfigPath` | string | `<script folder>\ServiceWatchdog.json` | JSON config to load |
| `-ServiceName` | string[] | none | Ad-hoc override of the config service list for this run |
| `-ValidateConfig` | switch | | Parse and validate config, print summary, exit 0 or 2. No checks, no POST |
| `-TestAlert` | switch | | Send a `test` event through the webhook and exit. No service checks, state untouched |
| `-SendHeartbeat` | switch | | Force a heartbeat this run regardless of schedule |
| `-DryRun` | switch | | Do every check, log every intended action with `[DRYRUN]`, never start a service, never POST, never write state or the event log |
| `-Verbosity` | Low/Medium/High | Low | Console output level; file log always complete |
| `-LogPath` | string | derived | Override the log file path |

`-ValidateConfig` and `-TestAlert` are mutually exclusive with each other and with
`-SendHeartbeat`; combining them is a parameter error (exit 2).

### 4.3 Configuration file schema (ServiceWatchdog.json, SchemaVersion 1)

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

Validation rules (exit code 2 with every violation listed, event 1020):

- `SchemaVersion` must be 1. `SiteName` 1 to 64 printable characters.
- `Services` non-empty array of 1 to 100 unique strings, each 1 to 256 characters. Service
  names are the short name (`Spooler`), not the display name; the watchdog also accepts a
  display name and resolves it, logging the short name it resolved to.
- Integers: `MaxStartAttempts` 1 to 20, `RetryDelaySeconds` 0 to 300,
  `PostStartVerifySeconds` 0 to 120, `StartPendingWaitSeconds` 0 to 300, `MaxRunSeconds`
  30 to 3600, `TimeoutSeconds` 5 to 120, `ReminderMinutes` 5 to 10080,
  `RemediationCooldownMinutes` 0 to 10080, `HeartbeatHours` 1 to 168,
  `LogRetentionDays` 1 to 365.
- `MaxRunSeconds` bounds the service checks and start rounds only (4.5). The worst-case
  wall time of a run is `MaxRunSeconds + 2 * (2 * TimeoutSeconds + 5) + 15` seconds (two
  webhook calls with one retry each, plus startup). The installer checks this against the
  task execution limit (5.1).
- Warning (not failure) when `StartPendingWaitSeconds * count(Services)` exceeds
  `MaxRunSeconds`, because that combination cannot finish every wait inside the budget.
- `Webhook.Url` must be `https://`. `Webhook.FunctionKey` non-empty. Placeholder values
  (containing `REPLACE`) fail validation with a message naming the key to edit.
- Unknown keys produce a warning, not a failure, so a newer config works on an older script.
- Missing optional keys take the defaults above. `Logging.LogRoot` empty means
  `$env:ProgramData\ServiceWatchdog\Logs`.
- `Services` must be a JSON array; a bare string is a validation error. Placeholder detection
  (`REPLACE`, case-sensitive) also covers `SiteName`.
- `-ServiceName` replaces `Services` for that run only and is logged as an override.
- `-ValidateConfig` performs no log-retention sweep; retention runs only on real runs and
  `-TestAlert`.

### 4.4 State file (ServiceWatchdog.state.json, beside the config)

```json
{
  "SchemaVersion": 1,
  "HostName": "SRV-EXAMPLE-01",
  "LastRunUtc": "2026-09-04T18:05:02Z",
  "LastHeartbeatUtc": "2026-09-04T07:00:11Z",
  "PendingNotification": false,
  "PendingEventId": null,
  "PendingEventType": null,
  "PendingServices": [],
  "Services": {
    "Spooler": {
      "Status": "Healthy",
      "FirstFailedUtc": null,
      "LastNotifiedUtc": null,
      "LastRemediatedUtc": "2026-09-03T11:20:44Z",
      "LastError": null,
      "FlapCount": 0,
      "FlapWindowStartUtc": null,
      "FlapSuppressedUntilUtc": null
    }
  }
}
```

- `Status` is one of `Healthy`, `Failed`, `Missing`, `Disabled`, `Unknown`. `Unknown` is
  written only when the service check itself threw an unexpected exception (not the
  Missing case) and is treated like `Healthy` for transition purposes.
- Unreadable or invalid state is treated as empty, logged as WARNING, and reported as
  event 1021. The file is written atomically (write temp file, then move). `-DryRun` never
  writes it.
- On each run, after loading state, entries whose key is not in the effective service list
  (after any `-ServiceName` override) are removed. If a removed entry's `Status` was
  `Failed`, `Missing`, or `Disabled`, event 1006 (WARNING) records that the service was
  dropped from monitoring while unhealthy.
- All timestamps are strings in the form `yyyy-MM-ddTHH:mm:ssZ` (UTC), produced with
  `.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')`, never raw `[datetime]` objects.

### 4.5 Service handling

A single stopwatch for the whole run starts before the first service check; every wait
below is capped at the seconds remaining of `MaxRunSeconds`. For each configured service,
in order:

| Observed condition | Action | Recorded status |
|---|---|---|
| Not installed (`Get-Service` fails) | none | `Missing` |
| Start mode `Disabled` (from `Win32_Service.StartMode`) | none, never change start type | `Disabled` |
| `Running` | none | `Healthy` |
| `StartPending` | `WaitForStatus('Running', min(StartPendingWaitSeconds, remaining))`; never issue a new start; still pending when the budget is gone is `Failed` with `LastError` noting the budget | `Healthy` or `Failed` |
| `Stopped`, `StopPending`, `Paused`, other | eligible for start rounds | `Failed` unless a round succeeds |
| Check threw an unexpected exception | none, logged | `Unknown` |

Start rounds:

1. Round counter starts at 1. While any service is eligible, the round is at most
   `MaxStartAttempts`, and time remains:
   - For each eligible service, `Start-WatchdogService` (a helper that calls
     `(Get-Service <name>).Start()`, which does not block, then
     `WaitForStatus('Running', min(PostStartVerifySeconds, remaining))`) inside
     `Invoke-Action`. Capture the exception message as `LastError`. The Service Control
     Manager starts declared dependencies itself; dependency failures surface in that
     message. `Start-Service` is not used because it blocks until the SCM resolves the
     start and could consume the whole budget on one stuck service.
   - After the wait, re-read every eligible service. A service that is `Running` leaves the
     eligible set as remediated with `Attempts = round`. A service that started and stopped
     again is still failed with `LastError` set to a flapping message.
   - If services remain and another round is allowed, sleep `RetryDelaySeconds`, capped so
     the time budget is respected.
2. When the budget runs out before the attempt count is exhausted, remaining services are
   `Failed` with `LastError` noting the budget, and `Attempts` reflects rounds actually run.

Event 1001 is written for every successful start. Events 1002, 1003 and 1004 are written
when the 4.6 category for that service is `alert`, `flapping`, or `reminder` (once on
transition and again at the reminder cadence); 1005 is written when the category is
`recovered`. These are independent of email settings.

### 4.6 Notification decisions

Computed after the rounds, per service, comparing new status with the previous state:

| Previous | New | Category | Notes |
|---|---|---|---|
| Healthy / Unknown / none | Failed, Missing, Disabled | `alert` | sets `FirstFailedUtc` |
| Failed / Missing / Disabled | same problem, `now - LastNotifiedUtc >= ReminderMinutes` | `reminder` | |
| Failed / Missing / Disabled | different problem (e.g. Missing to Failed) | `alert` | |
| Failed / Missing / Disabled | Healthy (with or without our action) | `recovered` | clears `FirstFailedUtc` |
| Healthy / Unknown / none | Healthy after our start succeeded | `remediated` | only if `NotifyOnRemediation` and `now - LastRemediatedUtc >= RemediationCooldownMinutes` |

Flapping: every transition between a problem status and `Healthy` (either direction)
increments `FlapCount` inside a rolling 60-minute window that starts at
`FlapWindowStartUtc`; the window and count reset when 60 minutes pass with no transition.
On the fourth transition inside the window the service's category becomes `flapping`
(replacing `alert` or `recovered`), event 1007 is written, and `FlapSuppressedUntilUtc`
is set to `now + ReminderMinutes`. While suppressed, the service produces no `alert`,
`recovered`, `remediated`, or `reminder` category, and events 1002/1005 are not written;
its status is still tracked and still appears in payloads. When the suppression time
passes and the service has held one status since `FlapSuppressedUntilUtc` was set, the
flap fields reset and normal notification resumes with the next transition; if it has not
held one status, another `flapping` event is sent and the suppression is extended by
`ReminderMinutes`.

If any service is notifiable, exactly one event is POSTed for the run. The event type is
the highest-priority category present: `alert` > `flapping` > `recovered` > `remediated`
> `reminder`. The payload lists every monitored service with its current status so the
email is a complete picture, and marks which services triggered the notification.

Event identity: each notification carries an `EventId` (GUID). When `PendingNotification`
is true and this run's category and set of notifiable services equal `PendingEventType`
and `PendingServices`, the run reuses `PendingEventId`; otherwise it generates a new one.
The function deduplicates on `EventId` (6.4), so a retry of an already-delivered
notification cannot email twice.

Delivery: on success the new per-service `Status` values are committed to state,
`LastNotifiedUtc` is stamped for the notifiable services, and the `Pending*` fields are
cleared. On failure (network error, timeout, 5xx, 429, or any 4xx) the state is saved with
`PendingNotification = true`, `PendingEventId`, `PendingEventType`, and
`PendingServices` set, and, for every service that was notifiable this run, the previous
`Status`, `FirstFailedUtc`, `LastNotifiedUtc`, `FlapCount`, `FlapWindowStartUtc`, and
`FlapSuppressedUntilUtc` are preserved unchanged (`LastError` and `LastRemediatedUtc` are
updated), so the next run computes the same transition again and re-sends. The flap fields
are preserved alongside `Status` so that a transition whose delivery is retried is counted
toward the flap threshold exactly once, when it is finally committed; otherwise a single
outage during a webhook outage would be counted on every retry run and become `flapping`
(review ruling, 2026-09-04). Services that were not notifiable commit normally. A
`remediated` category whose delivery fails is dropped and logged, because it is
informational only. Delivery failures write event 1011, 1013, 1014, or 1015 (4.9).

Heartbeat: when `now - LastHeartbeatUtc >= HeartbeatHours`, or `-SendHeartbeat`, a
`heartbeat` event is POSTed after any notification event. Success stamps
`LastHeartbeatUtc` and writes event 1012; failure is logged and retried next run.

### 4.7 Webhook call

- On Windows PowerShell 5.1 only: `[Net.ServicePointManager]::SecurityProtocol =
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12`.
- `Invoke-WebRequest -UseBasicParsing -Method Post -Uri <Url> -Headers @{ 'x-functions-key'
  = <key>; 'User-Agent' = 'ServiceWatchdog/1.0.0' } -ContentType 'application/json;
  charset=utf-8' -Body <UTF-8 bytes of ConvertTo-Json -Depth 10> -TimeoutSec
  <TimeoutSeconds>`; read `.StatusCode` and parse `.Content` with `ConvertFrom-Json`. On
  failure read `$_.Exception.Response.StatusCode` (a `WebException` on 5.1, an
  `HttpResponseException` on 7) and the response body when available. `Invoke-WebRequest`
  is used rather than `Invoke-RestMethod` because 5.1 exposes no status code on success
  otherwise.
- One retry after 5 seconds on timeout, network error, or 5xx. No retry on 4xx.
- The function key is never written to the log; the URL is logged with the key redacted
  if it ever appears in a query string.
- Proxy: the script honors the WinHTTP proxy in effect for SYSTEM. The README documents
  `netsh winhttp set proxy` for sites that need it.

### 4.8 Payload schema (SchemaVersion 1)

```json
{
  "SchemaVersion": 1,
  "EventType": "alert",
  "EventId": "8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d",
  "SiteName": "Example Org",
  "HostName": "SRV-EXAMPLE-01",
  "Fqdn": "srv-example-01.example.com",
  "TimestampUtc": "2026-09-04T18:05:02Z",
  "RunId": "3f9c7a44-1c2e-4b1a-9e6b-0b2a4c9d8e11",
  "WatchdogVersion": "1.0.0",
  "Summary": "2 of 3 monitored services are down",
  "Services": [
    {
      "Name": "Spooler",
      "DisplayName": "Print Spooler",
      "Status": "Failed",
      "StartType": "Automatic",
      "Attempts": 5,
      "FirstFailedUtc": "2026-09-04T17:50:01Z",
      "LastError": "Cannot start service Spooler on computer '.'",
      "FlapCount": 0,
      "Notify": true
    }
  ]
}
```

- Payload `Status` per service is derived as: `Recovered` when the 4.6 category for the
  service is `recovered`; `Remediated` when our start succeeded this run (regardless of
  `NotifyOnRemediation`); otherwise the state `Status` (`Healthy`, `Failed`, `Missing`,
  `Disabled`, `Unknown`). `Notify` is true for every service that has a 4.6 category this run;
  all of them ride in the single POST, and `EventType` is only the highest-priority category.
- `StartType` is one of `Boot`, `System`, `Automatic`, `AutomaticDelayedStart`, `Manual`,
  `Disabled`, `Unknown`, mapped from `Win32_Service.StartMode` plus `DelayedAutoStart`
  (`Auto` with `DelayedAutoStart` true = `AutomaticDelayedStart`); null for `Missing`.
- Nullable: `Fqdn`, `DisplayName`, `StartType`, `FirstFailedUtc`, `LastError`. `Attempts`
  and `FlapCount` are integers, 0 when not applicable. Every other field is required and
  non-null. Timestamps use the 4.4 format.
- The endpoint truncates `LastError` to 1000 characters, `Summary` to 512, and
  `DisplayName` to 256 before sending; the ` [truncated]` marker it appends counts toward
  the limit, so the sent value never exceeds it.
- `test` events carry an empty `Services` array and a summary line. `heartbeat` events
  carry the full service list with `Notify = false` everywhere. Both use a fresh `EventId`.
- The endpoint never adds fields beyond this schema; the function rejects unknown
  top-level keys (6.3).

### 4.9 Logging

- File: `<LogRoot>\ServiceWatchdog-yyyyMMdd.log`, one file per day, appended by every run.
  At the start of each run, files matching `ServiceWatchdog-*.log` older than
  `LogRetentionDays` are deleted, each inside its own try/catch; a deletion failure is a
  WARNING and never aborts the run. Format `[yyyy-MM-dd HH:mm:ss.fff] [LEVEL] message`.
  This deviates from the authoring skill's per-run file naming because a 5-minute task
  would create 288 files a day; `$MSPName` is not used because the tool is deployed by
  end-client IT, so the path is product-named. Both deviations are stated in `.NOTES`.
  Sensitive values are masked.
- Event log: source `ServiceWatchdog` in the `Application` log. The worker registers the
  source itself if missing and it is elevated (guarded by `SourceExists`); otherwise it
  logs a warning and continues with file logging only.

| ID | Level | When |
|---|---|---|
| 1000 | Information | Run completed, all services healthy (only if `EventLogHealthyRuns`) |
| 1001 | Information | Service started successfully, with attempt count |
| 1002 | Error | Service failed to start after retries, with last error (alert/flapping/reminder cadence) |
| 1003 | Warning | Service not installed (same cadence) |
| 1004 | Warning | Service disabled, skipped (same cadence) |
| 1005 | Information | Service recovered |
| 1006 | Warning | Service removed from the monitored list while unhealthy |
| 1007 | Warning | Service flapping; notifications suppressed until the stated time |
| 1010 | Information | Notification delivered (event type, HTTP status) |
| 1011 | Error | Delivery failed: network, DNS, or timeout; will retry |
| 1012 | Information | Heartbeat delivered |
| 1013 | Error | Delivery failed: 401/403, check the function key; will retry |
| 1014 | Error | Delivery failed: other 4xx from the function (payload rejected); will retry |
| 1015 | Error | Delivery failed: 5xx or 429 from the function; will retry |
| 1020 | Error | Configuration invalid (exit 2) |
| 1021 | Warning | State file unreadable, reset to empty |
| 1030 | Information | Test alert sent |
| 1099 | Error | Unexpected error (exit 1) |

### 4.10 Exit codes

| Code | Meaning |
|---|---|
| 0 | All monitored services healthy, or all problems remediated this run |
| 1 | Unexpected error |
| 2 | Configuration or parameters invalid |
| 10 | Notification or heartbeat delivery failed and is pending (no service failures) |
| 50 | One or more services Failed, Missing, or Disabled after retries |

When both 50 and 10 apply, 50 wins and both conditions are logged. `-TestAlert` exits 0
when the function returned 200, 10 when delivery failed, 2 on invalid config.
`-SendHeartbeat` follows the normal run codes. `-ValidateConfig` exits 0 or 2.

## 5. Endpoint: Register-WinServiceWatchdogTask.ps1 and Unregister-WinServiceWatchdogTask.ps1

Both `#Requires -Version 5.1`, `#Requires -RunAsAdministrator`, Enterprise tier. Elevation
is enforced by `#Requires`, which stops the script before it runs (the host reports exit
1); `.NOTES` documents this.

### 5.1 Register

| Parameter | Default | Purpose |
|---|---|---|
| `-InstallPath` | `$env:ProgramData\ServiceWatchdog` | Where the worker, config, state, and logs live |
| `-SourcePath` | `$PSScriptRoot` | Where to copy `Invoke-WinServiceWatchdog.ps1` and the example config from |
| `-ConfigPath` | `<InstallPath>\ServiceWatchdog.json` | Config to validate and use |
| `-TaskName` | `ServiceWatchdog` | Task name in the root Task Scheduler folder |
| `-IntervalMinutes` | 5 | Repetition interval |
| `-StartupDelayMinutes` | 5 | Delay on the boot trigger |
| `-ExecutionTimeLimitSeconds` | 420 | Task execution limit; must be at least the worst-case run time from 4.3 |
| `-SetServiceRecovery` | off | Also set SCM failure actions on each listed service via `sc.exe failure` |
| `-RunNow` | off | Start the task immediately after registration |
| `-TestAlert` | off | Run the worker with `-TestAlert` after registration |
| `-Force` | off | Overwrite an existing worker script at `InstallPath` |
| `-DryRun`, `-Verbosity`, `-LogPath` | | standard |

Steps, each through `Invoke-Action`:

1. Create `InstallPath`. Copy the worker script; if it already exists and `-Force` is not
   set, exit 2 with a message to re-run with `-Force`. If no config exists, copy
   `ServiceWatchdog.example.json` to `ConfigPath`, then stop with exit 2 and a message to
   edit it and re-run.
2. ACL `InstallPath` with `icacls`, wrapped in a helper `Set-WatchdogInstallAcl` so tests
   can mock it: `icacls "<InstallPath>" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F"
   "*S-1-5-32-544:(OI)(CI)F"` (well-known SIDs for SYSTEM and Administrators, so the call
   is locale-safe); a non-zero exit code fails the step.
3. Refuse a `-ConfigPath` outside `InstallPath` (subfolders allowed) with exit 2 before any
   mutation, because the ACL in step 2 only protects that folder. Validate the config by
   running the worker with `-ValidateConfig -ConfigPath <path>`; abort on non-zero. Under
   `-DryRun` the source copy of the worker is used because the install copy does not exist
   yet.
   Then read `MaxRunSeconds` and `Webhook.TimeoutSeconds` from the config and exit 2 if
   `-ExecutionTimeLimitSeconds` is below `MaxRunSeconds + 2 * (2 * TimeoutSeconds + 5) + 15`.
4. Register the event source (`SourceExists` guard).
5. Register the task with `Register-ScheduledTask -Force` (always, regardless of the
   script's own `-Force`, because re-registration is idempotent and must succeed on reruns
   that only change scheduling parameters):
   - Principal `NT AUTHORITY\SYSTEM`, `RunLevel Highest`.
   - Trigger A (continuous schedule): `$daily = New-ScheduledTaskTrigger -Daily -At
     '00:00'`; the cmdlet exposes repetition only on its `-Once` parameter set, so build a
     throwaway `$once = New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval
     (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 1)`
     and copy `$daily.Repetition = $once.Repetition`.
   - Trigger B (post-boot): `$boot = New-ScheduledTaskTrigger -AtStartup;
     $boot.Delay = "PT${StartupDelayMinutes}M"` (the cmdlet exposes only `-RandomDelay`).
   - Settings: `MultipleInstances IgnoreNew`, `ExecutionTimeLimit`, `StartWhenAvailable`,
     `AllowStartIfOnBatteries`, `DontStopIfGoingOnBatteries`.
   - Action: `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
     -WindowStyle Hidden -File "<InstallPath>\Invoke-WinServiceWatchdog.ps1"`, with
     `-ConfigPath <path>` appended only when the config is not beside the worker. No
     argument carries a secret.
   - Description names this repository and the version.
6. Optional `-SetServiceRecovery`: `sc.exe failure <svc> reset= 86400
   actions= restart/60000/restart/120000/none/0` per Microsoft's non-critical guidance.
7. Optional `-RunNow` and `-TestAlert`.
8. Print a summary: install path, task name, next run time, config path, log path.

Exit codes: 0 success, 1 unexpected, 2 config invalid, not yet edited, outside
`InstallPath`, worker already present without `-Force`, or execution limit too small,
10 task registered but the `-TestAlert` delivery failed, 50 task registered but one or
more `-SetServiceRecovery` steps failed (the loop continues past a failing service).

### 5.2 Unregister

Parameters: `-TaskName` (default `ServiceWatchdog`), `-InstallPath` (default
`$env:ProgramData\ServiceWatchdog`), `-RemoveEventSource`, `-RemoveFiles` (deletes the
install folder including config, state, and logs), `-Force` (skips the `-RemoveFiles`
confirmation), `-DryRun`, `-Verbosity`, `-LogPath`. Confirmation uses
`[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]` with
`$PSCmdlet.ShouldProcess`, so `-Confirm:$false` and `-Force` both skip it and an
unattended run never blocks on a prompt. Steps through `Invoke-Action`: unregister the
task if present, optionally remove the event source, optionally remove files. Does not
touch SCM failure actions. Exit codes: 0 success (including task already absent),
1 unexpected, 2 invalid parameters.

## 6. Azure Function App

### 6.1 Hosting and runtime

- Windows Consumption plan (`Y1`, `Dynamic`), Functions runtime `~4`, PowerShell `7.4`
  via `FUNCTIONS_WORKER_RUNTIME_VERSION` and `siteConfig.powerShellVersion`, both from one
  Bicep parameter so the move to 7.6 is a parameter change. PowerShell 7.4 leaves Functions
  support on 2026-11-10; the README and Hudu article carry a dated check item.
- Rationale over Flex Consumption: Flex is Linux-only and supports 7.4 only, while the 7.6
  preview is Windows-only, so Windows Consumption is the plan with an upgrade path this
  year. Flex is listed as a v2 migration option.
- No managed dependencies (`requirements.psd1` empty, `managedDependency.enabled = false`),
  no Az modules, `profile.ps1` contains no `Connect-AzAccount`.
- `host.json`: version 2.0, extension bundle `[4.*, 5.0.0)`, `functionTimeout 00:02:00`,
  Application Insights sampling `excludedTypes = "Request;Exception"`, default log level
  Information.
- Site: `httpsOnly`, minimum TLS 1.2, FTPS disabled, system-assigned managed identity,
  `WEBSITE_RUN_FROM_PACKAGE = 1`. `functionsRuntimeAdminIsolationEnabled: true` is a
  top-level site property (`properties.functionsRuntimeAdminIsolationEnabled`, not
  `siteConfig`); it is absent from the ARM template schema, so `main.bicep` precedes it
  with `#disable-next-line BCP037` and a comment linking the app-settings reference, and
  the install script verifies it after deployment (7.2 step 6).

### 6.2 App settings

All watchdog settings are prefixed `WATCHDOG_`. Secrets are Key Vault references.

| Setting | Default | Notes |
|---|---|---|
| `WATCHDOG_MAIL_PROVIDER` | `Smtp2GoApi` | or `Smtp` |
| `WATCHDOG_MAIL_FROM` | required | `Service Watchdog <alerts@example.com>`; must be a verified sender in SMTP2GO |
| `WATCHDOG_MAIL_TO` | required | semicolon-separated recipients |
| `WATCHDOG_MAIL_SUBJECT_PREFIX` | `[Service Watchdog]` | |
| `WATCHDOG_MAIL_TIMEOUT_SECONDS` | `20` | provider call timeout per attempt |
| `WATCHDOG_SMTP2GO_API_URL` | `https://api.smtp2go.com/v3/email/send` | regional override |
| `WATCHDOG_SMTP2GO_API_KEY` | KV ref to secret `Smtp2GoApiKey` | |
| `WATCHDOG_SMTP_HOST` | | e.g. `mail.smtp2go.com` |
| `WATCHDOG_SMTP_PORT` | `587` | 587 or 2525; port 25 is blocked on most Azure subscriptions |
| `WATCHDOG_SMTP_USERNAME` | | |
| `WATCHDOG_SMTP_PASSWORD` | KV ref to secret `SmtpPassword` | |
| `WATCHDOG_SMTP_USE_STARTTLS` | `true` | |
| `WATCHDOG_TABLE_ENDPOINT` | required | storage account table endpoint, ends with `/` |
| `WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR` | `6` | `recovered` and `heartbeat` exempt |
| `WATCHDOG_ALLOWED_SITES` | empty | optional semicolon list; empty allows any `SiteName` |
| `WATCHDOG_STALE_HOURS` | `26` | digest threshold |
| `WATCHDOG_DIGEST_SCHEDULE` | `0 0 7 * * *` | NCRONTAB, referenced as `%WATCHDOG_DIGEST_SCHEDULE%` |
| `WATCHDOG_DIGEST_ALWAYS_SEND` | `false` | send a daily all-clear summary even when nothing is stale |

Startup guard: `Get-WatchdogConfig` checks only the settings required by the configured
`WATCHDOG_MAIL_PROVIDER` (`WATCHDOG_SMTP2GO_API_KEY` for `Smtp2GoApi`;
`WATCHDOG_SMTP_HOST`, `WATCHDOG_SMTP_USERNAME`, `WATCHDOG_SMTP_PASSWORD` for `Smtp`).
A value starting with `@Microsoft.KeyVault(` is an unresolved reference; the function
throws a terminating error naming the setting. `SendServiceWatchdogAlert/run.ps1` catches
it and returns 500 `config_unresolved`; `SendServiceWatchdogDigest/run.ps1` lets it
propagate so the invocation fails visibly in Application Insights. Neither path ever
passes the literal reference string to a mail provider. Settings of the unused provider
are never checked.

### 6.3 Module ServiceWatchdogAlert

Loaded from `Modules/` (on `PSModulePath` automatically) and unit-tested directly.

| Function | Responsibility |
|---|---|
| `Get-WatchdogConfig` | Read and validate app settings; startup guard; return a config object |
| `Test-WatchdogPayload` | Validate a payload hashtable against 4.8; return an error list |
| `ConvertTo-WatchdogEmail` | Build subject, text body, HTML body. Every payload field embedded in the HTML body passes through `[System.Net.WebUtility]::HtmlEncode`; the plain-text body uses raw values; the subject strips `\r` and `\n` from every field it embeds |
| `Send-WatchdogMail` | Dispatch by provider; returns `@{ Sent; ProviderMessageId; Error; StatusCode }` |
| `Send-WatchdogMailSmtp2Go` | REST call with `X-Smtp2go-Api-Key`; success when `data.succeeded >= 1`; when `data.failed > 0` alongside success, logs a Warning listing `data.failures` and still returns `Sent = $true`; on 429 or 5xx retries up to 2 more times (2 s, then 5 s, honoring `Retry-After` up to 30 s); no retry on other 4xx |
| `Send-WatchdogMailSmtp` | `System.Net.Mail.SmtpClient` with `EnableSsl` for STARTTLS via a factory `New-WatchdogSmtpClient` that tests replace; documents that implicit TLS on 465 is unsupported |
| `Test-WatchdogRateLimit` | Module-scope sliding window per host key; best effort per worker process |
| `Get-WatchdogStorageToken` | Managed-identity bearer token for `https://storage.azure.com/` from `$env:IDENTITY_ENDPOINT` with `X-IDENTITY-HEADER`, cached in module scope until 5 minutes before `expires_on` |
| `Set-WatchdogHostEntity` | Insert-or-replace the host row via the Table REST API |
| `Test-WatchdogSentEvent` / `Set-WatchdogSentEvent` | Read and write the dedup row for an `EventId` via the Table REST API |
| `ConvertTo-WatchdogHostEntity` | Build the host entity; `LastSeenUtc` is always the function's own `[DateTime]::UtcNow` at receipt, never the payload's `TimestampUtc`, so staleness never depends on the server's clock |
| `Get-WatchdogStaleHosts` | Given rows and `StaleHours`, return stale and fresh sets |
| `Write-WatchdogLog` | Structured log line including `RunId`/`HostName` for App Insights correlation |

Table REST calls: `PUT <WATCHDOG_TABLE_ENDPOINT><Table>(PartitionKey='<pk>',RowKey='<rk>')`
with headers `Authorization: Bearer <token>`, `x-ms-version: 2020-12-06`, `x-ms-date`
(RFC 1123), `Accept: application/json;odata=nometadata`, `DataServiceVersion: 3.0;NetFx`,
`MaxDataServiceVersion: 3.0;NetFx`, `Content-Type: application/json`, `-TimeoutSec 10`.
A PUT without `If-Match` is Insert Or Replace (expect 204). `GET` of the same URI returns
200 or 404. Keys are URL-encoded with single quotes doubled. Every table call is
best-effort: failures are logged as Warning with the status code and never change the
HTTP response or block sending.

Payload limits: body at most 256 KB, at most 100 services, strings at most 256 characters
except `LastError` at most 1000 and `Summary` at most 512, `HostName` matches
`^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}$`, `EventType` in the allowed set, `SchemaVersion` 1,
`TimestampUtc` and `FirstFailedUtc` in the exact 4.4 format, `RunId` and `EventId` GUIDs,
`Status` in `Healthy, Failed, Missing, Disabled, Unknown, Recovered, Remediated`,
`StartType` in the 4.8 set or null. Nullable fields listed in 4.8 pass when null.
Unknown top-level keys are a validation error naming the key.

Sanitize (for table keys and the rate-limit key): replace every character outside
`[A-Za-z0-9._ -]` with `_` and trim to 64 characters. `PartitionKey` is the sanitized
`SiteName`; `RowKey` and the rate-limit key are the sanitized `HostName` upper-cased.

### 6.4 SendServiceWatchdogAlert (HTTP)

- `function.json`: `httpTrigger` (`authLevel function`, `methods ["post"]`,
  `route "servicewatchdog/alert"`) and `http` output `Response` only. No table bindings:
  the Tables output binding only creates entities, so host rows are written in code.
- Flow: config guard (500) → body must be a hashtable (400) → `Test-WatchdogPayload`
  (400) → optional site allowlist (403) → `Set-WatchdogHostEntity` (best effort) →
  if `heartbeat`, return 200 with `emailSent = false` → if not `test`, `Test-WatchdogSentEvent`
  for (`HostName`, `EventId`); when found return 200 with `duplicate = true` →
  rate limit unless `recovered` (429) → `Send-WatchdogMail` → on `Sent`,
  `Set-WatchdogSentEvent` (best effort) and return 200; otherwise 502.
- Exactly one `Push-OutputBinding` to `Response` per invocation, `Content-Type
  application/json` on every response.
- Response bodies: 200 is `{ accepted: true, emailSent: <bool>, duplicate: <bool>,
  providerMessageId: <string or null> }`. Every non-200 is `{ accepted: false, error:
  <code>, errors: [<messages>] }` with `error` one of `config_unresolved` (500),
  `invalid_body` (400), `invalid_payload` (400), `site_not_allowed` (403), `rate_limited`
  (429 with `Retry-After: 600`), `provider_failed` (502), `internal_error` (500, any
  unexpected exception, so every branch still returns JSON and exactly one push).
- Every 400 and 403 logs the caller's client IP from `X-Forwarded-For` or
  `X-Azure-ClientIP`.

Email content: subject `<prefix> <HostName>: <summary>` with `[TEST]`, `Reminder:`, or
`Flapping:` where applicable; body sections: site, host, FQDN, time, event type, a table
of every service (name, display name, status, start type, attempts, first failed, last
error), and a footer naming the watchdog version, run id, and event id. Plain text mirrors
the HTML.

Table entities: `WatchdogHosts` rows carry `PartitionKey`, `RowKey`, `LastSeenUtc`,
`LastEventType`, `WatchdogVersion`, `MonitoredServiceCount`, `ProblemServiceCount`
(services whose status is `Failed`, `Missing`, or `Disabled`; a `test` event stores 0/0).
`WatchdogSentEvents` rows carry `PartitionKey` (sanitized host key), `RowKey` (`EventId`),
`SentUtc`, `EventType`, `ProviderMessageId`.

### 6.5 SendServiceWatchdogDigest (timer)

- `function.json`: `timerTrigger` schedule `%WATCHDOG_DIGEST_SCHEDULE%`,
  `runOnStartup false`; `table` input `Hosts` (`tableName WatchdogHosts`, connection
  `AzureWebJobsStorage`, no `partitionKey`, `rowKey`, `filter`, or `take`, so every row is
  returned; input bindings read with the connection string and need no role).
- Flow: read all rows → if zero rows, email a distinct "no hosts have ever reported"
  notice regardless of `WATCHDOG_DIGEST_ALWAYS_SEND` → else `Get-WatchdogStaleHosts` →
  if any stale, email a digest listing stale hosts with last-seen and age, plus a count of
  fresh hosts → else, if `WATCHDOG_DIGEST_ALWAYS_SEND`, email an all-clear summary → log
  counts either way. A mail failure is logged as Error and does not throw.
- The digest is exempt from the per-host rate limit and the dedup check.

## 7. Azure deployment

### 7.1 main.bicep

Parameters: `baseName`, `location` (default resource group location), `powerShellVersion`
(`7.4`, allowed `7.4` or `7.6`), `mailProvider`, `mailTimeoutSeconds` (20), `smtp2GoApiUrl`, `mailFrom`, `mailTo`, `mailSubjectPrefix`, `smtpHost`,
`smtpPort`, `smtpUsername`, `smtpUseStartTls`, `maxAlertsPerHostPerHour`, `staleHours`,
`digestSchedule`, `digestAlwaysSend`, `allowedSites`, `deployerObjectId` (gets Key Vault
Secrets Officer so the install script can seed secrets), `deployerPrincipalType`
(allowed `User`, `ServicePrincipal`, `Group`; default `User`), `tags`.

Resources, with verified API versions from the research:

- Log Analytics workspace (`PerGB2018`, 30-day retention) and workspace-based Application
  Insights (connection string in app settings, no AAD-only ingestion).
- Storage account: `StorageV2`, `Standard_LRS`, TLS 1.2 minimum, HTTPS only, no public
  blob access; table service with tables `WatchdogHosts` and `WatchdogSentEvents`.
- App Service plan `Y1`/`Dynamic`, Windows.
- Function App `kind: 'functionapp'`, `identity: { type: 'SystemAssigned' }`, site
  settings from 6.1, and all app settings inline in `siteConfig.appSettings` (Microsoft's
  guidance for Consumption, so the app never starts without its storage settings):
  `AzureWebJobsStorage` and `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` as
  `DefaultEndpointsProtocol=https;AccountName=...;AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}`,
  `WEBSITE_CONTENTSHARE: toLower(functionAppName)` (must never change after first
  deployment), `FUNCTIONS_EXTENSION_VERSION ~4`, `FUNCTIONS_WORKER_RUNTIME powershell`,
  `FUNCTIONS_WORKER_RUNTIME_VERSION`, `WEBSITE_RUN_FROM_PACKAGE 1`,
  `APPLICATIONINSIGHTS_CONNECTION_STRING`, `WATCHDOG_TABLE_ENDPOINT` from
  `storage.properties.primaryEndpoints.table`, and every other `WATCHDOG_*` setting, with
  the two secrets declared inline as
  `'@Microsoft.KeyVault(SecretUri=${keyVault.properties.vaultUri}secrets/Smtp2GoApiKey)'`
  and `...secrets/SmtpPassword)`. They resolve as literal strings until the install script
  seeds the secrets and restarts the app; the 6.2 guard covers that window. On redeploy the
  template replaces the whole settings collection, so every setting the app needs is in
  the template. The template does not create `basicPublishingCredentialsPolicies`
  resources; SCM basic auth stays at the platform default so zip deploy works.
- Key Vault: name `kv-${baseName}-${take(uniqueString(resourceGroup().id), 6)}` (3 to 24
  characters), standard SKU, `enableRbacAuthorization: true`, `enableSoftDelete: true`,
  `enablePurgeProtection: true`, `publicNetworkAccess: 'Enabled'`, `networkAcls: {
  defaultAction: 'Allow', bypass: 'AzureServices' }` (Consumption apps and the operator
  workstation reach the vault over public endpoints). Secrets are not created by Bicep;
  the install script seeds them.
- Globally unique names carry a six-character `uniqueString(resourceGroup().id)` suffix:
  function app `func-<baseName>-<suffix>`, vault `kv-<baseName>-<suffix>`, storage account
  `st<baseName><suffix>` (lowercase, no hyphens). Plan, workspace, and App Insights are
  unsuffixed.
- Role assignments with deterministic names `guid(<scope>.id, functionApp.id, <roleId>)`
  for the function identity (a principal id cannot appear in a resource name, Bicep BCP120)
  and `guid(keyVault.id, deployerObjectId, <roleId>)` for the deployer:
  Key Vault Secrets User (`4633458b-17de-408a-b874-0445c86b69e6`) to
  `functionApp.identity.principalId`, `principalType: 'ServicePrincipal'`, vault scope;
  Key Vault Secrets Officer (`b86a8fe4-44ce-4948-aee5-eccb2c155cd7`) to `deployerObjectId`
  with `principalType: deployerPrincipalType`, vault scope; Storage Table Data Contributor
  (`0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3`) to the function identity, storage account scope.
- Outputs: `functionAppName`, `functionAppHostName`, `alertUrl`, `keyVaultName`,
  `storageAccountName`, `applicationInsightsName`.

Validated locally with `bicep build` and `bicep lint`, clean apart from the suppressed
BCP037.

### 7.2 Install-AzureServiceWatchdogFunction.ps1

`#Requires -Version 7.4`, `#Requires -Modules Az.Accounts, Az.Resources, Az.Websites,
Az.KeyVault` (Az 9.7.1 or later so `Publish-AzWebApp` can fall back to Entra
authentication), Enterprise tier. Runs from an operator workstation.

Parameters: `-ResourceGroupName`, `-BaseName`, `-MailFrom`, `-MailTo` (mandatory);
`-SubscriptionId` (optional; the current context subscription when omitted), `-Location`
(optional; required only when the resource group must be created), `-MailProvider`,
`-MailSubjectPrefix`, `-Smtp2GoApiKey` (SecureString), `-SmtpHost`, `-SmtpPort`,
`-SmtpCredential` (PSCredential), `-SmtpUseStartTls` (`[bool]`, default true),
`-PowerShellVersion`, `-FunctionKeyName` (default `watchdog`; an existing key of that name
is reused on re-run), `-SourcePath` (AzureFunction folder, default relative to the
script), `-SendTestEmail`, `-DryRun`, `-Verbosity`, `-LogPath`. Under `-DryRun` with a
missing resource group the script warns and exits 0 without a what-if, because ARM cannot
what-if into a group that does not exist.

Steps:

1. Prerequisites: required modules present, Bicep CLI on `PATH` (checked with
   `bicep --version`; Azure PowerShell does not install it), signed-in context on the
   requested subscription. Determine the deployer: for a user account
   `(Get-AzADUser -SignedIn).Id` with type `User`; for a service principal
   `(Get-AzADServicePrincipal -ApplicationId (Get-AzContext).Account.Id).Id` with type
   `ServicePrincipal`. Fail with exit 2 (prerequisites) or 20 (not signed in) and a
   specific message.
2. Create the resource group if missing.
3. Deploy `main.bicep` with `New-AzResourceGroupDeployment -TemplateFile` and a parameter
   hashtable. Under `-DryRun` run it with `-WhatIf` and stop after printing the change
   summary.
4. Seed Key Vault secrets `Smtp2GoApiKey` and/or `SmtpPassword` (whichever the provider
   needs) with `Set-AzKeyVaultSecret`, retrying on 403 for up to 5 minutes while the
   Secrets Officer assignment propagates.
5. Package the contents of `AzureFunction/` so `host.json` is at the archive root
   (`Compress-Archive -Path "<SourcePath>\*"`), excluding `local.settings*.json`, and
   deploy with `Publish-AzWebApp -ResourceGroupName -Name -ArchivePath -Force`. A 401 from
   the SCM endpoint means SCM basic auth is disabled by policy; the README documents the
   `basicPublishingCredentialsPolicies` fix.
6. `Restart-AzWebApp` (Az.Websites; works for function apps) so Key Vault references
   resolve against the seeded secrets. Verify admin isolation: `Invoke-AzRestMethod -Method
   GET -Path "<siteResourceId>?api-version=2024-04-01"`; if
   `properties.functionsRuntimeAdminIsolationEnabled` is not true, PATCH
   `{"properties":{"functionsRuntimeAdminIsolationEnabled":true}}` and re-check. Then poll
   `Invoke-AzRestMethod -Method GET -Path "<siteResourceId>/functions?api-version=2024-04-01"`
   every 15 seconds for up to 5 minutes until `SendServiceWatchdogAlert` is listed.
7. Create the named function key: `Invoke-AzRestMethod -Method PUT -Path
   "<siteResourceId>/functions/SendServiceWatchdogAlert/keys/<FunctionKeyName>?api-version=2024-04-01"
   -Payload (@{ name = <FunctionKeyName> } | ConvertTo-Json)` (no `value`; the service
   generates the key), retrying on 404 or 5xx every 15 seconds for up to 5 minutes. Read it
   back with `Invoke-AzRestMethod -Method POST -Path
   ".../functions/SendServiceWatchdogAlert/listkeys?api-version=2024-04-01"`; the key is
   the property named `<FunctionKeyName>` under `properties`.
8. Print once, to the console only: alert URL, function key, Key Vault name, and the two
   lines to paste into `ServiceWatchdog.json`. Never write the key to the log file.
9. Optional `-SendTestEmail`: POST a `test` payload to the alert URL with the key in the
   `x-functions-key` header and report the result.

Exit codes: 0, 1 unexpected, 2 prerequisites or parameters, 20 not signed in or not
authorized, 50 deployed but a post-deployment step failed (message says which).

Key rotation, both directions, is documented in the README and Hudu article:
function key = create new key, update every server's config, delete old key;
SMTP2GO key = create new key, `Set-AzKeyVaultSecret`, restart the app or call the
config-references refresh endpoint, verify with `-TestAlert`, revoke old key. The README
troubleshooting section also covers re-deploying after deleting a resource group within
90 days (`Undo-AzKeyVaultRemoval` or a different `baseName`, because purge protection
prevents purging the vault).

## 8. Security controls (v1)

- Endpoint: secrets only in the ACLed config file, never in task arguments; key sent in a
  header, not the query string; TLS 1.2 enforced; state and config parsed defensively.
- Function: dedicated named function key per deployment, function-level auth, HTTPS only,
  admin endpoints isolated, strict payload validation with unknown-key rejection and size
  limits, HTML encoding of every field in the HTML part, plain-text part always present,
  subject lines stripped of line breaks, recipients and sender fixed server-side,
  `EventId` deduplication, per-host rate limit (best effort, held in module-scope memory
  per instance; on Consumption it is a backstop, not a hard global cap; the primary
  defenses are the endpoint state machine and fixed recipients), SMTP2GO key scoped to
  `/email/send` with a provider-side rate limit (documented setup step), secrets in Key
  Vault with RBAC and purge protection, least-privilege identity (Secrets User and Table
  Data Contributor only), Application Insights without sampling of requests and exceptions,
  client IP logged on rejected calls.
- Repository: `.gitignore` for real config, local settings, and the real Bicep parameter
  file; example values use `example.com`, `SRV-EXAMPLE-01`, `REPLACE_WITH_FUNCTION_KEY`;
  nothing brand- or client-specific in code, comments, examples, or `.NOTES`.

## 9. Testing

- Pester tests for every script and the module, run locally on PowerShell 7.6 with Pester
  6 (written in Pester 5.5-compatible syntax). Windows-only cmdlets (`Get-Service`,
  `Get-CimInstance`, `Register-ScheduledTask`, `New-ScheduledTaskTrigger`, `New-EventLog`,
  `Write-EventLog`, `icacls`, `sc.exe`) and all network calls are mocked; `.Start()` and
  `WaitForStatus` are reached through `Start-WatchdogService` so tests mock the helper.
  Coverage target 80% for the worker, the module, and the installer.
- Required test groups per the authoring skill: parameter validation, `-DryRun` makes zero
  mutations (asserts `Start-WatchdogService`, `Invoke-WebRequest`, state write, and event
  log write are never called), success paths, every error path, state transitions from
  4.6 including pending-delivery retry with `EventId` reuse, previous-status preservation
  on failed delivery, dropped-service handling, state-file reset, time-budget exhaustion
  including StartPending waits, Disabled and Missing handling, flapping detection,
  suppression and release, heartbeat scheduling, payload validation edge cases including
  unknown keys and nulls, HTML encoding of hostile strings and subject line-break
  stripping, SMTP2GO 200-with-partial-failures and 429 retry, provider timeouts, dedup hit
  and miss, a simulated 403 from the table write still returning 200, a second heartbeat
  from the same host returning 200, rate limit exemptions, stale-host computation and the
  zero-row digest notice.
- `run.ps1` files are tested by dot-sourcing with mocked `Push-OutputBinding` and a fake
  `$Request`.
- `Tests/ServiceWatchdogContract.Tests.ps1` drives the worker's real payload path for
  every event type and passes the result through the module's `Test-WatchdogPayload`, and
  asserts the endpoint truncation limits agree with the module limits.
- Windows PowerShell 5.1 compatibility: `Tests/Test-WindowsPowerShellCompat.ps1` parses
  the endpoint scripts with the PowerShell AST and fails on any 7-only construct listed in
  4.1. Real execution on a Windows Server is the operator's acceptance test, documented in
  the README.
- `bicep build` and `bicep lint` on the template; PSScriptAnalyzer on all scripts.
- Contract check: the worker's payload builder output for every event type passes
  `Test-WatchdogPayload` with zero errors.

## 10. Documentation deliverables

- `README.md`: what it does, architecture summary, requirements, quick start (Azure first,
  then servers), config reference, event IDs and exit codes, testing an installation,
  rotation procedures, troubleshooting (including SCM basic auth, Key Vault name reuse,
  proxy as SYSTEM), runtime-version check item, v2 ideas. Follows the PerUserMfaAudit
  README structure.
- Root `README.md`: convert the Monitoring table to the three-column form used by the
  other sections (`| Folder | Scripts | Description |`, existing rows get an empty Folder
  cell), then add a `ServiceWatchdog/` row for `Endpoint/Invoke-WinServiceWatchdog.ps1`
  with continuation rows for `Endpoint/Register-WinServiceWatchdogTask.ps1`,
  `Endpoint/Unregister-WinServiceWatchdogTask.ps1`, and
  `Deploy/Install-AzureServiceWatchdogFunction.ps1`, in the same commit that adds them.
- `Docs/Hudu-ServiceWatchdog.html`: global knowledge-base article using the existing
  callout and table classes from the Hudu stylesheet. Same sections as the README plus
  placeholders for the real function URL, key location, recipient list, and change log.
  Publishing happens only after the user reviews the draft.

## 11. Versioning

All scripts, the module manifest, the payload `WatchdogVersion`, the Bicep template
metadata, and the README start at 1.0.0. The payload `SchemaVersion` changes only when a
field's meaning changes; adding optional fields does not bump it.
