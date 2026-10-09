"""S6 同步字捕获黄金裁判自检 —— 判据不能自己给自己背书，这里做独立校验：

1. **同步字常量互证**：`framing.gold_sync_word()` 与冻结常量 0x517AE4216E7555CA 逐位一致，
   0/1 平衡 32/32、旁瓣 max|R|=16（frame_format.md §2.3 特性表）；
2. **相关峰与无虚警**：真实帧流（`build_frame_bits`）峰值拍 corr=64 恰在同步字末位拍，
   非峰窗全部不命中（随机窗 max corr ≤ 51 < 门限下限 52）；独立朴素相关器逐拍一致；
3. **零填窗**：复位后立即灌同步字，第 64 拍 corr=64；前 63 拍与独立朴素相关器一致；
4. **门限整数语义**：随机流逐拍 thresh 与浮点独立重算（真四舍五入 + floor 除法）一致，
   半入边界（历史和 %16 == 8 进位 / == 7 不进位）各有实拍可见性验证；
5. **hit 等号边界**：构造 corr == thresh 命中、corr == thresh−1 不命中（等号语义有档）；
6. **M/N 判决全边界**（FRAME_LEN=200）：槽 2 确认 / 槽 3 凑满确认（**声明优先于弃候选**）/
   弃候选 / 无粘滞重开 / 锁定期 hit 忽略且 timer 不重置 / 伪峰吞真峰后重捕；
7. **停表冻结不变式**：任意 din_valid 空隙插入后，有效拍输出与无空隙版逐行相等（长度解耦）；
8. **虚警解析上界**：p_w 精确二项尾 + 联合界 Pfa/帧 ≤ 1e-6（§8.5 证明的独立重算）；
9. **检测概率下界**：真实帧流实测峰值工作点门限 T，解析 Pd(3 帧内声明) @ 0 dB ≥ 99%；
10. **跨模块互证**：4 帧真实帧流 → frame_start 恰在各帧同步字末位拍、acq 恰在槽 2（延迟 1 帧）。

用法:
    python sim/golden_ref/sim/check_sync_acq.py     # 判据行 [SYNC-ACQ-GOLDEN]
"""
from __future__ import annotations

