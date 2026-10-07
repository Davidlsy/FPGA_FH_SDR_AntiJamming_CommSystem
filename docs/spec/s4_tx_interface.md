# S4 发射链接口规格书 (TX Chain Interface Specification)

> **版本**: v1.1
> **适用模块**: `frame_tx` → `conv_enc` → `blk_inter` → `qpsk_map` → `srrc_duc`
> **机器可读来源**: `sim/golden_ref/config.py`（`FRAME_*` 帧格式 + `FIXED_POINT_CONFIG` 位宽 + `DUC_CONFIG` DUC 位宽）
> **相关规格**: `docs/spec/frame_format.md`（帧层）、`docs/spec/fixed_point_spec.md`（位宽）、
> `docs/spec/s4_tx_p3_freeze_draft.md`（P3 决策 1/2/3 全文）

## 0. 冻结状态

> **状态**: **本版冻结 §2–§8 全部**（P2 的 §4.3 四条决策、P3 的 §6.1 位宽架构与 §8 三项），无遗留待冻结项
> **冻结日期**: 2026-09-28（§2–§7，P0–P2）；2026-10-07（§6.1 + §8，P3 收口）
> **冻结依据**: S4 任务卡「五模块位真验证」+ 计划书 §S4-P0「接口冻结」
> **签核证据**: `sim/framework/run_selftest.ps1` → `[FRAMEWORK SELFTEST] PASS`（8 项，含 1:N 与激励节奏契约用例）；
> `sim/run_s4_acceptance.ps1` → `[S4 ACCEPTANCE] suites=18 failed=0 status=PASS`；
> srrc_duc 手写版 `srrc-frame/edge` 与 FIR IP 版 `srrc-fir-frame/edge` 四套件均 `errors=0`；
> `sim/golden_ref/sim/sfdr_analysis.py` → NCO/DUC SFDR −85.45 dBc（≤ −50 dBc 判据 PASS）
> **变更策略**: 接口冻结后任何模块不得私改；改接口必须走 §9 流程并重跑全部 S4 向量

为什么接口要先于 RTL 冻结：五个模块是**单方向线性串联**（图 1），上游一拍动的位序或节拍差一拍，
下游就是全链红。S2 的教训写在 `sim/framework/README.md` §9——"各自正确、互不一致"是最贵的错。

## 1. 通用流控约定（本版冻结）

1. **valid-only，无背压**：只有 `din_valid/din_data` 与 `dout_valid/dout_data` 两组信号，
   **没有 `ready`**。上游一拍能出一拍，下游必须能收下；速率由上游节拍天然形成。
2. **固定节拍**：同一输入的每个有效拍对应固定的输出拍数（各模块的比值见 §4），
   不存在"有时 1 拍、有时 2 拍"的输出长度。这条是位真比对可判定的前提。
3. **按 valid 对齐，不按绝对时刻对齐**：允许流水线延迟不同（IP 版 vs 手写版 SRRC 的延迟
   本来就不一样），比对只认各自的 valid。
4. **比特序 MSB-first**：字节内 MSB 先出；多比特字（帧头、CRC、总线上的多路信号）同样高位在前。
5. **复位语义**：同步低有效复位；复位后五个模块都回到空闲，`frame_tx` 帧号归零，
   `conv_enc` 移位寄存器与块内计数归零，`blk_inter` 写指针归零。
6. **总线打包顺序**：多路信号一律"高位在前"，例如 `{i, q}` 表示 I 在 `[23:12]`、Q 在 `[11:0]`。
7. 判据行必须是纯 ASCII（脚本只 match ASCII 字段），见 `sim/README.md` §5。

## 2. 模块接口总表

