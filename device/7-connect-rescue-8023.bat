@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\connect.ps1"
if not exist "%S%" set "S=%~dp0connect.ps1"
if not exist "%S%" ( echo [!] connect.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Open the rescue shell (port 8023, Termux, unprivileged)
echo ------------------------------------------------------------
echo  This is the fallback channel when the Linux root channel
echo  (8022) is down but Termux is alive: you land inside Termux
echo  as the app user, and from there you can look around, fix
echo  files, or restart the root chain.
echo.
echo  It needs Termux openssh, which the deployment installs while
echo  the phone has network once.
echo ============================================================
echo.
set /p SN=Phone serial (blank if only one is connected): 
if "%SN%"=="" (
    %PS% "%S%" -Port 8023 %*
) else (
    %PS% "%S%" -Serial %SN% -Port 8023 %*
)
echo.
pause
