@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy_enet.ps1" %*
pause