| 模块 | 输入 | 输出 | 拍数关系 | 本版状态 |
|---|---|---|---|---|
| `frame_tx` | `din_data[7:0]` 载荷字节 | `dout_bit` 帧比特流 | **256 → 2160** | 冻结 |
| `conv_enc` | `din_bit` + `blk_len[15:0]` 配置 | `dout_data[1:0]` = `{g₁, g₂}` | **N → N+6** | 冻结 |
| `blk_inter` | `din_data[1:0]` | `dout_data[1:0]` | **2166 → 2170**（尾部补零 8 bit = 4 拍） | 冻结（存储介质 P2 定） |
| `qpsk_map` | `din_data[1:0]` = `{i_bit, q_bit}` | `dout_data[23:0]` = `{i_out[11:0], q_out[11:0]}` | **1:1** | 冻结 |
| `srrc_duc` | `din_data[23:0]` | 见 §6（每拍 1 采样 / 每 4 拍 1 符号） | **符号:采样 = 1:4** | 流控冻结，位宽与架构见 §6.1 |

`blk_inter` 的输入/输出都是 **1 个 QPSK 符号的 2 bit**（因为 `conv_enc` 的两路输出
`{g₁, g₂}` 恰好就是一个符号的 `{I, Q}`），所以三个模块之间**不需要任何串并转换**——
这条如果不冻结，后面一定会有人在中间塞一个 serializer，然后逐拍比对全线错位一拍。

## 3. 拍数账本（从一帧到上采样，逐模块）

帧格式冻结后，长度全部可算（`docs/spec/frame_format.md` §7）：

| 环节 | 输入 | 输出 | 说明 |
|---|---|---|---|
| `frame_tx` | 256 拍 × 8 bit | 2160 拍 × 1 bit | 同步字 64 + 帧头 32 + 载荷 2048 + CRC 16 |
| `conv_enc` | 2160 拍 × 1 bit | **2166 拍 × 2 bit** | 2160 信息位 + 6 尾比特，每拍出 `{g₁,g₂}` |
| `blk_inter` | 2166 拍 × 2 bit (4332 bit) | **2170 拍 × 2 bit (4340 bit)** | 10 行 × 434 列，尾部补零 **8 bit** |
| `qpsk_map` | 2170 拍 × 2 bit | 2170 拍 × 24 bit | 每符号 2 bit → 12 bit I / 12 bit Q |
| `srrc_duc` | 2170 符号 | **8712 采样** | 上采样 ×4 + full 卷积 32 拍拖尾（`4N+32`，见 §6.1） |

补零 8 bit 的来历：编码后 4332 bit 不是交织深度 10 的整数倍，`ceil(4332/10)=434` 列 →
4340 bit，故补齐 8 bit（= 4 拍，因为一拍送一个符号的 2 bit）。这与 S1 `block_interleave`
的补零行为严格一致（**补零由交织器内部产生**，
不是让上游多喂 8 bit——那样上游就得知道交织器的几何，违反分层）。
落在 padded 序的**末 8 位**（第 9 行末），按 padded 序存储时正好是最后 4 个字，
这一条决定了 P2 的存储序选择（见 §4.3）。

## 4. 各模块接口详述

### 4.1 frame_tx

```verilog
module frame_tx (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [7:0]  din_data,     // 载荷字节，每 256 个字节构成一帧
    output logic        dout_valid,
    output logic        dout_bit      // 帧比特流，MSB-first
);
```

- **帧边界由固定载荷长度决定**：连续收满 256 个有效字节即一帧，不额外引入 `frame_start` 握手
  （多一条握手线就多一处与上游不一致的可能，而载荷长度本来就冻结了）。
- **载荷输入速率约束（重要）**：本模块输出 2160 bit/帧而只吃 256 byte/帧，
  两者**不同速**（差 8.44 倍）。无背压约定下，上游必须满足

  > 平均每字节耗时 ≥ 2160 / 256 = 8.44 拍

  否则帧缓存会溢出。`frame_tx` 内部按**双缓冲**（2 × 256 B）实现：
  一边发第 k 帧、一边收第 k+1 帧的载荷，因此只要满足上述约束就不会丢字节。
  本约束不是实现细节而是接口属性——不写下来，联调时一定会有人按"每拍一字节"灌数据。
