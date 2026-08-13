@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

where python >nul 2>nul
if %errorlevel% equ 0 (
  python "%SCRIPT_DIR%server.py" --open
) else (
  py -3 "%SCRIPT_DIR%server.py" --open
)

pause
