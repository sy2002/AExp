#!/usr/bin/env bash
# Reset bench for M2M/vhdl/controllers/HDMI/video_out_clock.vhd (the
# M2M-UPSTREAM hdmi-clock-reset change): a long reset press must keep the HDMI
# pixel clock running on the backup clock, hold the HDMI encoder in reset during
# the press and let no edge of the unlocked MMCM reach the scaler's released
# output stage, neither at power-up nor after the press nor in a sweep of resets
# that land in every state of the machine, and the MMCM must end locked with the
# multiplexer on its output.
# tb_video_out_clock_reset.vhd runs against the behavioural cell models in
# unisim_models.vhd and the real cdc_stable.vhd.
#
# Red control: the bench also runs against a copy of the file with the two
# functional edits of the change undone (the template behaviour: cfg_rst asserted in the
# rsti branch, mmcm_rst driven by rsti). That run must FAIL.
#
# Usage: CORE/sim/video/run_voc_reset.sh [workdir]
#   workdir defaults to a fresh mktemp directory. Runtime: about 15 seconds.
# Exit status 0 only if the real file passes and the red control fails.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-voc-reset.XXXXXX")}"
mkdir -p "$W/logs" || exit 2
W="$(cd "$W" && pwd)"
echo "work dir: $W"
SRC="$ROOT/M2M/vhdl/controllers/HDMI/video_out_clock.vhd"

# the red control: undo the two edits of the change in a copy
python3 - "$SRC" "$W/voc_red.vhd" <<'PY' || { echo "RED CONTROL UNAVAILABLE: the edits of hdmi-clock-reset were not found in video_out_clock.vhd"; exit 2; }
import sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
a = """        clk_mux   <= '0';                                  -- backup clock first
        cfg_cnt   <= "11";
        cfg_state <= RESET_WAIT;                           -- then reset and reprogram
"""
b = """        cfg_rst   <= '1';
        cfg_state <= RESET;
"""
c = "  mmcm_rst <= cfg_rst;\n"
d = "  mmcm_rst <= cfg_rst or rsti;\n"
assert s.count(a) == 1 and s.count(c) == 1
pathlib.Path(sys.argv[2]).write_text(s.replace(a, b).replace(c, d))
PY

# run <tag> <dut file>: analyse, elaborate, simulate; prints PASS/FAIL per the bench verdict
run() {
  local tag="$1" dutf="$2" wd="$W/$1" log="$W/logs/$1.log"
  mkdir -p "$wd"
  local NVC="nvc --std=2008 --work=work:$wd/work -L $wd"
  if ! { $NVC --work=unisim:"$wd/unisim" -a "$HERE/unisim_models.vhd" &&
         $NVC -a "$ROOT/M2M/vhdl/cdc_stable.vhd" "$dutf" "$HERE/tb_video_out_clock_reset.vhd" &&
         $NVC -e -gVARIANT="$tag" tb_video_out_clock_reset &&
         $NVC -r --stop-time=100ms --exit-severity=failure tb_video_out_clock_reset; } > "$log" 2>&1; then
    if ! grep -q "TB FAILED" "$log"; then echo "BUILD/RUN ERROR $tag ($(grep -m1 -E 'Error|Fatal' "$log" | cut -c1-110))"; return 2; fi
  fi
  grep -q "older than its source file" "$log" && { echo "STALE $tag (re-analyse)"; return 2; }
  grep -E "Note:.*(long press|sweep:)" "$log" | sed 's/.*Note: [0-9]*[a-z]*s+[0-9]*: /  /'
  grep -E "Error:.*FAIL" "$log" | sed 's/.*Error: [0-9]*[a-z]*s+[0-9]*: /  /' | head -6
  if grep -q "TB PASSED" "$log"; then echo "PASS  $tag"; return 0; fi
  echo "FAIL  $tag"; return 1
}

status=0
run dut "$SRC"; green=$?
run red "$W/voc_red.vhd"; redrc=$?
echo "-------------------------------------------"
if [ "$green" -eq 0 ] && [ "$redrc" -eq 1 ]; then
  echo "VIDEO_OUT_CLOCK RESET: PASS (real file passes, red control fails as it must)"
else
  echo "VIDEO_OUT_CLOCK RESET: FAILED (real file exit $green, red control exit $redrc; expected 0 and 1)"
  status=1
fi
exit "$status"
