# S2 验收：验证基础设施（板卡的仿真替身）

> 状态：**验收通过**（5/5 套件，1538 项，0 错误；一轮 47.6 s）
> 日期：2026-09-25
> 关联出口：计划书 §S2 —「四件套全部通过自测并写 README；任意成员 10 分钟内可用模板起一个新模块 testbench」
> 验收环境：Vivado Simulator v2021.2 · Python 3.12.7 + numpy 2.5.3 · 主机见 `docs/report/env.md`（LAPTOP-NLI2SH3R）

## 1. 验收对象

| # | 交付物 | 落点 | 自测规模 | 各自的判据行 | README |
|---|---|---|---|---|---|
| 1 | 自动比对框架 | `sim/framework/` | 4 组 | `[FRAMEWORK SELFTEST] PASS` | `sim/framework/README.md` |
| 2 | AD9363 SPI 行为模型 | `sim/models/ad9363/` | 6 项 | `RESULT : *** ALL TESTS PASSED ***` | `sim/models/ad9363/README.md` |
| 3 | 信道模型库 | `sim/models/channel/` | 29 项 | `[CHANNEL STATS] PASS` | `sim/models/channel/README.md` |
| 4 | 干扰注入源 | `sim/models/jammer/` | 31 项 | `[JAMMER STATS] PASS` | `sim/models/jammer/README.md` |
| 5 | PS/PL 协同仿真环境 | `sim/vip/` | 28 项（7 组） | `[VIP-RESULT] … status=PASS` | `sim/vip/README.md` |

五项此前已分别提交（`5e88d59` 框架+信道、`eb4bda6` 干扰源、`0ed3379` VIP；AD9363 模型计入更早的
`d0cd22d` 并随后续提交修订 README）。本次验收新增的是**把它们串成一次可复现运行**的入口：
`sim/run_s2_acceptance.ps1` / `.bat`，以及总入口 `sim/README.md`。

## 2. 验收方法

计划书 §S2 的出口门槛要求「四件套**全部**通过自测」。五项各自能跑，并不等于它们同时成立——
于是本项验收只做一件事：**在一次运行里按依赖顺序跑完五项，并给出唯一判据行**。

三条取自各子脚本的既有口径，本次不另立一套：

1. **退出码只是必要条件**。xsim 批处理模式即使 `$fatal` 也返回 0（2021.2 实测），所以判成败一律看
   各套件自己那一行判据行；
2. **判据只 match ASCII**。日志重定向后中文编码不可靠（`[CHANNEL STATS] PASS (29 项…)` 的中文段可能是
   乱码），聚合脚本因此只取 `[CHANNEL STATS] PASS \(29`、`(?m)^\s*errors\s*:\s*0` 这类 ASCII 锚点；
3. **不重复实现编译步骤**。聚合脚本调用的就是各模块自己的入口脚本（含 AD9363 的 `.bat`），
   验收跑的就是日常跑的那一条路径，避免"验收版"与"日常版"两套仪器。

任一项失败不影响其余项继续跑完，一轮给出完整画面；总日志（各项完整 stdout 顺序拼接）落
`sim/logs/s2_acceptance.log`（`*.log` 未入库，可随时重跑重建）。

## 3. 实测结果（本机，2026-09-25）

| # | 套件 | 规模 | 耗时 |
|---|---|---|---|
| 1 | 自动比对框架 | 4/4 组 | 18.3 s |
| 2 | AD9363 SPI 行为模型 | checks=1446 errors=0 | 5.1 s |
| 3 | 信道模型库 | 29 项 | 7.7 s |
| 4 | 干扰注入源 | 31 项 | 7.4 s |
| 5 | PS/PL 协同仿真环境 | checks=28 errors=0 | 9.0 s |

汇总判据行：

```
[S2 ACCEPTANCE] suites=5 failed=0 checks=1538 errors=0 status=PASS
```

原始判据行（摘自 `sim/logs/s2_acceptance.log`）：

```
==================== S2 framework selftest ====================
[PASS] positive rand    golden-consistent DUT must be judged PASS (4096 beats)
[PASS] positive edge    edge-case vector must be judged PASS (196 beats)
[PASS] negative inject  must FAIL and locate the injected beat 1000
[PASS] stall watchdog   watchdog must close out instead of hanging silently
  [FRAMEWORK SELFTEST] PASS

  checks : 1446
  errors : 0
  RESULT : *** ALL TESTS PASSED ***

[CHANNEL STATS] PASS (29 项全部达预期)
[JAMMER STATS] PASS (31 项全部达预期)
[VIP-RESULT] tb=tb_axi_ps_seq checks=28 errors=0 status=PASS
```

三点说明：

- **1538 是"项"的加总，不是同一种单位**（框架计 4 组，其余计检查项）。真正的判据是 `failed=0` 与各项判据行；
- **AD9363 的 check 数不是定值**（1444~1446 浮动，其随机压力用 `$urandom`），本项验收判 `errors=0`，
  不写死检查数；
- **负路径也计入通过**：框架自测的第 3、4 项是「注入 1 bit 错误必须被判 FAIL 并定位到第 1000 拍」
  与「DUT 卡死必须被看门狗收口」——一个抓不到错的比对器等于没有比对器，这两项通过才有意义。

**复核**：第二轮改用双击入口 `sim\run_s2_acceptance.bat` 复跑，结论一致
（`status=PASS`，65.3 s，多出的约 18 s 为 `.bat` 冷启动与逐项落盘），退出码 0。两个入口都可用。

## 4. 出口门槛对照

