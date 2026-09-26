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

The S2 verification infrastructure — comparison framework, AD9363 SPI behaviour
model, channel model library, jammer source, and the PS/PL AXI VIP environment —
passes its acceptance run in one shot: 5/5 suites, 1538 checks, 0 errors, 47.6 s
(`sim/run_s2_acceptance.ps1`; report in `docs/report/s2_verification.md`).

## Build

Requires Vivado / Vitis ML 2021.2. From a clean checkout:

```bash
# smoke project: create -> synthesize -> implement -> bitstream
vivado -mode batch -source build/create_smoke_project.tcl
```

---

## 当前状态（阶段、已交付、下一步）

> 本节是仓库的实际状态。上文 Overview / Architecture / Key Features / Performance 描述的是实施手册
> V3.0.1 的目标设计（终态）；两者的差集以本节与下列边界表为准。

### 编号体系

工程有两套编号线，本 README 与各报告里的 `S` 编号指**纯仿真路线的验证阶段 S0–S10**
（定义见 `docs/amd-fhss-sim-only-plan.html`）。`docs/pins.md`、`docs/report/env.md` 另用 AMD 实施手册的
阶段号 `P0′–P7′` 与板级闸 `BV-01/BV-02`（定义见 `docs/fpga-fhss-amd-implementation-plan.html`）。两套
编号不通用。

### 进度

| 阶段 | 内容 | 状态 | 证据 |
|---|---|---|---|
| S0 | 工具链冒烟：综合 → 实现 → bitstream + 行为仿真 | **完成** | `build/create_smoke_project.tcl`、`sim/tb_fhss_top.v`（`[SMOKE] PASS`） |
| S1 | 浮点 / 定点黄金参考链 + BER 基线，定点规格书冻结 | **完成**（2026-09-22 冻结） | `sim/golden_ref/`、`data/s1_ber_baseline/`、`docs/spec/fixed_point_spec.md` |
| S2 | 验证基础设施四件套（比对框架 / AD9363 模型 / 信道库 / 干扰源）+ PS-PL 协同仿真 | **完成**（2026-09-25 验收：5/5 套件、1538 项、0 错误） | `sim/run_s2_acceptance.ps1`、`docs/report/s2_verification.md` |
| S3 | `spi_master` + `ad9363_cfg` 对 AD9363 模型做逐条（地址, 数据, 延时）比对 | **进行中** | `src/spi_master.v` 已入库；`src/ad9363_cfg.v` 与其 testbench 仍在工作区，尚未入库 |
| S4+ | 发射链 / 接收链 / 跳频层 / 干扰感知 RTL | **未开始** | 仅 `sim/framework/vectors/qpsk_map/` 向量已就绪，等 S4-P1 接真实 DUT |

### 已知边界

- **板卡未到货**。`board/fhss_zynq_pins.xdc` 只有 `sys_clk` 与 4 个 LED 已填，AD9363 数据 / SPI / 按键
  全是注释占位；`src/constraints/fhss_zynq_timing.xdc` 仅 `[1][6]` 生效。**当前 bitstream 只用于工具流
  验证，不得下载到板卡**；引脚冻结（P1′-S1）、AD9363 真机回读（BV-01）、排针信号完整性（BV-02）
  均在板卡到货后补。人读引脚表与状态总览见 `docs/pins.md`。
- S2 五项之间没有联合仿真：RF 侧（信道 + 干扰源）接口一致但未串联，控制侧（SPI / AXI）与 RF 侧
  也无交叉；登记见 `sim/README.md` §6 与 `docs/report/s2_verification.md` §5/§6。
- `sim/framework/` 的比对框架目前只跑过自测（`golden-consistent` 桩 DUT），还没有真实模块用过它的
  模板——所以"所有 RTL 模块已逐比特比对"目前仅对 S0/S1 的链级结论成立，不是逐模块结论。
- `sw/`、`skill/` 目前只有 `.gitkeep`。
- 复现入口：S1 见 `sim/golden_ref/README.md`，S2 见 `docs/report/s2_verification.md` §8。

## 工程结构

