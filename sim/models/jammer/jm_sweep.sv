// =====================================================================
// jm_sweep.sv — S2 干扰注入源 · 扫频（chirp）
//
// 二阶相位累加：每拍 ftw += dfw、ph += ftw，于是瞬时频率随拍号**线性**变化，
// 扫到 cfg_period 拍后把 ftw 拉回起始值重新扫（锯齿扫频，经典扫频干扰形态）。
//
//     起点频率 = cfg_ftw0 / 2^32   （cycle/sample）
//     终点频率 = (cfg_ftw0 + period·dfw) / 2^32
//     扫频斜率 = dfw / 2^32         （cycle/sample²）
//
// ftw/dfw 均为 32 位带符号相位增量，故起始/终止频率可正可负（覆盖整个
// 奈奎斯特区）。输出同 jm_dds：源格式、单位功率复音，相位连续。
// =====================================================================
`timescale 1ns/1ps

module jm_sweep #(
    parameter int SRC_W    = 16,
    parameter int SRC_FRAC = 13
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic        [31:0]  cfg_ftw0,     // 起始相位增量
    input  logic signed [31:0]  cfg_dfw,      // 每拍相位增量的增量
    input  logic        [15:0]  cfg_period,   // 每段扫频的拍数
    output logic                src_valid,
    output logic signed [SRC_W-1:0] src_i,
    output logic signed [SRC_W-1:0] src_q,
    output logic        [31:0]  sweep_cnt     // 完成的扫频段数（核验用）
);
    import ch_pkg::*;

    logic [31:0] ph;
    logic [31:0] ftw;          // 当前相位增量（随扫频增长）
    logic [15:0] pos;          // 段内位置
    real    ph_rad;
    longint qi, qq;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph        <= 32'h0;
            ftw       <= cfg_ftw0;
            pos       <= 16'd0;
            sweep_cnt <= 32'd0;
            src_valid <= 1'b0;
            src_i     <= '0;
            src_q     <= '0;
        end else begin
            src_valid <= in_valid;
            if (in_valid) begin
                ph_rad = 2.0 * PI * real'({1'b0, ph[31:1]}) / 2147483648.0;
                qi = quant_rne_sat($cos(ph_rad), SRC_W, SRC_FRAC);
                qq = quant_rne_sat($sin(ph_rad), SRC_W, SRC_FRAC);
                src_i <= qi[SRC_W-1:0];
                src_q <= qq[SRC_W-1:0];

                ph <= ph + ftw;

                if (cfg_period != 16'd0 && pos >= cfg_period - 16'd1) begin
                    // 一段扫完：频率拉回起点重扫
                    ftw       <= cfg_ftw0;
                    pos       <= 16'd0;
                    sweep_cnt <= sweep_cnt + 32'd1;
                end else begin
                    ftw <= ftw + cfg_dfw[31:0];
                    pos <= pos + 16'd1;
                end
            end
        end
    end

endmodule
