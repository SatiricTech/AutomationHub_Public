# Managed dependencies for the ServiceWatchdog function app.
#
# Intentionally empty (DESIGN.md section 6.1): host.json disables managed dependencies and
# the only module the app uses, ServiceWatchdogAlert, is bundled under Modules/. Nothing is
# downloaded from the PowerShell Gallery at cold start.
@{
}
