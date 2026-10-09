# S6 跳频链接口规格书（fh_interface）

> **适用模块**: `fh_ctrl` / `nco_hop`（本版）→ TOD 时基 / 同步字捕获 / 跳同步状态机（预留）
> **状态**: **本版冻结 `fh_ctrl` 口径**（§2–§4）**与 `nco_hop` 口径**（§5），其余模块仅登记边界与预留（§6），不冒充已有
> **冻结依据**: 计划书 S6 步骤卡「跳频层：fh_ctrl / nco_hop / TOD / 捕获 / 跳同步状态机」
> 首条「`fh_ctrl`：LFSR-16 直移，收发同种子 10⁶ 跳逐跳比对，16 信道驻留均匀性统计（偏差 <±10%）」
> **日期**: 2026-10-09
> **变更策略**: 冻结后 `fh_ctrl` 不得私改；改多项式 / 种子 / 映射 / 移位节拍必须走变更流程，
> 重跑黄金自检与全部 `fh_ctrl` 向量，并重出跳频图案统计

跳频层为什么也要"接口先于 RTL 冻结"：`nco_hop` 换 FTW 的时刻、TOD 外推的跳沿、捕获后状态机
的跳序号对齐，全都以 `fh_ctrl` 的"跳"定义为基准。图案发生器的口径含糊一处（一跳移几位、
信道号取哪几位），下游三个模块会各自"合理发挥"，最终在 S8 全链环回表现为"图案对不上"——
与接收链同一种不可回溯的错位。故本规格先把"一跳"的定义写死。

## 1. 通用流控约定（沿用 `s4_tx_interface.md` §1 / `s5_rx_interface.md` §1）

1. **valid-only，无背压**：只有 `din_valid/din_*` 与 `dout_valid/dout_*`，没有 `ready`。
2. **按 valid 对齐**：比对与下游消费只认 `dout_valid`，不认绝对时刻。
3. **复位语义**：同步低有效复位。复位后 LFSR 状态 ← 参数 `SEED`，`hop_index` ← 0，
   `dout_valid` ← 0，信道号总线保持未定义直到第一跳。
4. **比特序 MSB-first**：多路信号打包"高位在前"（与全工程一致）。
5. **判据行必须纯 ASCII**（脚本只 match ASCII 字段，见 `sim/README.md` §5）。
6. **跳速无关**：`fh_ctrl` 是纯 tick 驱动逻辑，一拍 `din_valid` = 一个跳沿，
   与绝对跳速（100/500/1000 hop/s）无关；三档跳速的验证归 `nco_hop` / TOD / 状态机（§5）。

## 2. 跳频图案口径（本版冻结）

### 2.1 LFSR-16 直移

| 项 | 冻结值 | 来源 / 理由 |
|---|---|---|
| 结构 | Fibonacci LFSR，每拍输出寄存器 LSB，反馈位进最高位 | 与 `frame_format.md` §2 的 6 级 LFSR **完全同构**（`float_chain/framing.m_sequence` 同一语义），全工程只有一种 LFSR 写法 |
| 级数 | 16 | 任务卡「LFSR-16」 |
| 多项式 | `x^16 + x^15 + x^13 + x^4 + 1`，掩码 `17'h1A011`（bit i = x^i 项，含 x^0 与 x^16） | 16 级本原多项式，**周期 2^16−1 = 65535 已数值验证**（`check_fh_pattern.py` 自检项）；掩码表示沿用 `frame_format.md` §2 风格 |
| 反馈抽头 | `state[0] ^ state[4] ^ state[13] ^ state[15]` → 移入 `state[15]` | 掩码低位 16 bit 展开（不含 x^16 最高项），与 `_taps_of` 一致 |
| 种子 | 参数 `SEED`，默认 `16'h0001`（仅 LSB=1） | 与 `m_sequence(state=1)` 同风格；**全零种子是吸收态，禁止** |
| 运行时重载 | `din_seed_load=1` 拍加载 `din_seed` 并清 `hop_index`，该拍不产生输出 | 收发重同步 / 多种子用例需要；"收发同种子"即收发两侧加载同值 |

### 2.2 一跳 = 移位 4 拍，信道号非重叠取字

