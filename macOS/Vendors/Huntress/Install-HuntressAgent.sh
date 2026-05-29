#!/bin/bash

# Install-HuntressAgent.sh
# Deploys the Huntress macOS Agent from an RMM (built/tested for NinjaOne, runs as root).
#
# This is a WRAPPER around Huntress's official generic installer. It adds:
#   1. MDM-enrollment detection, and branches the install accordingly.
#   2. Best-effort handling of the macOS permissions Huntress needs
#      (Full Disk Access, System Extension, Network Content Filter).
#   3. NinjaOne-friendly logging and exit codes.
#
# ----------------------------------------------------------------------------
# READ THIS FIRST -- what is and isn't possible without MDM
# ----------------------------------------------------------------------------
# On macOS Ventura 13+ the three approvals Huntress needs for full EDR/Host
# Isolation are gated by Apple's TCC / system-extension security model. Running
# as root does NOT bypass them:
#
#   * Full Disk Access (PPPC)   -> ONLY grantable silently via an MDM-delivered
#                                  profile on an enrolled device. The TCC db is
#                                  SIP-protected; no script can write it.
#   * System Extension approval -> Auto-approval needs the MDM profile. Else the
#                                  user must approve in System Settings.
#   * Network Content Filter    -> Same. Auto-approval needs the MDM profile.
#
# Also: since macOS 11, `profiles install` from the command line is DEAD. A
# .mobileconfig can only arrive via MDM, or be installed manually by a logged-in
# user (and even then the FDA/sysext payloads are ignored unless MDM-managed).
#
# THEREFORE:
#   * MDM-enrolled Mac (with the Huntress profile deployed) -> fully silent.
#   * Non-MDM Mac -> agent installs silently and reports to the portal, but the
#     three approvals REQUIRE a human. This script launches the Huntress
#     Configuration Wizard in the logged-in user's session to guide them through
#     it. If no one is logged in, the approvals stay pending until someone is.
#
# Huntress MDM profile (deploy this via your MDM for silent installs):
#   https://raw.githubusercontent.com/huntresslabs/deployment-scripts/refs/heads/main/Bash/mac/HuntressSystemExtensionProfile.mobileconfig
# Reference:
#   https://support.huntress.io/hc/en-us/articles/25013857741331
# ============================================================================


##############################################################################
## Begin user-modified variables
##############################################################################

# Your Huntress Account Key (32-char hex from the portal's "Add Agent" page).
# Leave as-is to require it be passed by NinjaOne (env var or -a flag).
defaultAccountKey="__ACCOUNT_KEY__"

# Organization Key. NinjaOne can override this per-org. A placeholder is fine.
defaultOrgKey="Mac Agents"

# Shows up in Huntress support tooling so they know which RMM deployed the agent.
rmm="NinjaOne"

# Optional comma-separated agent tags (e.g. "workstation,sales").
defaultTags=""

##############################################################################
## Do not modify below this line
##############################################################################

scriptVersion="2026.05.29"

huntressInstallerUrl="https://raw.githubusercontent.com/huntresslabs/deployment-scripts/refs/heads/main/Bash/mac/InstallHuntress-macOS-bash.sh"
huntressProfileUrl="https://raw.githubusercontent.com/huntresslabs/deployment-scripts/refs/heads/main/Bash/mac/HuntressSystemExtensionProfile.mobileconfig"

huntressApp="/Applications/Huntress.app"
huntressBin="${huntressApp}/Contents/MacOS/Huntress"

workDir="/Users/Shared/Huntress"
wrapperInstaller="/tmp/InstallHuntress-macOS-bash.sh"
stagedProfile="${workDir}/HuntressSystemExtensionProfile.mobileconfig"
logFile="${workDir}/HuntressDeploy.log"

keyPattern="[a-f0-9]{32}"

# ---------------------------------------------------------------------------
# Logging -- echoes to stdout (so NinjaOne captures it) and appends to logFile.
# ---------------------------------------------------------------------------
logger() {
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")
    echo "${ts} -- $*"
    [ -d "$workDir" ] && echo "${ts} -- $*" >> "$logFile"
}

