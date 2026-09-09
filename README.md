# AutomationHub

A curated collection of IT automation scripts for MSPs, MSSPs, and IT professionals. Designed for real-world deployment across managed environments.

**License:** GNU GPLv3 - Free to use, modify, and distribute with attribution.

>
> # ⚠️ Disclaimer & Terms of Use

> **TL;DR:** All scripts, configurations, and tools in this repository are provided **"as-is"** without any warranty of any kind. **Use at your own risk.**

---

### Please Read Before Running Anything Here:

* **Production vs. Testing:** While I make every effort to keep work-in-progress or experimental scripts out of this main repository until they are relatively production-ready, mistakes can happen. 
* **Edge Cases & Scope:** Some tools here were built specifically to solve an immediate, highly specific need of mine. They may not account for environmental edge cases, specific user permissions, or unique infrastructure configurations that differ from my own. It *will* break something if run blindly.
* **Maintenance & Support:** This repository is maintained on a "best-effort" basis. I do not actively monitor, update, or maintain these scripts unless I personally encounter an issue or a bug that affects my own daily workflows. 

### Liability
By downloading, copying, or executing any code found within this repository, you acknowledge and agree that **I am not responsible for any damage, data loss, downtime, or security incidents** that may occur in your environment. Always review, test, and vet scripts in a isolated sandbox environment before running them anywhere near production.

---

## Repository Structure

### [`Windows/`](Windows/) - Windows OS Management
| Folder | Scripts | Description |
|--------|---------|-------------|
| [`Activation/`](Windows/Activation/) | `Invoke-WindowsHomeToProUpgrade.ps1` | Upgrade Windows Home to Pro (interactive + RMM) |
| | `Invoke-WindowsProActivation.ps1` | Activate Windows Pro with product key (interactive + RMM) |
| [`ActiveDirectory/`](Windows/ActiveDirectory/) | `New-DomainAdmin.ps1` | Create a new Domain Admin account |
| | `Get-FsmoRoles.ps1` | Display all 5 FSMO role holders |
| | `Export-GPResultReport.cmd` | Generate Group Policy results as HTML |
| [`AzureBlob/`](Windows/AzureBlob/) | `Get-AzureBlobData.ps1` | Pull files from Azure Blob (SAS token or SFTP) into ProgramData category folders |
| [`DeviceManagement/`](Windows/DeviceManagement/) | `Rename-Device-Rmm.ps1` | Automated device naming for RMM deployment |
| | `Rename-Device-AdHoc.ps1` | Interactive device renaming with prompts |
| [`Fonts/`](Windows/Fonts/) | `Install-Fonts.ps1` | System-wide font install from local folder or SFTP (Azure Blob) |
| [`ServerRoles/`](Windows/ServerRoles/) | `Get-WindowsServerRoles.ps1` | Detect installed server roles (AD DS, DNS, DHCP, Hyper-V, etc.) |

### [`Microsoft365/`](Microsoft365/) - Cloud & Office
| Folder | Scripts | Description |
|--------|---------|-------------|
| [`EntraID/`](Microsoft365/EntraID/) | `Start-EntraIDSyncCycle.bat` | Trigger a delta Entra ID (Azure AD) sync |
| [`EntraID/PerUserMfaAudit/`](Microsoft365/EntraID/PerUserMfaAudit/) | `Get-EntraPerUserMfaAudit.ps1` | Read-only audit of legacy per-user MFA state (Enabled/Enforced) tenant-wide, per group, or per user — CSV report + CI exit codes |
| [`OfficeApps/`](Microsoft365/OfficeApps/) | `Install-Microsoft365Apps.ps1` | Deploy M365 Business Standard apps via ODT |
| | `Get-LatestOdtInstaller.ps1` | Download the latest Office Deployment Tool |
| | `Microsoft365-BusinessStandard.xml` | ODT configuration for Business Standard (non-shared) |
| [`AVD/`](Microsoft365/AVD/) | `Redirections.xml` | FSLogix profile redirection config for AVD + Hybrid Entra |

