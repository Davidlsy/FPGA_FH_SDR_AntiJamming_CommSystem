"""
SRRC (Square Root Raised Cosine) 平方根升余弦滤波器
滚降系数 α=0.35, 上采样因子 4, 跨度 8 符号
"""
import numpy as np
from ..config import SRRC_ALPHA, SRRC_SPAN, UPSAMPLE_FACTOR, SRRC_NUM_TAPS


def srrc_coeffs(alpha=SRRC_ALPHA, span=SRRC_SPAN, sps=UPSAMPLE_FACTOR):
    """
    生成 SRRC 滤波器系数

    参数:
        alpha: 滚降系数
        span: 滤波器跨度 (符号数), 滤波器延伸 ±span/2 个符号
        sps: 每符号采样点数 (上采样因子)

    返回:
        h: 滤波器系数 (已归一化能量)
    """
    num_taps = span * sps + 1
    t = np.arange(-span * sps // 2, span * sps // 2 + 1) / sps

    h = np.zeros(num_taps)
    for i in range(num_taps):
        tt = t[i]
        if tt == 0:
            h[i] = 1 - alpha + 4 * alpha / np.pi
        elif abs(tt) == 1 / (4 * alpha):
            h[i] = (alpha / np.sqrt(2)) * (
                (1 + 2 / np.pi) * np.sin(np.pi / (4 * alpha))
                + (1 - 2 / np.pi) * np.cos(np.pi / (4 * alpha))
            )
        else:
            numerator = np.sin(np.pi * tt * (1 - alpha)) + \
                        4 * alpha * tt * np.cos(np.pi * tt * (1 + alpha))
            denominator = np.pi * tt * (1 - (4 * alpha * tt) ** 2)
            h[i] = numerator / denominator

    # 归一化: 使滤波器能量 = 1
    # 这样 TX 脉冲成形 + RX 匹配滤波后，符号增益为 1 (sum(h^2) = 1)
    h = h / np.sqrt(np.sum(h ** 2))
    return h


def pulse_shape(symbols, sps=UPSAMPLE_FACTOR, h=None):
    """
    脉冲成形：上采样 + SRRC 滤波

    参数:
        symbols: 输入复符号, shape (N,)
        sps: 上采样因子
        h: SRRC 滤波器系数 (None 则自动生成)

    返回:
        shaped: 成形后信号, shape (N*sps + len(h) - 1,)
    """
    symbols = np.asarray(symbols, dtype=np.complex128)

    if h is None:
        h = srrc_coeffs()

    # 上采样：在符号间插零
    n = len(symbols)
    upsampled = np.zeros(n * sps, dtype=np.complex128)
    upsampled[::sps] = symbols

    # 卷积 (使用 full 模式)
    shaped = np.convolve(upsampled, h)
    return shaped


def matched_filter(signal, sps=UPSAMPLE_FACTOR, h=None):
    """
    匹配滤波：SRRC 滤波 + 下采样

    参数:
        signal: 接收信号
        sps: 下采样因子
        h: SRRC 滤波器系数 (None 则自动生成)

    返回:
        symbols: 下采样后的符号, shape (M,)
        filtered: 滤波后的全采样信号
    """
    if h is None:
        h = srrc_coeffs()

    # 匹配滤波 (系数相同，因为 SRRC 是自共轭对称的)
    filtered = np.convolve(signal, h)

    # 总群延迟 = TX 滤波器延迟 + RX 滤波器延迟 = 2 * (num_taps - 1) / 2 = num_taps - 1
    # 假设输入信号已通过 TX SRRC 脉冲成形
    num_taps = len(h)
    total_delay = num_taps - 1  # TX + RX 总延迟

    # 从最佳相位开始下采样
    n_symbols = (len(filtered) - total_delay) // sps
    symbols = filtered[total_delay:total_delay + n_symbols * sps:sps]

    return symbols, filtered
