// =====================================================================
// conv_enc.v — S4 发射链 · 卷积编码器 (171, 133)₈, K=7, R=1/2
//
// 规格: docs/spec/s4_tx_interface.md §4.2
// 判据: 输出比特流与 S1 参考逐拍一致（10⁶ bit 量级 0 错误）
//
// 结构: 6 级移位寄存器 + 两棵 6 输入异或树，四组 7 bit 与门/异或即可，
// 无需流水线（组合路径 = 2 级 LUT）。
//
// 三处容易各自"正确"却互不一致的地方，这里按 S1 参考逐条对齐：
//   1. 位序: 先 g₁(0o171) 后 g₂(0o133) → dout_data = {g₁, g₂}；
//   2. 窗口: full_reg[i] = 输入延迟 i 拍，i=0 是当前比特（g₁ 的 MSB 对应当前位）；
//   3. 尾比特: 块内收满 blk_len 位后补 K−1 = 6 个 0，寄存器归零，
//      尾码字**照常计入输出** → 输出拍数 = blk_len + 6。
//
// 为什么需要 blk_len 而不是"看 din_valid 拉低判块尾"：链路里帧是背靠背的，
// valid 不会在两帧之间拉低，靠间隙判尾会把两帧粘成一块。块长是控制面寄存器。
//
// 为什么输入侧有 64 深弹性缓冲：本模块输出 blk_len+6 拍而只吃 blk_len 拍输入，
// 输出比输入慢 0.28%。缓冲吸收这个节拍差与上游抖动，代价是约 64 个 FF。
// 接口约束仍成立（见规格书 §4.2）：上游平均速率 ≤ blk_len/(blk_len+6)，
// 缓冲只保证短时突发不丢比特。
// =====================================================================
`timescale 1ns/1ps

module conv_enc #(
    parameter integer K       = 7,             // 约束长度
    parameter [6:0]   G1      = 7'b1111001,    // 0o171
    parameter [6:0]   G2      = 7'b1011011,    // 0o133
    parameter integer FIFO_AW = 6              // 输入弹性缓冲深度 = 2^FIFO_AW
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic        din_bit,
    input  logic [15:0] blk_len,      // 配置：一个编码块的信息比特数（链路里 = 2160）
    output logic        dout_valid,
    output logic [1:0]  dout_data     // {g₁, g₂}
);

    localparam int TAIL_BITS = K - 1;  // 归零尾比特数 = 6
    localparam int FIFO_DEPTH = 1 << FIFO_AW;

    // ------------------------------------------------------------------
    // 输入弹性缓冲（64 深，1 bit 宽）
    // ------------------------------------------------------------------
    logic [FIFO_DEPTH-1:0] fifo;
    logic [FIFO_AW-1:0]    wr_ptr, rd_ptr;
    logic [FIFO_AW:0]      level;

    wire        fifo_full  = (level == FIFO_DEPTH[FIFO_AW:0]);
    wire        fifo_empty = (level == '0);
    wire        fifo_push  = din_valid && !fifo_full;
    wire [0:0]  fifo_head  = fifo[rd_ptr];

    // ------------------------------------------------------------------
    // 编码核心
    // ------------------------------------------------------------------
    logic [K-2:0] sr;        // 最近 K−1 个输入（sr[0] 最新）
    logic [15:0]  cnt;       // 块内已收比特数
    logic [2:0]   tail_cnt;  // 尾比特阶段已发个数
    logic         in_tail;

    wire        consume   = !in_tail && !fifo_empty;   // 本拍消费一个缓冲比特
    wire [0:0]  cons_bit  = in_tail ? 1'b0 : fifo_head; // 尾阶段输入恒 0
    wire [K-1:0] win      = {cons_bit, sr};
    wire        g1        = ^(win & G1);
    wire        g2        = ^(win & G2);

    assign dout_valid = consume || in_tail;
    assign dout_data  = {g1, g2};

    // 缓冲读写（同拍推入/弹出时 level 不变）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            level  <= '0;
        end else begin
            if (fifo_push) begin
                fifo[wr_ptr] <= din_bit;
                wr_ptr       <= wr_ptr + 1'b1;
            end
            if (consume) rd_ptr <= rd_ptr + 1'b1;

            unique case ({fifo_push, consume})
                2'b10:   level <= level + 1'b1;
                2'b01:   level <= level - 1'b1;
                default: level <= level;
            endcase
        end
    end

    // 移位寄存器 + 块计数 + 尾比特状态机
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr       <= '0;
            cnt      <= '0;
            tail_cnt <= '0;
            in_tail  <= 1'b0;
        end else if (in_tail) begin
            sr <= {1'b0, sr[K-2:1]};
            if (tail_cnt == TAIL_BITS[2:0] - 1'b1) begin
                in_tail  <= 1'b0;
                tail_cnt <= '0;
            end else begin
                tail_cnt <= tail_cnt + 1'b1;
            end
        end else if (consume) begin
            sr <= {cons_bit, sr[K-2:1]};
            if (cnt + 1'b1 == blk_len) begin
                cnt      <= '0;
                in_tail  <= 1'b1;
                tail_cnt <= '0;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
