"""S6 同步字捕获黄金裁判 —— `docs/spec/s6_fh_interface.md` §8 逐条同构。

- 滑动相关：`corr = 64 − popcount(sr ⊕ SYNC_WORD)`，sr = 最近 64 bit（复位补 0）；
- 恒虚警门限：`noise_est = (Σ 近 NAVG=16 拍 corr（不含本拍） + 8) >> 4`，
  `thresh = max(THRESH_MIN, (noise_est × COEFF_Q) >> COEFF_SHIFT)`，命中 `corr ≥ thresh`（等号算）；
- M/N 判决（帧槽确认）：IDLE 命中开候选（m=1, slots=1, timer=FRAME_LEN）；
  TRACK 每 FRAME_LEN 有效拍一个槽位拍，槽位命中 m+1 且发 frame_start，
  **m ≥ M 声明优先**（发 acq、关候选），否则 slots ≥ N 弃候选；非槽位 hit 忽略（锁定期）；
- `din_valid=0` 整拍冻结（sr/噪声历史/timer/状态全保持，无输出行）。

数值全整数、无浮点：`noise_est` 用 16 深零填充滑窗和（与 RTL 移位累加同构：空历史 == 全 0），
两边同用非负 floor 移位。位真由 sim_sync_acq 与 RTL 逐拍比对锁定。
"""
from __future__ import annotations

from collections.abc import Iterable

# 冻结常量（docs/spec/s6_fh_interface.md §8.1 / frame_format.md §2.3）
SYNC_WORD = 0x517AE4216E7555CA
SYNC_W = 64
FRAME_LEN_DEFAULT = 2160      # 帧周期（bit），frame_format.md §7
M_HIT_DEFAULT = 2             # M/N 判决（§8.3）
N_SLOT_DEFAULT = 3
NAVG = 16                     # 噪声估计平均长度（2 的幂，右移除法）
NAVG_SHIFT = 4                # = log2(NAVG)，四舍五入加 (NAVG>>1)
COEFF_Q = 13                  # 门限系数 K = 13/8 = 1.625
COEFF_SHIFT = 3
THRESH_MIN = 52               # 门限下限（§8.5 虚警上界的关键）
SYNC_MASK = (1 << SYNC_W) - 1


def sim_sync_acq(
    cmds: Iterable[tuple[int, int]],
    frame_len: int = FRAME_LEN_DEFAULT,
    m_hit: int = M_HIT_DEFAULT,
    n_slot: int = N_SLOT_DEFAULT,
) -> list[tuple[int, int, int, int, int]]:
    """逐拍推进捕获器，返回有效拍输出 (hit, acq, frame_start, corr, thresh)。

    cmds 每项 = (din_valid, din_bit)；din_valid=0 的拍整拍冻结（无输出行）。
    """
    sr = 0
    hist = [0] * NAVG          # 16 深零填充滑窗（空历史 == 全 0）
    h_idx = 0
    h_sum = 0                  # hist 之和，恒 == Σ 已见近 16 拍 corr
    track = False
    timer = 0
    m_cnt = 0
    slots = 0
    out: list[tuple[int, int, int, int, int]] = []

    for din_valid, din_bit in cmds:
        if not din_valid:
            continue

        # 1) 滑动相关（最新 bit 进 LSB；恰好覆盖同步字时 sr == SYNC_WORD → corr=64）
        sr = ((sr << 1) | (int(din_bit) & 1)) & SYNC_MASK
        corr = SYNC_W - ((sr ^ SYNC_WORD).bit_count())

        # 2) 恒虚警门限（训练窗 = 近 16 拍历史，不含本拍）+ 命中
        noise_est = (h_sum + (NAVG >> 1)) >> NAVG_SHIFT
        thresh = max(THRESH_MIN, (noise_est * COEFF_Q) >> COEFF_SHIFT)
        hit = 1 if corr >= thresh else 0

        h_sum += corr - hist[h_idx]          # 覆盖的槽恰是 16 拍前的旧值
        hist[h_idx] = corr
        h_idx = (h_idx + 1) % NAVG

        # 3) M/N 状态迁移（§8.3）
        acq = 0
        frame_start = 0
        if not track:
            if hit:
                track = True
                timer = frame_len
                m_cnt = 1
                slots = 1
                frame_start = 1
        elif timer > 1:
            timer -= 1                       # 非槽位拍：hit 忽略（锁定期）
        else:                                # timer == 1：槽位拍
            slots += 1
            if hit:
                m_cnt += 1
                frame_start = 1
            if m_cnt >= m_hit:               # 声明优先于弃候选
                acq = 1
                track = False
            elif slots >= n_slot:
                track = False
            else:
                timer = frame_len

        out.append((hit, acq, frame_start, corr, thresh))
    return out
