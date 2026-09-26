`timescale 1ns / 1ps
`default_nettype none
//=====================================================================
// tb_spi_master.sv
//---------------------------------------------------------------------
// S3 冒烟验证: spi_master (RTL) vs ad9363_spi_model (S2 行为模型)
//
// 用例 (全部定向, 逐项后门比对):
//   T1  单字节写  0x013 <= 0xA5            -> peek 比对
//   T2  单字节读  0x013                    -> 读回比对 (走完整 SPI 读路径)
//   T3  4 字节写  0x004..0x007             -> peek 逐字节比对
//   T4  4 字节读  0x004..0x007             -> 读回逐字节比对
//   T5  8 字节写+读 (最大突发) 0x028..0x02F -> 写后读回全比对
//   T6  超时中止: 写事务停在 WWAIT 不喂数据 -> master 看门狗触发 error=1,
//       CSB/SCLK 回安全电平, 器件数据未被破坏 (模型 1us 看门狗先中止, 预期)
//   T7  超时后恢复: 单字节读 0x013          -> 正常读到 0xA5
//
// 收尾: 模型错误计数器审计 (extra_clk/rdback/early_csb/ignored 全 0,
//       timeout=1 为 T6 预期), 事务计数审计, 输出唯一判据行.
//
// 运行: run_spi_master.bat (xvlog/xelab/xsim, Vivado 2021.2)
//=====================================================================
module tb_spi_master;

    localparam [9:0] A_RW1   = 10'h013;   // ENSM Mode (RW)
    localparam [9:0] A_BURST4= 10'h004;   // 0x004..0x007 (RW x4)
    localparam [9:0] A_BURST8= 10'h028;   // 0x028..0x02F (RW x8)

    //------------------------------ 时钟/复位 ------------------------------
    reg clk = 1'b0;
    always #10 clk = ~clk;                // 50 MHz
    reg rst_n = 1'b0;

    //------------------------------ 命令接口 ------------------------------
    reg        cmd_valid = 1'b0;
    reg        cmd_rd    = 1'b0;
    reg [9:0]  cmd_addr  = 10'd0;
    reg [2:0]  cmd_nb_m1 = 3'd0;
    reg [7:0]  cmd_div   = 8'd4;          // SCLK = 50MHz/(2*4) = 6.25 MHz
    wire       cmd_ready;

    //------------------------------ 写数据流 ------------------------------
    wire       wbuf_rdy;
    reg        wbuf_valid = 1'b0;
    reg [7:0]  wbuf_data  = 8'd0;

    //------------------------------ 读数据流 ------------------------------
    wire [7:0] rdata;
    wire       rdata_valid;

    wire       done;
    wire [3:0] error;
    wire       busy;

    //------------------------------ SPI 引脚 ------------------------------
    wire spi_sclk, spi_csb, sdo, sdo_oe;
    wire sdio;                            // 三态总线 -> 模型 SDIO (SPI_DI)
    wire sdo_chip;                        // 模型 SDO (SPI_DO) -> 主机 SDI
    assign sdio = sdo_oe ? sdo : 1'bz;

    //------------------------------ DUT / 模型 ------------------------------
    spi_master #(
        .TIMEOUT_CLKS(24'd1000)           // 1000 clk = 20 us @ 50 MHz
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_ready   (cmd_ready),
        .cmd_valid   (cmd_valid),
        .cmd_rd      (cmd_rd),
        .cmd_addr    (cmd_addr),
        .cmd_nb_m1   (cmd_nb_m1),
        .cmd_div     (cmd_div),
        .cmd_cpol    (1'b0),
        .cmd_cpha    (1'b0),
        .wbuf_rdy    (wbuf_rdy),
        .wbuf_valid  (wbuf_valid),
        .wbuf_data   (wbuf_data),
        .rdata       (rdata),
        .rdata_valid (rdata_valid),
        .done        (done),
        .error       (error),
        .busy        (busy),
        .sdi         (sdo_chip),
        .sdo         (sdo),
        .sdo_oe      (sdo_oe),
        .spi_sclk    (spi_sclk),
        .spi_csb     (spi_csb)
    );

    ad9363_spi_model #(
        .TCO_NS    (5.0),
        .TIMEOUT_NS(1000.0),
        .VERBOSE   (1)
    ) model (
        .sclk     (spi_sclk),
        .csb      (spi_csb),
        .sdio     (sdio),
        .sdo      (sdo_chip),
        .gp_resetb(1'b1)
    );

    //------------------------------ 计分板 ------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer i;

    function automatic [7:0] pick_byte(input [63:0] data, input integer n, input integer idx);
        pick_byte = data >> (8 * (n - 1 - idx));   // idx 字节 = 从 MSB 起第 idx 个
    endfunction

    // 记录一次检查结果
    task automatic check(input bit ok, input [255:0] tag);
        begin
            if (ok) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("[%0t] [FAIL] %0s", $time, tag);
            end
        end
    endtask

    // 下发一次命令 (空闲时才发)
    task automatic issue_cmd(input bit rd, input [9:0] a, input [2:0] nb_m1);
        begin
            while (busy) @(negedge clk);
            @(negedge clk);
            cmd_valid = 1'b1;
            cmd_rd    = rd;
            cmd_addr  = a;
            cmd_nb_m1 = nb_m1;
            cmd_div   = 8'd4;
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    // 写事务: 逐字节喂数据 (byte0 = data 最高字节)
    task automatic feed_bytes(input [2:0] nb_m1, input [63:0] data);
        integer n, k;
        begin
            n = nb_m1 + 1;
            for (k = 0; k < n; k = k + 1) begin
                while (!wbuf_rdy) @(negedge clk);
                wbuf_valid = 1'b1;
                wbuf_data  = pick_byte(data, n, k);
                @(negedge clk);
                while (wbuf_rdy) @(negedge clk);   // 等主控取走
                wbuf_valid = 1'b0;
            end
        end
    endtask

    // 读事务: 收集字节, byte0 装配到最高字节
    task automatic collect_bytes(input [2:0] nb_m1, output [63:0] data);
        integer n, k;
        begin
            data = 64'd0;
            n = nb_m1 + 1;
            for (k = 0; k < n; k = k + 1) begin
                while (!rdata_valid) @(negedge clk);
                data = (data << 8) | rdata;
                @(negedge clk);
            end
        end
    endtask

    // 等完成并校验错误码
    task automatic wait_done(input [3:0] exp_err, input [255:0] tag);
        begin
            while (!done) @(negedge clk);
            check(error === exp_err,
                  {tag, ": error=", 8'(error), " expect=", 8'(exp_err)});
            @(negedge clk);
        end
    endtask

    //------------------------------ 协议间谍 (器件视角还原) ------------------------------
    reg [15:0] spy_instr;
    reg [7:0]  spy_wbyte, spy_rbyte;
    reg [4:0]  spy_bitcnt;
    reg        spy_in_data;
    reg        spy_is_wr;
    reg [3:0]  spy_bytcnt;
    reg [2:0]  spy_nbm1;
    integer    spy_pedges;
    integer    spy_txn;

    always @(negedge spi_csb) begin
        spy_instr   = 16'd0;
        spy_bitcnt  = 5'd0;
        spy_in_data = 1'b0;
        spy_bytcnt  = 4'd0;
        spy_pedges  = 0;
        spy_txn     = spy_txn + 1;
    end

    always @(posedge spi_csb) begin
        $display("[%0t] SPY-TXN[%0d] END: posedges=%0d", $time, spy_txn, spy_pedges);
    end

    always @(posedge spi_sclk) begin
        if (!spi_csb) begin
            spy_pedges = spy_pedges + 1;
            if (!spy_in_data) begin
                spy_instr = {spy_instr[14:0], sdio};
                if (spy_bitcnt == 5'd15) begin
                    spy_is_wr   = spy_instr[15];
                    spy_nbm1    = spy_instr[14:12];
                    spy_in_data = 1'b1;
                    spy_bitcnt  = 5'd0;
                    $display("[%0t] SPY-TXN[%0d] INSTR: 0x%04h %s nb=%0d addr=0x%03h",
                             $time, spy_txn, spy_instr, spy_is_wr ? "WR" : "RD",
                             spy_nbm1 + 3'd1, spy_instr[9:0]);
                end else begin
                    spy_bitcnt = spy_bitcnt + 5'd1;
                end
            end else begin
                if (spy_is_wr) begin
                    spy_wbyte = {spy_wbyte[6:0], sdio};
                end else begin
                    spy_rbyte = {spy_rbyte[6:0], sdo_chip};
                end
                if (spy_bitcnt == 5'd7) begin
                    spy_bitcnt = 5'd0;
                    if (spy_is_wr)
                        $display("[%0t] SPY-TXN[%0d] WR-BYTE[%0d]: 0x%02h", $time, spy_txn, spy_bytcnt, spy_wbyte);
                    else
                        $display("[%0t] SPY-TXN[%0d] RD-BYTE[%0d] chip-drove: 0x%02h", $time, spy_txn, spy_bytcnt, spy_rbyte);
                    spy_bytcnt = spy_bytcnt + 4'd1;
                end else begin
                    spy_bitcnt = spy_bitcnt + 5'd1;
                end
            end
        end
    end

    //------------------------------ 主控内部状态逐拍跟踪 (仅 T1 窗口) ------------------------------
    reg trace_on = 1'b0;
    always @(negedge clk) begin
        if (trace_on)
            $display("[%0t] TRC: st=%0d edge_ph=%0d half=%0d bits=%0d pairs=%0d sclk=%b csb=%b sdo_oe=%b sdo_r=%b sh_out=%04h",
                     $time, dut.state, dut.edge_ph, dut.half_cnt, dut.bits_left, dut.pairs_left,
                     dut.sclk_r, dut.csb_r, dut.sdo_oe_r, dut.sdo_r, dut.sh_out);
    end

    //------------------------------ 测试主体 ------------------------------
    reg [63:0] wr_pat, rd_pat;

    initial begin
        $display("==== tb_spi_master: smoke test start ====");
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        //---------------- T1: 单字节写 ----------------
        trace_on = 1'b1;
        issue_cmd(1'b0, A_RW1, 3'd0);
        feed_bytes(3'd0, 64'hA5);
        wait_done(4'd0, "T1 wr 1B done");
        trace_on = 1'b0;
        check(model.peek_reg(A_RW1) === 8'hA5, "T1 peek 0x013 == 0xA5");

        //---------------- T2: 单字节读 ----------------
        issue_cmd(1'b1, A_RW1, 3'd0);
        collect_bytes(3'd0, rd_pat);
        wait_done(4'd0, "T2 rd 1B done");
        check(rd_pat[7:0] === 8'hA5, "T2 readback 0x013 == 0xA5");

        //---------------- T3: 4 字节突发写 ----------------
        wr_pat = 64'h11_22_33_44_00_00_00_00;
        issue_cmd(1'b0, A_BURST4, 3'd3);
        feed_bytes(3'd3, wr_pat);
        wait_done(4'd0, "T3 wr 4B done");
        for (i = 0; i < 4; i = i + 1)
            check(model.peek_reg(A_BURST4 + i[9:0]) === pick_byte(wr_pat, 4, i),
                  "T3 peek burst4");

        //---------------- T4: 4 字节突发读 ----------------
        issue_cmd(1'b1, A_BURST4, 3'd3);
        collect_bytes(3'd3, rd_pat);
        wait_done(4'd0, "T4 rd 4B done");
        check(rd_pat[31:0] === 32'h11_22_33_44, "T4 readback burst4");

        //---------------- T5: 8 字节最大突发 写+读 ----------------
        wr_pat = 64'hDE_AD_BE_EF_5A_A5_3C_C3;
        issue_cmd(1'b0, A_BURST8, 3'd7);
        feed_bytes(3'd7, wr_pat);
        wait_done(4'd0, "T5 wr 8B done");
        for (i = 0; i < 8; i = i + 1)
            check(model.peek_reg(A_BURST8 + i[9:0]) === pick_byte(wr_pat, 8, i),
                  "T5 peek burst8");

        issue_cmd(1'b1, A_BURST8, 3'd7);
        collect_bytes(3'd7, rd_pat);
        wait_done(4'd0, "T5 rd 8B done");
        check(rd_pat === wr_pat, "T5 readback burst8 (64-bit)");

        //---------------- T6: 看门狗超时中止 ----------------
        // 写事务停在 WWAIT 不喂数据: 模型 1us SCLK 看门狗先中止器件侧,
        // 主控 20us 看门狗随后触发, 释放总线并报 error=1
        issue_cmd(1'b0, A_RW1, 3'd0);          // 故意不 feed
        wait_done(4'd1, "T6 timeout abort error==1");
        check(spi_csb === 1'b1, "T6 CSB released high");
        check(spi_sclk === 1'b0, "T6 SCLK idle low");
        check(model.peek_reg(A_RW1) === 8'hA5, "T6 aborted write did not land");

        //---------------- T7: 超时后恢复 ----------------
        issue_cmd(1'b1, A_RW1, 3'd0);
        collect_bytes(3'd0, rd_pat);
        wait_done(4'd0, "T7 recovery rd done");
        check(rd_pat[7:0] === 8'hA5, "T7 recovery readback == 0xA5");

        //---------------- 模型计数器审计 ----------------
        check(model.err_extra_clk_cnt == 0, "model: no extra SCLK");
        check(model.err_rdback_cnt    == 0, "model: no readback mismatch");
        check(model.csb_early_cnt     == 0, "model: no early CSB");
        check(model.wr_ignored_cnt    == 0, "model: no ignored writes");
        check(model.err_timeout_cnt   == 1, "model: exactly 1 timeout (T6)");
        check(model.txn_cnt           == 8, "model: 8 transactions");
        check(model.wr_txn_cnt        == 4, "model: 4 writes");
        check(model.rd_txn_cnt        == 4, "model: 4 reads");

        //---------------- 汇总 ----------------
        $display("---- tb_spi_master summary: checks=%0d failed=%0d",
                 pass_cnt + fail_cnt, fail_cnt);
        model.model_report();
        if (fail_cnt == 0)
            $display("*** SPI-MASTER SMOKE PASS ***");
        else
            $display("*** SPI-MASTER SMOKE FAIL (%0d) ***", fail_cnt);
        $finish;
    end

endmodule

`default_nettype wire
