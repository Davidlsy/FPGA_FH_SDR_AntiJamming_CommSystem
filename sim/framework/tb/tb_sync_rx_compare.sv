// =====================================================================
// tb_sync_rx_compare.sv — S5 · sync_rx 符号级同步位真比对 TB
//
// DUT = sync_rx（Costas 载波环 + 早迟门定时 + 软解调，4 sps → 1 sps）。
// 复用 P0 框架（tb_vec_cmp）：向量灌入，DUT 全部输出打包成 76 bit 一拍，
// 与 golden_ref.fixed_point.rx_modules.fixed_sync_rx_hw 逐符号比对。
//
// 用例（-d 切换，默认 rand）:
//     rand   600 QPSK 符号无损伤基线（成形+匹配滤波，2464 采样）
//     freq   +1 kHz 频偏 + 0.7 rad 相偏
//     rate   ±750 ppm 符号率偏差双段（mu 扫过近 ±2 采样，抽头窗 j0 全取值）
//     edge   数值边界：全 0 / 满幅交替 / 舍入 tie / 量化死区 / 中幅随机
//
// 比对口径：
//   · SKIP_OUT=0 —— golden 模型与 RTL 共享复位状态（phase/freq/mu/dt = 0），
//     暂态是确定的，从第 1 个符号起就应当位真一致；"收敛后再比"是判解调对错
//     的口径（s5_rx_interface.md §6 第 3 条），不是位真比对的口径；
//   · expect 总线 = {sym_i[13:0], sym_q[13:0], soft_i[7:0], soft_q[7:0],
//     pe[15:0], te[15:0]}：环路状态走岔时 pe/te 会先于符号暴露；
//   · 激励节奏 STIM_PERIOD=1（样本按 din_valid 连续计数，拍间隔不进语义）。
// =====================================================================
`timescale 1ns/1ps

module tb_sync_rx_compare;

    localparam int IN_W  = 28;   // {i_in[13:0], q_in[13:0]}
    localparam int OUT_W = 76;   // {sym_i, sym_q, soft_i, soft_q, pe, te}

`ifdef SYNC_RX_CASE_FREQ
    localparam string CASE_NAME = "freq";
`elsif SYNC_RX_CASE_RATE
    localparam string CASE_NAME = "rate";
`elsif SYNC_RX_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "rand";
`endif

    localparam string STIM_FILE = {"vectors/sync_rx/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/sync_rx/", CASE_NAME, "_expect.hex"};

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    logic             stim_valid;
    logic [IN_W-1:0]  stim_data;
    logic             dut_valid;
    logic [OUT_W-1:0] dut_data;
    int               stim_count;

    logic [27:0] sym_data;
    logic [7:0]  soft_i, soft_q;
    logic [15:0] phase_err, timing_err;

    tb_vec_cmp #(
        .IN_W        (IN_W),
        .OUT_W       (OUT_W),
        .STIM_FILE   (STIM_FILE),
        .EXP_FILE    (EXP_FILE),
        .TB_NAME     ({"tb_sync_rx_", CASE_NAME}),
        .STIM_PERIOD (1),
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

    sync_rx u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .din_valid  (stim_valid),
        .din_data   (stim_data),
        .dout_valid (dut_valid),
        .dout_data  (sym_data),
        .dout_soft_i(soft_i),
        .dout_soft_q(soft_q),
        .phase_err  (phase_err),
        .timing_err (timing_err)
    );

    // 全部输出打包成一拍（高位在前，与 export_vectors 的 pack_fields 同序）
    assign dut_data = {sym_data, soft_i, soft_q, phase_err, timing_err};

endmodule
