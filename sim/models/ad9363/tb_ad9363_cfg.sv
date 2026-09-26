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
    wire busy;
    wire done;
    wire [3:0]  error;
    wire [9:0]  fault_addr;
    wire [15:0] prog_cnt;

    //------------------------------ cfg <-> spi_master 内部连线 ------------------------------
    wire        c_valid, c_ready, c_rd;
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
        .DEPTH(256), .CLKS_PER_US(50), .CMD_DIV(8'd4), .TIMEOUT_US(24'd100000)
    ) cfg (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done), .error(error),
        .fault_addr(fault_addr), .prog_cnt(prog_cnt),
        .spi_cmd_valid(c_valid), .spi_cmd_ready(c_ready),
        .spi_cmd_rd(c_rd), .spi_cmd_addr(c_addr),
        .spi_cmd_nb_m1(c_nbm1), .spi_cmd_div(c_div),
        .spi_wbuf_valid(w_valid), .spi_wbuf_rdy(w_rdy), .spi_wbuf_data(w_data),
        .spi_rdata(rdata), .spi_rdata_valid(rdata_valid),
        .spi_done(spi_done), .spi_error(spi_error), .spi_busy(spi_busy)
    );

    spi_master #(.TIMEOUT_CLKS(24'd3000)) master (
        .clk(clk), .rst_n(rst_n),
        .cmd_ready(c_ready), .cmd_valid(c_valid), .cmd_rd(c_rd),
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

    //------------------------------ 计分板 ------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check(input bit ok, input [255:0] tag);
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
