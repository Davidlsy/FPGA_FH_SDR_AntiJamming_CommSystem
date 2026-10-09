"""S5 viterbi_dec BER 三路同序列对比（浮点参考 / 硬件忠实 RTL 语义 / MATLAB vitdec）

判据（docs/spec/s5_rx_interface.md §4.4）：
  1. 与浮点参考 `viterbi_decode` BER 差 ≤0.5 dB（目标 BER 处 SNR 损失）；
  2. BER 与 MATLAB `vitdec` **同序列**叠图；
  3. 高 SNR 无误码平底。

三路拿到**同一条**量化后软序列（即 RTL 输入口的真实序列）：
    z = 1 − 2·bit（bit0 → 正，与 sync_rx 软解调同向）
    soft = z + N(0, σ²)，σ² = 1/γb（γb = Eb/N0；Ec=1/编码比特、R=1/2 → Eb=2）
    Q3.5 格点化 round(soft·32)/32 + ±127/32 饱和（viterbi_metric_w=8 / frac=5）
差异只来自译码器实现本身：
    浮点参考      viterbi_decode   —— float PM + 全回溯（归零帧）
    硬件忠实      fixed_viterbi_hw —— Q3.5 整数 PM + 16 bit 饱和 + 滑窗 96（= RTL 语义）
    MATLAB 交叉   vitdec(tblen=96, 'trunc', 'unquant') —— 与 RTL 同为滑窗截断模式
交织与脉冲成形不在此级：交织是 i.i.d. 信道下的比特置换，不改 BER；链路级效应由
S1 基线（data/s1_ber_baseline）覆盖。绝对 Eb/N0 口径用教科书卷积码约定，
曲线瀑布点应落在 1e-5 ≈ 4.3~4.6 dB（与设计报告「编码 1e-5 约 4.6 dB」锚点互证）。
"""
from __future__ import annotations

import numpy as np

from ..config import (
    CONV_TAIL_BITS,
    FIXED_POINT_CONFIG,
    FRAME_TOTAL_BITS,
    RX_CONFIG,
)
from ..fixed_point.rx_modules import fixed_viterbi_hw
from ..float_chain.conv_encoder import conv_encode
from ..float_chain.viterbi import viterbi_decode
from .snr_loss import snr_loss_analysis

INFO_LEN = FRAME_TOTAL_BITS                  # 2160 信息比特/帧（conv 输入）
CODED_LEN = 2 * (INFO_LEN + CONV_TAIL_BITS)  # 4332 编码比特/帧（含 6 尾比特）
WIN_TB = RX_CONFIG["viterbi_win_tb"]         # 滑窗回溯 96（= RTL TB_DEPTH）
METRIC_FRAC = FIXED_POINT_CONFIG["viterbi_metric_frac"]   # Q3.5
SOFT_LO = -(1 << (FIXED_POINT_CONFIG["viterbi_metric_w"] - 1)) + 1   # −127
SOFT_HI = (1 << (FIXED_POINT_CONFIG["viterbi_metric_w"] - 1)) - 1    # +127


# ============================================================
# 帧生成：一条量化软序列，三路共用
# ============================================================
def make_soft_frame(rng: np.random.Generator, ebn0_db: float,
                    info_len: int = INFO_LEN):
    """一帧 (info_bits, soft_q)。

    soft_q 是 Q3.5 格点上的浮点值（k/32）；fixed_viterbi_hw 内部 ×32 取整
    是无损还原，MATLAB 侧按同一批实数喂 vitdec——三路严格同序列。
    """
    info = rng.integers(0, 2, info_len).astype(np.int8)
    coded = conv_encode(info)                            # 2*(info_len+6)
    gamma = 10.0 ** (ebn0_db / 10.0)
    sigma = 1.0 / np.sqrt(gamma)                         # σ² = N0/2 = 1/γb
    z = 1.0 - 2.0 * coded.astype(np.float64)             # bit0 → +1
    soft = z + rng.normal(0.0, sigma, len(z))
    soft_q = np.clip(np.round(soft * (1 << METRIC_FRAC)), SOFT_LO, SOFT_HI)
    soft_q = soft_q / (1 << METRIC_FRAC)
    return info, soft_q


