#!/usr/bin/env bash
# The analog Standard VGA path: M2M's video_mixer with the scandoubler on,
# as analog_pipeline.vhd instantiates it, with LINEDOUBLER = 1 (the plain line
# doubler that VGA_LINEDOUBLER in CORE/vhdl/globals.vhd selects) and, as the
# control, LINEDOUBLER = 0 (MiSTer's Hq2x, which needs four clocks per pixel
# and drops every second hires pixel at AExp's two). Icarus Verilog compiles
# the real video_mixer.sv, scandoubler.v, hq2x.sv, video_freezer.sv and
# gamma_corr.sv from M2M/vhdl/controllers/MiSTer; check_scandoubler.py judges
# the traces (its docstring defines every check).
#
#   tb_scandoubler.v          modelled rasters: Amiga hires/lowres,
#                             interlaced, resolution switches, hblank moved by
#                             1-3 clocks, a widened window, generic rasters
#                             with 2, 3, 5 and 8 clocks per pixel, hblank
#                             moving from line to line (random 0-3 clocks per
#                             line, a one-time step of 5 or 7 clocks), vblank
#                             changing 1 or 3 clocks after the hblank edge
#   tb_scandoubler_minimig.v  the raster of Minimig's amiga_clk.v and
#                             agnus_beamcounter.v with the frame-locked
#                             enable of main.vhd
#
# Checks, each one result line:
#   lines  LINEDOUBLER = 1: every output line shows one complete input line,
#          every column once with the expected clocks per pixel, every input
#          line on two consecutive output lines, no X. In the cells whose
#          hblank moves from line to line (--moving-window) an output window
#          may also show blanking pixels next to the line, and the second copy
#          may end short by what the next input line is shorter; a window that
#          starts with pixels of the previous line (wrong half) fails. In the
#          cells with a late vblank edge (--vertical) every output frame must
#          show exactly the input lines whose active part is outside vblank
#   same   lowres-type rasters: the LINEDOUBLER = 1 output equals the
#          LINEDOUBLER = 0 output one output line later, clock for clock (HS,
#          VS, DE, CE_PIXEL, RGB under DE); a shift one clock off must differ
#   red    LINEDOUBLER = 0 at hires: the lines check must fail, with the
#          decimation signature (every hires line shows every second pixel)
#          and nothing else wrong. A red check passes only if the control
#          fails exactly that way.
#
# Usage: CORE/sim/video/run_scandoubler.sh [workdir] [quick|full]
#   quick  the gate subset (run_all.sh): eleven checks on 48-line modelled
#          frames and one hires frame of the Minimig raster; about 1.5
#          minutes with JOBS=1, under 1 with JOBS=3
#   full   (default, run_long.sh) quick plus the matrix at PAL frame height
#          and the Minimig raster across resolution switches, 57 checks;
#          about 50 minutes with JOBS=1, about 18 with JOBS=3
#   JOBS=n runs n simulations in parallel (default 1)
#   MIXER_DIR=dir takes video_mixer.sv, scandoubler.v, hq2x.sv,
#   video_freezer.sv and gamma_corr.sv from dir instead of
#   M2M/vhdl/controllers/MiSTer (for red controls on an older or mutated
#   scandoubler)
#   KEEP_TRACES=1 keeps every trace.txt (by default only the traces of failed
#   checks stay; one simulation writes up to about 90 MB, a full run about
#   1 GB)
#
# workdir must be an existing directory or a path containing a slash; without
# one, a fresh mktemp directory is used. The runner copies every source into
# <workdir>/src first and simulates that copy; agnus_beamcounter.v is used
# with six declarations moved in front of their first use (Icarus cannot bind
# a name used before its declaration), and the runner proves that nothing
# else changed. A source edited during the run fails it as CHANGED. Every
# simulation runs in its own directory under <workdir>/cells.
# Exit status: the number of failed checks (0 = all pass).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
MIX="${MIXER_DIR:-$ROOT/M2M/vhdl/controllers/MiSTer}"
MM="$ROOT/CORE/Minimig_MiSTerMEGA65/rtl"

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
  W="$(mktemp -d "${TMPDIR:-/tmp}/aexp-scandoubler.XXXXXX")" || exit 2
