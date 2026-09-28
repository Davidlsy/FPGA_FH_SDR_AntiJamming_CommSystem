# S4 发射链验证报告（P0 + P1 + P2）

> **阶段**: S4-P0 判据与接口冻结 + S4-P1 纯逻辑三模块 + S4-P2 `blk_inter` 存储迁移
> **日期**: 2026-09-28
> **依据**: S4 任务卡「发射链 frame_tx / conv_enc / blk_inter / qpsk_map / srrc_duc」
> **验收入口**: `sim/run_s4_acceptance.ps1`（`-Full` 追加任务卡的两条长跑判据）
> **本报告范围**: 任务卡的五个模块里已完成四个（P0 冻结了全部五个的接口）；
> `srrc_duc` 双版 + NCO（P3）、IP vs 手写对比（P4）、整链收口（P5）**未开始**，见 §7。

## 1. 结论

```
[S4 ACCEPTANCE] suites=18 failed=0 positives=14 full=False status=PASS
```

- **18/18 套件通过**（14 条正例位真比对 + 4 条证伪用例），总耗时 **83.5 s**；
  `-Full` 另加 task 卡的两条长跑判据共 20/20。
- 任务卡的四条量化判据均已跑满：
  - `frame_tx` **1000 随机帧**：2,160,000 拍逐拍比对，**0 错误**；
  - `conv_enc` **10⁶ bit**：463 块 = 1,000,080 bit，输出 1,002,858 拍，**0 错误**；
  - `blk_inter` **解交织还原 0 错误**：三用例逐块还原 0 错误 + 尾部 8 bit 补零正确；
  - `blk_inter` **突发 10 bit 打散 ≥10 码字位**：实测量化为
    `[BURST-RESULT] restore=1 errors=10 rows=10 rows_no_interleave=1 burst=10 status=PASS`。
- 四条证伪用例全部按预期判 FAIL（详见 §4.2、§5.2）——**这是本报告最该被看重的部分**：
  正例的 PASS 只有在"把关键处改错就必然红"的前提下才有信息量。
- `blk_inter` 的**两种存储实现**（`blk_mem_gen` IP 版与 RTL 推断版）跑同一套向量、同一套 TB，
  位真结果一致——这是 P2「存储介质替换而非逻辑重写」的实证。
- 帧层黄金模型自检 36 项 0 失败；比对框架自测 8 项全过（含 S4-P0 新增的 1:N 与激励节奏契约）。

## 2. 交付物

| 类别 | 文件 | 说明 |
|---|---|---|
| RTL | `src/frame_tx.v` | 帧成形：Gold 同步字 + 帧头 + 256B + CRC16，双缓冲 |
| RTL | `src/conv_enc.v` | (171,133)₈ 卷积编码，含 6 bit 归零尾比特与输入弹性缓冲 |
| RTL | `src/blk_inter.v` | 块交织：写行读列地址生成 + 双缓冲 + 32 拍输入弹性缓冲 |
| RTL | `src/blk_mem_1w1r.v` | 存储器副本：`blk_mem_gen` IP 版 / RTL 推断版，同接口同延迟 |
| RTL | `src/qpsk_map.v` | QPSK 直移映射，纯组合 |
| RTL | `src/frame_tx_sync.vh` | 同步字常量（生成物，综合期即 LUT-ROM） |
| 生成脚本 | `build/gen_blk_mem_gen.tcl` | 生成 blk_inter 正式版存储 IP（产物 `build/ip/` 不入库） |
| 规格 | `docs/spec/frame_format.md` | 帧格式规格书（P0 首次定义帧层，已冻结） |
| 规格 | `docs/spec/s4_tx_interface.md` | 五模块接口规格书（流控/位序/拍数账本/P2 存储决策/NCO 语义） |
| 黄金模型 | `sim/golden_ref/float_chain/framing.py` | 帧层唯一裁判：m 序列 / Gold / CRC16 / 成帧与解析 |
| 黄金模型 | `sim/golden_ref/sim/check_framing.py` | 帧层自检（36 项，两条独立 CRC 路径 + 注错负例） |
| 生成器 | `sim/golden_ref/gen_frame_sync.py` | 同步字 → RTL 常量，带 `--check` |
| 框架 | `sim/framework/hdl/tb_vec_cmp.sv` | 比对器扩展：激励/期望长度解耦 + 激励节奏 + `stim_count` |
| 框架 | `sim/framework/tb/tb_{qpsk_map,conv_enc,frame_tx,blk_inter}_compare.sv` | 四个模块的位真 TB（用例 `-d` 切换，含证伪用例） |
| 框架 | `sim/framework/tb/tb_blk_inter_burst.sv` | 模块专属量化检查：突发打散 + TB 侧独立解交织模型 |
| 向量 | `sim/framework/vectors/{qpsk_map,conv_enc,frame_tx,blk_inter}/` | 由 `export_vectors.py` 从黄金模型确定性导出 |
| 验收 | `sim/run_s4_acceptance.ps1` | 统一验收，判据行 `[S4 ACCEPTANCE]` |

