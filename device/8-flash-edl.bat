@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\flash_edl.ps1"
if not exist "%S%" set "S=%~dp0flash_edl.ps1"
if not exist "%S%" ( echo [!] flash_edl.ps1 not found & pause & exit /b 1 )
:menu
cls
echo ============================================================
echo  EDL (9008) deep flash  -  unified ROM: MIUI dev 9.8.29
echo ------------------------------------------------------------
echo  Why: the exploit writes to hard-coded kernel addresses of
echo  ONE kernel build (3.18.71-perf-ga01336f).  Flashing every
echo  phone to this one ROM makes all of them identical.
echo.
echo  The bootloader stays LOCKED (EDL needs no unlock), and
echo  partitions like persist / keystore / frp are NOT written,
echo  so IMEI, sensors and keystore survive.
echo.
echo  You must short-circuit the test points to enter 9008.
echo ------------------------------------------------------------
echo   1  list the partitions that would be written (no phone)
echo   2  wait for a 9008 phone, flash it, then reset it
echo   3  a 9008 port is already there - flash it right now
echo   4  loop: flash one phone after another (Ctrl+C stops)
echo   5  exit
echo ============================================================
set /p CH=Choose 1-5: 
if "%CH%"=="1" ( %PS% "%S%" -List & pause & goto menu )
if "%CH%"=="2" ( %PS% "%S%" -Wait -Reset & pause & goto menu )
if "%CH%"=="3" ( %PS% "%S%" -WaitSec 20 -Reset & pause & goto menu )
if "%CH%"=="4" ( %PS% "%S%" -Loop -Reset & goto menu )
if "%CH%"=="5" exit /b 0
pause
goto menu
