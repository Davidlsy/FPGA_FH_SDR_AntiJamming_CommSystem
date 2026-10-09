"""S6 TOD 时基黄金裁判自检 —— 判据不能自己给自己背书，这里做独立校验：

1. **tick 分频精确性**（真实 8000 拍值）：tick 恰每 8000 有效拍一次，tick 拍 tod = 新计数；
2. **跳沿网格**（三档 hop_ticks=1/2/10）与**换挡重网格**：跳沿只落 tick 边界、tod ≡ 0 mod hop_ticks；
3. **snap 牵引**：±32 边界、+33 负例（7.6 #1 有意边界）、64 窗回绕、63→0 跨窗；
4. **对齐脉冲规则"未发过才补发"**（§7.4）：晚检测不双发、早检测不丢发，用边界值
   "逐个恰一次"度量（同拍自然 tick 不可归因，按值多重度量才免疫窗口相位滑动）；
5. **对齐误差 ≤±0.25 跳周期**（任务卡判据）：TX/RX 双实例 + 初值偏差 + 帧首检测抖动扫描，
   三档跳速各测，跳沿时刻按 tod 值配对；
6. **长外推无漂移**：单次装订后 5000 tick 边界与整数公式逐点互证；
7. **跨模块互证**：TX/RX 跳沿各喂一个 fh_ctrl 实例（每跳沿一拍推进命令），
   跳计数守恒 + `hop_index`/`channel` 逐跳相等 + 逐拍信道流互比（抖动窗内允许不等）。

用法:
    python sim/golden_ref/sim/check_tod.py           # 判据行 [TOD-GOLDEN]
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from golden_ref.fixed_point.fh_pattern import sim_fh_ctrl  # noqa: E402
from golden_ref.fixed_point.tod import (  # noqa: E402
    TOD_TICK_SAMPLES,
    hop_ticks_of,
    sim_tod,
    snap_tod,
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


def _norm(stream, fill=(0, 0, 0, 0, 0, 0)):
    return [tuple(c) for c in stream]


def _cycles(n, rate_sel=0, load=None, aligns=None):
    """生成 n 拍激励：load=(cycle, value)，aligns={cycle: A}。"""
    load = load or {}
    aligns = aligns or {}
    cmds = []
    for c in range(n):
        if c in load:
            cmds.append((1, rate_sel, 1, 0, 0, load[c]))
        elif c in aligns:
            cmds.append((1, rate_sel, 0, 1, aligns[c], 0))
        else:
            cmds.append((1, rate_sel, 0, 0, 0, 0))
    return cmds


def main() -> int:
    print("S6 TOD 时基黄金裁判自检")
    print("=" * 66)

    print("[1] tick 分频精确性（TICK_SAMPLES=8000 真实值）")
    n = 3 * TOD_TICK_SAMPLES + 500
    out = sim_tod(_cycles(n, rate_sel=0, load={0: 1000}))
    ticks = [i for i, o in enumerate(out) if o[0] == 1]
    check("tick 恰每 8000 有效拍（含装订声明的边界拍）", all(b - a == TOD_TICK_SAMPLES for a, b in zip(ticks, ticks[1:])),
          f"tick 拍号={ticks}")
    tods = [o[1] for o in out]
    check("tick 拍 tod = 边界计数（装订拍 = 装订值）",
          all(tods[i] == 1000 + k for k, i in enumerate(ticks)),
          f"tick 拍 tod={[tods[i] for i in ticks]}")
    check("非 tick 拍 tod 保持", tods[1] == 1000 and tods[2] == 1000)

    print("[2] 跳沿网格三档 + 换挡重网格（tick_samples=80 加速，语义同构）")
    ts = 80
    for sel, ht in ((0, 1), (1, 2), (2, 10)):
        out = sim_tod(_cycles(40 * ts, rate_sel=sel, load={0: 0}), tick_samples=ts)
        edges = [i for i, o in enumerate(out) if o[2] == 1]
        tick_pos = [i for i, o in enumerate(out) if o[0] == 1]
        ok_grid = all(i in tick_pos for i in edges)                     # 跳沿只落 tick 边界
        k = [out[i][1] for i in edges]                                 # 跳沿的 tod 值
        ok_mod = all(v % ht == 0 for v in k)
        exp = list(range(0, 40, ht)) if sel != 2 else list(range(0, 40, ht))
        check(f"rate_sel={sel}（{hop_ticks_of(sel)} tick/跳）跳沿落边界且 tod≡0 mod {ht}",
              ok_grid and ok_mod and k == exp, f"跳沿 tod={k}")
    # 换挡：0（每 tick）→ 2（每 10 tick），跳沿立即按新分频、仍落 tick 边界
    cmds = _cycles(30 * ts, rate_sel=0, load={0: 0})
    for c in range(15 * ts, 30 * ts):
        cmds[c] = (1, 2, 0, 0, 0, 0)
    out = sim_tod(cmds, tick_samples=ts)
    edges = [out[i][1] for i, o in enumerate(out) if o[2] == 1]
    tick_pos = {i for i, o in enumerate(out) if o[0] == 1}
    ok = all(out[i][1] % 10 == 0 for i, o in enumerate(out) if o[2] == 1 and out[i][1] >= 15)
    ok = ok and all(i in tick_pos for i, o in enumerate(out) if o[2] == 1)
    check("换挡后跳沿只落 tod≡0 mod 10 的 tick 边界", ok, f"跳沿 tod={edges}")

    print("[3] snap 牵引（76 窗最近，±32 边界 + 负例）")
    check("低 6 位一致 → 不动", snap_tod(0x2A, 0x1234_002A) == 0x1234_002A)
    check("+32 拉回", snap_tod(0x20, 0x00_0001) == 0x0000_0020, f"→{snap_tod(0x20, 1):#x}")
    check("−32 拉回", snap_tod(0x00, 0x00_0020) == 0x0000_0000, f"→{snap_tod(0x00, 0x20):#x}")
    check("+33 牵引失败留 −31（7.6 #1 负例）", snap_tod(0x21, 0x00_0000) == (0x21 - 64) & 0xFFFF_FFFF,
          f"→{snap_tod(0x21, 0):#x}")
    check("64 窗回绕（0x3F→0x00 邻窗）", snap_tod(0x00, 0x00_003F) == 0x0000_0040,
          f"→{snap_tod(0x00, 0x3F):#x}")
    check("tod 回绕端（8 bit 窄位宽）", snap_tod(0x01, 0xFF, tod_w=8) == 0x01, f"→{snap_tod(0x01, 0xFF, 8):#x}")

    print("[4] 对齐脉冲规则『未发过才补发』（7.4，边界值逐个恰一次）")
    ts4 = 10
    n4 = 40 * ts4
    # 基准 TX：装订声明边界 5，自然边界 6..44
    tx = sim_tod(_cycles(n4, rate_sel=0, load={0: 5}), tick_samples=ts4)
    tx_vals = [o[1] for o in tx if o[0]]
    # 极小晚检测例：边界 6 已在拍 10 发出，拍 11 对齐 A=6 → 整拍不动、不双发
    rx = sim_tod(_cycles(3 * ts4, rate_sel=0, load={0: 5}, aligns={11: 6}), tick_samples=ts4)
    check("晚检测：snap 不改 tod 的对齐拍不双发", rx[11][0] == 0 and rx[11][1] == 6,
          f"拍11 tick={rx[11][0]} tod={rx[11][1]}")
    check("晚检测：边界 6 恰发一次", [o[1] for o in rx if o[0]].count(6) == 1,
          f"边界序列={[o[1] for o in rx if o[0]]}")
    # 极小早检测例：拍 9 对齐 A=6 → 边界 6 提前声明；拍 10 自然重锚不得双发
    rx = sim_tod(_cycles(3 * ts4, rate_sel=0, load={0: 5}, aligns={9: 6}), tick_samples=ts4)
    check("早检测：对齐拍补发声明边界", rx[9][0] == 1 and rx[9][1] == 6,
          f"拍9 tick={rx[9][0]} tod={rx[9][1]}")
    check("早检测：边界 6 恰发一次（自然重锚不双发）",
          [o[1] for o in rx if o[0]].count(6) == 1 and rx[10][0] == 0,
          f"边界序列={[o[1] for o in rx if o[0]]}")
    # 持续抖动流：边界值逐个恰一次（取内部值域，免疫窗口相位滑动）
    lo, hi = tx_vals[3], tx_vals[-3] + 1
    for name, delta in (("晚检测 δ=+1", +1), ("早检测 δ=−1", -1)):
        aligns = {k * ts4 + delta: (5 + k) & 63 for k in range(2, 38)}
        rx = sim_tod(_cycles(n4, rate_sel=0, load={0: 5}, aligns=aligns), tick_samples=ts4)
        rx_vals = [o[1] for o in rx if o[0]]
        ok = (all(rx_vals.count(v) == 1 for v in range(lo, hi))
              and all(tx_vals.count(v) == 1 for v in range(lo, hi)))
        check(f"{name}流：边界值 {lo}..{hi - 1} 逐个恰一次", ok,
              f"rx 边界数={len(rx_vals)} tx 边界数={len(tx_vals)}")

    print("[5] 对齐误差 ≤±0.25 跳周期（任务卡判据，TX/RX 双实例 + 抖动扫描）")
    deltas = (-100, -64, -20, 0, 20, 64, 100)
    max_all = 0
    for sel in (0, 1, 2):
        ht = hop_ticks_of(sel)
        period = TOD_TICK_SAMPLES * ht                     # 跳周期（拍）
        bound = 0.25 * period
        n5 = 22 * 2 * TOD_TICK_SAMPLES                     # 22 个帧 @ 2 tick/帧
        base = 1000
        tx = sim_tod(_cycles(n5, rate_sel=sel, load={0: base}))
        aligns = {}
        for m in range(1, 21):
            b = m * 2 * TOD_TICK_SAMPLES                   # 帧首 = TX tick 边界
            aligns[b + deltas[m % len(deltas)]] = (base + 2 * m) & 63
        rx = sim_tod(_cycles(n5, rate_sel=sel, load={3333: base + 21}, aligns=aligns))
        # 跳沿按 tod 值配对（牵引瞬态的游离边不配对，只比公共键）
        tx_e = {o[1]: i for i, o in enumerate(tx) if o[2]}
        rx_e = {o[1]: i for i, o in enumerate(rx) if o[2]}
        keys = sorted(set(tx_e) & set(rx_e))
        cut = base + 2 * 3 + ht                            # 前 2 帧为牵引瞬态
        keys = [k for k in keys if k >= cut]
        err = max((abs(rx_e[k] - tx_e[k]) for k in keys), default=0)
        max_all = max(max_all, err)
        ok = err <= bound and len(keys) > 0
        check(f"rate_sel={sel} 对齐误差 {err} ≤ {bound:.0f} 拍（0.25 跳周期）",
              ok, f"配对跳沿={len(keys)} 抖动±{max(map(abs, deltas))} 拍")

    print("[6] 长外推无漂移（单次装订，5000 tick）")
    ts6 = 80
    out = sim_tod(_cycles(5000 * ts6, rate_sel=2, load={0: 0}), tick_samples=ts6)
    edges = [out[i][1] for i, o in enumerate(out) if o[2]]
    exp = list(range(0, 5000, 10))
    check("5000 tick 跳沿逐点 = 整数公式（无漂移）", edges == exp, f"跳沿数={len(edges)}")

    print("[7] 跨模块互证：TX/RX 跳沿 → fh_ctrl 双实例 hop_index/channel 互比")
    n7 = 14 * 2 * TOD_TICK_SAMPLES
    base = 77
    # RX 同值装订、相位滞后 3333 拍 + 抖动扫描：修正全为前向，跳计数应守恒
    tx = sim_tod(_cycles(n7, rate_sel=1, load={0: base}))
    aligns = {m * 2 * TOD_TICK_SAMPLES + deltas[m % len(deltas)]: (base + 2 * m) & 63
              for m in range(1, 11)}
    rx = sim_tod(_cycles(n7, rate_sel=1, load={3333: base}, aligns=aligns))
    # 跳计数守恒按内部值域过滤（两端窗口相位滑动免疫）
    v_lo, v_hi = base + 1, base + 23
    tx_cnt = sum(1 for o in tx if o[2] and v_lo <= o[1] <= v_hi)
    rx_cnt = sum(1 for o in rx if o[2] and v_lo <= o[1] <= v_hi)
    check("跳沿计数守恒（收敛后无漂移）", tx_cnt == rx_cnt and tx_cnt > 0,
          f"tx 跳={tx_cnt} rx 跳={rx_cnt} 值域={v_lo}..{v_hi}")
    # 双 fh_ctrl 实例：每个跳沿喂一拍推进命令（契约 (seed_load, seed) = (0, ·)）
    tx_all = [i for i, o in enumerate(tx) if o[2]]
    rx_all = [i for i, o in enumerate(rx) if o[2]]
    tx_hops = sim_fh_ctrl([(0, 0)] * len(tx_all))
    rx_hops = sim_fh_ctrl([(0, 0)] * len(rx_all))
    check("fh_ctrl 双实例 hop_index/channel 逐跳相等", tx_hops == rx_hops and len(tx_hops) > 0,
          f"逐跳相等={sum(a == b for a, b in zip(tx_hops, rx_hops))}/{len(tx_hops)}")

    def _stream(pos, hops, n):
        st = [None] * n
        k = -1
        pi = 0
        for c in range(n):
            while pi < len(pos) and pos[pi] <= c:
                k += 1
                pi += 1
            st[c] = hops[k] if k >= 0 else None
        return st

    tx_stream = _stream(tx_all, tx_hops, n7)
    rx_stream = _stream(rx_all, rx_hops, n7)
    cut = 3 * 2 * TOD_TICK_SAMPLES
    tol = max(map(abs, deltas))
    bad = [c for c in range(cut, n7)
           if tx_stream[c] != rx_stream[c]
           and not (any(abs(c - p) <= tol for p in tx_all)
                    or any(abs(c - p) <= tol for p in rx_all))]
    check(f"逐拍 (hop_index, channel) 互比（±{tol} 拍抖动窗内允许不等）", not bad,
          f"越界不等拍={len(bad)}")

    print()
    status = "PASS" if FAILED == 0 else "FAIL"
    print(f"[TOD-GOLDEN] checks={CHECKS} failed={FAILED} status={status}")
    print(f"[TOD-GOLDEN] align_err_max={max_all} samples (bound 2000 @1000hop/s)")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