fi
mkdir -p "$W" || exit 2
W="$(cd "$W" && pwd)"
JOBS="${JOBS:-1}"
T0=$(date +%s)

echo "work dir: $W   mode: $MODE   jobs: $JOBS"
[ -z "${MIXER_DIR:-}" ] || echo "mixer sources: $MIX"
# A reused work dir must not show the previous run's results.
rm -rf "$W/logs" "$W/cells" "$W/src"
mkdir -p "$W/logs" "$W/cells" "$W/src"

# ------------------------------------------------------------ source snapshot
SRC_FILES="video_mixer.sv scandoubler.v hq2x.sv video_freezer.sv gamma_corr.sv
  amiga_clk.v agnus_beamcounter.v tb_scandoubler.v tb_scandoubler_minimig.v
  check_scandoubler.py"
src_orig() {
  case "$1" in
    amiga_clk.v|agnus_beamcounter.v) echo "$MM/$1" ;;
    tb_*|check_*) echo "$HERE/$1" ;;
    *) echo "$MIX/$1" ;;
  esac
}
for f in $SRC_FILES; do
  cp "$(src_orig "$f")" "$W/src/$f" || { echo "cannot copy $f"; exit 2; }
done

# agnus_beamcounter.v with the declarations that follow their first use moved
# to just after the port list ("wire X = e;" becomes "wire X;" there and
# "assign X = e;" in place); every changed line must name a moved identifier
python3 -I - "$W/src/agnus_beamcounter.v" "$W/src/agnus_beamcounter_sim.v" \
  > "$W/logs/hoist.log" 2>&1 <<'PY' || { echo "HOIST FAILED"; cat "$W/logs/hoist.log"; exit 2; }
import re, sys, difflib
src, dst = sys.argv[1:3]
NAMES = ["ersy", "long_line", "long_frame", "last_line", "end_of_frame", "htotal"]
orig = open(src).read().splitlines(keepends=True)
lines = list(orig)
hoisted = []
for name in NAMES:
    pat = re.compile(r'^(\s*)(reg|wire)(\s*\[[^\]]*\])?\s+' + name + r'\s*(;|=)(.*)$', re.S)
    idx = [i for i, l in enumerate(lines) if pat.match(l)]
    assert len(idx) == 1, (name, idx)
    i = idx[0]; m = pat.match(lines[i])
    if m.group(4) == ';':
        hoisted.append(lines[i].lstrip())
        lines[i] = ''
    else:
        hoisted.append('%s%s %s;\n' % (m.group(2), m.group(3) or '', name))
        lines[i] = '%sassign %s =%s' % (m.group(1), name, m.group(5))
mod = [i for i, l in enumerate(lines) if re.match(r'^module agnus_beamcounter\b', l)]
assert len(mod) == 1
end = [i for i, l in enumerate(lines) if i > mod[0] and l.strip() == ');'][0]
lines[end + 1:end + 1] = hoisted
out = ''.join(lines)
open(dst, 'w').write(out)
bad = []
for d in difflib.unified_diff(orig, out.splitlines(keepends=True), n=0):
    if d.startswith(('---', '+++', '@@')) or d[1:].strip() == '':
        continue
    if not any(re.search(r'\b%s\b' % n, d[1:]) for n in NAMES):
        bad.append(d)
assert not bad, bad
print('agnus_beamcounter.v: %d declarations moved, the diff is confined to them' % len(hoisted))
PY

