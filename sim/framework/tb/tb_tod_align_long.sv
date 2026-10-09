// =====================================================================
// tb_tod_align_long.sv — S6 · tod 对齐误差 + 跳沿对齐长跑断言（任务卡判据）
//
// 判据（docs/spec/s6_fh_interface.md §7.5）:
//   1. tick 精确性：无装订/对齐事件的间隔内相邻 tick 脉冲恰隔 8000 个有效拍；
//      事件拍为重锚（含 tod 牵引跳变），间隔不作 8000 约束，但重锚后下一个
//      间隔必须回到恰 8000（长跑逐段断言）；
//   2. 对齐误差 ≤±0.25 跳周期（任务卡判据）：TX/RX 双 tod 实例，RX 相位滞后
//      3333 拍 + 初值偏差 +21 tick + 帧首检测抖动扫描（δ=±100/±64/±20/0），
//      对齐后跳沿时刻按 tod 值配对互比，三档跳速各测，实测最大值入档；
//   3. 跳沿对齐用 hop_index（§7.1）：同值装订相位的跳沿计数守恒（收敛后值域
//      窗口）+ 双 fh_ctrl 实例 hop_index/channel 逐跳相等（每跳沿一拍推进命令）；
//   4. 长外推（§7.5 判据 5）：单次对齐后自由外推 40 tick，收发跳沿时刻差恒定
//      （不漂移、无抖动），且仍 ≤±0.25 跳周期。
//
// 证据口径:
//   · 真实冻结参数 TICK_SAMPLES=8000、TOD_W=32（逐拍位真比对是缩参，见
//     tb_tod_compare 头注释；本 TB 证冻结值本身的时序判据）；
//   · 全 RTL 实例互比（双 tod + 双 fh_ctrl），无黄金模型背书；黄金同构判据在
//     check_tod.py [5][6][7]，两侧同参同抖动流；
//   · 跳沿时刻按 tod 值配对（牵引瞬态游离边不配对，last-wins 消重复键），
//     与黄金 [5] 同款度量；误差基准 = 帧首检测抖动 δ（理想共钟，7.6 #2）；
//   · fh_ctrl 契约 (seed_load, seed) = (0, ·)：每跳沿一拍推进，加载拍不出数。
//
// 本 TB 自含激励，不读向量文件；结果行纯 ASCII。
// =====================================================================
`timescale 1ns/1ps

module tb_tod_align_long;

    localparam int TICK_SAMPLES = 8000;                     // 冻结值（§7.1）
    localparam int TOD_W        = 32;
    localparam int BASE         = 1000;                     // 三档网格公共基准（1000 ≡ 0 mod 1/2/10）
    localparam int RX_DELAY     = 3333;                     // RX 相位滞后（拍）
    localparam int FRAMES_A     = 20;                       // 对齐误差相位：抖动扫描对齐数
    localparam int FRAMES_B     = 10;                       // 跳沿守恒相位：对齐数
    localparam int TICKS_C      = 40;                       // 长外推：单次对齐后自由外推 tick 数
    localparam int DELTAS [0:6] = '{-100, -64, -20, 0, 20, 64, 100};  // 帧首检测抖动（拍）
    localparam int TOTAL_CYC    = (FRAMES_A + 2) * 2 * TICK_SAMPLES * 3   // A ×3 档
                                + (FRAMES_B + 2) * 2 * TICK_SAMPLES * 3   // B ×3 档
                                + (TICKS_C + 2) * TICK_SAMPLES + 100_000; // C + 余量

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // ----激励命令（每拍一命令，任务块在边沿前赋值）----
    logic        tx_valid = 1'b0, tx_load = 1'b0;
    logic [1:0]  tx_sel   = 2'd0;
    logic [31:0] tx_val   = 32'd0;
    logic        rx_valid = 1'b0, rx_load = 1'b0, rx_align = 1'b0;
    logic [1:0]  rx_sel   = 2'd0;
    logic [31:0] rx_val   = 32'd0;
    logic [5:0]  rx_a     = 6'd0;

    logic        tx_dv, tx_tick, tx_hop;
    logic [31:0] tx_tod;
    logic        rx_dv, rx_tick, rx_hop;
    logic [31:0] rx_tod;
    logic        fh_tx_v, fh_rx_v;
    logic [19:0] fh_tx_ix, fh_rx_ix;
    logic [3:0]  fh_tx_ch, fh_rx_ch;

    tod #(.TICK_SAMPLES(TICK_SAMPLES), .TOD_W(TOD_W), .FIELD_W(6)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .din_valid(tx_valid), .din_rate_sel(tx_sel), .din_tod_load(tx_load),
        .din_tod_value(tx_val), .din_align_valid(1'b0), .din_align_tod(6'd0),
        .dout_valid(tx_dv), .dout_tick(tx_tick), .dout_tod(tx_tod), .dout_hop_edge(tx_hop)
    );

    tod #(.TICK_SAMPLES(TICK_SAMPLES), .TOD_W(TOD_W), .FIELD_W(6)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .din_valid(rx_valid), .din_rate_sel(rx_sel), .din_tod_load(rx_load),
        .din_tod_value(rx_val), .din_align_valid(rx_align), .din_align_tod(rx_a),
        .dout_valid(rx_dv), .dout_tick(rx_tick), .dout_tod(rx_tod), .dout_hop_edge(rx_hop)
    );

    // 双 fh_ctrl：每跳沿一拍推进命令（跳沿对齐判据的 hop_index/channel 互比）
    fh_ctrl #(.SEED(16'h0001)) u_fh_tx (
        .clk(clk), .rst_n(rst_n),
        .din_valid(tx_hop), .din_seed_load(1'b0), .din_seed(16'd0),
        .dout_valid(fh_tx_v), .dout_hop_index(fh_tx_ix), .dout_channel(fh_tx_ch)
    );
    fh_ctrl #(.SEED(16'h0001)) u_fh_rx (
        .clk(clk), .rst_n(rst_n),
        .din_valid(rx_hop), .din_seed_load(1'b0), .din_seed(16'd0),
        .dout_valid(fh_rx_v), .dout_hop_index(fh_rx_ix), .dout_channel(fh_rx_ch)
    );

    // ----事件记录（绝对拍号；输出比输入晚 1 拍，收发同差互比抵消）----
    int cyc = 0;
    int tick_tx_cy [0:2047]; int n_tick_tx = 0;
    int tick_rx_cy [0:2047]; int n_tick_rx = 0;
    int edge_tx_cy [0:2047]; longint edge_tx_key [0:2047]; int n_edge_tx = 0;
    int edge_rx_cy [0:2047]; longint edge_rx_key [0:2047]; int n_edge_rx = 0;
    int align_rx_cy [0:2047]; int n_align_rx = 0;
    int fh_tx_ix_a [0:2047]; int fh_tx_ch_a [0:2047]; int n_fh_tx = 0;
    int fh_rx_ix_a [0:2047]; int fh_rx_ch_a [0:2047]; int n_fh_rx = 0;

    int bs_tick_tx = 0, bs_tick_rx = 0, bs_edge_tx = 0, bs_edge_rx = 0;
    int bs_align_rx = 0, bs_fh_tx = 0, bs_fh_rx = 0;

    int errs = 0;
    int align_err_max_all = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (tx_tick) begin tick_tx_cy[n_tick_tx] = cyc; n_tick_tx = n_tick_tx + 1; end
            if (rx_tick) begin tick_rx_cy[n_tick_rx] = cyc; n_tick_rx = n_tick_rx + 1; end
            if (tx_hop) begin
                edge_tx_cy[n_edge_tx] = cyc;
                edge_tx_key[n_edge_tx] = longint'(tx_tod);
                n_edge_tx = n_edge_tx + 1;
            end
            if (rx_hop) begin
                edge_rx_cy[n_edge_rx] = cyc;
                edge_rx_key[n_edge_rx] = longint'(rx_tod);
                n_edge_rx = n_edge_rx + 1;
            end
            if (rx_align) begin align_rx_cy[n_align_rx] = cyc; n_align_rx = n_align_rx + 1; end
            if (fh_tx_v) begin
                fh_tx_ix_a[n_fh_tx] = int'(fh_tx_ix); fh_tx_ch_a[n_fh_tx] = int'(fh_tx_ch);
                n_fh_tx = n_fh_tx + 1;
            end
            if (fh_rx_v) begin
                fh_rx_ix_a[n_fh_rx] = int'(fh_rx_ix); fh_rx_ch_a[n_fh_rx] = int'(fh_rx_ch);
                n_fh_rx = n_fh_rx + 1;
            end
        end
        cyc = cyc + 1;
    end

    // ----对齐时刻表（相位内共享）----
    int  n_sched = 0;
    int  sched_cy [0:63];
    logic [5:0] sched_a [0:63];

    task automatic do_reset();
        begin
            rst_n = 1'b0;
            tx_valid = 1'b0; rx_valid = 1'b0;
            tx_load = 1'b0; rx_load = 1'b0; rx_align = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #2;                                  // 监视器同沿记录已落定，取基准快照
            bs_tick_tx = n_tick_tx; bs_tick_rx = n_tick_rx;
            bs_edge_tx = n_edge_tx; bs_edge_rx = n_edge_rx;
            bs_align_rx = n_align_rx;
            bs_fh_tx = n_fh_tx; bs_fh_rx = n_fh_rx;
        end
    endtask

    // ----驱动 n_cyc 拍：TX 装订 BASE @0、RX 装订 @RX_DELAY，对齐按时刻表----
    task automatic drive(input int sel, input int n_cyc, input int value_off);
        int c, ai;
        begin
            ai = 0;
            for (c = 0; c < n_cyc; c++) begin
                tx_valid = 1'b1;
                tx_sel   = sel[1:0];
                tx_load  = (c == 0);
                tx_val   = 32'(BASE);
                rx_valid = 1'b1;
                rx_sel   = sel[1:0];
                rx_load  = (c == RX_DELAY);
                rx_val   = 32'(BASE + value_off);
                rx_align = (ai < n_sched) && (c == sched_cy[ai]);
                rx_a     = rx_align ? sched_a[ai] : 6'd0;
                if (rx_align) ai = ai + 1;
                @(posedge clk);
            end
            repeat (4) @(posedge clk);
            #2;
        end
    endtask

    function automatic int ht_of(input int sel);
        ht_of = (sel == 1) ? 2 : (sel == 2) ? 10 : 1;
    endfunction

    // ----判据 1：tick 精确性（事件间隔放行，其余恰 8000）----
    function automatic int cad_err(input bit is_rx);
        int i, t0, t1, d, a, in_span, err, b0, n;
        begin
            err = 0;
            b0  = is_rx ? bs_tick_rx : bs_tick_tx;
            n   = is_rx ? n_tick_rx  : n_tick_tx;
            for (i = b0 + 1; i < n; i++) begin
                t0 = is_rx ? tick_rx_cy[i-1] : tick_tx_cy[i-1];
                t1 = is_rx ? tick_rx_cy[i]   : tick_tx_cy[i];
                d  = t1 - t0;
                if (d != TICK_SAMPLES) begin
                    in_span = 0;
                    if (is_rx) begin
                        for (a = bs_align_rx; a < n_align_rx; a++)
                            if (align_rx_cy[a] >= t0 && align_rx_cy[a] < t1) in_span = 1;
                    end
                    if (!in_span) err = err + 1;   // 事件拍重锚放行；重锚后须回到恰 8000
                end
            end
            cad_err = err;
        end
    endfunction

    // ----判据 2：对齐误差（跳沿按 tod 值配对，last-wins 消重复键）----
    function automatic int pair_err_max(input int sel, input int cut_key, output int pairs);
        int tx_at [0:255];
        int rx_at [0:255];
        int i, k, emax, off;
        begin
            for (i = 0; i < 256; i++) begin tx_at[i] = -1; rx_at[i] = -1; end
            for (i = bs_edge_tx; i < n_edge_tx; i++)
                if (edge_tx_key[i] >= BASE && edge_tx_key[i] < BASE + 256)
                    tx_at[int'(edge_tx_key[i] - BASE)] = edge_tx_cy[i];
            for (i = bs_edge_rx; i < n_edge_rx; i++)
                if (edge_rx_key[i] >= BASE && edge_rx_key[i] < BASE + 256)
                    rx_at[int'(edge_rx_key[i] - BASE)] = edge_rx_cy[i];
            pairs = 0; emax = 0;
            for (k = cut_key - BASE; k < 256; k++) begin
                if (tx_at[k] >= 0 && rx_at[k] >= 0) begin
                    off = rx_at[k] - tx_at[k];
                    if (off < 0) off = -off;
                    if (off > emax) emax = off;
                    pairs = pairs + 1;
                end
            end
            pair_err_max = emax;
        end
    endfunction

    // ----判据 4：长外推（配对偏移恒定 = 不漂移）----
    function automatic int drift_err(input int cut_key, output int ref_off, output int pairs);
        int tx_at [0:255];
        int rx_at [0:255];
        int i, k, err, off;
        begin
            for (i = 0; i < 256; i++) begin tx_at[i] = -1; rx_at[i] = -1; end
            for (i = bs_edge_tx; i < n_edge_tx; i++)
                if (edge_tx_key[i] >= BASE && edge_tx_key[i] < BASE + 256)
                    tx_at[int'(edge_tx_key[i] - BASE)] = edge_tx_cy[i];
            for (i = bs_edge_rx; i < n_edge_rx; i++)
                if (edge_rx_key[i] >= BASE && edge_rx_key[i] < BASE + 256)
                    rx_at[int'(edge_rx_key[i] - BASE)] = edge_rx_cy[i];
            err = 0; pairs = 0; ref_off = 0;
            for (k = cut_key - BASE; k < 256; k++) begin
                if (tx_at[k] >= 0 && rx_at[k] >= 0) begin
                    off = rx_at[k] - tx_at[k];
                    if (pairs == 0) ref_off = off;
                    else if (off != ref_off) err = err + 1;
                    pairs = pairs + 1;
                end
            end
            drift_err = err;
        end
    endfunction

    // ----判据 3：跳沿计数守恒 + fh_ctrl 双实例 hop_index/channel 逐跳相等----
    function automatic int hop_check(input int sel, output int tx_cnt, output int rx_cnt,
                                     output int fh_beats, output int grid_err);
        int i, n, err, ht;
        begin
            ht = ht_of(sel);
            tx_cnt = 0; rx_cnt = 0; grid_err = 0;
            for (i = bs_edge_tx; i < n_edge_tx; i++) begin
                if (edge_tx_key[i] >= BASE + 1 && edge_tx_key[i] <= BASE + 23) tx_cnt = tx_cnt + 1;
                if (edge_tx_key[i] % ht != 0) grid_err = grid_err + 1;
            end
            for (i = bs_edge_rx; i < n_edge_rx; i++) begin
                if (edge_rx_key[i] >= BASE + 1 && edge_rx_key[i] <= BASE + 23) rx_cnt = rx_cnt + 1;
                if (edge_rx_key[i] % ht != 0) grid_err = grid_err + 1;
            end
            n = n_fh_tx - bs_fh_tx;
            fh_beats = n;
            err = (n == (n_fh_rx - bs_fh_rx)) ? 0 : 1;
            for (i = 0; i < n; i++) begin
                if (bs_fh_tx + i < n_fh_tx && bs_fh_rx + i < n_fh_rx)
                    if (fh_tx_ix_a[bs_fh_tx + i] != fh_rx_ix_a[bs_fh_rx + i]
                        || fh_tx_ch_a[bs_fh_tx + i] != fh_rx_ch_a[bs_fh_rx + i]) err = err + 1;
            end
            if (tx_cnt != rx_cnt) err = err + 1;
            hop_check = err;
        end
    endfunction

    // ----分相位激励 + 断言----
    int emax, pairs, cad_tx, cad_rx, cnt_tx, cnt_rx, fh_beats, grid_err, hop_err;
    int ref_off, drift_e, sel_i, ph;

    task automatic run_align_phase(input int sel, input int frames, input int value_off,
                                   input string tag);
        int m, ht, bound;
        begin
            ht = ht_of(sel);
            bound = (TICK_SAMPLES / 4) * ht;
            n_sched = 0;
            for (m = 1; m <= frames; m++) begin
                sched_cy[n_sched] = m * 2 * TICK_SAMPLES + DELTAS[m % 7];
                sched_a[n_sched]  = 6'((BASE + 2 * m) & 63);
                n_sched = n_sched + 1;
            end
            do_reset();
            drive(sel, (frames + 2) * 2 * TICK_SAMPLES, value_off);

            cad_tx = cad_err(1'b0);
            cad_rx = cad_err(1'b1);
            emax = pair_err_max(sel, BASE + 2 * 3 + ht, pairs);
            if (emax > align_err_max_all) align_err_max_all = emax;
            if (cad_tx != 0 || cad_rx != 0 || pairs == 0 || emax > bound) errs = errs + 1;
            $display("[TOD-LONG] phase=%0s rate_sel=%0d ht=%0d frames=%0d pairs=%0d align_err_max=%0d bound=%0d cad_tx_err=%0d cad_rx_err=%0d %s",
                     tag, sel, ht, frames, pairs, emax, bound, cad_tx, cad_rx,
                     (cad_tx == 0 && cad_rx == 0 && pairs > 0 && emax <= bound) ? "ok" : "FAIL");

            if (tag == "hop_grid") begin
                hop_err = hop_check(sel, cnt_tx, cnt_rx, fh_beats, grid_err);
                if (hop_err != 0 || grid_err != 0) errs = errs + 1;
                $display("[TOD-LONG] phase=hop_grid rate_sel=%0d cnt_tx=%0d cnt_rx=%0d fh_beats=%0d fh_err=%0d grid_err=%0d %s",
                         sel, cnt_tx, cnt_rx, fh_beats, hop_err, grid_err,
                         (hop_err == 0 && grid_err == 0) ? "ok" : "FAIL");
            end
        end
    endtask

    task automatic run_extrap_phase(input int sel);
        begin
            n_sched = 0;
            sched_cy[0] = 2 * TICK_SAMPLES + DELTAS[1];   // 单次对齐（δ=−64）
            sched_a[0]  = 6'((BASE + 2) & 63);
            n_sched = 1;
            do_reset();
            drive(sel, (TICKS_C + 2) * TICK_SAMPLES, 21);  // 初值偏差 +21 tick

            cad_tx = cad_err(1'b0);
            cad_rx = cad_err(1'b1);
            emax = pair_err_max(sel, BASE + 4, pairs);
            drift_e = drift_err(BASE + 4, ref_off, pairs);
            if (emax > align_err_max_all) align_err_max_all = emax;
            if (cad_tx != 0 || cad_rx != 0 || pairs < 30 || drift_e != 0 || emax > (TICK_SAMPLES / 4)) errs = errs + 1;
            $display("[TOD-LONG] phase=extrap rate_sel=%0d ticks=%0d pairs=%0d offset=%0d drift_err=%0d align_err_max=%0d bound=%0d cad_tx_err=%0d cad_rx_err=%0d %s",
                     sel, TICKS_C, pairs, ref_off, drift_e, emax, TICK_SAMPLES / 4, cad_tx, cad_rx,
                     (cad_tx == 0 && cad_rx == 0 && pairs >= 30 && drift_e == 0
                      && emax <= TICK_SAMPLES / 4) ? "ok" : "FAIL");
        end
    endtask

    initial begin
        @(posedge clk);
        // 判据 2/3/4：三档跳速 × 对齐误差相位 + 跳沿守恒相位（同值装订）
        for (ph = 0; ph < 3; ph++) begin
            sel_i = (ph == 0) ? 0 : (ph == 1) ? 1 : 2;
            run_align_phase(sel_i, FRAMES_A, 21, "align_err");
            run_align_phase(sel_i, FRAMES_B, 0,  "hop_grid");
        end
        // 判据 5：长外推（单次对齐 + 40 tick 自由外推，1000 hop/s）
        run_extrap_phase(0);

        $display("[TOD-LONG] align_err_max=%0d samples (bound %0d @1000hop/s)",
                 align_err_max_all, TICK_SAMPLES / 4);
        if (errs == 0) begin
            $display("[TOD-LONG] status=PASS phases=7 align_err_max=%0d tick_cadence=ok hop_index=ok drift=ok",
                     align_err_max_all);
        end else begin
            $display("[TOD-LONG] status=FAIL errs=%0d align_err_max=%0d", errs, align_err_max_all);
            $fatal(1);
        end
        $finish;
    end

    // 看门狗：总拍数 + 余量；卡死不静默挂
    initial begin
        #(10ns * TOTAL_CYC);
        $display("[TOD-LONG] status=FAIL timeout");
        $fatal(1);
    end

endmodule