- **位真用例的激励节奏因此取 STIM_PERIOD=9**（每 9 拍一个载荷字节，平均 9 > 8.44），
  见 `sim/framework/README.md` §3 与 `vectors/frame_tx/*_meta.json` 的 `stim_period`。
- **内部顺序**：收载荷（写入帧缓存；CRC 在发射阶段边发边算）→
  发同步字 64 拍 → 发帧头 32 拍 → 发载荷 2048 拍 → 发 CRC 16 拍，共 2160 拍。
- **帧号**：模块内部计数器，复位后为 0，每帧 +1，8 bit 回绕（帧头字段定义见帧格式规格书 §3）。
- **同步字**：来自 `src/frame_tx_sync.vh` 的 `FRAME_SYNC_WORD`（生成物，见 `sim/golden_ref/gen_frame_sync.py`），
  不运行时生成。
- **CRC**：位串行 LFSR（与黄金模型 `crc16_bitwise` 同构），在发射阶段对帧头 + 载荷逐位更新，
  载荷发完时恰好算完。任务卡建议的"8-bit 查表、每拍一字节"在本接口下不成立——
  本模块输出是**比特串行**的，查表反而要在 2080 bit 之外多出 260 拍字节域。已在帧格式规格书 §5/§8 登记。
- **实现约束**：帧缓存为 2 × 256 B（4 kbit），用分布式 RAM（`reg [7:0] mem [0:255]` 推断）
  即可，不需要 BRAM。

### 4.2 conv_enc

```verilog
module conv_enc #(parameter int BLK_LEN_DEFAULT = 2160) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic        din_bit,
    input  logic [15:0] blk_len,      // 配置：一个编码块的信息比特数
    output logic        dout_valid,
    output logic [1:0]  dout_data     // {g₁, g₂}，先 g₁ 后 g₂
);
```

- **(171,133)₈，K=7，R=1/2**：6 级移位寄存器 + 两棵 6 输入异或树，组合逻辑即可。
- **尾比特由编码器补齐**：块内计满 `blk_len` 位后自动补 K−1 = 6 个 0，寄存器归零，
  尾码字照常计入输出 → 输出拍数 = `blk_len + 6`。尾比特与 S1 `conv_encode` 行为一致。
- **为什么要 `blk_len` 而不是"看 valid 拉低判断块尾"**：链路里帧是**背靠背**的，
  valid 不会在两帧之间拉低；靠 valid 间隙判尾会把两帧粘成一块。块长是控制面寄存器
  （PS 侧可配，默认 = 帧长 2160），与 S1 参考的"按块编码"语义一致。
- **位序**：先 `g₁`（`0o171`）后 `g₂`（`0o133`），与 S1 `conv_encode` 的输出位序一致，
  这条不书面确认就会"RTL 与参考各自正确、互不一致"。

### 4.3 blk_inter

```verilog
module blk_inter #(
    parameter int DEPTH    = 10,      // 交织深度（行数）
    parameter int N_COL    = 434,     // 列数 = ceil(4332/DEPTH)
    parameter bit USE_BRAM_IP = 1'b0  // 1 = blk_mem_gen IP 版；0 = RTL 推断版
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       din_valid,
    input  logic [1:0] din_data,      // 一个符号的 {I, Q} 两比特
    output logic       dout_valid,
    output logic [1:0] dout_data
);
```

- **地址生成器保持不变**（任务卡原话）：写地址行优先递增 `row×Ncol+col`，读地址列优先
  `col×Nrow+row`。交织几何由地址序决定，与存储介质无关。
- **块边界**：收满 `DEPTH × N_COL` 个比特（= 2170 个符号）即一块，收满后开始读出。

本节以下四条是 P2 开工时冻结的（原为"待 P2 定"，见 §8）：

