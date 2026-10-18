# ============================================================
#  This file moved.  The maintained version is:
#
#      device\flash_edl.ps1        (or just double-click 8-flash-edl.bat)
#
#  It is the same EDL/9008 deep-flash flow, but with parameters instead of
#  hard-coded paths:
#
#      -List                  show what would be written (no phone needed)
#      -Wait / -Loop          wait for a 9008 port / flash one phone after another
#      -Images <dir>          raw images (rawprogram0.xml + patch0.xml + *.img + firehose .elf)
#      -Tools  <dir>          MiFlash dir with fh_loader.exe and QSaharaServer.exe
#      -ComPort COM3          pin the port
#
#  This shim only forwards, so old notes that say "flash_edl.ps1" keep working.
# ============================================================
& (Join-Path $PSScriptRoot 'device\flash_edl.ps1') @args
exit $LASTEXITCODE
