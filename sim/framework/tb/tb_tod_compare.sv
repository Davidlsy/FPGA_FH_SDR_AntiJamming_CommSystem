// =====================================================================
// tb_tod_compare.sv — S6 · tod 时基位真比对 TB
//
// DUT = tod（1 ms tick + 帧头截断 TOD 外推跳沿）。
// 复用 P0 框架（tb_vec_cmp）：逐拍灌 {din_valid, rate_sel, tod_load, align_valid,
// align_tod, tod_value} 命令流，DUT 每个 din_valid 拍吐 {tick, tod, hop_edge}，
// 与 golden_ref.fixed_point.tod.sim_tod 逐拍比对。
//
// 用例（-d 切换，默认 seq）:
//     seq    装订 tod=200 后纯自然步进 288 tick：三档跳速 + rate_sel=3 兜底 +
//            8 bit 回绕（200→232 跨 256），扫全 tick 节拍与跳沿网格
//     rand   随机换挡 + 随机装订/对齐 + 20% din_valid 停表空隙（事件混流）
//     edge   停表拍携命令须忽略 / 装订=声明边界（网格·非网格）/ 装订与自然 tick
//            同拍脉冲合并 / 对齐晚检测不双发 / 早检测补发 / ±32 保持与 ±33 负例 /
//            64 窗跨窗 / 窄位宽回绕端 / 装订+对齐同拍装订优先 / 装订值高位掩码
//
// 比对口径（docs/spec/s6_fh_interface.md §7.3/§7.4）:
//   · SKIP_OUT=0 —— 复位即确定（tod=0, frac=0），第 1 拍起位真一致；
//   · stim 总线 = {din_valid, rate_sel[1:0], tod_load, align_valid,
//     align_tod[5:0], tod_value[31:0]}（43 bit，高位在前），
//     DUT.din_valid = stim_valid && stim_data[42]：din_valid 是数据位（可表达停表拍），
//     但送完向量后 tb_vec_cmp 保持末行数据，须用 stim_valid 门控防续吐；
//   · expect 总线 = {tick, tod[31:0], hop_edge}（34 bit，高位在前）；
//   · 拍数账本 1:1（valid 对齐，寄存 1 拍不影响比对）；STIM_PERIOD=1；
//   · din_valid=0 的拍 DUT 无输出 → 长度解耦（stim 行数 ≥ expect 行数）；
//   · **缩参比对**：TICK_SAMPLES=10、TOD_W=8（与 export_vectors.TOD_CMP_* 同步冻结）。
//     冻结值 8000/32 一个 tick 就占 8000 行（MAX_DEPTH=32768 装不下几个 tick），
//     且 2^32 回绕不可达；§7.4 语义对参数无依赖，缩参后 8 bit 回绕每 256 tick
//     可见（§7.1「比对口径里含窄位宽回绕自检」）。冻结值本身由 tb_tod_align_long
//     （真实 8000/32 + tick 精确性/对齐误差断言）与黄金自检 [1][5][7] 覆盖。
// =====================================================================
`timescale 1ns/1ps

module tb_tod_compare;

    localparam int IN_W  = 43;   // {din_valid, rate_sel[1:0], tod_load, align_valid, align_tod[5:0], tod_value[31:0]}
    localparam int OUT_W = 34;   // {tick, tod[31:0], hop_edge}

    localparam int TICK_SAMPLES = 10;   // 缩参（冻结 8000，见头注释）
    localparam int TOD_W        = 8;    // 缩参（冻结 32）

`ifdef TOD_CASE_RAND
    localparam string CASE_NAME = "rand";
`elsif TOD_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "seq";
`endif

    localparam string STIM_FILE = {"vectors/tod/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/tod/", CASE_NAME, "_expect.hex"};

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
        .TB_NAME     ({"tb_tod_", CASE_NAME}),
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

    tod #(
        .TICK_SAMPLES(TICK_SAMPLES),
        .TOD_W       (TOD_W),
        .FIELD_W     (6)
    ) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .din_valid     (stim_valid && stim_data[42]),
        .din_rate_sel  (stim_data[41:40]),
        .din_tod_load  (stim_data[39]),
        .din_tod_value (stim_data[31:0]),
        .din_align_valid(stim_data[38]),
        .din_align_tod (stim_data[37:32]),
        .dout_valid    (dut_valid),
        .dout_tick     (dut_data[33]),
        .dout_tod      (dut_data[32:1]),
        .dout_hop_edge (dut_data[0])
    );

endmodule
