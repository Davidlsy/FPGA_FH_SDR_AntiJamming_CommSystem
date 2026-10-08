"""
S5 接收链定点黄金模型（ddc_rx / sync_rx / blk_deinter / viterbi_dec）

这是 S5 位真比对的**裁判**：RTL 写出后必须与本文件逐拍/逐比特一致。
位宽口径见 `docs/spec/s5_rx_interface.md` §6.1（v1.1 冻结）；DDC 与同步环的结构参数
见 `config.RX_CONFIG`。

与既有 `fixed_modules.py` 的分工：那里面是 S1 的"功能等价"定点模型
（`fixed_sync_receive` 只做理想同步 + 4 次幂粗相偏、`fixed_viterbi_decode` 用 float 累加），
**不足以当 RTL 的位真裁判**；本文件是 S5 补齐的硬件忠实版本。

三段的状态：
  - `fixed_cic_decimate` / `fixed_ddc_rx`    —— 位真（整数域，可逐拍比对）
  - `soft_deinterleave`                       —— 位真（纯置换）
  - `fixed_viterbi_hw`                        —— 位真（整数 PM + 滑窗回溯）
  - `fixed_costas_timing_rx`                  —— **候选实现**：定点 I/O + 定点相位/定时累加器，
    内部误差项与环路乘法用浮点建模。完全逐位真需与 RTL 协同定标（判别器增益、每步舍入点），
    故本函数当前用于**收敛性判定**（#5 的判据），其位真冻结随 RTL 落地（#3/#16）。

输入定标约定（贯穿本文件，RTL 必须同款）：
  ADC 12 bit 补码满量程 ±2048 ↔ 归一化基带幅度 ±1.0
  → 幅度 a 的 Q3.11 定点整数 = round(a × 2^11)，与 ADC 整数**同刻度**
  （2048 = 2^11，故 CIC 单位增益输出整数即 Q3.11 量级）
"""
import numpy as np

from ..config import CONV_K, FIXED_POINT_CONFIG, INTERLEAVER_DEPTH, RX_CONFIG
from .fixed_modules import fixed_srrc_coeffs
from .quantizer import quantize_complex


# ============================================================
# 整数工具
# ============================================================
def _wrap_signed(v, width):
    """按 width 位补码卷绕（CIC 积分器的模 2^width 语义）。"""
    mask = (1 << width) - 1
    v = int(v) & mask
    return v - (1 << width) if (v >> (width - 1)) & 1 else v


def _round_shift_half_even(x, shift):
    """
    有理右移 shift 位，**round half-to-even**（与 `np.round` / S4 量化口径一致）。
    适用于 numpy 整数数组或 Python 整数。
    """
    if shift <= 0:
        return np.asarray(x, dtype=np.int64)
    half = 1 << (shift - 1)
    q = np.floor_divide(x, 1 << shift)
    r = np.asarray(x, dtype=np.int64) - q * (1 << shift)   # 0 <= r < 2^shift
    carry = (r > half) | ((r == half) & ((q & 1) == 1))
    return q + carry.astype(np.int64)


def _sat_int(v, width):
    """饱和到 width 位补码范围。"""
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    return np.clip(np.asarray(v, dtype=np.int64), lo, hi)


# ============================================================
# 解交织（dtype 无关版）
# ============================================================
def soft_interleave(values, depth=INTERLEAVER_DEPTH):
    """
    与 `float_chain.interleaver.block_interleave` **同置换**、但 dtype 无关的交织。

    为什么另写：`block_interleave` 内部 `padded = np.zeros(n_total, dtype=np.int8)`，
    会把软值（float）强转 int8 而破坏数据——RX 侧需要对**软判决值**做同样的置换，
    故此处用 `values.dtype` 建缓冲。
    """
    v = np.asarray(values)
    n = len(v)
    n_cols = int(np.ceil(n / depth))
    n_total = depth * n_cols
    padded = np.zeros(n_total, dtype=v.dtype)
    padded[:n] = v
    return padded.reshape(depth, n_cols).T.flatten()


