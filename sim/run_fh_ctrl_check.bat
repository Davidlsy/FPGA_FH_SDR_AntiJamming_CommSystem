@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set LOG=..\logs
set FAIL=0

call :run_case seq -
if errorlevel 1 set FAIL=1
call :run_case rand FH_CTRL_CASE_RAND
if errorlevel 1 set FAIL=1
call :run_case edge FH_CTRL_CASE_EDGE
if errorlevel 1 set FAIL=1

call :run_long
if errorlevel 1 set FAIL=1

if "%FAIL%"=="1" (
    echo [fh_ctrl] SOME CASES FAILED
    exit /b 1
)
echo [fh_ctrl] ALL CASES PASS
exit /b 0

:run_case
rem %1 = case name, %2 = case define ("-" = default seq)
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
set DEF=
if not "%~2"=="-" set DEF=-d %~2
call xvlog -sv %DEF% -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_fh_ctrl_compare.sv "%SRC%\fh_ctrl.v" > %LOG%\fh_ctrl_%~1.xvlog.log 2>&1
if errorlevel 1 (echo [fh_ctrl/%~1] XVLOG FAIL & type %LOG%\fh_ctrl_%~1.xvlog.log & exit /b 1)
call xelab -relax -timescale 1ns/1ps -snapshot snap_fh_ctrl_%~1 -debug typical work.tb_fh_ctrl_compare > %LOG%\fh_ctrl_%~1.xelab.log 2>&1
if errorlevel 1 (echo [fh_ctrl/%~1] XELAB FAIL & type %LOG%\fh_ctrl_%~1.xelab.log & exit /b 1)
call xsim snap_fh_ctrl_%~1 -runall > %LOG%\fh_ctrl_%~1.xsim.log 2>&1
echo ==================== fh_ctrl/%~1 ====================
type %LOG%\fh_ctrl_%~1.xsim.log
findstr /c:"status=PASS" %LOG%\fh_ctrl_%~1.xsim.log >nul
if errorlevel 1 (echo [fh_ctrl/%~1] COMPARE FAIL & exit /b 1)
exit /b 0

:run_long
rem 1e6 hop TX/RX cross-check + dwell uniformity (self-stimulated, no vectors)
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog -sv -i "%SRC%" -work work tb\tb_fh_ctrl_long.sv "%SRC%\fh_ctrl.v" > %LOG%\fh_ctrl_long.xvlog.log 2>&1
if errorlevel 1 (echo [fh_ctrl/long] XVLOG FAIL & type %LOG%\fh_ctrl_long.xvlog.log & exit /b 1)
call xelab -relax -timescale 1ns/1ps -snapshot snap_fh_ctrl_long -debug typical work.tb_fh_ctrl_long > %LOG%\fh_ctrl_long.xelab.log 2>&1
if errorlevel 1 (echo [fh_ctrl/long] XELAB FAIL & type %LOG%\fh_ctrl_long.xelab.log & exit /b 1)
call xsim snap_fh_ctrl_long -runall > %LOG%\fh_ctrl_long.xsim.log 2>&1
echo ==================== fh_ctrl/long ====================
type %LOG%\fh_ctrl_long.xsim.log
findstr /c:"status=PASS" %LOG%\fh_ctrl_long.xsim.log >nul
if errorlevel 1 (echo [fh_ctrl/long] LONG FAIL & exit /b 1)
exit /b 0
