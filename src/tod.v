// =====================================================================
// tod.v — S6 跳频层 · TOD 时基（1 ms tick + 帧头截断 TOD 外推跳沿）
//
// 规格: docs/spec/s6_fh_interface.md §7
// 判据: 位真比对 golden_ref.fixed_point.tod.sim_tod（errors=0）
//       + tick 恰隔 8000 有效拍（无事件段）+ 对齐误差 ≤±0.25 跳周期（三档跳速）
//
// 语义（§7.4 每拍原子执行，与 sim_tod 逐条同构，任何一条走岔都在脉冲账上现形）:
//   1. 自然步进（总是发生）: frac+1；frac 到 TICK_SAMPLES 边界 → frac=0、tod+1
//      （mod 2^TOD_W 自然回绕）、发 tick 脉冲；新 tod ≡ 0 (mod hop_ticks) 再发 hop 脉冲；
//   2. 装订/对齐（同拍改写，不吞 1) 的脉冲）:
//      din_tod_load → tod ← din_tod_value、frac ← 0，且**装订 = 声明边界**（发 tick，
//      网格点再发 hop）——不发脉冲会让装订后头 hop_ticks 毫秒无跳沿驱动 fh_ctrl
//      （孤儿区间，决策 #14）；
//      否则 din_align_valid → a = snap(din_align_tod)（64 窗最近，±32 牵引），
//      若 a ≠ 步进后 tod 则补发声明边界脉冲（**未发过才补发**：晚检测边界已发→
//      不补防双跳沿、早检测边界被重锚吞掉→补发防丢跳沿，决策 #12），tod ← a、frac ← 0；
//   3. din_valid=0 整拍冻结（时基停表，决策 #13）；复位 frac/tod 归零。
//
// 输出口径: 每个 din_valid 拍 → 1 个 dout_valid 拍；tick 拍的 dout_tod = 新计数
// （帧首 bit 拍取 dout_tod[5:0] 入帧头，§7.2 字段语义锚点）。
// =====================================================================
`timescale 1ns/1ps

module tod #(
    parameter int TICK_SAMPLES = 8000,        // 1 ms @ 8 MSPS（§7.1 冻结值）
    parameter int TOD_W        = 32,          // tick 计数位宽（比对用窄位宽测回绕）
    parameter int FIELD_W      = 6            // 帧头字段宽（frame_format.md [29:24]）
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                din_valid,       // 采样拍使能；0 = 整拍冻结（停表）
    input  logic [1:0]          din_rate_sel,    // 0:1000, 1:500, 2:100 hop/s（其余=1000）
    input  logic                din_tod_load,    // 装订：tod ← din_tod_value, frac ← 0，并声明边界
    input  logic [31:0]         din_tod_value,
    input  logic                din_align_valid, // 帧头 TOD 对齐（与装订同拍时装订优先）
    input  logic [FIELD_W-1:0]  din_align_tod,   // 帧头 [29:24] 字段值
    output logic                dout_valid,
    output logic                dout_tick,       // 1 ms tick 脉冲（tick 边界拍）
    output logic [31:0]         dout_tod,        // 当前 tick 计数（低 6 位 = 帧头字段）
    output logic                dout_hop_edge    // 跳沿脉冲（驱动 fh_ctrl.din_valid）
);

    localparam int FRAC_W = (TICK_SAMPLES < 2) ? 1 : $clog2(TICK_SAMPLES);

    // ----跳沿网格（§7.1: hop_ticks = 1/2/10，rate_sel 其余值按 1000）----
    function automatic logic on_grid(input logic [TOD_W-1:0] v, input logic [1:0] sel);
        case (sel)
            2'd1:    on_grid = ~v[0];            // hop_ticks = 2
            2'd2:    on_grid = ((v % 10) == 0);  // hop_ticks = 10
            default: on_grid = 1'b1;             // 0/3 → hop_ticks = 1
        endcase
    endfunction

    // ----snap：低 FIELD_W 位对齐到 A，高 2^(TOD_W)−64 窗取 64 窗内最近（§7.4）----
    // 与 golden snap_tod 同一公式：X = (tod & ~mask) | A；
    // 有符号差 sd = X − tod（mod 2^TOD_W 取 [−2^(TOD_W−1), 2^(TOD_W−1)−1]）；
    // sd > +2^(FIELD_W−1) 则 X −= 2^FIELD_W；sd < −2^(FIELD_W−1) 则 X += 2^FIELD_W。
    function automatic logic [TOD_W-1:0] snap_tod(
        input logic [FIELD_W-1:0] a,
        input logic [TOD_W-1:0]   t
    );
        logic [TOD_W-1:0] x, d;
        logic signed [TOD_W:0] sd;
        begin
            x  = {t[TOD_W-1:FIELD_W], a};
            d  = x - t + {1'b1, {(TOD_W-1){1'b0}}};               // (X − tod + 2^(TOD_W−1)) mod 2^TOD_W
            sd = $signed({1'b0, d}) - $signed({2'b01, {(TOD_W-1){1'b0}}});  // d − 2^(TOD_W−1)
            if (sd > (32'sd1 <<< (FIELD_W - 1)))
                x = x - (1 <<< FIELD_W);
            else if (sd < -(32'sd1 <<< (FIELD_W - 1)))
                x = x + (1 <<< FIELD_W);
            snap_tod = x;                                          // mod 2^TOD_W（位宽截断）
        end
    endfunction

    // ----状态寄存器 ----
    logic [FRAC_W-1:0] frac;   // 子拍相位 0..TICK_SAMPLES-1，tick 边界清 0
    logic [TOD_W-1:0]  tod;    // tick 计数（除复位外不归零，自然回绕）

    // ----拍内次态（§7.4 原子执行的组合展开：1) 自然步进 → 2) 装订/对齐改写）----
    logic [FRAC_W-1:0] frac_step, frac_nxt;
    logic [TOD_W-1:0]  tod_step, tod_nxt, a_snap;
    logic              tick_nxt, hop_nxt;

    always_comb begin
        // 1) 自然步进（总是发生）：frac 到边界 → 换 tick、tod+1 自然回绕
        if (frac == FRAC_W'(TICK_SAMPLES - 1)) begin
            frac_step = '0;
            tod_step  = tod + 1'b1;
            tick_nxt  = 1'b1;
            hop_nxt   = on_grid(tod_step, din_rate_sel);
        end else begin
            frac_step = frac + 1'b1;
            tod_step  = tod;
            tick_nxt  = 1'b0;
            hop_nxt   = 1'b0;
        end
        frac_nxt = frac_step;
        tod_nxt  = tod_step;
        a_snap   = snap_tod(din_align_tod, tod_step);

        // 2) 装订/对齐（同拍改写，不吞 1) 的脉冲；装订优先于对齐）
        if (din_tod_load) begin
            tod_nxt  = din_tod_value[TOD_W-1:0];
            frac_nxt = '0;
            tick_nxt = 1'b1;                                     // 装订 = 声明边界
            hop_nxt  = hop_nxt | on_grid(tod_nxt, din_rate_sel);
        end else if (din_align_valid) begin
            if (a_snap != tod_step) begin                        // 未发过才补发
                tick_nxt = 1'b1;
                hop_nxt  = hop_nxt | on_grid(a_snap, din_rate_sel);
            end
            tod_nxt  = a_snap;
            frac_nxt = '0;
        end
    end

    // ----输出寄存（§7.4: dout_* ← 本拍脉冲 + 步进/改写后 tod）----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            frac          <= '0;
            tod           <= '0;
            dout_valid    <= 1'b0;
            dout_tick     <= 1'b0;
            dout_hop_edge <= 1'b0;
            dout_tod      <= '0;
        end else if (din_valid) begin
            frac          <= frac_nxt;
            tod           <= tod_nxt;
            dout_valid    <= 1'b1;
            dout_tick     <= tick_nxt;
            dout_hop_edge <= hop_nxt;
            dout_tod      <= 32'(tod_nxt);   // TOD_W ≤ 32，高位零扩展
        end else begin
            dout_valid    <= 1'b0;           // 冻结拍：frac/tod/dout_tod 保持（停表）
            dout_tick     <= 1'b0;
            dout_hop_edge <= 1'b0;
        end
    end

endmodule
