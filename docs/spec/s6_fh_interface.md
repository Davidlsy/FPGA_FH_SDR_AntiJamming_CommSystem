# S6 跳频链接口规格书（fh_interface）

> **适用模块**: `fh_ctrl` / `nco_hop` / `tod` / `sync_acq`（本版）→ 跳同步状态机（预留）
> **状态**: **本版冻结 `fh_ctrl` 口径**（§2–§4）、**`nco_hop` 口径**（§5）、**`tod` 口径**（§7）
> **与 `sync_acq` 口径**（§8），其余模块仅登记边界与预留（§6），不冒充已有
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

1. **TOD 时基**：~~预留~~ → **已冻结于 §7**（帧头 `[29:24]` 字段分配同步落
   `frame_format.md` §3）。TOD 对齐误差 ≤±0.25 跳周期是任务卡判据。跳沿对齐用
   `hop_index`（§2.2，双 `fh_ctrl` 实例互比）。
2. **同步字捕获**：~~预留~~ → **已冻结于 §8**（`sync_acq`）。归 S6（S5
   `s5_rx_interface.md` §5 已划界）。同步字长度口径 **64 bit**（`frame_format.md`
   冻结值；计划书 S6 的"32 bit Gold"是旧口径，已在 `s5_rx_interface.md` §7 登记
   移交本规格更正——§8 确认更正生效）。
3. **跳同步状态机**（扫描→捕获→跟踪→重捕）：迁移全覆盖、无死锁判据属该模块收口。
4. **三档跳速验证**（100/500/1000 hop/s）：`fh_ctrl` 与速率无关（§1 第 6 条）；
   `nco_hop` 的三档覆盖见 §5.4（跳间隔节拍）；TOD 与状态机的三档判据在其收口用例中覆盖。

## 7. `tod` 时基本体口径（本版冻结）

> 任务卡：「TOD 时基：1 ms tick + 帧头携 TOD 外推跳沿，仿真验证对齐误差 ≤±0.25 跳周期」。
> 帧头承载只有 `frame_format.md` §3 的 6 bit 保留位可用，字段分配**由本节冻结**（该行注释
> 原文即"字段分配待 TOD 模块冻结"）。

### 7.1 时基与跳沿网格

| 项 | 冻结值 | 来源 / 理由 |
|---|---|---|
| 时钟域 | 采样时钟 clk（fs = 8 MSPS），每拍一采样 | 与全链同域；TOD 是全链唯一时间权威 |
| tick | **TICK_SAMPLES = 8000 拍 = 1 ms**（整数，无舍入） | 任务卡「1 ms tick」；8 MSPS × 1 ms = 8000 |
| tick 计数 | `tod[31:0]`，每 tick +1，**2^32 自然回绕**（≈49.7 天） | 与 `hop_index` 同风格的自然回绕；比对口径里含窄位宽回绕自检 |
| 子拍相位 | `frac[12:0]`：0..7999，tick 边界清 0 | 对齐/装订都以"拍"为最小分辨率 |
| 跳沿网格 | **跳沿 = tick 边界且 `tod ≡ 0 (mod hop_ticks)`**，`hop_ticks`：1000 hop/s→1、500→2、100→10 | 跳沿永远落在 tick 边界 → 无亚拍抖动；三档跳速即三档分频比 |
| rate_sel 生效 | 即时（下一拍按新 `hop_ticks` 判沿），跳沿仍只落 tick 边界 | 网格锚定使换挡不需要"生效延迟"语义 |
| 跳沿对齐判等 | 双 `fh_ctrl` 实例的 `hop_index` / `channel` 互比（§2.2） | §6.1「跳沿对齐用 hop_index」的落地形式；不造第二套跳计数 |

### 7.2 帧头字段分配与外推语义