# ------------------------------------------------------------------ the cells
# simulation: "<name>|<bench>|<parameters>", bench model or minimig
# quick model rasters: 48-line frames, vblank on lines 0..10
QM="VLINES=48 VBEND=10 LOGFROM=1 FRAMES=2 STOPLINE=15"
# PAL model rasters: 313-line frames, vblank on lines 0..25
FM="LOGFROM=1 FRAMES=2 STOPLINE=30"
sims=(
  "q_hires|model|LD=1 P0=2 P1=2 $QM"
  "q_hires_ld0|model|LD=0 P0=2 P1=2 $QM"
  "q_lores|model|LD=1 P0=4 P1=4 $QM"
  "q_lores_ld0|model|LD=0 P0=4 P1=4 $QM"
  "q_lace_hires|model|LD=1 P0=2 P1=2 LACE=1 ${QM/FRAMES=2/FRAMES=3}"
  "q_sw_lh|model|LD=1 P0=4 P1=2 SW=1 $QM"
  "q_hb1_hires|model|LD=1 P0=2 P1=2 HBDLY=1 $QM"
  "q_g3|model|LD=1 GEN=1 P0=3 P1=3 $QM"
  "q_jit_hires|model|LD=1 P0=2 P1=2 HBJIT=1 SEED=6 $QM"
  "q_vb1_hires|model|LD=1 P0=2 P1=2 VBDLY=1 $QM"
  "q_minimig|minimig|LD=1 SCHED=H FH0=1 NFRAMES=2"
)
checks=(
  "q_hires|lines|q_hires --hs-period 908 --min-lines 70"
  "q_hires_red|red|q_hires_ld0 --min-lines 70"
  "q_lores|lines|q_lores --hs-period 908 --min-lines 70"
  "q_lores_same|same|q_lores q_lores_ld0 --shift 908"
  "q_lace_hires|lines|q_lace_hires --hs-period 908 --min-lines 140"
  "q_sw_lh|lines|q_sw_lh --min-lines 70"
  "q_hb1_hires|lines|q_hb1_hires --hs-period 908 --min-lines 70"
  "q_g3|lines|q_g3 --hs-period 681 --min-lines 70"
  "q_jit_hires|lines|q_jit_hires --moving-window --min-lines 70"
  "q_vb1_hires|lines|q_vb1_hires --vertical --hs-period 908 --min-lines 70"
  "q_minimig|lines|q_minimig --hs-period 908 --min-lines 500"
)
if [ "$MODE" = full ]; then
  # longest first: xargs starts the simulations in list order
  sims=(
    "minimig|minimig|LD=1 SCHED=LLHHLL NFRAMES=6"
    "lace_hires_ld0|model|LD=0 P0=2 P1=2 LACE=1 ${FM/FRAMES=2/FRAMES=3}"
    "lace_lores_ld0|model|LD=0 P0=4 P1=4 LACE=1 ${FM/FRAMES=2/FRAMES=3}"
    "minimig_ld0|minimig|LD=0 SCHED=LLH NFRAMES=3"
    "hires_ld0|model|LD=0 P0=2 P1=2 $FM"
    "lores_ld0|model|LD=0 P0=4 P1=4 $FM"
    "hb1_lores_ld0|model|LD=0 P0=4 P1=4 HBDLY=1 $FM"
    "hb2_lores_ld0|model|LD=0 P0=4 P1=4 HBDLY=2 $FM"
    "hb3_lores_ld0|model|LD=0 P0=4 P1=4 HBDLY=3 $FM"
    "wide_lores_ld0|model|LD=0 P0=4 P1=4 HBON=36 HBOFF=71 $FM"
    "g5_ld0|model|LD=0 GEN=1 P0=5 P1=5 $FM"
    "g8_ld0|model|LD=0 GEN=1 P0=8 P1=8 $FM"
    "minimig_hires_ld0|minimig|LD=0 SCHED=H FH0=1 NFRAMES=2"
    "minimig_mixed|minimig|LD=1 SCHED=M FH0=1 NFRAMES=2"
    "minimig_hb1|minimig|LD=1 HBOFS=1 SCHED=H FH0=1 NFRAMES=2"
    "minimig_hb2|minimig|LD=1 HBOFS=2 SCHED=H FH0=1 NFRAMES=2"
    "minimig_hb3|minimig|LD=1 HBOFS=3 SCHED=H FH0=1 NFRAMES=2"
    "minimig_pixd1|minimig|LD=1 PIXD=1 SCHED=H FH0=1 NFRAMES=2"
    "lace_hires|model|LD=1 P0=2 P1=2 LACE=1 ${FM/FRAMES=2/FRAMES=3}"
    "lace_lores|model|LD=1 P0=4 P1=4 LACE=1 ${FM/FRAMES=2/FRAMES=3}"
    "hires|model|LD=1 P0=2 P1=2 $FM"
    "lores|model|LD=1 P0=4 P1=4 $FM"
    "sw_lh|model|LD=1 P0=4 P1=2 SW=1 $FM"
    "sw_hl|model|LD=1 P0=2 P1=4 SW=1 $FM"
    "hb1_hires|model|LD=1 P0=2 P1=2 HBDLY=1 $FM"
    "hb2_hires|model|LD=1 P0=2 P1=2 HBDLY=2 $FM"
    "hb3_hires|model|LD=1 P0=2 P1=2 HBDLY=3 $FM"
    "hb1_lores|model|LD=1 P0=4 P1=4 HBDLY=1 $FM"
    "hb2_lores|model|LD=1 P0=4 P1=4 HBDLY=2 $FM"
    "hb3_lores|model|LD=1 P0=4 P1=4 HBDLY=3 $FM"
    "wide_hires|model|LD=1 P0=2 P1=2 HBON=36 HBOFF=71 $FM"
    "wide_lores|model|LD=1 P0=4 P1=4 HBON=36 HBOFF=71 $FM"
    "g2|model|LD=1 GEN=1 P0=2 P1=2 $FM"
    "g3|model|LD=1 GEN=1 P0=3 P1=3 $FM"
    "g5|model|LD=1 GEN=1 P0=5 P1=5 $FM"
    "g8|model|LD=1 GEN=1 P0=8 P1=8 $FM"
    "jit_hires|model|LD=1 P0=2 P1=2 HBJIT=1 SEED=6 $FM"
    "jit_lores|model|LD=1 P0=4 P1=4 HBJIT=1 SEED=6 $FM"
    "step5_hires|model|LD=1 P0=2 P1=2 STEPD=5 STEPF=2 $FM"
    "step7_hires|model|LD=1 P0=2 P1=2 STEPD=7 STEPF=2 $FM"
    "step7_lores|model|LD=1 P0=4 P1=4 STEPD=7 STEPF=2 $FM"
    "vb1_hires|model|LD=1 P0=2 P1=2 VBDLY=1 $FM"
    "vb3_hires|model|LD=1 P0=2 P1=2 VBDLY=3 $FM"
    "vb1_lores|model|LD=1 P0=4 P1=4 VBDLY=1 $FM"
    "vb3_lores|model|LD=1 P0=4 P1=4 VBDLY=3 $FM"
    "vb1_hb2_hires|model|LD=1 P0=2 P1=2 VBDLY=1 HBDLY=2 $FM"
    "${sims[@]}"
  )
  checks+=(
    "hires|lines|hires --hs-period 908"
    "hires_red|red|hires_ld0"
    "lores|lines|lores --hs-period 908"
    "lores_same|same|lores lores_ld0 --shift 908"
    "lace_hires|lines|lace_hires --hs-period 908"
    "lace_hires_red|red|lace_hires_ld0"
    "lace_lores|lines|lace_lores --hs-period 908"
    "lace_lores_same|same|lace_lores lace_lores_ld0 --shift 908"
    "sw_lh|lines|sw_lh"
    "sw_hl|lines|sw_hl"
    "hb1_hires|lines|hb1_hires --hs-period 908"
    "hb2_hires|lines|hb2_hires --hs-period 908"
    "hb3_hires|lines|hb3_hires --hs-period 908"
    "hb1_lores|lines|hb1_lores --hs-period 908"
    "hb1_lores_same|same|hb1_lores hb1_lores_ld0 --shift 908"
    "hb2_lores|lines|hb2_lores --hs-period 908"
    "hb2_lores_same|same|hb2_lores hb2_lores_ld0 --shift 908"
    "hb3_lores|lines|hb3_lores --hs-period 908"
    "hb3_lores_same|same|hb3_lores hb3_lores_ld0 --shift 908"
    "wide_hires|lines|wide_hires --hs-period 908"
    "wide_lores|lines|wide_lores --hs-period 908"
    "wide_lores_same|same|wide_lores wide_lores_ld0 --shift 908"
    "g2|lines|g2 --hs-period 454"
    "g3|lines|g3 --hs-period 681"
    "g5|lines|g5 --hs-period 1135"
    "g5_same|same|g5 g5_ld0 --shift 1135"
    "g8|lines|g8 --hs-period 1816"
    "g8_same|same|g8 g8_ld0 --shift 1816"
    "jit_hires|lines|jit_hires --moving-window"
    "jit_lores|lines|jit_lores --moving-window"
    "step5_hires|lines|step5_hires --moving-window"
    "step7_hires|lines|step7_hires --moving-window"
    "step7_lores|lines|step7_lores --moving-window"
    "vb1_hires|lines|vb1_hires --vertical --hs-period 908"
    "vb3_hires|lines|vb3_hires --vertical --hs-period 908"
    "vb1_lores|lines|vb1_lores --vertical --hs-period 908"
    "vb3_lores|lines|vb3_lores --vertical --hs-period 908"
    "vb1_hb2_hires|lines|vb1_hb2_hires --vertical --hs-period 908"
    "minimig|lines|minimig --min-lines 1500"
    "minimig_same|same|minimig minimig_ld0 --shift 908 --frames 1:3 --min-de 500000"
    "minimig_hires_red|red|minimig_hires_ld0 --min-lines 500"
    "minimig_mixed|lines|minimig_mixed --hs-period 908 --min-lines 500"
    "minimig_hb1|lines|minimig_hb1 --hs-period 908 --min-lines 500"
    "minimig_hb2|lines|minimig_hb2 --hs-period 908 --min-lines 500"
    "minimig_hb3|lines|minimig_hb3 --hs-period 908 --min-lines 500"
    "minimig_pixd1|lines|minimig_pixd1 --hs-period 908 --min-lines 500"
  )
