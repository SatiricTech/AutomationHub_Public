REM Description: Small helper script to quickly start an AADSync by double-clicking on this script file.
REM Author: Ramon DeWitt - Via ChatGPT

echo Starting AD Sync (Delta)...
powershell.exe -ex bypass -command "Import-Module ADSync; Start-ADSyncSyncCycle -PolicyType Delta;"