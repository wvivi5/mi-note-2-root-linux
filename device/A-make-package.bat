@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\make-package.ps1"
if not exist "%S%" set "S=%~dp0make-package.ps1"
if not exist "%S%" ( echo [!] make-package.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Rebuild the portable package (dist\mi-note-2-root-linux)
echo ------------------------------------------------------------
echo  Used by the author after changing a script: assembles the
echo  folder again and zips it.  Needs adb somewhere findable.
echo ============================================================
echo.
%PS% "%S%" %*
echo.
pause