fi

# run_sim "<name>|<bench>|<parameters>" - one line: SIM <name> <seconds> <status>
run_sim() {
  local name bench params rest top srcs t0 rc p v
  name="${1%%|*}"; rest="${1#*|}"
  bench="${rest%%|*}"; params="${rest#*|}"
  local cdir="$W/cells/$name"
  mkdir -p "$cdir"
  if [ "$bench" = minimig ]; then
    top=tb_scandoubler_minimig
    srcs="$W/src/amiga_clk.v $W/src/agnus_beamcounter_sim.v"
  else
    top=tb_scandoubler
    srcs=""
  fi
  local pargs=()
  for p in $params; do
    v="${p#*=}"
    case "$v" in [0-9]*) ;; *) v="\"$v\"" ;; esac
    pargs+=(-P "$top.${p%%=*}=$v")
  done
  t0=$(date +%s)
  # $srcs is a word list and is split on purpose
  # shellcheck disable=SC2086
  if ( cd "$cdir" && iverilog -g2012 -o sim.vvp -s "$top" "${pargs[@]}" "$W/src/$top.v" \
         "$W/src/video_mixer.sv" "$W/src/scandoubler.v" "$W/src/hq2x.sv" \
         "$W/src/video_freezer.sv" "$W/src/gamma_corr.sv" $srcs \
       && vvp -n sim.vvp ) > "$W/logs/sim_$name.log" 2>&1 \
     && grep -q '^E ' "$cdir/trace.txt" 2>/dev/null; then
    rc=ok
  else
    rc=FAILED
  fi
  echo "SIM $name $(( $(date +%s) - t0 ))s $rc"
}