def soft_deinterleave(values, depth=INTERLEAVER_DEPTH, n_out=None):
    """
    解交织（`soft_interleave` 的逆），dtype 无关。

    参数:
        values: 交织序序列（软值或硬比特）
        depth:  交织深度（必须与发射侧 `INTERLEAVER_DEPTH` 相同）
        n_out:  输出长度；None → 自动去掉尾部补零。
                发射侧 `block_interleave(4332)` → 4340（补 8 bit），
                故 RX 应取 **n_out = 原有的 4332**（= 4340 − 8）。

    返回:
        deinterleaved: 长度 n_out（或与输入等长）
    """
    v = np.asarray(values)
    n = len(v)
    n_cols = int(np.ceil(n / depth))
    n_total = depth * n_cols
    if n_total != n:
        padded = np.zeros(n_total, dtype=v.dtype)
        padded[:n] = v
        v = padded
    out = v.reshape(n_cols, depth).T.flatten()
    return out if n_out is None else out[:n_out]


# ============================================================
# DDC：CIC 抽取 + 匹配 FIR
# ============================================================
def fixed_cic_decimate(x_int, decim=None, stages=None, diff_delay=None, acc_w=None):
    """
    定点 CIC 抽取器（整数域，逐拍可判）。

    结构：N 级积分器（输入速率）→ 抽取 D → N 级梳状器（输出速率），微分延迟 M。
    增益 = (D·M)^N，输出右移 log2(增益) 位还原单位增益（round half-to-even）。
    积分器 / 梳状器按 `acc_w`（任务卡：48 bit）**模 2^acc_w 补码卷绕**。

    参数:
        x_int: 输入整数序列（ADC 刻度：幅度 × 2048）
    返回:
        y_int: 抽取后的整数序列（同刻度，单位增益；长度 = ceil(len(x)/D)）
    """
    cfg = RX_CONFIG
    decim = cfg["cic_decim"] if decim is None else decim
    stages = cfg["cic_stages"] if stages is None else stages
    diff_delay = cfg["cic_diff_delay"] if diff_delay is None else diff_delay
    acc_w = cfg["cic_acc_w"] if acc_w is None else acc_w

    x = np.asarray(x_int, dtype=np.int64)

    # --- 积分器（输入速率），逐点模 2^acc_w ---
    y = x.copy()
    for _ in range(stages):
        acc = np.empty_like(y)
        s = 0
        for i in range(len(y)):
            s = _wrap_signed(s + int(y[i]), acc_w)
            acc[i] = s
        y = acc

    # --- 抽取 ---
    y = y[::decim]

    # --- 梳状器（输出速率）---
    for _ in range(stages):
        prev = np.zeros_like(y)
        if diff_delay:
            prev[diff_delay:] = y[:-diff_delay]
        y = np.array([_wrap_signed(int(a) - int(b), acc_w) for a, b in zip(y, prev)],
                     dtype=np.int64)

    # --- 增益归一：>> log2((D·M)^N) ---
    gain = (decim * diff_delay) ** stages
    shift = round(np.log2(gain))
    assert (1 << shift) == gain, f"CIC 增益 {gain} 非 2 的幂，需改用乘法归一化"
    return _round_shift_half_even(y, shift)


