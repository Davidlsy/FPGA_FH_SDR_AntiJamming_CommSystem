// =====================================================================
// tx_chain_top.v — S4-P5 整链收口 · 发射链顶层（五模块串联）
//
// 五模块串联：frame_tx → conv_enc → blk_inter → [符号速率适配] → qpsk_map → srrc_duc
//
// 速率衔接（P5 的核心设计点）：
//   前三级与 qpsk_map 都在"符号节拍"（1 个有效拍 = 1 个符号）下工作。blk_inter
//   的读侧是"写满 bank 后连续 2170 拍吐符号"，即输出始终是突发（burst），无论输入
//   多慢——它是"节奏放大器"。而 srrc_duc 需要"每 4 拍 1 个符号"（符号率 = 采样率/4，
//   见 docs/spec/s4_tx_interface.md §2/§6.1）。二者相差 4 倍，故中间加一个符号速率
//   适配器：先把 blk_inter 突发的 2170 个符号收进缓冲（2 bit/符号，2170×2 bit），
//   再以 1/4 节拍放出，喂给 qpsk_map（1:1）与 srrc_duc。
//
//   为什么缓冲放在 blk_inter 之后而不是 qpsk_map 之后：此刻数据只有 2 bit/符号
//   （4.3 kbit），比放在 qpsk_map 之后的 24 bit/符号（52 kbit）小一个数量级。
//
// 时钟：单一时钟域（判定用 tb 抽象，物理时钟域留待 S10 顶层集成）。复位同步低有效。
//
// 判据（S4-P5）：随机帧载荷灌入 frame_tx，链路输出 8712 采样，与 S1 全链路定点参考
//   逐拍比对 0 错误。TB 复用 P0 框架（sim/framework/hdl/tb_vec_cmp.sv），只换顶层与向量。
// =====================================================================
`timescale 1ns/1ps

module tx_chain_top #(
    parameter int N_SYMS   = 2170,               // 一帧符号数（blk_inter 输出）
    parameter int BLK_BITS = 2160,               // conv_enc 块长 = 帧长
    parameter string LUT_FILE = "../../src/nco_lut.mem"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [7:0]  din_data,      // 载荷字节（每帧 256 个；节奏见 §4.1 约束）
    output logic        dout_valid,
    output logic [31:0] dout_data      // {i_out[15:0], q_out[15:0]}，DUC 输出 Q5.11
);

    // ------------------------------------------------------------------
    // 级 1：frame_tx（载荷字节 → 2160 拍帧比特流）
    // ------------------------------------------------------------------
    logic ft_valid, ft_bit;
    frame_tx u_frame_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (din_valid),
        .din_data  (din_data),
        .dout_valid(ft_valid),
        .dout_bit  (ft_bit)
    );

    // ------------------------------------------------------------------
    // 级 2：conv_enc（1 bit/拍 → 1 符号 2 bit/拍，块长 = 帧长）
    // ------------------------------------------------------------------
    logic       ce_valid;
    logic [1:0] ce_data;
    conv_enc u_conv_enc (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (ft_valid),
        .din_bit   (ft_bit),
        .blk_len   (16'(BLK_BITS)),
        .dout_valid(ce_valid),
        .dout_data (ce_data)
    );

    // ------------------------------------------------------------------
    // 级 3：blk_inter（1 符号/拍 → 2170 符号/块，读侧突发输出）
    // ------------------------------------------------------------------
    logic       bi_valid;
    logic [1:0] bi_data;
    blk_inter u_blk_inter (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (ce_valid),
        .din_data  (ce_data),
        .dout_valid(bi_valid),
        .dout_data (bi_data)
    );

    // ------------------------------------------------------------------
    // 符号速率适配器：收 2170 个符号（突发）→ 以 1/4 节拍放出
    // ------------------------------------------------------------------
    localparam [1:0] A_IDLE = 2'd0, A_COLLECT = 2'd1, A_DRAIN = 2'd2;

    logic [1:0]  buf_valid_state;
    logic [1:0]  sym_buf [0:N_SYMS-1];      // 2 bit/符号
    logic [11:0] wcnt;                       // 收集计数 0..N_SYMS
    logic [11:0] rcnt;                       // 放出计数 0..N_SYMS-1
    logic [1:0]  rph;                        // 放出节奏相位 0..3（每 4 拍 1 个）

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid_state <= A_IDLE;
            wcnt <= '0;
            rcnt <= '0;
            rph  <= '0;
        end else begin
            case (buf_valid_state)
                A_IDLE: begin
                    if (bi_valid) begin
                        sym_buf[0]      <= bi_data;
                        wcnt            <= 12'd1;
                        buf_valid_state <= A_COLLECT;
                    end
                end
                A_COLLECT: begin
                    if (bi_valid) begin
                        sym_buf[wcnt] <= bi_data;
                        if (wcnt == N_SYMS - 1) begin
                            buf_valid_state <= A_DRAIN;
                            rcnt            <= '0;
                            rph             <= '0;
                        end else begin
                            wcnt <= wcnt + 1'b1;
                        end
                    end
                end
                A_DRAIN: begin
                    if (rph == 2'd3) begin
                        rph <= '0;
                        if (rcnt == N_SYMS - 1)
                            buf_valid_state <= A_IDLE;
                        else
                            rcnt <= rcnt + 1'b1;
                    end else begin
                        rph <= rph + 1'b1;
                    end
                end
                default: buf_valid_state <= A_IDLE;
            endcase
        end
    end

    wire        ad_valid = (buf_valid_state == A_DRAIN) && (rph == 2'd0);
    wire [1:0]  ad_data  = sym_buf[rcnt];

    // ------------------------------------------------------------------
    // 级 4：qpsk_map（2 bit → 24 bit 符号，1:1）
    // ------------------------------------------------------------------
    logic        qm_valid;
    logic [23:0] qm_data;
    qpsk_map u_qpsk_map (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (ad_valid),
        .din_data  (ad_data),
        .dout_valid(qm_valid),
        .dout_data (qm_data)
    );

    // ------------------------------------------------------------------
    // 级 5：srrc_duc（1 符号/4 拍 → 1 采样/拍，8712 采样/帧）
    // ------------------------------------------------------------------
    srrc_duc #(.LUT_FILE(LUT_FILE)) u_srrc_duc (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (qm_valid),
        .din_data  (qm_data),
        .freq_word (16'd8192),      // S4 固定频点 f0 = fs/8（接口规格 §8）
        .freq_valid(1'b1),
        .dout_valid(dout_valid),
        .dout_data (dout_data)
    );

endmodule

`default_nettype wire
