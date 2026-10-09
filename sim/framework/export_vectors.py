#!/usr/bin/env python3
"""S2 比对框架 · golden 向量导出器

把 S1 定点参考模型（sim/golden_ref）转成 xsim 可直接 $readmemh 的十六进制向量：

    vectors/<module>/<case>_stim.hex      每行一个输入总线值
    vectors/<module>/<case>_expect.hex    与 stim 逐行对应的期望输出总线值
    vectors/<module>/<case>_meta.json     位宽 / 打包规则 / 种子 / 样本数

位宽、小数位一律取自 golden_ref.config.FIXED_POINT_CONFIG（即 docs/spec/
fixed_point_spec.md 的机器可读来源），本文件不硬编码任何位宽。

stim 与 expect 的**行数互不约束**（S4-P0 起）：前者是驱动节拍数，后者是比对长度。
成帧（256 拍 → 2160 拍）、上采样、交织补零这类 N:M 模块因此不需要把形状凑成一比一。

长跑用例（frame_tx/long、conv_enc/long）体积过大且可由固定种子确定性重生成，
默认不生成、不入库；`--full` 或 `--case long` 才产出，权威验收脚本据此跑满判据。

向量格式与 TB 时序契约见 sim/framework/README.md，比对器见 hdl/tb_vec_cmp.sv。
新增模块：在 MODULES 里加一条 `cases` + `export` 即可，S4 剩余的 blk_inter /
srrc_duc 依次照此接入。
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parents[1]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

import numpy as np
from golden_ref import __version__ as GOLDEN_REF_VERSION
from golden_ref.config import (
    FIXED_POINT_CONFIG,
    FRAME_PAYLOAD_BYTES,
    FRAME_TOTAL_BITS,
    RX_CONFIG,
)
from golden_ref.fixed_point.duc import fixed_srrc_duc
from golden_ref.fixed_point.fixed_modules import (
    fixed_pulse_shape,
    fixed_qpsk_modulate,
)
from golden_ref.fixed_point.rx_modules import (
    fixed_ddc_rx,
    fixed_sync_rx_hw,
    fixed_viterbi_hw,
    rx_adc_quantize,
    soft_deinterleave,
    upsample_bandlimited,
)
from golden_ref.calib_sync_rx import impair, mk_mf_int
from golden_ref.float_chain.conv_encoder import conv_encode
from golden_ref.float_chain.framing import build_frame_bits
from golden_ref.float_chain.interleaver import block_interleave

FRAMEWORK_DIR = Path(__file__).resolve().parent
DEFAULT_OUT = FRAMEWORK_DIR / "vectors"
DEFAULT_SEED = 20260924

# conv_enc 的块长固定为帧长（= 链路里的真实取值，见 docs/spec/s4_tx_interface.md §4.2）。
# 10⁶ bit 判据按整块堆叠表达：463 × 2160 = 1,000,080 bit ≥ 10⁶，
# 而不是用一个 10⁶ 比特的单块——blk_len 是 16 bit，装不下。
CONV_BLK_BITS = FRAME_TOTAL_BITS

# 长跑用例（frame_tx/long、conv_enc/long）体积过大且可由固定种子确定性重生成，
# 按 .gitignore 的约定不入库，只在权威验收（run_s4_acceptance.ps1 -Full）时生成。
LONG_CASES = {"long"}


# ============================================================
# 定点 → 十六进制
# ============================================================
def to_int(value: float, width: int, frac: int) -> int:
    """把 S1 定点模型的输出精确还原为补码整数。

    golden_ref.quantizer 的返回值恒落在 int/2**frac 这一格点上，所以这里 round
    回整数是无损的；同时校验格点与位宽范围，避免向量静默溢出或被悄悄截断。
    """
    scaled = float(value) * (1 << frac)
    nearest = int(round(scaled))
    if abs(scaled - nearest) > 1e-6:
        raise ValueError(f"{value} 不在 {frac} 位小数格点上（偏移 {scaled - nearest:.3e}）")
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    if not lo <= nearest <= hi:
        raise ValueError(f"{nearest} 超出 {width} bit 补码范围 [{lo}, {hi}]")
    return nearest


def hex_of_int(value: int, width: int) -> str:
    """补码整数 → 定宽十六进制（无 0x 前缀，xsim $readmemh 按位宽左填充）。"""
    return format(value & ((1 << width) - 1), f"0{(width + 3) // 4}x")


def pack_fields(*fields: tuple[int, int]) -> int:
    """按高位在前打包若干 (整数, 位宽) 字段。"""
    out = 0
    for value, width in fields:
        out = (out << width) | (value & ((1 << width) - 1))
    return out


# ============================================================
# qpsk_map
# ============================================================
def _qpsk_map_cases(seed: int):
    """返回 [(用例名, 载荷, 用例说明)]；载荷为 (i_bit, q_bit) 列表。

    比特序号沿用 golden_ref 约定：偶位为 I、奇位为 Q，故一个符号即 (I, Q)。
    """
    rng = np.random.default_rng(seed)
    n_rand = 4096
    rand_bits = rng.integers(0, 2, size=2 * n_rand)
    rand_syms = list(zip(rand_bits[0::2].tolist(), rand_bits[1::2].tolist()))

    edge_syms = [(0, 0), (1, 1), (0, 1), (1, 0)]   # 四星座点，首拍即复位后第一个符号
    edge_syms += [(0, 0)] * 64                     # 全 0 载荷连续段
    edge_syms += [(1, 1)] * 64                     # 全 1 载荷连续段
    edge_syms += [(0, 0), (1, 1)] * 32             # 最坏码型交替

    return [
        ("rand", rand_syms, f"长随机序列 {n_rand} 符号（default_rng(seed={seed})）"),
        ("edge", edge_syms, "边界用例：四星座点 + 全 0/全 1 连续段 + 最坏码型交替"),
    ]


def _export_qpsk_map(syms, seed: int):
    cfg = FIXED_POINT_CONFIG
    w, frac = cfg["qpsk_out_w"], cfg["qpsk_out_frac"]

    bits = np.array([b for pair in syms for b in pair], dtype=np.int8)
    sym_q = fixed_qpsk_modulate(bits)
    if len(sym_q) != len(syms):
        raise RuntimeError(f"参考模型输出符号数 {len(sym_q)} != 载荷 {len(syms)}")

    stim_hex, expect_hex = [], []
    for (i_bit, q_bit), s in zip(syms, sym_q):
        stim_hex.append(hex_of_int(pack_fields((i_bit, 1), (q_bit, 1)), 2))
        expect_hex.append(
            hex_of_int(
                pack_fields(
                    (to_int(s.real, w, frac), w),
                    (to_int(s.imag, w, frac), w),
                ),
                2 * w,
            )
        )

    meta = {
        "stim": {"bits": 2, "packing": "{i_bit, q_bit}", "frac": None},
        "expect": {
            "bits": 2 * w,
            "packing": "{i_out[11:0], q_out[11:0]}",
            "field_bits": w,
            "field_frac": frac,
        },
    }
    return stim_hex, expect_hex, meta


# ============================================================
# frame_tx
# ============================================================
def _frame_payloads(rng, n: int):
    return [rng.integers(0, 256, FRAME_PAYLOAD_BYTES, dtype=np.uint8).tobytes() for _ in range(n)]


def _frame_tx_cases(seed: int):
    """用例的"块"= 一帧：256 拍载荷进，2160 拍比特出。

    帧号随帧序递增（0 起），所以多帧用例同时覆盖了帧号字段与背靠背帧边界。
    """
    rng = np.random.default_rng(seed)
    edge = [
        b"\x00" * FRAME_PAYLOAD_BYTES,
        b"\xff" * FRAME_PAYLOAD_BYTES,
        bytes(0xAA if i % 2 == 0 else 0x55 for i in range(FRAME_PAYLOAD_BYTES)),
        b"\x00" * (FRAME_PAYLOAD_BYTES - 1) + b"\x01",   # 末字节仅 LSB 为 1
    ]
    return [
        ("single", _frame_payloads(rng, 1), "单帧随机载荷：复位后首帧、帧号 0"),
        ("multi", _frame_payloads(rng, 8), "8 帧背靠背随机载荷：覆盖帧号递增与帧边界"),
        ("edge", edge, "边界载荷：全 0 / 全 0xFF / 0xAA-0x55 交替 / 末字节单比特"),
        ("long", _frame_payloads(rng, 1000), "1000 随机帧（任务卡判据；体积大，不入库）"),
    ]


def _export_frame_tx(payloads, seed: int):
    stim_hex, expect_hex = [], []
    for frame_no, payload in enumerate(payloads):
        stim_hex += [hex_of_int(b, 8) for b in payload]
        expect_hex += [hex_of_int(int(x), 1) for x in build_frame_bits(payload, frame_no=frame_no)]

    meta = {
        "stim": {"bits": 8, "packing": "载荷字节（每帧 256 个）", "frac": None},
        "expect": {"bits": 1, "packing": "帧比特流：同步字64→帧头32→载荷2048→CRC16", "frac": None},
        "frames": len(payloads),
        # 载荷 1 字节 / 9 拍：满足接口规格 §4.1 的"平均每字节 ≥ 8.44 拍"约束。
        # TB 必须把 tb_vec_cmp 的 STIM_PERIOD 设成同一个值（见 tb_frame_tx_*.sv）。
        "stim_period": 9,
    }
    return stim_hex, expect_hex, meta


# ============================================================
# conv_enc
# ============================================================
def _conv_enc_cases(seed: int):
    """用例的"块"= 一个编码块，块长固定为帧长（链路里的真实取值）。"""
    rng = np.random.default_rng(seed)

    def rand_blk():
        return rng.integers(0, 2, CONV_BLK_BITS).astype(np.int8)

    edge = [
        np.zeros(CONV_BLK_BITS, dtype=np.int8),
        np.ones(CONV_BLK_BITS, dtype=np.int8),
        np.tile(np.array([0, 1], dtype=np.int8), CONV_BLK_BITS // 2),
        np.concatenate([[1], np.zeros(CONV_BLK_BITS - 1, dtype=np.int8)]),
    ]
    return [
        ("frame", [rand_blk()], f"单块随机信息位（块长 = 帧长 {CONV_BLK_BITS}）"),
        ("rand", [rand_blk() for _ in range(8)], "8 块背靠背随机：覆盖块边界与尾比特"),
        ("edge", edge, "边界：全 0 / 全 1 / 交替 / 首位单 1（寄存器归零路径）"),
        ("long", [rand_blk() for _ in range(463)],
         "463 块 = 1,000,080 bit（任务卡 10⁶ bit 判据；体积大，不入库）"),
    ]


def _export_conv_enc(blocks, seed: int):
    stim_hex, expect_hex = [], []
    for blk in blocks:
        blk = np.asarray(blk, dtype=np.int8)
        stim_hex += [hex_of_int(int(b), 1) for b in blk]

        enc = conv_encode(blk)
        if len(enc) != 2 * (len(blk) + 6):
            raise RuntimeError(f"参考编码输出 {len(enc)} != 2*({len(blk)}+6)")

        # 每拍输出一个符号 {g1, g2}——与接口规格 §4.2 的 dout_data[1:0] 一致
        for k in range(0, len(enc), 2):
            expect_hex.append(hex_of_int(pack_fields((int(enc[k]), 1), (int(enc[k + 1]), 1)), 2))

    meta = {
        "stim": {"bits": 1, "packing": "信息比特，MSB-first", "frac": None},
        "expect": {"bits": 2, "packing": "{g1, g2}（先 g1 后 g2）", "frac": None},
        "blk_len": CONV_BLK_BITS,
        "blocks": len(blocks),
    }
    return stim_hex, expect_hex, meta


# ============================================================
# blk_inter
# ============================================================
# 一块 = 一帧的编码输出：2160 帧比特 + 6 归零尾比特 = 4332 bit = 2166 拍（2 bit/拍）。
# 交织后 10 × 434 = 4340 bit = 2170 拍，尾部补零 8 bit。
BLK_IN_BITS = 2 * (FRAME_TOTAL_BITS + 6)


def _blk_inter_cases(seed: int):
    """用例载荷是 (块列表, 激励节奏) —— 节奏随用例变，故随载荷一起传给导出器。

    `frame` 用例用真实的编码帧比特（conv_enc 的输出）当激励，让模块级位真比对
    与链路里跑的是同一种数据；后两个用例的节奏放到 1/2，因为交织器一块要吃
    2166 拍数据、块周期 2171 拍，连续满速灌多块会累积出超出弹性缓冲的节拍差
    （见接口规格 §4.3 的速率约束）。
    """
    rng = np.random.default_rng(seed)

    payload = rng.integers(0, 256, FRAME_PAYLOAD_BYTES, dtype=np.uint8).tobytes()
    coded_frame = conv_encode(build_frame_bits(payload, frame_no=0))

    def rand_block():
        return rng.integers(0, 2, BLK_IN_BITS).astype(np.int8)

    edge = [
        np.zeros(BLK_IN_BITS, dtype=np.int8),
        np.ones(BLK_IN_BITS, dtype=np.int8),
        np.tile(np.array([0, 1], dtype=np.int8), BLK_IN_BITS // 2),
        np.concatenate([[1], np.zeros(BLK_IN_BITS - 1, dtype=np.int8)]),
    ]

    return [
        ("frame", ([coded_frame], 1), "1 块 = 一帧的编码输出（真实链路激励）"),
        ("rand", ([rand_block() for _ in range(8)], 2), "8 块随机比特背靠背（节奏 1/2）"),
        ("edge", (edge, 2), "边界块：全 0 / 全 1 / 交替 / 首位单 1（节奏 1/2）"),
    ]


def _export_blk_inter(payload, seed: int):
    blocks, stim_period = payload
    stim_hex, expect_hex = [], []

    for blk in blocks:
        blk = np.asarray(blk, dtype=np.int8)
        inter = block_interleave(blk)
        if len(inter) % 2:
            raise RuntimeError(f"交织输出 {len(inter)} bit 不是 2 的整数倍")

        # 一拍一个符号：stim = {b[2k], b[2k+1]}，expect = {interleaved[2m], interleaved[2m+1]}
        for k in range(0, len(blk), 2):
            stim_hex.append(hex_of_int(pack_fields((int(blk[k]), 1), (int(blk[k + 1]), 1)), 2))
        for m in range(0, len(inter), 2):
            expect_hex.append(hex_of_int(pack_fields((int(inter[m]), 1), (int(inter[m + 1]), 1)), 2))

    n_col = (len(blocks[0]) + 9) // 10
    meta = {
        "stim": {"bits": 2, "packing": "{I, Q}（I 是靠前那个比特）", "frac": None},
        "expect": {"bits": 2, "packing": "列优先读出后的 {I, Q}", "frac": None},
        "blocks": len(blocks),
        "block_bits": len(blocks[0]),
        "matrix": {"depth": 10, "cols": n_col, "pad_bits": 10 * n_col - len(blocks[0])},
        "stim_period": stim_period,
    }
    return stim_hex, expect_hex, meta


# ============================================================
# srrc_duc
# ============================================================
# 一块 = 一帧的符号流：blk_inter 输出 2170 符号 → SRRC 上采样 ×4 + full 卷积 → 8712 采样
# （4N+32，见 docs/spec/s4_tx_p3_freeze_draft.md 决策 1.5 ①）
SRRC_N_SYMS = 2170


def _srrc_duc_cases(seed: int):
    """用例的"块"= 一帧符号（2170 个）；激励节奏 STIM_PERIOD=4（符号 1/4 节奏进）。"""
    rng = np.random.default_rng(seed)

    def rand_syms(n):
        bits = rng.integers(0, 2, size=2 * n, dtype=np.int8)
        return fixed_qpsk_modulate(bits)

    edge_bits = np.zeros(2 * SRRC_N_SYMS, dtype=np.int8)
    edge_bits[0:8] = [0, 0, 1, 1, 0, 1, 1, 0]      # 四星座点 00/11/01/10
    edge_bits[16:272] = 0                            # 全 0 连续段（→ +724+724j）
    edge_bits[512:768] = 1                           # 全 1 连续段（→ −724−724j）
    edge_syms = fixed_qpsk_modulate(edge_bits)

    return [
        ("frame", [rand_syms(SRRC_N_SYMS)], "1 帧 2170 符号 → 8712 采样（full 卷积 4N+32）"),
        ("edge", [edge_syms], "边界：四星座点 + 全 0/全 1 连续段"),
    ]


def _export_srrc_duc(payload, seed: int):
    sym_blocks = payload
    stim_hex, expect_hex = [], []
    for syms in sym_blocks:
        syms = np.asarray(syms)
        for s in syms:
            stim_hex.append(hex_of_int(
                pack_fields((to_int(s.real, 12, 10), 12), (to_int(s.imag, 12, 10), 12)), 24))

        i_out, q_out = fixed_srrc_duc(syms)
        if len(i_out) != 4 * len(syms) + 32:
            raise RuntimeError(f"参考 DUC 输出 {len(i_out)} != 4*{len(syms)}+32")
        for i, q in zip(i_out, q_out):
            expect_hex.append(hex_of_int(
                pack_fields((to_int(i, 16, 11), 16), (to_int(q, 16, 11), 16)), 32))

    meta = {
        "stim": {"bits": 24, "packing": "{i_in[11:0], q_in[11:0]}", "frac": 10},
        "expect": {"bits": 32, "packing": "{i_out[15:0], q_out[15:0]}", "frac": 11},
        "sym_rows": len(sym_blocks[0]),
        "stim_period": 4,
        "upsample": 4,
        "num_taps": 33,
    }
    return stim_hex, expect_hex, meta


# ============================================================
# tx_chain（S4-P5 整链端到端）
# ============================================================
def _tx_chain_cases(seed: int):
    """用例的"块"= 一帧端到端：256 载荷字节 → 五模块串联 → 8712 采样。

    golden 链路与 RTL 逐级同构：
      build_frame_bits → conv_encode → block_interleave → fixed_qpsk_modulate → fixed_srrc_duc
    （2160 bit → 4332 bit → 4340 bit → 2170 符号 → 8712 采样）。
    """
    rng = np.random.default_rng(seed)
    rand_payload = rng.integers(0, 256, FRAME_PAYLOAD_BYTES, dtype=np.uint8).tobytes()
    return [
        ("frame", [rand_payload],
         "单帧随机载荷端到端：256 字节 → 2160 bit → 4332 bit → 4340 bit → 2170 符号 → 8712 采样"),
        ("edge", [b"\x00" * FRAME_PAYLOAD_BYTES], "边界载荷（全 0）端到端"),
    ]


def _export_tx_chain(payloads, seed: int):
    stim_hex, expect_hex = [], []
    for frame_no, payload in enumerate(payloads):
        stim_hex += [hex_of_int(b, 8) for b in payload]

        bits = build_frame_bits(payload, frame_no=frame_no)
        coded = conv_encode(bits)
        inter = block_interleave(coded)
        syms = fixed_qpsk_modulate(inter)
        i_out, q_out = fixed_srrc_duc(syms)
        if len(i_out) != 4 * len(syms) + 32:
            raise RuntimeError(f"参考 DUC 输出 {len(i_out)} != 4*{len(syms)}+32")
        for i, q in zip(i_out, q_out):
            expect_hex.append(hex_of_int(
                pack_fields((to_int(i, 16, 11), 16), (to_int(q, 16, 11), 16)), 32))

    meta = {
        "stim": {"bits": 8, "packing": "载荷字节（每帧 256 个）", "frac": None},
        "expect": {"bits": 32, "packing": "{i_out[15:0], q_out[15:0]}", "frac": 11},
        "frames": len(payloads),
        # 载荷 1 字节 / 9 拍：满足接口规格 §4.1 的 ≥8.44 拍/字节速率约束
        "stim_period": 9,
    }
    return stim_hex, expect_hex, meta


# ============================================================
# 接收链（S5）：ddc_rx / blk_deinter / viterbi_dec
# ============================================================
# 接收链是发射链的逆（见 docs/spec/s5_rx_interface.md §2/§3）。位真裁判来自
# sim/golden_ref/fixed_point/rx_modules.py。
#
# sync_rx 的环路系数已按 #3 标定**冻结**（config.RX_CONFIG 的 Q1.19 值），故向量是
# 冻结参考而非草稿；信号构造与标定器共用 golden_ref/calib_sync_rx.py 的 mk_mf_int /
# impair（同一套损伤模型，不另抄一份）。
RX_DECIM = RX_CONFIG["cic_decim"]
# 接收链软判决 8bit/5 小数（S1 冻结）；理想强软值取 ±3.5（满量程 3.96875，避免饱和）
RX_SOFT_STRONG = 3.5
# ddc_rx 的激励行数 = D × (4·N+32)。取 N=2000 使 32128 行 < tb_vec_cmp 缺省 MAX_DEPTH(32768)，
# 开箱即用；若要跑整帧 2170 符号（34848 行），TB 需显式调大 MAX_DEPTH。
DDC_N_SYM = 2000


def _rx_adc_input(syms):
    """4 sps 成形信号 → f_adc 的 ADC 输入（带限上采样 ×D，AGC 到 ±0.9 满量程内）。

    带限（FFT）上采样而非零插值：零插值不是真实过采样，会把 CIC 的增益/下垂测错。
    AGC 按**峰值**归一，故弱信号段与强信号段的相对电平（如 −60 dB）被保留。
    """
    shaped = fixed_pulse_shape(syms)
    peak = float(np.max(np.abs(shaped)))
    return upsample_bandlimited(shaped / peak * 0.9, RX_DECIM)


def _rx_frame_soft(seed: int):
    """一帧的码流与其「交织序理想软值」（blk_deinter / viterbi_dec 共用）。

    返回 (coded, interleaved_bits, soft_interleaved)：
      coded            4332 hard bits（conv_encode 输出）
      interleaved_bits 4340 bit（block_interleave 补零后）
      soft_interleaved 4340 个 8bit/5 小数软值（bit0 → +3.5、bit1 → −3.5）
    """
    rng = np.random.default_rng(seed)
    payload = rng.integers(0, 256, FRAME_PAYLOAD_BYTES, dtype=np.uint8).tobytes()
    bits = build_frame_bits(payload, frame_no=0)
    coded = conv_encode(bits)
    inter = block_interleave(coded)
    soft = np.where(inter == 0, RX_SOFT_STRONG, -RX_SOFT_STRONG)
    return coded, inter, soft


def _pack_soft_pair(soft):
    """两个 8bit 软值打包成一个 16bit 字（高位在前）——与发射侧 2bit/符号同序。"""
    sw = FIXED_POINT_CONFIG["viterbi_metric_w"]
    sf = FIXED_POINT_CONFIG["viterbi_metric_frac"]
    out = []
    for k in range(0, len(soft) - 1, 2):
        out.append(hex_of_int(
            pack_fields((to_int(soft[k], sw, sf), sw), (to_int(soft[k + 1], sw, sf), sw)), 2 * sw))
    return out


def _ddc_rx_cases(seed: int):
    rng = np.random.default_rng(seed)
    rand_syms = fixed_qpsk_modulate(rng.integers(0, 2, 2 * DDC_N_SYM, dtype=np.int8))

    # edge：四星座点 + 一段 −60 dB 弱信号（动态范围用例；峰值由强符号段决定，
    #       故归一化不会把弱段抬回来，二者相对电平保持 −60 dB）
    edge_bits = np.zeros(2 * 64, dtype=np.int8)
    edge_bits[0:8] = [0, 0, 1, 1, 0, 1, 1, 0]
    edge_syms = fixed_qpsk_modulate(edge_bits).copy()
    edge_syms[32:] *= 1e-3

    return [
        ("rand", [rand_syms],
         f"{DDC_N_SYM} 符号成形（4 sps）→ 带限上采样 ×{RX_DECIM} 到 f_adc → CIC 抽取 + 匹配 FIR"),
        ("edge", [edge_syms], "边界：四星座点 + −60 dB 弱信号段（动态范围）"),
    ]


def _export_ddc_rx(payload, seed: int):
    stim_hex, expect_hex = [], []
    aw = RX_CONFIG["adc_in_w"]
    ow = FIXED_POINT_CONFIG["srrc_out_w"]
    of = FIXED_POINT_CONFIG["srrc_out_frac"]
    for syms in payload:
        adc = _rx_adc_input(np.asarray(syms))
        # 激励写模型内部的**同一批 ADC 整数**（±2048 ↔ ±1.0），不另写一份量化
        i_int, q_int = rx_adc_quantize(adc)
        for i, q in zip(i_int, q_int):
            stim_hex.append(hex_of_int(pack_fields((int(i), aw), (int(q), aw)), 2 * aw))
        out, _ = fixed_ddc_rx(adc)
        for s in out:
            expect_hex.append(hex_of_int(
                pack_fields((to_int(s.real, ow, of), ow), (to_int(s.imag, ow, of), ow)), 2 * ow))
    meta = {
        "stim": {"bits": 2 * aw, "packing": "{i[11:0], q[11:0]}", "frac": aw - 1,
                 "rate": f"f_adc = {RX_DECIM} × 2 MSPS"},
        "expect": {"bits": 2 * ow, "packing": "{i[13:0], q[13:0]}", "frac": of, "rate": "4 sps"},
        "decim": RX_DECIM,
        "cic_stages": RX_CONFIG["cic_stages"],
        "cic_diff_delay": RX_CONFIG["cic_diff_delay"],
        "stim_period": 1,
        "max_depth_hint": "stim 行数须 ≤ tb_vec_cmp 的 MAX_DEPTH（缺省 32768）",
    }
    return stim_hex, expect_hex, meta


def _blk_deinter_cases(seed: int):
    # 用例载荷 = 一个种子列表，每个种子出一帧软判决码流（2170 拍进 → 2166 拍出）。
    # rand 多帧背靠背验证乒乓双缓冲与块边界：输出 2166 < 输入 2170，双缓冲天然追得上。
    return [
        ("frame", [seed], "一帧软判决码流 4340 → 4332（逆 blk_inter 置换 + 去 8bit 补零）"),
        ("rand", [seed + k for k in range(4)],
         "4 帧背靠背 17360 → 17328（乒乓双缓冲连续流式，覆盖块边界）"),
    ]


def _export_blk_deinter(payload, seed: int):
    stim_hex, expect_hex = [], []
    for sd in payload:
        _, _, soft = _rx_frame_soft(sd)
        out = soft_deinterleave(soft, n_out=len(soft) - 8)
        stim_hex += _pack_soft_pair(soft)
        expect_hex += _pack_soft_pair(out)
    sw = FIXED_POINT_CONFIG["viterbi_metric_w"]
    sf = FIXED_POINT_CONFIG["viterbi_metric_frac"]
    meta = {
        "stim": {"bits": 2 * sw, "packing": "{soft[2k], soft[2k+1]}", "frac": sf},
        "expect": {"bits": 2 * sw, "packing": "{soft[2k], soft[2k+1]}", "frac": sf},
        "depth": 10,
        "note": "输入 4340 个软值 / 输出 4332 个（去发射侧补的 8 bit）",
        "stim_period": 1,
    }
    return stim_hex, expect_hex, meta


def _viterbi_dec_cases(seed: int):
    # 用例载荷 = (种子, 软值风格) 列表，每个元素出一帧（2166 拍进 → 2160 bit 出）。
    # rand 4 帧背靠背：打「帧尾补吐与下一帧 ACS 并行」的重叠与帧界清零；
    # noise/edge 让 PM 归一化、16 bit 饱和、ACS 并列取舍真正受力——理想软值谁都能对。
    return [
        ("frame", [(seed, "ideal")],
         "一帧理想软值 4332 软比特 → 2160 信息比特（64 态 / 回溯 96）"),
        ("rand", [(seed + k, "noise") for k in range(4)],
         "4 帧背靠背噪声软值 17328 软比特 → 8640 信息比特（含 0 值段打并列取舍）"),
        ("edge", [(seed, "edge")],
         "满量程 ±127/32 软值：PM 16bit 饱和 + ACS 哨兵 32768 取舍边界"),
    ]


def _viterbi_soft(de, sd: int, style: str):
    """按风格造一帧 Q3.5 **格点**软值（正 = 更可能为 0）；golden 与向量共用同一批值。

    格点化后再交给 golden/to_int，避免半格点舍入（half-to-even vs half-away）分歧。
    """
    if style == "ideal":
        return de
    if style == "edge":
        return np.where(de > 0, 3.96875, -3.96875)   # ±127/32 满量程
    # noise：±3.5 + 高斯（σ=1.5），钳到 ±127/32 后量化到 1/32 格点；
    # 中段 32 个软值置 0 → 路径度量并列密集出现，专打「严格小于、先到者赢」的取舍。
    rng = np.random.default_rng(sd ^ 0x5A5A)
    q = np.clip(np.asarray(de) + rng.normal(0.0, 1.5, len(de)), -3.96875, 3.96875)
    q = np.round(q * 32) / 32
    q[len(q) // 2 - 16:len(q) // 2 + 16] = 0.0
    return q


def _export_viterbi_dec(payload, seed: int):
    stim_hex, expect_hex = [], []
    for sd, style in payload:
        _, _, soft = _rx_frame_soft(sd)
        de = soft_deinterleave(soft, n_out=len(soft) - 8)
        q = _viterbi_soft(de, sd, style)
        # 逐帧 fresh call（PM 复位、回溯窗从零起）——与 RTL 的「帧尾清零再开下一帧」同构
        dec = fixed_viterbi_hw(q, win_tb=RX_CONFIG["viterbi_win_tb"])
        stim_hex += _pack_soft_pair(q)
        expect_hex += [hex_of_int(int(b), 1) for b in dec]
    sw = FIXED_POINT_CONFIG["viterbi_metric_w"]
    sf = FIXED_POINT_CONFIG["viterbi_metric_frac"]
    meta = {
        "stim": {"bits": 2 * sw, "packing": "{soft[2k], soft[2k+1]}", "frac": sf},
        "expect": {"bits": 1, "packing": "信息比特（已去 6 尾比特）", "frac": None},
        "states": 64,
        "tb_depth": RX_CONFIG["viterbi_tb_depth"],
        "frames": len(payload),
        "styles": [st for _, st in payload],
        "stim_period": 1,
    }
    return stim_hex, expect_hex, meta


# ============================================================
# sync_rx（S5）：符号级同步 —— Costas 载波环 + 早迟门定时 + 软解调
# ============================================================
# 激励 = 4 sps 复采样 Q3.11 整数；expect 把 sync_rx 的**全部输出**一拍打包（76 bit）：
# 判决符号 + 双路软判决 + pe/te。环路状态一旦走岔，pe/te 会先于符号暴露出来。
# 位真比对从第 1 个符号起（SKIP_OUT=0）：golden 模型与 RTL 共享复位状态，暂态是确定的，
# 不需要"收敛后再比"——§6 第 3 条的收敛窗口是判"解调对错"的口径，不是位真比对的口径。
SYNC_IN_W = 14   # din_data 单路位宽（Q3.11）
SYNC_N_SYM = 600  # rand/freq 用例符号数（= calib 的工况长度）


def _sync_sat14(a):
    """损伤后重量化到 din_data 的 14 bit 端口（RTL 口装不下的部分按饱和丢弃）。

    频偏旋转保复数幅度但 I/Q 各自可到 |z|（≈√2×峰值），故满幅信号损伤后会超出
    14 bit——真实链路里 ddc_rx 输出就是 14 bit，这里同样饱和后再喂模型与 RTL。
    """
    return np.clip(a, -(1 << (SYNC_IN_W - 1)), (1 << (SYNC_IN_W - 1)) - 1).astype(np.int64)


def _sync_rx_cases(seed: int):
    """用例载荷 = (i_int, q_int) 一对 Q3.11 整数序列（长度 4 的整数倍）。

    rand/freq/rate 与 calib_sync_rx.py 的 B/A1/D 工况同构（同一 mk_mf_int / impair），
    rate 取 ±750 ppm 双段：mu 扫过近 ±2 采样，抽头窗 j0 = 1−(mu>>>14) 的 4 个取值
    全部走到——这是 sync_rx 组合逻辑里最容易写错的一处，向量必须踩到。
    """
    i0, q0 = mk_mf_int(n_sym=SYNC_N_SYM, seed=seed)

    # rate：±750 ppm 真时间轴拉伸（calib impair 的 ppm 语义），前后两段反号
    n_seg = 400 * 4
    ir, qr = mk_mf_int(n_sym=800, seed=seed)
    ip, qp = impair(ir[:n_seg], qr[:n_seg], ppm=+750e-6)
    in_, qn = impair(ir[n_seg:], qr[n_seg:], ppm=-750e-6)
    rate = (np.concatenate([ip, in_]), np.concatenate([qp, qn]))

    # edge：数值边界（不走信号链，直接构造整数），段长均为 4 的整数倍
    alt  = np.tile(np.array([8191, -8192], dtype=np.int64), 32)          # 满幅交替（饱和路径）
    ties = np.resize(np.array([3, -3, 32, -32, 96, -96, 33, -33,        # 舍入 tie 候选（Q6.22→Q3.11
                               1, -1, 2, -2, 4096, -4096, 8191, -8192],  # 与软判决 >>17 的 .5 位）
                     dtype=np.int64), 64)
    rng = np.random.default_rng(seed)
    small = rng.integers(-4, 5, 128).astype(np.int64)                    # 量化死区（环路 Ki 舍 0）
    med   = rng.integers(-4096, 4096, 128).astype(np.int64)

    edge = (
        np.concatenate([np.zeros(64, dtype=np.int64), alt, ties, small, med]),
        np.concatenate([np.zeros(64, dtype=np.int64), np.roll(alt, 1), np.roll(ties, 3),
                        rng.integers(-4, 5, 128).astype(np.int64),
                        rng.integers(-4096, 4096, 128).astype(np.int64)]),
    )

    return [
        ("rand", (i0, q0),
         f"{SYNC_N_SYM} QPSK 符号成形+匹配滤波（全卷积拖尾 → {len(i0)} 采样）无损伤基线"),
        ("freq", impair(i0, q0, f_off=1e3, ph0=0.7),
         "+1 kHz 频偏 + 0.7 rad 相偏（计划书损伤注入）"),
        ("rate", rate,
         "±750 ppm 符号率偏差（真时间轴拉伸）双段：mu 扫过近 ±2 采样，抽头窗 j0 四取值全覆盖"),
        ("edge", edge, "数值边界：全 0 / 满幅交替 / 舍入 tie 值 / 小信号量化死区 / 中幅随机"),
    ]


def _export_sync_rx(payload, seed: int):
    i_int = _sync_sat14(np.asarray(payload[0], dtype=np.int64))
    q_int = _sync_sat14(np.asarray(payload[1], dtype=np.int64))
    if len(i_int) != len(q_int) or len(i_int) % 4:
        raise RuntimeError(f"sync_rx 激励长度异常: {len(i_int)}/{len(q_int)}（须相等且为 4 的整数倍）")

    stim_hex = [hex_of_int(pack_fields((int(i), SYNC_IN_W), (int(q), SYNC_IN_W)), 2 * SYNC_IN_W)
                for i, q in zip(i_int, q_int)]

    r = fixed_sync_rx_hw(i_int, q_int)
    expect_hex = []
    for k in range(len(r["sym_i"])):
        expect_hex.append(hex_of_int(
            pack_fields(
                (int(r["sym_i"][k]), SYNC_IN_W), (int(r["sym_q"][k]), SYNC_IN_W),
                (int(r["soft_i"][k]), 8), (int(r["soft_q"][k]), 8),
                (int(r["pe"][k]), 16), (int(r["te"][k]), 16),
            ),
            2 * SYNC_IN_W + 8 + 8 + 16 + 16,
        ))

    mu_samp = r["mu"].astype(np.float64) / float(1 << 14)   # Q2.14 → 采样
    meta = {
        "stim": {"bits": 2 * SYNC_IN_W, "packing": "{i_in[13:0], q_in[13:0]}",
                 "frac": 11, "rate": "4 sps"},
        "expect": {
            "bits": 2 * SYNC_IN_W + 8 + 8 + 16 + 16,
            "packing": "{sym_i[13:0], sym_q[13:0], soft_i[7:0], soft_q[7:0], pe[15:0], te[15:0]}",
            "field_frac": {"sym": 11, "soft": 5, "pe": 11, "te": 11},
            "rate": "1 sps（早迟门 4:1 取样）",
        },
        "n_sym": len(r["sym_i"]),
        "loop_coeffs_q19": {k: RX_CONFIG[k] for k in
                            ("costas_kp_q19", "costas_ki_q19", "timing_kp_q19", "timing_ki_q19")},
        # 轨迹摘要（只读不比对）：证明本用例真把抽头窗 j0 的取值踩到了
        "mu_range_samp": [float(mu_samp.min()), float(mu_samp.max())],
        "stim_period": 1,
    }
    return stim_hex, expect_hex, meta


# ============================================================
# 注册表：新增模块在此登记
# ============================================================
MODULES = {
    "qpsk_map": {
        "cases": _qpsk_map_cases,
        "export": _export_qpsk_map,
        "golden_source": "golden_ref.fixed_point.fixed_modules.fixed_qpsk_modulate",
    },
    "frame_tx": {
        "cases": _frame_tx_cases,
        "export": _export_frame_tx,
        "golden_source": "golden_ref.float_chain.framing.build_frame_bits",
    },
    "conv_enc": {
        "cases": _conv_enc_cases,
        "export": _export_conv_enc,
        "golden_source": "golden_ref.float_chain.conv_encoder.conv_encode",
    },
    "blk_inter": {
        "cases": _blk_inter_cases,
        "export": _export_blk_inter,
        "golden_source": "golden_ref.float_chain.interleaver.block_interleave",
    },
    "srrc_duc": {
        "cases": _srrc_duc_cases,
        "export": _export_srrc_duc,
        "golden_source": "golden_ref.fixed_point.duc.fixed_srrc_duc",
    },
    "tx_chain": {
        "cases": _tx_chain_cases,
        "export": _export_tx_chain,
        "golden_source": "golden_ref 全链路（framing→conv→interleave→qpsk→srrc_duc）",
    },
    "ddc_rx": {
        "cases": _ddc_rx_cases,
        "export": _export_ddc_rx,
        "golden_source": "golden_ref.fixed_point.rx_modules.fixed_ddc_rx（CIC 抽取 + 匹配 FIR）",
    },
    "blk_deinter": {
        "cases": _blk_deinter_cases,
        "export": _export_blk_deinter,
        "golden_source": "golden_ref.fixed_point.rx_modules.soft_deinterleave",
    },
    "viterbi_dec": {
        "cases": _viterbi_dec_cases,
        "export": _export_viterbi_dec,
        "golden_source": "golden_ref.fixed_point.rx_modules.fixed_viterbi_hw",
    },
    "sync_rx": {
        "cases": _sync_rx_cases,
        "export": _export_sync_rx,
        "golden_source": "golden_ref.fixed_point.rx_modules.fixed_sync_rx_hw（Costas + 早迟门 + 软解调）",
    },
}


# ============================================================
# 落盘
# ============================================================
def _write_lines(path: Path, lines) -> None:
    # newline="\n"：仓库 .gitattributes 要求文本文件 LF，Windows 默认会写成 CRLF
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def _write_json(path: Path, payload: dict) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")


def export_module(module: str, case_filter: str, seed: int, out_dir: Path,
                  full: bool = False) -> list[dict]:
    entry = MODULES[module]
    written = []
    out_dir = out_dir / module
    out_dir.mkdir(parents=True, exist_ok=True)

    for case, payload, note in entry["cases"](seed):
        if case_filter == "all":
            # 长跑用例（10⁶ bit / 1000 帧）体积大且不入库，默认不生成；--full 才带上
            if case in LONG_CASES and not full:
                continue
        elif case_filter != case:
            continue

        stim_hex, expect_hex, meta = entry["export"](payload, seed)
        # 行数不再要求相等（S4-P0：激励节拍数 ≠ 比对长度），但不能有空文件
        if not stim_hex or not expect_hex:
            raise RuntimeError(f"{module}/{case}: 空向量 stim={len(stim_hex)} expect={len(expect_hex)}")

        _write_lines(out_dir / f"{case}_stim.hex", stim_hex)
        _write_lines(out_dir / f"{case}_expect.hex", expect_hex)
        _write_json(
            out_dir / f"{case}_meta.json",
            {
                "module": module,
                "case": case,
                "stim_rows": len(stim_hex),
                "expect_rows": len(expect_hex),
                "count": len(expect_hex),      # 比对长度（PASS 判据里的 compared 目标）
                "case_note": note,
                "seed": seed,
                "golden_source": entry["golden_source"],
                "golden_ref_version": GOLDEN_REF_VERSION,
                "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
                **meta,
            },
        )
        written.append({"module": module, "case": case,
                        "stim_rows": len(stim_hex), "expect_rows": len(expect_hex)})
    return written


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="从 S1 定点参考模型导出 xsim 比对向量")
    ap.add_argument("--module", action="append", default=None,
                    help=f"模块名，可重复；缺省=全部（{'/'.join(MODULES)}）")
    ap.add_argument("--case", default="all", help="用例名，缺省 all（不含长跑用例，见 --full）")
    ap.add_argument("--full", action="store_true",
                    help="all 时也生成长跑用例（frame_tx/long 1000 帧、conv_enc/long 10⁶ bit）")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED, help=f"随机种子，缺省 {DEFAULT_SEED}")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"输出目录，缺省 {DEFAULT_OUT}")
    ap.add_argument("--list", action="store_true", help="只列出已注册模块")
    args = ap.parse_args(argv)

    if args.list:
        for name, entry in MODULES.items():
            cases = "/".join(c for c, _, _ in entry["cases"](DEFAULT_SEED))
            print(f"{name:16s} cases={cases:12s} {entry['golden_source']}")
        return 0
    modules = args.module or list(MODULES)
    unknown = [m for m in modules if m not in MODULES]
    if unknown:
        print(f"未注册的模块: {', '.join(unknown)}（已注册: {', '.join(MODULES)}）", file=sys.stderr)
        return 2

    total = 0
    for module in modules:
        written = export_module(module, args.case, args.seed, args.out, full=args.full)
        if not written:
            print(f"[VEC-GEN] {module}/{args.case} 无匹配用例", file=sys.stderr)
            return 2
        for item in written:
            rel = (args.out / item["module"]).relative_to(FRAMEWORK_DIR) if args.out.is_relative_to(FRAMEWORK_DIR) else args.out / item["module"]
            print(f"[VEC-GEN] {item['module']}/{item['case']}  "
                  f"stim {item['stim_rows']:7d} 行 / expect {item['expect_rows']:7d} 行  "
                  f"→ {rel}\\{item['case']}_{{stim,expect}}.hex")
            total += item["expect_rows"]

    print(f"[VEC-GEN] 完成：{len(modules)} 个模块，合计 {total} 个比对样本")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