# ============================================================
# 单点仿真（自适应停：两路各攒够误码 / 到比特上限 / 到帧上限）
# ============================================================
def simulate_point(ebn0_db: float, *, max_frames: int, min_error_bits: int,
                   max_bits: int, rng: np.random.Generator):
    """返回该 Eb/N0 点的误码统计 + MATLAB 所需的逐帧软序列。"""
    n_bits = n_err_f = n_err_x = 0
    only_f = only_x = 0                      # 配对分歧：只有一路错的比特数
    soft_frames, info_frames = [], []

    while (min(n_err_f, n_err_x) < min_error_bits
           and n_bits < max_bits and len(soft_frames) < max_frames):
        info, soft_q = make_soft_frame(rng, ebn0_db)
        dec_f = viterbi_decode(soft_q)                       # 浮点参考（全回溯）
        dec_x = fixed_viterbi_hw(soft_q, win_tb=WIN_TB)      # 硬件忠实（RTL 语义）

        wf = dec_f != info
        wx = dec_x != info
        n_err_f += int(np.sum(wf))
        n_err_x += int(np.sum(wx))
        only_f += int(np.sum(wf & ~wx))
        only_x += int(np.sum(wx & ~wf))
        n_bits += len(info)

        soft_frames.append(soft_q)
        info_frames.append(info)

    return {
        "ebn0_db": float(ebn0_db),
        "n_bits": n_bits,
        "n_frames": len(soft_frames),
        "err_float": n_err_f,
        "err_fixed": n_err_x,
        "only_float": only_f,
        "only_fixed": only_x,
        "soft_frames": soft_frames,
        "info_frames": info_frames,
    }


def run_sweep(eb_n0_range, *, seed: int = 20261009, max_frames: int = 400,
              min_error_bits: int = 50, max_bits: int = 600_000,
              log=print):
    """全扫点。逐点用独立种子派生（点间可复现，互不串扰）。"""
    records = []
    for idx, ebn0 in enumerate(eb_n0_range):
        rng = np.random.default_rng(seed + 1000 * idx)
        rec = simulate_point(float(ebn0), max_frames=max_frames,
                             min_error_bits=min_error_bits,
                             max_bits=max_bits, rng=rng)
        records.append(rec)
        log(f"[{idx + 1}/{len(eb_n0_range)}] Eb/N0 = {ebn0:4.1f} dB | "
            f"{rec['n_frames']:4d} 帧 {rec['n_bits']:7d} bit | "
            f"float {rec['err_float']:6d}  fixed {rec['err_fixed']:6d}")
    return records


# ============================================================
# 判据
# ============================================================
def loss_analysis(records):
    """fixed vs float 的目标 BER 处 SNR 损失（≤0.5 dB 判据）。"""
    ebn0 = np.array([r["ebn0_db"] for r in records])
    ber_f = np.array([r["err_float"] / r["n_bits"] for r in records])
    ber_x = np.array([r["err_fixed"] / r["n_bits"] for r in records])
    losses, ratio = snr_loss_analysis(ber_f, ber_x, ebn0)
    return losses, ratio


def floor_check(records, ratio):
    """高 SNR 平底检查。

    判平底的签名：fixed 曲线在高 SNR 段停止下降（非递增劣化）而 float 仍在降，
    或 fixed/float 误码比在相邻两点持续 >3。零误码点给 95% 上界 3/N 参与观察。
    """
    n = len(records)
    hi = records[max(0, n - 3):]           # 最高 3 点
    details, floor = [], False
    for r, rt in zip(hi, ratio[-len(hi):]):
        ber_x = r["err_fixed"] / r["n_bits"]
        bound = 3.0 / r["n_bits"] if r["err_fixed"] == 0 else None
        details.append({
            "ebn0_db": r["ebn0_db"], "err_fixed": r["err_fixed"],
            "n_bits": r["n_bits"], "ber_fixed": ber_x,
            "ber_fixed_95ub": bound, "ratio": float(rt),
        })
    bers = [d["ber_fixed"] for d in details]
    for a, b in zip(bers, bers[1:]):
        if b > a:                          # 高 SNR 处误码回升 = 平底签名
            floor = True
    rats = [d["ratio"] for d in details if d["err_fixed"] > 0]
    if len(rats) >= 2 and all(r > 3.0 for r in rats[-2:]):
        floor = True
    return {"floor": floor, "points": details}


