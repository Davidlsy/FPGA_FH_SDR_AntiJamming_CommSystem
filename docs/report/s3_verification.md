# S3 射频配置模块 · 验证报告

对象：`src/spi_master.v` + `src/ad9363_cfg.v`
日期：2026-09-28
判据入口：`sim/run_s3_acceptance.ps1` → `[S3 ACCEPTANCE] suites=4 failed=0 checks=4718 errors=0 status=PASS`（21.7 s）

## 1. 结论与出口门槛

计划书 S3 的四条操作与出口门槛的达成情况：

| 计划书 S3 要求 | 状态 | 证据 |
|---|---|---|
| `spi_master` 直移：≥1000 组随机向量，逐拍断言 SCLK 极性/相位、CSB 建立保持、位序 | 达成 | `tb_spi_master_rand.sv`：1200 向量 / 4580 项 / 0 失败 |
| `ad9363_cfg` 表驱动状态机直移，cfg_rom 转 `$readmemh` 格式 | 达成 | `src/ad9363_cfg.v`、`ad9363_init.mem`、`gen_init_table.py` |
| 对接 SPI 行为模型跑全量初始化序列：逐条比对（地址,数据,延时）三元组、回读路径、暂停/恢复、超时保护 | 机制达成，**序列表内容待补** | `tb_ad9363_cfg.sv` R5（逐条）、R4（暂停/恢复）、R6（超时）；序列内容见 §5 |
| 异常注入 ≥5 类 | 达成 | §4 覆盖矩阵，全部落在 `ad9363_cfg` 集成层 |
| 交付物：两模块 RTL、仿真日志、异常注入覆盖报告 | 达成 | 本文件即覆盖报告；日志见 §7 复现入口 |
| 出口门槛：仿真报告评审通过 | **待评审** | —— |

**按计划书要求重申本档的效力边界**：以上只证明"协议与逻辑正确"，不证明"真芯片能初始化"。真机结论见 §6 的 BV-01。

## 2. 被测件与验证结构

```
ad9363_cfg  ──cmd/wbuf/rdata 握手──▶  spi_master  ──SCLK/CSB/SDIO/SDO──▶  ad9363_spi_model
 表驱动状态机                          4 线主控                              寄存器堆 + 回读校验 + 异常注入
      ▲                                                                              │
      └──────────────── TB 侧引脚嗅探器（独立观测，不读 DUT 内部信号）◀────────────────┘
                                   │
                                   ▼
                       与 gen_init_table.py 从 CSV 独立编码的期望逐条比对
```

三个 TB 分工：

| TB | 被测 | 规模 | 判据行 |
|---|---|---|---|
| `tb_spi_master.sv` | `spi_master` 单体 | 36 项（T1–T7，含超时与恢复） | `SPI-MASTER SMOKE PASS` |
| `tb_spi_master_rand.sv` | `spi_master` 单体 | 1200 随机向量 / 4580 项 + CPOL/CPHA 包络 + F1–F5 | `SPI-MASTER RAND PASS` |
| `tb_ad9363_cfg.sv` | `ad9363_cfg` + `spi_master` + 器件模型 | 101 项（R1–R9） | `AD9363-CFG PASS` |

## 3. 初始化表：单一来源与两条独立编码路径

```
ad9363_init_table.csv          ← 全工程唯一的人类可读来源
        │
        ├── gen_init_table.py ──▶ ad9363_init.mem          （RTL：cfg_rom，$readmemh 32-bit 字）
        └────────────────────────▶ ad9363_init_expect.txt  （TB ：逐条 (op,addr,data,gap_us) 期望）
```

两条输出走**相互独立**的编码路径，所以 `.mem` 的字段打包错误会被 TB 的逐条比对抓住——只比对 DUT 内部信号做不到这一点（判别力见 §6）。生成器同时能逐字节复现既有的 `ad9363_init.mem`，这也是它上线时的一次自检：`words=12 txns=9 declared_delay_total=72us`。

## 4. 异常注入覆盖矩阵

计划书要求的五类，全部在 `ad9363_cfg` 集成层（而非仅在 `spi_master` 单体层）：

