#!/usr/bin/env python3
"""
定点规格书自动生成工具
根据 config.py 中的位宽配置和量化/溢出策略，生成《定点规格书》Markdown 文档
默认写入 docs/spec/fixed_point_spec.md（评审冻结版存放处）
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from golden_ref.config import FIXED_POINT_CONFIG, QUANT_MODE, OVERFLOW_MODE
from golden_ref.fixed_point.quantizer import get_quant_range, get_quantization_noise_power

_REPO_ROOT = Path(__file__).resolve().parents[2]
_DEFAULT_SPEC = _REPO_ROOT / "docs" / "spec" / "fixed_point_spec.md"
_FREEZE_JSON = _REPO_ROOT / "docs" / "spec" / "freeze_status.json"


def _load_freeze_status():
    """读取 docs/spec/freeze_status.json；缺失时返回待评审默认值。"""
    import json
    default = {
        "version": "v1.0",
        "status": "pending_review",
        "status_zh": "待评审",
        "freeze_date": "",
        "review_record": "docs/report/s1_spec_review.md",
        "change_policy": "冻结后位宽/量化/溢出策略变更须走变更流程并重跑 sim/golden_ref",
        "baseline_evidence": [],
    }
    if not _FREEZE_JSON.exists():
        return default
    try:
        data = json.loads(_FREEZE_JSON.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default
    merged = dict(default)
    merged.update({k: v for k, v in data.items() if v is not None})
    return merged


def generate_fixed_point_spec(output_path=None):
    """生成定点规格书 Markdown 文档（默认 docs/spec/fixed_point_spec.md）"""
    if output_path is None:
        output_path = str(_DEFAULT_SPEC)

    freeze = _load_freeze_status()
    frozen = str(freeze.get("status", "pending_review")).lower() in ("frozen", "froze")

    # 模块描述
    module_desc = {
        "conv_encoder_out": "卷积编码器输出",
        "interleaver_out": "交织器输出",
        "qpsk_out": "QPSK 调制输出 (I/Q 复信号)",
        "srrc_out": "SRRC 脉冲成形输出",
        "srrc_coeff": "SRRC 滤波器系数",
        "awgn_out": "AWGN 信道输出",
        "sync_out": "同步模块输出",
        "viterbi_metric": "Viterbi 分支度量输入",
        "viterbi_pm": "Viterbi 路径度量",
    }

    lines = []
    lines.append("# 定点规格书 (Fixed-Point Specification)")
    lines.append("")
    lines.append("> **版本**: " + str(freeze.get("version", "v1.0")) + "  ")
    lines.append("> **适用模块**: S1 浮点黄金参考与定点化  ")
    lines.append("> **生成方式**: 自动生成自 `config.FIXED_POINT_CONFIG`  ")
    lines.append("")
    status_zh = freeze.get("status_zh") or ("已冻结" if frozen else "待评审")
    lines.append("## 0. 评审冻结状态")
    lines.append("")
    lines.append(f"> **状态**: **{status_zh}**  ")
    if frozen and freeze.get("freeze_date"):
        lines.append(f"> **冻结日期**: {freeze['freeze_date']}  ")
    else:
        lines.append("> **冻结日期**: （评审通过后填写）  ")
    lines.append(f"> **评审记录**: `{freeze.get('review_record', 'docs/report/s1_spec_review.md')}`  ")
    evidence = freeze.get("baseline_evidence") or []
    if evidence:
        lines.append("> **签核证据**:  ")
        for ev in evidence:
            lines.append(f">   - `{ev}`  ")
    lines.append(f"> **变更策略**: {freeze.get('change_policy', '见 §5')}  ")
    if not frozen:
        lines.append("> ")
        lines.append("> 当前为**评审前草稿**。全员评审通过后，修改 `docs/spec/freeze_status.json`")
        lines.append("> 为 `status=frozen` 并填写日期，再运行本脚本刷新本文档。")
    lines.append("")

    # ---- 概述 ----
    lines.append("## 1. 概述")
    lines.append("")
    lines.append("本文档定义全链路各模块的定点化位宽、量化方式与溢出处理策略。")
    lines.append("所有模块均采用 **有符号补码** 表示，位宽包含 1 bit 符号位。")
    lines.append("")
    lines.append(f"- **量化方式**: `{QUANT_MODE}`" +
                 ("（四舍五入）" if QUANT_MODE == "round" else "（截断）"))
    lines.append(f"- **溢出处理**: `{OVERFLOW_MODE}`" +
                 ("（饱和）" if OVERFLOW_MODE == "saturate" else "（卷绕）"))
    lines.append("")

    # ---- 模块位宽总表 ----
    lines.append("## 2. 模块位宽总表")
    lines.append("")
    lines.append("| 模块 | 总位宽 (bit) | 整数位 (含符号) | 小数位 | 表示范围 | 量化步长 | 量化噪声功率 |")
    lines.append("|------|:-----------:|:--------------:|:------:|----------|:--------:|:------------:|")
    lines.append("")

    for key, desc in module_desc.items():
        w_key = f"{key}_w"
        f_key = f"{key}_frac"

        if w_key not in FIXED_POINT_CONFIG:
            continue

        total_w = FIXED_POINT_CONFIG[w_key]
        frac_w = FIXED_POINT_CONFIG[f_key]
        int_w = total_w - frac_w  # 含符号位

        min_val, max_val, step = get_quant_range(total_w, frac_w)
        noise_power = get_quantization_noise_power(total_w, frac_w)

        range_str = f"[{min_val:.4f}, {max_val:.4f}]"
        step_str = f"{step:.6e}"
        noise_str = f"{noise_power:.2e}"

        lines.append(f"| {desc} | {total_w} | {int_w} | {frac_w} | {range_str} | {step_str} | {noise_str} |")

    lines.append("")

    # ---- 关键节点详述 ----
    lines.append("## 3. 关键节点详述")
    lines.append("")

    lines.append("### 3.1 SRRC 输出")
    lines.append("")
    srrc_w = FIXED_POINT_CONFIG["srrc_out_w"]
    srrc_f = FIXED_POINT_CONFIG["srrc_out_frac"]
    min_v, max_v, step_v = get_quant_range(srrc_w, srrc_f)
    lines.append(f"- **位宽**: {srrc_w} bit 有符号, {srrc_f} bit 小数")
    lines.append(f"- **表示范围**: [{min_v:.4f}, {max_v:.4f}]")
    lines.append(f"- **量化步长**: {step_v:.6e}")
    lines.append("- **设计说明**: SRRC 输出信号峰值约 ±2.0，留 2 bit 整数位余量，"
                 "防止脉冲成形后峰值溢出。小数位 11 bit 保证足够精度。")
    lines.append("")

    lines.append("### 3.2 Viterbi 度量")
    lines.append("")
    vm_w = FIXED_POINT_CONFIG["viterbi_metric_w"]
    vm_f = FIXED_POINT_CONFIG["viterbi_metric_frac"]
    min_v, max_v, step_v = get_quant_range(vm_w, vm_f)
    lines.append(f"- **分支度量位宽**: {vm_w} bit 有符号, {vm_f} bit 小数")
    lines.append(f"- **路径度量位宽**: {FIXED_POINT_CONFIG['viterbi_pm_w']} bit 有符号, "
                 f"{FIXED_POINT_CONFIG['viterbi_pm_frac']} bit 小数")
    lines.append(f"- **分支度量范围**: [{min_v:.4f}, {max_v:.4f}]")
    lines.append("- **设计说明**: 分支度量由 QPSK 软解调输出量化而来，8 bit 足够区分"
                 "各分支的度量差异。路径度量 16 bit 防止累积溢出，并采用"
                 "每步减最小值的归一化策略。")
    lines.append("")

    lines.append("### 3.3 CIC 各级（预留）")
    lines.append("")
    cic_ws = FIXED_POINT_CONFIG.get("cic_stage_w", [])
    cic_fs = FIXED_POINT_CONFIG.get("cic_stage_frac", [])
    for i, (w, f) in enumerate(zip(cic_ws, cic_fs)):
        min_v, max_v, step_v = get_quant_range(w, f)
        lines.append(f"- **第 {i+1} 级**: {w} bit / {f} bit 小数, 范围 [{min_v:.1f}, {max_v:.1f}]")
    lines.append("- **设计说明**: CIC 各级位宽逐级增长，匹配积分器的位宽扩展需求。"
                 "具体级数和位宽根据最终插值/抽取比确定。")
    lines.append("")

    # ---- 验证方法 ----
    lines.append("## 4. 验证方法")
    lines.append("")
    lines.append("1. **定点 vs 浮点逐节点比对**: 在每个模块输出端，计算定点与浮点输出的 SNR 差异。")
    lines.append("2. **全链路 BER 比对**: 在 Eb/N0 = 0~8 dB 范围内扫描，比较浮点与定点的 BER 曲线。")
    lines.append("3. **出口门槛**: 定点链相对浮点 BER 损失 ≤ 0.5 dB（在目标 BER 处测量）。")
    lines.append("")

    # ---- 变更流程 ----
    lines.append("## 5. 变更流程")
    lines.append("")
    lines.append("本规格书经全员评审后冻结。后续模块位宽调整必须遵循以下流程：")
    lines.append("")
    lines.append("1. 提交变更申请，说明调整原因与预期影响")
    lines.append("2. 重新运行全链路 BER 仿真，验证 SNR 损失仍 ≤ 0.5 dB")
    lines.append("3. 更新关键节点 SNR 损失表")
    lines.append("4. 评审通过后更新本文档版本号")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("*本文档由 `generate_spec.py` 自动生成；冻结状态来自 `docs/spec/freeze_status.json`，"
                 "位宽正文勿手改。评审模板见 `docs/report/s1_spec_review.md`。*")

    # 写入文件
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"定点规格书已生成: {output_path}")
    return output_path


if __name__ == "__main__":
    generate_fixed_point_spec()
