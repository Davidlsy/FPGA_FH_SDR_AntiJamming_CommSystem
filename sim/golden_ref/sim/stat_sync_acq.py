"""S6 同步字捕获统计判据（docs/spec/s6_fh_interface.md §8.5 第 3 条，任务卡原文）:

- **虚警 Pfa ≤ 1e-6/帧**：判据由解析上界证明——门限下限 T=52 使单窗命中率
  p_w ≤ P(Bin(64, ½) ≥ 52) 无条件成立（不依赖 noise_est 分布）：
  候选开启率 ≤ 2160·p_w/帧、开候选后 2 个后续槽误确认 ≤ 2·p_w
  → Pfa/帧 ≤ 4320·p_w²（联合界）；MC 做两件校核：纯噪声流窗口超限率与精确
  二项尾一致（分块 t 检验，容忍重叠窗相关）、实际检测器长噪声流零误声明；
- **检测概率 Pd ≥ 99%**（Eb/N0 ≥ 0 dB）：MC 扫 SNR 曲线，SNR 口径 = 捕获输入
  比特流 Eb/N0（BPSK 硬判决映射 BER = Q(√(2·Eb/N0))），同时出 BER 轴。

产物 data/s6_sync_acq/（Pd/Pfa 曲线 + SNR 表 + 报告）。

用法:
    python sim/golden_ref/sim/stat_sync_acq.py             # 全量
    python sim/golden_ref/sim/stat_sync_acq.py --quick     # 冒烟（少窗少试）
"""
from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from golden_ref.fixed_point.sync_acq import (  # noqa: E402
    FRAME_LEN_DEFAULT,
    M_HIT_DEFAULT,
    N_SLOT_DEFAULT,
    SYNC_W,
    SYNC_WORD,
    THRESH_MIN,
    sim_sync_acq,
)

_REPO_ROOT = Path(__file__).resolve().parents[3]
_DEFAULT_OUT = _REPO_ROOT / "data" / "s6_sync_acq"

PFA_CRIT = 1e-6          # 任务卡：虚警 ≤ 1e-6/帧
PD_CRIT = 0.99           # 任务卡：0 dB 检测概率 ≥ 99%
PD_CRIT_EBN0 = 0.0
N_FRAMES_TRIAL = 4       # 捕获判定窗：≤ 3 帧延迟（候选 + N=3 槽）须 4 帧可见


# ---------------------------------------------------------------- 基础
def binom_tail(n: int, k_min: int, p: float) -> float:
    return sum(math.comb(n, k) * p**k * (1 - p) ** (n - k) for k in range(k_min, n + 1))


def ber_bpsk(ebn0_db):
    """BPSK 硬判决映射 BER = Q(√(2·Eb/N0)) = ½·erfc(√γ)。标量/数组皆可（次轴用）。"""
    from scipy.special import erfc

    x = np.asarray(ebn0_db, dtype=float)
    out = 0.5 * erfc(np.sqrt(10.0 ** (x / 10.0)))
    return float(out) if np.ndim(ebn0_db) == 0 else out


def ber_to_ebn0(ber):
    """ber_bpsk 的反函数（次轴刻度用）。"""
    from scipy.special import erfcinv

    b = np.clip(np.asarray(ber, dtype=float), 1e-300, 1.0)
    gamma = erfcinv(2.0 * b) ** 2
    out = 10.0 * np.log10(gamma)
    return float(out) if np.ndim(ber) == 0 else out


