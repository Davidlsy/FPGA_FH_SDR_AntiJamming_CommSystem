// =====================================================================
// sync_acq.v — S6 跳频层 · 同步字捕获（滑动相关 + 恒虚警门限 + M/N 帧槽确认）
//
// 规格: docs/spec/s6_fh_interface.md §8
// 判据: 位真比对 golden_ref.fixed_point.sync_acq.sim_sync_acq（errors=0）
//       + Pfa ≤ 1e-6/帧（解析上界 2.3e-10）+ Pd ≥ 99% @ 0 dB（stat_sync_acq）
//
// 语义（§8.4 每拍原子执行，与 sim_sync_acq 逐条同构，任何一条走岔都在事件账上现形）:
//   1. 滑动相关: sr ← {sr[62:0], din_bit}（最新 bit 进 LSB，复位后不足窗补 0），
//      corr ← 64 − popcount(sr ⊕ SYNC_WORD)（匹配数 = 64 − Hamming 距离）；
//   2. 恒虚警门限: noise_est ← (Σ 近 NAVG 拍 corr（不含本拍） + NAVG/2) >> log2(NAVG)
//      （CA-CFAR 同款训练窗，零填充滑窗和与移位累加同构），
//      thresh ← max(THRESH_MIN, (noise_est × COEFF_Q) >> COEFF_SHIFT)，
//      hit ← (corr ≥ thresh)（等号算命中），随后本拍 corr 计入历史；
//   3. M/N 帧槽判决（§8.3）: IDLE hit 开候选（timer←FRAME_LEN, m←1, slots←1, 发 frame_start）；
//      TRACK 非槽位拍 timer−1 且 hit 忽略（锁定期不抢占不重置，决策 #18）；
//      槽位拍（timer==1）slots+1，hit → m+1 且发 frame_start，
//      随后 m ≥ M 优先（发 acq、关候选），否则 slots ≥ N 弃候选，否则 timer←FRAME_LEN；
//   4. 输出寄存（延 1 拍，同 tod）: dout_hit/acq/frame_start ← 本拍脉冲，
//      dout_corr/thresh ← 本拍值。
//
//   din_valid=0 整拍冻结（sr/噪声历史/槽位计时/状态全保持，无输出行，决策 #13）；
//   复位 sr=0、噪声历史为空（noise_est=0 → thresh=THRESH_MIN）。
//
// 捕获延迟 = 1 帧（M=2）：首个命中拍 → 确认拍恰隔 FRAME_LEN 个有效拍。
// =====================================================================
`timescale 1ns/1ps

module sync_acq #(
    parameter logic [63:0] SYNC_WORD   = 64'h517AE4216E7555CA,  // frame_format.md §2.3 冻结常量
    parameter int         FRAME_LEN    = 2160,   // 帧周期（bit），frame_format.md §7
    parameter int         M_HIT        = 2,      // M/N 判决（§8.3）
    parameter int         N_SLOT       = 3,
    parameter int         NAVG         = 16,     // 噪声估计平均长度（2 的幂）
    parameter int         COEFF_Q      = 13,     // 门限系数 K = COEFF_Q >> COEFF_SHIFT = 1.625
    parameter int         COEFF_SHIFT  = 3,
    parameter int         THRESH_MIN   = 52      // 门限下限（§8.5 虚警上界的关键）
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,       // 采样拍使能；0 = 整拍冻结（停表）
    input  logic        din_bit,         // 解码比特流（MSB-first 帧序）
    output logic        dout_valid,
    output logic        dout_hit,        // 本拍命中（观测口）
    output logic        dout_acq,        // M/N 确认脉冲（第 M 次槽位命中的拍）
    output logic        dout_frame_start,// 帧界声明脉冲 = 同步字末位拍
    output logic [6:0]  dout_corr,       // 观测口（统计/调试直接取自向量）
    output logic [6:0]  dout_thresh
);

    localparam int SYNC_W  = 64;
    localparam int HIST_AW = (NAVG < 2) ? 1 : $clog2(NAVG);   // hist 槽地址宽
    localparam int SUM_W   = 7 + HIST_AW;                     // Σ corr ≤ NAVG×64 = 1024
    localparam int PROD_W  = SUM_W + 8;                       // est×COEFF_Q 中间宽
    localparam int TIMER_W = (FRAME_LEN < 2) ? 1 : $clog2(FRAME_LEN + 1);
    localparam int CNT_W   = (N_SLOT < 2) ? 1 : $clog2(N_SLOT + 1);

    function automatic logic [6:0] popcount64(input logic [63:0] v);
        logic [6:0] c;
        begin
            c = '0;
            for (int i = 0; i < SYNC_W; i++) c = c + {6'd0, v[i]};
            popcount64 = c;
        end
    endfunction

    // ----状态寄存器 ----
    logic [63:0]        sr;                 // 最近 64 bit（LSB = 最新）
    logic [6:0]         hist [0:NAVG-1];    // 近 NAVG 拍 corr（训练窗，零填充）
    logic [HIST_AW-1:0] h_idx;
    logic [SUM_W-1:0]   h_sum;              // hist 之和（恒 == Σ 已见近 NAVG 拍 corr）
    logic               track;
    logic [TIMER_W-1:0] timer;
    logic [CNT_W-1:0]   m_cnt, slots;

    // ----拍内次态（§8.4 原子执行的组合展开）----
    logic [6:0]         corr_c, thresh_c;
    logic [SUM_W-1:0]   est_c;
    logic [PROD_W-1:0]  prod_c, raw_c;
    logic               hit_c, acq_c, fs_c;
    logic               track_n;
    logic [TIMER_W-1:0] timer_n;
    logic [CNT_W-1:0]   m_n, s_n;

    always_comb begin
        // 1) 滑动相关（最新 bit 进 LSB；恰好覆盖同步字时 sr == SYNC_WORD → corr=64）
        corr_c = 7'd64 - popcount64({sr[62:0], din_bit} ^ SYNC_WORD);

        // 2) 恒虚警门限（训练窗 = 近 NAVG 拍历史，不含本拍；四舍五入 + 下限）+ 命中
        est_c  = (h_sum + SUM_W'(NAVG >> 1)) >> HIST_AW;
        prod_c = PROD_W'(est_c) * PROD_W'(COEFF_Q);
        raw_c  = prod_c >> COEFF_SHIFT;
        thresh_c = (raw_c < PROD_W'(THRESH_MIN)) ? 7'(THRESH_MIN) : 7'(raw_c);
        hit_c  = (corr_c >= thresh_c);

        // 3) M/N 状态迁移（§8.3 表）
        track_n = track;
        timer_n = timer;
        m_n     = m_cnt;
        s_n     = slots;
        acq_c   = 1'b0;
        fs_c    = 1'b0;
        if (!track) begin
            if (hit_c) begin                                 // IDLE：开候选 = 槽位 1
                track_n = 1'b1;
                timer_n = TIMER_W'(FRAME_LEN);
                m_n     = CNT_W'(1);
                s_n     = CNT_W'(1);
                fs_c    = 1'b1;
            end
        end else if (timer > TIMER_W'(1)) begin
            timer_n = timer - 1'b1;                          // 非槽位拍：hit 忽略（锁定期）
        end else begin                                       // 槽位拍（timer == 1）
            s_n  = slots + 1'b1;
            m_n  = m_cnt;
            if (hit_c) begin
                m_n  = m_cnt + 1'b1;
                fs_c = 1'b1;
            end
            if (m_n >= CNT_W'(M_HIT)) begin                  // 声明优先于弃候选
                acq_c   = 1'b1;
                track_n = 1'b0;
            end else if (s_n >= CNT_W'(N_SLOT)) begin
                track_n = 1'b0;
            end else begin
                timer_n = TIMER_W'(FRAME_LEN);
            end
        end
    end

    // ----输出寄存（§8.4 步骤 4：本拍脉冲/值延 1 拍）----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sr                <= '0;
            h_idx             <= '0;
            h_sum             <= '0;
            track             <= 1'b0;
            timer             <= '0;
            m_cnt             <= '0;
            slots             <= '0;
            dout_valid        <= 1'b0;
            dout_hit          <= 1'b0;
            dout_acq          <= 1'b0;
            dout_frame_start  <= 1'b0;
            dout_corr         <= '0;
            dout_thresh       <= '0;
            for (int i = 0; i < NAVG; i++) hist[i] <= '0;
        end else if (din_valid) begin
            sr                <= {sr[62:0], din_bit};
            h_sum             <= h_sum + SUM_W'(corr_c) - SUM_W'(hist[h_idx]);
            hist[h_idx]       <= corr_c;
            h_idx             <= (h_idx == HIST_AW'(NAVG - 1)) ? '0 : h_idx + 1'b1;
            track             <= track_n;
            timer             <= timer_n;
            m_cnt             <= m_n;
            slots             <= s_n;
            dout_valid        <= 1'b1;
            dout_hit          <= hit_c;
            dout_acq          <= acq_c;
            dout_frame_start  <= fs_c;
            dout_corr         <= corr_c;
            dout_thresh       <= thresh_c;
        end else begin
            dout_valid        <= 1'b0;                       // 冻结拍：整拍保持（停表）
        end
    end

endmodule
