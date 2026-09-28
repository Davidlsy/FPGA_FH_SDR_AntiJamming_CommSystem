# sim/ · 仿真树总入口

S1 与 S2 两条线在这里汇合：**S1（`golden_ref/`）给出「判据」，S2（`framework/`、`models/`、`vip/`）
给出「板卡的仿真替身」**。没有硬件时，后续所有步骤（S3 射频配置、S5 跳频、S7 干扰感知、S8 抗干扰增益）
都必须靠这两条线在仿真域内闭环。

## 1. 目录

| 目录 | 阶段 | 说明 |
|---|---|---|
| `golden_ref/` | S1 | 浮点 + 定点黄金参考链（Python 包），`run_ber.py` 出 BER 曲线与 SNR 损失表 |
| `float_ref/` | S1 | V2.x MATLAB 归档链重跑与对照（见 `docs/report/s1_archive_compare.md`） |
| `framework/` | S2 / S4 | 自动比对框架：向量导出 + 逐拍比对器 + TB 模板（**所有 RTL 模块回归都靠它**；S4-P0 起支持激励/期望长度解耦与激励节奏，S4-P1 起有三个真实 DUT 在用） |
| `models/ad9363/` | S2 / S3 | AD9363 SPI 行为模型（板卡的仿真替身）+ S3 射频配置模块的验证落点 |
| `models/channel/` | S2 | 信道模型库：AWGN / CFO / SFO / 多径 |
| `models/jammer/` | S2 | 干扰注入源：单音 / 多音 / 扫频 / 部分频带 + JSR 标定 |
| `vip/` | S2 | PS/PL 协同仿真环境：AXI VIP 主端发真实 AXI4-Lite 事务 |
| `tb_fhss_top.v` | S0 | 工具链冒烟 testbench（`[SMOKE] PASS`） |
| `run_s2_acceptance.ps1` / `.bat` | S2 | **统一验收**：五项串跑 + 唯一判据行（见 §3） |
| `run_s3_acceptance.ps1` | S3 | **统一验收**：四项串跑（表一致性 + 三个 TB）+ 唯一判据行 `[S3 ACCEPTANCE]` |
| `run_s4_acceptance.ps1` | S4 | **统一验收**：S4 位真比对串跑 + 唯一判据行 `[S4 ACCEPTANCE]`（`-Full` 带 1000 帧 / 10⁶ bit 长跑判据） |
| `logs/` | — | 运行日志（`*.log` 未入库，可随时重跑重建） |

## 2. 五件套之间的关系

```
RF 数字基带侧（位宽/握手一致，可直接串联）
  golden_ref 样点 ──▶ ch_top 信道库 ──▶ jm_top 干扰源 ──▶ S4+ 的 RX 链
                     AWGN/CFO/SFO/多径   单音/多音/扫频/部分频带

  S4 TX 链（已到位三段，逐段与 golden_ref 逐拍位真比对）
  frame_tx ──▶ conv_enc ──▶ [blk_inter] ──▶ qpsk_map ──▶ [srrc_duc]
  256B→2160bit  N→N+6 拍     P2 待做         2bit→24bit    P3 待做

控制侧
  TB 的 PS 软件序列 ──▶ AXI VIP(master) ──▶ axi_regs_demo（S9 换真 axi_regs）
  spi_master（S3） ──▶ ad9363_spi_model（寄存器数组 + 回读校验 + 异常注入）

横向贯穿
  tb_vec_cmp（逐拍向量比对器）── S4 起为每个 RTL 模块配一组向量
```

三条线各自独立，**目前没有联合仿真**：RF 侧两件可直连但从未串过，控制侧两件与 RF 侧也无交叉。
这是 S2 已知边界之一（见 §7 与 `docs/report/s2_verification.md`）。

## 3. 一键验收（推荐入口）

```powershell
.\sim\run_s2_acceptance.ps1        # 或双击 run_s2_acceptance.bat
```

