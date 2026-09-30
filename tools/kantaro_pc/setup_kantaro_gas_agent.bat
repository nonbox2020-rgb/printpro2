@echo off
rem ============================================================
rem  Kantaro PC pickup agent (GAS version) - one-click setup
rem  Receives the CSV files that GAS converted (Google Drive
rem  2_kantaro folder) and puts them into the Kantaro csv folder.
rem  Double-click this file. Keep these 3 files in the same folder:
rem    setup_kantaro_gas_agent.bat
rem    setup_kantaro_gas_agent.ps1
rem    kantaro_gas_agent.ps1
rem ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_kantaro_gas_agent.ps1"
