"""
BER 仿真 - 浮点参考链与定点链 BER 曲线对比
"""
import numpy as np
from ..config import (
    EB_N0_RANGE_DB, DEFAULT_FRAME_LEN, DEFAULT_NUM_FRAMES,
    MIN_ERROR_BITS, MAX_BITS_PER_EBN0, UPSAMPLE_FACTOR,
    INTERLEAVER_DEPTH, CONV_K
)
from ..float_chain.conv_encoder import conv_encode
from ..float_chain.interleaver import block_interleave, block_deinterleave
from ..float_chain.qpsk_mod import qpsk_modulate, qpsk_demodulate_soft
from ..float_chain.srrc import pulse_shape, matched_filter, srrc_coeffs
from ..float_chain.awgn import add_awgn
from ..float_chain.sync import sync_receive
from ..float_chain.viterbi import viterbi_decode


def float_link_transmit(info_bits, h_srrc=None):
    """
    浮点发射链路：编码 -> 交织 -> QPSK -> 脉冲成形

    返回:
        tx_signal: 发射信号 (采样率 sps 倍符号率)
    """
    # 1. 卷积编码
    encoded = conv_encode(info_bits)

    # 2. 交织 (确保长度是 depth 的整数倍，补零到最近的整数倍)
    n_pad = (INTERLEAVER_DEPTH - len(encoded) % INTERLEAVER_DEPTH) % INTERLEAVER_DEPTH
    encoded_padded = np.concatenate([encoded, np.zeros(n_pad, dtype=np.int8)])
    interleaved = block_interleave(encoded_padded)

    # 3. QPSK 调制
    symbols = qpsk_modulate(interleaved)

    # 4. 脉冲成形
    if h_srrc is None:
        h_srrc = srrc_coeffs()
    tx_signal = pulse_shape(symbols, h=h_srrc)

    return tx_signal, len(encoded_padded), n_pad


def float_link_receive(rx_signal, encoded_len_padded, n_pad, h_srrc=None):
    """
    浮点接收链路：匹配滤波 -> 同步 -> 软解调 -> 解交织 -> Viterbi 译码

    返回:
        decoded: 译码后信息比特
    """
    # 1. 匹配滤波
    if h_srrc is None:
        h_srrc = srrc_coeffs()
    mf_symbols, _ = matched_filter(rx_signal, h=h_srrc)

    # 截断到正确长度
    n_expected_symbols = encoded_len_padded // 2
    if len(mf_symbols) > n_expected_symbols:
        mf_symbols = mf_symbols[:n_expected_symbols]

    # 2. 同步 (简化: 直接用匹配滤波输出，假设同步理想)
    # 对于黄金参考，同步简化处理
    sync_symbols, _ = sync_receive(mf_symbols, sps=1)

    # 3. 软解调
    llrs = qpsk_demodulate_soft(sync_symbols)

    # 4. 解交织
    deinterleaved = block_deinterleave(llrs)

    # 截断到原始编码长度 (去掉补零)
    deinterleaved = deinterleaved[:encoded_len_padded]

    # 5. Viterbi 译码
    decoded = viterbi_decode(deinterleaved)

    return decoded


def simulate_ber_float(eb_n0_db, frame_len=DEFAULT_FRAME_LEN,
                       num_frames=DEFAULT_NUM_FRAMES,
                       min_error_bits=MIN_ERROR_BITS,
                       max_bits=MAX_BITS_PER_EBN0, seed=None):
    """
    浮点 BER 仿真 (单 Eb/N0 点)

    参数:
        eb_n0_db: Eb/N0 (dB)
        frame_len: 每帧信息比特数
        num_frames: 仿真帧数
        min_error_bits: 最小误比特数
        max_bits: 最大仿真比特数
        seed: 随机种子

    返回:
        ber: 误比特率
        total_bits: 总仿真比特数
        total_errors: 总误比特数
    """
    if seed is not None:
        np.random.seed(seed)

    h_srrc = srrc_coeffs()
    total_errors = 0
    total_bits = 0

    frame_count = 0
    while total_errors < min_error_bits and total_bits < max_bits and frame_count < num_frames * 100:
        # 生成随机信息比特
        info_bits = np.random.randint(0, 2, size=frame_len, dtype=np.int8)

        # 发射
        tx_signal, encoded_len_padded, n_pad = float_link_transmit(info_bits, h_srrc)

        # AWGN 信道
        # bit_rate = 每符号信息比特数 = QPSK(2) * 码率(1/2) = 1
        noisy_signal, _ = add_awgn(tx_signal, eb_n0_db, bit_rate=1.0, sps=UPSAMPLE_FACTOR)

        # 接收
        try:
            decoded = float_link_receive(noisy_signal, encoded_len_padded, n_pad, h_srrc)
        except Exception:
            frame_count += 1
            continue

        # 计算误比特 (截断到实际长度)
        n_compare = min(len(info_bits), len(decoded))
        errors = np.sum(info_bits[:n_compare] != decoded[:n_compare])

        total_errors += errors
        total_bits += n_compare
        frame_count += 1

    ber = total_errors / total_bits if total_bits > 0 else 0.0
    return ber, total_bits, total_errors


def run_ber_simulation_float(eb_n0_range=None, **kwargs):
    """
    运行全 Eb/N0 范围的浮点 BER 仿真

    返回:
        eb_n0_db_list: Eb/N0 列表
        ber_list: 对应的 BER 列表
    """
    if eb_n0_range is None:
        eb_n0_range = EB_N0_RANGE_DB

    ber_list = []
    for eb_n0 in eb_n0_range:
        ber, bits, errors = simulate_ber_float(eb_n0, **kwargs)
        ber_list.append(ber)
        print(f"Eb/N0 = {eb_n0:.1f} dB, BER = {ber:.2e}, "
              f"总比特 = {bits}, 误比特 = {errors}")

    return np.array(eb_n0_range), np.array(ber_list)
