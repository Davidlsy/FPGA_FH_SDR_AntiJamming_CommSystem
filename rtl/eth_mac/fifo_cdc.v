//============================================================================
// 模块名 : fifo_cdc
// 功能   : 异步 FIFO 跨时钟域模块 (Asynchronous FIFO / Clock Domain Crossing)
// 场景   : eth_mac 数据通路 —— 125M 以太网时钟域(RGMII) <-> 用户/基带时钟域
//
// 设计要点:
//   1) 读写指针采用格雷码编码(每次只变化一位), 经 2 级触发器同步到对方时钟域,
//      从根本上避免多比特指针跨时钟域产生的亚稳态;
//   2) wfull 在写时钟域本地产生, rempty 在读时钟域本地产生, 判断逻辑不跨域;
//   3) FIFO 深度 = 2**AW, 指针位宽比地址位宽多 1 位, 用于区分满/空;
//   4) 读出为 FWFT(First Word Fall Through): 只要 !rempty, rdata 即为当前队头
//      数据, renc 相当于"弹出"握手, 方便流式数据处理;
//   5) 满时写入/空时读取被硬件自动忽略, 并分别给出 woverflow/runderflow 脉冲;
//   6) 内部含各时钟域独立的复位同步器(异步复位, 同步释放);
//   7) 参数化: DW 数据位宽, AW 地址位宽, AFULL/AEMPTY 水位阈值 (建议 AW >= 4).
//
// 复位约定:
//   上电时 wrst_n 与 rrst_n 需同时保持低电平至少若干个两侧时钟周期.
//============================================================================

