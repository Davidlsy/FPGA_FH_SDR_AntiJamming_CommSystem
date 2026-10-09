#!/usr/bin/env python
"""sync_rx 环路系数标定器（#3 冻结值的来源，复现/重标用）

本文件是**收敛判据的唯一来源**：check_rx.py §5 直接 import cases/resid_rms/judge，
两边不可能漂移。

口径：
  · 600 符号 QPSK + SRRC 成形 + 匹配滤波，Q3.11 整数
  · 损伤 A：1 kHz 频偏 + 相偏（fs = 2 MSPS，500 ksym/s）
  · 损伤 B：无损伤基线
  · 损伤 C：±20 ppm 符号率偏差（真时间轴拉伸）+ 1 kHz 频偏
  · 损伤 D：±500 ppm 纯速率偏差 —— 超规格鲁棒性工况，专测 Ki_t 积分路径

判据（含**定时项** |mu|tail）：
  A: lock ≤ 500 符号，resid_rms_tail < 0.15 rad，|mu|tail < 0.5 采样
  B: lock ≤ 200 符号
  C: resid_rms_tail < 0.25 rad，|mu|tail < 0.5 采样
  D: resid_rms_tail < 0.25 rad，|mu|tail < 1.8 采样（mu 合法走到 ~1.2，只判不失锁）

为什么判据必须含定时项：早期只看载波残差，定时环**正反馈发散**（mu 乱跳、采样点
滑出符号峰）却照样过检 —— 载波残差对定时失锁不敏感。故 A/C 一律加 |mu|tail 门限。

用法:
    python calib_sync_rx.py               # 跑当前冻结系数的全部工况
    python calib_sync_rx.py --sweep       # 扫 Kp/Ki 网格，打印合格组合
    python calib_sync_rx.py --ckp A --cki B --tkp C --tki D   # 系数探针
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

SIM_DIR = Path(__file__).resolve().parents[1]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

from golden_ref.config import FIXED_POINT_CONFIG, RX_CONFIG  # noqa: E402
from golden_ref.fixed_point.fixed_modules import (  # noqa: E402
    fixed_pulse_shape, fixed_qpsk_modulate, fixed_srrc_coeffs,
)
from golden_ref.fixed_point.quantizer import quantize_complex  # noqa: E402
from golden_ref.fixed_point.rx_modules import fixed_sync_rx_hw  # noqa: E402

FS = 2e6
SAT16 = 1 << 15


def mk_mf_int(n_sym=600, seed=31):
    """n_sym 符号 QPSK + SRRC 成形 + 匹配滤波，返回 Q3.11 整数 I/Q。"""
    rng = np.random.default_rng(seed)
    syms = fixed_qpsk_modulate(rng.integers(0, 2, 2 * n_sym))
    shaped = fixed_pulse_shape(syms)
    h_q, _ = fixed_srrc_coeffs()
    mf = np.convolve(shaped, h_q)
    _, (mi, mq) = quantize_complex(mf, FIXED_POINT_CONFIG["srrc_out_w"],
                                   FIXED_POINT_CONFIG["srrc_out_frac"])
    return mi.copy(), mq.copy()


def impair(i_int, q_int, f_off=0.0, ph0=0.0, ppm=0.0):
    """频偏/相偏/符号率偏差作用于 Q3.11 整数（浮点域施加后重量化饱和）。

    率偏差 = **时间轴拉伸** rx[n] = tx[n·(1+ppm)]（线性插值 + 重量化）。
    早期版本只把频偏采样号乘 (1+ppm)，那并不改变符号率，C 工况根本测不到定时跟踪。
    """
    L = len(i_int)
    n_out = np.arange(L, dtype=np.float64)
    n_src = n_out * (1.0 + ppm)

    def warp(a):
        i0 = np.floor(n_src).astype(np.int64)
        fr = n_src - i0
        i1 = i0 + 1
        v0 = np.where((i0 >= 0) & (i0 < L), a[np.clip(i0, 0, L - 1)], 0.0)
        v1 = np.where((i1 >= 0) & (i1 < L), a[np.clip(i1, 0, L - 1)], 0.0)
        return v0 + (v1 - v0) * fr

    ri0, rq0 = warp(i_int), warp(q_int)
    rot = np.exp(1j * (2 * np.pi * f_off / FS * n_out + ph0))
    x = (ri0 + 1j * rq0) * rot
    ri = np.clip(np.round(x.real), -SAT16, SAT16 - 1).astype(np.int64)
    rq = np.clip(np.round(x.imag), -SAT16, SAT16 - 1).astype(np.int64)
    return ri, rq


EDGE = 16  # 首尾各弃符号数：MF 群延迟 8 符号 + mu 漂移裕量，尾部无数据支撑，残差是伪影


def resid_rms(sym_i, sym_q, tail=256, win=64):
    """残余相位误差 RMS（到最近 QPSK 点的角距），返回 (tail_rms, lock_sym)。

    只在有数据支撑的中段统计（掐掉 EDGE×2），否则尾部空符号把 RMS 抬到伪影水平。
    """
    ang = np.arctan2(sym_q.astype(np.float64), sym_i.astype(np.float64))
    nearest = np.round((ang - np.pi / 4) / (np.pi / 2)) * (np.pi / 2) + np.pi / 4
    resid = ((ang - nearest + np.pi) % (2 * np.pi) - np.pi)[EDGE:-EDGE]
    t = slice(max(0, len(resid) - tail), len(resid))
    lock = None
    for k in range(win - 1, len(resid)):
        if lock is None and np.sqrt(np.mean(resid[k - win + 1:k + 1] ** 2)) < 0.15:
            lock = k + 1
    return float(np.sqrt(np.mean(resid[t] ** 2))), lock


def run_case(i_int, q_int, ckp, cki, tkp, tki):
    """跑一例，返回 (resid_rms, lock, mu_tail)。

    mu_tail = 尾段 |mu| 峰值（采样）——**定时判据**。教训：早期判据只看载波残差，
    定时环正反馈发散（mu 乱跳）却照样过检；故收敛判据必须含定时项。
    """
    r = fixed_sync_rx_hw(i_int, q_int, costas_kp=ckp, costas_ki=cki,
                         timing_kp=tkp, timing_ki=tki)
    rms, lock = resid_rms(r["sym_i"], r["sym_q"])
    mu_s = np.abs(r["mu"][EDGE:-EDGE]) / 16384.0
    mu_tail = float(mu_s[-256:].max()) if len(mu_s) else float("inf")
    return rms, lock, mu_tail


def cases(seeds=(31,), amps=(1.0,)):
    """工况 × 数据种子 × 幅度档（幅度档乘到 Q3.11 整数上再饱和，模拟电平波动）。"""
    out = {}
    for seed in seeds:
        i0, q0 = mk_mf_int(seed=seed)
        for amp in amps:
            ai = np.clip(np.round(i0 * amp), -SAT16, SAT16 - 1).astype(np.int64)
            aq = np.clip(np.round(q0 * amp), -SAT16, SAT16 - 1).astype(np.int64)
            tag = f"s{seed}@{amp:g}"
            out[f"A1 +1kHz+0.7rad {tag}"] = impair(ai, aq, f_off=1e3, ph0=0.7)
            out[f"A2 -1kHz+2.3rad {tag}"] = impair(ai, aq, f_off=-1e3, ph0=2.3)
            out[f"B 无损伤 {tag}"] = (ai, aq)
            out[f"C1 +20ppm+1kHz {tag}"] = impair(ai, aq, f_off=1e3, ppm=20e-6)
            out[f"C2 -20ppm-1kHz {tag}"] = impair(ai, aq, f_off=-1e3, ppm=-20e-6)
            # D：超规格大速率偏差（600 符号内 mu 要走 ~1.2 采样）—— 专测 Ki_t 积分路径
            # 能不能跟住持续漂移。规格只要求 ±20ppm，D 是设计鲁棒性工况，不进冻结判据。
            out[f"D1 +500ppm {tag}"] = impair(ai, aq, ppm=500e-6)
            out[f"D2 -500ppm {tag}"] = impair(ai, aq, ppm=-500e-6)
    return out


MU_TOL = 0.5       # 采样：A/C 尾段 |mu| 峰值上限（这些工况 mu 应贴 0）
MU_TOL_D = (0.6, 1.8)  # 采样：D 工况 mu 应**跟住**漂移（~1.2）—— 上下界缺一不可


def judge(name, rms, lock, mu_tail):
    if name.startswith(("A1", "A2")):
        return lock is not None and lock <= 500 and rms < 0.15 and mu_tail < MU_TOL
    if name.startswith("B"):
        return lock is not None and lock <= 200
    if name.startswith("D"):
        lo, hi = MU_TOL_D
        # 下界是关键：只判 mu_tail < hi 会把"卡在 0 没跟住"误判为通过
        return np.isfinite(rms) and rms < 0.25 and lo < mu_tail < hi
    return np.isfinite(rms) and rms < 0.25 and mu_tail < MU_TOL


def slack(name, rms, lock, mu_tail):
    """统一裕量（越大越稳）：各判据折算到"符号数 / 毫弧度 / 毫采样"同一量纲。"""
    s = []
    if name.startswith(("A1", "A2")):
        s += [500 - (lock or 9999), (0.15 - rms) * 1000, (MU_TOL - mu_tail) * 1000]
    elif name.startswith("B"):
        s += [200 - (lock or 9999)]
    elif name.startswith("D"):
        lo, hi = MU_TOL_D
        s += [(0.25 - rms) * 1000, (mu_tail - lo) * 1000, (hi - mu_tail) * 1000]
    else:
        s += [(0.25 - rms) * 1000, (MU_TOL - mu_tail) * 1000]
    return min(s)


def parse_coef(argv):
    """--ckp/--cki/--tkp/--tki 数值探针（覆盖冻结值）。"""
    out = {}
    for key in ("ckp", "cki", "tkp", "tki"):
        flag = f"--{key}"
        if flag in argv:
            out[key] = int(argv[argv.index(flag) + 1])
    return out


def parse_list(argv, flag, cast, default):
    if flag not in argv:
        return default
    return tuple(cast(v) for v in argv[argv.index(flag) + 1].split(","))


def main(argv):
    cfg = RX_CONFIG
    seeds = parse_list(argv, "--seeds", int, (31,))
    amps = parse_list(argv, "--amps", float, (1.0,))
    cs = cases(seeds=seeds, amps=amps)

    if "--sweep" not in argv:
        o = parse_coef(argv)
        ckp = o.get("ckp", cfg["costas_kp_q19"])
        cki = o.get("cki", cfg["costas_ki_q19"])
        tkp = o.get("tkp", cfg["timing_kp_q19"])
        tki = o.get("tki", cfg["timing_ki_q19"])
        print(f"冻结系数: costas Kp={ckp} Ki={cki} | timing Kp={tkp} Ki={tki} (Q1.19)")
        ok = True
        for name, (ri, rq) in cs.items():
            rms, lock, mu_tail = run_case(ri, rq, ckp, cki, tkp, tki)
            good = judge(name, rms, lock, mu_tail)
            ok &= good
            print(f"  [{'PASS' if good else 'FAIL'}] {name}: lock={lock} "
                  f"resid_rms={rms:.4f} rad |mu|tail={mu_tail:.3f} samp")
        print(f"结论: {'全通过' if ok else '存在失败工况'}")
        return 0 if ok else 1

    # 细扫：围绕 Ki 死区以上的区域找裕量最大的组合
    print("扫描 costas/timing 系数网格（Q1.19）...")
    best = []
    for ckp in [1168, 2336, 4672, 9344]:
        for cki in [16, 32, 64, 128, 256]:
            for tkp in [920, 1835, 3670]:
                for tki in [13, 26, 52, 104]:
                    allok = True
                    worst = 1e9
                    rows = []
                    for name, (ri, rq) in cs.items():
                        rms, lock, mu_tail = run_case(ri, rq, ckp, cki, tkp, tki)
                        good = judge(name, rms, lock, mu_tail)
                        allok &= good
                        rows.append((name, rms, lock, mu_tail))
                        worst = min(worst, slack(name, rms, lock, mu_tail))
                    if allok:
                        best.append((worst, ckp, cki, tkp, tki, rows))
    best.sort(key=lambda t: -t[0])
    for worst, ckp, cki, tkp, tki, rows in best[:15]:
        print(f"  [OK] Kp_c={ckp} Ki_c={cki} Kp_t={tkp} Ki_t={tki} 裕量={worst:.0f} | " +
              " ".join(f"{n.split()[0]}:L{l},R{r:.3f},M{m:.2f}" for n, r, l, m in rows))
    print(f"合格组合数: {len(best)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
