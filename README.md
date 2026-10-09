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

The S3 RF-configuration pair (`spi_master` + `ad9363_cfg`) passes its own
acceptance run the same way: 4/4 suites, 4718 checks, 0 errors, 21.7 s
(`sim/run_s3_acceptance.ps1`; report in `docs/report/s3_verification.md`). Caveat
worth stating: the register-sequence *content* is still a smoke placeholder
pending the real table, so S3's evidence proves the table-driven state machine
and the per-entry comparison mechanism — not the chip's bring-up.

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
| S3 | `spi_master` + `ad9363_cfg` 对 AD9363 模型做逐条（地址, 数据, 延时）比对 | **进行中**（代码与机制完成，序列表内容待补，报告待评审） | 两模块 RTL 已入库；`sim/run_s3_acceptance.ps1` 四套件 4718 项 0 错误；`docs/report/s3_verification.md`、评审清单 `docs/report/s3_review.md`（结论待填） |
| S4-P0..P2 | 帧格式与接口冻结（P0）+ `frame_tx` / `conv_enc` / `qpsk_map`（P1）+ `blk_inter` 存储迁移（P2） | **完成**（2026-09-28 验收：18/18 套件、0 错误；`-Full` 另含 1000 帧与 10⁶ bit 长跑判据） | `sim/run_s4_acceptance.ps1`、`docs/report/s4_verification.md`、`docs/spec/{frame_format,s4_tx_interface}.md` |
| S4-P3 | `srrc_duc` 手写多相版 + FIR Compiler IP 版 + NCO/DUC 混频；三项决策冻结 | **完成**（2026-10-07 收口：两版逐拍位真一致，四套件各 8712 拍 0 错误；NCO/DUC SFDR −85.45 dBc 达标） | `src/srrc_duc{,_fir}.v`、`sim/run_srrc{,_fir}_check.bat`、`docs/spec/s4_tx_interface.md` §6.1/§8、`docs/spec/s4_tx_p3_freeze_draft.md`、`sim/golden_ref/sim/sfdr_analysis.py`；**S4 报告尚未补 P3 章节** |
| S4-P4 | IP vs 手写三栏对比（资源 / Fmax / SFDR） | **完成**（2026-10-08：手写版 LUT 5581/FF 523/DSP 18/Fmax 33.79 MHz；FIR IP 版 LUT 5261/FF 1256/DSP 18/Fmax 59.13 MHz；两版 61.44 MHz 下均时序违规，见已知边界） | `build/p4_compare.tcl`、`docs/report/s4-p4-ip-vs-handwritten-comparison.html` |
| S4-P5 | 五模块整链收口（`frame_tx`→`conv_enc`→`blk_inter`→速率适配→`qpsk_map`→`srrc_duc` 串联位真比对） | **完成**（2026-10-08：随机帧载荷端到端 256 字节 → 8712 采样，frame/edge 两用例各 8712 拍 0 错误，**S4 出口门槛达成**） | `src/tx_chain_top.v`、`sim/run_tx_chain_check.bat`、`sim/framework/tb/tb_tx_chain_compare.sv`、`sim/framework/export_vectors.py`（新增 tx_chain 端到端向量） |
| S5-P0/预备 | 接收链接口冻结 + 黄金参考补齐（DDC/同步/Viterbi/解交织）+ 框架 `SKIP_OUT` 与接收链向量导出 | **完成**（2026-10-08：P0 四项决策冻结；黄金模型自检 24/24、框架自测 9/9） | `docs/spec/s5_rx_interface.md`、`sim/golden_ref/fixed_point/rx_modules.py`、`sim/framework/export_vectors.py` |
| S5 #2 | `ddc_rx` 数字下变频：CIC 3 级抽取（D=4，48 bit 卷绕）+ 33 抽头匹配 FIR，RTL + 位真比对 | **完成**（2026-10-09：rand 8064 拍、edge 320 拍逐拍 0 错误；黄金模型自检 27/27） | `src/ddc_rx.v`、`sim/run_ddc_rx_check.bat`、`sim/framework/tb/tb_ddc_rx_compare.sv` |
| S5 #3 | `sync_rx` 符号级同步：位真语义 + **同步环参数标定冻结**（Q1.19）+ RTL + 位真比对 | **完成**（2026-10-09：rand/freq/rate/edge 四用例共 2160 符号逐符号 0 错误；标定 126 例全过） | `src/sync_rx.v`、`sim/run_sync_rx_check.bat`、`sim/framework/tb/tb_sync_rx_compare.sv`、`docs/spec/fixed_point_spec.md` v1.1 §3.4 |
| S5 #4 | `blk_deinter` 块解交织：逆 `blk_inter` 置换 + 去 8 bit 补零（乒乓双缓冲），RTL + 位真比对 | **完成**（2026-10-09：frame 2166 拍、rand 8664 拍逐拍 0 错误；黄金模型自检 27/27） | `src/blk_deinter.v`、`sim/run_blk_deinter_check.bat`、`sim/framework/tb/tb_blk_deinter_compare.sv` |
| S5 #5 | `viterbi_dec` 软判决 Viterbi 译码：64 态 ACS + 16 bit PM 归一化 + 回溯 96（寄存器交换），RTL + 位真比对 + **BER 三路同序列对比** | **完成**（2026-10-09：frame 2160 bit、rand 8640 bit、edge 2160 bit 逐比特 0 错误；黄金模型自检 27/27；BER 对比最大 SNR 损失 0.004 dB、无平底、MATLAB `vitdec` 同序列 2.48 Mbit 叠图一致） | `src/viterbi_dec.v`、`sim/run_viterbi_dec_check.bat`、`sim/framework/tb/tb_viterbi_dec_compare.sv`、`sim/golden_ref/run_viterbi_ber.py`、`docs/report/s5_viterbi_ber.md` |

