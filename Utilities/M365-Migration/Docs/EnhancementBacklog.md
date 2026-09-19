# Enhancement backlog

Wanted changes to how the toolkit behaves, as opposed to
[documentation problems](KnownDocGaps.md). Nothing here is a defect; each item is friction
noticed while running a real migration. None is urgent.

---

## 1. A run profile naming the source and destination tenants, so sessions are reused

**The ask.** Record the source and destination tenant IDs once — a profile file, or a
parameter set the runbook establishes at the start — and have each script reuse an existing
session when it already points at the right tenant, instead of re-authenticating on nearly
every invocation.

**What already exists.** Session reuse and a tenant check are both implemented. A cached Graph
session is reused when its tenant matches, and dropped with a logged reason when it does not.
So the tenant half of the request is already built.

**What actually forces the re-auth.** The scope set, not the tenant. Every script asks for the
scopes it needs and no more, and a cached session that lacks any requested scope is dropped and
rebuilt. The runbook alternates between read-only phases and writing phases whose scope sets do
not contain one another, so consecutive steps keep invalidating each other's session even
though the tenant never changed. Working through the runbook therefore means signing in again
at almost every step.

**Options worth weighing.**

- Connect once per tenant with the union of the scopes the whole runbook needs, so every later
  script's requirement is already satisfied. Cheapest to build, and the trade-off is that a
  read-only phase then holds write scopes it does not use.
- Keep per-script scopes but request them incrementally, so a session is widened rather than
  dropped and rebuilt.
- A run profile file holding both tenant IDs, which the scripts read instead of taking
  `-TenantId` on every call.

**Worth noting beyond convenience.** A profile that names the source and destination tenants
explicitly would also guard the most expensive mistake in this toolkit, which is running a
writing script against the wrong tenant. Today that is prevented only by the operator passing
the right tenant on every command and reading the connection line. Naming the two tenants once,
in one place, turns a per-command discipline into a property of the run.

**Also worth checking when this is picked up.** Exchange Online is a separate session with its
own lifetime and a noticeably slower connect, so any session strategy needs to cover both.

**Half of this is now done.** The workbench's `M365Migration.settings.json` is the run profile
this item asked for: both tenant GUIDs are named once per migration, every step is given
`-TenantId` from the side it belongs to, and every connector asserts it reached that tenant. So
the "expensive mistake" half — running a writer against the wrong tenant because someone forgot
an argument — is now a property of the workspace rather than a per-command discipline. The
re-authentication half is untouched: each script still asks for its own scope set, so
consecutive steps keep invalidating each other's cached session. Phase batching in one child
process (below) is the answer to that half, not another profile.

---

## 2. Deferred from the 1.2.0 hardening pass

Every item below was raised, weighed and consciously left out of 1.2.0 — either because the
fix is larger than the finding, or because it belongs with the workbench work rather than
ahead of it. None is a defect; each is written so it can be picked up cold.

### Behaviour

- **Hand-added plan columns are dropped on write-back.** `Import-MigrationPlan` and
  `Save-MigrationPlan` carry only the canonical schema, so an operator's own column — a ticket
  reference, a note to the service desk — survives being read but not being written back by a
  writer. Either round-trip unknown columns or say plainly in the README that the plan is
  schema-fixed.
- **OneDrive and calendar read errors in `Get-MigrationInventory` are hidden.** They are logged
  at DEBUG and do not set exit 2, so a tenant whose OneDrive reads all failed looks like a
  tenant with no OneDrive. Surface them as rows, or at least raise the level.
- **Credentials CSV naming and ACL.** The file holding `GeneratedPassword` is named like every
  other results file and inherits the folder's permissions. A distinct name and owner-only
  permissions would make it obvious and harder to leak — the rescue copy in the temp folder
  especially.
- **Graph scope trims.** `Set-MigrationIdentity` asks for `Directory.ReadWrite.All` it may not
  need; `Reset-MigrationCutoverPasswords` carries scopes that are redundant given the others;
  and three writers still request `ReadWrite` scopes under `-DryRun`. Each trim is small, each
  needs its own proof that nothing else used the scope.
