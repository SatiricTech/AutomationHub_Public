# Azure Functions profile.ps1 for the ServiceWatchdog function app.
#
# This file runs once per worker instance on cold start (DESIGN.md section 6.1). It is
# intentionally minimal: the app ships no Az modules and never calls Connect-AzAccount.
# The Core Tools default profile would call Connect-AzAccount -Identity whenever MSI_SECRET
# is set, which throws on every cold start when Az.Accounts is not present, so that block
# is deliberately absent. Storage is reached through the Table REST API with a token from
# the managed-identity endpoint inside the ServiceWatchdogAlert module, and the module is
# auto-loaded from the Modules folder on first use, so nothing needs to happen here.