| 项 | 冻结值 | 理由 |
|---|---|---|
| 帧头 `[29:24]` | **`tod[5:0]`（帧首 bit 拍的 tick 计数低 6 位）**，未启用 TOD 时恒 0 | 6 bit 承载不了 32 bit 计数；低 6 位 + 连续跟踪即"截断 TOD"标准做法 |
| 采样时刻 | 帧首 bit 拍（同步字后第一 bit），由 `frame_tx` 侧在该拍取 `dout_tod[5:0]` | 语义唯一：字段值 = 该拍输出的 `dout_tod[5:0]` |
| 帧首对齐约束 | **帧首 bit 落在 tick 边界**（TX 调度约束，tick 边界拍即 tick 脉冲拍） | 6 bit 装不下"毫秒数 + 子毫秒相位"两项；帧首锚定 tick 边界后字段只需毫秒数，相位信息由边界语义免费提供。不锚定时 1 ms 相位不确定度 = ±1 跳周期 @1000 hop/s，判据不成立 |
| 外推（对齐） | `din_align_valid` 拍载入 `din_align_tod`：`tod` 低 6 位对齐到 A，高 26 位取 64 窗内**最近**值（snap）；`frac ← 0` | 帧间隔 0.54 ms ≪ 64 ms 模糊窗，连续跟踪消歧；snap 牵引范围 ±32 tick |
| 牵引范围 | **±32 tick（±32 ms）**；更大偏差须 `din_tod_load` 装订或状态机粗对齐 | 截断 TOD 的固有边界，负例进自检（+33 不修正，行为见 7.4） |
| 对齐误差判据 | 对齐后跳沿时刻与基准网格偏差 **≤±0.25 跳周期**（三档各测） | 任务卡判据；折算采样数 1000 hop/s→±2000、500→±4000、100→±20000 |

**为什么误差预算够**：对齐残差 = 帧首检测抖动 δ（采样级）+ 0（理想共钟，无漂移）。
δ = ±100 拍时最坏档误差 = 100/8000 = 0.0125 跳周期，判据余量 20×。
真实晶振 ppm 级频偏导致的缓慢走离归 BV-05 遗留板级（本域只证逻辑正确性）。

### 7.3 接口

```verilog
module tod #(
    parameter int TICK_SAMPLES = 8000,      // 1 ms @ 8 MSPS（冻结值）
    parameter int TOD_W        = 32,        // tick 计数位宽（自检用窄位宽测回绕）
    parameter int FIELD_W      = 6          // 帧头字段宽（frame_format.md [29:24]）
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                din_valid,       // 采样拍使能；0 = 整拍冻结（停表）
    input  wire [1:0]          din_rate_sel,    // 0:1000, 1:500, 2:100 hop/s（其余=1000）
    input  wire                din_tod_load,    // 装订：tod ← din_tod_value, frac ← 0，并声明边界
    input  wire [31:0]         din_tod_value,
    input  wire                din_align_valid, // 帧头 TOD 对齐（与装订同拍时装订优先）
    input  wire [5:0]          din_align_tod,   // 帧头 [29:24] 字段值
    output reg                 dout_valid,
    output reg                 dout_tick,       // 1 ms tick 脉冲（tick 边界拍）
    output reg  [31:0]          dout_tod,        // 当前 tick 计数（低 6 位 = 帧头字段）
    output reg                 dout_hop_edge    // 跳沿脉冲（驱动 fh_ctrl.din_valid）
);
```

时序语义：

1. `din_valid=0` 拍：`frac/tod` 均不推进，`dout_valid=0`，无任何脉冲（时基停表；
   运行期 `din_valid` 恒 1，门控仅用于测试/停用模式）；
2. 复位：`frac ← 0`、`tod ← 0`、`dout_valid ← 0`（初始相位归零，装订后才对外生效）；
3. `dout_tod` 连续给出当前计数，`frame_tx` 在帧首 bit 拍取 `dout_tod[5:0]` 入帧头。

### 7.4 每拍原子执行（`din_valid=1`）

```
tick ← 0; hop ← 0
1) 自然步进（总是发生）:
    frac ← frac + 1
    若 frac == TICK_SAMPLES（原 frac = TICK_SAMPLES−1）:
        frac ← 0; tod ← tod + 1（mod 2^TOD_W）
        tick ← 1; 若 tod ≡ 0 (mod hop_ticks) 则 hop ← 1
2) 装订/对齐（同拍改写，不吞 1) 的脉冲）:
    若 din_tod_load:      tod ← din_tod_value; frac ← 0                （装订，优先级最高）
                          tick ← 1; 若 tod ≡ 0 (mod hop_ticks) 则 hop ← 1（装订 = 声明边界）
    否则若 din_align_valid:
        a ← snap(din_align_tod)
        若 tod ≠ a:  tick ← 1; 若 a ≡ 0 (mod hop_ticks) 则 hop ← 1    （补发声明边界）
        tod ← a; frac ← 0                                              （相位重锚到对齐拍）
输出寄存: dout_valid ← 1; dout_tick/dout_hop_edge ← 本拍脉冲; dout_tod ← tod（步进/改写后）
```

