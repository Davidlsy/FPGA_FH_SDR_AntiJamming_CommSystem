# 开发环境记录

> 对应实施手册 P0′-S3 交付项；核对日期：2026-09-16

## Vivado 版本号

| 项目 | 值 |
|------|-----|
| 版本 | **Vivado ML 2021.2 (64-bit)** |
| SW Build | 3367213（2021-10-19） |
| IP Build | 3369179（2021-10-21） |
| 安装路径 | `D:\software\vivado2021\Vivado\2021.2` |
| License | WebPACK（覆盖 Zynq-7000） |

**版本理由**：队内现有环境；Zynq-7000 为长生命周期器件族，本方案所用 IP 均获 2021.2 完整支持。指南 3.3.3.1 为推荐（2026.1/2025.2）而非强制，使用 2021.2 须在设计报告中声明，并保证 `build/` Tcl 脚本可复现（三机干净重建）。

## 操作系统

| 项目 | 值 |
|------|-----|
| 主机名 | LAPTOP-NLI2SH3R |
| 系统 | Microsoft Windows 11 家庭中文版 |
| 版本 | 10.0.22631 Build 22631 |
| 架构 | x64-based PC |
| BIOS | XIAOMI RMGRP6B0P0808（2024-05-10） |

辅助工具（本机实测）：Python 3.12.7、Node.js v24.18.0、Git 2.53.0.windows.2、ModelSim（`D:\software\Modelsim`）。

## IP 组件清单

以下为本方案计划使用、已在 Vivado 2021.2 IP Catalog 中核验可选的 IP 核：

| IP 名称 | Catalog 版本 | 用途 | 选用策略 |
|---------|-------------|------|----------|
| **FIR Compiler** | fir_compiler_v7_2 | 发射 SRRC 成形（31 抽头）、接收匹配滤波 | 与手写 DSP48E1 做对比实验，主用 IP |
| **CIC Compiler** | cic_compiler_v4_0 | 接收 DDC 抽取 | 可用 IP 或手写，按资源/时序择优 |
| **FFT** | xfft_v9_1（备选 xfft_v7_2） | 频谱扫描 / 空闲信道检测 | 主用 IP，自研版作对比写入报告 |
| **Block Memory Generator** | blk_mem_gen_v8_4 | 交织矩阵、Viterbi 回溯、帧缓存 | BSRAM→BRAM36（或 RTL 推断） |
| **Clocking Wizard** | clk_wiz_v6_0 | MMCM 产生 61.44 MHz 等基带时钟 | 主用 IP |
| **AXI VIP** | axi_vip_v1_1 | AXI4-Lite 寄存器桥（axi_regs）仿真验证 | 仅仿真 |
| **Zynq Processing System 7** | processing_system7_v5_5 | PS 硬核（GEM 千兆网、控制面） | BD 中必选 |
| **Processing System 7 VIP** | processing_system7_vip_v1_0 | PS 侧接口仿真 | 仅仿真 |

**明确不用 IP 的模块（自研保留，创新点红线）**：
- `nco_hop`：不用 DDS Compiler —— 相位连续跳频机制建立在自研相位累加器上
- `viterbi_dec`：AMD 新一代器件无现成免费软判决 Viterbi IP，自研保留
- `conv_enc`：(171,133)₈ 纯逻辑，有叙事价值，不用 IP 替换

**核验状态**：上述 IP 已在本机 `Vivado/2021.2/data/ip/xilinx` 目录中确认存在。新建工程试选 XC7Z020-CLG400 的空工程编译验证尚未执行（待板卡/器件最终确认后做）。

---

*记录人：MiMo Agent · 依据 docs/fpga-fhss-amd-implementation-plan.html P0′-S3 与本机实测*
