# S1 浮点黄金参考与定点化 - 仓库包名 golden_ref
"""
数字通信系统黄金参考链：卷积(171,133) / 交织10 / QPSK / SRRC α=0.35 / AWGN / 同步 / Viterbi 译码
提供浮点参考实现与定点化实现，用于 BER 基线比对与定点 SNR 损失评估。

路径约定:
- 源码/脚本: sim/golden_ref/
- BER 基线数据: data/s1_ber_baseline/
- 定点规格书: docs/spec/fixed_point_spec.md
"""

__version__ = "1.0.0"
