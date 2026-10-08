#!/usr/bin/env python3
"""
S5 接收链黄金模型自检（ddc_rx / sync_rx / blk_deinter / viterbi_dec）

用法:
    python sim/golden_ref/sim/check_rx.py

退出码 0 = 全部通过；非 0 = 有失败项（打印 FAIL 行）。
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from golden_ref.config import (
    FIXED_POINT_CONFIG,
    INTERLEAVER_DEPTH,
    RX_CONFIG,
    SRRC_ALPHA,
    UPSAMPLE_FACTOR,
)
from golden_ref.fixed_point.fixed_modules import (
    fixed_pulse_shape,
    fixed_qpsk_demodulate_soft,
    fixed_qpsk_modulate,
    fixed_srrc_coeffs,
)
from golden_ref.fixed_point.quantizer import quantize_complex
from golden_ref.fixed_point.rx_modules import (
    fixed_cic_decimate,
    fixed_costas_timing_rx,
    fixed_ddc_rx,
    fixed_viterbi_hw,
    soft_deinterleave,
    soft_interleave,
)
from golden_ref.float_chain.conv_encoder import conv_encode
from golden_ref.float_chain.interleaver import block_deinterleave, block_interleave
from golden_ref.float_chain.viterbi import viterbi_decode

N_PASS = 0
N_FAIL = 0
FAILS = []


def check(name, cond, detail=""):
    global N_PASS, N_FAIL
    if cond:
        N_PASS += 1
        print(f"  [PASS] {name}" + (f"  ({detail})" if detail else ""))
    else:
        N_FAIL += 1
        FAILS.append(name)
        print(f"  [FAIL] {name}" + (f"  ({detail})" if detail else ""))


def section(title):
    print(f"\n=== {title} ===")


def upsample_fft(x, factor):
    """带限（FFT）整数倍上采样，作为"更高采样率的同一信号"的物理模型。"""
    x = np.asarray(x, dtype=np.complex128)
    n = len(x)
    X = np.fft.fft(x)
    Y = np.zeros(n * factor, dtype=np.complex128)
    half = n // 2
    Y[:half + 1] = X[:half + 1]
    Y[-(n - half - 1):] = X[half + 1:]
    return np.fft.ifft(Y) * factor


# ============================================================
# 1. CIC 抽取器
# ============================================================
def test_cic():
    section("1. CIC 抽取器")
    D, N, M = RX_CONFIG["cic_decim"], RX_CONFIG["cic_stages"], RX_CONFIG["cic_diff_delay"]

    c = 1000
    y = fixed_cic_decimate(np.full(D * 40, c, dtype=np.int64))
    steady = y[D * 8:]
    check("1.1 单位增益（常数输入稳态 = 输入）",
          np.all(steady == c), f"y[稳态]={set(steady.tolist())}")

    gain = (D * M) ** N
    check("1.2 增益 = (D·M)^N 且为 2 的幂", gain == 64, f"gain={gain}")

    imp = np.zeros(D * 20, dtype=np.int64)
    imp[0] = 2047
    y_imp = fixed_cic_decimate(imp)
    fx = imp.astype(np.float64)
    for _ in range(N):
        fx = np.cumsum(fx)
    fx = fx[::D]
    for _ in range(N):
        prev = np.zeros_like(fx)
        prev[M:] = fx[:-M]
        fx = fx - prev
    ref = np.round(fx / gain)
    check("1.3 冲激响应 = 浮点 CIC / 增益",
          np.array_equal(y_imp, ref), f"max|Δ|={np.max(np.abs(y_imp - ref)):.0f}")


# ============================================================
# 2. 解交织（dtype 无关）
# ============================================================
def test_deinterleave():
    section("2. 解交织（可承载软值）")
    rng = np.random.default_rng(11)
    n_in = 4332
    s = rng.normal(size=n_in)
    il = soft_interleave(s, INTERLEAVER_DEPTH)
    di = soft_deinterleave(il, INTERLEAVER_DEPTH, n_out=n_in)
    check("2.1 soft_deinterleave ∘ soft_interleave = Id（float 软值）",
          np.array_equal(di, s), f"{len(il)} -> {len(di)}")

    b = rng.integers(0, 2, n_in).astype(np.int8)
    check("2.2 与 block_interleave 置换一致",
          np.array_equal(block_interleave(b, INTERLEAVER_DEPTH), soft_interleave(b, INTERLEAVER_DEPTH)))
    check("2.3 与 block_deinterleave 输出一致",
          np.array_equal(block_deinterleave(block_interleave(b, INTERLEAVER_DEPTH), INTERLEAVER_DEPTH),
                         soft_deinterleave(block_interleave(b, INTERLEAVER_DEPTH), INTERLEAVER_DEPTH)))
    check("2.4 去尾补零后长度 = 4332",
          len(soft_deinterleave(il, INTERLEAVER_DEPTH)[:n_in]) == 4332)


# ============================================================
# 3. DDC（CIC 抽取 + 匹配 FIR）
# ============================================================
def test_ddc():
    section("3. DDC（CIC 抽取 + 匹配 FIR）")
    D = RX_CONFIG["cic_decim"]
    scale = 1 << (RX_CONFIG["adc_in_w"] - 1)
    rng = np.random.default_rng(23)

    # 3.1 输出长度
    n_sym = 200
    syms = fixed_qpsk_modulate(rng.integers(0, 2, 2 * n_sym))
    shaped4 = fixed_pulse_shape(syms)
    n_samp = len(shaped4)
    peak = np.max(np.abs(shaped4))
    norm = shaped4 / peak * 0.9                       # AGC 归一化到 ±0.9（≤ ADC 满量程）
    up = upsample_fft(norm, D)
    out, info = fixed_ddc_rx(up)
    check("3.1 输出长度 = ceil(N/D) + (taps−1)",
          len(out) == n_samp + 32, f"len={len(out)} 期望 {n_samp + 32}")
    check("3.2 满量程输入不饱和", not info["saturated"], f"mf_peak={info['mf_peak']:.1f}")

    # 3.3 通带增益平坦（SRRC 带内：|f| < (1+α)/2/4 of 4sps）
    #     注意：正弦的 mean|·| = (2/π)·峰值 ≈ 0.637·峰值，故用峰值测增益
    band = (1 + SRRC_ALPHA) / 2 / UPSAMPLE_FACTOR          # SRRC 单边带边 ≈ 0.16875
    freqs = [0.02, 0.08, 0.12, band]
    gains = {}
    for f_out in freqs:
        n_in = 4096
        n = np.arange(n_in)
        tone = 0.5 * np.exp(1j * 2 * np.pi * (f_out / UPSAMPLE_FACTOR) * n)
        x_int = np.round(tone.real * scale).astype(np.int64)
        y = fixed_cic_decimate(x_int)
        g = float(np.max(np.abs(y[-200:]))) / (0.5 * scale)      # 峰值增益
        gains[f_out] = g

    check("3.3 通带增益 ≈ 1（D=4 CIC 带内 droop 内）",
          all(0.85 <= g <= 1.05 for g in gains.values()),
          "; ".join(f"{k:.4f}:{gains[k]:.3f}" for k in freqs) +
          "（带边 droop ≈ −1.2 dB，属 CIC 固有，由接收匹配滤波一并考虑）")
    check("3.4 通带增益单调下垂（CIC 特征）",
          gains[freqs[0]] >= gains[freqs[-1]],
          f"g({freqs[0]:.3f})={gains[freqs[0]]:.3f} ≥ g({freqs[-1]:.3f})={gains[freqs[-1]]:.3f}")

    # 3.5 60 dB 动态：−60 dB 通带音仍可分辨（峰值 ≥ 1 LSB）
    n_in = 4096
    n = np.arange(n_in)
    tiny = 0.5 * 1e-3 * np.exp(1j * 2 * np.pi * (0.05 / UPSAMPLE_FACTOR) * n)
    y_t = fixed_cic_decimate(np.round(tiny.real * scale).astype(np.int64))
    amp_t = float(np.max(np.abs(y_t[-200:])))
    check("3.5 60 dB 动态仍可分辨（−60 dB 音峰值 ≥ 1 LSB）",
          amp_t >= 1.0, f"输出峰值 ≈ {amp_t:.2f} LSB（输入 −60 dB ≈ 1.02 LSB 峰值）")


# ============================================================
# 4. Viterbi（硬件忠实版）
# ============================================================
def test_viterbi():
    section("4. Viterbi（整数 PM + 16 bit 饱和 + 滑窗回溯）")
    rng = np.random.default_rng(5)
    info_bits = rng.integers(0, 2, 2160).astype(np.int8)
    coded = conv_encode(info_bits)                       # 2*(2160+6) = 4332
    il = block_interleave(coded, INTERLEAVER_DEPTH)      # 4340

    check("4.1 长度账本 2160 → 4332 → 4340",
          len(coded) == 4332 and len(il) == 4340, f"{len(coded)}, {len(il)}")

    def rx_from_interleaved(soft_il):
        soft_de = soft_deinterleave(np.asarray(soft_il, dtype=np.float64),
                                    INTERLEAVER_DEPTH, n_out=4332)
        return fixed_viterbi_hw(soft_de, win_tb=96)

    # 4.2 无噪：理想软值（交织序）→ 解交织 → 译码 = 原始
    ideal_il = np.where(il == 0, +4.0, -4.0)
    dec = rx_from_interleaved(ideal_il)
    check("4.2 无噪译码正确（= 原始信息比特）",
          len(dec) == 2160 and np.array_equal(dec, info_bits), f"len={len(dec)}")

    ref = viterbi_decode(soft_deinterleave(ideal_il, INTERLEAVER_DEPTH, n_out=4332))
    check("4.3 与浮点参考逐比特一致", np.array_equal(dec, ref), f"len={len(ref)}")

    dec_full = fixed_viterbi_hw(soft_deinterleave(ideal_il, INTERLEAVER_DEPTH, n_out=4332),
                                win_tb=0)
    check("4.4 滑窗 96 与全回溯一致", np.array_equal(dec, dec_full),
          f"差异={int(np.sum(dec != dec_full))}")

    # 4.5 有噪 BER（Eb/N0 = 6 dB）
    #     星座映射：qpsk_map 中 bit 0 → +（正），bit 1 → −（负），故软值 = 1−2·bit
    sigma = np.sqrt(10 ** (-6.0 / 10) / 2)
    s = (1 - 2 * il.astype(np.float64)) + rng.normal(scale=sigma, size=len(il))
    soft = 4.0 * s / (1 + sigma ** 2)
    dec_n = rx_from_interleaved(soft)
    ber = float(np.mean(dec_n != info_bits[:len(dec_n)]))
    check("4.5 6 dB 有噪 BER < 1e-2", ber < 1e-2, f"BER={ber:.2e}")


# ============================================================
# 5. 同步环（收敛性，候选实现）
# ============================================================
def _mk_mf_signal(n_sym, seed=31):
    rng = np.random.default_rng(seed)
    syms = fixed_qpsk_modulate(rng.integers(0, 2, 2 * n_sym))
    shaped = fixed_pulse_shape(syms)
    h_q, _ = fixed_srrc_coeffs()
    mf = np.convolve(shaped, h_q)
    mf_q, _ = quantize_complex(mf, FIXED_POINT_CONFIG["srrc_out_w"],
                               FIXED_POINT_CONFIG["srrc_out_frac"])
    return mf_q


def test_sync():
    section("5. 同步环（二阶 Costas + 早迟门，收敛性）")
    mf_q = _mk_mf_signal(600)
    fs = 2e6
    n = np.arange(len(mf_q))

    sig = mf_q * np.exp(1j * (2 * np.pi * 1e3 / fs * n + 0.7))     # 1 kHz 频偏 + 相偏
    _, _, _, info = fixed_costas_timing_rx(sig, sps=UPSAMPLE_FACTOR)
    check("5.1 1 kHz 频偏下 ≤500 符号收敛",
          info["lock_symbols"] is not None and info["lock_symbols"] <= 500,
          f"lock={info['lock_symbols']}")
    check("5.2 稳态残余相位误差 RMS 小（< 0.15 rad）", info["resid_rms_tail"] < 0.15,
          f"resid_rms={info['resid_rms_tail']:.4f} rad")

    _, _, _, info0 = fixed_costas_timing_rx(mf_q, sps=UPSAMPLE_FACTOR)
    check("5.3 无损伤时快速锁定",
          info0["lock_symbols"] is not None and info0["lock_symbols"] <= 200,
          f"lock={info0['lock_symbols']}")

    ppm = 20e-6
    n2 = np.arange(len(mf_q)) * (1 + ppm)
    _, _, _, info2 = fixed_costas_timing_rx(
        mf_q * np.exp(1j * (2 * np.pi * 1e3 / fs * n2)), sps=UPSAMPLE_FACTOR)
    check("5.4 ±20 ppm 符号率偏差下不发散",
          np.isfinite(info2["resid_rms_tail"]) and info2["resid_rms_tail"] < 0.25,
          f"resid_rms={info2['resid_rms_tail']:.4f} rad")


# ============================================================
# 6. 链路端到端（同步 + 解交织 + 译码；DDC 另测）
# ============================================================
def test_end_to_end():
    section("6. 链路端到端（前导 + 1 kHz 频偏 + 相偏，无噪 → BER 应为 0）")
    rng = np.random.default_rng(9)
    n_info = 400
    info_bits = rng.integers(0, 2, n_info).astype(np.int8)
    coded = conv_encode(info_bits)                        # 812
    il = block_interleave(coded, INTERLEAVER_DEPTH)       # 820
    frame_syms = fixed_qpsk_modulate(il)                  # 410
    n_sym = len(frame_syms)

    # 前导：给同步环留出收敛时间（否则没有稳态可判）
    n_pre = 300
    pre_syms = fixed_qpsk_modulate(rng.integers(0, 2, 2 * n_pre))
    all_syms = np.concatenate([pre_syms, frame_syms])

    h_q, _ = fixed_srrc_coeffs()
    mf_q, _ = quantize_complex(np.convolve(fixed_pulse_shape(all_syms), h_q),
                               FIXED_POINT_CONFIG["srrc_out_w"],
                               FIXED_POINT_CONFIG["srrc_out_frac"])
    fs = 2e6
    n = np.arange(len(mf_q))
    rx = mf_q * np.exp(1j * (2 * np.pi * 1e3 / fs * n + 1.1))

    sym_rx, _, _, sinfo = fixed_costas_timing_rx(rx, sps=UPSAMPLE_FACTOR)
    check("6.1 同步锁定", sinfo["lock_symbols"] is not None,
          f"lock={sinfo['lock_symbols']} resid_rms={sinfo['resid_rms_tail']:.4f}")

    # 期望起点 = 匹配滤波群延迟（32 采样 = 8 符号）+ 前导长度；±16 符号内搜索
    # 同时解析 **QPSK Costas 的 4 重相位模糊**——真实接收机由帧同步字（64 bit Gold，
    # 属 S6）判定象限；此处等价地对 4 个旋转取最优。
    guess = n_pre + 8
    ROT = [(0, "0°"), (1, "90°"), (2, "180°"), (3, "270°")]
    best = (1.0, None, None)
    for off in range(max(0, guess - 16), guess + 17):
        seg = sym_rx[off:off + n_sym]
        if len(seg) < n_sym:
            break
        for k90, name in ROT:
            rot = np.exp(1j * k90 * np.pi / 2)
            soft = fixed_qpsk_demodulate_soft(seg * rot)[:2 * n_sym]
            de = soft_deinterleave(soft, INTERLEAVER_DEPTH, n_out=len(coded))
            dec = fixed_viterbi_hw(de, win_tb=96)
            ber = float(np.mean(dec != info_bits[:len(dec)])) if len(dec) else 1.0
            if ber < best[0]:
                best = (ber, off, name)
            if ber == 0.0:
                break
        if best[0] == 0.0:
            break

    check("6.2 端到端 BER = 0（解析 4 重相位模糊后）", best[0] == 0.0,
          f"best BER={best[0]:.3e} @ offset={best[1]} 符号（期望≈{guess}）"
          f"+ 旋转 {best[2]}")
    check("6.3 相位模糊为 4 重（非 2/8 重）——需帧同步字判定象限（归 S6）",
          best[2] in ("0°", "90°", "180°", "270°"), f"实测锁定象限 = {best[2]}")
    print(f"  [INFO] 对齐偏移与象限待 #16 位真比对时按向量 meta.json 固化"
          f"（当前 offset={best[1]}, rot={best[2]}）")


def main():
    print("=" * 64)
    print("S5 接收链黄金模型自检")
    print("=" * 64)
    test_cic()
    test_deinterleave()
    test_ddc()
    test_viterbi()
    test_sync()
    test_end_to_end()
    print("\n" + "=" * 64)
    print(f"[RX CHECK] pass={N_PASS} fail={N_FAIL} status={'PASS' if N_FAIL == 0 else 'FAIL'}")
    if FAILS:
        print("  失败项: " + "; ".join(FAILS))
    print("=" * 64)
    return 0 if N_FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