## 3. P0：判据与接口冻结

### 3.1 帧格式（任务卡要求"以 S1 定点参考做位真裁判"，但 S1 里没有帧层）

S1 交付的 `golden_ref` 只有编码/交织/调制/SRRC，**没有 Gold 同步字、没有 CRC、没有帧头**，
定点规格书也只冻结位宽——直接写 RTL 就没有裁判。故 P0 先冻结帧格式，再冻结裁判，最后动 RTL：

| 字段 | 长度 | 取值 |
|---|---|---|
| 同步字 | 64 bit | Gold 序列 `0x517AE4216E7555CA` |
| 帧头 | 32 bit | 版本(2) \| 保留(6) \| 帧号(8) \| 载荷字节数(16) = `0x40000100` |
| 载荷 | 2048 bit | 256 byte |
| CRC16 | 16 bit | CRC-16/CCITT-FALSE，覆盖帧头 + 载荷（2080 bit） |
| 合计 | **2160 bit** | 270 byte |

**同步字不是抄来的**，两处都用数值验证：

1. **优选对**：遍历 6 级全部本原多项式（6 个）的两两组合（15 对），确认冻结对
   `0o103` & `0o133` 的周期交叉相关集恰为 `{-17, -1, 15}`（= n 偶数时的 `{-1, -1±2^(n/2+1)}`），
   并保留 9 个"不满足三值性"的对照对，证明该判据不是恒真条件；
2. **相位**：两条 m 序列同态起步时异或结果前 8 位塌成全 0（对前导检测不利），
   故按「最长同值游程 → 旁瓣 → 0/1 平衡」三级准则遍历 63 个相对位移，
   冻结 `shift=24`（游程 4、旁瓣 max|R|=16、恰 32 个 1，三项同时最优且唯一）——
   自检里有一条检查专门重跑这个搜索并要求 `argmin == 24`。

### 3.2 比对器扩展：两个长度解耦 + 激励节奏

原比对器把向量长度取成 `stim` 与 `expect` 行数的较小值，只支持"一入一出"。而五模块里
有三个不是 1:1（`frame_tx` 256→2160、`conv_enc` N→N+6、`blk_inter`/`srrc_duc` 同理），
故 P0 扩展为：

| 项 | 语义 |
|---|---|
| `n_stim` | 激励行数 = 驱动节拍数 |
| `n_exp` | 期望行数 = **比对长度**（PASS 判据里的 `compared` 目标） |
| `STIM_PERIOD` | 激励节奏：每 N 拍送出一个激励拍（多速率模块必需） |
| `stim_count` | 输出激励行数，供 TB 引用（块长等配置不再手抄） |

新加判据必须同时加证伪用例——框架自测因此从 4 项扩到 8 项，含
`positive ratio`（3 拍激励 → 9 拍期望）、`positive cadence`（1/4 节奏）、
`negative extra`（数据流不变、末尾多吐 3 拍 → 必须 FAIL）。

**为什么必须有激励节奏**：`frame_tx` 输出 2160 拍/帧却只吃 256 字节/帧（差 8.44 倍），
按"每拍都有效"驱动会得到"上游 8.4 倍过载"的假象。P3 的采样域 DUC 同样需要它
（符号 1/4 节奏进、采样连续出），故把它放在 P0 而不是留给 P3 做前置。

### 3.3 接口规格

`docs/spec/s4_tx_interface.md` 冻结了五个模块的流控（valid-only、无背压、固定节拍）、
位序（MSB-first、总线高位在前）、**拍数账本**（从帧到上采样的逐环节长度）、
NCO 相位连续跳频语义（`freq_word` / `freq_valid` / 相位累加器不清零，为 S6 预留），
以及各模块的输入速率约束。三处与任务卡的**有意偏差**在 §5 列出。

## 4. P1：三模块位真比对

### 4.1 正例套件

