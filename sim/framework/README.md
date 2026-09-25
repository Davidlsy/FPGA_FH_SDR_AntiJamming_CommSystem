# S2 验证基础设施 · 自动比对框架

计划书 §S2「自动比对框架」与 §S4-P0「位真比对基线」的实现。一句话：

> **把 S1 的定点参考模型变成可执行判据。** 每个 RTL 模块的输出与 `sim/golden_ref`
> 的定点结果逐拍比对，一条命令给出 PASS/FAIL，让 5 个模块「写完即测、测完即绿」，
> 而不是最后集中在整链里排障。

框架本身也经过自测（4 项检查，见 §7）——一个抓不到错的比对器等于没有比对器。

## 1. 组成

| 文件 | 作用 |
|---|---|
| `export_vectors.py` | 向量导出器：调 `golden_ref` 定点模型 → `<case>_{stim,expect}.hex` + `<case>_meta.json` |
| `hdl/tb_vec_cmp.sv` | **逐拍向量比对器**（参数化模块）：激励驱动 + 比对 + 首失配定位 + 看门狗 + PASS/FAIL |
| `tb/tb_module_template.sv` | 新模块 TB 模板，照着填 4 处即可 |
| `tb/tb_vector_selftest.sv` | 框架自测 TB（含自测桩 `stub_qpsk_map`，三条路径） |
| `run_selftest.ps1` / `.bat` | 一键自测：导出向量 + 4 项检查 + 日志 + 退出码 |
| `vectors/qpsk_map/` | 已生成的向量（rand 4096 符号 / edge 196 符号） |
| `logs/` | 每次运行的 xvlog/xelab/xsim 日志（`*.log` 已被 gitignore） |

比对器对外只要求四根线，TB 因此退化成接线工作：

```systemverilog
tb_vec_cmp #(...) u_cmp (.clk, .rst_n, .stim_valid, .stim_data, .dut_valid, .dut_data);
<dut>      u_dut (.din_valid(stim_valid), .din_data(stim_data),
                  .dout_valid(dut_valid), .dout_data(dut_data), ...);
```

## 2. 向量契约

```
vectors/<module>/<case>_stim.hex     输入总线，每行一个值
vectors/<module>/<case>_expect.hex   与 stim 逐行对应的期望输出总线值
vectors/<module>/<case>_meta.json    位宽 / 打包 / 种子 / 样本数 / golden 来源
```

- 每行是一个**定宽补码十六进制数**（无 `0x` 前缀，低位在右），xsim 的 `$readmemh` 按位宽左填充；
- **行数即向量长度**，TB 与比对器都不声明 N——少一处不一致来源；
- 位宽、小数位一律取自 `golden_ref.config.FIXED_POINT_CONFIG`，也就是
  `docs/spec/fixed_point_spec.md` 的机器可读来源；导出器不硬编码任何位宽，
  并会校验每个值都落在量化格点与补码范围内，避免向量静默溢出；
- 多路信号按「高位在前」打包，打包规则写进 `meta.json` 的 `packing` 字段。
  例：`qpsk_map` 输入 2 bit `{i_bit, q_bit}`、输出 24 bit `{i_out[11:0], q_out[11:0]}`。

生成：

```powershell
python export_vectors.py --list                      # 已注册模块
python export_vectors.py --module qpsk_map --case all
python export_vectors.py                             # 全部模块、全部用例
```

## 3. TB 时序契约

- 复位释放后 `stim_valid` **连续拉高 n_vec 拍**，逐行送出 `_stim.hex`；
- 比对只认 DUT 自己的 `dout_valid`：**先按各自 valid 对齐再比数值**，所以流水线延迟
  不会被误判为数据错（S4-P0「逐拍而非逐帧」的口径）；组合逻辑零延迟同样直接可用；
- 送完 `stim_valid` 拉低，靠 `DRAIN_CYCLES`（默认 64）等流水线排空——深流水线
  （如 31 抽头 SRRC）按需放大；
- **看门狗**默认 `8*n_vec + 4096` 拍。DUT 卡死、`dout_valid` 未接对时由它收口并
  报「只收到 x/y 个输出」，不会静默挂死；
- 输出有效拍多于向量长度 → 计入 `extra` 并判 FAIL。

## 4. 判据

| 结论 | 条件 |
|---|---|
| PASS | `errors == 0` 且 `compared == vectors` |
| FAIL | 有任何失配 / 多余拍 / 看门狗超时 |

失败时打印首个失配的**序号、时刻、期望值、实际值**（`MAX_MISMATCHES` 默认再列 8 处），
并 `$fatal` 收尾。

同时打印一行纯 ASCII 的机器可读结果，脚本与 CI 只认这一行：

```
[VEC-RESULT] tb=tb_qpsk_map_rand status=PASS vectors=4096 compared=4096 errors=0 extra=0 timeout=0 first_mismatch=-1 first_expected=0xxxxxxx first_actual=0xxxxxxx
```

## 5. 运行

```powershell
.\run_selftest.ps1          # 或双击 run_selftest.bat：导出向量 + 4 项自测
```

