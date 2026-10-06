// =====================================================================
// srrc_duc.v — S4 发射链 · SRRC 脉冲成形 + NCO 上变频（DUC）
//
// 规格: docs/spec/s4_tx_interface.md §4.5/§5、docs/spec/s4_tx_p3_freeze_draft.md 决策 1
// 判据: 输出与 golden_ref.fixed_point.duc.fixed_srrc_duc 逐拍位真一致（0 错误）
//
// 结构（三一段串接，采样时钟域，每采样节拍产出 1 个采样点）:
//   1. SRRC 33 抽头上采样 ×4 多相滤波器（符号 1/4 节奏进，采样连续出）
//   2. NCO：16 bit 相位累加器 + 四分之一波 sin/cos LUT（相位不清零，S6 跳频预留）
//   3. DUC 复数混频：I' = I·cos − Q·sin，Q' = I·sin + Q·cos，输出 Q5.11
//
// 多相分解（33 = 9 + 8 + 8 + 8，相位 0 有 9 抽头）:
//     shaped[4a+p] = Σ_j h[p + 4j] · sym[a−j]，p = 0..3
//   系数来自 src/srrc_coeff.vh（原始序 h[0..32]，12 bit Q1.11），多相索引在 RTL 内完成。
//
// 位真一致的两条硬口径（决策 1.5）:
//   · 输出拍数 = 4N + 32（full 卷积）：符号流结束后再输出 32 拍拖尾（NUM_TAPS−1）。
//   · 舍入 round half-to-even：进位 = round_bit && (sticky || lsb)，与 np.round 一致，
//     不是 half-up（SRRC 量化到 14 bit 时有采样恰逢 .5，half-up 会差 1 LSB）。
//
// NCO LUT 镜像公式（决策 1.3，RTL 必须逐项复刻）:
//     四分之一波表 [0, π/2) 共 2^14 项，高 2 bit 定象限、低 14 bit 定 idx，
//     镜像 mirror = 16383 − idx；cos(p) = sin(p + 2^14)。
// =====================================================================
`timescale 1ns/1ps

`include "srrc_coeff.vh"

