# Known documentation gaps

Places where this toolkit's own documentation — the folder `README.md` and the Hudu runbook
in this directory — misleads someone running it for the first time. Every item below was hit
during a live tenant-to-tenant migration, not found by proof-reading. None of them is a code
bug; each is a thing the docs say, or fail to say, that cost an operator a failed run or a
wrong decision.

Resolve these the next time the docs are revised. Where a fix belongs in code rather than
prose, that is called out.

---

## 1. Example values are indistinguishable from values to substitute

**What happens.** The runbook examples read `-TargetDomain newco.com`,
`-InterimDomain newco.onmicrosoft.com` and `-Prefix Contoso`. An operator copied the block
and ran it against two live tenants with those values still in place, because nothing marks
them as placeholders.

**Suggested fix.** Make substitutable values look substitutable, and add a short "before you
run this, replace these" list to the top of the runbook naming every value that is
environment-specific. Real-looking domains in examples are the trap.

## 2. Runbook examples use wildcards that only one parameter supports

**What happens.** Every runbook example writes CSV inputs as `.\Source_Users_*.csv`. Only
`-PlanPath` resolves a wildcard. Every other CSV parameter is read literally, so each of those
examples fails with "file not found" when pasted.

**Suggested fix.** Either stop showing wildcards on parameters that cannot take them, or make
the CSV parameters resolve a unique wildcard the way `-PlanPath` already does. The second is
the better fix: the filenames carry a timestamp, so a wildcard is the natural way to name
them and operators will keep reaching for it.

## 3. Relative paths in the examples cannot work as written

**What happens.** Examples use `.\` for every input, but the source and destination
inventories are written into two different folders under the output root, and neither is the
folder the scripts are run from. No single working directory makes an example runnable.

**Suggested fix.** Show full paths in the runbook, or show the variables that build them.
State plainly that the two inventories do not share a folder.

## 4. An empty optional CSV is fatal, and nothing says so

**What happens.** A tenant with no shared mailboxes, or no mail contacts, still gets a
header-only CSV from the inventory. Passing that file to the planner aborts the run with
"contains no data rows". The operator has to work out that the fix is to drop the argument.

**Suggested fix.** Best fixed in code: an optional input that exists but holds no rows should
log a warning and contribute nothing, not end the run. Until then the docs must say to omit
inputs whose CSV is empty, and the error text should name the parameter to drop.

## 5. No rule for choosing the target domain

**What happens.** The docs explain what `-TargetDomain` is but not how to pick it. It is the
domain users will sign in on **in the destination tenant**, which is frequently not the
migrating company's own domain — a destination tenant that has absorbed several companies
may put every user's sign-in address on the parent domain regardless of origin.

**Suggested fix.** Give the operator a rule: read the destination inventory's users file and
use the domain its existing accounts actually sign in on. Say explicitly that the migrating
company's own domain is often the wrong answer.

## 6. No rule for deciding whether an interim domain is needed at all

**What happens.** The runbook always passes `-InterimDomain`, so it reads as mandatory. It is
only needed when the target domain is still held by the source tenant and therefore cannot be
verified in the destination yet. When the target domain is already verified in the
destination, passing an interim domain adds a pointless provision-then-rename cycle.

**Suggested fix.** State the test in one line: if the target domain already appears in the
destination inventory's domains file, omit `-InterimDomain`. Show the runbook's main example
without it, and treat the interim case as the variant.

## 7. Sign-in and mail addresses always share one domain

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

## 9. A runbook does not say which version of the toolkit it describes

**What happens.** A published runbook described scripts that existed only on an unmerged
branch. Someone following it against the released code found the script was not there.

**Suggested fix.** Stamp each runbook with the release or merge it corresponds to, and do not
publish one describing unreleased scripts without marking it as pending.

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

---

## The pattern behind these

Every item here was found by running the toolkit against real tenants, and none by reading the
docs. The examples are internally consistent and describe the parameters accurately; what they
lack is the operator's decision context — which value comes from where, which argument to drop,
and which choice needs a human. A worked first-run walkthrough against a realistic pair of
tenants would have caught all nine.
