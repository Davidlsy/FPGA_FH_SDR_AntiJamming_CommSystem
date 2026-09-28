`timescale 1ns / 1ps
`default_nettype none
//=====================================================================
// tb_ad9363_cfg.sv
//---------------------------------------------------------------------
// S3 D3: ad9363_cfg + spi_master + ad9363_spi_model 全链路验证
//
//   R1 正常配置 : 跑完初始化表, done=1/error=0, 逐寄存器 peek 比对,
//                prog_cnt == 11 (END 之前的表项数)
//   R2 回读失配 : inject_readback_err 破坏首个读字节 -> error=2,
//                fault_addr=0x013 (第一个 READV 目标)
//   R3 恢复     : 无注入重跑 -> done=1/error=0
//   R4 暂停/恢复: 表项边界暂停 -> prog_cnt 冻结/看门狗不误触发 -> 从断点续跑,
//                不重复已执行表项 (以模型事务数 9 为证)
//   R5 逐条比对 : 引脚波形嗅探 vs CSV 派生的期望, 逐条核验 (op,addr,data) 与延时
//   R6 无应答   : 掐断命令握手 -> cfg 总看门狗 error=3 -> 放开后恢复
//   R7 表项损坏 : 改写 cfg_rom 造非法 OP -> error=4 安全报错 -> 恢复表后重跑
//   R8 中途复位 : 表项之间拉低 rst_n -> 回 IDLE 无死锁 -> 重跑完好
//   R9 重复上电 : 连续两次完整序列不做复位 -> 事务数/软复位次数证明无状态残留
//   收尾        : 模型计数器审计 (extra SCLK / early CSB 等)
//
// 运行: run_ad9363_cfg.bat
//=====================================================================
module tb_ad9363_cfg;

    //------------------------------ 时钟/复位 ------------------------------
    reg clk = 1'b0;
    always #10 clk = ~clk;                // 50 MHz
    reg rst_n = 1'b0;

    //------------------------------ cfg 接口 ------------------------------
    reg  start = 1'b0;
    reg  pause = 1'b0;
    wire busy;
    wire paused;
    wire done;
    wire [3:0]  error;
    wire [9:0]  fault_addr;
    wire [15:0] prog_cnt;

    //------------------------------ cfg <-> spi_master 内部连线 ------------------------------
    // 命令握手经一道闸门: block_spi=1 时两侧的 valid/ready 同时掐断, 等价于"总线无应答"
    // (主控不接命令), 供 R6 验证 cfg 的总看门狗。正常跑表时 block_spi 恒为 0。
    reg         block_spi = 1'b0;
    wire        c_valid_raw, c_ready_raw;
    wire        c_valid, c_ready, c_rd;
    assign c_valid = c_valid_raw & ~block_spi;
    assign c_ready = c_ready_raw & ~block_spi;
    wire [9:0]  c_addr;
    wire [2:0]  c_nbm1;
    wire [7:0]  c_div;
    wire        w_valid, w_rdy;
    wire [7:0]  w_data;
    wire [7:0]  rdata;
    wire        rdata_valid;
    wire        spi_done;
    wire [3:0]  spi_error;
    wire        spi_busy;

    //------------------------------ SPI 引脚 ------------------------------
    wire spi_sclk, spi_csb, sdo, sdo_oe, sdi;
    wire sdio;
    assign sdio = sdo_oe ? sdo : 1'bz;

    //------------------------------ DUT / 模型 ------------------------------
    ad9363_cfg #(
        // 总看门狗刻意收紧到 150us (默认 100000us): 一次正常跑表约 95us, 而 R4 的
        // 暂停时长是 250us —— 若暂停期间看门狗未冻结, R4 必然报 error=3。
        .DEPTH(256), .CLKS_PER_US(50), .CMD_DIV(8'd4), .TIMEOUT_US(24'd150)
    ) cfg (
        .clk(clk), .rst_n(rst_n),
        .start(start), .pause(pause), .busy(busy), .paused(paused), .done(done), .error(error),
        .fault_addr(fault_addr), .prog_cnt(prog_cnt),
        .spi_cmd_valid(c_valid_raw), .spi_cmd_ready(c_ready),
        .spi_cmd_rd(c_rd), .spi_cmd_addr(c_addr),
        .spi_cmd_nb_m1(c_nbm1), .spi_cmd_div(c_div),
        .spi_wbuf_valid(w_valid), .spi_wbuf_rdy(w_rdy), .spi_wbuf_data(w_data),
        .spi_rdata(rdata), .spi_rdata_valid(rdata_valid),
        .spi_done(spi_done), .spi_error(spi_error), .spi_busy(spi_busy)
    );

    spi_master #(.TIMEOUT_CLKS(24'd3000)) master (
        .clk(clk), .rst_n(rst_n),
        .cmd_ready(c_ready_raw), .cmd_valid(c_valid), .cmd_rd(c_rd),
        .cmd_addr(c_addr), .cmd_nb_m1(c_nbm1), .cmd_div(c_div),
        .cmd_cpol(1'b0), .cmd_cpha(1'b0),
        .wbuf_rdy(w_rdy), .wbuf_valid(w_valid), .wbuf_data(w_data),
        .rdata(rdata), .rdata_valid(rdata_valid),
        .done(spi_done), .error(spi_error), .busy(spi_busy),
        .sdi(sdi), .sdo(sdo), .sdo_oe(sdo_oe),
        .spi_sclk(spi_sclk), .spi_csb(spi_csb)
    );

    ad9363_spi_model #(.TCO_NS(5.0), .TIMEOUT_NS(1000.0), .VERBOSE(0)) model (
        .sclk(spi_sclk), .csb(spi_csb), .sdio(sdio), .sdo(sdi), .gp_resetb(1'b1)
    );

    //------------------------------ SPI 事务嗅探 (器件视角, 不读 DUT 内部信号) ------------------------------
    // 从 CSB/SCLK/SDIO 三个引脚还原出器件实际看到的事务序列, 作为逐条比对的【实测侧】。
    // 采样点与 tb_spi_master.sv 的协议间谍一致: 沿 sclk 上升沿取位(器件在同一沿后 tCO 才
    // 更新 SDO, 故此刻读到的是本拍应采的那一位), 写数据取 SDIO, 读数据取器件侧的 SDO。
    localparam integer MAX_SN = 256;
    reg [3:0]  sn_op    [0:MAX_SN-1];   // 0=写, 1=读
    reg [9:0]  sn_addr  [0:MAX_SN-1];
    reg [7:0]  sn_data  [0:MAX_SN-1];
    time       sn_start [0:MAX_SN-1];   // CSB 下降沿 = 事务开始
    time       sn_end   [0:MAX_SN-1];   // CSB 上升沿 = 事务结束
    integer    sn_n = 0;
    reg        sn_en = 1'b0;
    reg        sn_overflow = 1'b0;

    reg [15:0] sn_instr;
    reg [7:0]  sn_byte;
    reg [4:0]  sn_bitcnt;
    reg        sn_in_data, sn_is_wr;

    always @(negedge spi_csb) begin
        if (sn_en) begin
            sn_instr   = 16'd0;
            sn_bitcnt  = 5'd0;
            sn_in_data = 1'b0;
            if (sn_n < MAX_SN) sn_start[sn_n] = $time;
        end
    end

    always @(posedge spi_sclk) begin
        if (sn_en && !spi_csb) begin
            if (!sn_in_data) begin
                sn_instr = {sn_instr[14:0], sdio};
                if (sn_bitcnt == 5'd15) begin
                    sn_is_wr   = sn_instr[15];
                    sn_in_data = 1'b1;
                    sn_bitcnt  = 5'd0;
                end else sn_bitcnt = sn_bitcnt + 5'd1;
            end else begin
                sn_byte = sn_is_wr ? {sn_byte[6:0], sdio} : {sn_byte[6:0], sdi};
                if (sn_bitcnt == 5'd7) begin
                    if (sn_n < MAX_SN) begin
                        sn_op[sn_n]   = sn_is_wr ? 4'd0 : 4'd1;
                        sn_addr[sn_n] = sn_instr[9:0];
                        sn_data[sn_n] = sn_byte;
                    end else sn_overflow = 1'b1;
                    sn_bitcnt = 5'd0;
                end else sn_bitcnt = sn_bitcnt + 5'd1;
            end
        end
    end

    always @(posedge spi_csb) begin
        if (sn_en && sn_n < MAX_SN) begin
            sn_end[sn_n] = $time;
            sn_n = sn_n + 1;
        end
    end

    //------------------------------ 逐条期望 (由 gen_init_table.py 从 CSV 独立编码) ------------------------------
    localparam integer MAX_EX = 256;
    integer   ex_n, ex_words;
    reg [3:0] ex_op   [0:MAX_EX-1];
    reg [9:0] ex_addr [0:MAX_EX-1];
    reg [7:0] ex_data [0:MAX_EX-1];
    integer   ex_gap  [0:MAX_EX-1];
    reg       ex_loaded = 1'b0;

    // 实测间隙相对表内声明延时的允许上界 (ns): 状态机搬运 + CSB 间隔/建立/保持节拍,
    // 以及 S_DELAY 的 us 节拍对齐 (声明的 N us 实际等 N+1 个 us 节拍) 之和。
    localparam integer GAP_MARGIN_NS = 4000;

    task automatic load_expect(input string path);
        integer fd, i, rc, op_i, gap_i;
        reg [9:0] a;
        reg [7:0] d;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                check(1'b0, "expect file opened");
            end else begin
                rc = $fscanf(fd, "%d %d", ex_n, ex_words);
                if (rc != 2) check(1'b0, "expect header parsed");
                for (i = 0; i < ex_n; i = i + 1) begin
                    rc = $fscanf(fd, "%d %h %h %d", op_i, a, d, gap_i);
                    if (rc != 4) check(1'b0, $sformatf("expect line[%0d] parsed", i));
                    ex_op[i] = op_i[3:0]; ex_addr[i] = a; ex_data[i] = d; ex_gap[i] = gap_i;
                end
                $fclose(fd);
                ex_loaded = 1'b1;
            end
        end
    endtask

    //------------------------------ 计分板 ------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check(input bit ok, input string tag);
        begin
            if (ok) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("[%0t] [FAIL] %0s", $time, tag);
            end
        end
    endtask

    // 触发一次配置并等 done / error
    task automatic run_once(output bit got_done, output [3:0] err);
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            got_done = 0; err = 0;
            while (1) begin
                @(negedge clk);
                if (done) begin got_done = 1; break; end
                if (error != 4'd0) begin err = error; break; end
            end
            repeat (2) @(negedge clk);
        end
    endtask

    //------------------------------ 测试主体 ------------------------------
    bit gd;
    reg [3:0] er;
    integer   r4_guard;
    reg [15:0] r4_snap;
    integer   r5_i;
    time      r5_gap;
    integer   r6_guard;
    integer   r6_state;
    integer   r6_wd;
    reg [31:0] rom3_orig;

    initial begin
        $display("==== tb_ad9363_cfg: start ====");
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        //---------------- R1: 正常配置 ----------------
        run_once(gd, er);
        check(gd == 1,        "R1 done");
        check(er == 4'd0,     "R1 error==0");
        check(prog_cnt == 16'd11, "R1 prog_cnt==11");
        check(model.peek_reg(10'h013) === 8'hA5, "R1 reg 0x013");
        check(model.peek_reg(10'h020) === 8'h33, "R1 reg 0x020");
        check(model.peek_reg(10'h004) === 8'h11, "R1 reg 0x004");
        check(model.peek_reg(10'h005) === 8'h22, "R1 reg 0x005");
        check(model.peek_reg(10'h028) === 8'hDE, "R1 reg 0x028");
        // 软复位后 0x003 默认 0x5F 应保持 (表里没写它)
        check(model.peek_reg(10'h003) === 8'h5F, "R1 reg 0x003 default");

        //---------------- R2: 回读失配 ----------------
        model.inject_readback_err(8'hFF, 1);   // 破坏第一个读字节 (0x013)
        run_once(gd, er);
        check(gd == 0,            "R2 no done");
        check(er == 4'd2,         "R2 error==2 (readback)");
        check(fault_addr == 10'h013, "R2 fault_addr==0x013");
        model.reset_stats();

        //---------------- R3: 恢复 ----------------
        run_once(gd, er);
        check(gd == 1,      "R3 done");
        check(er == 4'd0,   "R3 error==0");
        check(model.peek_reg(10'h013) === 8'hA5, "R3 reg 0x013 recovered");

        //---------------- R4: 暂停/恢复 ----------------
        model.reset_stats();
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        // 第 1 个写表项完成后再请求暂停, 使暂停点落在表项边界
        while (prog_cnt < 16'd1) @(negedge clk);
        pause = 1'b1;
        r4_guard = 0;
        while (paused !== 1'b1 && r4_guard < 20000) begin
            @(negedge clk);
            r4_guard = r4_guard + 1;
        end
        check(paused === 1'b1, "R4 paused at entry boundary");
        check(busy   === 1'b1, "R4 busy stays high while paused");

        r4_snap = prog_cnt;
        repeat (12500) @(negedge clk);          // 250 us > 收紧后的看门狗 150 us
        check(prog_cnt === r4_snap, "R4 prog_cnt frozen while paused");
        check(done     === 1'b0,    "R4 no done while paused");
        check(error    ==  4'd0,    "R4 watchdog frozen while paused");

        pause = 1'b0;
        gd = 0; er = 0;
        while (1) begin
            @(negedge clk);
            if (done) begin gd = 1; break; end
            if (error != 4'd0) begin er = error; break; end
        end
        check(gd == 1,            "R4 done after resume");
        check(er == 4'd0,         "R4 error==0 after resume");
        check(prog_cnt == 16'd11, "R4 prog_cnt==11 after resume");
        check(model.txn_cnt == 9, "R4 no entry re-executed (9 transactions)");
        check(model.peek_reg(10'h028) === 8'hDE, "R4 reg 0x028 after resume");

        //---------------- R5: 逐条 (地址,数据,延时) 三元组比对 ----------------
        // 实测侧 = 引脚波形嗅探, 期望侧 = gen_init_table.py 从 CSV 独立编码的产物。
        // 把"表驱动状态机是否忠实执行 cfg_rom"从"跑完查几个寄存器"升级为逐条证据:
        // 顺序、地址、数据逐条比对, 表内声明的延时按实测事务间隙核验。
        load_expect("ad9363_init_expect.txt");
        check(ex_loaded == 1'b1, "R5 expect file loaded");
        check(ex_n     == 9,     "R5 expect txn count==9");
        check(ex_words == 12,    "R5 expect rom word count==12");

        sn_n = 0;
        sn_overflow = 1'b0;
        sn_en = 1'b1;
        run_once(gd, er);
        sn_en = 1'b0;

        check(gd == 1,             "R5 done");
        check(er == 4'd0,          "R5 error==0");
        $display("[%0t] R5 run duration: 看门狗计数 wd_us=%0d us (限值 150 us)", $time, cfg.wd_us);
        check(sn_overflow == 1'b0, "R5 sniffer no overflow");
        check(sn_n == ex_n,        "R5 sniffed txn count matches table");

        for (r5_i = 0; r5_i < ex_n; r5_i = r5_i + 1) begin
            if (r5_i < sn_n) begin
                check(sn_op[r5_i]   === ex_op[r5_i],   $sformatf("R5 txn[%0d] op",   r5_i));
                check(sn_addr[r5_i] === ex_addr[r5_i], $sformatf("R5 txn[%0d] addr", r5_i));
                check(sn_data[r5_i] === ex_data[r5_i], $sformatf("R5 txn[%0d] data", r5_i));
            end
        end

        for (r5_i = 0; r5_i < ex_n - 1; r5_i = r5_i + 1) begin
            if (r5_i + 1 < sn_n) begin
                r5_gap = sn_start[r5_i + 1] - sn_end[r5_i];
                $display("[%0t] R5 gap[%0d->%0d] meas=%0d ns declared=%0d us",
                         $time, r5_i, r5_i + 1, r5_gap, ex_gap[r5_i]);
                check((r5_gap >= ex_gap[r5_i] * 1000)
                      && (r5_gap <= ex_gap[r5_i] * 1000 + GAP_MARGIN_NS),
                      $sformatf("R5 gap[%0d] within [%0d, %0d] ns", r5_i,
                                ex_gap[r5_i] * 1000, ex_gap[r5_i] * 1000 + GAP_MARGIN_NS));
            end
        end

        //---------------- R6: SPI 无应答 -> 总看门狗 error=3 ----------------
        // 掐断 cfg->spi_master 的命令握手 (等价于总线不响应): 状态机卡在 S_WRCMD,
        // 由 cfg 自己的总看门狗 (本 TB 收紧到 150us) 兜住 -> error=3。这条错误路径
        // 在原 TB 里从未被执行过。随后放开闸门, 验证可恢复。
        model.reset_stats();
        block_spi = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        gd = 0; er = 0;
        r6_guard = 0;
        while (gd == 0 && er == 0 && r6_guard < 20000) begin
            @(negedge clk);
            if (done)          gd = 1;
            if (error != 4'd0) er = error;
            r6_guard = r6_guard + 1;
        end
        $display("[%0t] R6 diag: er=%0d error=%0d state=%0d wd_us=%0d busy=%b guard=%0d",
                 $time, er, error, cfg.state, cfg.wd_us, busy, r6_guard);
        check(gd == 0,              "R6 no done (transaction never completes)");
        check(er == 4'd3,           "R6 error==3 (cfg watchdog)");
        check(cfg.state == 4'd0,    "R6 FSM back to IDLE (no deadlock)");
        check(fault_addr == 10'h000, "R6 fault_addr=0x000 (首条写 0x000)");
        check(model.txn_cnt == 0,   "R6 no SPI transaction reached the device");
        block_spi = 1'b0;
        repeat (4) @(negedge clk);
        sn_n = 0; sn_overflow = 1'b0; sn_en = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        gd = 0; er = 0; r6_guard = 0;
        r6_state = -1; r6_wd = -1;
        while (gd == 0 && er == 0 && r6_guard < 20000) begin
            @(negedge clk);
            if (done) gd = 1;
            if (error != 4'd0 && er == 4'd0) begin
                er = error; r6_state = cfg.state; r6_wd = cfg.wd_us;
            end
            r6_guard = r6_guard + 1;
        end
        sn_en = 1'b0;
        if (gd == 0 || er != 4'd0 || sn_n != 9) begin
            for (r5_i = 0; r5_i < sn_n; r5_i = r5_i + 1)
                $display("[%0t] R6 sniff[%0d] op=%0d addr=0x%03h data=0x%02h start=%0t end=%0t",
                         $time, r5_i, sn_op[r5_i], sn_addr[r5_i], sn_data[r5_i],
                         sn_start[r5_i], sn_end[r5_i]);
        end
        check(sn_n == 9, "R6 recovery run issued exactly 9 transactions");
        $display("[%0t] R6 recovery diag: gd=%0d er=%0d txn=%0d state=%0d wd=%0d guard=%0d prog_cnt=%0d",
                 $time, gd, er, model.txn_cnt, r6_state, r6_wd, r6_guard, prog_cnt);
        check(gd == 1,    $sformatf("R6 done after gate released (er=%0d)", er));
        check(er == 4'd0, "R6 error==0 after gate released");
        check(model.txn_cnt == 9, "R6 full table re-run after recovery");

        //---------------- R7: 表项损坏 -> 非法 OP error=4 ----------------
        // 直接改写 cfg_rom 的字, 造一条 OP 未定义的表项 (OP=5, 地址 0x0AA):
        // 期望状态机安全报错而非执行未知操作。用完恢复原字。
        model.reset_stats();
        rom3_orig = cfg.rom[3];
        cfg.rom[3] = 32'h52A80000;      // OP=5 未定义 | ADDR=0x0AA | DATA/DELAY=0
        run_once(gd, er);
        check(gd == 0,               "R7 no done");
        check(er == 4'd4,            "R7 error==4 (bad op)");
        check(fault_addr == 10'h0AA, "R7 fault_addr=0x0AA (损坏表项地址)");
        cfg.rom[3] = rom3_orig;
        model.reset_stats();
        run_once(gd, er);
        check(gd == 1,    "R7 done after table restored");
        check(er == 4'd0, "R7 error==0 after table restored");
        check(prog_cnt == 16'd11, "R7 prog_cnt==11 after table restored");

        //---------------- R8: 主控中途复位 -> 回 IDLE, 无死锁, 可重跑 ----------------
        // 复位点刻意选在表项之间 (事务已结束、CSB 已释放): 中途打断的是"序列"而不是
        // 单个 SPI 事务 —— 事务中途打断器件的场景由 tb_spi_master_rand 的 F5 覆盖。
        model.reset_stats();
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        while (prog_cnt < 16'd1) @(negedge clk);
        check(spi_csb === 1'b1, "R8 CSB released before reset (between transactions)");
        rst_n = 1'b0;
        repeat (10) @(negedge clk);
        check(busy   === 1'b0, "R8 busy low after reset");
        check(paused === 1'b0, "R8 not paused after reset");
        check(done   === 1'b0, "R8 done low after reset");
        rst_n = 1'b1;
        repeat (5) @(negedge clk);
        model.reset_stats();
        run_once(gd, er);
        check(gd == 1,            "R8 done after recovery");
        check(er == 4'd0,         "R8 error==0 after recovery");
        check(prog_cnt == 16'd11, "R8 prog_cnt==11 after recovery");

        //---------------- R9: 重复上电 (连续两次完整序列, 中间不做任何复位) ----------------
        // 验证幂等与状态残留: 两次各 9 笔事务, 第二次不跳条、不重复、不带着第一次的断点。
        model.reset_stats();
        run_once(gd, er);
        check(gd == 1, "R9 first power-up done");
        check(er == 4'd0, "R9 first power-up error==0");
        run_once(gd, er);
        check(gd == 1,            "R9 second power-up done");
        check(er == 4'd0,         "R9 second power-up error==0");
        check(prog_cnt == 16'd11, "R9 prog_cnt==11 after second power-up");
        check(model.txn_cnt == 18,             "R9 18 transactions in both runs (no residue)");
        check(model.evt_soft_reset_cnt == 2,   "R9 two soft resets (表首各一次)");
        check(model.err_extra_clk_cnt == 0,    "R9 no extra SCLK");

        //---------------- 收尾审计 ----------------
        check(model.err_extra_clk_cnt == 0, "model: no extra SCLK");
        check(model.csb_early_cnt     == 0, "model: no early CSB");
        check(model.wr_ignored_cnt    == 0, "model: no ignored writes");
        check(model.err_timeout_cnt   == 0, "model: no timeout");

        //---------------- 汇总 ----------------
        $display("---- tb_ad9363_cfg summary: checks=%0d failed=%0d",
                 pass_cnt + fail_cnt, fail_cnt);
        model.model_report();
        if (fail_cnt == 0)
            $display("*** AD9363-CFG PASS ***");
        else
            $display("*** AD9363-CFG FAIL (%0d) ***", fail_cnt);
        $finish;
    end

endmodule

`default_nettype wire
