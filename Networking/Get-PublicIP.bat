@echo off
:loop
cls
echo Press any key to stop monitoring...
echo.
echo Current Public IP:
curl -s http://ifconfig.me/ip
timeout /t 5 /nobreak > nul
if not errorlevel 1 goto loop
exit