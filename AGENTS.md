# AExp — Amiga 500 for MEGA65: instructions for coding assistants

This file is for AI coding assistants working in this repository (`CLAUDE.md`
includes it). It holds current facts and rules, not history. Keep it that way:
when something changes, rewrite the affected statement in the present tense
instead of appending a log entry. Deep material lives in the tracked developer
docs listed in section 2; point there instead of duplicating it here.

Make no assumption about who the user is. Section 6 lists the people who
appear in issues, commits and comments.

## 1. What this is and where it stands

- A port of the MiSTer Minimig-AGA core to the MEGA65, scoped to an
  **Amiga 500: OCS only, PAL only, cycle-exact 68000 (fx68k), Kickstart 1.3**.
  512 KB Chip RAM + 512 KB Slow RAM (OSM toggle "Slow RAM (A501)") + 256 KB
  Kickstart, all in FPGA block RAM. No SDRAM, no Fast RAM, no IDE, no AGA/ECS.
- Kickstart comes from the SD card, `/amiga/kick.rom` (raw 256 KB dump, no
  byte swapping) and is **mandatory**: without it the core stops at a fatal
  error screen (`C_CRTROMTYPE_MANDATORY` in `CORE/vhdl/globals.vhd`).
- Built on the MiSTer2MEGA65 (M2M) framework **V2.0.1, in a modified copy**
  that lives in `M2M/` as part of this repository (rule 8).
- Boards: MEGA65 R3/R3A, R4, R5, R6, one Vivado project each.
- **Status:** Version 1 is released (tag `V1`, commit `46ef60c`, July 2026).
  Version 2 is in beta; the current build is the one named by `CORE_VERSION`
  in `CORE/vhdl/config.vhd` (`WIP-V2-B2` at the time of writing).
  `VERSIONS.md` is the authoritative feature list per release, and
  everything it lists is shipped and works: among others the simulated ADF
  drives (read and write), up to three drives, the Hardware Floppy reading
  and writing real disks (Copylock originals included), DVI mode, the audio
  filters, the interlace flicker fixer, screen adjustment. The flicker-free
  HDMI clock servo (menu toggle, default on) shipped with V1 as well. Do not
  re-open any of these as "unverified".
- **Version names:** releases are `V<n>` (`V<n>.<m>` for a point release);
  alphas are `WIP-V<n>-A<k>`, betas `WIP-V<n>-B<k>` (`make_release.py` also
  accepts an `X<m>` suffix). Git tags use exactly these names.
- **Tag trap:** `V1.0.0`, `V2.0.0`, `V2.0.1` and similar are **M2M framework**
  releases, never AExp releases. If you add sy2002/MiSTer2MEGA65 as a remote
  to compare, set `remote.<name>.tagOpt --no-tags` so that its tags never
  enter this repository. Any "V2.0.1" in a comment means the framework.
- **`CORE_VERSION` is the single version source.** The welcome and help
  screens, `CORENAME` and the settings file `/amiga/aexp-<CORE_VERSION>.cfg`
  (`CFG_FILE`) derive from it. A new version therefore needs a new settings
  file (rule 13). Every alpha/beta has a row in `doc/inofficial.md` with its
  commit hash, and `make_release.py` refuses to package a WIP build without
  it.

## 2. Where the knowledge lives

