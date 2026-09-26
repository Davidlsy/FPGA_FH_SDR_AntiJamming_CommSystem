`timescale 1ns / 1ps
`default_nettype none
//=====================================================================
// spi_slave_gen.sv
//---------------------------------------------------------------------
// 通用 4 线 SPI 从机 (仿真 BFM), 参数化 CPOL/CPHA, 用于 spi_master 的
// 极性/相位包络验证 (mode 0/1/2/3)。
//
// 行为: CSB 低有效期间, 在每个 SCLK 沿统计边沿, 并按模式在采样沿
// (CPHA=0 -> 前沿, CPHA=1 -> 后沿) 采集 MOSI 到 captured 移位寄存器。
// MISO 由测试台自行忽略 (mode 0 的 MISO 正确性已由 ad9363_spi_model 全验证)。
//
// 该从机的采样沿约定与 spi_master 的驱动沿互补 (驱动沿后半个周期采样),
// 因此 captured 中的 MOSI 流与主控发出的位流完全一致, 可逐位比对。
//=====================================================================
module spi_slave_gen #(
    parameter CPOL = 0,
    parameter CPHA = 0
)(
    input  wire        sclk,
    input  wire        csb,
    input  wire        mosi,
    output reg  [79:0] captured,   // 采样到的 MOSI 位流 (MSB 先入, 最多 80 位)
    output reg  [6:0]  cap_bits,   // 采样位计数 (采样沿个数)
    output reg  [6:0]  edge_cnt    // SCLK 边沿计数 (前沿+后沿)
);

    reg leading;

    always @(posedge sclk or negedge sclk) begin
        if (!csb) begin
            edge_cnt = edge_cnt + 7'd1;
            // 当前 sclk 电平 == 有效电平 (~CPOL) 则本次沿为前沿
            leading = (sclk === ((CPOL == 0) ? 1'b1 : 1'b0));
            if ((CPHA == 0 && leading) || (CPHA == 1 && !leading)) begin
                captured = {captured[78:0], mosi};
                cap_bits = cap_bits + 7'd1;
            end
        end
    end

    always @(negedge csb) begin
        captured = 80'd0;
        cap_bits = 7'd0;
        edge_cnt = 7'd0;
    end

endmodule

`default_nettype wire