1. **存储序 = padded 序（行优先）**，而不是交织序。理由有三：① 写侧变成**顺序写一个计数器**
   （任务卡说"写行读列地址生成器不变"，写侧就是那个行优先递增器）；② 补零那 8 bit 落在
   padded 序的**末 4 个字**，直接写 0 即可（若按交织序存储，8 个补零位会散落在
   4269…4339 之间，实现要单独一张表）；③ 读侧的列优先地址可以用两个计数器加一张 10 项
   stride ROM 生成，不需要除 434 的除法器。
   具体量：输出拍 m 的两位来自 padded 位置 `a = (2m mod 10)×434 + (2m div 10)` 与 `a+434`
   （因为 `2m+1` 的列号不跨列 → 两地址恒差 434，且同奇偶 → **共享同一个字内 bit 选择**）。
   折算成 2 bit 字地址：`w = 217×r + (c>>1)`、`w+217`，字内选择 `c[0]`，其中
   `2m = 10c + r`（r 恒为偶数）。对 FSM 而言 P2 的整个读地址生成是"一个 ROM + 两个加法器"。
2. **存储宽度 = 2 bit/字，深度 = 2170 字/块 × 2 块 = 4340 字**。宽度取 2 bit 是因为一拍正好
   送一个符号：写侧一拍一个整字（**写地址就是输入拍计数 k**），读侧一拍读两个字各取 1 bit。
   双缓冲（两块）让"写第 k+1 块"与"读第 k 块"并行，块周期 = 2170 拍。
3. **读写冲突模式：不存在冲突**。写与读永远作用于不同的 bank（双缓冲），同 bank 内先写满
   再读，故不需要 read-first / write-first / no-change 的选择——这条比选一个模式更强，
   也就没有"与参考不一致"的口子。
4. **输入速率约束**：一块要写 2166 拍数据 + 4 拍补零 = 2170 拍，而块周期就是 2170 拍，
   所以平均输入速率必须 ≤ 2166/2170 ≈ 0.9982 拍⁻¹。与 `conv_enc` 同理，模块内带
   **32 拍弹性缓冲**吸收抖动；位真向量对多块用例把激励节奏放到 1/2（见 `STIM_PERIOD`）。
- **两种存储实现同接口、同行为**：正式交付版用 `blk_mem_gen`（简单双口，两个副本；
  由 `build/gen_blk_mem_gen.tcl` 生成，产物不入库）；RTL 推断版用 `logic [1:0] mem [...]`
  同结构（综合器会复制阵列，代价由 P4 的资源数据给出）。两者跑**同一个向量、同一套 TB**
  （`blk-frame` 与 `blk-ip-frame`），位真结果必须一致——已实测一致。
  **两版读延迟必须都是 1 拍**：7 系列 BRAM 的输出寄存器会再叠一拍，`blk_mem_gen` 的
  `Register_PortB_Output_of_Memory_Primitives` 必须关掉（开了实测 2 拍，会表现为
  IP 版输出整体错一位）。这条是踩过的坑，写进规格以免下次重演。
- 输入/输出维持"2 bit = 一个符号"的粒度，见 §2 末的说明。

### 4.4 qpsk_map

```verilog
module qpsk_map (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        din_valid,
    input  logic [1:0]  din_data,     // {i_bit, q_bit}
    output logic        dout_valid,
    output logic [23:0] dout_data     // {i_out[11:0], q_out[11:0]}
);
```

- **直移（直接映射）纯组合，无状态**：`i_bit=0 → +round(1/√2·2¹⁰) = +724`，
  `i_bit=1 → −724`，Q 路同理。
- 位宽取自《定点规格书》：QPSK 输出 12 bit 有符号、10 bit 小数（`qpsk_out_w/frac`）。

### 4.5 srrc_duc

见 §6。滤波器本体、NCO、DUC 混频三段在模块内串接，对外只有一组 valid 流。

## 5. NCO 与相位连续语义（S6 跳频预留）

### 5.1 架构（P3 冻结，本节先记决策与代价）

