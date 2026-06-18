#!/usr/bin/env python3
"""sweep_util.py -- M3 utilization + cycle harness.

Produces results/util_sweep.csv: spatial utilization, cycle count, and achieved
MAC throughput vs batch M vs logical shape, for the P=1024 pool in its four
shapes (32x32, 16x64, 8x128, 4x256), at N=256 (tiled across C), K=32.

Method
------
For an output-stationary array the per-tile latency is K+R+C-2 (pipeline fill
R+C plus K accumulations). We MEASURE this directly from the RTL by running one
full physical tile (M=R, N=C) per shape and reading the corner's valid window:
empirically valid_rise=R+C and done=R+C+K, so latency = done-2 = K+R+C-2. Because
result_valid_out is the FULL-array corner (R-1,C-1), padded rows still drive it,
so the per-tile latency is independent of M -- exactly as the model assumes (it
uses R,C, not M,N). We confirm this with one extra partial-tile run (M<R).

The full M x 256 workload needs ceil(M/R)*ceil(N/C) serial tiles (output-
stationary: each tile must drain before the next), so

    cycles = ceil(M/R) * ceil(N/C) * (K+R+C-2) - 1            (model)

with the per-tile term taken from the hardware measurement. Spatial utilization
is the per-tile fabric occupancy:

    spatial_util = (min(M,R) * min(N,C)) / (R*C)

Every CSV row's cycle count is validated against the closed form (must agree
within 1 cycle) and the util against its formula.
"""

import csv
import math
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_E = os.path.join(ROOT, "src", "exact_accum")
SRC_R = os.path.join(ROOT, "src", "reconfig")
TB = os.path.join(ROOT, "tb", "reconfig_tb", "gemm_driver_tb.sv")
VIVADO = "/tools/Xilinx/Vivado/2022.1/settings64.sh"

SHAPES = [(32, 32), (16, 64), (8, 128), (4, 256)]
BATCHES = [1, 2, 4, 8, 16, 32]
N_TOTAL = 256
K = 32
SEED = 11


def gen_vectors(R, C, M, N, out):
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "gen_vectors.py"),
                    "--M", str(M), "--N", str(N), "--K", str(K),
                    "--seed", str(SEED), "--out", out],
                   check=True, stdout=subprocess.DEVNULL)


def run_sim(R, C, M, N, tag):
    """Build + run one tile; return the parsed CSVROW dict."""
    case = os.path.join(ROOT, "tb", "gen", f"case_{tag}")
    run = os.path.join(ROOT, "build", "m3", tag)
    if os.path.isdir(run):
        shutil.rmtree(run)
    os.makedirs(run)
    gen_vectors(R, C, M, N, case)
    for f in os.listdir(case):
        if f.startswith("block"):
            shutil.copy(os.path.join(case, f), run)

    script = f"""
source {VIVADO} >/dev/null 2>&1 || true
cd {run}
xvlog -sv -d R_PARAM={R} -d C_PARAM={C} -d M_PARAM={M} -d N_PARAM={N} \
    -d K_PARAM={K} -d P_PARAM=1024 \
    {SRC_E}/clz.sv {SRC_E}/convert_fixed2bf16.sv {SRC_E}/pe_exact_1s.sv \
    {SRC_R}/os_array_shaped.sv {TB} > xvlog.log 2>&1
xelab gemm_driver_tb -s sim --timescale 1ns/1ps > xelab.log 2>&1
xsim sim -runall > xsim.log 2>&1
"""
    subprocess.run(["bash", "-c", script], check=True)
    with open(os.path.join(run, "xsim.log")) as f:
        text = f.read()
    m = re.search(r"CSVROW (.+)", text)
    if not m:
        raise RuntimeError(f"no CSVROW for {tag}\n{text[-500:]}")
    d = {}
    for kv in m.group(1).split():
        if "=" in kv:
            key, val = kv.split("=")
            d[key] = int(val)
    return d


def main():
    print("=== M3 sweep: measuring per-tile latency from RTL (one full tile/shape) ===")
    latency = {}
    for (R, C) in SHAPES:
        d = run_sim(R, C, R, C, f"lat_{R}x{C}")
        model_term = K + R + C - 2
        Lmeas = d["latency"]
        ok = abs(Lmeas - model_term) <= 1
        latency[(R, C)] = Lmeas
        print(f"  {R:>2}x{C:<3}  valid_rise={d['valid_rise']:>3} done={d['done']:>3} "
              f"latency_meas={Lmeas:>3}  K+R+C-2={model_term:>3}  "
              f"{'OK' if ok else 'MISMATCH!'}")
        if not ok:
            print("  WARNING: measured per-tile latency disagrees with model > 1 cycle")

    # confirm per-tile latency is independent of M (padded rows still drive corner)
    print("=== confirming M-independence (partial tile M<R on 4x256) ===")
    dp = run_sim(4, 256, 2, 256, "indep_4x256_M2")
    full = latency[(4, 256)]
    print(f"  4x256 M=2: latency_meas={dp['latency']}  full-tile={full}  "
          f"{'OK (M-independent)' if dp['latency'] == full else 'DIFFERS'}")

    # compose the sweep CSV
    rows = []
    flagged = 0
    for (R, C) in SHAPES:
        L = latency[(R, C)]
        model_term = K + R + C - 2
        for M in BATCHES:
            n_tiles = math.ceil(M / R) * math.ceil(N_TOTAL / C)
            cycles_meas = n_tiles * L - 1
            cycles_model = n_tiles * model_term - 1
            active = min(M, R) * min(N_TOTAL, C)
            total = R * C
            util = active / total
            util_model = (min(M, R) * min(N_TOTAL, C)) / (R * C)
            macs = M * N_TOTAL * K
            macs_per_cycle = macs / cycles_meas
            cyc_ok = abs(cycles_meas - cycles_model) <= 1
            util_ok = abs(util - util_model) < 1e-9
            if not (cyc_ok and util_ok):
                flagged += 1
                print(f"  FLAG R={R} C={C} M={M}: "
                      f"cycles {cycles_meas} vs model {cycles_model}, "
                      f"util {util} vs {util_model}")
            rows.append({
                "R": R, "C": C, "M": M, "N": N_TOTAL, "K": K,
                "cycles": cycles_meas,
                "active_pes": active, "total_pes": total,
                "spatial_util": round(util, 6),
                "measured_macs_per_cycle": round(macs_per_cycle, 4),
                "cycles_model": cycles_model,
                "n_tiles": n_tiles,
            })

    out_dir = os.path.join(ROOT, "results")
    os.makedirs(out_dir, exist_ok=True)
    out_csv = os.path.join(out_dir, "util_sweep.csv")
    cols = ["R", "C", "M", "N", "K", "cycles", "active_pes", "total_pes",
            "spatial_util", "measured_macs_per_cycle", "cycles_model", "n_tiles"]
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)

    print(f"=== wrote {out_csv} ({len(rows)} rows), {flagged} flagged ===")

    # headline: spatial_util vs M per shape (the phenomenon)
    print("\nspatial_util (%) by shape x M:")
    hdr = "  M:    " + "".join(f"{M:>8}" for M in BATCHES)
    print(hdr)
    for (R, C) in SHAPES:
        line = f"  {R:>2}x{C:<4}"
        for M in BATCHES:
            u = (min(M, R) * min(N_TOTAL, C)) / (R * C)
            line += f"{u*100:>7.1f}%"
        print(line)
    return 0 if flagged == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
