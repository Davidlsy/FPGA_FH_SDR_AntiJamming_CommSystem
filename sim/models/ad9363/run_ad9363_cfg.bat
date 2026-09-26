@echo off
REM =====================================================================
REM run_ad9363_cfg.bat - S3 D3: ad9363_cfg + spi_master + model chain test
REM
REM Usage:
REM   run_ad9363_cfg.bat          compile, elaborate, run; PASS/FAIL gate
REM   run_ad9363_cfg.bat gui      open the waveform GUI instead
REM
REM Requires xvlog/xelab/xsim on PATH, e.g. first run once:
REM   call D:\software\vivado2021\Vivado\2021.2\settings64.bat
REM
REM DUT : ..\..\..\src\ad9363_cfg.v  ..\..\..\src\spi_master.v
REM BFM : ad9363_spi_model.sv
REM TB  : tb_ad9363_cfg.sv  (init table: ad9363_init.mem)
REM =====================================================================
setlocal
cd /d "%~dp0"

if /i "%~1"=="gui" (set "GUI=1") else (set "GUI=0")

echo [1/3] xvlog
call xvlog -work work ..\..\..\src\spi_master.v ..\..\..\src\ad9363_cfg.v
if errorlevel 1 goto :fail
call xvlog -sv -work work ad9363_spi_model.sv tb_ad9363_cfg.sv
if errorlevel 1 goto :fail

echo [2/3] xelab
call xelab -relax -timescale 1ns/1ps -snapshot tb_ad9363_cfg -debug typical work.tb_ad9363_cfg
if errorlevel 1 goto :fail

echo [3/3] xsim
if "%GUI%"=="1" (
    call xsim tb_ad9363_cfg -gui -wdb tb_ad9363_cfg.wdb
    exit /b 0
)
call xsim tb_ad9363_cfg -runall > ad9363_cfg_run.log 2>&1
type ad9363_cfg_run.log
findstr /C:"AD9363-CFG PASS" ad9363_cfg_run.log >nul
if errorlevel 1 goto :fail

echo.
echo *** PASS: AD9363-CFG PASS ***
exit /b 0

:fail
echo.
echo *** FAIL: see messages above ^(full log: ad9363_cfg_run.log^) ***
exit /b 1
