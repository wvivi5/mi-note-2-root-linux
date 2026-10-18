@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\collect-info.ps1"
if not exist "%S%" set "S=%~dp0collect-info.ps1"
if not exist "%S%" ( echo [!] collect-info.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Step 0: is the phone / the toolchain ready?
echo ------------------------------------------------------------
echo  * lists every attached phone
echo  * reads model / ROM / security patch / uname -r
echo  * verdict: does the kernel match the exploit address table?
echo ============================================================
echo.
%PS% "%S%" %*
echo.
pause
