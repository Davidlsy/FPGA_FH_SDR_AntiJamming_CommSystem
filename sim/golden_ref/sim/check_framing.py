#!/usr/bin/env python3
"""S4 帧层黄金参考自检 —— 判据不能自己给自己背书，这里做三件独立校验：

1. **CRC 走两条独立编码路径**：位串行 LFSR（与 RTL 同构）与 8-bit 查表，
   并要求二者都对上 CRC-16/CCITT-FALSE 的标准向量 "123456789" → 0x29B1；
2. **m 序列/优选对用数值验证而非凭记忆**：遍历 6 级全部本原多项式，逐个
   算周期，再对全部两两组合算周期交叉相关集，确认冻结的那对取值恰为
   {-17, -1, 15}（n 为偶数时的 {-1, -1±2^(n/2+1)}）；
3. **成帧往返与负例**：`build_frame_bits` → `parse_frame_bits` 还原一致；
   帧头/载荷注错必须被 CRC 检出、同步字注错必须被 `sync_ok` 检出——
   只测正例不能证明校验真的接上了。

用法:
    python sim/check_framing.py            # 判据行 [FRAME-GOLDEN]
"""
from __future__ import annotations

import itertools
import sys
from pathlib import Path

import numpy as np

# 本文件在 sim/golden_ref/sim/ 下，sim/ 是三层之上（包名 golden_ref 在 sim/ 里）
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from golden_ref.config import (  # noqa: E402
    FRAME_COVERED_BITS,
    FRAME_CRC_BITS,
    FRAME_PAYLOAD_BYTES,
    FRAME_SYNC_LEN,
    FRAME_SYNC_M,
    FRAME_SYNC_POLY,
    FRAME_SYNC_SHIFT,
    FRAME_TOTAL_BITS,
)
from golden_ref.float_chain.framing import (  # noqa: E402
    build_frame_bits,
    bytes_to_bits,
    crc16_bitwise,
    crc16_table,
    gold_sync_word,
    m_sequence,
    parse_frame_bits,
)

CHECKS = 0
FAILED = 0


def _state_cycle(mask: int, n: int = FRAME_SYNC_M) -> int:
    """从状态 1 出发回到 1 所需的拍数（= 2^n-1 时该多项式本原）。"""
    taps = [i for i in range(n) if (mask >> i) & 1]
    reg = 1
    for k in range(1, 1 << (n + 1)):
        fb = 0
        for t in taps:
            fb ^= (reg >> t) & 1
        reg = (reg >> 1) | (fb << (n - 1))
        if reg == 1:
            return k
    return -1


def _longest_run(bits) -> int:
    """最长同值游程（同步字里连续 0/1 的最大长度，越小越利于相关检测）。"""
    bits = list(np.asarray(bits).ravel())
    best = cur = 1
    for i in range(1, len(bits)):
        cur = cur + 1 if bits[i] == bits[i - 1] else 1
        best = max(best, cur)
    return best


def check(name: str, ok: bool, detail: str = "") -> None:
    global CHECKS, FAILED
    CHECKS += 1
    if not ok:
        FAILED += 1
    mark = "ok  " if ok else "FAIL"
    print(f"  [{mark}] {name}{('  ' + detail) if detail else ''}")


