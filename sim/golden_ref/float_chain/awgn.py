"""
AWGN 加性高斯白噪声信道
支持按 Eb/N0 或 Es/N0 配置噪声功率
"""
import numpy as np
from ..config import CONV_RATE, QPSK_BITS_PER_SYMBOL


def add_awgn(signal, eb_n0_db, bit_rate=None, sps=1):
    """
    向信号添加 AWGN 噪声

    参数:
        signal: 输入信号 (复信号)
        eb_n0_db: Eb/N0 (dB)
        bit_rate: 每符号携带的信息比特数 (考虑编码)
                  若为 None 则从全局配置计算: QPSK * 码率 = 2 * 1/2 = 1
        sps: 每符号采样点数 (信号采样率相对于符号率)

    返回:
        noisy_signal: 加噪后的信号
        noise_power: 噪声功率 (双边)
    """
    signal = np.asarray(signal, dtype=np.complex128)

    if bit_rate is None:
        # 信息比特/符号 = 调制阶数 * 码率
        bit_rate = QPSK_BITS_PER_SYMBOL * CONV_RATE

    # 计算符号平均能量
    symbol_energy = np.mean(np.abs(signal[::sps]) ** 2) * sps if sps > 1 else np.mean(np.abs(signal) ** 2)
    # 更准确: 用信号总能量除以符号数
    n_symbols = len(signal) // sps if sps > 1 else len(signal)
    symbol_energy = np.sum(np.abs(signal) ** 2) / n_symbols

    # Eb = Es / (bits_per_symbol * code_rate)  这里 bits_per_symbol 考虑了编码
    eb = symbol_energy / bit_rate

    # Eb/N0 线性值
    eb_n0_linear = 10 ** (eb_n0_db / 10)

    # N0 = Eb / (Eb/N0)
    n0 = eb / eb_n0_linear

    # 匹配滤波后噪声方差每维应为 N0/2
    # 由于 SRRC 滤波器能量归一化为 1，输入噪声方差每维 = N0/2
    # (输出方差 = 输入方差 * 滤波器能量 = N0/2 * 1 = N0/2)
    noise_var_per_dim = n0 / 2

    # 生成复高斯噪声
    noise = np.sqrt(noise_var_per_dim) * (
        np.random.randn(len(signal)) + 1j * np.random.randn(len(signal))
    )

    noisy_signal = signal + noise
    noise_power = 2 * noise_var_per_dim  # 复噪声总功率

    return noisy_signal, noise_power


def add_awgn_simple(signal, snr_db):
    """
    简化版：按信号功率与 SNR (dB) 添加噪声

    参数:
        signal: 输入信号
        snr_db: 信噪比 (dB)

    返回:
        noisy_signal: 加噪后的信号
    """
    signal = np.asarray(signal, dtype=np.complex128)
    sig_power = np.mean(np.abs(signal) ** 2)
    noise_power = sig_power / (10 ** (snr_db / 10))
    noise_std = np.sqrt(noise_power / 2)  # 每维
    noise = noise_std * (np.random.randn(len(signal)) + 1j * np.random.randn(len(signal)))
    return signal + noise
