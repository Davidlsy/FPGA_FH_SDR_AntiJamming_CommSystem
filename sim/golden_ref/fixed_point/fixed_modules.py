"""
定点化模块实现
各模块的定点版本，位宽配置来自 config.FIXED_POINT_CONFIG
"""
import numpy as np
from ..config import FIXED_POINT_CONFIG, UPSAMPLE_FACTOR, CONV_K
from .quantizer import quantize, quantize_complex
from ..float_chain.srrc import srrc_coeffs


# ============================================================
# 定点 SRRC 滤波器
# ============================================================
def fixed_srrc_coeffs():
    """生成定点化的 SRRC 滤波器系数"""
    cfg = FIXED_POINT_CONFIG
    h_float = srrc_coeffs()
    h_q, h_int = quantize(h_float, cfg["srrc_coeff_w"], cfg["srrc_coeff_frac"])
    return h_q, h_int


def fixed_pulse_shape(symbols, h_q=None):
    """
    定点脉冲成形

    参数:
        symbols: 定点 QPSK 符号 (复值，已量化)
        h_q: 量化后的 SRRC 系数 (浮点表示)

    返回:
        shaped_q: 量化后的成形信号
    """
    cfg = FIXED_POINT_CONFIG
    sps = UPSAMPLE_FACTOR

    if h_q is None:
        h_q, _ = fixed_srrc_coeffs()

    symbols = np.asarray(symbols, dtype=np.complex128)

    # 上采样
    n = len(symbols)
    upsampled = np.zeros(n * sps, dtype=np.complex128)
    upsampled[::sps] = symbols

    # 卷积 (全精度中间结果)
    shaped = np.convolve(upsampled, h_q)

    # 输出量化
    shaped_q, _ = quantize_complex(shaped, cfg["srrc_out_w"], cfg["srrc_out_frac"])

    return shaped_q


def fixed_matched_filter(signal, h_q=None):
    """
    定点匹配滤波

    参数:
        signal: 输入定点信号
        h_q: 量化后的 SRRC 系数

    返回:
        symbols_q: 下采样后量化的符号
        filtered_q: 滤波后的全采样信号
    """
    cfg = FIXED_POINT_CONFIG
    sps = UPSAMPLE_FACTOR

    if h_q is None:
        h_q, _ = fixed_srrc_coeffs()

    # 匹配滤波
    filtered = np.convolve(signal, h_q)

    # 输出量化
    filtered_q, _ = quantize_complex(filtered, cfg["sync_out_w"], cfg["sync_out_frac"])

    # 总群延迟 = TX 滤波器延迟 + RX 滤波器延迟 = num_taps - 1
    # 假设输入信号已通过 TX SRRC 脉冲成形
    num_taps = len(h_q)
    total_delay = num_taps - 1
    n_symbols = (len(filtered_q) - total_delay) // sps
    symbols_q = filtered_q[total_delay:total_delay + n_symbols * sps:sps]

    return symbols_q, filtered_q


# ============================================================
# 定点 QPSK 调制
# ============================================================
def fixed_qpsk_modulate(bits):
    """
    定点 QPSK 调制

    参数:
        bits: 输入比特流

    返回:
        symbols_q: 量化后的 QPSK 复符号
    """
    cfg = FIXED_POINT_CONFIG

    bits = np.asarray(bits, dtype=np.int8)
    assert len(bits) % 2 == 0

    i_bits = bits[0::2]
    q_bits = bits[1::2]

    # QPSK 符号值: ±1/√2
    amp = 1.0 / np.sqrt(2)
    i_vals = amp * (1 - 2 * i_bits.astype(np.float64))
    q_vals = amp * (1 - 2 * q_bits.astype(np.float64))

    symbols = i_vals + 1j * q_vals

    # 量化
    symbols_q, _ = quantize_complex(symbols, cfg["qpsk_out_w"], cfg["qpsk_out_frac"])

    return symbols_q


def fixed_qpsk_demodulate_soft(symbols):
    """
    定点 QPSK 软解调 (输出 LLR 软值)

    参数:
        symbols: 接收复符号 (定点值)

    返回:
        llrs_q: 量化后的软值 (用于 Viterbi 度量)
    """
    cfg = FIXED_POINT_CONFIG

    symbols = np.asarray(symbols, dtype=np.complex128)

    # 软值正比于 I/Q 分量
    amp = 1.0 / np.sqrt(2)
    i_llr = 2 * amp * symbols.real
    q_llr = 2 * amp * symbols.imag

    llrs = np.empty(2 * len(symbols), dtype=np.float64)
    llrs[0::2] = i_llr
    llrs[1::2] = q_llr

    # 量化为 Viterbi 度量位宽
    llrs_q, _ = quantize(llrs, cfg["viterbi_metric_w"], cfg["viterbi_metric_frac"])

    return llrs_q


# ============================================================
# 定点 AWGN (噪声按定点位宽生成)
# ============================================================
def fixed_add_awgn(signal, eb_n0_db, out_w=None, out_frac=None):
    """
    定点 AWGN 信道：加噪后量化到指定位宽

    参数:
        signal: 输入定点信号
        eb_n0_db: Eb/N0 (dB)
        out_w: 输出总位宽 (None 用配置)
        out_frac: 输出小数位宽

    返回:
        noisy_q: 加噪并量化后的信号
    """
    cfg = FIXED_POINT_CONFIG
    if out_w is None:
        out_w = cfg["awgn_out_w"]
        out_frac = cfg["awgn_out_frac"]

    # 计算噪声功率 (用浮点方式生成噪声，再加到信号上量化)
    from ..float_chain.awgn import add_awgn
    noisy, _ = add_awgn(signal, eb_n0_db, bit_rate=1.0, sps=UPSAMPLE_FACTOR)

    # 量化
    noisy_q, _ = quantize_complex(noisy, out_w, out_frac)

    return noisy_q


