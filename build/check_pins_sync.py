import re

xdc = open(r"board\fhss_zynq_pins.xdc", encoding="ascii").read()
md = open(r"docs\pins.md", encoding="utf-8").read()

xdc_map = {}
for line in xdc.splitlines():
    s = line.lstrip("#").strip()
    m = re.search(r"PACKAGE_PIN\s+(\w+).*get_ports\s+\{?([A-Za-z0-9_\[\]]+)\}?\]", s)
    if m:
        xdc_map[m.group(2)] = m.group(1)

md_map = {}
for line in md.splitlines():
    m = re.match(r"\|\s*`([A-Za-z0-9_\[\]]+)`\s*\|\s*\*\*(\w+)\*\*", line)
    if m:
        md_map[m.group(1)] = m.group(2)

print("xdc entries:", len(xdc_map), " md entries:", len(md_map))
print("only in xdc :", {k: v for k, v in xdc_map.items() if k not in md_map})
print("only in md  :", {k: v for k, v in md_map.items() if k not in xdc_map})
print("mismatch    :", {k: (xdc_map[k], md_map[k]) for k in xdc_map if k in md_map and xdc_map[k] != md_map[k]})
pins = list(xdc_map.values())
print("dup pins    :", [p for p in set(pins) if pins.count(p) > 1])