| Path | Content |
|---|---|
| `README.md` | User manual; also the start page of the documentation website |
| `VERSIONS.md` | Release notes per version. Maintained by the project owner; change it only when asked |
| `doc/inofficial.md` | List of WIP builds (name, date, commit, summary). Maintained by the project owner; change it only when asked |
| `doc/developers.md` | Building from source, the settings file |
| `doc/developers/architecture.md` | **Start here.** Layering, repository layout, clock domains and CDC, QNICE devices, HyperRAM map, firmware callbacks, the core rules, every modification of the M2M framework (section 8), the Minimig submodule, the MiSTer HPS code AExp replaces, mouse and joystick (POT-line buttons, presence latch), local checks |
| `doc/developers/floppy-adf.md` | Simulated ADF drives: MFM, the engine, three drives, write-back, the arm-state invariant, verification |
| `doc/developers/hardware-floppy.md` | The MEGA65's internal drive as a real Amiga drive: read chain, data separators, framing hold, Copylock/`DSKBYTR`, write datapath and its safety, diagnostics device `0x0104`, the field-report protocols |
| `doc/developers/timing_closure.md` | The HyperRAM read-capture hold miss, why the IDELAY is fixed, the build re-roll |
| `doc/developers/audio.md` | Audio path, A500/LED filters, stereo mix, volume |
| `doc/developers/hdmi_latency.md` | HDMI latency and the flicker-free clock servo |
| `doc/developers/minimig_fdd.cpp`, `minimig_config.cpp` | Verbatim reference copies from `Main_MiSTer` commit `c738023`: the software models of `adf_track_engine.vhd` and `amiga_config.vhd`. Line numbers in the engine's comments refer to this copy |
| `CORE/Minimig_MiSTerMEGA65/README.md` | The fork's branch model and its list of modifications |
| `doc/*.md` (user docs) | `drives.md`, `hardware_floppy.md`, `keyboard.md`, `audio.md`, `screen_adjust.md`, `retrotubes.md`, `RTC.md` |
| `doc/make_doc.md` | The website builder `doc/make_doc.py` |
| `doc/developers/tools.md` | The host tools in `tools/` (menu and firmware checkers, Hardware Floppy diagnostics decoder, ADF compare, flux analysis) and the testbenches in `CORE/sim/`: what each checks, how to run it, runtimes, the pre-synthesis gate |
| [M2M Wiki](https://github.com/sy2002/MiSTer2MEGA65/wiki) | The framework, the QNICE debug console |
| [C64MEGA65](https://github.com/MJoergen/C64MEGA65) | The reference M2M port; origin of the mount-device, physical-drive and menu-dependency patterns. Consult it for any M2M integration pattern |

**Before touching X, read Y:**

| If you touch | Read first |
|---|---|
| Anything in the floppy stack (`adf_*`, `physical_fdd/`, `paula_floppy.v`, the write-back firmware, drive menu lines) | `floppy-adf.md` and `hardware-floppy.md`, then rule 15 |
| The firmware's ADF write-back (`HANDLE_CORE_IO`, `FLUSH_ADF_STEP`, `PREP_LOAD_IMAGE`) | `floppy-adf.md` sections 8 and 9 |
| `config.vhd` menu items, groups, help pages | Rules 10, 11, 13 |
| `m2m-rom.asm` | Rules 10–14, `architecture.md` section 6 |
| Anything in `M2M/` | Rule 8 and `architecture.md` section 8 |
| Constraints, build scripts, a failed build | Rules 5 and 9, `timing_closure.md` |
| Clocks, CDC, new QNICE devices | `architecture.md` sections 4 and 5, rules 3–5 |
| The Minimig submodule | Rule 16, `architecture.md` section 9 |
| Audio | `audio.md` |
| Video pipeline, HDMI, analog modes | Rule 6, `hdmi_latency.md`, `doc/screen_adjust.md` |
| A user's floppy problem report | `hardware-floppy.md` section 9 |

## 3. Hard rules

Each rule was learned the expensive way. Rules 3 and 11 are cited by number
in source comments ("CLAUDE.md rule 3", "hard rule 11 of AGENTS.md"): keep
the numbering stable and append new rules at the end.

1. **Keep the four `.xpr` files in sync.** Every file-list or file-type change
   goes into `CORE/CORE-R3.xpr`, `-R4`, `-R5` and `-R6` in the same commit.
   Expected per-board deltas, do not "fix" them: the board top
   `M2M/vhdl/top_mega65-r<n>.vhd`, the board constraints `M2M/MEGA65-R<n>.xdc`,
   R3's `max10.vhdl` + `pcm_to_pdm.vhdl` versus R4+'s `audio.vhd`, and
   `M2M/vhdl/vdrives.vhd`, which R4–R6 list and R3 does not (AExp never
   instantiates it; `C_VDNUM = 0`).
2. **`.xpr` `SFType` tokens:** only `VHDL2008`, `SVerilog`, or no attribute
   (inferred from the extension). Anything else, such as `"Verilog"` or
   `"SystemVerilog"`, makes Vivado segfault when it opens the project.
3. **Block RAM is full** (364 or 365 of 365 tiles, depending on the build;
   check `Block RAM Tile` in `*_utilization_placed.rpt`). New buffers go into
   HyperRAM or distributed LUTRAM, never block RAM. The 320 Amiga tiles are an
   exact mapping with nothing left to squeeze; re-enabling IDE (+8 tiles) does
   not fit.
4. **No QNICE ports on spread-out block RAM.** QNICE devices are accessed on
   the falling clock edge, a 10 ns half-period budget, and the address bus
   cannot reach 256 tiles spread over the die in time (it once cost
   WNS −0.757 ns). Only the Kickstart ROM (64 tiles) has a QNICE port; devices
   `0x0101`/`0x0102` (Chip/Slow RAM) stay reserved and unwired. The CPU-facing
   data path of every QNICE device shares that half-period cone: give a new
   register bank a registered readout (the `physical_fdd_diag` pattern) rather
   than a wide combinational mux.
5. **The timing margin is thin.** Judge a build by
   `*_timing_summary_postroute_physopted.rpt` (post-route `phys_opt_design` is
   enabled on all four boards; `_routed` is the state before it) or, after a
   re-roll, by `mega65_<board>_reroll_timing.rpt`; WNS and WHS must both be
   ≥ 0. Load-bearing constraints in `CORE/CORE.xdc`:
   - the ascal FIFO CDC `set_max_delay -datapath_only` bounds (they cut
     phantom inter-clock requirements and the router's hold-fix detours);
   - the clock-pair `set_max_delay -datapath_only 20.000` between `qnice_clk`
     and `main_clk` in both directions. Deliberately not a false path: a
     clock-pair false path would override the object-scoped `cdc_stable`
     bounds in `M2M/common.xdc`;
   - the flicker-free leg: `set_case_analysis` on
     `CORE/hr_core_speed_reg[0]/Q` and the generated clock on
     `CORE/clk_gen/i_clk_fast/CLKOUT0`. Renaming `hr_core_speed` or
     `i_clk_fast` makes these silently match nothing; `build_bitstream.tcl`
     fails such a build with `GATE` lines.

   Framework timing fixes go into `CORE/CORE.xdc`, never into
   `M2M/common.xdc` or the board XDCs.
6. **Video into the framework:** syncs active-high (Minimig's are active-low
   and inverted in `main.vhd`); blanks must cover the syncs. The video clock is
   `main_clk` (28.375 MHz); the pixel enable is frame-locked, 7.09 MHz (4
   clocks per pixel) in all-lowres frames and 14.19 MHz (2 clocks per pixel)
   in frames with hires lines. MiSTer's Hq2x line doubling needs at least 4
   and drops every second hires pixel at 2, so the analog scandoubler runs as
   a plain line doubler: keep `VGA_LINEDOUBLER` in `globals.vhd` `true`
   (rule 8, `line-doubler`). The enable is **never** 28 MHz: the line doubler
   needs two clocks per pixel, and ascal accepts at most `IHRES` 1024 pixels
   per line. `qnice_scandoubler_o` is `'1'` for Standard VGA and `'0'` in the
   two 15 kHz modes, decoded from the VGA radio in `mega65.vhd`. Keep
   `qnice_ascal_triplebuf_o` at `'0'`: triple buffering grows the frame buffer
   to 6 MB, overwrites the ADF pools and breaks flicker-free.
7. **`OPTM_PAUSE` stays `false`**: the core does not implement `pause_i`.
8. **`M2M/` is a modified framework; do not modify it further** unless there
   is no other way, and then only with the project owner's explicit sign-off.
   Never merge or copy a newer M2M release into it: some AExp changes carry
   no tag, so a framework upgrade is a change-by-change port along
   `architecture.md` section 8, not a merge.
   Every sanctioned change carries an `M2M-UPSTREAM <name>` tag
   (`grep -rn 'M2M-UPSTREAM' M2M CORE`), and new framework inputs default to
   values that leave other M2M cores bit-identical. The ten named exceptions:
   - `interlace` — `video_fl_i` field flag through to ascal `i_fl`,
     `INTER => true` (HDMI weave deinterlacing);
   - `core-io-hook` — `HANDLE_CORE_IO`, an extra mandatory firmware callback
     run in the Shell main loop and in every blocking wait loop;
   - `screen-center` — HDMI crop offsets, analog overscan soft blank, analog
     pan via `analog_positioner.vhd`;
   - `osm-hotkey` — core-selectable key(s) that open the menu;
   - `osm-scale` — `RAM_STYLE_SELECT` for `tdp_ram`, ascal ping-pong buffers
     pinned to LUTRAM (the untagged 8x8-font OSM renderer belongs to it);
   - `raw-joyports` — DB9 lines through 2-FF synchronizers, no 1 ms debounce;
   - `floppy-pins` — the board tops route the internal floppy connector into
     the core, read pins and the write pins `f_wdata`/`f_wgate` alike;
   - `osm-deps` — menu-line dependencies (`OPTM_DEP`/`OPTM_DEP2`,
     `optm_deps.asm`);
   - `live-text` — `OPTM_LIVE_TEXT`, in-place repaint of part of a menu line;
   - `line-doubler` — a plain line doubler in place of Hq2x in the analog
     scandoubler (`LINEDOUBLER` in `scandoubler.v`), selected by the core
     constant `VGA_LINEDOUBLER` in `globals.vhd`; needs only 2 clocks per
     pixel (rule 6).

   Further differences (the tagged bug fixes `qnice2hyperram-watchdog` and
   `gencfg-r7`, the HyperRAM pblock in `M2M/MEGA65-R<n>.xdc`, the
   `M2M$LOAD_POLYPHASE` copy in `m2m-rom.asm`) are listed in `architecture.md`
   section 8.11. Never re-sync `M2M/` from the template; moving to M2M V2.1.0
   is planned future work.
9. **Never change the HyperRAM read-capture IDELAY** (`IDELAY_VALUE => 20` in
   `M2M/vhdl/controllers/hyperram/hyperram_rx.vhd`). It is field-calibrated
   across individual machines. Do not force or re-route the RWDS strobe and do
   not loosen the input-delay constraints either; all three move the sampling
   point. A small hold miss on `hr_d_io`/`hr_rwds` is placement luck, and
   `CORE/build_all.sh` re-rolls it (`timing_closure.md`).
10. **`make_rom.sh` scrapes VHDL with line-based `awk`: keep these constants
    on one line each.** `C_MENU_*` from `mega65.vhd` and the core's `OPTM_G_*`
    from `config.vhd` (value read as field 6 of
    `constant NAME : natural := 45;`) become `AEXP_OSM_*`/`AEXP_OPTM_G_*` in
    `osm_const.asm`; `C_VDNUM`, `C_CRTROMS_MAN_NUM`, `C_CRTROMS_AUTO_NUM`, the
    `C_ADF_*` geometry and `C_DEV_AMIGA_ADF0..2` from `globals.vhd` become
    `globals.asm` and the device symbols. The firmware has no hard-coded menu
    index. The generated `.asm` files are git-ignored; menu changes reach the
    ROM only through `make_rom.sh` (run by every synthesis).
11. **Every menu growth needs a QNICE heap rebudget.** `HELP_MENU`
    (`M2M/rom/options.asm`) builds the menu in `MENU_HEAP_SIZE`
    (`m2m-rom.asm`), and `FB_HEAP` (the file browser) starts right behind it,
    so every spare word costs browser capacity. The demand is
    `20 + len(OPTM_ITEMS) + 1 + 4 * OPTM_SIZE + 1` (struct, item string with
    `\n` counting 2, terminator, four per-item arrays) plus
    `(vdrives + submenus + manual ROMs + 1) * (OPTM_DX + 2)` for `OPTM_HEAP`.
    **Round up to the next 32-word boundary and no further.** When
    `MENU_HEAP_SIZE` changes, subtract the same delta from both `HEAP_SIZE`
    constants (debug and release) so the combined totals stay put. A shortfall
    is loud (`ERR_FATAL_HEAP1`/`ERR_FATAL_HEAP2` at boot and on every menu
    open), and the menu checker `tools/check_osm_menu.py` recomputes
    the demand statically; the current numbers are in the comment above
    `MENU_HEAP_SIZE`. **Firmware variables count too:** they sit below `HEAP`,
    so every added word pushes `HEAP` up and comes out of the stack. Check in
    `m2m-rom.lis` that `HEAP` + the combined release total stays below
    `VAR$STACK_START` (`0xFEE0`) by more than `STACK_SIZE`; the arithmetic is in
    the comment next to the release `HEAP_SIZE`.
12. **The firmware ROM must end below `0x7000`.** M2M maps the device window
    at `0x7000`–`0x7FFF`, so 28672 words are usable. `make_rom.sh` enforces it,
    with `END_OF_ROM` as the last ROM item before `.ORG 0x8000`; the build log
    prints `Shell ROM: N/28672 words.` (27533 at `WIP-V2-B1`).
13. **Menu structure (`config.vhd`):**
    - A line's position is the bit number that carries its state; inserting a
      line shifts every `C_MENU_*` constant behind it, by hand. The HDMI filter
      radio (`C_MENU_FLT_*`) is read by the firmware, not the HDL.
    - Group ids must be monotonically increasing; a new feature takes the next
      id. `OPTM_G_START` appears exactly once.
    - Defaults: exactly one `OPTM_G_STDSEL` per radio, every STDSEL line must
      be visible under the other groups' defaults, and at most one drive may
      default to Hardware Floppy (`DRV_ENFORCE_COUNT`/`DRV_STEAL_HW` do not
      run at boot). A changed default must also change the HDL that mirrors
      it: `drv_decode` and `qnice_hwf_map3_decode` in `mega65.vhd`, and the
      power-on value of `drv_map_applied` in `amiga_cold_boot.vhd` (a mismatch
      fires a cold boot at t=0).
    - `OPTM_DY` + 2 must not exceed 36 rows. Welcome and help pages print into
      a full-screen frame with 34 rows of 43 columns inside. Every help page
      has exactly 33 rows of at most 42 columns: the free last row and column
      keep the text off the border (row 34 visibly touches it), and the footer
      stays on rows 32 and 33 with a matching `(n/N)` counter.
      `tools/check_osm_menu.py` checks all of it. Page strings may contain
      `;`, so measure them with a string-aware scanner.
    - The README's blind key sequence for switching DVI on depends on the
      menu layout above the HDMI submenu and on the drive defaults; re-derive
      it when either changes.
    - After any menu change run `tools/check_osm_menu.py` and, if
      `OPTM_SIZE` changed, generate a fresh settings file (section 4). Never
      copy an older `.cfg` forward: the firmware accepts a file on its length
      alone, so a used file silently restores old selections.
14. **QNICE assembly pitfalls (`m2m-rom.asm`):**
    - The assembler wrapper runs the C preprocessor (`cc -xc -E`), so `'` and
      `"` are tokenised inside `;` comments: no possessive apostrophes (write
      "the X of Y"), and never split a quoted string across lines.
    - Only `ADD`, `ADDC`, `SUB`, `SUBC`, `SHL` and `SHR` write the carry flag;
      `MOVE` does not. Address arithmetic inserted between a 32-bit `ADD` and
      its `ADDC` silently eats the carry. Run `tools/check_firmware.py`
      after firmware changes.
    - Call monitor/OS functions (`MTH$`, `STR$`, `IO$`, …) through
      `SYSCALL(name, 1)`, never `RSUB` to the internal label, even when it
      resolves.
15. **Floppy data-safety invariants.** Each one prevents silent data loss on
    a user's disk or image:
    - The ADF write drain is unit-tagged: it aborts the moment Paula selects
      another unit, and `drain_unit` latched at drain start decides the commit
      address. An untagged drain writes one drive's data into another's image.
    - A drive is flushed only through its own FAT32 handle snapshot
      (`ADF_FDH0/1/2` via `ADF_FDH_TAB`), never through a shared "current"
      handle.
    - One image file may not be mounted into two drives (`ADF_DUP_CHECK`):
      each drive holds its own HyperRAM copy and the later flush overwrites
      the earlier.
    - No handle may stay FAT32-dirty across a return to the main loop. There
      is one sector buffer, its owner is tracked by address, and the file
      browser claims it without flushing.
    - The arm-state invariant of `floppy-adf.md` section 9 holds per drive: a
      drive is announced write-protected until its own mount completes and
      the firmware arms its `WR_EN`; `PREP_LOAD_IMAGE` force-flushes and
      disarms; SD-card changes disarm.
    - A Hardware Floppy write is owned per trackwr **episode**: ownership
      binds once, qualified by the real per-drive select line
      (`main_hwf_selected`, because Paula's priority-encoded `sel` field
      encodes "nothing selected" as `df0`), every later drain inherits it, and
      a physical drain never commits (`drain_commit = '0'`). An aborted
      episode stays dead; the read chain is held in reset for the whole
      episode.
    - The writer's gate conjunction (enable, selected, motor, streaming,
      tab-qualified `wr_ok`) and the disk's own tab are the only write
      guards; there is no runtime read-only switch. The post-DSKBLK drain hold
      (`mega65.vhd` holds SELECT and SIDE) and the writer's "no SELECT/SIDE
      abort after the session fell" ship together or not at all; STEP and DIR
      are never held.
16. **Minimig submodule conventions** (`CORE/Minimig_MiSTerMEGA65`, repo
    `sy2002/Minimig_MiSTerMEGA65`): `MiSTer` mirrors upstream unchanged,
    `develop` carries all MEGA65 changes and is what AExp tracks, `master`
    equals `develop` at each AExp release. Every change to an original file
    gets a dated provenance comment
    (`// MiSTer2MEGA65 (AExp Amiga 500 port), <Month Year>: ...`) with the
    original code kept as a comment next to it. Commit in the submodule on
    `develop` first, then record the new pointer in AExp.
17. **The QNICE submodule tracks `dev-V1.61`** (`.gitmodules` `branch`), not
    the 2024 commit the M2M V2.0.1 template pins. That branch carries the FAT32
    fixes the ADF write-back depends on (sector buffer written back before
    `DIR_OPEN`/`FILE_OPEN` reuse it; 32-bit sector-address overflow check).
    Update with `git submodule update --remote M2M/QNICE`; never let a
    template sync drag the pointer back.
18. **The QNICE tool binaries belong to the OS that runs Vivado.** The
    pre-synthesis hook runs `make_rom.sh` with `M2M/QNICE/assembler/qasm` and
    `qasm2rom` as built in place. In a working copy shared with a build host
    of another OS, do not rebuild them in place and do not run `make_rom.sh`:
    the `asm` wrapper deletes `m2m-rom.out`/`.rom` first and then fails on the
    foreign binaries. Use the native recipe in section 4. (`build_all.sh`
    runs an optional, git-ignored `CORE/make_qasm.sh` first if it exists and
    is executable, and stops with a hint to `make-toolchain.sh` if the
    assembler is missing or built for another OS.)

## 4. Build and verification

**Vivado 2022.2** (ML Standard, Artix-7 XC7A200T) runs on Linux or Windows
only, so it is usually not on the machine where the code is edited. Prepare
everything, then ask the user to build and return the logs.

- **Builds:** per board in the GUI (Generate Bitstream on
  `CORE/CORE-R<n>.xpr`; the pre-synthesis hook `CORE/m2m-rom/synth_pre.tcl`
  rebuilds the firmware), or in batch with `CORE/build_all.sh` (`--help`),
  which writes `build_R<n>.log` with `RESULT` lines and re-rolls boards that
  only just missed timing (`timing_closure.md`).
- **What to request after a build:** `CORE/CORE-R<n>.runs/synth_1/runme.log`;
  from `impl_1/`: `*_utilization_placed.rpt`,
  `*_timing_summary_postroute_physopted.rpt`, `*_route_status.rpt`, and after
  a re-roll `mega65_<board>_reroll.txt` + `_reroll_timing.rpt`; the
  `build_R<n>.log` summary for batch builds. For per-module BRAM ask for
  `report_utilization -hierarchical`.
- **What to check in them:**
  - `Synth 8-3876` lines saying `microrom.mem` and `nanorom.mem` were "read
    successfully". A silent failure here gives a dead CPU and no error.
  - Amiga RAMs inferred as block RAM; `Block RAM Tile` ≤ 365.
  - `Synth 8-5835` ("BRAM over-utilized … implement using LUT-RAM") is
    routine at this fill level; it is a real failure only if implementation
    then cannot place or route.
  - WNS/WHS ≥ 0 from the post-route phys-opt report (rule 5); no `GATE`
    lines; route status fully routed.
  - `Shell ROM: N/28672 words.` (rule 12).
- **Settings file for a dev SD card:** from inside `M2M/tools`,
  `./make_config.sh aexp-<CORE_VERSION>.cfg auto` (`auto` reads `OPTM_SIZE`
  from `config.vhd`; type the `.cfg` suffix).
- **Releases:** `make_release.py` (generic M2M packager) with
  `CORE/release.toml` and the core-specific hooks in `CORE/release_hooks.py`
  (ships `aexp_screen.cfg` presets and `aexp_screen_cfg.py`). It validates
  `CORE_VERSION`, generates the settings file and checks `doc/inofficial.md`.
- **Documentation website:** every push of `README.md` or `doc/**` to
  `develop` rebuilds and publishes https://sy2002.github.io/AExp/
  (`.github/workflows/pages.yml`) unless `doc/DOC_FROZEN` exists. Docs on
  `develop` are therefore user-facing at once. `doc/make_doc.py check` builds
  it locally (see `doc/make_doc.md`).

**Local static checks before any Vivado round trip** (free tools: nvc, GHDL as
a second opinion, Icarus Verilog):

- **VHDL:** analyse with `nvc --std=2008` in dependency order, from a scratch
  work directory (nvc writes its library into the invocation directory):
  `M2M/QNICE/vhdl/tools.vhd`, `types_pkg`, `video_modes_pkg`, `tdp_ram`,
  `2port2clk_ram`, `cdc_stable`, `qnice_csr`, `qnice2hyperram`, the
  `memory/avm_*` + `axi_fifo` files, then `globals.vhd`, `config.vhd`, the
  `physical_fdd/` files (pkg first, top last), `adf_track_engine`,
  `adf_mount_wrapper`, `amiga_config`, `amiga_cold_boot`, `audio_filters`,
  `keyboard`, `clk`, `main`, `mega65`. `clk.vhd` and `mega65.vhd` need stub
  `unisim.vcomponents` (`MMCME2_ADV`, `BUFG`, `BUFGCE`, `BUFGMUX_CTRL`) and
  `xpm.vcomponents` (`xpm_cdc_async_rst`, `xpm_cdc_single`, `xpm_fifo_axis`)
  packages. `CORE/sim/run_nvc_chain.sh` runs this chain with the stubs in
  `CORE/sim/stubs/`.
- **Verilog:** `iverilog -g2012 -t null` over the Minimig sources AExp uses,
  with stubs for `dpram` and `fx68k`. Known noise: forward references, fx68k
  unpacked structs, zero-width-concat follow-ons.
- **Menu and firmware:** `tools/check_osm_menu.py` after any menu change,
  `tools/check_firmware.py` after any firmware change. Both must end with
  `all checks passed`.
- **Firmware assembly without the build host:** build the tools natively into
  a temp dir (`cc -O2 -o "$TMP"/qasm M2M/QNICE/assembler/qasm.c`, same for
  `qasm2rom.c`), then from `CORE/m2m-rom`:
  `cc -xc -E m2m-rom.asm | sed '/^#.*/d' > "$TMP"/t.asm && "$TMP"/qasm "$TMP"/t.asm "$TMP"/m2m-rom.out && "$TMP"/qasm2rom "$TMP"/m2m-rom.out "$TMP"/m2m-rom.rom`.
  This needs the generated include files of rule 10 to exist (any earlier
  `make_rom.sh` run). Its first `END_OF_ROM` + 1 words are identical to the
  build host's trimmed `m2m-rom.rom`.
- **Testbenches** live in `CORE/sim/`, one directory per area, each with its
  runner; `doc/developers/tools.md` lists them with runtimes.
  `CORE/sim/run_all.sh` is the pre-synthesis gate (both checkers, the nvc
  chain and every bench that finishes in minutes, about 6 minutes);
  `CORE/sim/run_long.sh` runs the full floppy regression, the write matrix,
  the write mutants, the Minimig beam-counter golden diff and the full
  scandoubler matrix, which take hours serially (set `JOBS`). The floppy
  benches are described in `hardware-floppy.md` section 11
  (`CORE/sim/floppy/run_fdd_regression.sh`, `run_write_matrix.sh`,
  `run_write_mutants.sh`). Others: drive-default cold boot
  (`CORE/sim/misc/`), the Minimig backports and the Copylock surface
  (`CORE/sim/minimig/`), keyboard, audio, analog positioner and the analog
  scandoubler (`CORE/sim/keyboard/`, `audio/`, `video/`).
- **Testbench discipline:** every new check gets a red control (show it
  fails on a mutant or on the old code) before its green counts; a mutant
  counts as killed only if the same cell is green on the unmutated design and
  it fails on an assertion, not a timeout; treat nvc's "older than its source
  file" warning as a failure (stale analysis); give each parallel run its own
  work directory; never edit a script while it runs.

## 5. Architecture cheat sheet

Full picture: `architecture.md` sections 2, 4 and 5.

- **Layering:** board top → `framework.vhd` (M2M: QNICE, SD, OSM, HyperRAM,
  video pipelines) + `CORE/vhdl/mega65.vhd` (clocks, BRAMs, QNICE devices,
  ADF mount devices, Hardware Floppy front end, OSM decoding) → `main.vhd`
  (replaces MiSTer's `Minimig.sv`: `amiga_config`, `adf_track_engine`,
  `keyboard`, `audio_filters`, video enables) → `minimig_m65.v`/`minimig.v`,
  `cpu_wrapper.v`/fx68k, `amiga_clk.v`.
- **Clocks:** `main_clk` 28.375 MHz (100 MHz × 56.75 / 5 / 40, −5.6 ppm vs
  PAL), dithered through a `BUFGMUX_CTRL` with the flicker-free twin
  28.4375 MHz (`i_clk_fast`) so that the average frame rate is exactly 50 Hz;
  `qnice_clk` 50 MHz (QNICE, ADF mount devices, the whole Hardware Floppy
  front end and writer); `hr_clk` 100 MHz (HyperRAM); framework video and
  audio clocks. There is no 113.5 MHz clock.
- **Amiga memory bus:** with a 68000 and no Fast RAM, all CPU and DMA traffic
  goes through Minimig's single SRAM-style port (`ram_addr[22:1]` word
  address + byte enables), banked by `minimig_sram_bridge.v`: Chip at
  `ram_addr[22:19] = "0000"`, Slow at `"1000"`, Kickstart at `"1111"` (bit 18
  ignored, the `$F8`/`$FC` mirror). Each memory is split into upper/lower
  8-bit lanes; the even byte is bits 15..8, so raw ROM dumps load unswapped.
- **QNICE devices** (`globals.vhd`): `0x0100` Kickstart, `0x0101`/`0x0102`
  reserved, `0x0103`/`0x0105`/`0x0106` ADF mount devices of `df0`/`df1`/`df2`
  (byte window into the image, `0xFFFE` write-back CSR, `0xFFFF` M2M load
  handshake), `0x0104` Hardware Floppy diagnostics (from the QNICE monitor:
  select it, then `M D 7000 707D`; `0x7001` reads the map version `000D`;
  `hardware-floppy.md` section 8).
- **Host channel:** `IO_UIO` carries `amiga_config.vhd`'s replay of the MiSTer
  HPS configuration after every reset (`0xF1` halt, `0xF3` OCS, `0xF4` 68000,
  `0xF5` memory incl. the Slow RAM bit, `0xF6`, `0xF7` drive count, `0xF8`,
  `0xF9` joystick swap, `0xF2` audio mix, `0xF1` release). `IO_FPGA` is
  Paula's floppy channel, served by `adf_track_engine.vhd`; `main.vhd`
  multiplexes the bus between the two.
- **HyperRAM** (8 MB, 8 KB windows, `C_HMAP_*`): `0x000`–`0x1FF` framework
  (ascal frame buffer in the first 2 MB), `0x200`/`0x280`/`0x300` the
  `df0`/`df1`/`df2` image pools (115 windows + guard window each), `0x3FF` top
  guard. `mega65.vhd` asserts the ordering at elaboration time. Core access
  pattern: `avm_fifo` CDC + `avm_arbit_general`.
- **Drives:** three units, each a Disk Image, the Hardware Floppy (at most
  one) or Off (`df0` never Off); default one drive, `df0` as Disk Image,
  because many games misbehave with more. The drive index 0..2 is at once the
  Amiga unit, manual ROM id, device selector, HyperRAM pool and firmware
  array index. A topology change cold-boots only the Amiga.

## 6. Working conventions

- **Commits:** the repo-local git config sets the author identity; use it as
  configured. Do not add `Co-Authored-By` trailers; AI assistance is credited
  in `AUTHORS`. Commit only when asked.
- **Code comments describe the present state.** Never narrate what was
  removed or changed; that belongs in commit messages.
- **Documents read as if they had always been right.** No narration of how a
  text was produced or corrected, no process meta. Keep only caveats about
  the subject itself.
- **Say "simulated", not "emulated",** for what the core does (the simulated
  Amiga, what the core simulates): it is FPGA hardware, not a software
  emulator. "Emulator" stays correct for real software emulators (the QNICE
  emulator, WinUAE) and third-party devices that imitate hardware.
- **Markdown must render in Marked 2 with MathJax inline math.** Outside code
  spans and fences: escape bare `$` as `\$` (two on a line become math), never
  write bare `==` (pairs turn the text between them into a yellow highlight,
  even across sections), put angle-bracket placeholders like `<name>` in
  backticks, watch stray `*`/`_`. Only give a code fence a language tag when
  all of its content is that language.
- **Debugging: classify before you theorise.** A failure pattern gets
  classified with measurements and a control before any theory. A near-100 %
  failure rate across independent inputs (disks, titles, testers) points at
  an internal, systematic cause; require a controlled reference test before
  blaming the inputs. For floppy field reports follow `hardware-floppy.md`
  section 9 exactly: control disk, X-Copy map, fresh diagnostics dumps,
  runtime A/B arms, flux.
- **When asked for something "like the C64 core",** read the C64MEGA65 code
  first and propose one concrete design in this project's vocabulary instead
  of abstract options.
- **Scope:** AExp is open-source preservation in the MAME/WinUAE tradition.
  Kickstart and trackdisk disassembly, copy-protection analysis (Copylock)
  and flux reverse engineering are in scope.
- **People:**
  - sy2002 — author of the M2M framework and of this port.
  - deft — MEGA65 project lead and Amiga demo author; provides test content
    and calibration data. Communicate with him in German; documents for him
    are German PDFs made with pandoc + xelatex (strip any English context
    header first).
  - dejavu4u2 — field tester of Hardware Floppy reading and writing (real
    A500/A500+ as referee, flux dumps); credited in `AUTHORS`.

## 7. Open work

Check `gh issue list -R sy2002/AExp --state open` for the live state. As of
`WIP-V2-B2`:

- **Version 2 release:** the beta is in field test; the release date in
  `VERSIONS.md` is still a placeholder. Documentation issues #31 (developer
  docs), #27 (user docs) and #26 (Minimig README + `minimig_fdd.cpp`) are open
  for V2.