import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from golden_ref.fixed_point.sync_acq import (  # noqa: E402
    COEFF_Q,
    COEFF_SHIFT,
    FRAME_LEN_DEFAULT,
    NAVG,
    N_SLOT_DEFAULT,
    SYNC_W,
    SYNC_WORD,
    THRESH_MIN,
    sim_sync_acq,
)
from golden_ref.float_chain.framing import (  # noqa: E402
    FRAME_SYNC_LEN,
    bits_to_int,
    build_frame_bits,
    gold_sync_word,
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


def _sync_bits() -> list[int]:
    return [(SYNC_WORD >> (SYNC_W - 1 - i)) & 1 for i in range(SYNC_W)]


def _naive_corr(stream: list[int], n: int) -> int:
    """独立朴素相关器：窗 = 最近 64 bit（不足窗前补 0），匹配数。"""
    win = ([0] * SYNC_W + stream[: n + 1])[-SYNC_W:]
    s = _sync_bits()
    return sum(1 for a, b in zip(win, s) if a == b)


def _binom_tail(n: int, k_min: int, p: float) -> float:
    return sum(math.comb(n, k) * p**k * (1 - p) ** (n - k) for k in range(k_min, n + 1))


def _build_stream(length: int, forces: dict[int, int], seed: int = 20261009) -> list[int]:
    """forces = {窗口末位拍: 64 bit 字（MSB=最早 bit）}，强制窗互不重叠（间隔 ≥64）；其余伪随机填充。"""
    rng = random.Random(seed)
    bits = [rng.randint(0, 1) for _ in range(length)]
    prev = -10**9
    for t, word in sorted(forces.items()):
        assert SYNC_W - 1 <= t < length, f"强制窗越界 t={t}"
        assert t - prev >= SYNC_W, f"强制窗重叠 t={t} prev={prev}"
        for i in range(SYNC_W):
            bits[t - SYNC_W + 1 + i] = (word >> (SYNC_W - 1 - i)) & 1
        prev = t
    return bits


def _cmds(bits: list[int], gaps: list[tuple[int, int]] | None = None):
    """比特流 → (din_valid, din_bit) 命令流；gaps = [(有效拍序号, 拍数)] **插入式**停表。

    停表拍不携带 bit（din_valid=0 整拍冻结），有效比特序列与无空隙版恒等——
    这样"有效拍输出逐行相等"的不变式检验的才是冻结语义，而非激励差异。
    """
    gap_at: dict[int, int] = {}
    for pos, n in gaps or []:
        gap_at[pos] = gap_at.get(pos, 0) + n
    out: list[tuple[int, int]] = []
    for i, b in enumerate(bits):
        out.append((1, b))
        out.extend([(0, 0)] * gap_at.get(i, 0))
    return out


def main() -> int:
    print("S6 同步字捕获黄金裁判自检")
    print("=" * 66)

    print("[1] 同步字常量互证（framing.gold_sync_word / 特性表）")
    gold = bits_to_int(gold_sync_word())
    check("黄金源逐位一致", gold == SYNC_WORD, f"0x{gold:016X}")
    check("与 frame_format.md §2.3 冻结常量一致", SYNC_WORD == 0x517AE4216E7555CA)
    ones = SYNC_WORD.bit_count()
    check("0/1 平衡 32/32", ones == 32 and FRAME_SYNC_LEN == 64, f"ones={ones}")
    sbits = _sync_bits()
    r_max = max(
        abs(sum(1 if a == b else -1 for a, b in zip(sbits, sbits[k:] + sbits[:k])))
        for k in range(1, SYNC_W)
    )
    check("旁瓣 max|R| = 16（frame_format 特性表）", r_max == 16, f"max|R|={r_max}")

    print("[2] 相关峰与无虚警（4 帧真实帧流）")
    payload = bytes((i * 7 + 3) & 0xFF for i in range(256))
    frames = [list(map(int, build_frame_bits(payload, frame_no=k))) for k in range(4)]
    stream = [b for f in frames for b in f]
    rows = sim_sync_acq(_cmds(stream), frame_len=FRAME_LEN_DEFAULT)
    peak_beats = [k * FRAME_LEN_DEFAULT + SYNC_W - 1 for k in range(4)]
    check("峰值拍 corr=64 且恰在同步字末位拍",
          all(rows[t][3] == 64 for t in peak_beats),
          f"peak corr={[rows[t][3] for t in peak_beats]}")
    non_peak = [r for t, r in enumerate(rows) if t not in peak_beats]
    check("非峰窗无命中（max corr ≤ 51 < 门限下限 52）",
          all(r[0] == 0 for r in non_peak) and max(r[3] for r in non_peak) <= 51,
          f"max={max(r[3] for r in non_peak)}")
    check("独立朴素相关器逐拍一致（8640 拍）",
          all(rows[t][3] == _naive_corr(stream, t) for t in range(len(stream))))

    print("[3] 零填窗（复位后立即灌同步字）")
    sb = _sync_bits()
    rows0 = sim_sync_acq(_cmds(sb))
    check("第 64 拍 corr=64（sr==SYNC_WORD）", rows0[63][3] == 64, f"corr={rows0[63][3]}")
    check("前 63 拍与朴素零填窗一致",
          all(rows0[t][3] == _naive_corr(sb, t) for t in range(63)))

    print("[4] 门限整数语义（浮点独立重算 + 半入边界实拍）")
    rng = random.Random(7)
    rstream = [rng.randint(0, 1) for _ in range(3000)]
    rrows = sim_sync_acq(_cmds(rstream))
    corrs = [r[3] for r in rrows]

    def _ref_thresh(i: int) -> int:
        s = sum(corrs[max(0, i - NAVG): i])        # 近 16 拍历史（不足窗补 0，同模型）
        est = math.floor(s / NAVG + 0.5)           # 真四舍五入（浮点独立路径）
        return max(THRESH_MIN, (est * COEFF_Q) // (1 << COEFF_SHIFT))

    check("逐拍 thresh 与浮点独立重算一致（3000 拍）",
          all(rrows[i][4] == _ref_thresh(i) for i in range(len(rrows))))
    up_beats = [i for i in range(NAVG, len(corrs))
                if sum(corrs[i - NAVG:i]) % NAVG == 8 and rrows[i][4] > THRESH_MIN]
    dn_beats = [i for i in range(NAVG, len(corrs))
                if sum(corrs[i - NAVG:i]) % NAVG == 7 and rrows[i][4] > THRESH_MIN]
    check("半入边界 %16==8 进位实拍可见", len(up_beats) > 0,
          f"n={len(up_beats)} 例 thresh={[rrows[i][4] for i in up_beats[:3]]}")
    check("半入边界 %16==7 不进位实拍可见", len(dn_beats) > 0,
          f"n={len(dn_beats)} 例 thresh={[rrows[i][4] for i in dn_beats[:3]]}")

    print("[5] hit 等号边界（构造 corr == thresh / thresh−1）")
    # 前 200 拍全 0（corr 恒 32 → est=32 → thresh=52），随后灌强制窗：
    # 窗末拍 corr = 64 − 反相位数；历史和 s = Σ corr[窗末-16 .. 窗末-1] 须落 [504,519] → est=32。
    base = [0] * 200

    def _eq_case(n_flips: int, want_corr: int):
        for trial in range(400):
            flip_pos = random.Random(1000 + trial).sample(range(SYNC_W), n_flips)
            word = SYNC_WORD ^ sum(1 << (SYNC_W - 1 - p) for p in flip_pos)
            bits = base + [(word >> (SYNC_W - 1 - i)) & 1 for i in range(SYNC_W)]
            rr = sim_sync_acq(_cmds(bits))
            s = sum(r[3] for r in rr[-NAVG - 1:-1])
            if rr[-1][3] == want_corr and 504 <= s <= 519:
                return rr[-1], s
        return None, 0

    row, s = _eq_case(12, 52)
    check("corr == thresh(52) 等号算命中",
          row is not None and row[0] == 1 and row[4] == 52,
          f"corr={row[3] if row else '-'} hit={row[0] if row else '-'} hist_sum={s}")
    row, s = _eq_case(13, 51)
    check("corr == thresh−1 不命中（等号语义有档）",
          row is not None and row[0] == 0 and row[4] == 52,
          f"corr={row[3] if row else '-'} hit={row[0] if row else '-'} hist_sum={s}")

    print("[6] M/N 判决全边界（FRAME_LEN=200，强制窗驱动）")
    fl = 200
    anti = SYNC_WORD ^ ((1 << SYNC_W) - 1)      # 反相同步字 → corr=0 必不命中
    total = 1400

    def _mn(forces: dict[int, int], gaps=None):
        return sim_sync_acq(_cmds(_build_stream(total, forces), gaps), frame_len=fl)

    def _events(rows_):
        return [t for t, r in enumerate(rows_) if r[1]], [t for t, r in enumerate(rows_) if r[2]]

    t0 = 263
    # a) 槽 3 凑满确认：hit / miss / hit → acq 恰在槽 3（声明优先于弃候选）
    acqs, fss = _events(_mn({t0: SYNC_WORD, t0 + fl: anti, t0 + 2 * fl: SYNC_WORD}))
    check("槽 3 凑满 M=2 → 确认（声明优先于弃候选）", acqs == [t0 + 2 * fl], f"acq={acqs}")
    check("frame_start 恰在两个命中拍", fss == [t0, t0 + 2 * fl], f"fss={fss}")
    # b) 槽 2 确认（捕获延迟 1 帧）
    acqs, _ = _events(_mn({t0: SYNC_WORD, t0 + fl: SYNC_WORD}))
    check("槽 2 确认：acq = 开候选拍 + FRAME_LEN", acqs == [t0 + fl], f"acq={acqs}")
    # c) 弃候选：hit / miss / miss → 无 acq
    acqs, _ = _events(_mn({t0: SYNC_WORD, t0 + fl: anti, t0 + 2 * fl: anti}))
    check("槽 2/3 全 miss → 弃候选无 acq", acqs == [], f"acq={acqs}")
    # d) 无粘滞重开：弃候选后下一个 hit 立即开新候选并确认
    tr = t0 + 2 * fl + 100
    acqs, fss = _events(_mn({t0: SYNC_WORD, t0 + fl: anti, t0 + 2 * fl: anti,
                             tr: SYNC_WORD, tr + fl: SYNC_WORD}))
    check("弃候选后无粘滞重开并再确认", acqs == [tr + fl], f"acq={acqs} fss={fss}")
    # e) 锁定期：开候选后 100 拍的 hit 被忽略且 timer 不重置（槽 2 仍在 +FRAME_LEN）
    acqs, fss = _events(_mn({t0: SYNC_WORD, t0 + 100: SYNC_WORD, t0 + fl: SYNC_WORD}))
    check("锁定期 hit 忽略（无 frame_start）且 timer 不重置（槽 2 确认）",
          fss == [t0, t0 + fl] and acqs == [t0 + fl], f"acq={acqs} fss={fss}")
    # f) 伪峰吞真峰后重捕（§8.6 #1 有意边界的行为档）：
    #    伪峰 t0 开候选 → 真峰 t0+100 落锁定期被吞 → 槽 2/3 miss 弃候选 → 真峰重开并确认
    t1 = t0 + 2 * fl + 100
    acqs, fss = _events(_mn({t0: SYNC_WORD, t0 + 100: SYNC_WORD,
                             t0 + fl: anti, t0 + 2 * fl: anti,
                             t1: SYNC_WORD, t1 + fl: SYNC_WORD}))
    check("伪峰吞真峰后重捕：acq 只在重开候选的槽 2",
          acqs == [t1 + fl] and t0 + 100 not in fss,
          f"acq={acqs} fss={fss}")

    print("[7] 停表冻结不变式（任意空隙 → 有效拍输出逐行相等）")
    # 空隙钉在同步字中段（拆字）、槽位拍前、acq 拍前后——冻结语义最易错的位置
    gaps = [(5, 3), (t0 - 1, 7), (100, 17), (t0 + fl - 1, 5),
            (600, 31), (t0 + 2 * fl - 1, 9), (t0 + 2 * fl, 4)]
    forces_a = {t0: SYNC_WORD, t0 + fl: anti, t0 + 2 * fl: SYNC_WORD}
    ra = sim_sync_acq(_cmds(_build_stream(total, forces_a)), frame_len=fl)
    rg = sim_sync_acq(_cmds(_build_stream(total, forces_a), gaps), frame_len=fl)
    check("停表版与连续版逐行相等（拆同步字/槽位拍前空隙，M/N 事件流保持）", rg == ra)

    print("[8] 虚警解析上界（精确二项尾 + 联合界，独立重算）")
    p_w = _binom_tail(64, THRESH_MIN, 0.5)
    pfa = FRAME_LEN_DEFAULT * p_w * (N_SLOT_DEFAULT - 1) * p_w
    check("p_w(窗命中) = P(Bin(64,½) ≥ 52)", abs(p_w - 2.283e-7) / 2.283e-7 < 0.02,
          f"p_w={p_w:.3e}")
    check("Pfa/帧 ≤ 1e-6（判据）", pfa <= 1e-6, f"bound={pfa:.3e}")

    print("[9] 检测概率下界（真实帧流实测工作点 + 半解析）")
    t_work = max(rows[t][4] for t in peak_beats)
    ber0 = 0.5 * math.erfc(1.0)                   # 0 dB BPSK 硬判决：Q(√2) ≈ 0.0786
    p_w_det = 1 - _binom_tail(64, SYNC_W - t_work + 1, ber0)   # P(e ≤ 64−T)
    pd3 = p_w_det**2 * (3 - 2 * p_w_det)          # 3 帧内声明（开1确2 / 开1确3 / 漏1开2确3）
    check("峰值工作点门限 T ≤ 56（检测余量）", t_work <= 56, f"T={t_work}")
    check("Pd(3 帧内) ≥ 99% @ 0 dB（BER=Q(√2)≈0.0786）", pd3 >= 0.99,
          f"P_w={p_w_det:.5f} Pd={pd3:.5f}")

    print("[10] 跨模块互证（build_frame_bits 4 帧流）")
    acqs = [t for t, r in enumerate(rows) if r[1]]
    fss = [t for t, r in enumerate(rows) if r[2]]
    check("frame_start 恰在各帧同步字末位拍", fss == peak_beats, f"fss={fss}")
    check("acq 恰在槽 2（捕获延迟 1 帧）", acqs == [peak_beats[1], peak_beats[3]], f"acq={acqs}")

    print()
    status = "PASS" if FAILED == 0 else "FAIL"
    print(f"[SYNC-ACQ-GOLDEN] checks={CHECKS} failed={FAILED} status={status}")
    print(f"[SYNC-ACQ-GOLDEN] pfa_bound={pfa:.3e} per frame (criterion 1e-6)  "
          f"work_thresh={t_work}  pd_0dB={pd3:.5f} (criterion 0.99)")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
