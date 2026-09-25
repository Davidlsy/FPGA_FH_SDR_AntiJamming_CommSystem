#!/usr/bin/env python3
"""S2 信道模型库 · 统计核验

读 sim/models/channel/dump/ 下 tb_channel_stats.sv 导出的场景样本，对每个信道
效应做**解析判据**核验。刻意不另写一套 numpy 参考模型——两套「真理」是这类
验证最容易翻车的地方。唯一的例外是 AWGN 的期望 σ：它直接调用 S1 自己的
golden_ref.float_chain.awgn.add_awgn 现算，从而把「信道噪声与 S1 BER 基线同源」
变成一个可执行判据，而不是一句声明。

判据一览（measured / expected / tol 全部落 CSV）：
  identity      全旁路逐位透明
  awgn          每维均值、σ 对齐 golden_ref、白性（自相关）、无饱和
  cfo           相位斜率 = 2π·FTW/2^32、幅度不变、相位连续
  sfo           μ 漂移率 = ppm×1e-6、输出 = quant(m+μ)、滑码计数
  mp_impulse    冲激响应 = 抽头系数
  mp_rayleigh   各抽头功率 = 指数 PDP、幅度比 = π/4
  mp_rician     由统计估出的 K 与配置一致

用法：python check_channel_stats.py     （先跑 run_channel_check.ps1 生成 dump）
"""
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DUMP = HERE / "dump"
SIM_DIR = HERE.parents[1]
OUT_CSV = HERE.parents[2] / "data" / "s2_channel_stats" / "channel_stats_table.csv"

if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

from golden_ref.float_chain.awgn import add_awgn  # noqa: E402

PI = math.pi
# 低于该值的 K 视为纯瑞利（TB 用 -990 → -99 dB 表示纯瑞利）
PURE_RAYLEIGH_MAX_DB = -20.0
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
    print(f"[CH-RESULT] check={name} status={'PASS' if ok else 'FAIL'} "
          f"measured={measured} expected={expected} tol={tol}")


def load_config() -> dict:
    cfg = {}
    for line in (DUMP / "channel_config.log").read_text(encoding="utf-8").splitlines():
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


# ============================================================
# 各场景核验
# ============================================================
def check_identity(cfg: dict) -> None:
    din = load_matrix(DUMP / "identity_in.log")
    dout = load_matrix(DUMP / "identity_out.log")
    n = min(len(din), len(dout))
    mismatch = int(np.sum(np.any(din[:n] != dout[:n], axis=1)))
    add_check("identity_bit_exact", mismatch == 0 and len(din) == len(dout),
              f"mismatch={mismatch}", "mismatch=0", "0",
              f"全旁路逐位透明；拍数 in={len(din)} out={len(dout)}")
    add_check("identity_beat_count", len(din) == cfg["N_IDENT"] and len(dout) == cfg["N_IDENT"],
              f"in={len(din)},out={len(dout)}", f"{cfg['N_IDENT']} 拍", "0")


