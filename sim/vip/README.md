# S2 验证基础设施 · PS/PL 协同仿真环境（Zynq / AXI VIP）

计划书 §S2 第四件交付物。S9 要在仿真里「执行真实 PS 软件序列：上电初始化 →
读状态字轮询 → 写控制字 → 验证 PL 行为即时响应」；没有这套环境，PS 与 PL 的
控制面就只能等到上板才第一次联调。

## 1. 先说结论：用了哪个 VIP，以及为什么

| VIP | 是否使用 | 依据（本机 Vivado 2021.2 实测） |
|---|---|---|
| **AXI VIP**（`axi_vip_v1_1`，master 模式） | **已建并验证** | 可在 RTL 工程里 `create_ip` + 生成仿真目标，**不需要 Block Design**；master agent 直接在该 AXI4-Lite 总线上发真实读写事务 |
| Processing System 7 VIP（`processing_system7_vip`） | **未建**（不是遗漏） | 它是 **BD-only** IP：在 RTL 工程里执行 `create_ip -vlnv xilinx.com:ip:processing_system7_vip:1.0` 报 `ERROR: [Coretcl 2-1134] No IP matching VLNV ... was found`。要用它必须先有 Block Design 与 PS 配置 |

S2/S9 真正需要的「PS 侧软件对 PL 寄存器的真实读写序列」，本质是**在 PS 的 M_AXI_GP
路径上发 AXI4-Lite 事务**——这正是 AXI VIP master agent 做的事，也是真实设计里 PS
到 PL 的唯一通路。PS7 VIP 额外提供的是 PS 内部模型（DDR、GEM、多主口），它在需要
DDR 级协同或 GEM 回环时才必需。**建议**：等 S9/S10 真做出 BD（PS7 + AXI Interconnect
+ `axi_regs`）时把 PS7 VIP 一并加上，那时 BD 已存在，代价最小；现在为它单独造一个
BD 会引入第二个与真实工程脱节的设计源。

## 2. 组成

| 文件 | 作用 |
|---|---|
| `build_axi_vip.tcl` | 批量生成 AXI VIP（`create_ip` + 配置 + `generate_target`）到 `gen/` |
| `axi_regs_demo.sv` | **环境自带示例从端**：AXI4-Lite 从端 + 行为级 PL（寄存器映射做成 FHSS 控制面形状） |
| `tb_axi_ps_seq.sv` | PS 侧软件序列 TB：VIP master agent + 7 组自检 |
| `run_vip_check.ps1` / `.bat` | 一键：生成 VIP → xvlog → xelab → xsim → 判据 |
| `gen/` | 生成产物（目录内局部 `.gitignore` 挡住，可随时重建） |
| `logs/` | 运行日志（`*.log`，已被根 `.gitignore` 忽略） |

> `axi_regs_demo.sv` **不是设计交付物**：S9 会用真正的 `axi_regs` 替换它。保留它是
> 因为环境需要一个可被 PS 读写、行为可验证的 PL 端；寄存器映射刻意做成 FHSS 控制面
> 的形状，S9 换表时拓扑不变。

## 3. 用法

```powershell
.\run_vip_check.ps1            # 首次会先 vivado -mode batch 生成 VIP（约 1 分钟）
.\run_vip_check.ps1 -Rebuild   # 强制重建 VIP 生成产物
```

单独跑时的三步（与生成脚本产出的路径一一对应）：

```powershell
xvlog -sv -L xilinx_vip -L axi_vip_v1_1_11 -work work `
      gen/axi_vip_mst/sim/axi_vip_mst_pkg.sv gen/axi_vip_mst/sim/axi_vip_mst.sv `
      axi_regs_demo.sv tb_axi_ps_seq.sv
xelab -relax -timescale 1ns/1ps -snapshot sn_vip -debug typical `
      -L axi_vip_v1_1_11 -L xilinx_vip work.tb_axi_ps_seq
