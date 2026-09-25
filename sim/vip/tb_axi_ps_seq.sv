// =====================================================================
// tb_axi_ps_seq.sv — S2 PS/PL 协同仿真环境 · PS 侧软件序列 TB
//
// 在 xsim 里用 AXI VIP 的 **master agent** 执行一段 PS 侧软件序列，逐项自检：
//   1) 上电初始化：轮询 STATUS.pl_ready 直到就绪（带超时）
//   2) 复位值表：逐个读 10 个寄存器核对复位值；并确认 PL 上报在动
//   3) 通用读写：SCRATCH 写-回读（含全 1 / 全 0 边界）
//   4) 只读保护：向 RO 寄存器写，值不得被改动，且仍回 OKAY
//   5) 未映射地址：读/写均须回 DECERR（不能挂死、不能静默成功）
//   6) 控制序列：使能跳频 → 同步锁定 → 改 HOP_RATE → 跳频速率即时变化 → 关闭归零
//   7) 控制字回显：写 BLK_VER 后立即在 STATUS 高位看到
//
// 依赖：build_axi_vip.tcl 生成的 IP（axi_vip_mst + axi_vip_mst_pkg）。
// agent 绑定路径 = u_vip.inst.IF（wrapper 内部实例名为 inst）；若写错，VIP 会打印
// 「Xilinx AXI VIP Found at Path: ...」提示正确路径，据此修正。
//
// 判据：全部 check 通过 → 打印 [VIP-RESULT] ... status=PASS 并 $finish；
//       有任一项失败 → status=FAIL 并 $fatal 退出，便于脚本卡闸门。
// =====================================================================
`timescale 1ns/1ps

import axi_vip_pkg::*;
import axi_vip_mst_pkg::*;

module tb_axi_ps_seq;

    // ---------------- 寄存器偏移（与 axi_regs_demo.sv 一致） ----------------
    localparam xil_axi_ulong REG_CTRL      = 'h00;
    localparam xil_axi_ulong REG_STATUS    = 'h04;
    localparam xil_axi_ulong REG_HOP_RATE  = 'h08;
    localparam xil_axi_ulong REG_FREQ_WORD = 'h0C;
    localparam xil_axi_ulong REG_GAIN      = 'h10;
    localparam xil_axi_ulong REG_BLK_VER   = 'h14;
    localparam xil_axi_ulong REG_BER_CNT   = 'h18;
    localparam xil_axi_ulong REG_RSSI      = 'h1C;
    localparam xil_axi_ulong REG_SCRATCH   = 'h20;
    localparam xil_axi_ulong REG_ID        = 'h24;
    localparam xil_axi_ulong REG_UNMAPPED  = 'h40;

    localparam bit [31:0] ID_VALUE = 32'h4648_5353;   // "FHSS"

    // ---------------- 时钟与复位 ----------------
    bit aclk    = 1'b0;
    bit aresetn = 1'b0;
    always #5 aclk = ~aclk;

    // ---------------- VIP ↔ 示例从端 ----------------
    wire [31:0] m_awaddr;
    wire [2:0]  m_awprot;
    wire        m_awvalid, m_awready;
    wire [31:0] m_wdata;
    wire [3:0]  m_wstrb;
    wire        m_wvalid, m_wready;
    wire [1:0]  m_bresp;
    wire        m_bvalid, m_bready;
    wire [31:0] m_araddr;
    wire [2:0]  m_arprot;
    wire        m_arvalid, m_arready;
    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rvalid, m_rready;

    axi_vip_mst u_vip (
        .aclk(aclk),
        .aresetn(aresetn),
        .m_axi_awaddr(m_awaddr), .m_axi_awprot(m_awprot),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_araddr(m_araddr), .m_axi_arprot(m_arprot),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    axi_regs_demo u_dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awaddr(m_awaddr), .s_axi_awprot(m_awprot),
        .s_axi_awvalid(m_awvalid), .s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata), .s_axi_wstrb(m_wstrb),
        .s_axi_wvalid(m_wvalid), .s_axi_wready(m_wready),
        .s_axi_bresp(m_bresp), .s_axi_bvalid(m_bvalid), .s_axi_bready(m_bready),
        .s_axi_araddr(m_araddr), .s_axi_arprot(m_arprot),
        .s_axi_arvalid(m_arvalid), .s_axi_arready(m_arready),
        .s_axi_rdata(m_rdata), .s_axi_rresp(m_rresp),
        .s_axi_rvalid(m_rvalid), .s_axi_rready(m_rready),
        .pl_ready(), .hopping_active(), .sync_locked(), .hop_count()
    );

    // ---------------- VIP master agent ----------------
    axi_vip_mst_mst_t mst_agent;
    xil_axi_prot_t    prot = 3'b000;

    int chk_cnt = 0;
    int err_cnt = 0;

    function automatic string resp_name(input xil_axi_resp_t r);
        case (r)
            XIL_AXI_RESP_OKAY  : return "OKAY";
            XIL_AXI_RESP_EXOKAY: return "EXOKAY";
            XIL_AXI_RESP_SLVERR: return "SLVERR";
            XIL_AXI_RESP_DECERR: return "DECERR";
            default            : return "UNKNOWN";
        endcase
    endfunction

    task automatic check(input string name, input logic ok, input string detail);
        begin
            chk_cnt = chk_cnt + 1;
            if (!ok) err_cnt = err_cnt + 1;
            $display("[VIP-CHK] %s %0s  %s", ok ? "PASS" : "FAIL", name, detail);
        end
    endtask

    task automatic wr_reg(input xil_axi_ulong addr, input bit [31:0] data,
                          output xil_axi_resp_t resp);
        bit [63:0] d64;
        begin
            d64 = {32'h0, data};
            mst_agent.AXI4LITE_WRITE_BURST(addr, prot, d64, resp);
        end
    endtask

    task automatic rd_reg(input xil_axi_ulong addr, output bit [31:0] data,
                          output xil_axi_resp_t resp);
        bit [63:0] d64;
        begin
            mst_agent.AXI4LITE_READ_BURST(addr, prot, d64, resp);
            data = d64[31:0];
        end
    endtask

    // 在固定的时钟窗内数跳频次数（读事务本身占几拍，故窗略长于 cycles）
    task automatic measure_hops(input int cycles, output int hops);
        bit [31:0] s0, s1;
        xil_axi_resp_t r0, r1;
        begin
            rd_reg(REG_STATUS, s0, r0);
            repeat (cycles) @(posedge aclk);
            rd_reg(REG_STATUS, s1, r1);
            hops = int'((s1[15:8] - s0[15:8]) & 8'hFF);
        end
    endtask

    // ---------------- 全局看门狗 ----------------
    initial begin
        #2ms;
        $display("[VIP-RESULT] tb=tb_axi_ps_seq checks=%0d errors=%0d status=FAIL note=watchdog_timeout",
                 chk_cnt, err_cnt + 1);
        $fatal(1, "[VIP] 全局看门狗超时：AXI 事务未在 2 ms 内完成");
    end

    // ---------------- PS 侧软件序列 ----------------
    initial begin : PS_SOFTWARE_SEQUENCE
        bit [31:0] v, v0, v1;
        xil_axi_resp_t resp;
        logic ok;
        int polls, hops_slow, hops_fast;

        repeat (10) @(posedge aclk);
        aresetn = 1'b1;

        // agent 绑定到 VIP 接口（wrapper 内部实例名为 inst）
        mst_agent = new("ps_master_agent", u_vip.inst.IF);
        mst_agent.start_master();

        $display("[VIP] ---- 1) 上电初始化：轮询 pl_ready ----");
        ok = 1'b0; polls = 0;
        for (int i = 0; i < 200 && !ok; i++) begin
            rd_reg(REG_STATUS, v, resp);
            if (resp == XIL_AXI_RESP_OKAY && v[0] == 1'b1) begin
                ok = 1'b1; polls = i + 1;
            end
        end
        check("boot_poll_pl_ready", ok, $sformatf("轮询 %0d 次后 STATUS.pl_ready=1", polls));

        $display("[VIP] ---- 2) 复位值表 ----");
        rd_reg(REG_CTRL, v, resp);
        check("rst_ctrl", v == 32'h0 && resp == XIL_AXI_RESP_OKAY, $sformatf("CTRL=0x%08h", v));
        rd_reg(REG_HOP_RATE, v, resp);
        check("rst_hop_rate", v == 32'd100, $sformatf("HOP_RATE=%0d", v));
        rd_reg(REG_FREQ_WORD, v, resp);
        check("rst_freq_word", v == 32'h0, $sformatf("FREQ_WORD=0x%08h", v));
        rd_reg(REG_GAIN, v, resp);
        check("rst_gain", v == 32'd32, $sformatf("GAIN=%0d", v));
        rd_reg(REG_BLK_VER, v, resp);
        check("rst_blk_ver", v == 32'h0, $sformatf("BLK_VER=0x%08h", v));
        rd_reg(REG_SCRATCH, v, resp);
        check("rst_scratch", v == 32'h0, $sformatf("SCRATCH=0x%08h", v));
        rd_reg(REG_ID, v, resp);
        check("rst_id", v == ID_VALUE, $sformatf("ID=0x%08h（\"FHSS\"）", v));
        rd_reg(REG_STATUS, v, resp);
        check("rst_status", v == 32'h0000_0001, $sformatf("STATUS=0x%08h（仅 pl_ready 置位）", v));

        rd_reg(REG_BER_CNT, v0, resp);
        rd_reg(REG_RSSI, v1, resp);
        check("pl_status_alive", (v0 < 32'h1000) && (v1 >= 32'h400) && (v1 <= 32'h4FF),
              $sformatf("BER=%0d RSSI=0x%03h（自由计数器应在合理范围）", v0, v1[11:0]));
        repeat (200) @(posedge aclk);
        rd_reg(REG_BER_CNT, v1, resp);
        check("pl_status_moving", v1 > v0, $sformatf("BER %0d → %0d（PL 上报在动）", v0, v1));

        $display("[VIP] ---- 3) 通用读写 SCRATCH ----");
        wr_reg(REG_SCRATCH, 32'hA5A5_1234, resp);
        check("scratch_wr_resp", resp == XIL_AXI_RESP_OKAY, $sformatf("写响应 %s", resp_name(resp)));
        rd_reg(REG_SCRATCH, v, resp);
        check("scratch_rb", v == 32'hA5A5_1234, $sformatf("回读 0x%08h", v));
        wr_reg(REG_SCRATCH, 32'hFFFF_FFFF, resp);
        rd_reg(REG_SCRATCH, v, resp);
        check("scratch_all_ones", v == 32'hFFFF_FFFF, $sformatf("全 1 回读 0x%08h", v));
        wr_reg(REG_SCRATCH, 32'h0000_0000, resp);
        rd_reg(REG_SCRATCH, v, resp);
        check("scratch_all_zeros", v == 32'h0, $sformatf("全 0 回读 0x%08h", v));

        $display("[VIP] ---- 4) 只读寄存器写保护 ----");
        rd_reg(REG_STATUS, v0, resp);
        wr_reg(REG_STATUS, 32'hDEAD_BEEF, resp);
        check("ro_status_wr_resp", resp == XIL_AXI_RESP_OKAY, $sformatf("写 RO 仍回 %s", resp_name(resp)));
        rd_reg(REG_STATUS, v1, resp);
        check("ro_status_guard", v0 == v1, $sformatf("STATUS 写前后 0x%08h → 0x%08h", v0, v1));
        rd_reg(REG_ID, v0, resp);
        wr_reg(REG_ID, 32'h0, resp);
        rd_reg(REG_ID, v1, resp);
        check("ro_id_guard", v1 == ID_VALUE, $sformatf("ID 写入后仍为 0x%08h", v1));
        wr_reg(REG_BER_CNT, 32'hFFFF_FFFF, resp);
        rd_reg(REG_BER_CNT, v1, resp);
        check("ro_ber_guard", v1 < 32'h1000, $sformatf("BER 写入后仍为 %0d（未被写成 0xFFFF）", v1));

        $display("[VIP] ---- 5) 未映射地址须回 DECERR ----");
        rd_reg(REG_UNMAPPED, v, resp);
        check("unmapped_rd_decerr", resp == XIL_AXI_RESP_DECERR,
              $sformatf("读 0x40 响应 %s", resp_name(resp)));
        wr_reg(REG_UNMAPPED, 32'h1, resp);
        check("unmapped_wr_decerr", resp == XIL_AXI_RESP_DECERR,
              $sformatf("写 0x40 响应 %s", resp_name(resp)));

        $display("[VIP] ---- 6) 控制序列：写控制字 PL 即时响应 ----");
        wr_reg(REG_HOP_RATE, 32'd200, resp);
        wr_reg(REG_CTRL, 32'h1, resp);
        ok = 1'b0;
        for (int i = 0; i < 100 && !ok; i++) begin
            rd_reg(REG_STATUS, v, resp);
            if (v[1] == 1'b1) ok = 1'b1;
        end
        check("ctrl_enable_immediate", ok, $sformatf("写 CTRL.en=1 后 STATUS.hopping_active=%0b", v[1]));

        ok = 1'b0;
        for (int i = 0; i < 4000 && !ok; i++) begin
            rd_reg(REG_STATUS, v, resp);
            if (v[2] == 1'b1) ok = 1'b1;
        end
        check("ctrl_sync_locked", ok, $sformatf("HOP_RATE=200 下第 2 跳后 sync_locked=%0b", v[2]));

        measure_hops(2000, hops_slow);
        check("hop_rate_slow", hops_slow >= 5 && hops_slow <= 15,
              $sformatf("HOP_RATE=200 时 2000 拍内跳 %0d 次（期望 ~10）", hops_slow));

        wr_reg(REG_HOP_RATE, 32'd20, resp);
        measure_hops(2000, hops_fast);
        check("hop_rate_fast", hops_fast >= 70 && hops_fast <= 130,
              $sformatf("改 HOP_RATE=20 后 2000 拍内跳 %0d 次（期望 ~100）", hops_fast));
        check("hop_rate_immediate", hops_fast > hops_slow * 5,
              $sformatf("改控制字即时生效：%0d → %0d 次（≥5 倍）", hops_slow, hops_fast));

        wr_reg(REG_BLK_VER, 32'hA5, resp);
        rd_reg(REG_STATUS, v, resp);
        check("blk_ver_echo", v[23:16] == 8'hA5,
              $sformatf("写 BLK_VER=0xA5 后 STATUS[23:16]=0x%02h", v[23:16]));

        wr_reg(REG_CTRL, 32'h0, resp);
        repeat (4) @(posedge aclk);
        rd_reg(REG_STATUS, v, resp);
        check("ctrl_disable_resets", v[1] == 1'b0 && v[2] == 1'b0 && v[15:8] == 8'h0,
              $sformatf("关闭后 STATUS=0x%08h（hopping/locked/hop_count 归零）", v));

        $display("[VIP-RESULT] tb=tb_axi_ps_seq checks=%0d errors=%0d status=%s",
                 chk_cnt, err_cnt, err_cnt == 0 ? "PASS" : "FAIL");
        if (err_cnt == 0) begin
            $display("[VIP] *** PS/PL 协同仿真环境自检通过 ***");
            $finish;
        end else begin
            $display("[VIP] *** 自检失败：%0d/%0d 项未达预期 ***", err_cnt, chk_cnt);
            $fatal(1, "[VIP] tb_axi_ps_seq FAIL");
        end
    end

endmodule