它把五项自测按依赖顺序串跑一遍，聚合出唯一判据行，总日志落 `sim/logs/s2_acceptance.log`：

```
[S2 ACCEPTANCE] suites=5 failed=0 checks=1538 errors=0 status=PASS
```

本机实测（Vivado Simulator 2021.2 / Python 3.12.7 + numpy 2.5.3，主机见 `docs/report/env.md`）：

| # | 套件 | 入口 | 规模 | 判据行 | 实测耗时 |
|---|---|---|---|---|---|
| 1 | 自动比对框架 | `framework/run_selftest.ps1` | 4 组 | `[FRAMEWORK SELFTEST] PASS` | 18.3 s |
| 2 | AD9363 SPI 行为模型 | `models/ad9363/run_xsim.bat` | 6 项 | `RESULT : *** ALL TESTS PASSED ***` | 5.1 s |
| 3 | 信道模型库 | `models/channel/run_channel_check.ps1` | 29 项 | `[CHANNEL STATS] PASS` | 7.7 s |
| 4 | 干扰注入源 | `models/jammer/run_jammer_check.ps1` | 31 项 | `[JAMMER STATS] PASS` | 7.4 s |
| 5 | PS/PL 协同仿真环境 | `vip/run_vip_check.ps1` | 28 项（7 组） | `[VIP-RESULT] … status=PASS` | 9.0 s |

另有 S4 发射链验收（P0+P1 已落地的三个模块）：

```powershell
.\sim\run_s4_acceptance.ps1          # 短用例：11/11 套件，49.9 s
.\sim\run_s4_acceptance.ps1 -Full    # 追加 1000 帧 / 10⁶ bit 长跑判据：13/13 套件，65.4 s
```

```
[S4 ACCEPTANCE] suites=13 failed=0 positives=10 full=True status=PASS
```

判据口径与前两阶段一致（`failed=0` + 各套件自己的 `[VEC-RESULT]` 行）。其中三条是**证伪用例**
（故意把 I/Q 互换、位序颠倒、CRC 多项式换错），必须判 FAIL——反例跑不出 FAIL，正例的 PASS 也不值钱。

合计 47.6 s（首次 `-Rebuild` 式生成 AXI VIP 时约 +1 min）。**判据是 `failed=0` 与各项判据行，
不是检查数的具体值**——AD9363 的随机压力用 `$urandom`，check 数在 1444~1446 间浮动。

## 4. 分项单独跑

| 目的 | 命令 |
|---|---|
| 只跑某个模块 | 见上表入口脚本，各自 `Set-Location` 到自己目录，互不干扰 |
| 新模块 TB | 照 `framework/README.md` §6 的四步走（注册向量 → `export_vectors.py` → 复制模板 → 接线） |
| 重生成 AXI VIP 生成物 | `vip\run_vip_check.ps1 -Rebuild`（`vip/gen/` 未入库，可随时重建） |
| 带波形 | `models/ad9363/run_xsim.bat gui`、`framework/run_selftest.ps1` 见其内部快照名 |

前置：`xvlog`/`xelab`/`xsim`/`vivado` 在 PATH（`call D:\software\vivado2021\Vivado\2021.2\settings64.bat`），
`python` 带 `numpy`。`.bat` 入口会自动尝试加载该 settings64.bat。

## 5. 跨目录约定（新增模型必须遵守）

1. **位宽/小数位只有一个来源**：`golden_ref/config.py` 的 `FIXED_POINT_CONFIG`（= `docs/spec/fixed_point_spec.md`），
   信道与干扰源因此都是 `W=14, FRAC=11`，量化用 `ch_pkg.sv`（round-half-even + 饱和，与 `golden_ref.quantizer` 对齐）。
   **不要各自再写一份量化原语**——两处各写一份，迟早就此不一致。
2. **数据通路按 `*_valid` 逐拍握手**，对接时按各拍 valid 对齐，不按绝对时间对齐。
3. **判据行必须是纯 ASCII**（`[VEC-RESULT]`、`[CHANNEL STATS]`、`[VIP-RESULT]`、`[S2 ACCEPTANCE]`…）：
   重定向后中文编码不可靠，脚本只 match ASCII 字段。
