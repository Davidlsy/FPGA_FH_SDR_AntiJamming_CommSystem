// =====================================================================
// tb_blk_inter_burst.sv — S4-P2 · 突发打散量化验证（模块专属检查）
//
// 任务卡点名的判据是「突发 10 bit 打散 ≥10 码字位」，也是最容易被做成**假测试**
// 的一条：只验证"数据能还原"是连通性测试，证明不了抗突发能力。所以本 TB 自己
// 做三件事，且全部用**独立于 DUT 的 TB 侧模型**（不信 DUT 内部信号）：
//
//   1. 灌一块确定激励（din_data = 拍计数低 2 位），收下 DUT 的 2170 拍输出（4340 bit）；
//   2. 在交织流第 1000 位翻连续 10 bit（模拟信道突发），用 TB 侧解交织模型还原，
//      统计错误落在**几行**（行 = 一个码字 = 位置 div 434）；
//   3. 对照：同样 10 个位置若不经交织（顺序发送），只会落在 1 行。
//
// 判据: 还原 0 错误 + 错误数 == 10 + 分散行数 ≥ 10 → [BURST-RESULT] … status=PASS
// TB 侧解交织是 dout[(j%10)*434 + (j/10)] = din[j] 的直接转写，与 S1
// `block_deinterleave` 同式但独立实现（两条路径互为交叉校验）。
// =====================================================================
`timescale 1ns/1ps

module tb_blk_inter_burst;

    localparam int DEPTH     = 10;
    localparam int N_COL     = 434;
    localparam int IN_BITS   = 4332;      // 一块输入比特数
    localparam int OUT_BITS  = 4340;      // 一块输出比特数 = DEPTH*N_COL
    localparam int IN_BEATS  = IN_BITS / 2;
    localparam int BURST_LEN = 10;
    localparam int BURST_POS = 1000;      // 突发起始位置（远离补零区）

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic       din_valid;
    logic [1:0] din_data;
    logic       dout_valid;
    logic [1:0] dout_data;

    blk_inter u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (din_valid),
        .din_data  (din_data),
        .dout_valid(dout_valid),
        .dout_data (dout_data)
    );

    // ------------------------------------------------------------------
    // 激励：2166 拍，din_data = 拍计数低 2 位（{I, Q} = {cnt[1], cnt[0]}）
    // ------------------------------------------------------------------
    int drv_cnt = 0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            din_valid <= 1'b0;
            din_data  <= 2'b00;
            drv_cnt   <= 0;
        end else if (drv_cnt < IN_BEATS) begin
            din_valid <= 1'b1;
            din_data  <= drv_cnt[1:0];
            drv_cnt   <= drv_cnt + 1;
        end else begin
            din_valid <= 1'b0;
        end
    end

    // 激励比特流的第 k 位（k/2 拍的第 (k%2?0:1) 位）
    function automatic logic stim_bit(input int k);
        logic [1:0] beat;
        begin
            beat     = 2'(k / 2);
            stim_bit = (k % 2 == 0) ? beat[1] : beat[0];
        end
    endfunction

    // ------------------------------------------------------------------
    // 收下交织输出
    // ------------------------------------------------------------------
    logic [OUT_BITS-1:0] interleaved;     // bit[0] 最先出
    int                  rcvd = 0;

    always_ff @(posedge clk) begin
        if (rst_n && dout_valid && rcvd < OUT_BITS) begin
            interleaved[rcvd]     <= dout_data[1];
            interleaved[rcvd + 1] <= dout_data[0];
            rcvd <= rcvd + 2;
        end
    end

    // ------------------------------------------------------------------
    // TB 侧独立模型：解交织
    // ------------------------------------------------------------------
    function automatic void deinterleave(input logic [OUT_BITS-1:0] src,
                                        output logic [OUT_BITS-1:0] dst);
        int j, pos;
        begin
            dst = '0;
            for (j = 0; j < OUT_BITS; j++) begin
                pos = (j % DEPTH) * N_COL + (j / DEPTH);   // 列优先读出的逆映射
                dst[pos] = src[j];
            end
        end
    endfunction

    int                  errors;
    int                  rows_after;
    int                  rows_before;
    int                  restored_ok;
    logic [OUT_BITS-1:0] corrupted;
    logic [OUT_BITS-1:0] recovered;
    bit [OUT_BITS-1:0]   seen;

    initial begin
        wait (rcvd >= OUT_BITS);
        #50;

        // ---- 1. 还原检查：解交织后 = 激励序列 + 8 位补零 ----
        deinterleave(interleaved, recovered);
        restored_ok = 1;
        for (int k = 0; k < IN_BITS; k++)
            if (recovered[k] !== stim_bit(k)) restored_ok = 0;
        for (int k = IN_BITS; k < OUT_BITS; k++)
            if (recovered[k] !== 1'b0) restored_ok = 0;

        // ---- 2. 注错：交织流里连续 10 bit ----
        corrupted = interleaved;
        for (int k = 0; k < BURST_LEN; k++)
            corrupted[BURST_POS + k] = ~corrupted[BURST_POS + k];

        deinterleave(corrupted, recovered);
        errors = 0;
        seen   = '0;
        for (int k = 0; k < IN_BITS; k++) begin
            if (recovered[k] !== stim_bit(k)) begin
                errors = errors + 1;
                seen[k / N_COL] = 1'b1;                  // 行号 = 位置 div 434
            end
        end
        rows_after = 0;
        for (int r = 0; r < DEPTH; r++)
            if (seen[r]) rows_after = rows_after + 1;

        // ---- 3. 对照：同样 10 个位置若不经交织 ----
        begin
            bit [DEPTH-1:0] seen_b;
            seen_b = '0;
            for (int k = 0; k < BURST_LEN; k++)
                seen_b[(BURST_POS + k) / N_COL] = 1'b1;
            rows_before = 0;
            for (int r = 0; r < DEPTH; r++)
                if (seen_b[r]) rows_before = rows_before + 1;
        end

        // ---- 判据行（纯 ASCII）----
        if (restored_ok && errors == BURST_LEN && rows_after >= DEPTH) begin
            $display("[BURST-RESULT] tb=tb_blk_inter_burst restore=%0d errors=%0d rows=%0d rows_no_interleave=%0d burst=%0d status=PASS",
                     restored_ok, errors, rows_after, rows_before, BURST_LEN);
            $display("[BURST] 解交织还原 0 错误；%0d bit 突发被打散到 %0d 个码字行（无交织时 %0d 行）",
                     BURST_LEN, rows_after, rows_before);
            $finish;
        end else begin
            $display("[BURST-RESULT] tb=tb_blk_inter_burst restore=%0d errors=%0d rows=%0d rows_no_interleave=%0d burst=%0d status=FAIL",
                     restored_ok, errors, rows_after, rows_before, BURST_LEN);
            $fatal(1, "[BURST] FAIL");
        end
    end

    // 看门狗：正常应在 ~4400 拍内收满
    initial begin
        #2_000_000;
        $display("[BURST-RESULT] tb=tb_blk_inter_burst restore=0 errors=0 rows=0 rows_no_interleave=0 burst=%0d status=FAIL",
                 BURST_LEN);
        $fatal(1, "[BURST] watchdog timeout");
    end

endmodule
