"""
定点 BER 仿真与 SNR 损失分析
"""
from pathlib import Path

import numpy as np
from ..config import (
    EB_N0_RANGE_DB, DEFAULT_FRAME_LEN, DEFAULT_NUM_FRAMES,
    MIN_ERROR_BITS, MAX_BITS_PER_EBN0, INTERLEAVER_DEPTH
)
from ..float_chain.conv_encoder import conv_encode
from ..float_chain.interleaver import block_interleave, block_deinterleave
from ..fixed_point.fixed_modules import (
    fixed_qpsk_modulate, fixed_pulse_shape, fixed_matched_filter,
    fixed_add_awgn, fixed_sync_receive, fixed_qpsk_demodulate_soft,
    fixed_viterbi_decode, fixed_srrc_coeffs
)


def fixed_link_transmit(info_bits, h_q=None):
    """
    定点发射链路

    返回:
        tx_signal_q: 定点发射信号
        encoded_len_padded: 编码+补零后的长度
        n_pad: 补零数
    """
    # 1. 卷积编码 (位宽极窄，等效整数运算)
    encoded = conv_encode(info_bits)

    # 2. 交织 (比特级，无量化损失)
    n_pad = (INTERLEAVER_DEPTH - len(encoded) % INTERLEAVER_DEPTH) % INTERLEAVER_DEPTH
    encoded_padded = np.concatenate([encoded, np.zeros(n_pad, dtype=np.int8)])
    interleaved = block_interleave(encoded_padded)

    # 3. 定点 QPSK 调制
    symbols_q = fixed_qpsk_modulate(interleaved)

    # 4. 定点脉冲成形
    if h_q is None:
        h_q, _ = fixed_srrc_coeffs()
    tx_signal_q = fixed_pulse_shape(symbols_q, h_q=h_q)

    return tx_signal_q, len(encoded_padded), n_pad


def fixed_link_receive(rx_signal_q, encoded_len_padded, n_pad, h_q=None):
    """
    定点接收链路

    返回:
        decoded: 译码后信息比特
    """
    # 1. 定点匹配滤波
    if h_q is None:
        h_q, _ = fixed_srrc_coeffs()
    mf_symbols_q, _ = fixed_matched_filter(rx_signal_q, h_q=h_q)

    # 截断到正确长度
    n_expected_symbols = encoded_len_padded // 2
    if len(mf_symbols_q) > n_expected_symbols:
        mf_symbols_q = mf_symbols_q[:n_expected_symbols]

    # 2. 定点同步
    sync_symbols_q, _ = fixed_sync_receive(mf_symbols_q)

    # 3. 定点软解调
    llrs_q = fixed_qpsk_demodulate_soft(sync_symbols_q)

    # 4. 解交织 (软值)
    deinterleaved = block_deinterleave(llrs_q)
    deinterleaved = deinterleaved[:encoded_len_padded]

    # 5. 定点 Viterbi 译码
    decoded = fixed_viterbi_decode(deinterleaved)

    return decoded


def simulate_ber_fixed(eb_n0_db, frame_len=DEFAULT_FRAME_LEN,
                       num_frames=DEFAULT_NUM_FRAMES,
                       min_error_bits=MIN_ERROR_BITS,
                       max_bits=MAX_BITS_PER_EBN0, seed=None):
    """
    定点 BER 仿真 (单 Eb/N0 点)

    返回:
        ber: 误比特率
        total_bits: 总仿真比特数
        total_errors: 总误比特数
    """
    if seed is not None:
        np.random.seed(seed)

    h_q, _ = fixed_srrc_coeffs()
    total_errors = 0
    total_bits = 0

    frame_count = 0
    while total_errors < min_error_bits and total_bits < max_bits and frame_count < num_frames * 100:
        info_bits = np.random.randint(0, 2, size=frame_len, dtype=np.int8)

        # 定点发射
        tx_signal_q, encoded_len_padded, n_pad = fixed_link_transmit(info_bits, h_q)

        # 定点 AWGN
        noisy_signal_q = fixed_add_awgn(tx_signal_q, eb_n0_db)

        # 定点接收
        try:
            decoded = fixed_link_receive(noisy_signal_q, encoded_len_padded, n_pad, h_q)
        except Exception:
            frame_count += 1
            continue

        n_compare = min(len(info_bits), len(decoded))
        errors = np.sum(info_bits[:n_compare] != decoded[:n_compare])

        total_errors += errors
        total_bits += n_compare
        frame_count += 1

    ber = total_errors / total_bits if total_bits > 0 else 0.0
    return ber, total_bits, total_errors


