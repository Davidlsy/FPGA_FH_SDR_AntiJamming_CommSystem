@echo off
REM =====================================================================
REM run_channel_check.bat - double-click entry for the S2 channel check
REM
REM The real logic (xvlog/xelab/xsim + python stats check) lives in
REM run_channel_check.ps1. This batch file only:
REM   1) loads the local Vivado 2021.2 environment when xvlog is not on PATH
REM   2) hands over to PowerShell and forwards the exit code
REM
REM Usage: run_channel_check.bat
REM =====================================================================
setlocal
cd /d "%~dp0"

where xvlog >nul 2>&1
if errorlevel 1 (
    if exist "D:\software\vivado2021\Vivado\2021.2\settings64.bat" (
        echo [env] xvlog not on PATH, loading D:\software\vivado2021\Vivado\2021.2\settings64.bat
        call "D:\software\vivado2021\Vivado\2021.2\settings64.bat"
    ) else (
        echo [env] settings64.bat not found, please put xvlog/xelab/xsim on PATH manually
    )
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_channel_check.ps1"
exit /b %errorlevel%
