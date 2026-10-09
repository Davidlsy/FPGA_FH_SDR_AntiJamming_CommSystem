// =====================================================================
// tb_fh_ctrl_long.sv — S6 · fh_ctrl 10⁶ 跳收发互比 + 驻留均匀性（任务卡判据）
//
// 判据（docs/spec/s6_fh_interface.md §4.2，计划书 S6 首条原文）:
//   1. 收发同种子 10⁶ 跳**逐跳互比**（TX/RX 两实例 channel + hop_index 全等）；
//   2. 16 信道驻留均匀性：每信道驻留 ∈ [56250, 68750]（均值 ±10%）；
//   3. 前 8 跳黄金锚点（channel = 8,0,0,0,14,9,13,9；hop_index = 0..7）——
//      把 10⁶ 跳长跑与黄金参考钉在一起，不靠 7MB 向量文件（seq 用例已有逐跳位真）。
//
// 本 TB 自含激励（1 次同种子加载 + 10⁶ 个跳拍），不读向量文件；结果行纯 ASCII。
// =====================================================================
`timescale 1ns/1ps

module tb_fh_ctrl_long;

    localparam int N_HOPS   = 1_000_000;
    localparam int DWELL_LO = 56_250;   // 10⁶/16 × 0.9
    localparam int DWELL_HI = 68_750;   // 10⁶/16 × 1.1

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic        din_valid     = 1'b0;
    logic        din_seed_load = 1'b0;
    logic [15:0] din_seed      = 16'h0001;

    logic        tx_valid, rx_valid;
    logic [19:0] tx_idx,  rx_idx;
    logic [3:0]  tx_chan, rx_chan;

    fh_ctrl #(.SEED(16'h0001)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .din_valid(din_valid), .din_seed_load(din_seed_load), .din_seed(din_seed),
        .dout_valid(tx_valid), .dout_hop_index(tx_idx), .dout_channel(tx_chan)
    );

    fh_ctrl #(.SEED(16'h0001)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .din_valid(din_valid), .din_seed_load(din_seed_load), .din_seed(din_seed),
        .dout_valid(rx_valid), .dout_hop_index(rx_idx), .dout_channel(rx_chan)
    );

    // 黄金锚点：种子 16'h0001 前 8 跳（check_fh_pattern.py [2] 同源）
    logic [3:0] anchor_ch [0:7] = '{4'd8, 4'd0, 4'd0, 4'd0, 4'd14, 4'd9, 4'd13, 4'd9};

    int dwell [0:15];
    int mismatches = 0;
    int anchor_err = 0;
    int hop_seen   = 0;
    int i;

    initial begin
        for (i = 0; i < 16; i++) dwell[i] = 0;

        // 同种子显式加载（收发同种子）→ 10⁶ 个跳拍
        @(posedge rst_n);
        @(posedge clk);
        din_seed_load <= 1'b1;
        din_seed      <= 16'h0001;
        din_valid     <= 1'b1;
        @(posedge clk);
        din_seed_load <= 1'b0;
        for (i = 0; i < N_HOPS; i++) begin
            din_valid <= 1'b1;
            @(posedge clk);
        end
        din_valid <= 1'b0;
    end

    // 逐跳互比 + 驻留统计 + 锚点（在输出拍采样）
    always @(posedge clk) begin
        if (rst_n && tx_valid) begin
            hop_seen++;
            if (rx_valid !== 1'b1 || tx_idx !== rx_idx || tx_chan !== rx_chan) begin
                mismatches++;
                if (mismatches <= 8)
                    $display("[FH-LONG] mismatch@hop=%0d tx={%0d,%0d} rx={%0d,%0d}",
                             hop_seen - 1, tx_idx, tx_chan,
                             rx_idx, rx_chan);
            end
            dwell[tx_chan]++;
            if (hop_seen <= 8 && tx_chan !== anchor_ch[hop_seen - 1])
                anchor_err++;
            if (hop_seen <= 8 && tx_idx !== (hop_seen - 1))
                anchor_err++;
        end
    end

    // 收口：跑满 N_HOPS 个输出拍后出判据行
    initial begin
        wait (hop_seen == N_HOPS);
        @(posedge clk);
        if (mismatches == 0 && anchor_err == 0) begin
            $display("[FH-LONG] anchor=ok first8=8,0,0,0,14,9,13,9");
            for (i = 0; i < 16; i++)
                $display("[FH-LONG] dwell ch=%0d n=%0d %s", i, dwell[i],
                         (dwell[i] >= DWELL_LO && dwell[i] <= DWELL_HI) ? "ok" : "OUT-OF-RANGE");
            for (i = 0; i < 16; i++)
                if (dwell[i] < DWELL_LO || dwell[i] > DWELL_HI) begin
                    $display("[FH-LONG] status=FAIL hops=%0d mismatches=%0d uniform=FAIL",
                             hop_seen, mismatches);
                    $fatal(1);
                end
            $display("[FH-LONG] status=PASS hops=%0d mismatches=0 anchor_err=0 uniform=PASS", hop_seen);
        end else begin
            $display("[FH-LONG] status=FAIL hops=%0d mismatches=%0d anchor_err=%0d",
                     hop_seen, mismatches, anchor_err);
            $fatal(1);
        end
        $finish;
    end

    // 看门狗：10⁶ 跳 + 余量；卡死不静默挂
    initial begin
        #(10ns * (N_HOPS + 100_000));
        $display("[FH-LONG] status=FAIL timeout hops=%0d", hop_seen);
        $fatal(1);
    end

endmodule
