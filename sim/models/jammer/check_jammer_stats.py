#!/usr/bin/env python3
"""S2 干扰注入源 · 频谱与 JSR 核验

读 sim/models/jammer/dump/ 下 tb_jammer_stats.sv 导出的场景样本，用**解析判据**
核验四类干扰波形与 JSR 标定。全部期望值由 dump/jammer_config.log 里的参数算出，
不在本文件重复写常量。

判据一览：
  off            关闭干扰时逐位透明
  tone          峰频 = FTW/2^32、总功率 = JS·10^(JSR/10)、杂散 ≤ -40 dBc
  multitone     四个峰的频率与各自功率、总功率
  sweep         瞬时频率斜率 = DFW/2^32、起点 = FTW0/2^32、周期 = PERIOD、功率
  partial       -3 dB 带宽 ≈ 0.88/D、带外功率占比、总功率
  jsr           三档 JSR 的实测功率比（含 0/5/10 dB）
  sum           输出 = 量化(信号 + 干扰)，削顶样本另计

用法：python check_jammer_stats.py     （先跑 run_jammer_check.ps1 生成 dump）
"""
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DUMP = HERE / "dump"
OUT_CSV = HERE.parents[2] / "data" / "s2_jammer_stats" / "jammer_stats_table.csv"

RESULTS: list[dict] = []


def add_check(name: str, ok: bool, measured, expected, tol, note: str = "") -> None:
    RESULTS.append({
        "check": name,
        "status": "PASS" if ok else "FAIL",
        "measured": measured,
        "expected": expected,
        "tolerance": tol,
        "note": note,
    })
    print(f"[JM-RESULT] check={name} status={'PASS' if ok else 'FAIL'} "
          f"measured={measured} expected={expected} tol={tol}")


def load_config() -> dict:
    cfg = {}
    for line in (DUMP / "jammer_config.log").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, val = line.split()
        cfg[key] = float(val) if ("." in val or "e" in val.lower()) else int(val)
    return cfg


def load_matrix(path: Path, cols: int | None = None) -> np.ndarray:
    data = np.loadtxt(path, comments="#")
    if data.ndim == 1:
        data = data.reshape(1, -1)
    return data if cols is None else data[:, :cols]


def to_complex(codes: np.ndarray, frac: int) -> np.ndarray:
    return (codes[:, 0] + 1j * codes[:, 1]) / (2.0 ** frac)


# ============================================================
# 频谱工具
# ============================================================
def fft_peak_freq(z: np.ndarray) -> float:
    """归一化到 fs 的峰频，Hann 窗 + 抛物线插值到亚 bin 精度。"""
    n = len(z)
    spec = np.abs(np.fft.fftshift(np.fft.fft(z * np.hanning(n)))) ** 2
    k = int(np.argmax(spec))
    d = 0.0
    if 0 < k < len(spec) - 1:
        a, b, c = spec[k - 1], spec[k], spec[k + 1]
        denom = a - 2.0 * b + c
        if denom != 0:
            d = 0.5 * (a - c) / denom
    return (k + d - n / 2.0) / n


def spectral_peaks(z: np.ndarray, thresh_db: float = -25.0, merge_bins: int = 3):
    """返回归一化频率的峰列表（合并 Hann 主瓣内的相邻 bin）。"""
    n = len(z)
    spec = np.abs(np.fft.fftshift(np.fft.fft(z * np.hanning(n)))) ** 2
    spec_db = 10.0 * np.log10(spec / spec.max() + 1e-30)
    cand = [i for i in range(1, len(spec) - 1)
            if spec_db[i] > thresh_db and spec[i] >= spec[i - 1] and spec[i] >= spec[i + 1]]
    groups: list[list[int]] = []
    for i in cand:
        if groups and i - groups[-1][-1] <= merge_bins:
            groups[-1].append(i)
        else:
            groups.append([i])
    out = []
    for g in groups:
        k = max(g, key=lambda i: spec[i])
        out.append(((k - n / 2.0) / n, float(spec[k] / spec.sum())))
    return out


