@echo off
setlocal
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "S=%~dp0device\publish.ps1"
if not exist "%S%" set "S=%~dp0publish.ps1"
if not exist "%S%" ( echo [!] publish.ps1 not found & pause & exit /b 1 )
echo.
echo ============================================================
echo  Publish this repo to GitHub (via the REST API)
echo ------------------------------------------------------------
echo  Use this when "git push" fails with
echo      unable to access ... Empty reply from server
echo  (github.com:443 blocked, api.github.com still fine).
echo.
echo  It commits everything, uploads the objects through the API,
echo  force-moves main onto the new commit, then verifies that
echo  every remote blob sha equals the local one.
echo.
echo  Optional:  B-publish.bat -Message "what changed"
echo ============================================================
echo.
%PS% "%S%" %*
echo.
pause
