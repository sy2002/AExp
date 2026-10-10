#!/usr/bin/env bash
# The local gate before a synthesis: the two Python checkers, the nvc analysis
# of all CORE VHDL, and every testbench that finishes in minutes. The long
# floppy suites (the four splice cells, the write matrix, the write mutants)
# and the full scandoubler matrix are in run_long.sh. The floppy regression in
# quick mode includes the paula_floppy.v golden diff
# (CORE/sim/minimig/run_paula_obs.sh); the scandoubler step runs the quick
# subset of CORE/sim/video/run_scandoubler.sh.
#
# Usage: CORE/sim/run_all.sh [workdir]
#   workdir defaults to a fresh temporary directory; every step works in its
#   own subdirectory and leaves its log there. JOBS=<n> lets the floppy
#   regression and the scandoubler bench run their cells in parallel.
# Runtime: about 6 minutes (see doc/developers/tools.md).
# Exit status: the number of failed steps (0 = all passed).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
BASE="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-sim-all.XXXXXX")}"
mkdir -p "$BASE" || exit 2
BASE="$(cd "$BASE" && pwd)"
echo "work dir: $BASE"
export JOBS="${JOBS:-1}"

fails=0
# step <name> <command...>: runs the command with its output in <name>.log
step() {
  local name="$1"; shift
  local log="$BASE/$name.log" t0 t1 rc
  t0=$(date +%s)
  ( cd "$BASE" && "$@" ) > "$log" 2>&1
  rc=$?
  t1=$(date +%s)
  if [ "$rc" -eq 0 ]; then
    printf 'PASS  %-22s %4ss\n' "$name" "$((t1 - t0))"
  else
    printf 'FAIL  %-22s %4ss  (exit %s, log: %s)\n' "$name" "$((t1 - t0))" "$rc" "$log"
    fails=$((fails + 1))
  fi
}

step check_osm_menu  python3 -B "$ROOT/tools/check_osm_menu.py"
step check_firmware  python3 -B "$ROOT/tools/check_firmware.py"
step nvc_chain       "$HERE/run_nvc_chain.sh" "$BASE/nvc_chain"
step audio           "$HERE/audio/run.sh" "$BASE/audio"
step keyboard        "$HERE/keyboard/run.sh" "$BASE/keyboard"
step video           "$HERE/video/run.sh" "$BASE/video"
step scandoubler     "$HERE/video/run_scandoubler.sh" "$BASE/scandoubler" quick
step misc            "$HERE/misc/run.sh" "$BASE/misc"
step cia_inmode      "$HERE/minimig/run_tb_cia_inmode.sh" "$BASE/cia_inmode"
step blitter_freeze  env MUTANTS=0 "$HERE/minimig/run_tb_blitter_freeze.sh" "$BASE/blitter_freeze"
step fdd_quick       "$HERE/floppy/run_fdd_regression.sh" "$BASE/fdd_quick" quick

echo "-------------------------------------------"
if [ "$fails" -eq 0 ]; then
  echo "RUN_ALL: all steps PASS"
else
  echo "RUN_ALL: $fails step(s) FAILED"
fi
exit "$fails"