### 已知边界

- **板卡未到货**。`board/fhss_zynq_pins.xdc` 只有 `sys_clk` 与 4 个 LED 已填，AD9363 数据 / SPI / 按键
  全是注释占位；`src/constraints/fhss_zynq_timing.xdc` 仅 `[1][6]` 生效。**当前 bitstream 只用于工具流
  验证，不得下载到板卡**；引脚冻结（P1′-S1）、AD9363 真机回读（BV-01）、排针信号完整性（BV-02）
  均在板卡到货后补。人读引脚表与状态总览见 `docs/pins.md`。
- S2 五项之间没有联合仿真：RF 侧（信道 + 干扰源）接口一致但未串联，控制侧（SPI / AXI）与 RF 侧
  也无交叉；登记见 `sim/README.md` §6 与 `docs/report/s2_verification.md` §5/§6。
- `sim/framework/` 的比对框架现已由**十一个 DUT**（`frame_tx` / `conv_enc` / `qpsk_map` / `blk_inter`
  / `srrc_duc` 手写版与 FIR IP 版 / `tx_chain` / `sync_rx` / `ddc_rx` / `blk_deinter` / `viterbi_dec`）在使用，并为此扩展成"激励/期望长度解耦 +
  激励节奏 + 前导跳过"（S4-P0 / S5）：原实现只支持一入一出，装不下成帧（256 拍进 / 2160 拍出）、
  上采样这类 N:M 模块与 4:1 同步环。每加一条判据都配了专门证伪它的用例（`sim/framework/README.md` §7）。
  **尚未用过框架的只剩跳频层**；接收链四个模块 `ddc_rx` / `sync_rx` / `blk_deinter` / `viterbi_dec`
  已全部完整位真接入（0 错误）。
- S4 的五个模块现已全部落地（`frame_tx` / `conv_enc` / `blk_inter` / `qpsk_map` / `srrc_duc` 双版），
  P0–P5 已收口，**任务卡的 S4 出口门槛已达成**（五模块位真比对全过：单模块 + IP 对比 + 整链端到端）。
  `docs/report/s4_verification.md` 尚未补 P3–P5 章节，引用 P3/P4/P5 结论分别以
  `docs/spec/s4_tx_interface.md` §0/§6.1/§8、`docs/report/s4-p4-ip-vs-handwritten-comparison.html`、
  `src/tx_chain_top.v` + `sim/run_tx_chain_check.bat` 为准。
