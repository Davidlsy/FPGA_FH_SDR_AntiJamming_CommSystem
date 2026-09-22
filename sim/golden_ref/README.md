# S1 黄金参考链（golden_ref）

全系统唯一正确性基准：浮点参考链 + 定点参考模型。

- 链路：卷积 (171,133)₈ / 交织 10 / QPSK / SRRC α=0.35 / AWGN / 同步 / Viterbi
- 量化：round（四舍五入）+ saturate（饱和），位宽见 `docs/spec/fixed_point_spec.md`
- 来源：`s1_golden_reference.zip`（包名在仓库内规范为 `golden_ref`）

## 仓库内路径

| 内容 | 路径 |
|------|------|
| 参考链源码 / 脚本 | `sim/golden_ref/`（本目录） |
| BER 基线曲线 + 原始数据 | `data/s1_ber_baseline/` |
| 定点规格书（冻结基准） | `docs/spec/fixed_point_spec.md` |

## 目录结构

```text
sim/golden_ref/
├── config.py           # 系统参数与 FIXED_POINT_CONFIG
├── run_ber.py          # BER 仿真入口
├── generate_spec.py    # 从 config 生成定点规格书
├── float_chain/        # 浮点模块
├── fixed_point/        # 定点模块与量化器
└── sim/                # 浮点/定点链路仿真与 SNR 损失分析
```

## 运行

依赖：Python 3 + numpy（绘图可选 matplotlib）。在本目录执行：

```powershell
python run_ber.py --quick          # 快速冒烟
python run_ber.py                  # 标准 Eb/N0 0–8 dB
python run_ber.py --float-only     # 仅浮点
python run_ber.py --export-loss-only  # 仅从已有 npz 导出损失表
python generate_spec.py            # 重新生成规格书到 docs/spec/
```

默认输出：

- `data/s1_ber_baseline/ber_float.npz`
- `data/s1_ber_baseline/ber_fixed.npz`
- `data/s1_ber_baseline/ber_curve.png`
- `data/s1_ber_baseline/snr_loss_table.csv`
- `docs/spec/fixed_point_spec.md`（generate_spec）

## 出口门槛

定点链相对浮点 BER 损失 **≤ 0.5 dB**（Eb/N0 0–8 dB 扫描）。规格书经全员评审冻结后，后续模块位真比对一律以 `docs/spec/fixed_point_spec.md` 为准；改动须走变更流程并重跑本链路。

评审冻结模板：

- 会议记录：`docs/report/s1_spec_review.md`
- 状态源：`docs/spec/freeze_status.json`（`pending_review` → `frozen` 后重跑 `generate_spec.py`）

## 下游用法

- S2+：testbench / RTL 输出与本包浮点、定点向量逐拍或逐 BER 点比对
- S5/S8：RTL BER 与 `data/s1_ber_baseline/` 基线叠图
