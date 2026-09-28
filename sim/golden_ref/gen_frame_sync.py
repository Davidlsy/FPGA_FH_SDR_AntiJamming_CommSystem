#!/usr/bin/env python
"""帧同步字头文件生成器 —— Gold 同步字 → src/frame_tx_sync.vh

单一来源是 `golden_ref.float_chain.framing.gold_sync_word()`（本文件不含任何
自己的序列生成逻辑，只负责把它落成 RTL 常量）。

为什么落成 `localparam` 而不是 `.mem`：
  · `$readmemh` 的路径是运行时相对路径，仿真与综合的工作目录不一致时容易失联；
  · 64 bit 常量在综合期即映射为 LUT-ROM，符合"系数存 LUT-ROM 直接输出、
    不做运行时生成"的要求；
  · `frame_tx` 的位真向量比对会逐位校核这 64 个输出，常量若漂移必然红——再由
    本文件 `--check` 在提交前拦住，两道闸都指向同一个黄金模型。

用法:
    python gen_frame_sync.py           # 生成 src/frame_tx_sync.vh（覆盖）
    python gen_frame_sync.py --check   # 只校验磁盘产物与黄金模型是否一致（CI 用）
"""
from __future__ import annotations

import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parents[1]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

from golden_ref.config import (  # noqa: E402
    FRAME_SYNC_LEN,
    FRAME_SYNC_M,
    FRAME_SYNC_POLY,
)
from golden_ref.float_chain.framing import bits_to_int, gold_sync_word  # noqa: E402

REPO_ROOT = SIM_DIR.parent
OUT_PATH = REPO_ROOT / "src" / "frame_tx_sync.vh"


def render() -> str:
    sync = gold_sync_word()
    word = bits_to_int(sync)
    polys = " 与 ".join(f"0o{p:o}" for p in FRAME_SYNC_POLY)
    return (
        "// =====================================================================\n"
        "// frame_tx_sync.vh — 帧同步字常量（生成物，请勿手改）\n"
        "//\n"
        "// 生成器: sim/golden_ref/gen_frame_sync.py\n"
        "// 黄金源: golden_ref.float_chain.framing.gold_sync_word()\n"
        f"// 构造  : {FRAME_SYNC_M} 级 m 序列优选对 {polys} 逐位异或，\n"
        f"//         周期 2^{FRAME_SYNC_M}-1 = 63，取 {FRAME_SYNC_LEN} bit（末位重复首位）\n"
        "// 规格  : docs/spec/frame_format.md §2\n"
        "// 校验  : python sim/golden_ref/gen_frame_sync.py --check\n"
        "// =====================================================================\n"
        f"localparam [63:0] FRAME_SYNC_WORD = 64'h{word:016X};\n"
    )


def main(argv: list[str]) -> int:
    text = render()
    if "--check" in argv:
        if not OUT_PATH.exists():
            print(f"[FRAME-SYNC] FAIL: 产物缺失 {OUT_PATH.relative_to(REPO_ROOT)}")
            return 1
        if OUT_PATH.read_text(encoding="utf-8") != text:
            print(f"[FRAME-SYNC] FAIL: 产物与黄金模型不一致 "
                  f"{OUT_PATH.relative_to(REPO_ROOT)}（重跑 gen_frame_sync.py）")
            return 1
        print(f"[FRAME-SYNC] OK: {OUT_PATH.relative_to(REPO_ROOT)} 与黄金模型一致 "
              f"bits={FRAME_SYNC_LEN} words=1")
        return 0

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    # newline="\n"：仓库 .gitattributes 要求文本文件 LF
    with open(OUT_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"[FRAME-SYNC] OK: {OUT_PATH.relative_to(REPO_ROOT)} bits={FRAME_SYNC_LEN} words=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