- **snap(A)**：`X = (tod & ~63) | A`；若 `X − tod > 32` 则 `X −= 64`；若 `tod − X > 32` 则 `X += 64`
  （mod 2^TOD_W）。等价"64 窗内最近"，牵引范围 ±32；
- **对齐脉冲规则"未发过才补发"**（判据 4 跳计数守恒的关键）：对齐声明"本拍 = 帧首 tick 边界"。
  晚检测（δ>0）时该边界的脉冲已由自然步进发出（步进后 `tod == a`）→ 不再补发，防**双跳沿**；
  早检测（δ<0）时自然 wrap 被 `frac ← 0` 重锚吞掉（步进后 `tod == a−1 ≠ a`）→ 补发，
  防**丢跳沿**。稳态下跳计数两种极性都守恒，`hop_index` 不积累漂移；
- **装订拍 = 声明边界**：装订把 tod 改写到 `din_tod_value` 并把 frac 清 0，即声明"本拍 = 该值的
  tick 边界"，故同拍发 tick 脉冲、网格点再发 hop 脉冲。不发脉冲会让装订后的头 `hop_ticks` 毫秒
  没有跳沿驱动 `fh_ctrl`（无有效信道的孤儿区间）；对齐的"补发"以同一边界语义为基准；
- **拍数账本**：N 个激励拍中 F 个冻结拍 → `dout_valid` 恰 N−F 拍，与 nco_hop 同款长度解耦；
- tick 拍的 `dout_tod` = **新**计数（帧首 bit 拍取到的即该 tick 的编号）——字段语义锚点；
- 对齐拍必须 ≈ tick 边界（7.2 契约）：中段拍对齐会重锚栅格，是口径误用（7.6 #3）。

### 7.5 验证判据

> **实测结果**（2026-10-09 收口，`sim/run_tod_check.bat` 串跑三用例 + 长跑全过）：
> `seq` 2 881 拍 / `rand` 4 921 拍 / `edge` 568 拍逐拍 `{tick, tod[31:0], hop_edge}` **errors=0**
> （`compared = n_exp`；比对缩参 TICK_SAMPLES=10 / TOD_W=8，语义对参数无依赖，
> 冻结值 8000/32 由长跑与黄金自检覆盖）；
> `tb_tod_align_long`（真实 8000/32）7 相位全过：三档跳速 × 对齐误差 + 跳沿守恒 + 40 tick 外推，
> **align_err_max = 100 拍 ≤ ±2 000 拍判据**（1000 hop/s 档 ±0.25 跳周期 = ±2 000 拍 @ 8 MSPS，
> 其余档界宽 4 000/20 000 拍）、tick 节拍 `cad_err=0`、双 `fh_ctrl` 逐跳 `fh_err=0`
> （对齐后 `hop_index`/`channel` 全等，含 40 tick 自由外推段 `drift_err=0`）。
> 黄金自检 `check_tod.py` 26/26（含 +33 tick 牵引范围负例）。
> 判据行见 `sim/logs/tod_{seq,rand,edge,long}.xsim.log`。

1. **位真比对**（`run_tod_check.bat`，golden = `golden_ref.fixed_point.tod`）：
   `seq` / `rand` / `edge` 三用例逐拍 `{tick, tod[31:0], hop_edge}` `errors=0`；
2. **tick 精确性**：无对齐/装订事件区间内相邻 tick 脉冲恰隔 8000 个有效拍；
   对齐事件允许 8000±δ 重锚（长跑逐段断言）；
3. **对齐误差**（任务卡判据）：TX/RX 双实例，RX 初值带偏差 + 帧首检测抖动扫描，
   对齐后跳沿时刻互比 **≤±0.25 跳周期**，三档跳速各测，实测最大值入档；
4. **跳沿对齐用 `hop_index`**：对齐后双 `fh_ctrl` 的 `hop_index` / `channel` 逐跳相等；
5. **长外推**：单次对齐后自由外推（长跑段），跳沿不漂移、无抖动。

