@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set IP=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\build\ip\fir_compiler\fir_srrc
set LOG=..\logs

copy /y "%IP%\fir_srrc.mif" . >nul 2>&1

rem ============ srrc-fir-frame ============
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog -sv -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_srrc_duc_fir_compare.sv "%SRC%\srrc_duc_fir.v" > %LOG%\srrc_fir_frame.xvlog.log 2>&1
if errorlevel 1 (echo [srrc-fir-frame] XVLOG FAIL & type %LOG%\srrc_fir_frame.xvlog.log & goto :edge)
call xvhdl --work work "%IP%\hdl\xbip_utils_v3_0_vh_rfs.vhd" "%IP%\hdl\axi_utils_v2_0_vh_rfs.vhd" "%IP%\hdl\fir_compiler_v7_2_vh_rfs.vhd" "%IP%\sim\fir_srrc.vhd" > %LOG%\srrc_fir_frame.xvhdl.log 2>&1
if errorlevel 1 (echo [srrc-fir-frame] XVHDL FAIL & type %LOG%\srrc_fir_frame.xvhdl.log & goto :edge)
call xelab -relax -timescale 1ns/1ps -snapshot snap_srrc_fir_frame -debug typical work.tb_srrc_duc_fir_compare > %LOG%\srrc_fir_frame.xelab.log 2>&1
if errorlevel 1 (echo [srrc-fir-frame] XELAB FAIL & type %LOG%\srrc_fir_frame.xelab.log & goto :edge)
call xsim snap_srrc_fir_frame -runall > %LOG%\srrc_fir_frame.xsim.log 2>&1
echo ==================== srrc-fir-frame ====================
type %LOG%\srrc_fir_frame.xsim.log

:edge
rem ============ srrc-fir-edge ============
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog -sv -d SRRC_CASE_EDGE -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_srrc_duc_fir_compare.sv "%SRC%\srrc_duc_fir.v" > %LOG%\srrc_fir_edge.xvlog.log 2>&1
if errorlevel 1 (echo [srrc-fir-edge] XVLOG FAIL & type %LOG%\srrc_fir_edge.xvlog.log & goto :end)
call xvhdl --work work "%IP%\hdl\xbip_utils_v3_0_vh_rfs.vhd" "%IP%\hdl\axi_utils_v2_0_vh_rfs.vhd" "%IP%\hdl\fir_compiler_v7_2_vh_rfs.vhd" "%IP%\sim\fir_srrc.vhd" > %LOG%\srrc_fir_edge.xvhdl.log 2>&1
if errorlevel 1 (echo [srrc-fir-edge] XVHDL FAIL & type %LOG%\srrc_fir_edge.xvhdl.log & goto :end)
call xelab -relax -timescale 1ns/1ps -snapshot snap_srrc_fir_edge -debug typical work.tb_srrc_duc_fir_compare > %LOG%\srrc_fir_edge.xelab.log 2>&1
if errorlevel 1 (echo [srrc-fir-edge] XELAB FAIL & type %LOG%\srrc_fir_edge.xelab.log & goto :end)
call xsim snap_srrc_fir_edge -runall > %LOG%\srrc_fir_edge.xsim.log 2>&1
echo ==================== srrc-fir-edge ====================
type %LOG%\srrc_fir_edge.xsim.log

:end
endlocal
