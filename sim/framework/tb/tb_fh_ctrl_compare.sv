// =====================================================================
// tb_fh_ctrl_compare.sv — S6 · fh_ctrl 跳频图案位真比对 TB
//
// DUT = fh_ctrl（LFSR-16 直移，一跳 = 移位 4 拍，16 信道非重叠取字）。
// 复用 P0 框架（tb_vec_cmp）：命令流灌入，DUT 每跳吐 {hop_index, channel}，
// 与 golden_ref.fixed_point.fh_pattern.sim_fh_ctrl 逐跳比对。
//
// 用例（-d 切换，默认 seq）:
//     seq    复位默认种子连续 16384 跳（= 4×2^16 bit，LFSR 全周期平铺边界）
//     rand   随机种子重载 ×4 段 × 4096 跳（加载语义 + 多种子）
//     edge   边界种子 + 每 8 跳穿插加载（加载拍不出数 / 清 hop_index）
//
// 比对口径（docs/spec/s6_fh_interface.md §3/§4）:
//   · SKIP_OUT=0 —— 模型与 RTL 共享复位状态（SEED 参数同源），第 1 跳起位真一致；
//   · expect 总线 = {hop_index[19:0], channel[3:0]}（24 bit，高位在前）；
//   · 激励节奏 STIM_PERIOD=1（1 激励拍 = 1 命令：加载或跳）；
//   · 加载拍不出数 → N:M 长度解耦（stim 行数 = 命令数，expect 行数 = 跳数）；
//     DUT 输出寄存一拍，按各自 dout_valid 对齐不受影响；DRAIN_CYCLES=8 足够排空。
// =====================================================================
`timescale 1ns/1ps

module tb_fh_ctrl_compare;

    localparam int IN_W  = 17;   // {seed_load, seed[15:0]}
    localparam int OUT_W = 24;   // {hop_index[19:0], channel[3:0]}

`ifdef FH_CTRL_CASE_RAND
    localparam string CASE_NAME = "rand";
`elsif FH_CTRL_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "seq";
`endif

    localparam string STIM_FILE = {"vectors/fh_ctrl/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/fh_ctrl/", CASE_NAME, "_expect.hex"};

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic              stim_valid;
    logic [IN_W-1:0]   stim_data;
    logic              dut_valid;
    logic [OUT_W-1:0]  dut_data;
    int                stim_count;

    tb_vec_cmp #(
        .IN_W        (IN_W),
        .OUT_W       (OUT_W),
        .STIM_FILE   (STIM_FILE),
        .EXP_FILE    (EXP_FILE),
        .TB_NAME     ({"tb_fh_ctrl_", CASE_NAME}),
        .STIM_PERIOD (1),
        .DRAIN_CYCLES(8)
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    fh_ctrl u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .din_valid     (stim_valid),
        .din_seed_load (stim_data[16]),
        .din_seed      (stim_data[15:0]),
        .dout_valid    (dut_valid),
        .dout_hop_index(dut_data[23:4]),
        .dout_channel  (dut_data[3:0])
    );

endmodule