# run_check "<name>|<kind>|<arguments>" - one result line
run_check() {
  local name kind args rest log a b why
  name="${1%%|*}"; rest="${1#*|}"
  kind="${rest%%|*}"; args="${rest#*|}"
  log="$W/logs/check_$name.log"
  set -- $args
  case "$kind" in
    lines|red)
      a="$1"; shift
      python3 -I "$W/src/check_scandoubler.py" lines "$W/cells/$a/trace.txt" "$@" > "$log" 2>&1
      local rc=$?
      local sig cls
      sig="$(sed -n 's/^SIGNATURE //p' "$log")"
      cls="$(grep '^CLASS' "$log" | sed 's/^CLASS //' | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
      if [ "$kind" = lines ]; then
        if [ "$rc" -eq 0 ] && grep -q '^RESULT PASS' "$log"; then
          echo "PASS  $name   ($cls)"
        else
          why="$(grep -m1 -E '^  |^ERROR' "$log" | sed 's/^ *//' | cut -c1-100)"
          echo "FAIL  $name   (${why:-$cls; signature ${sig:-none}})"
          echo "$a" >> "$W/logs/keep.txt"
        fi
      else
        if [ "$rc" -eq 0 ]; then
          echo "FAIL  $name   (the red control passed: the checker did not see the decimation)"
          echo "$a" >> "$W/logs/keep.txt"
        elif [ "$rc" -eq 1 ] && [ "$sig" = decimated ]; then
          echo "PASS  $name   (red as expected, decimated: $cls)"
        else
          echo "FAIL  $name   (red, but not with the decimation signature: ${sig:-no verdict}; $cls)"
          echo "$a" >> "$W/logs/keep.txt"
        fi
      fi
      ;;
    same)
      a="$1"; b="$2"; shift 2
      if python3 -I "$W/src/check_scandoubler.py" same "$W/cells/$a/trace.txt" \
           "$W/cells/$b/trace.txt" "$@" > "$log" 2>&1 && grep -q '^RESULT PASS' "$log"; then
        echo "PASS  $name   ($(sed -n 's/^same .*: \([0-9]* clocks, [0-9]* under DE\).*/\1/p' "$log"), 0 differ)"
      else
        echo "FAIL  $name   ($(grep -m1 -E '^mismatching|^  error|^ERROR' "$log" | cut -c1-100))"
        printf '%s\n%s\n' "$a" "$b" >> "$W/logs/keep.txt"
      fi
      ;;
  esac
}
export -f run_sim run_check
export W