def spur_db(z: np.ndarray, f_expected: float, half_width_bins: int = 4) -> float:
    """主瓣之外的功率占比（dBc）——纯音的杂散水平。"""
    n = len(z)
    spec = np.abs(np.fft.fftshift(np.fft.fft(z * np.hanning(n)))) ** 2
    k0 = int(round(f_expected * n + n / 2.0))
    lo = max(0, k0 - half_width_bins)
    hi = min(len(spec), k0 + half_width_bins + 1)
    total = float(spec.sum())
    in_band = float(spec[lo:hi].sum())
    return 10.0 * math.log10(max(total - in_band, 1e-30) / total)


def psd_smoothed(z: np.ndarray, nseg: int = 16, smooth: int = 5):
    """Welch 平均周期图 + 滑动平均平滑，返回 (归一化频率轴, 线性功率)。"""
    seg_len = len(z) // nseg
    seg = z[:seg_len * nseg].reshape(nseg, seg_len)
    win = np.hanning(seg_len)
    psd = (np.abs(np.fft.fftshift(np.fft.fft(seg * win, axis=1))) ** 2).mean(axis=0)
    freqs = (np.arange(seg_len) - seg_len / 2.0) / seg_len
    if smooth > 1:
        kern = np.ones(smooth) / smooth
        psd = np.convolve(psd, kern, mode="same")
    return freqs, psd


# ============================================================
# 各场景核验
# ============================================================
def check_off(cfg: dict) -> None:
    din = load_matrix(DUMP / "off_in.log")
    dout = load_matrix(DUMP / "off_out.log")
    n = min(len(din), len(dout))
    mismatch = int(np.sum(np.any(din[:n] != dout[:n, :2], axis=1)))
    jm_nonzero = int(np.sum(np.any(dout[:n, 2:] != 0, axis=1)))
    add_check("off_identity", mismatch == 0 and len(din) == len(dout),
              f"mismatch={mismatch}", "0", "0",
              f"关闭干扰时逐位透明；拍数 in={len(din)} out={len(dout)}")
    add_check("off_jammer_zero", jm_nonzero == 0, f"{jm_nonzero} 拍非零", "0", "0",
              "关闭时干扰输出应恒为 0")


def check_sum(cfg: dict, phase: str) -> None:
    din = load_matrix(DUMP / f"{phase}_in.log")
    dout = load_matrix(DUMP / f"{phase}_out.log")
    n = min(len(din), len(dout))
    frac = int(cfg["FRAC"])
    scale = float(2 ** frac)
    lo, hi = -scale * 2.0, scale * 2.0 - 1.0 / 1.0   # 14/11 补码界：±4.0
    sig = din[:n].astype(float) / scale
    jam = dout[:n, 2:].astype(float) / scale
    out = dout[:n, :2].astype(float)
    expect_v = sig + jam
    keep = np.all(np.abs(expect_v) < 3.99, axis=1)      # 排除顶到 ±4.0 轨的样本
    clipped = int(np.sum(~keep))
    if keep.sum() == 0:
        add_check(f"sum_{phase}", False, "all clipped", "0", "1 code", "全部削顶，无法核对")
        return
    exp_codes = np.round(expect_v[keep] * scale)
    err = float(np.max(np.abs(out[keep] - exp_codes)))
    add_check(f"sum_{phase}", err <= 1.0, f"max err={err:.3f} code (clipped={clipped})",
              "0", "1 code", "输出应为量化后的「信号 + 干扰」")


