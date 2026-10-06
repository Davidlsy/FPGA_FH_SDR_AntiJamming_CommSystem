#!/usr/bin/env python3
"""S4-P3 定点 DUC 模型自检（NCO + LUT + 复数混频）

验证 docs/spec/s4_tx_p3_freeze_draft.md 决策 1 的黄金裁判是否自洽：
  - 四分之一波 sin LUT 单调、范围、量化精度
  - 四象限对称查表与 numpy 参考的误差
  - NCO 相位连续性（逐拍累加 = k*freq_word mod 2^16，切换 FTW 不清相位）
  - 向量化混频与逐拍 NCO 步进的等价性
  - 满量程输入下混频不溢出 Q5.11

用法：python sim\\golden_ref\\sim\\check_duc.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

SIM_DIR = Path(__file__).resolve().parents[2]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

from golden_ref.config import DUC_CONFIG, FIXED_POINT_CONFIG  # noqa: E402
from golden_ref.fixed_point.duc import (  # noqa: E402
    FixedNCO,
    fixed_duc_mix,
    gen_sin_lut,
    nco_lookup,
)
from golden_ref.fixed_point.quantizer import quantize  # noqa: E402

PW = DUC_CONFIG["nco_phase_w"]
LW = DUC_CONFIG["nco_lut_w"]
LF = DUC_CONFIG["nco_lut_frac"]
OW = DUC_CONFIG["duc_out_w"]
OF = DUC_CONFIG["duc_out_frac"]
FW = DUC_CONFIG["nco_freq_word"]

LSB_LUT = 2.0 ** -LF
LSB_DUC = 2.0 ** -OF

checks = 0


def check(name: str, cond: bool) -> None:
    global checks
    checks += 1
    if not cond:
        print(f"[DUC-CHECK] FAIL: {name}")
        sys.exit(1)


def on_lattice(x, frac: int) -> bool:
    scaled = np.asarray(x, dtype=np.float64) * (1 << frac)
    return bool(np.all(np.abs(scaled - np.round(scaled)) < 1e-6))


# ------------------------------------------------------------
# 1. LUT 基本性质
# ------------------------------------------------------------
lut_float, lut_int = gen_sin_lut()
n = 1 << (PW - 2)
check("LUT 项数 = 2^(phase_w-2)", len(lut_int) == n)
check("LUT 单调不减", bool(np.all(np.diff(lut_int.astype(np.int64)) >= 0)))
check("LUT 非负", bool(np.all(lut_int >= 0)))
check("LUT 上限 = 2^lut_frac（sin 峰值 1.0）", int(lut_int.max()) <= (1 << LF))
check("LUT[0] = 0（sin 0）", int(lut_int[0]) == 0)

theta = 2.0 * np.pi * np.arange(n) / (1 << PW)
err_lut = np.abs(lut_float - np.sin(theta))
check(f"LUT 量化误差 ≤ 0.5 LSB（max={err_lut.max():.2e}）", bool(err_lut.max() <= 0.5 * LSB_LUT + 1e-12))

# ------------------------------------------------------------
# 2. 四象限对称查表 vs numpy 参考
# ------------------------------------------------------------
# 四分之一波 LUT 的镜像公式 mirror = (2^(phase_w-2)-1) - idx 把 π/2 离散到表末项，
# 引入 ≤1 bin（≈1.57 LSB）的固有角误差；叠加 LUT 量化 0.5 LSB，理论容差 ≈ 2.1 LSB。
# 这是标准 DDS 四分之一波实现的行为（不是 bug），RTL 必须用同一镜像公式保证位真一致。
TOL = 3 * LSB_LUT
rng = np.random.default_rng(20261005)
phases = rng.integers(0, 1 << PW, size=10000)
cos_arr, sin_arr = nco_lookup(phases, lut_int)
ref_ang = 2.0 * np.pi * phases / (1 << PW)
ref_cos, ref_sin = np.cos(ref_ang), np.sin(ref_ang)
check(f"cos 查表误差 ≤ 3 LSB（max={np.abs(cos_arr - ref_cos).max():.2e}）",
      bool(np.abs(cos_arr - ref_cos).max() <= TOL + 1e-12))
check(f"sin 查表误差 ≤ 3 LSB（max={np.abs(sin_arr - ref_sin).max():.2e}）",
      bool(np.abs(sin_arr - ref_sin).max() <= TOL + 1e-12))
check("sin/cos 值域在 [-1, 1]", bool(np.abs(sin_arr).max() <= 1.0 + 1e-12 and np.abs(cos_arr).max() <= 1.0 + 1e-12))

# 端点：cos(0) = sin(π/2) 应恰为 LUT 末项（= 2^lut_frac，量化后为 1.0）
c0, s0 = nco_lookup(0, lut_int)
check("cos(0) = 1.0（LUT 末项）", abs(c0 - 1.0) <= LSB_LUT)
check("sin(0) = 0.0", abs(s0) <= 1e-12)

# ------------------------------------------------------------
# 3. NCO 相位连续性
# ------------------------------------------------------------
nco = FixedNCO(FW)
steps = 1000
seen = [nco.step()[1] for _ in range(steps)]
# 逐拍累加后的相位 = k*FW mod 2^16，与向量化相位一致
k = np.arange(steps, dtype=np.int64)
vec_phase = (k * np.int64(FW)) & ((1 << PW) - 1)
_, vec_sin = nco_lookup(vec_phase, nco.lut_int)
check("逐拍 step 与向量化相位等价（sin 一致）",
      bool(np.allclose(np.array(seen), vec_sin, atol=1e-15)))

# 切换 FTW 后相位不清零：切换前最后相位 + 新 FTW = 切换后首相位
nco2 = FixedNCO(FW)
nco2.step()
phase_before = nco2.phase
nco2.set_freq_word(3 * FW)
nco2.step()
check("set_freq_word 不清零相位（连续）", nco2.phase == ((phase_before + 3 * FW) & ((1 << PW) - 1)))

# ------------------------------------------------------------
# 4. 满量程混频不溢出 Q5.11
# ------------------------------------------------------------
# SRRC 满量程 ±4（Q3.11 可表示上界），四象限遍历 cos/sin 符号，取最坏组合
edge = (2 ** (FIXED_POINT_CONFIG["srrc_out_w"] - 1) - 1) / (2 ** FIXED_POINT_CONFIG["srrc_out_frac"])
shaped = np.array([edge + 1j * edge, edge - 1j * edge, -edge + 1j * edge, -edge - 1j * edge])
i_out, q_out = fixed_duc_mix(shaped, FW)
peak = max(np.abs(i_out).max(), np.abs(q_out).max())
check(f"满量程混频峰值 ≤ 8（实测 {peak:.4f}）", peak <= 8.0 + 1e-9)
check("满量程混频远低于 Q5.11 上限 ±16（不饱和）", peak < 16.0)

# ------------------------------------------------------------
# 5. 输出格点 + 向量化/逐拍等价
# ------------------------------------------------------------
i_out2, q_out2 = fixed_duc_mix(shaped, FW, lut_int)
check("输出落在 Q5.11 格点", on_lattice(i_out2, OF) and on_lattice(q_out2, OF))

# 逐拍 NCO 版：手动累加相位 → 混频 → 同样 quantize，与 fixed_duc_mix 的向量化路径对拍
phase = 0
mask = (1 << PW) - 1
cos_l, sin_l = [], []
for _ in range(len(shaped)):
    c, s = nco_lookup(phase, lut_int)
    cos_l.append(c); sin_l.append(s)
    phase = (phase + FW) & mask
i_mix = shaped.real * np.array(cos_l) - shaped.imag * np.array(sin_l)
q_mix = shaped.real * np.array(sin_l) + shaped.imag * np.array(cos_l)
i_manual, _ = quantize(i_mix, OW, OF)
q_manual, _ = quantize(q_mix, OW, OF)
check("向量化混频与逐拍 NCO 对拍一致（I 路）", bool(np.allclose(i_manual, i_out2, atol=1e-12)))
check("向量化混频与逐拍 NCO 对拍一致（Q 路）", bool(np.allclose(q_manual, q_out2, atol=1e-12)))

print(f"[DUC-CHECK] PASS  {checks} 项检查全过")
