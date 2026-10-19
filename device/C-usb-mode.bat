@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\usbmode.ps1"
if not exist "%S%" set "S=%~dp0usbmode.ps1"
if not exist "%S%" ( echo [!] usbmode.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  USB role switch (host = OTG network card / peripheral = adb)
echo ------------------------------------------------------------
echo  The helper on the phone re-reads the role every second,
echo  so the switch takes effect within about 1 second.
echo.
echo  1) host        -> the phone is a USB host: an OTG NIC comes up (eth0).
echo                      adb is dead in this role.
echo  2) peripheral  -> the phone is a USB device: adb over USB works.
echo                      No NIC.
echo  3) auto        -> clear manual override; the phone decides itself
echo                      from the charger port and the cable.
echo  4) status      -> show the current role and hardware signals.
echo.
set /p SN=Phone serial (blank if only one is connected):
set /p M=Mode (host/peripheral/auto/status) [status]:
if "%M%"=="" set M=status
if "%SN%"=="" (
    %PS% "%S%" -Mode %M%
) else (
    %PS% "%S%" -Serial %SN% -Mode %M%
)
echo.
pause
