"""
系统配置参数 - 浮点与定点共享
所有参数来源于 S1 任务规格书
"""
import numpy as np

# ============================================================
# 卷积编码参数 (171, 133)_8 = 约束长度 K=7, 码率 1/2
# ============================================================
CONV_GEN_POLY = [0o171, 0o133]   # 生成多项式 (八进制)
CONV_K = 7                       # 约束长度
CONV_RATE = 1 / 2                # 码率
CONV_TAIL_BITS = CONV_K - 1      # 尾比特数 (归零编码)

# ============================================================
# 交织参数
# ============================================================
INTERLEAVER_DEPTH = 10           # 块交织深度 (行数)
# 列数由输入帧长度动态决定，默认帧长对应列数 = frame_len / depth

# ============================================================
# QPSK 调制参数
# ============================================================
QPSK_BITS_PER_SYMBOL = 2         # 每符号 2 bit
QPSK_ENERGY = 1.0                # 符号平均能量

# ============================================================
# SRRC 脉冲成形参数
# ============================================================
SRRC_ALPHA = 0.35                # 滚降系数
SRRC_SPAN = 8                    # 滤波器跨度 (符号数)
UPSAMPLE_FACTOR = 4              # 上采样因子 (每符号采样点数)
SRRC_NUM_TAPS = SRRC_SPAN * UPSAMPLE_FACTOR + 1  # 抽头数

# ============================================================
# AWGN 信道参数
# ============================================================
EB_N0_RANGE_DB = np.arange(0, 9, 1)  # Eb/N0 扫描范围 0~8 dB

# ============================================================
# 仿真参数
# ============================================================
DEFAULT_FRAME_LEN = 1000         # 每帧信息比特数
DEFAULT_NUM_FRAMES = 50          # 默认仿真帧数
MIN_ERROR_BITS = 100             # 最小误比特数 (统计置信度)
MAX_BITS_PER_EBN0 = 5_000_000    # 每个 Eb/N0 点最大仿真比特数

# ============================================================
# 定点化参数 - 各模块位宽配置
# ============================================================
FIXED_POINT_CONFIG = {
    # 卷积编码输出：硬判决 0/1，1 bit 足够；量化为 2bit 带符号用于后续
    "conv_encoder_out_w": 2,
    "conv_encoder_out_frac": 0,

    # 交织：与卷积输出同位宽
    "interleaver_out_w": 2,
    "interleaver_out_frac": 0,

    # QPSK 调制输出：I/Q 两路，12 bit 有符号，1 bit 整数 + 10 bit 小数
    "qpsk_out_w": 12,
    "qpsk_out_frac": 10,

    # SRRC 输出：14 bit 有符号，2 bit 整数 + 11 bit 小数
    "srrc_out_w": 14,
    "srrc_out_frac": 11,

    # SRRC 系数量化：12 bit 有符号
    "srrc_coeff_w": 12,
    "srrc_coeff_frac": 11,

    # AWGN 后：同位宽
    "awgn_out_w": 14,
    "awgn_out_frac": 11,

    # 同步输出：14 bit 有符号
    "sync_out_w": 14,
    "sync_out_frac": 11,

    # Viterbi 度量输入：8 bit 有符号
    "viterbi_metric_w": 8,
    "viterbi_metric_frac": 5,

    # Viterbi 路径度量：16 bit 有符号
    "viterbi_pm_w": 16,
    "viterbi_pm_frac": 5,

    # CIC 各级（预留，若用于插值/抽取）
    "cic_stage_w": [16, 18, 20],
    "cic_stage_frac": [11, 11, 11],
}

# 量化模式: "round" 四舍五入, "trunc" 截断
QUANT_MODE = "round"
# 溢出模式: "saturate" 饱和, "wrap" 卷绕
OVERFLOW_MODE = "saturate"

# ============================================================
# S4 帧格式参数
# 《帧格式规格书》docs/spec/frame_format.md 的机器可读来源。
# 本组只描述比特级成帧；与 FIXED_POINT_CONFIG 的位宽规格相互独立，
# 增删本组不触碰 S1 冻结基线（定点规格书 §0 的变更策略只管位宽/量化/溢出）。
# ============================================================
FRAME_SYNC_POLY = [0o103, 0o133]     # 6 级本原多项式优选对: x^6+x+1 与 x^6+x^4+x^3+x+1
FRAME_SYNC_M = 6                     # m 序列级数（周期 2^6-1 = 63）
# 第二条 m 序列的相对位移（Gold 码的相位自由度）。两条序列同状态起步时异或结果
# 前 8 位会塌成全 0，故按准则搜相位并冻结 k=24：最长同值游程 4、旁瓣 max|R|=16、
# 恰 32 个 1（全表三项同时最优，见 docs/spec/frame_format.md §2.2）。
FRAME_SYNC_SHIFT = 24
FRAME_SYNC_LEN = 64                  # 同步字长度 = 一个 Gold 周期 63 bit + 首位重复
FRAME_HEADER_BITS = 32               # 帧头长度（整字节）
FRAME_HEADER_VERSION = 0b01          # 帧头版本字段
FRAME_PAYLOAD_BYTES = 256            # 每帧载荷字节数
FRAME_CRC_POLY = 0x1021              # CRC-16/CCITT-FALSE（初值 FFFF、不反序、无终值异或）
FRAME_CRC_INIT = 0xFFFF
FRAME_CRC_BITS = 16
# 送 CRC 的比特 = 帧头 + 载荷；同步字不参与（它只是接收端相关检测用的已知前导）
FRAME_COVERED_BITS = FRAME_HEADER_BITS + FRAME_PAYLOAD_BYTES * 8
# 帧总长 = 同步字 + 帧头 + 载荷 + CRC
FRAME_TOTAL_BITS = FRAME_SYNC_LEN + FRAME_COVERED_BITS + FRAME_CRC_BITS

