// =====================================================================
// tb_vec_cmp.sv — S2 验证基础设施 · 逐拍向量比对器
//
// 计划书 §S2「自动比对框架」与 §S4-P0「位真比对基线」的实现：
// 一个参数化模块同时充当激励驱动器和输出比对器，TB 只需三处接线：
//
//     tb_vec_cmp #(...) u_cmp (.clk, .rst_n, .stim_valid, .stim_data,
//                              .dut_valid, .dut_data);
//     <dut> u_dut (.din_valid(stim_valid), .din_data(stim_data),
//                  .dout_valid(dut_valid), .dout_data(dut_data), ...);
//
// 时序契约（与 sim/framework/README.md 一致）：
//   · 复位释放后 stim_valid 连续拉高 n_stim 拍，逐拍送出 <case>_stim.hex 的每一行；
//   · 送完后 stim_valid 拉低，靠 DRAIN_CYCLES 等流水线排空；
//   · 只按 DUT 自己的 dout_valid 取数比对——有延迟的模块不需要 TB 手工对齐，
//     但延迟差不会被误判为数据错（S4-P0「逐拍而非逐帧」的口径）。
//
// 两个长度相互独立（S4-P0 扩展，见 README §3）：
//   · n_stim = stim 文件行数 = 激励节拍数；
//   · n_exp  = expect 文件行数 = **比对长度**，也是 PASS 判据里的 compared 目标值。
//   一比一的模块（qpsk_map / conv_enc）两值相等；成帧、上采样、补零类模块
//   （frame_tx 256→2160、blk_inter 补零、srrc_duc ×4 上采样）则不等——
//   它们在线性链里本来就是 N:M，硬凑 1:1 会把补零/尾码字塞进上游模块，
//   反而掩盖真实的数据通路形状。
//
// 判据：错误数 0 且比对拍数 == n_exp → PASS；否则 FAIL 并 $fatal 退出，
// 让批处理脚本能靠退出码而非日志肉眼判断。
//
// 前导窗口（S5 接收链扩展）：SKIP_OUT 指定"丢弃 DUT 最前面的多少个 dout_valid 拍"。
// 接收链的同步环在锁定前输出的是过渡态，本就不可比；把它算进比对会把"未锁定"记成
// "数据错"。被丢弃的拍既不计 compared 也不计 extra，只计入 skipped 供脚本核对。
// =====================================================================
`timescale 1ns/1ps

module tb_vec_cmp #(
    parameter int    IN_W           = 1,
    parameter int    OUT_W          = 1,
    parameter int    MAX_DEPTH      = 32768,
    parameter string STIM_FILE      = "",
    parameter string EXP_FILE       = "",
    parameter string TB_NAME        = "tb_vec_cmp",
    parameter int    DRAIN_CYCLES   = 64,
    parameter int    TIMEOUT_CYCLES = 0,      // 0 = 自动 (8*max(stim*n, n_exp) + 4096)
    parameter int    STIM_PERIOD    = 1,      // 激励节奏：每 STIM_PERIOD 拍送出一个激励拍
    parameter int    MAX_MISMATCHES = 8,
    // 跳过 DUT 的前 SKIP_OUT 个 dout_valid 拍再开始比对（S5 接收链扩展）：
    // 同步环（Costas/定时）在锁定前的那段输出不具可比性，若从第 1 拍就比，
    // 会把"尚未锁定"记成"数据错"。SKIP_OUT=0 时与老行为逐拍等价。
    parameter int    SKIP_OUT       = 0
) (
    input  logic             clk,
    input  logic             rst_n,
    output logic             stim_valid,
    output logic [IN_W-1:0]  stim_data,
    input  logic             dut_valid,
    input  logic [OUT_W-1:0] dut_data,
    output int               stim_count       // = n_stim，供 DUT 侧的块长等配置直接引用
);

    logic [IN_W-1:0]  stim_mem [0:MAX_DEPTH-1];
    logic [OUT_W-1:0] exp_mem  [0:MAX_DEPTH-1];

    int   n_stim     = 0;      // 激励行数（驱动节拍数）
    int   n_exp      = 0;      // 期望行数（比对长度）
    int   drive_idx  = 0;
    int   exp_idx    = 0;      // 已发出的期望序号
    int   cmp_cnt    = 0;      // 已比对拍数
    int   skip_cnt   = 0;      // 已丢弃的前导输出拍数（< SKIP_OUT）
    int   err_cnt    = 0;
    int   extra_cnt  = 0;      // 超出期望长度的多余有效拍
    int   first_idx  = -1;     // 首个失配序号（0 起）
    realtime first_time = 0;
    logic [OUT_W-1:0] first_exp = 'x;
    logic [OUT_W-1:0] first_act = 'x;

    logic [OUT_W-1:0] bad_exp [0:MAX_MISMATCHES-1];
    logic [OUT_W-1:0] bad_act [0:MAX_MISMATCHES-1];
    int   bad_idx [0:MAX_MISMATCHES-1];
    int   bad_cnt = 0;

    int   idle_cyc  = 0;
    int   cyc       = 0;
    int   drive_cyc = 0;
    int   timeout   = 0;
    logic finished  = 1'b0;

    // 供 DUT 侧引用：块长这类"必须与激励长度一致"的配置直接取这个值，
    // 不再由 TB 手抄一遍（少一处可能不一致的来源）。
    assign stim_count = n_stim;

    // ---------------------------------------------------------------
    // 向量加载：两份文件各自数行数（互不约束）
    // ---------------------------------------------------------------
    initial begin
        for (int i = 0; i < MAX_DEPTH; i++) begin
            stim_mem[i] = 'x;
            exp_mem[i]  = 'x;
        end

        if (STIM_FILE == "" || EXP_FILE == "") begin
            $display("[VEC] %0s ERROR 未指定向量文件", TB_NAME);
            $fatal(1, "[VEC] %0s vector file not set", TB_NAME);
        end

        $readmemh(STIM_FILE, stim_mem);
        $readmemh(EXP_FILE, exp_mem);

        while (n_stim < MAX_DEPTH && stim_mem[n_stim] !== 'x)
            n_stim++;
        while (n_exp < MAX_DEPTH && exp_mem[n_exp] !== 'x)
            n_exp++;

        if (n_stim == 0 || n_exp == 0) begin
            $display("[VEC] %0s ERROR 向量为空，检查 %0s (stim=%0d) / %0s (expect=%0d)",
                     TB_NAME, STIM_FILE, n_stim, EXP_FILE, n_exp);
            $fatal(1, "[VEC] %0s empty vectors", TB_NAME);
        end
        if (n_stim >= MAX_DEPTH || n_exp >= MAX_DEPTH) begin
            $display("[VEC] %0s ERROR 向量长度达到 MAX_DEPTH=%0d（stim=%0d expect=%0d），请调大参数",
                     TB_NAME, MAX_DEPTH, n_stim, n_exp);
            $fatal(1, "[VEC] %0s vector too long", TB_NAME);
        end

        timeout = (TIMEOUT_CYCLES > 0) ? TIMEOUT_CYCLES
                                       : (8 * (((n_stim * STIM_PERIOD) > (n_exp + SKIP_OUT))
                                               ? (n_stim * STIM_PERIOD) : (n_exp + SKIP_OUT))
                                          + 4096);
        $display("[VEC] %0s  加载 %0s：激励 %0d 拍（节奏 1/%0d），期望 %0d 拍，跳过前导 %0d 拍，看门狗 %0d 拍",
                 TB_NAME, EXP_FILE, n_stim, STIM_PERIOD, n_exp, SKIP_OUT, timeout);
    end

    // ---------------------------------------------------------------
    // 激励驱动：每 STIM_PERIOD 拍送出一个激励拍，送满 n_stim 拍后拉低让流水线排空。
    //
    // 节奏参数是为**多速率**模块准备的：比特串行输出的成帧器（256 字节进 → 2160 比特出）
    // 与采样域的 DUC（符号 1/4 节奏进 → 采样连续出）都不是每拍都有激励，
    // 硬按连续有效驱动会得到上游 8 倍过载的假象。STIM_PERIOD=1 时与老行为逐拍等价。
    // ---------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stim_valid <= 1'b0;
            stim_data  <= '0;
            drive_idx  <= 0;
            drive_cyc  <= 0;
        end else if (drive_idx >= n_stim) begin
            stim_valid <= 1'b0;
            drive_cyc  <= 0;
        end else if (drive_cyc == 0) begin
            stim_valid <= 1'b1;
            stim_data  <= stim_mem[drive_idx];
            drive_idx  <= drive_idx + 1;
            drive_cyc  <= STIM_PERIOD - 1;
        end else begin
            stim_valid <= 1'b0;
            drive_cyc  <= drive_cyc - 1;
        end
    end

    // ---------------------------------------------------------------
    // 比对：只看 DUT 自己的 valid，输出一拍比一拍
    // ---------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exp_idx   <= 0;
            cmp_cnt   <= 0;
            skip_cnt  <= 0;
            err_cnt   <= 0;
            extra_cnt <= 0;
            bad_cnt   <= 0;
        end else if (dut_valid) begin
            if (skip_cnt < SKIP_OUT) begin
                // 前导窗口：丢弃，不计入比对也不计入多余拍
                skip_cnt <= skip_cnt + 1;
            end else if (exp_idx >= n_exp) begin
                extra_cnt <= extra_cnt + 1;
                err_cnt   <= err_cnt + 1;
                if (first_idx < 0) begin
                    first_idx  <= exp_idx;
                    first_time <= $realtime;
                    first_exp  <= 'x;
                    first_act  <= dut_data;
                end
            end else begin
                cmp_cnt <= cmp_cnt + 1;
                if (dut_data !== exp_mem[exp_idx]) begin
                    err_cnt <= err_cnt + 1;
                    if (first_idx < 0) begin
                        first_idx  <= exp_idx;
                        first_time <= $realtime;
                        first_exp  <= exp_mem[exp_idx];
                        first_act  <= dut_data;
                    end
                    if (bad_cnt < MAX_MISMATCHES) begin
                        bad_idx[bad_cnt] <= exp_idx;
                        bad_exp[bad_cnt] <= exp_mem[exp_idx];
                        bad_act[bad_cnt] <= dut_data;
                        bad_cnt <= bad_cnt + 1;
                    end
                end
                exp_idx <= exp_idx + 1;
            end
        end
    end

    // 空闲计数：全部向量比对完后再静默 DRAIN_CYCLES 拍才算结束
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) idle_cyc <= 0;
        else if (dut_valid) idle_cyc <= 0;
        else if (idle_cyc < DRAIN_CYCLES + 1) idle_cyc <= idle_cyc + 1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cyc <= 0;
        else cyc <= cyc + 1;
    end

    // ---------------------------------------------------------------
    // 收口：判 PASS/FAIL 并打印 summary
    // ---------------------------------------------------------------
    task automatic report_and_finish(input bit timed_out);
        int    done_pct;
        int    fm_idx;
        string status;
        begin
            if (finished) return;
            finished = 1'b1;

            done_pct = (n_exp > 0) ? (cmp_cnt * 100 / n_exp) : 0;
            status   = (err_cnt == 0 && cmp_cnt == n_exp) ? "PASS" : "FAIL";
            fm_idx   = (first_idx >= 0) ? (first_idx + 1) : -1;

            // 机器可读结果行：纯 ASCII，脚本/CI 只认这一行，不受控制台代码页影响。
            // vectors = 期望行数（比对长度）；stim_rows 供 N:M 模块核对驱动节拍数。
            $display("[VEC-RESULT] tb=%0s status=%0s vectors=%0d compared=%0d errors=%0d extra=%0d timeout=%0d first_mismatch=%0d first_expected=0x%h first_actual=0x%h stim_rows=%0d stim_period=%0d skipped=%0d",
                     TB_NAME, status, n_exp, cmp_cnt, err_cnt, extra_cnt, timed_out ? 1 : 0,
                     fm_idx, first_exp, first_act, n_stim, STIM_PERIOD, skip_cnt);

            $display("[VEC] ------------------------------------------------------------");
            $display("[VEC] %0s  激励 %0d 拍 / 期望 %0d 拍  已比对 %0d (%0d%%)  错误 %0d  多余拍 %0d  跳过前导 %0d",
                     TB_NAME, n_stim, n_exp, cmp_cnt, done_pct, err_cnt, extra_cnt, skip_cnt);

            if (timed_out) begin
                $display("[VEC] %0s  看门狗超时：%0d 拍内只收到 %0d/%0d 个输出",
                         TB_NAME, timeout, cmp_cnt, n_exp);
                $display("[VEC] %0s  排查方向：DUT 是否卡死、dout_valid 是否按要求逐拍有效、%0s",
                         TB_NAME, "流水线延迟是否超出 DRAIN_CYCLES");
            end

            if (first_idx >= 0) begin
                $display("[VEC] %0s  首个失配：第 %0d 拍 @ %0t  期望 0x%h  实际 0x%h",
                         TB_NAME, first_idx + 1, first_time, first_exp, first_act);
                for (int i = 0; i < bad_cnt; i++)
                    $display("[VEC] %0s    失配[%0d] 第 %0d 拍  期望 0x%h  实际 0x%h",
                             TB_NAME, i, bad_idx[i] + 1, bad_exp[i], bad_act[i]);
                if (err_cnt > bad_cnt)
                    $display("[VEC] %0s    …另有 %0d 处失配未列出（MAX_MISMATCHES=%0d）",
                             TB_NAME, err_cnt - bad_cnt, MAX_MISMATCHES);
            end

            if (status == "PASS") begin
                $display("[VEC] %0s  PASS", TB_NAME);
                $display("[VEC] ------------------------------------------------------------");
                $finish;
            end else begin
                $display("[VEC] %0s  FAIL", TB_NAME);
                $display("[VEC] ------------------------------------------------------------");
                $fatal(1, "[VEC] %0s FAIL", TB_NAME);
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst_n && !finished) begin
            if (exp_idx >= n_exp && idle_cyc > DRAIN_CYCLES)
                report_and_finish(1'b0);
            else if (cyc >= timeout)
                report_and_finish(1'b1);
        end
    end

endmodule

`default_nettype wire
