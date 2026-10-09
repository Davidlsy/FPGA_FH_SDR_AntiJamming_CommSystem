// =====================================================================
// tb_sync_acq_long.sv — S6 · 同步字捕获长跑（真实参数，任务卡判据）
//
// 判据（docs/spec/s6_fh_interface.md §8.5 第 4 条）:
//   1. 噪声段无误声明：5 帧纯伪随机（确定性 LFSR 载荷，黄金预验证 0 命中）
//      → hit / frame_start / acq 全 0；
//   2. 信号段捕获延迟 = 1 帧：帧 1 同步字命中开候选 → acq 恰隔 FRAME_LEN 个
//      **有效**拍（2160）落在帧 2 同步字末位拍（M=2 槽 2 确认）；
//   3. frame_start 拍与同步字末位拍重合（6/6 帧），acq 恰在帧 2/4/6。
//
// 真实冻结参数：FRAME_LEN=2160 / M=2 / N=3（位真比对用缩参 200，§8.6 #4；
// 本 TB 与 stat_sync_acq 覆盖冻结值本身）。
// 激励混入 ~1% din_valid 停表拍：槽位计时只数有效拍，冻结拍不得推进 timer——
// 若停表拍被误计入 2160 延迟，判据 2/3 的拍号账立即现形。
//
// 本 TB 自含激励（确定性 LFSR-16 载荷，与 fh_ctrl 同多项式），不读向量文件；
// 结果行纯 ASCII。
// =====================================================================
`timescale 1ns/1ps

module tb_sync_acq_long;

    localparam logic [63:0] SYNC_WORD = 64'h517AE4216E7555CA;  // frame_format.md §2.3
    localparam int FRAME_LEN = 2160;
    localparam int M_HIT     = 2;
    localparam int N_SLOT    = 3;
    localparam int SYNC_W    = 64;
    localparam int N_FRAMES  = 6;
    localparam int NOISE_BITS = 5 * FRAME_LEN;

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic       din_valid = 1'b0;
    logic       din_bit   = 1'b0;
    logic       dut_valid, dut_hit, dut_acq, dut_fs;
    logic [6:0] dut_corr, dut_thresh;

    sync_acq #(
        .SYNC_WORD(SYNC_WORD),
        .FRAME_LEN(FRAME_LEN),
        .M_HIT    (M_HIT),
        .N_SLOT   (N_SLOT)
    ) u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .din_valid       (din_valid),
        .din_bit         (din_bit),
        .dout_valid      (dut_valid),
        .dout_hit        (dut_hit),
        .dout_acq        (dut_acq),
        .dout_frame_start(dut_fs),
        .dout_corr       (dut_corr),
        .dout_thresh     (dut_thresh)
    );

    // ----输出账（有效拍序号 = 驱动侧 beat 序号，输出寄存 1 拍不影响对齐）----
    int vbeat = 0;
    int hit_cnt = 0, acq_cnt = 0, fs_cnt = 0;
    int fs_at [0:15];
    int acq_at [0:15];

    always @(posedge clk) begin
        if (rst_n && dut_valid) begin
            if (dut_hit) hit_cnt++;
            if (dut_fs)  fs_at[fs_cnt++]  = vbeat;
            if (dut_acq) acq_at[acq_cnt++] = vbeat;
            vbeat++;
        end
    end

    // ----确定性伪随机载荷（LFSR-16，与 fh_ctrl §2 同多项式；黄金预验证 0 命中）----
    logic [15:0] lfsr = 16'hACE1;

    task automatic next_payload(output logic b);
        logic fb;
        b  = lfsr[0];
        fb = lfsr[0] ^ lfsr[4] ^ lfsr[13] ^ lfsr[15];
        lfsr = {fb, lfsr[15:1]};
    endtask

    // ----驱动：一个有效拍 + stall 个停表拍（din_valid=0 整拍冻结）----
    int beat = 0;

    task automatic send(input logic b, input int stall);
        din_bit   <= b;
        din_valid <= 1'b1;
        @(posedge clk);
        din_valid <= 1'b0;
        din_bit   <= 1'b0;
        beat++;
        repeat (stall) @(posedge clk);
    endtask

    int sync_end [0:7];
    int n_sync = 0;
    int noise_hits = 0, noise_fs = 0, noise_acq = 0;
    int i, f;
    logic b;
    bit ok_noise, ok_fs, ok_acq;

    initial begin
        @(posedge rst_n);
        @(posedge clk);

        // ----Phase A：噪声段（5 帧纯伪随机，无同步字）----
        for (i = 0; i < NOISE_BITS; i++) begin
            next_payload(b);
            send(b, (i % 100 == 99) ? 1 : 0);
        end
        noise_hits = hit_cnt;
        noise_fs   = fs_cnt;
        noise_acq  = acq_cnt;

        // ----Phase B：信号段（6 帧 × 2160 bit：64 bit 同步字 + 2096 bit 载荷）----
        for (f = 0; f < N_FRAMES; f++) begin
            for (i = 0; i < SYNC_W; i++)
                send(SYNC_WORD[SYNC_W - 1 - i], 1'b0);      // MSB-first 帧序
            sync_end[n_sync++] = beat - 1;                  // 同步字末位拍
            for (i = 0; i < FRAME_LEN - SYNC_W; i++) begin
                next_payload(b);
                send(b, (i % 100 == 99) ? 1 : 0);
            end
        end

        repeat (8) @(posedge clk);

        // ----判据----
        ok_noise = (noise_hits == 0 && noise_fs == 0 && noise_acq == 0);
        ok_fs = (fs_cnt == N_FRAMES);
        for (i = 0; i < N_FRAMES; i++)
            ok_fs = ok_fs && (fs_at[i] == sync_end[i]);
        ok_acq = (acq_cnt == N_FRAMES / 2);
        for (i = 0; i < N_FRAMES / 2; i++)
            ok_acq = ok_acq && (acq_at[i] == sync_end[2 * i + 1])
                            && (acq_at[i] - sync_end[2 * i] == FRAME_LEN);

        $display("[SYNC-ACQ-LONG] noise: hits=%0d fs=%0d acq=%0d %s",
                 noise_hits, noise_fs, noise_acq, ok_noise ? "ok" : "FAIL");
        for (i = 0; i < N_FRAMES; i++)
            $display("[SYNC-ACQ-LONG] frame=%0d sync_end=%0d fs_at=%0d %s",
                     i + 1, sync_end[i], (i < fs_cnt) ? fs_at[i] : -1,
                     (i < fs_cnt && fs_at[i] == sync_end[i]) ? "ok" : "FAIL");
        for (i = 0; i < N_FRAMES / 2; i++)
            $display("[SYNC-ACQ-LONG] acq=%0d at=%0d open=%0d delay=%0d %s",
                     i + 1, (i < acq_cnt) ? acq_at[i] : -1, sync_end[2 * i],
                     (i < acq_cnt) ? (acq_at[i] - sync_end[2 * i]) : -1,
                     (i < acq_cnt && acq_at[i] == sync_end[2 * i + 1]
                      && acq_at[i] - sync_end[2 * i] == FRAME_LEN) ? "ok" : "FAIL");

        if (ok_noise && ok_fs && ok_acq) begin
            $display("[SYNC-ACQ-LONG] status=PASS frames=%0d fs=%0d acq=%0d delay=%0d beats=%0d",
                     N_FRAMES, fs_cnt, acq_cnt, FRAME_LEN, vbeat);
        end else begin
            $display("[SYNC-ACQ-LONG] status=FAIL noise=%0d fs=%0d/%0d acq=%0d/%0d",
                     ok_noise, fs_cnt, N_FRAMES, acq_cnt, N_FRAMES / 2);
            $fatal(1);
        end
        $finish;
    end

    // 看门狗：全段有效拍 + 停表 + 余量；卡死不静默挂
    initial begin
        #(10ns * (NOISE_BITS + N_FRAMES * FRAME_LEN + 20_000));
        $display("[SYNC-ACQ-LONG] status=FAIL timeout beats=%0d fs=%0d acq=%0d",
                 vbeat, fs_cnt, acq_cnt);
        $fatal(1);
    end

endmodule