### [`Vendors/`](Vendors/) - Third-Party Product Deployment & Removal
| Folder | Scripts | Description |
|--------|---------|-------------|
| [`BlackpointCyber/`](Vendors/BlackpointCyber/) | `Install-BlackpointAgent.ps1` | Install Blackpoint ZTAC/Snap agent via NinjaOne |
| | `Uninstall-BlackpointAgent.ps1` | Full removal including registry and services |
| [`DUO/`](Vendors/DUO/) | `Set-DuoBypass.ps1` | Add localhost redirect for DUO (fail-open config) |
| [`Egnyte/`](Vendors/Egnyte/) | `Add-EgnyteTrustedSites.ps1` | Add Egnyte to IE Trusted Sites for all user profiles |
| | `Enable-EgnyteOfficeCoEdit.ps1` | Enable Egnyte co-editing in Office apps |
| [`Huntress/`](Vendors/Huntress/) | `Install-HuntressAgent.ps1` | Install Huntress agent from GitHub |
| | `Set-HuntressAuditPolicy.ps1` | Ad-hoc: enforce Huntress SIEM audit policy baseline (interactive) |
| | `Invoke-HuntressAuditPolicyRemediation.ps1` | RMM detect & remediate for Huntress SIEM audit policy baseline |
| [`LastPass/`](Vendors/LastPass/) | `Install-LastPass.ps1` | Deploy LastPass with browser extension detection |
| | `Remove-LastPassBrowserExtension.ps1` | Remove LastPass extensions from Chrome/Edge |
| [`NinjaOne/`](Vendors/NinjaOne/) | `Uninstall-NinjaRmmAgent.ps1` | Complete Ninja agent removal (services, registry, drivers) |
| [`Proofpoint/`](Vendors/Proofpoint/) | `Uninstall-ProofpointOutlookPlugin.ps1` | Detect-first silent removal of the Proofpoint Outlook encryption plug-in (closes Outlook only if installed) |
| [`ScreenConnect/`](Vendors/ScreenConnect/) | `Uninstall-ScreenConnectAll.ps1` | Remove all ScreenConnect/ConnectWise Control instances |
| | `Uninstall-ScreenConnectSelective.ps1` | Remove ScreenConnect except protected fingerprints |
| [`SentinelOne/`](Vendors/SentinelOne/) | `Install-SentinelOneAgent.ps1` | Install or clean SentinelOne agent (v2.1) |
| [`ThreatLocker/`](Vendors/ThreatLocker/) | `Install-ThreatLocker.ps1` | Deploy ThreatLocker via NinjaOne custom fields |
| [`Timus/`](Vendors/Timus/) | `Install-TimusConnect.ps1` | Install or update Timus Connect client |
| | `New-TimusEntraSsoApp.ps1` | Create Entra ID enterprise app for Timus SSO/Sync |
| | `Uninstall-TimusConnect.ps1` | Full removal of Timus Connect |

### [`Networking/`](Networking/) - Network Tools
| Scripts | Description |
|---------|-------------|
| `Get-NetworkAdapterInfo.ps1` | List network adapters with status, MAC, speed |
| `Get-PublicIP.bat` | Continuous public IP monitor (5-second refresh) |

### [`Monitoring/`](Monitoring/) - Auditing & Discovery
| Scripts | Description |
|---------|-------------|
| `Get-UserLogonEvents.ps1` | Parse logon events from Security/System logs (last 24hrs) |
| `Get-BrowserHistory.ps1` | Extract browser history from Chrome/Firefox/Edge with search |
| `Get-DiskFreeSpace.ps1` | Report disk space usage across all drives |
| `Find-Hypervisors.py` | Network scan for Hyper-V, Proxmox, and VMware hosts |

### [`macOS/`](macOS/) - Apple Device Management
Mirrors the top-level structure for cross-platform parity. Add Mac scripts in the matching subfolder.

| Folder | Scripts | Description |
|--------|---------|-------------|
| [`DeviceManagement/`](macOS/DeviceManagement/) | `Rename-MacDevice.sh` | Rename Mac ComputerName, LocalHostName, and HostName |
| [`Microsoft365/`](macOS/Microsoft365/) | | *Ready for future Mac M365 scripts* |
| [`Vendors/`](macOS/Vendors/) | | *Ready for future Mac vendor scripts* |
| [`Networking/`](macOS/Networking/) | | *Ready for future Mac networking scripts* |
| [`Monitoring/`](macOS/Monitoring/) | | *Ready for future Mac monitoring scripts* |
| [`Utilities/`](macOS/Utilities/) | | *Ready for future Mac utility scripts* |

