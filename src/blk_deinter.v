// =====================================================================
// blk_deinter.v — S5 接收链 · 块解交织（逆 blk_inter，去 8 bit 补零）
//
// 规格: docs/spec/s5_rx_interface.md §4.3
// 判据: 位真比对 golden_ref.fixed_point.rx_modules.soft_deinterleave（errors=0）
//
// 语义（与发射侧 blk_inter 严格成逆）:
//   发射 blk_inter: 写行优先、读列优先——interleaved[j] = padded[(j mod 10)*434 + (j div 10)]
//   本模块:          写列优先、读行优先——padded[i]   = interleaved[10*(i mod 434) + (i div 434)]
//   即把交织序按矩阵转置还原，再丢掉发射侧尾部补的 8 bit（padded 序末 4 个字）。
//
// 几何（与 blk_inter 共用，不得另设）:
//     DEPTH=10 行 × N_COL=434 列；整块 4340 个软值 = 2170 拍（16 bit/拍 = 2 软值）
//     输入 2170 拍（4340 软值），输出 2166 拍（4332 软值）——去 8 bit 补零
//     元素 j 的逆像: i → j = 10*(i mod 434) + (i div 434)；只产 i=0..4331（丢 4332..4339）
//
// 位宽口径（§4.3 澄清）: 搬的是**软判决值**（8 bit/5 小数），不是 2 个硬比特。
//     总线 16 bit、一拍 2 个软值（高位在前 {soft[2k], soft[2k+1]}），与发射侧 2bit/符号同序。
//     同一置换对「4340 比特」和「4340 软值」都成立，因为发射侧也是一拍一个 2bit 字——
//     两侧元素序完全一致，故 {I,Q} 打包顺序必须全程一致。
//
// 存储（元素级置换，故按 16 bit 字存 + 字内选字节）:
//     一拍 2 个软值 = 1 个 16 bit 字，写侧顺序写 2170 字；读侧按逆置换取**元素**，
//     两元素可能落在不同字里（j 与 j+10 相差 5 个字），故需 2 个读口——
//     沿用 blk_inter 的「复制存储、写广播、读分流」纪律：一个数组 1 写 2 读
//     （综合时由工具复制到 2 块简单双口 BRAM，等价 blk_inter 的两个 blk_mem_1w1r）。
//     读同步、读延迟 1 拍（与 blk_mem_1w1r 一致）。
//
// 乒乓双缓冲（连续流式）: 2 个 bank（各 2170 字），写满一 bank 置 full 并切到另一 bank，
//     读侧见到 full 即排空该 bank（产 2166 拍）后清 full 并切 bank。
//     输出比输入快（2166 < 2170 拍/块），故读侧总能追上写侧、2 bank 不回灌、无需输入 FIFO
//     ——这一点与 blk_inter 相反（blk_inter 输出更慢，才需 FIFO + 节奏约束）。
//
// 参数前提: DEPTH 与 N_COL 均为偶数（10 / 434），N_COL ≥ 2（否则 j0/j1 同字需 2 读口仍成立）。
// =====================================================================
`timescale 1ns/1ps

module blk_deinter #(
    parameter int DEPTH  = 10,        // 交织深度（行数），与 blk_inter 相同
    parameter int N_COL  = 434,       // 列数 = ceil(4332 / DEPTH)，与 blk_inter 相同
    parameter int N_PAD  = 8,         // 发射侧补零位数（= 10*N_COL − 4332），输出丢弃
    parameter int ADDR_W = 13         // 存储地址宽度（2 bank × 2170 字 = 4340 ≤ 8192）
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [15:0] din_data,     // {soft[2k][7:0], soft[2k+1][7:0]}（高位在前）
    output logic        dout_valid,
    output logic [15:0] dout_data     // {soft[2m][7:0], soft[2m+1][7:0]}（高位在前）
);

    localparam int N_ELEM    = DEPTH * N_COL;           // 4340 个软值/块
    localparam int IN_WORDS  = N_ELEM / 2;              // 2170 输入字/块（2 软值/字）
    localparam int OUT_WORDS = (N_ELEM - N_PAD) / 2;    // 2166 输出拍/块
    localparam int WW        = $clog2(IN_WORDS);        // 12：wr_word 0..2169
    localparam int RW        = $clog2(OUT_WORDS);       // 12：rd_beat 0..2165
    localparam int COL_W     = $clog2(N_COL);           // 9：col 0..433
    localparam int ROW_W     = $clog2(DEPTH);           // 4：row 0..9
    localparam int J_W       = $clog2(N_ELEM);          // 13：元素 j 0..4339

    localparam [J_W-1:0]    TEN       = 13'd10;
    localparam [COL_W-1:0]  N_COL_M1  = N_COL - 1;
    localparam [ADDR_W-1:0] BANK_BASE = IN_WORDS;       // bank1 基址 = 2170

    // ------------------------------------------------------------------
    // 写侧：顺序写 2170 字/块（元素 2k→高字节、2k+1→低字节），满一 bank 切换
    // ------------------------------------------------------------------
    logic              wr_bank;
    logic [WW-1:0]     wr_word;

    wire [ADDR_W-1:0] wr_base = wr_bank ? BANK_BASE : {ADDR_W{1'b0}};
    wire [ADDR_W-1:0] wr_addr = wr_base + {{(ADDR_W-WW){1'b0}}, wr_word};
    wire              wr_en   = din_valid;

    // ------------------------------------------------------------------
    // 读侧：输出元素 i = N_COL*row + col，逆像 j = 10*col + row
    //   一拍产 2 元素 i、i+1（j0、j1），再把 (row,col) 前进 2 个元素到 (r2,c2)
    // ------------------------------------------------------------------
    logic              rd_bank;
    logic              rd_run;
    logic [RW-1:0]     rd_beat;
    logic [ROW_W-1:0]  row;
    logic [COL_W-1:0]  col;

    wire [COL_W-1:0] c0 = col;
    wire [ROW_W-1:0] r0 = row;
    wire             wrap0 = (c0 == N_COL_M1);
    wire [COL_W-1:0] c1 = wrap0 ? {COL_W{1'b0}} : (c0 + {{(COL_W-1){1'b0}}, 1'b1});
    wire [ROW_W-1:0] r1 = wrap0 ? (r0 + {{(ROW_W-1){1'b0}}, 1'b1}) : r0;
    wire             wrap1 = (c1 == N_COL_M1);
    wire [COL_W-1:0] c2 = wrap1 ? {COL_W{1'b0}} : (c1 + {{(COL_W-1){1'b0}}, 1'b1});
    wire [ROW_W-1:0] r2 = wrap1 ? (r1 + {{(ROW_W-1){1'b0}}, 1'b1}) : r1;

    wire [J_W-1:0] j0 = TEN * c0 + {{(J_W-ROW_W){1'b0}}, r0};
    wire [J_W-1:0] j1 = TEN * c1 + {{(J_W-ROW_W){1'b0}}, r1};

    wire [ADDR_W-1:0] rd_base   = rd_bank ? BANK_BASE : {ADDR_W{1'b0}};
    wire [ADDR_W-1:0] rd_addr_a = rd_base + {{(ADDR_W-12){1'b0}}, j0[J_W-1:1]};
    wire [ADDR_W-1:0] rd_addr_b = rd_base + {{(ADDR_W-12){1'b0}}, j1[J_W-1:1]};

    logic sel0_q, sel1_q;          // 字内字节选择（j 偶→高字节、奇→低字节），与读数据同拍对齐

    // ------------------------------------------------------------------
    // 存储：2 bank × 2170 字，1 写 2 读（同步读、延迟 1 拍）
    //   综合时本数组被工具复制成 2 块简单双口 BRAM（写广播、读分流），等价 blk_inter
    // ------------------------------------------------------------------
    logic [15:0] mem [0:2*IN_WORDS-1];
    logic [15:0] rdata_a, rdata_b;

    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= din_data;
        rdata_a <= mem[rd_addr_a];
        rdata_b <= mem[rd_addr_b];
    end

    // 字内选字节 → 输出 {elem_i, elem_i+1}（高位在前）
    wire [7:0] e0 = sel0_q ? rdata_a[7:0] : rdata_a[15:8];
    wire [7:0] e1 = sel1_q ? rdata_b[7:0] : rdata_b[15:8];
    assign dout_data = {e0, e1};

    // ------------------------------------------------------------------
    // 控制：写侧 + 读侧（乒乓 bank_full 握手）
    // ------------------------------------------------------------------
    logic [1:0] bank_full;         // 第 i 位 = bank i 已写满待读

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank    <= 1'b0;
            wr_word    <= '0;
            rd_bank    <= 1'b0;
            rd_run     <= 1'b0;
            rd_beat    <= '0;
            row        <= '0;
            col        <= '0;
            bank_full  <= 2'b00;
            sel0_q     <= 1'b0;
            sel1_q     <= 1'b0;
            dout_valid <= 1'b0;
        end else begin
            // ---- 写侧：一拍 1 字，写满 2170 字置 full 并切 bank ----
            if (wr_en) begin
                if (wr_word == IN_WORDS - 1) begin
                    wr_word           <= '0;
                    bank_full[wr_bank] <= 1'b1;
                    wr_bank           <= ~wr_bank;
                end else begin
                    wr_word <= wr_word + 1'b1;
                end
            end

            // ---- 读侧：见 full 即排空该 bank，产 OUT_WORDS 拍后切 bank ----
            if (!rd_run) begin
                dout_valid <= 1'b0;
                if (bank_full[rd_bank]) begin
                    rd_run <= 1'b1;
                    rd_beat <= '0;
                    row    <= '0;
                    col    <= '0;
                end
            end else begin
                // 本拍发一条读命令（元素 i、i+1），读数据下一拍随 dout_valid 出
                sel0_q     <= j0[0];
                sel1_q     <= j1[0];
                dout_valid <= 1'b1;
                if (rd_beat == OUT_WORDS - 1) begin
                    // 最后一拍命令已发：收口，本 bank 交还
                    rd_run             <= 1'b0;
                    rd_beat            <= '0;
                    row                <= '0;
                    col                <= '0;
                    bank_full[rd_bank] <= 1'b0;
                    rd_bank            <= ~rd_bank;
                end else begin
                    rd_beat <= rd_beat + 1'b1;
                    col     <= c2;
                    row     <= r2;
                end
            end
        end
    end

endmodule

`default_nettype wire