- **Seat pre-check counts users who already hold the licence** (KnownDocGaps #12). Subtract the
  rows whose target user already has the SKU, or report planned and net-new side by side.
- **`-RecomputeLicenses` on a re-plan** (KnownDocGaps #11). `-ExistingPlanPath` freezes the
  licence column along with the identity, so a corrected SKU map never reaches an override row.
  A switch that preserves identity while recomputing licences is the smallest honest fix.
- **Mapping export should refuse, or make you acknowledge, in-scope rows that are `Skipped`**
  (KnownDocGaps #10). An incomplete mapping file is worse than no mapping file, and today it
  looks complete.
- **`Remove-MigrationTeamsPhoneAssignments` resolves users before the row loop.** One transient
  Teams error therefore aborts the whole wave before a single number is released. Per-row
  resolution fails one row instead. The current shape is the safe direction, which is why it
  shipped, but it is not the right one.
- **`-ReportOnly` as an alias of `-DryRun`**, `-User` as `[string[]]` in the Teams scripts, and
  `-ScriptName` taken from `$MyInvocation` instead of a literal. Three small consistency wins
  that each touch several files.

### Structure and tests

- **Main-region extractions.** `New-MigrationIdentityPlan`, `New-MigrationRecipients`,
  `Get-MigrationInventory` and `Import-MigrationVivaLearningHistory` still carry long `Main`
  regions that can only be tested end to end. Pulling the decisions out, as the other scripts
  now have, is what makes them unit-testable.
- **Line-length reflow of pre-existing over-120-character lines**, then turn on the
  `PSAvoidLongLines` analyzer rule so they cannot come back.
- **Result-row builder consolidation.** A `New-MigrationResultRow` helper, and promoting the
  three duplicated `Private/` converters, would remove the copy-paste that every script repeats.
- **`Import-OptionalPlanCsv`: unify the three empty-CSV catch shapes.** The planner catches the
  same "no data rows" condition in three places with three slightly different shapes.
- **Behavioural `-DryRun` end-to-end harness for `Get-MigrationInventory`**, and driving the
  `RecipientAddress` → `UpdateAddresses` path in the domain-references harness. Both are
  currently proved structurally rather than by running them.
- **Duplicate "could not confirm" warning in `Get-MigrationInventory`**, alongside the one
  `Assert-MigrationTenant` already emits. Cosmetic, but it reads like two different problems.
- **`Assert-MigrationTenant -FallbackTenantId` to own the four-script expected-tenant block.**
  `Get-MigrationInventory`, `Remove-MigrationDomainReferences`, `Set-MigrationIdentity` and
  `Test-MigrationReadiness` each carry the same
  `$expectedTenant = if ($TenantId) { $TenantId } else { $graphTenantId }` line, plus the same
  "this run was not pinned" warning around it. A `-FallbackTenantId` parameter would let the
  guard make that choice itself, so the fallback rule and its warning live in one place
  instead of four.
- **The Hudu article still uses relative paths.** `Docs/Hudu-M365Migration.html` writes
  `-PlanPath .\Contoso_IdentityPlan_<ts>.csv` and its siblings, the shape the README dropped
  in 1.2.0 because each `-Prefix` gets its own folder and no single working directory makes
  a relative path work. The article is published, so rewriting it to the `$RunDir`-style
  absolute paths is the owner's call and waits on their go.

### Bigger

- **Phase batching in one child process** (workbench v2). Running several phases in a single
  child would keep one set of sessions alive across them, which is the real answer to the
  re-authentication friction item 1 describes. Explicitly a non-goal of workbench 1.0.0
  (`Docs/Workbench-Design.md` section 1): one child process per step is what makes an exit
  code, a driver file and a ledger line mean one thing each, and batching has to keep that.

---

## 3. Deferred from the workbench build (workbench 1.0.0)

Everything raised and consciously left out while building `Start-MigrationWorkbench.ps1` and
the engine functions behind it. As above: none is a defect, and each is written so it can be
picked up cold. Section numbers below are sections of `Docs/Workbench-Design.md`.

### Behaviour

- **`Aborted` has no state of its own.** A run the operator cancelled is recorded in the ledger
  with `"Aborted": true`, but the scanner maps it to `Failed` (§6) because it left nothing
  behind and carries an undefined exit code. That is the safe reading — it is certainly not
  `Done` — but the board cannot distinguish "this failed" from "I stopped this", which are
  different next actions. A seventh state, or a glyph modifier, would say which.
- **A launch failure writes no ledger line.** `Invoke-MigrationStep` appends to the ledger in a
  `finally`, but a child that never starts — a missing or unreadable `pwsh`, a driver folder
  that cannot be created — throws before there is a run to record. The step then looks as if it
  was never attempted. The docstring says so; a ledger line with a synthetic exit code would say
  it where the operator is looking.
- **The GUI has no password box, by design.** The Viva Learning app-only phase is the one step
  that needs a client secret, and the WinForms window asks for it the same way an unattended run
  does: `M365MIGRATION_CLIENT_SECRET` in the environment, or a certificate thumbprint in the
  settings. That was accepted for 1.0.0 because a `SecureString` typed into a form still has to
  reach a child process through that same environment block, so the box would add a control
  without changing where the secret travels. Worth revisiting only with an answer to what the
  box buys.
- **`Get-MigrationWaveKey` sorts its normal form as strings**, so the key for waves `2` and `10`
  is `10|2`. Harmless for the comparison it exists for — both sides are reduced the same way —
  but the key is not a human-orderable list, and a natural sort would make the ledger's own
  `Wave` values read the way an operator wrote them.
- **Cross-parameter-set conflict order is unspecified.** Where an operator's overrides name
  parameters from two sets, `Resolve-MigrationStepArguments` picks the first satisfiable set
  holding the values supplied first and drops the rest (§7.1). Which of two equally satisfiable
  sets wins is not stated anywhere, so it is whatever the script declared first. Say it, or
  decide it.
- **An empty gate list flattens to `$null`.** `Test-MigrationStepGate` returning nothing follows
  the module's convention rather than returning an empty array, so every caller wraps it in
  `@()`. Consistent with the rest of the module, and consistently a small trap.
- **Report paths are printed in full.** The results view prints absolute paths, which wrap on a
  narrow terminal. Shortening them relative to the workspace would fit, at the cost of a path
  that cannot be pasted straight into a shell.

### Structure and tests

- **The ledger sort is duplicated.** `Get-MigrationRunLedger` and the results renderer both sort
  entries by `Started` then line number, descending. One of them should call the other.
- **`Get-MigrationStep -Id` builds all 17 script introspections before filtering.** Cached per
  session, so it costs once, but asking for one step should not read seventeen `Get-Help`
  documents first.
- **`ResultIds` ordering for an instance override is containment-based, not "first".** An
  instance that overrides its script's result tokens produces a list whose order follows the
  containment check rather than the order the instance declared. Nothing reads the order today;
  a scanner change that did would be surprised by it.
- **The step form's error guard also catches prompt failures.** A broken prompt seam is reported
  as a step-form problem rather than as the input failure it is.
- **Helpers called from `finally` blocks are not individually guarded.** The ledger append and
  the process kill are inside one `try`, so a throw in the first skips the second.
- **`Mapping` is not in `Export-MappingFile`'s `Produces`.** The Fly workbook is deliberately off
  the filename contract (see the README's Conventions table), so the scanner cannot parse it and
  the step is marked done from its results file instead. Correct today; worth stating in the
  overlay rather than leaving to be rediscovered.
- **Three `Requires` edges are judgement calls**, not facts the catalog can prove: they encode a
  runbook order rather than a hard data dependency, and nothing in `StepCatalog.psd1` marks them
  as the softer kind. A reader deciding whether an edge may be removed cannot tell which are
  advice.
- **`Requires` accepts `Export:*` but nothing uses it.** Either use it or drop it from the
  vocabulary, so the grammar and the catalog stay the same size.
- **Test and help tidying.** No test covers `Save-MigrationSettings`' backup-copy failure path,
  nor the `DryRunFirst` combination of a ledger rehearsal, no plan and a failed exit. The
  `-Because` text at `Tests/StepCatalog.Tests.ps1` around the `Confirm` assertion still
  describes the pre-ruling behaviour (`-Confirm:$false` is now emitted for every script
  declaring `SupportsShouldProcess`, not only the High-impact ones).
- **`Get-MigrationCatalogValue` has no `[OutputType()]`**, and `New-MigrationStepObject`'s help
  describes the copy it makes in terms that read as if it mutated its input.
- **`Import-MigrationCsv`'s inverse costs an advanced-function call per cell.**
  `ConvertFrom-MigrationSafeCell` is invoked once for every cell of every CSV the toolkit reads
  back — roughly 15µs of `[CmdletBinding()]` overhead each, which is most of the cost on a
  wide inventory. Inlining the check, or hoisting a compiled regex into the reader, would remove
  it without changing behaviour.

### Documentation and help text

- **`ConvertFrom-MigrationSafeCell`'s help does not name the foreign-file case.** It explains the
  round-trip through the toolkit's own files, which is where the apostrophe comes from. It does
  not say that an operator-authored CSV read through `Import-MigrationCsv` — a hand-built wave
  map, a SKU map edited in Excel — gets the same treatment, so a deliberate leading apostrophe
  before `=`, `+`, `-` or `@` in someone else's file is removed too. That is the right behaviour
  and an unwelcome surprise if it is not written down.
- **The renderers' wording is now public API.** `Format-MigrationWorkbenchView`,
  `Format-MigrationStepGlyph`, `Format-MigrationStepLastRun` and
  `Get-MigrationScriptSynopsisText` are exported (§9), so the strings they return are reachable
  by anything, and a wording or glyph change is a breaking change for whoever parsed them. Decide
  whether the text is contract or presentation and say which in each function's `.NOTES`.
- **`Get-MigrationSettingsSchema`'s help still forward-references "a later task"** for what the
  `Required` column is for. The settings form exists now; the sentence should name it.
- **`[Alias('Tenant')]` on `-DelegatedOrganization`** was raised during the catalog work and is a
  toolkit change rather than a workbench one, so it was left alone. Recorded here so it is not
  raised a third time.