任务卡的 SRRC 手写版是"SRL 输入延迟线 + 对称折叠 16 路乘法"，那是**采样时钟域**的结构
（每拍产出 1 个采样点）。而符号流是每 4 拍来一个符号，两条路只能选一条：

| 方案 | 结构 | 代价 | 结论 |
|---|---|---|---|
| A. 采样时钟域，符号 1/4 节奏输入 | 1 采样/拍输出；延迟线 33 抽头（SRL 省 FF）；折叠后 16 路乘法 | 需要比对器支持"激励节奏" | **推荐**（与任务卡结构一致，DSP 用量最小） |
| B. 符号时钟域，4 采样/拍并行输出 | 多相/并行 4 路；每拍 4×16 = **64 路乘法** | DSP48E1 占用 ×4，与"折叠省 DSP"的叙事相反 | 不取 |

方案 A 所需的"激励节奏"能力（`tb_vec_cmp` 的 `STIM_PERIOD`）**已在 S4-P0 落地并自测**
（`run_selftest.ps1` 的 `positive cadence` 用例），`frame_tx` 的位真向量也已经在用它
（载荷 1 字节/9 拍）。P3 不需要再为框架做前置工作。

### 5.2 相位连续跳频语义（本版冻结，S6 直接换字）

```verilog
// srrc_duc 内的 NCO 控制接口（S4 只用固定频点，接口与语义现在就冻结）
input  logic [15:0] freq_word;    // FTW：相位累加器每拍增量
input  logic        freq_valid;   // 高电平时在下一拍载入 freq_word
```

- **跳频只更新 FTW，绝不清零相位累加器**——这是"相位连续"的全部含义，
  也是 T 卡在任务卡里点名要保留的机制（频谱不出现跳变边带）；
- 相位累加器 **16 bit**，`freq_word` 即增量，频率分辨率 = fs / 2¹⁶；
- 相位不做截断，直接作 sin/cos 查找表地址（避免截断杂散）；LUT 16 bit、14 bit 小数，
  可用四分之一波对称压缩省 LUT；
- **不用 DDS Compiler**（创新点红线，见 `docs/report/env.md`）。

## 6. 存储与仿真口径（本规格强制，踩过的坑）

1. **BRAM 上电内容为 X**：仿真中必须"先写满再读"，或在 TB 里显式初始化，
   否则读到未写区域会把 X 带进比对器，产生假失败。
2. **读写冲突**：同地址读写取 read-first / write-first / no-change 之一，
   必须与黄金模型行为一致，并记录在本规格的模块小节里（P2 冻结时填具体值）。
3. **输出寄存器打拍**：`blk_mem_gen` 输出打一拍会让数据滞后一拍，黄金向量生成时
   要把这拍算进去——比对器按 valid 对齐，所以只影响延迟，不影响判据。
4. **比对是"逐拍"不是"逐帧"**：比对粒度到时钟沿，延迟差不会被误判为数据错。

### 6.1 srrc_duc 位宽与架构（P3 冻结，2026-10-07）

三段串接（采样时钟域，每采样节拍产出 1 个采样点）：

1. **SRRC 33 抽头上采样 ×4 多相滤波**：符号 1/4 节奏进、采样连续出（多相分解 33 = 9+8+8+8，相位 0 有 9 抽头）；
2. **NCO**：16 bit 相位累加器 + 四分之一波 sin/cos LUT（相位不清零，§5.2）；
3. **DUC 复数混频**：`I′ = I·cos − Q·sin`，`Q′ = I·sin + Q·cos`，输出 Q5.11。

位宽账本（单一来源 `config.py` 的 `FIXED_POINT_CONFIG` / `DUC_CONFIG`）：

