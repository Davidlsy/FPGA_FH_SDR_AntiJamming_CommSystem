// =====================================================================
// tb_blk_deinter_compare.sv — S5 · blk_deinter 块解交织位真比对 TB
//
// DUT = blk_deinter（逆 blk_inter 置换 + 去 8 bit 补零，2170 拍 → 2166 拍）。
// 复用 P0 框架（tb_vec_cmp）：向量灌入，DUT 输出 16 bit 一拍（2 软值），
// 与 golden_ref.fixed_point.rx_modules.soft_deinterleave 逐拍比对。
//
// 用例（-d 切换，默认 frame）:
//     frame  一帧软判决码流 4340 → 4332（2170 激励拍 → 2166 输出拍）
//     rand   4 帧背靠背（乒乓双缓冲连续流式）8680 激励拍 → 8664 输出拍
//
// 比对口径：
//   · SKIP_OUT=0 —— 纯置换、模型与 RTL 共享复位状态，第 1 个输出起就应位真一致；
//   · expect 总线 = {soft[2m][7:0], soft[2m+1][7:0]}（高位在前，与导出器 pack_fields 同序）；
//   · 激励节奏 STIM_PERIOD=1（软值按 din_valid 连续计数；输出 2166 < 输入 2170，
//     双缓冲乒乓天然追得上，无需节拍约束）；
//   · N:M 模块（2170 → 2166）：DUT 自行缓冲后按 dout_valid 吐 2166 拍，多一拍算 extra。
// =====================================================================
`timescale 1ns/1ps

module tb_blk_deinter_compare;

    localparam int IN_W  = 16;   // {soft[2k][7:0], soft[2k+1][7:0]}
    localparam int OUT_W = 16;   // {soft[2m][7:0], soft[2m+1][7:0]}

`ifdef BLK_DEINTER_CASE_RAND
    localparam string CASE_NAME = "rand";
`else
    localparam string CASE_NAME = "frame";
`endif

    localparam string STIM_FILE = {"vectors/blk_deinter/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/blk_deinter/", CASE_NAME, "_expect.hex"};

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
        .TB_NAME     ({"tb_blk_deinter_", CASE_NAME}),
        .STIM_PERIOD (1),
        .DRAIN_CYCLES(128)
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    blk_deinter u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_data (dut_data)
    );

endmodule
