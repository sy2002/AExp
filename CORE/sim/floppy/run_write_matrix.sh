#!/usr/bin/env bash
# Write-datapath matrix: runs tb_fdd_write.vhd over its scenario cells and
# cross-checks every flux dump against the independent Python twin
# models/td_write_check.py. The scenarios are listed in the header of
# tb_fdd_write.vhd; doc/developers/hardware-floppy.md describes what they
# protect.
#
# Usage: CORE/sim/floppy/run_write_matrix.sh [workdir] [quick|full|fullonly]
#   quick     the short-DMA mechanics scenarios S3, S4, S5, S9, S10 and S11
#             in both separator arms (42 cells, the default)
#   full      quick plus the full-track block: S1 over RPM x separator x
#             framing, the S1p precomp cases, S2, S2x, the S6 tail sweep and
#             the S12 interlock (77 cells)
#   fullonly  the full-track block alone (35 cells)
#
# workdir must be an existing directory or a path containing a slash (for
# example ./work); any other argument is rejected, so a typo cannot become a
# work directory. Without one, a fresh mktemp directory is used; a reused one
# has its logs, sources and cell directories wiped first, so no result of an
# earlier run can be mistaken for this one.
#
# At the start the runner copies the HDL, the bench and the twin into
# <workdir>/src; every cell analyses that copy and the twin runs from it, so
# all cells of one run test the same tree even if a file is edited during
# the run. At the end a source that no longer matches its copy fails the run
# (CHANGED). Every cell analyses into its own subdirectory and runs there:
# nvc -r writes the flux dump into the current directory, and concurrent
# elaborations of one top with different generics would collide in a shared
# library. A cell without a result line (a child that never ran) counts as
# failed.
#
# Environment:
#   JOBS=<n>        run n cells at a time (default 1). The cells are
#                   compute-bound, so use at most the number of physical cores.
#   CELLS=<regex>   run only the cells whose tag matches (grep -E), e.g.
#                   CELLS='^s3_' for the write-protect cells.
#
# Runtime: about 74 s per cell on average (S1 about 150 s, S3 about 60 s);
# full is about 95 minutes serially and about 25 minutes with JOBS=8.
# Exit status: the number of failed cells and failed twin cross-checks.
# The mutant matrix, which proves that these checks can fail, is
# run_write_mutants.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PF="$ROOT/CORE/vhdl/physical_fdd"

