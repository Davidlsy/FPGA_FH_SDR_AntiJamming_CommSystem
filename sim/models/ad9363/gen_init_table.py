#!/usr/bin/env python
"""AD9363 初始化表生成器 —— 从 CSV 单一来源派生 RTL ROM 与 TB 期望文件。

    ad9363_init_table.csv
        |-- gen_init_table.py --> ad9363_init.mem         (RTL: cfg_rom, $readmemh 32-bit 字)
        `----------------------> ad9363_init_expect.txt  (TB : 逐条 (op,addr,data,gap) 期望)

两条输出走相互独立的编码路径，TB 因此能抓住 .mem 的字段打包错误（地址/数据/延时
写错位、位宽截断、表项数不符等）——只比对 DUT 内部信号做不到这一点。

用法:
    python gen_init_table.py           # 生成两份产物（覆盖）
    python gen_init_table.py --check   # 只校验磁盘上的产物与 CSV 是否一致（CI 用）

编码（与 src/ad9363_cfg.v 头注释一致，32-bit 字）:
    [31:28] OP | [27:18] ADDR | [17:16] RSVD | [15:8] DATA | [7:0] 短延时
    OP_WRITE=0 OP_READV=1 OP_DELAY=2 OP_END=0xF
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CSV_PATH = HERE / "ad9363_init_table.csv"
MEM_PATH = HERE / "ad9363_init.mem"
EXPECT_PATH = HERE / "ad9363_init_expect.txt"

OP_WRITE, OP_READV, OP_DELAY, OP_END = 0x0, 0x1, 0x2, 0xF
OP_NAMES = {"WRITE": OP_WRITE, "READV": OP_READV, "DELAY": OP_DELAY, "END": OP_END}

ADDR_MAX = 0x3FF
DATA_MAX = 0xFF
SHORT_DELAY_MAX = 0xFF          # [7:0]
LONG_DELAY_MAX = (1 << 28) - 1  # [27:0]


class TableError(Exception):
    pass


def parse_csv(path: Path) -> list[dict]:
    rows: list[dict] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().startswith("op,"):     # 表头
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 4:
            raise TableError(f"{path.name}:{lineno}: fewer than 4 fields: {line!r}")
        op_txt, addr_txt, data_txt, delay_txt = parts[0], parts[1], parts[2], parts[3]
        note = parts[4] if len(parts) > 4 else ""

        if op_txt not in OP_NAMES:
            raise TableError(f"{path.name}:{lineno}: unknown op {op_txt!r}")
        op = OP_NAMES[op_txt]

        addr = _hex_field(addr_txt, f"{path.name}:{lineno}: addr", ADDR_MAX, op, need=(op in (OP_WRITE, OP_READV)))
        data = _hex_field(data_txt, f"{path.name}:{lineno}: data", DATA_MAX, op, need=(op in (OP_WRITE, OP_READV)))

        if delay_txt == "":
            delay = 0
        else:
            try:
                delay = int(delay_txt, 10)
            except ValueError as exc:
                raise TableError(f"{path.name}:{lineno}: delay_us not decimal: {delay_txt!r}") from exc

        limit = SHORT_DELAY_MAX if op in (OP_WRITE, OP_READV) else LONG_DELAY_MAX
        if not 0 <= delay <= limit:
            raise TableError(
                f"{path.name}:{lineno}: delay_us={delay} outside {op_txt} field range 0..{limit}"
            )
        if op == OP_END and delay != 0:
            raise TableError(f"{path.name}:{lineno}: END entry must not carry a delay")

        rows.append({"op": op, "op_txt": op_txt, "addr": addr, "data": data, "delay": delay, "note": note})

    if not rows:
        raise TableError("table is empty")
    if rows[-1]["op"] != OP_END:
        raise TableError("last entry must be END")
    if sum(1 for r in rows if r["op"] == OP_END) != 1:
        raise TableError("END entry must appear exactly once")
    return rows


def _hex_field(text: str, where: str, limit: int, op: int, need: bool) -> int:
    if text == "":
        if need:
            raise TableError(f"{where}: {OP_NAMES_INV[op]} entry must provide this field")
        return 0
    try:
        value = int(text, 16)
    except ValueError as exc:
        raise TableError(f"{where}: not a hex number: {text!r}") from exc
    if not 0 <= value <= limit:
        raise TableError(f"{where}: 0x{value:X} outside 0..0x{limit:X}")
    return value


OP_NAMES_INV = {v: k for k, v in OP_NAMES.items()}


def encode_mem_word(row: dict) -> int:
    """RTL 侧编码：cfg_rom 的 32-bit 字。"""
    op = row["op"]
    if op == OP_END:
        return OP_END << 28
    if op == OP_DELAY:
        return (OP_DELAY << 28) | (row["delay"] & LONG_DELAY_MAX)
    return (op << 28) | ((row["addr"] & ADDR_MAX) << 18) | ((row["data"] & DATA_MAX) << 8) | (
        row["delay"] & SHORT_DELAY_MAX
    )


def build_mem(rows: list[dict]) -> str:
    return "".join(f"{encode_mem_word(r):08X}\n" for r in rows)


def build_expect(rows: list[dict]) -> tuple[str, int]:
    """TB 侧期望：每个 SPI 事务一行 (op addr data gap_us)。

    gap_us = 本事务结束后、下一个事务开始前，表里声明的总延时
             （本表项自带的短延时 + 其后的 DELAY 表项之和）。
    只由表的延时字段算出，与 .mem 的编码路径无关。
    """
    txns: list[list] = []
    pending_delay = 0
    for row in rows:
        op = row["op"]
        if op == OP_DELAY:
            pending_delay += row["delay"]
            continue
        if op == OP_END:
            break
        if txns:
            txns[-1][3] = pending_delay
        pending_delay = row["delay"]
        txns.append([op, row["addr"], row["data"], 0])
    # 最后一个事务之后不再有事务，gap 记 0（其后的延时不属于任何间隙）

    lines = [f"{len(txns)} {len(rows)}"]
    for op, addr, data, gap in txns:
        lines.append(f"{op} {addr:03X} {data:02X} {gap}")
    return "\n".join(lines) + "\n", len(txns)


def main(argv: list[str]) -> int:
    check_only = "--check" in argv
    try:
        rows = parse_csv(CSV_PATH)
    except (TableError, OSError) as exc:
        print(f"[GEN-INIT] FAIL: {exc}")
        return 2

    mem_text = build_mem(rows)
    expect_text, n_txn = build_expect(rows)
    n_words = len(rows)

    if check_only:
        problems = []
        for path, want in ((MEM_PATH, mem_text), (EXPECT_PATH, expect_text)):
            got = path.read_text(encoding="utf-8") if path.exists() else None
            if got != want:
                problems.append(path.name)
        if problems:
            print(f"[GEN-INIT] FAIL: stale artifacts vs csv: {', '.join(problems)} "
                  f"(rerun gen_init_table.py)")
            return 1
        print(f"[GEN-INIT] OK: artifacts match csv (words={n_words} txns={n_txn})")
        return 0

    MEM_PATH.write_text(mem_text, encoding="utf-8", newline="\n")
    EXPECT_PATH.write_text(expect_text, encoding="utf-8", newline="\n")
    total_delay = sum(r["delay"] for r in rows)
    print(
        f"[GEN-INIT] OK: {MEM_PATH.name} words={n_words} | {EXPECT_PATH.name} txns={n_txn} "
        f"| declared_delay_total={total_delay}us"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
