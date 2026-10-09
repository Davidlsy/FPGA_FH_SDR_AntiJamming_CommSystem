@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem"
call vivado -mode batch -nojournal -nolog -tempDir build\vivado_tmp\gen_fir -source build\gen_fir_compiler.tcl > build\fir_gen.log 2>&1
type build\fir_gen.log
