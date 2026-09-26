@echo off
REM =====================================================================
REM run_spi_master_rand.bat - S3 D2: spi_master randomized + fault injection
REM
REM Usage:
REM   run_spi_master_rand.bat          compile, elaborate, run; PASS/FAIL gate
REM   run_spi_master_rand.bat gui      open the waveform GUI instead
REM
REM Requires xvlog/xelab/xsim on PATH, e.g. first run once:
REM   call D:\software\vivado2021\Vivado\2021.2\settings64.bat
REM
REM DUT : ..\..\..\src\spi_master.v
REM BFM : ad9363_spi_model.sv, spi_slave_gen.sv
REM TB  : tb_spi_master_rand.sv
REM =====================================================================
setlocal
cd /d "%~dp0"

if /i "%~1"=="gui" (set "GUI=1") else (set "GUI=0")

echo [1/3] xvlog
call xvlog -work work ..\..\..\src\spi_master.v
if errorlevel 1 goto :fail
call xvlog -sv -work work ad9363_spi_model.sv spi_slave_gen.sv tb_spi_master_rand.sv
if errorlevel 1 goto :fail

echo [2/3] xelab
call xelab -relax -timescale 1ns/1ps -snapshot tb_spi_master_rand -debug typical work.tb_spi_master_rand
if errorlevel 1 goto :fail

echo [3/3] xsim
if "%GUI%"=="1" (
    call xsim tb_spi_master_rand -gui -wdb tb_spi_master_rand.wdb
    exit /b 0
)
call xsim tb_spi_master_rand -runall > spi_master_rand.log 2>&1
type spi_master_rand.log
findstr /C:"SPI-MASTER RAND PASS" spi_master_rand.log >nul
if errorlevel 1 goto :fail

echo.
echo *** PASS: SPI-MASTER RAND PASS ***
exit /b 0

:fail
echo.
echo *** FAIL: see messages above ^(full log: spi_master_rand.log^) ***
exit /b 1
