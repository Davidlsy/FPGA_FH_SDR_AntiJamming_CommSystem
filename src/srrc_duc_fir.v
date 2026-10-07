// =====================================================================
// srrc_duc_fir.v — S4 发射链 · SRRC 成形用 FIR Compiler IP 版 + NCO 上变频（DUC）
//
// 与 src/srrc_duc.v（手写多相）**接口完全一致**，唯一差异在 SRRC 成形段：
//   手写版 = 33 抽头多相乘累加（组合逻辑，full convolution 4N+32，无流水延迟）
//   FIR 版 = 2 × fir_srrc（FIR Compiler 7.2，Interpolation×4），输出带 3 拍 pipeline
//            空转（前 3 个采样恒 0），流式 4N、无 full-convolution 拖尾。
//
// 对齐要点（实测 tb_fir_latency / tb_fir_check 得出）：
//   1. FIR 输出流前 FIR_LATENCY=3 个采样是 latency 空转（0），须丢弃。
//   2. 流式输出不含 full-convolution 拖尾 → 符号流结束后补 TAIL_SYMS 个零符号；
//      因 3 拍空转吃掉了 3 个输出位，TAIL_SYMS = 8 + 1 = 9（8 补 32 拍尾 + 1 补偿空转）。
//   3. 输出端丢弃前 3 空转后，精确输出 4N+32 个采样（total_out，N=真实符号数），
//      再多的（K=9 多出 1 个）截断。
//   4. NCO 用 sample_valid（而非 FIR tvalid）驱动递增——空转 3 拍不计相位。
//
// 判据：输出序列与手写版 / golden_ref.fixed_point.duc.fixed_srrc_duc **逐值一致**
//       （tb_vec_cmp 只看 dout_valid 序列、不看绝对延迟）。
// =====================================================================
`timescale 1ns/1ps

module srrc_duc_fir #(
    parameter int  NCO_PHASE_W   = 16,        // NCO 相位累加器位宽
    parameter int  NCO_LUT_FRAC  = 14,        // NCO LUT 小数位（Q2.14）
    parameter int  NCO_LUT_DEPTH = 16384,     // 四分之一波 LUT 深度 2^(NCO_PHASE_W-2)
    parameter int  SRRC_OUT_W    = 14,        // SRRC 输出位宽（Q3.11，符号扩展后）
    parameter int  DUC_OUT_W     = 16,        // DUC 输出位宽（Q5.11）
    parameter int  DUC_FRAC      = 11,
    parameter int  NUM_TAPS      = 33,        // SRRC 抽头数（与手写版同源）
    parameter int  UPSAMPLE      = 4,         // 上采样因子
    parameter int  FIR_LATENCY   = 3,         // FIR 输出流前导空转拍数（实测）
    parameter int  TAIL_SYMS     = 9,         // 拖尾零符号 = (NUM_TAPS-1)/UPSAMPLE + 1 = 8 + 1
    parameter int  SYM_PERIOD    = 4,         // 符号 1/4 节奏（= UPSAMPLE）
    parameter string LUT_FILE    = "../../src/nco_lut.mem"  // 相对 sim/framework 的 xsim cwd
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

    // ------------------------------------------------------------------
    // 输入 FSM：IDLE → RUN → TAIL → DONE
    //   RUN   din_valid 时把符号喂给 FIR（1/4 节奏透传），sym_cnt 计真实符号数 N；
    //         连续 SYM_PERIOD 拍无符号 → TAIL
    //   TAIL  每 SYM_PERIOD 拍喂 1 个零符号，共 TAIL_SYMS 个（补 full 卷积尾 + 补偿空转）
    //   DONE  停止，锁存 total_out = 4·N + 32
    //
    // 注：Interpolation×4 下 FIR 输入速率 = 采样速率/4，1/4 节奏下 s_axis_tready 恒 1，
    //     故不做 tready 背压，直接透传 din_valid。
    // ------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_TAIL = 2'd2, S_DONE = 2'd3;

    logic [1:0]  state;
    logic [2:0]  sym_idle;      // RUN 中连续无符号拍数
    logic [3:0]  tail_cnt;      // 已喂零符号数 0..TAIL_SYMS
    logic [2:0]  tail_phase;    // TAIL 中 0..SYM_PERIOD-1 节奏
    logic [15:0] sym_cnt;       // 真实符号数 N

    logic        fir_valid;
    logic [11:0] fir_i_in, fir_q_in;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            sym_idle   <= '0;
            tail_cnt   <= '0;
            tail_phase <= '0;
            sym_cnt    <= '0;
            fir_valid  <= 1'b0;
            fir_i_in   <= '0;
            fir_q_in   <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    sym_idle <= '0;
                    if (din_valid) begin
                        state     <= S_RUN;
                        fir_valid <= 1'b1;
                        fir_i_in  <= din_data[23:12];
                        fir_q_in  <= din_data[11:0];
                        sym_cnt   <= sym_cnt + 1'b1;
                    end else begin
                        fir_valid <= 1'b0;
                    end
                end
                S_RUN: begin
                    if (din_valid) begin
                        fir_valid <= 1'b1;
                        fir_i_in  <= din_data[23:12];
                        fir_q_in  <= din_data[11:0];
                        sym_idle  <= '0;
                        sym_cnt   <= sym_cnt + 1'b1;
                    end else begin
                        fir_valid <= 1'b0;
                        if (sym_idle >= (SYM_PERIOD - 1)) begin   // 连续 4 拍无符号 → 符号流结束
                            state      <= S_TAIL;
                            tail_cnt   <= '0;
                            tail_phase <= '0;
                        end else begin
                            sym_idle <= sym_idle + 1'b1;
                        end
                    end
                end
                S_TAIL: begin
                    if (tail_phase == 0) begin
                        fir_valid <= 1'b1;
                        fir_i_in  <= '0;
                        fir_q_in  <= '0;
                        if (tail_cnt >= (TAIL_SYMS - 1))
                            state <= S_DONE;
                        else
                            tail_cnt <= tail_cnt + 1'b1;
                    end else begin
                        fir_valid <= 1'b0;
                    end
                    tail_phase <= (tail_phase == (SYM_PERIOD - 1)) ? '0 : (tail_phase + 1'b1);
                end
                default: begin   // S_DONE
                    fir_valid <= 1'b0;
                end
            endcase
        end
    end

    // total_out = 4N + 32（组合逻辑）：sym_cnt 在 S_TAIL/S_DONE 期间已稳定 = N，
    // 故在尾采样输出阶段该值恒定。主体阶段由 total_ready 无条件放行，不依赖它。
    wire [15:0] total_out  = (sym_cnt << 2) + 16'd32;
    wire        total_ready = (state == S_TAIL) || (state == S_DONE);

    // ------------------------------------------------------------------
    // FIR Compiler IP ×2（I/Q），16bit AXI-Stream；Data_Width=12 取低 12 位，
    // Output_Width=13 出低 13 位（Q3.11 少一位符号扩展，下面补）。
    // ------------------------------------------------------------------
    logic        fir_i_tvalid, fir_q_tvalid;
    logic [15:0] fir_i_tdata,  fir_q_tdata;
    logic        fir_i_rdy,     fir_q_rdy;

    fir_srrc u_fir_i (
        .aresetn            (rst_n),
        .aclk               (clk),
        .s_axis_data_tvalid (fir_valid),
        .s_axis_data_tready (fir_i_rdy),
        .s_axis_data_tdata  ({{4{fir_i_in[11]}}, fir_i_in}),
        .m_axis_data_tvalid (fir_i_tvalid),
        .m_axis_data_tdata  (fir_i_tdata)
    );

    fir_srrc u_fir_q (
        .aresetn            (rst_n),
        .aclk               (clk),
        .s_axis_data_tvalid (fir_valid),
        .s_axis_data_tready (fir_q_rdy),
        .s_axis_data_tdata  ({{4{fir_q_in[11]}}, fir_q_in}),
        .m_axis_data_tvalid (fir_q_tvalid),
        .m_axis_data_tdata  (fir_q_tdata)
    );

    // FIR 输出 13bit Q3.11 → 符号扩展 14bit（与手写版 SRRC 输出 Q3.11 对齐）
    logic signed [SRRC_OUT_W-1:0] srrc_i, srrc_q;
    always_comb begin
        srrc_i = {fir_i_tdata[12], fir_i_tdata[12:0]};
        srrc_q = {fir_q_tdata[12], fir_q_tdata[12:0]};
    end

    // ------------------------------------------------------------------
    // 输出对齐：丢弃 FIR 前 FIR_LATENCY 个空转，输出 total_out(=4N+32) 个采样
    // ------------------------------------------------------------------
    logic [1:0]  drop_cnt;
    logic        dropping;
    logic [15:0] out_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drop_cnt <= '0;
            dropping <= 1'b1;
            out_cnt  <= '0;
        end else if (fir_i_tvalid) begin
            if (dropping) begin
                if (drop_cnt >= (FIR_LATENCY - 1)) begin
                    dropping <= 1'b0;
                    out_cnt  <= '0;
                end else begin
                    drop_cnt <= drop_cnt + 1'b1;
                end
            end else begin
                out_cnt <= out_cnt + 1'b1;
            end
        end
    end

    wire sample_valid = fir_i_tvalid && !dropping && (!total_ready || (out_cnt < total_out));

    // ------------------------------------------------------------------
    // NCO：16 bit 相位累加器 + 四分之一波 sin LUT（与手写版同一份 LUT / 公式）
    //   用 sample_valid（丢弃空转后的有效采样）驱动递增，采样 j 用 phase = j·ftw。
    // ------------------------------------------------------------------
    logic [15:0]            ftw;
    logic [NCO_PHASE_W-1:0] phase_acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          ftw <= '0;
        else if (freq_valid) ftw <= freq_word;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          phase_acc <= '0;
        else if (sample_valid) phase_acc <= phase_acc + ftw;
    end

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

    wire [NCO_PHASE_W-1:0] phase_cos = phase_acc + (1 << (NCO_PHASE_W - 2));

    // ------------------------------------------------------------------
    // DUC 复数混频 + 量化到 Q5.11（与手写版完全同口径）
    // ------------------------------------------------------------------
    logic signed [15:0] cos_v, sin_v;
    logic signed [31:0] i_mix_full, q_mix_full;

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
        cos_v = sin_lut(phase_cos);
        sin_v = sin_lut(phase_acc);

        i_mix_full = $signed(srrc_i) * cos_v - $signed(srrc_q) * sin_v;
        q_mix_full = $signed(srrc_i) * sin_v + $signed(srrc_q) * cos_v;
    end

    // 输出寄存器（混频结果打一拍，与手写版一致）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_valid <= 1'b0;
            dout_data  <= '0;
        end else begin
            dout_valid <= sample_valid;
            dout_data  <= {quant_duc(i_mix_full), quant_duc(q_mix_full)};
        end
    end

endmodule

`default_nettype wire
