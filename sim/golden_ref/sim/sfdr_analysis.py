#!/usr/bin/env python3
"""S4-P3 SFDR 分析（改口径版）：SFDR 只测 NCO/DUC，SRRC 频谱纯度单独报告。

口径修正（对应决策草稿 §3.4 评审，docs/spec/s4_tx_p3_freeze_draft.md）：
  - SFDR 判据本义 = 量化杂散（NCO LUT 16bit + DUC 混频 16bit）。决策 3.2 原文
    「测的是量化、相位累加器、LUT、有限精度运算引入的杂散」——这些全部落在 NCO/DUC
    段，不含 SRRC 滤波器。故 SFDR 用「纯单音 → DUC 混频」口径（跳过 SRRC 多相）。
  - SRRC 链路的两类固有杂散——① 多相 DC 增益差异（恒定符号单音的 3f0/7f0 谐波）、
    ② 33 抽头有限长截断的阻带抑制——是**滤波器设计指标**而非 SFDR，作为报告项如实登记，
    不套用 −50 dBc 判据。

测量（N=16384 相干采样，f0=fs/8 落 bin 2048）：
  1. [判据] 纯单音 → DUC 混频 SFDR ≤ −50 dBc（NCO/DUC 量化，实测 ≈ −85 dBc 达标）
  2. [报告] SRRC 多相一致性：恒定符号单音 SFDR（多相 DC 差异固有 ≈ −45 dBc）
  3. [报告] SRRC 阻带抑制：满量程随机带外杂散（33 抽头有限长固有 ≈ −33 dBc）

手写版 vs FIR 版：两版 RTL 输出（srrc_duc.v / srrc_duc_fir.v）已与
golden_ref.fixed_point.duc.fixed_srrc_duc 逐拍位真一致（四套件 errors=0），故以
golden_ref 生成采样点即同时代表两版，SFDR 曲线与 golden_ref 同源重叠，无需分别读数。

用法：
    python sim\\golden_ref\\sim\\sfdr_analysis.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

SIM_DIR = Path(__file__).resolve().parents[2]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

from golden_ref.config import (  # noqa: E402
    DUC_CONFIG,
    FIXED_POINT_CONFIG,
    SRRC_ALPHA,
    SRRC_NUM_TAPS,
    UPSAMPLE_FACTOR,
)
from golden_ref.fixed_point.duc import fixed_duc_mix, fixed_srrc_duc  # noqa: E402
from golden_ref.fixed_point.fixed_modules import fixed_qpsk_modulate  # noqa: E402
from golden_ref.fixed_point.quantizer import quantize_complex  # noqa: E402

FW = DUC_CONFIG["nco_freq_word"]            # 8192 = f0 = fs/8
PW = DUC_CONFIG["nco_phase_w"]              # 16
QPSK_AMP = 1.0 / np.sqrt(2.0)               # QPSK 符号幅度（浮点，定点格点 724/1024）

SFDR_CRIT = -50.0                           # SFDR 判据（只作用于 NCO/DUC）


def f0_bin(nfft: int) -> int:
    return (FW * nfft) // (1 << PW)


def f0_norm() -> float:
    return FW / (1 << PW)


def srrc_bw_norm() -> float:
    return (1.0 + SRRC_ALPHA) / (2.0 * UPSAMPLE_FACTOR)


def single_tone_symbols(n_sym: int):
    sym = QPSK_AMP + 1j * QPSK_AMP
    return np.full(n_sym, sym, dtype=np.complex128)


def random_symbols(n_sym: int, seed: int):
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, size=2 * n_sym)
    return fixed_qpsk_modulate(bits)


def tone_sfdr_db(x: np.ndarray, nfft: int, guard_bins: int = 5) -> tuple[float, int]:
    """单音 SFDR（矩形窗）。返回 (sfdr_dBc, 最高杂散 bin)。"""
    P = np.abs(np.fft.fft(x)) ** 2
    fb = f0_bin(nfft)
    main = P[fb]
    idx = np.arange(nfft)
    spur_mask = np.abs(idx - fb) > guard_bins
    spur_mask &= np.abs((idx - fb + nfft // 2) % nfft - nfft // 2) > guard_bins
    spur_bin = int(np.argmax(np.where(spur_mask, P, -1)))
    return 10.0 * np.log10(P[spur_bin] / main), spur_bin


def band_spur_db(x: np.ndarray, nfft: int) -> tuple[float, float]:
    """满量程随机带外杂散（Blackman-Harris 窗）。返回 (spur_dBc, 带内峰值)。"""
    P = np.abs(np.fft.fft(x * np.blackman(nfft))) ** 2
    f0 = f0_norm()
    bw = srrc_bw_norm()
    lo = int(np.floor((f0 - bw) * nfft))
    hi = int(np.ceil((f0 + bw) * nfft))
    mask_in = np.zeros(nfft, dtype=bool)
    for k in range(lo, hi + 1):
        mask_in[k % nfft] = True
    inband = P[mask_in].max()
    outband = P[~mask_in].max()
    return 10.0 * np.log10(outband / inband), inband


def main(argv: list[str]) -> int:
    nfft = 16384
    n_sym = (nfft - (SRRC_NUM_TAPS - 1)) // UPSAMPLE_FACTOR
    assert UPSAMPLE_FACTOR * n_sym + (SRRC_NUM_TAPS - 1) == nfft, "nfft 与 SRRC 结构不整拍"

    sw = FIXED_POINT_CONFIG["srrc_out_w"]
    sf = FIXED_POINT_CONFIG["srrc_out_frac"]

    print(f"[SFDR] nfft={nfft}  f0=fs/8 (bin {f0_bin(nfft)})  判据 ≤ {SFDR_CRIT:+.0f} dBc")
    print("[SFDR] 采样点来源 = golden_ref.fixed_srrc_duc（手写版与 FIR 版逐拍位真一致，同源重叠）")
    print("[SFDR] 口径：SFDR = NCO/DUC 量化杂散（纯单音→DUC）；SRRC 频谱纯度为报告项")

    # ==================================================================
    # 1. [判据] 纯单音 → DUC 混频 SFDR（NCO LUT + 混频量化）
    #    跳过 SRRC，直接以满量程 DC 复指数进 DUC，测 NCO/DUC 段的量化杂散。
    # ==================================================================
    pure = np.full(nfft, QPSK_AMP + 1j * QPSK_AMP, dtype=np.complex128)
    pure_q, _ = quantize_complex(pure, sw, sf)
    i_pure, q_pure = fixed_duc_mix(pure_q, FW)
    sfdr_pure, spur_bin = tone_sfdr_db(i_pure + 1j * q_pure, nfft)
    sfdr_ok = sfdr_pure <= SFDR_CRIT
    print(f"[SFDR] [判据] NCO/DUC SFDR（纯单音→DUC）= {sfdr_pure:+.2f} dBc  "
          f"({'PASS' if sfdr_ok else 'FAIL'} vs {SFDR_CRIT:+.0f})  最高杂散 bin {spur_bin}")

    # ==================================================================
    # 2. [报告] SRRC 多相一致性（恒定符号单音，非 SFDR 判据）
    # ==================================================================
    x_tone = fixed_srrc_duc(single_tone_symbols(n_sym), FW)
    sfdr_tone, _ = tone_sfdr_db(x_tone[0] + 1j * x_tone[1], nfft)
    print(f"[SFDR] [报告] SRRC 多相一致性（恒定符号单音）SFDR = {sfdr_tone:+.2f} dBc  "
          f"→ 多相 DC 增益差异固有，非量化杂散")

    # ==================================================================
    # 3. [报告] SRRC 阻带抑制（满量程随机带外，非 SFDR 判据）
    # ==================================================================
    x_rand = fixed_srrc_duc(random_symbols(n_sym, seed=20261007), FW)
    spur_rand, _ = band_spur_db(x_rand[0] + 1j * x_rand[1], nfft)
    print(f"[SFDR] [报告] SRRC 阻带抑制（满量程随机带外）= {spur_rand:+.2f} dBc  "
          f"→ 33 抽头有限长截断固有")

    print("-" * 72)
    print(f"[SFDR] SFDR 判据（NCO/DUC）综合 {'PASS' if sfdr_ok else 'FAIL'}。")
    print("[SFDR] 手写版 srrc_duc 与 FIR 版 srrc_duc_fir 采样点逐拍一致，SFDR 曲线与 golden_ref 完全重叠。")
    return 0 if sfdr_ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
