#!/usr/bin/env bash
# Golden diff and Copylock timing check for the DSKBYTR observation surface in
# rtl/paula_floppy.v (tb_paula_obs.v; see its header for the three parts).
#
# The bench runs the current paula_floppy.v of the Minimig submodule. Icarus
# cannot bind the two regs rx_data/tx_data, which the file uses before it
# declares them (Vivado accepts that), so the runner writes a copy with only
# those two declarations moved behind the port list, checks that the copy
# differs from the original in nothing else, and simulates it beside the
# frozen reference paula_floppy_ref.v.
#
# Usage: CORE/sim/minimig/run_paula_obs.sh [workdir]
#   workdir defaults to a fresh mktemp directory. Runtime: a few seconds.
# Exit status 0 only if the bench prints "TB_PAULA_OBS: ALL CHECKS PASS".
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RTL="$ROOT/CORE/Minimig_MiSTerMEGA65/rtl"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-paula-obs.XXXXXX")}"
mkdir -p "$W" || exit 2
W="$(cd "$W" && pwd)"
echo "work dir: $W"

python3 -I - "$RTL/paula_floppy.v" "$W/paula_floppy_dut.v" <<'PY' || { echo "TB_PAULA_OBS: cannot prepare paula_floppy.v"; exit 2; }
import re, sys
s = open(sys.argv[1]).read()
d = []
for n in ('rx_data', 'tx_data'):
    m = re.search(r'^reg\s+\[15:0\]\s+' + n + r';.*$', s, flags=re.M)
    if m is None:
        sys.exit(f"declaration of {n} not found")
    d.append(m.group(0))
    s = s[:m.start()] + s[m.end():]
m = re.search(r'^\);\s*$', s, flags=re.M)
if m is None:
    sys.exit("end of the port list not found")
s = s[:m.end()] + '\n' + '\n'.join(d) + '\n' + s[m.end():]
# proof that the copy is a pure reorder: the same non-blank lines, and only
# the two declarations at a different place
orig = open(sys.argv[1]).read().splitlines()
new = s.splitlines()
if sorted(l for l in orig if l.strip()) != sorted(l for l in new if l.strip()):
    sys.exit("the copy is not a pure reorder of paula_floppy.v")
moved = [l for l in orig if l.strip()]
kept = [l for l in new if l.strip()]
for l in d:
    moved.remove(l)
    kept.remove(l)
if moved != kept:
    sys.exit("the copy changes more than the two declarations")
open(sys.argv[2], 'w').write(s)
PY

cd "$W" || exit 2
iverilog -g2012 -o "$W/tb_paula_obs.vvp" "$HERE/tb_paula_obs.v" \
  "$W/paula_floppy_dut.v" "$RTL/paula_floppy_fifo.v" "$HERE/paula_floppy_ref.v" \
  || { echo "TB_PAULA_OBS: compile failed"; exit 2; }
vvp -n "$W/tb_paula_obs.vvp" | tee "$W/tb_paula_obs.log"
grep -q "^TB_PAULA_OBS: ALL CHECKS PASS" "$W/tb_paula_obs.log"
