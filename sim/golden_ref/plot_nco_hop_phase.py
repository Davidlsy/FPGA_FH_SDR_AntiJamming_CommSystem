#!/usr/bin/env python3
"""S6 nco_hop 相位轨迹图（出口门槛"断言报告 + 相位轨迹图"双证据之二）

数据源 = seq 用例向量（sim/framework/vectors/nco_hop/seq_{stim,expect}.hex），
该向量已由 xsim 位真比对 0 错误锁定，故图上轨迹即 RTL 实际输出轨迹。

图两幅:
  (a) 相位轨迹（前 256 拍 / 32 跳放大，跳沿竖线）——斜率只在跳沿改变、折点无阶跃；
  (b) 每跳实测步进 vs §5.1 冻结 FTW 表——256 跳 × 16 信道逐点重合。

用法:
    python sim/golden_ref/plot_nco_hop_phase.py     # 出图到 data/s6_nco_hop_phase/
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[2]
VEC_DIR = ROOT / "sim" / "framework" / "vectors" / "nco_hop"
OUT_DIR = ROOT / "data" / "s6_nco_hop_phase"

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

FTW_TABLE = np.array([(2 * k + 1) * 1024 for k in range(16)], dtype=np.int64)


def _read_hex(path: Path, width_bits: int) -> np.ndarray:
    vals = [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]
    return np.array(vals, dtype=np.int64) & ((1 << width_bits) - 1)


def main() -> int:
    stim = _read_hex(VEC_DIR / "seq_stim.hex", 6)
    exp = _read_hex(VEC_DIR / "seq_expect.hex", 48)

    valid = (stim >> 5) & 1
    hop = (stim >> 4) & 1
    ch = stim & 0xF
    phase = (exp >> 32) & 0xFFFF

    k = np.nonzero(valid)[0]                      # 输出拍 ↔ 有效激励拍
    if len(k) != len(phase):
        raise RuntimeError(f"有效拍 {len(k)} != 期望行 {len(phase)}")

    hop_k = k[(hop[k] == 1)]                      # 跳沿（激励拍号）
    hop_pos = np.searchsorted(k, hop_k)           # 跳沿在输出序列中的位置
    hop_ch = ch[hop_k]

    # 每跳实测步进：生效延迟 2 拍 → 首个反映新字的步进是 Δphase[k+1]（= phase[k+2]−phase[k+1]）
    delta = np.diff(phase.astype(np.int64)) & 0xFFFF
    step_meas = delta[hop_pos + 1]                # 该跳首次反映新 ftw 的步进

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11.0, 7.2))

    zoom = 256                                        # (a) 只画前 256 拍（32 跳）便于看折点
    ax1.plot(k[:zoom], phase[:zoom], lw=1.0, color="#1f4e79")
    for x in hop_k[:33]:
        ax1.axvline(x, color="#c00000", lw=0.5, alpha=0.5)
    ax1.set_title("(a) nco_hop 相位轨迹（seq 前 256 拍 / 32 跳放大；全程 2048 拍由断言覆盖，红线 = 跳沿）")
    ax1.set_xlabel("采样拍")
    ax1.set_ylabel("相位累加器（16 bit 回绕）")
    ax1.set_xlim(k[0], k[zoom - 1])
    ax1.grid(alpha=0.3)

    hop_no = np.arange(len(hop_pos))
    for kk in range(16):
        sel = hop_ch == kk
        if sel.any():
            ax2.plot(hop_no[sel], FTW_TABLE[kk] * np.ones(sel.sum()), ".",
                     ms=4, color="#c00000", alpha=0.9)
    ax2.plot([], [], ".", ms=5, color="#c00000", label="FTW[k] = (2k+1)·1024（§5.1 冻结表）")
    ax2.plot(hop_no, step_meas, "o", ms=6, mfc="none", mew=1.0, color="#1f4e79",
             label="实测步进（跳后首个生效步进，重合于红点）")
    resid = int(np.max(np.abs(step_meas - FTW_TABLE[hop_ch])))
    ax2.set_title(f"(b) 每跳实测步进 vs 冻结 FTW 表（生效延迟 2 拍；max|差| = {resid}）")
    ax2.set_xlabel("跳序号")
    ax2.set_ylabel("步进 / 拍")
    ax2.set_xlim(-4, hop_no[-1] + 4)
    ax2.grid(alpha=0.3)
    ax2.legend(loc="upper right", fontsize=9)

    fig.tight_layout()
    out = OUT_DIR / "phase_trajectory.png"
    fig.savefig(out, dpi=140)
    print(f"[NCO-HOP-PLOT] hops={len(hop_pos)}  max|step-FTW|={int(np.max(np.abs(step_meas - FTW_TABLE[hop_ch])))}  -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
