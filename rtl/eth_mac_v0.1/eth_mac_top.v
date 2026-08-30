`timescale 1ns / 1ps
//============================================================================
// eth_mac_top.v : 以太网子系统顶层
//----------------------------------------------------------------------------
// 模块连接 (自 PHY 至用户应用) :
//
//   PHY <---> rgmii_if <---> mac_core <---> eth_proto <---+----------+ <---> 用户应用
//   (RGMII)   GMII<->RGMII  前导码/CRC    ARP/ICMP/UDP     | fifo_cdc |     (usr_clk 域)
//                                                          |  x2+适配  |
//   PHY <--- mdio_ctrl <--- PHY配置FSM (50M 域)             +----------+
//
// 时钟方案 :
//   eth_clk = rgmii_rxc 经 BUFG (1000M 链路下为 125MHz 恢复时钟)
//   整个 MAC 协议栈 (rgmii_if 发送侧 / mac_core / eth_proto / 两个 fifo_cdc
//   的以太网侧端口) 统一运行于 eth_clk 单时钟域 :
//     - mac_core 的 gtx_clk 与 rx_clk 接同一时钟, TXC 由 rxc 经 ODDR 正向
//       输出给 PHY, 收发天然同源, MAC 栈内零跨时钟域
//     - 唯一的跨时钟域由两个 fifo_cdc 完成 (eth_clk <-> usr_clk)
//   注意 : 本设计仅支持 1000M 全双工 (TXC 频率恒等于 rxc, 100/10M 模式下
//   字节速率会加倍), 故 PHY 配置状态机只通告 1000M, 不成交则不建链
//   若坚持用本地 PLL 125M 作 gtx_clk, 须在 mac_core RX 输出后补一级跨时钟
//   域 FIFO 并把 eth_clk 换成 PLL 输出 (本顶层不采用)
//
// 对 eth_proto.tx_ready 的语义适配 (重要) :
//   eth_proto 期望 tx_ready 为 "逐字节可接收" (其帧内字节计数以
//   tx_valid && tx_ready 推进), 而 mac_core 的 tx_ready 是 "帧槽位空闲"
//   (仅 IDLE 为 1, 帧内恒 0), 二者直连会死锁 (帧内 tx_cnt 冻结, mac_core
//   永远等不到 eop); 且 eth_proto 发起新帧不检查 tx_ready, 若 mac_core
//   尚在 CRC/IFG 尾部会丢失首字节
//   本顶层用 frame_active 跟踪 MAC 面字节流, 合成逐字节 ready :
//     - mac IDLE 拍接收 sop 字节时置位, 接收帧尾 eop 字节时清零
//     - ep_tx_ready = mac_tx_ready | frame_active
//   效果 : 帧内逐字节接收; 帧尾 IFG 期间自动冻结 eth_proto 帧计数, 直到
//   mac_core 回到 IDLE 才放行下一帧 (同时修复上述丢首字节问题)
//
// 用户应用接口 (usr_clk 域, 两个 fifo_cdc + 收发适配) :
//   TX (用户 -> 网络) : 逐字节写入, 报文格式 (大端) :
//       [0]   目的 UDP 端口高字节   例 : 端口 69 = 0x0045 -> 先写 0x00 后写 0x45
//       [1]   目的 UDP 端口低字节
//       [2]   载荷长度高字节 (len >= 1, 建议 <= 1472)
//       [3]   载荷长度低字节 (必须与随后实际写入的载荷字节数一致)
//       [4..] 载荷 len 字节 (wfull=1 拍的写入被丢弃, 勿在报文中途长时间停写)
//       报文固定发往 PEER_IP; 对端 MAC 未学习时自动先发 ARP 请求, 每 ~110ms
//       重探一次, 学到 MAC 后报文自动发出
//   RX (网络 -> 用户) : FWFT 读出 (usr_rx_valid = !empty, renc 弹出当前字) :
//       sop 字 : usr_rx_sop=1, usr_rx_port=对端源端口(16位), data=载荷首字节
//       中间字 : 载荷字节
//       末字   : usr_rx_eop=1
//       即每个 UDP 报文首字带出源端口, 末字带 eop; 无 eop 的残包(溢出所致)
//       上层应丢弃
//
// 使用约束 :
//   1. PHY 须为 RGMII 接口且使能 RGMII-ID (PHY 内部收发延迟), 或对
//      rgmii_rxd/rx_ctl 加输入延迟约束; PHY_ADDR 按硬件 strap 修改
//   2. usr_clk 域需保证 RX FIFO 排空速率; 持续千兆大流量请加大 RX_FIFO_AW
//   3. TX 报文 len 必须与实际写入字节数一致, 否则发送侧停等, 超时(约20ms)
//      后按已收字节强制补零发完, 并清空 FIFO 内残留字节 (该报文作废)
//   4. MAC 栈未使用 rx_crc_ok (eth_proto 无此输入), 畸形帧依赖 IP 头校验
//      和 ARP/ICMP 字段检查过滤
//   5. 收到针对本机 IP 的 ARP 请求自动应答; ping 自动回显应答
//============================================================================
module eth_mac_top #(
    //--------------------------- 参数配置 ----------------------------------
    parameter [47:0] LOCAL_MAC      = 48'h11_22_33_44_55_66, // 本机 MAC
    parameter [31:0] LOCAL_IP       = 32'hC0_A8_01_64,       // 本机 IP: 192.168.1.100
    parameter [31:0] PEER_IP        = 32'hC0_A8_01_01,       // 对端 IP: 192.168.1.1(PC)
    parameter [15:0] LOCAL_UDP_PORT = 16'd5000,              // 本机 UDP 源端口
    parameter [4:0]  PHY_ADDR       = 5'd1,                  // PHY 地址(按硬件 strap)
    parameter        ICMP_BUF_AW    = 10,                    // eth_proto ICMP RAM 位宽
    parameter        RX_FIFO_AW     = 10,                    // RX FIFO 深度 2^AW
    parameter        TX_FIFO_AW     = 10                     // TX FIFO 深度 2^AW
)(
    //----------------------- 系统时钟与复位 --------------------------------
    input  wire        sys_clk,       // 50MHz 板载时钟 (MDIO 用)
    input  wire        sys_rst_n,     // 板载复位, 低有效(异步)
    output wire        phy_rst_n,     // PHY 复位(上电展宽 ~84ms 后释放)
    output wire        phy_mdc,       // PHY MDIO 时钟 2.5MHz
    inout  wire        phy_mdio,      // PHY MDIO 数据(需上拉)

    //----------------------- RGMII 物理引脚 --------------------------------
    output wire        rgmii_txc,     // 发送时钟 (= eth_clk 经 ODDR 输出)
    output wire [3:0]  rgmii_txd,     // 发送数据
    output wire        rgmii_tx_ctl,  // 发送控制
    input  wire        rgmii_rxc,     // 接收时钟 (来自 PHY, 兼作 eth_clk)
    input  wire [3:0]  rgmii_rxd,     // 接收数据
    input  wire        rgmii_rx_ctl,  // 接收控制

    //----------------------- 用户应用时钟域 --------------------------------
    input  wire        usr_clk,       // 用户/基带时钟
    input  wire        usr_rst_n,     // 用户域复位(低有效, 需与 usr_clk 同步)
    output wire        usr_link_up,   // 链路建立指示(usr 域)
    output wire        usr_peer_mac_valid, // 已学到对端 MAC(usr 域)
    output wire        usr_tx_ovf,    // TX FIFO 满时仍写入(usr 域脉冲)
    output wire        usr_rx_ovf,    // RX FIFO 满丢包指示(usr 域, 仅供调试)

    //--- TX : 用户 -> 网络 (报文格式见文件头) ---
    input  wire        usr_tx_wenc,   // 写入请求(!usr_tx_full 时被接收)
    input  wire [7:0]  usr_tx_wdata,  // 写入字节
    output wire        usr_tx_full,   // 写满(为 1 期间写入被忽略)
    output wire        usr_tx_afull,  // 逼近满(水线以上建议不开新报文)

    //--- RX : 网络 -> 用户 (FWFT, 报文格式见文件头) ---
    input  wire        usr_rx_renc,   // 弹出请求(弹出 usr_rx_data 当前字)
    output wire [7:0]  usr_rx_data,   // 数据字节
    output wire [15:0] usr_rx_port,   // 对端源端口(仅 sop 字拍有效)
    output wire        usr_rx_sop,    // 报文首字
    output wire        usr_rx_eop,    // 报文末字
    output wire        usr_rx_valid,  // = !empty, 当前字可读
    output wire        usr_rx_empty,  // 空

    //----------------------- 状态指示 LED ----------------------------------
    output wire        led_link,      // 链路建立(高有效)
    output wire        led_peer       // 已学到对端 MAC(高有效)
);

    //======================================================================
    // 0. 时钟 : 50M 板载时钟与 rgmii_rxc 各自上 BUFG
    //    eth_clk 兼作 mac_core 的 gtx_clk/rx_clk 与 eth_proto 的 clk
    //======================================================================
    wire clk_50m;
    wire eth_clk;

    BUFG u_bufg_50m (.I(sys_clk),   .O(clk_50m));
    BUFG u_bufg_eth (.I(rgmii_rxc), .O(eth_clk));

    //======================================================================
    // 1. PHY 复位展宽 : 上电/复位后保持 PHY 在复位 ~84ms 再释放
    //======================================================================
    reg  [21:0] por_cnt;
    reg         phy_rst_n_r;

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            por_cnt     <= 22'd0;
            phy_rst_n_r <= 1'b0;
        end else if (!phy_rst_n_r) begin
            if (&por_cnt)
                phy_rst_n_r <= 1'b1;             // 2^22 / 50MHz = 83.9ms
            else
                por_cnt <= por_cnt + 22'd1;
        end
    end

    assign phy_rst_n = phy_rst_n_r;

    //======================================================================
    // 2. PHY 配置状态机 (50M 域, 驱动 mdio_ctrl) :
    //    等 PHY 复位释放 -> 软复位 -> 等 -> 只通告 1000M-FD -> 重启自协商
    //    -> 双读 BMSR 判链路 (寄存器1 bit2 为锁存低, 需连读两次)
    //    建链后周期复查以刷新链路指示
    //======================================================================
    localparam [3:0] M_RSTWAIT = 4'd0,   // 等 phy_rst_n 释放 + 建立延时
                     M_W_SWRST = 4'd1,   // 发起: 写 reg0=0x8000 软复位
                     M_D_SWRST = 4'd2,   // 等待 done
                     M_RSTDELAY= 4'd3,   // 等 PHY 内部复位完成
                     M_W_ADV1  = 4'd4,   // 发起: 写 reg9=0x0200 (仅 1000M-FD)
                     M_D_ADV1  = 4'd5,
                     M_W_ADV2  = 4'd6,   // 发起: 写 reg4=0x0021 (关 10/100 通告)
                     M_D_ADV2  = 4'd7,
                     M_W_ANEG  = 4'd8,   // 发起: 写 reg0=0x1200 (使能+重启自协商)
                     M_D_ANEG  = 4'd9,
                     M_POLL    = 4'd10,  // 轮询间隔
                     M_W_LNK1  = 4'd11,  // 发起: 读 reg1 (第 1 次)
                     M_D_LNK1  = 4'd12,
                     M_W_LNK2  = 4'd13,  // 发起: 读 reg1 (第 2 次)
                     M_D_LNK2  = 4'd14,  // 两次 bit2 均 1 -> 链路建立
                     M_LINKED  = 4'd15;  // 已建链, 周期复查

    localparam [23:0] PHY_RST_DLY = 24'd2_100_000;   // ~42ms  (复位释放后建立)
    localparam [23:0] SWRST_DLY   = 24'd8_400_000;   // ~168ms (软复位完成等待)
    localparam [23:0] POLL_DLY    = 24'd4_200_000;   // ~84ms  (链路轮询周期)

    reg  [3:0]  m_st;
    reg  [23:0] m_cnt;
    reg         m_start, m_op, m_link;
    reg  [4:0]  m_ra;
    reg  [15:0] m_wd, m_rd1;
    wire        m_busy, m_done;
    wire [15:0] m_rdata;

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            m_st    <= M_RSTWAIT;
            m_cnt   <= 24'd0;
            m_start <= 1'b0;
            m_op    <= 1'b0;
            m_ra    <= 5'd0;
            m_wd    <= 16'd0;
            m_rd1   <= 16'd0;
            m_link  <= 1'b0;
        end else begin
            m_start <= 1'b0;                     // start 为单拍脉冲
            case (m_st)
                //----------------------------------------------------------
                M_RSTWAIT:
                    if (phy_rst_n_r) begin
                        if (m_cnt == PHY_RST_DLY) begin
                            m_cnt <= 24'd0;
                            m_st  <= M_W_SWRST;
                        end else
                            m_cnt <= m_cnt + 24'd1;
                    end
                //----------------------------------------------------------
                // 各写步骤 : 等待 mdio 空闲 -> 单拍 start -> 等 done
                M_W_SWRST: if (!m_busy) begin
                    m_op <= 1'b0; m_ra <= 5'd0; m_wd <= 16'h8000;
                    m_start <= 1'b1; m_st <= M_D_SWRST;
                end
                M_D_SWRST: if (m_done) begin
                    m_cnt <= 24'd0; m_st <= M_RSTDELAY;
                end
                M_RSTDELAY:
                    if (m_cnt == SWRST_DLY) begin
                        m_cnt <= 24'd0; m_st <= M_W_ADV1;
                    end else
                        m_cnt <= m_cnt + 24'd1;
                //----------------------------------------------------------
                // 自协商通告 : 只保留 1000M-FD, 10/100M 一律不通告
                // (本 MAC 栈仅支持千兆, 见文件头时钟方案说明)
                M_W_ADV1: if (!m_busy) begin
                    m_op <= 1'b0; m_ra <= 5'd9; m_wd <= 16'h0200;
                    m_start <= 1'b1; m_st <= M_D_ADV1;
                end
                M_D_ADV1: if (m_done) m_st <= M_W_ADV2;
                M_W_ADV2: if (!m_busy) begin
                    m_op <= 1'b0; m_ra <= 5'd4; m_wd <= 16'h0021;
                    m_start <= 1'b1; m_st <= M_D_ADV2;
                end
                M_D_ADV2: if (m_done) m_st <= M_W_ANEG;
                M_W_ANEG: if (!m_busy) begin
                    m_op <= 1'b0; m_ra <= 5'd0; m_wd <= 16'h1200;
                    m_start <= 1'b1; m_st <= M_D_ANEG;
                end
                M_D_ANEG: if (m_done) begin
                    m_cnt <= 24'd0; m_st <= M_POLL;
                end
                //----------------------------------------------------------
                // 链路轮询 : 间隔 ~84ms, 连读两次 BMSR
                M_POLL:
                    if (m_cnt == POLL_DLY) begin
                        m_cnt <= 24'd0; m_st <= M_W_LNK1;
                    end else
                        m_cnt <= m_cnt + 24'd1;
                M_W_LNK1: if (!m_busy) begin
                    m_op <= 1'b1; m_ra <= 5'd1; m_wd <= 16'd0;
                    m_start <= 1'b1; m_st <= M_D_LNK1;
                end
                M_D_LNK1: if (m_done) begin
                    m_rd1 <= m_rdata; m_st <= M_W_LNK2;
                end
                M_W_LNK2: if (!m_busy) begin
                    m_op <= 1'b1; m_ra <= 5'd1; m_wd <= 16'd0;
                    m_start <= 1'b1; m_st <= M_D_LNK2;
                end
                M_D_LNK2:
                    if (m_done) begin
                        if (m_rd1[2] & m_rdata[2]) begin
                            m_link <= 1'b1;          // 两次均为 1 -> 建链
                            m_cnt  <= 24'd0;
                            m_st   <= M_LINKED;
                        end else begin
                            if (!m_rd1[2] && !m_rdata[2])
                                m_link <= 1'b0;      // 两次均为 0 -> 断链
                            m_st <= M_POLL;
                        end
                    end
                //----------------------------------------------------------
                // 已建链 : 周期复查, 以便断链后刷新指示
                M_LINKED:
                    if (m_cnt == POLL_DLY) begin
                        m_cnt <= 24'd0; m_st <= M_W_LNK1;
                    end else
                        m_cnt <= m_cnt + 24'd1;
                //----------------------------------------------------------
                default: m_st <= M_RSTWAIT;
            endcase
        end
    end

    // MDIO 总线接口 (Clause 22)
    mdio_ctrl u_mdio_ctrl (
        .clk      (clk_50m),
        .rst_n    (sys_rst_n),
        .mdc      (phy_mdc),
        .mdio     (phy_mdio),
        .start    (m_start),
        .op       (m_op),
        .phy_addr (PHY_ADDR),
        .reg_addr (m_ra),
        .wr_data  (m_wd),
        .rd_data  (m_rdata),
        .busy     (m_busy),
        .done     (m_done)
    );

    //======================================================================
    // 3. MAC 协议栈 : rgmii_if <-> mac_core <-> eth_proto (eth_clk 单域)
    //======================================================================
    wire [7:0]  mac_txd, mac_rxd;
    wire        mac_tx_en, mac_tx_er, mac_rx_dv, mac_rx_er;
    wire [7:0]  ep_rx_data, ep_tx_data;
    wire        ep_rx_valid, ep_rx_sop, ep_rx_eop;
    wire        ep_tx_valid, ep_tx_sop, ep_tx_eop;
    wire        mac_tx_ready, rx_crc_ok;
    wire [7:0]  ep_ap_rx_data;
    wire        ep_ap_rx_valid, ep_ap_rx_sop, ep_ap_rx_eop;
    wire [15:0] ep_ap_rx_port;
    wire        ep_ap_tx_ready, peer_mac_valid;

    //--------------------------------------------------------------
    // 3.1 tx_ready 语义适配 : 合成 "逐字节可接收" (见文件头说明)
    //     frame_active 在 sop 字节被接收拍置位, eop 字节被接收拍清零
    //--------------------------------------------------------------
    reg  frame_active;
    wire ep_tx_ready_g = mac_tx_ready | frame_active;
    wire ep_acc        = ep_tx_valid & ep_tx_ready_g;  // 本拍一个 MAC 面字节被接收

    always @(posedge eth_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            frame_active <= 1'b0;
        else if (ep_acc & ep_tx_eop)                 // 帧尾字节已交付 mac_core
            frame_active <= 1'b0;
        else if (ep_acc & ep_tx_sop)                 // 帧首字节已交付 mac_core
            frame_active <= 1'b1;
    end
    //--------------------------------------------------------------
    // 3.2 物理层接口 : GMII <-> RGMII (TXC 由 eth_clk 经 ODDR 输出)
    //--------------------------------------------------------------
    rgmii_if u_rgmii_if (
        .gtx_clk      (eth_clk),
        .rst_n        (sys_rst_n),
        .gmii_txd     (mac_txd),
        .gmii_tx_en   (mac_tx_en),
        .gmii_tx_er   (mac_tx_er),
        .gmii_rxd     (mac_rxd),
        .gmii_rx_dv   (mac_rx_dv),
        .gmii_rx_er   (mac_rx_er),
        .rgmii_txc    (rgmii_txc),
        .rgmii_txd    (rgmii_txd),
        .rgmii_tx_ctl (rgmii_tx_ctl),
        .rgmii_rxc    (rgmii_rxc),
        .rgmii_rxd    (rgmii_rxd),
        .rgmii_rx_ctl (rgmii_rx_ctl)
    );

    //--------------------------------------------------------------
    // 3.3 MAC 核心层 : 前导码/FCS 封装解封, CRC32 校验
    //     gtx_clk 与 rx_clk 同接 eth_clk -> 栈内无跨时钟域
    //     rx_crc_ok 仅为观察点 (eth_proto 未提供该输入)
    //--------------------------------------------------------------
    mac_core u_mac_core (
        .gtx_clk    (eth_clk),
        .rx_clk     (eth_clk),
        .rst_n      (sys_rst_n),
        .tx_data    (ep_tx_data),
        .tx_valid   (ep_tx_valid),
        .tx_sop     (ep_tx_sop),
        .tx_eop     (ep_tx_eop),
        .tx_ready   (mac_tx_ready),
        .gmii_txd   (mac_txd),
        .gmii_tx_en (mac_tx_en),
        .gmii_tx_er (mac_tx_er),
        .gmii_rxd   (mac_rxd),
        .gmii_rx_dv (mac_rx_dv),
        .gmii_rx_er (mac_rx_er),
        .rx_data    (ep_rx_data),
        .rx_valid   (ep_rx_valid),
        .rx_sop     (ep_rx_sop),
        .rx_eop     (ep_rx_eop),
        .rx_crc_ok  (rx_crc_ok)
    );

    //--------------------------------------------------------------
    // 3.4 协议层 : ARP 应答/请求, ICMP 回显, UDP 收发
    //--------------------------------------------------------------
    eth_proto #(
        .LOCAL_MAC      (LOCAL_MAC),
        .LOCAL_IP       (LOCAL_IP),
        .PEER_IP        (PEER_IP),
        .LOCAL_UDP_PORT (LOCAL_UDP_PORT),
        .ICMP_BUF_AW    (ICMP_BUF_AW)
    ) u_eth_proto (
        .clk           (eth_clk),
        .rst_n         (sys_rst_n),
        // RX : 来自 mac_core (帧字节流, 无前导码/FCS)
        .rx_data       (ep_rx_data),
        .rx_valid      (ep_rx_valid),
        .rx_sop        (ep_rx_sop),
        .rx_eop        (ep_rx_eop),
        // TX : 送往 mac_core (tx_ready 为适配后的逐字节 ready)
        .tx_data       (ep_tx_data),
        .tx_valid      (ep_tx_valid),
        .tx_sop        (ep_tx_sop),
        .tx_eop        (ep_tx_eop),
        .tx_ready      (ep_tx_ready_g),
        // RX 应用侧 : UDP 载荷 -> RX fifo 打包
        .app_rx_data   (ep_ap_rx_data),
        .app_rx_valid  (ep_ap_rx_valid),
        .app_rx_sop    (ep_ap_rx_sop),
        .app_rx_eop    (ep_ap_rx_eop),
        .app_rx_port   (ep_ap_rx_port),
        // TX 应用侧 : TX fifo 读出 -> UDP 打包
        .app_tx_data   (tf_rdata),
        .app_tx_valid  (ap_valid),
        .app_tx_sop    (ap_sop),
        .app_tx_eop    (ap_eop),
        .app_tx_len    (ap_len),
        .app_tx_dport  (ap_dport),
        .app_tx_ready  (ep_ap_tx_ready),
        .peer_mac_valid(peer_mac_valid)
    );

    //======================================================================
    // 4. 应用层数据通路 : eth_clk 域 <-> usr_clk 域 (fifo_cdc x2)
    //======================================================================
    //--------------------------------------------------------------
    // 4.1 RX fifo : eth_proto 载荷 -> 用户
    //     每字 26 位 : {sop, eop, 对端源端口[15:0], 数据[7:0]}
    //--------------------------------------------------------------
    wire [25:0] rxr_data;
    wire        rxr_empty, rxw_full, rx_ovf;
    reg  [25:0] rxw_d;
    reg         rxw_en, rx_drop;

    fifo_cdc #(
        .DW (26),
        .AW (RX_FIFO_AW)
    ) u_fifo_rx (
        // 写域 : eth_clk (MAC 协议栈)
        .wclk         (eth_clk),
        .wrst_n       (sys_rst_n),
        .wenc         (rxw_en),
        .wdata        (rxw_d),
        .wfull        (rxw_full),
        .walmost_full (),
        .woverflow    (rx_ovf),
        // 读域 : usr_clk (FWFT)
        .rclk         (usr_clk),
        .rrst_n       (usr_rst_n),
        .renc         (usr_rx_renc),
        .rdata        (rxr_data),
        .rempty       (rxr_empty),
        .ralmost_empty(),
        .runderflow   ()
    );

    //--------------------------------------------------------------
    // 4.2 RX 打包 : app_rx 字节流 -> 26 位宽字
    //     首字携带源端口; FIFO 满时丢包(满在首字前整包丢弃,
    //     满在报文中途则截断 -> 用户收到无 eop 残包, 应丢弃)
    //--------------------------------------------------------------
    always @(posedge eth_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rxw_en  <= 1'b0;
            rxw_d   <= 26'd0;
            rx_drop <= 1'b0;
        end else begin
            rxw_en <= 1'b0;
            if (ep_ap_rx_valid) begin
                if (ep_ap_rx_sop) begin
                    rx_drop <= 1'b0;
                    if (!rxw_full) begin
                        rxw_en <= 1'b1;
                        rxw_d  <= {1'b1, 1'b0, ep_ap_rx_port, ep_ap_rx_data};
                    end else
                        rx_drop <= 1'b1;             // 首字都放不下, 整包丢弃
                end else if (!rx_drop) begin
                    if (!rxw_full) begin
                        rxw_en <= 1'b1;
                        rxw_d  <= {1'b0, ep_ap_rx_eop, 16'd0, ep_ap_rx_data};
                    end else
                        rx_drop <= 1'b1;             // 中途溢出, 截断(无 eop)
                end
            end
        end
    end

    // 用户侧读出解包 : FWFT, valid=!empty
    assign usr_rx_valid = !rxr_empty;
    assign usr_rx_sop   = rxr_data[25];
    assign usr_rx_eop   = rxr_data[24];
    assign usr_rx_port  = rxr_data[23:8];
    assign usr_rx_data  = rxr_data[7:0];
    assign usr_rx_empty = rxr_empty;

    //--------------------------------------------------------------
    // 4.3 TX fifo : 用户 -> eth_proto 发送适配器
    //     逐字 8 位, 报文 = [目的端口2B][长度2B][载荷len B] (大端)
    //--------------------------------------------------------------
    wire [7:0] tf_rdata;
    wire       tf_rempty, tf_renc, tf_udf;

    fifo_cdc #(
        .DW (8),
        .AW (TX_FIFO_AW)
    ) u_fifo_tx (
        // 写域 : usr_clk (用户直接写, 含 4 字节报文头)
        .wclk         (usr_clk),
        .wrst_n       (usr_rst_n),
        .wenc         (usr_tx_wenc),
        .wdata        (usr_tx_wdata),
        .wfull        (usr_tx_full),
        .walmost_full (usr_tx_afull),
        .woverflow    (usr_tx_ovf),
        // 读域 : eth_clk (FWFT, 发送适配器逐字节取)
        .rclk         (eth_clk),
        .rrst_n       (sys_rst_n),
        .renc         (tf_renc),
        .rdata        (tf_rdata),
        .rempty       (tf_rempty),
        .ralmost_empty(),
        .runderflow   (tf_udf)
    );

    //--------------------------------------------------------------
    // 4.4 TX 发送适配器 (eth_clk 域) : FIFO 字节流 -> eth_proto 应用接口
    //     状态流 : 解析 4 字节报文头 -> 携首字节发起(sop) -> 头 42 字节
    //     期间 eth_proto 不取载荷, 随后逐字节对齐弹出 -> 帧尾等发送完毕
    //
    //     与 eth_proto 内部字节计数 n 的对齐 :
    //       n 仅在 (MAC 面字节被接收) 时推进, 故适配器用 ep_acc 计数,
    //       t_cnt 与 n 逐拍相等; t_cnt>=42 的接收拍对应载荷首字节,
    //       此拍弹出 FIFO 队头(FWFT), 恰好供下一载荷字节
    //     对端 MAC 未学习时 eth_proto 先发 ARP 请求, 本适配器保持
    //     valid/sop; 超时(HOLD_MAX)撤回数据使 probe_sent 复位, 间隔
    //     GAP_MAX 后重新发起, 实现 ARP 周期重探
    //     容错 : 报文头/载荷停等超时(STALL_MAX) -> 强制 eop 补零发完
    //     (TH_FORCE) -> 清空 FIFO 残留(TH_FLUSH), 防止整条发送通路死锁
    //--------------------------------------------------------------
    localparam [3:0] TH_HDR0  = 4'd0,    // 取目的端口高字节
                     TH_HDR1  = 4'd1,    // 取目的端口低字节
                     TH_HDR2  = 4'd2,    // 取载荷长度高字节
                     TH_HDR3  = 4'd3,    // 取载荷长度低字节
                     TH_WAIT  = 4'd4,    // 携首字节发起, 等 eth_proto 启动
                     TH_SEND  = 4'd5,    // 帧进行中, 对齐弹出载荷
                     TH_TAIL  = 4'd6,    // 载荷交付完毕, 等整帧发完
                     TH_FLUSH = 4'd7,    // 清空残留字节
                     TH_GAP   = 4'd8,    // 撤回数据间隔(清 probe_sent)
                     TH_FORCE = 4'd9;    // 停等超时, 强制 eop 补零发完

    localparam [23:0] T_STALL_MAX = 24'd2_500_000;   // ~20ms  停等超时
    localparam [23:0] T_HOLD_MAX  = 24'd12_500_000;  // ~100ms 发起保持超时
    localparam [23:0] T_GAP_MAX   = 24'd1_250_000;   // ~10ms  撤回间隔

    reg  [3:0]  t_st;
    reg  [15:0] t_dport, t_len, t_cnt;
    reg  [23:0] t_stall;
    wire        t_ready = ep_ap_tx_ready;

    // FWFT 弹出 : 报文头各拍 / 载荷被接收拍 / 清空时连续弹出
    assign tf_renc = (((t_st == TH_HDR0) | (t_st == TH_HDR1) |
                       (t_st == TH_HDR2) | (t_st == TH_HDR3)) & !tf_rempty)
                   | ((t_st == TH_SEND) & ep_acc &
                      (t_cnt >= 16'd42) & (t_cnt < 16'd42 + t_len) & !tf_rempty)
                   | ((t_st == TH_FLUSH) & !tf_rempty);

    // 呈现给 eth_proto 的应用接口
    reg         ap_valid, ap_sop, ap_eop;
    reg  [15:0] ap_len, ap_dport;
    wire        t_flow = (t_cnt < 16'd42) | !tf_rempty;  // 本拍有载荷可给

    always @* begin
        ap_valid = 1'b0;
        ap_sop   = 1'b0;
        ap_eop   = 1'b0;
        ap_len   = t_len;
        ap_dport = t_dport;
        case (t_st)
            TH_WAIT: begin
                ap_valid = 1'b1;
                ap_sop   = !t_ready;             // 启动后撤下 sop
            end
            TH_SEND: begin
                ap_valid = t_flow;               // 头 42 字节恒有效, 载荷区看 FIFO
                ap_eop   = ep_acc & (t_cnt == 16'd41 + t_len); // 末载荷字节拍
            end
            TH_FORCE: begin
                ap_valid = 1'b1;                 // 强制标记报文提前结束
                ap_eop   = 1'b1;
            end
            default: ;
        endcase
    end

    always @(posedge eth_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            t_st    <= TH_HDR0;
            t_cnt   <= 16'd0;
            t_stall <= 24'd0;
            t_dport <= 16'd0;
            t_len   <= 16'd0;
        end else begin
            case (t_st)
                //------------------------------------------------------
                // 报文头 : 依次捕获端口/长度, FWFT 弹出
                TH_HDR0:
                    if (!tf_rempty) begin
                        t_dport[15:8] <= tf_rdata;
                        t_stall <= 24'd0;
                        t_st    <= TH_HDR1;
                    end else begin
                        t_stall <= t_stall + 24'd1;
                        if (t_stall == T_STALL_MAX) t_st <= TH_FLUSH;
                    end
                TH_HDR1:
                    if (!tf_rempty) begin
                        t_dport[7:0] <= tf_rdata;
                        t_stall <= 24'd0;
                        t_st    <= TH_HDR2;
                    end else begin
                        t_stall <= t_stall + 24'd1;
                        if (t_stall == T_STALL_MAX) t_st <= TH_FLUSH;
                    end
                TH_HDR2:
                    if (!tf_rempty) begin
                        t_len[15:8] <= tf_rdata;
                        t_stall <= 24'd0;
                        t_st    <= TH_HDR3;
                    end else begin
                        t_stall <= t_stall + 24'd1;
                        if (t_stall == T_STALL_MAX) t_st <= TH_FLUSH;
                    end
                TH_HDR3:
                    if (!tf_rempty) begin
                        t_len[7:0] <= tf_rdata;
                        t_stall <= 24'd0;
                        t_st <= ({t_len[15:8], tf_rdata} == 16'd0)
                                ? TH_FLUSH          // len=0 报文作废
                                : TH_WAIT;
                    end else begin
                        t_stall <= t_stall + 24'd1;
                        if (t_stall == T_STALL_MAX) t_st <= TH_FLUSH;
                    end
                //------------------------------------------------------
                // 携首字节发起 : valid/sop 保持到 eth_proto 启动 UDP 帧;
                // 启动拍若 MAC 已接收首字节(ep_acc), 计数从 1 起对齐
                TH_WAIT:
                    if (t_ready) begin
                        t_stall <= 24'd0;
                        t_cnt   <= ep_acc ? 16'd1 : 16'd0;
                        t_st    <= TH_SEND;
                    end else begin
                        t_stall <= t_stall + 24'd1;
                        if (t_stall == T_HOLD_MAX) begin
                            t_stall <= 24'd0;
                            t_st    <= TH_GAP;   // 撤回数据 -> 复位 probe_sent
                        end
                    end
                TH_GAP:
                    if (t_stall == T_GAP_MAX) begin
                        t_stall <= 24'd0;
                        t_st    <= TH_WAIT;      // 重新发起/重新探测
                    end else
                        t_stall <= t_stall + 24'd1;
                //------------------------------------------------------
                // 帧进行中 : 跟随 ep_acc 计数, 载荷区每拍弹出队头;
                // FIFO 空导致停等超时 -> 强制 eop 让 eth_proto 补零发完
                TH_SEND:
                    if (ep_acc) begin
                        t_stall <= 24'd0;
                        t_cnt   <= t_cnt + 16'd1;
                        if (t_cnt == 16'd41 + t_len)
                            t_st <= TH_TAIL;     // 末载荷字节已交付
                    end else if (!t_ready) begin
                        t_st <= TH_TAIL;         // 防御 : 帧意外结束
                    end else if (t_cnt >= 16'd42) begin
                        t_stall <= t_stall + 24'd1;
                        if (t_stall == T_STALL_MAX) t_st <= TH_FORCE;
                    end
                TH_FORCE: t_st <= TH_TAIL;
                //------------------------------------------------------
                // 等整帧发完(含短帧补零), 之后清残留
                TH_TAIL:  if (!t_ready) t_st <= TH_FLUSH;
                TH_FLUSH: if (tf_rempty) begin
                              t_stall <= 24'd0;
                              t_st    <= TH_HDR0;
                          end
                default:  t_st <= TH_HDR0;
            endcase
        end
    end

    //======================================================================
    // 5. 状态指示与跨域同步
    //======================================================================
    // 50M 域 LED
    reg [1:0] led_peer_sync;
    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n)
            led_peer_sync <= 2'b00;
        else
            led_peer_sync <= {led_peer_sync[0], peer_mac_valid};
    end
    assign led_link = m_link;                    // 50M 域本地信号
    assign led_peer = led_peer_sync[1];

    // usr 域状态指示 (电平信号, 2 级同步; rx_ovf 为跨域脉冲仅调试参考)
    reg [1:0] umac_sync, ulnk_sync, uovf_sync;
    always @(posedge usr_clk or negedge usr_rst_n) begin
        if (!usr_rst_n) begin
            umac_sync <= 2'b00;
            ulnk_sync <= 2'b00;
            uovf_sync <= 2'b00;
        end else begin
            umac_sync <= {umac_sync[0], peer_mac_valid};
            ulnk_sync <= {ulnk_sync[0], m_link};
            uovf_sync <= {uovf_sync[0], rx_ovf};
        end
    end
    assign usr_peer_mac_valid = umac_sync[1];
    assign usr_link_up        = ulnk_sync[1];
    assign usr_rx_ovf         = uovf_sync[1];

endmodule

//============================================================================
// Vivado 工程提示 :
//   1. 时钟约束 :
//        create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
//        create_clock -period 8.000  -name eth_clk [get_ports rgmii_rxc]
//        create_clock -period <usr>  -name usr_clk [get_ports usr_clk]
//        set_clock_groups -asynchronous \
//            -group [get_clocks sys_clk] -group [get_clocks eth_clk] \
//            -group [get_clocks usr_clk]
//   2. RGMII 引脚 IOSTANDARD 按板卡 (常见 LVCMOS25); 若 PHY 未开 RGMII-ID,
//      需对 rgmii_rxd/rx_ctl 加输入延迟约束或经 PHY 寄存器开启内部延迟
//   3. 将 rgmii_if / mac_core / eth_proto / fifo_cdc / mdio_ctrl 源文件与
//      本顶层一并加入工程; BUFG/IDDR/ODDR 为 Xilinx 原语
//   4. led_* 为高有效, 板卡 LED 低有效时请取反
//   5. phy_mdio 引脚需板上/内部上拉
//============================================================================
