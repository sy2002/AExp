#!/usr/bin/env bash
# Golden diff of rtl/agnus_beamcounter.v: the beam counter of fa40334, the
# Minimig fork's baseline before the upstream ports (OLD), against the working
# tree (NEW = upstream 06f30af VHPOSR readback + d16cd84 field1 gate).
#
#   CORE/sim/minimig/run_tb_beamcounter_readback.sh [builddir]
#       green run, exit != 0 on any failure (about ten minutes)
#   CORE/sim/minimig/run_tb_beamcounter_readback.sh [builddir] --red
#       red controls: every broken expectation and every DUT mutant must
#       fail; exit != 0 if one passes (six runs in parallel, about ten
#       minutes on a machine with six free cores)
#   The build dir is the first non-option argument, else $OUT, else a fresh
#   mktemp directory. Needs the submodule history (git show fa40334:...).
#
# rtl/agnus_beamcounter.v uses six identifiers before declaring them (Vivado
# and Quartus accept that, iverilog cannot bind it). Both copies get the same
# mechanical transformation: each such declaration moves to just after the
# port list; a "wire X = expr;" becomes "wire X;" there plus "assign X =
# expr;" in the original place (a net declaration assignment and a continuous
# assignment are the same thing). The script then proves from a diff that only
# those lines and the module name changed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
M="$ROOT/CORE/Minimig_MiSTerMEGA65"
RED=0
DIR=""
# a build directory must exist or contain a slash, so a typo cannot become one
for a in "$@"; do
    case "$a" in
        --red) RED=1 ;;
        */*) [ -z "$DIR" ] || { echo "usage: $0 [builddir] [--red]" >&2; exit 2; }
             DIR="$a" ;;
        *) if [ -d "$a" ] && [ -z "$DIR" ]; then DIR="$a"
           else echo "unknown argument: $a (usage: $0 [builddir] [--red])" >&2; exit 2; fi ;;
    esac
done
O="${DIR:-${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-beamcounter.XXXXXX")}}"
mkdir -p "$O"
O="$(cd "$O" && pwd)"
echo "build dir: $O"
cd "$O"

echo "NEW source: $M/rtl/agnus_beamcounter.v (submodule HEAD $(git -C "$M" rev-parse --short HEAD), blob $(git -C "$M" hash-object rtl/agnus_beamcounter.v | cut -c1-7))"
echo "OLD source: fa40334:rtl/agnus_beamcounter.v (blob $(git -C "$M" rev-parse --short fa40334:rtl/agnus_beamcounter.v))"
git -C "$M" show fa40334:rtl/agnus_beamcounter.v > "$O/orig_old.v"
cp "$M/rtl/agnus_beamcounter.v" "$O/orig_new.v"

hoist() {  # hoist <in> <out> <module name>
python3 -I - "$1" "$2" "$3" <<'PY'
import re, sys, difflib
src, dst, modname = sys.argv[1:4]
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
lines[mod[0]] = re.sub(r'^module agnus_beamcounter\b', 'module ' + modname, lines[mod[0]])
end = [i for i, l in enumerate(lines) if i > mod[0] and l.strip() == ');'][0]
lines[end + 1:end + 1] = hoisted
out = ''.join(lines)
open(dst, 'w').write(out)
# proof: every changed line names a hoisted identifier or is the module line
bad = []
for d in difflib.unified_diff(orig, out.splitlines(keepends=True), n=0):
    if d.startswith(('---', '+++', '@@')):
        continue
    body = d[1:]
    if body.strip() == '':
        continue
    if re.match(r'^module agnus_beamcounter', body):
        continue
    if not any(re.search(r'\b%s\b' % n, body) for n in NAMES):
        bad.append(d)
assert not bad, bad
print('hoist %s -> %s: %d declarations moved, diff confined to them' % (src.split('/')[-1], modname, len(hoisted)))
PY
}

hoist "$O/orig_old.v" "$O/bc_old.v" agnus_beamcounter_old
hoist "$O/orig_new.v" "$O/bc_new.v" agnus_beamcounter

run() {  # run <tag> <new copy> [iverilog defines...]
    local tag="$1" newv="$2"; shift 2
    iverilog -g2012 -Wno-timescale "$@" -o "$O/tb_$tag.vvp" -s tb_beamcounter_readback \
        "$HERE/tb_beamcounter_readback.v" "$O/bc_old.v" "$newv" "$M/rtl/amiga_clk.v"
    vvp -n "$O/tb_$tag.vvp" > "$O/tb_$tag.log" 2>&1 || true
    grep -q '^RESULT: PASS' "$O/tb_$tag.log"
}

if [ "$RED" = 0 ]; then
    rc=0
    run green "$O/bc_new.v" || rc=1
    grep -E '^(cycles|frames|readback|field1|PASS|FAIL|RESULT)' "$O/tb_green.log"
    exit $rc
fi

# ---------------------------------------------------------------- red controls
mutant() {  # mutant <name> <python regex> <replacement>
python3 -I - "$O/bc_new.v" "$O/bc_new_$1.v" "$2" "$3" <<'PY'
import re, sys
src, dst, pat, rep = sys.argv[1:5]
s = open(src).read()
t, n = re.subn(pat, rep, s)
assert n == 1, (pat, n)
open(dst, 'w').write(t)
PY
}
mutant m1_readback_reverted 'data_out\[15:0\] = \{vpos\[7:0\],\|hpos\[8:1\] \? hpos\[8:1\] - 8.d1 : ersy \? 8.d0 : htotal\[8:1\]\};' 'data_out[15:0] = {vpos[7:0],hpos[8:1]};'
mutant m2_no_ersy_gate   ': ersy \? 8.d0 : htotal\[8:1\]\}' ': htotal[8:1]}'
mutant m3_field1_reverted 'assign field1 = \(~long_frame\) & lace;' 'assign field1 = ~long_frame;'
mutant m4_hpos_split_broken 'assign hpos = \{hpos_hi\[8:1\], cck\};' 'assign hpos = {hpos_hi[8:1], ~cck};'

# the six controls run in parallel (about ten minutes each, like the green run)
expect_red() {  # expect_red <tag> <check that must FAIL> <new copy> [defines...]
    local tag="$1" chk="$2" newv="$3"; shift 3
    if run "$tag" "$newv" "$@"; then
        echo "CONTROL $tag: GREEN - the control did not fire (BAD)"
    elif grep -qF "FAIL $chk " "$O/tb_$tag.log"; then
        echo "CONTROL $tag: RED as expected ($(grep -F "FAIL $chk " "$O/tb_$tag.log" | head -1))"
    else
        echo "CONTROL $tag: RED but not at check $chk (BAD)"
    fi
}
expect_red e1_wrap0        '(ii)'  "$O/bc_new.v" -DRED_EXPECT_WRAP0       > "$O/ctl_e1.txt" &
expect_red e2_field1_eq    '(iii)' "$O/bc_new.v" -DRED_EXPECT_FIELD1_EQ   > "$O/ctl_e2.txt" &
expect_red m1_readback     '(ii)'  "$O/bc_new_m1_readback_reverted.v"     > "$O/ctl_m1.txt" &
expect_red m2_ersy_gate    '(ii)'  "$O/bc_new_m2_no_ersy_gate.v"          > "$O/ctl_m2.txt" &
expect_red m3_field1       '(iii)' "$O/bc_new_m3_field1_reverted.v"       > "$O/ctl_m3.txt" &
expect_red m4_hpos_split   '(i)'   "$O/bc_new_m4_hpos_split_broken.v"     > "$O/ctl_m4.txt" &
wait
cat "$O"/ctl_e1.txt "$O"/ctl_e2.txt "$O"/ctl_m1.txt "$O"/ctl_m2.txt "$O"/ctl_m3.txt "$O"/ctl_m4.txt
if grep -q 'BAD' "$O"/ctl_*.txt || [ "$(cat "$O"/ctl_*.txt | grep -c 'RED as expected')" -ne 6 ]; then
    echo "RED CONTROLS: FAILURE"; exit 1
fi
echo "RED CONTROLS: ALL FIRED"
