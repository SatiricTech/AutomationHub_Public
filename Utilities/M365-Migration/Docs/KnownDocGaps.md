# Known documentation gaps

Places where this toolkit's own documentation — the folder `README.md` and the Hudu runbook
in this directory — misleads someone running it for the first time. Every item below was hit
during a live tenant-to-tenant migration, not found by proof-reading. None of them is a code
bug; each is a thing the docs say, or fail to say, that cost an operator a failed run or a
wrong decision.

Resolve these the next time the docs are revised. Where a fix belongs in code rather than
prose, that is called out.

The 1.2.0 hardening pass closed **#2, #3, #4, #6, #7 and #9**; each carries a
**Resolved in 1.2.0** line naming how, and its heading says so.

The workbench (`Start-MigrationWorkbench.ps1`, 1.0.0) then closed **#1 and #5** for anyone
running it, because both were gaps about where a value comes from and the workbench answers
that from the workspace instead of from an example. Each carries a **Resolved by the
workbench** line. It also moved **#8 and #10** from invisible to visible without deciding
either, and left **#11** exactly where it was — see the note on it.

**#8, #10, #11 and #12 are still open**: #11 and #12 are code changes recorded in
`EnhancementBacklog.md`, #10 is both, and #8 is prose still to be written. #1 and #5 also stand
for anyone working from the command line rather than through the workbench, since the README's
own examples are unchanged.

---

## 1. Example values are indistinguishable from values to substitute — resolved for workbench runs

**What happens.** The runbook examples read `-TargetDomain newco.com`,
`-InterimDomain newco.onmicrosoft.com` and `-Prefix Contoso`. An operator copied the block
and ran it against two live tenants with those values still in place, because nothing marks
them as placeholders.

**Suggested fix.** Make substitutable values look substitutable, and add a short "before you
run this, replace these" list to the top of the runbook naming every value that is
environment-specific. Real-looking domains in examples are the trap.