| 套件 | 规模 | 判据行 | 耗时 |
|---|---|---|---|
| `qpsk-rand` | 4096 符号 | `status=PASS vectors=4096 compared=4096 errors=0` | 4.6 s |
| `qpsk-edge` | 196 符号 | `vectors=196 compared=196 errors=0` | 4.4 s |
| `conv-frame` | 1 块 2160 bit | `vectors=2166 compared=2166 errors=0` | 4.6 s |
| `conv-rand` | 8 块 17280 bit | `vectors=17328 compared=17328 errors=0` | 4.7 s |
| `conv-edge` | 4 个边界块 | `vectors=8664 compared=8664 errors=0` | 4.7 s |
| `frame-single` | 1 帧 | `vectors=2160 compared=2160 errors=0`（stim 256 拍，节奏 1/9） | 4.6 s |
| `frame-multi` | 8 帧 | `vectors=17280 compared=17280 errors=0` | 4.8 s |
| `frame-edge` | 4 个边界载荷 | `vectors=8640 compared=8640 errors=0` | 4.5 s |
| `conv-long` | 463 块 = 1,000,080 bit | `vectors=1002858 compared=1002858 errors=0` | 7.2 s |
| `frame-long` | **1000 随机帧** | `vectors=2160000 compared=2160000 errors=0` | 7.4 s |

边界用例覆盖：`qpsk_map` 四星座点 + 全 0/全 1 + 最坏码型交替；`conv_enc` 全 0 / 全 1 /
0101 交替 / 首位单 1（寄存器归零路径）；`frame_tx` 载荷全 0 / 全 0xFF / 0xAA-0x55 /
末字节单比特，且多帧用例覆盖帧号递增与背靠背帧边界。

### 4.2 证伪用例（关键处改错必须红）

| 套件 | 注入的错误 | 结果 | 说明 |
|---|---|---|---|
| `neg-qpsk` | I/Q 两路互换 | `errors=2058`，首失配第 5 拍：期望 `0xd2c2d4` 实际 `0x2d4d2c` | 极性/映射写错必被抓 |
| `neg-conv` | `{g₁,g₂}` 位序颠倒 | `errors=1070`，首失配第 6 拍：期望 `0x1` 实际 `0x2` | 与 S1 参考"各自正确、互不一致"的典型错 |
| `neg-frame` | CRC 多项式换成 `0x8005` | `errors=6`，首失配第 **2145** 拍（= CRC 字段起点） | 多项式/覆盖范围写错只影响 CRC 段，向量照样定位到字段级 |

### 4.3 任务卡判据对照

| 任务卡判据 | 本阶段证据 |
|---|---|
| `frame_tx`: 1000 随机帧 0 错误 | `frame-long`：2,160,000 拍，0 错误 |
| `conv_enc`: 10⁶ bit 与参考 0 错误 | `conv-long`：1,000,080 bit → 1,002,858 拍，0 错误 |
| `qpsk_map`: 纯逻辑零改动 | 4096 随机 + 196 边界，0 错误 |
| `blk_inter`: 还原 0 错误；突发 10 bit 打散 ≥10 码字位 | §5.3：还原 0 错误 + `rows=10`（无交织 1 行），两种存储实现一致 |
| `srrc_duc`: 两版逐拍一致；SFDR ≤ −50 dBc | **未开始（P3）** |
| IP vs 手写三栏对比表 | **未开始（P4）** |
| 五模块串联位真比对全过 | **未开始（P5）** |

`frame_tx` 的 CRC 检出能力另有一层证据在帧层自检里：CRC 覆盖区单比特注错 **32/32 全部检出**、
同步字注错被 `sync_ok` 检出、帧头版本位注错同时改变字段并让 CRC 失败。

## 5. P2：blk_inter 存储迁移

任务卡的要求是「存储 BRAM36（`blk_mem_gen` 或 RTL 推断），**写行读列地址生成器不变**」——
即核心是**存储介质替换而不是逻辑重写**。P2 的产出因此分三块：地址生成器与流控、两种存储
实现、以及"打散 ≥10 码字位"这条最容易被做成假测试的判据。

### 5.1 开工时冻结的四条设计决策

见 `docs/spec/s4_tx_interface.md` §4.3（含理由）。摘要：

| 决策 | 取值 | 关键理由 |
|---|---|---|
| 存储序 | **padded 序（行优先）** | 写侧退化为"顺序写一个字地址计数器"（任务卡说的行优先递增器就是它）；补零那 8 bit 落在末 4 个字，写 0 即可；读侧用一张 `217×r` 项表 + 两个加法器生成列优先地址，**不需要除 434 的除法器** |
| 字宽与深度 | 2 bit/字、2 块 × 2170 字 | 一拍正好一个符号：写侧一拍一个整字，读侧一拍读两个字各取 1 bit |
| 读写冲突 | **不存在冲突** | 写与读永远作用于不同 bank（双缓冲），同 bank 内先写满再读——这比"选一个 read-first/write-first/no-change"更强，也就没有与参考不一致的口子 |
| 输入速率 | 平均 ≤ 2166/2171 ≈ 0.9977 拍⁻¹ | 一块写 2166 拍数据 + 4 拍补零，块周期 2171 拍；模块内带 32 拍弹性缓冲吸抖 |

