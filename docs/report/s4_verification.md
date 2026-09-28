# S4 发射链验证报告（P0 + P1）

> **阶段**: S4-P0 判据与接口冻结 + S4-P1 纯逻辑三模块（`frame_tx` / `conv_enc` / `qpsk_map`）
> **日期**: 2026-09-28
> **依据**: S4 任务卡「发射链 frame_tx / conv_enc / blk_inter / qpsk_map / srrc_duc」
> **验收入口**: `sim/run_s4_acceptance.ps1`（`-Full` 追加任务卡的两条长跑判据）
> **本报告范围**: 任务卡的五个模块里已完成三个（P0 冻结了全部五个的接口）；`blk_inter`（P2）、
> `srrc_duc` 双版 + NCO（P3）、IP vs 手写对比（P4）、整链收口（P5）**未开始**，见 §6。

## 1. 结论

```
[S4 ACCEPTANCE] suites=13 failed=0 positives=10 full=True status=PASS
```

- **13/13 套件通过**（10 条正例位真比对 + 3 条证伪用例），总耗时 **65.4 s**；
  只跑短用例为 `suites=11 failed=0 positives=8 full=False`，49.9 s。
- 任务卡的两条量化判据均已跑满：
  - `frame_tx` **1000 随机帧**：2,160,000 拍逐拍比对，**0 错误**；
  - `conv_enc` **10⁶ bit**：463 块 = 1,000,080 bit，输出 1,002,858 拍，**0 错误**。
- 三条证伪用例全部按预期判 FAIL（详见 §4.2）——**这是本报告最该被看重的部分**：
  正例的 PASS 只有在"把关键处改错就必然红"的前提下才有信息量。
- 帧层黄金模型自检 36 项 0 失败（`[FRAME-GOLDEN] checks=36 failed=0 status=PASS`）；
  比对框架自测 8 项全过（含 S4-P0 新增的 1:N 与激励节奏契约）。

## 2. 交付物

| 类别 | 文件 | 说明 |
|---|---|---|
| RTL | `src/frame_tx.v` | 帧成形：Gold 同步字 + 帧头 + 256B + CRC16，双缓冲 |
| RTL | `src/conv_enc.v` | (171,133)₈ 卷积编码，含 6 bit 归零尾比特与输入弹性缓冲 |
| RTL | `src/qpsk_map.v` | QPSK 直移映射，纯组合 |
| RTL | `src/frame_tx_sync.vh` | 同步字常量（生成物，综合期即 LUT-ROM） |
| 规格 | `docs/spec/frame_format.md` | 帧格式规格书（本阶段首次定义帧层，已冻结） |
| 规格 | `docs/spec/s4_tx_interface.md` | 五模块接口规格书（流控/位序/拍数账本/NCO 语义） |
| 黄金模型 | `sim/golden_ref/float_chain/framing.py` | 帧层唯一裁判：m 序列 / Gold / CRC16 / 成帧与解析 |
| 黄金模型 | `sim/golden_ref/sim/check_framing.py` | 帧层自检（36 项，两条独立 CRC 路径 + 注错负例） |
| 生成器 | `sim/golden_ref/gen_frame_sync.py` | 同步字 → RTL 常量，带 `--check` |
| 框架 | `sim/framework/hdl/tb_vec_cmp.sv` | 比对器扩展：激励/期望长度解耦 + 激励节奏 + `stim_count` |
| 框架 | `sim/framework/tb/tb_{qpsk_map,conv_enc,frame_tx}_compare.sv` | 三个模块的位真 TB（用例用 `-d` 切换，含证伪用例） |
| 向量 | `sim/framework/vectors/{qpsk_map,conv_enc,frame_tx}/` | 由 `export_vectors.py` 从黄金模型确定性导出 |
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
| `blk_inter`: 还原 0 错误；突发 10 bit 打散 ≥10 码字位 | **未开始（P2）** |
| `srrc_duc`: 两版逐拍一致；SFDR ≤ −50 dBc | **未开始（P3）** |
| IP vs 手写三栏对比表 | **未开始（P4）** |
| 五模块串联位真比对全过 | **未开始（P5）** |

`frame_tx` 的 CRC 检出能力另有一层证据在帧层自检里：CRC 覆盖区单比特注错 **32/32 全部检出**、
同步字注错被 `sync_ok` 检出、帧头版本位注错同时改变字段并让 CRC 失败。

