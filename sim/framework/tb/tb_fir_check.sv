// tb_fir_check.sv — 8 符号，打印 40 个输出，理解多相顺序
`timescale 1ns/1ps
module tb_fir_check;
    logic clk = 1'b0; logic rst_n = 1'b0;
    always #5 clk = ~clk;
    logic din_valid; logic [15:0] din_i, din_q;
    int cyc = 0; int sym = 0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin din_valid<=1'b0; din_i<='0; din_q<='0; cyc<=0; sym<=0; end
        else begin
            cyc <= cyc + 1;
            if (sym < 8 && cyc >= 2 && (cyc - 2) % 4 == 0) begin
                din_valid<=1'b1; din_i<=16'h02D4; din_q<=16'h02D4;
                sym <= sym + 1;
            end else din_valid<=1'b0;
        end
    end
    logic i_rdy, i_vout; logic [15:0] i_dout;
    fir_srrc u_fir_i (.aresetn(rst_n),.aclk(clk),
        .s_axis_data_tvalid(din_valid),.s_axis_data_tready(i_rdy),
        .s_axis_data_tdata(din_i),
        .m_axis_data_tvalid(i_vout),.m_axis_data_tdata(i_dout));
    int out_cnt = 0;
    always_ff @(posedge clk) begin
        if (rst_n && i_vout && out_cnt < 70) begin
            $display("[FIR] %0d  I=%0d", out_cnt, $signed(i_dout[12:0]));
            out_cnt <= out_cnt + 1;
        end
    end
    initial begin #30 rst_n=1'b1; #6000 $finish; end
endmodule
