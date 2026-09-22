"""
QPSK 调制/解调
Gray 编码：00 -> +1+j, 01 -> -1+j, 11 -> -1-j, 10 -> +1-j
"""
import numpy as np
from ..config import QPSK_ENERGY


def qpsk_modulate(bits):
    """
    QPSK 调制 (Gray 编码)

    参数:
        bits: 输入比特流, shape (2*N,), 必须为偶数长度

    返回:
        symbols: 复值符号, shape (N,)
    """
    bits = np.asarray(bits, dtype=np.int8)
    assert len(bits) % 2 == 0, "QPSK 输入比特数必须为偶数"

    # Gray 编码映射表
    # I 路: 第一位 0 -> +1, 1 -> -1
    # Q 路: 第二位 0 -> +1, 1 -> -1
    i_bits = bits[0::2]
    q_bits = bits[1::2]

    # 归一化能量: 每个符号能量 = 2 * A^2 = 1 => A = 1/sqrt(2)
    amp = np.sqrt(QPSK_ENERGY / 2)
    i_vals = amp * (1 - 2 * i_bits.astype(np.float64))
    q_vals = amp * (1 - 2 * q_bits.astype(np.float64))

    symbols = i_vals + 1j * q_vals
    return symbols


def qpsk_demodulate_soft(symbols):
    """
    QPSK 软解调 - 输出对数似然比 (LLR)
    LLR = log(P(b=0|r) / P(b=1|r))

    参数:
        symbols: 接收复符号, shape (N,)

    返回:
        llrs: 软比特 LLR, shape (2*N,), 正表示更可能为 0
    """
    symbols = np.asarray(symbols, dtype=np.complex128)

    # Gray 编码下：
    # I 路 LLR 与实部成正比 (实部大 -> 第一位是 0)
    # Q 路 LLR 与虚部成正比 (虚部大 -> 第二位是 0)
    # 对于 AWGN 信道, LLR = 2 * sqrt(E_s) * r_i / sigma^2
    # 这里直接输出与 LLR 成正比的软值 (相对值即可用于 Viterbi)
    amp = np.sqrt(QPSK_ENERGY / 2)
    i_llr = 2 * amp * symbols.real  # 正比于 I 路 LLR
    q_llr = 2 * amp * symbols.imag  # 正比于 Q 路 LLR

    # 按位交织输出: [I0, Q0, I1, Q1, ...]
    llrs = np.empty(2 * len(symbols), dtype=np.float64)
    llrs[0::2] = i_llr
    llrs[1::2] = q_llr

    return llrs


def qpsk_demodulate_hard(symbols):
    """
    QPSK 硬解调

    参数:
        symbols: 接收复符号

    返回:
        bits: 硬判决比特流
    """
    llrs = qpsk_demodulate_soft(symbols)
    bits = (llrs < 0).astype(np.int8)
    return bits
