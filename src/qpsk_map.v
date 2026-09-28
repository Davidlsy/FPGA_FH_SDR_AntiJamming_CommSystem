// =====================================================================
// qpsk_map.v — S4 发射链 · QPSK 符号映射
//
// 规格: docs/spec/s4_tx_interface.md §4.4
// 判据: 4 个星座点穷举 + 长随机序列与 S1 定点参考逐拍一致（0 错误）
//
// 直移（直接映射），纯组合、无状态、零延迟：
//     i_bit = 0 → +round(1/√2 · 2^10) = +724
//     i_bit = 1 → −724                       （Q 路同理）
//
// 724 不是手抄的常数：fixed_qpsk_modulate 用 amp = 1/√2 经《定点规格书》
// 的 qpsk_out_w=12 / frac=10 量化（round）而来，round(0.7071068 × 1024) = 724。
// 位真向量会逐拍校核这两个值，改错任何一个都会红。
// =====================================================================
`timescale 1ns/1ps

module qpsk_map (
    input  logic        clk,          // 纯组合模块不需要时钟，保留端口是为了接口统一
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [1:0]  din_data,     // {i_bit, q_bit}
    output logic        dout_valid,
    output logic [23:0] dout_data     // {i_out[11:0], q_out[11:0]}，12 bit 有符号 / 10 bit 小数
);

    localparam logic signed [11:0] AMP_POS = 12'sd724;
    localparam logic signed [11:0] AMP_NEG = -12'sd724;

    logic signed [11:0] i_out, q_out;

    assign i_out = din_data[1] ? AMP_NEG : AMP_POS;
    assign q_out = din_data[0] ? AMP_NEG : AMP_POS;

    assign dout_data  = {i_out, q_out};
    assign dout_valid = din_valid;

endmodule

`default_nettype wire
