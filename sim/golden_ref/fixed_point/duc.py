"""
S4-P3 定点 DUC（数字上变频）：NCO + 复数混频

把 SRRC 成形后的复基带（14 bit，Q3.11，即 fixed_pulse_shape 的输出）上变频到 NCO
固定频点，输出 16 bit（Q5.11）。与 docs/spec/s4_tx_interface.md §5.2（NCO 相位连续语义）
一致：

  - 相位累加器 16 bit，每采样节拍 += freq_word，相位绝不清零（相位连续跳频的根基）；
  - 相位不截断，直接作 sin/cos 四分之一波 LUT 地址（避免相位截断杂散）；
  - 复数混频 I' = I·cos − Q·sin，Q' = I·sin + Q·cos；
  - 乘法全精度中间，输出 round + saturate 到 Q5.11（决策 1，见 s4_tx_p3_freeze_draft.md）。

位宽全部来自 config.DUC_CONFIG，本文件不硬编码任何位宽。
"""
from __future__ import annotations

import numpy as np

from ..config import DUC_CONFIG
from .quantizer import quantize


# ============================================================
# 四分之一波 sin LUT
# ============================================================
def gen_sin_lut(phase_w: int | None = None,
                lut_w: int | None = None,
                lut_frac: int | None = None):
    """生成四分之一波 sin LUT（覆盖 [0, π/2) 区间，共 2^(phase_w-2) 项）。

    返回 (lut_float, lut_int)：
      lut_float: 量化到 Q(lut_w, lut_frac) 格点的浮点值，shape (2^(phase_w-2),)
      lut_int:   同值补码整数，shape 同上
    """
    phase_w = phase_w if phase_w is not None else DUC_CONFIG["nco_phase_w"]
    lut_w = lut_w if lut_w is not None else DUC_CONFIG["nco_lut_w"]
    lut_frac = lut_frac if lut_frac is not None else DUC_CONFIG["nco_lut_frac"]

    n = 1 << (phase_w - 2)                       # 四分之一波项数 = 2^(phase_w-2)
    idx = np.arange(n, dtype=np.float64)
    theta = 2.0 * np.pi * idx / (1 << phase_w)   # 覆盖 [0, π/2)，不含端点
    lut_float, lut_int = quantize(np.sin(theta), lut_w, lut_frac)
    return lut_float, lut_int


def _sin_int(phase, lut_int, phase_w: int) -> np.ndarray:
    """整数相位（0 ≤ phase < 2^phase_w）→ sin 的补码整数，四象限对称。

    phase 可为标量或数组。高 2 bit 定象限，低 (phase_w-2) bit 定象限内角。
    """
    mask = (1 << phase_w) - 1
    q_shift = phase_w - 2
    q_mask = (1 << q_shift) - 1

    p = np.asarray(phase, dtype=np.int64) & mask
    quadrant = (p >> q_shift).astype(np.int64)
    idx = (p & q_mask).astype(np.int64)
    mirror = q_mask - idx

    lut = np.asarray(lut_int, dtype=np.int64)
    sin = np.where(quadrant == 0, lut[idx],
          np.where(quadrant == 1, lut[mirror],
          np.where(quadrant == 2, -lut[idx],
                    -lut[mirror])))
    return sin


def nco_lookup(phase, lut_int, phase_w: int | None = None, lut_frac: int | None = None):
    """整数相位 → (cos, sin) 浮点值。

    cos(p) = sin(p + π/2) = sin(p + 2^(phase_w-2))，复用 sin 查表，保证 sin/cos
    由同一份 LUT 生成（与 RTL 单表 + 相位偏移一致，避免两表不一致的位真风险）。
    """
    phase_w = phase_w if phase_w is not None else DUC_CONFIG["nco_phase_w"]
    lut_frac = lut_frac if lut_frac is not None else DUC_CONFIG["nco_lut_frac"]

    s = _sin_int(phase, lut_int, phase_w)
    c = _sin_int(np.asarray(phase, dtype=np.int64) + (1 << (phase_w - 2)), lut_int, phase_w)
    scale = 1 << lut_frac
    return c / scale, s / scale


