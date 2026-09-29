@echo off
rem ============================================================
rem  Kantaro PC pickup agent - one-click setup
rem  Double-click this file. Keep these 3 files in the same folder:
rem    setup_kantaro_agent.bat
rem    kantaro_agent_installer.ps1
rem    kantaro_agent.ps1
rem ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0kantaro_agent_installer.ps1"
