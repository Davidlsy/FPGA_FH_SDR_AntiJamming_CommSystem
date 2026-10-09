// =====================================================================
// sync_rx.v — S5 接收链 · 符号级同步（二阶 Costas 载波环 + 早迟门定时 + 软解调）
//
// 规格: docs/spec/s5_rx_interface.md §4.2（结构冻结）
// 判据: 与 golden_ref.fixed_point.rx_modules.fixed_sync_rx_hw 逐符号位真一致（0 错误）
// 系数: config.RX_CONFIG 的 Q1.19 冻结值（#3 标定，2026-10-09）——本文件是唯一 RTL 副本
//
// 结构（§4.2 冻结）：更新率 1/符号。全部状态 16 bit **自然补码卷绕**：
//   phase_acc  NCO 载波相位（2^16 = 2π，四分之一波表与 srrc_duc 同源，src/nco_lut.mem）
//   freq_acc   载波频偏积分项（NCO 单位/符号）
//   mu         定时偏移 Q2.14（2^16 = 4 采样 = 1 符号，卷绕即"滑采样"）
//   dt         定时积分项（mu 单位）
//
// 流水语义（与位真模型的块语义逐点等价）：
//   · 样本序号 n 按 din_valid 连续计数（与拍间隔无关），符号 k 消费 x[4k..4k+3]；
//   · 状态 mu 决定采样窗：n0 = 4k + (mu >>> 14)，读 x[n0−1 .. n0+2] 四个采样。
//     mu 是 16 bit 卷绕值，故 mu>>>14 ∈ [−2, 1]，四抽头恒落在最近 7 采样窗内；
//   · **越界读 0**（模型 tap() 语义）由复位后延迟线为 0 天然实现：符号 0 需要的
//     x[−3..−1] 就是尚未移入的 sreg 空位；
//   · 第 4 个采样 x[4k+3] 移入后 1 拍做整符号组合运算并登记（sym_go 单拍脉冲），
//     每 4 个采样恰好 1 个输出符号，尾部不足 4 采样的余数不出符号（n_sym = L//4）。
//
// 每符号 k 的运算序（= fixed_sync_rx_hw 循环体，逐步对应，勿调序）：
//   1. n0 = 4k + (mu >>> 14)，frac = mu[13:0]；
//   2. 早/中/迟三点线性插值（同一 frac）：y = a + round_he((b−a)·frac, 14)；
//   3. te = |late|² − |early|²（Q6.22 → round_he(·,11) + 饱和 → Q3.11）。
//      极性约定：te > 0 = 采样偏早（迟端能量大）→ mu 该增大，`mu += Kp·te` 为负反馈。
//      教训：用 |early|²−|late|² 是正反馈，mu 乱跳而载波残差判据察觉不到；
//   4. 定时环：dt += Ki_t·te；mu += Kp_t·te + dt（先积分项后累加器）；
//   5. Costas 误差取**旧相位**旋转的中点采样：pe = sign(I)·Q − sign(Q)·I，
//      sign(x) = x ≥ 0 ? +1 : −1（取符号位，0 算 +1）；
//   6. 载波环：freq += Ki_c·pe；phase += Kp_c·pe + freq（先积分项后累加器）；
//   7. 判决符号 = 中点采样按**新相位**再旋转一次（Q3.11，饱和）；
//   8. 软判决 = sat8(round_he(符号 × 2896, 17))（√2·x 的 LLR 律，Q3.5）。
//
// 环路乘法统一 inc = round_he(err × coef, 14)，14 = err_frac(11) + coef_frac(19) − acc_w(16)；
// 系数语义 = 每单位误差对应的卷绕周期数（载波：相位周期/误差；定时：符号周期/误差）。
// 冻结值（config.RX_CONFIG）：Costas Kp=2336 Ki=64，定时 Kp=1835 Ki=104（Q1.19）。
//
// 位真两条硬口径：
//   · 舍入一律 **round half-to-even**（进位 = round_bit && (sticky || lsb)），与
//     np.round / S4 量化同口径，不是 half-up；
//   · 中间量全精度（模型是 Python int），只在规定的量化点舍入/饱和，别处不丢位。
// =====================================================================
`timescale 1ns/1ps

`default_nettype none

