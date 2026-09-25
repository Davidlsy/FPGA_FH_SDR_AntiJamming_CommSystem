// =====================================================================
// jm_top.sv — S2 干扰注入源 · 类型选择 + JSR 标定 + 与信号相加
//
//   cfg_type: 0 = 关闭（直通，逐位透明）  1 = 单音/多音  2 = 扫频  3 = 部分频带
//
// **JSR 口径（务必与报告一致）**：JSR 按**总功率**定义
//     P_jam = JS × 10^(JSR/10)，  JSR_DB = 10·log10(P_jam / P_signal)
// 其中参考信号功率取参数 JS（与 ch_awgn 的 ES 同口径，不在线估功率）。
// 换调制/成形系数时必须同步改 JS，否则 JSR 名义值与实际不符。
// 部分频带干扰下另有「带内 JSR」——只一部分功率落在信号带宽内，
// 对 BER 起作用的其实是带内那个比值，报告里要写清用的是哪个。
//
// 输出两路：
//   out_* = 信号 + 干扰（14/11，即接收机看到的总波形）
//   jm_*  = 干扰本身（14/11），供核验与 S7 频谱感知单独取用
// 单独引出 jm_* 是必要的：高 JSR 下和信号会顶到 14/11 的 ±4.0 轨，
// 测量干扰功率必须在相加之前，否则量到的是削顶后的波形。
//
// 三个波形源并行运行，由 cfg_type 选一；源格式为 16/13 单位功率，
// 此处按 JSR 缩放并量化到 14/11。
// =====================================================================
`timescale 1ns/1ps

module jm_top #(
    parameter int    W        = 14,
    parameter int    FRAC     = 11,
    parameter int    SRC_W    = 16,
    parameter int    SRC_FRAC = 13,
    parameter int    MAXTONES = 8,
    parameter real   JS       = 1.0,           // 参考信号功率（同 ch_awgn 的 ES）
    parameter logic [31:0] SEED = 32'h1A2B_3C4D
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic signed [W-1:0] in_i,
    input  logic signed [W-1:0] in_q,

    // 运行时可配
    input  logic        [1:0]   cfg_type,
    input  logic signed [31:0]  cfg_jsr_db_x10,
    input  logic        [2:0]   cfg_tone_count,
    input  logic        [31:0]  cfg_tone_ftw,
    input  logic signed [31:0]  cfg_tone_spacing,
    input  logic        [31:0]  cfg_sweep_ftw0,
    input  logic signed [31:0]  cfg_sweep_dfw,
    input  logic        [15:0]  cfg_sweep_period,
    input  logic        [7:0]   cfg_pb_div,
    input  logic        [31:0]  cfg_pb_ftw,

    output logic                out_valid,
    output logic signed [W-1:0] out_i,
    output logic signed [W-1:0] out_q,
    output logic                jm_valid,
    output logic signed [W-1:0] jm_i,
    output logic signed [W-1:0] jm_q
);
    import ch_pkg::*;

    localparam real INV_SRC_SCALE = 1.0 / (2.0 ** SRC_FRAC);
    localparam real OUT_SCALE     = 2.0 ** FRAC;

    logic                v_dds, v_swp, v_pbt;
    logic signed [SRC_W-1:0] dds_i, dds_q, swp_i, swp_q, pbt_i, pbt_q;

    logic signed [SRC_W-1:0] src_i, src_q;
    logic signed [W-1:0] in_i_d, in_q_d;
    logic in_valid_d;
    real    scale, src_ri, src_rq, sum_ri, sum_rq;
    longint qi, qq;

    // 三个波形源的输出都过了一级寄存器，信号直通路径没有——若不在信号路径补一级，
    // 干扰会比信号晚一拍：首个采样是 0，在频谱里表现为约 -39 dBc 的假杂散。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_i_d     <= '0;
            in_q_d     <= '0;
            in_valid_d <= 1'b0;
        end else begin
            in_i_d     <= in_i;
            in_q_d     <= in_q;
            in_valid_d <= in_valid;
        end
    end

    assign src_i = (cfg_type == 2'd1) ? dds_i :
                   (cfg_type == 2'd2) ? swp_i :
                   (cfg_type == 2'd3) ? pbt_i : '0;
    assign src_q = (cfg_type == 2'd1) ? dds_q :
                   (cfg_type == 2'd2) ? swp_q :
                   (cfg_type == 2'd3) ? pbt_q : '0;

    jm_dds #(
        .W(W), .FRAC(FRAC), .SRC_W(SRC_W), .SRC_FRAC(SRC_FRAC), .MAXTONES(MAXTONES)
    ) u_dds (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .cfg_count(cfg_tone_count), .cfg_ftw(cfg_tone_ftw), .cfg_spacing(cfg_tone_spacing),
        .src_valid(v_dds), .src_i(dds_i), .src_q(dds_q)
    );

    jm_sweep #(.SRC_W(SRC_W), .SRC_FRAC(SRC_FRAC)) u_swp (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .cfg_ftw0(cfg_sweep_ftw0), .cfg_dfw(cfg_sweep_dfw), .cfg_period(cfg_sweep_period),
        .src_valid(v_swp), .src_i(swp_i), .src_q(swp_q), .sweep_cnt()
    );

    jm_partial #(.SRC_W(SRC_W), .SRC_FRAC(SRC_FRAC)) u_pbt (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .cfg_div(cfg_pb_div), .cfg_ftw(cfg_pb_ftw), .seed_init(SEED),
        .src_valid(v_pbt), .src_i(pbt_i), .src_q(pbt_q)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            jm_valid  <= 1'b0;
            out_i     <= '0;
            out_q     <= '0;
            jm_i      <= '0;
            jm_q      <= '0;
        end else begin
            out_valid <= in_valid_d;
            jm_valid  <= in_valid_d;
            if (in_valid_d) begin
                if (cfg_type == 2'd0) begin
                    // 关闭：直通（经一级寄存），逐位透明
                    out_i <= in_i_d;
                    out_q <= in_q_d;
                    jm_i  <= '0;
                    jm_q  <= '0;
                end else begin
                    scale   = $sqrt(JS * (10.0 ** (real'(cfg_jsr_db_x10) / 100.0)));
                    src_ri  = real'(src_i) * INV_SRC_SCALE * scale;
                    src_rq  = real'(src_q) * INV_SRC_SCALE * scale;

                    qi = quant_rne_sat(src_ri, W, FRAC);
                    qq = quant_rne_sat(src_rq, W, FRAC);
                    jm_i <= qi[W-1:0];
                    jm_q <= qq[W-1:0];

                    sum_ri = real'(in_i_d) / OUT_SCALE + src_ri;
                    sum_rq = real'(in_q_d) / OUT_SCALE + src_rq;
                    qi = quant_rne_sat(sum_ri, W, FRAC);
                    qq = quant_rne_sat(sum_rq, W, FRAC);
                    out_i <= qi[W-1:0];
                    out_q <= qq[W-1:0];
                end
            end
        end
    end

endmodule
