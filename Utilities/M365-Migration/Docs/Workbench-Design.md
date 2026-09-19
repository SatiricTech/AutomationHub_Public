# M365 Migration Workbench — design

Status: approved 2026-09-18. This document is binding for the implementation on branch
`feature/m365-migration-workbench`; change the document before changing the behaviour it
describes.

## 1. What this is

A front door on the existing 17-script toolkit. The operator points it at a migration folder;
it reads what is already there, keeps the migration's settings in one JSON file beside the
outputs, presents the scripts both as guided phases with detected state and as a flat toolbox,
builds the exact command line for a step, runs it with a live log, and records what ran.

Three ways in, one engine:

| Mode | How | Where |
|---|---|---|
| Console workbench | `Start-MigrationWorkbench.ps1 [-Workspace <dir>]` | macOS, Linux, Windows (default off Windows, `-Console` forces it on Windows) |
| WinForms workbench | same script, no `-Console`, on Windows | Windows with pwsh 7.4+ (`Start-MigrationWorkbench.cmd` double-click launcher) |
| Non-interactive | `Start-MigrationWorkbench.ps1 -Workspace <dir> -Step <id> [-Wave ...] [-DryRun] [-Set @{...}]` | anywhere; exits with the step's exit code |

Every one of the 17 scripts keeps every option it has today. The workbench never bypasses a
script; it only builds the command an operator could have typed.

### Non-goals

- No web UI, no third-party TUI module, no compiled host. Nothing that works around a
  Microsoft product limit.
- No plan editor. The identity plan is edited in Excel/CSV as today; the workbench shows it,
  pins it and reconciles it.
- No batching of several steps into one child process (v2 candidate — see backlog).
- No secrets in the settings file, ever.

## 2. Decisions and why

| Decision | Why |
|---|---|
| Engine functions live in `M365Migration/Public` (one per file), not a second module | The toolkit *is* the build; one manifest, one test that pins exports. The scripts never call the workbench functions; the dependency direction is workbench → toolkit only. |
| WinForms on Windows + console everywhere, both thin over the engine | WinForms/WPF do not exist off Windows; a browser cannot return a folder path and a local HTTP listener is custom infrastructure. The console mode is the product; the window is a skin. Both render from the same catalog objects, and a test asserts they list the same steps. |
| One child `pwsh` process per step | Scripts call `exit` at top level, `Import-Module -Force`, and hold process-global Graph/EXO/Teams sessions. In-session execution is how a cached SOURCE session reaches a DESTINATION writer. Graph re-auth is silent after the first sign-in (on-disk cache); EXO and Teams cost one browser/WAM click per step. |
| A generated driver `.ps1` per run, executed with `-File` | `pwsh -File` flattens arrays and hashtables (`-AliasDomainMap @{...}`) to strings; a splat in a driver file does not. The driver is also a reproducible artefact of exactly what ran. |
| Parameters are read from the scripts (`Get-Command`) plus a hand-written overlay | Hand-copying 17 param blocks rots silently. The overlay holds only what the AST cannot know (phase, side, bindings, resolvers, artefacts, exit-code meaning) and a test refuses any overlay key that is not a real parameter. |
| Tenant IDs are GUIDs in settings | The Exchange tenant assertion only works on GUIDs. A domain typed in the settings form is resolved to its GUID through the public OIDC discovery document, no sign-in needed. |
| The workspace is the selected folder and it is `-OutputPath` | Files land exactly where the README says today; anyone can drop to the CLI mid-migration. |
| Newest file is chosen by the timestamp in its name, never by mtime | Sync tools (OneDrive, Egnyte) rewrite mtimes. |

## 3. Workspace model

```
<workspace>/                                   -OutputPath for every step
  M365Migration.settings.json                  created by the workbench; client data; git-ignored
  Workbench/
    Runs.jsonl                                 one line per run (see 7.4)
    Runs/<yyyyMMdd-HHmmss>_<StepId>/           driver.ps1, stdout.txt, stderr.txt
  Source/        Source_<Tab>_<ts>.csv ...     -Prefix Source       (inventory)
  Destination/   Destination_<Tab>_<ts>.csv    -Prefix Destination  (inventory)
  Post/          Post_<Tab>_<ts>.csv           -Prefix Post         (post-migration inventory)
  <Label>/       <Label>_IdentityPlan_<ts>.csv, <Label>_<Id>-Results_<ts>.csv, logs, reports
```

