"""Compare Python golden_ref float BER vs MATLAB archive re-run CSV."""
import csv
from pathlib import Path
import numpy as np

root = Path(r"D:\My_project\FPGA_FH_SDR_AntiJamming_CommSystem")
py = np.load(root / "data" / "s1_ber_baseline" / "ber_float.npz")
csv_path = root / "sim" / "float_ref" / "results" / "matlab_archive_ber.csv"

rows = list(csv.DictReader(open(csv_path, encoding="utf-8-sig")))
eb_m = np.array([float(r["eb_n0_db"]) for r in rows])
ber_c = np.array([float(r["ber_coded"]) for r in rows])
ber_u = np.array([float(r["ber_unc"]) for r in rows])
ber_t = np.array([float(r["ber_theory_unc"]) for r in rows])

eb_p = np.asarray(py["eb_n0_db"], float)
ber_p = np.asarray(py["ber"], float)

print("EbN0 | MATLAB coded | Python float | ratio M/P | MATLAB unc vs theory")
print("-" * 78)
compare = []
for e, mc, mu, mt in zip(eb_m, ber_c, ber_u, ber_t):
    # python at same ebn0
    if e in eb_p:
        bp = float(ber_p[list(eb_p).index(e)])
    else:
        bp = float("nan")
    ratio = (mc / bp) if bp > 0 else float("nan")
    th_err_db = 0.0
    if mu > 0 and mt > 0:
        # rough: not eb shift, just print
        pass
    print(f"{e:4.0f} | {mc:.3e}   | {bp:.3e}    | {ratio:8.3f} | unc={mu:.3e} th={mt:.3e}")
    compare.append((e, mc, bp, ratio, mu, mt))

# interpolation: EbN0 at coded BER targets for MATLAB
def ebn0_at(e, b, target):
    e = np.asarray(e, float); b = np.asarray(b, float)
    pos = b > 0
    if not np.any(pos):
        return None
    floor = float(b[pos].min())
    for i in range(len(b)-1):
        b0, b1 = float(b[i]), float(b[i+1])
        if b0 <= 0: b0 = floor
        if b1 <= 0: b1 = floor
        lo, hi = min(b0,b1), max(b0,b1)
        if not (lo <= target <= hi):
            continue
        y0, y1 = np.log10(b0), np.log10(b1)
        yt = np.log10(target)
        if y1 == y0:
            return float(e[i])
        return float(e[i] + (e[i+1]-e[i])*(yt-y0)/(y1-y0))
    return None

print("\nEbN0 @ target BER (coded MATLAB vs Python float):")
for t in [1e-1, 5e-2, 1e-2, 1e-3]:
    em = ebn0_at(eb_m, ber_c, t)
    ep = ebn0_at(eb_p, ber_p, t)
    if em is None or ep is None:
        print(f"  {t:.0e}: MATLAB={em} Python={ep}")
        continue
    print(f"  {t:.0e}: MATLAB={em:.3f} dB, Python={ep:.3f} dB, delta(M-P)={em-ep:+.3f} dB")

# uncoded vs theory max relative
rel = np.abs(ber_u - ber_t) / np.maximum(ber_t, 1e-20)
print(f"\nUncoded vs theory: max rel err={np.nanmax(rel):.4f}, mean={np.nanmean(rel):.4f}")
print("MATLAB_COMPARE_SCRIPT_OK")
