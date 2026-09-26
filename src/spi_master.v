`timescale 1ns / 1ps
`default_nettype none
//=====================================================================
// spi_master.v
//---------------------------------------------------------------------
// SPI 主控制器 (S3 射频配置模块 - AD9363 寄存器访问物理层)
//
// 目标器件: AD9363 (SPI 从机), 兼容通用 SPI 从机
//   - 指令字 16-bit, MSB first:
//       D15   = W/R  (1=写, 0=读; 见 UG-672 与 sim/models/ad9363 模型)
//       D14:12= NB   (传输字节数-1, 单事务最多 8 字节)
//       D11:10= 保留 (发 0)
//       D9:0  = 寄存器起始地址 (器件内部按字节自增)
//   - 4 线模式: SDIO = 主机输出(指令+写数据), SDO = 器件输出(读数据)
//     3 线半双工模式不支持 (板级默认 4 线, 寄存器 0x000 保持复位值)
//   - CPOL/CPHA 每事务可配; **仅 mode 0 (CPOL=0,CPHA=0) 按 AD9363
//     时序验证** (器件在指令最后一位的上升沿后 tCO 即输出读数据,
//     主机在其后下降沿采样), mode 1/2/3 为常规时序, 未随本芯片验证
//
// 时序约定 (mode 0, 对齐 sim/models/ad9363/ad9363_spi_model.sv):
//   - SCLK 空闲电平 = CPOL, 边界由半周期节拍产生: eff_div = clk 半周期数
//   - 主机在下降沿(节拍边界)更新 SDIO, 器件在上升沿采样
//   - 读数据: 器件在指令第 16 个上升沿 +tCO 更新 SDO 首位;
//     主机在其后每个下降沿节拍采样 -> 采样点即节拍边界, 无 NBA 竞争
//
// 接口:
//   cmd_*   : 命令握手 (valid/ready), 一次事务 = 1..8 字节读或写
//   wbuf_*  : 写数据流 (仅在写事务中握手, 每字节 ready->valid)
//   rdata*  : 读数据流 (每字节 1 拍 valid 脉冲)
//   done    : 事务完成脉冲 (error=0 成功 / 1 看门狗超时中止)
//
// 使用注意:
//   1. AD9363 SCLK 上限约 25 MHz: clk=125MHz 时 cmd_div>=3; 50MHz 时 >=1(内部钳到 2)
//   2. 写事务字节间 SCLK 停止等 wbuf_valid, 要求上游在 1us 内供数
//      (仿真模型的 SCLK 空闲看门狗门限; 真芯片无此限制)
//   3. 软复位(0x000<=0x81)会使器件立即中止事务, 必须作为独立单字节
//      写事务下发 (D3 配置 FSM 需遵守)
//
// 时钟域: 单一 clk, 同步复位 rst_n (低有效)
//=====================================================================
module spi_master #(
    parameter [23:0] TIMEOUT_CLKS   = 24'd1_048_576, // 事务看门狗 (clk 数)
    parameter [3:0]  CSB_GAP_TICKS  = 4'd2,          // CSB 高电平间隔 (节拍数)
    parameter [3:0]  CS_SETUP_TICKS = 4'd2,          // CSB 下降沿到首沿 (节拍数)
    parameter [3:0]  CS_HOLD_TICKS  = 4'd2           // 末沿到 CSB 上升沿 (节拍数)
)(
    // 时钟/复位
    input  wire        clk,
    input  wire        rst_n,

    // 命令接口: 一次 SPI 事务
    output wire        cmd_ready,
    input  wire        cmd_valid,
    input  wire        cmd_rd,        // 1=读, 0=写
    input  wire [9:0]  cmd_addr,      // 寄存器起始地址 (10-bit)
    input  wire [2:0]  cmd_nb_m1,     // 传输字节数-1 (1..8 字节)
    input  wire [7:0]  cmd_div,       // SCLK 半周期 = max(2, cmd_div) 个 clk
    input  wire        cmd_cpol,
    input  wire        cmd_cpha,

    // 写数据流 (写事务期间按字节握手)
    output wire        wbuf_rdy,
    input  wire        wbuf_valid,
    input  wire [7:0]  wbuf_data,

    // 读数据流 (读事务期间每字节一拍)
    output reg  [7:0]  rdata,
    output reg         rdata_valid,

    // 状态/错误
    output reg         done,          // 完成脉冲, 与 error 同拍有效
    output reg  [3:0]  error,         // 0=OK, 1=看门狗超时中止
    output wire        busy,

    // SPI 引脚 (4 线: 经顶层 IOBUF/sdir 连接)
    input  wire        sdi,           // <- 器件 SDO (MISO)
    output wire        sdo,           // -> 器件 SDIO (MOSI)
    output wire        sdo_oe,        // SDIO 输出使能 (事务期间为 1)
    output wire        spi_sclk,
    output wire        spi_csb        // 低有效
);

    //------------------------------ 状态编码 ------------------------------
    localparam [2:0] S_IDLE  = 3'd0;  // 空闲, 等命令
    localparam [2:0] S_CS    = 3'd1;  // CSB 间隔 + 建立等待
    localparam [2:0] S_BITS  = 3'd2;  // 移位引擎 (指令 + 数据)
    localparam [2:0] S_WWAIT = 3'd3;  // 写事务: 等待下一数据字节
    localparam [2:0] S_HOLD  = 3'd4;  // CSB 保持等待

    localparam [3:0] ERR_NONE    = 4'd0;
    localparam [3:0] ERR_TIMEOUT = 4'd1;

    //------------------------------ 寄存器 ------------------------------
    reg [2:0]  state;
    reg [23:0] wd_cnt;         // 看门狗计数
    reg [7:0]  half_cnt;       // 半周期节拍内 clk 计数
    reg [7:0]  eff_div;        // 生效半周期分频 (>=2)
    reg [3:0]  tick_cnt;       // S_CS/S_HOLD 节拍计数
    reg        edge_ph;        // 0: 下一节拍边界=前沿(SCLK->有效), 1: 后沿
    reg        phase_data;     // 0: 指令段, 1: 数据段
    reg [4:0]  bits_left;      // 当前单元剩余位数: 指令 16 / 数据字节 8 (后沿递减)
    reg [6:0]  pairs_left;     // 数据段剩余 (前,后) 沿对数 = 8*N
    reg [6:0]  rd_bits_left;   // 读方向尚未采样的位数
    reg [2:0]  rd_bit_cnt;     // 字节内采样计数 (0..7)
    reg [15:0] sh_out;         // 移位输出 (MSB 对齐)
    reg [7:0]  sh_in;          // 采样移入
    reg        sample_p;       // 采样预约 (mode0: 前沿置位->后沿采样; mode1 反之)
    reg        rw_r, cpol_r, cpha_r;
    reg        sclk_r, csb_r, sdo_r, sdo_oe_r;

    //------------------------------ 输出连线 ------------------------------
    assign cmd_ready = (state == S_IDLE);
    assign wbuf_rdy  = (state == S_WWAIT);
    assign busy      = (state != S_IDLE);
    assign sdo       = sdo_r;
    assign sdo_oe    = sdo_oe_r;
    assign spi_sclk  = sclk_r;
    assign spi_csb   = csb_r;

    // 指令段与写数据段需要主机驱动 SDIO; 读数据段不需要
    wire mosi_act = (~phase_data) | (~rw_r);

    //=====================================================================
    // 主状态机
    //=====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            wd_cnt       <= 24'd0;
            half_cnt     <= 8'd0;
            eff_div      <= 8'd2;
            tick_cnt     <= 4'd0;
            edge_ph      <= 1'b0;
            phase_data   <= 1'b0;
            bits_left    <= 5'd0;
            pairs_left   <= 7'd0;
            rd_bits_left <= 7'd0;
            rd_bit_cnt   <= 3'd0;
            sh_out       <= 16'd0;
            sh_in        <= 8'd0;
            sample_p     <= 1'b0;
            rw_r         <= 1'b0;
            cpol_r       <= 1'b0;
            cpha_r       <= 1'b0;
            sclk_r       <= 1'b0;
            csb_r        <= 1'b1;
            sdo_r        <= 1'b0;
            sdo_oe_r     <= 1'b0;
            rdata        <= 8'd0;
            rdata_valid  <= 1'b0;
            done         <= 1'b0;
            error        <= 4'd0;
        end else begin
            // 默认单拍脉冲
            done        <= 1'b0;
            rdata_valid <= 1'b0;

            case (state)
                //-----------------------------------------------------
                // 空闲: 接受命令, 锁存参数, 生成指令字
                //-----------------------------------------------------
                S_IDLE: begin
                    if (cmd_valid) begin
                        rw_r         <= cmd_rd;
                        cpol_r       <= cmd_cpol;
                        cpha_r       <= cmd_cpha;
                        eff_div      <= (cmd_div < 8'd2) ? 8'd2 : cmd_div;
                        // 指令字: {W/R, NB-1, 保留 2'b00, 地址}
                        sh_out       <= {~cmd_rd, cmd_nb_m1, 2'b00, cmd_addr};
                        bits_left    <= 5'd16;
                        pairs_left   <= {1'b0, cmd_nb_m1, 3'b000} + 7'd8;   // 8*(NB)
                        rd_bits_left <= {1'b0, cmd_nb_m1, 3'b000} + 7'd8;
                        rd_bit_cnt   <= 3'd0;
                        sh_in        <= 8'd0;
                        sample_p     <= 1'b0;
                        phase_data   <= 1'b0;
                        edge_ph      <= 1'b0;
                        half_cnt     <= 8'd0;
                        tick_cnt     <= 4'd0;
                        sdo_r        <= 1'b0;
                        sclk_r       <= cmd_cpol;   // 空闲电平
                        wd_cnt       <= 24'd0;
                        state        <= S_CS;
                    end
                end

                //-----------------------------------------------------
                // CSB 间隔(高) + 建立时间(低), 然后启动指令移位
                //-----------------------------------------------------
                S_CS: begin
                    if (half_cnt == eff_div - 8'd1) begin
                        half_cnt <= 8'd0;
                        if (tick_cnt == CSB_GAP_TICKS + CS_SETUP_TICKS - 4'd1) begin
                            // 启动移位: mode0/2 在首个前沿前驱动指令 MSB
                            if (!cpha_r) begin
                                sdo_r  <= sh_out[15];
                                sh_out <= {sh_out[14:0], 1'b0};
                            end
                            edge_ph <= 1'b0;
                            state   <= S_BITS;
                        end else begin
                            tick_cnt <= tick_cnt + 4'd1;
                            if (tick_cnt == CSB_GAP_TICKS - 4'd1) begin
                                csb_r    <= 1'b0;   // 间隔结束, 拉低 CSB
                                sdo_oe_r <= 1'b1;   // 开始驱动 SDIO
                            end
                        end
                    end else begin
                        half_cnt <= half_cnt + 8'd1;
                    end
                end

                //-----------------------------------------------------
                // 移位引擎: 每半周期一个节拍边界
                //-----------------------------------------------------
                S_BITS: begin
                    if (half_cnt == eff_div - 8'd1) begin
                        half_cnt <= 8'd0;
                        if (edge_ph == 1'b0) begin
                            //============= 前沿边界: SCLK -> 有效电平 =========
                            sclk_r  <= ~cpol_r;
                            edge_ph <= 1'b1;
                            if (cpha_r) begin
                                // mode1/3: MOSI 在前沿更新
                                if (mosi_act) begin
                                    sdo_r  <= sh_out[15];
                                    sh_out <= {sh_out[14:0], 1'b0};
                                end
                                // mode1/3: 在前沿采样 MISO
                                if (rw_r && sample_p) begin
                                    sh_in        <= {sh_in[6:0], sdi};
                                    sample_p     <= 1'b0;
                                    rd_bits_left <= rd_bits_left - 7'd1;
                                    rd_bit_cnt   <= rd_bit_cnt + 3'd1;
                                    if (rd_bit_cnt == 3'd7) begin
                                        rdata       <= {sh_in[6:0], sdi};
                                        rdata_valid <= 1'b1;
                                    end
                                end
                            end
                            // mode0/2 读采样预约: 含 AD9363 特例 ——
                            // 指令最后一位的前沿同时预约第一个读数据位
                            if (rw_r && !cpha_r
                                && (rd_bits_left != 7'd0)
                                && (phase_data || (bits_left == 5'd1)))
                                sample_p <= 1'b1;
                        end else begin
                            //============= 后沿边界: SCLK -> 空闲电平 =========
                            sclk_r  <= cpol_r;
                            edge_ph <= 1'b0;
                            // 位数递减仅对主机驱动 SDIO 的单元有意义 (指令段/写数据段);
                            // 读数据段由 rd_bits_left/rd_bit_cnt 记账, 避免 bits_left 回绕
                            if (mosi_act)
                                bits_left <= bits_left - 5'd1;

                            // ---- 三个互不排斥的动作: 采样 / 驱动 / 预约 ----
                            // (1) mode0/2 读: 在后沿采样 MISO
                            if (rw_r && !cpha_r) begin
                                if (sample_p) begin
                                    sh_in        <= {sh_in[6:0], sdi};
                                    sample_p     <= 1'b0;
                                    rd_bits_left <= rd_bits_left - 7'd1;
                                    rd_bit_cnt   <= rd_bit_cnt + 3'd1;
                                    if (rd_bit_cnt == 3'd7) begin
                                        rdata       <= {sh_in[6:0], sdi};
                                        rdata_valid <= 1'b1;
                                    end
                                end
                            end
                            // (2) mode0/2 MOSI 驱动: 指令段(含读事务) + 写数据段。
                            //     读指令段同样需要驱动, 之前用 else-if 链导致读事务
                            //     指令只送出首位的错误在此修复
                            if (!cpha_r && mosi_act && (bits_left > 5'd1)) begin
                                sdo_r  <= sh_out[15];
                                sh_out <= {sh_out[14:0], 1'b0};
                            end
                            // (3) mode1/3 读: 预约下一前沿采样
                            if (rw_r && cpha_r && phase_data && (rd_bits_left != 7'd0))
                                sample_p <= 1'b1;

                            //--------- 单元/字节推进 (所有模式) ---------
                            if (!phase_data) begin
                                if (bits_left == 5'd1) begin
                                    // 指令段结束
                                    phase_data <= 1'b1;
                                    bits_left  <= 5'd8;
                                    if (!rw_r)
                                        state <= S_WWAIT;   // 取第一个写数据字节
                                end
                            end else begin
                                pairs_left <= pairs_left - 7'd1;
                                if (pairs_left == 7'd1) begin
                                    // 数据段最后一个 (前,后) 沿对结束
                                    state    <= S_HOLD;
                                    tick_cnt <= 4'd0;
                                end else if (!rw_r && (bits_left == 5'd1)) begin
                                    // 写: 本字节完成, 取下一个
                                    state <= S_WWAIT;
                                end
                            end
                        end
                    end else begin
                        half_cnt <= half_cnt + 8'd1;
                    end
                end

                //-----------------------------------------------------
                // 写事务: 等待上游提供下一数据字节
                //-----------------------------------------------------
                S_WWAIT: begin
                    if (wbuf_valid) begin
                        if (!cpha_r) begin
                            // mode0/2: 入口直接驱动 bit7, 移位寄存器预移一位
                            // (b6 对齐到 [15], 供首个尾沿驱动)
                            sdo_r  <= wbuf_data[7];
                            sh_out <= {wbuf_data[6:0], 9'b0};
                        end else begin
                            // mode1/3: 首沿驱动
                            sh_out <= {8'h00, wbuf_data};
                        end
                        bits_left <= 5'd8;
                        edge_ph   <= 1'b0;
                        half_cnt  <= 8'd0;
                        state     <= S_BITS;
                    end
                end

                //-----------------------------------------------------
                // CSB 保持, 然后结束事务
                //-----------------------------------------------------
                S_HOLD: begin
                    if (half_cnt == eff_div - 8'd1) begin
                        half_cnt <= 8'd0;
                        if (tick_cnt == CS_HOLD_TICKS - 4'd1) begin
                            csb_r    <= 1'b1;
                            sdo_oe_r <= 1'b0;
                            done     <= 1'b1;
                            error    <= ERR_NONE;
                            state    <= S_IDLE;
                        end else begin
                            tick_cnt <= tick_cnt + 4'd1;
                        end
                    end else begin
                        half_cnt <= half_cnt + 8'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase

            //-----------------------------------------------------
            // 看门狗: 任何非空闲事务超时 -> 强制中止 (覆盖以上分支)
            //-----------------------------------------------------
            if (state != S_IDLE) begin
                if (wd_cnt >= TIMEOUT_CLKS - 24'd1) begin
                    state        <= S_IDLE;
                    csb_r        <= 1'b1;
                    sclk_r       <= cpol_r;
                    sdo_oe_r     <= 1'b0;
                    sample_p     <= 1'b0;
                    done         <= 1'b1;
                    error        <= ERR_TIMEOUT;
                    wd_cnt       <= 24'd0;
                end else begin
                    wd_cnt <= wd_cnt + 24'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
