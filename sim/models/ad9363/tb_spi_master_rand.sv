`timescale 1ns / 1ps
`default_nettype none
//=====================================================================
// tb_spi_master_rand.sv
//---------------------------------------------------------------------
// S3 D2: spi_master 单体随机验证 + 异常注入
//
// 1. 随机功能向量 (NUM_VECS >= 1000, 默认 1200):
//    - 随机化: 读/写方向, 起始地址(限 RW 区), 突发长度 1..8 字节,
//               SCLK 分频 2..8, 数据内容, 写数据握手延迟 0..10 clk
//    - 对端: ad9363_spi_model (S2 交付, mode 0)
//    - 判据: 写后 peek 比对; 读回与 peek 逐字节比对; 收尾模型计数器全 0
// 2. CPOL/CPHA 包络 (mode 0/1/2/3) vs spi_slave_gen:
//    - SCLK 空闲电平 == CPOL; 边沿数 == 2*(16+8*nb); MOSI 位流逐位比对
// 3. 异常注入 (5 类):
//    F1 无应答超时 : wbuf 停供 -> 主控看门狗 error=1, 总线释放, 可恢复
//    F2 错误回读   : inject_readback_err -> 主控忠实回传被破坏字节
//    F3 中途硬复位 : gp_resetb 中断事务 -> 恢复
//    F4 软复位     : 单字节写 0x000<=0x81 -> 干净中止, 寄存器回默认
//    F5 主控复位   : 事务中 rst_n 拉低 -> 主控回 IDLE, 恢复
//
// 运行: run_spi_master_rand.bat
//=====================================================================
module tb_spi_master_rand;

    localparam integer NUM_VECS = 1200;

    //------------------------------ 时钟/复位 ------------------------------
    reg clk = 1'b0;
    always #10 clk = ~clk;                // 50 MHz
    reg rst_n = 1'b0;
    reg gp_resetb = 1'b1;

    //------------------------------ DUT A: 连 AD9363 模型 (mode 0) ------------------------------
    reg        a_valid = 1'b0, a_rd = 1'b0;
    reg [9:0]  a_addr = 10'd0;
    reg [2:0]  a_nbm1 = 3'd0;
    reg [7:0]  a_div  = 8'd4;
    wire       a_ready;
    reg        a_wvalid = 1'b0;
    reg [7:0]  a_wdata  = 8'd0;
    wire       a_wrdy;
    wire [7:0] a_rdata;
    wire       a_rvalid;
    wire       a_done;
    wire [3:0] a_error;
    wire       a_busy;
    wire a_sclk, a_csb, a_sdo, a_sdo_oe, a_sdi;
    wire sdio;
    assign sdio = a_sdo_oe ? a_sdo : 1'bz;

    spi_master #(.TIMEOUT_CLKS(24'd3000)) dut_a (
        .clk(clk), .rst_n(rst_n),
        .cmd_ready(a_ready), .cmd_valid(a_valid), .cmd_rd(a_rd),
        .cmd_addr(a_addr), .cmd_nb_m1(a_nbm1), .cmd_div(a_div),
        .cmd_cpol(1'b0), .cmd_cpha(1'b0),
        .wbuf_rdy(a_wrdy), .wbuf_valid(a_wvalid), .wbuf_data(a_wdata),
        .rdata(a_rdata), .rdata_valid(a_rvalid),
        .done(a_done), .error(a_error), .busy(a_busy),
        .sdi(a_sdi), .sdo(a_sdo), .sdo_oe(a_sdo_oe),
        .spi_sclk(a_sclk), .spi_csb(a_csb)
    );

    ad9363_spi_model #(.TCO_NS(5.0), .TIMEOUT_NS(1000.0), .VERBOSE(0)) model (
        .sclk(a_sclk), .csb(a_csb), .sdio(sdio), .sdo(a_sdi), .gp_resetb(gp_resetb)
    );

    //------------------------------ DUT B: 连通用从机 (测 CPOL/CPHA) ------------------------------
    reg        b_valid = 1'b0, b_rd = 1'b0;
    reg [9:0]  b_addr = 10'd0;
    reg [2:0]  b_nbm1 = 3'd0;
    reg [7:0]  b_div  = 8'd4;
    reg        b_cpol = 1'b0, b_cpha = 1'b0;
    wire       b_ready;
    reg        b_wvalid = 1'b0;
    reg [7:0]  b_wdata  = 8'd0;
    wire       b_wrdy;
    wire [7:0] b_rdata;
    wire       b_rvalid;
    wire       b_done;
    wire [3:0] b_error;
    wire       b_busy;
    wire b_sclk, b_csb, b_sdo, b_sdo_oe;

    spi_master #(.TIMEOUT_CLKS(24'd3000)) dut_b (
        .clk(clk), .rst_n(rst_n),
        .cmd_ready(b_ready), .cmd_valid(b_valid), .cmd_rd(b_rd),
        .cmd_addr(b_addr), .cmd_nb_m1(b_nbm1), .cmd_div(b_div),
        .cmd_cpol(b_cpol), .cmd_cpha(b_cpha),
        .wbuf_rdy(b_wrdy), .wbuf_valid(b_wvalid), .wbuf_data(b_wdata),
        .rdata(b_rdata), .rdata_valid(b_rvalid),
        .done(b_done), .error(b_error), .busy(b_busy),
        .sdi(1'b0), .sdo(b_sdo), .sdo_oe(b_sdo_oe),
        .spi_sclk(b_sclk), .spi_csb(b_csb)
    );

    // 4 个通用从机, 按被测模式选择
    wire [79:0] g_cap [0:3];
    wire [6:0]  g_capbits [0:3];
    wire [6:0]  g_edges [0:3];
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : gsl
        spi_slave_gen #(.CPOL(g[1]), .CPHA(g[0])) s (
            .sclk(b_sclk), .csb(b_csb), .mosi(b_sdo),
            .captured(g_cap[g]), .cap_bits(g_capbits[g]), .edge_cnt(g_edges[g])
        );
    end endgenerate

    //------------------------------ 计分板 ------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer vec_done = 0;
    integer seed = 20260926;

    function automatic [31:0] rnd(input [31:0] n);
        rnd = $unsigned($random(seed)) % n;
    endfunction

    function automatic [7:0] pick_byte(input [63:0] data, input integer n, input integer idx);
        pick_byte = data >> (8 * (n - 1 - idx));
    endfunction

    task automatic check(input bit ok, input [255:0] tag);
        begin
            if (ok) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("[%0t] [FAIL] %0s", $time, tag);
            end
        end
    endtask

    //------------------------------ A 侧事务辅助 ------------------------------
    task automatic a_cmd(input bit rd, input [9:0] a, input [2:0] nbm1, input [7:0] dv);
        begin
            while (a_busy) @(negedge clk);
            @(negedge clk);
            a_valid = 1'b1; a_rd = rd; a_addr = a; a_nbm1 = nbm1; a_div = dv;
            @(negedge clk);
            a_valid = 1'b0;
        end
    endtask

    task automatic a_feed(input [2:0] nbm1, input [63:0] data, input integer lat);
        integer n, k, j;
        begin
            n = nbm1 + 1;
            for (k = 0; k < n; k = k + 1) begin
                while (!a_wrdy) @(negedge clk);
                for (j = 0; j < lat; j = j + 1) @(negedge clk);
                a_wvalid = 1'b1;
                a_wdata  = pick_byte(data, n, k);
                @(negedge clk);
                while (a_wrdy) @(negedge clk);
                a_wvalid = 1'b0;
            end
        end
    endtask

    task automatic a_collect(input [2:0] nbm1, output [63:0] data);
        integer n, k;
        begin
            data = 64'd0;
            n = nbm1 + 1;
            for (k = 0; k < n; k = k + 1) begin
                while (!a_rvalid) @(negedge clk);
                data = (data << 8) | a_rdata;
                @(negedge clk);
            end
        end
    endtask

    task automatic a_wait_done(input [3:0] exp_err, input [255:0] tag);
        begin
            while (!a_done) @(negedge clk);
            check(a_error === exp_err, {tag, ": error=", 8'(a_error)});
            @(negedge clk);
        end
    endtask

    //------------------------------ B 侧事务辅助 ------------------------------
    task automatic b_cmd(input bit rd, input [9:0] a, input [2:0] nbm1,
                         input [7:0] dv, input bit cp, input bit cpha);
        begin
            while (b_busy) @(negedge clk);
            @(negedge clk);
            b_valid = 1'b1; b_rd = rd; b_addr = a; b_nbm1 = nbm1; b_div = dv;
            b_cpol = cp; b_cpha = cpha;
            @(negedge clk);
            b_valid = 1'b0;
        end
    endtask

    task automatic b_feed(input [2:0] nbm1, input [63:0] data);
        integer n, k;
        begin
            n = nbm1 + 1;
            for (k = 0; k < n; k = k + 1) begin
                while (!b_wrdy) @(negedge clk);
                b_wvalid = 1'b1;
                b_wdata  = pick_byte(data, n, k);
                @(negedge clk);
                while (b_wrdy) @(negedge clk);
                b_wvalid = 1'b0;
            end
        end
    endtask

    task automatic b_wait_done(input [3:0] exp_err, input [255:0] tag);
        begin
            while (!b_done) @(negedge clk);
            check(b_error === exp_err, {tag, ": error=", 8'(b_error)});
            @(negedge clk);
        end
    endtask

    //------------------------------ RW 区段扫描 ------------------------------
    reg [9:0] run_start [0:63];
    reg [4:0] run_len   [0:63];
    integer   run_cnt;

    task automatic scan_rw_runs();
        integer i, cur_start, cur_len;
        begin
            cur_start = -1; cur_len = 0; run_cnt = 0;
            for (i = 1; i < 1024; i = i + 1) begin   // 跳过 0x000 (软复位寄存器)
                if (model.peek_acc(i[9:0]) == 2'd1) begin
                    if (cur_len == 0) cur_start = i;
                    cur_len = cur_len + 1;
                end else begin
                    if (cur_len > 0) begin
                        run_start[run_cnt] = cur_start[9:0];
                        run_len[run_cnt]   = cur_len[4:0];
                        run_cnt = run_cnt + 1;
                        cur_len = 0;
                    end
                end
            end
            if (cur_len > 0) begin
                run_start[run_cnt] = cur_start[9:0];
                run_len[run_cnt]   = cur_len[4:0];
                run_cnt = run_cnt + 1;
            end
            $display("[%0t] RW scan: %0d contiguous runs", $time, run_cnt);
        end
    endtask

    //------------------------------ 测试主体 ------------------------------
    integer t, i, k;
    integer nb;
    reg [9:0]  a;
    reg [63:0] wd, rd, exp;
    reg [15:0] exp_instr;
    integer lat;

    initial begin
        $display("==== tb_spi_master_rand: start (NUM_VECS=%0d) ====", NUM_VECS);
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        #100;
        scan_rw_runs();

        //========================================================
        // 1. 随机功能向量 (mode 0, 对 AD9363 模型)
        //========================================================
        for (t = 0; t < NUM_VECS; t = t + 1) begin
            // 随机方向 / 分频 / 突发长度
            a_rd  = (rnd(2) == 1);
            a_div = 8'd2 + rnd(7);          // 2..8
            nb    = 1 + rnd(8);             // 1..8

            // 随机选一段长度足够的 RW 区, 取随机偏移
            a = 10'h3FF;
            for (k = 0; k < 64; k = k + 1) begin
                i = rnd(run_cnt);
                if (run_len[i] >= nb) begin
                    a = run_start[i] + rnd(run_len[i] - nb + 1);
                    k = 64;
                end
            end

            if (a_rd) begin
                a_cmd(1'b1, a, nb - 1, a_div);
                a_collect(nb - 1, rd);
                a_wait_done(4'd0, "RAND read");
                exp = 64'd0;
                for (i = 0; i < nb; i = i + 1)
                    exp = (exp << 8) | model.peek_reg(a + i[9:0]);
                check(rd === exp, "RAND read data match");
            end else begin
                wd = 64'd0;
                for (i = 0; i < nb; i = i + 1)
                    wd = (wd << 8) | rnd(256);
                lat = rnd(11);              // 握手延迟 0..10 clk
                a_cmd(1'b0, a, nb - 1, a_div);
                a_feed(nb - 1, wd, lat);
                a_wait_done(4'd0, "RAND write");
                for (i = 0; i < nb; i = i + 1)
                    check(model.peek_reg(a + i[9:0]) === pick_byte(wd, nb, i),
                          "RAND write peek");
            end

            vec_done = vec_done + 1;
            if (vec_done % 100 == 0)
                $display("[%0t] ... %0d/%0d vectors", $time, vec_done, NUM_VECS);
        end

        // 随机阶段计数器审计 (必须全 0)
        check(model.err_extra_clk_cnt == 0, "RAND: no extra SCLK");
        check(model.err_rdback_cnt    == 0, "RAND: no readback mismatch");
        check(model.csb_early_cnt     == 0, "RAND: no early CSB");
        check(model.wr_ignored_cnt    == 0, "RAND: no ignored writes");
        check(model.err_timeout_cnt   == 0, "RAND: no timeout");

        //========================================================
        // 2. CPOL/CPHA 包络检查 (mode 0/1/2/3 vs 通用从机)
        //========================================================
        for (i = 0; i < 4; i = i + 1) begin
            // 写: 1 字节, div=4
            wd = 64'hA5;
            b_cmd(1'b0, 10'h014, 3'd0, 8'd4, i[1], i[0]);
            b_feed(3'd0, wd);
            b_wait_done(4'd0, "ENV write");
            exp_instr = {1'b1, 3'd0, 2'b00, 10'h014};   // W + nb-1 + 00 + addr
            check(g_cap[i][23:8] === exp_instr, "ENV instr word");
            check(g_cap[i][7:0]  === 8'hA5,      "ENV write data");
            check(g_capbits[i]   == 7'd24,       "ENV write sample edges");
            check(g_edges[i]     == 7'd48,       "ENV write total edges");
            @(negedge clk);
            check(b_sclk === i[1], "ENV write SCLK idle == CPOL");

            // 读: 1 字节, div=4 (只验指令位流 + 沿结构, MISO 已由 AD9363 全验证)
            // 读事务主控仍打 16+8 个 SCLK 对, 故采样沿 24 / 总沿 48
            b_cmd(1'b1, 10'h037, 3'd0, 8'd4, i[1], i[0]);
            b_wait_done(4'd0, "ENV read");
            exp_instr = {1'b0, 3'd0, 2'b00, 10'h037};   // R + nb-1 + 00 + addr
            check(g_cap[i][23:8] === exp_instr, "ENV read instr word");
            check(g_capbits[i]   == 7'd24,       "ENV read sample edges");
            check(g_edges[i]     == 7'd48,       "ENV read total edges");
            @(negedge clk);
            check(b_sclk === i[1], "ENV read SCLK idle == CPOL");
        end

        //========================================================
        // 3. 异常注入
        //========================================================
        // F1 无应答超时: 写事务不喂数据 -> 主控看门狗
        a_cmd(1'b0, 10'h013, 3'd0, 8'd4);       // 不 feed
        a_wait_done(4'd1, "F1 timeout error==1");
        check(a_csb === 1'b1,  "F1 CSB released");
        check(a_sclk === 1'b0, "F1 SCLK idle");
        check(model.err_timeout_cnt == 1, "F1 model timeout==1 (device watchdog first)");
        model.reset_stats();

        // F2 错误回读: 注入 4 字节损坏, 主控忠实回传
        wd = 64'h12_34_56_78;
        a_cmd(1'b0, 10'h004, 3'd3, 8'd4);
        a_feed(3'd3, wd, 0);
        a_wait_done(4'd0, "F2 write before inject");
        model.inject_readback_err(8'hFF, 4);    // 后续 4 个读字节 XOR 0xFF
        a_cmd(1'b1, 10'h004, 3'd3, 8'd4);
        a_collect(3'd3, rd);
        a_wait_done(4'd0, "F2 corrupted read");
        check(rd === (wd ^ 64'hFFFFFFFF), "F2 master returns corrupted bytes faithfully");
        check(model.rb_inj_fired == 4,        "F2 injected byte count");
        check(model.err_rdback_cnt == 4,      "F2 model flags 4 readback mismatches");
        model.reset_stats();

        // F3 中途硬复位: 突发写中途拉 gp_resetb
        a_cmd(1'b0, 10'h028, 3'd7, 8'd4);       // 8 字节写
        a_feed(3'd7, 64'hDE_AD_BE_EF_5A_A5_3C_C3, 0);  // 但不等它做完, 中途复位
        repeat (4) @(negedge clk);
        gp_resetb = 1'b0;
        repeat (30) @(negedge clk);             // 600ns 硬复位
        gp_resetb = 1'b1;
        check(model.evt_hard_reset_cnt == 1, "F3 hard reset detected");
        // 主控把剩余时钟发完并结束 (写数据已丢失)
        a_wait_done(4'd0, "F3 master finishes write (data lost)");
        model.reset_stats();
        // 恢复: 干净写读
        a_cmd(1'b0, 10'h020, 3'd0, 8'd4);
        a_feed(3'd0, 64'h3C, 0);
        a_wait_done(4'd0, "F3 recovery write");
        check(model.peek_reg(10'h020) === 8'h3C, "F3 recovery write landed");

        // F4 软复位: 单字节写 0x000 <= 0x81 (干净中止, 无多余时钟)
        a_cmd(1'b0, 10'h000, 3'd0, 8'd4);
        a_feed(3'd0, 64'h81, 0);
        a_wait_done(4'd0, "F4 soft reset write");
        check(model.evt_soft_reset_cnt == 1, "F4 soft reset detected");
        check(model.err_extra_clk_cnt  == 0, "F4 no extra SCLK (single-byte soft reset)");
        // 寄存器回到默认: 0x003 (Rx Enable) 默认 0x5F
        check(model.peek_reg(10'h003) === 8'h5F, "F4 regs reset to default");
        model.reset_stats();

        // F5 主控复位: 事务中 rst_n 拉低
        a_cmd(1'b0, 10'h013, 3'd0, 8'd4);
        a_feed(3'd0, 64'h5A, 0);
        repeat (2) @(negedge clk);
        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        check(a_busy === 1'b0, "F5 master back to idle");
        check(a_csb === 1'b1,  "F5 CSB released");
        check(a_sclk === 1'b0, "F5 SCLK idle");
        model.reset_stats();
        // 恢复
        a_cmd(1'b0, 10'h013, 3'd0, 8'd4);
        a_feed(3'd0, 64'hC3, 0);
        a_wait_done(4'd0, "F5 recovery write");
        check(model.peek_reg(10'h013) === 8'hC3, "F5 recovery write landed");

        //========================================================
        // 汇总
        //========================================================
        $display("---- tb_spi_master_rand summary: vecs=%0d checks=%0d failed=%0d",
                 vec_done, pass_cnt + fail_cnt, fail_cnt);
        model.model_report();
        if (fail_cnt == 0)
            $display("*** SPI-MASTER RAND PASS ***");
        else
            $display("*** SPI-MASTER RAND FAIL (%0d) ***", fail_cnt);
        $finish;
    end

endmodule

`default_nettype wire
