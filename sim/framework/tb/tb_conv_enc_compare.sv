// =====================================================================
// tb_conv_enc_compare.sv — S4-P1 · conv_enc 位真比对 TB
//
// 用例（-d 切换，默认 frame）:
//     frame  1 块随机（2160 拍进 → 2166 拍出）
//     rand   8 块背靠背            -d CONV_CASE_RAND
//     edge   4 个边界块            -d CONV_CASE_EDGE
//     long   463 块 = 1,000,080 bit -d CONV_CASE_LONG（激励节奏 1/2，见下）
// 证伪用例（必须判 FAIL）:
//     -d CONV_NEG_ORDER           把 {g₁,g₂} 颠倒成 {g₂,g₁}
//
// 两处与模块契约强相关、写错就必然红的地方：
//   1. blk_len 必须等于帧长 2160（一个编码块的"信息比特数"）。它不是从向量行数推出来的
//      ——多块用例的激励行数是 2160 的整数倍，块长是每一块的长度。
//   2. long 用例把激励节奏放慢到 1/2：编码器每块输出 2166 拍却只吃 2160 拍输入，
//      连续满速灌 463 块会累积出 2778 bit 的节拍差，超出 64 深弹性缓冲。
//      放慢到 1/2 后缓冲常态只有几个比特，判据仍然是"逐拍位真"。
// =====================================================================
`timescale 1ns/1ps

module tb_conv_enc_compare;

    localparam int  IN_W  = 1;
    localparam int  OUT_W = 2;
    localparam int  BLK_LEN = 2160;          // = 帧长，见 docs/spec/frame_format.md §7

`ifdef CONV_CASE_RAND
    localparam string CASE_NAME = "rand";
    localparam int    MAX_DEPTH = 32768;
    localparam int    STIM_PERIOD = 1;
`elsif CONV_CASE_EDGE
    localparam string CASE_NAME = "edge";
    localparam int    MAX_DEPTH = 32768;
    localparam int    STIM_PERIOD = 1;
`elsif CONV_CASE_LONG
    localparam string CASE_NAME = "long";
    localparam int    MAX_DEPTH = 2097152;   // 期望 1002858 行
    localparam int    STIM_PERIOD = 2;
`else
    localparam string CASE_NAME = "frame";
    localparam int    MAX_DEPTH = 32768;
    localparam int    STIM_PERIOD = 1;
`endif

    localparam string STIM_FILE = {"vectors/conv_enc/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/conv_enc/", CASE_NAME, "_expect.hex"};

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

`ifdef CONV_NEG_ORDER
    // 证伪：位序颠倒（S1 参考是先 g₁ 后 g₂）
    assign dut_data = {dut_data_raw[0], dut_data_raw[1]};
`else
    assign dut_data = dut_data_raw;
`endif

    tb_vec_cmp #(
        .IN_W       (IN_W),
        .OUT_W      (OUT_W),
        .MAX_DEPTH  (MAX_DEPTH),
        .STIM_FILE  (STIM_FILE),
        .EXP_FILE   (EXP_FILE),
        .STIM_PERIOD(STIM_PERIOD),
        .DRAIN_CYCLES(128),
        .TB_NAME    ({"tb_conv_enc_", CASE_NAME})
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    // 激励长度必须是整数个块——否则是向量与块长口径不一致，直接判死比看失配波形快
    always_ff @(posedge clk) begin
        if (rst_n && stim_count > 0 && (stim_count % BLK_LEN != 0)) begin
            $display("[VEC] FAIL 激励 %0d 拍不是块长 %0d 的整数倍", stim_count, BLK_LEN);
            $fatal(1, "[VEC] stim length not a multiple of block length");
        end
    end

    conv_enc u_dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .din_valid(stim_valid),
        .din_bit  (stim_data[0]),
        .blk_len  (16'd2160),
        .dout_valid(dut_valid),
        .dout_data (dut_data_raw)
    );

endmodule
