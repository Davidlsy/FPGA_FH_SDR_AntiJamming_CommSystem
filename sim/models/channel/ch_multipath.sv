// =====================================================================
// ch_multipath.sv — S2 信道模型库 · 多径（瑞利 / 莱斯，准静态）
//
// 抽头系数按「指数功率延迟谱 + 首径莱斯」生成：
//     p_k        ∝ 10^(-k·PDP_DECAY_DB/10)，归一化使 Σp_k = 1
//     首径（t=0） 按 K 拆成视距 + 散射：视距功率 p_0·K/(K+1)，散射功率 p_0/(K+1)
//     其余抽头   纯瑞利，功率即 p_k
// 于是 **E|h_k|² = p_k 对所有抽头成立，Σ E|h_k|² = 1**，K 的定义为
// 「首径视距功率 / 首径散射功率」——这个定义下由首径样本估出的 K 直接等于配置值。
//
// 注意不要把 (K+1) 摊到所有抽头：那样除首径外的抽头会白掉 (K+1) 倍功率，
// 总功率不再为 1（K=6 dB 时实测只剩 0.628）。
//
// 准静态：一次 burst 内系数不变，由 cfg_reseed 脉冲重新抽取（统计核验就是
// 靠连续 reseed 采 |h| 的样本）。**时变衰落（多普勒谱）未建模**——见 README
// 的已知边界；若 S6/S8 需要时变，往 cfg_reseed 喂 burst 边界即可先跑通，
// 真正的多普勒成形需要另加成形滤波器。
//
// cfg_en = 0 时直通（逐位相等，仅晚一拍）。
// =====================================================================
`timescale 1ns/1ps

module ch_multipath #(
    parameter int    W            = 14,
    parameter int    FRAC         = 11,
    parameter int    NTAPS        = 4,
    parameter real   PDP_DECAY_DB = 3.0,
    parameter logic [31:0] SEED   = 32'h5EED_0F17
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic signed [W-1:0] in_i,
    input  logic signed [W-1:0] in_q,
    input  logic                cfg_en,
    input  logic signed [31:0]  cfg_k_db_x10,   // 莱斯 K (dB×10)；给很小的值即纯瑞利
    input  logic                cfg_reseed,
    output logic                out_valid,
    output logic signed [W-1:0] out_i,
    output logic signed [W-1:0] out_q
);
    import ch_pkg::*;

    localparam int MAXTAPS = 16;

    // 抽头系数与功率（TB 经层次引用读取用于核验）
    real h_i [0:MAXTAPS-1];
    real h_q [0:MAXTAPS-1];
    real p_k [0:MAXTAPS-1];

    logic [31:0] seed_q;
    logic signed [W-1:0] dl_i [0:MAXTAPS-1];
    logic signed [W-1:0] dl_q [0:MAXTAPS-1];

    real    scale, acc_i, acc_q;
    longint qi, qq;

    initial begin
        scale = 2.0 ** FRAC;
    end

    // -----------------------------------------------------------------
    // 抽头生成：k_db 为莱斯 K（dB）
    // -----------------------------------------------------------------
    task automatic gen_taps(input real k_db);
        real k_lin, p_tot, scat_sigma, los_amp;
        begin
            k_lin = (k_db <= -100.0) ? 0.0 : (10.0 ** (k_db / 10.0));
            p_tot = 0.0;
            for (int t = 0; t < MAXTAPS; t++) begin
                if (t < NTAPS) p_k[t] = 10.0 ** (-(real'(t) * PDP_DECAY_DB) / 10.0);
                else           p_k[t] = 0.0;
                p_tot = p_tot + p_k[t];
            end
            for (int t = 0; t < MAXTAPS; t++) p_k[t] = p_k[t] / p_tot;

            for (int t = 0; t < MAXTAPS; t++) begin
                // 首径按 K 拆分；其余抽头纯瑞利，功率即 p_k（不摊 (K+1)）
                if (t == 0) scat_sigma = $sqrt(p_k[0] / (2.0 * (k_lin + 1.0)));
                else        scat_sigma = $sqrt(p_k[t] / 2.0);
                cgauss(seed_q, scat_sigma, h_i[t], h_q[t]);
            end

            los_amp = $sqrt(p_k[0] * k_lin / (k_lin + 1.0));
            h_i[0]  = h_i[0] + los_amp;
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 种子与抽头只在**这一个进程**里写：xsim 不允许同一变量被两个进程驱动，
            // 把 gen_taps 放到 initial 里会与这里的复位分支冲突（VRFC 10-3818）
            seed_q    = seed_nz(SEED);
            out_valid <= 1'b0;
            out_i     <= '0;
            out_q     <= '0;
            for (int t = 0; t < MAXTAPS; t++) begin
                dl_i[t] <= '0;
                dl_q[t] <= '0;
            end
            gen_taps(real'(cfg_k_db_x10) / 10.0);
        end else begin
            out_valid <= in_valid;
            if (cfg_reseed) gen_taps(real'(cfg_k_db_x10) / 10.0);

            if (in_valid) begin
                for (int t = MAXTAPS-1; t > 0; t--) begin
                    dl_i[t] <= dl_i[t-1];
                    dl_q[t] <= dl_q[t-1];
                end
                dl_i[0] <= in_i;
                dl_q[0] <= in_q;

                if (cfg_en) begin
                    // 标准因果 FIR：y[m] = Σ_{t} h[t]·x[m-t]，抽头 0 乘**当前**输入，
                    // 因此冲激响应与系数逐拍一一对应（否则整体多一拍延迟）
                    acc_i = h_i[0] * real'(in_i) - h_q[0] * real'(in_q);
                    acc_q = h_i[0] * real'(in_q) + h_q[0] * real'(in_i);
                    for (int t = 1; t < NTAPS; t++) begin
                        acc_i = acc_i + h_i[t] * real'(dl_i[t-1]) - h_q[t] * real'(dl_q[t-1]);
                        acc_q = acc_q + h_i[t] * real'(dl_q[t-1]) + h_q[t] * real'(dl_i[t-1]);
                    end
                    qi = quant_rne_sat(acc_i / scale, W, FRAC);
                    qq = quant_rne_sat(acc_q / scale, W, FRAC);
                    out_i <= qi[W-1:0];
                    out_q <= qq[W-1:0];
                end else begin
                    out_i <= in_i;
                    out_q <= in_q;
                end
            end
        end
    end

endmodule
