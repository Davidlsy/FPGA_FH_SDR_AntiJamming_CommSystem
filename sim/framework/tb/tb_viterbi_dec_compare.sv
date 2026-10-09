// =====================================================================
// tb_viterbi_dec_compare.sv — S5 · viterbi_dec 软判决 Viterbi 位真比对 TB
//
// DUT = viterbi_dec（64 态 ACS + 16bit PM 归一化 + 回溯 96，2166 拍 → 2160 bit）。
// 复用 P0 框架（tb_vec_cmp）：向量灌入，DUT 每拍吐 1 bit，与
// golden_ref.fixed_point.rx_modules.fixed_viterbi_hw 逐比特比对。
//
// 用例（-d 切换，默认 frame）:
//     frame  一帧理想软值 4332 软比特 → 2160 信息比特
//     rand   4 帧背靠背噪声软值 17328 → 8640（帧界清零 + 帧尾补吐与下一帧 ACS 并行）
//     edge   满量程 ±127/32 软值（PM 饱和 + ACS 哨兵 32768 取舍边界）
//
// 比对口径：
//   · SKIP_OUT=0 —— 模型与 RTL 共享复位状态（PM 仅状态 0 为 0），第 1 个输出起就应位真一致；
//   · expect 总线 = 1 bit 信息比特（MSB-first，已去 6 尾比特）；
//   · 激励节奏 STIM_PERIOD=1（1 输入拍 = 1 格型步）；
//   · N:M 模块（2166 拍 → 2160 bit）：DUT 自行回溯后按 dout_valid 吐 bit，
//     多吐一个算 extra；DRAIN_CYCLES 给 256 覆盖帧尾补吐 89 拍 + 余量。
// =====================================================================
`timescale 1ns/1ps

module tb_viterbi_dec_compare;

    localparam int IN_W  = 16;   // {soft[2k][7:0], soft[2k+1][7:0]}（Q3.5 补码）
    localparam int OUT_W = 1;    // 译码信息比特

`ifdef VITERBI_DEC_CASE_RAND
    localparam string CASE_NAME = "rand";
`elsif VITERBI_DEC_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "frame";
`endif

    localparam string STIM_FILE = {"vectors/viterbi_dec/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/viterbi_dec/", CASE_NAME, "_expect.hex"};

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic              stim_valid;
    logic [IN_W-1:0]   stim_data;
    logic              dut_valid;
    logic [OUT_W-1:0]  dut_data;
    int                stim_count;

    tb_vec_cmp #(
        .IN_W        (IN_W),
        .OUT_W       (OUT_W),
        .STIM_FILE   (STIM_FILE),
        .EXP_FILE    (EXP_FILE),
        .TB_NAME     ({"tb_viterbi_dec_", CASE_NAME}),
        .STIM_PERIOD (1),
        .DRAIN_CYCLES(256)
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    viterbi_dec u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_soft  (stim_data),
        .dout_valid(dut_valid),
        .dout_bit  (dut_data)
    );

endmodule
