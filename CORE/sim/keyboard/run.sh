#!/usr/bin/env bash
# Keyboard benches for CORE/vhdl/keyboard.vhd, all in MEGA65 mode
# (keyboard_mode_i = '0', the default):
#   tb_keyboard        balanced make/break for shifted F-keys, chords, early
#                      shift release and normal keys while a substituted
#                      F-key is held (fast keyboard.device-like reader)
#   tb_keyboard_guard  the post-send ack blackout (C_ACK_GUARD): an ack inside
#                      the settling window does not release the next code
#   tb_keyboard_lossy  send-then-wait-for-ack flow control against a modelled
#                      single-byte CIA SDR: no overrun and no stuck key for a
#                      fast, a slow and a non-reading consumer
#
# Usage: CORE/sim/keyboard/run.sh [workdir]
#   workdir defaults to a fresh mktemp directory. Runtime: about 1.5 minutes,
#   almost all of it tb_keyboard_lossy.
# Exit status 0 only if all three benches pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-keyboard.XXXXXX")}"
mkdir -p "$W/logs" || exit 2
W="$(cd "$W" && pwd)"
echo "work dir: $W"
cd "$W" || exit 2
NVC="nvc --std=2008 --work=work:$W/work -L $W"

$NVC -a "$ROOT/CORE/vhdl/keyboard.vhd" "$HERE/tb_keyboard.vhd" \
    "$HERE/tb_keyboard_guard.vhd" "$HERE/tb_keyboard_lossy.vhd" \
    > "$W/logs/analyse.log" 2>&1 \
  || { echo "ANALYSE FAILED"; tail -20 "$W/logs/analyse.log"; exit 1; }

fails=0
# bench <unit> <pass-regex>: elaborate, run, and require the pass marker
bench() {
  local unit="$1" pass="$2" log="$W/logs/$1.log"
  if $NVC -e "$unit" > "$log" 2>&1 && $NVC -r "$unit" >> "$log" 2>&1; then
    if grep -q "older than its source file" "$log"; then
      echo "STALE $unit   (analysed unit is older than its source - re-analyse)"
      fails=$((fails+1)); return
    fi
    if grep -qE "$pass" "$log" && ! grep -qE "\*\* (Error|Failure)|>>> STUCK" "$log"; then
      echo "PASS  $unit"; return
    fi
  fi
  echo "FAIL  $unit   ($(grep -m1 -E '>>> |Error|Failure' "$log" | cut -c1-110))"
  fails=$((fails+1))
}

bench tb_keyboard       "clean after FINAL"
bench tb_keyboard_guard "GUARD RESULT: PASS"
bench tb_keyboard_lossy "@@@ RESULT: PASS"

if [ "$fails" -eq 0 ]; then echo "KEYBOARD: all benches PASS"; else echo "KEYBOARD: $fails bench(es) FAILED"; fi
exit "$fails"
