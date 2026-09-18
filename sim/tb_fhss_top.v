`timescale 1ns / 1ps
//=============================================================================
// tb_fhss_top : S0 simulator smoke test (the main smoke test on the
//               simulation-only route)
//-----------------------------------------------------------------------------
// Purpose : verify the xsim simulation infrastructure -- clock generation,
//           waveform viewing, automatic PASS/FAIL verdict (seed of the S2
//           verification infrastructure / regression framework)
// Checks  : 1) cnt power-on value 0, no X   2) cnt +10 per 10 clock cycles
//           3) long run free of X / hang
// Run     : Flow Navigator -> Run Behavioral Simulation (default 1000 ns is
//           enough; this tb calls $finish at ~805 ns, deliberately earlier
//           than the default run length)
// Notes   : behavioral simulation does NOT read xdc -- pin/timing constraint
//           validation is carried by the synthesis -> implementation smoke
//           run. The led bit slice needs 2^21 cycles (~42 ms) to toggle, so
//           LED blinking is a board-observation item; only counter stepping
//           is checked here. $display strings stay ASCII to avoid xsim
//           console encoding issues.
//=============================================================================
module tb_fhss_top;

    reg        sys_clk;
    wire [3:0] led;
    integer    errors;
    integer    cnt_a, cnt_b;

    fhss_top dut (
        .sys_clk (sys_clk),
        .led     (led)
    );

    // 50 MHz clock (period 20 ns, matches create_clock -period 20.000
    // in fhss_zynq_timing.xdc)
    initial sys_clk = 1'b0;
    always #10 sys_clk = ~sys_clk;

    initial begin
        errors = 0;

        // --- Check 1: initial value and no X (t=5 ns, before first edge) ---
        #5;
        if (dut.cnt !== 26'd0) begin
            $display("[SMOKE][FAIL] cnt init = %0d, expect 0", dut.cnt);
            errors = errors + 1;
        end
        if (^led === 1'bx) begin
            $display("[SMOKE][FAIL] led has X: %b", led);
            errors = errors + 1;
        end

        // --- Check 2: 10 clock cycles (200 ns) -> cnt delta = 10 ---
        cnt_a = dut.cnt;
        #200;
        cnt_b = dut.cnt;
        if (cnt_b - cnt_a !== 10) begin
            $display("[SMOKE][FAIL] cnt delta = %0d in 10 cycles, expect 10",
                     cnt_b - cnt_a);
            errors = errors + 1;
        end

        // --- Check 3: long run 600 ns (30 cycles), no X, no hang ---
        #600;
        if ((^dut.cnt === 1'bx) || (^led === 1'bx)) begin
            $display("[SMOKE][FAIL] X after long run: cnt=%b led=%b",
                     dut.cnt, led);
            errors = errors + 1;
        end

        // --- Verdict (t ~ 805 ns, before the default 1000 ns run length) ---
        if (errors == 0)
            $display("[SMOKE] tb_fhss_top PASS at %0t ns", $time);
        else
            $display("[SMOKE] tb_fhss_top FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
