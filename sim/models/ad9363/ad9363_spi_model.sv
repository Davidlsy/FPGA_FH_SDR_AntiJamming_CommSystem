`timescale 1ns / 1ps
`default_nettype none
//=====================================================================
// ad9363_spi_model.sv
//---------------------------------------------------------------------
// AD9363 SPI 行为模型 (仿真用 BFM/从端模型)
//
// 功能:
//   1. 寄存器数组: 10-bit 地址空间 x 8-bit, 共 1024 项
//      默认值/访问属性由 ad9363_regs_def.vh 加载 (自动生成自
//      ADI UG-672 寄存器表 + no-OS 驱动 ad9361.c/.h 关键覆盖项)
//   2. 读写状态机: IDLE -> CMD(16bit 指令) -> WR/RD(1..8 字节) -> DONE
//      指令格式: D15=W/R, D14:12=NB(字节数-1), D11:10 保留, D9:0=地址
//      多字节访问地址自增, 10-bit 空间回绕 (0x3FF -> 0x000)
//   3. 回读校验: 模型内置检查器, 读出字节与寄存器堆比对,
//      不一致即计数 err_rdback_cnt (可捕获注入的读错误)
//   4. 异常注入:
//      - 超时      : CSB 有效期间 SCLK 无活动 -> 看门狗中止事务
//      - 错误回读  : inject_readback_err(mask, n) 将后续 n 个读字节
//                    与 mask 异或, 用于验证上层回读校验逻辑
//      - 复位中断  : 软复位 (写 0x81 到 0x000) / 硬复位 (GP_RESETB)
//                    均可在事务进行中打断并恢复默认值
//
// SPI 时序 (依据 AD9363 数据手册 "SPI TIMING"):
//   - SPI 模式 0 (CPOL=0, CPHA=0): SCLK 空闲低
//   - 主机在下降沿更新 SPI_DI(SDIO), 器件在上升沿采样
//   - 器件在上升沿后 tCO (3..8ns) 更新 SPI_DO(SDO), 主机在下降沿采样
//   - 4 线模式: SDIO 仅作输入, 读数据走 SDO (本模型固定 4 线/MSB-first,
//     3-wire/LSB-first 配置位仅存储并给出提示, 不重配置接口引擎)
//=====================================================================
module ad9363_spi_model #(
    parameter real    TCO_NS     = 5.0,     // SDO 输出延迟 (手册 tCO 3..8ns)
    parameter real    TIMEOUT_NS = 1000.0,  // SCLK 无活动超时门限
    parameter integer VERBOSE    = 1
)(
    input  wire sclk,      // SPI 时钟
    input  wire csb,       // 片选, 低有效
    inout  wire sdio,      // SPI_DI: 指令+写数据 (3线模式下读数据, 本模型未用)
    output wire sdo,       // SPI_DO: 4 线模式读数据, 3 线模式高阻
    input  wire gp_resetb   // 硬复位, 低有效
);

    `include "ad9363_defs.vh"

    //------------------------------ 访问属性 ------------------------------
    localparam [1:0] ACC_RSVD = `AD9363_ACC_RSVD;  // 保留: 写忽略, 读 0x00
    localparam [1:0] ACC_RW   = `AD9363_ACC_RW;    // 可读可写
    localparam [1:0] ACC_RO   = `AD9363_ACC_RO;    // 只读: 写忽略

    //------------------------------ 状态机编码 ----------------------------
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_CMD = 3'd1;   // 接收 16-bit 指令
    localparam [2:0] ST_WR  = 3'd2;   // 接收写数据字节
    localparam [2:0] ST_RD  = 3'd3;   // 移出读数据字节
    localparam [2:0] ST_DONE= 3'd4;   // 事务完成, 等待 CSB 拉高

    //------------------------------ 寄存器堆 ------------------------------
    reg [7:0] regs     [0:1023];   // 工作副本
    reg [7:0] regs_def [0:1023];   // 上电/复位默认值
    reg [1:0] acc      [0:1023];   // 访问属性

    //------------------------------ 接口状态 ------------------------------
    reg [2:0]  state;
    reg [15:0] instr;              // 指令移位寄存器
    reg [4:0]  cmd_cnt;            // 指令位计数 0..15
    reg [2:0]  bit_cnt;            // 数据位计数 0..7
    reg [3:0]  byte_cnt;           // 已完成数据字节计数
    reg        wr_flag;            // 1=写, 0=读
    reg [2:0]  nb_m1;              // 字节数-1 (指令 D14:12)
    reg [9:0]  txn_addr;           // 当前事务地址 (自增/回绕)
    reg [7:0]  wr_byte, rd_byte;   // 数据移位寄存器
    reg        byte_injected;      // 当前读字节是否被注入损坏
    reg        txn_aborted;        // 当前事务已被中止
    reg        timeout_fired;      // 看门狗已触发 (CSB 拉高前不重复触发)
    reg        in_reset;           // GP_RESETB 有效期间
    reg        sdo_en, sdo_val, sdo_next;
    assign sdo = sdo_en ? sdo_val : 1'bz;
    real       t_last_act;         // 最近 SPI 活动 (SCLK 沿 / CSB 下降沿)

    //------------------------------ 状态/错误计数器 ------------------------
    integer txn_cnt, wr_txn_cnt, rd_txn_cnt;
    integer err_timeout_cnt;       // SCLK 超时次数
    integer err_rdback_cnt;        // 回读校验失败次数 (读出 != 寄存器堆)
    integer err_extra_clk_cnt;     // IDLE/DONE/中止后收到的多余 SCLK
    integer wr_ignored_cnt;        // 对 RO/保留地址的写 (被忽略)
    integer csb_early_cnt;         // 事务中途 CSB 拉高
    integer evt_soft_reset_cnt;    // 软复位次数
    integer evt_hard_reset_cnt;    // 硬复位次数
    integer rb_inj_left;           // 待注入的读损坏字节数
    integer rb_inj_fired;          // 已注入的读损坏字节数
    reg  [7:0] rb_inj_mask;         // 注入异或掩码

    //=====================================================================
    // 内部任务/函数
    //=====================================================================

    // 恢复全部寄存器为默认值
    task do_reset_regs();
        integer i;
        begin
            for (i = 0; i < 1024; i = i + 1)
                regs[i] = regs_def[i];
        end
    endtask

    // 中止当前事务: 释放总线, 回 IDLE
    task abort_txn(input [255:0] why);
        begin
            sdo_en     = 1'b0;
            state      = ST_IDLE;
            txn_aborted = 1'b1;
            if (VERBOSE)
                $display("[%0t] AD9363-MODEL: transaction ABORTED (%0s)", $time, why);
        end
    endtask

    // 读字节装载 (含错误回读注入)
    function [7:0] fetch_rd_byte(input [9:0] a);
        reg [7:0] v;
        begin
            v = regs[a];
            if (rb_inj_left > 0)
                v = v ^ rb_inj_mask;
            fetch_rd_byte = v;
        end
    endfunction

    // 回读校验: 读出字节与寄存器堆比对 (仅校验 RW 地址)
    task ship_check(input [9:0] a, input [7:0] shipped, input injected);
        begin
            if (acc[a] == ACC_RW && shipped !== regs[a]) begin
                err_rdback_cnt = err_rdback_cnt + 1;
                if (VERBOSE)
                    $display("[%0t] AD9363-MODEL: *** READBACK MISMATCH addr=0x%03h shipped=0x%02h regs=0x%02h%s",
                             $time, a, shipped, regs[a], injected ? " [injected]" : " [UNEXPECTED]");
            end
        end
    endtask

    // 写字节提交 (含访问保护 / 软复位 / 地址自增由调用者处理)
    task commit_byte(input [9:0] a, input [7:0] v);
        begin
            if (a == 10'h000) begin
                // SPI Configuration: D7|D0 同时置位 -> 软复位 (no-OS: SOFT_RESET|_SOFT_RESET)
                if ((v & (`SOFT_RESET | `_SOFT_RESET)) == (`SOFT_RESET | `_SOFT_RESET)) begin
                    evt_soft_reset_cnt = evt_soft_reset_cnt + 1;
                    if (VERBOSE)
                        $display("[%0t] AD9363-MODEL: *** SOFT RESET (reg 0x000 <= 0x%02h)", $time, v);
                    do_reset_regs();
                    regs[10'h000] = 8'h00;   // 复位后自清零
                    abort_txn("soft reset");
                end else begin
                    regs[a] = v;
                    if (v != 8'h00 && VERBOSE)
                        $display("[%0t] AD9363-MODEL: NOTE: SPI config bits stored but NOT reconfigured (model fixed 4-wire/MSB-first), 0x000<=0x%02h",
                                 $time, v);
                end
            end else if (acc[a] == ACC_RW) begin
                regs[a] = v;
            end else begin
                wr_ignored_cnt = wr_ignored_cnt + 1;
                if (VERBOSE)
                    $display("[%0t] AD9363-MODEL: write to non-writable addr 0x%03h (0x%02h) ignored",
                             $time, a, v);
            end
        end
    endtask

    //=====================================================================
    // 异常注入 API (仿真专用, 由 testbench 分层调用)
    //=====================================================================

    // 错误回读注入: 后续 n_bytes 个读字节与 mask 异或
    task inject_readback_err(input [7:0] mask, input integer n_bytes);
        begin
            rb_inj_mask = mask;
            rb_inj_left = n_bytes;
            if (VERBOSE)
                $display("[%0t] AD9363-MODEL: INJECT readback error mask=0x%02h count=%0d",
                         $time, mask, n_bytes);
        end
    endtask

    // 清零全部状态计数器
    task reset_stats();
        begin
            txn_cnt = 0; wr_txn_cnt = 0; rd_txn_cnt = 0;
            err_timeout_cnt = 0; err_rdback_cnt = 0; err_extra_clk_cnt = 0;
            wr_ignored_cnt = 0; csb_early_cnt = 0;
            evt_soft_reset_cnt = 0; evt_hard_reset_cnt = 0;
            rb_inj_fired = 0;
        end
    endtask

    // 后门观察接口
    function [7:0] peek_reg    (input [9:0] a); peek_reg     = regs[a];     endfunction
    function [7:0] peek_reg_def(input [9:0] a); peek_reg_def = regs_def[a]; endfunction
    function [1:0] peek_acc    (input [9:0] a); peek_acc     = acc[a];      endfunction

    // 状态报告
    task model_report();
        begin
            $display("  ---- AD9363 model statistics ----");
            $display("  transactions        : total=%0d (wr=%0d, rd=%0d)", txn_cnt, wr_txn_cnt, rd_txn_cnt);
            $display("  timeout errors      : %0d", err_timeout_cnt);
            $display("  readback mismatches : %0d (injected=%0d)", err_rdback_cnt, rb_inj_fired);
            $display("  ignored writes      : %0d", wr_ignored_cnt);
            $display("  extra SCLK errors   : %0d", err_extra_clk_cnt);
            $display("  early CSB term.     : %0d", csb_early_cnt);
            $display("  soft resets         : %0d", evt_soft_reset_cnt);
            $display("  hard resets         : %0d", evt_hard_reset_cnt);
        end
    endtask

    //=====================================================================
    // SPI 从端核心状态机
    //=====================================================================
    always @(posedge sclk) begin
        if (!csb && !in_reset) begin
            t_last_act = $realtime;
            case (state)
                //----------------------------------------------------
                ST_IDLE, ST_DONE: begin
                    // 中止/完成后仍有时钟 -> 协议违例
                    err_extra_clk_cnt = err_extra_clk_cnt + 1;
                end
                //----------------------------------------------------
                ST_CMD: begin
                    instr = {instr[14:0], sdio};
                    if (cmd_cnt == 5'd15) begin
                        cmd_cnt   = 5'd0;
                        wr_flag   = instr[15];
                        nb_m1     = instr[14:12];
                        txn_addr  = instr[9:0];
                        txn_cnt   = txn_cnt + 1;
                        if (wr_flag) begin
                            wr_txn_cnt = wr_txn_cnt + 1;
                            state   = ST_WR;
                            bit_cnt = 3'd0;
                            byte_cnt = 4'd0;
                        end else begin
                            rd_txn_cnt = rd_txn_cnt + 1;
                            state   = ST_RD;
                            bit_cnt = 3'd0;
                            byte_cnt = 4'd0;
                            rd_byte = fetch_rd_byte(txn_addr);
                            byte_injected = (rb_inj_left > 0);
                            if (byte_injected) begin
                                rb_inj_left = rb_inj_left - 1;
                                rb_inj_fired = rb_inj_fired + 1;
                            end
                            ship_check(txn_addr, rd_byte, byte_injected);
                            sdo_en   = 1'b1;
                            sdo_next = rd_byte[7];
                            #TCO_NS if (sdo_en) sdo_val = sdo_next;
                        end
                    end else begin
                        cmd_cnt = cmd_cnt + 5'd1;
                    end
                end
                //----------------------------------------------------
                ST_WR: begin
                    wr_byte = {wr_byte[6:0], sdio};
                    if (bit_cnt == 3'd7) begin
                        bit_cnt = 3'd0;
                        commit_byte(txn_addr, wr_byte);
                        if (!txn_aborted) begin          // 软复位可能已中止
                            txn_addr = txn_addr + 10'd1;  // 自增, 10-bit 回绕
                            byte_cnt = byte_cnt + 4'd1;
                            if (byte_cnt > {1'b0, nb_m1})
                                state = ST_DONE;
                        end
                    end else begin
                        bit_cnt = bit_cnt + 3'd1;
                    end
                end
                //----------------------------------------------------
                ST_RD: begin
                    if (bit_cnt == 3'd7) begin
                        bit_cnt  = 3'd0;
                        txn_addr = txn_addr + 10'd1;      // 自增, 10-bit 回绕
                        byte_cnt = byte_cnt + 4'd1;
                        if (byte_cnt > {1'b0, nb_m1}) begin
                            state = ST_DONE;
                            #TCO_NS sdo_en = 1'b0;        // 最后一位送出后释放 (tHZS)
                        end else begin
                            rd_byte = fetch_rd_byte(txn_addr);
                            byte_injected = (rb_inj_left > 0);
                            if (byte_injected) begin
                                rb_inj_left = rb_inj_left - 1;
                                rb_inj_fired = rb_inj_fired + 1;
                            end
                            ship_check(txn_addr, rd_byte, byte_injected);
                            sdo_next = rd_byte[7];
                            #TCO_NS if (sdo_en) sdo_val = sdo_next;
                        end
                    end else begin
                        bit_cnt   = bit_cnt + 3'd1;
                        sdo_next  = rd_byte[3'd7 - bit_cnt];
                        #TCO_NS if (sdo_en) sdo_val = sdo_next;
                    end
                end
                default: ;
            endcase
        end
    end

    //=====================================================================
    // CSB 事件: 事务开始/结束
    //=====================================================================
    always @(negedge csb) begin
        if (!in_reset) begin
            state        = ST_CMD;
            cmd_cnt      = 5'd0;
            bit_cnt      = 3'd0;
            byte_cnt     = 4'd0;
            txn_aborted  = 1'b0;
            timeout_fired= 1'b0;
            t_last_act   = $realtime;
        end
    end

    always @(posedge csb) begin
        if (!in_reset) begin
            // 事务未完成即拉高 CSB -> 计数
            if (state == ST_CMD && cmd_cnt != 5'd0)
                csb_early_cnt = csb_early_cnt + 1;
            else if ((state == ST_WR || state == ST_RD) && (byte_cnt <= {1'b0, nb_m1}))
                csb_early_cnt = csb_early_cnt + 1;
            state         = ST_IDLE;
            sdo_en        = 1'b0;
            timeout_fired = 1'b0;
        end
    end

    //=====================================================================
    // 异常注入(超时): SCLK 无活动看门狗
    //   CSB 有效且状态机不在 IDLE/DONE 时, 若 TIMEOUT_NS 内无任何
    //   SCLK 沿, 判定超时, 中止事务并释放总线 (检测分辨率 <= 2xTIMEOUT_NS)
    //=====================================================================
    always begin
        #(TIMEOUT_NS);
        if (!csb && !in_reset && !timeout_fired &&
            state != ST_IDLE && state != ST_DONE) begin
            if (($realtime - t_last_act) >= (TIMEOUT_NS - 1.0)) begin
                err_timeout_cnt = err_timeout_cnt + 1;
                timeout_fired  = 1'b1;
                if (VERBOSE)
                    $display("[%0t] AD9363-MODEL: *** SCLK TIMEOUT (%0.0f ns idle, CSB low) -> abort",
                             $realtime, ($realtime - t_last_act));
                abort_txn("sclk inactivity timeout");
            end
        end
    end

    //=====================================================================
    // 异常注入(复位中断): GP_RESETB 硬复位, 可在事务进行中异步打断
    //=====================================================================
    always @(gp_resetb) begin
        if (gp_resetb === 1'b0) begin
            in_reset = 1'b1;                       // 立即屏蔽 SPI 活动
            evt_hard_reset_cnt = evt_hard_reset_cnt + 1;
            if (VERBOSE)
                $display("[%0t] AD9363-MODEL: *** HARD RESET (GP_RESETB asserted)", $time);
            #1.0;                                  // 复位传播延迟
            do_reset_regs();
            abort_txn("hard reset");
        end else begin
            in_reset   = 1'b0;
            t_last_act = $realtime;
        end
    end

    //=====================================================================
    // 上电初始化: 载入默认值表 + 复位全部状态
    //=====================================================================
    integer i;
    initial begin : power_on
        for (i = 0; i < 1024; i = i + 1) begin
            regs_def[i] = 8'h00;
            acc[i]      = ACC_RSVD;
        end
`include "ad9363_regs_def.vh"
        // 上电状态
        state = ST_IDLE;  sdo_en = 1'b0;  sdo_val = 1'b0;  sdo_next = 1'b0;
        cmd_cnt = 5'd0;  bit_cnt = 3'd0;  byte_cnt = 4'd0;
        instr = 16'h0;   wr_flag = 1'b0;  nb_m1 = 3'd0;    txn_addr = 10'h0;
        wr_byte = 8'h0;  rd_byte = 8'h0;  byte_injected = 1'b0;
        txn_aborted = 1'b0;  timeout_fired = 1'b0;  in_reset = 1'b0;
        t_last_act = 0.0;
        txn_cnt = 0;  wr_txn_cnt = 0;  rd_txn_cnt = 0;
        err_timeout_cnt = 0;  err_rdback_cnt = 0;  err_extra_clk_cnt = 0;
        wr_ignored_cnt = 0;  csb_early_cnt = 0;
        evt_soft_reset_cnt = 0;  evt_hard_reset_cnt = 0;
        rb_inj_left = 0;  rb_inj_fired = 0;  rb_inj_mask = 8'h0;
        do_reset_regs();
        $display("[%0t] AD9363-MODEL: power-on, %0d registers loaded (defaults from UG-672 / no-OS driver)",
                 $time, 438);
    end

endmodule

`default_nettype wire