def check_tone(cfg: dict, tag: str, jsr_x10: int) -> None:
    din = load_matrix(DUMP / f"tone_{tag}_in.log")
    dout = load_matrix(DUMP / f"tone_{tag}_out.log")
    frac = int(cfg["FRAC"])
    jam = to_complex(dout[:, 2:], frac)
    sig = to_complex(din, frac)

    p_jam = float(np.mean(np.abs(jam) ** 2))
    p_sig = float(np.mean(np.abs(sig) ** 2))
    p_expect = cfg["JS"] * 10.0 ** (jsr_x10 / 100.0)

    add_check(f"tone{tag}_power", abs(p_jam / p_expect - 1.0) < 0.01,
              f"{p_jam:.6f}", f"{p_expect:.6f}", "rel 1%",
              "干扰总功率 = JS·10^(JSR/10)")

    jsr_meas = 10.0 * math.log10(p_jam / p_sig)
    add_check(f"tone{tag}_jsr", abs(jsr_meas - jsr_x10 / 10.0) < 0.2,
              f"{jsr_meas:.4f} dB", f"{jsr_x10 / 10.0:.4f} dB", "0.2 dB",
              "实测 JSR = 10·log10(P_jam / P_signal)")

    f_expect = cfg["TONE_FTW"] / 2.0 ** 32
    f_meas = fft_peak_freq(jam)
    add_check(f"tone{tag}_peak_freq", abs(f_meas - f_expect) < 1e-4,
              f"{f_meas:.8f}", f"{f_expect:.8f}", "1e-4",
              "单音峰频 = FTW/2^32（归一化到 fs）")

    if tag == "0":
        sp = spur_db(jam, f_expect)
        add_check("tone0_purity", sp < -40.0, f"{sp:.2f} dBc", "<-40 dBc", "-40 dBc",
                  "纯音主瓣外的杂散（量化底噪）")


def check_multitone(cfg: dict) -> None:
    din = load_matrix(DUMP / "multitone_in.log")
    dout = load_matrix(DUMP / "multitone_out.log")
    frac = int(cfg["FRAC"])
    jam = to_complex(dout[:, 2:], frac)
    sig = to_complex(din, frac)

    count = int(cfg["MULTI_COUNT"])
    f_expect = [(cfg["MULTI_FTW"] + k * cfg["MULTI_SPACING"]) / 2.0 ** 32 for k in range(count)]

    peaks = spectral_peaks(jam)
    peaks_sorted = sorted(p[0] for p in peaks)
    add_check("multi_peak_count", len(peaks) == count,
              f"{len(peaks)} 峰", f"{count} 峰", "0",
              "频谱峰数与配置音数一致")

    if len(peaks) == count:
        err = float(np.max(np.abs(np.array(peaks_sorted) - np.array(f_expect))))
        add_check("multi_peak_freqs", err < 1e-4, f"max err={err:.2e}",
                  "各音频率 = (FTW + k·spacing)/2^32", "1e-4",
                  f"期望 {[round(f, 6) for f in f_expect]}")

        peak_pow = np.array(sorted((p[1] for p in peaks)))
        add_check("multi_tone_balance", float(peak_pow.max() / peak_pow.min()) < 1.1,
                  f"max/min={float(peak_pow.max() / peak_pow.min()):.4f}", "1.0", "1.1",
                  "等功率合成的各音功率应一致")

    p_jam = float(np.mean(np.abs(jam) ** 2))
    p_sig = float(np.mean(np.abs(sig) ** 2))
    jsr_meas = 10.0 * math.log10(p_jam / p_sig)
    add_check("multi_jsr", abs(jsr_meas - 0.0) < 0.2, f"{jsr_meas:.4f} dB", "0 dB", "0.2 dB",
              "四音合计功率仍等于 JS（JSR 0 dB）")