| 环节 | 位宽 | 小数 | 范围 |
|---|---|---|---|
| QPSK 符号（qpsk_map 输出） | 12 | 10 | ±0.707（±724） |
| SRRC 系数 | 12 | 11 | [−1, 1) |
| SRRC 输出 | 14 | 11 | [−4, 4)，峰值 ≈ ±2 |
| NCO 相位累加器 | 16 | — | [0, 2π) |
| NCO LUT | 16 | 14 | [−1, 1] |
| DUC 混频输出 | 16 | 11 | [−16, 16)，峰值 ≤ ±8（留 2 倍余量） |

三条位真一致硬口径（RTL 必须逐项复刻，否则手写版 / FIR IP 版 / golden_ref 三方在最后一位分叉）：

- **输出拍数 = 4N + 32**（full 卷积）：符号流结束后再输出 32 拍拖尾（NUM_TAPS−1）。
- **舍入 round half-to-even**（进位 `round_bit && (sticky || lsb)`），不是 half-up。
- **NCO LUT 镜像公式** `mirror = 16383 − idx`，`cos(p) = sin(p + 2^14)`。

双版实现（接口与位真一致，P3 验证）：

- 手写版 `src/srrc_duc.v`：多相 MAC 组合逻辑，full convolution 无流水延迟；
- FIR Compiler IP 版 `src/srrc_duc_fir.v`：2 × `fir_srrc`（Interpolation×4），3 拍 latency +
  补 9 零符号（8 补 full-convolution 尾 + 1 补偿 latency 空转）后对齐 4N+32 输出。

## 7. 与任务卡的有意偏差（登记，不隐藏）

| # | 任务卡写法 | 本规格做法 | 理由 |
|---|---|---|---|
| 1 | SRRC「31 抽头」 | **33 抽头** | S1 冻结的系数是 `span 8 × sps 4 + 1 = 33`（`config.py:34`）。位真裁判必须是同源系数；改 31 要重跑 S1 BER 基线与 SNR 损失表，属独立变更 |
| 2 | CRC16「并行 8-bit 查表，每拍一字节」 | **位串行 LFSR，每拍一比特** | `frame_tx` 输出是比特串行流，查表会在 2080 bit 之外多出 260 拍字节域；已登记在帧格式规格书 §5 |
| 3 | — | `conv_enc` 增加 `blk_len` 配置端口 | 帧背靠背时 valid 不会拉低，编码器必须知道块长才能补尾比特 |

## 8. P3 冻结记录（2026-10-07，原"待冻结清单"三项已定）

| 项 | 冻结值 |
|---|---|
| `srrc_duc` 输出位宽与小数位 | 16 bit / 11 bit 小数（Q5.11），饱和输出；SRRC 本体 14 bit / 11 小数，详见 §6.1 |
| `srrc_duc` 目标时钟与采样率 | 采样率 **fs = 2 MSPS**、符号率 **500 ksps**；RTL 用「采样节拍」抽象（每 clk 沿 = 1 采样节拍），拍数关系 1:4 与物理时钟域解耦 |
| SFDR 分析方法 | SFDR 只测 **NCO/DUC 量化杂散**（纯单音 → DUC，实测 −85.45 dBc，≤ −50 dBc 判据 PASS）；SRRC 频谱纯度（多相一致性 −44.68 / 阻带抑制 −32.51 dBc）为**报告项**，不套 −50 判据 |

三项决策的完整推导见 `docs/spec/s4_tx_p3_freeze_draft.md` 决策 1/2/3（含附录确认结果）。

P2 开工时提出的三项（存储介质、读写冲突模式、输入速率约束）已在 §4.3 冻结，
本表不再保留——**冻结的是决策与理由，不是"待办"**。

## 9. 变更流程

1. 提交变更申请：说明改哪个模块的哪条约定、影响哪些下游与哪些向量；
2. 改 `docs/spec/s4_tx_interface.md`（与帧格式规格书同规）；
3. 重跑 `sim/framework/run_selftest.ps1`（框架契约本身是否仍成立）；
4. 重新导出全部 S4 向量并重跑 `sim/run_s4_acceptance.ps1`；
5. 评审通过后更新版本号与冻结日期。