| 计划书要求 | 用例 | 触发方式 | 期望与实测 |
|---|---|---|---|
| SPI 无应答 | R6 | TB 侧闸门掐断 cfg↔spi_master 的命令握手 | `error=3`（cfg 总看门狗），回 IDLE 无死锁，器件侧 0 笔事务；放开闸门后重跑 9 笔事务完好 |
| 错误回读 | R2 / R5 | 模型 `inject_readback_err`；R5 另以嗅探数据逐条比对 | `error=2`，`fault_addr=0x013`；R5 三笔回读字节与期望一致 |
| 中途复位 | R8 | 表项之间拉低 `rst_n` | 回 IDLE、`busy=0`、CSB 释放；重跑 `done=1 / error=0 / prog_cnt=11` |
| 表项损坏 | R7 | 改写 `cfg_rom` 造非法 OP（OP=5，地址 0x0AA） | `error=4`，`fault_addr=0x0AA`；恢复表后重跑完好 |
| 重复上电 | R9 | 连续两次完整序列，中间不做任何复位 | 两次各 9 笔事务（`txn_cnt=18`）、软复位 2 次；`prog_cnt=11`，无状态残留 |
| （额外）暂停/恢复 | R4 | 表项边界 `pause` 拉高 250 µs | `prog_cnt` 冻结、`busy` 仍高、看门狗不误触发；恢复后 9 笔事务、无表项重复执行 |

R6 与 R7 的价值在于它们激活了两条**在此之前从未被执行过**的错误路径：`error=3`（总看门狗）与 `error=4`（非法 OP）。R6 随即暴露了一处真实缺陷，见 §5。

## 5. 本次发现并修复的缺陷

**缺陷（`src/ad9363_cfg.v`）**：看门狗把状态强行带到 `S_FAULT` 时，`spi_cmd_valid` / `spi_wbuf_valid` 未被撤销（`S_WRCMD`/`S_WRDATA` 每拍无条件置 1，只在握手成功那一支清零）。结果是请求以电平形式悬在 `spi_master` 的命令接口上，**故障解除瞬间被当成新命令执行**，产生一笔幽灵事务。

实测证据（R6 修复前的嗅探时间线，TB 只在失败时打印）：

```
R6 sniff[0] op=0 addr=0x000 data=0x81 start=935390000 end=995230000   ← 幽灵事务, 挂死 59.84 µs
R6 sniff[1] op=0 addr=0x000 data=0x81 start=995410000 end=999590000   ← 主控看门狗中止后又补发一笔
R6 recovery diag: gd=0 er=3 txn=8 ... prog_cnt=8
```

59.84 µs 恰为 `spi_master` 的事务看门狗（`TIMEOUT_CLKS=3000` @50 MHz）；幽灵事务因上游不给写数据而挂死到超时。修复后同一次恢复跑的时间线恰好是表序，9 笔事务、114 µs：

```
R6 sniff[0] addr=0x000  [1] addr=0x013  [2] addr=0x020  [3] addr=0x004  [4] addr=0x005
R6 sniff[5] RD 0x013    [6] RD 0x020    [7] addr=0x028  [8] RD 0x028
R6 recovery diag: gd=1 er=0 txn=9 prog_cnt=11
```

**修复**：把两个握手请求改为默认撤销（`done <= 1'b0` 旁加 `spi_cmd_valid <= 1'b0` / `spi_wbuf_valid <= 1'b0`），只在 `S_WRCMD`/`S_RDCMD`/`S_WRDATA` 内显式拉高。这样任何强制跳转（看门狗、非法 OP）都不会留下悬挂请求。

## 6. 验证方法的判别力（断言不是摆设）

一个测不出问题的测试没有价值，故对三条关键断言各做了一次"故意破坏"实验：

| 断言 | 破坏方式 | 结果 |
|---|---|---|
| R4「暂停期间看门狗冻结」 | 从冻结条件里去掉 `S_PAUSED` | 6 项失败（`error=3` 连锁），证明确实在测冻结 |
| R5 逐条（地址,数据）比对 | 把生成器 `.mem` 编码里的地址/数据打包对调 | R5 每个事务的 addr/data 逐条失败（带索引），证明能抓字段错位 |
| R6 恢复后不重发命令 | 即 §5 的缺陷本身（修复前） | 嗅探到幽灵事务 + 超时，证明 R6 能抓悬挂请求 |

