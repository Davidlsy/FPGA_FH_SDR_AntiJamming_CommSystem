@echo off
setlocal
call "D:\software\vivado2021\Vivado\2021.2\settings64.bat" >nul 2>&1
cd /d "D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\framework"

set SRC=D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\src
set LOG=..\logs
set SRCS=%SRC%\tx_chain_top.v %SRC%\frame_tx.v %SRC%\conv_enc.v %SRC%\blk_inter.v %SRC%\blk_mem_1w1r.v %SRC%\qpsk_map.v %SRC%\srrc_duc.v

rem ============ tx-chain-frame ============
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog -sv -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_tx_chain_compare.sv %SRCS% > %LOG%\tx_chain_frame.xvlog.log 2>&1
if errorlevel 1 (echo [tx-chain-frame] XVLOG FAIL & type %LOG%\tx_chain_frame.xvlog.log & goto :edge)
call xelab -relax -timescale 1ns/1ps -snapshot snap_tx_chain_frame -debug typical work.tb_tx_chain_compare > %LOG%\tx_chain_frame.xelab.log 2>&1
if errorlevel 1 (echo [tx-chain-frame] XELAB FAIL & type %LOG%\tx_chain_frame.xelab.log & goto :edge)
call xsim snap_tx_chain_frame -runall > %LOG%\tx_chain_frame.xsim.log 2>&1
echo ==================== tx-chain-frame ====================
type %LOG%\tx_chain_frame.xsim.log

:edge
rem ============ tx-chain-edge ============
rmdir /s /q work 2>nul
rmdir /s /q xsim.dir 2>nul
call xvlog -sv -d TX_CHAIN_CASE_EDGE -i "%SRC%" -work work hdl\tb_vec_cmp.sv tb\tb_tx_chain_compare.sv %SRCS% > %LOG%\tx_chain_edge.xvlog.log 2>&1
if errorlevel 1 (echo [tx-chain-edge] XVLOG FAIL & type %LOG%\tx_chain_edge.xvlog.log & goto :end)
call xelab -relax -timescale 1ns/1ps -snapshot snap_tx_chain_edge -debug typical work.tb_tx_chain_compare > %LOG%\tx_chain_edge.xelab.log 2>&1
if errorlevel 1 (echo [tx-chain-edge] XELAB FAIL & type %LOG%\tx_chain_edge.xelab.log & goto :end)
call xsim snap_tx_chain_edge -runall > %LOG%\tx_chain_edge.xsim.log 2>&1
echo ==================== tx-chain-edge ====================
type %LOG%\tx_chain_edge.xsim.log

:end
endlocal