```text
FPGA_FH_SDR_AntiJamming_CommSystem/
│
├── .gitattributes              # Git 属性（文本 / 二进制判定）
├── .gitignore                  # 忽略规则（本地产物一律不入库，见文末图例）
├── .pre-commit-config.yaml     # 提交前检查（CI 的"文本卫生"作业复用同一套配置）
├── LICENSE                     # MIT
├── README.md                   # 工程说明（本文件）
├── requirements-dev.txt        # S1 / S2 Python 脚本与 pre-commit 的依赖
│
├── .github/workflows/          # 【CI】
│   ├── ci.yml                  #   文本卫生（pre-commit）+ S1 黄金参考链快速冒烟
│   └── fpga-sim.yml            #   S2 统一验收（自托管 Windows runner，需 Vivado 在 PATH）
│
├── src/                        # 【RTL 源码】
│   ├── fhss_top.v              #   S0 冒烟顶层：50MHz 计数器 + LED 心跳
│   ├── spi_master.v            #   S3 AD9363 SPI 主端
│   ├── ad9363_cfg.v *          #   S3 AD9363 初始化序列状态机（仅在工作区，尚未入库）
│   └── constraints/
│       └── fhss_zynq_timing.xdc  # 时序约束（跨板复用，唯一副本；当前 [1][6] 生效，[2][3][4][5A][7] 分阶段启用）
│
├── board/                      # 【板级约束】
│   └── fhss_zynq_pins.xdc      #   物理属性（每板一份，换板只替换此文件；当前仅 sys_clk + 4 LED 已填，AD9363 / 按键为占位）
│
├── sim/                        # 【仿真】入口见 sim/README.md
│   ├── README.md               #   仿真树总入口：S2 五件套关系、约定与运行顺序
│   ├── tb_fhss_top.v           #   S0 冒烟 testbench → [SMOKE] PASS/FAIL
│   ├── run_s2_acceptance.ps1   #   S2 统一验收：五项串跑 → [S2 ACCEPTANCE] 判据行（另有 .bat）
│   ├── framework/              #   S2 自动比对框架：golden 向量导出 + 逐拍比对器 + TB 模板
│   ├── models/ad9363/          #   S2 AD9363 SPI 行为模型（板卡的仿真替身）
│   ├── models/channel/         #   S2 信道模型库（AWGN / CFO / SFO / 多径）
│   ├── models/jammer/          #   S2 干扰注入源（单音/多音/扫频/部分频带 + JSR 标定）
│   ├── vip/                    #   S2 PS/PL 协同仿真环境（AXI VIP 主端 + PS 软件序列；gen/ 本地生成可重建）
│   ├── golden_ref/             #   S1 黄金参考链（Python 包 golden_ref）——全工程唯一正确性基准
│   │   ├── config.py           #     系统参数 + FIXED_POINT_CONFIG（位宽唯一来源）
│   │   ├── run_ber.py          #     BER 仿真入口 → data/s1_ber_baseline/
│   │   ├── generate_spec.py    #     生成定点规格书 → docs/spec/
│   │   ├── float_chain/        #     浮点模块（卷积/交织/QPSK/SRRC/AWGN/同步/Viterbi）
│   │   ├── fixed_point/        #     定点模块 + 量化器
│   │   └── sim/                #     链路 BER 仿真 + SNR 损失分析
│   ├── float_ref/              #   V2.x MATLAB 归档链重跑与对照（对照证据，不是基准）
│   │   ├── run_ber_sweep.m     #     归档脚本重跑 → results/
│   │   └── results/            #     归档 BER 数据（csv / mat）
│   └── logs/                   #   运行日志（*.log 本地生成）
│
├── build/                      # 【一键重建脚本】
│   ├── create_smoke_project.tcl  # Vivado batch：建工程→综合→实现→bit（`-tclargs sim` 只跑行为仿真）
│   └── vivado_smoke/ *         #   冒烟工程与实现产物（每次运行整目录重建）
│
├── sw/                         # 【上位机 / 软件】当前只有 .gitkeep（Python 上位机待开发；产物 sw/**/build、sw/dist 不入库）
│
├── skill/                      # 【技能 / 脚本 / 工具说明】当前只有 .gitkeep（比对框架尚未沉淀为技能包）
│
├── data/                       # 【数据 / 激励 / 参考结果】
│   ├── s1_ber_baseline/        #   S1 BER 基线
│   │   ├── ber_curve.png       #     浮点 vs 定点 BER 曲线
│   │   ├── ber_float.npz       #     浮点原始数据
│   │   ├── ber_fixed.npz       #     定点原始数据
│   │   └── snr_loss_table.csv  #     SNR 损失表（链路 + 节点位宽）
│   ├── s2_channel_stats/       #   S2 信道模型核验表
│   └── s2_jammer_stats/        #   S2 干扰源核验表
│
└── docs/                       # 【文档】
    ├── fpga-fhss-amd-implementation-plan.html  # 实施手册 V3.0.1（主线，阶段号 P0′–P7′）
    ├── amd-fhss-sim-only-plan.html             # 纯仿真路线备选方案（阶段号 S0–S10）
    ├── amd-board-requirements.html             # 选板论证（AX7020 / PYNQ-Z2）
    ├── s4-tx-chain-implementation-dark.html    # S4 TX 链实现说明（约 4.3 MB，内嵌字体）
    ├── pins.md                 # 人读引脚映射表（与 board/fhss_zynq_pins.xdc 1:1，含待填清单与状态总览）
    ├── spec/
    │   ├── fixed_point_spec.md #   S1 定点规格书（评审冻结基准，由 generate_spec.py 生成）
    │   └── freeze_status.json  #   冻结状态的机器可读来源
    ├── report/
    │   ├── env.md              #   开发环境记录
    │   ├── s1_archive_compare.md  # S1 MATLAB 归档对照报告
    │   ├── s1_spec_review.md   #   S1 定点规格书评审记录
    │   └── s2_verification.md  #   S2 验收报告（5/5 套件，1538 项，0 错误）
    └── Xilinx-Zynq-7000 系列开发板AX7020/   # ALINX 官方资料（用户手册 / 管脚表 / 原理图 / PCB）
```

> **图例**：无标记 = 已入库，clone 即可获得；`*` = 本地生成、不入库，可重建。仓库内另有
> `desktop.ini`（Windows 系统文件）与 `.ruff_cache/` 等本地产物，均按 `.gitignore` 忽略。
> `docs/Xilinx-Zynq-7000 系列开发板AX7020/` 是仓库内唯一的中文文件名目录，按交付纪律需在收尾时
> 改为英文目录名。

## License

This project is licensed under the [MIT License](LICENSE).
