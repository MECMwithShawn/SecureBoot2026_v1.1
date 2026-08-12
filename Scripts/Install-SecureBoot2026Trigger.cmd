@echo off
setlocal
set "LogDir=C:\Windows\Temp\SecureBoot2026"
if not exist "%LogDir%" mkdir "%LogDir%"
echo ===== Secure Boot 2026 Trigger Started %DATE% %TIME% ===== >> "%LogDir%\MECM-Trigger.log"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-SecureBoot2026Update.ps1" -RunTask -LogDir "%LogDir%" >> "%LogDir%\MECM-Trigger.log" 2>&1
set "ExitCode=%ERRORLEVEL%"
echo ExitCode=%ExitCode% %DATE% %TIME% >> "%LogDir%\MECM-Trigger.log"
exit /b %ExitCode%
