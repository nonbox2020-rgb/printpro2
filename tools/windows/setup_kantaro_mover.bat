@echo off
rem ============================================================
rem  Kantaro mover (Windows) - one-click setup
rem  Moves the CSV files that GAS puts in Google Drive
rem  (sanei CSV folder \ 2_kantaro) into the Kantaro folder.
rem  Double-click this file. Keep these 3 files in the same folder:
rem    setup_kantaro_mover.bat
rem    setup_kantaro_mover.ps1
rem    kantaro_mover.ps1
rem ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_kantaro_mover.ps1"
