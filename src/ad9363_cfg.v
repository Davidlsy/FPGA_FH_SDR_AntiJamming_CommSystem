`timescale 1ns / 1ps
`default_nettype none
//=====================================================================
// ad9363_cfg.v
//---------------------------------------------------------------------
// AD9363 配置状态机 (S3 射频配置模块 - 初始化表执行引擎)
//
// 功能: 从初始化表 ROM 逐条读取并执行配置项, 驱动 spi_master 完成
//   AD9363 上电初始化。所有 SPI 事务均为单字节 (写/读), 天然满足
//   "软复位必须独立单字节写事务"的器件约束。
//
// 初始化表 (32-bit 字, $readmemh 加载 ad9363_init.mem):
//   [31:28] OP  |  [27:18] ADDR[9:0] | [17:16] RSVD | [15:8] DATA | [7:0] 短延时
//   --------------------------------------------------------------------------
//   OP_WRITE = 4'h0 : 写 DATA 到 ADDR, 然后延时 [7:0] us (0 则不等)
//   OP_READV = 4'h1 : 读 ADDR, 与 DATA 比对, 失配 -> 故障(error=2)
//   OP_DELAY = 4'h2 : [27:0] 为延时(us), 纯等待 (PLL 锁定等)
//   OP_END   = 4'hF : 结束 (done=1)
//
// 错误码: 0=OK, 1=SPI 事务错误, 2=回读失配, 3=看门狗超时, 4=非法 OP
//
// 接口约定: start 为 1 拍脉冲; busy 运行期间高; done 完成脉冲;
//   error 为电平 (保持到下一次 start)。
//
// 暂停/恢复: pause 为电平输入, 在【表项边界】生效 —— 当前表项 (含其延时) 跑完
//   后停在 S_PAUSED, pc 指向下一条未执行表项, prog_cnt 保持; pause 撤销后从
//   断点继续, 已执行的表项不重复。两处刻意不暂停: SPI 事务中途 (会打断器件
//   事务语义) 与延时中途 (该延时就是 PLL 建立时间, 冻结它会使延时失去意义)。
//   暂停期间总看门狗冻结, 所以长时间暂停不会误报 error=3。
//
// 时钟域: 单一 clk, 同步复位 rst_n (低有效)。
//   CLKS_PER_US = 每微秒的 clk 数 (50MHz -> 50)。
//=====================================================================
module ad9363_cfg #(
    parameter integer  DEPTH       = 256,         // ROM 深度
    parameter integer  CLKS_PER_US = 50,          // 每 us 的 clk 数
    parameter [7:0]   CMD_DIV     = 8'd4,         // spi_master SCLK 分频
    parameter [23:0]  TIMEOUT_US  = 24'd100000    // 总看门狗 (us)
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,          // 1 拍脉冲触发
    input  wire        pause,          // 电平: 1=请求暂停 (表项边界生效)
    output wire        busy,
    output wire        paused,         // 电平: 1=已停在表项边界
    output reg         done,           // 完成脉冲
    output reg  [3:0]  error,          // 见错误码
    output reg  [9:0]  fault_addr,     // 出错寄存器地址 (调试)
    output reg  [15:0] prog_cnt,       // 已完成的表项数

    // ---- spi_master 命令接口 ----
    output reg         spi_cmd_valid,
    input  wire        spi_cmd_ready,
    output reg         spi_cmd_rd,
    output reg  [9:0]  spi_cmd_addr,
    output wire [2:0]  spi_cmd_nb_m1,  // 固定 0 (单字节)
    output wire [7:0]  spi_cmd_div,    // 固定 CMD_DIV

    output reg         spi_wbuf_valid,
    input  wire        spi_wbuf_rdy,
    output reg  [7:0]  spi_wbuf_data,

    input  wire [7:0]  spi_rdata,
    input  wire        spi_rdata_valid,
    input  wire        spi_done,
    input  wire [3:0]  spi_error,
    input  wire        spi_busy
);

    //------------------------------ 初始化表 ROM ------------------------------
    reg [31:0] rom [0:DEPTH-1];
    initial begin
        $readmemh("ad9363_init.mem", rom);
    end

    //------------------------------ 状态/错误码 ------------------------------
    localparam [3:0] S_IDLE   = 4'd0;
    localparam [3:0] S_EXE    = 4'd1;
    localparam [3:0] S_WRCMD  = 4'd2;
    localparam [3:0] S_WRDATA = 4'd3;
    localparam [3:0] S_WRDONE = 4'd4;
    localparam [3:0] S_DELAY  = 4'd5;
    localparam [3:0] S_RDCMD  = 4'd6;
    localparam [3:0] S_RDDATA = 4'd7;
    localparam [3:0] S_RDDONE = 4'd8;
    localparam [3:0] S_DONE   = 4'd9;
    localparam [3:0] S_FAULT  = 4'd10;
    localparam [3:0] S_PAUSED = 4'd11;

    localparam [3:0] ERR_OK     = 4'd0;
    localparam [3:0] ERR_SPI    = 4'd1;
    localparam [3:0] ERR_RDBACK = 4'd2;
    localparam [3:0] ERR_WDT    = 4'd3;
    localparam [3:0] ERR_BADOP  = 4'd4;

    localparam [3:0] OP_WRITE = 4'h0;
    localparam [3:0] OP_READV = 4'h1;
    localparam [3:0] OP_DELAY = 4'h2;
    localparam [3:0] OP_END   = 4'hF;

    //------------------------------ 寄存器 ------------------------------
    reg [3:0]  state;
    reg [15:0] pc;
    reg [7:0]  wr_data_r;
    reg [9:0]  wr_addr_r;
    reg [7:0]  wr_dly_r;
    reg [9:0]  rd_addr_r;
    reg [7:0]  rd_exp_r;
    reg [7:0]  rd_r;
    reg [27:0] dly_r;
    reg [23:0] wd_us;
    reg [3:0]  fault_code;
    reg        start_d;

    // 当前表项派生字段 (rom[pc] 组合读出)
    wire [31:0] cur     = rom[pc];
    wire [3:0]  curop   = cur[31:28];
    wire [9:0]  curaddr = cur[27:18];
    wire [7:0]  curdata = cur[15:8];

    //------------------------------ us 时基 (自由运行) ------------------------------
    reg [15:0] us_cnt;
    wire us_tick = (us_cnt == CLKS_PER_US - 1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               us_cnt <= 16'd0;
        else if (us_tick)         us_cnt <= 16'd0;
        else                      us_cnt <= us_cnt + 16'd1;
    end

    //------------------------------ start 脉冲检测 ------------------------------
    always @(posedge clk or negedge rst_n)
        if (!rst_n) start_d <= 1'b0; else start_d <= start;
    wire start_pulse = start && !start_d;

    //------------------------------ 主状态机 ------------------------------
    assign busy   = (state != S_IDLE);
    assign paused = (state == S_PAUSED);
    assign spi_cmd_nb_m1 = 3'd0;
    assign spi_cmd_div   = CMD_DIV;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            pc           <= 16'd0;
            wr_data_r    <= 8'd0;
            wr_addr_r    <= 10'd0;
            wr_dly_r     <= 8'd0;
            rd_addr_r    <= 10'd0;
            rd_exp_r     <= 8'd0;
            rd_r         <= 8'd0;
            dly_r        <= 28'd0;
            wd_us        <= 24'd0;
            fault_code   <= 4'd0;
            spi_cmd_valid<= 1'b0;
            spi_cmd_rd   <= 1'b0;
            spi_cmd_addr <= 10'd0;
            spi_wbuf_valid <= 1'b0;
            spi_wbuf_data  <= 8'd0;
            done         <= 1'b0;
            error        <= ERR_OK;
            fault_addr   <= 10'd0;
            prog_cnt     <= 16'd0;
        end else begin
            done <= 1'b0;
            // 握手请求默认撤销, 只在 S_WRCMD/S_RDCMD/S_WRDATA 内显式拉高。
            // 这样看门狗(或任何强制跳转)把状态带走时, 请求不会悬在总线上:
            // 否则 spi_master 会把残留的 valid 当成新命令执行, 产生一笔幽灵事务
            // (R6 异常注入实测到: 故障解除瞬间多发一笔命令并挂死到主控看门狗)。
            spi_cmd_valid  <= 1'b0;
            spi_wbuf_valid <= 1'b0;

            case (state)
                //----------------------------------------
                S_IDLE: begin
                    if (start_pulse) begin
                        pc          <= 16'd0;
                        prog_cnt    <= 16'd0;
                        error       <= ERR_OK;
                        fault_addr  <= 10'd0;
                        wd_us       <= 24'd0;
                        fault_code  <= 4'd0;
                        state       <= S_EXE;
                    end
                end

                //----------------------------------------
                // 解码当前表项并派发
                //----------------------------------------
                S_EXE: begin
                    if (pause) begin
                        state <= S_PAUSED;      // 表项边界暂停, pc/prog_cnt 保持
                    end else case (curop)
                        OP_WRITE: begin
                            wr_addr_r <= curaddr;
                            wr_data_r <= curdata;
                            wr_dly_r  <= cur[7:0];
                            state     <= S_WRCMD;
                        end
                        OP_READV: begin
                            rd_addr_r <= curaddr;
                            rd_exp_r  <= curdata;
                            state     <= S_RDCMD;
                        end
                        OP_DELAY: begin
                            dly_r <= cur[27:0];
                            state <= S_DELAY;
                        end
                        OP_END: begin
                            state <= S_DONE;
                        end
                        default: begin
                            fault_code <= ERR_BADOP;
                            fault_addr <= curaddr;
                            state      <= S_FAULT;
                        end
                    endcase
                end

                //----------------------------------------
                // 暂停: 停在表项边界, 等 pause 撤销后从 pc 续跑
                //----------------------------------------
                S_PAUSED: begin
                    if (!pause) state <= S_EXE;
                end

                //----------------------------------------
                // 写: 命令 -> 数据 -> 完成
                //----------------------------------------
                S_WRCMD: begin
                    spi_cmd_valid <= 1'b1;
                    spi_cmd_rd    <= 1'b0;
                    spi_cmd_addr  <= wr_addr_r;
                    if (spi_cmd_valid && spi_cmd_ready) begin
                        state <= S_WRDATA;
                    end
                end
                S_WRDATA: begin
                    spi_wbuf_valid <= 1'b1;
                    spi_wbuf_data  <= wr_data_r;
                    if (spi_wbuf_valid && spi_wbuf_rdy) begin
                        state <= S_WRDONE;
                    end
                end
                S_WRDONE: begin
                    if (spi_done) begin
                        if (spi_error != 4'd0) begin
                            fault_code <= ERR_SPI;
                            fault_addr <= wr_addr_r;
                            state      <= S_FAULT;
                        end else begin
                            prog_cnt <= pc + 16'd1;
                            if (wr_dly_r != 8'd0) begin
                                dly_r <= {20'd0, wr_dly_r};
                                state <= S_DELAY;
                            end else begin
                                pc    <= pc + 16'd1;
                                state <= S_EXE;
                            end
                        end
                    end
                end

                //----------------------------------------
                // 延时 (us)
                //----------------------------------------
                S_DELAY: begin
                    if (us_tick) begin
                        if (dly_r == 28'd0) begin
                            pc    <= pc + 16'd1;
                            state <= S_EXE;
                        end else begin
                            dly_r <= dly_r - 28'd1;
                        end
                    end
                end

                //----------------------------------------
                // 读回校验: 命令 -> 收数据 -> 比对
                //----------------------------------------
                S_RDCMD: begin
                    spi_cmd_valid <= 1'b1;
                    spi_cmd_rd    <= 1'b1;
                    spi_cmd_addr  <= rd_addr_r;
                    if (spi_cmd_valid && spi_cmd_ready) begin
                        state <= S_RDDATA;
                    end
                end
                S_RDDATA: begin
                    if (spi_rdata_valid) begin
                        rd_r  <= spi_rdata;
                        state <= S_RDDONE;
                    end
                end
                S_RDDONE: begin
                    if (spi_done) begin
                        if (spi_error != 4'd0) begin
                            fault_code <= ERR_SPI;
                            fault_addr <= rd_addr_r;
                            state      <= S_FAULT;
                        end else if (rd_r !== rd_exp_r) begin
                            fault_code <= ERR_RDBACK;
                            fault_addr <= rd_addr_r;
                            state      <= S_FAULT;
                        end else begin
                            prog_cnt <= pc + 16'd1;
                            pc       <= pc + 16'd1;
                            state    <= S_EXE;
                        end
                    end
                end

                //----------------------------------------
                // 完成 / 故障
                //----------------------------------------
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                S_FAULT: begin
                    error <= fault_code;
                    if (!start)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase

            //----------------------------------------
            // 看门狗 (运行期间按 us 累加; 暂停期间冻结)
            //----------------------------------------
            if (state != S_IDLE && state != S_DONE && state != S_FAULT
                && state != S_PAUSED) begin
                if (us_tick) begin
                    if (wd_us >= TIMEOUT_US - 24'd1) begin
                        fault_code <= ERR_WDT;
                        fault_addr <= curaddr;
                        state      <= S_FAULT;
                    end else begin
                        wd_us <= wd_us + 24'd1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
