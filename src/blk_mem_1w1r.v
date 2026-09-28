// =====================================================================
// blk_mem_1w1r.v — 1 写 1 读存储器副本（供 blk_inter 造多读端口）
//
// blk_inter 在双缓冲稳态下每拍要 1 写 + 2 读 = 3 次访问，而单块 BRAM 只有
// 两个端口。常规做法是**复制存储**：两个副本都接同一路写，读端口各分一路，
// 于是稳态下每拍 = 每副本 1 写 + 1 读，正好是简单双口 RAM 的能力上限。
//
// 代价：存储复制 2 份（本设计每副本 8192 × 2 bit = 16 kbit，各一个 BRAM18）。
// 收益：写侧与读侧可以同时跑，不需要把写相位和读相位串起来（块周期从 4340 拍
// 降到 2171 拍），也不需要按 bank 切换端口。
//
// 两种实现同接口、同行为，由 `BLK_INTER_USE_BRAM_IP 宏 选择：
//   定义   → blk_mem_gen（简单双口，正式交付版；IP 由 build/gen_blk_mem_gen.tcl 生成）
//   未定义 → RTL 推断（同步写 + 同步读，快速迭代版）
// 两者都保证**同步读、读延迟 1 拍**，所以 blk_inter 的时序与判据与选择无关。
// =====================================================================
`timescale 1ns/1ps

module blk_mem_1w1r #(
    parameter int ADDR_W = 13            // 8192 字（实际用到 4339）
) (
    input  logic              clk,
    input  logic              we,
    input  logic [ADDR_W-1:0] waddr,
    input  logic [1:0]        wdata,
    input  logic [ADDR_W-1:0] raddr,
    output logic [1:0]        rdata
);

`ifdef BLK_INTER_USE_BRAM_IP
    // 正式交付版：blk_mem_gen 简单双口（A 口写、B 口读，输出寄存器打开 → 读延迟 1 拍）
    // 由 build/gen_blk_mem_gen.tcl 生成；端口名与参数见生成的 blk_mem_gen_1w1r.v
    blk_mem_gen_1w1r u_bmg (
        .clka (clk),
        .wea  (we),
        .addra(waddr),
        .dina (wdata),
        .clkb (clk),
        .addrb(raddr),
        .doutb(rdata)
    );
`else
    // 快速迭代版：RTL 推断为简单双口 BRAM（同步写 + 同步读，读优先读旧值）
    logic [1:0] mem [0:(1 << ADDR_W)-1];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
`endif

endmodule

`default_nettype wire
