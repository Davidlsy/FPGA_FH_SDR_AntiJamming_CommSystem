// =====================================================================
// tb_blk_inter_compare.sv — S4-P2 · blk_inter 位真比对 TB
//
// 用例（-d 切换，默认 frame）:
//     frame  1 块（一帧的编码输出）  2166 拍进 → 2170 拍出
//     rand   8 块随机背靠背          -d BLK_CASE_RAND（节奏 1/2）
//     edge   4 个边界块              -d BLK_CASE_EDGE（节奏 1/2）
// 证伪用例（必须判 FAIL）:
//     -d BLK_NEG_SWAP                输出 {I,Q} 互换
//
// 激励节奏为何随用例变：交织器一块要吃 2166 拍数据、块周期 2171 拍（接口规格
// §4.3 的速率约束），单块用例满速灌没问题（输入 2166 拍就先结束），多块连续满速
// 会累积 4 拍/块的节拍差、超出 32 拍弹性缓冲，故多块用例把节奏放到 1/2。
// =====================================================================
`timescale 1ns/1ps

module tb_blk_inter_compare;

    localparam int IN_W  = 2;
    localparam int OUT_W = 2;

`ifdef BLK_CASE_RAND
    localparam string CASE_NAME   = "rand";
    localparam int    STIM_PERIOD = 2;
`elsif BLK_CASE_EDGE
    localparam string CASE_NAME   = "edge";
    localparam int    STIM_PERIOD = 2;
`else
    localparam string CASE_NAME   = "frame";
    localparam int    STIM_PERIOD = 1;
`endif

    localparam string STIM_FILE = {"vectors/blk_inter/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/blk_inter/", CASE_NAME, "_expect.hex"};

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

`ifdef BLK_NEG_SWAP
    assign dut_data = {dut_data_raw[0], dut_data_raw[1]};
`else
    assign dut_data = dut_data_raw;
`endif

    tb_vec_cmp #(
        .IN_W       (IN_W),
        .OUT_W      (OUT_W),
        .STIM_FILE  (STIM_FILE),
        .EXP_FILE   (EXP_FILE),
        .STIM_PERIOD(STIM_PERIOD),
        .DRAIN_CYCLES(128),
        .TB_NAME    ({"tb_blk_inter_", CASE_NAME})
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    blk_inter u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_data (dut_data_raw)
    );

endmodule
