#!/usr/bin/env python3
"""mx_ref.py -- bit-accurate Python reference for the MX systolic array.

This mirrors the RTL EXACTLY (src/exact_accum):
  * mxfp8_mac_pe  -- minifloat decode, integer magnitude multiply, arithmetic
    left-shift by (e0+e1-nrm0-nrm1), and an EXACT integer accumulation of the
    K=32 block (no FP32 anywhere).
  * conv_fixed2bf16_adjusted -- CLZ normalize, round-to-nearest-even, and the
    exact in_bias / exponent expression, producing a 16-bit bf16 word.

Because the accumulation is exact integer addition it is associative, so the
reduction order does not matter -- the result is identical to the RTL's
time-ordered accumulation.

The MX scale is applied only at the output, inside the conversion (one
(scale_north, scale_west) pair per output PE), exactly like the hardware.

Defaults are MXFP8 E4M3 (exp_width=4, man_width=3) with block length k=32.
"""

import argparse
import math
import os
import struct
import sys


# ---------------------------------------------------------------------------
# minifloat field decode
# ---------------------------------------------------------------------------
def decode_fields(byte, exp_width, man_width):
    """Return (sign, exp, man, nrm, man_ext) for an exp/man minifloat byte."""
    bit_width = 1 + exp_width + man_width
    byte &= (1 << bit_width) - 1
    sign = (byte >> (bit_width - 1)) & 1
    exp = (byte >> man_width) & ((1 << exp_width) - 1)
    man = byte & ((1 << man_width) - 1)
    nrm = 1 if exp != 0 else 0
    # man_ext = {|exp, man}  -> implicit bit is (exp != 0)
    man_ext = (nrm << man_width) | man
    return sign, exp, man, nrm, man_ext


def pe_product_shifted(byte_a, byte_b, exp_width, man_width):
    """One PE multiply: returns the signed integer prd_shifted (pre-accum)."""
    sa, ea, _, na, ma = decode_fields(byte_a, exp_width, man_width)
    sb, eb, _, nb, mb = decode_fields(byte_b, exp_width, man_width)

    # signed mantissas, magnitude multiply, re-apply sign (matches mul_i8 logic)
    sma = -ma if sa else ma
    smb = -mb if sb else mb
    prd_sign = (sma < 0) ^ (smb < 0)
    u_prd = abs(sma) * abs(smb)
    prd_fi = -u_prd if prd_sign else u_prd

    # arithmetic left shift by (ea+eb-na-nb); always >= 0 for valid minifloats
    shift = ea + eb - na - nb
    return prd_fi << shift


def block_dot(west_bytes, north_bytes, exp_width=4, man_width=3):
    """Exact integer accumulation of one K-length MX block (acc_reg value)."""
    assert len(west_bytes) == len(north_bytes)
    acc = 0
    for a, b in zip(west_bytes, north_bytes):
        acc += pe_product_shifted(a, b, exp_width, man_width)
    return acc


# ---------------------------------------------------------------------------
# fixed -> bf16 conversion (mirrors conv_fixed2bf16_adjusted)
# ---------------------------------------------------------------------------
def conv_fixed2bf16(acc, scale_north, scale_west, exp_width=4, man_width=3, k=32):
    """Convert the exact accumulator to a 16-bit bf16 word, applying scales."""
    prd_width = 2 * ((1 << exp_width) + man_width)
    W = prd_width + (k - 1).bit_length()          # = prd_width + $clog2(k)
    exp_bias = 127

    if acc == 0:
        return 0

    sign = 1 if acc < 0 else 0
    u = -acc if acc < 0 else acc
    u &= (1 << W) - 1                              # W-bit magnitude

    # count leading zeros within W bits, align so MSB sits at bit W-1
    lz = W - u.bit_length()
    aligned = u << lz

    # rounding bits (indices mirror the RTL: bit_width-1-{1,7,8,9})
    R = (aligned >> (W - 9)) & 1                   # round bit
    S = 1 if (aligned & ((1 << (W - 9)) - 1)) else 0   # sticky: bits [W-10:0]
    guard = (aligned >> (W - 8)) & 1               # mantissa LSB
    rnd_bit = R & (guard | S)

    man7 = (aligned >> (W - 8)) & 0x7F             # bits [W-2:W-8]
    man_ofl = man7 + rnd_bit
    rnd_ofl = (man_ofl >> 7) & 1
    bf16_man = man_ofl & 0x7F

    in_bias = prd_width - 4 + (2 * (127 - ((1 << exp_width) - 1))
                              - scale_north - scale_west)
    bf16_exp = ((W - 1) - lz + rnd_ofl + exp_bias - in_bias) & 0xFF

    return (sign << 15) | (bf16_exp << 7) | bf16_man


