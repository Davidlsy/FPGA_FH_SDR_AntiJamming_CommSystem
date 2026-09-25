// =====================================================================
// jm_dds.sv — S2 干扰注入源 · 多音 DDS（含单音）
//
// count 个复音，频率为 ftw + k·spacing（k = 0..count-1），等功率合成后按
// 1/sqrt(count) 归一，使**输出（源格式下的）总功率恒为 1**，与音数无关。
// 单音 = count 1 的特例，不另开一条代码路径。
//
// 源格式 SRC_W/SRC_FRAC（16/13，范围 ±4.0）：取 ±4.0 是为了容纳 count ≤ 8 时
// 同相叠加的峰值（最坏 sqrt(8)≈2.83），给 jm_top 留出按 JSR 缩放的余量。
// 幅度分辨率 1.2e-4，相对 14/11 输出台阶（4.9e-4）低一个量级，不额外引入误差。
//
// 相位累加只加不清零（与 ch_cfo / S6 nco_hop 同构），故各音相位连续。
// =====================================================================
`timescale 1ns/1ps

module jm_dds #(
    parameter int W        = 14,
    parameter int FRAC     = 11,
    parameter int SRC_W    = 16,
    parameter int SRC_FRAC = 13,
    parameter int MAXTONES = 8
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic        [2:0]   cfg_count,      // 音数 1..MAXTONES
    input  logic        [31:0]  cfg_ftw,        // 首个音的相位增量
    input  logic signed [31:0]  cfg_spacing,    // 相邻音的相位增量间隔
    output logic                src_valid,
    output logic signed [SRC_W-1:0] src_i,
    output logic signed [SRC_W-1:0] src_q
);
    import ch_pkg::*;

    localparam real SRC_SCALE = 2.0 ** SRC_FRAC;

    logic [31:0] ph [0:MAXTONES-1];

    real    acc_i, acc_q, ph_rad, norm;
    longint qi, qq;
    int     cnt;
    logic [31:0] ftw_k;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < MAXTONES; k++) ph[k] <= 32'h0;
            src_valid <= 1'b0;
            src_i     <= '0;
            src_q     <= '0;
        end else begin
            src_valid <= in_valid;
            if (in_valid) begin
                cnt = int'(cfg_count);
                if (cnt < 1)          cnt = 1;
                if (cnt > MAXTONES)   cnt = MAXTONES;
                norm = 1.0 / $sqrt(real'(cnt));

                acc_i = 0.0;
                acc_q = 0.0;
                for (int k = 0; k < MAXTONES; k++) begin
                    // 每个音的相位增量 = ftw + k·spacing；非激活音照旧累加，只是不参与合成
                    ftw_k = cfg_ftw + (k * cfg_spacing);
                    ph_rad = 2.0 * PI * real'({1'b0, ph[k][31:1]}) / 2147483648.0;
                    if (k < cnt) begin
                        acc_i = acc_i + $cos(ph_rad);
                        acc_q = acc_q + $sin(ph_rad);
                    end
                    ph[k] <= ph[k] + ftw_k;
                end

                qi = quant_rne_sat(acc_i * norm, SRC_W, SRC_FRAC);
                qq = quant_rne_sat(acc_q * norm, SRC_W, SRC_FRAC);
                src_i <= qi[SRC_W-1:0];
                src_q <= qq[SRC_W-1:0];
            end
        end
    end

endmodule
