@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\logs.ps1"
if not exist "%S%" set "S=%~dp0logs.ps1"
if not exist "%S%" ( echo [!] logs.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Export the diagnostics of a phone into .\logs\
echo ------------------------------------------------------------
echo  Collects boot.log / device-info.txt / p1.log / p2.log over
echo  adb, plus (when 8022 answers) the chroot watchdog log and
echo  the process list.  Useful when something did not come up.
echo ============================================================
echo.
set /p SN=Phone serial (blank = every attached phone): 
if "%SN%"=="" (
    %PS% "%S%" %*
) else (
    %PS% "%S%" -Serials %SN% %*
)
echo.
pause
