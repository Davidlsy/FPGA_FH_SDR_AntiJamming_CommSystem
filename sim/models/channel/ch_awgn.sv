// =====================================================================
// ch_awgn.sv — S2 信道模型库 · 加性高斯白噪声
//
// 噪声功率口径与 golden_ref.float_chain.awgn.add_awgn **同源**：
//     eb  = Es / bit_rate                     （bit_rate = QPSK 2 bit × 码率 1/2 = 1）
//     n0  = eb / 10^(EbN0/10)
//     每维方差 = n0 / 2                       （复噪声总功率 = n0）
// 若这里换了口径，S8 环回的 BER 曲线就对不上 S1 基线，且这种差异极难定位。
//
// 输出按规格书「AWGN 信道输出」量化为 14 bit / 11 小数（半值取偶 + 饱和）。
//
// cfg_en = 0 时直通（逐位相等，仅晚一拍），便于 TB 分相位测单通道效应。
// TB 可经层次引用读 sigma（实数）用于核验，模型本身不为此加端口。
// =====================================================================
`timescale 1ns/1ps

module ch_awgn #(
    parameter int    W        = 14,
    parameter int    FRAC     = 11,
    parameter real   ES       = 1.0,          // 符号能量 Es（与 S1 add_awgn 同定义）
    parameter real   BIT_RATE = 1.0,          // 每符号信息比特
    parameter real   EB_N0_DB = 4.0,
    parameter logic [31:0] SEED = 32'hA5A5_1234
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid,
    input  logic signed [W-1:0] in_i,
    input  logic signed [W-1:0] in_q,
    input  logic                cfg_en,
    output logic                out_valid,
    output logic signed [W-1:0] out_i,
    output logic signed [W-1:0] out_q
);
    import ch_pkg::*;

    real    sigma;          // 每维标准差（TB 核验用）
    real    scale;
    real    ni, nq;
    longint qi, qq;

    logic [31:0] seed_q;

    initial begin
        sigma = $sqrt(((ES / BIT_RATE) / (10.0 ** (EB_N0_DB / 10.0))) / 2.0);
        scale = 2.0 ** FRAC;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_q    <= seed_nz(SEED);
            out_valid <= 1'b0;
            out_i     <= '0;
            out_q     <= '0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                if (cfg_en) begin
                    ni = sigma * gauss01(seed_q);
                    nq = sigma * gauss01(seed_q);
                    qi = quant_rne_sat(real'(in_i) / scale + ni, W, FRAC);
                    qq = quant_rne_sat(real'(in_q) / scale + nq, W, FRAC);
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
