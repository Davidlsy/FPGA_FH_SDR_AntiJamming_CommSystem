"""
定点数量化工具
支持多种量化模式和溢出处理
"""
import numpy as np
from ..config import QUANT_MODE, OVERFLOW_MODE


def quantize(value, total_width, frac_width, quant_mode=QUANT_MODE, overflow_mode=OVERFLOW_MODE):
    """
    将浮点数量化为定点数

    参数:
        value: 输入浮点值 (标量或数组)
        total_width: 总位宽 (含符号位)
        frac_width: 小数位宽
        quant_mode: "round" 四舍五入, "trunc" 截断
        overflow_mode: "saturate" 饱和, "wrap" 卷绕

    返回:
        quantized_float: 量化后的浮点表示 (实际值是量化后的实数)
        quantized_int: 定点整数表示 (补码整数)
    """
    value = np.asarray(value, dtype=np.float64)
    scale = 2 ** frac_width

    # 1. 缩放
    scaled = value * scale

    # 2. 量化
    if quant_mode == "round":
        quantized_int = np.round(scaled).astype(np.int64)
    elif quant_mode == "trunc":
        quantized_int = np.floor(scaled).astype(np.int64) if frac_width > 0 else scaled.astype(np.int64)
    else:
        raise ValueError(f"未知量化模式: {quant_mode}")

    # 3. 溢出处理
    max_val = 2 ** (total_width - 1) - 1  # 最大正值
    min_val = -2 ** (total_width - 1)      # 最小负值

    if overflow_mode == "saturate":
        quantized_int = np.clip(quantized_int, min_val, max_val)
    elif overflow_mode == "wrap":
        # 补码卷绕
        range_val = 2 ** total_width
        quantized_int = ((quantized_int - min_val) % range_val) + min_val
    else:
        raise ValueError(f"未知溢出模式: {overflow_mode}")

    # 4. 转回浮点值
    quantized_float = quantized_int.astype(np.float64) / scale

    return quantized_float, quantized_int


def quantize_complex(value, total_width, frac_width, **kwargs):
    """
    量化复数 (I/Q 独立量化)

    参数:
        value: 输入复数值
        total_width: 总位宽
        frac_width: 小数位宽

    返回:
        quantized_float: 量化后的复数
        quantized_int: (I_int, Q_int) 元组
    """
    value = np.asarray(value, dtype=np.complex128)
    i_f, i_i = quantize(value.real, total_width, frac_width, **kwargs)
    q_f, q_i = quantize(value.imag, total_width, frac_width, **kwargs)
    return i_f + 1j * q_f, (i_i, q_i)


def get_quantization_noise_power(total_width, frac_width):
    """
    计算量化噪声功率 (均匀分布假设)

    参数:
        total_width: 总位宽
        frac_width: 小数位宽

    返回:
        noise_power: 量化噪声功率 (方差)
    """
    step = 2 ** (-frac_width)
    # 均匀分布在 [-step/2, step/2] 的方差 = step^2 / 12
    return step ** 2 / 12


def get_quant_range(total_width, frac_width):
    """
    获取定点数表示范围

    返回:
        (min_val, max_val, step)
    """
    max_val = (2 ** (total_width - 1) - 1) / (2 ** frac_width)
    min_val = -2 ** (total_width - 1) / (2 ** frac_width)
    step = 2 ** (-frac_width)
    return min_val, max_val, step