单模块 TB 三步（与 `sim/models/ad9363/run_xsim.bat` 同一套工具链）：

```powershell
xvlog -sv -work work hdl/tb_vec_cmp.sv tb/tb_<module>_<case>.sv
xelab -relax -timescale 1ns/1ps -snapshot snap_<module> -debug typical work.tb_<module>_<case>
xsim snap_<module> -runall
```

## 6. 10 分钟起一个新模块 TB

1. 在 `export_vectors.py` 的 `MODULES` 里注册一条：`cases`（返回用例与激励载荷）+
   `export`（调 golden_ref 定点函数，用 `to_int`/`hex_of_int`/`pack_fields` 打包）。
   位宽从 `FIXED_POINT_CONFIG` 取，不写字面量。
2. `python export_vectors.py --module <module>` 生成向量（首次会自动建目录）。
3. 复制 `tb/tb_module_template.sv` → `tb/tb_<module>_<case>.sv`，改 4 处：
   `IN_W`、`OUT_W`、`STIM_FILE` / `EXP_FILE`、DUT 例化。
4. 接 DUT：`din_valid ← stim_valid`、`din_data ← stim_data`、`dout_valid → dut_valid`、
   `dout_data → dut_data`；模块专属检查（比对器管不到的，如交织「突发错误被打散到
   ≥10 个码字位置」）另写在 TB 末尾。
5. 跑 §5 三步，看 `[VEC-RESULT]`。

**刻意约束：一个 TB 一个用例。** 比对器收口时会 `$finish` / `$fatal`，不适合在一个 TB
里串两轮；要第二个用例就再复制一份（或用 `ifdef` 切，`tb_vector_selftest.sv` 就是范例）。

## 7. 框架自测结论（本机实测）

`.\run_selftest.ps1` → `[FRAMEWORK SELFTEST] PASS`，四项：

| 检查 | 路径 | 期望 | 实测 |
|---|---|---|---|
| 正路径 rand | 桩 DUT 与 golden 一致 | PASS | `status=PASS compared=4096 errors=0` |
| 正路径 edge | 短向量 / 边界码型 | PASS | `status=PASS compared=196 errors=0` |
| 负路径 注入 | 第 1000 拍翻 1 bit | FAIL 且定位 | `status=FAIL errors=1 first_mismatch=1000`，期望 `0xd2c2d4` 实际 `0xd2c2d5` |
| 桩死 看门狗 | `dout_valid` 恒 0 | FAIL 且报超时 | `status=FAIL compared=0 timeout=1` |

自测桩 `stub_qpsk_map` 只是 golden 映射的镜像（四星座点 ±`round(1/√2·2¹⁰)` = ±724），
**不是设计交付物**，只服务于「证明框架可信」这件事。

> 当前 `qpsk_map` 的向量已就绪，但 DUT 属 S4-P1 交付、尚不存在。RTL 落地后
> `tb_qpsk_map_rand` 就是照模板填出的第一个真实实例。

## 8. 与计划书的两处有意偏离

- 计划书写交付 `tb_common.vh`（宏/任务库），这里实现为**参数化模块** `tb_vec_cmp.sv`：
  同样是公共复用，但参数化后不需要宏展开，位宽、文件名、看门狗全是参数，
  TB 只需接四根线，且模块可被单独自测。
- 计划书写「testbench 输出 vs **MATLAB** 参考」，实际比对基线是 `sim/golden_ref`
  （S1 交付的 Python 定点模型）：S1 已用 Python 复现并对齐 MATLAB 归档
  （见 `docs/report/s1_archive_compare.md`），比对基线应与冻结基准同源，避免出现
  两套「真理」。

## 9. 已知约束（踩过的坑，别再踩）

| 现象 | 原因 | 对策 |
|---|---|---|
| `xvlog` 报一堆语法错、中文成乱码 | Windows PowerShell 5.1 读**无 BOM** 的 UTF-8 `.ps1` 会按 GBK 解析 | `run_selftest.ps1` 必须带 UTF-8 BOM；编辑工具若把 BOM 去掉，补回即可 |
| 失败却退出码 0 | xsim 批处理模式**即使 `$fatal` 也返回 0**（2021.2 实测） | 判据取日志（同 `sim/models/ad9363/run_xsim.bat`），故有 `[VEC-RESULT]` 行 |
| 判据 match 不到中文 | 重定向后日志的中文编码不可靠 | 判据只用 `[VEC-RESULT]` 的 ASCII 字段 |
| `.hex` 向量会不会被 gitignore 吞掉 | 不会——仓库有意不按扩展名全局忽略 `.hex`（它是存储器初始化源文件） | 向量正常入库，作为比对证据 |
| 中文 `$display` 在 xsim 里显示正常 | xvlog 按字节透传 | 无需处理 |

## 10. 后续接入顺序（S4）

`qpsk_map` → `conv_enc` → `frame_tx`（P1）→ `blk_inter`（P2）→ `srrc_duc`（P3，双版本
FPGA Compiler / 手写各一份向量），逐个在 `MODULES` 里注册即可。整链环回（S8）复用同一
比对器，只换顶层与向量。
