//---------------------------------------------------------------
// ad9363_regs_def.vh
// AD9363 SPI 行为模型 - 寄存器默认值/访问属性表 (自动生成, 勿手改)
//
// 数据来源:
//   * UG-672 (AD9364 Register Map, ADI) —— AD9361/03/64 同族寄存器映射
//   * ADI no-OS 驱动 ad9361.c/.h —— Product ID(0x037)=0x08 等覆盖项
//   * 数据手册 '0x--' 默认值(温度/ADC读数等动态只读量)按 0x00 建模
//
// 本文件被 ad9363_spi_model.sv 的 initial 块 include,
// 依赖模型中已定义: regs_def[0:1023], acc[0:1023],
//   localparam ACC_RSVD/ACC_RW/ACC_RO
//---------------------------------------------------------------
    regs_def[10'h000] = 8'h00;  acc[10'h000] = ACC_RW;  // SPI
    regs_def[10'h001] = 8'h00;  acc[10'h001] = ACC_RW;  // Multichip
    regs_def[10'h002] = 8'h5F;  acc[10'h002] = ACC_RW;  // Tx
    regs_def[10'h003] = 8'h5F;  acc[10'h003] = ACC_RW;  // Rx
    regs_def[10'h004] = 8'h00;  acc[10'h004] = ACC_RW;  // Input
    regs_def[10'h005] = 8'h00;  acc[10'h005] = ACC_RW;  // RFPLL
    regs_def[10'h006] = 8'h00;  acc[10'h006] = ACC_RW;  // Rx
    regs_def[10'h007] = 8'h00;  acc[10'h007] = ACC_RW;  // Tx
    regs_def[10'h009] = 8'h10;  acc[10'h009] = ACC_RW;  // Clock
    regs_def[10'h00A] = 8'h03;  acc[10'h00A] = ACC_RW;  // BBPLL
    regs_def[10'h00B] = 8'h00;  acc[10'h00B] = ACC_RW;  // Offset
    regs_def[10'h00C] = 8'h00;  acc[10'h00C] = ACC_RW;  // Start  // undefined-default(0x--) -> 0x00
    regs_def[10'h00D] = 8'h03;  acc[10'h00D] = ACC_RW;  // Temp
    regs_def[10'h00E] = 8'h00;  acc[10'h00E] = ACC_RO;  // Temperature  // undefined-default(0x--) -> 0x00
    regs_def[10'h00F] = 8'h04;  acc[10'h00F] = ACC_RW;  // Temp
    regs_def[10'h010] = 8'hC0;  acc[10'h010] = ACC_RW;  // Parallel
    regs_def[10'h011] = 8'h00;  acc[10'h011] = ACC_RW;  // Parallel
    regs_def[10'h012] = 8'h04;  acc[10'h012] = ACC_RW;  // Parallel
    regs_def[10'h013] = 8'h01;  acc[10'h013] = ACC_RW;  // ENSM
    regs_def[10'h014] = 8'h13;  acc[10'h014] = ACC_RW;  // ENSM
    regs_def[10'h015] = 8'h08;  acc[10'h015] = ACC_RW;  // ENSM
    regs_def[10'h016] = 8'h00;  acc[10'h016] = ACC_RW;  // Calibration
    regs_def[10'h017] = 8'h00;  acc[10'h017] = ACC_RO;  // State  // undefined-default(0x--) -> 0x00
    regs_def[10'h018] = 8'h00;  acc[10'h018] = ACC_RW;  // AuxDAC
    regs_def[10'h019] = 8'h00;  acc[10'h019] = ACC_RW;  // AuxDAC
    regs_def[10'h01A] = 8'h00;  acc[10'h01A] = ACC_RW;  // AuxDAC
    regs_def[10'h01B] = 8'h00;  acc[10'h01B] = ACC_RW;  // AuxDAC
    regs_def[10'h01C] = 8'h10;  acc[10'h01C] = ACC_RW;  // AuxADC
    regs_def[10'h01D] = 8'h01;  acc[10'h01D] = ACC_RW;  // Aux
    regs_def[10'h01E] = 8'h00;  acc[10'h01E] = ACC_RO;  // AuxADC  // undefined-default(0x--) -> 0x00
    regs_def[10'h01F] = 8'h00;  acc[10'h01F] = ACC_RO;  // AuxADC  // undefined-default(0x--) -> 0x00
    regs_def[10'h020] = 8'h33;  acc[10'h020] = ACC_RW;  // Auto
    regs_def[10'h021] = 8'h0A;  acc[10'h021] = ACC_RW;  // AGC
    regs_def[10'h022] = 8'h0A;  acc[10'h022] = ACC_RW;  // AGC
    regs_def[10'h023] = 8'h3F;  acc[10'h023] = ACC_RW;  // AuxDAC
    regs_def[10'h024] = 8'h02;  acc[10'h024] = ACC_RW;  // Rx
    regs_def[10'h025] = 8'h02;  acc[10'h025] = ACC_RW;  // Tx
    regs_def[10'h026] = 8'h00;  acc[10'h026] = ACC_RW;  // External
    regs_def[10'h027] = 8'h03;  acc[10'h027] = ACC_RW;  // GPO
    regs_def[10'h028] = 8'h00;  acc[10'h028] = ACC_RW;  // GPO0
    regs_def[10'h029] = 8'h00;  acc[10'h029] = ACC_RW;  // GPO1
    regs_def[10'h02A] = 8'h00;  acc[10'h02A] = ACC_RW;  // GPO2
    regs_def[10'h02B] = 8'h00;  acc[10'h02B] = ACC_RW;  // GPO3
    regs_def[10'h02C] = 8'h00;  acc[10'h02C] = ACC_RW;  // GPO0
    regs_def[10'h02D] = 8'h00;  acc[10'h02D] = ACC_RW;  // GPO1
    regs_def[10'h02E] = 8'h00;  acc[10'h02E] = ACC_RW;  // GPO2
    regs_def[10'h02F] = 8'h00;  acc[10'h02F] = ACC_RW;  // GPO3
    regs_def[10'h030] = 8'h00;  acc[10'h030] = ACC_RW;  // AuxDAC1
    regs_def[10'h031] = 8'h00;  acc[10'h031] = ACC_RW;  // AuxDAC1
    regs_def[10'h032] = 8'h00;  acc[10'h032] = ACC_RW;  // AuxDAC2
    regs_def[10'h033] = 8'h00;  acc[10'h033] = ACC_RW;  // AuxDAC2
    regs_def[10'h035] = 8'h00;  acc[10'h035] = ACC_RW;  // Control
    regs_def[10'h036] = 8'hFF;  acc[10'h036] = ACC_RW;  // Control
    regs_def[10'h037] = 8'h08;  acc[10'h037] = ACC_RO;  // Product_ID
    regs_def[10'h03A] = 8'h00;  acc[10'h03A] = ACC_RW;  // Reference
    regs_def[10'h03B] = 8'h00;  acc[10'h03B] = ACC_RW;  // Digital
    regs_def[10'h03C] = 8'h03;  acc[10'h03C] = ACC_RW;  // LVDS
    regs_def[10'h03D] = 8'h00;  acc[10'h03D] = ACC_RW;  // LVDS
    regs_def[10'h03E] = 8'h00;  acc[10'h03E] = ACC_RW;  // LVDS
    regs_def[10'h03F] = 8'h01;  acc[10'h03F] = ACC_RW;  // BBPLL
    regs_def[10'h040] = 8'h00;  acc[10'h040] = ACC_RW;  // Must
    regs_def[10'h041] = 8'h00;  acc[10'h041] = ACC_RW;  // Fractional
    regs_def[10'h042] = 8'h00;  acc[10'h042] = ACC_RW;  // Fractional
    regs_def[10'h043] = 8'h00;  acc[10'h043] = ACC_RW;  // Fractional
    regs_def[10'h044] = 8'h10;  acc[10'h044] = ACC_RW;  // Integer
    regs_def[10'h045] = 8'h00;  acc[10'h045] = ACC_RW;  // Ref
    regs_def[10'h046] = 8'h09;  acc[10'h046] = ACC_RW;  // CP
    regs_def[10'h047] = 8'h00;  acc[10'h047] = ACC_RW;  // MCS
    regs_def[10'h048] = 8'hC5;  acc[10'h048] = ACC_RW;  // Loop
    regs_def[10'h049] = 8'hB8;  acc[10'h049] = ACC_RW;  // Loop
    regs_def[10'h04A] = 8'h2E;  acc[10'h04A] = ACC_RW;  // Loop
    regs_def[10'h04B] = 8'hC0;  acc[10'h04B] = ACC_RW;  // VCO
    regs_def[10'h04C] = 8'h00;  acc[10'h04C] = ACC_RW;  // Must
    regs_def[10'h04D] = 8'h00;  acc[10'h04D] = ACC_RW;  // BBPLL
    regs_def[10'h04E] = 8'h00;  acc[10'h04E] = ACC_RW;  // BBPLL
    regs_def[10'h050] = 8'h00;  acc[10'h050] = ACC_RW;  // Rx
    regs_def[10'h051] = 8'h00;  acc[10'h051] = ACC_RW;  // Tx
    regs_def[10'h052] = 8'h03;  acc[10'h052] = ACC_RW;  // Control
    regs_def[10'h053] = 8'h00;  acc[10'h053] = ACC_RW;  // Must
    regs_def[10'h054] = 8'h00;  acc[10'h054] = ACC_RW;  // Rx
    regs_def[10'h055] = 8'h00;  acc[10'h055] = ACC_RW;  // Open
    regs_def[10'h056] = 8'h00;  acc[10'h056] = ACC_RW;  // Tx
    regs_def[10'h057] = 8'h3C;  acc[10'h057] = ACC_RW;  // Analog
    regs_def[10'h058] = 8'h30;  acc[10'h058] = ACC_RW;  // Misc
    regs_def[10'h05E] = 8'h00;  acc[10'h05E] = ACC_RO;  // CH  // undefined-default(0x--) -> 0x00
    regs_def[10'h060] = 8'h00;  acc[10'h060] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h061] = 8'h00;  acc[10'h061] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h062] = 8'h00;  acc[10'h062] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h063] = 8'h00;  acc[10'h063] = ACC_RO;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h064] = 8'h00;  acc[10'h064] = ACC_RO;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h065] = 8'h00;  acc[10'h065] = ACC_RW;  // Tx
    regs_def[10'h067] = 8'h13;  acc[10'h067] = ACC_RW;  // Tx
    regs_def[10'h068] = 8'h18;  acc[10'h068] = ACC_RW;  // Tx
    regs_def[10'h069] = 8'h00;  acc[10'h069] = ACC_RW;  // Tx
    regs_def[10'h06A] = 8'h00;  acc[10'h06A] = ACC_RW;  // Tx
    regs_def[10'h06B] = 8'h00;  acc[10'h06B] = ACC_RO;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h06C] = 8'h00;  acc[10'h06C] = ACC_RO;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h06D] = 8'h00;  acc[10'h06D] = ACC_RO;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h06E] = 8'hA9;  acc[10'h06E] = ACC_RW;  // TPM
    regs_def[10'h06F] = 8'h00;  acc[10'h06F] = ACC_RW;  // Temp
    regs_def[10'h070] = 8'hC1;  acc[10'h070] = ACC_RW;  // Tx
    regs_def[10'h073] = 8'h00;  acc[10'h073] = ACC_RW;  // Tx
    regs_def[10'h074] = 8'h00;  acc[10'h074] = ACC_RW;  // Tx
    regs_def[10'h075] = 8'h00;  acc[10'h075] = ACC_RW;  // Open
    regs_def[10'h076] = 8'h00;  acc[10'h076] = ACC_RW;  // Open
    regs_def[10'h077] = 8'h40;  acc[10'h077] = ACC_RW;  // Tx
    regs_def[10'h078] = 8'h3C;  acc[10'h078] = ACC_RW;  // Tx
    regs_def[10'h079] = 8'h00;  acc[10'h079] = ACC_RW;  // Open
    regs_def[10'h07A] = 8'h00;  acc[10'h07A] = ACC_RW;  // Open
    regs_def[10'h07B] = 8'h00;  acc[10'h07B] = ACC_RW;  // Open
    regs_def[10'h07C] = 8'h00;  acc[10'h07C] = ACC_RW;  // Immediate
    regs_def[10'h08E] = 8'h00;  acc[10'h08E] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h08F] = 8'h00;  acc[10'h08F] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h090] = 8'h00;  acc[10'h090] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h091] = 8'h00;  acc[10'h091] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h092] = 8'h00;  acc[10'h092] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h093] = 8'h00;  acc[10'h093] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h094] = 8'h00;  acc[10'h094] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h095] = 8'h00;  acc[10'h095] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h096] = 8'h00;  acc[10'h096] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h097] = 8'h00;  acc[10'h097] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h098] = 8'h00;  acc[10'h098] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h099] = 8'h00;  acc[10'h099] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h09A] = 8'h00;  acc[10'h09A] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h09B] = 8'h00;  acc[10'h09B] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h09C] = 8'h00;  acc[10'h09C] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h09D] = 8'h00;  acc[10'h09D] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h09E] = 8'h00;  acc[10'h09E] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h09F] = 8'h00;  acc[10'h09F] = ACC_RW;  // Force
    regs_def[10'h0A0] = 8'h0C;  acc[10'h0A0] = ACC_RW;  // Quad
    regs_def[10'h0A1] = 8'h78;  acc[10'h0A1] = ACC_RW;  // Quad
    regs_def[10'h0A2] = 8'h1F;  acc[10'h0A2] = ACC_RW;  // Set
    regs_def[10'h0A3] = 8'h00;  acc[10'h0A3] = ACC_RW;  // Tx
    regs_def[10'h0A4] = 8'h10;  acc[10'h0A4] = ACC_RW;  // Set
    regs_def[10'h0A5] = 8'h06;  acc[10'h0A5] = ACC_RW;  // Mag
    regs_def[10'h0A6] = 8'h06;  acc[10'h0A6] = ACC_RW;  // Open
    regs_def[10'h0A7] = 8'h00;  acc[10'h0A7] = ACC_RO;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h0A8] = 8'h00;  acc[10'h0A8] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h0A9] = 8'h20;  acc[10'h0A9] = ACC_RW;  // Set
    regs_def[10'h0AA] = 8'h0A;  acc[10'h0AA] = ACC_RW;  // Tx
    regs_def[10'h0AB] = 8'h00;  acc[10'h0AB] = ACC_RW;  // Must
    regs_def[10'h0AC] = 8'h00;  acc[10'h0AC] = ACC_RW;  // Must
    regs_def[10'h0AD] = 8'h00;  acc[10'h0AD] = ACC_RW;  // Must
    regs_def[10'h0AE] = 8'h18;  acc[10'h0AE] = ACC_RW;  // Tx
    regs_def[10'h0C2] = 8'h1F;  acc[10'h0C2] = ACC_RW;  // Tx
    regs_def[10'h0C3] = 8'h1F;  acc[10'h0C3] = ACC_RW;  // Tx
    regs_def[10'h0C4] = 8'h1F;  acc[10'h0C4] = ACC_RW;  // Tx
    regs_def[10'h0C5] = 8'h1F;  acc[10'h0C5] = ACC_RW;  // Tx
    regs_def[10'h0C6] = 8'h1F;  acc[10'h0C6] = ACC_RW;  // Tx
    regs_def[10'h0C7] = 8'h2A;  acc[10'h0C7] = ACC_RW;  // Tx
    regs_def[10'h0C8] = 8'h2A;  acc[10'h0C8] = ACC_RW;  // Tx
    regs_def[10'h0C9] = 8'h2A;  acc[10'h0C9] = ACC_RW;  // Tx
    regs_def[10'h0CA] = 8'h20;  acc[10'h0CA] = ACC_RW;  // Tuner
    regs_def[10'h0CB] = 8'h00;  acc[10'h0CB] = ACC_RW;  // Tx
    regs_def[10'h0D0] = 8'h55;  acc[10'h0D0] = ACC_RW;  // Config0
    regs_def[10'h0D1] = 8'h0F;  acc[10'h0D1] = ACC_RW;  // Resistor
    regs_def[10'h0D2] = 8'h1F;  acc[10'h0D2] = ACC_RW;  // Capacitor
    regs_def[10'h0D3] = 8'h60;  acc[10'h0D3] = ACC_RW;  // Must
    regs_def[10'h0D6] = 8'h12;  acc[10'h0D6] = ACC_RW;  // Tx
    regs_def[10'h0D7] = 8'h1E;  acc[10'h0D7] = ACC_RW;  // Tx
    regs_def[10'h0F0] = 8'h00;  acc[10'h0F0] = ACC_RW;  // Rx  // undefined-default(0x--) -> 0x00
    regs_def[10'h0F1] = 8'h00;  acc[10'h0F1] = ACC_RW;  // Rx  // undefined-default(0x--) -> 0x00
    regs_def[10'h0F2] = 8'h00;  acc[10'h0F2] = ACC_RW;  // Rx  // undefined-default(0x--) -> 0x00
    regs_def[10'h0F3] = 8'h00;  acc[10'h0F3] = ACC_RO;  // Rx  // undefined-default(0x--) -> 0x00
    regs_def[10'h0F4] = 8'h00;  acc[10'h0F4] = ACC_RO;  // Rx  // undefined-default(0x--) -> 0x00
    regs_def[10'h0F5] = 8'h00;  acc[10'h0F5] = ACC_RW;  // Rx
    regs_def[10'h0F6] = 8'h00;  acc[10'h0F6] = ACC_RW;  // Rx
    regs_def[10'h0FA] = 8'hE0;  acc[10'h0FA] = ACC_RW;  // AGC
    regs_def[10'h0FB] = 8'h08;  acc[10'h0FB] = ACC_RW;  // AGC
    regs_def[10'h0FC] = 8'h03;  acc[10'h0FC] = ACC_RW;  // AGC
    regs_def[10'h0FD] = 8'h4C;  acc[10'h0FD] = ACC_RW;  // Max
    regs_def[10'h0FE] = 8'h44;  acc[10'h0FE] = ACC_RW;  // Peak
    regs_def[10'h0FF] = 8'h00;  acc[10'h0FF] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h100] = 8'h6F;  acc[10'h100] = ACC_RW;  // Digital
    regs_def[10'h101] = 8'h0A;  acc[10'h101] = ACC_RW;  // AGC
    regs_def[10'h102] = 8'h00;  acc[10'h102] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h103] = 8'h08;  acc[10'h103] = ACC_RW;  // Gain
    regs_def[10'h104] = 8'h2F;  acc[10'h104] = ACC_RW;  // ADC
    regs_def[10'h105] = 8'h3A;  acc[10'h105] = ACC_RW;  // ADC
    regs_def[10'h106] = 8'h25;  acc[10'h106] = ACC_RW;  // Gain
    regs_def[10'h107] = 8'h3F;  acc[10'h107] = ACC_RW;  // Small
    regs_def[10'h108] = 8'h1F;  acc[10'h108] = ACC_RW;  // Large
    regs_def[10'h109] = 8'h4C;  acc[10'h109] = ACC_RW;  // Manual
    regs_def[10'h10A] = 8'h58;  acc[10'h10A] = ACC_RW;  // Manual
    regs_def[10'h10B] = 8'h00;  acc[10'h10B] = ACC_RW;  // Manual
    regs_def[10'h110] = 8'h02;  acc[10'h110] = ACC_RW;  // Config
    regs_def[10'h111] = 8'hCA;  acc[10'h111] = ACC_RW;  // Config
    regs_def[10'h112] = 8'h4A;  acc[10'h112] = ACC_RW;  // Energy
    regs_def[10'h113] = 8'h4A;  acc[10'h113] = ACC_RW;  // Stronger
    regs_def[10'h114] = 8'h80;  acc[10'h114] = ACC_RW;  // Low
    regs_def[10'h115] = 8'h64;  acc[10'h115] = ACC_RW;  // Strong
    regs_def[10'h116] = 8'h65;  acc[10'h116] = ACC_RW;  // Final
    regs_def[10'h117] = 8'h08;  acc[10'h117] = ACC_RW;  // Energy
    regs_def[10'h118] = 8'h3F;  acc[10'h118] = ACC_RW;  // AGCLL
    regs_def[10'h119] = 8'h08;  acc[10'h119] = ACC_RW;  // Gain
    regs_def[10'h11A] = 8'h1C;  acc[10'h11A] = ACC_RW;  // Initial
    regs_def[10'h11B] = 8'h0A;  acc[10'h11B] = ACC_RW;  // Increment
    regs_def[10'h120] = 8'h00;  acc[10'h120] = ACC_RW;  // AGC  // undefined-default(0x--) -> 0x00
    regs_def[10'h121] = 8'h00;  acc[10'h121] = ACC_RW;  // LMT  // undefined-default(0x--) -> 0x00
    regs_def[10'h122] = 8'h00;  acc[10'h122] = ACC_RW;  // ADC  // undefined-default(0x--) -> 0x00
    regs_def[10'h123] = 8'h00;  acc[10'h123] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h124] = 8'h00;  acc[10'h124] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h125] = 8'h00;  acc[10'h125] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h126] = 8'h00;  acc[10'h126] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h127] = 8'h00;  acc[10'h127] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h128] = 8'h00;  acc[10'h128] = ACC_RW;  // Digital  // undefined-default(0x--) -> 0x00
    regs_def[10'h129] = 8'h00;  acc[10'h129] = ACC_RW;  // Outer  // undefined-default(0x--) -> 0x00
    regs_def[10'h12A] = 8'h00;  acc[10'h12A] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h12C] = 8'h00;  acc[10'h12C] = ACC_RW;  // Ext  // undefined-default(0x--) -> 0x00
    regs_def[10'h12D] = 8'h00;  acc[10'h12D] = ACC_RW;  // Ext
    regs_def[10'h130] = 8'h00;  acc[10'h130] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h131] = 8'h00;  acc[10'h131] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h132] = 8'h00;  acc[10'h132] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h133] = 8'h00;  acc[10'h133] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h134] = 8'h00;  acc[10'h134] = ACC_RO;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h135] = 8'h00;  acc[10'h135] = ACC_RO;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h136] = 8'h00;  acc[10'h136] = ACC_RO;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h137] = 8'h08;  acc[10'h137] = ACC_RW;  // Gain
    regs_def[10'h138] = 8'h00;  acc[10'h138] = ACC_RW;  // Mixer  // undefined-default(0x--) -> 0x00
    regs_def[10'h139] = 8'h00;  acc[10'h139] = ACC_RW;  // Mixer  // undefined-default(0x--) -> 0x00
    regs_def[10'h13A] = 8'h00;  acc[10'h13A] = ACC_RW;  // Mixer  // undefined-default(0x--) -> 0x00
    regs_def[10'h13B] = 8'h00;  acc[10'h13B] = ACC_RW;  // Mixer  // undefined-default(0x--) -> 0x00
    regs_def[10'h13C] = 8'h00;  acc[10'h13C] = ACC_RO;  // Mixer  // undefined-default(0x--) -> 0x00
    regs_def[10'h13D] = 8'h00;  acc[10'h13D] = ACC_RO;  // Mixer  // undefined-default(0x--) -> 0x00
    regs_def[10'h13E] = 8'h00;  acc[10'h13E] = ACC_RO;  // Mixer  // undefined-default(0x--) -> 0x00
    regs_def[10'h13F] = 8'h00;  acc[10'h13F] = ACC_RW;  // Mixer
    regs_def[10'h140] = 8'h00;  acc[10'h140] = ACC_RW;  // Word  // undefined-default(0x--) -> 0x00
    regs_def[10'h141] = 8'h00;  acc[10'h141] = ACC_RW;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h142] = 8'h00;  acc[10'h142] = ACC_RO;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h143] = 8'h00;  acc[10'h143] = ACC_RW;  // Config
    regs_def[10'h144] = 8'h00;  acc[10'h144] = ACC_RO;  // LNA  // undefined-default(0x--) -> 0x00
    regs_def[10'h145] = 8'h0B;  acc[10'h145] = ACC_RW;  // Max
    regs_def[10'h146] = 8'h00;  acc[10'h146] = ACC_RW;  // Temp
    regs_def[10'h147] = 8'h10;  acc[10'h147] = ACC_RW;  // Settle
    regs_def[10'h148] = 8'h04;  acc[10'h148] = ACC_RW;  // Measure
    regs_def[10'h149] = 8'h00;  acc[10'h149] = ACC_RW;  // Cal
    regs_def[10'h150] = 8'h08;  acc[10'h150] = ACC_RW;  // Duration
    regs_def[10'h151] = 8'h00;  acc[10'h151] = ACC_RW;  // Duration  // undefined-default(0x--) -> 0x00
    regs_def[10'h152] = 8'h00;  acc[10'h152] = ACC_RW;  // Weight
    regs_def[10'h153] = 8'h00;  acc[10'h153] = ACC_RW;  // Weight
    regs_def[10'h154] = 8'h00;  acc[10'h154] = ACC_RW;  // Weight
    regs_def[10'h155] = 8'h00;  acc[10'h155] = ACC_RW;  // Weight
    regs_def[10'h156] = 8'h00;  acc[10'h156] = ACC_RW;  // RSSI
    regs_def[10'h157] = 8'h00;  acc[10'h157] = ACC_RW;  // RSSI
    regs_def[10'h158] = 8'h01;  acc[10'h158] = ACC_RW;  // RSSI
    regs_def[10'h159] = 8'h00;  acc[10'h159] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h15A] = 8'h00;  acc[10'h15A] = ACC_RW;  // Open
    regs_def[10'h15B] = 8'h00;  acc[10'h15B] = ACC_RW;  // Open
    regs_def[10'h15C] = 8'h15;  acc[10'h15C] = ACC_RW;  // Dec
    regs_def[10'h15D] = 8'hB1;  acc[10'h15D] = ACC_RW;  // LNA
    regs_def[10'h161] = 8'h00;  acc[10'h161] = ACC_RO;  // CH1  // undefined-default(0x--) -> 0x00
    regs_def[10'h169] = 8'hC0;  acc[10'h169] = ACC_RW;  // Calibration
    regs_def[10'h16A] = 8'h08;  acc[10'h16A] = ACC_RW;  // Must
    regs_def[10'h16B] = 8'h08;  acc[10'h16B] = ACC_RW;  // Must
    regs_def[10'h170] = 8'h00;  acc[10'h170] = ACC_RW;  // RxA  // undefined-default(0x--) -> 0x00
    regs_def[10'h171] = 8'h00;  acc[10'h171] = ACC_RW;  // RxA  // undefined-default(0x--) -> 0x00
    regs_def[10'h172] = 8'h00;  acc[10'h172] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h173] = 8'h00;  acc[10'h173] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h174] = 8'h00;  acc[10'h174] = ACC_RW;  // RxA  // undefined-default(0x--) -> 0x00
    regs_def[10'h175] = 8'h00;  acc[10'h175] = ACC_RW;  // RxA  // undefined-default(0x--) -> 0x00
    regs_def[10'h176] = 8'h00;  acc[10'h176] = ACC_RW;  // Input  // undefined-default(0x--) -> 0x00
    regs_def[10'h177] = 8'h00;  acc[10'h177] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h178] = 8'h00;  acc[10'h178] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h179] = 8'h00;  acc[10'h179] = ACC_RW;  // RxB/C  // undefined-default(0x--) -> 0x00
    regs_def[10'h17A] = 8'h00;  acc[10'h17A] = ACC_RW;  // RxB/C  // undefined-default(0x--) -> 0x00
    regs_def[10'h17B] = 8'h00;  acc[10'h17B] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h17C] = 8'h00;  acc[10'h17C] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h17D] = 8'h00;  acc[10'h17D] = ACC_RW;  // RxB/C  // undefined-default(0x--) -> 0x00
    regs_def[10'h17E] = 8'h00;  acc[10'h17E] = ACC_RW;  // RxB/C  // undefined-default(0x--) -> 0x00
    regs_def[10'h17F] = 8'h00;  acc[10'h17F] = ACC_RW;  // Input  // undefined-default(0x--) -> 0x00
    regs_def[10'h180] = 8'h00;  acc[10'h180] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h181] = 8'h00;  acc[10'h181] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h182] = 8'h00;  acc[10'h182] = ACC_RW;  // Force
    regs_def[10'h185] = 8'h10;  acc[10'h185] = ACC_RW;  // Wait
    regs_def[10'h186] = 8'hB4;  acc[10'h186] = ACC_RW;  // RF
    regs_def[10'h187] = 8'h1C;  acc[10'h187] = ACC_RW;  // RF
    regs_def[10'h188] = 8'h05;  acc[10'h188] = ACC_RW;  // RF
    regs_def[10'h189] = 8'h30;  acc[10'h189] = ACC_RW;  // Must
    regs_def[10'h18A] = 8'hFF;  acc[10'h18A] = ACC_RW;  // Open
    regs_def[10'h18B] = 8'h8D;  acc[10'h18B] = ACC_RW;  // DC
    regs_def[10'h18C] = 8'h00;  acc[10'h18C] = ACC_RW;  // RF
    regs_def[10'h18D] = 8'h64;  acc[10'h18D] = ACC_RW;  // SOI
    regs_def[10'h18E] = 8'h00;  acc[10'h18E] = ACC_RW;  // Open
    regs_def[10'h18F] = 8'h00;  acc[10'h18F] = ACC_RW;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h190] = 8'h0D;  acc[10'h190] = ACC_RW;  // BB
    regs_def[10'h191] = 8'h06;  acc[10'h191] = ACC_RW;  // BB
    regs_def[10'h192] = 8'h03;  acc[10'h192] = ACC_RW;  // BB
    regs_def[10'h193] = 8'h3F;  acc[10'h193] = ACC_RW;  // BB
    regs_def[10'h194] = 8'h01;  acc[10'h194] = ACC_RW;  // BB
    regs_def[10'h19A] = 8'h00;  acc[10'h19A] = ACC_RO;  // BB  // undefined-default(0x--) -> 0x00
    regs_def[10'h19B] = 8'h00;  acc[10'h19B] = ACC_RO;  // BB  // undefined-default(0x--) -> 0x00
    regs_def[10'h19C] = 8'h00;  acc[10'h19C] = ACC_RO;  // BB  // undefined-default(0x--) -> 0x00
    regs_def[10'h19D] = 8'h00;  acc[10'h19D] = ACC_RO;  // BB  // undefined-default(0x--) -> 0x00
    regs_def[10'h19E] = 8'h00;  acc[10'h19E] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h19F] = 8'h00;  acc[10'h19F] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A0] = 8'h00;  acc[10'h1A0] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A1] = 8'h00;  acc[10'h1A1] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A2] = 8'h00;  acc[10'h1A2] = ACC_RO;  // BB  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A3] = 8'h00;  acc[10'h1A3] = ACC_RO;  // BB  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A4] = 8'h00;  acc[10'h1A4] = ACC_RO;  // BB  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A5] = 8'h00;  acc[10'h1A5] = ACC_RO;  // BB  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A7] = 8'h00;  acc[10'h1A7] = ACC_RO;  // RSSI  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A8] = 8'h00;  acc[10'h1A8] = ACC_RO;  // RSSI  // undefined-default(0x--) -> 0x00
    regs_def[10'h1A9] = 8'h00;  acc[10'h1A9] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h1AA] = 8'h00;  acc[10'h1AA] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h1AB] = 8'h00;  acc[10'h1AB] = ACC_RO;  // Symbol  // undefined-default(0x--) -> 0x00
    regs_def[10'h1AC] = 8'h00;  acc[10'h1AC] = ACC_RO;  // Preamble  // undefined-default(0x--) -> 0x00
    regs_def[10'h1DB] = 8'h60;  acc[10'h1DB] = ACC_RW;  // Rx
    regs_def[10'h1DC] = 8'h03;  acc[10'h1DC] = ACC_RW;  // TIA
    regs_def[10'h1DD] = 8'h0B;  acc[10'h1DD] = ACC_RW;  // TIA
    regs_def[10'h1E0] = 8'h03;  acc[10'h1E0] = ACC_RW;  // BBF
    regs_def[10'h1E1] = 8'h03;  acc[10'h1E1] = ACC_RW;  // Open
    regs_def[10'h1E2] = 8'h00;  acc[10'h1E2] = ACC_RW;  // Tune
    regs_def[10'h1E3] = 8'h00;  acc[10'h1E3] = ACC_RW;  // Tune
    regs_def[10'h1E4] = 8'h01;  acc[10'h1E4] = ACC_RW;  // BBF
    regs_def[10'h1E5] = 8'h01;  acc[10'h1E5] = ACC_RW;  // Open
    regs_def[10'h1E6] = 8'h01;  acc[10'h1E6] = ACC_RW;  // Rx
    regs_def[10'h1E7] = 8'h00;  acc[10'h1E7] = ACC_RW;  // Rx
    regs_def[10'h1E8] = 8'h60;  acc[10'h1E8] = ACC_RW;  // Rx
    regs_def[10'h1E9] = 8'h00;  acc[10'h1E9] = ACC_RW;  // Rx
    regs_def[10'h1EA] = 8'h60;  acc[10'h1EA] = ACC_RW;  // Rx
    regs_def[10'h1EB] = 8'h00;  acc[10'h1EB] = ACC_RW;  // Rx
    regs_def[10'h1EC] = 8'h60;  acc[10'h1EC] = ACC_RW;  // Rx
    regs_def[10'h1ED] = 8'h07;  acc[10'h1ED] = ACC_RW;  // Rx
    regs_def[10'h1EE] = 8'h60;  acc[10'h1EE] = ACC_RW;  // Must
    regs_def[10'h1EF] = 8'h07;  acc[10'h1EF] = ACC_RW;  // Rx
    regs_def[10'h1F0] = 8'hCC;  acc[10'h1F0] = ACC_RW;  // Rx
    regs_def[10'h1F1] = 8'h07;  acc[10'h1F1] = ACC_RW;  // Rx
    regs_def[10'h1F2] = 8'h00;  acc[10'h1F2] = ACC_RW;  // Rx
    regs_def[10'h1F3] = 8'h20;  acc[10'h1F3] = ACC_RW;  // Rx
    regs_def[10'h1F4] = 8'h00;  acc[10'h1F4] = ACC_RW;  // BBF
    regs_def[10'h1F8] = 8'h14;  acc[10'h1F8] = ACC_RW;  // Rx
    regs_def[10'h1F9] = 8'h1E;  acc[10'h1F9] = ACC_RW;  // Rx
    regs_def[10'h1FA] = 8'h01;  acc[10'h1FA] = ACC_RW;  // Must
    regs_def[10'h1FB] = 8'h05;  acc[10'h1FB] = ACC_RW;  // Rx
    regs_def[10'h1FC] = 8'h00;  acc[10'h1FC] = ACC_RW;  // Rx
    regs_def[10'h230] = 8'h54;  acc[10'h230] = ACC_RW;  // Disable
    regs_def[10'h231] = 8'h00;  acc[10'h231] = ACC_RW;  // Integer
    regs_def[10'h232] = 8'h00;  acc[10'h232] = ACC_RW;  // Integer
    regs_def[10'h233] = 8'h00;  acc[10'h233] = ACC_RW;  // Fractional
    regs_def[10'h234] = 8'h00;  acc[10'h234] = ACC_RW;  // Fractional
    regs_def[10'h235] = 8'h00;  acc[10'h235] = ACC_RW;  // Fractional
    regs_def[10'h236] = 8'h00;  acc[10'h236] = ACC_RW;  // Force
    regs_def[10'h237] = 8'h00;  acc[10'h237] = ACC_RW;  // Force
    regs_def[10'h238] = 8'h00;  acc[10'h238] = ACC_RW;  // Force
    regs_def[10'h239] = 8'h82;  acc[10'h239] = ACC_RW;  // ALC/Varactor
    regs_def[10'h23A] = 8'h0A;  acc[10'h23A] = ACC_RW;  // VCO
    regs_def[10'h23B] = 8'h00;  acc[10'h23B] = ACC_RW;  // CP
    regs_def[10'h23C] = 8'h00;  acc[10'h23C] = ACC_RW;  // CP
    regs_def[10'h23D] = 8'h80;  acc[10'h23D] = ACC_RW;  // CP
    regs_def[10'h23E] = 8'h00;  acc[10'h23E] = ACC_RW;  // Loop
    regs_def[10'h23F] = 8'h00;  acc[10'h23F] = ACC_RW;  // Loop
    regs_def[10'h240] = 8'h00;  acc[10'h240] = ACC_RW;  // Loop
    regs_def[10'h241] = 8'h00;  acc[10'h241] = ACC_RW;  // Dither/CP
    regs_def[10'h242] = 8'h04;  acc[10'h242] = ACC_RW;  // VCO
    regs_def[10'h243] = 8'h0D;  acc[10'h243] = ACC_RW;  // Must
    regs_def[10'h244] = 8'h00;  acc[10'h244] = ACC_RO;  // Cal  // undefined-default(0x--) -> 0x00
    regs_def[10'h245] = 8'h00;  acc[10'h245] = ACC_RW;  // Must
    regs_def[10'h246] = 8'h00;  acc[10'h246] = ACC_RW;  // Set
    regs_def[10'h247] = 8'h00;  acc[10'h247] = ACC_RO;  // CP  // undefined-default(0x--) -> 0x00
    regs_def[10'h248] = 8'h07;  acc[10'h248] = ACC_RW;  // Set
    regs_def[10'h249] = 8'h02;  acc[10'h249] = ACC_RW;  // VCO
    regs_def[10'h24A] = 8'h02;  acc[10'h24A] = ACC_RW;  // Lock
    regs_def[10'h24B] = 8'h17;  acc[10'h24B] = ACC_RW;  // Must
    regs_def[10'h24C] = 8'h00;  acc[10'h24C] = ACC_RW;  // Must
    regs_def[10'h24D] = 8'h00;  acc[10'h24D] = ACC_RW;  // Must
    regs_def[10'h24E] = 8'h00;  acc[10'h24E] = ACC_RW;  // Open
    regs_def[10'h24F] = 8'h00;  acc[10'h24F] = ACC_RW;  // Open
    regs_def[10'h250] = 8'h63;  acc[10'h250] = ACC_RW;  // Set
    regs_def[10'h251] = 8'h08;  acc[10'h251] = ACC_RW;  // VCO
    regs_def[10'h25A] = 8'h00;  acc[10'h25A] = ACC_RW;  // Rx
    regs_def[10'h25B] = 8'h00;  acc[10'h25B] = ACC_RW;  // Rx
    regs_def[10'h25C] = 8'h00;  acc[10'h25C] = ACC_RW;  // Rx  // undefined-default(0x--) -> 0x00
    regs_def[10'h25D] = 8'h00;  acc[10'h25D] = ACC_RW;  // Rx  // undefined-default(0x--) -> 0x00
    regs_def[10'h25E] = 8'h00;  acc[10'h25E] = ACC_RO;  // Rx  // undefined-default(0x--) -> 0x00
    regs_def[10'h25F] = 8'h00;  acc[10'h25F] = ACC_RW;  // Rx
    regs_def[10'h261] = 8'h00;  acc[10'h261] = ACC_RW;  // Rx
    regs_def[10'h270] = 8'h54;  acc[10'h270] = ACC_RW;  // Disable
    regs_def[10'h271] = 8'h00;  acc[10'h271] = ACC_RW;  // Integer
    regs_def[10'h272] = 8'h00;  acc[10'h272] = ACC_RW;  // Integer
    regs_def[10'h273] = 8'h00;  acc[10'h273] = ACC_RW;  // Fractional
    regs_def[10'h274] = 8'h00;  acc[10'h274] = ACC_RW;  // Fractional
    regs_def[10'h275] = 8'h00;  acc[10'h275] = ACC_RW;  // Fractional
    regs_def[10'h276] = 8'h00;  acc[10'h276] = ACC_RW;  // Force
    regs_def[10'h277] = 8'h00;  acc[10'h277] = ACC_RW;  // Force
    regs_def[10'h278] = 8'h00;  acc[10'h278] = ACC_RW;  // Force
    regs_def[10'h279] = 8'h82;  acc[10'h279] = ACC_RW;  // ALC/Varactor
    regs_def[10'h27A] = 8'h0A;  acc[10'h27A] = ACC_RW;  // VCO
    regs_def[10'h27B] = 8'h00;  acc[10'h27B] = ACC_RW;  // CP
    regs_def[10'h27C] = 8'h00;  acc[10'h27C] = ACC_RW;  // CP
    regs_def[10'h27D] = 8'h80;  acc[10'h27D] = ACC_RW;  // CP
    regs_def[10'h27E] = 8'h00;  acc[10'h27E] = ACC_RW;  // Loop
    regs_def[10'h27F] = 8'h00;  acc[10'h27F] = ACC_RW;  // Loop
    regs_def[10'h280] = 8'h00;  acc[10'h280] = ACC_RW;  // Loop
    regs_def[10'h281] = 8'h00;  acc[10'h281] = ACC_RW;  // Dither/CP
    regs_def[10'h282] = 8'h04;  acc[10'h282] = ACC_RW;  // VCO
    regs_def[10'h283] = 8'h0D;  acc[10'h283] = ACC_RW;  // Must
    regs_def[10'h284] = 8'h00;  acc[10'h284] = ACC_RO;  // Cal  // undefined-default(0x--) -> 0x00
    regs_def[10'h285] = 8'h00;  acc[10'h285] = ACC_RW;  // Must
    regs_def[10'h286] = 8'h00;  acc[10'h286] = ACC_RW;  // Set
    regs_def[10'h287] = 8'h00;  acc[10'h287] = ACC_RO;  // CP  // undefined-default(0x--) -> 0x00
    regs_def[10'h288] = 8'h07;  acc[10'h288] = ACC_RW;  // Set
    regs_def[10'h289] = 8'h02;  acc[10'h289] = ACC_RW;  // VCO
    regs_def[10'h28A] = 8'h02;  acc[10'h28A] = ACC_RW;  // Lock
    regs_def[10'h28B] = 8'h40;  acc[10'h28B] = ACC_RW;  // Must
    regs_def[10'h28C] = 8'h00;  acc[10'h28C] = ACC_RW;  // Must
    regs_def[10'h28D] = 8'h80;  acc[10'h28D] = ACC_RW;  // Must
    regs_def[10'h28E] = 8'h00;  acc[10'h28E] = ACC_RW;  // Open
    regs_def[10'h28F] = 8'h00;  acc[10'h28F] = ACC_RW;  // Open
    regs_def[10'h290] = 8'h63;  acc[10'h290] = ACC_RW;  // Set
    regs_def[10'h291] = 8'h08;  acc[10'h291] = ACC_RW;  // VCO
    regs_def[10'h292] = 8'h00;  acc[10'h292] = ACC_RW;  // DCXO
    regs_def[10'h293] = 8'h00;  acc[10'h293] = ACC_RW;  // DCXO
    regs_def[10'h294] = 8'h00;  acc[10'h294] = ACC_RW;  // DCXO
    regs_def[10'h29A] = 8'h00;  acc[10'h29A] = ACC_RW;  // Tx
    regs_def[10'h29B] = 8'h00;  acc[10'h29B] = ACC_RW;  // Tx
    regs_def[10'h29C] = 8'h00;  acc[10'h29C] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h29D] = 8'h00;  acc[10'h29D] = ACC_RW;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h29E] = 8'h00;  acc[10'h29E] = ACC_RO;  // Tx  // undefined-default(0x--) -> 0x00
    regs_def[10'h29F] = 8'h00;  acc[10'h29F] = ACC_RW;  // Tx
    regs_def[10'h2A1] = 8'h00;  acc[10'h2A1] = ACC_RW;  // Tx
    regs_def[10'h2A6] = 8'h04;  acc[10'h2A6] = ACC_RW;  // Set
    regs_def[10'h2A8] = 8'h00;  acc[10'h2A8] = ACC_RW;  // Set
    regs_def[10'h2AB] = 8'h04;  acc[10'h2AB] = ACC_RW;  // Ref
    regs_def[10'h2AC] = 8'h00;  acc[10'h2AC] = ACC_RW;  // Ref
    regs_def[10'h2B0] = 8'h00;  acc[10'h2B0] = ACC_RO;  // Gain  // undefined-default(0x--) -> 0x00
    regs_def[10'h2B1] = 8'h00;  acc[10'h2B1] = ACC_RO;  // LPF  // undefined-default(0x--) -> 0x00
    regs_def[10'h2B2] = 8'h00;  acc[10'h2B2] = ACC_RO;  // Dig  // undefined-default(0x--) -> 0x00
    regs_def[10'h2B3] = 8'h00;  acc[10'h2B3] = ACC_RO;  // Fast  // undefined-default(0x--) -> 0x00
    regs_def[10'h2B4] = 8'h00;  acc[10'h2B4] = ACC_RO;  // Slow  // undefined-default(0x--) -> 0x00
    regs_def[10'h2B5] = 8'h00;  acc[10'h2B5] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h2B6] = 8'h00;  acc[10'h2B6] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h2B7] = 8'h00;  acc[10'h2B7] = ACC_RO;  // Open  // undefined-default(0x--) -> 0x00
    regs_def[10'h2B8] = 8'h00;  acc[10'h2B8] = ACC_RO;  // Ovrg  // undefined-default(0x--) -> 0x00
    regs_def[10'h3DF] = 8'h00;  acc[10'h3DF] = ACC_RW;  // Control
    regs_def[10'h3F4] = 8'h00;  acc[10'h3F4] = ACC_RW;  // BIST
    regs_def[10'h3F5] = 8'h00;  acc[10'h3F5] = ACC_RW;  // BIST
    regs_def[10'h3F6] = 8'h00;  acc[10'h3F6] = ACC_RW;  // BIST

// 统计: RW=381, RO=57, 保留/未定义=586, 共 1024