def wilson_ci(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return 0.0, 1.0
    p = k / n
    den = 1.0 + z * z / n
    center = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return max(0.0, center - half), min(1.0, center + half)


def _sync_bits() -> np.ndarray:
    return np.array([(SYNC_WORD >> (SYNC_W - 1 - i)) & 1 for i in range(SYNC_W)],
                    dtype=np.uint8)


# ---------------------------------------------------------------- Pfa
def pfa_bound(thresh_min: int = THRESH_MIN) -> dict:
    """解析联合界：Pfa/帧 ≤ (2160·p_w) × (2·p_w)（开候选 × 后续 2 槽误确认）。"""
    p_w = binom_tail(SYNC_W, thresh_min, 0.5)
    open_rate = FRAME_LEN_DEFAULT * p_w          # 候选开启率/帧（含真峰拍，上界不区分）
    confirm = (N_SLOT_DEFAULT - 1) * p_w         # 开候选后后续槽误确认概率
    return {
        "thresh_min": thresh_min,
        "p_w": p_w,
        "open_rate_per_frame": open_rate,
        "confirm_prob": confirm,
        "pfa_per_frame": open_rate * confirm,
    }


def mc_noise_windows(n_windows: int, n_blocks: int = 40, seed: int = 20261009) -> dict:
    """纯噪声流窗口超限率 MC（校核 p_w 模型）。

    真流滑窗（相邻窗重叠 63 bit）；块率做 t 检验容忍重叠窗相关——
    块长 ≫ 相关长度 64，块间独立。
    """
    rng = np.random.default_rng(seed)
    sync = _sync_bits()
    assert n_windows % n_blocks == 0, "n_windows 必须被 n_blocks 整除"
    chunk = n_windows // n_blocks
    k_block = np.zeros(n_blocks, dtype=np.int64)
    for b in range(n_blocks):
        stream = rng.integers(0, 2, size=chunk + SYNC_W - 1, dtype=np.uint8)
        win = np.lib.stride_tricks.sliding_window_view(stream, SYNC_W)
        corr = (win == sync).sum(axis=1)
        k_block[b] = int((corr >= THRESH_MIN).sum())
    rate_block = k_block / chunk
    p_w = binom_tail(SYNC_W, THRESH_MIN, 0.5)
    se = float(np.std(rate_block, ddof=1) / math.sqrt(n_blocks))
    t_stat = (float(np.mean(rate_block)) - p_w) / se if se > 0 else 0.0
    return {
        "n_windows": n_windows,
        "n_blocks": n_blocks,
        "n_exceed": int(k_block.sum()),
        "rate": float(np.mean(rate_block)),
        "p_w_exact": p_w,
        "z_expect": float(n_windows * p_w),
        "se": se,
        "t_stat": t_stat,
        "consistent": abs(t_stat) <= 4.0,
    }


def mc_noise_detector(n_beats: int, seed: int = 20261009) -> dict:
    """实际黄金检测器灌纯噪声：统计 hit / 误 acq（Pfa 判据本体由解析上界证明）。"""
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, size=n_beats, dtype=np.uint8)
    out = sim_sync_acq([(1, int(b)) for b in bits], frame_len=FRAME_LEN_DEFAULT,
                       m_hit=M_HIT_DEFAULT, n_slot=N_SLOT_DEFAULT)
    hits = sum(o[0] for o in out)
    acqs = sum(o[1] for o in out)
    return {"n_beats": n_beats, "hits": hits, "false_acq": acqs,
            "hit_rate": hits / n_beats, "p_w_exact": binom_tail(SYNC_W, THRESH_MIN, 0.5)}


# ---------------------------------------------------------------- Pd
def pd_trial(ebn0_db: float, rng: np.random.Generator,
             frame_len: int = FRAME_LEN_DEFAULT) -> tuple[bool, int]:
    """单次试验：4 帧（64 bit 同步字 + 载荷），BPSK 硬判决翻转后进黄金检测器。

    返回 (是否捕获, acq 拍号)。捕获事件 = 试验内 acq 声明（噪声 Pfa ~ 1e-10，
    误 acq 可忽略 ⇒ 即真检测）。
    """
    ber = ber_bpsk(ebn0_db)
    n_bits = N_FRAMES_TRIAL * frame_len
    bits = rng.integers(0, 2, size=n_bits, dtype=np.uint8)
    sync = _sync_bits()
    for f in range(N_FRAMES_TRIAL):
        bits[f * frame_len: f * frame_len + SYNC_W] = sync
    flips = rng.random(n_bits) < ber
    bits ^= flips.astype(np.uint8)
    out = sim_sync_acq([(1, int(b)) for b in bits], frame_len=frame_len,
                       m_hit=M_HIT_DEFAULT, n_slot=N_SLOT_DEFAULT)
    for i, (hit, acq, fs, corr, thresh) in enumerate(out):
        if acq:
            return True, i
    return False, -1


