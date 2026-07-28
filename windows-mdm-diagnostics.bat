@echo off
setlocal
echo Running read-only Windows MDM diagnostics...
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-mdm-diagnostics.ps1"
echo.
pause
endlocal
