// =====================================================================
// ch_cfo.sv — S2 信道模型库 · 载波频偏（CFO）
//
// 用自研相位累加器实现复数旋转：y[n] = x[n] · exp(j2π·FTW·n/2^32)。
//
// 相位**只累加、不清零**——与 S6 的 nco_hop 相位连续跳频同构。这样 S6 做
// 相位连续性验证时，信道侧引入的 CFO 不会与 NCO 的清零行为混在一起，
// 二者是可分辨的独立效应。
//
// 频偏口径：cfg_ftw 为每拍相位增量，归一化频偏 = FTW / 2^32（cycle/sample）。
// 要按 Hz 给，乘以采样率即可：FTW = round(f_cfo / fs × 2^32)。
// =====================================================================
`timescale 1ns/1ps

module ch_cfo #(
    parameter int W    = 14,
    parameter int FRAC = 11
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic signed [W-1:0] in_i,
    input  logic signed [W-1:0] in_q,
    input  logic                cfg_en,
    input  logic        [31:0]  cfg_ftw,
    output logic                out_valid,
    output logic signed [W-1:0] out_i,
    output logic signed [W-1:0] out_q
);
    import ch_pkg::*;

    logic [31:0] phase_q;
    real    scale, ph, ci, cs;
    longint qi, qq;

    initial scale = 2.0 ** FRAC;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_q   <= 32'h0;
            out_valid <= 1'b0;
            out_i     <= '0;
            out_q     <= '0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                if (cfg_en) begin
                    // 取 31 位再转实数，避开 32 位向 real 转换的符号歧义
                    ph = 2.0 * PI * real'({1'b0, phase_q[31:1]}) / 2147483648.0;
                    ci = $cos(ph);
                    cs = $sin(ph);
                    qi = quant_rne_sat((real'(in_i) * ci - real'(in_q) * cs) / scale, W, FRAC);
                    qq = quant_rne_sat((real'(in_i) * cs + real'(in_q) * ci) / scale, W, FRAC);
                    out_i   <= qi[W-1:0];
                    out_q   <= qq[W-1:0];
                    phase_q <= phase_q + cfg_ftw;      // 相位连续：只加不清零
                end else begin
                    out_i <= in_i;
                    out_q <= in_q;
                end
            end
        end
    end

endmodule
