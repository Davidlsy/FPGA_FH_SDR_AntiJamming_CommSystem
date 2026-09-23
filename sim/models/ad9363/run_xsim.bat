@echo off
REM =====================================================================
REM run_xsim.bat - Vivado xsim build + run for the AD9363 SPI model
REM
REM Usage:
REM   run_xsim.bat          compile, elaborate, run; PASS/FAIL gate on log
REM   run_xsim.bat gui      open the waveform GUI instead of a batch run
REM
REM Requires xvlog/xelab/xsim on PATH, e.g. first run once:
REM   call D:\software\vivado2021\Vivado\2021.2\settings64.bat
REM =====================================================================
setlocal
cd /d "%~dp0"

if /i "%~1"=="gui" (set "GUI=1") else (set "GUI=0")

echo [1/3] xvlog
call xvlog -sv -work work ad9363_spi_model.sv tb_ad9363_spi_model.sv
if errorlevel 1 goto :fail

echo [2/3] xelab
call xelab -relax -timescale 1ns/1ps -snapshot tb_snap -debug typical work.tb_ad9363_spi_model
if errorlevel 1 goto :fail

echo [3/3] xsim
if "%GUI%"=="1" (
    call xsim tb_snap -gui -wdb tb_ad9363_spi_model.wdb
    exit /b 0
)
call xsim tb_snap -runall > sim_run.log 2>&1
type sim_run.log
findstr /C:"ALL TESTS PASSED" sim_run.log >nul
if errorlevel 1 goto :fail

echo.
echo *** PASS: RESULT : *** ALL TESTS PASSED ***
exit /b 0

:fail
echo.
echo *** FAIL: see messages above ^(full log: sim_run.log^) ***
exit /b 1
