//============================================================================
// rgmii_if.v
//----------------------------------------------------------------------------
// 模块功能 : GMII <-> RGMII 物理层接口转换 (Xilinx 7-Series IDDR/ODDR 原语)
//
// 在 eth_mac 架构中的位置 :
//   TX : mac_core --(GMII 字节流, gtx_clk 125MHz)--> [rgmii_if/ODDR] --> PHY
//   RX : PHY --(RGMII 4bit DDR)--> [rgmii_if/IDDR] --(GMII 字节流, rgmii_rxc)--> mac_core
//
// 时钟说明 :
//   gtx_clk   : 125MHz 发送时钟, 由 PLL/MMCM 产生, 走全局时钟网络
//   rgmii_rxc : PHY 恢复出的接收时钟 (1000M=125MHz, 100M=25MHz, 10M=2.5MHz)
//   RX 侧输出数据与 rgmii_rxc 同步, 后级由 fifo_cdc 完成跨时钟域
//
// RGMII 关键时序 :
//   1) 数据 : TXC/RXC 上升沿采样 D[3:0] (低半字节), 下降沿采样 D[7:4] (高半字节)
//   2) TX_CTL : 上升沿 = TX_EN, 下降沿 = TX_EN ^ TX_ER  (RGMII v2.0 编码)
//      RX_CTL : 上升沿 = RX_DV, 下降沿 = RX_DV ^ RX_ERR
//   3) 收发数据与时钟间的 2ns 偏移建议由 PHY 内部 delay (RGMII-ID 模式) 实现,
//      或在 Vivado 中对引脚添加 IODELAY 约束, 本模块本身不做延迟补偿
//
// 综合与仿真说明 :
//   - IDDR/ODDR 为 Xilinx 7-Series 原语, Vivado 自带 unisim 可直接仿真;
//     第三方仿真器需先编译 unisim 库
//   - 引脚约束 : IOSTANDARD = LVCMOS25, RGMII 引脚应与 PHY 靠近同一 bank
//   - 本模块兼容 10/100/1000M (RXC 自动降速, 字节流接口不变)
//============================================================================

