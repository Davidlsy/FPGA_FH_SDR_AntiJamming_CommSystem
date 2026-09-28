"""
S4 帧层黄金参考 —— m 序列 / Gold 同步字 / CRC-16 / 成帧与解析

这是 `frame_tx` 模块位真比对的**唯一裁判**：S4 之前全工程没有帧层，
任务卡要求的「Gold 同步字 + 帧头 + 256B + CRC16」在这里第一次被定义。
帧格式的冻结版本见 `docs/spec/frame_format.md`，参数取自 `config.py` 的
`FRAME_*` 常量（机器可读来源）。

为什么帧层不需要"定点化"：本层输入输出全部是比特，没有小数位、没有量化器，
浮点链与定点链在此完全重合，所以本模块可以直接拿来做位真基准——这不是
绕过《定点规格书》，而是该规格书 §2 里 `conv_encoder_out_w=2` 那类纯逻辑节点的
上游（比特级）等价物。

比特序约定（贯穿全工程）：
  · 比特流按 MSB-first 串行，即 `bytes_to_bits(b"\\x80")[0] == 1`；
  · 多比特字（帧头、CRC）同样 MSB-first 先出现。
"""
from __future__ import annotations

import numpy as np

from ..config import (
    FRAME_COVERED_BITS,
    FRAME_CRC_BITS,
    FRAME_CRC_INIT,
    FRAME_CRC_POLY,
    FRAME_HEADER_BITS,
    FRAME_HEADER_VERSION,
    FRAME_PAYLOAD_BYTES,
    FRAME_SYNC_LEN,
    FRAME_SYNC_M,
    FRAME_SYNC_POLY,
    FRAME_SYNC_SHIFT,
    FRAME_TOTAL_BITS,
)


# ============================================================
# m 序列与 Gold 同步字
# ============================================================
def _taps_of(poly: int, n: int) -> list[int]:
    """多项式掩码（bit i = x^i 项）→ 反馈抽头位号（不含最高项）。"""
    return [i for i in range(n) if (poly >> i) & 1]


def m_sequence(poly: int, n: int, state: int = 1) -> np.ndarray:
    """生成一个完整周期的 m 序列（长度 2^n - 1）。

    Fibonacci 结构：每拍输出寄存器 LSB，反馈为抽头位异或，反馈位进最高位。
    `state=1` 是常规起点（全零态是吸收态，不可用）。
    """
    taps = _taps_of(poly, n)
    reg = state & ((1 << n) - 1)
    out = np.empty((1 << n) - 1, dtype=np.int8)
    for i in range(out.size):
        out[i] = reg & 1
        fb = 0
        for t in taps:
            fb ^= (reg >> t) & 1
        reg = (reg >> 1) | (fb << (n - 1))
    return out


def gold_sync_word(poly_pair=None, m: int = None, length: int = None,
                   state: int = 1, shift: int = None) -> np.ndarray:
    """Gold 同步字：两个 m 序列优选对逐位异或（第二条先做相对位移）。

    级数取自 `FRAME_SYNC_POLY`（6 级：0o103 与 0o133，交叉相关集
    {-17, -1, 15}，即 n 为偶数时的 {-1, -1±2^(n/2+1)}，已数值验证）。

    相对位移 `FRAME_SYNC_SHIFT` 不是随手取的：两条序列若同状态起步，异或结果
    前 8 位会塌成全 0（m 序列开头是同一条 1,0,0,0,0,0 轨迹），对前导检测不利。
    按「最长同值游程最短 → 旁瓣最低 → 0/1 最平衡 → 位移最小」遍历 63 个相位后
    冻结 shift=24（游程 4、max|R|=16、恰 32 个 1）。

    Gold 周期为 2^m - 1 = 63，比任务卡的 64 少 1 位，故 `length=64` 时取
    「63 位周期 + 首位重复」；该重复只让非峰值相关浮动 ±1（相对主峰 64 无实质
    影响），换取了同步字长度与任务卡一致。
    """
    poly_pair = poly_pair or FRAME_SYNC_POLY
    m = m or FRAME_SYNC_M
    length = length or FRAME_SYNC_LEN
    shift = FRAME_SYNC_SHIFT if shift is None else shift

    a = m_sequence(poly_pair[0], m, state)
    b = np.roll(m_sequence(poly_pair[1], m, state), shift)
    period = a ^ b

    if length <= period.size:
        return period[:length].copy()
    reps = length // period.size
    tail = length - reps * period.size
    return np.concatenate([np.tile(period, reps), period[:tail]]).astype(np.int8)


# ============================================================
# 比特/字节/整数 包装
# ============================================================
def int_to_bits(value: int, width: int) -> np.ndarray:
    """整数 → 定宽比特数组（MSB-first）。"""
    return np.array([(value >> (width - 1 - i)) & 1 for i in range(width)], dtype=np.int8)


def bits_to_int(bits) -> int:
    """定宽比特数组（MSB-first）→ 整数。"""
    value = 0
    for b in np.asarray(bits).ravel():
        value = (value << 1) | (int(b) & 1)
    return value


def bytes_to_bits(data) -> np.ndarray:
    """字节序列 → 比特数组（每字节 MSB-first）。"""
    raw = np.frombuffer(bytes(data), dtype=np.uint8)
    return np.unpackbits(raw).astype(np.int8)


def bits_to_bytes(bits) -> bytes:
    """比特数组（MSB-first，长度须为 8 的整数倍）→ 字节序列。"""
    bits = np.asarray(bits, dtype=np.uint8)
    if bits.size % 8:
        raise ValueError(f"比特数 {bits.size} 不是 8 的整数倍，无法还原为字节")
    return np.packbits(bits).tobytes()


