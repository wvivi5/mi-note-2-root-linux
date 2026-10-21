@echo off
rem Measure how often a cold boot fails to decrypt /data.
rem Powers the phone off on purpose, several times, and waits for the RTC alarm
rem to bring it back each time.  Run this on the TEST phone only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fde-test.ps1" %*
pause