def fixed_ddc_rx(samples, decim=None, h_q=None):
    """
    定点 DDC：CIC 抽取（f_adc → 4 sps）+ 匹配 FIR（与发射 SRRC **同源** 33 抽头系数）。

    参数:
        samples: 输入复采样（基带幅度，实/虚各 ∈ ≈[-1, 1]；内部转到 ADC 整数刻度）
        decim:   抽取比（None 用 config）
        h_q:     量化后的 SRRC 系数（None 用 `fixed_srrc_coeffs`）

    返回:
        out_q:   Q3.11（14 bit / 11 小数）匹配滤波输出，长度 = ceil(len/D) + 32
        info:    诊断字典（CIC 峰值 / 匹配滤波峰值 / 是否饱和）
    """
    cfg = RX_CONFIG
    fp = FIXED_POINT_CONFIG
    if h_q is None:
        h_q, _ = fixed_srrc_coeffs()

    s = np.asarray(samples, dtype=np.complex128)

    # 幅度 → ADC 整数刻度（±2048 ↔ ±1.0），并饱和到 12 bit
    scale = float(1 << (cfg["adc_in_w"] - 1))          # 2048
    i_int = _sat_int(np.round(s.real * scale).astype(np.int64), cfg["adc_in_w"])
    q_int = _sat_int(np.round(s.imag * scale).astype(np.int64), cfg["adc_in_w"])

    i_dc = fixed_cic_decimate(i_int, decim=decim)
    q_dc = fixed_cic_decimate(q_int, decim=decim)

    # 匹配滤波：整数序列（已含 2^11 刻度）× Q1.11 系数 → 结果即 Q3.11 整数
    i_f = np.convolve(i_dc.astype(np.float64), h_q)
    q_f = np.convolve(q_dc.astype(np.float64), h_q)

    out_w, out_frac = fp["srrc_out_w"], fp["srrc_out_frac"]
    out_q, _ = quantize_complex(i_f + 1j * q_f, out_w, out_frac)

    peak = float(max(np.max(np.abs(out_q.real)), np.max(np.abs(out_q.imag))))
    info = {
        "cic_peak": int(max(np.max(np.abs(i_dc)), np.max(np.abs(q_dc)))),
        "mf_peak": peak,
        "saturated": bool(np.max(np.abs(i_f)) >= (1 << (out_w - 1)) or
                          np.max(np.abs(q_f)) >= (1 << (out_w - 1))),
        "n_out": len(out_q),
    }
    return out_q, info


