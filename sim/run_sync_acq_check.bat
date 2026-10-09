@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set LOG=..\logs
set FAIL=0

call :run_case seq -
if errorlevel 1 set FAIL=1
call :run_case rand SYNC_ACQ_CASE_RAND
if errorlevel 1 set FAIL=1
call :run_case edge SYNC_ACQ_CASE_EDGE
if errorlevel 1 set FAIL=1

call :run_long
if errorlevel 1 set FAIL=1

if "%FAIL%"=="1" (
    echo [sync_acq] SOME CASES FAILED
    exit /b 1
)
echo [sync_acq] ALL CASES PASS
exit /b 0

:run_case
rem %1 = case name, %2 = case define ("-" = default seq)
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
set DEF=
if not "%~2"=="-" set DEF=-d %~2
call xvlog -sv %DEF% -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_sync_acq_compare.sv "%SRC%\sync_acq.v" > %LOG%\sync_acq_%~1.xvlog.log 2>&1
if errorlevel 1 (echo [sync_acq/%~1] XVLOG FAIL & type %LOG%\sync_acq_%~1.xvlog.log & exit /b 1)
call xelab -relax -timescale 1ns/1ps -snapshot snap_sync_acq_%~1 -debug typical work.tb_sync_acq_compare > %LOG%\sync_acq_%~1.xelab.log 2>&1
if errorlevel 1 (echo [sync_acq/%~1] XELAB FAIL & type %LOG%\sync_acq_%~1.xelab.log & exit /b 1)
call xsim snap_sync_acq_%~1 -runall > %LOG%\sync_acq_%~1.xsim.log 2>&1
echo ==================== sync_acq/%~1 ====================
type %LOG%\sync_acq_%~1.xsim.log
findstr /c:"status=PASS" %LOG%\sync_acq_%~1.xsim.log >nul
if errorlevel 1 (echo [sync_acq/%~1] COMPARE FAIL & exit /b 1)
exit /b 0

:run_long
rem frozen params (FRAME_LEN=2160/M=2/N=3): noise silence + acq delay + frame_start align
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog -sv -i "%SRC%" -work work tb\tb_sync_acq_long.sv "%SRC%\sync_acq.v" > %LOG%\sync_acq_long.xvlog.log 2>&1
if errorlevel 1 (echo [sync_acq/long] XVLOG FAIL & type %LOG%\sync_acq_long.xvlog.log & exit /b 1)
call xelab -relax -timescale 1ns/1ps -snapshot snap_sync_acq_long -debug typical work.tb_sync_acq_long > %LOG%\sync_acq_long.xelab.log 2>&1
if errorlevel 1 (echo [sync_acq/long] XELAB FAIL & type %LOG%\sync_acq_long.xelab.log & exit /b 1)
call xsim snap_sync_acq_long -runall > %LOG%\sync_acq_long.xsim.log 2>&1
echo ==================== sync_acq/long ====================
type %LOG%\sync_acq_long.xsim.log
findstr /c:"status=PASS" %LOG%\sync_acq_long.xsim.log >nul
if errorlevel 1 (echo [sync_acq/long] LONG FAIL & exit /b 1)
exit /b 0