### 7.6 有意边界登记

1. **牵引范围 ±32 tick**：截断 TOD 的固有边界；+33 tick 偏差按 snap 仍留 −31 tick 误差
   （负例入黄金自检，行为有档不静默）。粗对齐归捕获 / 跳同步状态机（§6.2–§6.3）。
2. **理想共钟**：收发时钟同源无 ppm 频偏，对齐误差只有检测抖动分量；真实晶振走离归
   BV-05 遗留板级（计划书已登记），本域判据不含漂移分量。
3. **帧首 tick 边界约束**（7.2）：TX 调度必须把帧首 bit 排在 tick 边界；
   全链（S8）帧调度按此约束实现，代价是帧起点受 1 ms 栅格约束。

## 8. `sync_acq` 同步字捕获口径（本版冻结）

> 任务卡：「同步字捕获：32bit Gold 滑动相关 + 恒虚警门限（噪声估计 × 系数）+ M/N 判决，
> 统计检测概率 ≥99%、虚警 ≤1e-6 的 SNR 曲线」。同步字长度以 `frame_format.md` §2 的
> **64 bit** 为准（"32 bit"旧口径更正生效，§6.2）。
> 归属：S5 `sync_rx` 只做符号级同步（`s5_rx_interface.md` §5），帧同步字捕获归本节。
> 挂载点：`viterbi_dec` 输出的解码比特流——全帧（含同步字）进 `conv_enc`
> （`frame_format.md` §8.2），同步字只有解码后才可见，捕获天然落在比特域。

### 8.1 检测器口径（滑动相关 + 恒虚警门限）

| 项 | 冻结值 | 来源 / 理由 |
|---|---|---|
| 输入 | 解码比特流 1 bit/拍（`din_bit`，MSB-first 帧序） | 挂 `viterbi_dec` 输出 |
| 同步字 | `FRAME_SYNC_WORD = 64'h517AE4216E7555CA`（64 bit） | `frame_format.md` §2.3 冻结常量 |
| 滑动相关 | `corr = 64 − popcount(sr ⊕ SYNC)` ∈ [0, 64]，`sr` = 最近 64 bit（复位后不足窗补 0） | 硬比特域匹配滤波等价（匹配数 = 64 − Hamming 距离） |
| 噪声估计 | `noise_est = (Σ 最近 NAVG=16 个 corr（不含本拍） + 8) >> 4` | 恒虚警的"噪声估计" = **背景相关电平**的时间平均；训练窗不含被检单元（CA-CFAR 同款） |
| 门限 | `thresh = max(THRESH_MIN=52, (noise_est × 13) >> 3)`，系数 K = 13/8 = 1.625 | 任务卡"噪声估计 × 系数"；下限 52 = 背景电平 32（随机数据）时的名义值，使 p_w 无条件有界（8.5） |
| 命中 | `hit = (corr ≥ thresh)`，**等号算命中** | 冻结比较方向 |
| M/N 判决 | **M = 2、N = 3（帧槽确认）**，见 8.3 | 任务卡"M/N 判决" |

**为什么噪声估计是"背景相关电平"**：输入是硬判决比特，随机数据与平衡同步字（0/1 恰 32/32）
的相关均值恒 32，`noise_est` 即该背景电平的时间平均；门限 = 背景 × 1.625 并带下限。
恒虚警语义 = 门限随背景电平自适应，不随信号强度漂移。

### 8.2 接口

```verilog
module sync_acq #(
    parameter logic [63:0] SYNC_WORD   = 64'h517AE4216E7555CA,  // 冻结常量
    parameter int         FRAME_LEN    = 2160,   // 帧周期（bit），frame_format.md §7
    parameter int         M_HIT        = 2,      // M/N 判决（8.3）
    parameter int         N_SLOT       = 3,
    parameter int         NAVG         = 16,     // 噪声估计平均长度
    parameter int         COEFF_Q      = 13,     // 门限系数 K = COEFF_Q >> COEFF_SHIFT = 1.625
    parameter int         COEFF_SHIFT  = 3,
    parameter int         THRESH_MIN   = 52      // 门限下限（8.5 虚警上界的关键）
) (
    input  logic        clk, rst_n,
    input  logic        din_valid, din_bit,
    output logic        dout_valid,
    output logic        dout_hit,        // 本拍命中（观测口）
    output logic        dout_acq,        // M/N 确认脉冲（第 M 次槽位命中的拍）
    output logic        dout_frame_start,// 帧界声明脉冲 = 同步字末位拍
    output logic [6:0]  dout_corr,       // 观测口（统计/调试直接取自向量）
    output logic [6:0]  dout_thresh
);
```

