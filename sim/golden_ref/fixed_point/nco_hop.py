"""S6 定点 nco_hop：信道 → FTW 查表 + 相位连续跳频 NCO

docs/spec/s6_fh_interface.md §5 的位真裁判，语义与 RTL 逐条同构：

  - FTW 表（§5.1）: FTW[k] = (2k+1) * 1024，k = 0..15（奇数倍 1024，均匀 fs/32）；
  - 每拍（din_valid=1）原子执行（§5.2）:
        out ← LUT(phase)         # FixedNCO.step 口径：输出当前相位再步进
        phase ← phase + ftw      # 16 bit 自然回绕，只加不清零
        if hop: ftw ← FTW[ch]    # 换字不清相位；本拍步进仍用旧 ftw
  - din_valid=0 整拍冻结（phase/ftw 保持，无输出）。

NCO 核（16 bit 相位 / Q2.14 四分之一波 LUT / cos(p)=sin(p+2^14)）逐项复用
fixed_point.duc 已验证口径——S4 srrc_duc 的 NCO 就是按这套语义过的位真。
"""
from __future__ import annotations

from .duc import _sin_int, gen_sin_lut

# FTW 表（s6_fh_interface.md §5.1 冻结值）: (2k+1) * 2^10
NCO_HOP_FTW_TABLE = tuple((2 * k + 1) << 10 for k in range(16))

NCO_PHASE_W = 16
NCO_LUT_W = 16
NCO_LUT_FRAC = 14


def _check_channel(ch: int) -> int:
    if not isinstance(ch, int) or not 0 <= ch <= 15:
        raise ValueError(f"channel 必须是 0..15 的整数，收到 {ch!r}")
    return ch


def sim_nco_hop(cmds, ftw_table=NCO_HOP_FTW_TABLE, lut_int=None):
    """逐拍仿真 nco_hop。

    参数:
      cmds: 每拍 (din_valid, hop_valid, channel) 三元组序列；
            din_valid=0 的拍冻结，hop/channel 无意义。
      ftw_table: 信道 → FTW 查表（16 项，仅测试替用；默认冻结表）。
      lut_int: 复用的四分之一波 LUT 整数值；None 现场生成。

    返回: 每个 din_valid=1 的拍一个 (phase, cos_int, sin_int)：
      phase   —— 输出拍的相位累加器值（16 bit，步进前）
      cos_int/sin_int —— Q2.14 补码整数（与 nco_lut.mem 同刻度）
    """
    mask = (1 << NCO_PHASE_W) - 1
    lut = gen_sin_lut(NCO_PHASE_W)[1] if lut_int is None else lut_int

    phase = 0
    ftw = 0
    out = []
    for din_valid, hop_valid, channel in cmds:
        if not din_valid:
            continue
        s = _sin_int(phase, lut, NCO_PHASE_W)
        c = _sin_int(phase + (1 << (NCO_PHASE_W - 2)), lut, NCO_PHASE_W)
        out.append((phase, int(c), int(s)))
        phase = (phase + ftw) & mask
        if hop_valid:
            ftw = int(ftw_table[_check_channel(channel)]) & mask
    return out
