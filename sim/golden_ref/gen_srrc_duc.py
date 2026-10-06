#!/usr/bin/env python
"""srrc_duc 系数与 NCO LUT 生成器

单一来源是 golden_ref 的定点模型（本文件不含任何自己的数值生成逻辑）：
  · SRRC 33 抽头系数  → golden_ref.fixed_point.fixed_modules.fixed_srrc_coeffs()（12 bit Q1.11）
  · NCO 四分之一波 LUT → golden_ref.fixed_point.duc.gen_sin_lut()（16 bit Q2.14，16384 项）

产物：
  · src/srrc_coeff.vh  —— SRRC 系数 localparam 数组（33 个 12 bit）
  · src/nco_lut.mem     —— NCO LUT（16384 行 16 bit 十六进制，$readmemh 读）

用法:
    python gen_srrc_duc.py            # 生成两个产物
    python gen_srrc_duc.py --check    # 校验磁盘产物与黄金模型一致（CI 用）
"""
from __future__ import annotations

import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parents[1]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

from golden_ref.config import DUC_CONFIG, FIXED_POINT_CONFIG  # noqa: E402
from golden_ref.fixed_point.fixed_modules import fixed_srrc_coeffs  # noqa: E402
from golden_ref.fixed_point.duc import gen_sin_lut  # noqa: E402

REPO_ROOT = SIM_DIR.parent
COEFF_PATH = REPO_ROOT / "src" / "srrc_coeff.vh"
LUT_PATH = REPO_ROOT / "src" / "nco_lut.mem"


def render_coeff() -> str:
    _, h_int = fixed_srrc_coeffs()
    w = FIXED_POINT_CONFIG["srrc_coeff_w"]
    frac = FIXED_POINT_CONFIG["srrc_coeff_frac"]
    n = len(h_int)
    lines = [
        "// =====================================================================",
        "// srrc_coeff.vh — SRRC 33 抽头系数（生成物，请勿手改）",
        "//",
        "// 生成器: sim/golden_ref/gen_srrc_duc.py",
        "// 黄金源: golden_ref.fixed_point.fixed_modules.fixed_srrc_coeffs()",
        f"// 位宽  : {w} bit 有符号 / {frac} bit 小数（Q1.{frac}，定点规格书 srrc_coeff）",
        "// 组织  : 原始序 h[0..32]；多相索引 h[p + 4*j] 在 RTL 内完成",
        "// 校验  : python sim/golden_ref/gen_srrc_duc.py --check",
        "// =====================================================================",
        f"localparam [{w - 1}:0] SRRC_H [0:{n - 1}] = '{{",
    ]
    for i, v in enumerate(h_int):
        vv = int(v) & ((1 << w) - 1)
        comma = "," if i < n - 1 else ""
        fval = float(v) / (1 << frac)
        lines.append(f"    {w}'h{vv:0{(w + 3) // 4}X}{comma} // h[{i}] = {fval:+.6f}")
    lines.append("};")
    return "\n".join(lines) + "\n"


def render_lut() -> str:
    _, lut_int = gen_sin_lut()
    w = DUC_CONFIG["nco_lut_w"]
    lines = []
    for v in lut_int:
        vv = int(v) & ((1 << w) - 1)
        lines.append(f"{vv:0{(w + 3) // 4}X}")
    return "\n".join(lines) + "\n"


def write(path: Path, text: str) -> None:
    # newline="\n"：仓库 .gitattributes 要求文本文件 LF
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def main(argv: list[str]) -> int:
    coeff = render_coeff()
    lut = render_lut()

    if "--check" in argv:
        ok = True
        for path, text, name in [(COEFF_PATH, coeff, "coeff"), (LUT_PATH, lut, "lut")]:
            if not path.exists():
                print(f"[SRRC-DUC] FAIL: 产物缺失 {path.relative_to(REPO_ROOT)}")
                ok = False
            elif path.read_text(encoding="utf-8") != text:
                print(f"[SRRC-DUC] FAIL: {name} 与黄金模型不一致 {path.relative_to(REPO_ROOT)}（重跑 gen_srrc_duc.py）")
                ok = False
        if ok:
            _, h_int = fixed_srrc_coeffs()
            _, lut_int = gen_sin_lut()
            print(f"[SRRC-DUC] OK: coeff taps={len(h_int)} lut={len(lut_int)} 与黄金模型一致")
            return 0
        return 1

    write(COEFF_PATH, coeff)
    write(LUT_PATH, lut)
    _, h_int = fixed_srrc_coeffs()
    _, lut_int = gen_sin_lut()
    print(f"[SRRC-DUC] OK: {COEFF_PATH.relative_to(REPO_ROOT)} taps={len(h_int)}  "
          f"{LUT_PATH.relative_to(REPO_ROOT)} lut={len(lut_int)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
