#!/usr/bin/env python3
"""S2 比对框架 · golden 向量导出器

把 S1 定点参考模型（sim/golden_ref）转成 xsim 可直接 $readmemh 的十六进制向量：

    vectors/<module>/<case>_stim.hex      每行一个输入总线值
    vectors/<module>/<case>_expect.hex    与 stim 逐行对应的期望输出总线值
    vectors/<module>/<case>_meta.json     位宽 / 打包规则 / 种子 / 样本数

位宽、小数位一律取自 golden_ref.config.FIXED_POINT_CONFIG（即 docs/spec/
fixed_point_spec.md 的机器可读来源），本文件不硬编码任何位宽。

向量格式与 TB 时序契约见 sim/framework/README.md，比对器见 hdl/tb_vec_cmp.sv。
新增模块：在 MODULES 里加一条 `cases` + `export` 即可，S4 的 frame_tx / conv_enc /
qpsk_map / blk_inter / srrc_duc 依次照此接入。
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parents[1]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

import numpy as np  # noqa: E402

from golden_ref import __version__ as GOLDEN_REF_VERSION  # noqa: E402
from golden_ref.config import FIXED_POINT_CONFIG  # noqa: E402
from golden_ref.fixed_point.fixed_modules import fixed_qpsk_modulate  # noqa: E402

FRAMEWORK_DIR = Path(__file__).resolve().parent
DEFAULT_OUT = FRAMEWORK_DIR / "vectors"
DEFAULT_SEED = 20260924


# ============================================================
# 定点 → 十六进制
# ============================================================
def to_int(value: float, width: int, frac: int) -> int:
    """把 S1 定点模型的输出精确还原为补码整数。

    golden_ref.quantizer 的返回值恒落在 int/2**frac 这一格点上，所以这里 round
    回整数是无损的；同时校验格点与位宽范围，避免向量静默溢出或被悄悄截断。
    """
    scaled = float(value) * (1 << frac)
    nearest = int(round(scaled))
    if abs(scaled - nearest) > 1e-6:
        raise ValueError(f"{value} 不在 {frac} 位小数格点上（偏移 {scaled - nearest:.3e}）")
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    if not lo <= nearest <= hi:
        raise ValueError(f"{nearest} 超出 {width} bit 补码范围 [{lo}, {hi}]")
    return nearest


def hex_of_int(value: int, width: int) -> str:
    """补码整数 → 定宽十六进制（无 0x 前缀，xsim $readmemh 按位宽左填充）。"""
    return format(value & ((1 << width) - 1), f"0{(width + 3) // 4}x")


def pack_fields(*fields: tuple[int, int]) -> int:
    """按高位在前打包若干 (整数, 位宽) 字段。"""
    out = 0
    for value, width in fields:
        out = (out << width) | (value & ((1 << width) - 1))
    return out


# ============================================================
# qpsk_map
# ============================================================
def _qpsk_map_cases(seed: int):
    """返回 [(用例名, 载荷, 用例说明)]；载荷为 (i_bit, q_bit) 列表。

    比特序号沿用 golden_ref 约定：偶位为 I、奇位为 Q，故一个符号即 (I, Q)。
    """
    rng = np.random.default_rng(seed)
    n_rand = 4096
    rand_bits = rng.integers(0, 2, size=2 * n_rand)
    rand_syms = list(zip(rand_bits[0::2].tolist(), rand_bits[1::2].tolist()))

    edge_syms = [(0, 0), (1, 1), (0, 1), (1, 0)]   # 四星座点，首拍即复位后第一个符号
    edge_syms += [(0, 0)] * 64                     # 全 0 载荷连续段
    edge_syms += [(1, 1)] * 64                     # 全 1 载荷连续段
    edge_syms += [(0, 0), (1, 1)] * 32             # 最坏码型交替

    return [
        ("rand", rand_syms, f"长随机序列 {n_rand} 符号（default_rng(seed={seed})）"),
        ("edge", edge_syms, "边界用例：四星座点 + 全 0/全 1 连续段 + 最坏码型交替"),
    ]


def _export_qpsk_map(syms, seed: int):
    cfg = FIXED_POINT_CONFIG
    w, frac = cfg["qpsk_out_w"], cfg["qpsk_out_frac"]

    bits = np.array([b for pair in syms for b in pair], dtype=np.int8)
    sym_q = fixed_qpsk_modulate(bits)
    if len(sym_q) != len(syms):
        raise RuntimeError(f"参考模型输出符号数 {len(sym_q)} != 载荷 {len(syms)}")

    stim_hex, expect_hex = [], []
    for (i_bit, q_bit), s in zip(syms, sym_q):
        stim_hex.append(hex_of_int(pack_fields((i_bit, 1), (q_bit, 1)), 2))
        expect_hex.append(
            hex_of_int(
                pack_fields(
                    (to_int(s.real, w, frac), w),
                    (to_int(s.imag, w, frac), w),
                ),
                2 * w,
            )
        )

    meta = {
        "stim": {"bits": 2, "packing": "{i_bit, q_bit}", "frac": None},
        "expect": {
            "bits": 2 * w,
            "packing": "{i_out[11:0], q_out[11:0]}",
            "field_bits": w,
            "field_frac": frac,
        },
    }
    return stim_hex, expect_hex, meta


# ============================================================
# 注册表：新增模块在此登记
# ============================================================
MODULES = {
    "qpsk_map": {
        "cases": _qpsk_map_cases,
        "export": _export_qpsk_map,
        "golden_source": "golden_ref.fixed_point.fixed_modules.fixed_qpsk_modulate",
    },
}


# ============================================================
# 落盘
# ============================================================
def _write_lines(path: Path, lines) -> None:
    # newline="\n"：仓库 .gitattributes 要求文本文件 LF，Windows 默认会写成 CRLF
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def _write_json(path: Path, payload: dict) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")


def export_module(module: str, case_filter: str, seed: int, out_dir: Path) -> list[dict]:
    entry = MODULES[module]
    written = []
    out_dir = out_dir / module
    out_dir.mkdir(parents=True, exist_ok=True)

    for case, payload, note in entry["cases"](seed):
        if case_filter != "all" and case != case_filter:
            continue

        stim_hex, expect_hex, meta = entry["export"](payload, seed)
        if len(stim_hex) != len(expect_hex):
            raise RuntimeError(f"{module}/{case}: stim {len(stim_hex)} 行 != expect {len(expect_hex)} 行")

        _write_lines(out_dir / f"{case}_stim.hex", stim_hex)
        _write_lines(out_dir / f"{case}_expect.hex", expect_hex)
        _write_json(
            out_dir / f"{case}_meta.json",
            {
                "module": module,
                "case": case,
                "count": len(stim_hex),
                "case_note": note,
                "seed": seed,
                "golden_source": entry["golden_source"],
                "golden_ref_version": GOLDEN_REF_VERSION,
                "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
                **meta,
            },
        )
        written.append({"module": module, "case": case, "count": len(stim_hex)})
    return written


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="从 S1 定点参考模型导出 xsim 比对向量")
    ap.add_argument("--module", action="append", default=None,
                    help=f"模块名，可重复；缺省=全部（{'/'.join(MODULES)}）")
    ap.add_argument("--case", default="all", help="用例名，缺省 all")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED, help=f"随机种子，缺省 {DEFAULT_SEED}")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"输出目录，缺省 {DEFAULT_OUT}")
    ap.add_argument("--list", action="store_true", help="只列出已注册模块")
    args = ap.parse_args(argv)

    if args.list:
        for name, entry in MODULES.items():
            cases = "/".join(c for c, _, _ in entry["cases"](DEFAULT_SEED))
            print(f"{name:16s} cases={cases:12s} {entry['golden_source']}")
        return 0

    modules = args.module or list(MODULES)
    unknown = [m for m in modules if m not in MODULES]
    if unknown:
        print(f"未注册的模块: {', '.join(unknown)}（已注册: {', '.join(MODULES)}）", file=sys.stderr)
        return 2

    total = 0
    for module in modules:
        written = export_module(module, args.case, args.seed, args.out)
        if not written:
            print(f"[VEC-GEN] {module}/{args.case} 无匹配用例", file=sys.stderr)
            return 2
        for item in written:
            rel = (args.out / item["module"]).relative_to(FRAMEWORK_DIR) if args.out.is_relative_to(FRAMEWORK_DIR) else args.out / item["module"]
            print(f"[VEC-GEN] {item['module']}/{item['case']}  {item['count']:6d} 行  → {rel}\\{item['case']}_{{stim,expect}}.hex")
            total += item["count"]

    print(f"[VEC-GEN] 完成：{len(modules)} 个模块，合计 {total} 个向量样本")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
