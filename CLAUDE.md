# AExp — Amiga 500 for MEGA65

Port of the MiSTer Minimig-AGA core to the MEGA65, scoped to an Amiga 500
OCS, built on the MiSTer2MEGA65 (M2M) framework V2.0.1.

**Status: ADF floppy milestone achieved (2026-07-03).** Read-only ADF
support verified on real R3 hardware: Workbench 1.3.2 boots to the
desktop, demoscene trackloaders run (State of the Art, Batman, TBL Eon).
Mount via OSM " ADF:" → Shell streams to HyperRAM (QNICE device 0x0103,
`adf_mount_wrapper.vhd`) → `adf_track_engine.vhd` serves Paula over the
IO_FPGA host channel with bit-exact minimig_fdd.cpp MFM encoding. Design
spec: `.research/INTEGRATION-SPEC-floppy-adf.md` (supersedes the vdrives
advice AND three details of `doc/floppy_milestone_brief.md`). Milestone 1
(Kickstart hand, 2026-06-10/11) preceded it. Timing closed (run 3: all
AExp-owned groups ≥ +0.24 ns; global WNS +0.017 ns sits on the framework
HyperRAM PHY path). Everything below is the distilled project knowledge —
the deep material lives in `doc/` (see "Key documents").

## The emulated machine

- Amiga 500, **OCS only** (no ECS/AGA), **PAL only**, 68000 (fx68k,
  cycle-exact)
- 512 KB Chip RAM ($000000–$07FFFF) + 512 KB Slow RAM ($C00000–$C7FFFF,
  the "trapdoor" expansion) + 256 KB Kickstart 1.3 — **all in FPGA BRAM**,
  no SDRAM involved (R3 has none; R4+ SDRAM is unused)
- Kickstart is loaded from SD card at boot: `/amiga/kick.rom` (raw 256 KB
  dump, big-endian, no byte swapping), **mandatory** — missing file =
  fatal error screen, core never starts (`C_CRTROMTYPE_MANDATORY` in
  `CORE/vhdl/globals.vhd`)
- One core clock: **28.375 MHz** (PAL ideal 28.37516, −5.6 ppm), MMCM in
  `CORE/vhdl/clk.vhd` (100 MHz × 56.750 / 5 / 40). No 113.5 MHz clock —
  everything SDRAM/turbo/AGA that needed it is out of scope.
- Floppy: df0 with read-only ADF mount from the OSM (image staged in
  HyperRAM at word 0x200000 = `C_HMAP_ADF_DF0`; always reported
  write-protected; Amiga-initiated writes are drained and discarded).
  No write support, no df1..df3, no mouse yet, no IDE. Keyboard +
  joysticks work.

## Repository map

- `M2M/` — the framework. **NEVER modify.** Framework fixes go into
  `CORE/CORE.xdc` (constraints) or get documented for upstreaming.
  Git remote `upstream` = sy2002/MiSTer2MEGA65 (master = V2.0.1).
- `CORE/vhdl/` — the port (all files ours):
  - `mega65.vhd` — BRAM lanes (2×256K×8 chip, 2×256K×8 slow, 2×128K×8
    kick), banked-address decode, QNICE devices 0x0100 (kick) + 0x0103
    (ADF), HyperRAM plumbing (avm_fifo CDC + 2-master arbiter →
    hr_core_*), OSM wiring
  - `main.vhd` — wraps minimig_m65 + cpu_wrapper + amiga_clk; fx68k phase
    enables, frame-locked video CE, sync inversion, reset mapping, host
    bus mux (amiga_config ↔ adf_track_engine) + avm_cache
  - `amiga_config.vhd` — FSM replaying MiSTer's HPS config via the userio
    protocol after every reset (0xF1=0x07 halt+reset, 0xF3=OCS,
    0xF4=68000, **0xF5=0x04** = 512K+512K, 0xF6/0xF7/0xF8/0xF9/0xF2=0,
    0xF1=0x00 release)
  - `adf_mount_wrapper.vhd` — QNICE device 0x0103: byte-window bridge
    into HyperRAM + M2M CSR (window 0xFFFF) + ADF size validator
    (160–166 tracks × 5632 bytes; "mounted"+track count → cdc_stable)
  - `adf_track_engine.vhd` — Paula floppy host service (MiSTer HandleFDD
    in hardware): 1 ms poll + drive-status re-announce, per-sector MFM
    streaming with status-bit-8 flow control, write drain; the protocol
    contract is documented in its header
  - `keyboard.vhd` — MEGA65 keys → raw Amiga scancodes (kms_level toggle)
  - `clk.vhd`, `globals.vhd`, `config.vhd` (OSM menu — bit = line number,
    must match `C_MENU_*` constants in mega65.vhd)
