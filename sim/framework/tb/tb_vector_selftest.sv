// =====================================================================
// tb_vector_selftest.sv — S2 比对框架 · 自测 TB
//
// 目的：在还没有真实设计模块的时候，先证明「比对框架本身可信」。
// 一个抓不到错的比对器等于没有比对器，所以自测同时跑两条路径：
//
//   正路径                             预期
//   ------------------------------     ------------------------------
//   默认编译                           框架判 PASS（桩 DUT 与 golden 一致）
//   -d SELFTEST_CASE_EDGE              边界用例同样 PASS
//   -d SELFTEST_CASE_RATIO             1:N 路径 PASS（3 拍激励 → 9 拍期望）
//   -d SELFTEST_CASE_RATIO -d SELF_TEST_STIM_PERIOD
//                                      带节奏的激励 PASS（每 4 拍才出一个激励拍）
//
//   负路径
//   ------------------------------     ------------------------------
//   -d SELF_TEST_NEGATIVE              框架判 FAIL，且首个失配必须落在第 1000 拍
//   -d SELFTEST_CASE_RATIO + -d SELF_TEST_EXTRA_OUT
//                                      桩每输入多吐 1 拍 → 多余拍必须被判 FAIL
//
// 1:N 路径（S4-P0 新增）用 `stub_ratio3` 覆盖：这个桩每个输入拍产出 3 拍输出
// （k, k+1, k+2），对应成帧/上采样/补零类模块的真实形状。夹具向量只有 3+9 行，
// 手算即可核验，见 vectors/selftest_ratio/。
//
// 桩 DUT 只是 golden 映射的镜像（QPSK 四星座点 ±round(1/√2·2^10) = ±724），
// 不是设计交付物——真实模块的 TB 从 tb_module_template.sv 起手。
// =====================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------------
// 自测桩：qpsk_map 的 golden 映射镜像，{i_bit,q_bit} → {i_out,q_out}
// ---------------------------------------------------------------------
module stub_qpsk_map (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [1:0]  din_data,    // {i_bit, q_bit}
    output logic        dout_valid,
    output logic [23:0] dout_data    // {i_out[11:0], q_out[11:0]}
);

    // round(1/sqrt(2) * 2**10) = 724，与 golden_ref fixed_qpsk_modulate 一致
    localparam logic signed [11:0] AMP_POS = 12'sd724;
    localparam logic signed [11:0] AMP_NEG = -12'sd724;

    logic [11:0] i_out, q_out;
    assign i_out = din_data[1] ? AMP_NEG : AMP_POS;
    assign q_out = din_data[0] ? AMP_NEG : AMP_POS;

`ifdef SELF_TEST_STALL
    // 桩死路径：模拟 DUT 卡死 / dout_valid 接错——此路径只能靠看门狗收口
    assign dout_valid = 1'b0;
`else
    assign dout_valid = din_valid;
