#!/usr/bin/env bash
# Regression suite of the floppy stack: every read-side bench of the
# Hardware Floppy front end and engine, the multi-drive ownership bench,
# the DSKBYTR observation-tap bench and the paula_floppy.v golden diff.
#
# Usage: CORE/sim/floppy/run_fdd_regression.sh [workdir] [quick|full]
#   full   every cell (default); the four tb_fdd_splice cells take
#          10-15 min each, everything else finishes in seconds
#   quick  skips the tb_fdd_splice cells
#   JOBS=n runs n cells in parallel (default 1)
#
# workdir must be an existing directory or a path containing a slash (for
# example ./work); any other argument is rejected, so a typo cannot become a
# work directory. Without one, a fresh mktemp directory is used.
#
# At the start the runner copies the HDL and the benches into <workdir>/src,
# and every cell analyses that copy, so all cells of one run test the same
# tree even if a file is edited while the suite runs; the paula_floppy.v
# golden diff runs first, within seconds of the copy. At the end a source
# that no longer matches its copy fails the run (CHANGED): the results then
# describe the tree as it was at the start, not the current one. Every cell
# gets its own subdirectory with its own nvc library and runs from inside
# it, because nvc -r writes into the invocation directory and concurrent
# elaborations of one top with different generics collide in a shared
# library. A cell passes only if it elaborates and runs, prints its pass
# line, and reports no failure, no error and no stale analysed unit.
# Exit status: the number of failed cells (0 = all pass).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