: > "$W/logs/keep.txt"
printf '%s\n' "${sims[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_sim "$1"' _ {} \
  > "$W/logs/sims.txt"
nsim=$(grep -c ' ok$' "$W/logs/sims.txt")
if [ "$nsim" -eq "${#sims[@]}" ]; then
  echo "simulations: all $nsim finished"
else
  echo "simulations: $nsim of ${#sims[@]} finished, failed:" \
       "$(grep -v ' ok$' "$W/logs/sims.txt" | awk '{print $2}' | tr '\n' ' ')(logs: $W/logs/sim_*.log)"
fi
printf '%s\n' "${checks[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_check "$1"' _ {} \
  | tee "$W/logs/results.txt"

total=${#checks[@]}
passed=$(grep -c '^PASS' "$W/logs/results.txt")
reported=$(grep -cE '^(PASS|FAIL)' "$W/logs/results.txt")
fails=$((total - passed))
for f in $SRC_FILES; do
  if ! cmp -s "$W/src/$f" "$(src_orig "$f")"; then
    echo "CHANGED $f was edited during the run; the results describe $W/src"
    fails=$((fails + 1))
  fi
done
# the traces are large; keep only those of failed checks unless asked
if [ "${KEEP_TRACES:-0}" != 1 ]; then
  for s in "${sims[@]}"; do
    n="${s%%|*}"
    grep -qx "$n" "$W/logs/keep.txt" || rm -f "$W/cells/$n/trace.txt"
  done
fi
echo "-------------------------------------------"
if [ "$reported" -ne "$total" ]; then
  echo "$((total - reported)) check(s) produced no result line"
fi
if [ "$fails" -eq 0 ]; then
  echo "SCANDOUBLER ($MODE): all $total checks PASS ($(( $(date +%s) - T0 ))s)"
else
  echo "SCANDOUBLER ($MODE): $fails failure(s) in $total check(s) ($(( $(date +%s) - T0 ))s)"
fi
exit "$fails"
