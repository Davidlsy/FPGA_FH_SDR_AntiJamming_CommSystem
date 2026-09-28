// =====================================================================
// tb_frame_tx_compare.sv — S4-P1 · frame_tx 位真比对 TB
//
// 用例（-d 切换，默认 single）:
//     single 1 帧随机载荷         256 拍进 → 2160 拍出
//     multi  8 帧背靠背           -d FRAME_CASE_MULTI
//     edge   4 个边界载荷          -d FRAME_CASE_EDGE
//     long   1000 随机帧          -d FRAME_CASE_LONG（任务卡判据；向量不入库，可重生成）
// 证伪用例（必须判 FAIL）:
//     -d FRAME_NEG_CRC           把 CRC 多项式换成 0x8005（CRC-16/IBM）——多项式写错、
//                                覆盖范围写错这类"看起来很像"的错，必须被向量抓住
//
// 激励节奏 STIM_PERIOD=9：载荷 1 字节 / 9 拍。这不是凑数——本模块输出 2160 拍/帧
// 而只吃 256 字节/帧，连续满速灌会得到"上游 8.4 倍过载"的假象，与接口规格 §4.1
// 的速率约束（平均每字节 ≥ 8.44 拍）一致。
// =====================================================================
`timescale 1ns/1ps

module tb_frame_tx_compare;

    localparam int IN_W  = 8;
    localparam int OUT_W = 1;
    localparam int STIM_PERIOD = 9;      // 见文件头：载荷节奏

`ifdef FRAME_CASE_MULTI
    localparam string CASE_NAME = "multi";
    localparam int    MAX_DEPTH = 32768;
`elsif FRAME_CASE_EDGE
    localparam string CASE_NAME = "edge";
    localparam int    MAX_DEPTH = 32768;
`elsif FRAME_CASE_LONG
    localparam string CASE_NAME = "long";
    localparam int    MAX_DEPTH = 4194304;   // 期望 2160000 行
`else
    localparam string CASE_NAME = "single";
    localparam int    MAX_DEPTH = 32768;
`endif

    localparam string STIM_FILE = {"vectors/frame_tx/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/frame_tx/", CASE_NAME, "_expect.hex"};

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic             stim_valid;
    logic [IN_W-1:0]  stim_data;
    logic             dut_valid;
    logic             dut_bit;
    int               stim_count;

    tb_vec_cmp #(
        .IN_W       (IN_W),
        .OUT_W      (OUT_W),
        .MAX_DEPTH  (MAX_DEPTH),
        .STIM_FILE  (STIM_FILE),
        .EXP_FILE   (EXP_FILE),
        .STIM_PERIOD(STIM_PERIOD),
        .DRAIN_CYCLES(128),
        .TB_NAME    ({"tb_frame_tx_", CASE_NAME})
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_bit),
        .stim_count(stim_count)
    );

`ifdef FRAME_NEG_CRC
    frame_tx #(.CRC_POLY(16'h8005)) u_dut (
`else
    frame_tx u_dut (
`endif
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_bit  (dut_bit)
    );

endmodule