def check_awgn(cfg: dict) -> None:
    din = load_matrix(DUMP / "awgn_in.log")
    dout = load_matrix(DUMP / "awgn_out.log")
    n = min(len(din), len(dout))
    # dump 是定点码值；σ 的定义在实数域，故换算回实数域再统计
    noise = (dout[:n].astype(float) - din[:n].astype(float)) / (2.0 ** cfg["FRAC"])

    # 期望 σ 由 S1 自己的加噪函数现算：单位功率信号 → Es = 1 = 配置的 ES
    ref_sig = np.ones(8, dtype=np.complex128)
    es_ref = float(np.sum(np.abs(ref_sig) ** 2) / len(ref_sig))
    _, n0 = add_awgn(ref_sig, cfg["EB_N0_DB"], bit_rate=cfg["BIT_RATE"], sps=1)
    sigma_ref = math.sqrt(n0 / 2.0)

    add_check("awgn_es_consistent", abs(es_ref - cfg["ES"]) < 1e-12,
              f"{es_ref:.12f}", f"{cfg['ES']:.12f}", "1e-12",
              "核验用参考信号的 Es 与模型参数 ES 一致")

    # 模型内部 σ 与 golden_ref 现算值
    add_check("awgn_sigma_matches_golden", abs(cfg["AWGN_SIGMA"] / sigma_ref - 1.0) < 1e-9,
              f"{cfg['AWGN_SIGMA']:.12f}", f"{sigma_ref:.12f}", "rel 1e-9",
              "信道噪声口径与 golden_ref.add_awgn 同源")

    for dim, name in ((0, "i"), (1, "q")):
        x = noise[:, dim]
        mean = float(x.mean())
        std = float(x.std(ddof=1))
        tol_mean = 4.0 * sigma_ref / math.sqrt(n)
        add_check(f"awgn_mean_{name}", abs(mean) < tol_mean,
                  f"{mean:.6e}", "0", f"{tol_mean:.6e}", f"N={n}")
        add_check(f"awgn_std_{name}", abs(std / sigma_ref - 1.0) < 0.02,
                  f"{std:.6f}", f"{sigma_ref:.6f}", "rel 2%",
                  "每维 σ 对齐 golden_ref 现算值")

    # 白性：归一化自相关，滞后 1..16
    max_ac = 0.0
    for dim in (0, 1):
        x = noise[:, dim] - noise[:, dim].mean()
        denom = float(np.sum(x * x))
        for lag in range(1, 17):
            r = float(np.sum(x[:-lag] * x[lag:]) / denom)
            max_ac = max(max_ac, abs(r))
    tol_ac = 4.0 / math.sqrt(n)
    add_check("awgn_whiteness", max_ac < tol_ac, f"{max_ac:.6f}", f"<{tol_ac:.6f}", f"{tol_ac:.6f}",
              "噪声自相关（滞后 1..16）应近似为 0")

    # I/Q 独立
    r_iq = float(np.corrcoef(noise[:, 0], noise[:, 1])[0, 1])
    add_check("awgn_iq_independent", abs(r_iq) < 4.0 / math.sqrt(n),
              f"{r_iq:.6f}", "0", f"{4.0 / math.sqrt(n):.6f}")

    # 频谱平坦度（分段平均周期图的标准差，单位 dB）
    nseg = 64
    seg_len = n // nseg
    seg = noise[:seg_len * nseg, 0].reshape(nseg, seg_len)
    win = np.hanning(seg_len)
    psd = (np.abs(np.fft.rfft(seg * win, axis=1)) ** 2).mean(axis=0)
    band = psd[1:int(0.9 * len(psd))]
    psd_db = 10.0 * np.log10(band / band.mean())
    add_check("awgn_psd_flatness", float(psd_db.std()) < 2.0,
              f"{psd_db.std():.3f} dB", "<2.0 dB", "2.0 dB",
              f"分段平均周期图 PSD 标准差；max-min={float(psd_db.max() - psd_db.min()):.2f} dB")

    # 输出不得触界（14/11 范围 = ±4.0 → 码 ±8192）
    hi_code = int((1 << (cfg["W"] - 1)) - 1)
    lo_code = -int(1 << (cfg["W"] - 1))
    sat = int(np.sum((dout[:n] <= lo_code) | (dout[:n] >= hi_code)))
    add_check("awgn_no_saturation", sat == 0, f"{sat} samples at rail", "0", "0",
              f"输入 ±1.0、Eb/N0={cfg['EB_N0_DB']} dB 下不应饱和")


def check_cfo(cfg: dict) -> None:
    dout = load_matrix(DUMP / "cfo_out.log")
    i = dout[:, 0].astype(float)
    q = dout[:, 1].astype(float)
    n = len(i)
    amp = np.hypot(i, q) / (2.0 ** cfg["FRAC"])
    phase = np.unwrap(np.arctan2(q, i))
    m = np.arange(n)
    slope = float(np.polyfit(m, phase, 1)[0])
    expect = 2.0 * PI * cfg["CFO_FTW"] / (2.0 ** 32)

    add_check("cfo_phase_slope", abs(slope / expect - 1.0) < 1e-4,
              f"{slope:.12f}", f"{expect:.12f}", "rel 1e-4",
              f"归一化频偏 FTW/2^32={cfg['CFO_FTW'] / 2.0 ** 32:.9f} cycle/sample")

    amp_err = float(np.max(np.abs(amp - 1.0)))
    add_check("cfo_amplitude", amp_err < 3.0 / (2.0 ** cfg["FRAC"]),
              f"max|A-1|={amp_err:.6f}", "0", f"{3.0 / 2.0 ** cfg['FRAC']:.6f}")

    # 相位连续：逐拍相位增量应恒定
    steps = np.diff(phase)
    add_check("cfo_phase_continuity", float(steps.std()) < 1e-3,
              f"std(dphase)={float(steps.std()):.3e}", "<1e-3", "1e-3",
              "跳相或清零都会让逐拍相位增量出现离散跳变")


