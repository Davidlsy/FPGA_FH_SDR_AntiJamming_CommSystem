# S1 归档对照：MATLAB V2.x 浮点链 vs Python golden_ref

> 状态：**对照已完成**（归档仓库无 `ber.mat`，本仓库内重跑归档脚本导出）  
> 日期：2026-09-20  
> 关联出口：S1 验证方法 —「浮点链与归档曲线一致」

## 1. 归档源

| 项 | 位置 / 说明 |
|----|-------------|
| 归档工程 | `D:\My_project\归档\GoWin_SDR\`（GoWin 赛道旧仓） |
| MATLAB 主脚本 | `matlab/run_ber_sweep.m`（P1-S6） |
| 实施指南 | `docs/P1-S6_float_ref_guide.html` |
| 设计报告理论锚点 | 未编码 QPSK BER=1e-5 → Eb/N0≈9.6 dB；编码增益≈5 dB → 编码曲线 1e-5 约在 4.6 dB |
| **归档结果数据** | **不存在** `results/ber.mat` / `ber.csv`（指南要求归档，旧仓未交付） |

因此本项对照 = **在 AMD 仓库内用归档脚本算法重跑**，不是读一张历史曲线图。

## 2. 本仓库落点

| 文件 | 说明 |
|------|------|
| `sim/float_ref/run_ber_sweep.m` | 归档脚本副本 |
| `sim/float_ref/run_ber_sweep_export.m` | 可导出 CSV 的修复版（见 §3） |
| `sim/float_ref/results/matlab_archive_ber.csv` | MATLAB 重跑结果 |
| `sim/float_ref/results/matlab_archive_ber.mat` | 同上 MAT 格式 |
| `sim/float_ref/compare_matlab_python.py` | 与 Python `ber_float.npz` 对照脚本 |
| `data/s1_ber_baseline/ber_float.npz` | Python 黄金链浮点基线 |

重跑环境：MATLAB R2021b + Communications Toolbox；种子 `rng(2026)`；`Ninfo=5e5`/点；Eb/N0=0–8 dB。

## 3. 归档脚本问题（重跑时必须修）

直接跑 `run_ber_sweep.m` 会得到 BER≈0.5。诊断后确认三处问题：

| # | 问题 | 修复 |
|---|------|------|
| 1 | 群延迟用 `gds=span/2=5` 符号，收发两级 SRRC 级联实为 **10 符号** | `gds=(numel(h)-1)/sps` |
| 2 | `s=llr(:)` 为 MATLAB **列主序**（全部 MSB 再全部 LSB），与交织码流不符 | `s=reshape(llr.',[], 1)` → MSB1,LSB1,MSB2,LSB2… |
| 3 | 软判决符号：本机 `pskmod(…,'gray')` 下 bit=1 对应 Im/Re&lt;0，与 `vitdec`「正值→0」一致时 **不要** 再取负 | 使用 `+Im/+Re`，与 `unquant` 约定匹配 |

修复后 **未编码链** 与 `berawgn(...,'psk',4,'nondiff')` 理论线相对偏差 max≈1.4%（各点 BER 量级吻合，满足指南「与理论线核对」精神）。

## 4. 参数：归档 MATLAB vs Python golden_ref

| 项 | MATLAB 归档（修复版重跑） | Python `sim/golden_ref` |
|----|---------------------------|-------------------------|
| 卷积码 | (171,133)₈, K=7, R=1/2, 尾比特 | 同左 |
| 交织 | 深度 10 | 深度 10 |
| QPSK | π/4 Gray（`pskmod`） | 能量归一 Gray（自研） |
| SRRC | β=0.35, **span=10, sps=8** | β=0.35, **span=8, sps=4** |
| 同步 | 级联群延迟理想切片 | 理想/简化同步 |
| Viterbi | tblen=96, term, unquant 软判决 | 软判决自研 |
| 种子 | 2026 | run_ber 默认 42 |
| 每点比特 | 本报告 5e5（归档脚本原设 2e6） | 标准模式约至 2e6 累计 |
| 扫描 | 本报告 0–8 dB（归档脚本 0–12 dB） | 0–8 dB |

**结论前提**：两侧是同一算法族，但 SRRC 阶数/过采样与随机实现不同，**不要求逐点数值相同**；验收看公共 BER 区间的 Eb/N0 门限是否一致。

## 5. 数值对照

### 5.1 未编码（仅 MATLAB）

| Eb/N0 | 仿真 uncoded | 理论 | 相对偏差 |
|-------|--------------|------|----------|
| 0 | 7.885e-2 | 7.865e-2 | ~0.3% |
| 4 | 1.262e-2 | 1.250e-2 | ~1.0% |
| 8 | 1.920e-4 | 1.909e-4 | ~0.6% |

→ 归档实现的 Eb/N0→SNR 与 Gray 映射 **正确**。

### 5.2 编码：MATLAB 重跑 vs Python 浮点

| Eb/N0 | MATLAB coded | Python float | M/P |
|-------|--------------|--------------|-----|
| 0 | 1.566e-1 | 1.010e-1 | 1.55 |
| 1 | 4.059e-2 | 3.950e-2 | 1.03 |
| 2 | 5.384e-3 | 5.143e-3 | 1.05 |
| 3 | 3.520e-4 | 4.858e-4 | 0.73 |
| 4–8 | 0（Ninfo=5e5 统计到零） | 4 dB: 1.55e-5；之后 0 | — |

### 5.3 门限 Eb/N0（对数插值）

| 目标 BER | MATLAB | Python | Δ(M−P) |
|----------|--------|--------|--------|
| 1e-1 | 0.33 dB | 0.01 dB | +0.32 dB |
| 5e-2 | 0.85 dB | 0.75 dB | +0.10 dB |
| 1e-2 | 1.69 dB | 1.67 dB | **+0.02 dB** |
| 1e-3 | 2.62 dB | 2.69 dB | **−0.08 dB** |

瀑布区（BER 1e-2～1e-3）两侧门限差 **≤0.1 dB**；低 SNR（BER~0.1）差约 0.3 dB，与过采样/成形参数不同相符。

设计报告「编码 1e-5 约 4.6 dB」：本次 MATLAB `Ninfo=5e5` 在 4 dB 及以上误码已统计为 0，**未直接测到 1e-5**；Python 在 4 dB 给出 1.55e-5，与 4.6 dB 锚点同量级。若报告签核需要 1e-5 点，应将 MATLAB `Ninfo` 提到 **≥2e6**（归档脚本原设）并扫至 6–8 dB。

## 6. 出口判定（对照项）

| 判据 | 结果 |
|------|------|
| 归档脚本可复现、参数明确 | 是（修复后） |
| 未编码与理论一致 | 是（偏差 ≲1.4%） |
| 编码曲线与 Python 黄金链同瀑布区 | 是（1e-2/1e-3 门限差 ≤0.1 dB） |
| 与历史归档 **逐点** ber.mat 一致 | **无法执行**（旧仓无数据文件） |
| 链路级定点 ≤0.5 dB | 见 `data/s1_ber_baseline/snr_loss_table.csv`（已通过，另一出口） |

**对照项结论**：在「归档算法重跑 + 未编码贴理论 + 编码与 Python 门限一致」意义上，**支持** S1 浮点黄金参考成立。  
若竞赛/课程要求「与 V2.1 归档文件逐点一致」，需队内补交当年 `ber.mat`/曲线图后再做一次叠图；在此之前本报告为对照证据链。

## 7. 后续动作

1. （可选）MATLAB `Ninfo=2e6`，Eb/N0=0:1:8，重跑 `run_ber_sweep_export`，把 1e-5 附近点补齐进 CSV。  
2. （可选）将 Python `config` 的 SRRC 改为 span=10/sps=8 与归档对齐后重跑 `run_ber.py`，可把门限差压到更小（会改黄金参考参数，须评审）。  
3. 队内评审冻结 `docs/spec/fixed_point_spec.md` 时，将本报告列为浮点参考附件。

## 8. 复现命令

```powershell
# MATLAB 归档导出
& "D:\software\Matlab\bin\matlab.exe" -batch "cd('D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\float_ref'); Ninfo=5e5; EbN0=0:8; run_ber_sweep_export"

# 与 Python 基线对照
python D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem\sim\float_ref\compare_matlab_python.py
```

---

*报告生成：S1 归档对照 · 依据 GoWin 归档 P1-S6 脚本与本仓库 `data/s1_ber_baseline/ber_float.npz`*
