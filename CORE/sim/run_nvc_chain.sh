#!/usr/bin/env bash
# Static check of all CORE VHDL with nvc, the cheapest gate before a Vivado run.
#
# Analyses the M2M packages and the framework files the core depends on, then
# every file in CORE/vhdl in dependency order, against stub unisim/xpm
# libraries (CORE/sim/stubs) so that clk.vhd and mega65.vhd analyse outside
# Vivado, and finally elaborates config.vhd. The CORE file list is in the
# script; a .vhd file under CORE/vhdl that is missing from it fails the run. A menu edit that leaves
# OPTM_GROUPS with more or fewer than OPTM_SIZE entries fails here ("expected
# at most N positional associations" or "missing choice for element N").
#
# Usage: CORE/sim/run_nvc_chain.sh [workdir]
#   workdir defaults to a fresh temporary directory. nvc writes its libraries
#   there, never into the repository. Runtime: a few seconds.
# Exit status 0 only if analysis and elaboration are clean.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# a work directory must exist or contain a slash, so a typo cannot become one
if [ $# -gt 1 ]; then echo "usage: $0 [workdir]" >&2; exit 2; fi
case "${1:-}" in
  ""|*/*) ;;
  *) [ -d "$1" ] || { echo "unknown argument: $1 (usage: $0 [workdir])" >&2; exit 2; } ;;
esac
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/aexp-nvc-chain.XXXXXX")}"
mkdir -p "$W" || exit 2
W="$(cd "$W" && pwd)"
echo "work dir: $W"
cd "$W" || exit 2
rm -rf "$W/work" "$W/unisim" "$W/xpm" "$W"/*.log
NVC="nvc --std=2008 --work=work:$W/work -L $W"

$NVC --work=unisim:"$W/unisim" -a "$HERE/stubs/unisim_stub.vhd" > "$W/stub.log" 2>&1 &&
$NVC --work=xpm:"$W/xpm" -a "$HERE/stubs/xpm_stub.vhd" >> "$W/stub.log" 2>&1 ||
  { echo "NVC CHAIN: the stub libraries do not analyse"; cat "$W/stub.log"; exit 1; }

M=$ROOT/M2M/vhdl
C=$ROOT/CORE/vhdl

# CORE/vhdl in dependency order, relative to $C
CORE_FILES="globals.vhd config.vhd
  physical_fdd/physical_fdd_pkg.vhd physical_fdd/physical_fdd_inputs.vhd
  physical_fdd/physical_fdd_mfm_gaps.vhd physical_fdd/physical_fdd_mfm_quantise.vhd
  physical_fdd/physical_fdd_bits.vhd physical_fdd/physical_fdd_wfifo.vhd
  physical_fdd/physical_fdd_writer.vhd physical_fdd/physical_fdd_diag.vhd
  physical_fdd/physical_fdd_top.vhd
  adf_track_engine.vhd adf_mount_wrapper.vhd amiga_config.vhd
  amiga_cold_boot.vhd audio_filters.vhd keyboard.vhd clk.vhd main.vhd
  mega65.vhd"

# a new VHDL file must be added to the list above, or it would go unchecked
missing=0
for f in $(cd "$C" && find . -name '*.vhd' | sed 's#^\./##' | sort); do
  case " $(echo $CORE_FILES) " in
    *" $f "*) ;;
    *) echo "not in the chain: CORE/vhdl/$f"; missing=$((missing + 1)) ;;
  esac
done
if [ "$missing" -ne 0 ]; then
  echo "NVC CHAIN: FAILED - add the file(s) to CORE_FILES in $0"
  exit 1
fi

core_paths=()
for f in $CORE_FILES; do core_paths+=("$C/$f"); done

$NVC -a \
  "$ROOT/M2M/QNICE/vhdl/tools.vhd" "$M/controllers/HDMI/types_pkg.vhd" \
  "$M/av_pipeline/video_modes_pkg.vhd" \
  "$M/tdp_ram.vhd" "$M/2port2clk_ram.vhd" "$M/cdc_stable.vhd" \
  "$M/qnice_csr.vhd" "$M/qnice2hyperram.vhd" "$M/memory/avm_cache.vhd" \
  "$M/memory/axi_fifo.vhd" "$M/memory/avm_fifo.vhd" "$M/memory/avm_arbit.vhd" \
  "$M/memory/avm_arbit_general.vhd" \
  "${core_paths[@]}" \
  > "$W/chain.log" 2>&1
rc=$?
errs=$(grep -c "^\*\* Error" "$W/chain.log")
echo "analysis: exit $rc, $errs error(s)"
if [ "$rc" -ne 0 ] || [ "$errs" -ne 0 ]; then
  sed -n '1,40p' "$W/chain.log"
  echo "NVC CHAIN: FAILED"
  exit 1
fi

$NVC -e config > "$W/elab_config.log" 2>&1
rc=$?
errs=$(grep -c "^\*\* Error" "$W/elab_config.log")
echo "elaboration of config: exit $rc, $errs error(s)"
if [ "$rc" -ne 0 ] || [ "$errs" -ne 0 ]; then
  sed -n '1,40p' "$W/elab_config.log"
  echo "NVC CHAIN: FAILED"
  exit 1
fi
echo "NVC CHAIN: all CORE VHDL analyses clean, config elaborates"