def run_ber_simulation_fixed(eb_n0_range=None, **kwargs):
    """
    运行全 Eb/N0 范围的定点 BER 仿真

    返回:
        eb_n0_db_list, ber_list
    """
    if eb_n0_range is None:
        eb_n0_range = EB_N0_RANGE_DB

    ber_list = []
    for eb_n0 in eb_n0_range:
        ber, bits, errors = simulate_ber_fixed(eb_n0, **kwargs)
        ber_list.append(ber)
        print(f"[定点] Eb/N0 = {eb_n0:.1f} dB, BER = {ber:.2e}, "
              f"总比特 = {bits}, 误比特 = {errors}")

    return np.array(eb_n0_range), np.array(ber_list)


def _find_ebn0_at_ber(eb_n0_db, ber_curve, target_ber):
    """对数域插值求 BER=target 对应的 Eb/N0；曲线未覆盖则返回 None。"""
    e = np.asarray(eb_n0_db, dtype=float)
    b = np.asarray(ber_curve, dtype=float)
    order = np.argsort(e)
    e, b = e[order], b[order]
    # 仅用 BER>0 的点插值；两端为 0 时视为未覆盖
    pos = b > 0
    if not np.any(pos):
        return None
    # 在相邻非零段上找 target 交叉
    floor = float(b[pos].min())
    for i in range(len(b) - 1):
        b0, b1 = float(b[i]), float(b[i + 1])
        if b0 <= 0:
            b0 = floor
        if b1 <= 0:
            b1 = floor
        lo, hi = min(b0, b1), max(b0, b1)
        if not (lo <= target_ber <= hi):
            continue
        y0, y1 = np.log10(b0), np.log10(b1)
        yt = np.log10(target_ber)
        if y1 == y0:
            return float(e[i])
        return float(e[i] + (e[i + 1] - e[i]) * (yt - y0) / (y1 - y0))
    return None


def compute_snr_loss(float_ber, fixed_ber, eb_n0_db, target_ber=1e-5):
    """
    计算定点相对于浮点的 SNR 损失 (dB)。
    目标 BER 未落在曲线有效段时返回 None。
    """
    ebn0_float = _find_ebn0_at_ber(eb_n0_db, float_ber, target_ber)
    ebn0_fixed = _find_ebn0_at_ber(eb_n0_db, fixed_ber, target_ber)
    if ebn0_float is None or ebn0_fixed is None:
        return None
    return ebn0_fixed - ebn0_float


def snr_loss_analysis(float_ber_curve, fixed_ber_curve, eb_n0_db,
                      target_bers=None):
    """
    全曲线 SNR 损失分析

    返回:
        losses: {target_ber: loss_db 或 None}
        ber_ratio: 每点定点/浮点 BER 比值
    """
    if target_bers is None:
        target_bers = [1e-2, 5e-3, 2e-3, 1e-3, 5e-4, 2e-4, 1e-4, 1e-5]
    losses = {}
    for target in target_bers:
        losses[target] = compute_snr_loss(
            float_ber_curve, fixed_ber_curve, eb_n0_db, target
        )

    ber_ratio = np.asarray(fixed_ber_curve, float) / np.maximum(
        np.asarray(float_ber_curve, float), 1e-20
    )
    return losses, ber_ratio