- **P5 整链的速率衔接（关键设计点）**：前三级与 `qpsk_map` 都在"符号节拍"下工作，而 `blk_inter`
  的读侧是"写满 bank 后连续 2170 拍吐符号"（突发，与输入快慢无关），`srrc_duc` 却需要"每 4 拍
  1 个符号"（符号率 = 采样率/4）。二者相差 4 倍，故 `tx_chain_top` 在 `blk_inter`→`qpsk_map` 之间
  插了一个符号速率适配器（收 2170 个 2 bit 符号入缓冲，再以 1/4 节拍放出；放这里而非 `qpsk_map`
  之后，是因为此刻只有 2 bit/符号，比 24 bit 小一个数量级）。
- **P4 时序收敛问题（待处理，后续 S10 前解决）**：两版 `srrc_duc` 在 61.44 MHz 目标下均时序违规——
  手写版 WNS = −13.32 ns（Fmax 33.79 MHz，被 SRRC 组合 MAC 路径拖死）、FIR IP 版 WNS = −0.64 ns
  （Fmax 59.13 MHz）；NCO LUT 分布式 ROM 占约 75% LUT。报告建议「NCO LUT 改 BRAM 同步 ROM +
  混频前插一级流水」后再复查整链时序。注意：决策 2 冻结的**起步采样率 2 MSPS 下两版均够用**
  （33.79 MHz ≫ 2 MHz），61.44 MHz 是最终吞吐目标，收敛问题留待后续处理。
- **P3 的证据口径**：四条 srrc 判据（手写版 `srrc-frame` / `srrc-edge`、FIR IP 版
  `srrc-fir-frame` / `srrc-fir-edge`，各 8712 拍 0 错误）由分项脚本 `sim/run_srrc_check.bat` 与
  `sim/run_srrc_fir_check.bat` 给出。统一入口 `sim/run_s4_acceptance.ps1` 的套件表虽已加入
  `srrc-frame` / `srrc-edge`，但 `sim/logs/s4_acceptance.log` 仍停在 2026-09-28 那次 18 套件的
  `-Full` 运行，**加套件后未重跑**；FIR IP 版两套件不在统一入口内，且必须先跑
  `build/gen_fir_compiler.tcl` 生成 IP。`docs/report/s4_verification.md` 也尚未补 P3 章节（该报告
  仍写"P3–P5 未开始"），引用 P3 结论时以 `docs/spec/s4_tx_interface.md` §0/§6.1/§8 为准。
- `srrc_duc` 用 S1 冻结的 **33 抽头**（`span 8 × sps 4 + 1`），与任务卡写的"31 抽头"是有意偏差：
  位真裁判必须同源，改抽头数要重跑 S1 BER 基线。登记在 `docs/spec/s4_tx_interface.md` §7。
- `docs/spec/freeze_status.json` 覆盖定点规格（v1.1 = S1 位宽 2026-09-22 + `sync_rx` 同步环参数
  2026-10-09），未覆盖 S4/S5 接口规格；两者的冻结状态分别以 `docs/spec/s4_tx_interface.md` §0、
  `docs/spec/s5_rx_interface.md` §0（v1.2）为准。
- **S5 `sync_rx` 的证据口径**：rand/freq/rate/edge 四用例共 2160 符号逐符号位真 0 错误，由
  `sim/run_sync_rx_check.bat` 串跑给出（日志 `sim/logs/sync_rx_*`）。同步环 Q1.19 系数的唯一来源是
  `config.RX_CONFIG`（`fixed_point_spec.md` v1.1 §3.4 只是它的渲染）；改系数必须依次重跑
  `calib_sync_rx.py` 标定 → `export_vectors.py --module sync_rx` 重导向量 → `run_sync_rx_check.bat`，
  三步缺一即失去"位真裁判同源"。
- **S5 `ddc_rx` 的证据口径**：rand/edge 两用例共 8384 拍逐拍位真 0 错误（激励 32128 + 1152 拍 →
  期望 8064 + 320 拍，D = 4 抽取），由 `sim/run_ddc_rx_check.bat` 串跑给出（日志 `sim/logs/ddc_rx_*`）。
  黄金裁判 `fixed_ddc_rx` 的匹配 FIR 输出侧是 **Q3.11 整数刻度**，末级量化只剩 round half-to-even +
  饱和，**不能再走 `quantize`（幅度语义会二次量化、刻度翻倍全体饱和）**——踩过一次的坑，
  改模型前先读 `rx_modules.py` 该处注释；`check_rx.py` 27/27 是该修复后的自检口径。
