"""
卷积编码器 - (171, 133)_8, 约束长度 K=7, 码率 1/2
采用归零编码 (terminated convolutional code)
"""
import numpy as np
from ..config import CONV_GEN_POLY, CONV_K


def conv_encode(bits):
    """
    卷积编码

    参数:
        bits: 输入信息比特 (0/1), numpy array shape (N,)

    返回:
        encoded: 编码后比特流, shape (2*(N+K-1),)  [含尾比特]
    """
    bits = np.asarray(bits, dtype=np.int8)
    n = len(bits)

    # 添加尾比特使寄存器归零
    tail = np.zeros(CONV_K - 1, dtype=np.int8)
    bits_with_tail = np.concatenate([bits, tail])

    # 生成多项式的二进制表示 (从 MSB 到 LSB, 对应 K 个抽头)
    gen_polys = []
    for poly in CONV_GEN_POLY:
        # 转为 K 位二进制列表，index 0 是最高位（输入）
        bits_poly = [(poly >> (CONV_K - 1 - i)) & 1 for i in range(CONV_K)]
        gen_polys.append(bits_poly)

    # 移位寄存器状态 (K-1 个状态位 + 当前输入)
    # 用 shift_reg 保存最近 K-1 个输入比特
    shift_reg = np.zeros(CONV_K - 1, dtype=np.int8)
    encoded = []

    for b in bits_with_tail:
        # 当前完整寄存器 = [b] + shift_reg  (输入到输出方向)
        full_reg = np.concatenate([[b], shift_reg])

        # 计算两路输出
        for poly_bits in gen_polys:
            xor_sum = 0
            for i in range(CONV_K):
                if poly_bits[i]:
                    xor_sum ^= full_reg[i]
            encoded.append(xor_sum)

        # 移位: 最旧的丢掉, 新的从左边进来
        shift_reg = np.roll(shift_reg, 1)
        shift_reg[0] = b

    return np.array(encoded, dtype=np.int8)


def get_num_encoder_outputs(info_len):
    """给定信息比特数，返回编码后比特数（含尾比特）"""
    return 2 * (info_len + CONV_K - 1)
