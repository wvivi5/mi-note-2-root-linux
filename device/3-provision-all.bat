@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\provision-all.ps1"
if not exist "%S%" set "S=%~dp0provision-all.ps1"
if not exist "%S%" ( echo [!] provision-all.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Provision EVERY attached phone, one after another
echo ------------------------------------------------------------
echo  Only ONE phone can be plugged in at a time.  The script
echo  flashes/installs on each phone it sees, then waits for the
echo  next one (plug it in when asked).
echo.
echo  Do a single phone first (2-provision-one.bat) and confirm it
echo  really works before running this on the rest.
echo.
echo  Extra args are passed through, e.g.
echo     3-provision-all.bat -ExtraArgs -SkipApkInstall
echo ============================================================
echo.
%PS% "%S%" %*
echo.
pause