| 门槛（计划书 §S2） | 判定 | 证据 |
|---|---|---|
| 四件套全部通过自测 | **是** | 5/5 套件，`errors=0`，§3 |
| 各交付物写出 README | **是** | 5 份模块 README + 新增 `sim/README.md`（总入口） |
| 任意成员 10 分钟内可用模板起一个新模块 testbench | **未实测** | 模板 `framework/tb/tb_module_template.sv` 与四步流程见 `framework/README.md` §6；但还没有真实模块用它起过 TB（`qpsk_map` 的 DUT 属 S4-P1）。**登记为待演练**，S4-P1 第一个真实实例即为其验证 |
| 四件套之间可协同 | **未覆盖** | 见 §5 边界：三条线之间无联合仿真 |

## 5. 与计划书的落点差异（登记）

| # | 计划书写法 | 实际落点 | 影响与处置 |
|---|---|---|---|
| 1 | PS/PL 协同仿真环境 =「Zynq VIP（Processing System VIP）+ AXI VIP 搭建」 | **只建了 AXI VIP**。`processing_system7_vip` 是 BD-only IP，在 RTL 工程里 `create_ip` 报 `[Coretcl 2-1134] No IP matching VLNV`（`sim/vip/README.md` §1 实测） | S2/S9 需要的「PS 对 PL 寄存器的真实读写序列」本质就是 M_AXI_GP 上的 AXI4-Lite 事务，AXI VIP master 已覆盖；**PS7 VIP 待 S9/S10 有 BD 时一并接入**（那时代价最小） |
| 2 | 自动比对框架含「BER 曲线自动生成脚本」 | 实际落点是 S1 的 `golden_ref/run_ber.py`（产出 `data/s1_ber_baseline/ber_curve.png`），不在框架内 | 不另写一套；S8 整链回归直接复用 |
| 3 | 「此框架本身即技能包素材」 | `skill/` 目录目前只有 `.gitkeep`，框架尚未沉淀为技能包 | 登记为未落地素材；内容已具备（模板 + 判据约定 + 踩坑表），需要时再成包 |

## 6. 已知边界与遗留板级闸

| 边界 | 说明 | 何时补 |
|---|---|---|
| **AD9363 模型只覆盖数字接口协议**（板级闸 BV-01） | 寄存器默认值取自 UG-672 并与 no-OS `ad9361.c` 交叉核对，但芯片内部校准状态机、BB/RF PLL 锁定、ENSM 迁移时序无法仿真。**若真机某寄存器语义与手册理解有偏差，初始化可能在真机静默失败** | 板到货后逐项真机回读背书 |
| 四件套之间无联合仿真 | RF 侧（信道 + 干扰源）接口一致但未串联；控制侧（SPI / AXI）与 RF 侧无交叉。接口约定只写在各自 README 里，还没有机器可执行的检查 | 建议先做 RF 侧链路冒烟（§7.1）；S8 整链回归时全部串联 |
| VIP 示例从端不是真 `axi_regs` | 寄存器映射是示意形状，地址只译码低 8 位，未覆盖 WSTRB 字节选通，无 DDR/GEM/中断，时钟复位理想 | S9 换真表（拓扑不变） |
| 验收会让向量 meta 变脏 | 跑完验收 `git status` 会看到 `framework/vectors/qpsk_map/{rand,edge}_meta.json` 被修改，diff 只有 `generated_at` 一行；**向量值本身是确定性重生成的**（本次实测确认） | 需要干净树时把 `generated_at` 降级为日期字段（改 `export_vectors.py`） |

## 7. 后续动作

1. **RF 侧链路冒烟**（建议紧接着做，半天~1 天）：`golden_ref` 样点 → `ch_top` → `jm_top` → 回 Python
   用 S1 基线判 BER / JSR。一次证明三件接口真正兼容，也是 S8 抗干扰增益验证的底座。改造成本极低——
   两者都是 `W=14/FRAC=11` + `*_valid` 握手，干扰源已复用 `channel/ch_pkg.sv`。
2. **演练「10 分钟起一个 TB」**：用 `tb_module_template.sv` 对 S4-P1 的首个真实模块（`qpsk_map`，
   向量已就绪）走一遍，把出口门槛的第二半句变成实测结论。
3. **S9/S10 接入 PS7 VIP**：等 BD（PS7 + AXI Interconnect + `axi_regs`）存在时补，同时把示例从端换成真表。
4. 需干净树时处理 §6 最后一行（`generated_at`）。
5. 进入 **S3**：`spi_master` + `ad9363_cfg` 是 AD9363 模型的第一个真实消费者，用 S2 的环境做逐条
   （地址, 数据, 延时）三元组比对。

## 8. 复现命令

```powershell
# 前置：让 xvlog/xelab/xsim/vivado 进 PATH（.bat 入口会自动尝试加载）
call D:\software\vivado2021\Vivado\2021.2\settings64.bat

# 统一验收（五项串跑，判据行 [S2 ACCEPTANCE] …）
cd D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem
.\sim\run_s2_acceptance.ps1        # 或 .\sim\run_s2_acceptance.bat

# 只看总日志里的判据行
Select-String -Path sim\logs\s2_acceptance.log -Pattern '\[(FRAMEWORK SELFTEST|CHANNEL STATS|JAMMER STATS|VIP-RESULT)\]|ALL TESTS PASSED|^  (checks|errors)\s*:'
```

---

*报告生成：S2 验收 · 依据 `sim/run_s2_acceptance.ps1` 一次完整运行（2026-09-25）与各模块 README*