- `CORE/Minimig_MiSTerMEGA65/` — git submodule, upstream
  MiSTer-devel/Minimig-AGA_MiSTer. Branch **develop** carries all
  Xilinx/MEGA65 changes; master mirrors upstream. Every change to
  original files has a dated provenance comment with original code kept
  commented out. `rtl/minimig_m65.v` is our VHDL-friendly rename shim
  (minimig.v has leading-underscore ports = illegal VHDL identifiers).
- `CORE/CORE-R{3,4,5,6}.xpr` — one Vivado project per board.
- `doc/` — the knowledge base. `.research/` — untracked local research
  notes (integration specs, review reports); never committed.

## Hard rules (each learned the expensive way)

1. **Keep all four .xpr files in sync** — every file-list or file-type
   change goes to R3+R4+R5+R6 in the same commit. Expected per-board
   deltas (do NOT "fix"): board top, board XDC, R3 `max10.vhdl` +
   `pcm_to_pdm.vhdl` vs R4+ `audio.vhd`.
2. **.xpr SFType tokens**: only `VHDL2008`, `SVerilog`, or *no attribute*
  (extension-inferred). Anything else (e.g. "Verilog", "SystemVerilog")
  makes Vivado **segfault on project open** (hs_err with
  `HDDASrcFileType::getId`).
3. **BRAM is at 363.5/365 tiles — full.** All future buffers (ADF images,
   sector buffers, monitor ROMs) MUST live in HyperRAM. Re-enabling
   IDE (+8 tiles) does not fit. The 320 Amiga tiles are an exact mapping,
   nothing left to squeeze.
4. **No QNICE ports on die-spread BRAMs.** QNICE reads/writes RAMs on the
   falling clock edge = half-period (10 ns) budget; the address bus
   cannot reach 256 spread tiles in time (cost us WNS −0.757). Only the
   kick ROM (64 tiles) has a QNICE port.
5. **Timing margin is thin (+0.387 ns).** Check the timing summary after
   every build. The ascal FIFO CDC constraints in `CORE/CORE.xdc`
   (set_max_delay -datapath_only) are load-bearing — they cut phantom
   ps-requirement inter-clock paths AND the hold-fix router detours.
6. **Video into the framework**: active-HIGH syncs (minimig outputs are
   active-low — inverted in main.vhd), blanks must cover syncs, video CE
   is frame-locked 7.09/14.19 MHz and **never** 28 MHz (M2M line buffers:
   video_mixer LINE_LENGTH=768, ascal IHRES=1024),
   `qnice_scandoubler_o='1'` (15.625 kHz core!).
7. **OPTM_PAUSE stays false** — pause_i is not implemented in the core.
8. Commit as **sy2002 <code@sy2002.de>** (repo-local git config is set).
   Keep the `Co-Authored-By: Claude` trailer.
9. Do not delete `/tmp/claude-501` task outputs (deny rules in
   `.claude/settings.local.json`); tell workflow subagents not to run
   cleanup commands.
10. Changing `C_VDNUM`/`C_CRTROMS_*_NUM` in globals.vhd or `m2m-rom.asm`
    ⇒ rebuild the firmware (`CORE/m2m-rom/make_rom.sh` scrapes globals
    via awk — keep those constants single-line). Changing `OPTM_SIZE`
    ⇒ regenerate the settings file (`M2M/tools/make_config.sh`).

## Build & verification workflow

- **No Vivado on this Mac.** It runs in the user's Parallels Ubuntu VM on
  a shared folder. Prepare everything, then ask the user to synthesize
  and return: `CORE/CORE-R3.runs/synth_1/runme.log`,
  `impl_1/*_utilization_placed.rpt`, `impl_1/*_timing_summary_routed.rpt`,
  `impl_1/*_route_status.rpt`. Per-module BRAM: ask for
  `report_utilization -hierarchical`.
- **Pre-build the QNICE firmware on the Mac** before every synthesis
  (`cd CORE/m2m-rom && ./make_rom.sh`) — the Vivado pre-synth hook can
  fail silently in VM setups. Toolchain (one-time):
  `M2M/QNICE/tools/make-toolchain.sh`.
- **Local static checks before any Vivado round-trip** (installed:
  nvc 1.21, ghdl 5.1, iverilog): analyze all CORE VHDL with
  `nvc --std=2008` in dependency order (M2M packages first: tools.vhd,
  types_pkg, video_modes_pkg, tdp_ram, 2port2clk_ram); clk.vhd/mega65.vhd
  need stub `unisim`/`xpm` vcomponents packages (recipe in memory and in
  doc/how_to_port.md §3.J). iverilog `-g2012 -t null` over the kept
  Verilog set with stubs for `dpram` and `fx68k`. Known noise to ignore:
  forward references, fx68k unpacked structs, zero-width-concat
  follow-ons.
