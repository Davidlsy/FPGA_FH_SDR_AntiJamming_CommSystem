@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set LOG=..\logs
set FAIL=0

call :run_case frame -
if errorlevel 1 set FAIL=1
call :run_case rand VITERBI_DEC_CASE_RAND
if errorlevel 1 set FAIL=1
call :run_case edge VITERBI_DEC_CASE_EDGE
if errorlevel 1 set FAIL=1

if "%FAIL%"=="1" (
    echo [viterbi_dec] SOME CASES FAILED
    exit /b 1
)
echo [viterbi_dec] ALL CASES PASS
exit /b 0

:run_case
rem %1 = case name, %2 = case define ("-" = default frame)
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
set DEF=
if not "%~2"=="-" set DEF=-d %~2
call xvlog -sv %DEF% -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_viterbi_dec_compare.sv "%SRC%\viterbi_dec.v" > %LOG%\viterbi_dec_%~1.xvlog.log 2>&1
if errorlevel 1 (echo [viterbi_dec/%~1] XVLOG FAIL & type %LOG%\viterbi_dec_%~1.xvlog.log & exit /b 1)
call xelab -relax -timescale 1ns/1ps -snapshot snap_viterbi_dec_%~1 -debug typical work.tb_viterbi_dec_compare > %LOG%\viterbi_dec_%~1.xelab.log 2>&1
if errorlevel 1 (echo [viterbi_dec/%~1] XELAB FAIL & type %LOG%\viterbi_dec_%~1.xelab.log & exit /b 1)
call xsim snap_viterbi_dec_%~1 -runall > %LOG%\viterbi_dec_%~1.xsim.log 2>&1
echo ==================== viterbi_dec/%~1 ====================
type %LOG%\viterbi_dec_%~1.xsim.log
findstr /c:"status=PASS" %LOG%\viterbi_dec_%~1.xsim.log >nul
if errorlevel 1 (echo [viterbi_dec/%~1] COMPARE FAIL & exit /b 1)
exit /b 0
