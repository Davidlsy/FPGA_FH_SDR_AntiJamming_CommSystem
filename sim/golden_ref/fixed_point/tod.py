"""S6 TOD 时基黄金裁判 —— `docs/spec/s6_fh_interface.md` §7 逐条同构。

- 1 ms tick = TICK_SAMPLES = 8000 拍（fs = 8 MSPS），`tod` 每 tick +1，2^TOD_W 自然回绕；
- 跳沿 = tick 边界且 tod ≡ 0 (mod hop_ticks)：1000 hop/s→1、500→2、100→10；
- 帧头 `[29:24]` = tod[5:0]（帧首 bit 拍采样），对齐 snap 为 64 窗内最近（±32 牵引）；
- 每拍原子执行（§7.4）：自然步进总发生；装订/对齐同拍改写 tod/frac 不吞自然脉冲；
  装订拍 = 声明边界（tick + 网格 hop）；对齐"未发过才补发"声明边界脉冲
  （早检测防丢跳沿、晚检测防双跳沿；snap 不改 tod 的对齐拍不补发脉冲，相位仍重锚）。

数值不是 float：tick 计数、frac 全整数，位真由 sim_tod 与 RTL 逐拍比对锁定。
"""
from __future__ import annotations

from collections.abc import Iterable

TOD_TICK_SAMPLES = 8000        # 1 ms @ 8 MSPS（§7.1 冻结）
TOD_FIELD_W = 6                # 帧头 [29:24] 宽（§7.2 冻结）
TOD_DEFAULT_W = 32

# hop_ticks：1000 hop/s → 1、500 → 2、100 → 10；rate_sel 其余值按 1000（§7.1）
HOP_TICKS_TABLE = (1, 2, 10, 1)


def hop_ticks_of(rate_sel: int) -> int:
    """rate_sel → 每跳 tick 数（0:1000, 1:500, 2:100 hop/s，其余=1000）。"""
    return HOP_TICKS_TABLE[rate_sel & 0x3]


def snap_tod(align_tod: int, tod: int, tod_w: int = TOD_DEFAULT_W) -> int:
    """§7.4 snap：低 FIELD_W 位对齐到 A，高 26 位取 64 窗内最近（mod 2^tod_w）。"""
    mask = (1 << tod_w) - 1
    a = int(align_tod) & ((1 << TOD_FIELD_W) - 1)
    base = (int(tod) & mask) & ~((1 << TOD_FIELD_W) - 1)
    x = base | a
    d = (x - (int(tod) & mask) + (1 << (tod_w - 1))) & mask   # 有符号差（|d| ≤ 63）
    sd = d - (1 << (tod_w - 1))
    if sd > (1 << (TOD_FIELD_W - 1)):        # X − tod > 32
        x -= 1 << TOD_FIELD_W
    elif sd < -(1 << (TOD_FIELD_W - 1)):     # tod − X > 32
        x += 1 << TOD_FIELD_W
    return x & mask


def sim_tod(
    cmds: Iterable[tuple[int, int, int, int, int, int]],
    tick_samples: int = TOD_TICK_SAMPLES,
    tod_w: int = TOD_DEFAULT_W,
) -> list[tuple[int, int, int]]:
    """逐拍推进 TOD，返回有效拍输出 (tick, tod, hop_edge)。

    cmds 每项 = (din_valid, rate_sel, tod_load, align_valid, align_tod, tod_value)。
    din_valid=0 的拍整拍冻结（无输出）；返回行数 = 有效拍数（长度解耦契约）。
    """
    mask = (1 << tod_w) - 1
    tod = 0
    frac = 0
    out: list[tuple[int, int, int]] = []
    for din_valid, rate_sel, tod_load, align_valid, align_tod, tod_value in cmds:
        if not din_valid:
            continue
        hop_ticks = hop_ticks_of(int(rate_sel))
        tick = 0
        hop = 0

        # 1) 自然步进（总是发生）
        frac += 1
        if frac == tick_samples:
            frac = 0
            tod = (tod + 1) & mask
            tick = 1
            if tod % hop_ticks == 0:
                hop = 1

        # 2) 装订/对齐（同拍改写，不吞 1) 的自然脉冲）
        if tod_load:
            tod = int(tod_value) & mask
            frac = 0
            tick = 1                       # 装订 = 声明 tod 边界（无孤儿区间）
            if tod % hop_ticks == 0:
                hop = 1
        elif align_valid:
            a = snap_tod(align_tod, tod, tod_w)
            if tod != a:                      # 未发过才补发声明边界
                tick = 1
                if a % hop_ticks == 0:
                    hop = 1
            tod = a
            frac = 0

        out.append((tick, tod, hop))
    return out
