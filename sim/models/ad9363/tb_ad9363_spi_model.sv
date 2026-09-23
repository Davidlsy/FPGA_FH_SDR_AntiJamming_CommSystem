`timescale 1ns / 1ps
`default_nettype none
//=====================================================================
// tb_ad9363_spi_model.sv
//---------------------------------------------------------------------
// AD9363 SPI 行为模型测试平台
//
//   - SPI 主机 BFM (模式0: 下降沿驱动/采样延迟 TCO 后的 SDO)
//   - 六项测试:
//       T1 复位后默认值校验 (独立金标准 + 1024 地址全扫描)
//       T2 单字节/多字节读写 + 回读校验 (含地址自增/RO/保留写保护)
//       T3 异常注入 - 超时 (指令阶段/读数据阶段 SCLK 停滞)
//       T4 异常注入 - 错误回读 (注入损坏字节, 验证回读校验捕获)
//       T5 异常注入 - 复位中断 (事务中硬复位 / 事务中软复位 / 常规软复位)
//       T6 随机压力 + 边角 (200 次随机写读校验, 随机长度突发, 地址回绕)
//=====================================================================
module tb_ad9363_spi_model;

    `include "ad9363_defs.vh"

    localparam real TCLK = 100.0;   // SCLK 10 MHz (手册 tCP 最小 20ns, 留裕量)
    localparam real TSC  = 20.0;    // CSB 建立时间 (tSC >= 1ns)
    localparam real THZ  = 20.0;    // CSB 保持时间

    integer errors;
    integer checks;

    //------------------------------ 总线信号 ------------------------------
    reg  sclk_r;
    wire sclk = sclk_r;
    reg  csb;
    reg  gp_resetb;
    reg  sdio_drv, sdio_oe;
    wire sdio = sdio_oe ? sdio_drv : 1'bz;
    wire sdo;

    //------------------------------ DUT ------------------------------
    ad9363_spi_model #(
        .TCO_NS     (5.0),
        .TIMEOUT_NS (1000.0),
        .VERBOSE    (1)
    ) dut (
        .sclk      (sclk),
        .csb       (csb),
        .sdio      (sdio),
        .sdo       (sdo),
        .gp_resetb (gp_resetb)
    );

    //=====================================================================
    // SPI 主机 BFM
    //=====================================================================

    // 完整事务: 16-bit 指令 + (nm1+1) 字节数据, MSB 先行
    // 写: 下降沿驱动 SDIO; 读: 下降沿采样 SDO (器件上升沿后 tCO 已更新)
    task spi_txn(input wr, input [2:0] nm1, input [9:0] addr,
                 input [63:0] wdata, output [63:0] rdata);
        integer i, nbits;
        reg [15:0] instr;
        begin
            rdata = 64'h0;
            nbits = 8 * (nm1 + 1);
            instr = {wr, nm1, 2'b00, addr};
            csb    = 1'b0;
            sdio_oe = 1'b1;
            #(TSC);
            for (i = 15; i >= 0; i = i - 1) begin          // 指令阶段
                sdio_drv = instr[i];
                #(TCLK/2.0); sclk_r = 1'b1;
                #(TCLK/2.0); sclk_r = 1'b0;
            end
            if (wr) begin
                for (i = 0; i < nbits; i = i + 1) begin    // 写数据
                    sdio_drv = wdata[63 - i];
                    #(TCLK/2.0); sclk_r = 1'b1;
                    #(TCLK/2.0); sclk_r = 1'b0;
                end
                sdio_oe = 1'b0;
            end else begin
                sdio_oe = 1'b0;                            // 总线换向 (tHZM)
                for (i = 0; i < nbits; i = i + 1) begin    // 读数据
                    rdata[63 - i] = sdo;
                    #(TCLK/2.0); sclk_r = 1'b1;
                    #(TCLK/2.0); sclk_r = 1'b0;
                end
            end
            #(THZ) csb = 1'b1;
            // 事务间 CSB 高电平间隔: 若升高后在同一时间步内立刻拉低,
            // xsim 不向模型投递 posedge csb, 模型无法离开 ST_DONE
            #(TCLK);
        end
    endtask

    // 超时注入用: 发送 nbits 位指令后冻结 SCLK (CSB 保持低)
    task spi_txn_stall_start(input integer nbits, input wr);
        integer i;
        reg [15:0] instr;
        begin
            instr = {wr, 3'd1, 2'b00, 10'h2AA};
            csb    = 1'b0;
            sdio_oe = 1'b1;
            #(TSC);
            for (i = 15; i > 15 - nbits; i = i - 1) begin
                sdio_drv = instr[i];
                #(TCLK/2.0); sclk_r = 1'b1;
                #(TCLK/2.0); sclk_r = 1'b0;
            end
            // SCLK 停滞, CSB 保持低
        end
    endtask

    task spi_txn_stall_end;
        begin
            csb     = 1'b1;
            sdio_oe = 1'b0;
        end
    endtask

    //=====================================================================
    // 校验辅助
    //=====================================================================
    task chk(input cond, input [255:0] tag);
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("*** FAIL [%0s] (t=%0t)", tag, $time);
            end
        end
    endtask

    task chk8(input [9:0] addr, input [7:0] exp, input [255:0] tag);
        reg [63:0] rd;
        begin
            spi_txn(0, 3'd0, addr, 64'h0, rd);
            if (rd[63:56] !== exp) begin
                errors = errors + 1;
                $display("*** FAIL [%0s] addr=0x%03h read=0x%02h exp=0x%02h",
                         tag, addr, rd[63:56], exp);
            end
            checks = checks + 1;
        end
    endtask

    // 写 + 回读校验
    task wr_verify(input [9:0] addr, input [7:0] data, input [255:0] tag);
        reg [63:0] rd;
        begin
            spi_txn(1, 3'd0, addr, {data, 56'h0}, rd);
            chk8(addr, data, tag);
        end
    endtask

    //=====================================================================
    // T1: 复位后默认值校验
    //=====================================================================
    task t1_defaults;
        reg [63:0] rd;
        integer blk, j;
        reg [7:0] got, exp;
        begin
            $display("\n=== T1: reset & register defaults ===");
            // 独立金标准 (人工核对 UG-672 寄存器表)
            chk8(10'h000, 8'h00, "T1 def 0x000");
            chk8(10'h002, 8'h5F, "T1 def 0x002");
            chk8(10'h003, 8'h5F, "T1 def 0x003");
            chk8(10'h009, 8'h10, "T1 def 0x009");
            chk8(10'h00A, 8'h03, "T1 def 0x00A");
            chk8(10'h010, 8'hC0, "T1 def 0x010");
            chk8(10'h012, 8'h04, "T1 def 0x012");
            chk8(10'h013, 8'h01, "T1 def 0x013");
            chk8(10'h014, 8'h13, "T1 def 0x014");
            chk8(10'h015, 8'h08, "T1 def 0x015");
            chk8(10'h020, 8'h33, "T1 def 0x020");
            chk8(10'h027, 8'h03, "T1 def 0x027");
            chk8(10'h036, 8'hFF, "T1 def 0x036");
            chk8(10'h046, 8'h09, "T1 def 0x046");
            chk8(10'h048, 8'hC5, "T1 def 0x048");
            chk8(10'h049, 8'hB8, "T1 def 0x049");
            chk8(10'h04A, 8'h2E, "T1 def 0x04A");
            chk8(10'h06E, 8'hA9, "T1 def 0x06E");
            chk8(10'h070, 8'hC1, "T1 def 0x070");
            chk8(10'h077, 8'h40, "T1 def 0x077");
            chk8(10'h078, 8'h3C, "T1 def 0x078");
            chk8(10'h0D6, 8'h12, "T1 def 0x0D6");
            chk8(10'h0FA, 8'hE0, "T1 def 0x0FA");
            chk8(10'h110, 8'h02, "T1 def 0x110");
            chk8(10'h111, 8'hCA, "T1 def 0x111");
            // Product ID (0x037): (值 & 0xF8) == 0x08 (no-OS PRODUCT_ID_9361)
            spi_txn(0, 3'd0, `REG_PRODUCT_ID, 64'h0, rd);
            chk((rd[63:56] & `PRODUCT_ID_MASK) === `PRODUCT_ID_9361, "T1 product ID");
            // 全空间扫描: 128 次 8 字节突发读, 与模型默认表 (后门) 比对
            //   每块起始地址 = blk*8 ({blk[6:0],3'b000}), 覆盖 0x000..0x3FF
            for (blk = 0; blk < 128; blk = blk + 1) begin
                spi_txn(0, 3'd7, {blk[6:0], 3'b000}, 64'h0, rd);
                for (j = 0; j < 8; j = j + 1) begin
                    got = rd[63-8*j -: 8];
                    exp = dut.regs_def[blk*8 + j];
                    checks = checks + 1;
                    if (got !== exp) begin
                        errors = errors + 1;
                        $display("*** FAIL [T1 sweep] addr=0x%03h read=0x%02h def=0x%02h",
                                 blk*8+j, got, exp);
                    end
                end
            end
            $display("T1 done (golden + 1024-address sweep)");
        end
    endtask

    //=====================================================================
    // T2: 单字节/多字节读写 + 回读校验
    //=====================================================================
    task t2_wr_rd;
        reg [63:0] rd;
        begin
            $display("\n=== T2: single/multi-byte write-read verify ===");
            // 单字节
            wr_verify(10'h005, 8'hA5, "T2 wr 0x005");
            wr_verify(10'h006, 8'h5A, "T2 wr 0x006");
            // 4 字节突发写 (地址自增 0x028..0x02B)
            spi_txn(1, 3'd3, 10'h028, {8'hDE, 8'hAD, 8'hBE, 8'hEF, 32'h0}, rd);
            chk8(10'h028, 8'hDE, "T2 mb 0x028");
            chk8(10'h029, 8'hAD, "T2 mb 0x029");
            chk8(10'h02A, 8'hBE, "T2 mb 0x02A");
            chk8(10'h02B, 8'hEF, "T2 mb 0x02B");
            // 4 字节突发读 (一次事务读回全部)
            spi_txn(0, 3'd3, 10'h028, 64'h0, rd);
            chk(rd[63:56] === 8'hDE && rd[55:48] === 8'hAD &&
                rd[47:40] === 8'hBE && rd[39:32] === 8'hEF, "T2 mb read 0x028..0x02B");
            // 最大 8 字节突发
            spi_txn(1, 3'd7, 10'h028, {8'h01,8'h02,8'h03,8'h04,8'h05,8'h06,8'h07,8'h88}, rd);
            spi_txn(0, 3'd7, 10'h028, 64'h0, rd);
            chk(rd[63:56] === 8'h01 && rd[55:48] === 8'h02 && rd[47:40] === 8'h03 &&
                rd[39:32] === 8'h04 && rd[31:24] === 8'h05 && rd[23:16] === 8'h06 &&
                rd[15:8]  === 8'h07 && rd[7:0]   === 8'h88, "T2 8-byte burst");
            // 只读寄存器写保护 (0x017 State / 0x00E Temperature)
            spi_txn(1, 3'd0, `REG_STATE, {8'hFF, 56'h0}, rd);
            chk8(`REG_STATE, 8'h00, "T2 RO 0x017 ignored");
            spi_txn(1, 3'd0, `REG_TEMPERATURE, {8'hAA, 56'h0}, rd);
            chk8(`REG_TEMPERATURE, 8'h00, "T2 RO 0x00E ignored");
            chk(dut.wr_ignored_cnt >= 2, "T2 wr_ignored_cnt");
            // 保留地址 (0x008)
            spi_txn(1, 3'd0, 10'h008, {8'h5A, 56'h0}, rd);
            chk8(10'h008, 8'h00, "T2 RSVD 0x008 ignored");
        end
    endtask

    //=====================================================================
    // T3: 异常注入 - SCLK 超时
    //=====================================================================
    task t3_timeout;
        integer base;
        begin
            $display("\n=== T3: fault injection - SCLK timeout ===");
            // (a) 指令阶段停滞 (只发了 10/16 位指令)
            base = dut.err_timeout_cnt;
            spi_txn_stall_start(10, 1);
            #(2500.0);                                 // 停滞 2.5us (> 2xTIMEOUT)
            chk(dut.err_timeout_cnt == base + 1, "T3(a) watchdog fired");
            chk(dut.state == 3'd0, "T3(a) state back to IDLE");
            spi_txn_stall_end;
            #(200.0);
            wr_verify(10'h005, 8'h3C, "T3(a) recovery");
            // (b) 读数据阶段停滞 (16 位指令已发完, 器件已开始驱动 SDO)
            base = dut.err_timeout_cnt;
            spi_txn_stall_start(16, 0);
            #(2500.0);
            chk(dut.err_timeout_cnt == base + 1, "T3(b) watchdog fired");
            chk(sdo === 1'bz, "T3(b) SDO released by watchdog");
            chk(dut.state == 3'd0, "T3(b) state back to IDLE");
            spi_txn_stall_end;
            #(200.0);
            wr_verify(10'h006, 8'hC3, "T3(b) recovery");
        end
    endtask

    //=====================================================================
    // T4: 异常注入 - 错误回读
    //=====================================================================
    task t4_rdback_err;
        reg [63:0] rd;
        integer base;
        begin
            $display("\n=== T4: fault injection - readback corruption ===");
            // 正常写读基线
            wr_verify(10'h005, 8'hC3, "T4 clean wr 0x005");
            // 注入 1 个损坏读字节 (按位取反)
            base = dut.err_rdback_cnt;
            dut.inject_readback_err(8'hFF, 1);
            spi_txn(0, 3'd0, 10'h005, 64'h0, rd);
            chk(rd[63:56] === (8'hC3 ^ 8'hFF), "T4 injected byte corrupted (0xC3->0x3C)");
            chk(dut.err_rdback_cnt == base + 1, "T4 model readback check fired");
            chk8(10'h005, 8'hC3, "T4 clean read after inject");
            // 多字节注入: 4 字节读, 前 2 字节 D7 翻转
            spi_txn(1, 3'd3, 10'h028, {8'h11, 8'h22, 8'h33, 8'h44, 32'h0}, rd);
            base = dut.err_rdback_cnt;
            dut.inject_readback_err(8'h80, 2);
            spi_txn(0, 3'd3, 10'h028, 64'h0, rd);
            chk(rd[63:56] === 8'h91 && rd[55:48] === 8'hA2 &&
                rd[47:40] === 8'h33 && rd[39:32] === 8'h44, "T4 multibyte injection");
            chk(dut.err_rdback_cnt == base + 2, "T4 model readback check x2");
            chk8(10'h028, 8'h11, "T4 clean 0x028");
            chk8(10'h029, 8'h22, "T4 clean 0x029");
        end
    endtask

    //=====================================================================
    // T5: 异常注入 - 复位中断
    //=====================================================================
    task t5_reset_intr;
        reg [63:0] rd;
        integer base;
        begin
            $display("\n=== T5: fault injection - reset interruption ===");
            // (a) 8 字节写进行到第 5 字节时硬复位 (GP_RESETB 脉冲)
            wr_verify(10'h005, 8'h77, "T5(a) precondition 0x005");
            base = dut.evt_hard_reset_cnt;
            fork
                begin : wr_txn
                    spi_txn(1, 3'd7, 10'h028,
                            {8'h11,8'h22,8'h33,8'h44,8'h55,8'h66,8'h77,8'h88}, rd);
                end
                begin : rst_pulse
                    #(5300.0);              // 指令 16bit(1.6us)+3.7 字节左右
                    gp_resetb = 1'b0;
                    #(500.0);
                    gp_resetb = 1'b1;
                end
            join
            #(500.0);
            chk(dut.evt_hard_reset_cnt == base + 1, "T5(a) hard reset event");
            chk8(10'h005, 8'h00, "T5(a) regs restored 0x005");
            chk8(10'h028, 8'h00, "T5(a) aborted write 0x028");
            chk8(10'h02F, 8'h00, "T5(a) aborted write 0x02F");
            wr_verify(10'h005, 8'h55, "T5(a) recovery");
            // (b) 多字节写首字节 0x81 -> 事务中软复位, 其余字节丢弃
            base = dut.evt_soft_reset_cnt;
            wr_verify(10'h005, 8'h99, "T5(b) precondition 0x005");
            spi_txn(1, 3'd7, 10'h000,
                    {8'h81,8'hAA,8'hBB,8'hCC,8'hDD,8'hEE,8'hF0,8'h11}, rd);
            chk(dut.evt_soft_reset_cnt == base + 1, "T5(b) soft reset fired");
            chk8(10'h001, 8'h00, "T5(b) remaining bytes discarded");
            chk8(10'h005, 8'h00, "T5(b) regs restored 0x005");
            wr_verify(10'h005, 8'h66, "T5(b) recovery");
            // (c) 常规软复位 (单字节写 0x81 到 0x000)
            base = dut.evt_soft_reset_cnt;
            wr_verify(10'h005, 8'hE1, "T5(c) precondition 0x005");
            wr_verify(10'h006, 8'hE2, "T5(c) precondition 0x006");
            spi_txn(1, 3'd0, `REG_SPI_CONF, {`SOFT_RESET | `_SOFT_RESET, 56'h0}, rd);
            chk(dut.evt_soft_reset_cnt == base + 1, "T5(c) soft reset fired");
            chk8(10'h005, 8'h00, "T5(c) default restored 0x005");
            chk8(10'h006, 8'h00, "T5(c) default restored 0x006");
            chk8(10'h002, 8'h5F, "T5(c) default restored 0x002");
            chk8(`REG_SPI_CONF, 8'h00, "T5(c) self-cleared");
        end
    endtask

    //=====================================================================
    // T6: 随机压力 + 边角测试
    //=====================================================================
    task t6_stress;
        reg [63:0] rd, wdata;
        integer i, k, len;
        reg [9:0] a;
        reg [7:0] d;
        integer pool [0:15];
        begin
            $display("\n=== T6: random stress + corner cases ===");
            // 已知 RW 地址池
            pool[0]=10'h005;  pool[1]=10'h006;  pool[2]=10'h020;  pool[3]=10'h021;
            pool[4]=10'h022;  pool[5]=10'h026;  pool[6]=10'h027;  pool[7]=10'h028;
            pool[8]=10'h029;  pool[9]=10'h02A;  pool[10]=10'h02B; pool[11]=10'h077;
            pool[12]=10'h078; pool[13]=10'h0D6; pool[14]=10'h0D7; pool[15]=10'h02F;
            // 200 次随机单字节写 + 回读校验
            for (i = 0; i < 200; i = i + 1) begin
                a = pool[$urandom_range(0, 15)];
                d = $urandom;
                wr_verify(a, d, "T6 rand wr/rd");
            end
            // 30 次随机长度 (1..8 字节) 突发写读校验
            for (k = 0; k < 30; k = k + 1) begin
                len = $urandom_range(1, 8);
                wdata = 64'h0;
                for (i = 0; i < len; i = i + 1)
                    wdata[63 - i*8 -: 8] = $urandom;
                spi_txn(1, len - 1, 10'h028, wdata, rd);
                spi_txn(0, len - 1, 10'h028, 64'h0, rd);
                for (i = 0; i < len; i = i + 1)
                    chk(rd[63 - i*8 -: 8] === wdata[63 - i*8 -: 8], "T6 rand burst");
            end
            // 地址回绕: 2 字节写 @0x3FF -> 0x3FF(保留,忽略) + 0x000(回绕)
            spi_txn(1, 3'd1, 10'h3FF, {8'h55, 8'h33, 48'h0}, rd);
            chk8(10'h3FF, 8'h00, "T6 wrap rsvd ignored");
            chk8(10'h000, 8'h33, "T6 wrap into 0x000");
            spi_txn(0, 3'd1, 10'h3FF, 64'h0, rd);
            chk(rd[63:56] === 8'h00 && rd[55:48] === 8'h33, "T6 wrap read @0x3FF");
            // 软复位恢复现场
            spi_txn(1, 3'd0, `REG_SPI_CONF, {8'h81, 56'h0}, rd);
            chk8(10'h000, 8'h00, "T6 cleanup soft reset");
        end
    endtask

    //=====================================================================
    // 主流程
    //=====================================================================
    task summary;
        begin
            $display("\n=================== SUMMARY ===================");
            $display("  checks : %0d", checks);
            $display("  errors : %0d", errors);
            dut.model_report();
            if (errors == 0)
                $display("  RESULT : *** ALL TESTS PASSED ***");
            else
                $display("  RESULT : *** %0d ERRORS ***", errors);
            $display("===============================================");
        end
    endtask

    initial begin : main
        errors = 0;
        checks = 0;
        sclk_r   = 1'b0;
        csb      = 1'b1;
        gp_resetb= 1'b1;
        sdio_drv = 1'b0;
        sdio_oe  = 1'b0;
        $dumpfile("tb_ad9363_spi_model.vcd");
        $dumpvars(0, tb_ad9363_spi_model);

        $display("TB: AD9363 SPI behavioral model testbench, TCLK=%0.0fns", TCLK);
        // 上电硬复位
        #(100.0);
        gp_resetb = 1'b0;
        #(250.0);
        gp_resetb = 1'b1;
        #(100.0);

        t1_defaults;     // T1 复位后默认值校验
        t2_wr_rd;        // T2 读写 + 回读校验
        t3_timeout;      // T3 超时异常注入
        t4_rdback_err;   // T4 错误回读异常注入
        t5_reset_intr;   // T5 复位中断异常注入
        t6_stress;       // T6 随机压力 + 边角

        summary;
        $finish;
    end

endmodule

`default_nettype wire
