@echo off
rem Arcane-Front relay server one-click deploy (double-click or run from CLI)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
pause