# ============================================================
# MATLAB vitdec 桥（同序列 .mat 交换）
# ============================================================
def save_vitdec_input(records, io_dir):
    """导出逐点逐帧软序列 → vitdec_in.mat（cell 数组，MATLAB 直接 load）。"""
    from scipy.io import savemat
    from pathlib import Path

    io = Path(io_dir)
    io.mkdir(parents=True, exist_ok=True)
    soft = np.empty((len(records), 1), dtype=object)
    info = np.empty((len(records), 1), dtype=object)
    for p, r in enumerate(records):
        soft[p, 0] = np.stack(r["soft_frames"], axis=1)   # 4332 × nf（同序列）
        info[p, 0] = np.stack(r["info_frames"], axis=1)   # 2160 × nf
    savemat(io / "vitdec_in.mat", {
        "soft": soft, "info": info,
        "ebn0_db": np.array([r["ebn0_db"] for r in records]),
    }, do_compression=True)
    return io / "vitdec_in.mat"


def load_vitdec_output(io_dir):
    from scipy.io import loadmat
    from pathlib import Path

    d = loadmat(Path(io_dir) / "vitdec_out.mat")
    return (np.asarray(d["n_err"]).ravel().astype(np.int64),
            np.asarray(d["n_bits"]).ravel().astype(np.int64))


# ============================================================
# 自检（跑扫点前的口径冒烟）
# ============================================================
def self_check():
    """无噪帧三路一致 + 长度账本 + Q3.5 格点闭合。"""
    rng = np.random.default_rng(7)
    info = rng.integers(0, 2, INFO_LEN).astype(np.int8)
    coded = conv_encode(info)
    assert len(coded) == CODED_LEN == 4332, f"长度账本 {len(coded)}"
    soft_q = np.where(coded == 0, 3.5, -3.5)             # 无噪理想软值
    dec_f = viterbi_decode(soft_q)
    dec_x = fixed_viterbi_hw(soft_q, win_tb=WIN_TB)
    assert np.array_equal(dec_f, info), "浮点参考无噪译码错"
    assert np.array_equal(dec_x, info), "硬件忠实无噪译码错"
    _, sq = make_soft_frame(rng, 6.0)
    grid = sq * (1 << METRIC_FRAC)
    assert np.allclose(grid, np.round(grid)), "软值不在 Q3.5 格点"
    assert np.all(np.abs(grid) <= SOFT_HI), "软值超出饱和范围"
    return True


