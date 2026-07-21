#!/usr/bin/env bash
# Build the MEGA65 bitstreams of all four boards (R3, R4, R5, R6) one after
# another in Vivado batch mode - made for overnight runs:
#
#   cd CORE
#   source /tools/Xilinx/Vivado/2022.2/settings64.sh   # or wherever Vivado is
#   nohup ./build_all.sh > build_all.out 2>&1 &
#
# Optional: pass a subset of boards (./build_all.sh R4 R6). JOBS=<n> sets the
# number of parallel Vivado jobs per run (default 4).

set -u
cd "$(dirname "$0")"

if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: vivado is not on the PATH - source settings64.sh first." >&2
    exit 1
fi

# The QNICE assembler binaries live in a folder that macOS and the Ubuntu VM
# share, so whichever OS compiled them last wins. Rebuild them for this OS
# and assemble the firmware once: a firmware problem aborts the run here,
# before the first multi-hour synthesis (synth_pre.tcl re-runs make_rom.sh
# during synthesis anyway).
./make_qasm.sh || exit 1
( cd m2m-rom && ./make_rom.sh ) || exit 1

if [ "$#" -gt 0 ]; then boards=("$@"); else boards=(R3 R4 R5 R6); fi
jobs="${JOBS:-4}"
failed=0

for board in "${boards[@]}"; do
    echo "=== ${board}: build started $(date) ==="
    vivado -mode batch -notrace -source build_bitstream.tcl \
           -log "build_${board}.log" -journal "build_${board}.jou" \
           -tclargs "${board}" "${jobs}" || failed=1
done

echo
echo "=== Summary $(date) ==="
for board in "${boards[@]}"; do
    grep -h "^RESULT ${board}" "build_${board}.log" 2>/dev/null \
        || echo "RESULT ${board} FAILED - see build_${board}.log"
done
exit "${failed}"
