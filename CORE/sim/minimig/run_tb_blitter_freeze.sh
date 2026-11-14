#!/usr/bin/env bash
# Golden diff of the blitter freeze from upstream Minimig PR 236 (MiSTer
# commit 5578afd, Minimig submodule commit eea9d74). tb_blitter_freeze.v runs
# the pre-port blitter (fa40334, the Minimig fork's baseline before the
# upstream ports, renamed agnus_blitter_old) and rtl/agnus_blitter.v side by
# side; a mutant matrix then shows that every check can fail: each mutant must
# turn the run into RESULT: FAIL with its target sub-case failing.
#
# Usage: CORE/sim/minimig/run_tb_blitter_freeze.sh [builddir]
#   The build dir is the first argument, else $OUT, else a fresh mktemp
#   directory. MUTANTS=0 skips the mutant matrix (the bench alone takes a few
#   seconds); JOBS caps the parallel mutant runs (default 8). Needs the
#   submodule history (git show fa40334:...).
# Exit status 0 only if the real HDL passes and every mutant is killed at its
# target.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
R="$HERE"
M="$ROOT/CORE/Minimig_MiSTerMEGA65"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
O="${1:-${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-blitter-freeze.XXXXXX")}}"
mkdir -p "$O" || exit 2
O="$(cd "$O" && pwd)"
echo "build dir: $O"
cd "$O" || exit 2

git -C "$M" show fa40334:rtl/agnus_blitter.v \
  | sed -E 's/^module agnus_blitter([[:space:]]|$)/module agnus_blitter_old\1/' > "$O/agnus_blitter_old.v" || exit 2
grep -q '^module agnus_blitter_old' "$O/agnus_blitter_old.v" || { echo "FAIL: could not extract the fa40334 blitter"; exit 2; }
for f in adrgen barrelshifter fill minterm; do
  git -C "$M" diff --quiet fa40334 -- "rtl/agnus_blitter_$f.v" \
    || { echo "FAIL: rtl/agnus_blitter_$f.v differs from fa40334, OLD would not be the pre-port engine"; exit 2; }
done

SUBS=("$M/rtl/agnus_blitter_adrgen.v" "$M/rtl/agnus_blitter_barrelshifter.v" "$M/rtl/agnus_blitter_fill.v" "$M/rtl/agnus_blitter_minterm.v")
iverilog -g2012 -Wall -Wno-timescale -o "$O/base.vvp" -s tb_blitter_freeze \
  "$R/tb_blitter_freeze.v" "$O/agnus_blitter_old.v" "$M/rtl/agnus_blitter.v" "${SUBS[@]}" || { echo "FAIL: compile"; exit 2; }
(cd "$O" && vvp -n "$O/base.vvp") > "$O/base.log" 2>&1
grep -E '^  \[|^    (FAIL|RED|info)|^S[1-4] |^INFO|^RESULT' "$O/base.log"
grep -q '^RESULT: PASS' "$O/base.log" || { echo "FAIL: real HDL does not pass (log: $O/base.log)"; exit 1; }

[ "${MUTANTS:-1}" = "0" ] && exit 0

