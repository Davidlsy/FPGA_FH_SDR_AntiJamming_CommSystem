// =====================================================================
// tb_tx_chain_compare.sv — S4-P5 · 整链端到端位真比对 TB
//
// DUT = tx_chain_top（frame_tx → conv_enc → blk_inter → [速率适配] → qpsk_map → srrc_duc）。
// 复用 P0 框架（tb_vec_cmp）：随机帧载荷灌入，链路输出 8712 采样与 S1 全链路定点参考逐拍比对。
//
// 用例（-d 切换，默认 frame）:
//     frame  单帧随机载荷（256 字节 → 8712 采样）
//     edge   全 0 载荷端到端
//
// 激励节奏 STIM_PERIOD=9（载荷 1 字节/9 拍，满足接口规格 §4.1 的 ≥8.44 拍/字节约束）。
// NCO 固定频点 freq_word=8192（f0=fs/8，接口规格 §8）。
// DRAIN_CYCLES 留足：链路含前端突发 + 速率适配收集/放出 + DUC 拖尾。
// =====================================================================
`timescale 1ns/1ps

module tb_tx_chain_compare;

    localparam int IN_W  = 8;
    localparam int OUT_W = 32;

`ifdef TX_CHAIN_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "frame";
`endif

    localparam string STIM_FILE = {"vectors/tx_chain/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/tx_chain/", CASE_NAME, "_expect.hex"};

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic            stim_valid;
    logic [IN_W-1:0] stim_data;
    logic            dut_valid;
    logic [OUT_W-1:0] dut_data;
    int              stim_count;

    tb_vec_cmp #(
        .IN_W        (IN_W),
        .OUT_W       (OUT_W),
        .STIM_FILE   (STIM_FILE),
        .EXP_FILE    (EXP_FILE),
        .TB_NAME     ({"tb_tx_chain_", CASE_NAME}),
        .STIM_PERIOD (9),
        .DRAIN_CYCLES(256)
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    tx_chain_top u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_data (dut_data)
    );

endmodule