# ---------------------------------------------------------------------------
# bf16 decode (for verification / golden emission)
# ---------------------------------------------------------------------------
def bf16_to_float(word):
    """Decode a 16-bit bf16 (top half of an IEEE-754 float32) to float."""
    bits32 = (word & 0xFFFF) << 16
    return struct.unpack(">f", struct.pack(">I", bits32))[0]


def mx_dot_to_bf16(west_bytes, north_bytes, scale_west, scale_north,
                   exp_width=4, man_width=3, k=32):
    """Full single-PE pipeline: block dot -> conv -> bf16 word."""
    acc = block_dot(west_bytes, north_bytes, exp_width, man_width)
    return conv_fixed2bf16(acc, scale_north, scale_west, exp_width, man_width, k)


# ---------------------------------------------------------------------------
# block-file IO (TB format: k binary operand lines + 1 binary scale line)
# ---------------------------------------------------------------------------
def read_block_file(path, k):
    operands = []
    scale = 0
    with open(path) as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    for i in range(k):
        operands.append(int(lines[i], 2))
    scale = int(lines[k], 2)
    return operands, scale


def compute_matrix_from_dir(data_dir, rows, cols, k=32,
                            exp_width=4, man_width=3):
    """Reproduce the RTL output matrix from a directory of block*.txt files.

    Convention (matches the shipped TB): block 0..cols-1 are NORTH operands
    (output columns); block cols..cols+rows-1 are WEST operands (output rows).
    result[i][j] = MX dot(west[i], north[j]).
    """
    north_ops, north_scale = [], []
    for j in range(cols):
        ops, sc = read_block_file(os.path.join(data_dir, f"block{j}_mx.txt"), k)
        north_ops.append(ops)
        north_scale.append(sc)
    west_ops, west_scale = [], []
    for i in range(rows):
        ops, sc = read_block_file(
            os.path.join(data_dir, f"block{cols + i}_mx.txt"), k)
        west_ops.append(ops)
        west_scale.append(sc)

    matrix = []
    for i in range(rows):
        row = []
        for j in range(cols):
            word = mx_dot_to_bf16(west_ops[i], north_ops[j],
                                  west_scale[i], north_scale[j],
                                  exp_width, man_width, k)
            row.append(bf16_to_float(word))
        matrix.append(row)
    return matrix


# ---------------------------------------------------------------------------
# CLI: cross-check against the shipped golden
# ---------------------------------------------------------------------------
def _main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir",
                    default=os.path.join(os.path.dirname(__file__), "..",
                                         "tb", "data_sample",
                                         "MXFP8_E4M3_data"))
    ap.add_argument("--rows", type=int, default=32)
    ap.add_argument("--cols", type=int, default=32)
    ap.add_argument("--k", type=int, default=32)
    ap.add_argument("--exp-width", type=int, default=4)
    ap.add_argument("--man-width", type=int, default=3)
    ap.add_argument("--golden", default=None,
                    help="golden matrix file to compare against "
                         "(default: <data-dir>/result_matrix.txt)")
    ap.add_argument("--rtol", type=float, default=2e-2)
    ap.add_argument("--atol", type=float, default=1e-3)
    args = ap.parse_args()

    golden_path = args.golden or os.path.join(args.data_dir,
                                              "result_matrix.txt")
    mat = compute_matrix_from_dir(args.data_dir, args.rows, args.cols,
                                  args.k, args.exp_width, args.man_width)

    with open(golden_path) as f:
        golden = [[float(t) for t in ln.split()] for ln in f if ln.strip()]

    max_rel = 0.0
    sum_rel = 0.0
    n = 0
    worst = None
    for i in range(args.rows):
        for j in range(args.cols):
            m = mat[i][j]
            g = golden[i][j]
            ab = abs(m - g)
            rel = ab / abs(g) if abs(g) > 1e-12 else (0.0 if ab <= args.atol else float("inf"))
            if rel > max_rel:
                max_rel = rel
                worst = (i, j, m, g)
            sum_rel += rel if rel != float("inf") else 0.0
            n += 1

    print(f"reference matrix {args.rows}x{args.cols}, k={args.k}, "
          f"E{args.exp_width}M{args.man_width}")
    print(f"max  rel error vs golden: {max_rel:.6e}  worst={worst}")
    print(f"mean rel error vs golden: {sum_rel / n:.6e}")
    ok = max_rel <= args.rtol
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(_main())