- `blk_inter` 的两种存储实现（`blk_mem_gen` IP 版与 RTL 推断版）已跑同一套向量、位真一致；
  资源/时序的定量对比属 P4，本阶段不出口径。
- S4 长跑判据（1000 帧 / 10⁶ bit）的向量体积约 9 MB，按 `.gitignore` 的"S4 长跑向量"段不入库，
  由固定种子确定性重生成（`export_vectors.py --case long`）。
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
│   ├── ad9363_cfg.v            #   S3 AD9363 初始化序列状态机（表驱动 + cfg_rom，$readmemh 加载）
│   ├── frame_tx.v              #   S4-P1 帧成形：Gold 同步字 + 帧头 + 256B + CRC16（双缓冲）
│   ├── frame_tx_sync.vh        #   S4-P1 同步字常量（生成物，见 sim/golden_ref/gen_frame_sync.py）
│   ├── conv_enc.v              #   S4-P1 卷积编码 (171,133)₈，含 6 bit 归零尾比特与输入弹性缓冲
│   ├── blk_inter.v             #   S4-P2 块交织（写行读列，双缓冲 + 输入弹性缓冲）
│   ├── blk_mem_1w1r.v          #   S4-P2 存储器副本：blk_mem_gen IP 版 / RTL 推断版同接口
│   ├── qpsk_map.v              #   S4-P1 QPSK 直移映射（纯组合）
│   ├── srrc_duc.v              #   S4-P3 手写 33 抽头多相 SRRC(×4) + NCO + DUC 混频（位真基准）
│   ├── srrc_duc_fir.v          #   S4-P3 同功能 FIR Compiler IP 版（与手写版逐拍位真一致）
│   ├── srrc_coeff.vh           #   S4-P3 SRRC 33 抽头系数（生成物，见 sim/golden_ref/gen_srrc_duc.py）
│   ├── srrc_fir.coe            #   S4-P3 FIR Compiler 系数源（.coe → IP，产物 build/ip/fir_compiler/）
│   ├── nco_lut.mem             #   S4-P3 NCO 四分之一波 LUT（16384 × 16 bit，$readmemh 加载）
│   ├── tx_chain_top.v          #   S4-P5 发射链整链串联顶层（五模块 + blk_inter→qpsk_map 符号速率适配）
│   ├── ddc_rx.v                #   S5 数字下变频：CIC 3 级抽取（D=4）+ 33 抽头匹配 FIR（12 bit ADC → 4 sps Q3.11）
│   ├── sync_rx.v               #   S5 符号级同步：二阶 Costas + 早迟门定时 + 软解调（1/符号更新）
│   ├── blk_deinter.v           #   S5 块解交织：逆 blk_inter 置换 + 去 8 bit 补零（乒乓双缓冲）
│   ├── viterbi_dec.v           #   S5 软判决 Viterbi 译码：64 态 ACS + 16 bit PM 归一化 + 回溯 96（寄存器交换）
│   └── constraints/
│       └── fhss_zynq_timing.xdc  # 时序约束（跨板复用，唯一副本；当前 [1][6] 生效，[2][3][4][5A][7] 分阶段启用）
│
├── board/                      # 【板级约束】
│   └── fhss_zynq_pins.xdc      #   物理属性（每板一份，换板只替换此文件；当前仅 sys_clk + 4 LED 已填，AD9363 / 按键为占位）
│
├── sim/                        # 【仿真】入口见 sim/README.md
│   ├── README.md               #   仿真树总入口：两条线如何汇合、五件套关系、约定与运行顺序
│   ├── tb_fhss_top.v           #   S0 冒烟 testbench → [SMOKE] PASS/FAIL
│   ├── run_s2_acceptance.ps1   #   S2 统一验收：五项串跑 → [S2 ACCEPTANCE] 判据行（另有 .bat）
│   ├── run_s3_acceptance.ps1   #   S3 统一验收：四项串跑 → [S3 ACCEPTANCE] 判据行
│   ├── run_s4_acceptance.ps1   #   S4 统一验收：位真比对 + 证伪用例 → [S4 ACCEPTANCE]（-Full 带长跑判据）
│   ├── run_srrc_check.bat      #   S4-P3 srrc_duc 手写版分项跑（frame / edge 两套件）
│   ├── run_srrc_fir_check.bat  #   S4-P3 srrc_duc_fir FIR IP 版分项跑（需先建 build/ip/fir_compiler）
│   ├── run_tx_chain_check.bat  #   S4-P5 发射链整链位真比对（frame / edge 两用例）
│   ├── run_ddc_rx_check.bat    #   S5 ddc_rx 位真比对（rand / edge 两用例串跑）
│   ├── run_sync_rx_check.bat   #   S5 sync_rx 位真比对（rand / freq / rate / edge 四用例串跑）
│   ├── run_blk_deinter_check.bat  # S5 blk_deinter 位真比对（frame / rand 两用例串跑）
│   ├── run_viterbi_dec_check.bat  # S5 viterbi_dec 位真比对（frame / rand / edge 三用例串跑）
│   ├── framework/              #   S2 自动比对框架：golden 向量导出 + 逐拍比对器 + TB 模板
│   │   ├── README.md           #     向量契约 / TB 时序契约 / 判据 / 自测结论 / 有意偏离
│   │   ├── export_vectors.py   #     从 golden_ref 确定性导出向量（--case long 出长跑向量，不入库）
│   │   ├── run_selftest.ps1    #     框架自测（长度解耦 / 激励节奏 / 前导跳过等契约各有证伪用例；另有 .bat）
│   │   ├── hdl/tb_vec_cmp.sv   #     逐拍比对器：stim/expect 长度解耦 + stim_period 节奏 + stim_count
│   │   ├── tb/                 #     各模块 TB（见下）
│   │   │   ├── tb_vector_selftest.sv        #   框架自测用例
│   │   │   ├── tb_module_template.sv        #   新模块 TB 模板（照 README §6 十分钟起一个）
│   │   │   ├── tb_{qpsk_map,conv_enc,frame_tx,blk_inter,srrc_duc}_compare.sv  # 五模块位真 TB（-d 切用例）
│   │   │   ├── tb_{tx_chain,sync_rx,ddc_rx,blk_deinter,viterbi_dec}_compare.sv  #  S4-P5 整链 / S5 sync_rx、ddc_rx、blk_deinter、viterbi_dec 位真 TB
│   │   │   ├── tb_srrc_duc_fir_compare.sv   #   FIR IP 版 SRRC TB（与手写版同向量同判据）
│   │   │   ├── tb_blk_inter_burst.sv        #   blk_inter 突发打散量化（TB 侧带独立解交织模型）
│   │   │   └── tb_fir_check.sv              #   FIR Compiler IP 单体对齐核验（延迟 / 前 3 拍空转）
│   │   ├── run_fir_check.bat   #     FIR IP 版 SRRC 的独立核验入口（tb_fir_check）
│   │   ├── fir_srrc.mif        #     FIR IP 系数档（与 src/srrc_fir.coe 同源，.bat 会拷到工作目录）
│   │   ├── vectors/            #     各用例向量：{stim,expect}.hex + meta.json（长跑向量按 .gitignore 不入库）
│   │   ├── logs/ *             #     分项日志（本地生成）
│   │   ├── snap_*.wdb *        #     波形快照（本地生成）
│   │   └── xsim.dir/ *         #     编译与仿真数据库（本地生成）
│   ├── models/ad9363/          #   S2 SPI 行为模型 + S3 射频配置模块的验证落点
│   │   ├── README.md           #     模型与 TB 的约定、CPOL/CPHA 口径
│   │   ├── ad9363_spi_model.sv #     S2 模型本体（寄存器堆 + 回读校验 + 异常注入）
│   │   ├── ad9363_defs.vh      #     SPI 事务帧格式与指令位域常量
│   │   ├── ad9363_regs_def.vh  #     寄存器地址与位域定义（cfg 表、模型、TB 共用）
│   │   ├── ad9363_init_table.csv  #  S3 初始化表唯一人类可读来源（现为烟测占位序列，见 s3 报告 §8）
│   │   ├── gen_init_table.py   #     CSV → ad9363_init.mem + ad9363_init_expect.txt 两条独立编码路径
│   │   ├── spi_slave_gen.sv    #     通用 CPOL/CPHA 从机 BFM
│   │   ├── tb_spi_master*.sv   #     spi_master 冒烟 / 1200 向量随机 + 五类异常
│   │   ├── tb_ad9363_spi_model.sv  #  S2 模型自测
│   │   ├── tb_ad9363_cfg.sv    #     cfg 全链路 R1–R9（逐条三元组比对、暂停恢复、异常注入）
│   │   └── run_*.bat / run_iv.sh   #  分项运行入口（含 iverilog 交叉核对）
│   ├── models/channel/         #   S2 信道模型库（AWGN / CFO / SFO / 多径 + ch_top）；核验脚本 → data/s2_channel_stats/
│   ├── models/jammer/          #   S2 干扰注入源（单音/多音/扫频/部分频带 + JSR 标定）；核验 → data/s2_jammer_stats/
│   ├── vip/                    #   S2 PS/PL 协同仿真环境（AXI VIP 主端 + PS 软件序列；gen/ 本地生成可重建）
│   ├── golden_ref/             #   S1 黄金参考链（Python 包 golden_ref）——全工程唯一正确性基准
│   │   ├── README.md           #     复现入口与包内约定
│   │   ├── config.py           #     系统参数 + FIXED_POINT_CONFIG（位宽唯一来源）+ RX_CONFIG（接收链）+ FRAME_* + DUC_CONFIG
│   │   ├── run_ber.py          #     BER 仿真入口 → data/s1_ber_baseline/
│   │   ├── run_viterbi_ber.py  #     S5 viterbi_dec BER 三路同序列对比入口（含 MATLAB vitdec 交叉）→ data/s5_viterbi_ber/
│   │   ├── generate_spec.py    #     生成定点规格书 → docs/spec/
│   │   ├── gen_frame_sync.py   #     S4 帧同步字 → src/frame_tx_sync.vh（带 --check）
│   │   ├── gen_srrc_duc.py     #     S4-P3 系数与 LUT → src/srrc_coeff.vh、src/nco_lut.mem、src/srrc_fir.coe
│   │   ├── calib_sync_rx.py    #     S5 sync_rx 环路系数标定（工况×种子×幅度 126 例 → Q1.19 冻结值）
│   │   ├── float_chain/        #     浮点模块（卷积/交织/QPSK/SRRC/AWGN/同步/Viterbi）
│   │   │   └── framing.py      #       S4 帧层裁判：m 序列 / Gold / CRC16 / 成帧与解析
│   │   ├── fixed_point/        #     定点模块 + 量化器
│   │   │   ├── duc.py          #       S4-P3 DUC 裁判：NCO 相位累加 + 四分之一波 LUT + 复数混频
│   │   │   └── rx_modules.py   #       S5 接收链位真裁判：fixed_ddc_rx / fixed_sync_rx_hw / 解交织 / Viterbi
│   │   └── sim/                #     链路 BER 仿真 + SNR 损失分析 + 帧层 / DUC / SFDR 自检
│   │       └── sfdr_analysis.py  #    S4-P3 SFDR：NCO/DUC 判据项（−85.45 dBc）+ SRRC 频谱报告项
│   ├── float_ref/              #   V2.x MATLAB 归档链重跑与对照（对照证据，不是基准）
│   │   ├── run_ber_sweep.m     #     归档脚本重跑 → results/（另 run_ber_sweep_export.m 导数据）
│   │   ├── run_viterbi_vitdec.m  #   S5 viterbi_dec BER 对比的 MATLAB 侧桥（vitdec 同序列）
│   │   ├── compare_matlab_python.py  # MATLAB 归档链 vs golden_ref 的对照脚本
│   │   └── results/            #     归档 BER 数据（csv / mat）
│   └── logs/ *                 #   运行日志（*.log 本地生成）
│
├── build/                      # 【一键重建脚本】
│   ├── create_smoke_project.tcl  # Vivado batch：建工程→综合→实现→bit（`-tclargs sim` 只跑行为仿真）
│   ├── gen_blk_mem_gen.tcl     # S4-P2 生成 blk_inter 用的 blk_mem_gen（产物 build/ip/ 不入库，约 40 s）
│   ├── gen_fir_compiler.tcl    # S4-P3 生成 srrc_duc_fir 用的 fir_srrc（FIR Compiler 7.2，插值 ×4）
│   ├── run_fir.bat             # 上面那支 tcl 的一键入口（日志落 build/fir_gen.log）
│   ├── ip/ *                   #   IP 产物：blk_mem_gen/blk_mem_gen_1w1r、fir_compiler/fir_srrc（tcl 即单一来源）
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
│   ├── s2_channel_stats/       #   S2 信道模型核验表（channel_stats_table.csv）
│   ├── s2_jammer_stats/        #   S2 干扰源核验表（jammer_stats_table.csv）
│   └── s5_viterbi_ber/         #   S5 viterbi_dec BER 三路同序列对比（三线叠图 / SNR 损失表 / npz；matlab_io/ 过路 .mat 不入库）
│
└── docs/                       # 【文档】
    ├── fpga-fhss-amd-implementation-plan.html  # 实施手册 V3.0.1（主线，阶段号 P0′–P7′）
    ├── amd-fhss-sim-only-plan.html             # 纯仿真路线备选方案（阶段号 S0–S10）
    ├── amd-board-requirements.html             # 选板论证（AX7020 / PYNQ-Z2）
    ├── s4-tx-chain-implementation-dark.html    # S4 TX 链实现说明（约 4.3 MB，内嵌字体）
    ├── pins.md                 # 人读引脚映射表（与 board/fhss_zynq_pins.xdc 1:1，含待填清单与状态总览）
    ├── spec/
    │   ├── fixed_point_spec.md #   定点规格书 v1.1（S1 位宽 + S5 sync_rx 同步环参数 §3.4，由 generate_spec.py 生成）
    │   ├── frame_format.md     #   S4 帧格式规格书（帧层首次定义，已冻结）
    │   ├── s4_tx_interface.md  #   S4 发射链接口规格书 v1.1（流控 / 位序 / 拍数账本 / NCO 语义 / §8 P3 冻结记录）
    │   ├── s4_tx_p3_freeze_draft.md  # S4-P3 三项冻结决策全文（含 2026-10-07 评审确认结果）
    │   ├── s5_rx_interface.md  #   S5 接收链接口规格书 v1.2（逆映射 / 拍数账本 / 同步环语义，环路参数已解悬置）
    │   ├── s5_rx_p0_freeze_draft.md  # S5 P0 四项决策全文（含 2026-10-08 评审确认结果）
    │   └── freeze_status.json  #   定点规格冻结状态（v1.1）的机器可读来源
    ├── report/
    │   ├── env.md              #   开发环境记录
    │   ├── s1_archive_compare.md  # S1 MATLAB 归档对照报告
    │   ├── s1_spec_review.md   #   S1 定点规格书评审记录
    │   ├── s2_verification.md  #   S2 验收报告（5/5 套件，1538 项，0 错误）
    │   ├── s3_verification.md  #   S3 验证报告（4/4 套件，4718 项，0 错误；含异常注入覆盖矩阵与遗留项）
    │   ├── s3_review.md        #   S3 报告评审清单与记录（清单已建，结论待填）
    │   ├── s4_verification.md  #   S4 验证报告（P0–P2：18/18 套件，0 错误；P3 章节待补，见 §6/§7）
    │   └── s5_viterbi_ber.md   #   S5 viterbi_dec BER 三路同序列对比报告（§4.4 判据：0.004 dB / 无平底 / vitdec 叠图）
    └── AX7020_2017.4.1/        #   ALINX 官方资料（现仅用户手册 V2.2；原理图 / PCB / DDR3 / TRM 等大文件已移出仓库）
        └── ALINX黑金AX7020开发板用户手册V2.2.pdf
```

> **图例**：无标记 = 已入库，clone 即可获得；`*` = 本地生成、不入库，可重建。仓库内另有
> `desktop.ini`（Windows 系统文件）与 `.ruff_cache/` 等本地产物，均按 `.gitignore` 忽略。
> `docs/AX7020_2017.4.1/` 的目录名已改英文，但内部那份用户手册 PDF 仍是中文文件名，按交付纪律
> 可在收尾时一并改掉；该目录下原理图 / PCB / DDR3 / TRM 等大文件已移出仓库，需要时从 ALINX 官方
> 资料包重新取回。

## License

This project is licensed under the [MIT License](LICENSE).