def check_sweep(cfg: dict) -> None:
    dout = load_matrix(DUMP / "sweep_out.log")
    frac = int(cfg["FRAC"])
    jam = to_complex(dout[:, 2:], frac)

    nu = np.angle(jam[1:] * np.conj(jam[:-1])) / (2.0 * math.pi)
    period = int(cfg["SWEEP_PERIOD"])
    dfw = cfg["SWEEP_DFW"]
    slope_expect = dfw / 2.0 ** 32
    f0_expect = cfg["SWEEP_FTW0"] / 2.0 ** 32
    span = period * slope_expect

    # 扫频回卷：瞬时频率突降约一个 span
    jumps = list(np.where(np.diff(nu) < -0.5 * span)[0] + 1)
    seg_starts = [0] + jumps
    seg_ends = jumps + [len(nu)]
    lens = [e - s for s, e in zip(seg_starts, seg_ends)]
    full = [L for L in lens[:-1]] or lens
    mean_len = float(np.mean(full))

    add_check("sweep_period", abs(mean_len - period) <= 4.0,
              f"{mean_len:.1f} 拍", f"{period} 拍", "±4 拍",
              f"共 {len(jumps)} 次回卷，{len(seg_starts)} 段")

    # 对第一段做线性拟合：斜率 = DFW/2^32，截距 = FTW0/2^32
    s, e = seg_starts[0], seg_ends[0]
    idx = np.arange(s, e, dtype=float)
    if len(idx) >= 16:
        a, b = np.polyfit(idx, nu[s:e], 1)
        add_check("sweep_slope", abs(a / slope_expect - 1.0) < 1e-3,
                  f"{a:.3e}", f"{slope_expect:.3e}", "rel 1e-3",
                  "瞬时频率斜率 = DFW/2^32（cycle/sample²）")
        add_check("sweep_start_freq", abs(b - f0_expect) < 1e-4,
                  f"{b:.8f}", f"{f0_expect:.8f}", "1e-4",
                  "扫频起点 = FTW0/2^32")
    else:
        add_check("sweep_slope", False, "段太短", "—", "—", "无法拟合")

    p_jam = float(np.mean(np.abs(jam) ** 2))
    add_check("sweep_power", abs(p_jam / cfg["JS"] - 1.0) < 0.01,
              f"{p_jam:.6f}", f"{cfg['JS']:.6f}", "rel 1%", "扫频功率 = JS（JSR 0 dB）")


def _sinc_half_point() -> float:
    """解 |sinc(x)| = 1/sqrt(2) 的 x（= -3 dB 点，单位 fD/fs）。"""
    xs = np.linspace(0.01, 3.0, 200001)
    vals = np.abs(np.sinc(xs)) - 1.0 / math.sqrt(2.0)
    idx = np.where(np.diff(np.sign(vals)) != 0)[0][0]
    return float(xs[idx])


def check_partial(cfg: dict) -> None:
    dout = load_matrix(DUMP / "partial_out.log")
    frac = int(cfg["FRAC"])
    jam = to_complex(dout[:, 2:], frac)
    div = int(cfg["PB_DIV"])

    warm = jam[div:]                                  # 跳过滤波缓冲预热段
    p_jam = float(np.mean(np.abs(warm) ** 2))
    add_check("partial_power", abs(p_jam / cfg["JS"] - 1.0) < 0.03,
              f"{p_jam:.6f}", f"{cfg['JS']:.6f}", "rel 3%",
              f"跳过前 D={div} 拍预热后总功率 = JS")

    freqs, psd = psd_smoothed(warm, nseg=16, smooth=5)
    fc = cfg["PB_FTW"] / 2.0 ** 32
    pk = int(np.argmax(psd))

    # 参考电平取峰值附近的**局部均值**，不能取 argmax 本身：平滑周期图的峰值是
    # 随机起伏的上偏值（实测可达均值的 1.4 倍），拿它当 -3 dB 门限会把带宽测窄。
    lo_ref = max(0, pk - 20)
    hi_ref = min(len(psd), pk + 21)
    ref = float(np.mean(psd[lo_ref:hi_ref]))
    half = ref / 2.0

    def crossing(start: int, step: int) -> float:
        i = start
        while 0 < i < len(psd) - 1 and psd[i] > half:
            i += step
        return abs(float(freqs[i]) - fc)

    bw_meas = crossing(pk, -1) + crossing(pk, +1)
    x3 = _sinc_half_point()
    bw_expect = 2.0 * x3 / div                       # 滑动平均 |H|²≈sinc²(fD/fs)
    add_check("partial_bandwidth", abs(bw_meas / bw_expect - 1.0) < 0.30,
              f"{bw_meas:.5f} fs", f"{bw_expect:.5f} fs", "rel 30%",
              f"双边 -3 dB 带宽 = 2×{x3:.4f}/D（滑动平均的 sinc² 形状）")

    # 带外功率占比：与 sinc² 裙边的**解析预测**比，而不是拍一个想当然的门限。
    # sinc² 在 ±2×(-3dB) 之外的理论泄漏约 11%，拿 -10 dB 卡它必然误判。
    # 测量区间是 fc ± 2×单边 -3dB 带宽，故积分上限取 2·x3（u = f·D/fs）
    u = np.linspace(0.0, 2.0 * x3, 20001)
    frac_predict = 1.0 - 2.0 * float(np.trapezoid(np.sinc(u) ** 2, u))
    b3 = bw_expect / 2.0
    out_mask = np.abs(freqs - fc) > 2.0 * b3
    in_pow = float(psd[~out_mask].sum())
    out_pow = float(psd[out_mask].sum())
    frac_meas = out_pow / max(in_pow + out_pow, 1e-30)
    add_check("partial_outband", abs(frac_meas - frac_predict) < 0.04,
              f"{frac_meas * 100:.2f}%", f"{frac_predict * 100:.2f}%", "4 个百分点",
              "±2×单边 -3dB 带宽之外的功率占比 vs sinc² 裙边解析值")

    p_sig = float(np.mean(np.abs(to_complex(load_matrix(DUMP / "partial_in.log"), frac)) ** 2))
    jsr_meas = 10.0 * math.log10(p_jam / p_sig)
    add_check("partial_jsr", abs(jsr_meas - 0.0) < 0.3, f"{jsr_meas:.4f} dB", "0 dB", "0.3 dB",
              "部分频带同样按总功率标定 JSR（0 dB 档）")


