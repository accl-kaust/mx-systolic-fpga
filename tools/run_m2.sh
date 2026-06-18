#!/usr/bin/env bash
# M2 -- build the P=1024 pool in four compile-time logical shapes and check
# per-shape correctness. Shapes: 32x32, 16x64, 8x128, 4x256 (R*C = 1024).
#
# For each shape we generate a full GEMM (M=R, N=C, K=32) plus a padded case
# (M<R, N<C) to exercise the driver's zero-padding, then verify against the
# bit-accurate golden produced by mx_ref via gen_vectors.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_E="$ROOT/src/exact_accum"
SRC_R="$ROOT/src/reconfig"
TB="$ROOT/tb/reconfig_tb/gemm_driver_tb.sv"
source /tools/Xilinx/Vivado/2022.1/settings64.sh 2>/dev/null || true

# shape list: "R C"
SHAPES=("32 32" "16 64" "8 128" "4 256")
SEED=11

# optional padded sub-cases as "R C M N" (subset, for padding validation)
PADDED=("32 32 4 4" "16 64 8 40" "4 256 4 100")

run_one() {  # args: R C M N tag
    local R=$1 C=$2 M=$3 N=$4 tag=$5
    local case="$ROOT/tb/gen/case_${tag}"
    local run="$ROOT/build/m2/${tag}"
    rm -rf "$run"; mkdir -p "$run"

    python3 "$ROOT/tools/gen_vectors.py" --M "$M" --N "$N" --K 32 \
        --seed "$SEED" --out "$case" >/dev/null

    cp "$case"/block*.txt "$run/"
    pushd "$run" >/dev/null

    local build_ok=1 err="-"
    xvlog -sv -d R_PARAM=$R -d C_PARAM=$C -d M_PARAM=$M -d N_PARAM=$N \
        -d K_PARAM=32 -d P_PARAM=1024 \
        "$SRC_E/clz.sv" "$SRC_E/convert_fixed2bf16.sv" "$SRC_E/pe_exact_1s.sv" \
        "$SRC_R/os_array_shaped.sv" "$TB" > xvlog.log 2>&1 || build_ok=0
    if [ $build_ok -eq 1 ]; then
        # NOTE: no '-debug typical' -- full signal visibility makes 1024-PE
        # elaboration pathologically slow (30+ min vs ~6 s). Default elaboration
        # is optimized and sufficient since pass/fail is checked from the dump.
        xelab gemm_driver_tb -s sim --timescale 1ns/1ps \
            > xelab.log 2>&1 || build_ok=0
    fi
    if [ $build_ok -eq 1 ]; then
        xsim sim -runall > xsim.log 2>&1 || build_ok=0
    fi
    popd >/dev/null

    if [ $build_ok -eq 0 ]; then
        printf "%-14s %-9s %-6s\n" "$tag" "BUILD_FAIL" "-"
        return
    fi

    local out
    out=$(python3 "$ROOT/tools/check_results.py" "$run/out_hex.txt" \
            "$case/golden.txt" --rtol 2e-2 2>&1)
    err=$(echo "$out" | awk '/max  rel error:/{print $4}')
    local verdict
    verdict=$(echo "$out" | grep -qx PASS && echo PASS || echo FAIL)
    printf "%-14s %-9s %-6s\n" "$tag" "OK" "$verdict (maxrel=$err)"
}

echo "=== M2: per-shape correctness (P=1024) ==="
printf "%-14s %-9s %-6s\n" "shape(R x C)" "build" "result"
echo "--- full shapes (M=R, N=C) ---"
for s in "${SHAPES[@]}"; do
    read -r R C <<< "$s"
    run_one "$R" "$C" "$R" "$C" "${R}x${C}_full"
done
echo "--- padded shapes (M<R, N<C) ---"
for s in "${PADDED[@]}"; do
    read -r R C M N <<< "$s"
    run_one "$R" "$C" "$M" "$N" "${R}x${C}_pad_${M}x${N}"
done
