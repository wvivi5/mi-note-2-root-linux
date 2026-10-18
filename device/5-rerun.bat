@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\rerun.ps1"
if not exist "%S%" set "S=%~dp0rerun.ps1"
if not exist "%S%" ( echo [!] rerun.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Re-run the root chain WITHOUT rebooting
echo ------------------------------------------------------------
echo  Use it after editing the payload scripts, or when a phone
echo  is up but the chain never ran / never finished.
echo  It re-arms the exploit and re-deploys the root payload
echo  (password, sshd, watchdogs) on a running phone.
echo ============================================================
echo.
set /p SN=Phone serial (as shown by "adb devices"): 
if "%SN%"=="" ( echo [!] no serial given - nothing done & pause & exit /b 1 )
%PS% "%S%" -Serial %SN% %*
echo.
pause
