//============================================================================
// mdio_ctrl.v : MDIO 总线读写接口 (Clause 22), 用于配置 PHY 寄存器
//----------------------------------------------------------------------------
// 时钟   : clk = 50MHz, 内部分频产生 MDC = 2.5MHz (Clause 22 规定的最高速率)
// 帧格式 : 64 位串行帧, MSB 在先
//          [0 :31] Preamble : 32 个 1
//          [32:33] ST       = 01
//          [34:35] OP       = 写 01 / 读 10   (op=0 写, op=1 读)
//          [36:40] PHYAD[4:0]
//          [41:45] REGAD[4:0]
//          [46:47] TA       : 写 = 10 (主机驱动); 读 = ZZ (双方释放)
//          [48:63] DATA[15:0]
// 时序   : 数据在 MDC 下降沿之后改变, 在 MDC 上升沿采样 (标准规定)
//          状态机在下降沿推进/驱动新数据, 在上升沿采样读数据
// 用法   : start 单拍脉冲启动一次操作, busy 置 1;
//          操作结束给出单拍 done 脉冲, 读操作时 rd_data 在 done 拍有效
//          busy 期间新的 start 被忽略, 上层需等 done 后再发下一次操作
//
// 本版修复的 3 个 bug :
//   1) [主 bug] 原代码 if(sampling) rd_data <= {rd_data[14:0], mdio} 每个 clk
//      都移位一次 —— 一个位周期 = 20 个 clk, 每位被重复移入 20 次, 16 位数据
//      全部被冲掉; 且 sampling 置 1 后从不清零, 操作结束后 rd_data 一直漂移。
//      现改为仅在 MDC 上升沿采样一次, 每次读操作恰好采样 16 位,
//      并在操作结束/新操作启动/复位时清掉 sampling
//   2) 读操作的第 1 个 TA 拍 (bit46) 原来仍驱动 1, 规范要求读时 TA 为 ZZ;
//      现改为读操作从 bit46 起释放总线 (写操作不受影响, 仍驱动 10)
//   3) 采样时刻由 "任意 clk" 改为 "MDC 上升沿后 1 拍" (mdc_rise 脉冲),
//      此时 PHY 已稳定驱动当前位, 采样点最可靠
//============================================================================
module mdio_ctrl (
    input  wire        clk,          // 50MHz  系统时钟50MHz由板载 Crystal oscillator 晶振提供
    input  wire        rst_n,
    output wire        mdc,
    inout  wire        mdio,          //MDIO 总线两根线。MDC 是主机给 PHY 的参考时钟；MDIO 是双向线——写时主机驱动、读时 PHY 驱动， 所以必须是 inout（三态）。
    input  wire        start,        // 单拍脉冲：启动一次操作  //start 用单拍脉冲而不是电平：状态机只在空闲时抓一次（start && !running）， 若是电平，一帧跑完会被再次误触发。
    input  wire        op,           // 0=写 1=读
    input  wire [4:0]  phy_addr,
    input  wire [4:0]  reg_addr,
    input  wire [15:0] wr_data,
    output reg  [15:0] rd_data,
    output reg         busy,         //busy=1 期间外部别再发 start；
    output reg         done          //done 是单拍脉冲， 它为高的那一拍 rd_data 有效。
);
    // ---- MDC 生成：50MHz -> 2.5MHz ----
    reg [4:0] div_cnt;
    reg       mdc_r;
    reg       mdc_fall;      // MDC 下降沿脉冲：推进状态机 / 驱动新数据
    reg       mdc_rise;      // MDC 上升沿脉冲：采样 PHY 返回的数据

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 0; mdc_r <= 0; mdc_fall <= 0; mdc_rise <= 0;
        end else begin
            mdc_fall <= 0;
            mdc_rise <= 0;
            if (div_cnt == 5'd9) begin      //数到 9（0~9 共 10 拍）翻转一次 mdc_r：MDC 半周期 = 10×20ns = 200ns， 全周期 400ns = 2.5MHz。
                div_cnt <= 0; mdc_r <= ~mdc_r;
                if (mdc_r) mdc_fall <= 1;    // 旧值1->翻转为0 : 下降沿
                else       mdc_rise <= 1;    // 旧值0->翻转为1 : 上升沿
            end else
                div_cnt <= div_cnt + 1;
        end
    end
    assign mdc = mdc_r;

    // ---- 帧位序列（64 bit）----  //帧状态机
    // bit 0..31  preamble=1
    // bit 32..33 ST=01
    // bit 34..35 OP={op,~op}   写=01 读=10
    // bit 36..40 PHYAD[4:0]
    // bit 41..45 REGAD[4:0]
    // bit 46..47 TA（读时两拍均释放总线）
    // bit 48..63 DATA[15:0]
    reg [6:0] bit_cnt;       //帧内位计数 0~63
    reg       running;       //一帧进行中
    reg       mdio_oe;       //主机是否驱动 mdio（三态使能）
    reg       mdio_out;      //主机驱动出去的电平
    reg       sampling;      // DATA 段采样使能 (仅读操作置位)   //读数据接收窗口   //注意没有用 64bit 大移位寄存器，而是“1 个计数器 + 组合查表”逐位产生，原因见第 4 节。

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0; bit_cnt <= 0; mdio_oe <= 0; mdio_out <= 0;
            sampling <= 0; busy <= 0; done <= 0; rd_data <= 0;
        end else begin
            done <= 0;                              //每拍先把 done 清零，帧结束那一拍再置 1（同一 always 块里后面的赋值覆盖前面的）—— 这样就做出了单拍脉冲。
            if (start && !running) begin            //!running：正在跑帧时忽略新 start（防重入）。
                running <= 1; bit_cnt <= 0; busy <= 1;
                mdio_oe <= 1; mdio_out <= 1;        // preamble 首位
                sampling <= 0;                      // 清残留采样状态
            end else if (running && mdc_fall) begin
                if (bit_cnt == 7'd63) begin
                    running <= 0; busy <= 0; done <= 1; mdio_oe <= 0;
                    sampling <= 0;                  // 操作结束, 停止采样
                end else begin
                    bit_cnt <= bit_cnt + 1;
                    mdio_out <= next_bit(bit_cnt + 1);
                    // 读操作：从 TA 第 1 拍 (bit46) 起释放总线
                    // (规范要求读时 TA=ZZ; bit47、bit48..63 由 PHY 驱动)
                    if (op && (bit_cnt + 1) == 7'd46)
                        mdio_oe <= 0;
                    // 读操作：进入首个 DATA 拍 (bit48) 前使能采样,
                    // 随后的 16 个 MDC 上升沿恰好采入 16 位数据
                    if (op && (bit_cnt + 1) == 7'd48)
                        sampling <= 1;
                end
            end
            // 仅在 MDC 上升沿采样一次 (每位一个采样点)：
            // PHY 在下降沿之后改变 MDIO, 上升沿处数据稳定
            // 读序 MSB 在先, 首采样本 (DATA[15]) 移位 15 次后落在 rd_data[15]
            if (sampling && mdc_rise)
                rd_data <= {rd_data[14:0], mdio};
        end
    end
    
    // ---- 把“第 n 位”翻译成电平----
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
                7'd46:    next_bit = 1;                       // TA[0]（写; 读时 mdio_oe=0, 呈 Z）
                7'd47:    next_bit = 0;                       // TA[1]（写=0, 读=Z）
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

//============================================================================
// 例化示例 (顶层 / PHY 配置状态机) :
//
//   mdio_ctrl u_mdio_ctrl (
//       .clk      (clk_50m),         // 50MHz
//       .rst_n    (sys_rst_n),
//       .mdc      (phy_mdc),         // 接 PHY 的 MDC 引脚
//       .mdio     (phy_mdio),        // 接 PHY 的 MDIO 引脚 (inout, 需上拉)
//       .start    (mdio_start),      // 单拍脉冲
//       .op       (mdio_op),         // 0=写 1=读
//       .phy_addr (mdio_phy_addr),   // PHY 地址, 由硬件 strap 决定
//       .reg_addr (mdio_reg_addr),
//       .wr_data  (mdio_wr_data),
//       .rd_data  (mdio_rd_data),
//       .busy     (mdio_busy),
//       .done     (mdio_done)
//   );
//
// 使用要点 :
//   1. busy=1 期间的 start 被忽略, 上层配置状态机必须等 done 后再发起下一次
//   2. 读操作在 done 拍读 rd_data
//   3. 典型配置序列 (上层状态机) :
//        reg0  写 0x8000          软复位, 等待若干 ms
//        regXX 写 ...             按 PHY 手册使能 RGMII 延迟 (RGMII-ID)
//        reg9  写 0x0200 等       1000M 自协商通告
//        reg0  写 0x1200/0x1140   重启自协商 + 使能
//        reg1  读, 轮询 bit[2]    链路建立
//        reg17/reg31 读等         读协商结果/速度指示 (依 PHY 型号)
//============================================================================
