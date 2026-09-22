# sim/float_ref — V2.x MATLAB 浮点黄金参考（归档对照）

- **脚本来源**：`D:\My_project\归档\GoWin_SDR\matlab\run_ber_sweep.m`（P1-S6 / V2.x 归档）
- **用途**：S1 出口项「浮点链与归档曲线一致」的数据源
- **说明**：GoWin 归档目录中**没有** `results/ber.mat`，只有 `.m` 脚本；本目录在 AMD 仓库内重跑归档脚本并导出 CSV

## 参数（与归档脚本一致）

| 项 | 值 |
|----|-----|
| 随机种子 | `rng(2026)` |
| 卷积码 | (171,133)₈, K=7, R=1/2, 尾比特回零 |
| 交织 | 深度 10，行入列出 |
| QPSK | π/4 Gray |
| SRRC | β=0.35, span=10, **sps=8** |
| Viterbi | tblen=96, `'term'`, 软判决 `'unquant'` |
| Eb/N0 | 导出默认 0–8 dB（归档脚本扫 0–12 dB） |
| 每点信息比特 | 导出默认 `Ninfo` 可调（归档脚本 2e6） |

## 与 `sim/golden_ref`（Python）的参数差异

| 项 | MATLAB 归档 | Python golden_ref |
|----|-------------|-------------------|
| SRRC span / sps | 10 / 8 | 8 / 4 |
| 种子 | 2026 | 42（run_ber 默认） |
| 扫描 | 0–12 dB | 0–8 dB |
| 实现 | Communications Toolbox | numpy 自研链路 |

参数不完全相同，**不能**要求逐点数值重合；对照时看同算法族在公共 Eb/N0 上的 BER 量级/瀑布区位置是否合理，并在报告中写明差异。

## 运行

```powershell
# 快速对照（建议）
& "D:\software\Matlab\bin\matlab.exe" -batch "cd('D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\float_ref'); Ninfo=3e5; EbN0=0:8; run_ber_sweep_export"

# 更接近归档置信度（耗时长）
# Ninfo=2e6
```

输出：

- `results/matlab_archive_ber.csv`
- `results/matlab_archive_ber.mat`
- 对照报告：`docs/report/s1_archive_compare.md`

## 对照结论摘要（2026-09-20）

- GoWin 归档仓 **无** `ber.mat`，对照基于本目录重跑修复版脚本。
- 归档脚本需修：级联 SRRC 群延迟（10 符号）、LLR 行展开、`vitdec` 软判决符号。
- 未编码 vs 理论：偏差 ≲1.4%。
- 编码 vs Python `ber_float`：BER=1e-2 / 1e-3 门限差 ≤0.1 dB。
- 详见 `docs/report/s1_archive_compare.md`。
