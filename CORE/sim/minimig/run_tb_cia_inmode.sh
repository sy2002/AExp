#!/usr/bin/env bash
# Golden diff of the CIA timers with CNT pin and Timer A/B INMODE support
# (upstream MiSTer PR 230, Minimig submodule commit 62f880c) against the
# timers of fa40334, the Minimig fork's baseline before the upstream ports.
# tb_cia_inmode.v describes the four phases.
#
# Usage: CORE/sim/minimig/run_tb_cia_inmode.sh [builddir]
#   The build dir is the first argument, else $OUT, else a fresh mktemp
#   directory. Needs the submodule history (git show fa40334:...).
#   Runtime: about 1.5 minutes.
# Exit status 0 only if the bench prints "TB RESULT: PASS".
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
M="$ROOT/CORE/Minimig_MiSTerMEGA65"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
O="${1:-${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-cia-inmode.XXXXXX")}}"
mkdir -p "$O" || exit 2
O="$(cd "$O" && pwd)"
echo "build dir: $O"

for t in a b; do
  git -C "$M" show "fa40334:rtl/cia_timer$t.v" \
    | sed -E "s/^module cia_timer$t([[:space:]]|$)/module cia_timer${t}_old\1/" \
    > "$O/cia_timer${t}_old.v" || { echo "FAIL: cannot extract fa40334:rtl/cia_timer$t.v"; exit 2; }
  grep -q "^module cia_timer${t}_old" "$O/cia_timer${t}_old.v" \
    || { echo "FAIL: cia_timer${t}_old not found in the extracted file"; exit 2; }
done

cd "$O" || exit 2
iverilog -g2012 -Wall -Wno-timescale -o "$O/tb_cia_inmode.vvp" -s tb_cia_inmode \
  "$HERE/tb_cia_inmode.v" "$O/cia_timera_old.v" "$O/cia_timerb_old.v" \
  "$M/rtl/cia_timera.v" "$M/rtl/cia_timerb.v" || { echo "FAIL: compile"; exit 2; }
vvp -n "$O/tb_cia_inmode.vvp" | tee "$O/tb_cia_inmode.log"
grep -q "^TB RESULT: PASS" "$O/tb_cia_inmode.log"