- `dout_frame_start` 发出于**候选开启拍**与**每个命中槽位拍**（含最终确认拍），
  语义 = "该拍是同步字末位拍（帧首 bit 前一拍）"——下游 `tod` 对齐 / 状态机取帧界；
- `dout_valid` = `din_valid` 延 1 拍（输出寄存，同 `tod`）；
- **`din_valid=0` = 整拍冻结**：`sr` / 噪声历史 / 槽位计时 / 状态全保持，无输出行
  （长度解耦契约，同 `tod` 决策 #13）。

### 8.3 M/N 判决（帧槽确认）

**为什么 M/N 必须跨帧槽**：单个同步字只产生 **1 个**超门限样本——主峰占 1 拍（corr=64），
旁瓣 ≤ 40（`frame_format.md` §2.3 max|R|=16 → 匹配 ≤ 40）远低于门限 52；
逐拍滑窗 M/N 对单峰结构永远凑不齐 M 个命中。帧槽确认（候选开启后每 FRAME_LEN 拍
复检一次）是帧同步的标准 M/N 结构，虚警压制靠"伪峰须按 2160 bit 帧周期复发才能确认"。

每拍状态迁移（在 8.4 的原子执行内）：

| 状态 | 条件 | 动作 |
|---|---|---|
| IDLE | `hit` | 开候选：`timer ← FRAME_LEN`、`m ← 1`、`slots ← 1`；发 `frame_start` |
| TRACK | `timer > 1`（非槽位拍） | `timer ← timer−1`；**hit 被忽略**（锁定期，不抢占不重置） |
| TRACK | `timer == 1`（槽位拍） | `slots ← slots+1`；`hit` → `m ← m+1` 且发 `frame_start`；随后 **`m ≥ M` 优先**：发 `dout_acq`、关候选回 IDLE；否则 `slots ≥ N` → 弃候选回 IDLE；否则 `timer ← FRAME_LEN` |

- 开候选拍 = 槽位 1；此后每 FRAME_LEN 个**有效**拍一个槽位拍；
- **声明优先于弃候选**：第 N 槽恰凑满 M 时同拍取确认（边界判据入黄金自检）；
- 捕获延迟 = 1 帧（M=2）：首个命中拍 → 确认拍恰隔 FRAME_LEN 个有效拍；
- 速率无关：bit 域纯逻辑与 hop 速率解耦（同 `fh_ctrl` §1 第 6 条）；三档跳速覆盖归跳同步状态机。

### 8.4 每拍原子执行（`din_valid=1`）

```
1) sr ← {sr[62:0], din_bit};  corr ← 64 − popcount(sr ⊕ SYNC_WORD)
2) noise_est ← (Σ 近 16 拍 corr（不含本拍） + 8) >> 4
   thresh    ← max(THRESH_MIN, (noise_est × 13) >> 3)
   hit       ← (corr ≥ thresh)
   （随后本拍 corr 计入历史）
3) 状态迁移（8.3 表）
4) 输出寄存: dout_hit/dout_acq/dout_frame_start ← 本拍脉冲; dout_corr/dout_thresh ← 本拍值
```

- `din_valid=0` 的拍整拍冻结、无输出行；
- 拍数账本：N 个激励拍中 F 个冻结拍 → `dout_valid` 恰 N−F 拍（长度解耦，同 `tod`）；
- 复位后 `sr=0`（不足窗补 0）、噪声历史为空（`noise_est=0` → `thresh=THRESH_MIN`）。

### 8.5 验证判据

