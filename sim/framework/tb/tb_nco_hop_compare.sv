// =====================================================================
// tb_nco_hop_compare.sv — S6 · nco_hop 跳频 NCO 位真比对 TB
//
// DUT = nco_hop（信道 → FTW 查表 + 相位连续 NCO）。
// 复用 P0 框架（tb_vec_cmp）：逐拍灌 {din_valid, hop_valid, channel} 命令流，
// DUT 每个 din_valid 拍吐 {phase, cos, sin}，与 golden_ref.fixed_point.nco_hop
// 逐拍比对。
//
// 用例（-d 切换，默认 seq）:
//     seq    16 信道顺序轮转，每跳 8 拍（2048 拍，扫全 FTW 表）
//     rand   随机信道 + 随机跳间隔 1..16 拍 + 随机 din_valid 空隙
//     edge   每拍一跳（min 间隔）/ 长稳态（64 拍）/ 同信道连跳 / 信道 0/15 边界
//
// 比对口径（docs/spec/s6_fh_interface.md §5.3/§5.4）:
//   · SKIP_OUT=0 —— 复位即确定（phase=0, ftw=0），第 1 拍起位真一致；
//   · stim 总线 = {din_valid, hop_valid, channel[3:0]}（6 bit，高位在前），
//     DUT.din_valid = stim_valid && stim_data[5]：din_valid 是数据位（可表达冻结拍），
//     但送完向量后 tb_vec_cmp 保持末行数据，须用 stim_valid 门控防续吐；
//   · expect 总线 = {phase[15:0], cos[15:0], sin[15:0]}（48 bit，高位在前）；
//   · 拍数账本 1:1（valid 对齐，寄存 1 拍不影响比对）；STIM_PERIOD=1；
//   · din_valid=0 的拍 DUT 无输出 → 长度解耦（stim 行数 ≥ expect 行数）。
// =====================================================================
`timescale 1ns/1ps

module tb_nco_hop_compare;

    localparam int IN_W  = 6;    // {din_valid, hop_valid, channel[3:0]}
    localparam int OUT_W = 48;   // {phase[15:0], cos[15:0], sin[15:0]}

`ifdef NCO_HOP_CASE_RAND
    localparam string CASE_NAME = "rand";
`elsif NCO_HOP_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "seq";
`endif

    localparam string STIM_FILE = {"vectors/nco_hop/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/nco_hop/", CASE_NAME, "_expect.hex"};

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
        .TB_NAME     ({"tb_nco_hop_", CASE_NAME}),
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

    nco_hop u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .din_valid   (stim_valid && stim_data[5]),
        .din_hop_valid(stim_data[4]),
        .din_channel (stim_data[3:0]),
        .dout_valid  (dut_valid),
        .dout_phase  (dut_data[47:32]),
        .dout_cos    (dut_data[31:16]),
        .dout_sin    (dut_data[15:0])
    );

endmodule
