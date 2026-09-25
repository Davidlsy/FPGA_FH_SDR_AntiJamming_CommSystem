// =====================================================================
// ch_sfo.sv — S2 信道模型库 · 采样率偏差（SFO）
//
// 建模方式：**采样相位线性漂移**，即
//     y[m] = (1-μ_m)·x[m] + μ_m·x[m+1],   μ_m = frac(m · δ),  δ = ppm × 1e-6
// 每收到一个输入样本推进一次 μ，μ 越过 1 时绕回 0（滑掉一个采样点，slip）。
//
// 为什么不用「按绝对时间重采样」：那样输出样本的输入时间坐标会相对输入流
// 无界漂移（t_m = m·ratio 与输入计数之差随 m 线性增长），任何有限长的历史
// 缓冲都会在几千拍后耗尽，模型自己会停摆。而 SFO 对接收链真正的可观测量
// 就是**采样相位随时间漂移**，这正是上式建模的东西：μ 有界、每输入一拍出一拍、
// 落在 [m, m+1) 内不会溢出。
//
// δ = 0 时 y[m] = x[m]，即恒等（仍有 1 拍延迟）；cfg_en = 0 时直通无延迟。
// slip_cnt 输出滑码次数，mu 与 TB 的层次引用一起用于核验漂移率。
// =====================================================================
`timescale 1ns/1ps

module ch_sfo #(
    parameter int W    = 14,
    parameter int FRAC = 11
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic signed [W-1:0] in_i,
    input  logic signed [W-1:0] in_q,
    input  logic                cfg_en,
    input  logic signed [31:0]  cfg_sfo_ppm,
    output logic                out_valid,
    output logic signed [W-1:0] out_i,
    output logic signed [W-1:0] out_q,
    output logic        [31:0]  slip_cnt
);
    import ch_pkg::*;

    real    mu;             // 采样相位 ∈ [0,1)，累加器
    real    mu_used;        // 本拍输出所用的 μ（TB 核验用；NBA 赋值，与 out_i/out_q 同拍语义）
    real    mu_n, delta;
    real    scale, y_i, y_q;
    longint qi, qq;

    logic signed [W-1:0] d1_i, d1_q;   // x[m]
    logic                have_prev;

    initial begin
        scale = 2.0 ** FRAC;   // mu 只在复位分支里写：同一变量不可被两个进程驱动
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mu        <= 0.0;
            mu_used   <= 0.0;
            d1_i      <= '0;
            d1_q      <= '0;
            have_prev <= 1'b0;
            slip_cnt  <= 32'd0;
            out_valid <= 1'b0;
            out_i     <= '0;
            out_q     <= '0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) begin
                d1_i      <= in_i;
                d1_q      <= in_q;
                have_prev <= 1'b1;

                if (!cfg_en) begin
                    // 旁路：直通，时间轴不变（无 1 拍插值延迟）
                    out_valid <= 1'b1;
                    out_i     <= in_i;
                    out_q     <= in_q;
                end else if (have_prev) begin
                    delta = real'(cfg_sfo_ppm) * 1.0e-6;
                    y_i   = (1.0 - mu) * real'(d1_i) + mu * real'(in_i);
                    y_q   = (1.0 - mu) * real'(d1_q) + mu * real'(in_q);
                    qi    = quant_rne_sat(y_i / scale, W, FRAC);
                    qq    = quant_rne_sat(y_q / scale, W, FRAC);
                    out_valid <= 1'b1;
                    out_i     <= qi[W-1:0];
                    out_q     <= qq[W-1:0];
                    mu_used   <= mu;          // 与 out_i 同拍：TB 在同一沿读到的就是这一拍的 μ

                    mu_n = mu + delta;
                    if (mu_n >= 1.0) begin
                        mu_n     = mu_n - 1.0;
                        slip_cnt <= slip_cnt + 32'd1;
                    end
                    mu <= mu_n;
                end
            end
        end
    end

endmodule