> **实测结果**（2026-10-09 收口，`sim/run_sync_acq_check.bat` 串跑三用例 + 长跑全过）：
> `seq` 4 800 拍 / `rand` 6 000 拍 / `edge` 3 928 拍逐拍 `{hit, acq, frame_start, corr[6:0], thresh[6:0]}`
> **errors=0**（`compared = n_exp`；比对缩参 FRAME_LEN=200，冻结 2160 由长跑 + 统计覆盖，§8.6 #4）；
> `tb_sync_acq_long`（真实 2160/M=2/N=3）三判据全过：噪声段 10 800 拍 **hit=0 fs=0 acq=0**、
> 6 帧 `frame_start` 拍与同步字末位拍全等（10 863…21 663）、3 次 `acq` **延迟恰 2 160 有效拍**
> （含 ~1% 停表拍混入，冻结拍不推进槽位计时已入拍号账）。
> 黄金自检 `check_sync_acq.py` 28/28（判据行 `[SYNC-ACQ-GOLDEN] status=PASS`）。
> 统计判据 `stat_sync_acq.py`（`data/s6_sync_acq/`）：**Pfa/帧 ≤ 2.25e-10**（解析联合界，
> 裕量 4 440×；纯噪声流 MC 5 000 万窗实测率 2.0e-7 vs 精确二项尾 2.28e-7，t=−0.45 一致；
> 检测器 200 万噪声拍 hit=0/acq=0）、**Pd(0 dB) = 1.0000**（500/500，95% 下界 0.9924 ≥ 0.99），
> Pd 曲线约 −2.3 dB 起过 0.99（BER 轴同图次轴）。
> 判据行见 `sim/logs/sync_acq_{seq,rand,edge,long}.xsim.log` 与 `data/s6_sync_acq/report.md`。

1. **位真比对**（`run_sync_acq_check.bat`，golden = `golden_ref.fixed_point.sync_acq`）：
   `seq` / `rand` / `edge` 三用例逐拍 `{hit, acq, frame_start, corr[6:0], thresh[6:0]}` `errors=0`；
2. **黄金自检**（`check_sync_acq.py`）：同步字常量互证、相关峰/旁瓣与自相关表互证、
   门限整数语义（四舍五入 + 下限）、`hit` 等号、M/N 全边界（确认优先 / 锁定期 / 无粘滞重开）、
   停表冻结、帧流互证（`build_frame_bits` 灌入恰在同步字末位拍声明）；
3. **统计判据**（`stat_sync_acq.py`，任务卡原文）：
   - **虚警 Pfa ≤ 1e-6/帧**：以解析上界为证——门限下限 52 使单窗命中率
     `p_w ≤ P(Binomial(64,½) ≥ 52) = 2.28e-7` 无条件成立（不依赖 `noise_est` 分布），
     候选开启率 ≤ `2160·p_w`/帧、误确认 ≤ `2·p_w`（N−1=2 个后续槽）→
     **Pfa/帧 ≤ 2.3e-10**（判据裕量 ≈ 4 000×）；纯噪声流 MC 实测命中率与精确二项尾
     一致（校核 p_w 模型），判据本身由上界证明；
   - **检测概率 Pd ≥ 99%**（Eb/N0 ≥ 0 dB）：MC 扫 SNR 曲线；
     SNR 口径 = 捕获输入比特流 Eb/N0（BPSK 硬判决映射 BER = Q(√(2·Eb/N0))），
     同时出 BER 轴；
   - 曲线产物 `data/s6_sync_acq/`（Pd/Pfa 曲线 + SNR 表 + 报告）。
4. **长跑**（`tb_sync_acq_long`，真实参数 FRAME_LEN=2160 / M=2 / N=3）：噪声段无误声明、
   信号段捕获延迟 = 1 帧、`frame_start` 拍与同步字末位拍重合。

### 8.6 有意边界登记

1. **候选锁定期不抢占**：开候选后最坏 N−1=2 帧内非槽位 hit 被忽略——噪声峰开候选后真同步字
   落入锁定期则该帧漏检，下一帧重试。概率 ≈ `2×2160×p_w ≤ 1e-3`（M=2 帧确认天然容 1 帧漏检）。
2. **载荷无白化**（`frame_format.md` §4）：载荷含伪同步图案可开候选甚至吞真峰；M/N 帧槽确认
   压制单次伪峰（须按帧周期复发才能确认），持续伪同步归跳同步状态机重捕。
