#!/usr/bin/env bash
# Calibrate the measured per-tile latency against the OS model term K+R+C-2,
# by running a full physical tile (M=R, N=C) for each P=1024 shape.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_E="$ROOT/src/exact_accum"; SRC_R="$ROOT/src/reconfig"
TB="$ROOT/tb/reconfig_tb/gemm_driver_tb.sv"
source /tools/Xilinx/Vivado/2022.1/settings64.sh 2>/dev/null || true

for s in "32 32" "16 64" "8 128" "4 256"; do
    read -r R C <<< "$s"
    case="$ROOT/tb/gen/case_${R}x${C}_full"
    [ -d "$case" ] || python3 "$ROOT/tools/gen_vectors.py" --M "$R" --N "$C" --K 32 --seed 11 --out "$case" >/dev/null
    run="$ROOT/build/m3calib/${R}x${C}"; rm -rf "$run"; mkdir -p "$run"; cp "$case"/block*.txt "$run/"
    pushd "$run" >/dev/null
    xvlog -sv -d R_PARAM=$R -d C_PARAM=$C -d M_PARAM=$R -d N_PARAM=$C -d K_PARAM=32 -d P_PARAM=1024 \
        "$SRC_E/clz.sv" "$SRC_E/convert_fixed2bf16.sv" "$SRC_E/pe_exact_1s.sv" \
        "$SRC_R/os_array_shaped.sv" "$TB" > xvlog.log 2>&1
    xelab gemm_driver_tb -s sim --timescale 1ns/1ps > xelab.log 2>&1
    xsim sim -runall > xsim.log 2>&1
    popd >/dev/null
    model=$((32 + R + C - 2))
    row=$(grep CSVROW "$run/xsim.log")
    echo "$row  | model(K+R+C-2)=$model"
done