# ============================================================
# 相位累加器 NCO（逐拍步进，暴露相位连续性语义）
# ============================================================
class FixedNCO:
    """16 bit 相位累加器 NCO。每调用一次 step() 输出当前相位的 (cos, sin) 并步进。

    set_freq_word() 对应 §5.2 的 freq_valid 语义：载入新 FTW，下一拍生效，相位不清零。
    S4 阶段用固定频点（config.DUC_CONFIG["nco_freq_word"]）。
    """

    def __init__(self, freq_word: int | None = None, lut_int=None, phase_w: int | None = None):
        phase_w = phase_w if phase_w is not None else DUC_CONFIG["nco_phase_w"]
        self.phase_w = phase_w
        self.mask = (1 << phase_w) - 1
        fw = DUC_CONFIG["nco_freq_word"] if freq_word is None else freq_word
        self.freq_word = int(fw) & self.mask
        self.lut_int = gen_sin_lut(phase_w)[1] if lut_int is None else lut_int
        self.phase = 0

    def set_freq_word(self, freq_word: int) -> None:
        self.freq_word = int(freq_word) & self.mask

    def step(self):
        """返回当前相位的 (cos, sin) 浮点值，然后相位 += freq_word。"""
        c, s = nco_lookup(self.phase, self.lut_int, self.phase_w)
        self.phase = (self.phase + self.freq_word) & self.mask
        return c, s


# ============================================================
# 复数混频（黄金裁判主入口）
# ============================================================
def fixed_duc_mix(shaped, freq_word: int | None = None, lut_int=None):
    """SRRC 成形后的复基带 → NCO 混频输出（Q5.11 定点浮点值）。

    参数:
      shaped: 复基带数组（14 bit Q3.11 格点浮点值，即 fixed_pulse_shape 的输出）
      freq_word: NCO 频率字；None 用 DUC_CONFIG["nco_freq_word"]
      lut_int: 复用的 LUT；None 则现场生成

    返回:
      (i_out, q_out): 两路 16 bit Q5.11 格点浮点值数组，shape 与 shaped 相同
    """
    cfg = DUC_CONFIG
    w, frac = cfg["duc_out_w"], cfg["duc_out_frac"]
    phase_w = cfg["nco_phase_w"]
    mask = (1 << phase_w) - 1
    fw = DUC_CONFIG["nco_freq_word"] if freq_word is None else int(freq_word) & mask
    lut = gen_sin_lut(phase_w)[1] if lut_int is None else lut_int

    shaped = np.asarray(shaped, dtype=np.complex128)
    n = len(shaped)

    # 相位累加器逐拍推进：第 k 拍相位 = (k · fw) mod 2^phase_w。
    # 与 RTL 的"每拍 += fw 并溢出回绕"逐位等价（都是整数模 2^phase_w 累加）。
    k = np.arange(n, dtype=np.int64)
    phase = (k * (np.int64(fw))) & mask
    cos_arr, sin_arr = nco_lookup(phase, lut, phase_w)

    i_mix = shaped.real * cos_arr - shaped.imag * sin_arr
    q_mix = shaped.real * sin_arr + shaped.imag * cos_arr

    i_out, _ = quantize(i_mix, w, frac)
    q_out, _ = quantize(q_mix, w, frac)
    return i_out, q_out


def fixed_srrc_duc(symbols, freq_word: int | None = None, h_q=None):
    """端到端入口：QPSK 符号 → SRRC 成形 → DUC 混频（输出 Q5.11 采样序列）。

    symbols: 复符号数组（12 bit Q2.10 格点浮点值，即 fixed_qpsk_modulate 的输出）
    返回 (i_out, q_out)，长度为 len(symbols) * UPSAMPLE_FACTOR + num_taps - 1。
    """
    from .fixed_modules import fixed_pulse_shape
    shaped = fixed_pulse_shape(symbols, h_q=h_q)
    return fixed_duc_mix(shaped, freq_word=freq_word)
