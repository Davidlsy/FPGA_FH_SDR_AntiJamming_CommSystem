@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set LOG=..\logs
set FAIL=0

call :run_case seq -
if errorlevel 1 set FAIL=1
call :run_case rand TOD_CASE_RAND
if errorlevel 1 set FAIL=1
call :run_case edge TOD_CASE_EDGE
if errorlevel 1 set FAIL=1

call :run_long
if errorlevel 1 set FAIL=1

if "%FAIL%"=="1" (
    echo [tod] SOME CASES FAILED
    exit /b 1
)
echo [tod] ALL CASES PASS
exit /b 0

:run_case
rem %1 = case name, %2 = case define ("-" = default seq)
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
set DEF=
if not "%~2"=="-" set DEF=-d %~2
call xvlog --nolog -sv %DEF% -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_tod_compare.sv "%SRC%\tod.v" > %LOG%\tod_%~1.xvlog.log 2>&1
if errorlevel 1 (echo [tod/%~1] XVLOG FAIL & type %LOG%\tod_%~1.xvlog.log & exit /b 1)
call xelab --nolog -relax -timescale 1ns/1ps -snapshot snap_tod_%~1 -debug typical work.tb_tod_compare > %LOG%\tod_%~1.xelab.log 2>&1
if errorlevel 1 (echo [tod/%~1] XELAB FAIL & type %LOG%\tod_%~1.xelab.log & exit /b 1)
call xsim --nolog snap_tod_%~1 -runall > %LOG%\tod_%~1.xsim.log 2>&1
echo ==================== tod/%~1 ====================
type %LOG%\tod_%~1.xsim.log
findstr /c:"status=PASS" %LOG%\tod_%~1.xsim.log >nul
if errorlevel 1 (echo [tod/%~1] COMPARE FAIL & exit /b 1)
exit /b 0

:run_long
rem 7 phases self-stimulated: align_err + hop_grid x 3 rates + 40-tick extrapolation
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog --nolog -sv -i "%SRC%" -work work tb\tb_tod_align_long.sv "%SRC%\tod.v" "%SRC%\fh_ctrl.v" > %LOG%\tod_long.xvlog.log 2>&1
if errorlevel 1 (echo [tod/long] XVLOG FAIL & type %LOG%\tod_long.xvlog.log & exit /b 1)
call xelab --nolog -relax -timescale 1ns/1ps -snapshot snap_tod_long -debug typical work.tb_tod_align_long > %LOG%\tod_long.xelab.log 2>&1
if errorlevel 1 (echo [tod/long] XELAB FAIL & type %LOG%\tod_long.xelab.log & exit /b 1)
call xsim --nolog snap_tod_long -runall > %LOG%\tod_long.xsim.log 2>&1
echo ==================== tod/long ====================
type %LOG%\tod_long.xsim.log
findstr /c:"status=PASS" %LOG%\tod_long.xsim.log >nul
if errorlevel 1 (echo [tod/long] LONG FAIL & exit /b 1)
exit /b 0
