// =====================================================================
// tb_sync_acq_compare.sv — S6 · 同步字捕获位真比对 TB
//
// DUT = sync_acq（64 bit 同步字滑动相关 + 恒虚警门限 + M/N 帧槽确认）。
// 复用 P0 框架（tb_vec_cmp）：逐拍灌 {din_valid, din_bit}，DUT 每个 din_valid 拍吐
// {hit, acq, frame_start, corr[6:0], thresh[6:0]}，与 golden_ref.fixed_point.sync_acq
// .sim_sync_acq 逐拍比对。
//
// 用例（-d 切换，默认 seq）:
//     seq    缩参帧流 24 帧×200 bit（帧 = 64 bit 同步字 + 136 bit 伪随机载荷）：
//            规则节拍开候选/槽 2 确认，acq 每 2 帧、frame_start 每帧
//     rand   随机流 + 随机注入同步字/反相同步字 + 20% din_valid 停表空隙（事件混流）
//     edge   语义边界集中处（零填窗 / hit 等号两侧 / M/N 全边界：槽 2 确认·槽 3 凑满
//            确认优先·弃候选·无粘滞重开 / 锁定期 hit 忽略不重置 timer / 伪峰吞真峰后
//            重捕 / 停表拆同步字·槽位拍前空隙）
//
// 比对口径（docs/spec/s6_fh_interface.md §8.2/§8.4）:
//   · SKIP_OUT=0 —— 复位即确定（sr=0、hist 空），第 1 拍起位真一致；
//   · stim 总线 = {din_valid, din_bit}（2 bit，高位在前），
//     DUT.din_valid = stim_valid && stim_data[1]：din_valid 是数据位（可表达停表拍），
//     但送完向量后 tb_vec_cmp 保持末行数据，须用 stim_valid 门控防续吐；
//   · expect 总线 = {hit, acq, frame_start, corr[6:0], thresh[6:0]}（17 bit，高位在前）；
//   · 拍数账本 1:1（valid 对齐，输出寄存 1 拍不影响比对）；STIM_PERIOD=1；
//   · din_valid=0 的拍 DUT 无输出 → 长度解耦（stim 行数 ≥ expect 行数）；
//   · **缩参比对**：FRAME_LEN=200（冻结 2160，§8.6 #4；与 export_vectors.SYNC_ACQ_CMP_*
//     同步冻结）。冻结 2160 一帧就占 2160 行，多帧状态机长跑装不下；相关/门限语义对
//     FRAME_LEN 无依赖、帧槽语义同构。冻结值 2160/M=2/N=3 由 tb_sync_acq_long
//     （真实参数 + 捕获延迟/无误声明断言）与 stat_sync_acq（Pd/Pfa 曲线）覆盖。
// =====================================================================
`timescale 1ns/1ps

module tb_sync_acq_compare;

    localparam int IN_W  = 2;    // {din_valid, din_bit}
    localparam int OUT_W = 17;   // {hit, acq, frame_start, corr[6:0], thresh[6:0]}

    localparam int FRAME_LEN = 200;   // 缩参（冻结 2160，见头注释）

`ifdef SYNC_ACQ_CASE_RAND
    localparam string CASE_NAME = "rand";
`elsif SYNC_ACQ_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "seq";
`endif

    localparam string STIM_FILE = {"vectors/sync_acq/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/sync_acq/", CASE_NAME, "_expect.hex"};

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
        .TB_NAME     ({"tb_sync_acq_", CASE_NAME}),
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

    sync_acq #(
        .SYNC_WORD (64'h517AE4216E7555CA),
        .FRAME_LEN (FRAME_LEN),
        .M_HIT     (2),
        .N_SLOT    (3)
    ) u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .din_valid       (stim_valid && stim_data[1]),
        .din_bit         (stim_data[0]),
        .dout_valid      (dut_valid),
        .dout_hit        (dut_data[16]),
        .dout_acq        (dut_data[15]),
        .dout_frame_start(dut_data[14]),
        .dout_corr       (dut_data[13:7]),
        .dout_thresh     (dut_data[6:0])
    );

endmodule
