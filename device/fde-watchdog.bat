@echo off
rem Watch phones over USB and reboot the ones stuck before /data decryption.
rem Leave this running on the site PC so a power cut that lands on the password
rem screen fixes itself instead of waiting for someone to notice.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fde-watchdog.ps1" %*
pause
