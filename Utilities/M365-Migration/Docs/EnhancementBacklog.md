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
  re-authentication friction item 1 describes.
