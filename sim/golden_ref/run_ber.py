#!/usr/bin/env python3
"""
S1 浮点黄金参考与定点化 - 主入口
运行 BER 仿真并生成基线曲线（写入 data/s1_ber_baseline/）

用法:
    python run_ber.py                     # 运行浮点+定点 BER 仿真
    python run_ber.py --float-only        # 仅浮点
    python run_ber.py --quick             # 快速模式 (少帧数)
    python run_ber.py --export-loss-only  # 仅从已有 npz 导出 SNR 损失表
"""
import argparse
import os
import sys
from pathlib import Path

import numpy as np

# sim/golden_ref/ 的父目录是 sim/，包名 golden_ref
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from golden_ref.sim.ber_sim import run_ber_simulation_float
from golden_ref.sim.snr_loss import (
    run_ber_simulation_fixed,
    snr_loss_analysis,
    export_snr_loss_table,
)

# 仓库根：sim/golden_ref → 上两级
_REPO_ROOT = Path(__file__).resolve().parents[2]
_DEFAULT_OUT = _REPO_ROOT / "data" / "s1_ber_baseline"


def parse_args():
    parser = argparse.ArgumentParser(description="S1 浮点黄金参考与定点化 - BER 仿真")
    parser.add_argument("--float-only", action="store_true", help="仅运行浮点仿真")
    parser.add_argument("--quick", action="store_true", help="快速模式 (减少仿真量)")
    parser.add_argument("--seed", type=int, default=42, help="随机种子")
    parser.add_argument(
        "--output-dir",
        type=str,
        default=str(_DEFAULT_OUT),
        help="输出目录（默认 data/s1_ber_baseline）",
    )
    parser.add_argument(
        "--export-loss-only",
        action="store_true",
        help="仅根据已有 npz 导出 SNR 损失表，不重跑仿真",
    )
    return parser.parse_args()


def export_from_existing(output_dir):
    """读取 data 下 npz，导出 snr_loss_table.csv。"""
    out = Path(output_dir)
    fp = out / "ber_float.npz"
    fx = out / "ber_fixed.npz"
    if not fp.exists() or not fx.exists():
        raise FileNotFoundError(f"缺少 BER npz: {fp} / {fx}")
    f = np.load(fp)
    x = np.load(fx)
    ebn0 = f["eb_n0_db"]
    ber_f = f["ber"]
    ber_x = x["ber"]
    losses, ber_ratio = snr_loss_analysis(ber_f, ber_x, ebn0)
    csv_path = export_snr_loss_table(
        out / "snr_loss_table.csv", ebn0, ber_f, ber_x, losses, ber_ratio
    )
    print("SNR 损失表已导出:", csv_path)
    print("目标 BER 链路损失:")
    for target, loss in losses.items():
        if loss is None:
            print(f"  BER = {target:.0e}: 未覆盖")
        else:
            print(f"  BER = {target:.0e}: SNR 损失 = {loss:.3f} dB")
    reached = [v for v in losses.values() if v is not None]
    if reached:
        mx = max(reached)
        status = "✓ 通过" if mx <= 0.5 else "✗ 未通过"
        print(f"出口门槛: 最大可达损失 = {mx:.3f} dB, 阈值 = 0.5 dB → {status}")
    return csv_path


