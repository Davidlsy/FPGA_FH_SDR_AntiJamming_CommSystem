// =====================================================================
// tb_nco_hop_long.sv — S6 · nco_hop 相位轨迹断言 + 3×10⁵ 跳长跑（任务卡判据）
//
// 判据（docs/spec/s6_fh_interface.md §5.4）:
//   1. 每拍断言 phase[k+1] − phase[k] ≡ 生效 ftw[k]（mod 2^16）——"跳仅更新 FTW、
//      相位无阶跃"的机器检查；
//   2. 跳事件后 ≤2 拍断言步进已切到 FTW[ch]（生效延迟 <1 µs @ 8 MSPS = 8 拍），
//      并同时断言跳当拍步进仍用旧 ftw（非阻塞语义）；
//   3. 3×10⁵ 跳长跑（压缩节拍 4 拍/跳，§5.4 有意偏差登记）；
//   4. 三档跳速真实节拍短跑：1000/500/100 hop/s @ fs=8 MSPS → 8000/16000/80000 拍/跳。
//
// 证据口径:
//   · 跳事件由 fh_ctrl 实例产生（真实跳频图案，收发同种子 SEED=0x0001），
//     nco_hop.din_hop_valid = fh_ctrl.dout_valid 同拍（§5.3 耦合契约）；
//   · FTW 期望表按 §5.1 冻结值在 TB 内**逐项硬编码**，不复刻 RTL 的 (2k+1)<<10
//     公式——表值本身是独立证据；
//   · 断言只取激励侧（跳事件）与 DUT 输出侧（dout_phase 轨迹），无镜像模型背书。
//
// 本 TB 自含激励，不读向量文件（seq 用例已有逐拍位真）；结果行纯 ASCII。
// =====================================================================
`timescale 1ns/1ps

module tb_nco_hop_long;

    localparam int N_HOPS_LONG  = 300_000;   // 任务卡 3×10⁵ 跳（压缩 4 拍/跳）
    localparam int CYC_HOP_LONG = 4;         // 压缩节拍（≈1 符号/跳）
    localparam int REAL_HOPS    = 4;         // 每档真实节拍短跑跳数
    localparam int TOTAL_CYC    = N_HOPS_LONG * CYC_HOP_LONG
                                  + REAL_HOPS * (8_000 + 16_000 + 80_000) + 1_000;

    // §5.1 冻结 FTW 表（逐项硬编码，独立于 RTL 公式）: (2k+1)*1024
    localparam logic [15:0] FTW [0:15] = '{
        16'd1024,  16'd3072,  16'd5120,  16'd7168,
        16'd9216,  16'd11264, 16'd13312, 16'd15360,
        16'd17408, 16'd19456, 16'd21504, 16'd23552,
        16'd25600, 16'd27648, 16'd29696, 16'd31744
    };

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    // ----激励：fh_ctrl 产跳事件，nco_hop 每拍都采样 ----
    logic        fh_din_valid = 1'b0;
    logic        fh_seed_load = 1'b0;
    logic [15:0] fh_seed      = 16'h0001;
    logic        nco_din_valid = 1'b0;

    logic        fh_valid;
    logic [19:0] fh_idx;
    logic [3:0]  fh_chan;

    logic        dut_valid;
    logic [15:0] dut_phase, dut_cos, dut_sin;

    fh_ctrl #(.SEED(16'h0001)) u_fh (
        .clk(clk), .rst_n(rst_n),
        .din_valid(fh_din_valid), .din_seed_load(fh_seed_load), .din_seed(fh_seed),
        .dout_valid(fh_valid), .dout_hop_index(fh_idx), .dout_channel(fh_chan)
    );

    nco_hop u_dut (
        .clk(clk), .rst_n(rst_n),
        .din_valid(nco_din_valid),
        .din_hop_valid(fh_valid),
        .din_channel(fh_chan),
        .dout_valid(dut_valid),
        .dout_phase(dut_phase),
        .dout_cos(dut_cos),
        .dout_sin(dut_sin)
    );

    // ----相位轨迹断言监视器 ----
    // 输出拍与输入拍 1:1（din_valid 恒 1），dout 晚 1 拍寄存；hop_d 把跳事件
    // 与它所属的输出拍对齐（同一 posedge 采样）。
    logic        hop_d  = 1'b0;
    logic [3:0]  ch_d   = '0;
    logic [15:0] prev_phase = '0;
    logic [15:0] ftw_belief = '0;   // 生效于当前观测拍的 ftw（该拍步进用值）
    logic [15:0] ftw_used   = '0;   // 上一观测拍步进实际该用的 ftw
    logic        have_prev  = 1'b0;

    int delay_pend = 0;             // 2 = 下一 delta 该用旧 ftw，1 = 该用新 ftw
    logic [15:0] delay_old = '0;
    logic [3:0]  delay_ch  = '0;

    int beat_cnt = 0, hop_cnt = 0;
    int cont_err = 0, delay_err = 0, delay_hits = 0;
    logic seen_ch [0:15];
    logic [15:0] delta;

    always @(posedge clk) begin
        // hop_d/ch_d 用非阻塞：块内后续读取取"上一拍"的值，与 dout 拍对齐
        hop_d <= nco_din_valid && fh_valid;
        ch_d  <= fh_chan;
        if (!rst_n) begin
            have_prev  = 1'b0;
            ftw_belief = '0;
            ftw_used   = '0;
        end else if (dut_valid) begin
            beat_cnt = beat_cnt + 1;
            if (have_prev) begin
                delta = dut_phase - prev_phase;   // mod 2^16 自然回绕
                if (delta !== ftw_used) begin     // 判据 1：相位无阶跃
                    cont_err = cont_err + 1;
                    if (cont_err <= 8)
                        $display("[NCO-HOP-LONG] JUMP beat=%0d delta=%0d ftw_used=%0d",
                                 beat_cnt, delta, ftw_used);
                end
                if (delay_pend == 2 && delta !== delay_old) begin
                    delay_err = delay_err + 1;
                    if (delay_err <= 8)
                        $display("[NCO-HOP-LONG] DELAY-OLD beat=%0d delta=%0d old_ftw=%0d",
                                 beat_cnt, delta, delay_old);
                end
                if (delay_pend == 1) begin        // 判据 2：≤2 拍切到新 ftw
                    if (delta !== FTW[delay_ch]) begin
                        delay_err = delay_err + 1;
                        if (delay_err <= 8)
                            $display("[NCO-HOP-LONG] DELAY-NEW beat=%0d delta=%0d FTW[%0d]=%0d",
                                     beat_cnt, delta, delay_ch, FTW[delay_ch]);
                    end else
                        delay_hits = delay_hits + 1;
                end
                if (delay_pend > 0) delay_pend = delay_pend - 1;
            end
            if (hop_d) begin
                hop_cnt      = hop_cnt + 1;
                seen_ch[ch_d] = 1'b1;
                delay_pend   = 2;
                delay_old    = ftw_belief;
                delay_ch     = ch_d;
            end
            ftw_used   = ftw_belief;
            ftw_belief = hop_d ? FTW[ch_d] : ftw_belief;
            prev_phase = dut_phase;
            have_prev  = 1'b1;
        end
    end

    // ----分段激励：同一套断言跑压缩长跑 + 三档真实节拍 ----
    task automatic run_segment(input string name, input int hops, input int dwell);
        int h;
        begin
            $display("[NCO-HOP-LONG] seg=%0s hops=%0d dwell=%0d", name, hops, dwell);
            for (h = 0; h < hops; h++) begin
                @(posedge clk);
                fh_din_valid <= 1'b1;    // fh_ctrl 一拍 = 一跳
                @(posedge clk);
                fh_din_valid <= 1'b0;
                repeat (dwell - 2) @(posedge clk);   // 每跳恰 dwell 拍
            end
            @(posedge clk);
        end
    endtask

    int i, ch_cov;
    initial begin
        for (i = 0; i < 16; i++) seen_ch[i] = 1'b0;
        @(posedge rst_n);
        @(posedge clk);
        nco_din_valid <= 1'b1;           // 全程采样（门控语义归 seq/rand/edge 用例）
        @(posedge clk);

        run_segment("long",    N_HOPS_LONG, CYC_HOP_LONG);           // 判据 3
        run_segment("rate1000", REAL_HOPS, 8_000);                   // 判据 4（1000 hop/s）
        run_segment("rate500",  REAL_HOPS, 16_000);                  // 判据 4（500 hop/s）
        run_segment("rate100",  REAL_HOPS, 80_000);                  // 判据 4（100 hop/s）

        @(posedge clk);
        @(posedge clk);
        // 信道覆盖（真实跳频图案 3×10⁵ 跳应当 16 信道全覆盖）
        ch_cov = 0;
        for (i = 0; i < 16; i++) if (seen_ch[i]) ch_cov = ch_cov + 1;
        $display("[NCO-HOP-LONG] channel_coverage=%0d/16 %s", ch_cov,
                 (ch_cov == 16) ? "ok" : "INCOMPLETE");
        $display("[NCO-HOP-LONG] hops=%0d beats=%0d cont_err=%0d delay_err=%0d delay_hits=%0d",
                 hop_cnt, beat_cnt, cont_err, delay_err, delay_hits);
        if (cont_err == 0 && delay_err == 0 && delay_hits == hop_cnt && ch_cov == 16
            && hop_cnt > 0) begin
            $display("[NCO-HOP-LONG] status=PASS hops=%0d beats=%0d phase_cont=ok ftw_delay=2cyc(250ns)",
                     hop_cnt, beat_cnt);
        end else begin
            $display("[NCO-HOP-LONG] status=FAIL hops=%0d beats=%0d cont_err=%0d delay_err=%0d delay_hits=%0d",
                     hop_cnt, beat_cnt, cont_err, delay_err, delay_hits);
            $fatal(1);
        end
        $finish;
    end

    // 看门狗：总拍数 + 余量；卡死不静默挂
    initial begin
        #(10ns * TOTAL_CYC);
        $display("[NCO-HOP-LONG] status=FAIL timeout hops=%0d beats=%0d", hop_cnt, beat_cnt);
        $fatal(1);
    end

endmodule
