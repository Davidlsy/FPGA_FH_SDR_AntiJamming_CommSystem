// =====================================================================
// axi_regs_demo.sv — S2 PS/PL 协同仿真环境 · 示例寄存器从端
//
// **这是环境的示例 DUT，不是设计交付物**：S9 会用真正的 axi_regs（含完整寄存器
// 映射表）替换它。保留它是因为 PS 侧协同仿真环境需要一个可被 PS 读写、且行为可
// 验证的 PL 端；这里刻意把寄存器映射做成 FHSS 控制面的形状（控制字/状态字/跳频
// 速率/黑名单版本），使 S9 换表时拓扑不变。
//
// AXI4-Lite 从端特性：
//   · AW 与 W 分两拍接收（合规且简单），B/R 各一拍
//   · 支持字节选通 WSTRB（未选中的字节保持原值）
//   · 只读寄存器忽略写、照常回 OKAY
//   · 未映射地址（高 24 位非零，或字偏移 > REG_ID）回 DECERR
//
// 寄存器映射（字节偏移，字索引 = addr[7:2]）：
//   0x00 CTRL      RW  0x0000_0000  bit0 使能跳频, bit1 软复位(自清), bit3:2 保留
//   0x04 STATUS    RO  —           bit0 pl_ready, bit1 hopping_active, bit2 sync_locked,
//                                  bit15:8 hop_count, bit23:16 黑名单版本
//   0x08 HOP_RATE  RW  0x0000_0064 跳频周期（拍），0 表示不跳
//   0x0C FREQ_WORD RW  0x0000_0000 频率控制字（示意，闭环由跳频层接手）
//   0x10 GAIN      RW  0x0000_0020 射频增益码
//   0x14 BLK_VER   RW  0x0000_0000 黑名单版本（写后 STATUS[23:16] 立即跟随）
//   0x18 BER_CNT   RO  —           自由计数器（示意 PL 上报）
//   0x1C RSSI      RO  —           自由计数器（示意 PL 上报）
//   0x20 SCRATCH   RW  0x0000_0000 通用回读
//   0x24 ID        RO  0x4648_5353 "FHSS"
// =====================================================================
`timescale 1ns/1ps

module axi_regs_demo #(
    parameter int C_S_AXI_ADDR_WIDTH = 32,
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int PL_READY_CYCLES    = 64
) (
    input  logic                        aclk,
    input  logic                        aresetn,

    // AXI4-Lite 从端
    input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [2:0]                  s_axi_awprot,
    input  logic                        s_axi_awvalid,
    output logic                        s_axi_awready,
    input  logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  logic                        s_axi_wvalid,
    output logic                        s_axi_wready,
    output logic [1:0]                  s_axi_bresp,
    output logic                        s_axi_bvalid,
    input  logic                        s_axi_bready,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [2:0]                  s_axi_arprot,
    input  logic                        s_axi_arvalid,
    output logic                        s_axi_arready,
    output logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output logic [1:0]                  s_axi_rresp,
    output logic                        s_axi_rvalid,
    input  logic                        s_axi_rready,

    // PL 侧观测口（供顶层观察，不影响 AXI 行为）
    output logic       pl_ready,
    output logic       hopping_active,
    output logic       sync_locked,
    output logic [7:0] hop_count
);

    // ---------------- 寄存器字索引（== addr[7:2]） ----------------
    localparam logic [5:0] REG_CTRL      = 6'd0;
    localparam logic [5:0] REG_STATUS    = 6'd1;
    localparam logic [5:0] REG_HOP_RATE  = 6'd2;
    localparam logic [5:0] REG_FREQ_WORD = 6'd3;
    localparam logic [5:0] REG_GAIN      = 6'd4;
    localparam logic [5:0] REG_BLK_VER   = 6'd5;
    localparam logic [5:0] REG_BER_CNT   = 6'd6;
    localparam logic [5:0] REG_RSSI      = 6'd7;
    localparam logic [5:0] REG_SCRATCH   = 6'd8;
    localparam logic [5:0] REG_ID        = 6'd9;

    localparam logic [31:0] ID_VALUE     = 32'h4648_5353;   // "FHSS"

    function automatic logic addr_mapped(input logic [31:0] addr);
        return (addr[31:8] == 24'h0) && (addr[7:2] <= REG_ID);
    endfunction

    function automatic logic [31:0] merge_strb(input logic [31:0] old_v,
                                              input logic [31:0] new_v,
                                              input logic [3:0]  strb);
        logic [31:0] r;
        for (int b = 0; b < 4; b++) r[8*b +: 8] = strb[b] ? new_v[8*b +: 8] : old_v[8*b +: 8];
        return r;
    endfunction

    // ---------------- 可写寄存器 ----------------
    logic [31:0] reg_ctrl, reg_hop_rate, reg_freq_word, reg_gain, reg_blk_ver, reg_scratch;

    // ---------------- PL 侧行为状态 ----------------
    logic [31:0] cyc_q;
    logic        pl_ready_q;
    logic [31:0] hop_div_q;
    logic [7:0]  hop_cnt_q;
    logic        sync_locked_q;
    logic [15:0] ber_cnt_q;
    logic [31:0] rssi_q;

    assign pl_ready       = pl_ready_q;
    assign hopping_active = reg_ctrl[0];
    assign sync_locked    = sync_locked_q;
    assign hop_count      = hop_cnt_q;

    // ---------------- PL 行为模型（示意） ----------------
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cyc_q        <= 32'd0;
            pl_ready_q   <= 1'b0;
            hop_div_q    <= 32'd0;
            hop_cnt_q    <= 8'd0;
            sync_locked_q<= 1'b0;
            ber_cnt_q    <= 16'd0;
            rssi_q       <= 32'h0000_0400;
        end else begin
            cyc_q <= cyc_q + 32'd1;
            if (cyc_q >= PL_READY_CYCLES) pl_ready_q <= 1'b1;

            if (reg_ctrl[0]) begin
                // 使能跳频：每 HOP_RATE 拍跳一次，第 2 跳后报同步锁定
                if (reg_hop_rate == 32'd0)
                    hop_div_q <= 32'd0;
                else if (hop_div_q + 32'd1 >= reg_hop_rate) begin
                    hop_div_q <= 32'd0;
                    hop_cnt_q <= hop_cnt_q + 8'd1;
                    if (hop_cnt_q >= 8'd1) sync_locked_q <= 1'b1;
                end else
                    hop_div_q <= hop_div_q + 32'd1;
            end else begin
                hop_div_q     <= 32'd0;
                hop_cnt_q     <= 8'd0;
                sync_locked_q <= 1'b0;
            end

            // 状态上报在动：BER 慢速累加、RSSI 带偏置自由计数
            if (cyc_q[4:0] == 5'd0) ber_cnt_q <= ber_cnt_q + 16'd3;
            rssi_q <= 32'h0000_0400 + {24'h0, cyc_q[7:0]};
        end
    end

    // ---------------- 读数据 ----------------
    function automatic logic [31:0] read_reg(input logic [5:0] idx);
        case (idx)
            REG_CTRL      : return {28'h0, reg_ctrl[3:0]};
            REG_STATUS    : return {8'h00, reg_blk_ver[7:0], hop_cnt_q, 5'b0,
                                    sync_locked_q, reg_ctrl[0], pl_ready_q};
            REG_HOP_RATE  : return reg_hop_rate;
            REG_FREQ_WORD : return reg_freq_word;
            REG_GAIN      : return reg_gain;
            REG_BLK_VER   : return {24'h0, reg_blk_ver[7:0]};
            REG_BER_CNT   : return {16'h0, ber_cnt_q};
            REG_RSSI      : return rssi_q;
            REG_SCRATCH   : return reg_scratch;
            REG_ID        : return ID_VALUE;
            default       : return 32'h0;
        endcase
    endfunction

    // ---------------- 写通道 FSM：AW → W → B ----------------
    localparam logic [1:0] W_AW = 2'd0, W_W = 2'd1, W_B = 2'd2;

    logic [1:0]  wstate_q;
    logic [31:0] awaddr_q, wdata_q;
    logic [3:0]  wstrb_q;
    logic        bad_addr_q;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wstate_q   <= W_AW;
            awaddr_q   <= 32'd0;
            wdata_q    <= 32'd0;
            wstrb_q    <= 4'd0;
            bad_addr_q <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;

            reg_ctrl      <= 32'd0;
            reg_hop_rate  <= 32'd100;
            reg_freq_word <= 32'd0;
            reg_gain      <= 32'd32;
            reg_blk_ver   <= 32'd0;
            reg_scratch   <= 32'd0;
        end else begin
            case (wstate_q)
                W_AW: begin
                    if (s_axi_awvalid) begin
                        awaddr_q   <= s_axi_awaddr;
                        bad_addr_q <= !addr_mapped(s_axi_awaddr);
                        wstate_q   <= W_W;
                    end
                end
                W_W: begin
                    if (s_axi_wvalid) begin
                        wdata_q <= s_axi_wdata;
                        wstrb_q <= s_axi_wstrb;
                        if (!bad_addr_q) begin
                            case (awaddr_q[7:2])
                                REG_CTRL: begin
                                    // 只有 bit3:0 有意义；bit1 软复位自清
                                    reg_ctrl    <= merge_strb(reg_ctrl, s_axi_wdata, s_axi_wstrb) & 32'h0000_000F;
                                    reg_ctrl[1] <= 1'b0;
                                end
                                REG_HOP_RATE  : reg_hop_rate  <= merge_strb(reg_hop_rate,  s_axi_wdata, s_axi_wstrb);
                                REG_FREQ_WORD : reg_freq_word <= merge_strb(reg_freq_word, s_axi_wdata, s_axi_wstrb);
                                REG_GAIN      : reg_gain      <= merge_strb(reg_gain,      s_axi_wdata, s_axi_wstrb);
                                REG_BLK_VER   : reg_blk_ver   <= merge_strb(reg_blk_ver,   s_axi_wdata, s_axi_wstrb);
                                REG_SCRATCH   : reg_scratch   <= merge_strb(reg_scratch,   s_axi_wdata, s_axi_wstrb);
                                default: ;                       // 只读寄存器：忽略写
                            endcase
                        end
                        s_axi_bvalid <= 1'b1;
                        s_axi_bresp  <= bad_addr_q ? 2'b11 : 2'b00;   // DECERR / OKAY
                        wstate_q     <= W_B;
                    end
                end
                W_B: begin
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wstate_q     <= W_AW;
                    end
                end
                default: wstate_q <= W_AW;
            endcase
        end
    end

    assign s_axi_awready = (wstate_q == W_AW);
    assign s_axi_wready  = (wstate_q == W_W);

    // ---------------- 读通道 FSM：AR → R ----------------
    localparam logic [1:0] R_AR = 2'd0, R_R = 2'd1;

    logic [1:0]  rstate_q;
    logic [31:0] araddr_q;
    logic        rbad_q;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rstate_q     <= R_AR;
            araddr_q     <= 32'd0;
            rbad_q       <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= 2'b00;
            s_axi_rdata  <= 32'd0;
        end else begin
            case (rstate_q)
                R_AR: begin
                    if (s_axi_arvalid) begin
                        araddr_q     <= s_axi_araddr;
                        rbad_q       <= !addr_mapped(s_axi_araddr);
                        s_axi_rdata  <= addr_mapped(s_axi_araddr) ? read_reg(s_axi_araddr[7:2]) : 32'h0;
                        s_axi_rresp  <= addr_mapped(s_axi_araddr) ? 2'b00 : 2'b11;
                        s_axi_rvalid <= 1'b1;
                        rstate_q     <= R_R;
                    end
                end
                R_R: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        rstate_q     <= R_AR;
                    end
                end
                default: rstate_q <= R_AR;
            endcase
        end
    end

    assign s_axi_arready = (rstate_q == R_AR);

endmodule
