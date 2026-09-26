@echo off
REM =====================================================================
REM run_spi_master.bat - S3 spi_master RTL smoke test (xvlog/xelab/xsim)
REM
REM Usage:
REM   run_spi_master.bat          compile, elaborate, run; PASS/FAIL gate
REM   run_spi_master.bat gui      open the waveform GUI instead
REM
REM Requires xvlog/xelab/xsim on PATH, e.g. first run once:
REM   call D:\software\vivado2021\Vivado\2021.2\settings64.bat
REM
REM DUT : ..\..\..\src\spi_master.v        (Verilog-2001 RTL for synthesis)
REM BFM : ad9363_spi_model.sv           (S2 AD9363 behavioral model)
REM TB  : tb_spi_master.sv              (S3 smoke cases T1-T7 + audit)
REM =====================================================================
setlocal
cd /d "%~dp0"

if /i "%~1"=="gui" (set "GUI=1") else (set "GUI=0")

echo [1/3] xvlog
call xvlog -work work ..\..\..\src\spi_master.v
if errorlevel 1 goto :fail
call xvlog -sv -work work ad9363_spi_model.sv tb_spi_master.sv
if errorlevel 1 goto :fail

echo [2/3] xelab
call xelab -relax -timescale 1ns/1ps -snapshot tb_spi_master -debug typical work.tb_spi_master
if errorlevel 1 goto :fail

echo [3/3] xsim
if "%GUI%"=="1" (
    call xsim tb_spi_master -gui -wdb tb_spi_master.wdb
    exit /b 0
)
call xsim tb_spi_master -runall > spi_master_run.log 2>&1
type spi_master_run.log
findstr /C:"SPI-MASTER SMOKE PASS" spi_master_run.log >nul
if errorlevel 1 goto :fail

echo.
echo *** PASS: SPI-MASTER SMOKE PASS ***
exit /b 0

:fail
echo.
echo *** FAIL: see messages above ^(full log: spi_master_run.log^) ***
exit /b 1