echo "MUTANT MATRIX (each mutant must make its target sub-case fail)"
python3 - "$O" "$M" "$R" "${JOBS:-8}" <<'PY'
import sys, re, subprocess, concurrent.futures as cf
O, M, R, JOBS = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
new = open(f"{M}/rtl/agnus_blitter.v").read()
old_file = f"{O}/agnus_blitter_old.v"
subs = [f"{M}/rtl/agnus_blitter_{x}.v" for x in ("adrgen", "barrelshifter", "fill", "minterm")]
D = "    !data_in[0] &&\n    !data_in[4] &&\n    !data_in[3];"
FRZ = "\t\t\tchsel  = 2'bXX;\n\t\t\tptrsel = 2'bXX;\n\t\t\tmodsel = 2'bXX;\n\n\t\t\tenaptr = 1'b0;\n\t\t\tincptr = 1'b0;\n\t\t\tdecptr = 1'b0;"
T = lambda tag: rf"^\s+\[{tag}\] .* : FAIL$"
muts = [
  ("M00", "NEW slot holds the pre-port blitter",           "swap_new", [], [T("S2a"), T("S3g")]),
  ("M01", "freeze not gated by busy",                       None, [("    busy &&\n    bltcon1_write &&", "    bltcon1_write &&")], [T("S3a")]),
  ("M02", "data bit 4 (EFE) not required clear",            None, [(D, "    !data_in[0] &&\n    !data_in[3];")], [T("S3b1")]),
  ("M03", "data bit 3 (IFE) not required clear",            None, [(D, "    !data_in[0] &&\n    !data_in[4];")], [T("S3b2"), T("S3b4")]),
  ("M04", "data bit 0 (LINE) not required clear",           None, [(D, "    !data_in[4] &&\n    !data_in[3];")], [T("S3b3")]),
  ("M05", "bltcon0[9:8] check removed",                     None, [("    (bltcon0[9:8] == 2'b01);", "    1'b1;")], [T("S3d1"), T("S3d2"), T("S3d3")]),
  ("M06", "only USED checked (USEC ignored)",               None, [("    (bltcon0[9:8] == 2'b01);", "    (bltcon0[8] == 1'b1);")], [T("S3d1")]),
  ("M07", "only USEC checked (USED ignored)",               None, [("    (bltcon0[9:8] == 2'b01);", "    (bltcon0[9] == 1'b0);")], [T("S3d3")]),
  ("M08", "old fill mode not required",                     None, [("    (ife || efe) &&", "    1'b1 &&")], [T("S3c1"), T("S3c2")]),
  ("M09", "line gate dropped (raw bltcon1 bits 3/4)",       None, [("    !line &&\n    (ife || efe) &&", "    (bltcon1[3] || bltcon1[4]) &&")], [T("S3e2")]),
  ("M10", "BLTSIZE does not release",                       None, [("        blt_state <= BLT_INIT;\n      else\n        blt_state <= BLT_FROZEN;", "        blt_state <= BLT_FROZEN;\n      else\n        blt_state <= BLT_FROZEN;")], [T("S2a")]),
  ("M11", "frozen state still requests DMA",                None, [("\t\t\tdma_req = 1'b0;\n\n\t\t\tblt_next = BLT_FROZEN;", "\t\t\tdma_req = 1'b1;\n\n\t\t\tblt_next = BLT_FROZEN;")], [T("S2a")]),
  ("M12", "frozen state resumes the blit",                  None, [("      else\n        blt_state <= BLT_FROZEN;\n    end", "      else\n        blt_state <= BLT_A;\n    end")], [T("S2a")]),
  ("M13", "D pointer keeps moving while frozen (no DMA)",   None, [(FRZ, FRZ.replace("ptrsel = 2'bXX", "ptrsel = CHD").replace("modsel = 2'bXX", "modsel = CHD").replace("enaptr = 1'b0", "enaptr = enable").replace("decptr = 1'b0", "decptr = desc"))], [T("S2a")]),
  ("M14", "reset does not release the freeze",              None, [("    if (reset)\n      blt_state <= BLT_IDLE;\n    else if (blt_state == BLT_FROZEN) begin", "    if (reset && blt_state != BLT_FROZEN)\n      blt_state <= BLT_IDLE;\n    else if (blt_state == BLT_FROZEN) begin")], [T("S4a")]),
  ("M15", "BLTSIZH releases without ecs",                   None, [("(reg_address_in[8:1] == BLTSIZH[8:1] && ecs))", "(reg_address_in[8:1] == BLTSIZH[8:1]))")], [T("S2a")]),
  ("M16", "new data ignored (freeze on any BLTCON1 write)", None, [(D, "    1'b1;")], [T("S3f1"), T("S3b1")]),
  ("M17", "normal path changed (D requests before pipeline full)", None, [("dma_req = used & pipeline_full;", "dma_req = used;")], [T("S1")]),
  ("M18", "OLD slot holds the new blitter (red control)",   "swap_old", [], [r"^S2 FREEZE OLD .*: FAIL"]),
]
jobs = []
for mid, desc, kind, reps, exp in muts:
    of, nf = old_file, f"{M}/rtl/agnus_blitter.v"
    if kind == "swap_new":
        nf = f"{O}/{mid}_agnus_blitter.v"
        open(nf, "w").write(subprocess.run(["git", "-C", M, "show", "fa40334:rtl/agnus_blitter.v"],
                                           capture_output=True, text=True, check=True).stdout)
    elif kind == "swap_old":
        of = f"{O}/{mid}_agnus_blitter_old.v"
        open(of, "w").write(re.sub(r"^module agnus_blitter(\s|$)", r"module agnus_blitter_old\1", new, count=1, flags=re.M))
    else:
        s = new
        for a, b in reps:
            n = s.count(a)
            if n != 1:
                print(f"MUTANT {mid}: pattern matches {n} times, cannot build: {a!r}"); sys.exit(1)
            s = s.replace(a, b)
        nf = f"{O}/{mid}_agnus_blitter.v"
        open(nf, "w").write(s)
    jobs.append((mid, desc, of, nf, exp))

def run(j):
    mid, desc, of, nf, exp = j
    vvp = f"{O}/{mid}.vvp"
    c = subprocess.run(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", vvp, "-s", "tb_blitter_freeze",
                        f"{R}/tb_blitter_freeze.v", of, nf] + subs, capture_output=True, text=True)
    if c.returncode != 0:
        return mid, desc, False, "compile error: " + c.stderr.strip()[:200]
    r = subprocess.run(["vvp", "-n", vvp], capture_output=True, text=True, cwd=O, timeout=600)
    log = r.stdout + r.stderr
    open(f"{O}/{mid}.log", "w").write(log)
    red = re.findall(r"^\s+\[(\w+)\] .* : FAIL$", log, re.M)
    hit = all(re.search(e, log, re.M) for e in exp)
    killed = ("RESULT: FAIL" in log) and hit
    return mid, desc, killed, "red: " + (", ".join(red) if red else "summary only")

bad = 0
with cf.ThreadPoolExecutor(max_workers=JOBS) as ex:
    for mid, desc, killed, info in ex.map(run, jobs):
        print(f"MUTANT {mid} {desc}: {'KILLED' if killed else 'NOT KILLED AT TARGET'} ({info})")
        bad += 0 if killed else 1
print(f"MUTANTS: {len(jobs) - bad}/{len(jobs)} killed at target")
sys.exit(1 if bad else 0)
PY