def export_snr_loss_table(output_csv, eb_n0_db, float_ber, fixed_ber,
                          losses=None, ber_ratio=None, threshold_db=0.5):
    """
    导出 S1 SNR 损失表 CSV。

    分区:
      1) 同 Eb/N0 逐点 BER 对比
      2) 目标 BER 处链路 SNR 损失（出口门槛）
      3) 关键节点位宽/量化噪声（理论，来自 config；逐节点仿真损失待 L2/L3）
    """
    import csv
    from ..config import FIXED_POINT_CONFIG, QUANT_MODE, OVERFLOW_MODE
    from ..fixed_point.quantizer import get_quant_range, get_quantization_noise_power

    output_csv = Path(output_csv)
    output_csv.parent.mkdir(parents=True, exist_ok=True)

    if losses is None or ber_ratio is None:
        losses, ber_ratio = snr_loss_analysis(float_ber, fixed_ber, eb_n0_db)

    module_desc = {
        "conv_encoder_out": "卷积编码器输出",
        "interleaver_out": "交织器输出",
        "qpsk_out": "QPSK调制输出I/Q",
        "srrc_out": "SRRC输出",
        "srrc_coeff": "SRRC系数",
        "awgn_out": "AWGN信道输出",
        "sync_out": "同步输出",
        "viterbi_metric": "Viterbi分支度量",
        "viterbi_pm": "Viterbi路径度量",
        "cic_stage": "CIC各级(预留)",
    }

    with open(output_csv, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["section", "node", "metric", "float", "fixed", "loss_db_or_value", "pass", "note"])

        # --- 1. 逐点 BER ---
        e = np.asarray(eb_n0_db, float)
        bf = np.asarray(float_ber, float)
        bx = np.asarray(fixed_ber, float)
        ratio = np.asarray(ber_ratio, float) if ber_ratio is not None else bx / np.maximum(bf, 1e-20)
        for i, (ei, bfi, bxi, ri) in enumerate(zip(e, bf, bx, ratio)):
            w.writerow([
                "link_ber_point",
                f"ebn0_{ei:g}dB",
                "BER",
                f"{bfi:.6e}",
                f"{bxi:.6e}",
                f"ratio={ri:.4f}",
                "",
                "" if bfi > 0 or bxi > 0 else "both_zero_or_no_errors",
            ])

        # --- 2. 目标 BER 链路损失 ---
        reached_losses = []
        for target, loss in losses.items():
            if loss is None:
                w.writerow([
                    "link_snr_loss",
                    "full_chain",
                    f"BER={target:.0e}",
                    "",
                    "",
                    "",
                    "",
                    "curve_does_not_reach_target",
                ])
            else:
                ok = "YES" if loss <= threshold_db else "NO"
                reached_losses.append(loss)
                w.writerow([
                    "link_snr_loss",
                    "full_chain",
                    f"BER={target:.0e}",
                    "",
                    "",
                    f"{loss:.4f}",
                    ok,
                    f"threshold={threshold_db}dB",
                ])

        if reached_losses:
            mx = max(reached_losses)
            w.writerow([
                "gate",
                "full_chain",
                "max_snr_loss_among_reached_targets",
                "",
                "",
                f"{mx:.4f}",
                "YES" if mx <= threshold_db else "NO",
                f"threshold={threshold_db}dB; unreached BER not counted",
            ])
        else:
            w.writerow([
                "gate",
                "full_chain",
                "max_snr_loss_among_reached_targets",
                "",
                "",
                "",
                "UNKNOWN",
                "no target BER reached on both curves",
            ])

        # --- 3. 关键节点理论量化（规格书位宽） ---
        for key, desc in module_desc.items():
            w_key = f"{key}_w"
            f_key = f"{key}_frac"
            if key == "cic_stage":
                widths = FIXED_POINT_CONFIG.get("cic_stage_w", [])
                fracs = FIXED_POINT_CONFIG.get("cic_stage_frac", [])
                for i, (ww, ff) in enumerate(zip(widths, fracs), start=1):
                    _, _, step = get_quant_range(ww, ff)
                    nq = get_quantization_noise_power(ww, ff)
                    w.writerow([
                        "node_theory",
                        f"cic_stage{i}",
                        f"width={ww},frac={ff}",
                        "",
                        "",
                        f"quant_noise_power={nq:.6e};step={step:.6e}",
                        "",
                        f"quant={QUANT_MODE},overflow={OVERFLOW_MODE}; empirical_node_loss=pending",
                    ])
                continue
            if w_key not in FIXED_POINT_CONFIG:
                continue
            ww = FIXED_POINT_CONFIG[w_key]
            ff = FIXED_POINT_CONFIG[f_key]
            _, _, step = get_quant_range(ww, ff)
            nq = get_quantization_noise_power(ww, ff)
            w.writerow([
                "node_theory",
                key,
                f"width={ww},frac={ff}",
                desc,
                "",
                f"quant_noise_power={nq:.6e};step={step:.6e}",
                "",
                f"quant={QUANT_MODE},overflow={OVERFLOW_MODE}; empirical_node_loss=pending",
            ])

    return str(output_csv)
