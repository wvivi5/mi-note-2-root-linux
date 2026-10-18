@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\connect.ps1"
if not exist "%S%" set "S=%~dp0connect.ps1"
if not exist "%S%" ( echo [!] connect.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Open a root shell (port 8022)
echo ------------------------------------------------------------
echo  The script picks the path by itself, in this order:
echo     1. the phone's own wifi / usb-ethernet address
echo     2. adb forward over plain USB (no networking needed)
echo  So it also works on phones whose wifi is broken.
echo.
echo  Leave the serial blank if exactly one phone is plugged in.
echo  Type "exit" to come back here.
echo ============================================================
echo.
set /p SN=Phone serial (blank if only one is connected): 
if "%SN%"=="" (
    %PS% "%S%" %*
) else (
    %PS% "%S%" -Serial %SN% %*
)
echo.
pause