# ============================================================
# S4-P3 DUC（数字上变频）参数 —— srrc_duc 的 NCO + 复数混频
# 本组是 P3 新增（S1 冻结基线之外），位宽口径见 docs/spec/s4_tx_p3_freeze_draft.md 决策 1，
# 并与 docs/spec/s4_tx_interface.md §5.2（NCO 相位连续语义，已冻结）一致。
# 增删本组不触碰 S1 冻结基线（定点规格书 §0 的变更策略只管 FIXED_POINT_CONFIG）。
# ============================================================
DUC_CONFIG = {
    # NCO 相位累加器位宽（§5.2 已冻结：16 bit，相位不清零）
    "nco_phase_w": 16,
    # sin/cos LUT 输出位宽与小数位（§5.2：LUT 16 bit、14 bit 小数，Q2.14，实际值域 [-1,1]）
    "nco_lut_w": 16,
    "nco_lut_frac": 14,
    # DUC 复数混频输出位宽与小数位（决策 1：Q5.11，峰值 ≤ ±8 留 2 倍余量 → 表示 ±16）
    "duc_out_w": 16,
    "duc_out_frac": 11,
    # S4 阶段固定上变频频点：f0 = fs/8，freq_word = 2^16 / 8 = 8192（决策 2 建议值）
    "nco_freq_word": 8192,
}

# ============================================================
# S5 接收链参数（DDC / 同步环 / Viterbi）—— s5_rx_interface.md v1.1 §8 的机器可读来源
# 本组是 P0 冻结的接收链口径（S1 冻结基线之外），位宽口径见该规格 §6.1。
# 增删本组不触碰 S1 冻结基线（定点规格书 §0 的变更策略只管 FIXED_POINT_CONFIG）。
# ============================================================
RX_CONFIG = {
    # --- DDC：CIC 抽取（输出 4 sps = 2 MSPS，与发射 ×4 严格对称，是其逆）---
    # S5 验证档位 D = 4（f_adc = 8 MSPS）；板级最终值随 AD9363 配置（BV-01）
    "adc_in_w": 12,          # ADC 复采样位宽（AD9363 原生 12 bit，有符号补码）
    "cic_decim": 4,          # 抽取比 D
    "cic_stages": 3,         # 级数 N（与 S1 预留 cic_stage_w 的 3 项对齐）
    "cic_diff_delay": 1,     # 微分延迟 M
    "cic_acc_w": 48,         # 积分器 / 梳状器累加器位宽（任务卡指定；DSP48E1 原生宽度）
    # CIC 增益 = (D·M)^N = 4^3 = 64 = 2^6 → 输出右移 6 位还原单位增益（round half-to-even）
    # --- 同步环（结构冻结；系数为初值，待 #5 收敛性验证标定后更新本组）---
    "sync_acc_w": 16,        # 相位 / 定时累加器位宽（§4.2 冻结）
    "sync_coeff_w": 20,      # 环路系数定点位宽
    "sync_coeff_frac": 19,   # 环路系数小数位（Q1.19：Ki ~1e-4 才有足够分辨率）
    # 二阶环初值：ζ = 0.707、归一化带宽 B_n ≈ 5e-3（B_L ≈ 2.5 kHz @ 500 ksps），
    # 按 Kp = 4ζB_n/(1+2ζB_n+B_n²)、Ki = 4B_n²/(1+2ζB_n+B_n²) 取——
    # **仅为初值**，判别器增益并入后须在 #5 重新标定（见 s5_rx_p0_freeze_draft.md §2.3）
    "costas_kp": 0.0140,
    "costas_ki": 0.000099,
    "timing_kp": 0.0140,
    "timing_ki": 0.000099,
    "costas_damping": 0.707,
    # --- Viterbi（位宽继承 S1 FIXED_POINT_CONFIG 的 viterbi_metric/pm）---
    "viterbi_tb_depth": 96,  # 回溯深度（任务卡指定）
    "viterbi_win_tb": 96,    # 滑窗回溯判决深度（= 深度 96；None 则全回溯，仅作理想对照）
}
