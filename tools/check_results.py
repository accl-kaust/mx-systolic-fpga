#!/usr/bin/env python3
"""check_results.py -- M0 golden check for the MX systolic array.

Reads the SV-dumped hex results (one bf16 value per line, 4 hex digits each),
decodes each bf16 -> float32, reads the golden reference matrix
(space-separated decimal floats, N rows), and compares element-wise with a
relative tolerance. Prints PASS / FAIL plus max/mean error statistics.

Pass/fail is computed purely in Python from the dumped hex -- it does NOT rely
on the simulator's $bitstoshortreal, so it is simulator-agnostic.

Usage:
    check_results.py <out_hex.txt> <golden_matrix.txt> [--rtol 2e-2] [--atol 1e-3]
"""

import argparse
import struct
import sys


def bf16_hex_to_float(hexstr):
    """Decode a bfloat16 (top 16 bits of an IEEE-754 float32) to a Python float."""
    bits16 = int(hexstr, 16) & 0xFFFF
    # bfloat16 -> float32 by left-padding the mantissa with zeros.
    bits32 = bits16 << 16
    return struct.unpack(">f", struct.pack(">I", bits32))[0]


def read_hex_results(path):
    vals = []
    with open(path) as f:
        for line in f:
            tok = line.strip()
            if not tok:
                continue
            vals.append(bf16_hex_to_float(tok))
    return vals


def read_golden(path):
    rows = []
    with open(path) as f:
        for line in f:
            toks = line.split()
            if not toks:
                continue
            rows.append([float(t) for t in toks])
    # flatten row-major
    flat = [v for row in rows for v in row]
    return flat, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hex_file")
    ap.add_argument("golden_file")
    ap.add_argument("--rtol", type=float, default=2e-2,
                    help="relative tolerance (default 2e-2, bf16 rounding)")
    ap.add_argument("--atol", type=float, default=1e-3,
                    help="absolute tolerance floor for near-zero values")
    args = ap.parse_args()

    measured = read_hex_results(args.hex_file)
    golden, rows = read_golden(args.golden_file)

    if len(measured) != len(golden):
        print(f"FAIL: count mismatch -- measured {len(measured)} values, "
              f"golden {len(golden)} values")
        return 1

    n = len(measured)
    max_rel = 0.0
    sum_rel = 0.0
    max_abs = 0.0
    worst_idx = -1
    fails = []
    for i, (m, g) in enumerate(zip(measured, golden)):
        abs_err = abs(m - g)
        denom = abs(g)
        rel_err = abs_err / denom if denom > 1e-12 else (0.0 if abs_err <= args.atol else float("inf"))
        if rel_err > max_rel:
            max_rel = rel_err
            worst_idx = i
        sum_rel += rel_err if rel_err != float("inf") else 0.0
        max_abs = max(max_abs, abs_err)
        # element passes if within rtol OR within atol (handles near-zero)
        if abs_err > args.atol and rel_err > args.rtol:
            fails.append((i, m, g, rel_err, abs_err))

    mean_rel = sum_rel / n
    ncol = len(rows[0]) if rows else 0

    print(f"elements: {n}  (matrix {len(rows)}x{ncol})")
    print(f"max  rel error: {max_rel:.6e}  (index {worst_idx})")
    print(f"mean rel error: {mean_rel:.6e}")
    print(f"max  abs error: {max_abs:.6e}")
    print(f"tolerance: rtol={args.rtol}  atol={args.atol}")

    if fails:
        print(f"FAIL: {len(fails)} element(s) exceed tolerance")
        for i, m, g, rel, ab in fails[:10]:
            r = i // ncol if ncol else i
            c = i % ncol if ncol else 0
            print(f"  [{r},{c}] measured={m:.6g} golden={g:.6g} "
                  f"rel={rel:.4g} abs={ab:.4g}")
        if len(fails) > 10:
            print(f"  ... and {len(fails) - 10} more")
        return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