def check_sfo(cfg: dict) -> None:
    dout = load_matrix(DUMP / "sfo_out.log")
    y = dout[:, 0].astype(float)
    mu = dout[:, 2]
    m = np.arange(len(y), dtype=float)
    delta = cfg["SFO_PPM"] * 1e-6

    # 1) 时间基：μ_m 必须精确等于 frac(m·δ)
    dev = float(np.max(np.abs(mu - np.mod(m * delta, 1.0))))
    add_check("sfo_mu_drift", dev < 1e-9, f"max dev={dev:.3e}",
              f"μ_m = frac(m·{delta:g})", "1e-9",
              f"δ = {cfg['SFO_PPM']} ppm（精确依据：模型导出的 μ 序列）")

    # 2) 插值与量化确实用了 μ：输出应为 round(m + μ)，斜坡输入下
    exp_y = m + mu
    max_dev = float(np.max(np.abs(y - exp_y)))
    add_check("sfo_interp_uses_mu", max_dev <= 0.5001,
              f"max|y-(m+μ)|={max_dev:.6f}", "≤0.5001 code", "0.5001",
              "量子化台阶为 1 码，容差取半码")

    # 3) 滑码次数（外部一致性：与配置 ppm 的累计漂移交待）
    exp_slips = int(np.floor(m[-1] * delta))
    add_check("sfo_slip_count", abs(cfg["SFO_SLIPS"] - exp_slips) <= 1,
              cfg["SFO_SLIPS"], f"{exp_slips}±1", "1",
              "滑码 = μ 越过 1 的次数，随 ppm 线性增长")


def check_mp_impulse(cfg: dict) -> None:
    taps = load_matrix(DUMP / "mp_taps.log")
    dout = load_matrix(DUMP / "mp_impulse_out.log")
    scale = float(2 ** cfg["FRAC"])
    ntaps = int(cfg["NTAPS"])

    exp_i = np.round(taps[:, 1] * scale)
    exp_q = np.round(taps[:, 2] * scale)
    got_i = dout[:ntaps, 0].astype(float)
    got_q = dout[:ntaps, 1].astype(float)

    err = float(max(np.max(np.abs(got_i - exp_i)), np.max(np.abs(got_q - exp_q))))
    add_check("mp_impulse_response", err <= 1.0, f"max err={err:.3f} code", "0", "1 code",
              "冲激输入（+1.0）时的输出应等于抽头系数")

    tail = dout[ntaps:, :].astype(float)
    tail_ok = (np.max(np.abs(tail)) if tail.size else 0.0) <= 1.0
    add_check("mp_tail_zero", bool(tail_ok),
              f"max|tail|={float(np.max(np.abs(tail))) if tail.size else 0:.3f}", "0", "1 code",
              "抽头数之外的响应应为 0（延迟线长度足够）")

    p_sum = float(taps[:, 3].sum())
    add_check("mp_pdp_normalized", abs(p_sum - 1.0) < 1e-9, f"{p_sum:.12f}", "1", "1e-9",
              "功率延迟谱归一化：Σp_k = 1")


def _fade_matrix(path: Path, ntaps: int):
    raw = load_matrix(path)
    return raw[:, 0::2] + 1j * raw[:, 1::2]