| 项 | 冻结值 | 理由 |
|---|---|---|
| 移位节拍 | **一跳 = LFSR 推进 4 拍**（RTL 一拍组合展开 4 级反馈） | 16 信道 = 4 bit/跳；4 bit **非重叠**取字，相邻跳信道号无移位窗口相关性（每跳仅移 1 bit 会让相邻跳共享 3 bit，频点序列出现强局部结构，对跳频图案是缺陷） |
| 信道号 | `channel = {b0, b1, b2, b3}`，`b0` = 本跳**首个**移出位（现态 LSB），依次 `b1..b3` | `b0` 落在 `channel[3]`——MSB-first 总线约定；移出位即"输出 LSB"语义的连续 4 个输出 |
| 信道映射 | `channel[3:0]` 即 16 信道号 0–15，无重排 | 映射只影响频点编号不影响均匀性；nco_hop 的 FTW 表按同一编号（§5） |
| 跳序号 | `hop_index[19:0]`：种子加载后第一跳 = 0，逐跳 +1；**2^20 自然回绕** | 2^20 = 1 048 576 > 任务卡 10⁶ 跳长跑，不回绕；回绕语义登记在此防歧义 |
| 一拍一跳 | `din_valid` 一拍完成一跳（组合展开，无微序列） | 4 级 XOR 扇入浅，不构成时序压力；换来"跳沿 = 激励拍"的最简时序契约 |

**m 序列周期与跳的换算**：65535 bit / 4 = 16 383 跳 + 3 bit 余量。整周期后 bit 流周期平铺
（LFSR 周期性保证平铺 = 连续推进），故信道驻留分布在 16 384 跳以上即趋均匀；
±10% 判据在 10⁶ 跳上的统计余量极大（期望每信道 62 500 次，二项 σ≈245）。

### 2.3 驻留均匀性（任务卡判据）

10⁶ 跳（收发同种子）统计 16 信道各自驻留次数，要求每信道落在均值的 **±10%** 内
（即 56 250–68 750）。统计在黄金参考自检与 RTL 长跑 TB 各做一次，双侧互证。

## 3. `fh_ctrl` 接口

```verilog
module fh_ctrl #(
    parameter SEED = 16'h0001       // 复位后默认种子（全零禁止）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        din_valid,      // 一拍 = 一次加载或一跳
    input  wire        din_seed_load,  // 1: 加载 din_seed（不产生输出）；0: 推进一跳
    input  wire [15:0] din_seed,
    output reg         dout_valid,     // 每跳一拍（种子加载拍不拉高）
    output reg  [19:0] dout_hop_index, // 0 起，逐跳 +1，2^20 回绕
    output reg  [3:0]  dout_channel    // 本跳信道号 0–15
);
```

时序语义：

1. `din_seed_load=1` 拍：`state ← din_seed`，`hop_index ← 0`，`dout_valid=0`；
2. `din_seed_load=0` 拍：按 §2 推进一跳，**下一拍** `dout_valid=1` 并给出
   `{hop_index, channel}`（寄存输出一拍延迟，利于 nco_hop 侧时序；框架按 valid 对齐不受影响）；
   `hop_index` 给出的是**本跳**序号（加载后第一跳 = 0）；
3. 非输出拍 `dout_channel/dout_hop_index` 保持上一跳值——`nco_hop` 按 `dout_valid`
   才换 FTW，保持期就是"驻留期"；
4. 连续拍逐拍 `din_valid`（每拍一跳）合法，输出连续吐拍。

**拍数账本**：N 个激励拍中 L 个加载拍、H 个跳拍（N = L + H）→ `dout_valid` 恰 H 拍。
比对长度 = H（框架 stim/expect 长度解耦直接支持）。

## 4. `fh_ctrl` 验证判据

> **实测结果**（2026-10-09 收口，`sim/run_fh_ctrl_check.bat` 串跑三用例 + 长跑全过）：
> `seq` 16 384 跳 / `rand` 16 384 跳 / `edge` 768 跳逐跳 `errors=0`（`compared = n_exp`）；
> `tb_fh_ctrl_long` 10⁶ 跳收发互比 **mismatches=0**、前 8 跳黄金锚点一致（`8,0,0,0,14,9,13,9`），
> 16 信道驻留 min=62 450 / max=62 551 全部 ∈ [56 250, 68 750]（均匀性 PASS）。
> 判据行见 `sim/logs/fh_ctrl_{seq,rand,edge,long}.xsim.log`。