**一个端口预算的硬约束**：双缓冲稳态下每拍要 1 写 + 2 读 = 3 次访问，而单块 BRAM 只有两个
端口。解法是**两个"1 写 1 读"副本，写广播、读分流**——每个副本稳态下正好是简单双口 RAM 的
能力上限（代价是存储复制 2 份，本设计 2 × 8.7 kbit，仍在一个 BRAM36 之内）。

### 5.2 正例与证伪用例

| 套件 | 规模 | 判据行 |
|---|---|---|
| `blk-frame` | 1 块（激励 = 一帧的真实编码输出） | `vectors=2170 compared=2170 errors=0`（stim 2166 拍） |
| `blk-rand` | 8 块随机背靠背（节奏 1/2） | `vectors=17360 compared=17360 errors=0` |
| `blk-edge` | 4 个边界块 | `vectors=8680 compared=8680 errors=0` |
| `blk-burst` | 模块专属量化检查 | `[BURST-RESULT] restore=1 errors=10 rows=10 rows_no_interleave=1 burst=10 status=PASS` |
| `blk-ip-frame` | 同上向量，**换 blk_mem_gen 存储** | `vectors=2170 compared=2170 errors=0`（与 RTL 推断版逐拍一致） |
| `blk-ip-burst` | IP 版突发打散 | `restore=1 errors=10 rows=10 … status=PASS` |
| `neg-blk` | **证伪**：输出 `{I,Q}` 互换 | `status=FAIL`，`errors=1032`，首失配第 3 拍 |

**为什么突发判据要单独写一个 TB**：只验证"数据能还原"是连通性测试，证明不了抗突发能力。
`tb_blk_inter_burst.sv` 收下 DUT 的 4340 bit 交织输出后，在交织流第 1000 位翻**连续 10 bit**，
用**TB 侧独立实现**的解交织模型还原（与 S1 `block_deinterleave` 同式但独立代码路径），
统计错误落在几行：实测 **10 行**（10×434 矩阵的几何），而同样 10 个位置若不经交织只落在
**1 行**——这才是任务卡要的"量化验证"。

### 5.3 本阶段踩到并修掉的一个真问题

IP 版首次跑位真比对时**整体错一位**（`first_mismatch=2`，实际值 = 上一拍的期望值）。
根因不是地址生成，而是**读延迟不匹配**：7 系列 BRAM 的输出寄存器会额外叠一拍，
`blk_mem_gen` 的 `Register_PortB_Output_of_Memory_Primitives=true` 时实测读延迟 **2 拍**，
而 RTL 推断版 `rdata <= mem[raddr]` 是 **1 拍** —— 我的 FSM 按 1 拍设计，于是 IP 版的
数据比 valid 晚一拍。修法是关掉那个配置项（实测变 1 拍），并**把这条写进接口规格 §4.3**
以免下次重演。诊断手法值得留档：不猜参数含义，写一个 20 行的 TB 直接量"地址进、数据出"差几拍。

## 6. 与任务卡的有意偏差（登记，不隐藏）

| # | 任务卡写法 | 实际做法 | 理由 |
|---|---|---|---|
| 1 | SRRC「31 抽头」 | 待 P3；将沿用 S1 冻结的 **33 抽头** | S1 系数是 `span 8 × sps 4 + 1 = 33`；位真裁判必须同源，改 31 要重跑 S1 BER 基线（属独立变更流程） |
| 2 | CRC16「并行 8-bit 查表，每拍一字节」 | **位串行 LFSR，每拍一比特** | `frame_tx` 输出是比特串行流，查表要在 2080 bit 之外另开 260 拍字节域；位串行版边发边算，零额外节拍 |
| 3 | 「写行读列地址生成器不变」 | 未变（P2 已实现并逐拍验证） | P2 只换存储介质，不重写地址生成器；两种介质跑同一套向量 |
| 4 | 同步字 64 bit | 64 = Gold 周期 **63** + 首位重复 | 6 级 Gold 周期是 63，凑不出 64；代价已量化（旁瓣浮动 ±1，相对主峰 64 无实质影响） |
| 5 | 计划书"MATLAB 比对脚本" | 沿用 Python `golden_ref` | S2 已登记的偏差：比对基线须与冻结基准同源，避免两套"真理" |
| 6 | `blk_inter` 存储"BRAM36" | 两个 1 写 1 读副本（复制 2 份） | 双缓冲稳态每拍 3 次访问、单块 BRAM 只有 2 端口；存储量仍在一个 BRAM36 内（2 × 8.7 kbit） |
| 7 | — | `blk_inter` 增加 32 拍输入弹性缓冲 | 一块要写 2166+4 拍而块周期 2171 拍，存在 0.23% 的节拍差；无背压约定下必须靠缓冲吸抖并写死平均速率上限 |