# ============================================================
# 定点同步 (简化：功能同浮点，但输入输出量化)
# ============================================================
def fixed_sync_receive(signal, sps=1, ideal=True):
    """
    定点同步接收（默认理想同步）

    参数:
        signal: 输入定点信号
        sps: 每符号采样点数 (默认 1 = 符号率)
        ideal: True=理想同步（无相偏/频偏）

    返回:
        symbols_q: 同步后量化的符号
        sync_info: 同步信息
    """
    cfg = FIXED_POINT_CONFIG
    signal = np.asarray(signal, dtype=np.complex128)

    if sps > 1:
        # 定时同步
        if ideal:
            best_phase = 0
        else:
            best_phase = 0
            best_metric = -np.inf
            for phase in range(sps):
                sampled = signal[phase::sps]
                metric = np.mean(np.abs(sampled) ** 2)
                if metric > best_metric:
                    best_metric = metric
                    best_phase = phase
        symbols = signal[best_phase::sps]
    else:
        best_phase = 0
        symbols = signal

    if ideal:
        # 理想同步：无相偏/频偏校正
        phase_est = 0.0
        corrected = symbols
    else:
        # 4 次幂相位估计（考虑 QPSK 星座在象限，4 次幂后相位为 π）
        n_ref = min(50, len(symbols))
        if n_ref > 0:
            power4 = symbols[:n_ref] ** 4
            avg_phase4 = np.angle(np.mean(power4))
            phase_offset4 = avg_phase4 - np.pi
            phase_est = phase_offset4 / 4
            corrected = symbols * np.exp(-1j * phase_est)
        else:
            phase_est = 0.0
            corrected = symbols

    # 输出量化
    corrected_q, _ = quantize_complex(corrected, cfg["sync_out_w"], cfg["sync_out_frac"])

    sync_info = {
        "best_phase": best_phase,
        "phase_est": phase_est,
    }

    return corrected_q, sync_info


# ============================================================
# 定点 Viterbi 译码器 (路径度量量化)
# ============================================================
def fixed_viterbi_decode(soft_bits):
    """
    定点 Viterbi 译码

    参数:
        soft_bits: 量化后的软输入

    返回:
        decoded: 译码后信息比特
    """
    cfg = FIXED_POINT_CONFIG
    pm_w = cfg["viterbi_pm_w"]
    pm_frac = cfg["viterbi_pm_frac"]

    soft_bits = np.asarray(soft_bits, dtype=np.float64)
    n_total_bits = len(soft_bits)
    n_symbols = n_total_bits // 2
    num_states = 2 ** (CONV_K - 1)

    # 预计算状态输出表
    from ..float_chain.viterbi import _get_state_outputs
    output_table, next_state_table = _get_state_outputs()

    # 路径度量初始化为定点值
    path_metrics = np.full(num_states, np.inf, dtype=np.float64)
    path_metrics[0] = 0.0

    survivors = np.zeros((n_symbols, num_states), dtype=np.int16)

    # 前向递推
    for t in range(n_symbols):
        current_soft = soft_bits[2 * t:2 * t + 2]
        new_metrics = np.full(num_states, np.inf, dtype=np.float64)

        for state in range(num_states):
            if path_metrics[state] == np.inf:
                continue

            for input_bit in [0, 1]:
                expected = output_table[state, input_bit]
                # 分支度量 (绝对值形式)
                bit0 = (expected >> 1) & 1
                bit1 = expected & 1
                m0 = -current_soft[0] if bit0 == 0 else current_soft[0]
                m1 = -current_soft[1] if bit1 == 0 else current_soft[1]
                bm = m0 + m1

                next_state = next_state_table[state, input_bit]
                new_pm = path_metrics[state] + bm

                if new_pm < new_metrics[next_state]:
                    new_metrics[next_state] = new_pm
                    survivors[t, next_state] = state

        # 路径度量量化 (饱和处理防止溢出)
        finite_mask = np.isfinite(new_metrics)
        if np.any(finite_mask):
            new_metrics_q, _ = quantize(new_metrics[finite_mask], pm_w, pm_frac)
            new_metrics[finite_mask] = new_metrics_q

        # 减去最小路径度量防止累积溢出 (归一化)
        min_pm = np.min(new_metrics[np.isfinite(new_metrics)])
        if np.isfinite(min_pm):
            new_metrics[np.isfinite(new_metrics)] -= min_pm

        path_metrics = new_metrics

    # 回溯
    best_state = 0
    if not np.isfinite(path_metrics[best_state]) or path_metrics[best_state] == np.inf:
        best_state = np.argmin(path_metrics)

    decoded_rev = []
    state = int(best_state)

    for t in range(n_symbols - 1, -1, -1):
        prev_state = int(survivors[t, state])
        input_bit = state >> (CONV_K - 2)
        decoded_rev.append(input_bit)
        state = prev_state

    decoded = np.array(decoded_rev[::-1], dtype=np.int8)
    info_bits = decoded[:-(CONV_K - 1)] if len(decoded) > CONV_K - 1 else decoded

    return info_bits
