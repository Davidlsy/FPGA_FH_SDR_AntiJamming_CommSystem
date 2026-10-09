"""S6 跳频图案位真裁判：fh_ctrl（LFSR-16 直移）

口径见 `docs/spec/s6_fh_interface.md` §2：
- Fibonacci LFSR，每拍输出 LSB、反馈进最高位（与 `float_chain.framing.m_sequence` 同构）；
- 多项式 x^16+x^15+x^13+x^4+1（掩码 0x1A011，周期 65535）；
- 一跳 = 移位 4 拍，信道号 = 本跳移出 4 bit（首移出位落 channel[3]，MSB-first）；
- 种子加载拍不出数并清 hop_index；hop_index 20 bit 自然回绕。

本模块是纯逻辑（无量化），放在 fixed_point/ 是因为它就是位真裁判本体。
"""
from __future__ import annotations

import numpy as np

FH_POLY = 0x1A011          # 17 bit 掩码，bit i = x^i 项（含 x^0 与 x^16）
FH_N = 16                  # LFSR 级数
FH_PERIOD = (1 << FH_N) - 1   # 65535（本原多项式）
FH_DEFAULT_SEED = 0x0001
FH_HOP_BITS = 4            # 一跳移位拍数 = 信道号位宽
FH_INDEX_MASK = (1 << 20) - 1


def _check_seed(seed: int) -> int:
    """种子合法性：1..65535（全零是吸收态，禁止）。"""
    s = int(seed) & 0xFFFF
    if s == 0:
        raise ValueError("fh seed must be non-zero (all-zero is absorbing)")
    return s


def hop_bits(seed: int, n_bits: int) -> np.ndarray:
    """生成 n_bits 个 m 序列输出 bit（LSB 先出，周期平铺）。

    平铺与连续推进逐位等价（LFSR 周期性），自检里有专门的互证项。
    """
    s = _check_seed(seed)
    period = np.empty(FH_PERIOD, dtype=np.int8)
    reg = s
    for i in range(FH_PERIOD):
        period[i] = reg & 1
        fb = ((reg >> 0) ^ (reg >> 4) ^ (reg >> 13) ^ (reg >> 15)) & 1
        reg = (reg >> 1) | (fb << (FH_N - 1))
    reps = (n_bits + FH_PERIOD - 1) // FH_PERIOD
    return np.tile(period, reps)[:n_bits]


def hop_sequence(seed: int, n_hops: int) -> tuple[np.ndarray, np.ndarray]:
    """n_hops 跳的 (hop_index, channel)；hop_index 从 0 起（加载后第一跳）。

    channel[3] = 本跳首个移出位（现态 LSB），channel = {b0,b1,b2,b3}。
    """
    bits = hop_bits(seed, n_hops * FH_HOP_BITS).reshape(n_hops, FH_HOP_BITS)
    channel = (bits[:, 0] << 3) | (bits[:, 1] << 2) | (bits[:, 2] << 1) | bits[:, 3]
    hop_index = np.arange(n_hops, dtype=np.int64) & FH_INDEX_MASK
    return hop_index, channel.astype(np.int64)


def dwell_counts(seed: int, n_hops: int) -> np.ndarray:
    """16 信道驻留次数（均匀性统计用）。"""
    _, ch = hop_sequence(seed, n_hops)
    return np.bincount(ch, minlength=16)


def sim_fh_ctrl(cmds, seed: int = FH_DEFAULT_SEED) -> list[tuple[int, int]]:
    """按 RTL 语义跑命令流，返回逐输出拍的 (hop_index, channel)。

    cmds: 可迭代 (seed_load, seed_val)——每拍一个命令；
    seed_load=1 拍加载种子并清 hop_index（不出数）；=0 拍推进一跳（出一拍）。
    """
    reg = _check_seed(seed)
    hop_no = 0
    out: list[tuple[int, int]] = []
    for load, val in cmds:
        if load:
            reg = _check_seed(val)
            hop_no = 0
            continue
        # 一跳 = 移位 4 拍：先取移出 4 bit，再推进 4 次
        b = []
        for _ in range(FH_HOP_BITS):
            b.append(reg & 1)
            fb = ((reg >> 0) ^ (reg >> 4) ^ (reg >> 13) ^ (reg >> 15)) & 1
            reg = (reg >> 1) | (fb << (FH_N - 1))
        ch = (b[0] << 3) | (b[1] << 2) | (b[2] << 1) | b[3]
        out.append((hop_no & FH_INDEX_MASK, ch))
        hop_no += 1
    return out
