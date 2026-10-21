@echo off
rem One-click undo for the MIUI debloat pass (see restore-debloat.ps1).
rem Plug the phone in over USB first; keeps this folder and double-click it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-debloat.ps1" %*
pause