1. **位真比对**（`run_fh_ctrl_check.bat`，golden = `golden_ref.fixed_point.fh_pattern`）：
   | 用例 | 内容 | 规模 |
   |---|---|---|
   | `seq` | 单种子（`SEED` 默认）连续 16 384 跳 = 4×2^16 bit，覆盖 LFSR 全周期 + 跨周期平铺边界 | 16 384 跳 |
   | `rand` | 随机种子重载 ×4 段，每段 4 096 跳（打加载语义 + 多种子） | 16 384 跳 |
   | `edge` | 边界种子 `16'h0001` / `16'h8000` / `16'hFFFF` / `16'h5A5A` 各一段 + 加载拍密集穿插 | ≈1 000 跳 |
   判据：`errors=0` 且 `compared = n_exp`（逐跳 `{hop_index, channel}` 全对）。
2. **10⁶ 跳收发互比 + 均匀性**（`tb_fh_ctrl_long`，任务卡原文判据）：TX/RX 两个实例
   同种子各推进 10⁶ 跳，逐跳互比 `channel` 与 `hop_index`；RX 侧统计 16 信道驻留，
   判据：**0 失配 + 每信道驻留 ∈ [56 250, 68 750]**（±10%）。
3. **黄金自检**（`check_fh_pattern.py`）：多项式周期 = 65535、全零种子拒收、
   10⁶ 跳均匀性 ±10%、平铺与连续推进逐位一致。

## 5. `nco_hop`（本版冻结）

任务卡原文判据：「每跳仅更新 FTW、相位累加器不复位——testbench 用断言连续监测相位轨迹，
3×10⁵ 跳无阶跃，FTW 生效延迟 <1 µs」。与 `fh_ctrl` 的边界：`fh_ctrl` 无相位概念，
两者接口只有 `{dout_valid, dout_channel}`（§2.2 / §3）；信道号 → FTW 查表归 `nco_hop`。

### 5.1 频率规划（FTW 表，本版冻结）

16 信道均匀分布，信道 k（0–15，与 §2.2 编号一一对应、无重排）：

```
FTW[k] = (2k+1) × 1024        # = (2k+1) × 2^10
f[k]   = (2k+1) × fs / 64     # fs = NCO 样本时钟（验证档位 8 MSPS）
```

| 项 | 值 | 理由 |
|---|---|---|
| 信道间隔 | fs/32（验证档位 250 kHz） | 2 的幂，FTW 全为整数，位真无舍入 |
| 频段 | fs/64 … 31fs/64（验证档位 125 kHz … 3.875 MHz） | 严格位于 (0, fs/2)：避开 DC（FTW=0 得常数 LO）与 fs/2 边界；与 S4 固定频点 fs/8 同属 (0, fs/2) 谱图直观 |
| FTW 全集 | 1024, 3072, …, 31744（16 个奇数倍 1024） | 一一对应、单调、无重排 |
| NCO 核 | 16 bit 相位累加 + Q2.14 四分之一波 LUT | **逐项复用 S4 已验证口径**（`s4_tx_interface.md` §5.2/§6.1：镜像 `16383−idx`、`cos(p)=sin(p+2^14)`、相位不清零）；LUT 源 `src/nco_lut.mem` 不另造 |

注意：S4 的 fs/8（FTW=8192）是测试载波，**不是**跳频信道之一；交叉锚点由黄金自检在
NCO 核级以 FTW=8192 对 `duc.FixedNCO` 完成，不进 FTW 表。

### 5.2 相位连续与生效延迟语义（逐拍，采样节拍 = `din_valid`）

每拍（`din_valid=1`）原子执行（非阻塞语义，与 `srrc_duc` NCO 同构）：