# ============================================================
# 同步：二阶 Costas + 早迟门定时（候选实现，见模块 docstring）
# ============================================================
def fixed_costas_timing_rx(samples, sps=4, costas_kp=None, costas_ki=None,
                           timing_kp=None, timing_ki=None, init_phase=0.0,
                           init_mu=0.0):
    """
    定点同步接收：二阶 Costas 载波环 + 早迟门定时恢复。

    参数:
        samples: 4 sps 复采样（Q3.11 定点值或浮点同刻度）
        sps:     每符号采样点数（= UPSAMPLE_FACTOR = 4）
        *_kp/*_ki: 环路系数（None 用 `config.RX_CONFIG` 初值）

    返回:
        symbols:      判决/校正后符号（Q3.11）
        phase_err:    每符号载波相位误差（收敛报告用）
        timing_err:   每符号定时误差（收敛报告用）
        info:         {收敛符号数, 稳态相位误差 RMS, 稳态定时误差 RMS}
    """
    cfg = RX_CONFIG
    costas_kp = cfg["costas_kp"] if costas_kp is None else costas_kp
    costas_ki = cfg["costas_ki"] if costas_ki is None else costas_ki
    timing_kp = cfg["timing_kp"] if timing_kp is None else timing_kp
    timing_ki = cfg["timing_ki"] if timing_ki is None else timing_ki

    x = np.asarray(samples, dtype=np.complex128)
    n_sym = len(x) // sps
    # 早迟门间距：±EL（样本）。取 ±1 采样 = ±0.25 符号。
    # 若取 ±0.5 采样（±0.125 符号），误差信号过小，且"符号中点"（相位差 0.5 符号处）
    # 会构成第二个零点，环路易假锁到中点 → 定时不稳（实测 RMS 不收敛）。
    EL = 1.0

    def interp(pos):
        """线性插值取样（pos 为浮点样本位置）。"""
        i0 = int(np.floor(pos))
        frac = pos - i0
        if i0 < 0:
            return x[0]
        if i0 >= len(x) - 1:
            return x[-1]
        return x[i0] * (1 - frac) + x[i0 + 1] * frac

    phase = float(init_phase)          # 载波相位（rad）
    freq = 0.0                         # 频偏积分项（rad/符号）
    mu = float(init_mu)                # 定时位置（样本）
    dt = 0.0                           # 定时积分项

    symbols, pe_hist, te_hist, res_hist = [], [], [], []
    lock_sym = None
    for k in range(n_sym):
        base = k * sps + mu
        early = interp(base - EL)
        on_t = interp(base)
        late = interp(base + EL)

        # --- 早迟门定时误差：|early|² − |late|² ---
        te = float(np.abs(early) ** 2 - np.abs(late) ** 2)
        dt += timing_ki * te
        mu += timing_kp * te + dt
        # 定时常数回中（防漂移），保持 mu ∈ [-sps/2, sps/2)
        while mu >= sps / 2:
            mu -= sps
        while mu < -sps / 2:
            mu += sps

        # --- Costas 相位误差（QPSK 判决导向）---
        r = on_t * np.exp(-1j * phase)
        pe = float(np.sign(r.real) * r.imag - np.sign(r.imag) * r.real)
        freq += costas_ki * pe
        phase += costas_kp * pe + freq
        # 相位归一到 [-π, π)
        phase = (phase + np.pi) % (2 * np.pi) - np.pi

        r = on_t * np.exp(-1j * phase)
        sym_q, _ = quantize_complex(r, FIXED_POINT_CONFIG["sync_out_w"],
                                    FIXED_POINT_CONFIG["sync_out_frac"])
        symbols.append(sym_q)
        pe_hist.append(pe)
        te_hist.append(te)

        # 收敛判据：**残余相位误差**（到最近 QPSK 星座点的角距）的滚动 RMS。
        # 不用 Costas 判别器输出本身——判决导向误差在锁定后仍非零（量级 ~0.05），
        # 拿它当锁相判据会永不触发。
        ang = float(np.angle(r))
        nearest = round((ang - np.pi / 4) / (np.pi / 2)) * (np.pi / 2) + np.pi / 4
        resid = (ang - nearest + np.pi) % (2 * np.pi) - np.pi
        res_hist.append(resid)
        if lock_sym is None and k >= 64:
            w = np.array(res_hist[-64:])
            if np.sqrt(np.mean(w ** 2)) < 0.15:
                lock_sym = k + 1

    symbols = np.array(symbols, dtype=np.complex128)
    pe_hist = np.array(pe_hist)
    te_hist = np.array(te_hist)
    res_hist = np.array(res_hist)
    tail = slice(max(0, n_sym - 256), n_sym)
    info = {
        "lock_symbols": lock_sym,
        "phase_err_rms_tail": float(np.sqrt(np.mean(pe_hist[tail] ** 2))),
        "resid_rms_tail": float(np.sqrt(np.mean(res_hist[tail] ** 2))),
        "timing_err_rms_tail": float(np.sqrt(np.mean(te_hist[tail] ** 2))),
        "n_symbols": n_sym,
    }
    return symbols, pe_hist, te_hist, info


