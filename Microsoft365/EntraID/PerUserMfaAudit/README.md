# Get-EntraPerUserMfaAudit

Read-only audit of **legacy per-user MFA** state (`disabled` / `enabled` / `enforced`)
across a Microsoft Entra tenant, exported to CSV with a summary and CI-friendly exit
codes.

## Why per-user MFA matters

Legacy per-user MFA predates Conditional Access and is evaluated **independently of
it**. An account set to `enabled` or `enforced`:

- **Overrides Conditional Access app exclusions.** Excluding an app (e.g. Azure Windows
  VM Sign-In) from your CA MFA policy does nothing for a user who is per-user enforced.
- **Silently breaks non-interactive auth flows**, most notably:
  - Entra-joined VM sign-in — Azure Virtual Desktop and Azure Windows VM Sign-In
  - Identity-based SMB mounts to Azure Files — FSLogix profile containers

Tenants migrating to Conditional Access-based MFA need to find every account still set
to `enabled` or `enforced`. That is all this tool does — **it never writes anything**.

## What it does

For each in-scope user it calls the Graph **beta** endpoint

```
GET /beta/users/{id}/authentication/requirements   ->   perUserMfaState
```

and records `UserPrincipalName`, `DisplayName`, `AccountEnabled`, `PerUserMfaState`,
plus a `Flag` column: `REVIEW` (enabled/enforced), `OK` (disabled), or `ERROR`
(lookup failed; message in `ErrorDetail`). Per-user failures never abort the run.

Scope options:

| Invocation | Scope |
|---|---|
| *(no targeting parameters)* | All enabled member users in the tenant (>1,000 users requires `-Force` or interactive confirmation) |
| `-GroupId <guid>` | Transitive user members of one group |
| `-UserPrincipalName <upn[,upn]>` | Just those users |

`-IncludeDisabledAccounts` widens tenant/group scans; disabled accounts are excluded by
default.

## Requirements

- **PowerShell 7+** — Windows, macOS, or Linux
- Modules: `Microsoft.Graph.Authentication` and `Microsoft.Graph.Users`
  (the beta call uses `Invoke-MgGraphRequest` directly, so the beta SDK module is **not** needed)
- Sovereign clouds work: Graph calls use relative URIs, so a `Connect-MgGraph -Environment USGov`
  (or similar) session is honored

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Microsoft.Graph.Users -Scope CurrentUser
```

### Graph permissions

| Permission | Why |
|---|---|
| `Policy.Read.All` | Least-privileged permission for reading `perUserMfaState` (delegated **and** application). `UserAuthenticationMethod.Read.All` is *not* sufficient — it covers system-preferred MFA sign-in preferences, not legacy per-user MFA state. |
| `User.Read.All` | Enumerate users; read UPN / display name / enabled state |
| `GroupMember.Read.All` | Only when using `-GroupId` |

Delegated sign-in additionally requires an Entra role that can read authentication
requirements — **Global Reader** or **Authentication Policy Administrator** are the
least-privileged built-in options. For unattended runs, grant the permissions above as
*application* permissions with admin consent and connect app-only before invoking the
script (`Connect-MgGraph -ClientId ... -TenantId ... -CertificateThumbprint ...`).

## Usage

```powershell
# Audit an AVD users group
./Get-EntraPerUserMfaAudit.ps1 -GroupId 11111111-2222-3333-4444-555555555555

# Whole tenant, unattended (CI / scheduled)
./Get-EntraPerUserMfaAudit.ps1 -Force -OutputPath ./mfa-audit.csv

# Pipeline consumption
./Get-EntraPerUserMfaAudit.ps1 -UserPrincipalName 'user@contoso.com' -PassThru -Verbosity Silent |
    Where-Object Flag -eq 'REVIEW'
```

### Example output

```
TotalAudited : 42
Disabled     : 39
Enabled      : 1
Enforced     : 2
Errors       : 0
ReportPath   : /tmp/EntraPerUserMfaAudit-20260824-101512.csv

WARNING: 3 account(s) still have legacy per-user MFA enabled/enforced:
  avd-user1@contoso.com [enforced]
  avd-user2@contoso.com [enforced]
  svc-fslogix@contoso.com [enabled]
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Ran clean; every audited user is `disabled` |
| `1` | Ran; one or more users `enabled`/`enforced`, **or** some per-user lookups failed (`ERROR` rows) — attention needed |
| `2` | Fatal error (missing module, auth failure, group not found, scope resolved to zero users, throttling exhausted, confirmation declined, or *every* lookup failed) |

Nonzero-means-attention makes it usable as a scheduled or CI compliance gate.

## Remediation (not performed by this tool)

**This tool is read-only by design.** Once you have confirmed an account is covered by
Conditional Access MFA, legacy per-user MFA can be turned off via a PATCH to the same
beta endpoint:

```
PATCH /beta/users/{id}/authentication/requirements
Content-Type: application/json

{ "perUserMfaState": "disabled" }
```

(Requires `Policy.ReadWrite.AuthenticationMethod`.) Disable per-user MFA **only after**
CA-based MFA coverage is in place, or you will drop MFA protection for that account.
See Microsoft's guidance:
[Enable per-user MFA](https://learn.microsoft.com/entra/identity/authentication/howto-mfa-userstates).

> `perUserMfaState` lives on the Graph **beta** endpoint and can change without notice.
