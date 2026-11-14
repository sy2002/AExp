#!/usr/bin/env bash
# Mutant matrix for the Hardware Floppy write datapath: proves that the
# checks of tb_fdd_write.vhd (and of the twin models/td_write_check.py) can
# fail. Each mutant is a single-site edit of a copy of the real HDL
# (physical_fdd_writer.vhd or adf_track_engine.vhd), run against the one
# scenario cell that must detect it.
#
# The sense is inverted: every mutant must be killed. A mutant whose cell
# still passes is a checker defect and counts as a failure, and so does a
# kill that is not a real verdict (a timeout, a crash, a design that does
# not elaborate) or a kill in a cell that also fails on the unmutated
# design. An anchor that does not match the current HDL exactly once is a
# harness error: the mutant would no longer test what its name says.
# Anchors are code only and are matched token by token with comments
# removed, so reformatting or recommenting the HDL does not break them; a
# changed line of code does, loudly.
#
# Usage: CORE/sim/floppy/run_write_mutants.sh [workdir] [mutant-id ...]
#        CORE/sim/floppy/run_write_mutants.sh --anchors
#   mutant ids: i ii iii iv v vi vii viii ix x xi xii xiii xiv xv (default:
#   all); --anchors only checks that every anchor matches the current HDL
#   exactly once (no simulation, a second).
#
# workdir must be an existing directory or a path containing a slash (for
# example ./work); any other argument that is not a mutant id is rejected,
# so a typo cannot become a work directory. Without one, a fresh mktemp
# directory is used; a reused one has its logs, sources, mutant copies and
# cached baselines wiped first, so no result of an earlier run can be
# credited to this one.
#
# At the start the runner copies the HDL, both benches and the twin into
# <workdir>/src; every mutant and baseline is built from that copy, so the
# whole run tests one tree even if a file is edited meanwhile, and at the
# end a source that no longer matches its copy fails the run (CHANGED).
# A kill counts only if the same cell passes on the unmutated copy; when the
# kill comes from the twin, the twin must also accept the unmutated dump.
# JOBS=<n> (default 1) runs n mutants at a time, each in its own
# subdirectory. Runtime: about 40 minutes serially for all fifteen, about
# 11 minutes with JOBS=8.
# Exit status: the number of mutants that were not killed, plus one per
# changed source.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PF="$ROOT/CORE/vhdl/physical_fdd"
ENGINE="$ROOT/CORE/vhdl/adf_track_engine.vhd"
IDS_ALL="i ii iii iv v xiv xv vi vii viii ix x xiii xi xii"

usage() { echo "usage: $0 [workdir] [mutant-id ...] | --anchors" >&2; exit 2; }
is_id() { case " $IDS_ALL " in *" $1 "*) return 0 ;; esac; return 1; }

