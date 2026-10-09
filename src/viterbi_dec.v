// =====================================================================
// viterbi_dec.v — S5 接收链 · 软判决 Viterbi 译码器（64 态 / 回溯 96）
//
// 规格: docs/spec/s5_rx_interface.md §4.4
// 判据: 位真比对 golden_ref.fixed_point.rx_modules.fixed_viterbi_hw（errors=0）
//
// 语义（与黄金模型逐条同构，任何一条走岔都会在低 SNR 下表现为回溯分歧）:
//   1. 格型: 卷积码 (171,133)₈ K=7 → 64 态。next_state = {b, state[5:1]}（右移），
//      故 state 的 bit5 = 造出该状态的输入比特（回溯取位就取它）。
//      期望输出 = ^({b,state} & 7'o171) 配 s0、^({b,state} & 7'o133) 配 s1
//      （黄金模型 exp bit1 = 第一路多项式 → 配 I 路软值 s0，exp bit0 → 配 s1）。
//   2. 分支度量 = 绝对值型: bm = (e0 ? s0 : −s0) + (e1 ? s1 : −s1)；
//      软值 Q3.5 补码（8 bit，正 = 更可能为 0），一拍 2 软值 = 1 格型步。
//   3. ACS 并列取舍（严格复刻 golden 的循环次序）: 对每个 ns，前驱按 pred0={ns[4:0],0}
//      先、pred1={ns[4:0],1} 后处理，`cand < 当前值` 才更新（严格小于 → 先到者赢并列）；
//      初值是**哨兵 32768**（INF+1），故 cand ≥ 32768 的候选一律被拒。
//      两候选全拒时 pm 留 32768、survivor 留数组初值 **state 0**（不是 pred0！）。
//      且 base > 32767 的状态整条跳过（golden 的 `if base > INF: continue`）。
//   4. 路径度量: 每步先 **16 bit 饱和**（clip 到 [−32768, 32767]）再**减全局最小值**。
//      顺序不能反：clip 后减 min 使归一化值可能短暂超出 16 bit（≤ 32767+256 ≈ 33023），
//      故内部 PM 用 18 bit 有符号承载，饱和语义仍按 16 bit——与 golden 完全同构。
//   5. 回溯 = 寄存器交换（register exchange）: 每状态 96 bit 路径寄存器随 survivor 移入
//      当前输入比特，最优状态路径寄存器的**最老位**即为输出比特——与 golden 滑窗回溯
//      trace_from(t, argmin, 96)[0] 逐比特同构（同 survivor 链 ⇒ 同输出）。
//      每步 1 拍出 1 bit，天然是「1 输入拍 = 1 格型步」的节拍，不需要多周期回溯。
//      BRAM36×8 是任务卡的回溯存储**预算**；寄存器交换用 FF 不占 BRAM，仍在预算内。
//   6. 帧语义（S5 单帧口径，帧界在 S6 由帧同步给）: 每帧 FRAME_SYMS=2166 格型步
//      （2160 信息比特 + 6 尾比特），帧尾按黄金模型「末帧 flush W−1 个再丢 6 尾比特」
//      补吐 89 bit（= 96−1−6），然后**复位 PM / 路径寄存器**再开下一帧——与 golden
//      逐帧 fresh call 同构。补吐与下一帧 ACS 并行（补吐 89 拍 < 下一帧首出 95 拍，
//      输出流天然不相撞），故多帧背靠背不需要输入空隙。
//
// 输出口径: 2166 拍进（16 bit/拍 = 2 软值）→ 2160 bit 出（MSB-first，已去 6 尾比特）。
// =====================================================================
`timescale 1ns/1ps

module viterbi_dec #(
    parameter int TB_DEPTH   = 96,    // 回溯（滑窗判决）深度，任务卡指定
    parameter int FRAME_SYMS = 2166   // 每帧格型步数 = 2160 信息比特 + CONV_K-1 尾比特
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [15:0] din_soft,     // {s0[7:0], s1[7:0]}（高位在前），Q3.5 补码
    output logic        dout_valid,
    output logic        dout_bit      // 译码信息比特，MSB-first
);

    localparam int NS        = 64;                    // 2^(K-1)
    localparam int PM_W      = 18;                    // 有符号；哨兵 32768 需 17 bit，取 18
    localparam int TAIL      = 6;                     // 尾比特（CONV_K-1），帧尾丢弃
    localparam int FLUSH_N   = TB_DEPTH - 1 - TAIL;   // 帧尾补吐位数 = 89

    localparam logic signed [PM_W-1:0] PM_SAT  = 18'sd32767;  // 16 bit 饱和上限（INF）
    localparam logic signed [PM_W-1:0] PM_MIN  = -18'sd32768; // 16 bit 饱和下限（不可达，仍照做）
    localparam logic signed [PM_W-1:0] PM_SENT = 18'sd32768;  // ACS 并列初值（INF+1）

    // ----期望输出表（常量）: enc_out[1] 配 s0、enc_out[0] 配 s1 ----
    function automatic logic [1:0] enc_out(input logic [5:0] state, input logic b);
        logic [6:0] full;
        full = {b, state};
        enc_out = {^(full & 7'o171), ^(full & 7'o133)};
    endfunction

    // ----状态存储 ----
    logic signed [PM_W-1:0] pm       [0:NS-1];   // 路径度量（每步归一化后）
    logic [TB_DEPTH-1:0]    path_reg [0:NS-1];   // 路径寄存器（寄存器交换回溯）

    logic signed [7:0] s0, s1;
    assign s0 = din_soft[15:8];
    assign s1 = din_soft[7:0];

    // ----组合: 64 蝶形 ACS ----
    logic signed [PM_W-1:0] clipped [0:NS-1];    // 饱和后、归一化前
    logic [1:0]             sel     [0:NS-1];    // 0=pred0 1=pred1 2=哨兵（survivor=state 0）
    logic signed [PM_W-1:0] pm_min;
    logic [5:0]             best;

    // 中间量（综合时随循环展开被常量折叠）
    int unsigned            p0_t, p1_t;
    logic                   b_t;
    logic [1:0]             o0_t, o1_t;
    logic signed [PM_W-1:0] s0w, s1w, bm0_t, bm1_t, c0_t, c1_t, v_t;
    logic                   acc0_t, acc1_t;

    assign s0w = s0;
    assign s1w = s1;

    always_comb begin
        for (int unsigned n = 0; n < NS; n++) begin
            p0_t = (n & 6'h1F) << 1;              // pred0 = {ns[4:0], 1'b0}
            p1_t = p0_t | 1;                      // pred1 = {ns[4:0], 1'b1}
            b_t  = n[5];                          // 该状态对应的输入比特
            o0_t = enc_out(p0_t[5:0], b_t);
            o1_t = enc_out(p1_t[5:0], b_t);
            // 绝对值型分支度量（先把 ±s0/±s1 放宽到 PM_W，防 -(-128) 溢出）
            bm0_t = (o0_t[1] ? s0w : -s0w) + (o0_t[0] ? s1w : -s1w);
            bm1_t = (o1_t[1] ? s0w : -s0w) + (o1_t[0] ? s1w : -s1w);
            c0_t  = pm[p0_t] + bm0_t;
            c1_t  = pm[p1_t] + bm1_t;
            // 按黄金模型的处理次序复刻：pred0 先、pred1 后，严格小于才更新；
            // base > 32767 的状态整条跳过；初值 = 哨兵 32768。
            acc0_t = (pm[p0_t] <= PM_SAT) && (c0_t < PM_SENT);
            v_t    = acc0_t ? c0_t : PM_SENT;
            acc1_t = (pm[p1_t] <= PM_SAT) && (c1_t < v_t);
            if (acc1_t) begin
                v_t = c1_t;
                sel[n] = 2'd1;
            end else if (acc0_t) begin
                sel[n] = 2'd0;
            end else begin
                v_t = PM_SENT;
                sel[n] = 2'd2;                    // 两候选全拒：survivor 留数组初值 state 0
            end
            clipped[n] = (v_t > PM_SAT) ? PM_SAT : ((v_t < PM_MIN) ? PM_MIN : v_t);   // 16 bit 饱和
        end
    end

    // 全局最小值 + 最优状态（并列取最小下标，与 np.argmin 一致）
    always_comb begin
        pm_min = clipped[0];
        best   = 6'd0;
        for (int unsigned n = 1; n < NS; n++) begin
            if (clipped[n] < pm_min) begin
                pm_min = clipped[n];
                best   = n[5:0];
            end
        end
    end

    // 最优状态的胜出前驱路径寄存器（3:1；sel==2 → 状态 0）
    logic [TB_DEPTH-1:0] best_src;
    always_comb begin
        case (sel[best])
            2'd1:    best_src = path_reg[{best[4:0], 1'b1}];
            2'd0:    best_src = path_reg[{best[4:0], 1'b0}];
            default: best_src = path_reg[6'd0];
        endcase
    end

    // ----帧计数与帧尾补吐 ----
    logic [$clog2(FRAME_SYMS)-1:0] beat_cnt;      // 帧内格型步计数 0..FRAME_SYMS-1
    logic                          flushing;
    logic [$clog2(FLUSH_N+1)-1:0]  flush_cnt;
    logic [FLUSH_N-1:0]            flush_sr;      // 帧尾待吐比特（高位先出）

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int unsigned n = 0; n < NS; n++) begin
                pm[n]       <= (n == 0) ? '0 : PM_SAT;   // 仅状态 0 度量为 0
                path_reg[n] <= '0;
            end
            beat_cnt   <= '0;
            flushing   <= 1'b0;
            flush_cnt  <= '0;
            flush_sr   <= '0;
            dout_valid <= 1'b0;
            dout_bit   <= 1'b0;
        end else begin
            dout_valid <= 1'b0;

            // 帧尾补吐（与下一帧的输入拍并行；89 < 95 保证与输入拍输出不相撞）
            if (flushing) begin
                if (flush_cnt < FLUSH_N) begin
                    dout_valid <= 1'b1;
                    dout_bit   <= flush_sr[FLUSH_N-1];
                    flush_sr   <= flush_sr << 1;
                    flush_cnt  <= flush_cnt + 1'b1;
                end else begin
                    flushing <= 1'b0;
                end
            end

            // 格型步进：1 输入拍 = 1 格型步
            if (din_valid) begin
                if (beat_cnt >= TB_DEPTH - 1) begin
                    dout_valid <= 1'b1;
                    dout_bit   <= best_src[TB_DEPTH-2];  // 路径寄存器最老位 = t−W+1 的输入比特
                end

                if (beat_cnt == FRAME_SYMS - 1) begin
                    // 帧尾：快照「补吐位」（路径寄存器 [TB_DEPTH-2:TAIL]）+ 状态清零开下一帧。
                    // 末 6 位 = 尾比特，丢弃——与 golden 的 decoded[:-(K-1)] 同构。
                    flush_sr  <= best_src[TB_DEPTH-2-1 -: FLUSH_N];
                    flushing  <= 1'b1;
                    flush_cnt <= '0;
                    beat_cnt  <= '0;
                    for (int unsigned n = 0; n < NS; n++) begin
                        pm[n]       <= (n == 0) ? '0 : PM_SAT;
                        path_reg[n] <= '0;
                    end
                end else begin
                    beat_cnt <= beat_cnt + 1'b1;
                    for (int unsigned n = 0; n < NS; n++) begin
                        pm[n] <= clipped[n] - pm_min;    // 先 clip 后减全局最小值
                        case (sel[n])
                            2'd1:    path_reg[n] <= {path_reg[{n[4:0], 1'b1}][TB_DEPTH-2:0], n[5]};
                            2'd0:    path_reg[n] <= {path_reg[{n[4:0], 1'b0}][TB_DEPTH-2:0], n[5]};
                            default: path_reg[n] <= {path_reg[6'd0][TB_DEPTH-2:0], n[5]};
                        endcase
                    end
                end
            end
        end
    end

endmodule
