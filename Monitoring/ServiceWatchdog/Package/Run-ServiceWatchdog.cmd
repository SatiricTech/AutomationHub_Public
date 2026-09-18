@echo off
rem ============================================================================
rem  ServiceWatchdog - drop-and-deploy package
rem  Double-click entry point. Self-elevates (UAC), then launches the WinForms
rem  GUI in Windows PowerShell 5.1 with -STA, which WinForms requires.
rem  The window is kept open on any non-zero exit so the error stays readable.
rem
rem  Path handling: %~dp0 already ends in a backslash, so %PKGDIR%Name.ps1 is
rem  correct and every use is quoted, which is what makes a Downloads, OneDrive
rem  or UNC folder with spaces in its name work. The path is handed to
rem  PowerShell through an environment variable rather than inside a quoted
rem  -Command string, so an apostrophe or an ampersand in it cannot break the
rem  elevation call either.
rem ============================================================================
setlocal EnableExtensions

set "PKGDIR=%~dp0"
set "GUISCRIPT=%PKGDIR%Install-WinServiceWatchdogGui.ps1"
set "SELFCMD=%~f0"

rem The absolute path is used in preference to the PATH entry: powershell.exe is
rem always here on a supported server, and pwsh is never used (the GUI needs
rem Windows PowerShell for WinForms).
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

rem fltmc is the cheapest reliable elevation probe: it fails for standard users
rem and does not depend on the Server service the way "net session" does.
fltmc >nul 2>&1
if errorlevel 1 (
    echo Administrator rights are required. Accept the prompt that follows...
    "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:SELFCMD -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo Elevation was cancelled or failed. Right-click this file and choose
        echo "Run as administrator" instead.
        echo.
        pause
    )
    endlocal
    exit /b 0
)

if not exist "%GUISCRIPT%" (
    echo.
    echo Install-WinServiceWatchdogGui.ps1 was not found next to this launcher:
    echo   %GUISCRIPT%
    echo Copy the whole ServiceWatchdog folder to the server, not just this file.
    echo.
    pause
    endlocal
    exit /b 2
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%GUISCRIPT%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo ServiceWatchdog exited with code %RC%.
    echo Logs: %ProgramData%\ServiceWatchdog\Logs
    echo.
    pause
)

rem endlocal and exit on one line: on separate lines %RC% would be expanded
rem after endlocal had already discarded it, and the launcher would report the
rem wrong exit code to whatever ran it.
endlocal & exit /b %RC%