xsim sn_vip -runall
```

TB 侧 API（agent 绑定路径 = `u_vip.inst.IF`，wrapper 内部实例名为 `inst`）：

```systemverilog
import axi_vip_pkg::*;
import axi_vip_mst_pkg::*;              // 生成物，per-instance
axi_vip_mst_mst_t mst_agent;
mst_agent = new("ps_master_agent", u_vip.inst.IF);
mst_agent.start_master();
mst_agent.AXI4LITE_WRITE_BURST(addr, prot, data64, resp);   // 阻塞式，像 PS 的 mmio 写
mst_agent.AXI4LITE_READ_BURST (addr, prot, data64, resp);
```

**路径写错不用猜**：VIP 会把正确路径打印出来——本机实测输出
`XilinxAXIVIP: Found at Path: tb_axi_ps_seq.u_vip.inst`。

## 4. 寄存器映射（示例从端，与 TB 的常量 1:1）

| 偏移 | 名称 | 访问 | 复位值 | 说明 |
|---|---|---|---|---|
| 0x00 | CTRL | RW | 0x0000_0000 | bit0 使能跳频，bit1 软复位（自清） |
| 0x04 | STATUS | RO | — | bit0 pl_ready, bit1 hopping_active, bit2 sync_locked, bit15:8 hop_count, bit23:16 黑名单版本 |
| 0x08 | HOP_RATE | RW | 0x0000_0064 | 跳频周期（拍），0 = 不跳 |
| 0x0C | FREQ_WORD | RW | 0x0000_0000 | 频率控制字（闭环由跳频层接手） |
| 0x10 | GAIN | RW | 0x0000_0020 | 射频增益码 |
| 0x14 | BLK_VER | RW | 0x0000_0000 | 黑名单版本（写后 STATUS[23:16] 立即跟随） |
| 0x18 | BER_CNT | RO | — | 自由计数器（示意 PL 上报） |
| 0x1C | RSSI | RO | — | 自由计数器 |
| 0x20 | SCRATCH | RW | 0x0000_0000 | 通用回读 |
| 0x24 | ID | RO | 0x4648_5353 | `"FHSS"` |

未映射地址（高 24 位非零，或字偏移 > ID）读/写均回 **DECERR**，不静默成功、不挂死。

## 5. 自检（28 项，本机实测全过）

| 组 | 内容 | 实测 |
|---|---|---|
| 1 上电初始化 | 轮询 `STATUS.pl_ready` 直到就绪 | 轮询 22 次后置位 |
| 2 复位值表 | 逐个读 10 个寄存器核对复位值；PL 上报须在动 | ID=0x46485353；BER 9 → 30 |
| 3 通用读写 | SCRATCH 写-回读（含全 1 / 全 0 边界） | 三项全对 |
| 4 只读保护 | 向 RO 写：值不得被改，且仍回 OKAY | STATUS/ID/BER 均未被改写 |
| 5 未映射地址 | 读/写均须回 DECERR | 读 0x40 → DECERR，写 0x40 → DECERR |
| 6 控制序列 | 写 CTRL.en → `hopping_active` 立起 → 第 2 跳后 `sync_locked` → 改 HOP_RATE → 跳频速率即时变化 → 关闭归零 | 10 → 100 次（HOP_RATE 200 → 20），即时生效 |
| 7 控制字回显 | 写 BLK_VER 后立即在 STATUS 高位可见 | 0xA5 立即回显 |

判据行（脚本只认它）：

```
[VIP-RESULT] tb=tb_axi_ps_seq checks=28 errors=0 status=PASS
```

第 6 组是这套环境的核心价值：它证明**写控制字后 PL 行为在若干拍内改变**，而不只是
AXI 事务回 OKAY——这正是 S9 要验证的「PL 行为即时响应」。

## 6. 关键环境事实（2021.2 本机实测，别再踩）

| 事实 | 细节 |
|---|---|
| AXI VIP 不需要 Block Design | `create_ip` + `generate_target {instantiation_template simulation}` 即可拿到 per-instance 的 pkg 与 wrapper |
| 编译期就要 `-L xilinx_vip` | 否则 xvlog 报 `'axi_vip_pkg' is not declared`——`axi_vip_mst_pkg` 要 import 它 |
| 详细化要两个 `-L` | `xelab -L axi_vip_v1_1_11 -L xilinx_vip`，两者都在 `$XILINX_VIVADO/data/xsim/ip/`（预编译，无需自行编译 VIP 源码） |
| 生成目录名不固定 | 探查时是 `.../<name>_1/`，正式脚本里是 `.../<name>/`；生成脚本因此自动发现路径而不是写死 |
| PS7 VIP 是 BD-only | 见 §1 |
| 生成产物不入库 | `gen/.gitignore`（目录局部）挡住；`build_axi_vip.tcl` 可随时重建 |

## 7. 已知边界

| 边界 | 说明 | 何时补 |
|---|---|---|
| **示例从端不是真 axi_regs** | 寄存器映射是示意形状 | S9 换真表（拓扑不变） |
| **未覆盖 WSTRB 字节选通** | 从端实现了 `merge_strb`，但 VIP 的 `AXI4LITE_WRITE_BURST` 任务签名不含 strb，测不到 | 需改用 VIP 事务 API；或 S9 用真表时以定向测试补 |
| **地址只译码低 8 位** | 示例从端的简化（`addr[31:8]==0`） | 真 axi_regs 按实际映射 |
| **无 DDR / GEM / 中断** | 这些属 PS7 VIP 与 BD 的范围 | 需要时按 §1 的建议建 BD |
| **时钟/复位为理想** | TB 直接产生 `aclk/aresetn` | S10 集成后随 BD 时钟域走 |

## 8. 踩坑记录

| 现象 | 原因 | 对策 |
|---|---|---|
| `xvlog` 报 `'axi_vip_pkg' is not declared` | 生成包要 import 预编译的 `axi_vip_pkg`，编译期未给库路径 | xvlog 加 `-L xilinx_vip -L axi_vip_v1_1_11` |
| `syntax error near '['` | 对函数调用结果直接做位选（`merge_strb(...)[3:0]`）在 SV 里非法 | 先算出整字再掩码 |
| VIP 报 `Found at Path: ...` 却不是预期路径 | agent 绑定路径写错 | 按打印出的路径修正（本机为 `u_vip.inst.IF`） |
| 生成产物污染 `git status` | `gen/` 不在根 `.gitignore` 的忽略范围内 | 目录内局部 `.gitignore`（不动根规则） |
| `.gitignore` 里中文变 `?` | `Set-Content -Encoding ASCII` 无法表示中文 | 该文件注释写英文，避免编码坑 |

## 9. 后续（S9 / S10）

1. 用真正的 `axi_regs` 替换 `axi_regs_demo.sv`，把寄存器映射表定稿并写入 `docs/spec/`；
2. TB 的序列换成真实 PS 上电流程（与 Vitis 侧初始化顺序一致），保留现有的超时与
   DECERR 检查；
3. 建 BD（PS7 + AXI Interconnect + `axi_regs` + FHSS 顶层）时把 **PS7 VIP** 一并接入，
   让 PS 的内部模型（DDR/GEM）也进入仿真；
4. S10 集成后用本环境回归一遍「PS 写控制字 → PL 行为变化」全表。
