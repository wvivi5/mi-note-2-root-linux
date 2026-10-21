@echo off
rem Apply a debloat batch to the phone, reboot, and verify it survived.
rem See debloat.ps1 for the reasoning behind each safety check.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0debloat.ps1" %*
if errorlevel 1 (
  echo.
  echo [!] a batch failed or was rolled back - read the output above
  echo     undo everything at once with restore-debloat.bat
)
pause
