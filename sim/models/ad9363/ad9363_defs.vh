//---------------------------------------------------------------
// ad9363_defs.vh
// AD9363 SPI 行为模型 - 寄存器地址与位域符号名
// (来源: ADI no-OS 驱动 ad9361.h, 与 UG-672 寄存器表一致)
//---------------------------------------------------------------
`ifndef AD9363_DEFS_VH
`define AD9363_DEFS_VH

// ---- 寄存器地址 ----
`define REG_SPI_CONF                 10'h000  // SPI Configuration
`define REG_MULTICHIP_SYNC_AND_TX_MON 10'h001 // Multi-Chip Sync and Tx Mon Control
`define REG_TX_ENABLE_FILTER_CTRL    10'h002  // Tx Enable & Filter Control
`define REG_RX_ENABLE_FILTER_CTRL    10'h003  // Rx Enable & Filter Control
`define REG_INPUT_SELECT             10'h004  // Input Select
`define REG_RFPLL_DIVIDERS           10'h005  // RFPLL Dividers
`define REG_RX_CLOCK_DATA_DELAY      10'h006  // Rx Clock & Data Delay
`define REG_TX_CLOCK_DATA_DELAY      10'h007  // Tx Clock & Data Delay
`define REG_TEMP_OFFSET              10'h00B  // Offset
`define REG_TEMP_SENSE2              10'h00D  // Temp Sense2
`define REG_TEMPERATURE              10'h00E  // Temperature (RO)
`define REG_TEMP_SENSOR_CONFIG       10'h00F  // Temp Sensor Config
`define REG_PARALLEL_PORT_CONF_1     10'h010  // Parallel Port Configuration 1
`define REG_PARALLEL_PORT_CONF_2     10'h011  // Parallel Port Configuration 2
`define REG_PARALLEL_PORT_CONF_3     10'h012  // Parallel Port Configuration 3
`define REG_ENSM_MODE                10'h013  // ENSM Mode
`define REG_ENSM_CONFIG_1            10'h014  // ENSM Config 1
`define REG_ENSM_CONFIG_2            10'h015  // ENSM Config 2
`define REG_CALIBRATION_CTRL         10'h016  // Calibration Control
`define REG_STATE                    10'h017  // State (RO)
`define REG_AUXDAC_1_WORD            10'h018  // AuxDAC 1 Word
`define REG_AUXDAC_2_WORD            10'h019  // AuxDAC 2 Word
`define REG_AUXDAC_1_CONFIG          10'h01A  // AuxDAC 1 Config
`define REG_AUXDAC_2_CONFIG          10'h01B  // AuxDAC 2 Config
`define REG_AUXADC_CLOCK_DIVIDER     10'h01C  // AuxADC Clock Divider
`define REG_AUXADC_CONFIG            10'h01D  // Aux ADC Config
`define REG_AUXADC_WORD_MSB          10'h01E  // AuxADC Word MSB (RO)
`define REG_AUXADC_LSB               10'h01F  // AuxADC LSB (RO)
`define REG_AUTO_GPO                 10'h020  // Auto GPO
`define REG_AGC_GAIN_LOCK            10'h021  // AGC Gain Lock
`define REG_AGC_ATTACK               10'h022  // AGC Attack
`define REG_AUXDAC_ENABLE_CTRL       10'h023  // AuxDAC Enable Control
`define REG_RX_LOAD_SYNTH            10'h024  // Rx Load Synth
`define REG_TX_LOAD_SYNTH            10'h025  // Tx Load Synth
`define REG_GPO_FORCE_AND_INIT       10'h027  // GPO Force and Init
`define REG_GPO0_RX_DELAY            10'h028  // GPO0 Rx delay
`define REG_GPO1_RX_DELAY            10'h029  // GPO1 Rx delay
`define REG_GPO2_RX_DELAY            10'h02A  // GPO2 Rx delay
`define REG_GPO3_RX_DELAY            10'h02B  // GPO3 Rx delay
`define REG_GPO0_TX_DELAY            10'h02C  // GPO0 Tx Delay
`define REG_GPO1_TX_DELAY            10'h02D  // GPO1 Tx Delay
`define REG_GPO2_TX_DELAY            10'h02E  // GPO2 Tx Delay
`define REG_GPO3_TX_DELAY            10'h02F  // GPO3 Tx Delay
`define REG_AUXDAC1_RX_DELAY         10'h030  // AuxDAC1 Rx Delay
`define REG_AUXDAC1_TX_DELAY         10'h031  // AuxDAC1 Tx Delay
`define REG_AUXDAC2_RX_DELAY         10'h032  // AuxDAC2 Rx Delay
`define REG_AUXDAC2_TX_DELAY         10'h033  // AuxDAC2 Tx Delay
`define REG_CTRL_OUTPUT_POINTER      10'h035  // Control Output Pointer
`define REG_CTRL_OUTPUT_ENABLE       10'h036  // Control Output Enable
`define REG_PRODUCT_ID                10'h037  // Product ID (RO)
`define REG_LOOP_FILTER_1            10'h048  // Loop Filter 1
`define REG_LOOP_FILTER_2            10'h049  // Loop Filter 2
`define REG_LOOP_FILTER_3            10'h04A  // Loop Filter 3
`define REG_VCO_CTRL                 10'h04B  // VCO Control
`define REG_RFPLL_SYNTH_RX           10'h050  // Rx Synth
`define REG_RFPLL_SYNTH_TX           10'h051  // Tx Synth
`define REG_ANA_PWR_DWN_OVERRIDE     10'h057  // Analog Power Down Override
`define REG_MISC_PWR_DWN_OVERRIDE    10'h058  // Misc Power Down Override
`define REG_TX_ATTEN_0               10'h073  // Tx Atten 0
`define REG_TX_ATTEN_1               10'h074  // Tx Atten 1
`define REG_TX_ATTEN_OFFSET          10'h077  // Tx Atten Offset
`define REG_TX_ATTEN_THRESH          10'h078  // Tx Atten Thresh
`define REG_AUXADC_1_VREF            10'h0A0  // Quad Cal
`define REG_RX_FILTER_ADDR           10'h0F0  // Rx Filter Coeff Addr
`define REG_AGC_CONFIG_1             10'h0FA  // AGC Config 1
`define REG_AGC_CONFIG_2             10'h0FB  // AGC Config 2
`define REG_AGC_CONFIG_3             10'h0FC  // AGC Config 3
`define REG_AGC_GAIN_STEP            10'h103  // Gain Step
`define REG_AGC_MODE                 10'h110  // AGC Mode
`define REG_AGC_CLK_DIVIDER         10'h111  // AGC Clock Divider

// ---- SPI 指令格式 (D15 W/R, D14:12 NB=bytes-1, D11:10 保留, D9:0 地址) ----
`define AD_READ                     1'b0
`define AD_WRITE                     1'b1
`define AD_CNT(x)                    (((x) - 1) << 12)
`define AD_ADDR(x)                   ((x) & 10'h3FF)

// ---- 关键位域 ----
`define SOFT_RESET                   8'h80  // reg 0x000 D7
`define _SOFT_RESET                  8'h01  // reg 0x000 D0 (与 D7 同时置位触发软复位)
`define PRODUCT_ID_MASK              8'hF8
`define PRODUCT_ID_9361              8'h08  // AD9361/AD9363 家族 Product ID

// ---- 模型访问属性编码 ----
`define AD9363_ACC_RSVD              2'd0   // 保留地址: 写忽略, 读 0x00
`define AD9363_ACC_RW                2'd1   // 可读可写
`define AD9363_ACC_RO                2'd2   // 只读: 写忽略

`endif // AD9363_DEFS_VH