module srrc_duc #(
    parameter int  NUM_TAPS      = 33,        // SRRC 抽头数（§7 偏差 #1：33 而非 31）
    parameter int  UPSAMPLE      = 4,         // 上采样因子
    parameter int  NCO_PHASE_W   = 16,        // NCO 相位累加器位宽
    parameter int  NCO_LUT_FRAC  = 14,        // NCO LUT 小数位（Q2.14）
    parameter int  NCO_LUT_DEPTH = 16384,     // 四分之一波 LUT 深度 2^(NCO_PHASE_W-2)
    parameter int  SRRC_OUT_W    = 14,        // SRRC 输出位宽（Q3.11）
    parameter int  SRRC_FRAC     = 11,
    parameter int  DUC_OUT_W     = 16,        // DUC 输出位宽（Q5.11）
    parameter int  DUC_FRAC      = 11,
    parameter string LUT_FILE    = "../../src/nco_lut.mem"  // 相对 sim/framework 目录的 xsim cwd（上两级到项目根）
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [23:0] din_data,      // {i_in[11:0], q_in[11:0]}，QPSK 符号 Q2.10
    input  logic [15:0] freq_word,     // NCO 频率字（S4 固定频点 = 8192）
    input  logic        freq_valid,    // 高电平时下一拍载入 freq_word（S6 跳频用）
    output logic        dout_valid,
    output logic [31:0] dout_data      // {i_out[15:0], q_out[15:0]}，DUC 输出 Q5.11
);

    // 每相抽头数：相位 0 有 9 抽头（h[0,4,...,32]），其余 8
    localparam int TAPS_P0 = (NUM_TAPS + UPSAMPLE - 1) / UPSAMPLE;  // 9
    localparam int TAPS_PX = NUM_TAPS / UPSAMPLE;                   // 8

    logic [1:0] out_phase;     // 输出采样相位 0..3（被 drain_shift 前向引用，故提前声明）

    // ------------------------------------------------------------------
    // 符号延迟线（9 级，保存最近 9 个符号；I/Q 各一路）
    // ------------------------------------------------------------------
    logic signed [11:0] sreg_i [0:TAPS_P0-1];
    logic signed [11:0] sreg_q [0:TAPS_P0-1];

    // 拖尾补零 shift：out_phase==3 且无符号（符号流结束，模拟后续符号位置为 0）
    wire drain_shift = (out_phase == (UPSAMPLE-1)) && !din_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int j = 0; j < TAPS_P0; j++) begin
                sreg_i[j] <= '0;
                sreg_q[j] <= '0;
            end
        end else if (din_valid || drain_shift) begin
            sreg_i[0] <= din_valid ? din_data[23:12] : 12'sd0;
            sreg_q[0] <= din_valid ? din_data[11:0] : 12'sd0;
            for (int j = 1; j < TAPS_P0; j++) begin
                sreg_i[j] <= sreg_i[j-1];
                sreg_q[j] <= sreg_q[j-1];
            end
        end
    end

    // ------------------------------------------------------------------
    // 状态机：IDLE → RUN → DRAIN → IDLE
    //   IDLE  等第一个符号
    //   RUN   输出采样；din_valid 时加载符号；连续 4 拍无符号 → DRAIN
    //   DRAIN 输出 32 拍拖尾（NUM_TAPS-1）后回 IDLE
    // ------------------------------------------------------------------
    localparam [1:0] ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_DRAIN = 2'd2;

    logic [1:0] state;
    logic [2:0] sym_idle;      // 连续无符号拍数（0..7）
    logic [5:0] drain_cnt;     // 拖尾计数 0..NUM_TAPS-2

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            out_phase <= '0;
            sym_idle  <= '0;
            drain_cnt <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (din_valid) begin
                        state     <= ST_RUN;
                        out_phase <= '0;
                        sym_idle  <= '0;
                    end
                end
                ST_RUN: begin
                    out_phase <= out_phase + 1'b1;
                    if (din_valid)
                        sym_idle <= '0;
                    else
                        sym_idle <= sym_idle + 1'b1;
                    // 连续 UPSAMPLE 拍无符号（最后符号已过）→ 排空
                    if (!din_valid && sym_idle >= (UPSAMPLE - 1)) begin
                        state     <= ST_DRAIN;
                        drain_cnt <= '0;
                    end
                end
                ST_DRAIN: begin
                    out_phase <= out_phase + 1'b1;
                    if (drain_cnt >= (NUM_TAPS - 2))
                        state <= ST_IDLE;
                    drain_cnt <= drain_cnt + 1'b1;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // SRRC 多相乘累加（每相位独立，generate 展开；静态系数索引）
    // 乘积 12×12=24 bit（Q3.21），累加 9 项用 28 bit（Q6.21）不溢出
    // ------------------------------------------------------------------
    logic signed [27:0] acc_i [0:UPSAMPLE-1];
    logic signed [27:0] acc_q [0:UPSAMPLE-1];

    generate
        for (genvar gp = 0; gp < UPSAMPLE; gp++) begin : srrc_phase
            localparam int TAPS = (gp == 0) ? TAPS_P0 : TAPS_PX;
            always_comb begin
                acc_i[gp] = '0;
                acc_q[gp] = '0;
                for (int j = 0; j < TAPS; j++) begin
                    acc_i[gp] = acc_i[gp] + $signed(SRRC_H[gp + UPSAMPLE * j]) * sreg_i[j];
                    acc_q[gp] = acc_q[gp] + $signed(SRRC_H[gp + UPSAMPLE * j]) * sreg_q[j];
                end
            end
        end
    endgenerate

    wire signed [27:0] srrc_i_full = acc_i[out_phase];
    wire signed [27:0] srrc_q_full = acc_q[out_phase];

    // ------------------------------------------------------------------
    // SRRC 输出量化：28 bit Q6.21 → 14 bit Q3.11（round half-to-even + saturate）
    // ------------------------------------------------------------------
    function automatic signed [SRRC_OUT_W-1:0] quant_srrc;
        input signed [27:0] v;
        logic round_bit, sticky, lsb, carry;
        logic signed [27:0] v2;
        begin
            // DROP = (2*SRRC_FRAC) - SRRC_FRAC ... 实际 = SRRC_FRAC = 11，见下：
            // 乘积 Q3.21 → 输出 Q3.11，丢弃 21 - 11 = 10 位
            round_bit = v[9];
            sticky    = |v[8:0];
            lsb       = v[10];
            carry     = round_bit && (sticky || lsb);
            v2 = v + (carry ? 28'sd1024 : 28'sd0);   // 1024 = 1 << 10
            if (v2 > (28'sd8191 << 10))
                quant_srrc = SRRC_OUT_W'(8191);
            else if (v2 < -(28'sd8192 << 10))
                quant_srrc = SRRC_OUT_W'(-8192);
            else
                quant_srrc = SRRC_OUT_W'(v2 >>> 10);
        end
    endfunction

    // ------------------------------------------------------------------
    // NCO：16 bit 相位累加器 + 四分之一波 sin LUT
    // ------------------------------------------------------------------
    logic [15:0]                ftw;       // 生效频率字
    logic [NCO_PHASE_W-1:0]     phase_acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          ftw <= '0;
        else if (freq_valid) ftw <= freq_word;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          phase_acc <= '0;
        else if (state == ST_RUN || state == ST_DRAIN)
            phase_acc <= phase_acc + ftw;
    end

    // 四分之一波 LUT（$readmemh 加载，16 bit Q2.14）
    reg signed [15:0] nco_lut [0:NCO_LUT_DEPTH-1];
    initial $readmemh(LUT_FILE, nco_lut);

    // 四象限 sin 查表
    function automatic signed [15:0] sin_lut;
        input [NCO_PHASE_W-1:0] p;
        reg [1:0]  q;
        reg [13:0] idx, mir;
        begin
            q   = p[NCO_PHASE_W-1:NCO_PHASE_W-2];
            idx = p[NCO_PHASE_W-3:0];
            mir = 14'h3FFF - idx;
            case (q)
                2'd0: sin_lut = nco_lut[idx];
                2'd1: sin_lut = nco_lut[mir];
                2'd2: sin_lut = -nco_lut[idx];
                2'd3: sin_lut = -nco_lut[mir];
            endcase
        end
    endfunction

    // cos(p) = sin(p + π/2) = sin(p + 2^(NCO_PHASE_W-2))
    wire [NCO_PHASE_W-1:0] phase_cos = phase_acc + (1 << (NCO_PHASE_W - 2));

    // ------------------------------------------------------------------
    // DUC 复数混频 + 量化到 Q5.11
    // ------------------------------------------------------------------
    logic signed [SRRC_OUT_W-1:0] srrc_i_q, srrc_q_q;   // 量化后的 SRRC 输出
    logic signed [15:0]           cos_v, sin_v;         // NCO 查表值
    logic signed [31:0]           i_mix_full, q_mix_full;

    function automatic signed [DUC_OUT_W-1:0] quant_duc;
        input signed [31:0] v;
        logic round_bit, sticky, lsb, carry;
        logic signed [31:0] v2;
        begin
            // 乘积 Q3.11 × Q2.14 = Q5.25 → 输出 Q5.11，丢弃 25 - 11 = 14 位
            round_bit = v[13];
            sticky    = |v[12:0];
            lsb       = v[14];
            carry     = round_bit && (sticky || lsb);
            v2 = v + (carry ? 32'sd16384 : 32'sd0);     // 16384 = 1 << 14
            if (v2 > (32'sd32767 << 14))
                quant_duc = DUC_OUT_W'(32767);
            else if (v2 < -(32'sd32768 << 14))
                quant_duc = DUC_OUT_W'(-32768);
            else
                quant_duc = DUC_OUT_W'(v2 >>> 14);
        end
    endfunction

    always_comb begin
        srrc_i_q = quant_srrc(srrc_i_full);
        srrc_q_q = quant_srrc(srrc_q_full);

        cos_v = sin_lut(phase_cos);
        sin_v = sin_lut(phase_acc);

        // I' = I·cos − Q·sin ; Q' = I·sin + Q·cos（全精度中间）
        i_mix_full = $signed(srrc_i_q) * cos_v - $signed(srrc_q_q) * sin_v;
        q_mix_full = $signed(srrc_i_q) * sin_v + $signed(srrc_q_q) * cos_v;
    end

    // 输出寄存器
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_valid <= 1'b0;
            dout_data  <= '0;
        end else begin
            dout_valid <= (state == ST_RUN) || (state == ST_DRAIN);
            dout_data  <= {quant_duc(i_mix_full), quant_duc(q_mix_full)};
        end
    end

endmodule

`default_nettype wire
