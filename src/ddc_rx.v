// =====================================================================
// ddc_rx.v — S5 接收链 · 数字下变频（CIC 抽取 + 匹配 FIR）
//
// 规格: docs/spec/s5_rx_interface.md §4.1（结构冻结）
// 判据: 与 golden_ref.fixed_point.rx_modules.fixed_ddc_rx 逐采样位真一致（0 错误）
// 参数: config.RX_CONFIG 冻结值：N=3、M=1、D=4、累加器 48 bit
// 系数: src/srrc_coeff.vh（与发射 SRRC 同源，Q1.11 原始序 h[0..32]）
//
// 结构（§4.1 冻结，两段串接、顺序不可颠倒）：
//   1. CIC 抽取：N=3 级积分器（f_adc 速率）→ 抽取 D → N=3 级梳状器（输出速率，M=1）；
//      增益 (D·M)^N = 64 = 2^6，输出右移 6 位（round half-to-even）还原单位增益；
//   2. 匹配 FIR：33 抽头 SRRC（与发射端同源系数），4 sps 速率，输出 Q3.11。
//
// 位真口径（与 fixed_ddc_rx 逐语义对应，勿改）：
//   · 抽取相位 = 每组第 1 拍：样本序号 n 按 din_valid 连续计数，n % D == 0 的拍上
//     取积分器链的**当场新值**（模型 acc[i] = 吃进 x[i] 后的状态，y[::D]）；
//   · 积分器/梳状器 48 bit **补码卷绕**（寄存器位宽天然实现，正常量级不触发）；
//   · 舍入一律 round half-to-even（进位 = round_bit && (sticky || lsb)），且只在
//     两个量化点丢位：CIC 增益归一（>>6）、FIR 量化（>>11 + 饱和 14 bit）；
//   · FIR 全卷积语义：输出 n_dc + 32 拍——流结束后补 32 个零样本收尾
//     （= np.convolve full 的尾部零填充）。
//
// 流水结构（只影响延迟，不影响位真）：
//   · CIC 输出登记 1 拍；匹配 FIR 用**转置型 DSP48E1 级联**：每级
//     P = x·h + P_pre 显式打拍，级联尾即卷积输出（系数逆序 SRRC_H[32−j]），
//     不走 srrc_duc 手写版那种组合 MAC 长链（曾把 Fmax 拖到 33.79 MHz）；
//   · 输出量化再登记 1 拍：输入拍 → 输出拍延迟 3 拍，吞吐 1 拍/输出。
//
// 输入契约（与向量口径一致）：单流——复位后一段连续激励，din_valid 断 ≥ D 拍
// 视为流结束，补 32 拍零样本收尾后停；跨流重启/背压未定义。
// =====================================================================
`timescale 1ns/1ps

`default_nettype none