# ============================================================
# 出图 / 导表
# ============================================================
def plot_three(records, ber_matlab, out_png):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams["font.sans-serif"] = [
        "Microsoft YaHei", "SimHei", "NSimSun", "SimSun", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False

    ebn0 = [r["ebn0_db"] for r in records]
    ber_f = [r["err_float"] / r["n_bits"] for r in records]
    ber_x = [r["err_fixed"] / r["n_bits"] for r in records]
    ber_m = [e / b if b > 0 else np.nan for e, b in zip(ber_matlab[0], ber_matlab[1])]

    fig, ax = plt.subplots(figsize=(8, 6))
    ax.semilogy(ebn0, ber_f, "bo-", label="浮点参考 viterbi_decode（全回溯）",
                linewidth=2, markersize=6)
    ax.semilogy(ebn0, ber_x, "rs--",
                label=f"硬件忠实 fixed_viterbi_hw（Q3.5/16bit PM/滑窗 {WIN_TB}，RTL 语义）",
                linewidth=2, markersize=6)
    ax.semilogy(ebn0, ber_m, "g^:",
                label=f"MATLAB vitdec（trunc, tblen={WIN_TB}, unquant）",
                linewidth=2, markersize=6)
    for r in records:                        # 零误码点标 95% 上界
        if r["err_fixed"] == 0 and r["n_bits"] > 0:
            ax.semilogy([r["ebn0_db"]], [3.0 / r["n_bits"]], "rv",
                        markersize=9, markerfacecolor="none")
    ax.set_xlabel("Eb/N0 (dB)", fontsize=12)
    ax.set_ylabel("BER", fontsize=12)
    ax.set_title("S5 viterbi_dec BER 三路同序列对比\n"
                 "卷积码 (171,133) K=7 R=1/2 / 2160+6 尾比特 / AWGN / 软判决 Q3.5",
                 fontsize=13)
    ax.grid(True, which="both", ls="--", alpha=0.6)
    ax.legend(fontsize=9)
    ax.set_ylim([1e-7, 1])
    fig.savefig(out_png, dpi=150, bbox_inches="tight")
    plt.close(fig)


def export_csv(records, ber_matlab, losses, floor, out_csv, threshold_db=0.5):
    import csv
    from pathlib import Path

    out_csv = Path(out_csv)
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["# S5 viterbi_dec BER 三路同序列对比（同一条 Q3.5 量化软序列）"])
        w.writerow(["# 1) 逐点 BER"])
        w.writerow(["ebn0_db", "n_frames", "n_bits",
                    "err_float", "ber_float",
                    "err_fixed", "ber_fixed", "fixed/float",
                    "err_matlab", "ber_matlab",
                    "only_float_wrong", "only_fixed_wrong"])
        for r, em, bm in zip(records, ber_matlab[0], ber_matlab[1]):
            bf = r["err_float"] / r["n_bits"]
            bx = r["err_fixed"] / r["n_bits"]
            bmm = em / bm if bm > 0 else float("nan")
            w.writerow([f"{r['ebn0_db']:.1f}", r["n_frames"], r["n_bits"],
                        r["err_float"], f"{bf:.4e}",
                        r["err_fixed"], f"{bx:.4e}",
                        f"{bx / bf:.3f}" if bf > 0 else "n/a",
                        int(em), f"{bmm:.4e}",
                        r["only_float"], r["only_fixed"]])
        w.writerow([])
        w.writerow(["# 2) 目标 BER 处 SNR 损失（fixed vs float，出口门槛 ≤ 0.5 dB）"])
        w.writerow(["target_ber", "loss_db", "status"])
        reached = []
        for target, loss in losses.items():
            if loss is None:
                w.writerow([f"{target:.0e}", "未覆盖", "-"])
            else:
                reached.append(loss)
                w.writerow([f"{target:.0e}", f"{loss:.3f}",
                            "通过" if loss <= threshold_db else "未通过"])
        mx = max(reached) if reached else None
        w.writerow(["最大可达损失", f"{mx:.3f}" if mx is not None else "n/a",
                    ("通过" if mx is not None and mx <= threshold_db else "未通过")
                    if mx is not None else "-"])
        w.writerow([])
        w.writerow(["# 3) 高 SNR 平底检查（零误码点 ber 为 95% 上界 3/N）"])
        w.writerow(["ebn0_db", "err_fixed", "n_bits", "ber_fixed",
                    "ber_fixed_95ub", "fixed/float"])
        for d in floor["points"]:
            ub = f"{d['ber_fixed_95ub']:.4e}" if d["ber_fixed_95ub"] else "-"
            w.writerow([f"{d['ebn0_db']:.1f}", d["err_fixed"], d["n_bits"],
                        f"{d['ber_fixed']:.4e}", ub, f"{d['ratio']:.3f}"])
        w.writerow(["平底判定", "有" if floor["floor"] else "无"])
    return out_csv