## 7. 复现入口

```powershell
# 一键（推荐）：四项串跑 + 唯一判据行，总日志落 sim/logs/s3_acceptance.log
.\sim\run_s3_acceptance.ps1

# 分项
python sim\models\ad9363\gen_init_table.py --check      # 表产物与 CSV 一致性
cd sim\models\ad9363; .\run_spi_master.bat              # 判据行 SPI-MASTER SMOKE PASS
cd sim\models\ad9363; .\run_spi_master_rand.bat         # 判据行 SPI-MASTER RAND PASS
cd sim\models\ad9363; .\run_ad9363_cfg.bat              # 判据行 AD9363-CFG PASS
```

前置：`xvlog`/`xelab`/`xsim`/`python` 在 PATH（Vivado ML 2021.2，见 `docs/report/env.md`）。

## 8. 已知边界与未完成项

**一、初始化表内容是烟测占位，不是 ADI 推荐上电初始化序列。** 这点必须写清楚：`ad9363_init_table.csv` 的 12 行（11 条表项 + END，9 笔 SPI 事务）是为了把"表驱动状态机 → SPI 事务 → 器件模型 → 逐条比对"这条链路和比对机制跑通，**不是**真机的上电序列。因此本档的"逐条比对 100% 一致"证明的是**状态机忠实执行了表**，不是**表本身正确**。

表源困难的两点事实：
- 仓库内没有任何可用的真机序列表。`ad9363_regs_def.vh` 是 1024 项**上电默认值表**（来自 UG-672 / no-OS `ad9361.c`），是默认值、不是有序写入序列，不能当 cfg_rom 用。
- 仓库 `ad9363_defs.vh` 的寄存器符号只覆盖 `0x000–0x111`，**不含 BBPLL（0x3xx）/ RF PLL / 采样率与带宽配置段**——而真机初始化序列的主体恰好在这一段。所以"功能子集"无法仅由仓库自带资料拼出。

**表源已决（2026-09-28）**：V3.0 / P2′-S1 的原始 (地址,数据,延时) 表**确认不可考**（无存档），因此唯一路径是从 ADI no-OS `ad9361.c` 与 UG-672 抽取，并**逐条标注出处**；本条不再作为待确认问题，后续会话不必再询问。抽取时的一条纪律：不得凭记忆填写寄存器值，凡无法追溯到 ADI 公开来源的表项一律不写入 `.mem`，宁可让子集偏小。

好消息是这只剩**数据工作**：CSV 是唯一来源，替换它后重跑 `gen_init_table.py` + 验收即可，不需要动 RTL 与 TB；表一换，本条与 §1 的效力表述需同步重写。

**二、形式化角度"全部状态可达、无锁死环"未做。** 当前只有逐状态的用例覆盖与显式的故障退出路径（`S_FAULT → S_IDLE`），没有做可达性穷举或形式化证明。计划书的验证方法把这句写在括号里，本次未兑现，登记为遗留。

**三、暂停语义是"表项边界生效"。** 刻意不在 SPI 事务中途暂停（会打断器件事务语义），也不打断延时（该延时即 PLL 建立时间，冻结它会使延时失去意义）；暂停期间总看门狗冻结，故长时间暂停不误报 `error=3`。若后续需要"原子暂停"，需另立设计。

**四、mode 1/3 的时序未随 AD9363 验证。** 只有 mode 0 对齐器件手册时序；mode 1/2/3 仅过了通用从机的 CPOL/CPHA 包络（`spi_slave_gen.sv`）。

**五、`$readmemh` 用相对路径。** `ad9363_cfg.v` 的 `$readmemh("ad9363_init.mem", rom)` 依赖运行目录；S10 顶层集成时要改成绝对路径或 `coe`。

**六、BV-01（强依赖，板卡到货后）。** 真实 AD9363 的回读一致率、校准完成标志、BB/RF PLL 锁定、20 次冷复位无卡死，必须真机复核；补做入口为实施手册 P2′-S3B/S4，半天量级。**在 BV-01 完成前，本文档 §1 的"协议与逻辑正确"不得被引用为"射频初始化可用"。**
