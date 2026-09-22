"""
Viterbi 译码器 - 软输入硬输出
卷积码 (171, 133)_8, K=7, 码率 1/2
"""
import numpy as np
from ..config import CONV_GEN_POLY, CONV_K


def _get_state_outputs():
    """
    预计算每个状态在输入 0/1 时的输出 (2 bit) 和下一状态
    返回:
        output_table: shape (2^(K-1), 2), 每个状态的输出 (编码为整数 0-3)
        next_state_table: shape (2^(K-1), 2), 每个状态的下一状态
    """
    num_states = 2 ** (CONV_K - 1)
    output_table = np.zeros((num_states, 2), dtype=np.int8)
    next_state_table = np.zeros((num_states, 2), dtype=np.int16)

    # 生成多项式的二进制表示 (K 位)
    gen_polys_bin = []
    for poly in CONV_GEN_POLY:
        bits_poly = [(poly >> (CONV_K - 1 - i)) & 1 for i in range(CONV_K)]
        gen_polys_bin.append(bits_poly)

    for state in range(num_states):
        for input_bit in [0, 1]:
            # 当前完整寄存器 = [input_bit] + state 的二进制表示
            # state 是 K-1 位的
            full_reg = [input_bit] + [(state >> (CONV_K - 2 - i)) & 1 for i in range(CONV_K - 1)]

            # 计算输出
            out = 0
            for j, poly_bits in enumerate(gen_polys_bin):
                xor_sum = 0
                for i in range(CONV_K):
                    if poly_bits[i]:
                        xor_sum ^= full_reg[i]
                out |= (xor_sum << (1 - j))  # 第一路是高位

            output_table[state, input_bit] = out

            # 下一状态 = (state >> 1) | (input_bit << (K-2))
            next_state = (state >> 1) | (input_bit << (CONV_K - 2))
            next_state_table[state, input_bit] = next_state

    return output_table, next_state_table


def _compute_branch_metric(soft_bits, expected_output, metric_type="abs"):
    """
    计算分支度量

    参数:
        soft_bits: 当前时刻的 2 个软值 (LLR, 正值表示 0)
        expected_output: 期望输出 (0-3, 2 bit)
        metric_type: "abs" (绝对值和) 或 "euclidean" (欧氏距离)

    返回:
        metric: 分支度量 (越小越好)
    """
    # expected_output 的两位
    bit0 = (expected_output >> 1) & 1  # 第一路 (I)
    bit1 = expected_output & 1          # 第二路 (Q)

    if metric_type == "abs":
        # 软值正 -> 0 可能性大
        # 如果期望 bit 是 0，软值越大，度量越小 (越好)
        # 如果期望 bit 是 1，软值越小(越负)，度量越小
        m0 = -soft_bits[0] if bit0 == 0 else soft_bits[0]
        m1 = -soft_bits[1] if bit1 == 0 else soft_bits[1]
        return m0 + m1
    else:
        # 欧氏距离: 将软值映射为符号再比较
        # 简化: 直接用软值差
        expected_soft = np.array([1.0 if b == 0 else -1.0 for b in [bit0, bit1]])
        return np.sum((soft_bits - expected_soft) ** 2)


def viterbi_decode(soft_bits, metric_type="abs"):
    """
    Viterbi 软译码

    参数:
        soft_bits: 软输入比特 LLR, shape (2*N,), 正表示 0
        metric_type: "abs" 或 "euclidean"

    返回:
        decoded: 译码后信息比特, shape (M,), M = N - (K-1)  [尾比特被去除]
    """
    soft_bits = np.asarray(soft_bits, dtype=np.float64)
    n_total_bits = len(soft_bits)
    assert n_total_bits % 2 == 0, "软输入比特数必须为偶数"

    n_symbols = n_total_bits // 2  # 编码符号数 (每符号 2 bit)
    num_states = 2 ** (CONV_K - 1)

    # 预计算状态转移表
    output_table, next_state_table = _get_state_outputs()

    # 初始化路径度量
    # 状态 0 初始度量为 0，其他为无穷大
    path_metrics = np.full(num_states, np.inf, dtype=np.float64)
    path_metrics[0] = 0.0

    # 回溯指针: 每个时刻每个状态的前驱
    # 为节省内存，只存最近几帧的指针
    survivors = np.zeros((n_symbols, num_states), dtype=np.int16)

    # 前向递推
    for t in range(n_symbols):
        current_soft = soft_bits[2 * t:2 * t + 2]

        new_metrics = np.full(num_states, np.inf, dtype=np.float64)

        for state in range(num_states):
            if path_metrics[state] == np.inf:
                continue

            for input_bit in [0, 1]:
                # 期望输出
                expected = output_table[state, input_bit]
                # 分支度量
                bm = _compute_branch_metric(current_soft, expected, metric_type)
                # 下一状态
                next_state = next_state_table[state, input_bit]
                # 新的路径度量
                new_pm = path_metrics[state] + bm

                # 更新
                if new_pm < new_metrics[next_state]:
                    new_metrics[next_state] = new_pm
                    survivors[t, next_state] = state

        path_metrics = new_metrics

    # 回溯: 从 0 状态开始 (因为归零编码，最后状态应为 0)
    # 如果不归零，选度量最小的状态
    best_state = 0  # 归零编码，终止状态为 0
    if path_metrics[best_state] == np.inf:
        best_state = np.argmin(path_metrics)

    decoded_rev = []
    state = best_state

    for t in range(n_symbols - 1, -1, -1):
        prev_state = survivors[t, state]
        # 从 prev_state 到 state 的转移对应的输入比特
        # prev_state 的最高位就是输入比特
        # 因为 next_state = (prev_state >> 1) | (input_bit << (K-2))
        # 所以 input_bit = state >> (K-2)
        input_bit = state >> (CONV_K - 2)
        decoded_rev.append(input_bit)
        state = prev_state

    # 反转得到正确顺序
    decoded = np.array(decoded_rev[::-1], dtype=np.int8)

    # 去除尾比特 (最后 K-1 个比特是尾比特)
    info_bits = decoded[:-(CONV_K - 1)] if len(decoded) > CONV_K - 1 else decoded

    return info_bits
