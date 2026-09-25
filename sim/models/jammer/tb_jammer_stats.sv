// =====================================================================
// tb_jammer_stats.sv — S2 干扰注入源 · 核验 TB
//
// 七个场景顺序跑，每个场景前复位一次（相位累加器/噪声种子/滤波缓冲归零），
// 把输入拍与输出拍分别落盘，交给 check_jammer_stats.py 做解析判据核验：
//
//   off          关闭干扰        → 输出与输入逐拍逐位相等
//   tone_0       单音 JSR 0 dB   → 峰频、总功率、纯度；同时是 0 dB 档标定
//   tone_5       单音 JSR 5 dB   → JSR 标定
//   tone_10      单音 JSR 10 dB  → JSR 标定
//   multitone    四音 JSR 0 dB   → 四个峰的频率与各自功率
//   sweep        锯齿扫频         → 瞬时频率斜率/起点/周期/功率
//   partial      部分频带 D=8     → -3 dB 带宽、带外抑制、功率
//
// 落盘（全部 *.log，已被 gitignore）：
//   dump/<phase>_in.log    每行「in_i in_q」
//   dump/<phase>_out.log   每行「out_i out_q jm_i jm_q」
//   dump/jammer_config.log 全部场景参数（检查器只读它，不重复写常量）
//
// 输入/输出按各拍 valid 计数落盘，对齐与流水线延迟无关。
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_jammer_stats;
    import ch_pkg::*;

    localparam int W        = 14;
    localparam int FRAC     = 11;
    localparam int SRC_W    = 16;
    localparam int SRC_FRAC = 13;
    localparam real JS      = 1.0;

    // ---- 场景参数（同时写入 dump/jammer_config.log）----
    localparam int N_OFF     = 2048;
    localparam int N_TONE    = 8192;
    localparam int N_MULTI   = 8192;
    localparam int N_SWEEP   = 4096;
    localparam int N_PARTIAL = 32768;

    localparam int TONE_FTW      = 268435456;    // 2^32/16 → f = fs/16
    localparam int JSR_0_X10     = 0;
    localparam int JSR_5_X10     = 50;
    localparam int JSR_10_X10    = 100;

    localparam int MULTI_COUNT   = 4;
    localparam int MULTI_FTW     = 268435456;    // 2^32/16
    localparam int MULTI_SPACING = 67108864;     // 2^32/64 → 间隔 fs/64

    localparam int SWEEP_FTW0    = -536870912;   // -2^32/8  → 起点 -fs/8
    localparam int SWEEP_DFW     = 1048576;      // 2^32/4096 → 斜率 fs/4096 每拍
    localparam int SWEEP_PERIOD  = 1024;         // 扫到 +fs/8 后回卷

    localparam int PB_DIV        = 8;            // 标称 -3dB 带宽 ≈ 0.88·fs/8
    localparam int PB_FTW        = 536870912;    // 中心 +fs/8

    localparam string DUMP_DIR = "dump/";

    localparam int PID_OFF     = 0;
    localparam int PID_CONST   = 1;

    // ---- 时钟与复位 ----
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- jm_top 接线 ----
    logic                in_valid;
    logic signed [W-1:0] in_i, in_q;
    logic                out_valid, jm_valid;
    logic signed [W-1:0] out_i, out_q, jm_i, jm_q;

    logic        [1:0]  cfg_type;
    logic signed [31:0] cfg_jsr_db_x10;
    logic        [2:0]  cfg_tone_count;
    logic        [31:0] cfg_tone_ftw;
    logic signed [31:0] cfg_tone_spacing;
    logic        [31:0] cfg_sweep_ftw0;
    logic signed [31:0] cfg_sweep_dfw;
    logic        [15:0] cfg_sweep_period;
    logic        [7:0]  cfg_pb_div;
    logic        [31:0] cfg_pb_ftw;

    jm_top #(
        .W(W), .FRAC(FRAC), .SRC_W(SRC_W), .SRC_FRAC(SRC_FRAC), .JS(JS),
        .SEED(32'h1A2B_3C4D)
    ) u_jm (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
        .cfg_type(cfg_type), .cfg_jsr_db_x10(cfg_jsr_db_x10),
        .cfg_tone_count(cfg_tone_count), .cfg_tone_ftw(cfg_tone_ftw),
        .cfg_tone_spacing(cfg_tone_spacing),
        .cfg_sweep_ftw0(cfg_sweep_ftw0), .cfg_sweep_dfw(cfg_sweep_dfw),
        .cfg_sweep_period(cfg_sweep_period),
        .cfg_pb_div(cfg_pb_div), .cfg_pb_ftw(cfg_pb_ftw),
        .out_valid(out_valid), .out_i(out_i), .out_q(out_q),
        .jm_valid(jm_valid), .jm_i(jm_i), .jm_q(jm_q)
    );

    // ---- 激励 ----
    int   phase_id = PID_OFF;
    int   stim_idx = 0;
    int   stim_len = 0;
    logic stim_active = 1'b0;
    logic [31:0] tb_seed = 32'h5EED_1234;
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
                PID_OFF:   begin oi = rand_code(); oq = rand_code(); end
                // 其余场景用恒定 +1.0（码 2048）：信号功率恰为 1.0 = JS，便于 JSR 标定
                default:   begin oi = 14'sd2048; oq = 14'sd0; end
            endcase
        end
    endfunction

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

    always @(posedge clk) begin
        if (rst_n && f_in != 0 && in_valid)
            $fwrite(f_in, "%0d %0d\n", in_i, in_q);
        if (rst_n && f_out != 0 && out_valid)
            $fwrite(f_out, "%0d %0d %0d %0d\n", out_i, out_q, jm_i, jm_q);
    end

    // ---- 场景调度 ----
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
                $fatal(1, "[JM] cannot open dump files for %0s", name);

            repeat (len + drain) @(posedge clk);
            stim_active = 1'b0;
            repeat (8) @(posedge clk);

            $fclose(f_in);
            $fclose(f_out);
            f_in  = 0;
            f_out = 0;
        end
    endtask

    task automatic cfg_off();
        begin
            cfg_type         = 2'd0;
            cfg_jsr_db_x10   = 32'sd0;
            cfg_tone_count   = 3'd1;
            cfg_tone_ftw     = TONE_FTW;
            cfg_tone_spacing = 32'sd0;
            cfg_sweep_ftw0   = 32'sd0;
            cfg_sweep_dfw    = 32'sd0;
            cfg_sweep_period = 16'd0;
            cfg_pb_div       = 8'd1;
            cfg_pb_ftw       = 32'd0;
        end
    endtask

    task automatic dump_config();
        integer fh;
        begin
            fh = $fopen({DUMP_DIR, "jammer_config.log"}, "w");
            if (fh == 0) $fatal(1, "[JM] cannot open jammer_config.log");
            $fwrite(fh, "W %0d\n", W);
            $fwrite(fh, "FRAC %0d\n", FRAC);
            $fwrite(fh, "SRC_W %0d\n", SRC_W);
            $fwrite(fh, "SRC_FRAC %0d\n", SRC_FRAC);
            $fwrite(fh, "JS %0.12f\n", JS);
            $fwrite(fh, "N_OFF %0d\n", N_OFF);
            $fwrite(fh, "N_TONE %0d\n", N_TONE);
            $fwrite(fh, "N_MULTI %0d\n", N_MULTI);
            $fwrite(fh, "N_SWEEP %0d\n", N_SWEEP);
            $fwrite(fh, "N_PARTIAL %0d\n", N_PARTIAL);
            $fwrite(fh, "TONE_FTW %0d\n", TONE_FTW);
            $fwrite(fh, "JSR_TONE_0_X10 %0d\n", JSR_0_X10);
            $fwrite(fh, "JSR_TONE_5_X10 %0d\n", JSR_5_X10);
            $fwrite(fh, "JSR_TONE_10_X10 %0d\n", JSR_10_X10);
            $fwrite(fh, "MULTI_COUNT %0d\n", MULTI_COUNT);
            $fwrite(fh, "MULTI_FTW %0d\n", MULTI_FTW);
            $fwrite(fh, "MULTI_SPACING %0d\n", MULTI_SPACING);
            $fwrite(fh, "SWEEP_FTW0 %0d\n", SWEEP_FTW0);
            $fwrite(fh, "SWEEP_DFW %0d\n", SWEEP_DFW);
            $fwrite(fh, "SWEEP_PERIOD %0d\n", SWEEP_PERIOD);
            $fwrite(fh, "PB_DIV %0d\n", PB_DIV);
            $fwrite(fh, "PB_FTW %0d\n", PB_FTW);
            $fclose(fh);
        end
    endtask

    initial begin
        cfg_off();

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("[JM] phase off");
        cfg_off();
        run_phase("off", PID_OFF, N_OFF, 32);

        $display("[JM] phase tone_0 (JSR 0 dB)");
        cfg_off(); cfg_type = 2'd1; cfg_jsr_db_x10 = JSR_0_X10;
        run_phase("tone_0", PID_CONST, N_TONE, 32);

        $display("[JM] phase tone_5 (JSR 5 dB)");
        cfg_off(); cfg_type = 2'd1; cfg_jsr_db_x10 = JSR_5_X10;
        run_phase("tone_5", PID_CONST, N_TONE, 32);

        $display("[JM] phase tone_10 (JSR 10 dB)");
        cfg_off(); cfg_type = 2'd1; cfg_jsr_db_x10 = JSR_10_X10;
        run_phase("tone_10", PID_CONST, N_TONE, 32);

        $display("[JM] phase multitone");
        cfg_off(); cfg_type = 2'd1; cfg_jsr_db_x10 = JSR_0_X10;
        cfg_tone_count = 3'(MULTI_COUNT); cfg_tone_ftw = MULTI_FTW;
        cfg_tone_spacing = MULTI_SPACING;
        run_phase("multitone", PID_CONST, N_MULTI, 32);

        $display("[JM] phase sweep");
        cfg_off(); cfg_type = 2'd2; cfg_jsr_db_x10 = JSR_0_X10;
        cfg_sweep_ftw0 = SWEEP_FTW0; cfg_sweep_dfw = SWEEP_DFW;
        cfg_sweep_period = SWEEP_PERIOD[15:0];
        run_phase("sweep", PID_CONST, N_SWEEP, 32);

        $display("[JM] phase partial");
        cfg_off(); cfg_type = 2'd3; cfg_jsr_db_x10 = JSR_0_X10;
        cfg_pb_div = PB_DIV[7:0]; cfg_pb_ftw = PB_FTW;
        run_phase("partial", PID_CONST, N_PARTIAL, 32);

        dump_config();
        $display("[JM] all phases dumped");
        $finish;
    end

endmodule

`default_nettype wire
