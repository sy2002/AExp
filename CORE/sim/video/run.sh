#!/usr/bin/env bash
# Contract check for M2M/vhdl/av_pipeline/analog_positioner.vhd, the analog
# pan of the M2M-UPSTREAM screen-center change (tb_analog_positioner.vhd):
# clock-exact bypass at zero pan, pan in both directions and units, pulse
# widths, bounded periods, interlace phase preservation, clamps, disengage,
# mode change and reset. Five rasters:
#   raw_prog   progressive, 60 lines per field
#   raw_lace   interlaced, 62.5 lines per field
#   raw_quant  interlaced with VS quantized to line starts (62/63 lines)
#   dbl_prog   line-doubled progressive (doubled_i = 1)
#   dbl_lace   line-doubled interlaced
#
# Usage: CORE/sim/video/run.sh [workdir]
#   workdir defaults to a fresh mktemp directory. Runtime: about 25 seconds.
# Exit status 0 only if all five rasters pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-video.XXXXXX")}"
mkdir -p "$W/logs" || exit 2
W="$(cd "$W" && pwd)"
echo "work dir: $W"
cd "$W" || exit 2
NVC="nvc --std=2008 --work=work:$W/work -L $W"

$NVC -a "$ROOT/M2M/vhdl/av_pipeline/analog_positioner.vhd" "$HERE/tb_analog_positioner.vhd" \
    > "$W/logs/analyse.log" 2>&1 \
  || { echo "ANALYSE FAILED"; tail -20 "$W/logs/analyse.log"; exit 1; }

fails=0
# raster <tag> [generics...]
raster() {
  local tag="$1"; shift
  local log="$W/logs/$tag.log"
  if $NVC -e tb_analog_positioner "$@" > "$log" 2>&1 && $NVC -r tb_analog_positioner >> "$log" 2>&1; then
    if grep -q "older than its source file" "$log"; then
      echo "STALE $tag   (analysed unit is older than its source - re-analyse)"
      fails=$((fails+1)); return
    fi
    if grep -q "TB PASSED" "$log" && ! grep -qE "\*\* (Error|Failure)" "$log"; then
      echo "PASS  $tag"; return
    fi
  fi
  echo "FAIL  $tag   ($(grep -m1 -E 'Error|Failure' "$log" | cut -c1-110))"
  fails=$((fails+1))
}

raster raw_prog
raster raw_lace  -gG_FIELD_X2=125
raster raw_quant -gG_FIELD_X2=125 -gG_VS_QUANT=true
raster dbl_prog  -gG_DOUBLED=true
raster dbl_lace  -gG_DOUBLED=true -gG_FIELD_X2=125

if [ "$fails" -eq 0 ]; then echo "ANALOG POSITIONER: all rasters PASS"; else echo "ANALOG POSITIONER: $fails raster(s) FAILED"; fi
exit "$fails"