# ============================================================
# CRC-16/CCITT-FALSE
# ============================================================
# 两条相互独立的实现：位串行 LFSR（与 RTL 实现同构）与 8-bit 查表（与
# "123456789" 标准测试向量对齐）。二者互为交叉校验，见 sim/check_framing.py。
# ============================================================
def crc16_bitwise(bits) -> int:
    """位串行 CRC-16/CCITT-FALSE：MSB-first 逐位进 LFSR，返回 16 bit 余数。

    这是一般形式的"逐位"计算；对整字节输入与 `crc16_table` 结果相同。
    """
    crc = FRAME_CRC_INIT
    for b in np.asarray(bits).ravel():
        if ((crc >> 15) & 1) ^ (int(b) & 1):
            crc = ((crc << 1) ^ FRAME_CRC_POLY) & 0xFFFF
        else:
            crc = (crc << 1) & 0xFFFF
    return crc


def _crc_table() -> np.ndarray:
    table = np.zeros(256, dtype=np.uint16)
    for byte in range(256):
        crc = byte << 8
        for _ in range(8):
            crc = (((crc << 1) ^ FRAME_CRC_POLY) if crc & 0x8000 else (crc << 1)) & 0xFFFF
        table[byte] = crc
    return table


_CRC_TABLE = _crc_table()


def crc16_table(data) -> int:
    """8-bit 查表 CRC-16/CCITT-FALSE（初值 FFFF、不反序、无终值异或）。"""
    crc = FRAME_CRC_INIT
    for byte in bytes(data):
        crc = ((crc << 8) & 0xFFFF) ^ int(_CRC_TABLE[((crc >> 8) ^ byte) & 0xFF])
    return crc


# ============================================================
# 成帧
# ============================================================
def header_word(frame_no: int = 0, version: int = None,
                payload_bytes: int = None) -> int:
    """帧头 32 bit: [31:30] 版本 | [29:24] 保留 | [23:16] 帧号 | [15:0] 载荷字节数。"""
    version = FRAME_HEADER_VERSION if version is None else version
    payload_bytes = FRAME_PAYLOAD_BYTES if payload_bytes is None else payload_bytes
    return (((version & 0x3) << 30)
            | ((frame_no & 0xFF) << 16)
            | (payload_bytes & 0xFFFF))


def frame_offsets() -> dict[str, slice]:
    """帧内各字段的比特区间（左闭右开），供 TB 与报告引用（避免各处重复算偏移）。"""
    sync_end = FRAME_SYNC_LEN
    header_end = sync_end + FRAME_HEADER_BITS
    payload_end = header_end + FRAME_PAYLOAD_BYTES * 8
    return {
        "sync": slice(0, sync_end),
        "header": slice(sync_end, header_end),
        "payload": slice(header_end, payload_end),
        "crc": slice(payload_end, payload_end + FRAME_CRC_BITS),
    }


def build_frame_bits(payload, frame_no: int = 0, version: int = None) -> np.ndarray:
    """成帧：Gold 同步字 → 帧头 → 载荷 → CRC16，返回定长比特数组。

    payload: 长度为 `FRAME_PAYLOAD_BYTES` 的字节序列（bytes / bytearray / uint8 数组）。
    CRC 覆盖帧头 + 载荷（`FRAME_COVERED_BITS` = 2080 bit = 260 byte），不含同步字。
    """
    raw = bytes(payload)
    if len(raw) != FRAME_PAYLOAD_BYTES:
        raise ValueError(f"载荷长度 {len(raw)} != FRAME_PAYLOAD_BYTES {FRAME_PAYLOAD_BYTES}")

    sync_bits = gold_sync_word()
    head_bits = int_to_bits(header_word(frame_no, version), FRAME_HEADER_BITS)
    pay_bits = bytes_to_bits(raw)

    covered = np.concatenate([head_bits, pay_bits])
    assert covered.size == FRAME_COVERED_BITS
    crc_bits = int_to_bits(crc16_bitwise(covered), FRAME_CRC_BITS)

    frame = np.concatenate([sync_bits, head_bits, pay_bits, crc_bits]).astype(np.int8)
    assert frame.size == FRAME_TOTAL_BITS, f"帧长 {frame.size} != {FRAME_TOTAL_BITS}"
    return frame


def parse_frame_bits(bits) -> dict:
    """反向解析帧比特流：字段还原 + CRC 独立重算校验。

    返回 dict: {sync_ok, version, frame_no, payload_bytes, payload, crc_rx,
                crc_calc, crc_ok}。用于负例（注错必须被检出）与自检。
    """
    bits = np.asarray(bits, dtype=np.int8)
    if bits.size != FRAME_TOTAL_BITS:
        raise ValueError(f"帧长 {bits.size} != FRAME_TOTAL_BITS {FRAME_TOTAL_BITS}")

    off = frame_offsets()
    sync_rx = bits[off["sync"]]
    head = bits_to_int(bits[off["header"]])
    payload = bits_to_bytes(bits[off["payload"]])
    crc_rx = bits_to_int(bits[off["crc"]])
    crc_calc = crc16_bitwise(np.concatenate([bits[off["header"]], bits[off["payload"]]]))

    return {
        "sync_ok": bool(np.array_equal(sync_rx, gold_sync_word())),
        "version": (head >> 30) & 0x3,
        "frame_no": (head >> 16) & 0xFF,
        "payload_bytes": head & 0xFFFF,
        "payload": payload,
        "crc_rx": crc_rx,
        "crc_calc": crc_calc,
        "crc_ok": crc_rx == crc_calc,
    }
