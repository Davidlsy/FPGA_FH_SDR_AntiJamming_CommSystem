`timescale 1ns / 1ps
//============================================================================
// eth_proto.v : 以太网协议处理模块 (ARP / ICMP / UDP)
//----------------------------------------------------------------------------
// 位置 : mac_core 与 fifo_cdc 之间
//   RX(左->右) : mac_core --> eth_proto --> fifo_cdc(应用层)
//   TX(右->左) : fifo_cdc(应用层) --> eth_proto --> mac_core
//
// 功能 :
//   1. ARP  : 收到针对本机IP的ARP请求 -> 自动回复ARP应答
//             应用层要发UDP但对端MAC未知      -> 自动发ARP请求探测
//   2. ICMP : 收到回显请求(ping)      -> 自动回复回显应答(数据缓存于RAM)
//   3. UDP  : 收到UDP报文  -> 剥离ETH/IP/UDP头, 载荷送应用层(app_rx_*)
//            应用层载荷(app_tx_*) -> 自动打包UDP/IP/ETH帧发出
//
// 接口约定 :
//   - rx_* : mac_core输出的帧字节流(已去前导码和FCS)
//   - tx_* : 原始以太网帧字节流(无前导码/FCS, 短帧自动补0到60字节)
//   - 仅支持无选项IPv4(IHL=5), 不支持VLAN
//============================================================================
module eth_proto #(
    //--------------------------- 参数配置 ----------------------------------
    parameter [47:0] LOCAL_MAC      = 48'h11_22_33_44_55_66, // 本机MAC地址
    parameter [31:0] LOCAL_IP       = 32'hC0_A8_01_64,       // 本机IP: 192.168.1.100
    parameter [31:0] PEER_IP        = 32'hC0_A8_01_01,       // 对端IP: 192.168.1.1(PC)
    parameter [15:0] LOCAL_UDP_PORT = 16'd5000,              // 本机UDP源端口
    parameter        ICMP_BUF_AW    = 10                     // ICMP数据RAM位宽(2^10=1024字节)
)(
    input  wire        clk,             // 系统时钟(与mac_core同域, 125MHz)
    input  wire        rst_n,           // 低电平复位

    //-------------------- RX : 来自 mac_core -------------------------------
    input  wire [7:0]  rx_data,         // 帧数据字节
    input  wire        rx_valid,        // 数据有效
    input  wire        rx_sop,          // 帧起始(第一个字节)
    input  wire        rx_eop,          // 帧结束(最后一个字节)

    //-------------------- TX : 发往 mac_core -------------------------------
    output wire [7:0]  tx_data,         // 帧数据字节
    output wire        tx_valid,        // 数据有效
    output wire        tx_sop,          // 帧起始
    output wire        tx_eop,          // 帧结束
    input  wire        tx_ready,        // mac_core可接收(为1时字节被取走)

    //--------------- RX应用侧 : UDP载荷 -> fifo_cdc ------------------------
    output reg  [7:0]  app_rx_data,     // UDP载荷字节
    output reg         app_rx_valid,    // 载荷有效
    output reg         app_rx_sop,      // 包起始
    output reg         app_rx_eop,      // 包结束
    output wire [15:0] app_rx_port,     // 对端UDP源端口号

    //--------------- TX应用侧 : fifo_cdc -> UDP打包 ------------------------
    input  wire [7:0]  app_tx_data,     // 待发送载荷字节
    input  wire        app_tx_valid,    // 载荷有效(保持直到被接收)
    input  wire        app_tx_sop,      // 包起始
    input  wire        app_tx_eop,      // 包结束
    input  wire [15:0] app_tx_len,      // 载荷长度, 需在app_tx_sop时有效
    input  wire [15:0] app_tx_dport,    // 目的UDP端口, 需在app_tx_sop时有效
    output wire        app_tx_ready,    // 为1期间app_tx_data被逐字节接收
    output wire        peer_mac_valid   // 已学习到对端(PEER_IP)的MAC地址
);

    //----------------------------------------------------------------------
    // 帧类型定义
    //----------------------------------------------------------------------
    localparam T_ARP_REP = 2'd0;         // ARP应答
    localparam T_ARP_REQ = 2'd1;         // ARP请求
    localparam T_ICMP    = 2'd2;         // ICMP回显应答
    localparam T_UDP     = 2'd3;         // UDP数据帧

    //----------------------------------------------------------------------
    // 校验和函数 : 32位和 -> 16位反码折叠后取反
    //----------------------------------------------------------------------
    function [15:0] csum_fold;
        input [31:0] s;
        reg   [16:0] t;
        begin
            t = s[31:16] + s[15:0];
            t = {1'b0, t[15:0]} + {16'd0, t[16]};
            csum_fold = ~t[15:0];
        end
    endfunction

    //----------------------------------------------------------------------
    // IP头校验和计算(无选项20字节头)
    //----------------------------------------------------------------------
    function [15:0] iph_csum;
        input [15:0] totlen;             // IP总长度
        input [15:0] id;                 // IP标识
        input [7:0]  proto;              // 协议号
        input [31:0] src;                // 源IP
        input [31:0] dst;                // 目的IP
        begin
            iph_csum = csum_fold(
                         32'h0000_4500 + {16'h0000, totlen}   // 版本/首长 + 总长度
                       + {16'h0000, id}    + 32'h0000_4000    // 标识 + 标志/片偏移
                       + {8'h00, 8'h40, proto}                // TTL + 协议号
                       + {16'h0000, src[31:16]} + {16'h0000, src[15:0]}
                       + {16'h0000, dst[31:16]} + {16'h0000, dst[15:0]});
        end
    endfunction

    //----------------------------------------------------------------------
    // 字节选择函数 : 多字节字段的串行化输出
    //----------------------------------------------------------------------
    function [7:0] mac_b;                // MAC第i字节(i=0为最高字节)
        input [47:0] m;
        input [15:0] i;
        begin
            case (i)
                16'd0   : mac_b = m[47:40];
                16'd1   : mac_b = m[39:32];
                16'd2   : mac_b = m[31:24];
                16'd3   : mac_b = m[23:16];
                16'd4   : mac_b = m[15:8];
                default : mac_b = m[7:0];
            endcase
        end
    endfunction

    function [7:0] ip_b;                 // IP地址第i字节
        input [31:0] a;
        input [15:0] i;
        begin
            case (i)
                16'd0   : ip_b = a[31:24];
                16'd1   : ip_b = a[23:16];
                16'd2   : ip_b = a[15:8];
                default : ip_b = a[7:0];
            endcase
        end
    endfunction

    function [7:0] w16_b;                // 16位量第i字节
        input [15:0] v;
        input [15:0] i;
        begin
            w16_b = (i == 16'd0) ? v[15:8] : v[7:0];
        end
    endfunction

    //======================================================================
    // (1) RX解析 : 逐字节计数解析以太网帧
    //     字节布局 : [0:5]目的MAC [6:11]源MAC [12:13]类型
    //               ARP : [14:41]ARP报文(20操作+28字段)
    //               IP  : [14:33]IP头 [34:41]ICMP/UDP头 [42: ]载荷
    //======================================================================
    reg  [13:0] rx_cnt;
    reg  [47:0] r_dst_mac, r_src_mac;
    reg         r_acc;                   // 目的MAC过滤通过
    reg  [15:0] r_etype;                 // 以太网类型
    reg         f_ip;                    // 本帧为IPv4
    reg  [31:0] ip_sum;                  // IP头校验和累加
    reg         ip_ver_ok, ip_csum_ok, ip_dst_ok;
    reg  [15:0] r_iplen;                 // IP总长度
    reg  [7:0]  r_ipproto;               // IP协议号
    reg  [31:0] r_ipsrc, r_ipdst;        // 源/目的IP
    reg  [15:0] r_aroper;                // ARP操作码
    reg  [47:0] r_asha;                  // ARP发送端MAC
    reg  [31:0] r_aspa, r_atpa;          // ARP发送端/目标IP
    reg  [7:0]  r_ictype;                // ICMP类型
    reg  [15:0] r_icid, r_icseq;         // ICMP标识/序号
    reg  [31:0] r_icsum;                 // ICMP应答校验和累加
    reg  [15:0] r_usport, r_udport;      // UDP源/目的端口
    reg  [ICMP_BUF_AW:0] wptr;           // ICMP数据RAM写指针
    reg  [7:0]  icmp_buf [0:(1<<ICMP_BUF_AW)-1];
    reg         pend_icmp_rep;           // 待发送ICMP回显应答
    reg  [15:0] icmp_dlen;               // 回显数据长度
    reg  [47:0] icmp_dst_mac;            // 应答目的MAC
    reg  [31:0] icmp_dst_ip;             // 应答目的IP

    wire [13:0] ip_end = r_iplen[13:0] + 14'd13;  // IP载荷区末字节序号

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_cnt     <= 14'd0;
            r_acc      <= 1'b0;
            f_ip       <= 1'b0;
            ip_ver_ok  <= 1'b0;
            ip_csum_ok <= 1'b0;
            ip_dst_ok  <= 1'b0;
            ip_sum     <= 32'd0;
            wptr       <= {(ICMP_BUF_AW+1){1'b0}};
            app_rx_data  <= 8'd0;
            app_rx_valid <= 1'b0;
            app_rx_sop   <= 1'b0;
            app_rx_eop   <= 1'b0;
            pend_icmp_rep<= 1'b0;
            icmp_dlen    <= 16'd0;
            icmp_dst_mac <= 48'd0;
            icmp_dst_ip  <= 32'd0;
            r_dst_mac <= 48'd0;   r_src_mac <= 48'd0;
            r_etype   <= 16'd0;   r_iplen   <= 16'd0;
            r_ipproto <= 8'd0;    r_ipsrc   <= 32'd0;
            r_ipdst   <= 32'd0;
            r_aroper  <= 16'd0;   r_asha    <= 48'd0;
            r_aspa    <= 32'd0;   r_atpa    <= 32'd0;
            r_ictype  <= 8'd0;    r_icid    <= 16'd0;
            r_icseq   <= 16'd0;   r_icsum   <= 32'd0;
            r_usport  <= 16'd0;   r_udport  <= 16'd0;
        end else begin
            app_rx_valid <= 1'b0;
            app_rx_sop   <= 1'b0;
            app_rx_eop   <= 1'b0;

            if (start_icmp_rep)                  // 发送引擎取走ICMP应答请求
                pend_icmp_rep <= 1'b0;

            if (rx_valid) begin
                if (rx_sop) begin
                    rx_cnt    <= rx_eop ? 14'd0 : 14'd1;
                    r_acc     <= 1'b1;
                    f_ip      <= 1'b0;
                    ip_ver_ok <= 1'b0;
                    ip_csum_ok<= 1'b0;
                    ip_dst_ok <= 1'b0;
                    ip_sum    <= 32'd0;
                    wptr      <= {(ICMP_BUF_AW+1){1'b0}};
                    r_dst_mac <= {r_dst_mac[39:0], rx_data};
                end else begin
                    //----------------------------------------------
                    // 字节1~5 : 目的MAC
                    //----------------------------------------------
                    if (rx_cnt <= 14'd5)
                        r_dst_mac <= {r_dst_mac[39:0], rx_data};
                    //----------------------------------------------
                    // 字节6 : 目的MAC过滤 + 源MAC
                    //----------------------------------------------
                    if (rx_cnt == 14'd6) begin
                        r_acc <= (r_dst_mac == LOCAL_MAC) ||
                                 (r_dst_mac == 48'hFF_FF_FF_FF_FF_FF);
                        r_src_mac <= {r_src_mac[39:0], rx_data};
                    end
                    if (rx_cnt >= 14'd7 && rx_cnt <= 14'd11)
                        r_src_mac <= {r_src_mac[39:0], rx_data};
                    //----------------------------------------------
                    // 字节12~13 : 以太网类型
                    //----------------------------------------------
                    if (rx_cnt >= 14'd12 && rx_cnt <= 14'd13)
                        r_etype <= {r_etype[7:0], rx_data};
                    //----------------------------------------------
                    // 字节14 : 类型分发 + IP版本/首部长度
                    //----------------------------------------------
                    if (rx_cnt == 14'd14) begin
                        f_ip <= r_acc && (r_etype == 16'h0800);
                        if (r_acc && r_etype == 16'h0800) begin
                            ip_ver_ok <= (rx_data == 8'h45);
                            ip_sum    <= {rx_data, 8'h00};
                        end
                    end
                    //----------------------------------------------
                    // 字节15~33 : IP头校验和累加
                    //----------------------------------------------
                    if (f_ip && rx_cnt >= 14'd15 && rx_cnt <= 14'd33)
                        ip_sum <= (rx_cnt[0] == 1'b0)
                                    ? (ip_sum + {16'h0000, rx_data, 8'h00})
                                    : (ip_sum + {24'h000000, rx_data});
                    //----------------------------------------------
                    // 字节16~17 : IP总长度
                    //----------------------------------------------
                    if (f_ip && rx_cnt >= 14'd16 && rx_cnt <= 14'd17)
                        r_iplen <= {r_iplen[7:0], rx_data};
                    //----------------------------------------------
                    // 字节23 : 协议号 / 字节26~33 : 源、目的IP
                    //----------------------------------------------
                    if (f_ip && rx_cnt == 14'd23)
                        r_ipproto <= rx_data;
                    if (f_ip && rx_cnt >= 14'd26 && rx_cnt <= 14'd29)
                        r_ipsrc <= {r_ipsrc[23:0], rx_data};
                    if (f_ip && rx_cnt >= 14'd30 && rx_cnt <= 14'd33)
                        r_ipdst <= {r_ipdst[23:0], rx_data};
                    //----------------------------------------------
                    // 字节34 : IP头校验完成 + ICMP类型 + UDP源端口
                    //----------------------------------------------
                    if (f_ip && rx_cnt == 14'd34) begin
                        ip_csum_ok <= (csum_fold(ip_sum) == 16'h0000);
                        ip_dst_ok  <= (r_ipdst == LOCAL_IP);
                        r_ictype   <= rx_data;
                    end
                    if (f_ip && r_ipproto == 8'h11 &&
                        rx_cnt >= 14'd34 && rx_cnt <= 14'd35)
                        r_usport <= {r_usport[7:0], rx_data};
                    if (f_ip && r_ipproto == 8'h11 &&
                        rx_cnt >= 14'd36 && rx_cnt <= 14'd37)
                        r_udport <= {r_udport[7:0], rx_data};
                    if (f_ip && r_ipproto == 8'h01 &&
                        rx_cnt >= 14'd38 && rx_cnt <= 14'd39)
                        r_icid <= {r_icid[7:0], rx_data};
                    if (f_ip && r_ipproto == 8'h01 &&
                        rx_cnt >= 14'd40 && rx_cnt <= 14'd41)
                        r_icseq <= {r_icseq[7:0], rx_data};
                    //----------------------------------------------
                    // ARP字段 : 字节20~41
                    //----------------------------------------------
                    if (r_etype == 16'h0806 &&
                        rx_cnt >= 14'd20 && rx_cnt <= 14'd21)
                        r_aroper <= {r_aroper[7:0], rx_data};
                    if (r_etype == 16'h0806 &&
                        rx_cnt >= 14'd22 && rx_cnt <= 14'd27)
                        r_asha <= {r_asha[39:0], rx_data};
                    if (r_etype == 16'h0806 &&
                        rx_cnt >= 14'd28 && rx_cnt <= 14'd31)
                        r_aspa <= {r_aspa[23:0], rx_data};
                    if (r_etype == 16'h0806 &&
                        rx_cnt >= 14'd38 && rx_cnt <= 14'd41)
                        r_atpa <= {r_atpa[23:0], rx_data};
                    //----------------------------------------------
                    // ICMP回显请求 : 应答校验和累加(字节38~IP载荷末尾)
                    // 应答报文首字为0x0000, 故只需累加ID/序号/数据
                    //----------------------------------------------
                    if (f_ip && r_ipproto == 8'h01 && r_ictype == 8'h08 &&
                        rx_cnt >= 14'd38 && rx_cnt <= ip_end)
                        r_icsum <= (rx_cnt[0] == 1'b0)
                                     ? (r_icsum + {16'h0000, rx_data, 8'h00})
                                     : (r_icsum + {24'h000000, rx_data});
                    //----------------------------------------------
                    // ICMP回显请求 : 回显数据写入RAM(字节42~IP载荷末尾)
                    //----------------------------------------------
                    if (f_ip && r_ipproto == 8'h01 && r_ictype == 8'h08 &&
                        rx_cnt >= 14'd42 && rx_cnt <= ip_end) begin
                        if (!wptr[ICMP_BUF_AW]) begin
                            icmp_buf[wptr[ICMP_BUF_AW-1:0]] <= rx_data;
                            wptr <= wptr + 1'b1;
                        end
                    end
                    //----------------------------------------------
                    // UDP载荷送应用层(字节42~IP载荷末尾)
                    //----------------------------------------------
                    if (f_ip && ip_ver_ok && ip_csum_ok && ip_dst_ok &&
                        r_ipproto == 8'h11 &&
                        rx_cnt >= 14'd42 && rx_cnt <= ip_end) begin
                        app_rx_valid <= 1'b1;
                        app_rx_sop   <= (rx_cnt == 14'd42);
                        app_rx_eop   <= (rx_cnt == ip_end);
                        app_rx_data  <= rx_data;
                    end
                    //----------------------------------------------
                    // 帧结束 : 触发ICMP回显应答
                    //----------------------------------------------
                    if (rx_eop) begin
                        rx_cnt <= 14'd0;
                        f_ip   <= 1'b0;
                        if (r_acc && f_ip && ip_ver_ok && ip_csum_ok &&
                            ip_dst_ok && r_ipproto == 8'h01 &&
                            r_ictype == 8'h08 && r_iplen >= 16'd28 &&
                            (r_iplen - 16'd28) <= (1 << ICMP_BUF_AW)) begin
                            pend_icmp_rep <= 1'b1;
                            icmp_dlen     <= r_iplen - 16'd28;
                            icmp_dst_mac  <= r_src_mac;
                            icmp_dst_ip   <= r_ipsrc;
                        end
                    end else
                        rx_cnt <= rx_cnt + 14'd1;
                end
            end
        end
    end

    // 对端UDP源端口直通输出
    assign app_rx_port = r_usport;

    //======================================================================
    // (2) ARP请求评估 : 字节41后一拍进行(等待TPA字段移位完成)
    //======================================================================
    reg         arp_eval_d;
    reg         pend_arp_rep;            // 待发送ARP应答
    reg  [47:0] rep_dst_mac;             // 应答目的MAC(请求者MAC)
    reg  [31:0] rep_dst_ip;              // 应答目的IP(请求者IP)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arp_eval_d   <= 1'b0;
            pend_arp_rep <= 1'b0;
            rep_dst_mac  <= 48'd0;
            rep_dst_ip   <= 32'd0;
        end else begin
            if (start_arp_rep)                   // 发送引擎取走ARP应答请求
                pend_arp_rep <= 1'b0;

            if (arp_eval_d) begin
                arp_eval_d <= 1'b0;
                if (r_acc && r_etype == 16'h0806 &&
                    r_aroper == 16'h0001 && r_atpa == LOCAL_IP) begin
                    pend_arp_rep <= 1'b1;        // 是针对本机IP的ARP请求
                    rep_dst_mac  <= r_asha;      // 应答给请求者
                    rep_dst_ip   <= r_aspa;
                end
            end else if (rx_valid && rx_sop)
                arp_eval_d <= 1'b0;
            else if (rx_valid && rx_cnt == 14'd41)
                arp_eval_d <= 1'b1;
        end
    end

    //======================================================================
    // (3) 对端MAC学习 : 从ARP报文和来自PEER_IP的IP报文中提取
    //======================================================================
    reg  [47:0] peer_mac_r;
    reg         peer_mac_valid_r;

    wire learn_ip = rx_valid && rx_cnt == 14'd34 && f_ip &&
                    (r_ipproto == 8'h01 || r_ipproto == 8'h11) &&
                    (r_ipsrc == PEER_IP);
    wire learn_arp = arp_eval_d && r_acc && r_etype == 16'h0806 &&
                     r_atpa == LOCAL_IP &&
                     (r_aroper == 16'h0001 || r_aroper == 16'h0002) &&
                     (r_aspa == PEER_IP);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            peer_mac_r       <= 48'd0;
            peer_mac_valid_r <= 1'b0;
        end else if (learn_arp || learn_ip) begin
            peer_mac_r       <= learn_arp ? r_asha : r_src_mac;
            peer_mac_valid_r <= 1'b1;
        end
    end

    assign peer_mac_valid = peer_mac_valid_r;

    //======================================================================
    // (4) TX发送引擎 : 优先级 ARP应答 > ICMP应答 > ARP请求 > UDP
    //======================================================================
    wire [15:0] icmp_ip_len  = 16'd28 + icmp_dlen;    // IP总长 = 20+8+数据
    wire [15:0] icmp_frm_len = 16'd42 + icmp_dlen;    // 帧长   = 14+20+8+数据
    wire [15:0] udp_len_now     = (app_tx_len == 16'd0) ? 16'd1 : app_tx_len;
    wire [15:0] udp_ip_len_now  = 16'd28 + udp_len_now;
    wire [15:0] udp_frm_len_now = 16'd42 + udp_len_now;
    wire [15:0] udp_ip_len      = 16'd28 + udp_dlen_r;

    wire start_arp_rep  = !tx_run && pend_arp_rep;
    wire start_icmp_rep = !tx_run && !pend_arp_rep && pend_icmp_rep;
    wire do_probe       = app_tx_valid && app_tx_sop &&
                          !peer_mac_valid_r && !probe_sent;
    wire do_udp         = app_tx_valid && app_tx_sop && peer_mac_valid_r;
    wire start_probe    = !tx_run && !pend_arp_rep && !pend_icmp_rep && do_probe;
    wire start_udp      = !tx_run && !pend_arp_rep && !pend_icmp_rep &&
                          !do_probe && do_udp;

    reg         tx_run;
    reg  [1:0]  tx_type;
    reg  [15:0] tx_cnt, tx_len;
    reg         probe_sent;
    reg         udp_eop_done;
    reg  [15:0] udp_dlen_r, udp_dport_r, udp_ip_csum, ip_id_tx;
    reg  [15:0] icmp_csum, icmp_ip_csum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_run   <= 1'b0;
            tx_type  <= 2'd0;
            tx_cnt   <= 16'd0;
            tx_len   <= 16'd0;
            probe_sent   <= 1'b0;
            udp_eop_done <= 1'b0;
            udp_dlen_r   <= 16'd0;
            udp_dport_r  <= 16'd0;
            udp_ip_csum  <= 16'd0;
            ip_id_tx     <= 16'd0;
            icmp_csum    <= 16'd0;
            icmp_ip_csum <= 16'd0;
        end else begin
            //----------------------------------------------
            // ARP探测只发一次, 直到学到对端MAC或应用撤回数据
            //----------------------------------------------
            if (peer_mac_valid_r)
                probe_sent <= 1'b0;
            else if (!app_tx_valid)
                probe_sent <= 1'b0;
            else if (start_probe)
                probe_sent <= 1'b1;

            if (!tx_run) begin
                if (start_arp_rep) begin
                    tx_run  <= 1'b1;
                    tx_type <= T_ARP_REP;
                    tx_cnt  <= 16'd0;
                    tx_len  <= 16'd60;
                end else if (start_icmp_rep) begin
                    tx_run       <= 1'b1;
                    tx_type      <= T_ICMP;
                    tx_cnt       <= 16'd0;
                    icmp_csum    <= csum_fold(r_icsum);   // 应答ICMP校验和
                    icmp_ip_csum <= iph_csum(icmp_ip_len, 16'd0, 8'h01,
                                             LOCAL_IP, icmp_dst_ip);
                    tx_len       <= (icmp_frm_len < 16'd60) ? 16'd60
                                                            : icmp_frm_len;
                end else if (start_probe) begin
                    tx_run  <= 1'b1;
                    tx_type <= T_ARP_REQ;
                    tx_cnt  <= 16'd0;
                    tx_len  <= 16'd60;
                end else if (start_udp) begin
                    tx_run       <= 1'b1;
                    tx_type      <= T_UDP;
                    tx_cnt       <= 16'd0;
                    udp_eop_done <= 1'b0;
                    udp_dlen_r   <= udp_len_now;
                    udp_dport_r  <= app_tx_dport;
                    ip_id_tx     <= ip_id_tx + 16'd1;
                    udp_ip_csum  <= iph_csum(udp_ip_len_now, ip_id_tx + 16'd1,
                                             8'h11, LOCAL_IP, PEER_IP);
                    tx_len       <= (udp_frm_len_now < 16'd60) ? 16'd60
                                                               : udp_frm_len_now;
                end
            end else begin
                if (tx_valid && tx_ready) begin
                    if (in_pay && !udp_eop_done && app_tx_eop)
                        udp_eop_done <= 1'b1;
                    if (tx_cnt == tx_len - 16'd1) begin
                        tx_run <= 1'b0;                  // 一帧发送完毕
                        tx_cnt <= 16'd0;
                    end else
                        tx_cnt <= tx_cnt + 16'd1;
                end
            end
        end
    end

    //======================================================================
    // (5) TX字节生成 : 按帧类型和字节序号产生输出字节
    //======================================================================
    wire [15:0] n = tx_cnt;
    wire in_pay    = (tx_type == T_UDP) && (n >= 16'd42) &&
                     (n < 16'd42 + udp_dlen_r);
    wire pay_stall = in_pay && !udp_eop_done && !app_tx_valid;

    assign tx_valid = tx_run && !pay_stall;
    assign tx_sop   = tx_valid && (n == 16'd0);
    assign tx_eop   = tx_valid && (n == tx_len - 16'd1);
    assign tx_data  = (in_pay && !udp_eop_done) ? app_tx_data : hdr_byte;
    assign app_tx_ready = tx_run && (tx_type == T_UDP);

    reg [7:0] hdr_byte;
    always @* begin
        hdr_byte = 8'h00;
        case (tx_type)
            //----------------------------------------------
            // ARP应答 : [0:5]请求者MAC [6:11]本机MAC [12:13]0x0806
            //           HTYPE=1 PTYPE=0x0800 HLEN=6 PLEN=4 OPER=2
            //           [22:27]本机MAC [28:31]本机IP [32:37]请求者MAC
            //           [38:41]请求者IP [42:59]补0
            //----------------------------------------------
            T_ARP_REP: begin
                case (n)
                    16'd0,16'd1,16'd2,16'd3,16'd4,16'd5 :
                        hdr_byte = mac_b(rep_dst_mac, n);
                    16'd6,16'd7,16'd8,16'd9,16'd10,16'd11 :
                        hdr_byte = mac_b(LOCAL_MAC, n - 16'd6);
                    16'd12 : hdr_byte = 8'h08;
                    16'd13 : hdr_byte = 8'h06;
                    16'd14 : hdr_byte = 8'h00;
                    16'd15 : hdr_byte = 8'h01;
                    16'd16 : hdr_byte = 8'h08;
                    16'd17 : hdr_byte = 8'h00;
                    16'd18 : hdr_byte = 8'h06;
                    16'd19 : hdr_byte = 8'h04;
                    16'd20 : hdr_byte = 8'h00;
                    16'd21 : hdr_byte = 8'h02;
                    16'd22,16'd23,16'd24,16'd25,16'd26,16'd27 :
                        hdr_byte = mac_b(LOCAL_MAC, n - 16'd22);
                    16'd28,16'd29,16'd30,16'd31 :
                        hdr_byte = ip_b(LOCAL_IP, n - 16'd28);
                    16'd32,16'd33,16'd34,16'd35,16'd36,16'd37 :
                        hdr_byte = mac_b(rep_dst_mac, n - 16'd32);
                    16'd38,16'd39,16'd40,16'd41 :
                        hdr_byte = ip_b(rep_dst_ip, n - 16'd38);
                    default : hdr_byte = 8'h00;
                endcase
            end
            //----------------------------------------------
            // ARP请求 : 广播帧, 询问PEER_IP的MAC地址
            //----------------------------------------------
            T_ARP_REQ: begin
                case (n)
                    16'd0,16'd1,16'd2,16'd3,16'd4,16'd5 :
                        hdr_byte = 8'hFF;
                    16'd6,16'd7,16'd8,16'd9,16'd10,16'd11 :
                        hdr_byte = mac_b(LOCAL_MAC, n - 16'd6);
                    16'd12 : hdr_byte = 8'h08;
                    16'd13 : hdr_byte = 8'h06;
                    16'd14 : hdr_byte = 8'h00;
                    16'd15 : hdr_byte = 8'h01;
                    16'd16 : hdr_byte = 8'h08;
                    16'd17 : hdr_byte = 8'h00;
                    16'd18 : hdr_byte = 8'h06;
                    16'd19 : hdr_byte = 8'h04;
                    16'd20 : hdr_byte = 8'h00;
                    16'd21 : hdr_byte = 8'h01;
                    16'd22,16'd23,16'd24,16'd25,16'd26,16'd27 :
                        hdr_byte = mac_b(LOCAL_MAC, n - 16'd22);
                    16'd28,16'd29,16'd30,16'd31 :
                        hdr_byte = ip_b(LOCAL_IP, n - 16'd28);
                    16'd32,16'd33,16'd34,16'd35,16'd36,16'd37 :
                        hdr_byte = 8'h00;            // THA未知, 填0
                    16'd38,16'd39,16'd40,16'd41 :
                        hdr_byte = ip_b(PEER_IP, n - 16'd38);
                    default : hdr_byte = 8'h00;
                endcase
            end
            //----------------------------------------------
            // ICMP回显应答 : 类型0/码0, ID与序号原样返回,
            //                数据从RAM读回, 校验和只累加ID/序号/数据
            //----------------------------------------------
            T_ICMP: begin
                case (n)
                    16'd0,16'd1,16'd2,16'd3,16'd4,16'd5 :
                        hdr_byte = mac_b(icmp_dst_mac, n);
                    16'd6,16'd7,16'd8,16'd9,16'd10,16'd11 :
                        hdr_byte = mac_b(LOCAL_MAC, n - 16'd6);
                    16'd12 : hdr_byte = 8'h08;
                    16'd13 : hdr_byte = 8'h00;
                    16'd14 : hdr_byte = 8'h45;
                    16'd15 : hdr_byte = 8'h00;
                    16'd16,16'd17 :
                        hdr_byte = w16_b(icmp_ip_len, n - 16'd16);
                    16'd18,16'd19 :
                        hdr_byte = w16_b(16'h0000, n - 16'd18);
                    16'd20 : hdr_byte = 8'h40;
                    16'd21 : hdr_byte = 8'h00;
                    16'd22 : hdr_byte = 8'h40;
                    16'd23 : hdr_byte = 8'h01;
                    16'd24,16'd25 :
                        hdr_byte = w16_b(icmp_ip_csum, n - 16'd24);
                    16'd26,16'd27,16'd28,16'd29 :
                        hdr_byte = ip_b(LOCAL_IP, n - 16'd26);
                    16'd30,16'd31,16'd32,16'd33 :
                        hdr_byte = ip_b(icmp_dst_ip, n - 16'd30);
                    16'd34 : hdr_byte = 8'h00;       // 类型0 = 回显应答
                    16'd35 : hdr_byte = 8'h00;
                    16'd36,16'd37 :
                        hdr_byte = w16_b(icmp_csum, n - 16'd36);
                    16'd38,16'd39 :
                        hdr_byte = w16_b(r_icid, n - 16'd38);
                    16'd40,16'd41 :
                        hdr_byte = w16_b(r_icseq, n - 16'd40);
                    default :
                        if (n >= 16'd42 && n < 16'd42 + icmp_dlen)
                            hdr_byte = icmp_buf[n - 16'd42];
                endcase
            end
            //----------------------------------------------
            // UDP发送 : 目的为PEER_IP/已学习MAC, UDP校验和填0(合法)
            //----------------------------------------------
            T_UDP: begin
                case (n)
                    16'd0,16'd1,16'd2,16'd3,16'd4,16'd5 :
                        hdr_byte = mac_b(peer_mac_r, n);
                    16'd6,16'd7,16'd8,16'd9,16'd10,16'd11 :
                        hdr_byte = mac_b(LOCAL_MAC, n - 16'd6);
                    16'd12 : hdr_byte = 8'h08;
                    16'd13 : hdr_byte = 8'h00;
                    16'd14 : hdr_byte = 8'h45;
                    16'd15 : hdr_byte = 8'h00;
                    16'd16,16'd17 :
                        hdr_byte = w16_b(udp_ip_len, n - 16'd16);
                    16'd18,16'd19 :
                        hdr_byte = w16_b(ip_id_tx, n - 16'd18);
                    16'd20 : hdr_byte = 8'h40;
                    16'd21 : hdr_byte = 8'h00;
                    16'd22 : hdr_byte = 8'h40;
                    16'd23 : hdr_byte = 8'h11;
                    16'd24,16'd25 :
                        hdr_byte = w16_b(udp_ip_csum, n - 16'd24);
                    16'd26,16'd27,16'd28,16'd29 :
                        hdr_byte = ip_b(LOCAL_IP, n - 16'd26);
                    16'd30,16'd31,16'd32,16'd33 :
                        hdr_byte = ip_b(PEER_IP, n - 16'd30);
                    16'd34,16'd35 :
                        hdr_byte = w16_b(LOCAL_UDP_PORT, n - 16'd34);
                    16'd36,16'd37 :
                        hdr_byte = w16_b(udp_dport_r, n - 16'd36);
                    16'd38,16'd39 :
                        hdr_byte = w16_b(16'd8 + udp_dlen_r, n - 16'd38);
                    16'd40 : hdr_byte = 8'h00;       // UDP校验和=0
                    16'd41 : hdr_byte = 8'h00;
                    default : hdr_byte = 8'h00;      // 载荷走app_tx_data
                endcase
            end
            default : hdr_byte = 8'h00;
        endcase
    end

endmodule
