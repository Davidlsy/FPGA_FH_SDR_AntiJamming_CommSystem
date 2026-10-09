@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set LOG=..\logs

rem ============ srrc-frame ============
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog --nolog -sv -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_srrc_duc_compare.sv "%SRC%\srrc_duc.v" > %LOG%\srrc_frame.xvlog.log 2>&1
if errorlevel 1 (echo [srrc-frame] XVLOG FAIL & type %LOG%\srrc_frame.xvlog.log & goto :edge)
call xelab --nolog -relax -timescale 1ns/1ps -snapshot snap_srrc_frame -debug typical work.tb_srrc_duc_compare > %LOG%\srrc_frame.xelab.log 2>&1
if errorlevel 1 (echo [srrc-frame] XELAB FAIL & type %LOG%\srrc_frame.xelab.log & goto :edge)
call xsim --nolog snap_srrc_frame -runall > %LOG%\srrc_frame.xsim.log 2>&1
echo ==================== srrc-frame ====================
type %LOG%\srrc_frame.xsim.log

:edge
rem ============ srrc-edge ============
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog --nolog -sv -d SRRC_CASE_EDGE -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_srrc_duc_compare.sv "%SRC%\srrc_duc.v" > %LOG%\srrc_edge.xvlog.log 2>&1
if errorlevel 1 (echo [srrc-edge] XVLOG FAIL & type %LOG%\srrc_edge.xvlog.log & goto :end)
call xelab --nolog -relax -timescale 1ns/1ps -snapshot snap_srrc_edge -debug typical work.tb_srrc_duc_compare > %LOG%\srrc_edge.xelab.log 2>&1
if errorlevel 1 (echo [srrc-edge] XELAB FAIL & type %LOG%\srrc_edge.xelab.log & goto :end)
call xsim --nolog snap_srrc_edge -runall > %LOG%\srrc_edge.xsim.log 2>&1
echo ==================== srrc-edge ====================
type %LOG%\srrc_edge.xsim.log

:end
endlocal
