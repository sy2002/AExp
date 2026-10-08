#!/usr/bin/env bash
# Audio filter benches (doc/developers/audio.md, section "Verification"):
#   tb_iir_amiga.v       (Icarus) the two Amiga IIR filters as audio_filters.vhd
#                        instantiates them, measured gains against the analytic
#                        RC prototypes, plus channel separation
#   tb_audio_filters.vhd (nvc) the glue in audio_filters.vhd: bypass, A500/LED
#                        muxes, LED gating, stereo crossfeed, with the
#                        +100-offset IIR stub from CORE/sim/stubs
#
# Usage: CORE/sim/audio/run.sh [workdir]
#   workdir defaults to a fresh mktemp directory. Runtime: a few seconds.
# Exit status 0 only if both benches pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-audio.XXXXXX")}"
mkdir -p "$W/logs" || exit 2
W="$(cd "$W" && pwd)"
echo "work dir: $W"
cd "$W" || exit 2
NVC="nvc --std=2008 --work=work:$W/work -L $W"
fails=0

# tb_iir_amiga.v against M2M's copy of MiSTer's iir_filter.v
log="$W/logs/tb_iir_amiga.log"
if iverilog -g2012 -o "$W/tb_iir_amiga.vvp" "$HERE/tb_iir_amiga.v" \
     "$ROOT/M2M/vhdl/controllers/MiSTer/iir_filter.v" > "$log" 2>&1 \
   && vvp -n "$W/tb_iir_amiga.vvp" >> "$log" 2>&1 \
   && grep -q "^ALL PASS" "$log"; then
  echo "PASS  tb_iir_amiga"
else
  echo "FAIL  tb_iir_amiga   ($(grep -m1 -E 'FAIL|FAILURES|error' "$log" | cut -c1-100))"
  fails=$((fails+1))
fi

# tb_audio_filters.vhd with the IIR stub
log="$W/logs/tb_audio_filters.log"
if $NVC -a "$ROOT/CORE/sim/stubs/iir_stub_sim.vhd" "$ROOT/CORE/vhdl/audio_filters.vhd" \
       "$HERE/tb_audio_filters.vhd" > "$log" 2>&1 \
   && $NVC -e tb_audio_filters >> "$log" 2>&1 \
   && $NVC -r tb_audio_filters >> "$log" 2>&1; then
  if grep -q "older than its source file" "$log"; then
    echo "STALE tb_audio_filters   (analysed unit is older than its source - re-analyse)"
    fails=$((fails+1))
  elif grep -q "ALL PASS" "$log" && ! grep -qE "\*\* (Error|Failure)" "$log"; then
    echo "PASS  tb_audio_filters"
  else
    echo "FAIL  tb_audio_filters   ($(grep -m1 -E 'FAIL|Error|Failure' "$log" | cut -c1-100))"
    fails=$((fails+1))
  fi
else
  echo "FAIL  tb_audio_filters   ($(grep -m1 -E 'FAIL|Error|Failure' "$log" | cut -c1-100))"
  fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then echo "AUDIO: all benches PASS"; else echo "AUDIO: $fails bench(es) FAILED"; fi
exit "$fails"