One migration per workspace. The workbench's "new workspace" flow creates
`<default root>/<Label>/` (default root: `%LOCALAPPDATA%\Migration-Automations` on Windows,
`~/Migration-Automations` elsewhere — `Get-MigrationDefaultOutputRoot`, now exported). An
existing root that already holds `Source/`, `Destination/` and a label folder is a valid
workspace as-is.

Input files the operator supplies (SKU map, exclusion rules, wave map) may live anywhere; a
path inside the workspace is stored relative to it, any other path is stored absolute.

## 4. Settings file

`M365Migration.settings.json`, UTF-8 without BOM, key order preserved on round-trip. The
committed template is `Templates/M365Migration.settings.example.json`; the real filename is in
`.gitignore`. Only the example ever enters the repository.

```json
{
  "SchemaVersion": 1,
  "Label": "Contoso",
  "Scenario": "TenantToTenant",
  "Source":      { "TenantId": "<guid>", "DisplayName": "", "OnMicrosoftDomain": "contoso.onmicrosoft.com", "DelegatedOrganization": "" },
  "Destination": { "TenantId": "<guid>", "DisplayName": "", "OnMicrosoftDomain": "newco.onmicrosoft.com",   "DelegatedOrganization": "" },
  "Domains":     { "Target": "contoso.com", "Smtp": "", "Interim": "" },
  "Plan":        { "UpnFormat": "First.Last", "SmtpFormat": "", "MailNicknameFormat": "", "DefaultWave": "1",
                   "DefaultUsageLocation": "US", "SkuMapPath": "", "ExclusionRulesPath": "", "WaveMapPath": "",
                   "PreserveAliases": false, "AliasDomainMap": {}, "IncludeDisabled": false, "IncludeGuests": false,
                   "IncludeSynced": false },
  "Defaults":    { "Verbosity": "Medium", "IncludeCollisions": false, "UseInterim": false, "Tool": "AvePoint",
                   "PasswordLength": 16, "WordCount": 3 },
  "Pinned":      { "PlanPath": "" },
  "VivaLearning": { "ClientId": "", "CertificateThumbprint": "", "LearningProviderId": "" }
}
```

Rules:

- `Scenario` ∈ `TenantToTenant` | `InPlaceRedesign`. In-place: Source and Destination hold the
  same GUID; the phase view hides mapping export, domain release and Fly; identity cutover runs
  with `-MatchOn Source`.
