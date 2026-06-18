#!/usr/bin/env bash
# M4 -- per-shape correctness of the runtime serpentine fabric. The SAME
# serpentine_array is elaborated once per shape; only shape_sel changes, so each
# pass exercises the runtime switchbox folding f = C/32 in {1,2,4,8}.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_E="$ROOT/src/exact_accum"; SRC_R="$ROOT/src/reconfig"
TB="$ROOT/tb/reconfig_tb/serpentine_tb.sv"
source /tools/Xilinx/Vivado/2022.1/settings64.sh 2>/dev/null || true

echo "=== M4: runtime serpentine fabric, per-shape correctness ==="
printf "%-12s %-7s %-8s %-s\n" "shape(RxC)" "f" "build" "result"
for s in "32 32" "16 64" "8 128" "4 256"; do
    read -r R C <<< "$s"
    f=$((C/32))
    case="$ROOT/tb/gen/case_${R}x${C}_full"
    [ -d "$case" ] || python3 "$ROOT/tools/gen_vectors.py" --M "$R" --N "$C" --K 32 --seed 11 --out "$case" >/dev/null
    run="$ROOT/build/m4/${R}x${C}"; rm -rf "$run"; mkdir -p "$run"; cp "$case"/block*.txt "$run/"
    pushd "$run" >/dev/null
    ok=1
    xvlog -sv -d R_PARAM=$R -d C_PARAM=$C -d K_PARAM=32 \
        "$SRC_E/clz.sv" "$SRC_E/convert_fixed2bf16.sv" "$SRC_E/pe_exact_1s.sv" \
        "$SRC_R/serpentine_map.sv" "$SRC_R/serpentine_array.sv" "$TB" > xvlog.log 2>&1 || ok=0
    [ $ok -eq 1 ] && { xelab serpentine_tb -s sim --timescale 1ns/1ps > xelab.log 2>&1 || ok=0; }
    [ $ok -eq 1 ] && { xsim sim -runall > xsim.log 2>&1 || ok=0; }
    popd >/dev/null
    if [ $ok -eq 0 ]; then printf "%-12s %-7s %-8s %s\n" "${R}x${C}" "$f" "FAIL" "-"; continue; fi
    out=$(python3 "$ROOT/tools/check_results.py" "$run/out_hex.txt" "$case/golden.txt" --rtol 2e-2 2>&1)
    err=$(echo "$out" | awk '/max  rel error:/{print $4}')
    verdict=$(echo "$out" | grep -qx PASS && echo PASS || echo FAIL)
    printf "%-12s %-7s %-8s %s\n" "${R}x${C}" "$f" "OK" "$verdict (maxrel=$err)"
done