# ============================================================
# Viterbi：硬件忠实版（整数 PM + 16 bit 饱和 + 滑窗回溯）
# ============================================================
def fixed_viterbi_hw(soft_bits, tb_depth=None, win_tb=None):
    """
    硬件忠实的定点 Viterbi 译码（64 态、绝对值分支度量、16 bit 整数路径度量、
    每步减**全局最小值**归一化、滑窗回溯）。

    与 `fixed_modules.fixed_viterbi_decode` 的差别（后者**不能**当 RTL 裁判）：
      1. 路径度量是**整数**（单位 = 软判决 LLR 的 Q3.5 刻度），不是 float；
      2. 每步做 **16 bit 饱和**（模拟 RTL 位宽）；
      3. 回溯按**滑窗深度**（`win_tb`）判决，模拟 RTL 的有限回溯深度。

    参数:
        soft_bits: 软判决 LLR（浮点，正 = 更可能为 0），长度 2N，按 [I0,Q0,I1,Q1,...]
        tb_depth:  回溯存储深度（信息性；None 用 config）
        win_tb:    滑窗判决深度；None 用 config（96）；<=0 → 全回溯（理想对照）

    返回:
        info_bits: 译码信息比特（已去 6 尾比特）
    """
    cfg = RX_CONFIG
    fp = FIXED_POINT_CONFIG
    from ..float_chain.viterbi import _get_state_outputs

    if win_tb is None:
        win_tb = cfg["viterbi_win_tb"]
    metric_frac = fp["viterbi_metric_frac"]

    # 软值 → 整数（Q3.5 刻度）
    s = np.round(np.asarray(soft_bits, dtype=np.float64) * (1 << metric_frac)).astype(np.int64)
    n_sym = len(s) // 2
    num_states = 2 ** (CONV_K - 1)          # K=7 → 64

    output_table, next_state_table = _get_state_outputs()

    PM_MAX = (1 << (fp["viterbi_pm_w"] - 1)) - 1        # 32767
    PM_MIN = -(1 << (fp["viterbi_pm_w"] - 1))           # -32768

    INF = PM_MAX
    pm = np.full(num_states, INF, dtype=np.int64)
    pm[0] = 0

    survivors = np.zeros((n_sym, num_states), dtype=np.uint8)
    best_hist = np.zeros(n_sym, dtype=np.int16)

    for t in range(n_sym):
        s0, s1 = int(s[2 * t]), int(s[2 * t + 1])
        new_pm = np.full(num_states, INF + 1, dtype=np.int64)
        for state in range(num_states):
            base = pm[state]
            if base > INF:
                continue
            for b in (0, 1):
                exp = int(output_table[state, b])
                bit0, bit1 = (exp >> 1) & 1, exp & 1
                bm = (-s0 if bit0 == 0 else s0) + (-s1 if bit1 == 0 else s1)
                ns = int(next_state_table[state, b])
                cand = base + bm
                if cand < new_pm[ns]:
                    new_pm[ns] = cand
                    survivors[t, ns] = state
        # 16 bit 饱和 + 每步减全局最小值
        new_pm = np.clip(new_pm, PM_MIN, PM_MAX)
        m = int(np.min(new_pm))
        new_pm -= m
        pm = new_pm
        best_hist[t] = int(np.argmin(pm))

    # --- 回溯 ---
    def trace_from(t_end, state, steps):
        """返回时刻 (t_end−steps+1 .. t_end) 的输入比特，按时间升序，长度 steps。"""
        bits = []
        for tt in range(t_end, t_end - steps, -1):
            bits.append(state >> (CONV_K - 2))   # K=7 → 输入比特在 state 的 bit5
            state = int(survivors[tt, state])
        return bits[::-1]

    if not win_tb or win_tb <= 0:
        # 全回溯（理想对照，非 RTL 行为）
        decoded = np.array(trace_from(n_sym - 1, int(best_hist[n_sym - 1]), n_sym),
                           dtype=np.int8)
    else:
        # 滑窗回溯：时刻 t 判决 t−W+1；末尾 flush W−1 个（与 RTL 流水行为一致）
        W = min(win_tb, n_sym)
        decoded = [trace_from(t, int(best_hist[t]), W)[0] for t in range(W - 1, n_sym)]
        flush = trace_from(n_sym - 1, int(best_hist[n_sym - 1]), W)
        decoded.extend(flush[-(W - 1):])
        decoded = np.array(decoded, dtype=np.int8)

    k = CONV_K
    info_bits = decoded[:-(k - 1)] if len(decoded) > k - 1 else decoded
    return info_bits
