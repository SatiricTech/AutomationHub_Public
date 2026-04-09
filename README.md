# AutomationHub

A curated collection of IT automation scripts for MSPs, MSSPs, and IT professionals. Designed for real-world deployment across managed environments.

> **License:** GNU GPLv3 - Free to use, modify, and distribute with attribution.

---

## Repository Structure

### [`Windows/`](Windows/) - Windows OS Management
| Folder | Scripts | Description |
|--------|---------|-------------|
| [`Activation/`](Windows/Activation/) | `Invoke-WindowsHomeToProUpgrade.ps1` | Upgrade Windows Home to Pro (interactive + RMM) |
| | `Invoke-WindowsProActivation.ps1` | Activate Windows Pro with product key (interactive + RMM) |
| [`ActiveDirectory/`](Windows/ActiveDirectory/) | `New-DomainAdmin.ps1` | Create a new Domain Admin account |
| | `Get-FSMORoles.ps1` | Display all 5 FSMO role holders |
| | `Export-GPResultReport.cmd` | Generate Group Policy results as HTML |
| [`DeviceManagement/`](Windows/DeviceManagement/) | `Rename-Device-RMM.ps1` | Automated device naming for RMM deployment |
| | `Rename-Device-AdHoc.ps1` | Interactive device renaming with prompts |
| [`ServerRoles/`](Windows/ServerRoles/) | `Get-WindowsServerRoles.ps1` | Detect installed server roles (AD DS, DNS, DHCP, Hyper-V, etc.) |

### [`Microsoft365/`](Microsoft365/) - Cloud & Office
| Folder | Scripts | Description |
|--------|---------|-------------|
| [`EntraID/`](Microsoft365/EntraID/) | `Start-EntraIDSyncCycle.bat` | Trigger a delta Entra ID (Azure AD) sync |
| | `Update-M365UserPrincipalNames.ps1` | Bulk rename M365 UPNs to FirstInitial+LastName format |
| [`OfficeApps/`](Microsoft365/OfficeApps/) | `Install-Microsoft365Apps.ps1` | Deploy M365 Business Standard apps via ODT |
| | `Get-LatestODTInstaller.ps1` | Download the latest Office Deployment Tool |
| | `Microsoft365-BusinessStandard.xml` | ODT configuration for Business Standard (non-shared) |
| [`AVD/`](Microsoft365/AVD/) | `FSLogix-Redirections.xml` | FSLogix profile redirection config for AVD + Hybrid Entra |

### [`Vendors/`](Vendors/) - Third-Party Product Deployment & Removal
| Folder | Scripts | Description |
|--------|---------|-------------|
| [`BlackpointCyber/`](Vendors/BlackpointCyber/) | `Install-BlackpointAgent.ps1` | Install Blackpoint ZTAC/Snap agent via NinjaOne |
| | `Uninstall-BlackpointAgent.ps1` | Full removal including registry and services |
| [`DUO/`](Vendors/DUO/) | `Set-DUOBypass.ps1` | Add localhost redirect for DUO (fail-open config) |
| [`Egnyte/`](Vendors/Egnyte/) | `Add-EgnyteTrustedSites.ps1` | Add Egnyte to IE Trusted Sites for all user profiles |
| | `Enable-EgnyteOfficeCoEdit.ps1` | Enable Egnyte co-editing in Office apps |
| [`Huntress/`](Vendors/Huntress/) | `Install-HuntressAgent.ps1` | Install Huntress agent from GitHub |
| [`LastPass/`](Vendors/LastPass/) | `Install-LastPass.ps1` | Deploy LastPass with browser extension detection |
| | `Remove-LastPassBrowserExtension.ps1` | Remove LastPass extensions from Chrome/Edge |
| [`NinjaOne/`](Vendors/NinjaOne/) | `Uninstall-NinjaRMMAgent.ps1` | Complete Ninja agent removal (services, registry, drivers) |
| [`ScreenConnect/`](Vendors/ScreenConnect/) | `Uninstall-ScreenConnectAll.ps1` | Remove all ScreenConnect/ConnectWise Control instances |
| | `Uninstall-ScreenConnectSelective.ps1` | Remove ScreenConnect except protected fingerprints |
| [`SentinelOne/`](Vendors/SentinelOne/) | `Install-SentinelOneAgent.ps1` | Install or clean SentinelOne agent (v2.1) |
| [`ThreatLocker/`](Vendors/ThreatLocker/) | `Install-ThreatLocker.ps1` | Deploy ThreatLocker via NinjaOne custom fields |
| [`Timus/`](Vendors/Timus/) | `Install-TimusConnect.ps1` | Install or update Timus Connect client |
| | `New-TimusEntraSSOApp.ps1` | Create Entra ID enterprise app for Timus SSO/Sync |
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
| Scripts | Description |
|---------|-------------|
| `Mount-SysInternals.bat` | Map network drive to live Sysinternals tools |
| `Remove-SysInternals.bat` | Unmount Sysinternals network drive |
| `Send-UserNotification.ps1` | Display a notification message to the user |

---

## Naming Convention

All scripts follow the **PowerShell `Verb-Noun`** naming standard for consistency:

| Verb | Meaning | Example |
|------|---------|---------|
| `Install-` | Deploy an application | `Install-HuntressAgent.ps1` |
| `Uninstall-` | Remove an application | `Uninstall-NinjaRMMAgent.ps1` |
| `Get-` | Retrieve information | `Get-FSMORoles.ps1` |
| `Set-` | Configure a setting | `Set-DUOBypass.ps1` |
| `New-` | Create a resource | `New-DomainAdmin.ps1` |
| `Remove-` | Delete a component | `Remove-LastPassBrowserExtension.ps1` |
| `Invoke-` | Run a multi-step process | `Invoke-WindowsHomeToProUpgrade.ps1` |
| `Start-` | Begin a service/process | `Start-EntraIDSyncCycle.bat` |
| `Update-` | Modify existing resources | `Update-M365UserPrincipalNames.ps1` |
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