# ---------------------------------------------------------------------------
# Resolve config: precedence is CLI flag > NinjaOne env var > hardcoded default.
# NinjaOne exposes script variables as env vars; we accept a few common names.
# ---------------------------------------------------------------------------
accountKey=""
organizationKey=""
tags=""

# NinjaOne / environment overrides
[ -n "$accountKey_env" ]      && accountKey="$accountKey_env"
[ -n "$HUNTRESS_ACCOUNT_KEY" ] && accountKey="$HUNTRESS_ACCOUNT_KEY"
[ -n "$organizationKey_env" ] && organizationKey="$organizationKey_env"
[ -n "$HUNTRESS_ORG_KEY" ]     && organizationKey="$HUNTRESS_ORG_KEY"
[ -n "$tags_env" ]            && tags="$tags_env"
[ -n "$HUNTRESS_TAGS" ]        && tags="$HUNTRESS_TAGS"

# CLI flags (override env). -a account, -o org, -t tags.
while getopts "a:o:t:h" opt; do
    case "$opt" in
        a) accountKey="${OPTARG#=}" ;;
        o) organizationKey="${OPTARG#=}" ;;
        t) tags="${OPTARG#=}" ;;
        h)
            echo "Usage: $0 -a <account_key> [-o <org_key>] [-t <tags>]"
            exit 0
            ;;
        *) ;;
    esac
done

# Fall back to hardcoded defaults.
[ -z "$accountKey" ]      && accountKey="$defaultAccountKey"
[ -z "$organizationKey" ] && organizationKey="$defaultOrgKey"
[ -z "$tags" ]            && tags="$defaultTags"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root. Exiting."
    exit 1
fi

mkdir -p "$workDir"
chmod 755 "$workDir"

logger "=========== Huntress macOS deploy wrapper v${scriptVersion} (${rmm}) ==========="
logger "macOS version: $(sw_vers -productVersion)"

# Validate the account key now so we fail fast with a useful message.
accountKey=$(echo "$accountKey" | tr -d '[:space:]')
if ! [[ "$accountKey" =~ $keyPattern ]]; then
    logger "ERROR: A valid 32-char hex Account Key is required."
    logger "       Provide it via NinjaOne (HUNTRESS_ACCOUNT_KEY), the -a flag, or defaultAccountKey."
    exit 1
fi
organizationKey=$(echo "$organizationKey" | tr -dc '[:alnum:]- ' | tr ' ' '-' | xargs)
maskedKey="${accountKey:0:4}************************${accountKey: -4}"
logger "Account Key: ${maskedKey} | Org Key: ${organizationKey} | Tags: ${tags:-<none>}"

# ---------------------------------------------------------------------------
# Detect the console (GUI) user. Needed to launch the Wizard on non-MDM Macs.
# Returns empty if no one is logged into the GUI (e.g. login window / SSH only).
# ---------------------------------------------------------------------------
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
if [ "$consoleUser" = "root" ] || [ -z "$consoleUser" ]; then
    consoleUser=""
    consoleUID=""
    logger "No GUI user is currently logged in."
else
    consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
    logger "Console user: ${consoleUser} (uid ${consoleUID})"
fi

# ---------------------------------------------------------------------------
# Detect MDM enrollment. We treat "MDM enrollment: Yes" as managed.
# ---------------------------------------------------------------------------
mdmManaged=false
enrollmentStatus=$(profiles status -type enrollment 2>/dev/null)
logger "Enrollment status: $(echo "$enrollmentStatus" | tr '\n' ' ')"
if echo "$enrollmentStatus" | grep -qi "MDM enrollment: Yes"; then
    mdmManaged=true
    logger "Device IS MDM-enrolled -> expecting the Huntress profile to grant permissions silently."
else
    logger "Device is NOT MDM-enrolled -> approvals will require the Configuration Wizard + a logged-in user."
fi

