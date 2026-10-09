// =====================================================================
// fh_ctrl.v — S6 跳频层 · LFSR-16 跳频图案发生器
//
// 规格: docs/spec/s6_fh_interface.md §2/§3
// 判据: 位真比对 golden_ref.fixed_point.fh_pattern.sim_fh_ctrl（errors=0）；
//       10⁶ 跳收发互比 + 16 信道驻留均匀性 ±10%（tb_fh_ctrl_long）
//
// 语义（与黄金模型逐条同构，口径全在规格 §2，此处只列易写错处）:
//   1. LFSR: Fibonacci 直移——每拍输出寄存器 LSB、反馈进最高位，与
//      frame_format.md §2 的 6 级 LFSR 同构。多项式 x^16+x^15+x^13+x^4+1
//      （掩码 17'h1A011），反馈 = state[0]^state[4]^state[13]^state[15]。
//   2. 一跳 = 移位 4 拍（4 级反馈组合展开）：信道号 = 本跳移出的 4 个输出 bit
//      （b0=现态 LSB … b3），b0 落 channel[3]（MSB-first）。非重叠取字——
//      下一跳的 4 bit 来自 state[7:4]，与本跳无移位窗口重叠。
//   3. 加载拍（din_seed_load=1）: state←din_seed、hop_index←0、**不出数**；
//      全零种子是吸收态，规格禁止（模型侧拒收，RTL 不做防护——激励不产生）。
//   4. 输出寄存一拍: 每个跳拍**下一拍** dout_valid=1 并给 {hop_index, channel}，
//      hop_index 给的是本跳序号（加载后第一跳=0，2^20 自然回绕）。
//      非输出拍 channel/hop_index 保持——保持期就是 nco_hop 的驻留期。
//   5. hop_index 递增在输出拍完成（先出本跳号再 +1）。
// =====================================================================
`timescale 1ns/1ps

module fh_ctrl #(
    parameter logic [15:0] SEED = 16'h0001   // 复位后默认种子（全零禁止）
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,       // 一拍 = 一次加载或一跳
    input  logic        din_seed_load,   // 1: 加载 din_seed（不产生输出）；0: 推进一跳
    input  logic [15:0] din_seed,
    output logic        dout_valid,      // 每跳一拍（种子加载拍不拉高）
    output logic [19:0] dout_hop_index,  // 0 起，逐跳 +1，2^20 回绕
    output logic [3:0]  dout_channel     // 本跳信道号 0–15
);

    logic [15:0] state;
    logic [19:0] hop_cnt;   // 下一跳的序号（加载后第一跳 = 0）

    // ----单拍推进（反馈进最高位，输出 LSB）----
    function automatic logic [15:0] step1(input logic [15:0] s);
        logic fb;
        fb = s[0] ^ s[4] ^ s[13] ^ s[15];
        step1 = {fb, s[15:1]};
    endfunction

    // ----一跳 = 4 拍: 移出位 b0..b3 = s[0]、step1(s)[0]、…（即 s[3:0] 逆序）----
    logic [15:0] s1, s2, s3, s4;
    assign s1 = step1(state);
    assign s2 = step1(s1);
    assign s3 = step1(s2);
    assign s4 = step1(s3);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= SEED;
            hop_cnt       <= 20'd0;
            dout_valid    <= 1'b0;
            dout_hop_index<= 20'd0;
            dout_channel  <= 4'd0;
        end else if (din_valid && din_seed_load) begin
            state         <= din_seed;
            hop_cnt       <= 20'd0;
            dout_valid    <= 1'b0;
            // dout_hop_index/dout_channel 保持（规格 §3.3：非输出拍保持上一跳值）
        end else if (din_valid) begin
            state         <= s4;
            hop_cnt       <= hop_cnt + 20'd1;
            dout_valid    <= 1'b1;
            dout_hop_index<= hop_cnt;                       // 本跳序号
            dout_channel  <= {state[0], state[1], state[2], state[3]};
        end else begin
            dout_valid    <= 1'b0;
        end
    end

endmodule