`include "srrc_coeff.vh"

module ddc_rx #(
    parameter int DECIM_RATIO = 4,     // 抽取比 D = f_adc / 2 MSPS；S5 验证档位 D = 4（f_adc = 8 MSPS）
    parameter bit USE_CIC_IP  = 1'b0   // 1 = CIC Compiler IP 版轨道；0 = 手写 RTL 版
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         din_valid,
    input  wire  [23:0] din_data,      // ADC 复采样 {i[11:0], q[11:0]}（AD9363 原生 12 bit 补码）
    output logic        dout_valid,
    output logic [27:0] dout_data      // 4 sps 复采样 {i[13:0], q[13:0]}（Q3.11）
);

    // ------------------------------------------------------------------
    // IP 轨道预留（§4.1 双轨纪律：IP 版与手写版共用同一套向量/TB，位真须一致）。
    // CIC Compiler IP 由 build/gen_cic_compiler.tcl 生成后接入（参照 gen_fir_compiler.tcl
    // 先例）；接入前选 IP 轨直接报错，不静默降级到手写版。
    // ------------------------------------------------------------------
    initial if (USE_CIC_IP) $fatal(1, "ddc_rx: USE_CIC_IP=1 轨道未接入，当前交付为手写 RTL 版");

    // ------------------------------------------------------------------
    // 位真常量（config.RX_CONFIG / s5_rx_interface.md §4.1 冻结）
    // ------------------------------------------------------------------
    localparam int CIC_STAGES     = 3;
    localparam int CIC_DIFF_DELAY = 1;    // M=1 冻结；改 M 需扩梳状延迟线深度
    localparam int CIC_ACC_W      = 48;
    // 增益 (D·M)^N = 64 = 2^6；D 换档须保证增益仍是 2 的幂（模型同款断言）
    localparam int CIC_GAIN_SH    = CIC_STAGES * $clog2(DECIM_RATIO * CIC_DIFF_DELAY);
    localparam int NUM_TAPS       = 33;
    localparam int FIR_SHIFT      = 11;   // Q1.11 系数 → Q3.11 输出整数
    localparam int TAIL_BEATS     = NUM_TAPS - 1;   // 32：full 卷积尾部零样本数

    // ------------------------------------------------------------------
    // 整数工具（与 sync_rx.v 同款：64 bit 全精度中间，只在量化点舍入/饱和）
    // ------------------------------------------------------------------

    // 有理右移 sh 位，round half-to-even（= np.round / _round_shift_half_even）：
    // q = floor(x/2^sh)（算术右移），r = x − q·2^sh ∈ [0, 2^sh)，
    // 进位 = (r > 2^(sh−1)) || (r == 2^(sh−1) && q 为奇)
    function automatic signed [63:0] rsh_he;
        input signed [63:0] x;
        input integer       sh;
        logic signed [63:0] q;
        logic        [63:0] r, half;
        begin
            q    = x >>> sh;
            r    = x - (q <<< sh);
            half = 64'd1 << (sh - 1);
            rsh_he = ((r > half) || ((r == half) && q[0])) ? q + 64'sd1 : q;
        end
    endfunction

    function automatic signed [13:0] sat14;
        input signed [63:0] v;
        begin
            if      (v >  64'sd8191)  sat14 = 14'sd8191;
            else if (v < -64'sd8192)  sat14 = -14'sd8192;
            else                      sat14 = 14'(v);
        end
    endfunction

    // ------------------------------------------------------------------
    // 流控：样本节拍 / 抽取相位 / 流结束收尾
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {ST_IDLE, ST_RUN, ST_DRAIN, ST_DONE} state_e;
    state_e state;

    int unsigned decim_cnt;    // 有效样本序号 mod D（抽取相位）
    int unsigned idle_cnt;     // 连续无有效输入拍数（流结束检测）
    int unsigned drain_left;   // 收尾剩余零样本数

    wire samp_beat  = din_valid && (state != ST_DRAIN) && (state != ST_DONE);
    wire decim_beat = samp_beat && (decim_cnt == 0);
    wire drain_beat = (state == ST_DRAIN);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            decim_cnt  <= 0;
            idle_cnt   <= 0;
            drain_left <= 0;
        end else begin
            // 样本计数只跟 din_valid 走（拍间隔不进语义，与模型序列语义一致）
            if (samp_beat) begin
                decim_cnt <= (decim_cnt == DECIM_RATIO - 1) ? 0 : decim_cnt + 1;
                idle_cnt  <= 0;
            end else if (state == ST_RUN) begin
                idle_cnt <= idle_cnt + 1;
            end

            case (state)
                ST_IDLE: if (din_valid) state <= ST_RUN;
                ST_RUN: begin
                    // din_valid 断 ≥ D 拍 = 流结束（收尾前 CIC 输出必已登记完，无碰撞）
                    if (!samp_beat && (idle_cnt + 1 >= DECIM_RATIO)) begin
                        state      <= ST_DRAIN;
                        drain_left <= TAIL_BEATS;
                        decim_cnt  <= 0;
                    end
                end
                ST_DRAIN: begin
                    drain_left <= drain_left - 1;
                    if (drain_left == 1) state <= ST_DONE;
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // CIC 抽取（I/Q 两路同构；48 bit 补码卷绕 = 模 2^48，寄存器位宽天然实现）
    // ------------------------------------------------------------------
    logic signed [11:0] xin [0:1];
    assign xin[0] = din_data[23:12];
    assign xin[1] = din_data[11:0];

    logic signed [CIC_ACC_W-1:0] integ   [0:1][0:CIC_STAGES-1];   // 积分器（f_adc 速率）
    logic signed [CIC_ACC_W-1:0] dly_y   [0:1];                   // 梳状 1 级延迟（= 抽取点积分值）
    logic signed [CIC_ACC_W-1:0] comb_d  [0:1][0:CIC_STAGES-2];   // 梳状 2/3 级延迟

    // 当场新值：抽取点取的是"吃进本拍样本后"的积分链值（模型 acc[i] 语义）
    logic signed [CIC_ACC_W-1:0] integ_n [0:1][0:CIC_STAGES-1];
    logic signed [CIC_ACC_W-1:0] comb_n  [0:1][0:CIC_STAGES-1];

    generate
        for (genvar ch = 0; ch < 2; ch++) begin : g_cic
            assign integ_n[ch][0] = integ[ch][0] + xin[ch];
            for (genvar s = 1; s < CIC_STAGES; s++)
                assign integ_n[ch][s] = integ[ch][s] + integ_n[ch][s-1];

            assign comb_n[ch][0] = integ_n[ch][CIC_STAGES-1] - dly_y[ch];
            for (genvar s = 1; s < CIC_STAGES; s++)
                assign comb_n[ch][s] = comb_n[ch][s-1] - comb_d[ch][s-1];
        end
    endgenerate

    logic signed [63:0] cic_dat [0:1];   // CIC 输出（>>6 增益归一后，Q3.11 整数刻度）
    logic               cic_v;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int ch = 0; ch < 2; ch++) begin
                for (int s = 0; s < CIC_STAGES; s++)   integ[ch][s]  <= '0;
                for (int s = 0; s < CIC_STAGES-1; s++) comb_d[ch][s] <= '0;
                dly_y[ch]   <= '0;
                cic_dat[ch] <= '0;
            end
            cic_v <= 1'b0;
        end else begin
            cic_v <= decim_beat;
            for (int ch = 0; ch < 2; ch++) begin
                if (samp_beat)
                    for (int s = 0; s < CIC_STAGES; s++) integ[ch][s] <= integ_n[ch][s];

                if (decim_beat) begin
                    dly_y[ch] <= integ_n[ch][CIC_STAGES-1];
                    for (int s = 0; s < CIC_STAGES-1; s++) comb_d[ch][s] <= comb_n[ch][s];
                    cic_dat[ch] <= rsh_he(comb_n[ch][CIC_STAGES-1], CIC_GAIN_SH);
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 匹配 FIR（转置型 DSP48E1 级联，1 拍 1 个输出）
    //   a_j[k] = x[k]·h[32−j] + a_{j−1}[k−1]，级联尾 a_32[k] = Σ_m h[m]·x[k−m]
    //   = np.convolve full 第 k 点；系数逆序取 SRRC_H[NUM_TAPS-1-j]。
    //   每级 P 寄存器显式打拍（x·h 乘积与 P_pre 都在级内登记），级间无组合长链。
    // ------------------------------------------------------------------
    logic signed [63:0] fir_x   [0:1];
    logic signed [63:0] fir_acc [0:1][0:NUM_TAPS-1];

    wire fir_beat = cic_v || drain_beat;   // 收尾拍喂 0（= 尾部零填充）

    assign fir_x[0] = drain_beat ? 64'sd0 : cic_dat[0];
    assign fir_x[1] = drain_beat ? 64'sd0 : cic_dat[1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int ch = 0; ch < 2; ch++)
                for (int j = 0; j < NUM_TAPS; j++) fir_acc[ch][j] <= '0;
        end else if (fir_beat) begin
            for (int ch = 0; ch < 2; ch++) begin
                fir_acc[ch][0] <= fir_x[ch] * $signed(SRRC_H[NUM_TAPS-1]);
                for (int j = 1; j < NUM_TAPS; j++)
                    fir_acc[ch][j] <= fir_x[ch] * $signed(SRRC_H[NUM_TAPS-1-j])
                                      + fir_acc[ch][j-1];
            end
        end
    end

    // ------------------------------------------------------------------
    // 输出量化：>>11 round half-to-even + 饱和 14 bit（Q3.11），再登记 1 拍
    // ------------------------------------------------------------------
    logic y_val;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_val      <= 1'b0;
            dout_valid <= 1'b0;
            dout_data  <= '0;
        end else begin
            y_val      <= fir_beat;
            dout_valid <= y_val;
            if (y_val)
                dout_data <= {sat14(rsh_he(fir_acc[0][NUM_TAPS-1], FIR_SHIFT)),
                              sat14(rsh_he(fir_acc[1][NUM_TAPS-1], FIR_SHIFT))};
        end
    end

endmodule

`default_nettype wire
