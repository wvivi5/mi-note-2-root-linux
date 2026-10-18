@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\provision.ps1"
if not exist "%S%" set "S=%~dp0provision.ps1"
if not exist "%S%" ( echo [!] provision.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Provision ONE phone: root + Ubuntu chroot + ssh 8022
echo ------------------------------------------------------------
echo  Requirements:
echo    * USB debugging enabled and AUTHORIZED (unlock the screen,
echo      tick "always allow" on the RSA prompt)
echo    * screen stays unlocked: an APK install dialog pops up twice
echo      and has to be tapped "install" (the script taps it for you)
echo  Takes 5-15 minutes.  Extra args are passed through, e.g.
echo     2-provision-one.bat -SkipApkInstall
echo     2-provision-one.bat -VerifyOnly
echo     2-provision-one.bat -ForceKernel    ^(do not use unless told^)
echo ============================================================
echo.
set /p SN=Phone serial (as shown by "adb devices"): 
if "%SN%"=="" ( echo [!] no serial given - nothing done & pause & exit /b 1 )
%PS% "%S%" -Serial %SN% %*
echo.
pause