W=""
MODE="quick"
usage() { echo "usage: $0 [workdir] [quick|full|fullonly]" >&2; exit 2; }
for a in "$@"; do
  case "$a" in
    quick|full|fullonly) MODE="$a" ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
    */*) [ -z "$W" ] || usage; W="$a" ;;
    *) if [ -d "$a" ] && [ -z "$W" ]; then W="$a"
       else echo "unknown argument: $a" >&2; usage; fi ;;
  esac
done
if [ -z "$W" ]; then
  W="$(mktemp -d "${TMPDIR:-/tmp}/aexp-write-matrix.XXXXXX")" || exit 2
fi
mkdir -p "$W" || exit 2
W="$(cd "$W" && pwd)"
JOBS="${JOBS:-1}"
CELLS="${CELLS:-}"
echo "work dir: $W   mode: $MODE   jobs: $JOBS"
rm -rf "$W/logs" "$W/cells" "$W/preflight" "$W/src" "$W/summary.txt"
mkdir -p "$W/logs" "$W/cells" "$W/src/models"

# the sources, copied once into $W/src in dependency order; src_orig maps a
# copy back to its file in the tree
SRC_HDL="physical_fdd_pkg.vhd physical_fdd_inputs.vhd physical_fdd_mfm_gaps.vhd
  physical_fdd_mfm_quantise.vhd physical_fdd_bits.vhd physical_fdd_wfifo.vhd
  physical_fdd_writer.vhd physical_fdd_diag.vhd physical_fdd_top.vhd
  adf_track_engine.vhd tb_fdd_write.vhd"
SRC_ALL="$SRC_HDL models/td_write_check.py models/td_check.py"
src_orig() {
  case "$1" in
    physical_fdd_*) echo "$PF/$1" ;;
    adf_track_engine.vhd) echo "$ROOT/CORE/vhdl/$1" ;;
    *) echo "$HERE/$1" ;;
  esac
}
for f in $SRC_ALL; do
  cp "$(src_orig "$f")" "$W/src/$f" || { echo "cannot copy $f"; exit 2; }
done

# analyze <dir>: the copied front end, engine and bench, into <dir>
analyze() {
  local d="$1"
  # $SRC_HDL is a word list and is split on purpose
  # shellcheck disable=SC2086
  ( cd "$W/src" && nvc --std=2008 --work=work:"$d/work" -L "$d" -a $SRC_HDL )
}

# runcell "<tag>|<generics>": one result line
runcell() {
  local tag="${1%%|*}" gens="${1#*|}"
  local d="$W/cells/$tag" log="$W/logs/$tag.log"
  mkdir -p "$d"
  if ! analyze "$d" > "$log" 2>&1; then
    echo "FAIL  $tag   (analysis failed, see $log)"; return 1
  fi
  # shellcheck disable=SC2086  # the generics are separate words
  if ( cd "$d" && nvc --std=2008 --work=work:"$d/work" -L "$d" \
         -e tb_fdd_write $gens ) >> "$log" 2>&1 && \
     ( cd "$d" && nvc --std=2008 --work=work:"$d/work" -L "$d" \
         -r tb_fdd_write ) >> "$log" 2>&1; then
    # a unit analysed before its source was last edited is not this tree
    if grep -q "older than its source file" "$log"; then
      echo "STALE $tag   (analysed unit is older than its source)"; return 1
    fi
    if grep -q "ALL CHECKS PASS" "$log"; then
      echo "PASS  $tag"; return 0
    fi
  fi
  echo "FAIL  $tag   ($(grep -m1 -E 'Failure|Error' "$log" | cut -c1-120))"
  return 1
}
export -f analyze runcell
export W ROOT PF HERE SRC_HDL

cells=()
if [ "$MODE" != fullonly ]; then
  for LEG in false true; do
    cells+=("s3_wprot_leg$LEG|-gG_SCEN=4 -gG_WORDS=600 -gG_LEGACY=$LEG")
    # variants 0/1 = short/long engine abort; 2 = the underrun path, reached
    # by starving Agnus so the serializer runs dry with the DMA still open
    for V in 0 1 2; do
      cells+=("s4_abort${V}_leg$LEG|-gG_SCEN=5 -gG_WORDS=2000 -gG_VARIANT=$V -gG_LEGACY=$LEG")
    done
    for V in 0 1 2 3 4 5 6; do
      cells+=("s5_storm${V}_leg$LEG|-gG_SCEN=6 -gG_WORDS=3000 -gG_VARIANT=$V -gG_LEGACY=$LEG")
    done
    for V in 0 1 2 3; do
      cells+=("s9_cosel${V}_leg$LEG|-gG_SCEN=8 -gG_WORDS=3000 -gG_VARIANT=$V -gG_LEGACY=$LEG")
    done
    cells+=("s10_df0_leg$LEG|-gG_SCEN=9 -gG_WORDS=3000 -gG_LEGACY=$LEG")
    for V in 0 1 2 3 4; do
      cells+=("s11_res${V}_leg$LEG|-gG_SCEN=10 -gG_WORDS=1500 -gG_VARIANT=$V -gG_LEGACY=$LEG")
    done
  done
fi
if [ "$MODE" != quick ]; then
  # full-track scenarios across RPM x separator x framing
  for RPM in 300000 300500 295500 304500; do
    for LEG in false true; do
      for FH in true false; do
        cells+=("s1_r${RPM}_leg${LEG}_fh${FH}|-gG_SCEN=1 -gG_RPM_MHZ=$RPM -gG_LEGACY=$LEG -gG_FRAMEHOLD=$FH")
      done
    done
  done
  # S1p: the precomp policy cases; their dumps feed the twin, which is the
  # only check of the shift direction
  for T in 80 81 90; do
    cells+=("s1p_auto_t$T|-gG_SCEN=2 -gG_TRACK=$T -gG_PRECMODE=0 -gG_DUMP=true")
  done
  cells+=("s1p_on_t20|-gG_SCEN=2 -gG_TRACK=20 -gG_PRECMODE=1 -gG_DUMP=true")
  cells+=("s1p_off_t20|-gG_SCEN=2 -gG_TRACK=20 -gG_PRECMODE=2 -gG_DUMP=true")
  cells+=("s2_xcopy|-gG_SCEN=3 -gG_WORDS=6656")
  # S2x: X-Copy's DOS-engine buffer with the SIDE toggle after DSKBLK;
  # variant 1 is the deselect arm (the head-0 path)
  for V in 0 1; do
    cells+=("s2x_xcopy_real$V|-gG_SCEN=12 -gG_VARIANT=$V")
  done
  for X in 25 50 80 104 128 150 300 1000 2100; do
    cells+=("s6_tail$X|-gG_SCEN=7 -gG_VARIANT=$X")
  done
  for V in 0 1; do
    cells+=("s12_busy$V|-gG_SCEN=11 -gG_VARIANT=$V")
  done
fi

if [ -n "$CELLS" ]; then
  sel=()
  for c in "${cells[@]}"; do
    if printf '%s\n' "${c%%|*}" | grep -qE -- "$CELLS"; then sel+=("$c"); fi
  done
  cells=(${sel[@]+"${sel[@]}"})
fi
if [ ${#cells[@]} -eq 0 ]; then
  echo "no cell selected"; exit 2
fi

# fail fast on a source that does not analyse at all
mkdir -p "$W/preflight"
if ! analyze "$W/preflight" > "$W/logs/analyze.log" 2>&1; then
  echo "ANALYZE FAILED"; tail -20 "$W/logs/analyze.log"; exit 1
fi
echo "analyze ok, ${#cells[@]} cell(s)"

if [ "$JOBS" -le 1 ]; then
  for c in "${cells[@]}"; do runcell "$c"; done | tee "$W/summary.txt"
else
  printf '%s\n' "${cells[@]}" \
    | xargs -P "$JOBS" -I{} bash -c 'runcell "$1"' _ {} \
    | sort | tee "$W/summary.txt"
fi
# every selected cell must report PASS; a missing line is a failure too
passed=$(grep -c '^PASS' "$W/summary.txt")
fails=$(( ${#cells[@]} - passed ))
if [ "$(grep -cE '^(PASS|FAIL|STALE)' "$W/summary.txt")" -ne ${#cells[@]} ]; then
  echo "NO-RESULT $(( ${#cells[@]} - $(grep -cE '^(PASS|FAIL|STALE)' "$W/summary.txt") )) cell(s) produced no result line"
fi

# Cross-check every flux dump against the independent twin: the bench's flux
# model and td_write_check.py must agree edge for edge, and a disagreement
# is a failure in its own right.
dumps=()
dumpcells=0
for c in "${cells[@]}"; do
  case "${c#*|}" in
    *G_DUMP=true*)
      dumpcells=$((dumpcells+1))
      found=0
      for d in "$W/cells/${c%%|*}"/wr_dump_*.txt; do
        [ -e "$d" ] && { dumps+=("$d"); found=1; }
      done
      if [ $found -eq 0 ]; then
        echo "TWIN-NONE ${c%%|*} wrote no flux dump - the twin checked nothing"
        fails=$((fails+1))
      fi ;;
  esac
done
if [ $dumpcells -eq 0 ]; then
  echo "TWIN-SKIP no selected cell writes a flux dump"
fi
for d in ${dumps[@]+"${dumps[@]}"}; do
  cell="$(basename "$(dirname "$d")")"
  tlog="$W/logs/twin_${cell}_$(basename "$d" .txt).log"
  if python3 -B "$W/src/models/td_write_check.py" "$d" --mfm > "$tlog" 2>&1; then
    echo "TWIN-OK   $cell/$(basename "$d")"
  else
    echo "TWIN-FAIL $cell/$(basename "$d"): $(grep -m1 FAIL "$tlog" | cut -c1-90)"
    fails=$((fails+1))
  fi
done

# a source edited during the run: the cells tested the copy, not the tree
for f in $SRC_ALL; do
  if ! cmp -s "$W/src/$f" "$(src_orig "$f")"; then
    echo "CHANGED $f was edited during the run; the results describe $W/src"
    fails=$((fails+1))
  fi
done

echo "-------------------------------------------"
echo "MATRIX $MODE: $fails failure(s) in ${#cells[@]} cell(s)"
exit "$fails"
