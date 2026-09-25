// =====================================================================
// tb_channel_stats.sv — S2 信道模型库 · 统计核验 TB
//
// 七个场景顺序跑，每个场景只开一级效应，把「输入拍序列」与「输出拍序列」
// 分别落盘，交给 check_channel_stats.py 做解析判据核验：
//
//   identity    全旁路            → 输出必须与输入逐拍逐位相等
//   awgn        只开 AWGN         → 噪声均值/方差/白性；期望 σ 由 golden_ref 现算
//   cfo         只开 CFO          → 相位斜率 = 2π·FTW/2^32，幅度不变
//   sfo         只开 SFO          → μ_m = frac(m·δ) 的锯齿漂移 + 率 δ
//   mp_impulse  只开多径（冲激）   → 冲激响应 = 抽头系数（±1 LSB）
//   mp_rayleigh 只开多径（纯瑞利） → 各抽头功率 = 指数 PDP，幅度比 = π/4
//   mp_rician   只开多径（K=6dB） → 由统计估出的 K 与配置一致
//
// 落盘约定（全部 *.log，已被 .gitignore 忽略，可随时重跑重建）：
//   dump/<phase>_in.log    每行「in_i in_q」，一行 = 一个输入拍
//   dump/<phase>_out.log   每行「out_i out_q [mu]」，一行 = 一个输出拍
//   dump/mp_taps.log       冲激场景下模型实际使用的抽头系数
//   dump/mp_fade_*.log     每次 reseed 的复系数，一行 = 一组抽头
//   dump/channel_config.log 全部场景参数（检查器只读它，不在 Python 里重写常量）
//
// 输入/输出都按各拍 valid 计数落盘，故对齐与流水线延迟、SFO 的首拍跳过无关。
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_channel_stats;
    import ch_pkg::*;

    localparam int  W    = 14;
    localparam int  FRAC = 11;

    // ---- 场景参数（同时写入 dump/channel_config.log）----
    localparam real EB_N0_DB      = 4.0;
    localparam real ES            = 1.0;
    localparam real BIT_RATE      = 1.0;
    localparam int  NTAPS         = 4;
    localparam real PDP_DECAY_DB  = 3.0;
    localparam int  N_IDENT       = 2048;
    localparam int  N_AWGN        = 65536;
    localparam int  N_CFO         = 4096;
    localparam int  N_SFO         = 4096;
    localparam int  N_MP_IMP      = 64;
    localparam int  M_FADE        = 16384;
    localparam int  CFO_FTW       = 67108864;      // 2^32/64 → 归一化频偏 1/64
    localparam int  SFO_PPM       = 5000;          // δ = 5e-3
    localparam real K_RICIAN_DB   = 6.0;
    localparam int  MP_PURE_RAY_DB_X10 = -990;     // 纯瑞利：K = 0

    localparam string DUMP_DIR = "dump/";

    localparam int PID_IDENT = 0;
    localparam int PID_AWGN  = 1;
    localparam int PID_CFO   = 2;
    localparam int PID_SFO   = 3;
    localparam int PID_MPIMP = 4;

    // ---- 时钟与复位 ----
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- ch_top 接线 ----
    logic                in_valid;
    logic signed [W-1:0] in_i, in_q;
    logic                out_valid;
    logic signed [W-1:0] out_i, out_q;
    logic        [31:0]  slip_cnt;

    logic               cfg_mp_en, cfg_sfo_en, cfg_cfo_en, cfg_awgn_en, cfg_mp_reseed;
    logic signed [31:0] cfg_sfo_ppm, cfg_mp_k_db_x10;
    logic        [31:0] cfg_cfo_ftw;

    ch_top #(
        .W(W), .FRAC(FRAC), .ES(ES), .BIT_RATE(BIT_RATE), .EB_N0_DB(EB_N0_DB),
        .NTAPS(NTAPS), .PDP_DECAY_DB(PDP_DECAY_DB), .SEED(32'hC0FF_EE01)
    ) u_ch (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
        .cfg_mp_en(cfg_mp_en), .cfg_sfo_en(cfg_sfo_en),
        .cfg_cfo_en(cfg_cfo_en), .cfg_awgn_en(cfg_awgn_en),
        .cfg_sfo_ppm(cfg_sfo_ppm), .cfg_cfo_ftw(cfg_cfo_ftw),
        .cfg_mp_k_db_x10(cfg_mp_k_db_x10), .cfg_mp_reseed(cfg_mp_reseed),
        .out_valid(out_valid), .out_i(out_i), .out_q(out_q), .slip_cnt(slip_cnt)
    );

    // ---- 激励 ----
    int   phase_id  = PID_IDENT;
    int   stim_idx  = 0;
    int   stim_len  = 0;
    logic stim_active = 1'b0;
    logic [31:0] tb_seed = 32'h0BAD_F00D;
    int   sfo_slips_obs = 0;       // SFO 相位结束时的滑码次数

    logic signed [W-1:0] s_i, s_q;

    function automatic logic signed [W-1:0] rand_code();
        begin
            xs32(tb_seed);
            return $signed(tb_seed[13:0]);
        end
    endfunction

    function automatic void stim_sample(input int pid, input int idx,
                                       output logic signed [W-1:0] oi,
                                       output logic signed [W-1:0] oq);
        begin
            oi = '0;
            oq = '0;
            case (pid)
                PID_IDENT: begin oi = rand_code(); oq = rand_code(); end
                PID_AWGN:  begin oi = (idx < N_AWGN/2) ? 14'sd2048 : -14'sd2048; end
                PID_CFO:   begin oi = 14'sd2048; end
                PID_SFO:   begin oi = idx[13:0]; end          // 斜坡：码值 = 拍号
                PID_MPIMP: begin oi = (idx == 0) ? 14'sd2048 : 14'sd0; end
                default:   begin end
            endcase
        end
    endfunction

    // 激励驱动（与非阻塞赋值同拍语义，保证 dump 到的正是 DUT 消费的那一拍）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid <= 1'b0;
            in_i     <= '0;
            in_q     <= '0;
            stim_idx <= 0;
        end else if (stim_active && stim_idx < stim_len) begin
            stim_sample(phase_id, stim_idx, s_i, s_q);
            in_valid <= 1'b1;
            in_i     <= s_i;
            in_q     <= s_q;
            stim_idx <= stim_idx + 1;
        end else begin
            in_valid <= 1'b0;
        end
    end

    // ---- 落盘 ----
    integer f_in  = 0;
    integer f_out = 0;
    logic   dump_mu = 1'b0;

    // dump_mu 置位时（SFO 相位）改为直接取 SFO 子模块自己的输入/输出/valid/μ：
    // ch_top 的输出还要经 CFO、AWGN 两级寄存，而 μ 每拍都被覆盖，从顶层取数会让
    // (输出值, μ) 错开两拍——层次引用取同一拍，pairing 才成立。
    always @(posedge clk) begin
        if (dump_mu) begin
            if (rst_n && f_in != 0 && u_ch.v0)
                $fwrite(f_in, "%0d %0d\n", u_ch.a_i, u_ch.a_q);
            if (rst_n && f_out != 0 && u_ch.v1)
                $fwrite(f_out, "%0d %0d %0.12f\n", u_ch.b_i, u_ch.b_q, u_ch.u_sfo.mu_used);
        end else begin
            if (rst_n && f_in != 0 && in_valid)
                $fwrite(f_in, "%0d %0d\n", in_i, in_q);
            if (rst_n && f_out != 0 && out_valid)
                $fwrite(f_out, "%0d %0d\n", out_i, out_q);
        end
    end

    // ---- 场景调度 ----
    // 注意：开激励与关激励必须在**同一任务**里隔着时钟边沿做。若拆成
    // start_phase/end_phase 两个任务背靠背调用，stim_active 会在同一时间步内
    // 被置 1 又清 0，驱动器一个时钟沿都看不到，激励等于没发（dump 全空文件）。
    // 每个相位前复位一次：延迟线、插值历史、相位累加器、噪声种子都归零。
    // 不复位会让上一相位的残留样本被本相位当成历史（冲激响应里就会混进
    // 上一相位斜坡的尾巴，实测偏差可达数千码）。
    task automatic do_reset();
        begin
            stim_active = 1'b0;
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic run_phase(input string name, input int pid, input int len, input int drain);
        begin
            do_reset();

            phase_id    = pid;
            stim_len    = len;
            stim_idx    = 0;
            stim_active = 1'b1;

            f_in  = $fopen({DUMP_DIR, name, "_in.log"}, "w");
            f_out = $fopen({DUMP_DIR, name, "_out.log"}, "w");
            if (f_in == 0 || f_out == 0)
                $fatal(1, "[CH] cannot open dump files for %0s", name);

            repeat (len + drain) @(posedge clk);   // 送满 len 拍，再等流水线排空
            stim_active = 1'b0;
            repeat (8) @(posedge clk);

            $fclose(f_in);
            $fclose(f_out);
            f_in  = 0;
            f_out = 0;
        end
    endtask

    task automatic clear_cfg();
        begin
            cfg_mp_en   = 1'b0;
            cfg_sfo_en  = 1'b0;
            cfg_cfo_en  = 1'b0;
            cfg_awgn_en = 1'b0;
        end
    endtask

    // 抽头统计场景：连续 reseed 采样复系数
    task automatic run_fading(input string name, input int k_db_x10);
        integer fh;
        begin
            clear_cfg();
            cfg_mp_en        = 1'b1;
            cfg_mp_k_db_x10  = k_db_x10;
            cfg_mp_reseed    = 1'b0;
            do_reset();                       // 抽头按当前 K 重生成，延迟线清零
            fh = $fopen({DUMP_DIR, name, ".log"}, "w");
            if (fh == 0) $fatal(1, "[CH] cannot open %0s", name);

            for (int m = 0; m < M_FADE; m++) begin
                cfg_mp_reseed = 1'b1;
                @(posedge clk);                  // 本拍 ch_multipath 采样到 reseed → gen_taps
                cfg_mp_reseed = 1'b0;
                #1;                              // 让出该时间步，确保阻塞写的系数已生效
                for (int t = 0; t < NTAPS; t++)
                    $fwrite(fh, "%0.9f %0.9f ", u_ch.u_mp.h_i[t], u_ch.u_mp.h_q[t]);
                $fwrite(fh, "\n");
                @(posedge clk);
            end
            $fclose(fh);
            cfg_mp_en = 1'b0;
        end
    endtask

    task automatic dump_taps();
        integer fh;
        begin
            fh = $fopen({DUMP_DIR, "mp_taps.log"}, "w");
            if (fh == 0) $fatal(1, "[CH] cannot open mp_taps.log");
            $fwrite(fh, "# ntaps=%0d pdp_decay_db=%0.3f k_db_x10=%0d\n",
                    NTAPS, PDP_DECAY_DB, cfg_mp_k_db_x10);
            for (int t = 0; t < NTAPS; t++)
                $fwrite(fh, "%0d %0.12f %0.12f %0.12f\n",
                        t, u_ch.u_mp.h_i[t], u_ch.u_mp.h_q[t], u_ch.u_mp.p_k[t]);
            $fclose(fh);
        end
    endtask

    task automatic dump_config();
        integer fh;
        begin
            fh = $fopen({DUMP_DIR, "channel_config.log"}, "w");
            if (fh == 0) $fatal(1, "[CH] cannot open channel_config.log");
            $fwrite(fh, "W %0d\n", W);
            $fwrite(fh, "FRAC %0d\n", FRAC);
            $fwrite(fh, "ES %0.12f\n", ES);
            $fwrite(fh, "BIT_RATE %0.12f\n", BIT_RATE);
            $fwrite(fh, "EB_N0_DB %0.6f\n", EB_N0_DB);
            $fwrite(fh, "NTAPS %0d\n", NTAPS);
            $fwrite(fh, "PDP_DECAY_DB %0.6f\n", PDP_DECAY_DB);
            $fwrite(fh, "N_IDENT %0d\n", N_IDENT);
            $fwrite(fh, "N_AWGN %0d\n", N_AWGN);
            $fwrite(fh, "N_CFO %0d\n", N_CFO);
            $fwrite(fh, "N_SFO %0d\n", N_SFO);
            $fwrite(fh, "N_MP_IMP %0d\n", N_MP_IMP);
            $fwrite(fh, "M_FADE %0d\n", M_FADE);
            $fwrite(fh, "CFO_FTW %0d\n", CFO_FTW);
            $fwrite(fh, "SFO_PPM %0d\n", SFO_PPM);
            $fwrite(fh, "K_RICIAN_DB %0.6f\n", K_RICIAN_DB);
            $fwrite(fh, "MP_PURE_RAY_DB_X10 %0d\n", MP_PURE_RAY_DB_X10);
            $fwrite(fh, "AWGN_SIGMA %0.12f\n", u_ch.u_awgn.sigma);
            $fwrite(fh, "SFO_SLIPS %0d\n", sfo_slips_obs);
            $fclose(fh);
        end
    endtask

    initial begin
        clear_cfg();
        cfg_sfo_ppm      = 32'sd0;
        cfg_cfo_ftw      = 32'd0;
        cfg_mp_k_db_x10  = 32'sd0;
        cfg_mp_reseed    = 1'b0;
        dump_mu          = 1'b0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("[CH] phase identity");
        run_phase("identity", PID_IDENT, N_IDENT, 32);

        $display("[CH] phase awgn");
        clear_cfg(); cfg_awgn_en = 1'b1;
        run_phase("awgn", PID_AWGN, N_AWGN, 32);

        $display("[CH] phase cfo");
        clear_cfg(); cfg_cfo_en = 1'b1; cfg_cfo_ftw = CFO_FTW;
        run_phase("cfo", PID_CFO, N_CFO, 32);

        $display("[CH] phase sfo");
        clear_cfg(); cfg_sfo_en = 1'b1; cfg_sfo_ppm = SFO_PPM;
        dump_mu = 1'b1;
        run_phase("sfo", PID_SFO, N_SFO, 32);
        dump_mu = 1'b0;
        sfo_slips_obs = slip_cnt;      // 及时抓取：后续相位复位会把 slip_cnt 清零

        $display("[CH] phase mp_impulse");
        clear_cfg();
        cfg_mp_en       = 1'b1;
        cfg_mp_k_db_x10 = MP_PURE_RAY_DB_X10;   // 纯瑞利，复位时已按此 K 重生成抽头
        run_phase("mp_impulse", PID_MPIMP, N_MP_IMP, 48);
        dump_taps();                            // dump 复位后实际使用的那组系数
        cfg_mp_en = 1'b0;

        $display("[CH] phase mp_rayleigh");
        run_fading("mp_fade_rayleigh", MP_PURE_RAY_DB_X10);

        $display("[CH] phase mp_rician");
        run_fading("mp_fade_rician", $rtoi(K_RICIAN_DB * 10.0));

        $display("[CH] slip_cnt=%0d", slip_cnt);
        dump_config();                      // 参数在最后落盘：滑码次数等要等跑完才有
        $display("[CH] all phases dumped");
        $finish;
    end

endmodule

`default_nettype wire
