@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set IPDIR=D:/My_project/FPGA_FH_SDR_AntiJamming_CommSystem/build/ip/fir_compiler/fir_srrc

rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul

copy /y "D:/My_project/FPGA_FH_SDR_AntiJamming_CommSystem/build/ip/fir_compiler/fir_srrc/fir_srrc.mif" . >nul 2>&1

call xvlog -sv tb\tb_fir_check.sv > ..\logs\fir_xvlog.log 2>&1
call xvhdl --work work "D:/My_project/FPGA_FH_SDR_AntiJamming_CommSystem/build/ip/fir_compiler/fir_srrc/hdl/xbip_utils_v3_0_vh_rfs.vhd" "D:/My_project/FPGA_FH_SDR_AntiJamming_CommSystem/build/ip/fir_compiler/fir_srrc/hdl/axi_utils_v2_0_vh_rfs.vhd" "D:/My_project/FPGA_FH_SDR_AntiJamming_CommSystem/build/ip/fir_compiler/fir_srrc/hdl/fir_compiler_v7_2_vh_rfs.vhd" "D:/My_project/FPGA_FH_SDR_AntiJamming_CommSystem/build/ip/fir_compiler/fir_srrc/sim/fir_srrc.vhd" > ..\logs\fir_xvhdl.log 2>&1
call xelab -relax -timescale 1ns/1ps -snapshot snap_fir -debug typical work.tb_fir_check > ..\logs\fir_xelab.log 2>&1
call xsim snap_fir -runall > ..\logs\fir_xsim.log 2>&1
type ..\logs\fir_xsim.log