def mc_pd_sweep(points: list[float], n_trials: int, seed: int = 20261009) -> list[dict]:
    rng = np.random.default_rng(seed)
    records = []
    for ebn0 in points:
        ok = 0
        lat = []
        for _ in range(n_trials):
            got, at = pd_trial(ebn0, rng)
            if got:
                ok += 1
                lat.append(at)
        lo, hi = wilson_ci(ok, n_trials)
        records.append({
            "ebn0_db": ebn0,
            "ber": ber_bpsk(ebn0),
            "n_trials": n_trials,
            "detected": ok,
            "pd": ok / n_trials,
            "ci_lo": lo,
            "ci_hi": hi,
            "lat_med": int(np.median(lat)) if lat else -1,
        })
    return records


# ---------------------------------------------------------------- 产物
def plot_pd(records: list[dict], out_png: Path) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams["font.sans-serif"] = [
        "Microsoft YaHei", "SimHei", "NSimSun", "SimSun", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False

    ebn0 = [r["ebn0_db"] for r in records]
    pd_v = [r["pd"] for r in records]
    lo = [r["ci_lo"] for r in records]

    fig, ax = plt.subplots(figsize=(8, 6))
    ax.plot(ebn0, pd_v, "bo-", label="MC 实测 Pd（黄金检测器，4 帧捕获窗）",
            linewidth=2, markersize=6)
    ax.plot(ebn0, lo, "b^:", label="Pd 95% Wilson 下界", linewidth=1.2,
            markersize=5, markerfacecolor="none")
    ax.axhline(PD_CRIT, color="r", ls="--", label=f"判据 Pd ≥ {PD_CRIT:.2f} @ 0 dB")
    ax.axvline(PD_CRIT_EBN0, color="r", ls=":", linewidth=1)

    ax2 = ax.secondary_xaxis("top", functions=(ber_bpsk, ber_to_ebn0))
    ax2.set_xlabel("输入比特流 BER = Q(√(2·Eb/N0))", fontsize=11)

    ax.set_xlabel("Eb/N0 (dB)（捕获输入比特流口径）", fontsize=12)
    ax.set_ylabel("检测概率 Pd", fontsize=12)
    ax.set_title("S6 sync_acq 检测概率 vs SNR\n"
                 "64 bit Gold 滑动相关 + 恒虚警 max(52, est×13/8) + M/N=2/3 帧槽确认",
                 fontsize=13)
    ax.set_ylim([-0.02, 1.05])
    ax.grid(True, ls="--", alpha=0.6)
    ax.legend(fontsize=9, loc="lower right")
    fig.savefig(out_png, dpi=150, bbox_inches="tight")
    plt.close(fig)


def plot_pfa(out_png: Path) -> list[dict]:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams["font.sans-serif"] = [
        "Microsoft YaHei", "SimHei", "NSimSun", "SimSun", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False

    rows = [pfa_bound(t) for t in range(50, 61)]
    fig, ax = plt.subplots(figsize=(8, 6))
    ax.semilogy([r["thresh_min"] for r in rows],
                [r["pfa_per_frame"] for r in rows], "ro-",
                label="解析联合界 Pfa/帧 = 2160·p_w × 2·p_w", linewidth=2, markersize=6)
    ax.axhline(PFA_CRIT, color="r", ls="--", label=f"判据 Pfa ≤ {PFA_CRIT:.0e}/帧")
    ax.axvline(THRESH_MIN, color="g", ls=":", label=f"冻结下限 T={THRESH_MIN}")
    ax.set_xlabel("门限下限 THRESH_MIN", fontsize=12)
    ax.set_ylabel("Pfa / 帧（上界）", fontsize=12)
    ax.set_title("S6 sync_acq 虚警上界 vs 门限下限\n"
                 "p_w ≤ P(Bin(64,½) ≥ T) 无条件成立（不依赖 noise_est 分布）", fontsize=13)
    ax.grid(True, which="both", ls="--", alpha=0.6)
    ax.legend(fontsize=9)
    fig.savefig(out_png, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return rows


def export_csv(records: list[dict], pfa_rows: list[dict], mc_win: dict,
               mc_det: dict, out_csv: Path) -> None:
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["# S6 sync_acq 统计判据（docs/spec/s6_fh_interface.md §8.5 第 3 条）"])
        w.writerow(["# 1) Pd 扫 SNR（MC，捕获输入比特流 Eb/N0 / BPSK 硬判决映射）"])
        w.writerow(["ebn0_db", "ber", "n_trials", "detected", "pd",
                    "ci_lo_95", "ci_hi_95", "lat_med_beats", "verdict"])
        for r in records:
            verdict = "-"
            if r["ebn0_db"] == PD_CRIT_EBN0:
                verdict = "通过" if r["ci_lo"] >= PD_CRIT else (
                    "通过(点估计)" if r["pd"] >= PD_CRIT else "未通过")
            w.writerow([f"{r['ebn0_db']:.1f}", f"{r['ber']:.4e}", r["n_trials"],
                        r["detected"], f"{r['pd']:.4f}", f"{r['ci_lo']:.4f}",
                        f"{r['ci_hi']:.4f}", r["lat_med"], verdict])
        w.writerow([])
        w.writerow(["# 2) Pfa 解析联合界 vs 门限下限（判据 = 1e-6/帧）"])
        w.writerow(["thresh_min", "p_w_exact", "open_rate_per_frame",
                    "confirm_prob", "pfa_per_frame", "margin_vs_1e-6"])
        for r in pfa_rows:
            w.writerow([r["thresh_min"], f"{r['p_w']:.4e}",
                        f"{r['open_rate_per_frame']:.4e}",
                        f"{r['confirm_prob']:.4e}", f"{r['pfa_per_frame']:.4e}",
                        f"{PFA_CRIT / r['pfa_per_frame']:.1f}"])
        w.writerow([])
        w.writerow(["# 3) 纯噪声流 MC 校核（p_w 模型 + 检测器零误声明）"])
        w.writerow(["n_windows", "n_exceed", "rate", "p_w_exact", "z_expect",
                    "t_stat", "consistent", "n_beats", "hits", "false_acq"])
        w.writerow([mc_win["n_windows"], mc_win["n_exceed"], f"{mc_win['rate']:.4e}",
                    f"{mc_win['p_w_exact']:.4e}", f"{mc_win['z_expect']:.2f}",
                    f"{mc_win['t_stat']:.2f}", mc_win["consistent"],
                    mc_det["n_beats"], mc_det["hits"], mc_det["false_acq"]])


def write_report(records: list[dict], pfa: dict, mc_win: dict, mc_det: dict,
                 out_md: Path) -> None:
    r0 = next(r for r in records if r["ebn0_db"] == PD_CRIT_EBN0)
    pd_ok = r0["pd"] >= PD_CRIT
    pfa_ok = pfa["pfa_per_frame"] <= PFA_CRIT
    margin = PFA_CRIT / pfa["pfa_per_frame"]
    lines = [
        "# S6 `sync_acq` 统计判据报告",
        "",
        "口径：`docs/spec/s6_fh_interface.md` §8.5 第 3 条（任务卡原文：检测概率 ≥ 99%、",
        "虚警 ≤ 1e-6 的 SNR 曲线，挂 `viterbi_dec` 输出解码比特流——决策 #15 比特域捕获）。",
        "",
        "## 判据",
        "",
        "| 判据 | 要求 | 实测/证明 | 结论 |",
        "|---|---|---|---|",
        f"| 虚警 Pfa | ≤ {PFA_CRIT:.0e}/帧 | 解析联合界 {pfa['pfa_per_frame']:.2e}/帧（裕量 {margin:.0f}×） | {'通过' if pfa_ok else '未通过'} |",
        f"| 检测概率 Pd @ 0 dB | ≥ {PD_CRIT:.2f} | MC {r0['pd']:.4f}（{r0['detected']}/{r0['n_trials']}，95% 下界 {r0['ci_lo']:.4f}） | {'通过' if pd_ok else '未通过'} |",
        f"| p_w 模型校核 | 纯噪声 MC 与精确二项尾一致 | t={mc_win['t_stat']:.2f}（|t|≤4） | {'通过' if mc_win['consistent'] else '未通过'} |",
        f"| 检测器噪声段 | 零误声明 | {mc_det['n_beats']} 拍 hit={mc_det['hits']} acq={mc_det['false_acq']} | {'通过' if mc_det['false_acq'] == 0 else '未通过'} |",
        "",
        "## Pfa 解析上界（判据本体）",
        "",
        f"- 单窗命中率 `p_w ≤ P(Bin(64,½) ≥ {THRESH_MIN}) = {pfa['p_w']:.3e}`，门限下限使该界",
        "  **无条件**成立（`thresh ≥ THRESH_MIN`，不依赖 `noise_est` 分布）；",
        f"- 候选开启率 ≤ `2160×p_w = {pfa['open_rate_per_frame']:.2e}`/帧；",
        f"- 开候选后 2 个后续槽误确认 ≤ `2×p_w = {pfa['confirm_prob']:.2e}`（联合界相乘）；",
        f"- **Pfa/帧 ≤ {pfa['pfa_per_frame']:.2e}**，判据 1e-6，裕量 ≈ {margin:.0f}×。",
        "",
        "## Pd 扫 SNR（MC，BPSK 硬判决映射）",
        "",
        "| Eb/N0 (dB) | BER | Pd | 95% CI | 中位延迟 (拍) |",
        "|---|---|---|---|---|",
    ]
    for r in records:
        lines.append(f"| {r['ebn0_db']:.1f} | {r['ber']:.3e} | {r['pd']:.4f} "
                     f"| [{r['ci_lo']:.4f}, {r['ci_hi']:.4f}] | {r['lat_med']} |")
    lines += [
        "",
        "曲线：`pd_vs_ebn0.png`（含 BER 次轴）、`pfa_bound_vs_thresh.png`。",
        "",
        "## 备注",
        "",
        "- SNR 口径 = 捕获输入比特流 Eb/N0（§8.6 #3）；端到端映射归 S5 Viterbi BER 曲线，",
        "  在 S5 实测译码 BER（≤1.7e-4 @ 0 dB）下捕获检测概率 ≈ 1，本曲线刻画检测器抗噪边界。",
        "- 捕获事件 = 试验内 `acq` 声明（4 帧窗 = 候选 + N=3 槽 ≤ 3 帧延迟）；噪声 Pfa ~ 1e-10，",
        "  误 acq 不污染 MC 计数。",
    ]
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------- main
def parse_args():
    p = argparse.ArgumentParser(description="S6 sync_acq 统计判据（Pd/Pfa）")
    p.add_argument("--quick", action="store_true", help="冒烟（少窗少试）")
    p.add_argument("--trials", type=int, default=500, help="每 SNR 点 MC 试验数")
    p.add_argument("--windows", type=int, default=50_000_000,
                   help="纯噪声 MC 窗口数（须被 40 整除）")
    p.add_argument("--noise-beats", type=int, default=2_000_000,
                   help="检测器噪声段拍数")
    p.add_argument("--points", type=str, default="-4,-3,-2.5,-2,-1.5,-1,0,1")
    p.add_argument("--seed", type=int, default=20261009)
    p.add_argument("--output-dir", type=str, default=str(_DEFAULT_OUT))
    return p.parse_args()


def main() -> int:
    args = parse_args()
    trials = 60 if args.quick else args.trials
    windows = 400_000 if args.quick else args.windows
    noise_beats = 200_000 if args.quick else args.noise_beats
    points = [float(x) for x in args.points.split(",")]
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print("S6 sync_acq 统计判据（Pd/Pfa）")
    print("=" * 66)

    print(f"[1] Pfa 解析联合界（门限下限 T={THRESH_MIN}）")
    pfa = pfa_bound()
    print(f"    p_w = P(Bin(64,1/2)>={THRESH_MIN}) = {pfa['p_w']:.4e}")
    print(f"    候选开启 ≤ {pfa['open_rate_per_frame']:.3e}/帧, 误确认 ≤ {pfa['confirm_prob']:.3e}")
    pfa_ok = pfa["pfa_per_frame"] <= PFA_CRIT
    print(f"    Pfa/帧 ≤ {pfa['pfa_per_frame']:.3e}  判据 {PFA_CRIT:.0e}  "
          f"裕量 {PFA_CRIT / pfa['pfa_per_frame']:.0f}x  "
          f"{'PASS' if pfa_ok else 'FAIL'}")

    print(f"[2] 纯噪声流 MC 校核 p_w 模型（{windows} 窗）")
    mc_win = mc_noise_windows(windows, seed=args.seed)
    print(f"    趮限 {mc_win['n_exceed']} 次, 实测率 {mc_win['rate']:.4e}, "
          f"精确二项尾 {mc_win['p_w_exact']:.4e}, 期望 {mc_win['z_expect']:.1f}")
    print(f"    t = {mc_win['t_stat']:.2f}  "
          f"{'PASS' if mc_win['consistent'] else 'FAIL'}")

    print(f"[3] 检测器噪声段（{noise_beats} 拍）")
    mc_det = mc_noise_detector(noise_beats, seed=args.seed + 1)
    det_ok = mc_det["false_acq"] == 0
    print(f"    hit={mc_det['hits']} (率 {mc_det['hit_rate']:.3e}), "
          f"误 acq={mc_det['false_acq']}  {'PASS' if det_ok else 'FAIL'}")

    print(f"[4] Pd 扫 SNR（{len(points)} 点 x {trials} 试验）")
    records = mc_pd_sweep(points, trials, seed=args.seed + 2)
    for r in records:
        mark = ""
        if r["ebn0_db"] == PD_CRIT_EBN0:
            mark = "  <-- 判据点"
        print(f"    Eb/N0={r['ebn0_db']:5.1f} dB  BER={r['ber']:.3e}  "
              f"Pd={r['pd']:.4f}  CI=[{r['ci_lo']:.4f},{r['ci_hi']:.4f}]{mark}")
    r0 = next(r for r in records if r["ebn0_db"] == PD_CRIT_EBN0)
    pd_ok = r0["pd"] >= PD_CRIT
    print(f"    Pd(0 dB) = {r0['pd']:.4f}  判据 ≥ {PD_CRIT}  "
          f"{'PASS' if pd_ok else 'FAIL'}")

    print("[5] 产物导出 data/s6_sync_acq/")
    pfa_rows = plot_pfa(out_dir / "pfa_bound_vs_thresh.png")
    plot_pd(records, out_dir / "pd_vs_ebn0.png")
    export_csv(records, pfa_rows, mc_win, mc_det, out_dir / "snr_table.csv")
    np.savez(out_dir / "stat_sync_acq.npz",
             pd_ebn0=np.array([r["ebn0_db"] for r in records]),
             pd_value=np.array([r["pd"] for r in records]),
             pd_ci_lo=np.array([r["ci_lo"] for r in records]),
             pd_ber=np.array([r["ber"] for r in records]),
             pfa_thresh=np.array([r["thresh_min"] for r in pfa_rows]),
             pfa_bound=np.array([r["pfa_per_frame"] for r in pfa_rows]))
    write_report(records, pfa, mc_win, mc_det, out_dir / "report.md")

    ok = pfa_ok and pd_ok and mc_win["consistent"] and det_ok
    print(f"[STAT-SYNC-ACQ] pfa_bound={pfa['pfa_per_frame']:.2e} "
          f"pd_0dB={r0['pd']:.4f} status={'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
