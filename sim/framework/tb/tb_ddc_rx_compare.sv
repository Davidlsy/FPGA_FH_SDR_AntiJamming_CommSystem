// =====================================================================
// tb_ddc_rx_compare.sv — S5 · ddc_rx 数字下变频位真比对 TB
//
// DUT = ddc_rx（CIC 抽取 D=4 + 匹配 FIR，f_adc → 4 sps）。
// 复用 P0 框架（tb_vec_cmp）：向量灌入，DUT 输出 28 bit 一拍，
// 与 golden_ref.fixed_point.rx_modules.fixed_ddc_rx 逐采样比对。
//
// 用例（-d 切换，默认 rand）:
//     rand   2000 符号成形 → 带限上采样 ×4 到 f_adc（32128 激励拍）→ 8064 输出拍
//     edge   四星座点 + −60 dB 弱信号段（动态范围）1152 激励拍 → 320 输出拍
//
// 比对口径：
//   · SKIP_OUT=0 —— 模型与 RTL 共享复位状态（积分/梳状/FIR 延迟线全 0），
//     暂态是确定的，第 1 个输出起就应当位真一致；
//   · expect 总线 = {i[13:0], q[13:0]}（Q3.11，与导出器 pack_fields 同序）；
//   · 激励节奏 STIM_PERIOD=1（样本按 din_valid 连续计数，拍间隔不进语义）；
//   · 输出 n_dc + 32 拍（full 卷积 + 尾部 32 零样本），DRAIN_CYCLES 覆盖收尾延迟。
// =====================================================================
`timescale 1ns/1ps

module tb_ddc_rx_compare;

    localparam int IN_W  = 24;   // {i[11:0], q[11:0]}
    localparam int OUT_W = 28;   // {i[13:0], q[13:0]}

`ifdef DDC_RX_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "rand";
`endif

    localparam string STIM_FILE = {"vectors/ddc_rx/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/ddc_rx/", CASE_NAME, "_expect.hex"};

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
        .TB_NAME     ({"tb_ddc_rx_", CASE_NAME}),
        .STIM_PERIOD (1),
        .DRAIN_CYCLES(128)
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data),
        .stim_count(stim_count)
    );

    ddc_rx u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_data (dut_data)
    );

endmodule