## 7. 已知边界与遗留项

1. **P3–P5 未开始**：`srrc_duc` 双版 SRRC + NCO/DUC、IP vs 手写三栏对比、五模块整链收口均未做。
   任务卡的出口门槛因此**尚未达成**，本报告不得被引用为"S4 已通过"。
2. **`frame_tx` 的速率约束是接口属性**：上游平均每字节 ≥ 8.44 拍，否则帧缓存溢出丢字节
   （无背压约定下无法自愈）。已写进接口规格书 §4.1 与向量 `meta.json` 的 `stim_period`。
3. **`conv_enc` / `blk_inter` 的弹性缓冲只吸收短时抖动**：平均速率仍须分别 ≤ `blk_len/(blk_len+6)`
   与 2166/2171；长跑与多块用例把激励节奏放到 1/2 就是为了让缓冲常态只有几个字
   （见两个 TB 的头注释）。
4. **`blk_inter` 两种存储实现的资源/时序差异未定量**：本阶段只证明**行为一致**（同向量同位真）；
   资源与 Fmax 的对比属 P4 口径，本阶段不出数字。
5. **1000 帧 / 10⁶ bit 两条判据的向量不入库**：由固定种子确定性重生成，体积约 9 MB，
   按 `.gitignore` 的 S4 长跑向量段忽略；证据是本报告与 `sim/logs/s4_acceptance.log`
   （日志目录按既有约定不入库）。
6. **`blk_mem_gen` IP 产物不入库**：由 `build/gen_blk_mem_gen.tcl` 确定性重建（约 40 s），
   验收脚本在缺失时自动生成。IP 的**参数**是本仓库的源码（tcl 即单一来源），产物不是。
7. **SFDR / 真实发射频谱**：属 P3 与板级，本阶段无频谱结论。真实频谱（含 AD9363 模拟链路）
   仍按任务卡口径移交 **BV-03**。
8. **板卡未到货**：本阶段全部结论都是仿真域结论，不构成任何硬件可用性结论。

## 8. 复现

```powershell
# 帧层黄金模型自检（36 项，含两条独立 CRC 路径与注错检出）
python sim\golden_ref\sim\check_framing.py

# 同步字常量与黄金模型一致性（手改常量会在这里暴露）
python sim\golden_ref\gen_frame_sync.py --check

# 比对框架自测（8 项，含 1:N 与激励节奏契约）
powershell -File sim\framework\run_selftest.ps1

# blk_inter 正式版存储 IP（约 40 s；产物不入库，验收脚本会在缺失时自动生成）
vivado -mode batch -source build\gen_blk_mem_gen.tcl

# S4 统一验收：短用例 18/18 套件 83.5 s（本机实测，Vivado 2021.2 xsim）
powershell -File sim\run_s4_acceptance.ps1
powershell -File sim\run_s4_acceptance.ps1 -Full
```

前置：`xvlog`/`xelab`/`xsim` 在 PATH（`call D:\software\vivado2021\Vivado\2021.2\settings64.bat`）、
Python 3.12 带 numpy。总日志落 `sim/logs/s4_acceptance.log`。

## 9. 下一步

按 `docs/s4-tx-chain-implementation-dark.html` 的 P3–P5 推进：

1. **P3 开工前无需再动框架**：`STIM_PERIOD` 已落地并自测，且 `frame_tx` 与 `blk_inter` 已在实际
   使用它——采样域 DUC 的"符号 1/4 节奏进"可以直接用。
2. **P3 需要先冻的三项**留在接口规格 §8：`srrc_duc` 输出位宽与小数位、目标时钟与采样率、
   SFDR 分析方法。两版 SRRC 必须共用同一份 12 bit 量化系数（"逐拍一致"的前提）。
3. **P4 需要 Vivado 综合实现两轮采数**（同一约束、同一目标时钟取均值），本机 Vivado 2021.2 可用；
   `blk_inter` 两版存储的资源差异也应在同一轮采数里一并记录（§7 第 4 条）。