module sync_rx #(
    parameter string LUT_FILE = "../../src/nco_lut.mem"   // 相对 sim/framework 的 xsim cwd
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         din_valid,
    input  wire  [27:0] din_data,      // {i_in[13:0], q_in[13:0]}，4 sps 复采样 Q3.11
    output logic        dout_valid,
    output logic [27:0] dout_data,     // {sym_i[13:0], sym_q[13:0]}，1 sps 判决符号 Q3.11
    output logic [7:0]  dout_soft_i,   // I 路软判决（8 bit / 5 小数）
    output logic [7:0]  dout_soft_q,   // Q 路软判决（8 bit / 5 小数）
    output logic [15:0] phase_err,     // pe，载波环路可观测（收敛报告用），Q3.11
    output logic [15:0] timing_err     // te，定时环路可观测（收敛报告用），Q3.11
);

    // ------------------------------------------------------------------
    // 位真常量（config.RX_CONFIG / fixed_sync_rx_hw 同源）
    // ------------------------------------------------------------------
    localparam int ACC_W     = 16;                 // 四个状态统一卷绕宽度
    localparam int ERR_FRAC  = 11;                 // pe/te 小数位（Q3.11）
    localparam int COEF_FRAC = 19;                 // 环路系数 Q1.19
    localparam int INC_SHIFT = ERR_FRAC + COEF_FRAC - ACC_W;   // 14：环路乘法右移位数

    // 环路系数 **Q1.19 冻结值**（#3 标定）——修改必须同步 config.RX_CONFIG 与标定报告
    localparam int COSTAS_KP = 2336;
    localparam int COSTAS_KI = 64;
    localparam int TIMING_KP = 1835;
    localparam int TIMING_KI = 104;

    localparam int SOFT_SQRT2_Q11 = 2896;          // round(sqrt(2)·2^11)，软判决 LLR 定点常数

    localparam int NCO_PHASE_W   = 16;
    localparam int NCO_LUT_DEPTH = 16384;

    // ------------------------------------------------------------------
    // 整数工具：64 bit 全精度中间（模型 = Python int），只在量化点舍入/饱和
    // ------------------------------------------------------------------

    // 有理右移 shift 位，round half-to-even（= np.round / _round_shift_half_even）：
    // q = floor(x/2^s)（算术右移），r = x − q·2^s ∈ [0, 2^s)，
    // 进位 = (r > 2^(s−1)) || (r == 2^(s−1) && q 为奇)
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

    function automatic signed [63:0] m64;
        input signed [63:0] a;
        input signed [63:0] b;
        begin
            m64 = a * b;
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

    function automatic signed [15:0] sat16;
        input signed [63:0] v;
        begin
            if      (v >  64'sd32767)  sat16 = 16'sd32767;
            else if (v < -64'sd32768)  sat16 = -16'sd32768;
            else                       sat16 = 16'(v);
        end
    endfunction

    function automatic signed [7:0] sat8;
        input signed [63:0] v;
        begin
            if      (v >  64'sd127)  sat8 = 8'sd127;
            else if (v < -64'sd128)  sat8 = -8'sd128;
            else                     sat8 = 8'(v);
        end
    endfunction

    // 线性插值 a + (b−a)·frac/2^14，round half-to-even。
    // frac < 2^14 且 a/b 是整数格点 → 结果恒落在 [min(a,b), max(a,b)]（14 bit 内），
    // 故直接截 14 bit 不失位——与模型（不饱和的 Python int）等价。
    function automatic signed [13:0] lerp14;
        input signed [13:0] a;
        input signed [13:0] b;
        input        [13:0] frac;
        logic signed [63:0] a64, b64, f64;
        begin
            a64    = a;
            b64    = b;
            f64    = {50'd0, frac};        // frac 无符号，零扩展
            lerp14 = 14'(a64 + rsh_he(m64(b64 - a64, f64), 14));
        end
    endfunction

    // ------------------------------------------------------------------
    // NCO：四分之一波 sin LUT（与 srrc_duc 同源同镜像，S4 决策 1.3）
    // ------------------------------------------------------------------
    reg signed [15:0] nco_lut [0:NCO_LUT_DEPTH-1];
    initial $readmemh(LUT_FILE, nco_lut);

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

    // ------------------------------------------------------------------
    // 状态（16 bit 自然补码卷绕）与采样延迟线（7 级 = 最近 7 采样）
    //   sreg[0] = 最新采样 x[n]；符号 k 完成时 n = 4k+3，sreg[j] = x[4k+3−j]。
    //   复位后未移入的位置自然为 0 = 模型的"越界读 0"。
    // ------------------------------------------------------------------
    logic signed [15:0] phase_r, freq_r, mu_r, dt_r;
    logic signed [13:0] sreg_i [0:6];
    logic signed [13:0] sreg_q [0:6];
    logic        [1:0]  cnt;        // 组内采样序号（样本序号 n = 4k + cnt）
    logic               sym_go;     // 单拍脉冲：第 4 采样已入窗，本拍做整符号运算

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int j = 0; j < 7; j++) begin
                sreg_i[j] <= '0;
                sreg_q[j] <= '0;
            end
            cnt    <= '0;
            sym_go <= 1'b0;
        end else begin
            sym_go <= din_valid && (cnt == 2'd3);
            if (din_valid) begin
                sreg_i[0] <= din_data[27:14];
                sreg_q[0] <= din_data[13:0];
                for (int j = 1; j < 7; j++) begin
                    sreg_i[j] <= sreg_i[j-1];
                    sreg_q[j] <= sreg_q[j-1];
                end
                cnt <= cnt + 2'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 整符号组合运算（顺序 = fixed_sync_rx_hw 循环体，勿调序；结果只在 sym_go 登记）
    // ------------------------------------------------------------------

    // 步 1 的抽头窗：d = mu >>> 14 = mu[15:14] 视作 2 bit 有符号（−2..1），
    // x[n0+2] 在 sreg 的下标 j0 = 1 − d ∈ 0..3，四抽头 = sreg[j0 .. j0+3]。
    logic        [2:0]  j0;
    logic signed [13:0] t0_i, t1_i, t2_i, t3_i;   // x[n0+2], x[n0+1], x[n0], x[n0−1]
    logic signed [13:0] t0_q, t1_q, t2_q, t3_q;

    logic signed [13:0] ei, eq, oi, oq, li, lq;      // 早/中/迟插值点
    logic signed [15:0] te_c, pe_c;                  // 定时/载波误差字 Q3.11
    logic signed [15:0] dt_n, mu_n, freq_n, phase_n; // 下一状态（16 bit 卷绕）
    logic signed [13:0] ri_c, rq_c;                  // 旧相位旋转（饱和 Q3.11）
    logic signed [13:0] si_c, sq_c;                  // 判决符号 Q3.11
    logic signed [7:0]  soft_i_c, soft_q_c;          // 软判决 Q3.5
    logic signed [15:0] ri16, rq16;                  // pe 的 16 bit 符号扩展
    logic signed [15:0] s_old, c_old, s_new, c_new;  // 旧/新相位各自的 sin、cos

    always_comb begin
        // ---- 步 1：选抽头（mu 的卷绕值定窗位）----
        j0   = {1'b0, 2'd1 - mu_r[15:14]};
        t0_i = sreg_i[j0];
        t1_i = sreg_i[j0 + 3'd1];
        t2_i = sreg_i[j0 + 3'd2];
        t3_i = sreg_i[j0 + 3'd3];
        t0_q = sreg_q[j0];
        t1_q = sreg_q[j0 + 3'd1];
        t2_q = sreg_q[j0 + 3'd2];
        t3_q = sreg_q[j0 + 3'd3];

        // ---- 步 2：早/中/迟线性插值（同一 frac = mu[13:0]）----
        ei = lerp14(t3_i, t2_i, mu_r[13:0]);
        eq = lerp14(t3_q, t2_q, mu_r[13:0]);
        oi = lerp14(t2_i, t1_i, mu_r[13:0]);
        oq = lerp14(t2_q, t1_q, mu_r[13:0]);
        li = lerp14(t1_i, t0_i, mu_r[13:0]);
        lq = lerp14(t1_q, t0_q, mu_r[13:0]);

        // ---- 步 3：te = |late|² − |early|²（Q6.22 → Q3.11，饱和）
        //      te > 0 = 采样偏早（迟端能量大）→ mu 该增大（负反馈）----
        te_c = sat16(rsh_he(m64(li, li) + m64(lq, lq)
                          - m64(ei, ei) - m64(eq, eq), ERR_FRAC));

        // ---- 步 4：定时环（先积分项，再进累加器）----
        dt_n = 16'($signed(dt_r) + rsh_he(m64(te_c, 64'(TIMING_KI)), INC_SHIFT));
        mu_n = 16'($signed(mu_r) + rsh_he(m64(te_c, 64'(TIMING_KP)), INC_SHIFT)
                                 + $signed(dt_n));

        // ---- 步 5：Costas 误差 = **旧相位**旋转的中点采样（sign(0)=+1 取符号位）----
        s_old = sin_lut(phase_r);
        c_old = sin_lut(phase_r + 16'h4000);
        ri_c  = sat14(rsh_he(m64(oi, c_old) + m64(oq, s_old), 14));
        rq_c  = sat14(rsh_he(m64(oq, c_old) - m64(oi, s_old), 14));
        ri16  = {{2{ri_c[13]}}, ri_c};
        rq16  = {{2{rq_c[13]}}, rq_c};
        pe_c  = (ri_c[13] ? -rq16 : rq16) - (rq_c[13] ? -ri16 : ri16);

        // ---- 步 6：载波环（先积分项，再进累加器）----
        freq_n  = 16'($signed(freq_r)  + rsh_he(m64(pe_c, 64'(COSTAS_KI)), INC_SHIFT));
        phase_n = 16'($signed(phase_r) + rsh_he(m64(pe_c, 64'(COSTAS_KP)), INC_SHIFT)
                                        + $signed(freq_n));

        // ---- 步 7：判决符号 = 中点采样按**新相位**再旋转（Q3.11，饱和）----
        // 步 5/7 的相位不同，两组 sin/cos 分开查表，防止工具复用出 1 LSB 位真差
        s_new = sin_lut(phase_n);
        c_new = sin_lut(phase_n + 16'h4000);
        si_c  = sat14(rsh_he(m64(oi, c_new) + m64(oq, s_new), 14));
        sq_c  = sat14(rsh_he(m64(oq, c_new) - m64(oi, s_new), 14));

        // ---- 步 8：软判决 = sat8(round_he(符号 × 2896, 17)) ----
        soft_i_c = sat8(rsh_he(m64(si_c, 64'(SOFT_SQRT2_Q11)), 17));
        soft_q_c = sat8(rsh_he(m64(sq_c, 64'(SOFT_SQRT2_Q11)), 17));
    end

    // ------------------------------------------------------------------
    // 输出与状态登记（sym_go 单拍脉冲；每 4 采样恰好 1 个符号）
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_valid  <= 1'b0;
            dout_data   <= '0;
            dout_soft_i <= '0;
            dout_soft_q <= '0;
            phase_err   <= '0;
            timing_err  <= '0;
            phase_r     <= '0;
            freq_r      <= '0;
            mu_r        <= '0;
            dt_r        <= '0;
        end else begin
            dout_valid <= sym_go;
            if (sym_go) begin
                dout_data   <= {si_c, sq_c};
                dout_soft_i <= soft_i_c;
                dout_soft_q <= soft_q_c;
                phase_err   <= pe_c;
                timing_err  <= te_c;
                phase_r     <= phase_n;
                freq_r      <= freq_n;
                mu_r        <= mu_n;
                dt_r        <= dt_n;
            end
        end
    end

endmodule

`default_nettype wire