# ---------------------------------------------------------------------------
# Download Huntress's official installer wrapper.
# ---------------------------------------------------------------------------
logger "Downloading Huntress installer wrapper..."
if ! curl -fsSL "$huntressInstallerUrl" -o "$wrapperInstaller"; then
    logger "ERROR: Failed to download the Huntress installer from ${huntressInstallerUrl}"
    exit 1
fi
chmod +x "$wrapperInstaller"

# ---------------------------------------------------------------------------
# Run the installer.
#   * MDM-managed  -> pass --install_system_extension so the sysext installs
#                     silently (the deployed profile pre-approves it + FDA).
#   * Non-MDM      -> do NOT auto-install the sysext here; the Wizard installs
#                     it and guides the user through approval (Huntress's
#                     supported RMM flow). Avoids a surprise system prompt.
# ---------------------------------------------------------------------------
installArgs=(-a "$accountKey" -o "$organizationKey")
[ -n "$tags" ] && installArgs+=(-t "$tags")
if [ "$mdmManaged" = true ]; then
    installArgs+=(--install_system_extension)
fi

logger "Running Huntress installer (system extension auto-install: ${mdmManaged})..."
installOutput=$(/bin/bash "$wrapperInstaller" "${installArgs[@]}" 2>&1)
installRc=$?
logger "----- Huntress installer output -----"
logger "$installOutput"
logger "----- end installer output -----"

if [ $installRc -ne 0 ]; then
    # The installer exits 1 if the agent is ALREADY present (not a real failure).
    if echo "$installOutput" | grep -qi "already"; then
        logger "Agent already present; continuing to permission handling."
    else
        logger "ERROR: Huntress installer exited ${installRc}. See output above."
        exit 1
    fi
fi

# Confirm the app landed.
if [ ! -d "$huntressApp" ]; then
    logger "ERROR: ${huntressApp} not found after install. Aborting."
    exit 1
fi
logger "Huntress agent is installed at ${huntressApp}."

# ---------------------------------------------------------------------------
# Permission handling
# ---------------------------------------------------------------------------
if [ "$mdmManaged" = true ]; then
    logger "MDM-managed: relying on the deployed Huntress profile for FDA + sysext + content filter."
    logger "If approvals are missing, confirm the Huntress mobileconfig is assigned to this device in your MDM."
else
    # Stage the MDM profile locally for reference / manual install by a tech.
    logger "Staging Huntress mobileconfig to ${stagedProfile} (reference only -- manual install does NOT grant FDA without MDM)."
    curl -fsSL "$huntressProfileUrl" -o "$stagedProfile" 2>/dev/null \
        && logger "Profile staged." \
        || logger "WARN: could not download the profile for staging."

    if [ -n "$consoleUID" ]; then
        # Launch the Configuration Wizard in the user's GUI session. This installs
        # the system extension and walks the user through FDA + content filter.
        logger "Launching the Huntress Configuration Wizard for ${consoleUser}..."
        /bin/launchctl asuser "$consoleUID" /usr/bin/open -a "$huntressApp" \
            && logger "Wizard launched. The user must step through the approval prompts." \
            || logger "WARN: failed to launch the Wizard for ${consoleUser}."
    else
        logger "No GUI user logged in -- cannot launch the Configuration Wizard now."
        logger "ACTION REQUIRED: the agent is installed and reporting, but FDA / system extension /"
        logger "content filter remain UNAPPROVED until a user logs in and runs the Wizard:"
        logger "    open -a \"${huntressApp}\""
        logger "(Or enroll this Mac in MDM and deploy the Huntress profile for a fully silent setup.)"
    fi
fi

# ---------------------------------------------------------------------------
# Report current readiness (best-effort; available on agent 0.14.26+).
# ---------------------------------------------------------------------------
if [ -x "$huntressBin" ]; then
    logger "----- Huntress status -----"
    statusOutput=$("$huntressBin" status 2>&1) || statusOutput=$("$huntressBin" extensionctl status 2>&1)
    logger "$statusOutput"
    logger "----- end status -----"
fi

logger "=========== Huntress deploy wrapper finished ==========="
logger "Full log: ${logFile}"
exit 0
