//============================================================================
// mac_core.v
//----------------------------------------------------------------------------
// 模块功能 : MAC 核心层 —— 以太网帧的封装与解封 (前导码 + CRC32 FCS)
//
// 在 eth_mac 架构中的位置 :
//   TX : eth_proto --(原始帧字节流, gtx_clk 域)--> [mac_core] --(前导码+SFD+FCS)--> rgmii_if
//   RX : rgmii_if --(GMII 字节流, rx_clk 域)--> [mac_core] --(剥前导码/FCS, CRC 校验)--> eth_proto
//
// 时钟说明 :
//   gtx_clk : TX 侧时钟 (125MHz), 与 rgmii_if 发送侧同域
//   rx_clk  : RX 侧时钟, 直接接 rgmii_rxc (1000M=125M, 100M=25M, 10M=2.5MHz)
//   整条 RX 数据链路 (mac_core -> eth_proto) 工作在 rx_clk 域,
//   跨时钟域统一由后级 fifo_cdc 完成, 本模块内部不做跨域
//
// TX 功能 :
//   1) 帧前插入 7 字节前导码 0x55 + 1 字节 SFD 0xD5
//   2) 逐字节计算 CRC32, 帧尾追加 4 字节 FCS (线上字节序: 低字节在前)
//   3) 帧尾强制 12 字节 IFG (帧间隙), 期间 tx_ready 保持 0
//   4) 9 字节帧头缓存: 发前导码期间暂存 eth_proto 的后续字节, 支持连续流
//   5) 帧内断流超过缓存深度时线上会出现空闲 (属违规输入, 接收端会判错)
//
// RX 功能 :
//   1) 检测前导码/SFD 并剥离; 前导码非法 (非 0x55/0xD5 或过长) 整帧丢弃
//   2) 4 级流水线延迟, 精确剥离帧尾 4 字节 FCS, 送 eth_proto 的帧不含 FCS
//   3) CRC32 校验: 合法帧 (含 FCS) 经同一寄存器计算, 残留值恒为 32'hDEBB20E3
//   4) 帧合法性汇总: CRC 正确 且 无 rx_er 且 总长 64~1518 字节 (含 FCS),
//      结果在 rx_eop 拍随 rx_crc_ok 输出, 超长帧以 len_err 锁存防计数回绕
//
// CRC32 参数 (以太网 FCS 标准) :
//   多项式 0x04C11DB7 (反射 0xEDB88320), 初值 0xFFFFFFFF, 输出取反,
//   字节按线上顺序处理 (低位在先)。8 位并行方程组已与 CRC-32/ISO-HDLC
//   标准测试向量 ("123456789" -> 0xCBF43926) 及随机帧逐位模型比对通过
//============================================================================

