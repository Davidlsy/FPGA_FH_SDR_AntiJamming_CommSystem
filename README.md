# FHSS / SDR Anti-Jamming Communication System on AMD Zynq

A fully digital frequency-hopping spread-spectrum (FHSS) and software-defined-radio
(SDR) communication system on AMD Zynq-7000 (XC7Z020) with an AD9363 agile RF
transceiver. Built for reliable data transmission under hostile electromagnetic
interference, and verified over the air between two boards.

## Overview

Both ends hop across a 16-channel set following an LFSR pseudorandom pattern at
100–1000 hop/s (three selectable rates), while convolutional coding, block
interleaving, QPSK/BPSK adaptive mapping, and SRRC pulse shaping keep the link
reliable in a jamming environment.

The design follows a **PS/PL control-plane / data-plane split**: every
microsecond-level real-time signal-processing path is closed entirely inside the
programmable logic, while the ARM processing system handles only millisecond-level
control and human–machine interaction over an AXI4-Lite register bridge. The PS GEM
gigabit MAC replaces a hand-written RGMII MAC, and the RF transceiver is initialized
and reconfigured on the fly by a PL hardware state machine with no software
involvement — the key difference from designs that simply drive the AD9363 from an ADI
Linux driver.

## Architecture

**PL — data plane, 100% real-time**

- TX chain: framing → convolutional encoding (171,133)₈ → block interleaving →
  QPSK/BPSK mapping → SRRC shaping + NCO upconversion
- RX chain: DDC (CIC decimation + matched FIR + digital AGC) → Costas carrier
  recovery + early-late gate symbol sync → Viterbi soft-decision decoding →
  de-interleaving
- Hopping layer: LFSR-16 pattern generator, phase-continuous NCO, hop-sync FSM
  (scan / acquire / track / re-acquire), TOD time base
- Anti-jamming layer: 1024-point pipelined FFT interference sensing + bad-channel
  blacklist
- RF interface: table-driven SPI state machine performing all AD9363 configuration

**PS — control plane, millisecond-level**

- Runtime reconfiguration: frequency, gain, bandwidth, hop rate, blacklist version
- Status collection and forwarding: BER, RSSI, sync state, spectral peak
- Gigabit Ethernet to the host PC via the PS GEM hard core

## Key Features

- **Phase-continuous NCO hopping** — each hop updates only the frequency tuning
  word; the phase accumulator is never reset, so no spectral regrowth appears at hop
  boundaries and switching latency stays below 1 µs.
- **On-chip sense–decide–hop loop** — interference detection, blacklist decision,
  and frequency switching all complete inside a single chip, with no software in the
  loop.
- **Hardware-only RF bring-up** — the AD9363 initialization sequence is executed by
  a PL state machine, giving deterministic startup independent of any OS or driver.

## Performance

| Metric | Value |
|---|---|
| Hopping rate | 100 / 500 / 1000 hop/s |
| Channel set | 16 channels, LFSR-16 pattern |
| Over-the-air throughput | ≥ 1 Mbps |
| BER (no jamming) | < 1e-5 |
| Hop-sync acquisition / re-acquisition | < 1 s / < 2 s |
| BER improvement at 0 dB JSR | ≥ 1 order of magnitude vs. fixed-frequency |

All RTL modules are validated bit-exactly against a MATLAB floating-point golden
reference, with BER curves overlaid for quantization-loss assessment (see
`data/s1_ber_baseline/`).

## Build

Requires Vivado / Vitis ML 2021.2. From a clean checkout:

```bash
# smoke project: create -> synthesize -> implement -> bitstream
vivado -mode batch -source build/create_smoke_project.tcl
```

---

## 工程结构

FPGA_FH_SDR_AntiJamming_CommSystem/
│
├── .gitattributes              # Git 属性
├── .gitignore                  # 忽略规则
├── LICENSE                     # MIT
├── README.md                   # 工程说明
│
├── src/                        # 【RTL 源码】
│   ├── fhss_top.v              #   冒烟顶层：50MHz 计数器 + LED 心跳
│   └── constraints/
│       └── fhss_zynq_timing.xdc  # 时序约束（跨板复用，唯一副本）
│
├── board/                      # 【板级约束】
│   └── fhss_zynq_pins.xdc      #   引脚 + IOSTANDARD（每板一份，唯一副本）
│
├── sim/                        # 【仿真】
│   ├── tb_fhss_top.v           #   冒烟 testbench → [SMOKE] PASS/FAIL
│   ├── framework/              #   S2 自动比对框架：golden 向量导出 + 逐拍比对器 + TB 模板
│   ├── models/ad9363/          #   S2 AD9363 SPI 行为模型（板卡的仿真替身，自测 6 项）
│   ├── models/channel/         #   S2 信道模型库（AWGN / CFO / SFO / 多径，29 项统计核验）
│   ├── golden_ref/             #   S1 黄金参考链（Python 包 golden_ref）
│   └── float_ref/              #   V2.x MATLAB 归档链重跑与对照
│       ├── README.md           #     运行方式 / 路径约定 / 出口门槛
│       ├── config.py           #     系统参数 + FIXED_POINT_CONFIG
│       ├── run_ber.py          #     BER 仿真入口 → data/s1_ber_baseline/
│       ├── generate_spec.py    #     生成定点规格书 → docs/spec/
│       ├── float_chain/        #     浮点模块（卷积/交织/QPSK/SRRC/AWGN/同步/Viterbi）
│       ├── fixed_point/        #     定点模块 + 量化器
│       └── sim/                #     链路 BER 仿真 + SNR 损失分析
│
├── build/                      # 【一键重建脚本】
│   ├── create_smoke_project.tcl  # Vivado batch：建工程→综合→实现→bit
│   └── vivado_smoke/           #   冒烟工程与实现产物（综合/实现报告、bit 等）
│
├── sw/                         # 【上位机 / 软件】software
│   └── （Python 上位机等，产物 sw/build、sw/dist 已 ignore）
│
├── data/                       # 【数据 / 激励 / 参考结果】
│   └── s1_ber_baseline/        #   S1 BER 基线
│       ├── ber_curve.png       #     浮点 vs 定点 BER 曲线
│       ├── ber_float.npz       #     浮点原始数据
│       ├── ber_fixed.npz       #     定点原始数据
│       └── snr_loss_table.csv  #     SNR 损失表（链路 + 节点位宽）
│
├── skill/                      # 【技能 / 脚本 / 工具说明】
│
└── docs/                       # 【文档】
    ├── amd-board-requirements.html
    ├── amd-fhss-sim-only-plan.html          # 纯仿真路线 S0–S10
    ├── fpga-fhss-amd-implementation-plan.html
    ├── pins.md                 # 引脚映射表（与 board/fhss_zynq_pins.xdc 1:1）
    ├── spec/
    │   └── fixed_point_spec.md #   S1 定点规格书（评审冻结基准）
    └── report/
        ├── env.md              # 开发环境记录
        └── s1_archive_compare.md  # S1 MATLAB 归档对照报告

## License

This project is licensed under the [MIT License](LICENSE).
