@echo off
rem ============================================================================
rem  M365 Migration Workbench - double-click launcher (Start-MigrationWorkbench.cmd)
rem
rem  What this does: locates PowerShell 7 (pwsh.exe) and starts
rem  Start-MigrationWorkbench.ps1 next to this launcher, passing through any
rem  arguments given on the command line (so "Start-MigrationWorkbench.cmd
rem  -Console" works). The console window stays open on a non-zero exit so the
rem  error is readable.
rem
rem  This launcher never elevates. The workbench must run in the signed-in
rem  user's own logon session: interactive account sign-in (WAM) breaks under
rem  "Run as administrator", so no elevation probe or self-elevation exists here.
rem
rem  Requires PowerShell 7.4+. Windows PowerShell 5.1 cannot run this toolkit
rem  and is refused below with an install link instead of a silent fallback.
rem ============================================================================
setlocal EnableExtensions

set "PKGDIR=%~dp0"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (for %%p in (pwsh.exe) do set "PWSH=%%~$PATH:p")

if not defined PWSH (
    echo.
    echo PowerShell 7 is required; Windows PowerShell 5.1 cannot run this toolkit.
    echo Install it from https://aka.ms/install-powershell and run this launcher again.
    echo.
    pause
    endlocal
    exit /b 2
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%PKGDIR%Start-MigrationWorkbench.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo Migration Workbench exited with code %RC%.
    echo Check the log in the Workbench folder inside your workspace, or in
    echo Migration-Automations under your profile.
    echo.
    pause
)

rem endlocal and exit on one line: on separate lines %RC% would be expanded
rem after endlocal had already discarded it, and the launcher would report the
rem wrong exit code to whatever ran it.
endlocal & exit /b %RC%
