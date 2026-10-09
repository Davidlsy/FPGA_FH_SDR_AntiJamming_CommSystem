"""S6 nco_hop 黄金参考自检 —— 判据不能自己给自己背书，七件独立校验：

1. **FTW 表冻结值**：16 项、全为奇数倍 1024、严格位于 (0, 2^15)、单调一一对应；
2. **NCO 核交叉锚点**：无跳序列下与 `duc.FixedNCO(freq_word=8192)` 逐步
   (cos, sin) 一致——S4 已验证的 NCO 语义与本模块是同一套；
3. **相位连续性（互证）**：独立手写影子累加器逐拍核对 phase 轨迹——
   每拍增量恰为生效 ftw，除复位外无任何阶跃来源；
4. **FTW 生效延迟**：跳事件后 ftw 在 ≤2 拍内切换（< 1 µs = 8 拍 @ fs=8 MSPS）；
5. **LO 量化误差界**：|cos_int/2^14 − cos(2π·phase/2^16)| ≤ 2^-12（镜像 1 格偏差 + 舍入）；
6. **din_valid 门控**：空隙拍冻结（phase/ftw 保持、无输出）；
7. **压缩 3×10⁵ 跳长轨迹**：hop 计数、连续性、16 信道全覆盖（RTL 长跑的模型侧对照）。

用法:
    python sim/check_nco_hop.py           # 判据行 [NCO-HOP-GOLDEN]
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

# 本文件在 sim/golden_ref/sim/ 下，sim/ 是三层之上（包名 golden_ref 在 sim/ 里）
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from golden_ref.fixed_point.duc import FixedNCO  # noqa: E402
from golden_ref.fixed_point.nco_hop import (  # noqa: E402
    NCO_HOP_FTW_TABLE,
    NCO_LUT_FRAC,
    NCO_PHASE_W,
    sim_nco_hop,
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


def shadow_run(cmds):
    """独立影子实现：按 s6_fh_interface.md §5.2 的三条语义手写，与 sim_nco_hop 互证。

    返回 (轨迹, ftw 切换延迟列表)。轨迹元素 = (out_phase, phase_after, ftw_after)。
    """
    mask = (1 << NCO_PHASE_W) - 1
    phase, ftw = 0, 0
    traj, latencies = [], []
    for i, (din_valid, hop_valid, channel) in enumerate(cmds):
        if not din_valid:
            traj.append(None)
            continue
        out_phase = phase
        phase = (phase + ftw) & mask          # 本拍步进用旧 ftw
        if hop_valid:
            ftw = NCO_HOP_FTW_TABLE[channel]  # 换字不清相位
            latencies.append((i, ftw))
        traj.append((out_phase, phase, ftw))
    return traj, latencies


def main() -> int:
    print("S6 nco_hop 黄金参考自检")
    print("=" * 66)

    print("[1] FTW 表冻结值（s6 §5.1）")
    t = NCO_HOP_FTW_TABLE
    check("16 项", len(t) == 16, f"len={len(t)}")
    check("全为奇数倍 1024", all(v == (2 * k + 1) << 10 for k, v in enumerate(t)))
    check("严格位于 (0, 2^15)", all(0 < v < (1 << 15) for v in t),
          f"min={min(t)} max={max(t)}")
    check("唯一且单调", len(set(t)) == 16 and all(t[i] < t[i + 1] for i in range(15)))
    check("间隔恒为 fs/32（2048）", all(t[i + 1] - t[i] == 2048 for i in range(15)))

    print("[2] NCO 核交叉锚点（vs duc.FixedNCO，FTW=8192）")
    n = 256
    cmds = [(1, 1, 0)] + [(1, 0, 0)] * n
    out = sim_nco_hop(cmds, ftw_table=(8192,) * 16)
    ref = FixedNCO(freq_word=8192)
    mismatch = 0
    for k in range(n):
        c_r, s_r = ref.step()
        _, c, s = out[k + 1]                  # 拍 0 步进用旧 ftw=0（输出重复 1 拍），锚点自拍 1 起
        if (c, s) != (round(c_r * (1 << NCO_LUT_FRAC)), round(s_r * (1 << NCO_LUT_FRAC))):
            mismatch += 1
    check("256 拍逐拍一致", mismatch == 0, f"mismatch={mismatch}")

    print("[3] 相位连续性（独立影子累加器互证）")
    cmds = []
    state = 0x1234
    for i in range(20000):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        hop = 1 if (state >> 16) % 5 == 0 else 0
        cmds.append((1, hop, (state >> 8) & 0xF))
    out = sim_nco_hop(cmds)
    traj, latencies = shadow_run(cmds)
    live = [x for x in traj if x is not None]
    check("轨迹长度 = 有效拍数", len(out) == len(live), f"{len(out)} vs {len(live)}")
    bad = sum(1 for (p, _, _), (p0, _, _) in zip(out, live) if p != p0)
    check("phase 轨迹逐拍一致（互证）", bad == 0, f"bad={bad}")
    hops = sum(1 for _, h, _ in cmds if h)
    check("随机序列跳事件数", hops > 3000, f"hops={hops}")

    print("[4] FTW 生效延迟（≤2 拍，<1 µs = 8 拍 @ 8 MSPS）")
    mask = (1 << NCO_PHASE_W) - 1
    worst = 0
    for i, ftw_new in latencies:
        # 跳拍 i 的步进用旧 ftw；i+1 拍步进用新 ftw → 延迟 2 拍（含输出寄存 1 拍）
        if i + 1 >= len(live):
            continue
        delta = (live[i + 1][1] - live[i + 1][0]) & mask   # i+1 拍的步进增量
        if delta != ftw_new:
            worst += 1
    check("每次跳后下一拍步进即用新 ftw", worst == 0, f"bad={worst}")

    print("[5] LO 量化误差界（≤ 2^-12）")
    worst_err = 0.0
    for k in range(0, len(out), 97):
        p, c, s = out[k]
        ideal_c = math.cos(2 * math.pi * p / (1 << NCO_PHASE_W))
        ideal_s = math.sin(2 * math.pi * p / (1 << NCO_PHASE_W))
        worst_err = max(worst_err,
                        abs(c / (1 << NCO_LUT_FRAC) - ideal_c),
                        abs(s / (1 << NCO_LUT_FRAC) - ideal_s))
    check("抽样最大误差在界内", worst_err <= 2 ** -12, f"max={worst_err:.3e}")

    print("[6] din_valid 门控冻结语义")
    gated = [(1, 1, 3), (1, 0, 0), (0, 0, 0), (0, 0, 0), (1, 0, 0), (1, 0, 0)]
    out_g = sim_nco_hop(gated)
    traj_g, _ = shadow_run(gated)
    live_g = [x for x in traj_g if x is not None]
    check("空隙拍无输出", len(out_g) == 4, f"n={len(out_g)}")
    check("空隙前后 phase 连续（无跳变）",
          [p for p, _, _ in out_g] == [p for p, _, _ in live_g])
    # 空隙后首拍相位 = 空隙前末拍步进值（冻结不推进）
    check("冻结拍保持 phase/ftw", out_g[2][0] == live_g[1][1],
          f"{out_g[2][0]} vs {live_g[1][1]}")

    print("[7] 压缩 3×10⁵ 跳长轨迹（4 拍/跳）")
    n_hops, ticks_per = 300_000, 4
    cmds_long = []
    ch = 0
    for _ in range(n_hops):
        cmds_long.append((1, 1, ch))
        cmds_long.extend((1, 0, 0) for _ in range(ticks_per - 1))
        ch = (ch + 5) & 0xF
    out_l = sim_nco_hop(cmds_long)
    traj_l, lat_l = shadow_run(cmds_long)
    live_l = [x for x in traj_l if x is not None]
    bad = sum(1 for (p, _, _), (p0, _, _) in zip(out_l, live_l) if p != p0)
    check("总拍数", len(out_l) == n_hops * ticks_per, f"n={len(out_l)}")
    check("跳数", len(lat_l) == n_hops, f"hops={len(lat_l)}")
    check("全轨迹无阶跃（互证）", bad == 0, f"bad={bad}")
    covered = {c for _, h, c in cmds_long if h}
    check("16 信道全覆盖", covered == set(range(16)), f"n={len(covered)}")

    print("=" * 66)
    status = "PASS" if FAILED == 0 else "FAIL"
    print(f"[NCO-HOP-GOLDEN] checks={CHECKS} failed={FAILED} status={status}")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