- `Domains.Target` feeds `-TargetDomain` (planner) and `-Domain` (domain release).
  `Domains.Smtp` blank = same as Target; otherwise it feeds the planner's new `-SmtpDomain`.
  `Domains.Interim` blank = not needed; the settings form reads `Destination_Domains_*.csv`
  and says whether Target is already verified in the destination (KnownDocGaps #6).
- `Pinned.PlanPath` blank = newest `<Label>_IdentityPlan_*.csv`. Pinning is what makes a
  re-plan safe: `-ExistingPlanPath` defaults to the pinned plan.
- No key may match the module's secret-name pattern
  (`password|passphrase|secret|credential|token|apikey|api-key|certificate|thumbprint|key$`)
  except the documented `CertificateThumbprint`, which is a locator, not a secret. A test
  enforces this on the example file and on every write.
- The Viva client secret is prompted at run time as a SecureString and passed to the child
  through an environment variable scoped to that process; it never touches the driver or disk.
- Loading never throws. `Resolve-MigrationSettings -Path` returns
  `{ IsValid; Errors; Settings }`; a missing file is a valid "no settings yet" state; unknown
  keys are an error naming the valid keys; wrong `SchemaVersion` is an error.
- `Save-MigrationSettings` writes atomically (temp file + move) and keeps a single
  `.bak` of the previous version.

## 5. Step catalog

`Get-MigrationStep` returns one object per *step instance*. A script can back several
instances (inventory × Source/Destination/Post; readiness × Pre/Provisioned/Post; domain
release × report/remediate). The "All tools" view lists the 17 scripts with every parameter
free; the phase view lists the instances with their fixed values applied.

### 5.1 What comes from the script

`Get-Command <script path>` supplies, per parameter: name, .NET type, mandatory flag,
parameter set membership, `ValidateSet` values, `ValidateRange` bounds, `ValidatePattern`,
aliases, and the default value from the AST (`ParamBlockAst` default expressions). `Get-Help`
supplies the parameter description shown as help text. Cached per session.

### 5.2 What comes from the overlay — `M365Migration/StepCatalog.psd1`

Keyed by script basename. Every key below is optional except `Phase`, `Side`, `Title`.

```powershell
'New-MigrationUsers' = @{
    Title     = 'Provision users'
    Phase     = 'Prepare'                 # Discover | Plan | Prepare | Cutover
    Order     = 6                         # runbook step number, drives the phase view order
    Side      = 'Destination'             # Source | Destination | Offline
    Scenario  = @('TenantToTenant', 'InPlaceRedesign')
    Connects  = @('Graph')                # Graph | Exchange | Teams
    Impact    = 'Write'                   # Read | Write | Destructive
    ResultId  = 'New-Users'               # the -Name token in <Label>_<ResultId>-Results_<ts>.csv
    Bind      = @{                        # settings key -> parameter name
        'Destination.TenantId'       = 'TenantId'
        'Label'                      = 'Prefix'
        'Plan.DefaultUsageLocation'  = 'DefaultUsageLocation'
        'Defaults.IncludeCollisions' = 'IncludeCollisions'
        'Defaults.UseInterim'        = 'UseInterim'
        'Defaults.PasswordLength'    = 'PasswordLength'
        'Defaults.Verbosity'         = 'Verbosity'
    }
    Resolve   = @{ PlanPath = 'Plan' }    # parameter -> resolver name (see 5.3)
    Requires  = @('Plan', 'Readiness-Pre')
    Produces  = @('Results')              # artefact kinds the scanner looks for: Results | Report:<name> | Inventory | Plan | Mapping | Log
    ExitCodes = @{ 0 = 'Completed'; 1 = 'Failed'; 2 = 'Some rows failed' }
    Confirm   = $true                     # pass -Confirm:$false (ConfirmImpact High)
    Instances = @()                       # see readiness/inventory entries for the shape
    Notes     = 'Generated passwords are written only to the results file.'
}
'Test-MigrationReadiness' = @{
    ...
    Instances = @(
        @{ Id = 'Readiness-Pre';         Title = 'Readiness — pre-provisioning'; Order = 5;  Fixed = @{ Stage = 'Pre' } }
        @{ Id = 'Readiness-Provisioned'; Title = 'Readiness — provisioned';      Order = 9;  Fixed = @{ Stage = 'Provisioned' }; Resolve = @{ SourceMailboxesCsv = 'Inventory:Source:UserMailboxes' } }
        @{ Id = 'Readiness-Post';        Title = 'Readiness — post-cutover';     Order = 17; Fixed = @{ Stage = 'Post' } }
    )
}
```

Two details the example does not show. A script that names its results by mode carries
`ResultIds` as well as `ResultId` — `Compare-MigrationUserData` writes `Compare-UserData` in
CSV mode and `Compare-UserData-Plan` in plan mode — and the drift guard compares that list
with the `-Name` literals the script really passes to `Export-MigrationResult`. An instance
may override any key of its script's entry, `Bind` included; `Bind` merges on the target
parameter rather than the settings key, so the inventory's destination-side instances replace
the entry's `Source.TenantId` → `-TenantId` binding instead of leaving both standing.
`Requires` names either a step instance (which must be `Done`) or an artefact kind from the
`Produces` vocabulary (which must exist), so a plan supplied by hand satisfies `'Plan'`
without the planner having run in this workspace.

The drift-guard test (`Tests/StepCatalog.Tests.ps1`) asserts, for every script: an overlay
entry exists; every `Bind` target, `Resolve` key and `Fixed` key names a real parameter;
every `Bind` source is a key in the settings schema; every `ValidateSet` value used in
`Fixed` is valid; every parameter set of the script is representable (its mandatory set can
be satisfied from Bind ∪ Resolve ∪ Fixed ∪ operator input); and no parameter is silently
unaccounted for — each is bound, resolved, fixed, operator-entered, or listed in `Ignore`.

### 5.3 Resolvers

Named, pure functions over the workspace scan: `Plan` (pinned or newest plan),
`Inventory:<Prefix>:<Tab>` (newest `<Prefix>_<Tab>_*.csv`), `Export:<Id>` (another step's
export, e.g. the Teams `Get-` export for `Remove-`), `Settings:<key>` (a path
stored in settings), `ExistingPlan` (pinned plan, for the planner re-run). A resolver returns
`{ Value; Source; Candidates }` so the UI can show where a value came from and offer the
alternatives; `Value` is always `Candidates[0]`, and every path is absolute — a settings path
stored relative is resolved against the workspace.

`Export:<Id>` takes either a step id or one of a step's result tokens, and prefers that
step's report over its results file where it publishes both: `Get-MigrationTeamsPhoneAssignments`
writes `Source_Get-TeamsPhoneAssignments-Results_<ts>.csv` (what the export did) and
`Source_TeamsPhoneAssignments_<ts>.csv` (`Report:TeamsPhoneAssignments` — the number, its type
and the routing policy). Only the second round-trips into `-CsvPath`, so it is the value and the
results file stays on the candidate list. The report's name is the token without its leading
verb, and the preference only applies where the producing step's `Produces` declares it.
`Settings:<key>` answers with nothing for a blank string or an empty map, so "not configured"
never reaches a command line, and with a boolean's own value, `$false` included.

### 5.4 Non-catalog knowledge that lives here, not in the scripts

- `[bool]` parameters (`-ForceChangePassword`, `-AutoMapping`) render as checkboxes and are
  emitted as `-Name $false` / `-Name $true`.
- `Remove-MigrationDomainReferences` without `-AcknowledgeSourceTenant` is a report-only
  run; the remediate instance fixes the switch on and is `Impact = 'Destructive'`.
- `-Debug` and `-Verbose` are never passed (Graph request bodies would reach the console).

## 6. Folder scanner and detected state

`Get-MigrationWorkspace -Path` returns:

```
Path           the workspace folder, resolved
SettingsPath   <workspace>/M365Migration.settings.json
SettingsResult the whole Resolve-MigrationSettings result { Path; Exists; IsValid; Errors; Settings }
Settings       the settings document, or $null when it is missing or invalid
Label          from settings, else inferred (below), else ''
Scenario       from settings, else 'TenantToTenant' - it selects which step instances are scanned
Folders        [ordered] Source, Destination, Post, Label -> full path or $null
Artefacts      every parsed file: { Path; Folder; Prefix; Name; Suffix; Timestamp; Extension }
Plan           { Path; Pinned; Timestamp; RowCount; Waves = [ordered] @{ '1' = 90; '2' = 52 };
                 Statuses = [ordered] @{ Planned = 134; Collision = 3; ... }; DivergentRows } or $null
Steps          one entry per step instance:
               { Id; State; LastRun; LastDryRun; Files; Summary = @{ Succeeded; Failed; Skipped; Planned };
                 ExitCode; TenantVerified }
Ledger         the run-ledger entries (7.4), in the order they were appended
NextStepId     the step to do next, or $null
Warnings       header-only CSVs, an unreadable plan, a plan newer than the pinned one, a damaged
               ledger line, an ambiguous label, an unsatisfiable Requires, ...
```

`Plan.Timestamp`, like every other "when", is the moment in the filename.

Filenames are parsed by `ConvertFrom-MigrationOutputPath` (new, the single owner of the
`<Prefix>_<Name>[-<Suffix>]_<yyyyMMdd-HHmmss>.<ext>` contract; `Get-MigrationOutputPath`
is its inverse and every writer in the module uses it). `.bak` files are ignored, and so is
any other name the contract does not describe — notes and exports live beside the artefacts
and are not the scanner's business, so they are skipped without a warning.

Which step a file belongs to: a `Results`/`DryRun` file whose name is one of the instance's
result tokens, in the folder that instance writes to (its fixed `-Prefix`, else the label);
an inventory by `Prefix` equal to the instance's fixed `-Prefix` and the name `Users`; the
plan by the name `IdentityPlan` in the label folder; a report by a name the instance's
`Produces` lists as `Report:<name>`, taken whole (`DomainBlockers-Recheck` is one name).
A script that names its results by mode carries both tokens as `ResultIds`, and the scanner
matches on all of them: a CSV-mode comparison run from the command line still belongs to the
comparison step that only ever writes the plan-mode token itself.

Where two instances of one script could claim the same file (the three readiness stages, the
domain-release report and remediation) the catalogue's attribution rule decides: the file
belongs to the instance whose ledger entry recorded it, matched on the entry's `Files` list
or on its `Started`..`Ended` window, and otherwise to the lowest-ordered instance. `Files`
entries are matched on the leaf name, so a ledger written with relative or absolute paths
reads the same, and a file *no* naming rule claims but a ledger entry names — a log, a report
a future script adds — belongs to that entry's step. `Started` is floored to the whole second
before the window comparison, because filename stamps carry nothing finer.

Without a settings file the label is inferred: exactly one prefix folder that is not
`Source`/`Destination`/`Post` and holds at least one parseable artefact is the label folder;
zero or several leaves `Label` empty and warns, because a guessed label would attribute files
to the wrong step.

State per step instance:

| State | Rule |
|---|---|
| `NotRun` | no artefact and no ledger entry |
| `DryRun` | newest artefact is a `-DryRun_` results file |
| `Done` | newest live results has no `Failed` rows and exit code 0 (or an inventory/plan/mapping artefact exists) |
| `PartlyFailed` | newest live results has `Failed` rows (exit 2) |
| `WorkRemains` | ledger exit code 3 (domain references remain) |
| `Failed` | ledger exit code 1 |
| `Stale` | done, but the plan it consumed is older than the pinned plan |

Where two rules could both apply, they are settled in this order: `Failed`, `WorkRemains`,
`DryRun`, `PartlyFailed`, `Done` — a ledger that says the run failed outranks the file it
managed to write before it did, and a rehearsal newer than the last live run outranks it.

What counts as "live" is narrow, and deliberately so: a `-Results_` file, or the inventory or
plan a non-results step writes. A log or a report never makes a step `Done` — a domain-release
report says what the step found, not that it finished, and a log written in the same second as
a rehearsal would otherwise read as a live run. A step with only logs or reports on disk and
no ledger entry stays `NotRun`.

Whether a run was a rehearsal is the ledger's to say: when the newest entry for the step
records `DryRun`, that wins over what the filenames imply; a line that did not record it
leaves the question to the files.

A recorded run that left nothing behind and carries an exit code the catalogue does not
define — an abort, a child that died — is `Failed`. It is certainly not `Done`.

`Stale` is judged afterwards, only for a step that reads the plan (`Requires` names `Plan`,
or `Resolve` maps a parameter to the `Plan` resolver), against the plan's own filename
timestamp, and dated by the step's newest artefact — or, when the run left no file behind, by
its ledger entry's `Started`.

"Next step" is the lowest-ordered instance whose `Requires` are all `Done` and whose own
state is not `Done`. A `Requires` entry that names an artefact kind rather than a step
instance (see 5.2) is satisfied when that artefact exists in the workspace, whether or not
the step that would have produced it has run here. A `Requires` entry that is neither — not a
step in the scanned scenario, not a kind in the `Produces` vocabulary — can never be met, so
it blocks its step and is reported in `Warnings` naming both.

Reading a results CSV for the summary reads only the `Status` column; the `GeneratedPassword`
column is never read, rendered or persisted by the workbench.

## 7. Running a step

### 7.1 Resolve

`Resolve-MigrationStepArguments -Step -Workspace [-Override <hashtable>] [-DryRun]
[-Wave <string[]>]` returns `{ Arguments; ParameterSet; MissingMandatory; Warnings }`, where
`Arguments` is an ordered list — the script's own declaration order — of
`{ Name; Value; Source; Warning; Candidates }`.

`Source` is the rung of the precedence ladder that decided the value, highest first:
`Fixed` (the instance is only that step because of it), `Operator` (`-Override`; a key that is
not a parameter of the script is dropped and reported in `Warnings`), `Settings` (the `Bind`
map — a blank setting is not a value and is left out, a boolean always is one),
`Resolved` (the `Resolve` map, keeping the resolver's `Candidates`), and `Default` — the
script's own default, **recorded so a form can show it and deliberately not passed**, because
a default is the script's business and re-stating it would freeze today's value into a driver
file that outlives the script. A driver emits every argument whose `Source` is not `Default`.

Common parameters are always set explicitly, under the source `Common`: `-OutputPath
<workspace>`, `-Prefix <instance prefix or Label>` (offline steps take the label too),
`-Verbosity <settings>`, `-DryRun` when requested, `-Wave` when one is requested and the
script takes it, and `-Confirm:$false` when the script's `ConfirmImpact` is High (the
catalogue's `Confirm` flag), because an unattended child cannot answer a prompt. `-LogPath` is
never passed: every script derives it from `-OutputPath`. `-TenantId` is passed to any script
that takes it, from the side's settings block where the catalogue does not bind it;
`-DelegatedOrganization` only when the settings hold one for that side.

`ParameterSet` is the first set the script declares whose mandatory parameters are all
present, and `MissingMandatory` lists what that set still needs; where no set is satisfiable,
the closest one is chosen and its gap listed. A value the operator or the instance supplied
narrows the sets under consideration to the ones that hold it first — which is what makes
`-TestUser` select the `TestUser` set even though the plan would also have resolved — and
arguments outside the chosen set are then dropped, because a command line that mixes two sets
cannot bind at all.

### 7.2 Gates — `Test-MigrationStepGate`

Returned as data; both front ends render them the same way.

| Gate | Applies to | Behaviour |
|---|---|---|
| `DryRunFirst` | `Impact = Write` and `Destructive` | Soft: a live run is offered only after a `-DryRun_` results file newer than the pinned plan exists for that step and wave. Override allowed, recorded in the ledger. |
| `TypedConfirmation` | `Impact = Destructive`, and any `Side = Source` writer | Hard: the operator must type the source vanity domain (domain release, Teams number removal) or the word the gate names. A keypress/button is not accepted. |
| `Prerequisite` | steps with `Requires` | Soft: lists what is not `Done`. |
| `TenantMismatch` | any connecting step | Hard, post-run: the "Connected to ... tenant <guid>" lines in the child's log are compared with the expected side's GUID; a mismatch is flagged regardless of exit code. |
| `WaveRequired` | plan consumers | Soft: a blank wave means the whole plan; confirmed explicitly for writers. |

### 7.3 Driver and child process

`New-MigrationStepDriver` writes `Workbench/Runs/<ts>_<Id>/driver.ps1`:

```powershell
#Requires -Version 7.4
# Generated by Start-MigrationWorkbench <version> on <date> for <workspace>.
# Re-run by hand: pwsh -NoProfile -File "<this file>"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$parameters = @{
    PlanPath = '...'
    Wave     = @('1')
    TenantId = '...'
    Prefix   = 'Contoso'
    OutputPath = '...'
    DryRun   = $true
    Confirm  = $false
}
& '<toolkit path>/New-MigrationUsers.ps1' @parameters
exit $LASTEXITCODE
```

`Invoke-MigrationStep` runs `<same pwsh as the parent> -NoProfile -NonInteractive
-ExecutionPolicy Bypass -File driver.ps1` with stdout/stderr redirected to the run folder,
polls every 250 ms (`[Threading.Thread]::Sleep`, not `Start-Sleep`), reads new complete lines
from a byte offset and hands them to an injected writer scriptblock (console: `Write-Host`;
WinForms: the log pane + `DoEvents` pump). Cancel kills the process tree and records
`Aborted`. The exit code is read from the process object. Files produced are the files in the
step's prefix folder that did not exist when the run started.

Exit-code meaning comes from the overlay; the shared vocabulary is 0 completed, 1 failed,
2 some rows failed (amber), 3 work remains (amber, domain release), other = see the log.

### 7.4 Ledger

`Workbench/Runs.jsonl`, one JSON object per line, appended after every run:
`{ Started, Ended, StepId, Script, Side, TenantId, DryRun, Wave, ExitCode, Meaning, Aborted,
TenantVerified, GateOverrides, Driver, Files, Summary }`. Never contains parameter values
that match the secret pattern. The scanner reads it for state; the "Results & logs" view lists
it newest first.

## 8. Console workbench

Pure PowerShell, no third-party modules. Every prompt goes through one seam
(`$script:MigrationPrompt`, a scriptblock defaulting to `Read-Host`/`PromptForChoice`) so the
Pester suite drives the whole flow with scripted answers on macOS.

Screens: workspace pick (folders under the default root + recent list kept in
`~/.config/M365Migration/recent.json` on macOS/Linux, `%APPDATA%\M365Migration\recent.json`
on Windows) → first-run settings form (field by field, Enter accepts the suggestion, domain →
GUID resolved inline) → phase view (default) / all tools / settings / results & logs → step
form (each parameter with value and provenance; wave pick-list from the plan; file
parameters offer the resolver's candidates) → gates → command preview → live output → exit
meaning, Succeeded/Failed/Skipped counts, file paths.

## 9. WinForms workbench

Lives only in the `#region GUI` of `Start-MigrationWorkbench.ps1`, built inside
`Start-MigrationWorkbenchGui`, WinForms loaded there and only after the platform check.
Layout (TableLayoutPanel + Dock/Anchor, `SetHighDpiMode PerMonitorV2`, `AutoScaleMode = Dpi`):

- Top: workspace path + Browse, Label, SOURCE / DESTINATION tenant banner (colour-coded).
- Left: tabs "Phases" (TreeView: phase → instances with state glyph and last-run text) and
  "All tools" (ListView of the 17 scripts).
- Right: the step form generated from the catalog (TextBox / CheckBox / ComboBox for
  ValidateSet / CheckedListBox for `string[]` ValidateSet and for waves / file and folder
  pickers for path parameters), provenance shown beside each value, then the read-only
  command preview and the buttons **Dry run**, **Run**, **Copy command**, **Open folder**.
- Bottom: log pane (read-only, Consolas, capped), status strip.
- Dialogs: Settings (same fields as the console form), typed-confirmation dialog, results
  summary.

The window holds no logic: every button calls an engine function and renders the result.
A test dot-sources the script with `-NoGui` on macOS and asserts the GUI's step list equals
`Get-MigrationStep`.

## 10. Entry script and launcher

`Start-MigrationWorkbench.ps1` parameters: `-Workspace`, `-Console`, `-Step`, `-Wave`,
`-DryRun`, `-Set` (hashtable of parameter overrides for non-interactive runs), `-Verbosity`,
`-LogPath`, `-NoGui` (load-only guard). Its own log goes to `<workspace>/Workbench/` when a
workspace is known, else the default root.

`Start-MigrationWorkbench.cmd`: finds pwsh 7 (`%ProgramFiles%\PowerShell\7\pwsh.exe`, then
PATH), refuses Windows PowerShell 5.1 with the install link, launches
`-NoProfile -ExecutionPolicy Bypass -File`, keeps the window open on a non-zero exit. Never
elevates (WAM breaks under RunAs).

## 11. Toolkit hardening (Part A, done before the workbench)

From the five-lens code review of 2026-09-18. Every existing option is preserved.

Blockers:
1. `Connect-MigrationExchange`: after a fresh connection, if a GUID was requested and the
   connected `TenantId` differs, disconnect and throw. `Resolve-MigrationTenantId` (new)
   turns a domain into its GUID via `https://login.microsoftonline.com/<domain>/v2.0/.well-known/openid-configuration`,
   so all connectors compare GUIDs. This also fixes `New-MigrationRecipients`' guard, which
   aborted on the README's own domain-form example.
2. `Assert-MigrationTenant` (new) replaces the four per-script checks;
   `Set-MigrationMailboxPermissions` gains `-TenantId`; `Set-MigrationIdentity` passes the
   Graph GUID to the Exchange connector. Writers that run without `-TenantId` print a
   prominent warning naming the connected tenant.
3. `Reset-MigrationCutoverPasswords` and `New-MigrationUsers` export results in `finally`,
   fall back to a temp path, and exit 1 with an ERROR naming the count if both writes fail.
   A failed create whose account may exist carries its password in the Failed row.
4. `Save-MigrationPlan` refuses an empty row set; `Invoke-MigrationAction` throws when no
   run context exists (it executed the action today).
5. `Get-MigrationTargetDomain` (dead, interactive) is deleted;
   `Import-MigrationVivaLearningHistory`'s two `Read-Host` prompts become parameters that
   throw with guidance.
6. `Set-MigrationIdentity` never removes the vanity alias before the primary add has
   succeeded; a partial change lists completed steps in `Detail`.
7. `Remove-MigrationDomainReferences` exits 3 when references remain, 2 for row failures.

Majors: `Resolve-MigrationTeamsUser` rethrows anything but not-found;
`Set-MigrationTeamsPhoneAssignments` keeps "Assigned <number>" in a Failed policy grant;
`Remove-MigrationTeamsPhoneAssignments -All` and `Set-MigrationLicenses -RemoveUnplanned`
gain acknowledgement switches (the latter becomes `ConfirmImpact = 'High'`); a formula-prefix
sanitiser (`'` before `= + - @ \t \r`) in `Export-MigrationReport`, `Export-MigrationResult`
and both `Export-Excel` call sites; the planner treats a header-only optional CSV as empty
with a warning; the planner gains `-SmtpDomain`; `Get-MigrationOutputPath` /
`ConvertFrom-MigrationOutputPath` own the filename contract; `Export-MigrationReport
-SuppressInDryRun -Timestamp` replaces the four per-script CSV writers;
`Get-MigrationPlanSchema` (new) and `Get-MigrationDefaultOutputRoot` are exported; every
script's `.NOTES` gets `Version:`; results tokens follow one rule — the script name with
`Migration` removed (`Set-Licenses`, `Test-Readiness`, `Export-MappingFile`), and a
secondary output of the same script uses `-Suffix` (`TeamsPhoneNumbers-Unassigned`)
— so the four outliers are renamed and the README notes it; README fixes (LogPath claim, wildcard and relative-path
examples, "connect read-only" claim, log filename leader); `Templates/WaveMap.sample.csv`
and the `MatchType` column in `ExclusionRules.sample.csv`; tests for the Main regions of
`Set-MigrationLicenses`, `Test-MigrationReadiness`, `Remove-MigrationDomainReferences`;
hermetic stubs in the two SDK-dependent test files.

Documented deviations from the authoring standard (not changed): log root under the
per-migration folder rather than ProgramData; no TLS assertion (pwsh 7 uses OS defaults);
`[bool]` for default-on booleans; `-Verbosity` default `Medium`.

Later backlog (recorded in `EnhancementBacklog.md`, not in this pass): hand-added plan
columns dropped on write-back; OneDrive read errors hidden; credentials CSV naming/ACL;
scope trims; seat pre-check overstated; `-RecomputeLicenses`; Main-region extractions;
line-length reflow; result-row builder consolidation; phase batching in one child.

## 12. Testing

Pester 6 on macOS, no network, no display. Runs with the existing command
(`Invoke-Pester -Path Utilities/M365-Migration/Tests`).

- Engine: settings round-trip and refusals; scanner against `Tests/Fixtures/Workbench/`
  (synthetic filenames with and without prefix, `.bak`, header-only CSV, a dry-run newer than
  a live run); catalog drift guard over all 17 scripts; resolvers; argument resolution and
  provenance; gates; driver generation (parses clean, no secret values, arrays and hashtables
  survive); runner against `Tests/Fixtures/Workbench/Echo-Parameters.ps1` (dumps
  `$PSBoundParameters` as JSON and exits with a requested code) for exit codes 0/1/2/3 and
  cancellation; ledger append and read-back; tenant-verification parsing.
- Console: the full flow driven through the prompt seam.
- Entry script: dot-sourced with `-NoGui`; step-list parity between GUI and engine.
- Hardening: one test per item in §11, plus the coverage gaps named by the review.
- Coverage target 80% on the engine functions (Enterprise tier).

## 13. Documentation

`README.md` leads with the workbench quick start (both platforms) and keeps the script
reference; the root README's Utilities table gains the workbench row in the same commit.
`KnownDocGaps.md` marks each gap this work resolves. `EnhancementBacklog.md` gains the
"later" list. The Hudu article is updated only on the owner's go.

## 14. Versioning

Module `1.1.1 → 1.2.0`. `Start-MigrationWorkbench.ps1` carries `$script:Version = '1.0.0'`
(one constant, used in the banner, the driver header and the ledger).