`endif

`ifdef SELF_TEST_NEGATIVE
    // 负路径：把第 NEG_BEAT 个有效拍的最低位翻转
    localparam int NEG_BEAT = 1000;
    int beat;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          beat <= 0;
        else if (din_valid)  beat <= beat + 1;
    end
    assign dout_data = (din_valid && beat == NEG_BEAT - 1)
                     ? ({i_out, q_out} ^ 24'h000001)
                     : {i_out, q_out};
`else
    assign dout_data = {i_out, q_out};
`endif

endmodule


// ---------------------------------------------------------------------
// 自测桩（1:N 路径）：每个输入拍产出 3 拍输出 k, k+1, k+2
// 形状对应成帧（256 拍进 → 2160 拍出）、上采样（×4）、交织补零等真实模块。
//
// 带 -d SELF_TEST_EXTRA_OUT 时**数据流一字不变**，只在 FIFO 排空后再多吐 3 拍
// （值 0xA0..0xA2，与期望明显不同）——这样"多余拍"才是唯一被判错的来源。
// 直接把每输入拍数改成 4 会让整条流出相位错位，9 拍全错，测不到 extra 这条判据。
// ---------------------------------------------------------------------
module stub_ratio3 (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       din_valid,
    input  logic [7:0] din_data,
    output logic       dout_valid,
    output logic [7:0] dout_data
);

    localparam int PHASES = 3;

`ifdef SELF_TEST_EXTRA_OUT
    localparam bit EXTRA_TAIL = 1'b1;
`else
    localparam bit EXTRA_TAIL = 1'b0;
`endif

    logic [7:0] fifo [0:7];
    logic [3:0] wptr, rptr;
    logic [1:0] tail_cnt;
    int         phase;

    wire fifo_pop = (wptr != rptr);
    // 尾巴必须在"数据流已排空"之后才启动：rptr!=0 表示至少已读出一拍，
    // 否则复位后 FIFO 本来就是空的，尾拍会跑到数据前面（实测踩过一次）。
    wire drained  = (rptr != 4'd0) && !fifo_pop;
    wire tail_pop = EXTRA_TAIL && drained && (tail_cnt != 2'd3);

    assign dout_valid = fifo_pop || tail_pop;
    assign dout_data  = fifo_pop ? (fifo[rptr[2:0]] + phase[7:0])
                                 : (8'hA0 + {6'b0, tail_cnt});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          wptr <= 4'd0;
        else if (din_valid) begin
            fifo[wptr[2:0]] <= din_data;
            wptr <= wptr + 4'd1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rptr     <= 4'd0;
            phase    <= 0;
            tail_cnt <= 2'd0;
        end else if (dout_valid) begin
            if (fifo_pop) begin
                if (phase == PHASES - 1) begin
                    phase <= 0;
                    rptr  <= rptr + 4'd1;
                end else begin
                    phase <= phase + 1;
                end
            end else begin
                tail_cnt <= tail_cnt + 2'd1;
            end
        end
    end

endmodule


// ---------------------------------------------------------------------
// 自测 TB
// ---------------------------------------------------------------------
module tb_vector_selftest;

`ifdef SELFTEST_CASE_RATIO
    localparam int    IN_W  = 8;
    localparam int    OUT_W = 8;
    localparam string TB_LABEL  = "tb_selftest_ratio";
    localparam string STIM_FILE = "vectors/selftest_ratio/stim.hex";
    localparam string EXP_FILE  = "vectors/selftest_ratio/expect.hex";
`ifdef SELF_TEST_STIM_PERIOD
    localparam int    STIM_PERIOD = 4;      // 每 4 拍才出一个激励拍（多速率模块的形状）
`else
    localparam int    STIM_PERIOD = 1;
`endif
`else
    localparam int IN_W  = 2;
    localparam int OUT_W = 24;
    localparam string TB_LABEL = "tb_vector_selftest";
    localparam int    STIM_PERIOD = 1;

`ifdef SELFTEST_CASE_EDGE
    localparam string CASE_NAME = "edge";
`else
    localparam string CASE_NAME = "rand";
`endif
    localparam string STIM_FILE = {"vectors/qpsk_map/", CASE_NAME, "_stim.hex"};
    localparam string EXP_FILE  = {"vectors/qpsk_map/", CASE_NAME, "_expect.hex"};
`endif

    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    always #5 clk = ~clk;                       // 100 MHz，与目标基带时钟无关，仅用作节拍

    initial begin
        #100 rst_n = 1'b1;
    end

    logic             stim_valid;
    logic [IN_W-1:0]  stim_data;
    logic             dut_valid;
    logic [OUT_W-1:0] dut_data;

    tb_vec_cmp #(
        .IN_W       (IN_W),
        .OUT_W      (OUT_W),
        .STIM_FILE  (STIM_FILE),
        .EXP_FILE   (EXP_FILE),
        .STIM_PERIOD(STIM_PERIOD),
        .TB_NAME    (TB_LABEL)
    ) u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .stim_valid(stim_valid),
        .stim_data (stim_data),
        .dut_valid (dut_valid),
        .dut_data  (dut_data)
    );

`ifdef SELFTEST_CASE_RATIO
    stub_ratio3 u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_data (dut_data)
    );
`else
    stub_qpsk_map u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (stim_valid),
        .din_data  (stim_data),
        .dout_valid(dut_valid),
        .dout_data (dut_data)
    );
`endif

endmodule