W=""
MODE="full"
usage() { echo "usage: $0 [workdir] [quick|full]" >&2; exit 2; }
for arg in "$@"; do
  case "$arg" in
    quick|full) MODE="$arg" ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
    */*) [ -z "$W" ] || usage; W="$arg" ;;
    *) if [ -d "$arg" ] && [ -z "$W" ]; then W="$arg"
       else echo "unknown argument: $arg" >&2; usage; fi ;;
  esac
done
if [ -z "$W" ]; then
  W="$(mktemp -d "${TMPDIR:-/tmp}/aexp-fdd-reg.XXXXXX")" || exit 2
fi
mkdir -p "$W" || exit 2
W="$(cd "$W" && pwd)"
JOBS="${JOBS:-1}"

echo "work dir: $W   mode: $MODE   jobs: $JOBS"
# A reused work dir must not show the previous run's results.
rm -rf "$W/logs" "$W/cells" "$W/src"
mkdir -p "$W/logs" "$W/cells" "$W/src"

# the sources every cell analyses, copied once into $W/src; src_orig maps a
# copy back to its file in the tree
PF="$ROOT/CORE/vhdl/physical_fdd"
SRC_FILES="physical_fdd_pkg.vhd physical_fdd_inputs.vhd physical_fdd_mfm_gaps.vhd
  physical_fdd_mfm_quantise.vhd physical_fdd_bits.vhd physical_fdd_wfifo.vhd
  physical_fdd_writer.vhd physical_fdd_diag.vhd physical_fdd_top.vhd
  adf_track_engine.vhd tb_physical_fdd_top.vhd tb_fdd_margin.vhd
  tb_fdd_diag_ro.vhd tb_fdd_dpll.vhd tb_fdd_splice.vhd tb_engine_paula.vhd
  tb_adf_multidrive.vhd tb_hwf_obs_tap.vhd"
src_orig() {
  case "$1" in
    physical_fdd_*) echo "$PF/$1" ;;
    adf_track_engine.vhd) echo "$ROOT/CORE/vhdl/$1" ;;
    *) echo "$HERE/$1" ;;
  esac
}
for f in $SRC_FILES; do
  cp "$(src_orig "$f")" "$W/src/$f" || { echo "cannot copy $f"; exit 2; }
done

# run_cell "<tag>|<unit>|<generics>" - prints exactly one result line
run_cell() {
  local tag unit gens rest cdir log PF NVC
  tag="${1%%|*}"; rest="${1#*|}"
  unit="${rest%%|*}"; gens="${rest#*|}"
  cdir="$W/cells/$tag"
  log="$W/logs/$tag.log"
  mkdir -p "$cdir"

  if [ "$unit" = "@paula_obs" ]; then
    local runner="$ROOT/CORE/sim/minimig/run_paula_obs.sh"
    if [ ! -x "$runner" ]; then
      echo "FAIL  $tag   (missing $runner)"
      return 1
    fi
    if "$runner" "$cdir" > "$log" 2>&1 \
       && grep -q "TB_PAULA_OBS: ALL CHECKS PASS" "$log"; then
      echo "PASS  $tag"
      return 0
    fi
    echo "FAIL  $tag   ($(grep -m1 -iE 'fail|error' "$log" | cut -c1-100))"
    return 1
  fi

  NVC="nvc --std=2008 --work=work:$cdir/work -L $cdir"
  # $SRC_FILES is a word list in dependency order and is split on purpose
  # shellcheck disable=SC2086
  if ! ( cd "$W/src" && $NVC -a $SRC_FILES ) > "$log" 2>&1; then
    echo "FAIL  $tag   (analysis failed: $(grep -m1 -E '\*\* Error' "$log" | cut -c1-90))"
    return 1
  fi
  # $gens is a whitespace-separated generic list and is split on purpose
  # shellcheck disable=SC2086
  if ( cd "$cdir" && $NVC -e "$unit" $gens && $NVC -r "$unit" ) >> "$log" 2>&1; then
    if grep -q "older than its source file" "$log"; then
      echo "STALE $tag   (analysed unit is older than its source - re-run)"
      return 1
    fi
    if ! grep -qiE "Failure|\*\* Error" "$log" \
       && grep -qE "ALL PASS|ALL TESTS PASSED|ALL CHECKS PASS" "$log"; then
      echo "PASS  $tag"
      return 0
    fi
  fi
  echo "FAIL  $tag   ($(grep -m1 -iE 'Failure|\*\* Error' "$log" | cut -c1-110))"
  return 1
}
export -f run_cell
export ROOT HERE W SRC_FILES

cells=(
  # the tap bench and the golden diff guard the DSKBYTR observation surface
  # that the Copylock timing loop reads: a phantom or suppressed FIFO pop, or
  # a paula_floppy.v that is not byte-identical with the surface gated off,
  # breaks protected originals. The golden diff reads the Minimig submodule
  # directly, so it runs first, right after the sources were copied.
  "paula_obs|@paula_obs|"
  "top_dpll|tb_physical_fdd_top|"
  "top_legacy|tb_physical_fdd_top|-gG_LEGACY=true"
  "margin|tb_fdd_margin|"
  "diag_ro|tb_fdd_diag_ro|"
  "dpll_dpll|tb_fdd_dpll|"
  "dpll_legacy|tb_fdd_dpll|-gG_LEGACY=true"
)
if [ "$MODE" = full ]; then
  cells+=(
    "splice_ff|tb_fdd_splice|"
    "splice_fl|tb_fdd_splice|-gG_LEGACY=true"
    "splice_xf|tb_fdd_splice|-gG_FIXED=true"
    "splice_xl|tb_fdd_splice|-gG_FIXED=true -gG_LEGACY=true"
  )
fi
cells+=(
  "engine_paula|tb_engine_paula|"
  "multidrive|tb_adf_multidrive|"
  "obs_tap|tb_hwf_obs_tap|"
)

printf '%s\n' "${cells[@]}" \
  | xargs -P "$JOBS" -I{} bash -c 'run_cell "$1"' _ {} \
  | tee "$W/logs/results.txt"

total=${#cells[@]}
passed=$(grep -c '^PASS' "$W/logs/results.txt")
reported=$(grep -cE '^(PASS|FAIL|STALE)' "$W/logs/results.txt")
fails=$((total - passed))
# a source edited during the run: the cells tested the copy, not the tree
for f in $SRC_FILES; do
  if ! cmp -s "$W/src/$f" "$(src_orig "$f")"; then
    echo "CHANGED $f was edited during the run; the results describe $W/src"
    fails=$((fails + 1))
  fi
done
echo "-------------------------------------------"
if [ "$reported" -ne "$total" ]; then
  echo "$((total - reported)) cell(s) produced no result line"
fi
if [ "$fails" -eq 0 ]; then
  echo "FDD REGRESSION ($MODE): all $total cells PASS"
else
  echo "FDD REGRESSION ($MODE): $fails failure(s) in $total cell(s)"
fi
exit "$fails"