3. **SNR 口径**：捕获输入比特流 Eb/N0（BPSK 硬判决映射）；端到端 Eb/N0 → 输入 BER 的映射
   归链路级（S5 Viterbi BER 曲线）。在 S5 实测译码 BER（≤1.7e-4 @ 0 dB）下捕获检测概率≈1，
   性能瓶颈在状态机（下一模块），本节曲线刻画检测器本身的抗噪边界。
4. **比对缩参**：`FRAME_LEN=200`（冻结 2160 由长跑 + 统计覆盖）；同步字 64 bit、M/N、
   门限参数均按冻结值比对（相关统计对 `FRAME_LEN` 无依赖，帧槽语义同构）。

## 9. 决策登记

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
| 9 | 帧头 `[29:24]` = `tod[5:0]`（截断 TOD） | 6 bit 是帧头唯一保留位；低 6 位 + 连续跟踪消歧（帧间隔 ≪ 64 ms 模糊窗） | 牵引范围 ±32 tick，更大偏差须装订 / 状态机粗对齐（7.6 #1） |
| 10 | 帧首 bit 锚定 1 ms tick 边界 | 6 bit 装不下"毫秒数 + 子毫秒相位"；锚定后相位免费，1 ms 计数即完整 TOD 语义 | 帧起点受 1 ms 栅格约束（TX 调度，7.6 #3） |
| 11 | 跳沿 = tick 边界且 `tod ≡ 0 (mod hop_ticks)` | 跳沿永远落 tick 边界 → 换挡无亚拍抖动、对齐误差以 tick 为参照 | 跳速只能取 tick 的整分频（100/500/1000 恰为 1/2/10，全覆盖） |
| 12 | 对齐拍"未发过才补发"声明边界脉冲（7.4） | 晚检测边界已发 / 早检测边界被重锚吞掉；只有"未发过才补发"让稳态跳计数两种极性都守恒，`hop_index` 不积累漂移 | tod 大步跳变（牵引/回拨跨过已发边界）瞬态跳计数不守恒——单拍脉冲接口的结构性边界，清零归捕获/跳同步状态机 `seed` 重载（§6）；判据 4 从收敛后起算。对齐拍必须 ≈ tick 边界（7.2 契约） |
| 13 | `din_valid=0` = 时基停表 | 沿用全工程 valid-only 冻结语义（§1），比对拍数账本同 nco_hop | 运行期必须恒 1；漏喂即丢时间（由全链 S8 保证） |
| 14 | 装订拍 = 声明边界（tick + 网格 hop 脉冲，7.4） | 装订即"本拍 = 该 tod 值的 tick 边界"；不发脉冲会让装订后头 `hop_ticks` 毫秒无跳沿驱动 `fh_ctrl`（孤儿区间），且与对齐"补发"的边界语义不一致 | 装订与自然 tick 同拍时脉冲合并为一拍（两边界恰重合，不构成丢失） |
| 15 | `sync_acq` 挂解码比特流（8 引言） | 同步字被 `conv_enc` 编码（`frame_format.md` §8.2），解码后才可见；比特域相关与帧格式天然同相 | 判决在 BER 域而非软 SNR 域——SNR 曲线走 BPSK 硬判决映射（8.6 #3） |
| 16 | 门限 = `max(52, est×13/8)`（8.1） | "噪声估计 × 系数"任务卡原文；下限使 `p_w ≤ 2.28e-7` **无条件**成立 → 虚警解析上界可证明（不依赖 est 分布） | est 大幅低于背景时灵敏度不再继续提升（下限即名义值，实际无损失） |
| 17 | M/N 跨帧槽判决（M=2/N=3，8.3） | 单同步字只有 1 个超门限拍，逐拍 M/N 凑不齐 M；帧槽确认是帧同步标准结构，伪峰须按帧周期复发才能确认 | 捕获延迟 1 帧；候选期占 2 帧（锁定期漏检见 8.6 #1） |
| 18 | 候选锁定期非槽位 hit 不抢占 | 无逐拍竞争/重锚逻辑，状态机可证（无死锁归状态机模块判据） | 噪声峰开候选后最坏吞 1 帧真峰（P ≈ 1e-3，M=2 天然容错） |
| 19 | 输出 `corr`/`thresh` 观测口（8.2） | 统计曲线与位真向量直接取自 DUT 输出，判据可互证（同 `nco_hop` 决策 #7 风格） | 端口多 14 bit |
