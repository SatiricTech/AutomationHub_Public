# AutomationHub

Curated IT automation scripts for MSPs/MSSPs. **This repo is public and GPLv3.**
Treat every change as published the moment it merges.

## Public-repo rules

- No client names, tenant IDs, internal hostnames, API keys, or license keys —
  including in comments, examples, and `.NOTES` blocks.
- Scripts must be generic. Anything client-specific belongs in the private
  `Sentinel-ScriptHub` repo instead. When porting a script outward, strip identifiers
  and parameterize what was hardcoded.
- Leave the README's disclaimer and "as-is" liability sections intact.

## Naming

PascalCase `Verb-Noun.ps1`, following the [.NET capitalization
conventions](https://learn.microsoft.com/en-us/dotnet/standard/design-guidelines/capitalization-conventions):

- **PascalCase everything.** camelCase is for parameter names only, never filenames.
- **Acronyms over two letters get PascalCased:** `Rmm`, `Fsmo`, `Duo`, `Sso`, `Odt` —
  not `RMM`, `FSMO`. So `Uninstall-NinjaRmmAgent.ps1`, not `Uninstall-NinjaRMMAgent.ps1`.
- **Two-letter acronyms stay uppercase:** `AD`, `AV`, `IP`, `QR`, `ID`. So
  `Get-PublicIP.bat` and `New-QRCode.ps1` are correct as-is.
- **No underscores**, ever.
- No client names, dates, version numbers, author initials, or ticket numbers.

> The global `powershell-naming` skill specifies lowercase `verb-scope-target.ps1`.
> **That does not apply here** — this repo follows the .NET conventions above.

## The RMM / AdHoc variant pattern

Several tools ship as a pair:

- `*-Rmm.ps1` — non-interactive, driven by environment variables or parameters, safe
  for unattended RMM deployment. No prompts, no `Read-Host`.
- `*-AdHoc.ps1` (or the unsuffixed name) — interactive, prompts the technician.

Examples: `Rename-Device-Rmm.ps1` / `Rename-Device-AdHoc.ps1`,
`Invoke-WindowsProActivation-Rmm.ps1` / `Invoke-WindowsProActivation.ps1`.

If you add or change one half of a pair, check whether the other needs the same change.

## README is hand-maintained

The README contains per-folder tables listing every script with a description.
**Adding, renaming, or removing a script means updating its table row in the same
commit.** There is no generator — it drifts silently if you skip it.

## Layout

`Windows/`, `Microsoft365/`, `Networking/`, `Monitoring/`, `Utilities/`, `Vendors/`
(one subfolder per vendor), `macOS/` (mirrors the same category names for shell
scripts).

## Mixed languages

PowerShell (`.ps1`), batch (`.bat`), and shell (`.sh`, under `macOS/`). For shell
scripts: `bash -n` for syntax, `shellcheck` if available — both are already in this
repo's permission allowlist.

PowerShell here targets Windows endpoints and can't be executed on macOS. Syntax-check
and review instead.

## Workflow

Changes land via PR (see the merge history). Branch, commit, push, open a PR — don't
push to `main` directly.