module fifo_cdc #(
    // ---------------- 参数 ----------------
    parameter           DW           = 8,                // 数据位宽 (bit)
    parameter           AW           = 10,               // 地址位宽, FIFO 深度 = 2**AW
    parameter [AW:0]    AFULL_LEVEL  = (1<<AW) - 16,     // almost full : 已存数据量阈值
    parameter [AW:0]    AEMPTY_LEVEL = 16                // almost empty: 剩余数据量阈值
)(
    // ---------------- 写时钟域 (例如以太网 125M) ----------------
    input  wire             wclk,          // 写时钟
    input  wire             wrst_n,        // 写域异步复位, 低有效
    input  wire             wenc,          // 写请求 (内部自动受 wfull 保护)
    input  wire [DW-1:0]    wdata,         // 写数据
    output reg              wfull,         // 写满标志 (为1期间写入被忽略)
    output wire             walmost_full,  // 逼近满 (可用作上游提前反压)
    output reg              woverflow,     // 满时仍写入 -> 单周期脉冲

    // ---------------- 读时钟域 (例如用户/基带时钟) ----------------
    input  wire             rclk,          // 读时钟
    input  wire             rrst_n,        // 读域异步复位, 低有效
    input  wire             renc,          // 读请求/弹出 (内部自动受 rempty 保护)
    output wire [DW-1:0]    rdata,         // 读数据 (FWFT, !rempty 时有效)
    output reg              rempty,        // 读空标志 (为1期间读取被忽略)
    output wire             ralmost_empty, // 逼近空
    output reg              runderflow     // 空时仍读取 -> 单周期脉冲
);

    // 指针位宽 = 地址位宽 + 1 (用于区分满/空)
    localparam PTW = AW + 1;

    //========================================================================
    // 1. 复位同步 (异步复位, 同步释放), 每个时钟域独立
    //========================================================================
    reg [1:0] wrst_ff;
    reg [1:0] rrst_ff;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) wrst_ff <= 2'b00;
        else         wrst_ff <= {wrst_ff[0], 1'b1};
    end
    wire wclk_rst_n = wrst_ff[1];

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) rrst_ff <= 2'b00;
        else         rrst_ff <= {rrst_ff[0], 1'b1};
    end
    wire rclk_rst_n = rrst_ff[1];

    //========================================================================
    // 2. 格雷码 <-> 二进制 转换函数
    //========================================================================
    function [PTW-1:0] bin2gray;
        input [PTW-1:0] b;
        begin
            bin2gray = (b >> 1) ^ b;
        end
    endfunction

    function [PTW-1:0] gray2bin;
        input [PTW-1:0] g;
        integer i;
        begin
            gray2bin[PTW-1] = g[PTW-1];
            for (i = PTW-2; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    //========================================================================
    // 3. 指针寄存器与同步器声明
    //========================================================================
    reg  [PTW-1:0] wbin, wgray;         // 写指针 (写域): 二进制 + 格雷码
    reg  [PTW-1:0] rbin, rgray;         // 读指针 (读域): 二进制 + 格雷码

    // 读格雷码指针 -> 写域 2 级同步
    (* ASYNC_REG = "TRUE" *) reg [PTW-1:0] rgray_sync1_w;
    (* ASYNC_REG = "TRUE" *) reg [PTW-1:0] rgray_sync2_w;

    // 写格雷码指针 -> 读域 2 级同步
    (* ASYNC_REG = "TRUE" *) reg [PTW-1:0] wgray_sync1_r;
    (* ASYNC_REG = "TRUE" *) reg [PTW-1:0] wgray_sync2_r;

    wire        wpush = wenc & ~wfull;   // 写域内部保护: 满时丢弃写
    wire        rpop  = renc & ~rempty;  // 读域内部保护: 空时忽略读

    //========================================================================
    // 4. 写指针逻辑 (写时钟域)
    //========================================================================
    wire [PTW-1:0] wbin_next  = wbin + {{AW{1'b0}}, wpush};
    wire [PTW-1:0] wgray_next = bin2gray(wbin_next);

    always @(posedge wclk or negedge wclk_rst_n) begin
        if (!wclk_rst_n) begin
            wbin  <= {PTW{1'b0}};
            wgray <= {PTW{1'b0}};
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
        end
    end

    //========================================================================
    // 5. 读指针逻辑 (读时钟域)
    //========================================================================
    wire [PTW-1:0] rbin_next  = rbin + {{AW{1'b0}}, rpop};
    wire [PTW-1:0] rgray_next = bin2gray(rbin_next);

    always @(posedge rclk or negedge rclk_rst_n) begin
        if (!rclk_rst_n) begin
            rbin  <= {PTW{1'b0}};
            rgray <= {PTW{1'b0}};
        end else begin
            rbin  <= rbin_next;
            rgray <= rgray_next;
        end
    end

    //========================================================================
    // 6. 指针跨时钟域 2 级同步 (格雷码每次仅变 1 位, 同步后最多滞后, 不会出错值)
    //========================================================================
    always @(posedge wclk or negedge wclk_rst_n) begin
        if (!wclk_rst_n) begin
            rgray_sync1_w <= {PTW{1'b0}};
            rgray_sync2_w <= {PTW{1'b0}};
        end else begin
            rgray_sync1_w <= rgray;
            rgray_sync2_w <= rgray_sync1_w;
        end
    end

    always @(posedge rclk or negedge rclk_rst_n) begin
        if (!rclk_rst_n) begin
            wgray_sync1_r <= {PTW{1'b0}};
            wgray_sync2_r <= {PTW{1'b0}};
        end else begin
            wgray_sync1_r <= wgray;
            wgray_sync2_r <= wgray_sync1_r;
        end
    end

    //========================================================================
    // 7. 满/空标志产生 (各在本地时钟域判断)
    //========================================================================
    // 写满: 下一写格雷码指针 == 同步过来的读格雷码指针 (高两位取反)
    wire wfull_next = (wgray_next == {~rgray_sync2_w[PTW-1:PTW-2],
                                       rgray_sync2_w[PTW-3:0]});
    always @(posedge wclk or negedge wclk_rst_n) begin
        if (!wclk_rst_n) wfull <= 1'b0;
        else             wfull <= wfull_next;
    end

    // 读空: 下一读格雷码指针 == 同步过来的写格雷码指针
    wire rempty_next = (rgray_next == wgray_sync2_r);
    always @(posedge rclk or negedge rclk_rst_n) begin
        if (!rclk_rst_n) rempty <= 1'b1;
        else             rempty <= rempty_next;
    end

    //========================================================================
    // 8. almost 预警水位 (用同步过来的"滞后"指针计算, 结果偏保守, 安全)
    //========================================================================
    wire [PTW-1:0] rbin_sync_w = gray2bin(rgray_sync2_w);   // 写域看到的读指针
    wire [PTW-1:0] wbin_sync_r = gray2bin(wgray_sync2_r);   // 读域看到的写指针

    assign walmost_full  = wfull   | ((wbin - rbin_sync_w) >= AFULL_LEVEL);
    assign ralmost_empty = rempty  | ((wbin_sync_r - rbin) <= AEMPTY_LEVEL);

    //========================================================================
    // 9. 存储体: 写域时钟写入, 读域组合读出 (综合推断为分布式 RAM)
    //========================================================================
    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge wclk) begin
        if (wclk_rst_n & wpush)
            mem[wbin[AW-1:0]] <= wdata;
    end

    // 读: FWFT —— 组合输出队头数据, !rempty 即有效
    assign rdata = mem[rbin[AW-1:0]];

    //========================================================================
    // 10. 溢出/下溢告警脉冲 (调试用, 正常设计中应恒为 0)
    //========================================================================
    always @(posedge wclk or negedge wclk_rst_n) begin
        if (!wclk_rst_n) woverflow <= 1'b0;
        else             woverflow <= wenc & wfull;
    end

    always @(posedge rclk or negedge rclk_rst_n) begin
        if (!rclk_rst_n) runderflow <= 1'b0;
        else             runderflow <= renc & rempty;
    end

endmodule


//============================================================================
// 例化模板 (eth_mac 中 125M 以太网域 -> 用户/基带域):
//
//    fifo_cdc #(
//        .DW           (8  ),        // GMII 数据位宽
//        .AW           (10 )         // 深度 1024
//    ) u_fifo_cdc (
//        // 写域: 以太网 125M 时钟
//        .wclk          (gmii_clk      ),
//        .wrst_n        (rst_n_125m    ),
//        .wenc          (eth_wr_en     ),
//        .wdata         (eth_wr_data   ),
//        .wfull         (eth_fifo_full ),
//        .walmost_full  (eth_fifo_afull),
//        .woverflow     (eth_fifo_ovf  ),
//        // 读域: 用户/基带时钟
//        .rclk          (usr_clk       ),
//        .rrst_n        (rst_n_usr     ),
//        .renc          (usr_rd_en     ),
//        .rdata         (usr_rd_data   ),
//        .rempty        (usr_fifo_empty),
//        .ralmost_empty (usr_fifo_aempt),
//        .runderflow    (usr_fifo_udf  )
//    );
//============================================================================
