@echo off
rem One-time setup: generate SSH key and install to server (asks for server password once)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -SetupKey %*
pause