**Resolved by the workbench** (code): an operator running `Start-MigrationWorkbench.ps1` never
copies an example. Every environment-specific value lives in that workspace's own
`M365Migration.settings.json`; the settings form asks for each key by name with its one-line
description beside it, and deliberately suggests nothing where a guess would be dangerous — a
tenant GUID and a release domain are left blank rather than pre-filled, because Enter would
otherwise accept them. The step form then shows each resolved value with where it came from
(`Fixed`, `Operator`, `Settings`, `Resolved` or the script's own default), and the command
preview shows the real command before anything runs. **Still open for command-line runs:** the
README and the runbook examples still read `contoso.com`, `newco.com` and `-Prefix Contoso`,
and the "before you run this, replace these" list has not been written.

## 2. Runbook examples use wildcards that only one parameter supports — resolved

**What happens.** Every runbook example writes CSV inputs as `.\Source_Users_*.csv`. Only
`-PlanPath` resolves a wildcard. Every other CSV parameter is read literally, so each of those
examples fails with "file not found" when pasted.

**Suggested fix.** Either stop showing wildcards on parameters that cannot take them, or make
the CSV parameters resolve a unique wildcard the way `-PlanPath` already does. The second is
the better fix: the filenames carry a timestamp, so a wildcard is the natural way to name
them and operators will keep reaching for it.

**Resolved in 1.2.0** (docs only): the first fix. Every runbook example now names its file, and
a `*` appears only on `-PlanPath`. The README's Runbook preamble says which parameters resolve
a wildcard — `-PlanPath`, and `-ExistingPlanPath` in the planner, both through
`Import-MigrationPlan` — and that everything else is read with `-LiteralPath`. The behaviour
itself is unchanged; making the other CSV parameters resolve wildcards is still open, and sits
in `EnhancementBacklog.md` territory rather than here.

## 3. Relative paths in the examples cannot work as written — resolved

**What happens.** Examples use `.\` for every input, but the source and destination
inventories are written into two different folders under the output root, and neither is the
folder the scripts are run from. No single working directory makes an example runnable.

**Suggested fix.** Show full paths in the runbook, or show the variables that build them.
State plainly that the two inventories do not share a folder.

**Resolved in 1.2.0** (docs only): the README gained "Where output lands, and the paths in
these examples", which defines `$Root`, `$SourceDir`, `$DestDir` and `$RunDir`, says outright
that each `-Prefix` gets its own folder so no single working directory works, and every example
now builds an absolute path from those variables.

## 4. An empty optional CSV is fatal, and nothing says so — resolved

**What happens.** A tenant with no shared mailboxes, or no mail contacts, still gets a
header-only CSV from the inventory. Passing that file to the planner aborts the run with
"contains no data rows". The operator has to work out that the fix is to drop the argument.

**Suggested fix.** Best fixed in code: an optional input that exists but holds no rows should
log a warning and contribute nothing, not end the run. Until then the docs must say to omit
inputs whose CSV is empty, and the error text should name the parameter to drop.

**Resolved in 1.2.0** (code, for the planner): `New-MigrationIdentityPlan` reads every optional
input through `Import-OptionalPlanCsv`, which treats a header-with-no-rows file as empty and
warns `<parameter> '<file>' has a header but no rows; nothing was taken from it.` — naming the
parameter, as asked. That covers `-UserMailboxesCsv`, `-SharedMailboxesCsv`, `-GroupsCsv`,
`-ContactsCsv`, `-ExclusionRulesPath` and `-WaveMapPath`; `-SkuMapPath` and
`-ReservedAddressesPath` do their own reading and catch the same case with the same warning.
The required `-UsersCsv` still
refuses an empty file, correctly. **Scope to know:** no other script got this treatment, so a
header-only CSV handed to `New-MigrationRecipients` or `Set-MigrationMailboxPermissions` still
aborts with "contains no data rows" — the README's Runbook preamble says to drop the argument
there.

## 5. No rule for choosing the target domain — resolved for workbench runs

**What happens.** The docs explain what `-TargetDomain` is but not how to pick it. It is the
domain users will sign in on **in the destination tenant**, which is frequently not the
migrating company's own domain — a destination tenant that has absorbed several companies
may put every user's sign-in address on the parent domain regardless of origin.

**Suggested fix.** Give the operator a rule: read the destination inventory's users file and
use the domain its existing accounts actually sign in on. Say explicitly that the migrating
company's own domain is often the wrong answer.

**Resolved by the workbench** (code): the settings form applies that exact rule rather than
describing it. `Domains.Target` is suggested from the workspace itself — the sign-in domain
most of the destination tenant's existing users already have, read from the newest
`Destination_Users_*.csv`, with `onmicrosoft.com` domains passed over because the vanity domain
is the point of the key. Only the `UserPrincipalName` column is read. An operator who has run
the destination inventory therefore sees the destination's own convention offered, not their
client's domain. **Still open for command-line runs:** the README states what `-TargetDomain`
is but still does not give the rule in prose.

## 6. No rule for deciding whether an interim domain is needed at all — resolved

**What happens.** The runbook always passes `-InterimDomain`, so it reads as mandatory. It is
only needed when the target domain is still held by the source tenant and therefore cannot be
verified in the destination yet. When the target domain is already verified in the
destination, passing an interim domain adds a pointless provision-then-rename cycle.

**Suggested fix.** State the test in one line: if the target domain already appears in the
destination inventory's domains file, omit `-InterimDomain`. Show the runbook's main example
without it, and treat the interim case as the variant.

**Resolved in 1.2.0** (docs only): the README's "Interim vs target domain" section now leads
with the test in bold — if `-TargetDomain` already appears in the destination inventory's
`Domains` CSV, omit `-InterimDomain`. Runbook step 3 is written without it, and the interim
case is a blockquote variant naming the three commands that change (`-InterimDomain` on the
planner, `-UseInterim` in steps 4 and 6).

## 7. Sign-in and mail addresses always share one domain — resolved

**What happens.** The planner builds both the target UPN and the target primary SMTP address
from `-TargetDomain`, so they are always in the same domain. The `UpnSmtpDiverge` section
describes divergence purely in terms of the local-part format, which reads as though the two
could differ by domain as well. A destination whose convention is "sign in on the parent
domain, receive mail on the acquired company's domain" cannot be expressed in one pass.

**Suggested fix.** Say outright that one domain drives both columns. Document the workaround
for a split — build the plan on the sign-in domain, then edit the primary SMTP column and mark
those rows as an operator override — and note that the mail side cannot take effect until the
mail domain is released from the source tenant and verified in the destination. If the split
is common enough, a separate SMTP domain parameter belongs on the backlog.

**Resolved in 1.2.0** (code + docs): the planner gained `-SmtpDomain`, so the split no longer
needs a hand edit. The UPN is built in `-TargetDomain`, the primary SMTP address in
`-SmtpDomain`; those rows are marked `UpnSmtpDiverge`; collisions and reserved addresses are
judged per domain; and `-InterimDomain` then applies to the sign-in address only, with
`InterimPrimarySmtp` equal to `TargetPrimarySmtp` and a warning saying so. The README's "One
domain, or two" subsection states the default — one domain drives both columns — shows the
two-domain example and lists those consequences. Both domains still have to be verified in the
destination before the addresses can be applied.

## 8. A collision may not be a collision

**What happens.** When a planned address is already in use in the destination, the row is
marked `Collision` and a numeric suffix is proposed. The planner only knows the address is
taken; it cannot tell whether the holder is a different person or **the same person, already
provisioned** by an earlier pilot wave. In the second case the suggested suffix would create a
duplicate account for someone who is already migrated.

**Suggested fix.** Tell the operator to check who holds the address before accepting any
suffix, and to look for the tell-tales of an earlier wave — a recent creation date, or a
department or company attribute naming the migrating organisation. Note that the provisioning
script adopts an existing account rather than duplicating it, so the correct repair is to put
the un-suffixed address back on the row and mark it as an operator override.

**Surfaced, not resolved, by the workbench** (code): the board prints the plan's status counts
every time the workspace is scanned, so `3 Collision` is on screen rather than in a console
line that scrolled away an hour ago. Nothing else changed: the workbench cannot tell whether
the holder of a taken address is a different person or the same person from an earlier wave,
and the rule for deciding that is still unwritten. Open.

## 9. A runbook does not say which version of the toolkit it describes — resolved

**What happens.** A published runbook described scripts that existed only on an unmerged
branch. Someone following it against the released code found the script was not there.

**Suggested fix.** Stamp each runbook with the release or merge it corresponds to, and do not
publish one describing unreleased scripts without marking it as pending.

**Resolved in 1.2.0** (code + docs): every one of the 17 scripts now carries `Version: 1.2.0`
in its `.NOTES` block, the module manifest is `1.2.0`, and the README states the toolkit
version in "What this is". A runbook can therefore name the version it was written against and
an operator can check what they have. Publishing discipline for the Hudu article stays a human
habit, not something the code can enforce.

## 10. A skipped row in the mapping export means content will not migrate

**What happens.** The mapping exporter writes only the rows the plan has signed off. Anything
else is recorded as `Skipped` in the results file and simply does not appear in the mapping
file. The console prints a skipped count, but the mapping file itself looks complete and
carries no trace of the omission. An operator who uploads it to the migration tool has
silently excluded those people, and the first sign of trouble is their content never arriving.

**Suggested fix.** State next to the export step that the row count of the mapping file must
be reconciled against the number of in-scope plan rows before the file is uploaded, and that
any `Skipped` row is a person whose mailbox and drive will not move. Consider making the
exporter refuse to write a mapping file when any in-scope row is skipped unless a flag
acknowledges it, since an incomplete mapping is worse than no mapping.

**Surfaced, not resolved, by the workbench** (code): every run's Succeeded / Failed / Skipped
counts are written into the run ledger (`Workbench/Runs.jsonl`) and rendered both in the run
summary and in the results view, so the export's skipped count outlives the console it was
printed to and is still readable weeks later. The mapping file itself still looks complete, and
neither the reconciliation this gap asks for nor the acknowledgement switch exists — the switch
is on `EnhancementBacklog.md`. Open.

## 11. Re-planning with an existing plan freezes licences too

**What happens.** `-ExistingPlanPath` is documented as preserving a row's destination
identity, wave and provisioning state. It also preserves the target licence column. So a
re-run whose whole purpose is to apply a new or corrected SKU map silently skips every
operator-override row, leaving those users mapped to their old source SKUs — which may not
even exist in the destination tenant.

**Suggested fix.** Say plainly which columns `-ExistingPlanPath` freezes, licences included,
and warn that a SKU map change does not reach those rows. Consider preserving identity while
still recomputing licences, since identity is the thing an operator hand-edits and licences
are the thing a map is meant to own.

**Not resolved by the workbench, and more likely to be hit because of it** (code): the planner
step resolves `-ExistingPlanPath` from `Pinned.PlanPath` through the `ExistingPlan` resolver,
so a re-plan run from the workbench carries the pinned plan by default rather than as a
deliberate choice. That is the right behaviour for identity — pinning is what makes a re-plan
safe — but it means the licence freeze described here is now the default path rather than an
opt-in one. The fix is still `-RecomputeLicenses`, on `EnhancementBacklog.md`. Open.

## 12. The seat pre-check counts users who already hold the licence

**What happens.** The seat check totals every plan row that wants a SKU and compares it with
the free seats, without subtracting rows whose destination user already has that licence. On a
migration with a pilot wave already provisioned and licensed, the reported shortfall is
overstated by the size of that wave, and the check keeps failing after enough seats have been
bought.

**Suggested fix.** Subtract rows whose target user already holds the SKU, or report both
numbers — total planned and net new — so the operator knows how many seats to actually buy.
Until then, note in the docs that the figure is an upper bound when an earlier wave exists.

---

## The pattern behind these

Every item here was found by running the toolkit against real tenants, and none by reading the
docs. The examples are internally consistent and describe the parameters accurately; what they
lack is the operator's decision context — which value comes from where, which argument to drop,
and which choice needs a human. A worked first-run walkthrough against a realistic pair of
tenants would have caught every one of them.
