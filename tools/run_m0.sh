#!/usr/bin/env bash
# M0 -- reproduce the shipped 32x32 E4M3 baseline and check against the golden.
#
# Primary sim per the brief is Verilator, but this environment only has the lab
# reference sim (Vivado xsim). This script uses xsim; if you have Verilator the
# same TB/DUT/checker work with --binary mode (see report notes).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/exact_accum"
TB="$ROOT/tb/reconfig_tb/m0_exact_1s_tb.sv"
DATA="$ROOT/tb/data_sample/MXFP8_E4M3_data"
RUN="$ROOT/build/m0"
GOLDEN="$DATA/result_matrix.txt"

rm -rf "$RUN"
mkdir -p "$RUN"

# Stage the operand+scale blocks where the TB reads them ($fopen uses cwd).
cp "$DATA"/block*.txt "$RUN/"

cd "$RUN"

echo "=== xvlog (compile) ==="
xvlog -sv \
    "$SRC/clz.sv" \
    "$SRC/convert_fixed2bf16.sv" \
    "$SRC/pe_exact_1s.sv" \
    "$SRC/top_exact_systolic_mx.sv" \
    "$TB"

echo "=== xelab (elaborate) ==="
xelab -debug typical systolic_array_MX_tb -s m0_sim --timescale 1ns/1ps

echo "=== xsim (run) ==="
xsim m0_sim -runall

echo "=== check_results.py ==="
python3 "$ROOT/tools/check_results.py" "$RUN/out_hex.txt" "$GOLDEN" --rtol 2e-2