- **#35/#36 hires on analog Standard VGA** (every second pixel column lost):
  fixed in `WIP-V2-B2` by the `line-doubler` framework change (rule 8),
  pending field confirmation.
- **#24 File browser failure** after many warm starts with large ADF
  collections (seen on V1; a long reset press clears it). Unclassified until
  the reporter supplies the exact fatal-error text and code.
- **#30 Wings of Death horizontal jitter** after the disk-2 swap, on HDMI and
  analog, every AExp build; MiSTer comparison pending. Labelled V3 or later.
- **#22 screen controls** and **#3 hard disk on SD card:** research, V3 or
  later.
- **Upstream Minimig** (issue #28 and the two reports attached to it; A500
  faithfulness decides every port). In: MiSTer PRs 230, 234, 236, commit
  `d16cd84`. Deferred: PR 242 (WinUAE-derived model, in no MiSTer release,
  only ever tested together with 234). Not ported as written: PR 235, since a
  real A500 mirrors the custom registers at `$C00000`–`$D7FFFF` and
  `$DE0000`; an A500-exact decode of our own is backlog (acceptance:
  WhichAmiga 1.4 and xSysInfo 0.6). `Main_MiSTer`'s September 2026 changes to
  the two reference `.cpp` files are not reconciled; diff against the copies
  in `doc/developers/` first.
- **Framework:** migrating to M2M V2.1.0 and dropping what it supersedes
  (rule 8). A third flicker-free clock for content above 50 Hz is designed
  (`clk.vhd` header) but not built.
- **Hardware Floppy:** DD media only; HD disks are out of scope on this
  mechanism.
