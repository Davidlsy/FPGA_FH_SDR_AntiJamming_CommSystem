// =====================================================================
// tb_vector_selftest.sv — S2 比对框架 · 自测 TB
//
// 目的：在还没有真实设计模块的时候，先证明「比对框架本身可信」。
// 一个抓不到错的比对器等于没有比对器，所以自测同时跑两条路径：
//
//   正路径                             预期
//   ------------------------------     ------------------------------
//   默认编译                           框架判 PASS（桩 DUT 与 golden 一致）
//   -d SELFTEST_CASE_EDGE              边界用例同样 PASS
//
//   负路径
//   ------------------------------     ------------------------------
//   -d SELF_TEST_NEGATIVE              框架判 FAIL，且首个失配必须落在第 1000 拍
//
// 桩 DUT 只是 golden 映射的镜像（QPSK 四星座点 ±round(1/√2·2^10) = ±724），
// 不是设计交付物——真实模块的 TB 从 tb_module_template.sv 起手。
// =====================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------------
// 自测桩：qpsk_map 的 golden 映射镜像，{i_bit,q_bit} → {i_out,q_out}
// ---------------------------------------------------------------------
module stub_qpsk_map (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [1:0]  din_data,    // {i_bit, q_bit}
    output logic        dout_valid,
    output logic [23:0] dout_data    // {i_out[11:0], q_out[11:0]}
);

    // round(1/sqrt(2) * 2**10) = 724，与 golden_ref fixed_qpsk_modulate 一致
    localparam logic signed [11:0] AMP_POS = 12'sd724;
    localparam logic signed [11:0] AMP_NEG = -12'sd724;

    logic [11:0] i_out, q_out;
    assign i_out = din_data[1] ? AMP_NEG : AMP_POS;
    assign q_out = din_data[0] ? AMP_NEG : AMP_POS;

`ifdef SELF_TEST_STALL
    // 桩死路径：模拟 DUT 卡死 / dout_valid 接错——此路径只能靠看门狗收口
    assign dout_valid = 1'b0;
`else
    assign dout_valid = din_valid;
`endif

`ifdef SELF_TEST_NEGATIVE
    // 负路径：把第 NEG_BEAT 个有效拍的最低位翻转
    localparam int NEG_BEAT = 1000;
    int beat;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          beat <= 0;
        else if (din_valid)  beat <= beat + 1;
    end
    assign dout_data = (din_valid && beat == NEG_BEAT - 1)
                     ? ({i_out, q_out} ^ 24'h000001)
                     : {i_out, q_out};
`else
    assign dout_data = {i_out, q_out};
`endif

endmodule


// ---------------------------------------------------------------------
// 自测 TB
// ---------------------------------------------------------------------
module tb_vector_selftest;

    localparam int IN_W  = 2;
    localparam int OUT_W = 24;

`ifdef SELFTEST_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "rand";
`endif
    localparam string STIM_FILE = {"vectors/qpsk_map/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/qpsk_map/", CASE_NAME, "_expect.hex"};

    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    always #5 clk = ~clk;                       // 100 MHz，与目标基带时钟无关，仅用作节拍

    initial begin
        #100 rst_n = 1'b1;
    end

    logic             stim_valid;
    logic [IN_W-1:0]  stim_data;
    logic             dut_valid;
    logic [OUT_W-1:0] dut_data;

    tb_vec_cmp #(
        .IN_W      (IN_W),
        .OUT_W     (OUT_W),
        .STIM_FILE (STIM_FILE),
        .EXP_FILE  (EXP_FILE),
        .TB_NAME   ("tb_vector_selftest")
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data)
    );

    stub_qpsk_map u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_data (dut_data)
    );

endmodule
