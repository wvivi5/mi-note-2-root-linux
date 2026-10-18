@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\collect-info.ps1"
if not exist "%S%" set "S=%~dp0collect-info.ps1"
if not exist "%S%" ( echo [!] collect-info.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Kernel health check  (run this BEFORE arming a phone)
echo ------------------------------------------------------------
echo  OK    - matches the exploit address table, safe to arm
echo  NEEDS NEW OFFSETS - do NOT arm, flash the unified ROM first
echo ============================================================
echo.
%PS% "%S%" %*
echo.
pause
