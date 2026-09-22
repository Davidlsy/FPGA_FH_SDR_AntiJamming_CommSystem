"""
块交织器 - 深度 10
按行写入，按列读出；解交织相反
"""
import numpy as np
from ..config import INTERLEAVER_DEPTH


def block_interleave(bits, depth=INTERLEAVER_DEPTH):
    """
    块交织：按行写入，按列读出

    参数:
        bits: 输入比特流, shape (N,)
        depth: 交织深度 (行数)

    返回:
        interleaved: 交织后比特流, shape (N,)
    """
    bits = np.asarray(bits, dtype=np.int8)
    n = len(bits)

    # 计算列数：向上取整，不足补零
    n_cols = int(np.ceil(n / depth))
    n_total = depth * n_cols

    # 补零到完整矩阵
    padded = np.zeros(n_total, dtype=np.int8)
    padded[:n] = bits

    # 按行写入
    matrix = padded.reshape(depth, n_cols)
    # 按列读出
    interleaved = matrix.T.flatten()

    return interleaved


def block_deinterleave(bits, depth=INTERLEAVER_DEPTH):
    """
    块解交织：按列写入，按行读出

    参数:
        bits: 输入比特流 (soft 值也可), shape (N,)
        depth: 交织深度 (行数)

    返回:
        deinterleaved: 解交织后比特流, shape (N,)
    """
    bits = np.asarray(bits)
    n = len(bits)

    # 计算列数
    n_cols = int(np.ceil(n / depth))
    n_total = depth * n_cols

    # 补零
    padded = np.zeros(n_total, dtype=bits.dtype)
    padded[:n] = bits

    # 按列写入 (即 reshape 成 n_cols x depth)
    matrix = padded.reshape(n_cols, depth)
    # 按行读出
    deinterleaved = matrix.T.flatten()

    return deinterleaved[:n]
