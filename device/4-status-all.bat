@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\status-all.ps1"
if not exist "%S%" set "S=%~dp0status-all.ps1"
if not exist "%S%" ( echo [!] status-all.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Fleet checkup over the network (no USB needed)
echo ------------------------------------------------------------
echo  Enter the addresses to sweep, for example
echo      192.168.68.180-199        ^(a range^)
echo      192.168.68.185,186        ^(single ones^)
echo  Leave blank to have each attached phone report its own
echo  address over adb (plug one in first).
echo.
echo  Each phone is reported for 8022 (Linux root ssh) and
echo  8023 (Termux rescue ssh).  Add  -Deep  to also log in.
echo ============================================================
echo.
set /p RG=Range or IPs: 
if "%RG%"=="" (
    %PS% "%S%" -Deep %*
) else (
    echo.
    echo [i] using "%RG%"
    %PS% "%S%" -Range %RG% -Deep %*
)
echo.
pause