### [`Utilities/`](Utilities/) - General Tools
| Folder | Scripts | Description |
|--------|---------|-------------|
| | `Mount-SysInternals.bat` | Map network drive to live Sysinternals tools |
| | `Remove-SysInternals.bat` | Unmount Sysinternals network drive |
| | `Send-UserNotification.ps1` | Display a notification message to the user |
| [`M365-Migration/`](Utilities/M365-Migration/) | `M365Migration/` | Shared module every migration script imports (connections, logging, plan I/O, naming engine, collision resolver) |
| | `Get-MigrationInventory.ps1` | Read-only tenant pull into nine CSVs + one workbook: Users, UserMailboxes, SharedMailboxes, MailboxPermissions, Groups, Contacts, Domains, Licenses, Summary |
| | `Get-MigrationTeamsPhoneAssignments.ps1` | Export every user's Teams phone number, type and voice policies to a CSV (optionally the unassigned number inventory too) |
| | `Get-MigrationVivaLearningHistory.ps1` | Export every user's Viva Learning learner history (assignments + self-initiated courses) with course metadata to CSV + JSON |
| | `Compare-MigrationUserData.ps1` | Compare two user CSVs fuzzily, or check a destination inventory against the identity plan |
| | `New-MigrationIdentityPlan.ps1` | Turn source inventory CSVs into the identity plan: target UPN/SMTP naming, collisions, interim domain, SKU map, waves (offline) |
| | `Export-MigrationMappingFile.ps1` | Turn the identity plan into a migration tool's source-to-destination mapping file (AvePoint today; extensible registry) |
| | `Test-MigrationReadiness.ps1` | Pre-flight the destination tenant against the plan at stage Pre, Provisioned or Post; pass/fail per check |
| | `New-MigrationUsers.ps1` | Create destination Entra accounts from the plan (interim or target UPN, managers, GAL hiding, generated passwords) |
| | `Set-MigrationLicenses.ps1` | Assign the plan's licences via a SKU map: usage location first, seat pre-check, refuses group-assigned SKUs |
| | `New-MigrationRecipients.ps1` | Create or patch shared/room/equipment mailboxes, distribution lists, mail-enabled security groups, dynamic DLs and mail contacts |
| | `Remove-MigrationDomainReferences.ps1` | Release a vanity domain in the source tenant: report every reference and blocker, then move objects off the domain |
| | `Set-MigrationIdentity.ps1` | Apply the plan's target UPN, primary SMTP, aliases, X500, mail nickname and GAL visibility (also the in-place UPN redesign tool) |
| | `Set-MigrationMailboxPermissions.ps1` | Re-apply FullAccess, SendAs, SendOnBehalf, calendar permissions and forwarding to the migrated mailboxes |
| | `Reset-MigrationCutoverPasswords.ps1` | Cutover password reset to unique passphrases (plan, CSV, group or single user), change-at-next-sign-in, credential log |
| | `Set-MigrationTeamsPhoneAssignments.ps1` | Bulk-assign Teams phone numbers in the destination tenant from a CSV (auto-detects number type, grants voice routing policy) |
| | `Remove-MigrationTeamsPhoneAssignments.ps1` | Bulk-unassign Teams phone numbers in the source tenant, logging each removal as a reassignment-ready CSV |
| | `Import-MigrationVivaLearningHistory.ps1` | Replay exported Viva Learning learner history into the destination tenant under a custom provider (idempotent re-runs) |

---

## Naming Convention

All scripts follow the **PowerShell `Verb-Noun`** naming standard for consistency:

| Verb | Meaning | Example |
|------|---------|---------|
| `Install-` | Deploy an application | `Install-HuntressAgent.ps1` |
| `Uninstall-` | Remove an application | `Uninstall-NinjaRmmAgent.ps1` |
| `Get-` | Retrieve information | `Get-FsmoRoles.ps1` |
| `Set-` | Configure a setting | `Set-DuoBypass.ps1` |
| `New-` | Create a resource | `New-DomainAdmin.ps1` |
| `Remove-` | Delete a component | `Remove-LastPassBrowserExtension.ps1` |
| `Invoke-` | Run a multi-step process | `Invoke-WindowsHomeToProUpgrade.ps1` |
| `Start-` | Begin a service/process | `Start-EntraIDSyncCycle.bat` |
| `Test-` | Validate state or readiness | `Test-MigrationReadiness.ps1` |
| `Export-` | Output to file | `Export-GPResultReport.cmd` |
| `Find-` | Search/discover resources | `Find-Hypervisors.py` |
| `Enable-` | Turn on a feature | `Enable-EgnyteOfficeCoEdit.ps1` |
| `Add-` | Add to a collection | `Add-EgnyteTrustedSites.ps1` |

Scripts with `-RMM` suffix are designed for automated/silent deployment via RMM tools (no user prompts).

---

## Getting Started

1. **Clone the repo:** `git clone https://github.com/SatiricTech/AutomationHub_Public.git`
2. **Navigate** to the category folder that matches your need
3. **Review** the script before running - most require variables to be set (API keys, org names, etc.)
4. **Run** with appropriate privileges (most require Administrator/elevated PowerShell)

> **Note:** Scripts that integrate with NinjaOne read variables from custom fields via `Ninja-Property-Get`. Update these references for your RMM platform if needed.

---

## Contributing

Contributions are welcome! Please follow the `Verb-Noun` naming convention and place scripts in the appropriate category folder. For vendor-specific scripts, create a subfolder under `Vendors/` (or `macOS/Vendors/` for Mac).
