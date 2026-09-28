// =====================================================================
// tb_qpsk_map_compare.sv — S4-P1 · qpsk_map 位真比对 TB
//
// 用例（-d 切换，默认 rand）:
//     rand  4096 符号随机        -d QPSK_CASE_EDGE 时改用 edge 用例
// 证伪用例（必须判 FAIL，用来证明向量真的有鉴别力）:
//     -d QPSK_NEG_SWAP          把 I/Q 两路互换后再送比对器
//
// 参数说明见 sim/framework/README.md §3；本例 1:1（2 bit 进 → 24 bit 出）。
// =====================================================================
`timescale 1ns/1ps

module tb_qpsk_map_compare;

    localparam int    IN_W  = 2;
    localparam int    OUT_W = 24;

`ifdef QPSK_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "rand";
`endif

    localparam string STIM_FILE = {"vectors/qpsk_map/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/qpsk_map/", CASE_NAME, "_expect.hex"};

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic             stim_valid;
    logic [IN_W-1:0]  stim_data;
    logic             dut_valid;
    logic [OUT_W-1:0] dut_data_raw;
    logic [OUT_W-1:0] dut_data;
    int               stim_count;

`ifdef QPSK_NEG_SWAP
    // 证伪：I/Q 互换（24 bit = {I[11:0], Q[11:0]}）
    assign dut_data = {dut_data_raw[11:0], dut_data_raw[23:12]};
`else
    assign dut_data = dut_data_raw;
`endif

    tb_vec_cmp #(
        .IN_W      (IN_W),
        .OUT_W     (OUT_W),
        .STIM_FILE (STIM_FILE),
        .EXP_FILE  (EXP_FILE),
        .TB_NAME   ({"tb_qpsk_map_", CASE_NAME})
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    qpsk_map u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_data (dut_data_raw)
    );

endmodule
