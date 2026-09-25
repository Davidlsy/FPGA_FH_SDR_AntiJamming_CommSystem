// =====================================================================
// tb_module_template.sv — S2 比对框架 · 新模块位真比对 TB 模板
//
// 用法（详见 sim/framework/README.md §4）：整份复制成 tb_<module>_<case>.sv，
// 然后只改 4 处占位：MODULE_NAME、IN_W、OUT_W、DUT 例化；向量文件路径指向
// vectors/<module>/<case>_{stim,expect}.hex（由 export_vectors.py 生成）。
//
// 一个 TB 只跑一个用例。要跑第二个用例就再复制一份（改 CASE_NAME 与路径），
// 或用 ifdef 切换——比对器在收口时会 $finish/$fatal，不适合在一个 TB 里串两轮。
// =====================================================================
`timescale 1ns/1ps

module tb_MODULE_compare;

    // ------------------------------------------------------------------
    // ① 位宽与文件名：位宽必须与 docs/spec/fixed_point_spec.md 的该模块接口一致
    // ------------------------------------------------------------------
    localparam int    IN_W      = 2;                                 // DUT 输入总线位宽
    localparam int    OUT_W     = 24;                                // DUT 输出总线位宽
    localparam string MODULE_NAME = "MODULE";                        // 仅用于日志
    localparam string CASE_NAME   = "rand";                          // 仅用于日志
    localparam string STIM_FILE   = "vectors/MODULE/rand_stim.hex";
    localparam string EXP_FILE    = "vectors/MODULE/rand_expect.hex";

    // ------------------------------------------------------------------
    // 时钟与复位：节拍只定义比对节奏，与 DUT 实际时钟域无关
    // ------------------------------------------------------------------
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #100 rst_n = 1'b1;

    // ------------------------------------------------------------------
    // 比对器 ↔ DUT 的接线
    // ------------------------------------------------------------------
    logic             stim_valid;
    logic [IN_W-1:0]  stim_data;
    logic             dut_valid;
    logic [OUT_W-1:0] dut_data;

    tb_vec_cmp #(
        .IN_W     (IN_W),
        .OUT_W    (OUT_W),
        .STIM_FILE(STIM_FILE),
        .EXP_FILE (EXP_FILE),
        .TB_NAME  ({"tb_", MODULE_NAME, "_", CASE_NAME})
        //, .DRAIN_CYCLES   (64)     // 流水线深（如 SRRC 31 抽头）时按需放大
        //, .TIMEOUT_CYCLES (0)      // 0 = 自动 8*n_vec+4096
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data)
    );

    // ------------------------------------------------------------------
    // ② DUT 例化：输入接 stim_*，输出接 dut_*，端口名按该模块接口规格页
    //    组合逻辑（0 延迟）或流水线（多拍延迟）都无需额外处理——比对器只按
    //    DUT 自己的 dout_valid 取数，延迟不会被误判为数据错。
    // ------------------------------------------------------------------
    // MODULE u_dut (
    //     .clk       (clk),
    //     .rst_n     (rst_n),
    //     .din_valid (stim_valid),
    //     .din_data  (stim_data),
    //     .dout_valid(dut_valid),
    //     .dout_data (dut_data)
    // );

    // ------------------------------------------------------------------
    // ③ 模块专属检查写在这里（比对器管不到的项），例如
    //    blk_inter 的「突发错误被打散到 ≥10 个码字位置」
    // ------------------------------------------------------------------

endmodule
