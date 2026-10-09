#!/usr/bin/env python3
"""S5 viterbi_dec BER 三路同序列对比 - 主入口

三路：浮点参考 viterbi_decode / 硬件忠实 fixed_viterbi_hw（RTL 语义）
      / MATLAB vitdec（trunc, tblen=96, unquant，同序列叠图）
判据：与浮点参考 BER 差 ≤0.5 dB；高 SNR 无误码平底（§4.4）。

用法:
    python run_viterbi_ber.py            # 全量扫点 + MATLAB 交叉 + 出图出表
    python run_viterbi_ber.py --quick    # 冒烟（少帧少点，跑通流水线）
    python run_viterbi_ber.py --skip-matlab   # 只跑 Python 两路（无 MATLAB 环境时）
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from golden_ref.sim.viterbi_ber import (
    export_csv,
    floor_check,
    load_vitdec_output,
    loss_analysis,
    plot_three,
    run_sweep,
    save_vitdec_input,
    self_check,
)

_REPO_ROOT = Path(__file__).resolve().parents[2]
_DEFAULT_OUT = _REPO_ROOT / "data" / "s5_viterbi_ber"
_FLOAT_REF = _REPO_ROOT / "sim" / "float_ref"
_MATLAB_EXE = r"D:\software\Matlab\bin\matlab.exe"   # 与 s1 归档对照同一环境


def parse_args():
    p = argparse.ArgumentParser(description="S5 viterbi_dec BER 三路同序列对比")
    p.add_argument("--quick", action="store_true", help="冒烟模式（少帧少点）")
    p.add_argument("--points", type=str, default=None,
                   help="Eb/N0 点，逗号分隔（默认 0,1,2,3,3.5,4,4.5,5,5.5,6）")
    p.add_argument("--max-frames", type=int, default=None)
    p.add_argument("--min-error-bits", type=int, default=None)
    p.add_argument("--max-bits", type=int, default=None)
    p.add_argument("--seed", type=int, default=20261009)
    p.add_argument("--output-dir", type=str, default=str(_DEFAULT_OUT))
    p.add_argument("--skip-matlab", action="store_true", help="跳过 MATLAB vitdec 交叉")
    p.add_argument("--matlab", type=str, default=_MATLAB_EXE)
    return p.parse_args()


def run_matlab_vitdec(matlab_exe: str, io_dir: Path) -> bool:
    """调 MATLAB vitdec 跑同序列并回写 vitdec_out.mat。"""
    io = str(io_dir.resolve()).replace("\\", "/")
    fp = str(_FLOAT_REF.resolve()).replace("\\", "/")
    batch = f"cd('{fp}'); run_viterbi_vitdec('{io}')"
    print(f"[MATLAB] {matlab_exe} -batch \"{batch}\"")
    # 中文 Windows 下 MATLAB 控制台输出为 GBK；按字节收再解码，防 UTF-8 解码线程崩
    r = subprocess.run([matlab_exe, "-batch", batch],
                       capture_output=True, timeout=900)
    def _dec(b):
        return (b or b"").decode("gbk", errors="replace")
    if r.returncode != 0 or not (io_dir / "vitdec_out.mat").exists():
        print(_dec(r.stdout)[-2000:])
        print(_dec(r.stderr)[-2000:])
        print("[MATLAB] FAIL —— 可用 --skip-matlab 先出两路结果")
        return False
    return True


def main():
    args = parse_args()
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("S5 viterbi_dec BER 三路同序列对比")
    print("=" * 60)
    self_check()
    print("[自检] 无噪帧三路一致 / 长度账本 2160+6 → 4332 / Q3.5 格点闭合  PASS")

    if args.quick:
        points = args.points or "2.0,3.5,5.0"
        max_frames, min_err, max_bits = 8, 20, 20_000
    else:
        points = args.points or "0,1,2,3,3.5,4,4.5,5,5.5,6"
        max_frames, min_err, max_bits = 400, 50, 600_000
    eb_n0 = [float(x) for x in str(points).split(",")]
    max_frames = args.max_frames or max_frames
    min_err = args.min_error_bits or min_err
    max_bits = args.max_bits or max_bits
    print(f"点: {eb_n0} | 每点上限 {max_frames} 帧 / {max_bits} bit / 误码 {min_err}")

    # ---- Python 两路（同序列）----
    records = run_sweep(eb_n0, seed=args.seed, max_frames=max_frames,
                        min_error_bits=min_err, max_bits=max_bits)

    # ---- MATLAB vitdec（同序列）----
    ber_matlab = (np.zeros(len(records), dtype=np.int64),
                  np.array([r["n_bits"] for r in records], dtype=np.int64))
    if args.skip_matlab:
        print("[MATLAB] 跳过（--skip-matlab）")
    else:
        io_dir = out / "matlab_io"
        save_vitdec_input(records, io_dir)
        if run_matlab_vitdec(args.matlab, io_dir):
            errs, bits = load_vitdec_output(io_dir)
            ber_matlab = (errs, bits)
            print(f"[MATLAB] vitdec 同序列回读 PASS（{bits.sum()} bit）")
        else:
            sys.exit(1)

    # ---- 判据 ----
    losses, ratio = loss_analysis(records)
    floor = floor_check(records, ratio)

    print("-" * 60)
    print("目标 BER 处 SNR 损失（fixed vs float，门槛 ≤ 0.5 dB）:")
    reached = []
    for target, loss in losses.items():
        if loss is None:
            print(f"  BER = {target:.0e}: 未覆盖")
        else:
            reached.append(loss)
            print(f"  BER = {target:.0e}: SNR 损失 = {loss:.3f} dB")
    if reached:
        mx = max(reached)
        print(f"出口门槛: 最大可达损失 = {mx:.3f} dB → "
              f"{'✓ 通过' if mx <= 0.5 else '✗ 未通过'}")
    print(f"高 SNR 平底检查: {'✗ 存在平底签名' if floor['floor'] else '✓ 无平底'}")
    for d in floor["points"]:
        ub = f"（95% 上界 {d['ber_fixed_95ub']:.1e}）" if d["ber_fixed_95ub"] else ""
        print(f"  {d['ebn0_db']:.1f} dB: fixed BER={d['ber_fixed']:.2e}{ub} "
              f"fixed/float={d['ratio']:.2f}")

    # ---- 产物 ----
    np.savez(out / "ber_viterbi.npz",
             ebn0_db=np.array([r["ebn0_db"] for r in records]),
             n_bits=np.array([r["n_bits"] for r in records]),
             err_float=np.array([r["err_float"] for r in records]),
             err_fixed=np.array([r["err_fixed"] for r in records]),
             err_matlab=ber_matlab[0], n_bits_matlab=ber_matlab[1],
             only_float=np.array([r["only_float"] for r in records]),
             only_fixed=np.array([r["only_fixed"] for r in records]))
    plot_three(records, ber_matlab, out / "ber_curve_viterbi.png")
    csv_path = export_csv(records, ber_matlab, losses, floor,
                          out / "snr_loss_table_viterbi.csv")
    print(f"\n产物: {out / 'ber_curve_viterbi.png'}")
    print(f"      {csv_path}")
    print(f"      {out / 'ber_viterbi.npz'}")

    ok = (reached and max(reached) <= 0.5) and not floor["floor"]
    print("\n" + "=" * 60)
    print(f"[VITERBI BER] {'PASS' if ok else 'CHECK'}"
          f"（损失门槛 {'通过' if reached and max(reached) <= 0.5 else '未过/未覆盖'}，"
          f"平底 {'无' if not floor['floor'] else '有'}）")
    print("=" * 60)


if __name__ == "__main__":
    main()
