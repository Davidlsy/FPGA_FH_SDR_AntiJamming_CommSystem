"""
同步模块 - 黄金参考链使用理想同步
定时同步：匹配滤波后直接下采样（已知最佳相位）
载波同步：无频偏/相差（AWGN 理想信道假设）
"""
import numpy as np
from ..config import UPSAMPLE_FACTOR


def ideal_timing_recover(signal, sps=UPSAMPLE_FACTOR, phase=0):
    """
    理想定时恢复：按指定相位下采样

    参数:
        signal: 输入信号 (采样率 sps 倍符号率)
        sps: 每符号采样点数
        phase: 最佳采样相位 (0 ~ sps-1)

    返回:
        symbols: 下采样后的符号
    """
    return signal[phase::sps]


def coarse_time_sync(signal, sps=UPSAMPLE_FACTOR):
    """
    粗定时同步 - 基于幅度平方找最佳采样相位

    参数:
        signal: 输入信号
        sps: 每符号采样点数

    返回:
        best_phase: 最佳采样相位
    """
    best_phase = 0
    best_metric = -np.inf

    for phase in range(sps):
        sampled = signal[phase::sps]
        metric = np.mean(np.abs(sampled) ** 2)
        if metric > best_metric:
            best_metric = metric
            best_phase = phase

    return best_phase


def sync_receive(signal, sps=UPSAMPLE_FACTOR, ideal=True):
    """
    同步接收处理

    参数:
        signal: 输入接收信号
        sps: 每符号采样点数
        ideal: True=理想同步（无相偏/频偏）, False=使用估计算法

    返回:
        symbols: 同步后的符号序列
        sync_info: 同步参数字典
    """
    signal = np.asarray(signal, dtype=np.complex128)

    if sps > 1:
        # 定时同步
        if ideal:
            best_phase = 0  # 理想：已知最佳相位
        else:
            best_phase = coarse_time_sync(signal, sps)
        symbols = signal[best_phase::sps]
    else:
        best_phase = 0
        symbols = signal

    if ideal:
        # 理想同步：无载波相偏/频偏
        phase_est = 0.0
        freq_offset = 0.0
        corrected = symbols
    else:
        # 非理想：4 次幂相位估计（需要考虑 QPSK 星座偏移）
        n_ref = min(50, len(symbols))
        if n_ref > 0:
            # QPSK Gray 编码符号位于 4 个象限，4 次幂后相位均为 π
            # 预期 4 次幂相位 = π，偏差即为相偏的 4 倍
            power4 = symbols[:n_ref] ** 4
            avg_phase4 = np.angle(np.mean(power4))
            # 减去已知星座相位 π，得到 4 倍相偏
            phase_offset4 = avg_phase4 - np.pi
            phase_est = phase_offset4 / 4
            corrected = symbols * np.exp(-1j * phase_est)
        else:
            phase_est = 0.0
            corrected = symbols
        freq_offset = 0.0

    sync_info = {
        "best_phase": best_phase,
        "freq_offset": freq_offset,
        "phase_est": phase_est,
    }

    return corrected, sync_info
