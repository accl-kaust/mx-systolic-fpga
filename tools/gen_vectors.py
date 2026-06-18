#!/usr/bin/env python3
"""gen_vectors.py -- generate operand/scale block files + golden for any GEMM.

Emits the TB's exact block file format (k binary operand lines + 1 binary scale
line per block) and a golden.txt matrix computed by the bit-accurate mx_ref.

Block-file convention (matches the shipped TB):
  block 0 .. N-1        -> NORTH operands (output columns)
  block N .. N+M-1      -> WEST  operands (output rows)
  result[i][j] = MX dot(west[i], north[j])   (M rows x N cols)

Supports M < N and non-square shapes so later milestones can drive small-batch
decode shapes. Operands are full-range random minifloat bytes; the hardware (and
mx_ref) treat the fields as integers, so any byte is a valid stimulus.

Usage:
    gen_vectors.py --M 32 --N 32 --K 32 --seed 1 --out tb/gen/case_32x32
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
import mx_ref  # noqa: E402


def rand_block(rng, k, bit_width, scale_lo, scale_hi):
    operands = [rng.randrange(0, 1 << bit_width) for _ in range(k)]
    scale = rng.randrange(scale_lo, scale_hi + 1)
    return operands, scale


def write_block_file(path, operands, scale, bit_width):
    with open(path, "w") as f:
        for op in operands:
            f.write(format(op, f"0{bit_width}b") + "\n")
        f.write(format(scale & 0xFF, "08b") + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--M", type=int, required=True, help="output rows (west blocks)")
    ap.add_argument("--N", type=int, required=True, help="output cols (north blocks)")
    ap.add_argument("--K", type=int, default=32, help="contraction / block length")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--exp-width", type=int, default=4)
    ap.add_argument("--man-width", type=int, default=3)
    ap.add_argument("--scale-lo", type=int, default=120)
    ap.add_argument("--scale-hi", type=int, default=134)
    ap.add_argument("--out", required=True, help="output directory")
    args = ap.parse_args()

    bit_width = 1 + args.exp_width + args.man_width
    os.makedirs(args.out, exist_ok=True)
    rng = random.Random(args.seed)

    # NORTH blocks 0..N-1 (columns)
    north_ops, north_scale = [], []
    for j in range(args.N):
        ops, sc = rand_block(rng, args.K, bit_width, args.scale_lo, args.scale_hi)
        north_ops.append(ops)
        north_scale.append(sc)
        write_block_file(os.path.join(args.out, f"block{j}_mx.txt"),
                         ops, sc, bit_width)

    # WEST blocks N..N+M-1 (rows)
    west_ops, west_scale = [], []
    for i in range(args.M):
        ops, sc = rand_block(rng, args.K, bit_width, args.scale_lo, args.scale_hi)
        west_ops.append(ops)
        west_scale.append(sc)
        write_block_file(os.path.join(args.out, f"block{args.N + i}_mx.txt"),
                         ops, sc, bit_width)

    # golden M x N via bit-accurate reference
    golden_path = os.path.join(args.out, "golden.txt")
    with open(golden_path, "w") as f:
        for i in range(args.M):
            vals = []
            for j in range(args.N):
                word = mx_ref.mx_dot_to_bf16(
                    west_ops[i], north_ops[j], west_scale[i], north_scale[j],
                    args.exp_width, args.man_width, args.K)
                vals.append(mx_ref.bf16_to_float(word))
            f.write(" ".join(repr(v) for v in vals) + "\n")

    print(f"wrote {args.N} north + {args.M} west blocks (K={args.K}, "
          f"E{args.exp_width}M{args.man_width}) and golden.txt to {args.out}")
    print(f"golden matrix: {args.M} rows x {args.N} cols")


if __name__ == "__main__":
    sys.exit(main())