4. **xsim 批处理即使 `$fatal` 也返回退出码 0**（2021.2 实测），所以判成败一律看判据行，
   退出码只作必要条件。
5. `*.log` 不入库（根 `.gitignore`），入库的是 `data/` 下的核验表（`s2_channel_stats/`、`s2_jammer_stats/`）。

## 6. 已知边界（登记，不隐藏）

| 边界 | 说明 | 何时补 |
|---|---|---|
| AD9363 模型只覆盖数字接口协议 | 寄存器语义正确性最终靠真机回读背书；芯片内部校准状态机、BB/RF PLL 锁定、ENSM 迁移时序无法仿真 | 板到货后（BV-01） |
| 四件套之间无联合仿真 | RF 侧（信道+干扰）可直连但未串联；控制侧（SPI / AXI）与 RF 侧无交叉 | S8 整链回归时串联；另可先做 RF 侧冒烟 |
| VIP 示例从端不是真 `axi_regs` | 寄存器映射是示意形状，地址只译码低 8 位，未覆盖 WSTRB，无 DDR/GEM/中断 | S9 换真表（拓扑不变） |
| 「10 分钟起一个新模块 TB」 | 框架有模板与四步流程，S4-P1 起有三个真实 DUT 在用（`tb_qpsk_map_compare` / `tb_conv_enc_compare` / `tb_frame_tx_compare`）；约定是一条 TB 一个用例、用例用 `-d` 切换 | **已闭环**（S4-P1） |
| 验收会更新向量 meta | 跑完验收 `git status` 会看到 `framework/vectors/*/*_meta.json` 变脏，diff 只有 `generated_at` 一行；向量值本身是确定性重生成的 | 需要干净树时把它降级为日期字段 |
| BER 曲线脚本不在比对框架内 | 计划书 §S2 把它归在「自动比对框架」名下，实际落点是 S1 的 `golden_ref/run_ber.py`（产出 `data/s1_ber_baseline/ber_curve.png`） | S8 整链回归直接复用，不再另写 |

## 7. 下一步

- S2 待补：RF 侧链路冒烟（`golden_ref` 样点 → `ch_top` → `jm_top`，回 Python 用 S1 基线判 BER/JSR）——
  一次证明三件接口真正兼容，也是 S8 抗干扰增益验证的底座；验收结论见 `docs/report/s2_verification.md`。
- S3 已落地的部分：`spi_master` + `ad9363_cfg` 消费 `models/ad9363`，逐条（地址, 数据, 延时）三元组
  比对由「引脚波形嗅探 vs CSV 派生的期望」承担，入口 `run_s3_acceptance.ps1`，报告
  `docs/report/s3_verification.md`。**待补**：初始化表内容仍是烟测占位（真表来源见报告 §8），
  以及"全部状态可达、无锁死环"的形式化/可达性核查未做。
- S4 已落地的部分（P0+P1）：帧格式与五模块接口冻结（`docs/spec/frame_format.md`、
  `docs/spec/s4_tx_interface.md`），`frame_tx` / `conv_enc` / `qpsk_map` 三模块位真比对全过，
  入口 `run_s4_acceptance.ps1`（`-Full` 带 1000 帧与 10⁶ bit 两条长跑判据），
  报告 `docs/report/s4_verification.md`。**待补**：`blk_inter`（P2）、`srrc_duc` 双版 + NCO（P3）、
  IP vs 手写三栏对比（P4）、五模块整链收口（P5）——任务卡的 S4 出口门槛因此**尚未达成**。
- S4 起 `tb_vec_cmp` 消费向量，框架开始被真实 DUT 使用；期间按需要扩展了两处契约
  （激励/期望长度解耦、激励节奏 `STIM_PERIOD`），详见 `framework/README.md` §2–§3、§7。