def main() -> int:
    print("S4 帧层黄金参考自检")
    print("=" * 66)

    # ---------- 1. CRC 两条独立路径 + 标准向量 ----------
    print("[1] CRC-16/CCITT-FALSE")
    std = crc16_table(b"123456789")
    check("标准向量 '123456789' -> 0x29B1 (查表路径)", std == 0x29B1, f"0x{std:04X}")
    std_bits = crc16_bitwise(bytes_to_bits(b"123456789"))
    check("标准向量 '123456789' -> 0x29B1 (位串行路径)", std_bits == 0x29B1, f"0x{std_bits:04X}")

    rng = np.random.default_rng(20260928)
    agree = True
    for _ in range(64):
        n = int(rng.integers(1, 300))
        data = rng.integers(0, 256, size=n, dtype=np.uint8).tobytes()
        if crc16_table(data) != crc16_bitwise(bytes_to_bits(data)):
            agree = False
            break
    check("64 组随机长度下两条路径逐值一致", agree)

    # ---------- 2. m 序列与优选对 ----------
    print("[2] m 序列与优选对（数值验证）")
    period = (1 << FRAME_SYNC_M) - 1
    seqs = {}
    for mask in range(1 << (FRAME_SYNC_M + 1)):
        if not (mask & (1 << FRAME_SYNC_M)) or not (mask & 1):
            continue
        # 本原性判据 = 状态周期恰为 2^m-1：从状态 1 出发必须恰好 63 步才回到 1。
        # （不能用"所有旋转互不相同"代替：合式多项式在不对齐的截断下也能满足它。）
        if _state_cycle(mask) == period:
            s = m_sequence(mask, FRAME_SYNC_M)
            seqs[mask] = 2 * s.astype(np.int64) - 1

    check("6 级本原多项式个数 == 6", len(seqs) == 6, f"找到 {sorted(bin(m) for m in seqs)}")
    check("m 序列周期 == 63", all(m_sequence(m, FRAME_SYNC_M).size == period for m in seqs))

    for mask in seqs:
        s = m_sequence(mask, FRAME_SYNC_M)
        # m 序列一个周期内 0/1 个数相差恰为 1
        ones = int(s.sum())
        check(f"平衡性 poly={bin(mask)}", abs(ones - (period - ones)) == 1,
              f"1 的个数 {ones}/{period}")

    pair = tuple(FRAME_SYNC_POLY)
    a, b = seqs[pair[0]], seqs[pair[1]]
    corr = sorted({int(np.sum(a * np.roll(b, i))) for i in range(period)})
    check(f"冻结对 {bin(pair[0])} & {bin(pair[1])} 交叉相关集 == [-17, -1, 15]",
          corr == [-17, -1, 15], f"{corr}")

    others = []
    for x, y in itertools.combinations(sorted(seqs), 2):
        vals = {int(np.sum(seqs[x] * np.roll(seqs[y], i))) for i in range(period)}
        if len(vals) != 3:
            others.append((x, y))
    check("存在非优选对（证明上面的三值判据不是恒真）", len(others) > 0,
          f"{len(others)} 对不满足三值性")

    # ---------- 3. 同步字 ----------
    print("[3] Gold 同步字")
    sync = gold_sync_word()
    check("同步字长度 == 64", sync.size == FRAME_SYNC_LEN, f"{sync.size} bit")
    check("同步字末位 == 首位（63 周期 + 1 位重复）", int(sync[-1]) == int(sync[0]))
    check("同步字取自冻结优选对（含相对位移 24）",
          np.array_equal(sync[:period], (m_sequence(pair[0], FRAME_SYNC_M)
                                         ^ np.roll(m_sequence(pair[1], FRAME_SYNC_M),
                                                   FRAME_SYNC_SHIFT))))
    ac = [int(np.sum((2 * sync - 1) * (2 * np.roll(sync, i) - 1))) for i in range(1, sync.size)]
    check("旁瓣 max|R| == 16（主峰 64）", max(abs(v) for v in ac) == 16,
          f"max|R|={max(abs(v) for v in ac)}")
    check("同步字恰好 32 个 1（完全平衡）", int(sync.sum()) == 32, f"{int(sync.sum())}/64")
    check("最长同值游程 == 4", _longest_run(sync) == 4, f"{_longest_run(sync)} bit")
    check("同步字不是短周期序列", not any(np.array_equal(sync, np.roll(sync, i))
                                          for i in range(1, FRAME_SYNC_LEN // 2)))

    # 冻结的相位必须是按既定准则搜出来的最优（同分取最小位移），而不是手写的数字
    best = None
    for k in range(period):
        cand = np.concatenate([m_sequence(pair[0], FRAME_SYNC_M)
                               ^ np.roll(m_sequence(pair[1], FRAME_SYNC_M), k),
                               (m_sequence(pair[0], FRAME_SYNC_M)
                                ^ np.roll(m_sequence(pair[1], FRAME_SYNC_M), k))[:1]])
        c = 2 * cand - 1
        key = (_longest_run(cand),
               max(abs(int(np.sum(c * np.roll(c, i)))) for i in range(1, cand.size)),
               abs(int(cand.sum()) - 32))
        if best is None or key < best[0]:
            best = (key, k)
    check("冻结位移 24 是按准则搜索的最优相位", best[1] == FRAME_SYNC_SHIFT,
          f"最优 k={best[1]} key={best[0]}")

    # ---------- 4. 成帧往返 ----------
    print("[4] 成帧与反向解析")
    check("帧长算术 == 2160", FRAME_TOTAL_BITS == 2160, f"{FRAME_TOTAL_BITS} bit")
    check("CRC 覆盖长度 == 2080（帧头 32 + 载荷 2048）", FRAME_COVERED_BITS == 2080,
          f"{FRAME_COVERED_BITS} bit")
    check("帧长 == 同步字 + 覆盖 + CRC", FRAME_TOTAL_BITS
          == FRAME_SYNC_LEN + FRAME_COVERED_BITS + FRAME_CRC_BITS)

    payload = rng.integers(0, 256, size=FRAME_PAYLOAD_BYTES, dtype=np.uint8).tobytes()
    frame = build_frame_bits(payload, frame_no=7)
    parsed = parse_frame_bits(frame)
    check("载荷往返一致", parsed["payload"] == payload)
    check("帧号往返一致", parsed["frame_no"] == 7, f"帧号 {parsed['frame_no']}")
    check("载荷长度字段 == 256", parsed["payload_bytes"] == 256)
    check("CRC 校验通过", parsed["crc_ok"], f"rx=0x{parsed['crc_rx']:04X}")
    check("同步字校验通过", parsed["sync_ok"])

    # 帧号回绕
    check("帧号按 8 bit 回绕", parse_frame_bits(build_frame_bits(payload, frame_no=256))["frame_no"] == 0)

    # ---------- 5. 注错负例 ----------
    print("[5] 注错负例（校验必须检出）")
    detected = 0
    trials = 32
    for t in range(trials):
        bad = frame.copy()
        pos = int(rng.integers(FRAME_SYNC_LEN, FRAME_TOTAL_BITS))  # 只在 CRC 覆盖区注错
        bad[pos] ^= 1
        if not parse_frame_bits(bad)["crc_ok"]:
            detected += 1
    check(f"CRC 覆盖区单比特注错 {trials}/{trials} 全部检出", detected == trials,
          f"检出 {detected}")

    bad = frame.copy()
    bad[3] ^= 1
    check("同步字注错被 sync_ok 检出", not parse_frame_bits(bad)["sync_ok"])

    # 帧头单比特注错必须改变解析出的字段或 CRC。帧头 MSB = 版本字段的 bit1，
    # 故注错位置是 header 区的第 0 位（不是第 31 位——那是载荷字节数的 LSB）。
    bad = frame.copy()
    bad[FRAME_SYNC_LEN] ^= 1
    p = parse_frame_bits(bad)
    check("帧头版本位注错 → 版本字段变化且 CRC 失败",
          p["version"] != parsed["version"] and not p["crc_ok"],
          f"version={parsed['version']} → {p['version']}, crc_ok={p['crc_ok']}")

    # 载荷整字节全 0 / 全 0xFF 边界
    for label, pat in (("全 0", b"\x00"), ("全 0xFF", b"\xff")):
        f = build_frame_bits(pat * FRAME_PAYLOAD_BYTES)
        check(f"载荷{label}成帧后 CRC 自洽", parse_frame_bits(f)["crc_ok"])

    # ---------- 6. 与下游的算术衔接 ----------
    print("[6] 与下游链路的算术衔接（信息性）")
    coded = 2 * (FRAME_TOTAL_BITS + 6)
    cols = -(-coded // 10)
    print(f"  conv_enc : ({FRAME_TOTAL_BITS} + 6 尾) × 2 = {coded} bit")
    print(f"  blk_inter: 10 × {cols} = {10 * cols} bit（尾部补零 {10 * cols - coded} bit）")
    check("编码后长度适合交织（补零 < 交织深度）", (10 * cols) - coded < 10,
          f"补零 {10 * cols - coded} bit")

    print("=" * 66)
    status = "PASS" if FAILED == 0 else "FAIL"
    print(f"[FRAME-GOLDEN] checks={CHECKS} failed={FAILED} status={status}")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