```
dout ← LUT(phase)          # 输出当前相位（FixedNCO.step 口径），phase 不截断直接寻址
phase ← phase + ftw        # 16 bit 自然回绕；只加不清零
if (hop) ftw ← FTW[ch]     # 换字不清相位；本拍步进仍用旧 ftw
```

- **跳只换 FTW、绝不清零 phase**——"相位连续"的全部含义。加载拍步进用旧 ftw
  （`s4_tx_interface.md` §5.2 的 `freq_valid` 非阻塞语义原样搬用），新 ftw 从**下一拍**的步进起生效。
- **FTW 生效延迟**：跳事件拍 k → ftw 寄存器拍 k+1 生效 → 首个反映新字的步进在拍 k+2。
  验证档位 fs = 8 MSPS（1 拍 = 125 ns）：**生效延迟 = 2 拍 = 250 ns < 1 µs**（= 8 拍）。
- `din_valid=0`：整拍冻结（输出无效、phase/ftw 保持）——与全链 valid 门控数据通路一致。

### 5.3 接口

```verilog
module nco_hop (
    input  logic        clk, rst_n,
    input  logic        din_valid,       // 样本节拍：每拍产出 1 个 LO 样本
    input  logic        din_hop_valid,   // 跳事件（= fh_ctrl.dout_valid 同拍）
    input  logic [3:0]  din_channel,     // 信道号（= fh_ctrl.dout_channel）
    output logic        dout_valid,
    output logic [15:0] dout_phase,      // 相位累加器观测口（轨迹证据，任务卡出口门槛）
    output logic [15:0] dout_cos,        // Q2.14（= nco_lut 刻度）
    output logic [15:0] dout_sin
);
```

- 比对总线：stim = `{din_valid, hop_valid, channel[3:0]}`（6 bit），
  expect = `{phase[15:0], cos[15:0], sin[15:0]}`（48 bit，高位在前）。
- `dout_phase` 同时是比对项与相位轨迹证据来源（出口门槛要"断言报告 + 相位轨迹图"双证据）。
- 拍数账本：1 激励拍 → 1 输出拍（valid 对齐，寄存 1 拍不影响比对）。

### 5.4 验证判据

> **实测结果**（2026-10-09 收口，`sim/run_nco_hop_check.bat` 串跑三用例 + 长跑全过）：
> `seq` 2 048 拍 / `rand` 3 171 拍 / `edge` 201 拍逐拍 `{phase, cos, sin}` **errors=0**（`compared = n_exp`）；
> `tb_nco_hop_long` 相位轨迹断言 **cont_err=0**（1 616 006 拍逐拍 `Δphase ≡ 生效 ftw`，含 16 bit 回绕）、
> FTW 生效延迟断言 **delay_err=0**（300 012 跳全部 delay_hits 命中，跳当拍用旧字 / 下一拍用新字），
> 压缩长跑 300 000 跳 + 三档真实节拍（8 000/16 000/80 000 拍/跳）各 4 跳，16 信道全覆盖；
> 生效延迟实测 **2 拍 = 250 ns @ 8 MSPS < 1 µs**。黄金自检 `check_nco_hop.py` 18/18；
> 相位轨迹图 `data/s6_nco_hop_phase/phase_trajectory.png`（256 跳实测步进 vs 冻结 FTW 表 max|差| = 0）。
> 判据行见 `sim/logs/nco_hop_{seq,rand,edge,long}.xsim.log`。

1. **位真比对**（`run_nco_hop_check.bat`，golden = `golden_ref.fixed_point.nco_hop`）：
   三用例 `seq` / `rand` / `edge`，逐拍比对 `{phase, cos, sin}`，判据 `errors=0` 且
   `compared = n_exp`。`edge` 含 min 跳间隔（每拍一跳）、max 稳态间隔、`din_valid` 门控空隙、
   信道 0/15 边界与同信道连跳。
2. **相位轨迹断言 + 3×10⁵ 跳长跑**（`tb_nco_hop_long`）：每拍断言
   `phase_next − phase ≡ 生效 ftw`（mod 2^16，除 rst 外无任何其他来源），
   即"无阶跃"的机器检查；跳事件后 ≤2 拍断言 ftw 已切到 FTW[ch]（生效延迟 <1 µs）。
   长跑 3×10⁵ 跳（任务卡原文数）；三档跳速（100/500/1000 hop/s @ fs=8 MSPS →
   80000/16000/8000 拍/跳）各以真实节拍短跑覆盖生效延迟与连续性。