module rgmii_if (
    // 全局时钟与复位
    input  wire       gtx_clk,        // 125MHz 全局发送时钟
    input  wire       rst_n,          // 异步复位, 低有效

    // GMII 发送端 (来自 mac_core, gtx_clk 时钟域)
    input  wire [7:0] gmii_txd,       // 发送数据字节
    input  wire       gmii_tx_en,     // 发送帧指示
    input  wire       gmii_tx_er,     // 发送错误指示 (通常恒为 0, 保留)

    // GMII 接收端 (送往 mac_core, rgmii_rxc 时钟域)
    output reg  [7:0] gmii_rxd,       // 接收数据字节
    output reg        gmii_rx_dv,     // 接收帧指示
    output reg        gmii_rx_er,     // 接收错误指示

    // RGMII 物理引脚 (与 PHY 直连, DDR)
    output wire       rgmii_txc,      // 发送时钟 (ODDR 正向输出)
    output wire [3:0] rgmii_txd,      // 发送数据
    output wire       rgmii_tx_ctl,   // 发送控制
    input  wire       rgmii_rxc,      // 接收时钟 (来自 PHY)
    input  wire [3:0] rgmii_rxd,      // 接收数据
    input  wire       rgmii_rx_ctl    // 接收控制
);

    wire rst = ~rst_n;                // 内部统一为高有效复位

    //==========================================================================
    // 1. RX 时钟域复位同步 : 异步复位、同步释放
    //    rgmii_rxc 与 gtx_clk 异步, 复位必须先同步到 RX 域再使用
    //==========================================================================
    reg  [2:0] rst_rxc_r;
    wire       rst_rxc;

    always @(posedge rgmii_rxc or negedge rst_n) begin
        if (!rst_n)
            rst_rxc_r <= 3'b111;      // 复位期间保持复位有效
        else
            rst_rxc_r <= {1'b0, rst_rxc_r[2:1]};
    end

    assign rst_rxc = rst_rxc_r[0];

    //==========================================================================
    // 2. TX 方向 : GMII -> 寄存器 -> ODDR -> RGMII
    //    ODDR(SAME_EDGE) : D1 随上升沿送出, D2 随下降沿送出
    //==========================================================================
    reg [7:0] txd_d;
    reg       txen_d;
    reg       txer_d;

    // 先打一拍, 改善到 IOB 的时序路径
    always @(posedge gtx_clk or negedge rst_n) begin
        if (!rst_n) begin
            txd_d  <= 8'd0;
            txen_d <= 1'b0;
            txer_d <= 1'b0;
        end else begin
            txd_d  <= gmii_txd;
            txen_d <= gmii_tx_en;
            txer_d <= gmii_tx_er;
        end
    end

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_tx_data
            ODDR #(
                .DDR_CLK_EDGE ("SAME_EDGE"),
                .INIT         (1'b0),
                .SRTYPE       ("ASYNC")
            ) u_oddr_txd (
                .Q  (rgmii_txd[i]),
                .C  (gtx_clk),
                .CE (1'b1),
                .D1 (txd_d[i]),       // 上升沿 -> 低半字节 D[3:0]
                .D2 (txd_d[i + 4]),   // 下降沿 -> 高半字节 D[7:4]
                .R  (rst),
                .S  (1'b0)
            );
        end
    endgenerate

    // 发送控制 : 上升沿 = TX_EN, 下降沿 = TX_EN ^ TX_ER
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("ASYNC")
    ) u_oddr_txctl (
        .Q  (rgmii_tx_ctl),
        .C  (gtx_clk),
        .CE (1'b1),
        .D1 (txen_d),
        .D2 (txen_d ^ txer_d),        // tx_er 恒 0 时等价于 TX_EN
        .R  (rst),
        .S  (1'b0)
    );

    // 发送时钟 : D1=1/D2=0, 输出 125MHz、50% 占空比的正向时钟
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("ASYNC")
    ) u_oddr_txc (
        .Q  (rgmii_txc),
        .C  (gtx_clk),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (rst),
        .S  (1'b0)
    );

    //==========================================================================
    // 3. RX 方向 : RGMII -> IDDR -> 寄存器 -> GMII
    //    IDDR(SAME_EDGE_PIPELINED) : 上、下沿采样值在同一上升沿对齐输出,
    //    Q1 = 上升沿采样值(低半字节), Q2 = 对应下降沿采样值(高半字节)
    //==========================================================================
    wire [3:0] rxd_q1;                // 上升沿采样 : 低半字节
    wire [3:0] rxd_q2;                // 下降沿采样 : 高半字节
    wire       ctl_q1;                // 上升沿采样 : RX_DV
    wire       ctl_q2;                // 下降沿采样 : RX_DV ^ RX_ERR

    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_rx_data
            IDDR #(
                .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED"),
                .INIT_Q1      (1'b0),
                .INIT_Q2      (1'b0),
                .SRTYPE       ("ASYNC")
            ) u_iddr_rxd (
                .Q1 (rxd_q1[i]),
                .Q2 (rxd_q2[i]),
                .C  (rgmii_rxc),
                .CE (1'b1),
                .D  (rgmii_rxd[i]),
                .R  (rst_rxc),
                .S  (1'b0)
            );
        end
    endgenerate

    IDDR #(
        .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED"),
        .INIT_Q1      (1'b0),
        .INIT_Q2      (1'b0),
        .SRTYPE       ("ASYNC")
    ) u_iddr_rxctl (
        .Q1 (ctl_q1),
        .Q2 (ctl_q2),
        .C  (rgmii_rxc),
        .CE (1'b1),
        .D  (rgmii_rx_ctl),
        .R  (rst_rxc),
        .S  (1'b0)
    );

    // 拼接字节并打一拍输出 (rgmii_rxc 域)
    always @(posedge rgmii_rxc) begin
        if (rst_rxc) begin
            gmii_rxd   <= 8'd0;
            gmii_rx_dv <= 1'b0;
            gmii_rx_er <= 1'b0;
        end else begin
            gmii_rxd   <= {rxd_q2, rxd_q1};   // {高半字节, 低半字节}
            gmii_rx_dv <= ctl_q1;
            gmii_rx_er <= ctl_q1 ^ ctl_q2;    // RGMII v2.0 错误解码
        end
    end

endmodule

//============================================================================
// 例化示例 (eth_mac 顶层) :
//
//   rgmii_if u_rgmii_if (
//       .gtx_clk      (gtx_clk_125m),      // PLL 产生的 125MHz
//       .rst_n        (sys_rst_n),
//       .gmii_txd     (mac_txd),           // 接 mac_core TX
//       .gmii_tx_en   (mac_tx_en),
//       .gmii_tx_er   (1'b0),
//       .gmii_rxd     (mac_rxd),           // 接 mac_core RX (rxc 域)
//       .gmii_rx_dv   (mac_rx_dv),
//       .gmii_rx_er   (mac_rx_er),
//       .rgmii_txc    (phy_txc),
//       .rgmii_txd    (phy_txd),
//       .rgmii_tx_ctl (phy_tx_ctl),
//       .rgmii_rxc    (phy_rxc),
//       .rgmii_rxd    (phy_rxd),
//       .rgmii_rx_ctl (phy_rx_ctl)
//   );
//
// 注意事项 :
//   1. 若 PHY 未开启内部 RX delay (RGMII-ID), 需在 Vivado 中对 rxd/rx_ctl
//      加输入延迟约束 (IBUF IFD_DELAY_VALUE / IODELAY), 使采样点居中
//   2. gmii_rxd/rx_dv/rx_er 属于 rgmii_rxc 域, 后级逻辑跨域请使用 fifo_cdc
//   3. gmii_tx_er 一般不用, 正常收发不影响; 错误帧由 mac_core 的 CRC32 检出
//============================================================================
