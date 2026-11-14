#!/usr/bin/env bash
# Power-on cold-boot check for CORE/vhdl/amiga_cold_boot.vhd
# (tb_cold_boot_init.vhd): the default drive map must not cold-boot the Amiga
# at t=0, a different map must, and a deliberately wrong expectation must
# fail, which shows that the assertion can fire.
#
# Usage: CORE/sim/misc/run.sh [workdir]
#   workdir defaults to a fresh mktemp directory. Runtime: a few seconds.
# Exit status 0 only if all three cases end as expected.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-misc.XXXXXX")}"
mkdir -p "$W/logs" || exit 2
W="$(cd "$W" && pwd)"
echo "work dir: $W"
cd "$W" || exit 2
NVC="nvc --std=2008 --work=work:$W/work -L $W"

$NVC -a "$ROOT/CORE/vhdl/amiga_cold_boot.vhd" "$HERE/tb_cold_boot_init.vhd" \
    > "$W/logs/analyse.log" 2>&1 \
  || { echo "ANALYSE FAILED"; tail -20 "$W/logs/analyse.log"; exit 1; }

fails=0
# case <tag> <expect: pass|fail> [generics...]
case_run() {
  local tag="$1" expect="$2"; shift 2
  local log="$W/logs/$tag.log" got
  if $NVC -e tb_cold_boot_init "$@" > "$log" 2>&1 && $NVC -r tb_cold_boot_init >> "$log" 2>&1 \
     && grep -q "PASS: saw_boot" "$log"; then
    got=pass
  else
    got=fail
  fi
  if grep -q "older than its source file" "$log"; then
    echo "STALE $tag   (analysed unit is older than its source - re-analyse)"
    fails=$((fails+1)); return
  fi
  if [ "$got" = "$expect" ]; then
    echo "PASS  $tag   (bench ${got}ed as expected)"
  else
    echo "FAIL  $tag   (bench ${got}ed, expected it to $expect: $(grep -m1 -E 'Failure|Error' "$log" | cut -c1-90))"
    fails=$((fails+1))
  fi
}

case_run default_map     pass
case_run three_drive_map pass -gG_MAP=10010000 -gG_EXPECT_BOOT=true
case_run red_control     fail -gG_EXPECT_BOOT=true

if [ "$fails" -eq 0 ]; then echo "COLD BOOT: all cases PASS"; else echo "COLD BOOT: $fails case(s) FAILED"; fi
exit "$fails"