module mac_core (
    // 时钟与复位
    input  wire        gtx_clk,        // 125MHz 发送时钟 (与 rgmii_if 同源)
    input  wire        rx_clk,         // 接收时钟, 接 rgmii_rxc
    input  wire        rst_n,          // 异步复位, 低有效

    //----------------------------------------
    // 发送侧 : 来自 eth_proto (gtx_clk 域)
    // 契约 : sop/eop 必须与 valid 同拍; 帧内 valid 连续; 新帧等 tx_ready
    //----------------------------------------
    input  wire [7:0]  tx_data,        // 帧数据字节 (不含前导码/FCS)
    input  wire        tx_valid,       // 字节有效
    input  wire        tx_sop,         // 帧起始, 与首字节同拍
    input  wire        tx_eop,         // 帧结束, 与末字节同拍
    output wire        tx_ready,       // 空闲指示, 为 1 才允许发起新帧

    //----------------------------------------
    // 发送侧 : 送往 rgmii_if (gtx_clk 域)
    //----------------------------------------
    output reg  [7:0]  gmii_txd,       // GMII 发送字节 (含前导码/FCS)
    output reg         gmii_tx_en,     // GMII 发送帧指示
    output wire        gmii_tx_er,     // 恒 0, 保留

    //----------------------------------------
    // 接收侧 : 来自 rgmii_if (rx_clk 域)
    //----------------------------------------
    input  wire [7:0]  gmii_rxd,       // GMII 接收字节
    input  wire        gmii_rx_dv,     // GMII 接收帧指示
    input  wire        gmii_rx_er,     // GMII 接收错误指示

    //----------------------------------------
    // 接收侧 : 送往 eth_proto (rx_clk 域)
    //----------------------------------------
    output wire [7:0]  rx_data,        // 帧数据字节 (不含前导码/FCS)
    output wire        rx_valid,       // 字节有效
    output wire        rx_sop,         // 帧起始, 与首字节同拍
    output reg         rx_eop,         // 帧结束, 单拍脉冲 (末字节后 2 拍)
    output reg         rx_crc_ok       // 整帧校验结果, rx_eop 拍有效
);

    //==========================================================================
    // 0. CRC32 : 8 位并行下一态方程 (已验证, 字节低位在先)
    //    输入 crc 为当前寄存器值, d 为本拍字节, 返回处理完该字节后的新值
    //==========================================================================
    function [31:0] crc32_next;
        input [31:0] crc;
        input [7:0]  d;
        begin
            crc32_next[ 0] = crc[ 2] ^ crc[ 8] ^ d[2];
            crc32_next[ 1] = crc[ 0] ^ crc[ 3] ^ crc[ 9] ^ d[0] ^ d[3];
            crc32_next[ 2] = crc[ 0] ^ crc[ 1] ^ crc[ 4] ^ crc[10] ^ d[0] ^ d[1] ^ d[4];
            crc32_next[ 3] = crc[ 1] ^ crc[ 2] ^ crc[ 5] ^ crc[11] ^ d[1] ^ d[2] ^ d[5];
            crc32_next[ 4] = crc[ 0] ^ crc[ 2] ^ crc[ 3] ^ crc[ 6] ^ crc[12] ^ d[0] ^ d[2] ^ d[3] ^ d[6];
            crc32_next[ 5] = crc[ 1] ^ crc[ 3] ^ crc[ 4] ^ crc[ 7] ^ crc[13] ^ d[1] ^ d[3] ^ d[4] ^ d[7];
            crc32_next[ 6] = crc[ 4] ^ crc[ 5] ^ crc[14] ^ d[4] ^ d[5];
            crc32_next[ 7] = crc[ 0] ^ crc[ 5] ^ crc[ 6] ^ crc[15] ^ d[0] ^ d[5] ^ d[6];
            crc32_next[ 8] = crc[ 1] ^ crc[ 6] ^ crc[ 7] ^ crc[16] ^ d[1] ^ d[6] ^ d[7];
            crc32_next[ 9] = crc[ 7] ^ crc[17] ^ d[7];
            crc32_next[10] = crc[ 2] ^ crc[18] ^ d[2];
            crc32_next[11] = crc[ 3] ^ crc[19] ^ d[3];
            crc32_next[12] = crc[ 0] ^ crc[ 4] ^ crc[20] ^ d[0] ^ d[4];
            crc32_next[13] = crc[ 0] ^ crc[ 1] ^ crc[ 5] ^ crc[21] ^ d[0] ^ d[1] ^ d[5];
            crc32_next[14] = crc[ 1] ^ crc[ 2] ^ crc[ 6] ^ crc[22] ^ d[1] ^ d[2] ^ d[6];
            crc32_next[15] = crc[ 2] ^ crc[ 3] ^ crc[ 7] ^ crc[23] ^ d[2] ^ d[3] ^ d[7];
            crc32_next[16] = crc[ 0] ^ crc[ 2] ^ crc[ 3] ^ crc[ 4] ^ crc[24] ^ d[0] ^ d[2] ^ d[3] ^ d[4];
            crc32_next[17] = crc[ 0] ^ crc[ 1] ^ crc[ 3] ^ crc[ 4] ^ crc[ 5] ^ crc[25] ^ d[0] ^ d[1] ^ d[3] ^ d[4] ^ d[5];
            crc32_next[18] = crc[ 0] ^ crc[ 1] ^ crc[ 2] ^ crc[ 4] ^ crc[ 5] ^ crc[ 6] ^ crc[26] ^ d[0] ^ d[1] ^ d[2] ^ d[4] ^ d[5] ^ d[6];
            crc32_next[19] = crc[ 1] ^ crc[ 2] ^ crc[ 3] ^ crc[ 5] ^ crc[ 6] ^ crc[ 7] ^ crc[27] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[6] ^ d[7];
            crc32_next[20] = crc[ 3] ^ crc[ 4] ^ crc[ 6] ^ crc[ 7] ^ crc[28] ^ d[3] ^ d[4] ^ d[6] ^ d[7];
            crc32_next[21] = crc[ 2] ^ crc[ 4] ^ crc[ 5] ^ crc[ 7] ^ crc[29] ^ d[2] ^ d[4] ^ d[5] ^ d[7];
            crc32_next[22] = crc[ 2] ^ crc[ 3] ^ crc[ 5] ^ crc[ 6] ^ crc[30] ^ d[2] ^ d[3] ^ d[5] ^ d[6];
            crc32_next[23] = crc[ 3] ^ crc[ 4] ^ crc[ 6] ^ crc[ 7] ^ crc[31] ^ d[3] ^ d[4] ^ d[6] ^ d[7];
            crc32_next[24] = crc[ 0] ^ crc[ 2] ^ crc[ 4] ^ crc[ 5] ^ crc[ 7] ^ d[0] ^ d[2] ^ d[4] ^ d[5] ^ d[7];
            crc32_next[25] = crc[ 0] ^ crc[ 1] ^ crc[ 2] ^ crc[ 3] ^ crc[ 5] ^ crc[ 6] ^ d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[6];
            crc32_next[26] = crc[ 0] ^ crc[ 1] ^ crc[ 2] ^ crc[ 3] ^ crc[ 4] ^ crc[ 6] ^ crc[ 7] ^ d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[6] ^ d[7];
            crc32_next[27] = crc[ 1] ^ crc[ 3] ^ crc[ 4] ^ crc[ 5] ^ crc[ 7] ^ d[1] ^ d[3] ^ d[4] ^ d[5] ^ d[7];
            crc32_next[28] = crc[ 0] ^ crc[ 4] ^ crc[ 5] ^ crc[ 6] ^ d[0] ^ d[4] ^ d[5] ^ d[6];
            crc32_next[29] = crc[ 0] ^ crc[ 1] ^ crc[ 5] ^ crc[ 6] ^ crc[ 7] ^ d[0] ^ d[1] ^ d[5] ^ d[6] ^ d[7];
            crc32_next[30] = crc[ 0] ^ crc[ 1] ^ crc[ 6] ^ crc[ 7] ^ d[0] ^ d[1] ^ d[6] ^ d[7];
            crc32_next[31] = crc[ 1] ^ crc[ 7] ^ d[1] ^ d[7];
        end
    endfunction

    //==========================================================================
    // 1. 两个时钟域各自的复位同步 : 异步复位、同步释放
    //==========================================================================
    reg  [2:0] rst_tx_r;
    reg  [2:0] rst_rx_r;
    wire       rst_tx;
    wire       rst_rx;

    always @(posedge gtx_clk or negedge rst_n) begin
        if (!rst_n)
            rst_tx_r <= 3'b111;
        else
            rst_tx_r <= {1'b0, rst_tx_r[2:1]};
    end
    assign rst_tx = rst_tx_r[0];

    always @(posedge rx_clk or negedge rst_n) begin
        if (!rst_n)
            rst_rx_r <= 3'b111;
        else
            rst_rx_r <= {1'b0, rst_rx_r[2:1]};
    end
    assign rst_rx = rst_rx_r[0];

    //==========================================================================
    // 2. TX 方向 : 原始帧 -> [前导码 8B] + [数据] + [FCS 4B] -> GMII
    //    状态流 : IDLE -> PRE(8拍) -> DATA(发送+算CRC) -> CRC(4拍) -> IFG(12拍)
    //    帧头缓存 : 发前导码的 8 拍内 eth_proto 仍在连续送数, 若不暂存会丢字节,
    //    故设 9 字节移位缓存 (峰值 = sop 首字节 + PRE 期间最多 8 字节),
    //    DATA 态先从缓存头顺序取数, 排空后转为零延迟直通
    //==========================================================================
    localparam [2:0] TX_IDLE = 3'd0,     // 空闲, 等待 sop
                     TX_PRE  = 3'd1,     // 发送前导码 0x55 x7 + 0xD5
                     TX_DATA = 3'd2,     // 发送帧数据, 同步计算 CRC
                     TX_CRC  = 3'd3,     // 发送 4 字节 FCS
                     TX_IFG  = 3'd4;     // 帧间隙 12 字节时间

    reg  [2:0]  tx_state;
    reg  [2:0]  pre_cnt;       // 前导码字节计数
    reg  [1:0]  crc_cnt;       // FCS 字节计数
    reg  [3:0]  ifg_cnt;       // IFG 计数
    reg  [31:0] tx_crc;        // TX CRC 寄存器
    reg  [31:0] tx_fcs;        // 帧结束锁存的 FCS (已取反)

    // 9 字节帧头移位缓存 (数据 + 对应 eop 标记)
    reg  [7:0]  tbuf [0:8];
    reg         tbe  [0:8];
    reg  [3:0]  tcnt;          // 缓存字节数 0~9

    // 入队 : IDLE 收 sop / PRE 与 DATA 态的 tx_valid
    // 出队 : DATA 态缓存非空时每拍取 1 字节 (速率 >= 入队, 不会溢出)
    wire buf_push = (tx_state == TX_IDLE && tx_valid && tx_sop)
                 || (tx_state == TX_PRE  && tx_valid)
                 || (tx_state == TX_DATA && tx_valid && (tcnt != 4'd0));
    wire buf_pop  = (tx_state == TX_DATA) && (tcnt != 4'd0);

    integer m;
    always @(posedge gtx_clk) begin
        if (rst_tx) begin
            tcnt <= 4'd0;
        end else if (tx_state == TX_CRC || tx_state == TX_IFG) begin
            tcnt <= 4'd0;      // 防御 : 帧结束后清残留
        end else begin
            case ({buf_push, buf_pop})
                2'b10:   begin                // 仅入队 (此时 tcnt <= 8)
                    tbuf[tcnt] <= tx_data;
                    tbe[tcnt]  <= tx_eop;
                    tcnt       <= tcnt + 4'd1;
                end
                2'b01:   begin                // 仅出队 : 整体前移
                    for (m = 0; m < 8; m = m + 1) begin
                        tbuf[m] <= tbuf[m+1];
                        tbe[m]  <= tbe[m+1];
                    end
                    tcnt <= tcnt - 4'd1;
                end
                2'b11:   begin                // 出队同时入队 : 新字节接队尾
                    for (m = 0; m < 8; m = m + 1) begin
                        tbuf[m] <= tbuf[m+1];
                        tbe[m]  <= tbe[m+1];
                    end
                    tbuf[tcnt - 4'd1] <= tx_data;
                    tbe[tcnt - 4'd1]  <= tx_eop;
                end
                default: ;                    // 不动
            endcase
        end
    end

    assign tx_ready   = (tx_state == TX_IDLE);
    assign gmii_tx_er = 1'b0;

    always @(posedge gtx_clk) begin
        if (rst_tx) begin
            tx_state   <= TX_IDLE;
            pre_cnt    <= 3'd0;
            crc_cnt    <= 2'd0;
            ifg_cnt    <= 4'd0;
            tx_crc     <= 32'hFFFFFFFF;
            tx_fcs     <= 32'd0;
            gmii_txd   <= 8'd0;
            gmii_tx_en <= 1'b0;
        end else begin
            case (tx_state)
                //------------------------------------------------------------
                TX_IDLE: begin
                    gmii_tx_en <= 1'b0;
                    gmii_txd   <= 8'd0;
                    if (tx_valid && tx_sop) begin
                        tx_crc   <= 32'hFFFFFFFF; // CRC 初值
                        pre_cnt  <= 3'd0;
                        tx_state <= TX_PRE;
                    end
                end
                //------------------------------------------------------------
                // 8 拍 : 0x55 x7 + SFD 0xD5
                TX_PRE: begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd   <= (pre_cnt == 3'd7) ? 8'hD5 : 8'h55;
                    pre_cnt    <= pre_cnt + 1'b1;
                    if (pre_cnt == 3'd7)
                        tx_state <= TX_DATA;
                end
                //------------------------------------------------------------
                // 先排空帧头缓存, 再零延迟直通; CRC 逐字节累加, eop 拍锁存 FCS
                TX_DATA: begin
                    if (tcnt != 4'd0) begin
                        gmii_tx_en <= 1'b1;
                        gmii_txd   <= tbuf[0];
                        tx_crc     <= crc32_next(tx_crc, tbuf[0]);
                        if (tbe[0]) begin          // 缓存中的 eop 标记
                            tx_fcs   <= ~crc32_next(tx_crc, tbuf[0]);
                            crc_cnt  <= 2'd0;
                            tx_state <= TX_CRC;
                        end
                    end else if (tx_valid) begin
                        gmii_tx_en <= 1'b1;
                        gmii_txd   <= tx_data;
                        tx_crc     <= crc32_next(tx_crc, tx_data);
                        if (tx_eop) begin
                            tx_fcs   <= ~crc32_next(tx_crc, tx_data);
                            crc_cnt  <= 2'd0;
                            tx_state <= TX_CRC;
                        end
                    end else begin
                        gmii_tx_en <= 1'b0;        // 断流容错 : 暂停发送
                    end
                end
                //------------------------------------------------------------
                // 4 拍 : FCS 线上字节序 = 低字节在前
                TX_CRC: begin
                    gmii_tx_en <= 1'b1;
                    case (crc_cnt)
                        2'd0:    gmii_txd <= tx_fcs[7:0];
                        2'd1:    gmii_txd <= tx_fcs[15:8];
                        2'd2:    gmii_txd <= tx_fcs[23:16];
                        default: gmii_txd <= tx_fcs[31:24];
                    endcase
                    crc_cnt <= crc_cnt + 1'b1;
                    if (crc_cnt == 2'd3) begin
                        ifg_cnt  <= 4'd11;
                        tx_state <= TX_IFG;
                    end
                end
                //------------------------------------------------------------
                // 12 拍帧间隙, 期间不接收新帧
                TX_IFG: begin
                    gmii_tx_en <= 1'b0;
                    ifg_cnt    <= ifg_cnt - 1'b1;
                    if (ifg_cnt == 4'd0)
                        tx_state <= TX_IDLE;
                end
                //------------------------------------------------------------
                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    //==========================================================================
    // 3. RX 方向 : GMII -> [剥前导码] -> [4 级流水剥 FCS] + [CRC 校验] -> eth_proto
    //    状态流 : IDLE -> PRE(找 SFD) -> DATA(收数+算CRC) -> IDLE
    //    帧尾 4 字节是 FCS, 但收流时无法预知长度, 故用 4 级延迟线:
    //    输出延迟 4 拍, dv 消失后再屏蔽 4 拍, 恰好滤掉 FCS
    //==========================================================================
    localparam [1:0] RX_IDLE = 2'd0,     // 等 dv 上升
                     RX_PRE  = 2'd1,     // 检查前导码, 找 SFD 0xD5
                     RX_DATA = 2'd2;     // 帧数据接收

    reg  [1:0]  rx_state;
    reg  [3:0]  pre_cnt;       // 前导码 0x55 计数 (允许 0~7 个)
    reg         er_seen;       // 帧内出现过 rx_er
    reg         len_err;       // 超长帧锁存 (>1518 字节, 防计数回绕)
    reg  [11:0] rx_cnt;        // 帧内已收字节计数 (含 FCS)
    reg  [31:0] rx_crc;        // RX CRC 寄存器

    // 4 级延迟线 : 数据 + 有效 + 帧首标志
    reg  [7:0]  pipe_data [0:3];
    reg         pipe_dv   [0:3];
    reg         pipe_sop  [0:3];
    reg  [2:0]  flush_cnt;     // 帧尾 FCS 屏蔽计数 (dv 消失后 4 拍)

    wire        rx_is_sfd   = (gmii_rxd == 8'hD5);
    wire        rx_is_pre   = (gmii_rxd == 8'h55);
    wire [31:0] rx_crc_nxt  = crc32_next(rx_crc, gmii_rxd);
    wire        rx_len_ok   = !len_err && (rx_cnt >= 12'd64) && (rx_cnt <= 12'd1518);

    // 帧尾 FCS 屏蔽 : dv 消失拍 (flush_cnt 尚未生效, 用组合信号补屏蔽)
    // 加上其后 flush_cnt=4,3,2 三拍, 恰好盖住延迟线中移出的 4 个 FCS 字节
    wire rx_fcs_mask = (rx_state == RX_DATA) && !gmii_rx_dv;

    // 输出取自延迟线末级
    assign rx_data  = pipe_data[3];
    assign rx_valid = pipe_dv[3] && (flush_cnt == 3'd0) && !rx_fcs_mask;
    assign rx_sop   = pipe_sop[3] && pipe_dv[3] && (flush_cnt == 3'd0) && !rx_fcs_mask;

    integer k;
    always @(posedge rx_clk) begin
        if (rst_rx) begin
            rx_state  <= RX_IDLE;
            pre_cnt   <= 4'd0;
            er_seen   <= 1'b0;
            len_err   <= 1'b0;
            rx_cnt    <= 12'd0;
            rx_crc    <= 32'hFFFFFFFF;
            flush_cnt <= 3'd0;
            rx_eop    <= 1'b0;
            rx_crc_ok <= 1'b0;
            for (k = 0; k < 4; k = k + 1) begin
                pipe_data[k] <= 8'd0;
                pipe_dv[k]   <= 1'b0;
                pipe_sop[k]  <= 1'b0;
            end
        end else begin
            //------------------------------------------------------------
            // 每拍默认 : 延迟线推进, 新输入无效, 脉冲类信号清零
            //------------------------------------------------------------
            for (k = 3; k > 0; k = k - 1) begin
                pipe_data[k] <= pipe_data[k-1];
                pipe_dv[k]   <= pipe_dv[k-1];
                pipe_sop[k]  <= pipe_sop[k-1];
            end
            pipe_data[0] <= 8'd0;
            pipe_dv[0]   <= 1'b0;
            pipe_sop[0]  <= 1'b0;
            if (flush_cnt != 3'd0)
                flush_cnt <= flush_cnt - 1'b1;
            rx_eop <= 1'b0;

            case (rx_state)
                //------------------------------------------------------------
                RX_IDLE: begin
                    if (gmii_rx_dv) begin
                        rx_state <= RX_PRE;
                        pre_cnt  <= 4'd0;
                        er_seen  <= 1'b0;
                    end
                end
                //------------------------------------------------------------
                // 前导码 : 允许 0~7 个 0x55, 收到 0xD5 进入数据态
                RX_PRE: begin
                    if (!gmii_rx_dv || gmii_rx_er) begin
                        rx_state <= RX_IDLE;               // 假起始/错误
                    end else if (rx_is_sfd) begin
                        rx_state  <= RX_DATA;              // SFD, 数据从下一字节开始
                        rx_cnt    <= 12'd0;
                        rx_crc    <= 32'hFFFFFFFF;
                        len_err   <= 1'b0;
                        flush_cnt <= 3'd0;                 // 兜底清屏蔽
                    end else if (rx_is_pre && pre_cnt != 4'd7) begin
                        pre_cnt <= pre_cnt + 1'b1;         // 前导码字节
                    end else begin
                        rx_state <= RX_IDLE;               // 非法/过长前导码, 丢帧
                    end
                end
                //------------------------------------------------------------
                // 数据态 : 字节进 CRC 与延迟线; dv 消失 = 帧结束
                RX_DATA: begin
                    if (gmii_rx_dv) begin
                        rx_crc <= rx_crc_nxt;              // 含 FCS 一并累加
                        rx_cnt <= rx_cnt + 1'b1;
                        if (rx_cnt == 12'd1518)
                            len_err <= 1'b1;               // 超长锁存
                        pipe_data[0] <= gmii_rxd;
                        pipe_dv[0]   <= 1'b1;
                        pipe_sop[0]  <= (rx_cnt == 12'd0); // 首数据字节
                        if (gmii_rx_er)
                            er_seen <= 1'b1;
                    end else begin
                        // 帧结束拍 : CRC 已含全部字节 (含 FCS)
                        // 合法帧残留值恒为 32'hDEBB20E3, 以此判 CRC
                        flush_cnt <= 3'd4;                 // 屏蔽后续 4 拍 (FCS)
                        rx_crc_ok <= (rx_crc == 32'hDEBB20E3)
                                     && !er_seen && rx_len_ok;
                        rx_eop    <= 1'b1;
                        rx_state  <= RX_IDLE;
                    end
                end
                //------------------------------------------------------------
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

endmodule

//============================================================================
// 例化示例 (eth_mac 顶层) :
//
//   // eth_proto -> mac_core -> rgmii_if (TX, gtx_clk 域)
//   // rgmii_if   -> mac_core -> eth_proto (RX, rgmii_rxc 域)
//   mac_core u_mac_core (
//       .gtx_clk    (gtx_clk_125m),      // PLL 产生的 125MHz
//       .rx_clk     (phy_rxc),           // = rgmii_rxc, 与 rgmii_if RX 同域
//       .rst_n      (sys_rst_n),
//
//       .tx_data    (proto_tx_data),     // 接 eth_proto TX
//       .tx_valid   (proto_tx_valid),
//       .tx_sop     (proto_tx_sop),
//       .tx_eop     (proto_tx_eop),
//       .tx_ready   (proto_tx_ready),
//
//       .gmii_txd   (mac_txd),           // 接 rgmii_if TX
//       .gmii_tx_en (mac_tx_en),
//       .gmii_tx_er (mac_tx_er),         // 顶层也可直接悬空不用
//
//       .gmii_rxd   (mac_rxd),           // 接 rgmii_if RX (rxc 域)
//       .gmii_rx_dv (mac_rx_dv),
//       .gmii_rx_er (mac_rx_er),
//
//       .rx_data    (proto_rx_data),     // 接 eth_proto RX
//       .rx_valid   (proto_rx_valid),
//       .rx_sop     (proto_rx_sop),
//       .rx_eop     (proto_rx_eop),
//       .rx_crc_ok  (proto_rx_crc_ok)
//   );
//
// 接口时序约定 (与 eth_proto) :
//   TX : 1) 首拍 tx_valid=1 && tx_sop=1, tx_data=目的 MAC 首字节
//        2) 帧内 tx_valid 连续为 1 (帧内空拍会使线上出现空闲, 接收端判错)
//        3) 末拍 tx_valid=1 && tx_eop=1, tx_data=帧最后一字节 (不含 FCS)
//        4) 新帧必须等 tx_ready=1, IFG 期间发起的 sop 会被忽略
//        5) 单字节帧 (sop 与 eop 同拍) 亦支持, mac_core 自行缓存首字节
//   RX : 1) rx_sop 与首字节同拍, rx_valid 逐字节有效, 数据不含前导码/FCS
//        2) rx_eop 为单拍脉冲, 比最后有效字节晚 2 拍 (中间 1 拍为 FCS 屏蔽)
//        3) rx_crc_ok 在 rx_eop 拍有效: 1=整帧正确 (CRC/长度/无错误)
//           非法帧同样给出 eop (crc_ok=0), 由 eth_proto 决定丢弃
//
// 注意事项 :
//   1. TX/RX 是两个独立时钟域: TX 全部在 gtx_clk 域, RX 全部在 rx_clk 域,
//      不得将 rx_* 输出直接接到 gtx_clk 域逻辑, 跨域由 fifo_cdc 完成
//   2. CRC 校验用的是 "残留值" 技巧: 合法帧连同其 FCS 一起送入 CRC 寄存器,
//      终值恒为 32'hDEBB20E3 (magic number), 无需缓存末 4 字节做比较
//   3. FCS 线上字节序为低字节在前: tx_fcs[7:0] 最先发出, 与 zlib.crc32/
//      CRC-32/ISO-HDLC 标准一致 ("123456789" 的 FCS 线序为 26 43 F4 CB)
//   4. 帧长检查: 总长 (含 FCS) 须为 64~1518 字节, 即 eth_proto 收到的
//      帧数据为 60~1514 字节; 更长的巨型帧需自行放宽 rx_len_ok
//   5. 100M/10M 模式下 rx_clk 降速为 25M/2.5M, 本模块逻辑与速率无关
//   6. 综合提示: crc32_next 为纯组合 XOR 树, 125MHz 下时序裕量充足;
//      若时序紧张可将 CRC 计算移入相邻寄存器间加一级流水 (需同步调整 FCS)
//============================================================================