def write_csv(cfg: dict) -> None:
    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_CSV, "w", encoding="utf-8", newline="\n") as f:
        w = csv.writer(f)
        w.writerow(["# S2 干扰注入源频谱与 JSR 核验 · check_jammer_stats.py 生成，勿手改"])
        w.writerow(["# 场景参数来自 sim/models/jammer/dump/jammer_config.log"])
        w.writerow([f"# JS={cfg['JS']}  源格式={int(cfg['SRC_W'])}/{int(cfg['SRC_FRAC'])}  "
                    f"输出={int(cfg['W'])}/{int(cfg['FRAC'])}  单音={cfg['TONE_FTW']}/2^32  "
                    f"四音间隔={cfg['MULTI_SPACING']}/2^32  扫频斜率={cfg['SWEEP_DFW']}/2^32  "
                    f"扫频周期={int(cfg['SWEEP_PERIOD'])}  部分频带 D={int(cfg['PB_DIV'])}"])
        w.writerow(["check", "status", "measured", "expected", "tolerance", "note"])
        for r in RESULTS:
            w.writerow([r["check"], r["status"], r["measured"], r["expected"], r["tolerance"], r["note"]])


def main() -> int:
    if not (DUMP / "jammer_config.log").exists():
        print(f"[JM] 缺少 {DUMP/'jammer_config.log'}，先跑 run_jammer_check.ps1", file=sys.stderr)
        return 2

    cfg = load_config()

    check_off(cfg)
    check_tone(cfg, "0", cfg["JSR_TONE_0_X10"])
    check_tone(cfg, "5", cfg["JSR_TONE_5_X10"])
    check_tone(cfg, "10", cfg["JSR_TONE_10_X10"])
    check_multitone(cfg)
    check_sweep(cfg)
    check_partial(cfg)

    for phase in ("off", "tone_0", "tone_5", "tone_10", "multitone", "sweep", "partial"):
        check_sum(cfg, phase)

    write_csv(cfg)

    failed = [r for r in RESULTS if r["status"] == "FAIL"]
    print()
    print("==================== S2 干扰源核验 ====================")
    for r in RESULTS:
        print(f"  [{r['status']}] {r['check']:<24} measured={r['measured']:<26} expected={r['expected']}")
    print("======================================================")
    print(f"  明细表：{OUT_CSV}")
    if failed:
        print(f"  [JAMMER STATS] FAIL ({len(failed)}/{len(RESULTS)} 项未达预期)")
        return 1
    print(f"  [JAMMER STATS] PASS ({len(RESULTS)} 项全部达预期)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
