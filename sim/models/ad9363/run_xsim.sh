#!/bin/bash
#=====================================================================
# run_xsim.sh - Vivado xsim 仿真脚本 (AD9363 SPI 行为模型)
#
# 用法:
#   chmod +x run_xsim.sh
#   ./run_xsim.sh            # 编译 + 运行, 波形存 tb_ad9363_spi_model.wdb
#   ./run_xsim.sh gui        # 打开 GUI 查看波形
#
# 依赖: Vivado (xvlog/xelab/xsim 在 PATH 中, 或先 source settings64.sh)
#   source /tools/Xilinx/Vivado/202X.X/settings64.sh
#=====================================================================
set -e
GUI=0
[ "$1" == "gui" ] && GUI=1

# ---------- 1. 编译 (SystemVerilog-2009 兼容) ----------
xvlog -sv -work work \
    ad9363_spi_model.sv \
    tb_ad9363_spi_model.sv

# ---------- 2. 详细化 ----------
# -relax: 宽松类型检查; -timescale: 统一时间刻度
# dut TIMEOUT_NS=1000ns, TCO_NS=5ns 与 iverilog 回归一致
xelab -relax -timescale 1ns/1ps -snapshot tb_snap \
    -debug typical \
    work.tb_ad9363_spi_model

# ---------- 3. 运行 ----------
if [ $GUI -eq 1 ]; then
    xsim tb_snap -gui -wdb tb_ad9363_spi_model.wdb
else
    xsim tb_snap -runall
fi

# 期望输出末尾:
#   RESULT : *** ALL TESTS PASSED ***