def check_mp_fading(cfg: dict, filename: str, tag: str, k_db_expect: float) -> None:
    ntaps = int(cfg["NTAPS"])
    h = _fade_matrix(DUMP / filename, ntaps)
    n = h.shape[0]

    # 指数 PDP（与模型同一公式，参数来自配置 dump）
    k = np.arange(ntaps)
    pk = 10.0 ** (-k * cfg["PDP_DECAY_DB"] / 10.0)
    pk = pk / pk.sum()

    pow_meas = np.mean(np.abs(h) ** 2, axis=0)
    rel_err = float(np.max(np.abs(pow_meas / pk - 1.0)))
    add_check(f"mp_{tag}_pdp", rel_err < 0.03, f"max rel err={rel_err * 100:.2f}%",
              "各抽头 E|h_k|² = p_k", "3%", f"N={n} 组独立抽头")

    pow_total = float(np.mean(np.sum(np.abs(h) ** 2, axis=1)))
    add_check(f"mp_{tag}_power_conserved", abs(pow_total - 1.0) < 0.02,
              f"{pow_total:.6f}", "1.0", "2%", "Σ|h_k|² 的期望为 1")

    a0 = np.abs(h[:, 0])
    ratio = float(a0.mean() ** 2 / (a0 ** 2).mean())
    if k_db_expect <= PURE_RAYLEIGH_MAX_DB:
        add_check(f"mp_{tag}_amp_ratio", abs(ratio - PI / 4.0) < 0.015,
                  f"{ratio:.6f}", f"{PI / 4.0:.6f}", "0.015",
                  "瑞利幅度分布特征比 E[A]²/E[A²] = π/4")
    else:
        add_check(f"mp_{tag}_amp_ratio", ratio > PI / 4.0 + 0.01,
                  f"{ratio:.6f}", f">{PI / 4.0 + 0.01:.6f}", "—",
                  "莱斯分布下该比值高于 π/4")

    k_est = _estimate_k(h[:, 0])
    k_expect = 10.0 ** (k_db_expect / 10.0)
    k_est_db = 10.0 * math.log10(k_est) if k_est > 0 else -999.0
    if k_db_expect <= PURE_RAYLEIGH_MAX_DB:
        add_check(f"mp_{tag}_k_factor", k_est_db < -20.0,
                  f"{k_est_db:.2f} dB", "<-20 dB", "—", "纯瑞利：K→0")
    else:
        add_check(f"mp_{tag}_k_factor", abs(k_est_db - k_db_expect) < 0.5,
                  f"{k_est_db:.3f} dB", f"{k_db_expect:.3f} dB", "0.5 dB",
                  f"K_est = |E[h]|²/E|h-E[h]|²（线性 K={k_expect:.3f}）")


def _estimate_k(h: np.ndarray) -> float:
    """由复抽头样本估 K：K = |E[h]|² / E|h - E[h]|²"""
    mh = h.mean()
    resid = h - mh
    var = float(np.mean(np.abs(resid) ** 2))
    if var <= 0.0:
        return float("inf")
    return float(abs(mh) ** 2 / var)


def write_csv(cfg: dict) -> None:
    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_CSV, "w", encoding="utf-8", newline="\n") as f:
        w = csv.writer(f)
        w.writerow(["# S2 信道模型库统计核验 · check_channel_stats.py 生成，勿手改"])
        w.writerow(["# 场景参数来自 sim/models/channel/dump/channel_config.log"])
        w.writerow([f"# Eb/N0={cfg['EB_N0_DB']} dB  定点={int(cfg['W'])}/{int(cfg['FRAC'])}  "
                    f"抽头={int(cfg['NTAPS'])}  PDP={cfg['PDP_DECAY_DB']} dB/抽头  "
                    f"CFO={cfg['CFO_FTW'] / 2.0 ** 32:g} cycle/sample  SFO={int(cfg['SFO_PPM'])} ppm"])
        w.writerow(["check", "status", "measured", "expected", "tolerance", "note"])
        for r in RESULTS:
            w.writerow([r["check"], r["status"], r["measured"], r["expected"], r["tolerance"], r["note"]])


def main() -> int:
    if not (DUMP / "channel_config.log").exists():
        print(f"[CH] 缺少 {DUMP/'channel_config.log'}，先跑 run_channel_check.ps1", file=sys.stderr)
        return 2

    cfg = load_config()

    # TB 侧报告的滑码次数由 run_channel_check.ps1 写进 config（此处兜底）
    cfg.setdefault("SFO_SLIPS", -1)

    check_identity(cfg)
    check_awgn(cfg)
    check_cfo(cfg)
    check_sfo(cfg)
    check_mp_impulse(cfg)
    check_mp_fading(cfg, "mp_fade_rayleigh.log", "rayleigh", cfg["MP_PURE_RAY_DB_X10"] / 10.0)
    check_mp_fading(cfg, "mp_fade_rician.log", "rician", cfg["K_RICIAN_DB"])

    write_csv(cfg)

    failed = [r for r in RESULTS if r["status"] == "FAIL"]
    print()
    print("==================== S2 信道统计核验 ====================")
    for r in RESULTS:
        print(f"  [{r['status']}] {r['check']:<28} measured={r['measured']:<24} "
              f"expected={r['expected']}")
    print("=========================================================")
    print(f"  明细表：{OUT_CSV}")
    if failed:
        print(f"  [CHANNEL STATS] FAIL ({len(failed)}/{len(RESULTS)} 项未达预期)")
        return 1
    print(f"  [CHANNEL STATS] PASS ({len(RESULTS)} 项全部达预期)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
