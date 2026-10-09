@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set LOG=..\logs
set FAIL=0

call :run_case frame -
if errorlevel 1 set FAIL=1
call :run_case rand BLK_DEINTER_CASE_RAND
if errorlevel 1 set FAIL=1

if "%FAIL%"=="1" (
    echo [blk_deinter] SOME CASES FAILED
    exit /b 1
)
echo [blk_deinter] ALL CASES PASS
exit /b 0

:run_case
rem %1 = case name, %2 = case define ("-" = default frame)
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
set DEF=
if not "%~2"=="-" set DEF=-d %~2
call xvlog -sv %DEF% -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_blk_deinter_compare.sv "%SRC%\blk_deinter.v" > %LOG%\blk_deinter_%~1.xvlog.log 2>&1
if errorlevel 1 (echo [blk_deinter/%~1] XVLOG FAIL & type %LOG%\blk_deinter_%~1.xvlog.log & exit /b 1)
call xelab -relax -timescale 1ns/1ps -snapshot snap_blk_deinter_%~1 -debug typical work.tb_blk_deinter_compare > %LOG%\blk_deinter_%~1.xelab.log 2>&1
if errorlevel 1 (echo [blk_deinter/%~1] XELAB FAIL & type %LOG%\blk_deinter_%~1.xelab.log & exit /b 1)
call xsim snap_blk_deinter_%~1 -runall > %LOG%\blk_deinter_%~1.xsim.log 2>&1
echo ==================== blk_deinter/%~1 ====================
type %LOG%\blk_deinter_%~1.xsim.log
findstr /c:"status=PASS" %LOG%\blk_deinter_%~1.xsim.log >nul
if errorlevel 1 (echo [blk_deinter/%~1] COMPARE FAIL & exit /b 1)
exit /b 0
