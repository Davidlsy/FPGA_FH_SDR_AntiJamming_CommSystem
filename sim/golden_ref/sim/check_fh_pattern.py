"""S6 跳频图案黄金参考自检 —— 判据不能自己给自己背书，这里做四件独立校验：

1. **多项式本原性用数值验证而非凭记忆**：从种子 1 连续推进 LFSR，
   周期必须恰为 2^16−1 = 65535（少一位就不是本原多项式）；
2. **周期平铺 = 连续推进**：`hop_bits` 的 tile 实现与逐拍步进互证
   （跨周期边界逐位一致）——批量路径和参考路径不能是同一段代码；
3. **10⁶ 跳驻留均匀性**：16 信道各驻留次数落在均值 ±10% 内（任务卡判据）；
4. **RTL 语义仿真**：加载拍不出数 / 清 hop_index、一跳 4 bit 非重叠取字、
   全零种子拒收——负例只测正例不能证明护栏真的接上了。

用法:
    python sim/check_fh_pattern.py           # 判据行 [FH-GOLDEN]
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

# 本文件在 sim/golden_ref/sim/ 下，sim/ 是三层之上（包名 golden_ref 在 sim/ 里）
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from golden_ref.fixed_point.fh_pattern import (  # noqa: E402
    FH_DEFAULT_SEED,
    FH_PERIOD,
    dwell_counts,
    hop_bits,
    hop_sequence,
    sim_fh_ctrl,
)

CHECKS = 0
FAILED = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global CHECKS, FAILED
    CHECKS += 1
    if not ok:
        FAILED += 1
    mark = "ok  " if ok else "FAIL"
    print(f"  [{mark}] {name}{('  ' + detail) if detail else ''}")


def _step(reg: int) -> int:
    """单拍推进（独立手写，不 import 产品实现，做互证）。"""
    fb = ((reg >> 0) ^ (reg >> 4) ^ (reg >> 13) ^ (reg >> 15)) & 1
    return (reg >> 1) | (fb << 15)


def main() -> int:
    print("S6 跳频图案黄金参考自检")
    print("=" * 66)

    print("[1] 多项式本原性（周期数值验证）")
    reg = FH_DEFAULT_SEED
    seen = set()
    n = 0
    while reg not in seen and n <= FH_PERIOD + 1:
        seen.add(reg)
        reg = _step(reg)
        n += 1
    check("周期 = 65535（2^16-1）", n == FH_PERIOD and reg == FH_DEFAULT_SEED,
          f"实测周期={n}")
    check("除全零外无重复态", len(seen) == FH_PERIOD, f"不同态={len(seen)}")

    print("[2] 周期平铺与连续推进逐位互证")
    reg = FH_DEFAULT_SEED
    ref = np.empty(3 * FH_PERIOD + 123, dtype=np.int8)   # 跨 3 个周期 + 余量
    for i in range(ref.size):
        ref[i] = reg & 1
        reg = _step(reg)
    tiled = hop_bits(FH_DEFAULT_SEED, ref.size)
    check("tile 路径与逐步路径逐位一致", bool(np.array_equal(ref, tiled)),
          f"比对 {ref.size} bit")
    idx, ch = hop_sequence(FH_DEFAULT_SEED, 200)
    ch_ref = []
    reg = FH_DEFAULT_SEED
    for _ in range(200):
        b = []
        for _ in range(4):
            b.append(reg & 1)
            reg = _step(reg)
        ch_ref.append((b[0] << 3) | (b[1] << 2) | (b[2] << 1) | b[3])
    check("信道号 = 移出 4 bit（b0 落 channel[3]）",
          bool(np.array_equal(ch, np.array(ch_ref))),
          f"前 8 跳 channel={list(map(int, ch[:8]))}")
    check("hop_index 从 0 逐跳 +1", bool(np.array_equal(idx, np.arange(200))))

    print("[3] 10^6 跳驻留均匀性（任务卡 ±10%）")
    counts = dwell_counts(FH_DEFAULT_SEED, 1_000_000)
    mean = 1_000_000 / 16
    lo, hi = 0.9 * mean, 1.1 * mean
    ok = bool(np.all((counts >= lo) & (counts <= hi)))
    check("16 信道驻留全部在 [56250, 68750]", ok,
          f"min={counts.min()} max={counts.max()}")

    print("[4] RTL 语义仿真（fh_ctrl 命令流）")
    # 加载拍不出数、清 hop_index
    out = sim_fh_ctrl([(1, 0x8000), (0, 0)] * 3 + [(0, 0)])
    check("加载拍不出数", len(out) == 4, f"输出拍={len(out)}/激励拍=7")
    check("加载清 hop_index、段内续跳递增",
          [o[0] for o in out] == [0, 0, 0, 1],
          f"hop_index={[o[0] for o in out]}")
    # 加载改变序列：0x8000 段与 0x5A5A 段的首跳信道号应当不同
    a = sim_fh_ctrl([(1, 0x8000), (0, 0)])[0][1]
    b = sim_fh_ctrl([(1, 0x5A5A), (0, 0)])[0][1]
    check("不同种子 → 不同图案", a != b, f"0x8000→ch={a}  0x5A5A→ch={b}")
    # 连续 8 跳与 hop_sequence 一致
    out8 = sim_fh_ctrl([(1, FH_DEFAULT_SEED)] + [(0, 0)] * 8)
    _, ch8 = hop_sequence(FH_DEFAULT_SEED, 8)
    check("sim_fh_ctrl 与 hop_sequence 一致",
          [o[1] for o in out8] == [int(c) for c in ch8])
    # 负例：全零种子拒收
    try:
        sim_fh_ctrl([(1, 0x0000), (0, 0)])
        check("全零种子拒收", False, "未抛异常")
    except ValueError:
        check("全零种子拒收", True)

    print("=" * 66)
    status = "PASS" if FAILED == 0 else "FAIL"
    print(f"[FH-GOLDEN] checks={CHECKS} failed={FAILED} status={status}")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
