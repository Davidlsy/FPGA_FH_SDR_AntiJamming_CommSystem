`timescale 1ns / 1ps
//=============================================================================
// fhss_top : S0 smoke-test top level
//-----------------------------------------------------------------------------
// Purpose    : verify Vivado 2021.2 + xc7z020clg400-2 full flow
//              (synthesis -> implementation -> bitstream). 
// Clock      : sys_clk = PL_GCLK1 (U18, 50 MHz single-ended, AX7Z020B
//              manual sec 2.5)
// Output     : led[3:0] binary heartbeat -- led[3] blinks at ~1.5 Hz
//              (visible), lower bits toggle progressively faster
// Reset      : none (GSR loads initial values at power-up; a smoke design
//              needs no reset pin)
// Lifecycle  : replaced by the real integration top (fh_ctrl / nco_hop /
//              ad9363_if / axi_regs ...) after board arrival (P1'-S1)
// Constraints: src/constraints/fhss_zynq_timing.xdc (sections [1][6] active)
//              board/fhss_zynq_pins.xdc (sys_clk + led pins filled)
// Encoding   : pure ASCII English comments -- Vivado on Chinese Windows
//              reads BOM-less files as GBK, UTF-8 Chinese comments garble;
//=============================================================================
module fhss_top (
    input  wire       sys_clk,   // PL_GCLK1, U18, 50 MHz
    output wire [3:0] led        // user LED1-4 (J14/K14/J18/H18)
);

    reg [25:0] cnt = 26'd0;      // init value loaded by GSR, no reset pin needed

    always @(posedge sys_clk) begin
        cnt <= cnt + 1'b1;
    end

    // Heartbeat: led = cnt[24:21]; led[3] square-wave period = 2*2^24/50 MHz
    // ~ 0.67 s (~1.5 Hz blink), lower bits faster
    assign led = cnt[24:21];

endmodule
