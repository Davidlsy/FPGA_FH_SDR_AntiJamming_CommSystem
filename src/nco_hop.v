// =====================================================================
// nco_hop.v — S6 跳频层 · 信道 → FTW 查表 + 相位连续跳频 NCO
//
// 规格: docs/spec/s6_fh_interface.md §5
// 判据: 位真比对 golden_ref.fixed_point.nco_hop.sim_nco_hop（errors=0）
//       + 相位轨迹断言 3×10⁵ 跳无阶跃 + FTW 生效延迟 2 拍（250 ns < 1 µs @ 8 MSPS）
//
// 语义（§5.2，与 srrc_duc 的 NCO 逐拍同构，任何一条走岔都在相位轨迹上现形）:
//   1. 每拍（din_valid=1）原子执行:
//        dout ← LUT(phase)          // 输出当前相位（FixedNCO.step 口径）
//        phase ← phase + ftw        // 16 bit 自然回绕，只加不清零
//        if (hop) ftw ← FTW[ch]     // 换字不清相位；本拍步进仍用旧 ftw（非阻塞）
//   2. 跳只换 FTW、绝不清零 phase —— "相位连续"的全部含义。
//   3. FTW 表（§5.1 冻结）: FTW[k] = (2k+1)*1024，k=0..15。
//   4. NCO 核复用 S4 已验证口径: 16 bit 相位不截断直接寻址、Q2.14 四分之一波 LUT
//      （src/nco_lut.mem）、镜像 mir = 16383-idx、cos(p) = sin(p + 2^14)。
//   5. din_valid=0 整拍冻结（输出无效、phase/ftw 保持）。
//
// 输出口径: 每个 din_valid 拍 → 1 个 dout_valid 拍，{phase, cos, sin} 各 16 bit。
// =====================================================================
`timescale 1ns/1ps

module nco_hop #(
    parameter int  NCO_PHASE_W   = 16,        // NCO 相位累加器位宽（§5.2）
    parameter int  NCO_LUT_DEPTH = 16384,     // 四分之一波 LUT 深度 2^(NCO_PHASE_W-2)
    parameter string LUT_FILE    = "../../src/nco_lut.mem"  // 与 srrc_duc 同源
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,       // 样本节拍：每拍产出 1 个 LO 样本
    input  logic        din_hop_valid,   // 跳事件（= fh_ctrl.dout_valid 同拍）
    input  logic [3:0]  din_channel,     // 信道号（= fh_ctrl.dout_channel）
    output logic        dout_valid,
    output logic [15:0] dout_phase,      // 相位累加器观测口（轨迹证据）
    output logic [15:0] dout_cos,        // Q2.14
    output logic [15:0] dout_sin
);

    // ----FTW 表（§5.1 冻结值: (2k+1)*1024）----
    function automatic logic [15:0] ftw_of(input logic [3:0] ch);
        ftw_of = 16'(((2 * 16'(ch) + 16'd1) << 10));
    endfunction

    // ----状态寄存器 ----
    logic [NCO_PHASE_W-1:0] phase;   // 相位累加器（除复位外只加，绝不清零）
    logic [15:0]            ftw;     // 生效频率字

    // ----四分之一波 LUT（$readmemh 加载，16 bit Q2.14）----
    reg signed [15:0] nco_lut [0:NCO_LUT_DEPTH-1];
    initial $readmemh(LUT_FILE, nco_lut);

    // 四象限 sin 查表（镜像 mir = 16383 - idx，与 srrc_duc 同一公式）
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
    wire [NCO_PHASE_W-1:0] phase_cos = phase + (1 << (NCO_PHASE_W - 2));

    // ----每拍原子执行（§5.2）----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phase      <= '0;
            ftw        <= '0;
            dout_valid <= 1'b0;
            dout_phase <= '0;
            dout_cos   <= '0;
            dout_sin   <= '0;
        end else if (din_valid) begin
            dout_valid <= 1'b1;
            dout_phase <= phase;              // 输出当前相位（步进前）
            dout_cos   <= sin_lut(phase_cos);
            dout_sin   <= sin_lut(phase);
            phase      <= phase + ftw;        // 本拍步进用旧 ftw
            if (din_hop_valid) ftw <= ftw_of(din_channel);  // 换字不清相位
        end else begin
            dout_valid <= 1'b0;               // 冻结拍：phase/ftw 保持
        end
    end

endmodule
