#!/usr/bin/env bash
# The long simulation suites, for changes to the floppy stack or the analog
# video path and before a release: the full floppy regression (including the
# four splice cells), the full write matrix with the independent twin, the
# write mutant matrix, the Minimig beam-counter golden diff, and the full
# scandoubler matrix (CORE/sim/video/run_scandoubler.sh).
#
# Usage: CORE/sim/run_long.sh [workdir]
#   workdir defaults to a fresh temporary directory; every suite works in its
#   own subdirectory and leaves its log there. Set JOBS to the number of
#   physical cores: the suites are compute-bound and their cells independent.
# Runtime: about 4.25 hours with JOBS=1, a little over an hour with JOBS=8
# (see doc/developers/tools.md).
# Exit status: the number of failed suites (0 = all passed).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
BASE="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-sim-long.XXXXXX")}"
mkdir -p "$BASE" || exit 2
BASE="$(cd "$BASE" && pwd)"
echo "work dir: $BASE   JOBS=${JOBS:-1}"
export JOBS="${JOBS:-1}"

fails=0
# suite <name> <command...>: runs the command with its output in <name>.log
suite() {
  local name="$1"; shift
  local log="$BASE/$name.log" t0 t1 rc
  t0=$(date +%s)
  ( cd "$BASE" && "$@" ) > "$log" 2>&1
  rc=$?
  t1=$(date +%s)
  if [ "$rc" -eq 0 ]; then
    printf 'PASS  %-18s %6ss\n' "$name" "$((t1 - t0))"
  else
    printf 'FAIL  %-18s %6ss  (exit %s, log: %s)\n' "$name" "$((t1 - t0))" "$rc" "$log"
    fails=$((fails + 1))
  fi
}

suite fdd_regression  "$HERE/floppy/run_fdd_regression.sh" "$BASE/fdd_regression" full
suite write_matrix    "$HERE/floppy/run_write_matrix.sh" "$BASE/write_matrix" full
suite write_mutants   "$HERE/floppy/run_write_mutants.sh" "$BASE/write_mutants"
suite beamcounter     "$HERE/minimig/run_tb_beamcounter_readback.sh" "$BASE/beamcounter"
suite scandoubler     "$HERE/video/run_scandoubler.sh" "$BASE/scandoubler" full

echo "-------------------------------------------"
if [ "$fails" -eq 0 ]; then
  echo "RUN_LONG: all suites PASS"
else
  echo "RUN_LONG: $fails suite(s) FAILED"
fi
exit "$fails"