## 5. 与任务卡的有意偏差（登记，不隐藏）

| # | 任务卡写法 | 实际做法 | 理由 |
|---|---|---|---|
| 1 | SRRC「31 抽头」 | 待 P3；将沿用 S1 冻结的 **33 抽头** | S1 系数是 `span 8 × sps 4 + 1 = 33`；位真裁判必须同源，改 31 要重跑 S1 BER 基线（属独立变更流程） |
| 2 | CRC16「并行 8-bit 查表，每拍一字节」 | **位串行 LFSR，每拍一比特** | `frame_tx` 输出是比特串行流，查表要在 2080 bit 之外另开 260 拍字节域；位串行版边发边算，零额外节拍 |
| 3 | 「写行读列地址生成器不变」 | 未变，且 `blk_inter` 接口已冻结 | P2 只换存储介质，不重写地址生成器 |
| 4 | 同步字 64 bit | 64 = Gold 周期 **63** + 首位重复 | 6 级 Gold 周期是 63，凑不出 64；代价已量化（旁瓣浮动 ±1，相对主峰 64 无实质影响） |
| 5 | 计划书"MATLAB 比对脚本" | 沿用 Python `golden_ref` | S2 已登记的偏差：比对基线须与冻结基准同源，避免两套"真理" |

## 6. 已知边界与遗留项

1. **P2–P5 未开始**：`blk_inter`、`srrc_duc` 双版 SRRC + NCO/DUC、IP vs 手写三栏对比、
   五模块整链收口均未做。任务卡的出口门槛因此**尚未达成**，本报告不得被引用为"S4 已通过"。
2. **`frame_tx` 的速率约束是接口属性**：上游平均每字节 ≥ 8.44 拍，否则帧缓存溢出丢字节
   （无背压约定下无法自愈）。已写进接口规格书 §4.1 与向量 `meta.json` 的 `stim_period`。
3. **`conv_enc` 的弹性缓冲只吸收短时抖动**：平均速率仍须 ≤ `blk_len/(blk_len+6)`；
   长跑用例把激励节奏放到 1/2 就是为了让缓冲常态只有几个比特（见 TB 头注释）。
4. **1000 帧 / 10⁶ bit 两条判据的向量不入库**：由固定种子确定性重生成，体积约 9 MB，
   按 `.gitignore` 的 S4 长跑向量段忽略；证据是本报告与 `sim/logs/s4_acceptance.log`
   （日志目录按既有约定不入库）。
5. **SFDR / 真实发射频谱**：属 P3 与板级，本阶段无频谱结论。真实频谱（含 AD9363 模拟链路）
   仍按任务卡口径移交 **BV-03**。
6. **板卡未到货**：本阶段全部结论都是仿真域结论，不构成任何硬件可用性结论。

## 7. 复现

```powershell
# 帧层黄金模型自检（36 项，含两条独立 CRC 路径与注错检出）
python sim\golden_ref\sim\check_framing.py

# 同步字常量与黄金模型一致性（手改常量会在这里暴露）
python sim\golden_ref\gen_frame_sync.py --check

# 比对框架自测（8 项，含 1:N 与激励节奏契约）
powershell -File sim\framework\run_selftest.ps1

# S4 统一验收：短用例 49.9 s / 含长跑判据 65.4 s（本机实测，Vivado 2021.2 xsim）
powershell -File sim\run_s4_acceptance.ps1
powershell -File sim\run_s4_acceptance.ps1 -Full
```

前置：`xvlog`/`xelab`/`xsim` 在 PATH（`call D:\software\vivado2021\Vivado\2021.2\settings64.bat`）、
Python 3.12 带 numpy。总日志落 `sim/logs/s4_acceptance.log`。

## 8. 下一步

按 `docs/s4-tx-chain-implementation-dark.html` 的 P2–P5 推进，但 P2 开工前有两件已识别的具体工作：

1. **P2 开工即需定**：`blk_inter` 的输入速率约束（块交织是"收满再读"，与 `frame_tx` 同理）
   与读写冲突模式；建议按双缓冲设计（读 2170 拍 / 写 2166 拍，双缓冲后无需空隙）。
2. **P3 开工前无需再动框架**：`STIM_PERIOD` 已落地并自测，采样域 DUC 的"符号 1/4 节奏进"
   可以直接用。
3. P4 需要 Vivado 综合实现两轮采数（同一约束、同一目标时钟），本机 Vivado 2021.2 可用。