- Synthesis log checks: `microrom.mem`/`nanorom.mem` "read successfully"
  (silent failure = dead CPU with no error), Amiga RAMs as block RAM,
  `Synth 8-5835` = BRAM overflow. Vivado OOM in the VM: close the
  implemented design in the GUI before relaunching a run.
- Expected-warnings list and full log-reading guide:
  `doc/synthesis-handoff.md`.

## Architecture cheat sheet

- **Memory bus**: with 68000 + no fast RAM, ALL memory traffic (CPU +
  chipset DMA) flows through minimig's single SRAM-style port
  (`ram_addr[22:1]` word address + `_bhe/_ble/_we/_oe`). The address is
  BANKED by `minimig_sram_bridge.v`: chip at `[22:19]="0000"`, slow at
  `[22:19]="1000"`, kick at `[22:19]="1111"` (bit 18 ignored = F8/FC
  mirror). 1-cycle BRAM latency meets the 7.09 MHz bus easily; read-mux
  select is registered to match.
- **QNICE device bus**: `qnice_dev_id_i` ≥ 0x0100, 4k windows, byte
  addresses; kick = 0x0100 (lane U = even byte = bits 15:8, so raw ROM
  dumps load unmodified); 0x0101/0x0102 reserved (chip/slow, unwired).
- **Host/userio channel**: `IO_UIO` carries config commands (driven by
  amiga_config.vhd); `IO_FPGA` is Paula's floppy channel (tied 0 —
  the future floppy service and the RamDump upload engine plug in here /
  via cmd 0xF0 mem_write through the halted m68k_bridge).
- **HyperRAM**: 8 MB, Avalon-MM via `hr_core_*` ports (currently tied
  off), 100 MHz, ~9 cycles latency after CDC, arbiter shared with the
  ascal framebuffer. Core address space from `C_HMAP_DEMO` (0x0200, 4kW
  units). Pattern for core→HyperRAM: avm_cache + avm_fifo CDC (reference:
  C64MEGA65 REU chain).
- **Reference port**: /Users/mirko/.dev/MEGA65/C64MEGA65 — consult it for
  every M2M integration pattern (vdrives, CRT/PRG loaders, OSM, LEDs).

## Roadmap (doc/next_tests.md has details)

1. **Floppy: DONE 2026-07-03** (read-only MVP, verified on hardware).
   Before touching floppy code, read `.research/INTEGRATION-SPEC-floppy-adf.md`
   — it supersedes doc/floppy_milestone_brief.md in three verified points
   (DEVICE-type mount, bit-8 flow control not IO_WAIT, disk_present
   re-announce per poll). Future increments: write support (protocol
   groundwork documented in the spec), df1 (HyperRAM window
   `C_HMAP_ADF_DF1` reserved), mount-status OSM feedback.
2. **DiagROM test round** — zero code: 256 KB DiagROM as /amiga/kick.rom
   exercises slow RAM, keyboard, audio, CIAs (diagrom.com).
3. **RamDump loader** — run deft's demo without floppy (possibly obsolete
   now that ADFs boot — confirm with deft whether .A5R is still wanted):
   `doc/ramdump_format.md` (.A5R format: 192-byte header with full CPU
   context D0-D7/A0-A6/USP/SSP/SR/PC, segment table, RTE-based launcher
   entry) + `doc/demo_delivery_spec.md` (German delivery contract for
   deft, PDF is tracked). Loader = OSM manual-load → QNICE→main CDC FIFO
   → upload engine drives userio 0xF0 → launcher ROM replaces kick.
   Hardware state deliberately NOT restored (V1); brief color flicker OK.
4. Pending decision: publish to GitHub as sy2002/AExp (plan exists:
   fork Minimig upstream → sy2002/Minimig_MiSTerMEGA65, fix .gitmodules
   URL, add origin, push master+develop).

## Key documents (read before working)

- `doc/how_to_port.md` — THE reference (~4800 lines): M2M architecture,
  130-step porting walkthrough, Quartus→Vivado pattern catalog (Part III,
  grep it for any Vivado error), debugging playbook, port tables.
- `doc/synthesis-handoff.md` — build/run history, expected warnings,
  timing-closure war story, OOM lesson.
- `doc/next_tests.md`, `doc/ramdump_format.md`,
  `doc/demo_delivery_spec.md` — roadmap and content pipeline.
- `.research/` (local only) — integration specs and agent review reports
  from the porting sessions.

## People & communication

- The user IS sy2002 — author of the M2M framework and co-author of
  C64MEGA65. Expert level; framework questions can be asked directly.
- deft — MEGA65 project lead and Amiga demo author; provides test
  content (RamDump deliveries). Communication with deft is in German;
  documents intended for him: German, PDF via pandoc + xelatex
  (both installed; strip the English context header first).
