// =====================================================================
// ch_top.sv — S2 信道模型库 · 信道链
//
// 物理顺序（TX 出 → 信道 → RX 入）：
//     multipath（信道响应）→ SFO（采样时钟差）→ CFO（载波差）→ AWGN（热噪声）
//
// 四级各自可旁路（cfg_*_en=0 时该级直通、逐位相等），因此 TB 可以只开一级
// 单独测该级的效应，也可以全旁路做恒等自检。全旁路时整链是**逐位透明**的，
// 只引入固定的流水线延迟（每级 1 拍，共 4 拍）。
//
// 注意：SFO 在 ratio≠1 时会有 1 拍插值延迟，级联后的总延迟随配置而变，
// 所以对接的 TB 应按**各自的 valid 逐拍计数**对齐，不要按绝对时间对齐
// （与 sim/framework 的逐拍比对口径一致）。
// =====================================================================
`timescale 1ns/1ps

module ch_top #(
    parameter int    W            = 14,
    parameter int    FRAC         = 11,
    parameter real   ES           = 1.0,
    parameter real   BIT_RATE     = 1.0,
    parameter real   EB_N0_DB     = 4.0,
    parameter int    NTAPS        = 4,
    parameter real   PDP_DECAY_DB = 3.0,
    parameter logic [31:0] SEED   = 32'hC0FF_EE01
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic signed [W-1:0] in_i,
    input  logic signed [W-1:0] in_q,

    // 运行时配置
    input  logic                cfg_mp_en,
    input  logic                cfg_sfo_en,
    input  logic                cfg_cfo_en,
    input  logic                cfg_awgn_en,
    input  logic signed [31:0]  cfg_sfo_ppm,
    input  logic        [31:0]  cfg_cfo_ftw,
    input  logic signed [31:0]  cfg_mp_k_db_x10,
    input  logic                cfg_mp_reseed,

    output logic                out_valid,
    output logic signed [W-1:0] out_i,
    output logic signed [W-1:0] out_q,
    output logic        [31:0]  slip_cnt
);
    logic                v0, v1, v2, v3;
    logic signed [W-1:0] a_i, a_q, b_i, b_q, c_i, c_q;

    ch_multipath #(
        .W(W), .FRAC(FRAC), .NTAPS(NTAPS), .PDP_DECAY_DB(PDP_DECAY_DB), .SEED(SEED)
    ) u_mp (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
        .cfg_en(cfg_mp_en), .cfg_k_db_x10(cfg_mp_k_db_x10), .cfg_reseed(cfg_mp_reseed),
        .out_valid(v0), .out_i(a_i), .out_q(a_q)
    );

    ch_sfo #(.W(W), .FRAC(FRAC)) u_sfo (
        .clk(clk), .rst_n(rst_n), .in_valid(v0), .in_i(a_i), .in_q(a_q),
        .cfg_en(cfg_sfo_en), .cfg_sfo_ppm(cfg_sfo_ppm),
        .out_valid(v1), .out_i(b_i), .out_q(b_q), .slip_cnt(slip_cnt)
    );

    ch_cfo #(.W(W), .FRAC(FRAC)) u_cfo (
        .clk(clk), .rst_n(rst_n), .in_valid(v1), .in_i(b_i), .in_q(b_q),
        .cfg_en(cfg_cfo_en), .cfg_ftw(cfg_cfo_ftw),
        .out_valid(v2), .out_i(c_i), .out_q(c_q)
    );

    ch_awgn #(
        .W(W), .FRAC(FRAC), .ES(ES), .BIT_RATE(BIT_RATE), .EB_N0_DB(EB_N0_DB),
        .SEED(SEED ^ 32'h0000_1234)
    ) u_awgn (
        .clk(clk), .rst_n(rst_n), .in_valid(v2), .in_i(c_i), .in_q(c_q),
        .cfg_en(cfg_awgn_en),
        .out_valid(v3), .out_i(out_i), .out_q(out_q)
    );

    assign out_valid = v3;

endmodule
