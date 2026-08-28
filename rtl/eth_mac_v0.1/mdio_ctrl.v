module mdio_ctrl (
    input  wire        clk,          // 50MHz
    input  wire        rst_n,
    output wire        mdc,
    inout  wire        mdio,
    input  wire        start,        // 单拍脉冲：启动一次操作
    input  wire        op,           // 0=写 1=读
    input  wire [4:0]  phy_addr,
    input  wire [4:0]  reg_addr,
    input  wire [15:0] wr_data,
    output reg  [15:0] rd_data,
    output reg         busy,
    output reg         done
);
    // ---- MDC 生成：50MHz -> 2.5MHz ----
    reg [4:0] div_cnt;
    reg       mdc_r;
    reg       mdc_tick;      // MDC 下降沿脉冲，推进状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin div_cnt <= 0; mdc_r <= 0; mdc_tick <= 0; end
        else begin
            mdc_tick <= 0;
            if (div_cnt == 5'd9) begin
                div_cnt <= 0; mdc_r <= ~mdc_r;
                if (mdc_r) mdc_tick <= 1;    // 下降沿
            end else
                div_cnt <= div_cnt + 1;
        end
    end
    assign mdc = mdc_r;

    // ---- 帧位序列（64 bit）----
    // bit 0..31  preamble=1
    // bit 32..33 ST=01
    // bit 34..35 OP={op,~op}
    // bit 36..40 PHYAD[4:0]
    // bit 41..45 REGAD[4:0]
    // bit 46..47 TA（读时 bit46 释放总线）
    // bit 48..63 DATA[15:0]
    reg [6:0] bit_cnt;
    reg       running;
    reg       mdio_oe;
    reg       mdio_out;
    reg       sampling;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0; bit_cnt <= 0; mdio_oe <= 0; mdio_out <= 0;
            sampling <= 0; busy <= 0; done <= 0; rd_data <= 0;
        end else begin
            done <= 0;
            if (start && !running) begin
                running <= 1; bit_cnt <= 0; busy <= 1;
                mdio_oe <= 1; mdio_out <= 1;        // preamble 首位
            end else if (running && mdc_tick) begin
                if (bit_cnt == 7'd63) begin
                    running <= 0; busy <= 0; done <= 1; mdio_oe <= 0;
                end else begin
                    bit_cnt <= bit_cnt + 1;
                    mdio_out <= next_bit(bit_cnt + 1);
                    // 读操作：TA 第 2 拍后、DATA 阶段释放总线并采样
                    if (op && (bit_cnt + 1) >= 7'd47) begin
                        mdio_oe <= 0;
                        sampling <= 1;
                    end
                end
            end
            if (sampling) rd_data <= {rd_data[14:0], mdio};
        end
    end

    // 计算第 n 拍要驱动的 bit（n 从 1 起）
    function next_bit;
        input [6:0] n;
        begin
            casez (n)
                7'd32:    next_bit = 0;                       // ST[0]
                7'd33:    next_bit = 1;                       // ST[1]
                7'd34:    next_bit = op;                      // OP[1]
                7'd35:    next_bit = ~op;                     // OP[0]
                7'd36:    next_bit = phy_addr[4];
                7'd37:    next_bit = phy_addr[3];
                7'd38:    next_bit = phy_addr[2];
                7'd39:    next_bit = phy_addr[1];
                7'd40:    next_bit = phy_addr[0];
                7'd41:    next_bit = reg_addr[4];
                7'd42:    next_bit = reg_addr[3];
                7'd43:    next_bit = reg_addr[2];
                7'd44:    next_bit = reg_addr[1];
                7'd45:    next_bit = reg_addr[0];
                7'd46:    next_bit = 1;                       // TA[0]（写）
                7'd47:    next_bit = 0;                       // TA[1]（写=0，读=Z）
                7'd48:    next_bit = wr_data[15];
                7'd49:    next_bit = wr_data[14];
                7'd50:    next_bit = wr_data[13];
                7'd51:    next_bit = wr_data[12];
                7'd52:    next_bit = wr_data[11];
                7'd53:    next_bit = wr_data[10];
                7'd54:    next_bit = wr_data[9];
                7'd55:    next_bit = wr_data[8];
                7'd56:    next_bit = wr_data[7];
                7'd57:    next_bit = wr_data[6];
                7'd58:    next_bit = wr_data[5];
                7'd59:    next_bit = wr_data[4];
                7'd60:    next_bit = wr_data[3];
                7'd61:    next_bit = wr_data[2];
                7'd62:    next_bit = wr_data[1];
                7'd63:    next_bit = wr_data[0];
                default: next_bit = 1;                       // preamble
            endcase
        end
    endfunction

    assign mdio = mdio_oe ? mdio_out : 1'bz;
endmodule
