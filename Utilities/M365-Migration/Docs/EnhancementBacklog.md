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
