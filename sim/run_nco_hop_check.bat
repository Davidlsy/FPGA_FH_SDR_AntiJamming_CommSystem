@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set LOG=..\logs
set FAIL=0

call :run_case seq -
if errorlevel 1 set FAIL=1
call :run_case rand NCO_HOP_CASE_RAND
if errorlevel 1 set FAIL=1
call :run_case edge NCO_HOP_CASE_EDGE
if errorlevel 1 set FAIL=1

call :run_long
if errorlevel 1 set FAIL=1

if "%FAIL%"=="1" (
    echo [nco_hop] SOME CASES FAILED
    exit /b 1
)
echo [nco_hop] ALL CASES PASS
exit /b 0

:run_case
rem %1 = case name, %2 = case define ("-" = default seq)
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
set DEF=
if not "%~2"=="-" set DEF=-d %~2
call xvlog --nolog -sv %DEF% -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_nco_hop_compare.sv "%SRC%\nco_hop.v" > %LOG%\nco_hop_%~1.xvlog.log 2>&1
if errorlevel 1 (echo [nco_hop/%~1] XVLOG FAIL & type %LOG%\nco_hop_%~1.xvlog.log & exit /b 1)
call xelab --nolog -relax -timescale 1ns/1ps -snapshot snap_nco_hop_%~1 -debug typical work.tb_nco_hop_compare > %LOG%\nco_hop_%~1.xelab.log 2>&1
if errorlevel 1 (echo [nco_hop/%~1] XELAB FAIL & type %LOG%\nco_hop_%~1.xelab.log & exit /b 1)
call xsim --nolog snap_nco_hop_%~1 -runall > %LOG%\nco_hop_%~1.xsim.log 2>&1
echo ==================== nco_hop/%~1 ====================
type %LOG%\nco_hop_%~1.xsim.log
findstr /c:"status=PASS" %LOG%\nco_hop_%~1.xsim.log >nul
if errorlevel 1 (echo [nco_hop/%~1] COMPARE FAIL & exit /b 1)
exit /b 0

:run_long
rem 3e5 hop phase-trajectory assertions + 3 real hop-rate dwells (self-stimulated, no vectors)
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog --nolog -sv -i "%SRC%" -work work tb\tb_nco_hop_long.sv "%SRC%\nco_hop.v" "%SRC%\fh_ctrl.v" > %LOG%\nco_hop_long.xvlog.log 2>&1
if errorlevel 1 (echo [nco_hop/long] XVLOG FAIL & type %LOG%\nco_hop_long.xvlog.log & exit /b 1)
call xelab --nolog -relax -timescale 1ns/1ps -snapshot snap_nco_hop_long -debug typical work.tb_nco_hop_long > %LOG%\nco_hop_long.xelab.log 2>&1
if errorlevel 1 (echo [nco_hop/long] XELAB FAIL & type %LOG%\nco_hop_long.xelab.log & exit /b 1)
call xsim --nolog snap_nco_hop_long -runall > %LOG%\nco_hop_long.xsim.log 2>&1
echo ==================== nco_hop/long ====================
type %LOG%\nco_hop_long.xsim.log
findstr /c:"status=PASS" %LOG%\nco_hop_long.xsim.log >nul
if errorlevel 1 (echo [nco_hop/long] LONG FAIL & exit /b 1)
exit /b 0
