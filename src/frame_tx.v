// =====================================================================
// frame_tx.v — S4 发射链 · 帧成形
//
// 规格: docs/spec/s4_tx_interface.md §4.1 + docs/spec/frame_format.md
// 判据: 随机帧输出与 S1 参考逐拍一致（0 错误）+ CRC 注错必须被检出
//
// 帧结构（2160 bit，MSB-first 串行）:
//     同步字 64 | 帧头 32 | 载荷 2048（256 B）| CRC16
//
// 端口与节拍:
//     din  : 载荷字节，每 256 个有效字节构成一帧，节奏由上游决定
//     dout : 帧比特流，1 bit/拍，每帧 2160 拍
//
// 载荷进、比特出，两者天然不同速（256 拍进 / 2160 拍出，差 8.44 倍），
// 故内部按**双缓冲**（2 × 256 B）工作：一边发第 k 帧、一边收第 k+1 帧。
// 无背压约定下上游必须满足「平均每字节 ≥ 2160/256 = 8.44 拍」，
// 否则帧缓存会溢出而丢字节（接口约束，见规格书 §4.1）。
//
// CRC 在**发射阶段边发边算**：每发出一个帧头/载荷比特就更新一次 16 bit LFSR，
// 载荷发完时恰好算完，零额外节拍；尾随 16 拍直接吐余数。任务卡建议的
// "8-bit 查表、每拍一字节"在本接口下不成立——输出是比特串行的，查表要在
// 2080 bit 之外另开 260 拍字节域（偏差已登记在帧格式规格书 §5/§8）。
//
// 同步字来自 src/frame_tx_sync.vh（生成物），综合期即 LUT-ROM，不运行时生成。
// 编译需要 -i src 或把该头文件放进工作目录（见 sim/run_s4_acceptance.ps1）。
// =====================================================================
`timescale 1ns/1ps

`include "frame_tx_sync.vh"

module frame_tx #(
    parameter integer  PAYLOAD_BYTES = 256,          // 每帧载荷字节数
    parameter integer  SYNC_LEN      = 64,           // 同步字长度（= FRAME_SYNC_WORD 宽度）
    parameter integer  HEADER_BITS   = 32,           // 帧头长度
    parameter integer  CRC_BITS      = 16,           // CRC 长度
    parameter [1:0]    VERSION       = 2'b01,        // 帧头版本字段
    parameter [15:0]   PAYLOAD_LEN   = 16'd256,      // 帧头载荷字节数字段
    parameter [15:0]   CRC_POLY      = 16'h1021,     // CRC-16/CCITT-FALSE
    parameter [15:0]   CRC_INIT      = 16'hFFFF
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       din_valid,
    input  logic [7:0] din_data,
    output logic       dout_valid,
    output logic       dout_bit
);

    localparam int PAYLOAD_BITS = PAYLOAD_BYTES * 8;
    localparam int TOTAL_BITS   = SYNC_LEN + HEADER_BITS + PAYLOAD_BITS + CRC_BITS;   // 2160
    localparam int BCNT_W       = $clog2(TOTAL_BITS);
    localparam int BYTE_W       = $clog2(PAYLOAD_BYTES);                             // 8

    // ------------------------------------------------------------------
    // 双缓冲载荷存储（2 × 256 B = 4 kbit，LUTRAM 推断即可）
    // ------------------------------------------------------------------
    logic [7:0] mem [0:2*PAYLOAD_BYTES-1];     // {bank, byte}
    logic       wr_bank, rd_bank;
    logic [BYTE_W-1:0] wr_cnt;                 // 当前 bank 内已写字节数
    logic       pending;                       // 有收满未发的帧

    // ------------------------------------------------------------------
    // 发射侧状态
    // ------------------------------------------------------------------
    logic             emitting;
    logic [BCNT_W-1:0] bcnt;                   // 帧内比特计数 0..2159
    logic [15:0]      crc;
    logic [7:0]       frame_no;

    wire [31:0] hdr = {VERSION, 6'b0, frame_no, PAYLOAD_LEN};

    wire        frame_done = din_valid && (wr_cnt == BYTE_W'(PAYLOAD_BYTES - 1));

    // 帧内某拍发哪个比特（MSB-first）
    logic emit_bit;
    always_comb begin
        if (bcnt < BCNT_W'(SYNC_LEN)) begin
            emit_bit = FRAME_SYNC_WORD[SYNC_LEN-1 - bcnt];
        end else if (bcnt < BCNT_W'(SYNC_LEN + HEADER_BITS)) begin
            emit_bit = hdr[HEADER_BITS-1 - (bcnt - BCNT_W'(SYNC_LEN))];
        end else if (bcnt < BCNT_W'(SYNC_LEN + HEADER_BITS + PAYLOAD_BITS)) begin
            logic [BCNT_W-1:0] idx;
            idx = bcnt - BCNT_W'(SYNC_LEN + HEADER_BITS);
            emit_bit = mem[{rd_bank, idx[BYTE_W+2:3]}][3'd7 - idx[2:0]];
        end else begin
            emit_bit = crc[CRC_BITS-1 - (bcnt - BCNT_W'(SYNC_LEN + HEADER_BITS + PAYLOAD_BITS))];
        end
    end

    // CRC 覆盖帧头 + 载荷（不含同步字）
    wire crc_en = emitting
                && (bcnt >= BCNT_W'(SYNC_LEN))
                && (bcnt <  BCNT_W'(SYNC_LEN + HEADER_BITS + PAYLOAD_BITS));
    wire crc_fb   = crc[15] ^ emit_bit;
    wire [15:0] crc_next = {crc[14:0], 1'b0} ^ (crc_fb ? CRC_POLY : 16'h0000);

    assign dout_valid = emitting;
    assign dout_bit   = emit_bit;

    // ------------------------------------------------------------------
    // 单块时序：写侧与发射侧在同一个 always_ff 内，避免两处同时改 pending
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank  <= 1'b0;
            rd_bank  <= 1'b0;
            wr_cnt   <= '0;
            pending  <= 1'b0;
            emitting <= 1'b0;
            bcnt     <= '0;
            crc      <= CRC_INIT;
            frame_no <= 8'd0;
        end else begin
            // ---- 写侧：收满 PAYLOAD_BYTES 个字节即一帧，换 bank 继续收 ----
            if (din_valid) begin
                mem[{wr_bank, wr_cnt}] <= din_data;
                if (frame_done) begin
                    wr_cnt  <= '0;
                    wr_bank <= ~wr_bank;
                    pending <= 1'b1;
                end else begin
                    wr_cnt <= wr_cnt + 1'b1;
                end
            end

            // ---- 发射侧：无帧在发且有帧待发就启动，一帧正好 TOTAL_BITS 拍 ----
            if (emitting) begin
                if (bcnt == BCNT_W'(TOTAL_BITS - 1)) begin
                    emitting <= 1'b0;
                    frame_no <= frame_no + 8'd1;
                end else begin
                    bcnt <= bcnt + 1'b1;
                end
                if (crc_en) crc <= crc_next;
            end else if (pending) begin
                emitting <= 1'b1;
                rd_bank  <= ~wr_bank;          // 刚收满的那一帧在另一个 bank
                bcnt     <= '0;
                crc      <= CRC_INIT;
                // 本拍恰好又收满一帧时保留 pending，下一轮接着发
                pending  <= frame_done;
            end
        end
    end

endmodule

`default_nettype wire