MODE=run
W=""
SEL=""
for a in "$@"; do
  case "$a" in
    --anchors) MODE=anchors ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
    */*) [ -z "$W" ] || usage; W="$a" ;;
    *) if is_id "$a"; then SEL="$SEL $a"
       elif [ -d "$a" ] && [ -z "$W" ]; then W="$a"
       else echo "unknown argument: $a" >&2; usage; fi ;;
  esac
done
[ -n "$SEL" ] || SEL=" $IDS_ALL"
selected() { case "$SEL " in *" $1 "*) return 0 ;; esac; return 1; }

# mutate <src> <out|-> <old> <new>
# Replaces the one code occurrence of <old> in <src> by <new> and writes the
# result to <out> ("-" only checks). Matching runs on the whitespace-separated
# code tokens of <src>, with comments removed: <old> must equal a run of
# consecutive code tokens, so indentation, alignment, line breaks and
# comments around or between them do not matter.
mutate() {
  python3 -I - "$@" <<'PY'
import re, sys
src, out, old, new = sys.argv[1:5]
s = open(src).read()
toks = []                       # (text, start, end) of every code token
pos = 0
for line in s.split('\n'):
    cut, in_str = len(line), False
    for i, ch in enumerate(line):
        if ch == '"':
            in_str = not in_str
        elif not in_str and line.startswith('--', i):
            cut = i
            break
    for m in re.finditer(r'\S+', line[:cut]):
        toks.append((m.group(0), pos + m.start(), pos + m.end()))
    pos += len(line) + 1
want = old.split()
n = len(want)
hits = [i for i in range(len(toks) - n + 1)
        if toks[i][0] == want[0] and [t[0] for t in toks[i:i + n]] == want]
if len(hits) != 1:
    sys.stderr.write("anchor matched %d times (need exactly 1): %r\n"
                     % (len(hits), ' '.join(want)[:70]))
    sys.exit(2)
start, end = toks[hits[0]][1], toks[hits[0] + n - 1][2]
if out != '-':
    open(out, 'w').write(s[:start] + new.strip() + s[end:])
PY
}

hdl_path() {
  if [ "$1" = adf_track_engine.vhd ]; then echo "$ENGINE"; else echo "$PF/$1"; fi
}

# snapshot: copies the HDL, both benches and the twin into $SRC once per
# run; check_snapshot reports every source that changed since
snap_list() {
  (cd "$PF" && ls physical_fdd_*.vhd)
  echo adf_track_engine.vhd tb_fdd_write.vhd tb_adf_multidrive.vhd \
       models/td_write_check.py models/td_check.py
}
snap_orig() {
  case "$1" in
    physical_fdd_*) echo "$PF/$1" ;;
    adf_track_engine.vhd) echo "$ENGINE" ;;
    *) echo "$HERE/$1" ;;
  esac
}
snapshot() {
  local f
  rm -rf "$SRC"; mkdir -p "$SRC/models" || return 1
  for f in $(snap_list); do cp "$(snap_orig "$f")" "$SRC/$f" || return 1; done
}
check_snapshot() {
  local f n=0
  for f in $(snap_list); do
    if ! cmp -s "$SRC/$f" "$(snap_orig "$f")"; then
      echo "CHANGED $f was edited during the run; the results describe $SRC"
      n=$((n+1))
    fi
  done
  return $n
}

# copy_sources <dir>: the HDL every mutant and baseline analyses
copy_sources() {
  cp "$SRC"/physical_fdd_*.vhd "$SRC/adf_track_engine.vhd" "$1/"
}

# analyze_write <dir> <nvc command>: the write bench over the copies in <dir>
analyze_write() {
  local d="$1"; shift
  ( cd "$d" && "$@" -a physical_fdd_pkg.vhd physical_fdd_inputs.vhd \
      physical_fdd_mfm_gaps.vhd physical_fdd_mfm_quantise.vhd \
      physical_fdd_bits.vhd physical_fdd_wfifo.vhd physical_fdd_writer.vhd \
      physical_fdd_diag.vhd physical_fdd_top.vhd adf_track_engine.vhd \
      "$SRC/tb_fdd_write.vhd" )
}

# twin_ok <dir> <log>: the twin accepts every flux dump in <dir>; a dir
# without any dump fails
twin_ok() {
  local d found=0
  for d in "$1"/wr_dump_*.txt; do
    [ -e "$d" ] || continue
    found=1
    python3 -B "$SRC/models/td_write_check.py" "$d" --mfm >> "$2" 2>&1 || return 1
  done
  [ "$found" -eq 1 ]
}

# baseline_ok <generics...>
# A mutant counts as killed only if the cell that judges it passes on the
# unmutated design; otherwise a cell that fails for every design would score
# its mutant as killed while testing nothing. A cell that writes flux dumps
# (G_DUMP) must also satisfy the twin on the unmutated design, because the
# twin is what kills the precomp-direction mutant. Results are cached per
# generic string for the current run only.
baseline_ok() {
  local key bd
  key="$(printf '%s ' "$@" | tr -c 'A-Za-z0-9' '_')"
  bd="$W/base_$key"
  if [ -f "$bd/verdict" ]; then
    [ "$(cat "$bd/verdict")" = ok ]; return $?
  fi
  mkdir -p "$bd"
  copy_sources "$bd"
  local nvcb=(nvc --std=2008 --work=work:"$bd/work" -L "$bd")
  { analyze_write "$bd" "${nvcb[@]}" \
      && ( cd "$bd" && "${nvcb[@]}" -e tb_fdd_write "$@" ) \
      && ( cd "$bd" && "${nvcb[@]}" -r tb_fdd_write ); } > "$bd/base.log" 2>&1
  if grep -q "ALL CHECKS PASS" "$bd/base.log" \
     && ! grep -q "older than its source file" "$bd/base.log"; then
    case " $* " in
      *G_DUMP=true*)
        if ! twin_ok "$bd" "$bd/twin.log"; then
          echo bad > "$bd/verdict"; return 1
        fi ;;
    esac
    echo ok > "$bd/verdict"; return 0
  fi
  echo bad > "$bd/verdict"; return 1
}

# mut <id> <desc> <file> <old> <new> <killer generics...>
# The killer is a tb_fdd_write cell.
mut() {
  local id="$1" desc="$2" which="$3" old="$4" new="$5"; shift 5
  if [ "$MODE" = anchors ]; then
    if mutate "$(hdl_path "$which")" - "$old" "$new" 2>"$W/anchor_$id.txt"; then
      echo "ANCHOR-OK     $id ($desc)"
    else
      echo "HARNESS-ERROR $id ($desc): $(cat "$W/anchor_$id.txt")"; fails=$((fails+1))
    fi
    return 0
  fi
  selected "$id" || return 0
  local mw="$W/m_$id" log="$W/logs/mut_$id.log"
  rm -rf "$mw"; mkdir -p "$mw"
  copy_sources "$mw"
  local target="$mw/$which"
  if ! mutate "$target" "$target.mut" "$old" "$new" 2>"$W/logs/mut_$id.anchor"; then
    echo "HARNESS-ERROR $id ($desc): $(cat "$W/logs/mut_$id.anchor")"
    fails=$((fails+1)); return 1
  fi
  mv "$target.mut" "$target"
  local nvcm=(nvc --std=2008 --work=work:"$mw/work" -L "$mw")
  analyze_write "$mw" "${nvcm[@]}" > "$log" 2>&1
  if ! ( cd "$mw" && "${nvcm[@]}" -e tb_fdd_write "$@" ) >> "$log" 2>&1; then
    echo "HARNESS-ERROR $id ($desc): the mutant does not elaborate"
    fails=$((fails+1)); return 1
  fi
  ( cd "$mw" && "${nvcm[@]}" -r tb_fdd_write ) >> "$log" 2>&1
  if grep -q "older than its source file" "$log"; then
    echo "HARNESS-ERROR $id ($desc): analysed unit is older than its source"
    fails=$((fails+1)); return 1
  fi
  if grep -q "ALL CHECKS PASS" "$log"; then
    # The bench verdicts passed. Some kills live in the independent twin
    # (the precomp direction: the bench asserts only that precomp is active
    # and that pulses were shifted, the direction comes from the wall-clock
    # table only td_write_check.py reads), so the twin has its say before
    # the mutant is declared a survivor.
    local d
    for d in "$mw"/wr_dump_*.txt; do
      [ -e "$d" ] || continue
      if ! python3 -B "$SRC/models/td_write_check.py" "$d" --mfm \
           > "$W/logs/mut_${id}_twin.log" 2>&1; then
        if ! baseline_ok "$@"; then
          echo "CHECKER-DEFECT $id ($desc): the twin or the cell also fails on the unmutated design, so this kill proves nothing"
          fails=$((fails+1)); return 1
        fi
        echo "KILLED    $id ($desc): by the independent twin: $(grep -m1 FAIL "$W/logs/mut_${id}_twin.log" | cut -c1-70)"
        return 0
      fi
    done
    echo "SURVIVED  $id ($desc)  <-- checker defect: the matrix cannot see this"
    fails=$((fails+1)); return 1
  fi
  # A kill must be a real verdict failure. A timeout, a crash or an
  # out-of-memory would otherwise be scored as a kill and hide a checker
  # that never ran.
  if grep -qE "Failure" "$log"; then
    if ! baseline_ok "$@"; then
      echo "CHECKER-DEFECT $id ($desc): the cell fails on the unmutated design too, so this kill proves nothing"
      fails=$((fails+1)); return 1
    fi
    echo "KILLED    $id ($desc): $(grep -m1 -E 'Failure' "$log" | sed 's/.*Failure: [0-9a-z+]*: //' | cut -c1-88)"
    return 0
  fi
  echo "HARNESS-ERROR $id ($desc): the run neither passed nor asserted - $(tail -1 "$log" | cut -c1-70)"
  fails=$((fails+1)); return 1
}

# mut_adf <id> <desc> <file> <old> <new>
# The same contract with tb_adf_multidrive.vhd as the killer, for mutants
# whose detector is the multi-drive ownership bench (three simulated drives
# and a real HyperRAM image). No mutant uses it at present.
mut_adf() {
  local id="$1" desc="$2" which="$3" old="$4" new="$5"
  if [ "$MODE" = anchors ]; then
    if mutate "$(hdl_path "$which")" - "$old" "$new" 2>"$W/anchor_$id.txt"; then
      echo "ANCHOR-OK     $id ($desc)"
    else
      echo "HARNESS-ERROR $id ($desc): $(cat "$W/anchor_$id.txt")"; fails=$((fails+1))
    fi
    return 0
  fi
  selected "$id" || return 0
  local mw="$W/m_$id" log="$W/logs/mut_$id.log"
  rm -rf "$mw"; mkdir -p "$mw"
  copy_sources "$mw"
  local target="$mw/$which"
  if ! mutate "$target" "$target.mut" "$old" "$new" 2>"$W/logs/mut_$id.anchor"; then
    echo "HARNESS-ERROR $id ($desc): $(cat "$W/logs/mut_$id.anchor")"
    fails=$((fails+1)); return 1
  fi
  mv "$target.mut" "$target"
  local nvcm=(nvc --std=2008 --work=work:"$mw/work" -L "$mw")
  ( cd "$mw" && "${nvcm[@]}" -a adf_track_engine.vhd "$SRC/tb_adf_multidrive.vhd" \
      && "${nvcm[@]}" -e tb_adf_multidrive && "${nvcm[@]}" -r tb_adf_multidrive ) \
      > "$log" 2>&1
  if grep -q "ALL TESTS PASSED" "$log"; then
    echo "SURVIVED  $id ($desc)  <-- checker defect: the matrix cannot see this"
    fails=$((fails+1)); return 1
  fi
  if ! grep -q "FAIL:" "$log"; then
    echo "HARNESS-ERROR $id ($desc): the run neither passed nor reported a FAIL - $(tail -1 "$log" | cut -c1-70)"
    fails=$((fails+1)); return 1
  fi
  echo "KILLED    $id ($desc): $(grep -m1 'FAIL:' "$log" | sed 's/.*FAIL: //' | cut -c1-80)"
  return 0
}

define_mutants() {

# (i) LSB-first serialization instead of MSB-first
mut i "LSB-first serialization" physical_fdd_writer.vhd \
"            v_bit := sh_reg(15);
            sh_reg <= sh_reg(14 downto 0) & '0';" \
"            v_bit := sh_reg(0);
            sh_reg <= '0' & sh_reg(15 downto 1);" \
  -gG_SCEN=1

# (ii) 99-cycle cell instead of 100
mut ii "99-cycle cell" physical_fdd_writer.vhd \
"  constant C_CELL : natural := C_HALF_CELL_CYC;" \
"  constant C_CELL : natural := C_HALF_CELL_CYC - 1;" \
  -gG_SCEN=1

# (iii) one word dropped at the episode's first frame boundary
mut iii "first word dropped" physical_fdd_writer.vhd \
"              state <= ST_STREAM;
            else
              state       <= ST_DISCARD;" \
"              state <= ST_STREAM;
              fifo_rd_o <= '1';
            else
              state       <= ST_DISCARD;" \
  -gG_SCEN=1

# (iv) runt WDATA pulse (20 ns, far below the mechanism's 0.2 us floor)
mut iv "20 ns runt WDATA pulse" physical_fdd_writer.vhd \
"  constant C_WR_PULSE : natural := 25;" \
"  constant C_WR_PULSE : natural := 1;" \
  -gG_SCEN=1

# (v) WGATE window one cell short
mut v "WGATE one cell short" physical_fdd_writer.vhd \
"      if vwin(C_MID) = '1' and abort_lat = '0' and state = ST_STREAM
         and en_i = '1' and (sel_i = '1' or v_hold = '1') and mot_i = '1'
         and wr_ok_r = '1' then" \
"      if vwin(C_MID) = '1' and vwin(C_MID + 1) = '1' and abort_lat = '0'
         and state = ST_STREAM
         and en_i = '1' and (sel_i = '1' or v_hold = '1') and mot_i = '1'
         and wr_ok_r = '1' then" \
  -gG_SCEN=1

# (xiv) drain hold tied off: v_hold stays '0', so a SELECT or SIDE change
# during the post-DSKBLK drain aborts and cuts sector 10's last word. S2x
# is the only cell that detects it.
mut xiv "v_hold tied '0' (no drain hold)" physical_fdd_writer.vhd \
"      v_hold := '0';
      if state = ST_STREAM and sess_s = '0' then
        v_hold := '1';
      end if;" \
"      v_hold := '0';" \
  -gG_SCEN=12

# (xv) drain hold over-applied: v_hold for the whole episode instead of the
# drain, so a SELECT or SIDE change during the write no longer aborts and
# the writer keeps laying flux after the head has switched. S5 variant 6
# (side flip mid-write) detects it.
mut xv "v_hold over-applied to the whole episode" physical_fdd_writer.vhd \
"      if state = ST_STREAM and sess_s = '0' then
        v_hold := '1';
      end if;" \
"      if state = ST_STREAM then
        v_hold := '1';
      end if;" \
  -gG_SCEN=6 -gG_WORDS=3000 -gG_VARIANT=6

# (vi) ready recomputed as occupancy <= 2 (the overflow race)
mut vi "ready = occupancy <= 2" adf_track_engine.vhd \
"                           or phys_wr_level_i > 1 then" \
"                           or phys_wr_level_i > 2 then" \
  -gG_SCEN=1

# (vii) precompensation sign inverted; only the twin sees the direction
mut vii "precomp sign inverted" physical_fdd_writer.vhd \
"        if v_gap_b < v_gap_a then
          v_shift := -C_WR_PRECOMP;
        else
          v_shift := C_WR_PRECOMP;
        end if;" \
"        if v_gap_b < v_gap_a then
          v_shift := C_WR_PRECOMP;
        else
          v_shift := -C_WR_PRECOMP;
        end if;" \
  -gG_SCEN=2 -gG_TRACK=90 -gG_PRECMODE=0 -gG_DUMP=true

# (viii) abort on the first foreign sample: the persistence requirement is
# removed, so a one-poll change-poll click of Paula's priority encoder
# kills the episode.
#
# The obvious alternative mutation, dropping the `wr_epi = '0'` suppression
# on the unit-ownership guard, does not change behaviour: with that guard
# firing, in_drain is cleared and the write branch re-latches in the same
# cycle, and the re-latch takes the episode-inheritance path, which restores
# drain_unit = the physical unit and drain_commit = '0' anyway. The two
# mechanisms are deliberately redundant, so only removing both is
# observable, and that is mutant (xi).
mut viii "abort on the first foreign sample" adf_track_engine.vhd \
"            if foreign_cnt = C_WR_FOREIGN then
               epi_abort <= '1';" \
"            if true then
               epi_abort <= '1';" \
  -gG_SCEN=8 -gG_VARIANT=0 -gG_WORDS=3000

# (ix) the abort level is never set
mut ix "abort level never set" adf_track_engine.vhd \
"            if wr_epi = '1' then
               epi_abort <= '1';
               delay_cnt <= C_GAP_DELAY;
            end if;" \
"            if wr_epi = '1' then
               delay_cnt <= C_GAP_DELAY;
            end if;" \
  -gG_SCEN=5 -gG_VARIANT=0 -gG_WORDS=2000

# The busy interlock has two independent gates and therefore two mutants.
# G_POLL=200 shortens the engine's poll period: after an episode ends the
# engine parks for a full poll period, so at the real 1 ms it never re-polls
# inside the writer's ~104 us tail and neither gate is reachable.
#
# (x) the write side: do not bind a new episode on top of a draining tail.
# S12 variant 1 arms a second write inside the tail and measures its WGATE
# window; a second episode bound on the tail serializes the first one's
# residue in front of its own first word, so the window is not 1200 words.
mut x "busy interlock removed (write side)" adf_track_engine.vhd \
"                           and phys_wr_busy_i = '1' then" \
"                           and false then" \
  -gG_SCEN=11 -gG_VARIANT=1 -gG_WORDS=6815 -gG_POLL=200

# (xiii) the read side: do not dispatch a physical read while the writer is
# still driving the head. S12 variant 0 fires X-Copy's index-synced verify
# read inside the tail; the ilock_viol monitor counts every cycle a read
# session is open while wr_busy is high.
mut xiii "busy interlock removed (read side)" adf_track_engine.vhd \
"                        if phys_en_i = '1' and phys_wr_busy_i = '0'" \
"                        if phys_en_i = '1' and true" \
  -gG_SCEN=11 -gG_VARIANT=0 -gG_WORDS=6815 -gG_POLL=200

# (xi) episode inheritance removed. The killer is S9 variant 3, the only
# state in which the branch is observable: the ownership guard is suspended
# inside an episode, so a foreign sel alone can never re-latch the drain -
# the drain has to be cleared underneath the episode (a global abort does
# that and deliberately leaves the episode bound, because Paula still holds
# trackwr) and the next poll has to sample a foreign unit. That variant
# configures a mounted, write-enabled ADF drive at unit 2 for the wrongly
# owned drain to commit into; the always-on ownership monitor fires. The
# anchor is the inheritance branch that follows the episode bind.
mut xi "episode inheritance removed" adf_track_engine.vhd \
"                                 epi_precomp <= '0';
                              end if;
                           elsif wr_epi = '1' then" \
"                                 epi_precomp <= '0';
                              end if;
                           elsif false then" \
  -gG_SCEN=8 -gG_VARIANT=3 -gG_WORDS=3000

# (xii) precomp AUTO threshold off by one (track >= 80 instead of >= 81)
mut xii "precomp AUTO threshold >= 80" adf_track_engine.vhd \
"      elsif trk >= 81 then" \
"      elsif trk >= 80 then" \
  -gG_SCEN=2 -gG_TRACK=80 -gG_PRECMODE=0

}

fails=0

if [ "$MODE" = anchors ]; then
  W="$(mktemp -d "${TMPDIR:-/tmp}/aexp-mutant-anchors.XXXXXX")" || exit 2
  define_mutants
  rm -rf "$W"
  echo "-------------------------------------------"
  if [ "$fails" -eq 0 ]; then echo "ANCHORS: all match exactly once"
  else echo "ANCHORS: $fails anchor(s) broken"; fi
  exit "$fails"
fi

if [ -z "$W" ]; then
  W="$(mktemp -d "${TMPDIR:-/tmp}/aexp-write-mutants.XXXXXX")" || exit 2
fi
mkdir -p "$W" || exit 2
W="$(cd "$W" && pwd)"
JOBS="${JOBS:-1}"
# nothing of an earlier run may survive: a cached "ok" baseline from another
# tree would credit a kill this run never earned
rm -rf "$W/logs" "$W/par" "$W"/base_* "$W"/m_* "$W/summary.txt"
mkdir -p "$W/logs"
# the source snapshot; a child of a parallel run uses its parent's
if [ -n "${AEXP_MUTANT_SRC:-}" ]; then
  SRC="$AEXP_MUTANT_SRC"; OWN_SRC=0
else
  SRC="$W/src"; OWN_SRC=1
  snapshot || { echo "cannot copy the sources into $SRC"; exit 2; }
fi
n_sel=$(echo $SEL | wc -w | tr -d ' ')
echo "work dir: $W   mutants: $n_sel   jobs: $JOBS"

if [ "$JOBS" -gt 1 ] && [ "$n_sel" -gt 1 ]; then
  # one child per mutant, each with its own work directory and baseline cache
  mkdir -p "$W/par"
  runone() {
    local id="$1" out="$W/par/$1.txt"
    AEXP_MUTANT_SRC="$SRC" JOBS=1 "$SELF" "$W/par/wd_$1" "$1" > "$out" 2>&1
    local line
    line="$(grep -m1 -E '^(KILLED|SURVIVED|HARNESS-ERROR|CHECKER-DEFECT)' "$out")"
    echo "${line:-HARNESS-ERROR $id: no result line, see $out}"
  }
  export -f runone
  export W SRC
  export SELF="$HERE/$(basename "$0")"
  printf '%s\n' $SEL | xargs -P "$JOBS" -I{} bash -c 'runone "$1"' _ {} \
    | sort | tee "$W/summary.txt"
else
  define_mutants | tee "$W/summary.txt"
fi
# every selected mutant must report KILLED; a missing line is a failure too
killed=$(grep -c '^KILLED' "$W/summary.txt")
fails=$((n_sel - killed))
if [ "$(grep -cE '^(KILLED|SURVIVED|HARNESS-ERROR|CHECKER-DEFECT)' "$W/summary.txt")" -ne "$n_sel" ]; then
  echo "NO-RESULT not every mutant produced a result line"
fi
if [ "$OWN_SRC" -eq 1 ]; then
  check_snapshot
  fails=$((fails + $?))
fi

echo "-------------------------------------------"
if [ "$fails" -eq 0 ]; then
  echo "MUTANT MATRIX: all $n_sel mutants KILLED"
else
  echo "MUTANT MATRIX: $fails failure(s) among $n_sel mutants (survived, harness error, no result or changed source)"
fi
exit "$fails"