3. **黄金自检**（`check_nco_hop.py`）：FTW 表唯一性/边界、NCO 核 vs `duc.FixedNCO`
   交叉锚点（FTW=8192）、相位连续属性、生效延迟、LO 量化误差界、压缩 3×10⁵ 跳轨迹。

**有意偏差登记**：3×10⁶ 拍级的真实节拍长跑 xsim 不可行（3×10⁵ 跳 × 8000 拍/跳 = 2.4×10⁹ 拍），
故 3×10⁵ 跳长跑取**压缩节拍 4 拍/跳**（1.2×10⁶ 拍，约 1 符号/跳）；三档真实节拍（8000/16000/
80000 拍/跳）各跑短序列覆盖"延迟与连续性在真实 dwell 下成立"。两者的断言代码完全相同，
差别只在 dwell 长度，不构成判据放松。

## 6. 后续模块预留（本版只登记，不实现）

1. **TOD 时基**：1 ms tick + 帧头携 TOD 外推跳沿（帧格式 `frame_format.md` 头部
   `[29:24]` 6 bit 保留位是承载候选，字段分配待 TOD 模块冻结）。TOD 对齐误差
   ≤±0.25 跳周期是任务卡判据。跳沿对齐用 `hop_index`（§2.2）。
2. **同步字捕获**：归 S6（S5 `s5_rx_interface.md` §5 已划界）。同步字长度口径
   **64 bit**（`frame_format.md` 冻结值；计划书 S6 的"32 bit Gold"是旧口径，已在
   `s5_rx_interface.md` §7 登记移交本规格更正——此处确认更正生效）。
3. **跳同步状态机**（扫描→捕获→跟踪→重捕）：迁移全覆盖、无死锁判据属该模块收口。
4. **三档跳速验证**（100/500/1000 hop/s）：`fh_ctrl` 与速率无关（§1 第 6 条）；
   `nco_hop` 的三档覆盖见 §5.4（跳间隔节拍）；TOD 与状态机的三档判据在其收口用例中覆盖。

## 7. 决策登记

| # | 决策 | 理由 | 代价 |
|---|---|---|---|
| 1 | 每跳移 4 bit 而非 1 bit | 非重叠取字消除相邻跳信道号的移位窗口相关性 | 无（m 序列均衡性不依赖取字方式） |
| 2 | 多项式取 `x^16+x^15+x^13+x^4+1` | 16 级本原多项式（周期 65535 数值验证）；掩码风格与 `frame_format.md` 同构 | 换多项式 = 全链跳频图案失效，须走变更流程 |
| 3 | 运行时种子重载（`din_seed_load`） | 收发重同步与多种子用例需要；也使激励总线语义非平凡（否则 stim 是死值） | 端口多 1 bit + 17 bit 种子；"加载拍不出数"一条语义要进比对口径 |
| 4 | `hop_index` 20 bit 自然回绕 | 覆盖任务卡 10⁶ 跳不回绕；比 32 bit 省位宽 | 2^20 以上长跑会回绕（已登记，无实际用例） |
| 5 | 信道号取移出位 `b0` 在 MSB（`channel[3]`） | 与工程"高位在前"总线约定一致 | 无 |
| 6 | FTW 表 `(2k+1)×1024`（§5.1） | 均匀间隔 fs/32、严格位于 (0, fs/2)、全整数位真无舍入 | fs/8 不在表内（S4 测试载波非信道，交叉锚点走黄金自检）；换表 = 全链频点失效，走变更流程 |
| 7 | `nco_hop` 输出 `dout_phase` 观测口 | 任务卡出口门槛要"相位轨迹图"证据，轨迹直接来自向量 | 端口多 16 bit |
| 8 | 加载拍步进用旧 ftw（非阻塞） | 与 `srrc_duc` §5.2 已验证 NCO 逐拍同构，不造第二套生效语义 | 生效延迟 2 拍（250 ns @ 8 MSPS），仍在 <1 µs 判据内 |
