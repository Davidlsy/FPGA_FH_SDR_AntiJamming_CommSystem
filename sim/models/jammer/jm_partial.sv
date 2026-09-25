// =====================================================================
// jm_partial.sv — S2 干扰注入源 · 部分频带干扰（带限噪声）
//
// 做法：先在**全速率**上产生复高斯白噪声，用长度 D 的滑动平均低通，再搬移到
// 中心频率 cfg_pb_ftw。等效于把白噪声限制在标称带宽内，再放到带内任意位置。
//
// 为什么用滑动平均而不是「输入 D 倍抽取 + 插值」：抽取+线性插值的输出功率随
// 插值系数变化（μ=0.5 时只剩 2/3 功率），JSR 就不准了；滑动平均的输出功率
// 恒为输入功率的 1/D，乘 sqrt(D) 即精确归一，JSR 才有意义。
//
// 标称带宽：滑动平均的 |H(f)|² ≈ sinc²(fD/fs)，-3 dB 点在一侧 0.44·fs/D，
// 即**双边 -3 dB 带宽 ≈ 0.88·fs/D**（D=1 退化为全带白噪声）。
// 复位后前 D 拍滤波缓冲为空，功率偏低，核验时跳过前 D 拍。
// =====================================================================
`timescale 1ns/1ps

module jm_partial #(
    parameter int SRC_W    = 16,
    parameter int SRC_FRAC = 13,
    parameter int MAXD     = 256
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic        [7:0]   cfg_div,       // 滑动平均长度 D（1 = 全带白噪声）
    input  logic        [31:0]  cfg_ftw,       // 中心频率（相位增量）
    input  logic        [31:0]  seed_init,
    output logic                src_valid,
    output logic signed [SRC_W-1:0] src_i,
    output logic signed [SRC_W-1:0] src_q
);
    import ch_pkg::*;

    real    buf_i [0:MAXD-1];
    real    buf_q [0:MAXD-1];
    int     idx;
    int     div;
    real    sum_i, sum_q;
    real    ni, nq, base_i, base_q, norm, ph_rad, ci, cs;
    longint qi, qq;

    logic [31:0] seed_q;
    logic [31:0] ph_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_q    <= seed_nz(seed_init);
            ph_c      <= 32'h0;
            idx       <= 0;
            sum_i     = 0.0;
            sum_q     = 0.0;
            for (int k = 0; k < MAXD; k++) begin
                buf_i[k] = 0.0;
                buf_q[k] = 0.0;
            end
            src_valid <= 1'b0;
            src_i     <= '0;
            src_q     <= '0;
        end else begin
            src_valid <= in_valid;
            if (in_valid) begin
                div = int'(cfg_div);
                if (div < 1)    div = 1;
                if (div > MAXD) div = MAXD;

                // 单位功率复噪声（每维方差 1/2）
                ni = gauss01(seed_q) * 0.7071067811865476;
                nq = gauss01(seed_q) * 0.7071067811865476;

                // 滑动平均（环形缓冲 + 递推和）
                sum_i = sum_i - buf_i[idx] + ni;
                sum_q = sum_q - buf_q[idx] + nq;
                buf_i[idx] = ni;
                buf_q[idx] = nq;
                idx = (idx + 1) % div;

                // MA 输出方差 = σ²/D，乘 1/sqrt(D) 精确归一为单位功率
                norm   = 1.0 / $sqrt(real'(div));
                base_i = sum_i * norm;
                base_q = sum_q * norm;

                // 搬到中心频率
                ph_rad = 2.0 * PI * real'({1'b0, ph_c[31:1]}) / 2147483648.0;
                ci = $cos(ph_rad);
                cs = $sin(ph_rad);

                qi = quant_rne_sat(base_i * ci - base_q * cs, SRC_W, SRC_FRAC);
                qq = quant_rne_sat(base_i * cs + base_q * ci, SRC_W, SRC_FRAC);
                src_i <= qi[SRC_W-1:0];
                src_q <= qq[SRC_W-1:0];

                ph_c <= ph_c + cfg_ftw;
            end
        end
    end

endmodule