def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    if args.export_loss_only:
        export_from_existing(args.output_dir)
        return

    # 仿真参数
    if args.quick:
        num_frames = 10
        min_error_bits = 20
        max_bits = 200_000
        eb_n0_range = np.arange(0, 9, 2)  # 0, 2, 4, 6, 8 dB
    else:
        num_frames = 50
        min_error_bits = 100
        max_bits = 2_000_000
        eb_n0_range = np.arange(0, 9, 1)  # 0~8 dB

    print("=" * 60)
    print("S1 浮点黄金参考与定点化 - BER 仿真")
    print("=" * 60)
    print(f"Eb/N0 范围: {eb_n0_range[0]:.0f} ~ {eb_n0_range[-1]:.0f} dB")
    print(f"每帧比特: {num_frames} 帧 (快速模式)" if args.quick else f"每帧比特: 标准模式")
    print(f"随机种子: {args.seed}")
    print()

    # ---- 浮点参考链 BER ----
    print("[1/2] 运行浮点参考链 BER 仿真...")
    ebn0_float, ber_float = run_ber_simulation_float(
        eb_n0_range=eb_n0_range,
        num_frames=num_frames,
        min_error_bits=min_error_bits,
        max_bits=max_bits,
        seed=args.seed,
    )
    print()

    # 保存浮点结果
    float_result_path = os.path.join(args.output_dir, "ber_float.npz")
    np.savez(float_result_path, eb_n0_db=ebn0_float, ber=ber_float)
    print(f"浮点 BER 结果已保存: {float_result_path}")

    # ---- 定点链 BER ----
    ber_fixed = None
    if not args.float_only:
        print("[2/2] 运行定点链 BER 仿真...")
        ebn0_fixed, ber_fixed = run_ber_simulation_fixed(
            eb_n0_range=eb_n0_range,
            num_frames=num_frames,
            min_error_bits=min_error_bits,
            max_bits=max_bits,
            seed=args.seed,
        )
        print()

        # 保存定点结果
        fixed_result_path = os.path.join(args.output_dir, "ber_fixed.npz")
        np.savez(fixed_result_path, eb_n0_db=ebn0_fixed, ber=ber_fixed)
        print(f"定点 BER 结果已保存: {fixed_result_path}")

        # SNR 损失分析 + 导出 CSV
        print("-" * 60)
        print("SNR 损失分析 (定点 vs 浮点):")
        losses, ber_ratio = snr_loss_analysis(ber_float, ber_fixed, ebn0_float)
        for target, loss in losses.items():
            if loss is None:
                print(f"  BER = {target:.0e}: 未覆盖（曲线未到达该误码）")
            else:
                print(f"  BER = {target:.0e}: SNR 损失 = {loss:.2f} dB")

        reached = [v for v in losses.values() if v is not None]
        if reached:
            max_loss = max(reached)
            status = "✓ 通过" if max_loss <= 0.5 else "✗ 未通过"
            print(f"\n出口门槛验证: 最大可达 SNR 损失 = {max_loss:.2f} dB, 阈值 = 0.5 dB → {status}")
        else:
            print("\n出口门槛验证: 无可达目标 BER，需加长仿真或降低目标 BER")

        csv_path = export_snr_loss_table(
            os.path.join(args.output_dir, "snr_loss_table.csv"),
            ebn0_float,
            ber_float,
            ber_fixed,
            losses=losses,
            ber_ratio=ber_ratio,
        )
        print(f"SNR 损失表已导出: {csv_path}")

    # ---- 生成 BER 曲线图 ----
    print("\n生成 BER 基线曲线图...")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        fig, ax = plt.subplots(figsize=(8, 6))
        ax.semilogy(ebn0_float, ber_float, "bo-", label="浮点参考链", linewidth=2, markersize=6)

        if ber_fixed is not None:
            ax.semilogy(ebn0_fixed, ber_fixed, "rs--", label="定点链", linewidth=2, markersize=6)

        ax.set_xlabel("Eb/N0 (dB)", fontsize=12)
        ax.set_ylabel("BER", fontsize=12)
        ax.set_title("S1 黄金参考链 BER 基线曲线\n卷积(171,133) / 交织10 / QPSK / SRRC α=0.35 / AWGN",
                     fontsize=13)
        ax.grid(True, which="both", ls="--", alpha=0.6)
        ax.legend(fontsize=11)
        ax.set_ylim([1e-6, 1])

        plot_path = os.path.join(args.output_dir, "ber_curve.png")
        fig.savefig(plot_path, dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"BER 曲线图已保存: {plot_path}")
    except ImportError:
        print("  (matplotlib 未安装，跳过曲线图生成)")

    print("\n" + "=" * 60)
    print("仿真完成！")
    print("=" * 60)


if __name__ == "__main__":
    main()
