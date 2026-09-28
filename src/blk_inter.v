// =====================================================================
// blk_inter.v — S4 发射链 · 块交织（写行读列，BRAM36 存储）
//
// 规格: docs/spec/s4_tx_interface.md §4.3
// 判据: 解交织还原 0 错误；突发 10 bit 打散 ≥10 码字位；全矩阵覆盖
//
// 几何（与 S1 `block_interleave` 严格一致）:
//     DEPTH=10 行 × N_COL=434 列；整块 4340 bit = 2170 个符号（2 bit/拍）
//     输入 4332 bit（2166 拍）按行填满 10×434 矩阵，尾部补零 8 bit（4 个字）
//     输出按列读出：interleaved[j] = padded[(j mod 10)*434 + (j div 10)]
//
// 地址生成（"写行读列地址生成器"，任务卡要求不变）:
//     写: padded 序的**顺序字地址**（第 k 拍写第 k 个字）——行优先递增器就是这个计数器
//     读: 输出第 m 拍取 padded 位置 a = (2m mod 10)*434 + (2m div 10) 与 a+434 的两位。
//         记 2m = 10c + r（r 恒为偶数）→ 字地址 w = 217*r + (c>>1)、w+217，
//         字内选择 ~c[0]（两地址同奇偶，共用同一个选择位）。
//         故读侧只需一张 217*r 项表 + 两个加法器，**不需要除 434 的除法器**。
//
// 存储（P2 决策，见规格书 §4.3）:
//     padded 序、2 bit/字、双缓冲 2 块；稳态每拍 1 写 + 2 读 = 3 次访问，超出单块
//     BRAM 的端口数，故用**两个 1 写 1 读副本，写广播、读分流**（每个副本稳态下
//     正好是简单双口 RAM 的能力上限）。写读永远作用于不同 bank（双缓冲），
//     因此**不存在读写冲突**，无需 read-first / write-first / no-change 的选择。
//
// 速率约束（与 conv_enc 同理）: 一块写 2166 拍数据 + 4 拍补零 = 2170 拍，
//     块周期 2171 拍（读相位含 1 拍流水），故平均输入速率 ≤ 2166/2171 ≈ 0.9977 拍⁻¹。
//     模块内带 32 拍弹性缓冲吸收抖动；位真向量对多块用例把激励节奏放到 1/2。
//
// 参数前提: DEPTH 与 N_COL 均为偶数（10 / 434），否则"两地址同奇偶"不成立。
// =====================================================================
`timescale 1ns/1ps

module blk_inter #(
    parameter int DEPTH      = 10,       // 交织深度（行数）
    parameter int N_COL      = 434,      // 列数 = ceil(4332/DEPTH)
    parameter int DATA_WORDS = 2166,     // 一块的有效字数 = 4332 bit / 2
    parameter int FIFO_AW    = 5,        // 输入弹性缓冲深度 2^5 = 32 拍
    parameter int ADDR_W     = 13        // 存储地址宽度（2 块 × 2170 字 ≤ 8192）
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       din_valid,
    input  logic [1:0] din_data,      // 一个符号的 {I, Q}；I 是靠前的那个比特
    output logic       dout_valid,
    output logic [1:0] dout_data
);

    localparam int WOFF_W = $clog2(DEPTH * N_COL / 2);     // 12，够 0..2169

    // 显式定宽的常量：避免依赖 '( ) 宽度转换（各工具容忍度不一）
    localparam [WOFF_W-1:0] BLK_LAST  = DEPTH * N_COL / 2 - 1;   // 2169
    localparam [WOFF_W-1:0] STRIDE    = N_COL / 2;               // 217
    localparam [ADDR_W-1:0] BANK_BASE = DEPTH * N_COL / 2;       // 2170
    localparam int          ROW_MAX   = DEPTH;                   // 10

    wire [WOFF_W-1:0] zero_woff = {WOFF_W{1'b0}};
    wire [ADDR_W-1:0] zero_addr = {ADDR_W{1'b0}};

    // ------------------------------------------------------------------
    // 输入弹性缓冲（32 深 × 2 bit）
    // ------------------------------------------------------------------
    logic [1:0]         fifo [0:(1 << FIFO_AW)-1];
    logic [FIFO_AW-1:0] fifo_wr, fifo_rd;
    logic [FIFO_AW:0]   fifo_level;

    wire       fifo_full  = (fifo_level == (1 << FIFO_AW));
    wire       fifo_empty = (fifo_level == '0);
    wire       fifo_push  = din_valid && !fifo_full;
    wire [1:0] fifo_head  = fifo[fifo_rd];

    // ------------------------------------------------------------------
    // 写侧：顺序写 padded 序；前 DATA_WORDS 个字取自缓冲，后 4 个字写零
    // ------------------------------------------------------------------
    logic              wr_run;
    logic [WOFF_W-1:0] wr_word;
    logic              wr_bank;
    logic [1:0]        bank_full;      // 第 i 位 = bank i 已写满待读

    wire wr_in_data  = (wr_word < DATA_WORDS);
    wire fifo_pop    = wr_run && wr_in_data && !fifo_empty;
    wire wr_en       = wr_run && (wr_in_data ? fifo_pop : 1'b1);
    wire [1:0] wr_data = wr_in_data ? fifo_head : 2'b00;
    wire [ADDR_W-1:0] wr_base = wr_bank ? BANK_BASE : zero_addr;
    wire [ADDR_W-1:0] wr_addr = wr_base + {{(ADDR_W-WOFF_W){1'b0}}, wr_word};

    // ------------------------------------------------------------------
    // 读侧：列优先地址；两个读端口各读一个字，各取 1 bit
    // ------------------------------------------------------------------
    logic              rd_run;
    logic [WOFF_W-1:0] rd_cnt;
    logic [8:0]        col;            // 0..433
    logic [3:0]        row;            // 0,2,4,6,8
    logic              rd_bank;

    wire [WOFF_W-1:0] row_base = STRIDE * row;
    wire [WOFF_W-1:0] roff_a   = row_base + {{(WOFF_W-8){1'b0}}, col[8:1]};   // col[8:1] = col>>1
    wire [WOFF_W-1:0] roff_b   = roff_a + STRIDE;
    wire [ADDR_W-1:0] rd_base  = rd_bank ? BANK_BASE : zero_addr;
    wire [ADDR_W-1:0] rd_addr_a = rd_base + {{(ADDR_W-WOFF_W){1'b0}}, roff_a};
    wire [ADDR_W-1:0] rd_addr_b = rd_base + {{(ADDR_W-WOFF_W){1'b0}}, roff_b};

    logic [1:0] mem_a_q, mem_b_q;
    logic       sel_q;                 // 字内 bit 选择，与读数据同拍对齐

    assign dout_data = {mem_a_q[sel_q], mem_b_q[sel_q]};

    // ------------------------------------------------------------------
    // 控制
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr    <= '0;
            fifo_rd    <= '0;
            fifo_level <= '0;
            wr_run     <= 1'b0;
            wr_word    <= zero_woff;
            wr_bank    <= 1'b0;
            bank_full  <= 2'b00;
            rd_run     <= 1'b0;
            rd_cnt     <= zero_woff;
            col        <= '0;
            row        <= '0;
            rd_bank    <= 1'b0;
            sel_q      <= 1'b1;
            dout_valid <= 1'b0;
        end else begin
            // ---- 输入弹性缓冲 ----
            if (fifo_push) begin
                fifo[fifo_wr] <= din_data;
                fifo_wr       <= fifo_wr + 1'b1;
            end
            if (fifo_pop) fifo_rd <= fifo_rd + 1'b1;
            unique case ({fifo_push, fifo_pop})
                2'b10:   fifo_level <= fifo_level + 1'b1;
                2'b01:   fifo_level <= fifo_level - 1'b1;
                default: fifo_level <= fifo_level;
            endcase

            // ---- 写侧 ----
            if (!wr_run) begin
                // bank 空即可开写；被读侧占用时 bank_full=1，自然等待
                if (!bank_full[wr_bank]) begin
                    wr_run  <= 1'b1;
                    wr_word <= zero_woff;
                end
            end else if (wr_word != BLK_LAST) begin
                // 数据段等缓冲非空，补零段不等
                if (!wr_in_data || fifo_pop) wr_word <= wr_word + 1'b1;
            end else begin
                // 最后一个补零字写完 → 本 bank 满，切到另一个 bank
                wr_run             <= 1'b0;
                wr_word            <= zero_woff;
                bank_full[wr_bank] <= 1'b1;
                wr_bank            <= ~wr_bank;
            end

            // ---- 读侧 ----
            if (!rd_run) begin
                dout_valid <= 1'b0;
                if (bank_full[rd_bank]) begin
                    rd_run <= 1'b1;
                    rd_cnt <= zero_woff;
                    col    <= '0;
                    row    <= '0;
                end
            end else begin
                dout_valid <= 1'b1;                 // 打一拍，与同步读数据对齐
                sel_q      <= ~col[0];
                if (rd_cnt != BLK_LAST) begin
                    rd_cnt <= rd_cnt + 1'b1;
                    if ((row + 2) >= ROW_MAX) begin
                        row <= '0;
                        col <= col + 1'b1;
                    end else begin
                        row <= row + 2;
                    end
                end else begin
                    // 最后一拍照常给出（valid 已打拍），随后交还 bank
                    rd_run             <= 1'b0;
                    rd_cnt             <= zero_woff;
                    col                <= '0;
                    row                <= '0;
                    bank_full[rd_bank] <= 1'b0;
                    rd_bank            <= ~rd_bank;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 存储：两个 1 写 1 读副本，写广播、读分流
    // ------------------------------------------------------------------
    blk_mem_1w1r #(.ADDR_W(ADDR_W)) u_mem_a (
        .clk  (clk),
        .we   (wr_en),
        .waddr(wr_addr),
        .wdata(wr_data),
        .raddr(rd_addr_a),
        .rdata(mem_a_q)
    );

    blk_mem_1w1r #(.ADDR_W(ADDR_W)) u_mem_b (
        .clk  (clk),
        .we   (wr_en),
        .waddr(wr_addr),
        .wdata(wr_data),
        .raddr(rd_addr_b),
        .rdata(mem_b_q)
    );

endmodule

`default_nettype wire
