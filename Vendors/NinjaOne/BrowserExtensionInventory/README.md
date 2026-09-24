# Browser Extension Inventory for NinjaOne

`Set-NinjaBrowserExtensionInventory.ps1` reads the browser extensions installed for every user
on a Windows device and writes them to three NinjaOne device custom fields. Nothing leaves the
device except the custom field values. No web store or third-party API is called: the
extension name, version, permissions and install source all come from the browser's own files.

The point of the inventory is fleet-wide search. When a compromised extension is announced,
search the inventory field for its ID and you have the list of affected devices. The flag count
field turns sideloaded, unsigned and block-listed extensions into an alert.

## What it reads

| Browser | Source on disk | Notes |
|---|---|---|
| Chrome, Edge, Brave, Vivaldi, Chromium | `<profile>\User Data\<Profile>\Secure Preferences` and `Preferences` (`extensions.settings`) | Name and version come from the embedded manifest. `__MSG_...__` names are resolved from `Extensions\<id>\<version>\_locales`. Granted permissions come from `granted_permissions`. |
| Opera, Opera GX | `Opera Software\Opera Stable\Secure Preferences` | Single profile in the root folder. |
| Firefox | `Mozilla\Firefox\Profiles\<profile>\extensions.json` | Name, version, signature state, install source and permissions are all in this one file. |

User profiles come from the `ProfileList` registry key, not from a folder listing, so leftover
folders with no account are skipped. The script has to run as SYSTEM or a local administrator
to read other users' profiles.

## What it writes

| Field name | Type | Content |
|---|---|---|
| `browserExtensionInventory` | Multi-line text | One line per unique browser + extension ID: `browser\|id\|name\|version\|source\|state\|users\|flags`. Header line first, flagged entries next. Capped at 10,000 characters with a trailer line when cut. |
| `browserExtensionTable` | WYSIWYG | HTML table with the same data plus the risky permissions, for technicians. Capped at 199,999 characters. |
| `browserExtensionFlagCount` | Integer | Number of unique extensions flagged `blocked`, `sideloaded` or `unsigned`. |

Field names are parameters, so rename them if your tenant uses a different convention.

### Flags

| Flag | Meaning | Counts toward the flag count |
|---|---|---|
| `blocked` | ID is on the block list | Yes |
| `sideloaded` | Not from a store and not installed by policy: unpacked, external registry or preference install, command line, or a `.crx` installed by hand | Yes |
| `unsigned` | Firefox extension with no valid signature | Yes |
| `disabled` | Present but disabled by the user or the browser | No |
| `risk` | Holds a permission from the risky list (`<all_urls>`, `webRequest`, `cookies`, `debugger`, `nativeMessaging`, `proxy`, `history`, `tabs`, ...) | No |

Policy-installed extensions (`ExtensionInstallForcelist`) are reported with source `policy` and
are not flagged. Extensions that ship with the browser (component extensions and entries the
browser marks `was_installed_by_default`) are left out unless you pass
`-IncludeDefaultExtensions`.

Extension names are attacker-controlled. A malicious extension can call itself "Google Docs
Offline". Search by ID, never by name.

## NinjaOne setup

### 1. Create the custom fields

Administration, Devices, Global Custom Fields. Create three device fields:

| Label | Field name | Type | Technician | Scripts | API |
|---|---|---|---|---|---|
| Browser Extension Inventory | `browserExtensionInventory` | Multi-line text | Read only | Read/Write | Read/Write |
| Browser Extensions | `browserExtensionTable` | WYSIWYG | Read only | Read/Write | Read/Write |
| Browser Extension Flag Count | `browserExtensionFlagCount` | Integer | Read only | Read/Write | Read/Write |

The same three fields can be created through the public API (`POST /v2/node-attribute`) with
`scope` `NODE_ROLE`, `definitionScope` `["NODE"]` and `type` `TEXT_MULTILINE`, `WYSIWYG` and
`NUMERIC`.

### 2. Add the script

Administration, Library, Automation, Add, New Script.

| Setting | Value |
|---|---|
| Name | Set Browser Extension Inventory |
| Language | PowerShell |
| Operating system | Windows |
| Architecture | All |
| Run as | System |

Paste the script body. Before you paste, set `$MSPName` in the configuration region to your
MSP name; it only controls the log folder under `C:\ProgramData`.

Optional script variable for the block list:

| Variable name | Type | Value |
|---|---|---|
| `blockedExtensionIds` | String | Comma-separated extension IDs |

The script reads the variable from the `blockedExtensionIds` environment variable NinjaOne
sets at run time. `-BlockedExtensionId` as a preset parameter works the same way.

### 3. Schedule it

Add the script to the workstation policy under Scheduled Scripts, or to a scheduled task, once
a day. The scan takes a few seconds per user profile.

### 4. Alert on the flag count

Policy, Conditions, Add, Custom Fields:

| Setting | Value |
|---|---|
| Field | Browser Extension Flag Count |
| Operator | Greater than |
| Value | 0 |

Set the severity, ticket and notification options the way your other conditions use them.

### 5. Search the fleet

Devices, search, then filter on Browser Extension Inventory contains `<extension id>`. The
same filter works in a device group, so a saved group per block-listed ID is a one-time setup.

## First run on a test device

1. Run the script from NinjaOne against one device with `-DryRun -Verbosity High` as the
   parameters. The activity log shows every extension found and the three values that would be
   written. No field changes.
2. Check the log under `C:\ProgramData\<MSPName>\Logs\Set-NinjaBrowserExtensionInventory-<timestamp>.log`.
   Each line in the DEBUG output names the browser, user, ID, name, source and flags.
3. Look for `sideloaded` entries that came from a store. Edge Add-ons installs are recognised
   by their update URL; a store install that still shows `sideloaded` means a new store URL
   has appeared and belongs in `$script:StoreUpdateUrlPatterns`.
4. Run again without `-DryRun`. Open the device and read the three fields.

A manual run on a device without the NinjaOne agent still works. The script logs a warning
that the CLI is missing and, with `-ReportPath C:\Temp\ext.json`, writes the full record set to
JSON.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected failure, see the log |
| 50 | Partial success: at least one profile or browser file could not be read. The fields are still written from what was readable. |

## Tests

`Tests\Set-NinjaBrowserExtensionInventory.Tests.ps1` is a Pester 5/6 suite that dot-sources
the script and runs the parsers and formatters against fixture files in `TestDrive`. It runs
on macOS, Linux and Windows and touches no real profile or NinjaOne field.

```powershell
Invoke-Pester -Path .\Tests\Set-NinjaBrowserExtensionInventory.Tests.ps1
```

On PowerShell 7 the JSON files are parsed with `ConvertFrom-Json -AsHashtable`. On Windows
PowerShell 5.1, which is what the NinjaOne agent runs, the script uses
`JavaScriptSerializer` instead, because 5.1 `ConvertFrom-Json` fails on browser preference
files whose keys differ only by case. The 5.1 path is exercised by the first run on a real
device, not by the suite.

## Known limits

- Windows only. The macOS browser paths differ and Safari extensions need `pluginkit`.
- A user profile that is on a removed or offline drive is skipped and counted as a read
  failure (exit code 50).
- The inventory field holds about 100 to 150 lines before the 10,000 character cap applies.
  A device with more unique extensions than that still gets the full table in the WYSIWYG
  field and the full list in the log.
- The risky permission list is a fixed set in the configuration region. Edit it to match your
  own review policy.
