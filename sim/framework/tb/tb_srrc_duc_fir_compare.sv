// =====================================================================
// tb_srrc_duc_fir_compare.sv — S4-P3 · srrc_duc_fir（FIR Compiler IP 版）位真比对 TB
//
// 与 tb_srrc_duc_compare.sv 同向量、同比对器，唯一差异是 DUT 换成 srrc_duc_fir
// （SRRC 段用 2 × fir_srrc）。tb_vec_cmp 只看 dout_valid 序列、不看绝对延迟，
// 故 FIR 版的 3 拍 latency + 零符号补拖尾天然对齐，输出应逐值与手写版/golden_ref 一致。
//
// 用例（-d 切换，默认 frame）:
//     frame  2170 符号 → 8712 采样（full 卷积 4N+32）
//     edge   四星座点 + 全 0/全 1 连续段
//
// 激励节奏 STIM_PERIOD=4（符号 1/4 节奏进）；NCO 固定频点 freq_word=8192（f0=fs/8）。
// DRAIN_CYCLES 比手写版更大：FIR 版输出分两批（主体 4N + 尾 32），中间有短暂空档。
// =====================================================================
`timescale 1ns/1ps

module tb_srrc_duc_fir_compare;

    localparam int IN_W  = 24;
    localparam int OUT_W = 32;

`ifdef SRRC_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "frame";
`endif

    localparam string STIM_FILE = {"vectors/srrc_duc/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/srrc_duc/", CASE_NAME, "_expect.hex"};

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic             stim_valid;
    logic [IN_W-1:0]  stim_data;
    logic             dut_valid;
    logic [OUT_W-1:0] dut_data;
    int               stim_count;

    tb_vec_cmp #(
        .IN_W       (IN_W),
        .OUT_W      (OUT_W),
        .STIM_FILE  (STIM_FILE),
        .EXP_FILE   (EXP_FILE),
        .TB_NAME    ({"tb_srrc_duc_fir_", CASE_NAME}),
        .STIM_PERIOD(4),
        .DRAIN_CYCLES(160)
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    srrc_duc_fir u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .din_valid  (stim_valid),
        .din_data   (stim_data),
        .freq_word  (16'd8192),
        .freq_valid (1'b1),
        .dout_valid (dut_valid),
        .dout_data  (dut_data)
    );

endmodule
