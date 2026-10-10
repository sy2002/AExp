# AExp architecture: a map of the core

This document is the starting point for anyone who works on the Amiga 500
core for the MEGA65. It explains how the core is put together, where each part
lives in the repository, which clock domains and buses connect the parts, and
which rules you have to respect when you change something. The deeper design
documents are listed at the [end](#13-where-to-read-next); this one tells you
which of them to open.

It assumes that you know VHDL, the Xilinx tools and the MEGA65, and ideally the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M) framework. It
does not assume that you know the Amiga. Where Amiga knowledge is needed, the
text explains it or points to the glossary in
[floppy-adf.md](floppy-adf.md#13-glossary-for-m2m-coders).

## Contents

1. [What the core simulates](#1-what-the-core-simulates)
2. [From the board to the Amiga chips](#2-from-the-board-to-the-amiga-chips)
3. [Repository layout](#3-repository-layout)
4. [Clock domains and crossings](#4-clock-domains-and-crossings)
5. [QNICE devices and the HyperRAM map](#5-qnice-devices-and-the-hyperram-map)
6. [The QNICE firmware](#6-the-qnice-firmware)
7. [Rules you have to know](#7-rules-you-have-to-know)
8. [The modified M2M framework](#8-the-modified-m2m-framework)
9. [The Minimig submodule](#9-the-minimig-submodule)
10. [The MiSTer HPS code and its replacements](#10-the-mister-hps-code-and-its-replacements)
11. [Mouse and joystick](#11-mouse-and-joystick)
12. [Checking your work before a Vivado run](#12-checking-your-work-before-a-vivado-run)
13. [Where to read next](#13-where-to-read-next)

---

## 1. What the core simulates

AExp is an Amiga 500 with the original chipset (OCS), PAL only. The CPU is
[fx68k](https://github.com/ijor/fx68k), a cycle-exact 68000. The chipset comes
from the MiSTer [Minimig-AGA](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer)
core, of which AExp uses only the A500 subset: no ECS, no AGA, no 68020, no
Fast RAM, no IDE.

The machine has three memories, and all three live in the FPGA's block RAM:

| Memory | Size | CPU address | Notes |
|---|---|---|---|
| Chip RAM | 512 KB | `$000000-$07FFFF` | shared by CPU and the custom chips |
| Slow RAM | 512 KB | `$C00000-$C7FFFF` | the A501 trapdoor expansion; can be switched off in the menu |
| Kickstart ROM | 256 KB | `$F80000-$FFFFFF` | loaded from the SD card at startup |

Nothing uses SDRAM. The R3 board has none, and the SDRAM of R4 and later is
left unused so that all boards run the same design.

The Kickstart ROM is not part of the core. The QNICE firmware loads it from
`/amiga/kick.rom` on the SD card while the core is held in reset. It is a
mandatory file (`C_CRTROMTYPE_MANDATORY` in `CORE/vhdl/globals.vhd`): if it is
missing, the firmware shows a fatal error naming the file and the core never
starts. The file is a raw 256 KB dump, big-endian, exactly as read from the ROM
chip.

Floppy disks come in two flavours. Up to three Amiga drive units (`df0:`,
`df1:`, `df2:`) can each be a simulated drive that mounts an `.adf` disk image
from the SD card, read and write (a "Disk Image" drive in the menu); at most
one of them can instead be the MEGA65's own 3.5" drive, which then reads and
writes real Amiga disks (the "Hardware Floppy"). By default only `df0:`
exists, as a Disk Image drive, because some games misbehave when the Amiga
sees more than one drive.

The whole Amiga runs on one clock of 28.375 MHz, the PAL master clock (the
ideal value is 28.37516 MHz; the difference is -5.6 ppm, well inside the
tolerance of a real crystal). The 7.09 MHz bus timing of the original machine
is made with clock enables, not with additional clocks.

## 2. From the board to the Amiga chips

The design is layered. The outer layers belong to the M2M framework, the inner
layers to AExp:

```
M2M/vhdl/top_mega65-r<n>.vhd           board top, one per MEGA65 revision
 |
 +-- framework.vhd  (M2M)              QNICE CPU running the Shell firmware,
 |                                     SD card + FAT32, on-screen menu (OSM),
 |                                     keyboard scan, joystick ports,
 |                                     HyperRAM controller, audio output,
 |                                     av_pipeline: ascal scaler (HDMI) and
 |                                     scandoubler/analog path (VGA)
 |
 +-- MEGA65_Core = CORE/vhdl/mega65.vhd
      |  clk.vhd                       28.375 MHz core clock + flicker-free twin
      |  Chip, Slow and Kickstart BRAMs
      |  QNICE device decode (0x0100 .. 0x0106)
      |  3 x adf_mount_wrapper         one ADF mount device per drive
      |  avm_fifo + avm_arbit_general HyperRAM access for the floppy
      |  physical_fdd_top + _diag      Hardware Floppy front end (50 MHz)
      |  amiga_cold_boot               Amiga-only cold boot on topology change
      |  OSM decoding, drive LED, flicker-free servo
      |
      +-- main.vhd                     replaces MiSTer's Minimig.sv
           |  amiga_config             replays the MiSTer HPS configuration
           |  adf_track_engine         Paula floppy host service (+ avm_cache)
           |  keyboard                 MEGA65 keys -> Amiga keycodes
           |  audio_filters            A500/LED filters, stereo mix
           |  video clock enables, sync polarity, master volume
           |
           +-- amiga_clk.v             clock enables of the Amiga bus
           +-- cpu_wrapper.v -> fx68k  the 68000
           +-- minimig_m65.v -> minimig.v
                                       Agnus, Denise, Paula, the two CIAs,
                                       Gary, userio, the SRAM bridge
```

The QNICE firmware (`CORE/m2m-rom/m2m-rom.asm` together with the framework's
Shell in `M2M/rom/`) runs on the QNICE soft CPU inside the framework. It loads
the Kickstart, runs the menu, streams disk images into the core and writes
changed disk tracks back to the SD card.

A few interfaces carry almost all of the traffic between these layers.

**The Amiga memory bus.** With a 68000 and no Fast RAM, every memory access of
the machine, from the CPU and from the custom chips' DMA alike, goes through
one SRAM-style port of Minimig (`ram_addr[22:1]` plus byte enables). Minimig's
`minimig_sram_bridge.v` maps the CPU address space onto banks of that port:
Chip RAM is at `ram_addr[22:19] = "0000"`, Slow RAM at `"1000"` and the
Kickstart at `"1111"` (bit 18 is ignored, which gives the `$F8`/`$FC` mirror).
`mega65.vhd` decodes these banks onto the BRAMs. Every memory is split into an
upper and a lower 8-bit lane, so that the byte at an even address is data bits
15..8, which is why a raw ROM dump streamed byte by byte lands correctly
without byte swapping.

**The host channel.** On MiSTer, an ARM processor (the HPS) talks to Minimig
over a small SPI-like bus. Two of its "chip selects" matter here: `IO_UIO`
carries configuration commands into `userio.v`, and `IO_FPGA` is Paula's
floppy channel. The MEGA65 has no HPS, so two AExp blocks in `main.vhd` speak
that bus instead. `amiga_config.vhd` replays MiSTer's boot-time configuration
after every reset (OCS chipset, 68000, 512 KB + 512 KB memory, drive count,
joystick port mapping) and then releases the CPU. `adf_track_engine.vhd` then
owns the bus and serves Paula's floppy requests. `main.vhd` multiplexes the
shared strobe and data lines between the two. Both blocks are modelled on
MiSTer's HPS software; section
[10](#10-the-mister-hps-code-and-its-replacements) names the files.

**The floppy.** The Amiga floppy controller cannot read sectors; it only moves
raw MFM words, and the operating system decodes them in software. AExp
therefore needs an MFM codec in hardware. `adf_track_engine.vhd` is a hardware
port of MiSTer's ARM-side floppy service, `minimig_fdd.cpp`; a copy of the
version it was modelled on is kept in this folder as
[`minimig_fdd.cpp`](minimig_fdd.cpp), and
[floppy-adf.md](floppy-adf.md#41-the-software-model-minimig_fddcpp)
lists what AExp changed and added. The disk images live in HyperRAM, one pool
per drive; the firmware copies changed tracks back to the `.adf` files in the
background. For the Hardware Floppy, the engine streams words that
`CORE/vhdl/physical_fdd/` reconstructs from the real flux, and Paula's floppy
logic is extended so that the real drive's status lines reach the CIAs. See
[floppy-adf.md](floppy-adf.md) and [hardware-floppy.md](hardware-floppy.md).

**Video.** Minimig produces 15 kHz PAL video in the core clock domain.
`main.vhd` generates a frame-locked pixel clock enable (7.09 MHz, or 14.19 MHz
for hires frames), inverts the active-low Minimig syncs and exports the
interlace field flag. The framework scales the picture for HDMI with ascal,
which also weaves interlaced fields, and either scandoubles it to 31 kHz for
VGA or passes it through raw in the two 15 kHz analog modes.

**Audio.** Paula's four channels pass `audio_filters.vhd` (the A500 low-pass
and the LED filter, ported from MiSTer's `Minimig.sv`, plus the stereo mix) and
the master volume in `main.vhd`, and then reach the framework, which feeds both
HDMI and the 3.5 mm jack. See [audio.md](audio.md).

**Keyboard, mouse, joysticks.** `keyboard.vhd` translates the MEGA65 key matrix
into raw Amiga keycodes and hands them to CIA-A with the real keyboard
handshake. The DB9 ports reach Minimig without debouncing, so a real Amiga
mouse moves smoothly; section [11](#11-mouse-and-joystick) explains the mouse
path and why the MEGA65 cannot see the right button of a passive Amiga mouse.

## 3. Repository layout

### `CORE/vhdl/`: the port

All files in this folder are AExp's own.

| File | Purpose |
|---|---|
| `mega65.vhd` | The `MEGA65_Core` entity the framework instantiates. Amiga memories (BRAM), QNICE device decode, the three ADF mount devices with their HyperRAM chain, the Hardware Floppy front end and its pins, all OSM decoding (`C_MENU_*` constants), drive LED, the flicker-free servo. |
| `main.vhd` | Wraps Minimig and fx68k in the core clock domain. Takes the role of MiSTer's `Minimig.sv`: CPU phase enables, video clock enable and sync polarity, reset mapping, the host bus multiplexer, the floppy engine and its read cache, keyboard, audio. |
| `amiga_config.vhd` | Replays MiSTer's configuration commands (`0xF1`..`0xF9`) over the `IO_UIO` channel after every reset, then releases the 68000. |
| `amiga_cold_boot.vhd` | Turns a change of the memory or drive topology into a cold boot of the simulated Amiga only: holds Minimig in reset and clears the ExecBase pointer at `$000004` so that Kickstart re-probes the machine. |
| `adf_track_engine.vhd` | The floppy host service: polls Paula, MFM-encodes sectors from HyperRAM for reads, decodes and commits written sectors, streams the Hardware Floppy's words, and feeds the physical write path. One instance for all drives. |
| `adf_mount_wrapper.vhd` | One ADF mount device (three instances): byte window into that drive's HyperRAM pool, the framework's load handshake with an ADF size check, and the write-back registers (dirty-track bitmap, write enable, anti-thrashing timer). |
| `physical_fdd/` | The Hardware Floppy: input conditioning, flux interval measurement, the data separator, sync alignment, a dual-clock word FIFO, the write front end and the diagnostics register bank. Runs at 50 MHz. |
| `keyboard.vhd` | MEGA65 keyboard to Amiga keycodes, two mapping modes, CIA handshake. |
| `audio_filters.vhd` | A500 and LED filters and the stereo mix. |
| `clk.vhd` | The core clock: a native 28.375 MHz MMCM, a 28.4375 MHz twin for the HDMI flicker-free mode and a glitch-free clock multiplexer. |
| `config.vhd` | The on-screen menu (items, groups, dependencies, help pages), `CORE_VERSION`, the settings file name and other Shell configuration. |
| `globals.vhd` | Clock speeds, OSM canvas size, the HyperRAM map, the ADF geometry, the QNICE device ids and the list of loadable ROMs and disk images. |

### `CORE/m2m-rom/`: the firmware

`m2m-rom.asm` is the core-specific part of the QNICE firmware (section
[6](#6-the-qnice-firmware)). `make_rom.sh` assembles it together with the
framework's Shell into `m2m-rom.rom`, which the bitstream embeds as the QNICE
ROM. Before assembling, it scrapes constants from the VHDL sources into
generated include files (`osm_const.asm`, `globals.asm`,
`shell_fhandles.asm`, `shell_fh_ptrs.asm`; all git-ignored). `synth_pre.tcl`
is the Vivado pre-synthesis hook that runs `make_rom.sh`, so every synthesis
rebuilds the firmware from the current sources. `video_filters/` holds the
coefficient tables of the HDMI scaler filters the menu offers.

### `CORE/Minimig_MiSTerMEGA65/`: the chipset

A git submodule with AExp's fork of the MiSTer Minimig core. See section
[9](#9-the-minimig-submodule).

### Vivado projects, constraints and build scripts

| File | Purpose |
|---|---|
| `CORE/CORE-R3.xpr` .. `CORE-R6.xpr` | One Vivado project per board revision (R3 also covers R3A). |
| `CORE/CORE.xdc` | All core-specific timing constraints, including the ones that cover framework paths (section [7](#7-rules-you-have-to-know)). |
| `CORE/build_all.sh` | Batch build of one or more boards, with the automatic re-roll of boards that just missed timing. |
| `CORE/build_bitstream.tcl` | Builds one board and checks the sign-off gates. |
| `CORE/reroll_bitstream.tcl` | Re-implements a board with other placer and router directives. |

How to build is in [developers.md](../developers.md); the re-roll is explained
in [`timing_closure.md`](timing_closure.md).

### Releases

`make_release.py` in the repository root is the generic M2M packaging script:
it turns the bitstreams of all boards into `.cor` files, generates the
matching settings file and collects the documentation. AExp's own policy lives
in `CORE/release.toml` (file names, version check, settings file) and
`CORE/release_hooks.py` (the screen-adjustment files and tool that ship with
every release, documentation link rewriting). `VERSIONS.md` holds the release
notes; `doc/inofficial.md` lists the alpha and beta builds, and
`make_release.py` requires a row there for every work-in-progress build.

### `M2M/`: the framework

The framework is part of this repository, not a submodule (section
[8](#8-the-modified-m2m-framework) explains what AExp changed in it). Inside it,
`M2M/QNICE` is a submodule with the QNICE CPU, its tool chain and its monitor
and FAT32 library, and `M2M/tools/make_config.sh` creates the menu settings
file.

### Everything else

`doc/` holds the end-user documentation and `doc/developers/` these developer
notes; `doc/make_doc.py` builds both into the documentation website (see
[`make_doc.md`](../make_doc.md)). `aexp_screen_cfg.py` and the
`aexp_screen.cfg_*` presets in the repository root are the end-user tool and
data for the screen adjustment (see [`screen_adjust.md`](../screen_adjust.md)).
`tools/` holds the host-side checkers and the tools for floppy field reports,
`CORE/sim/` the simulation testbenches; [Tools and testbenches](tools.md)
describes both.

## 4. Clock domains and crossings

| Clock | Frequency | Where it is used |
|---|---|---|
| `main_clk` | 28.375 MHz, or 28.4375 MHz while the flicker-free servo selects the twin | All of Minimig and fx68k, `main.vhd`, `adf_track_engine`, keyboard, audio filters; also the video clock handed to the framework. |
| `qnice_clk` | 50 MHz | QNICE CPU and Shell. QNICE device accesses are done on the falling edge. The ADF mount devices (CSR, size check, write-back registers) and the whole Hardware Floppy front end run here. |
| `hr_clk` | 100 MHz | HyperRAM controller, the framework's HyperRAM arbiter, the memory side of ascal, the floppy's four-way arbiter. |
| video output clocks | per video mode | HDMI and analog output pipelines of the framework. |
| audio clock | 12.288 MHz | framework audio output. |

The core clock switches between two MMCM outputs through a `BUFGMUX_CTRL`.
The HDMI output runs at exactly 50 Hz, the native Amiga frame rate is
49.92 Hz, and so ascal's single frame buffer would drop or repeat a frame
roughly every 12 seconds. The servo dithers the core clock between the native clock and a
slightly faster twin so that the average frame rate is exactly 50 Hz. The
analysis is in [`hdmi_latency.md`](hdmi_latency.md). `CORE.xdc` times only the
faster leg (it freezes the multiplexer select with `set_case_analysis` and
defines `main_clk` on the twin's output), and `build_bitstream.tcl` refuses a
build in which those constraints matched no pins.

Crossings follow three patterns:

* Quasi-static values and toggle handshakes cross with the framework's
  `cdc_stable`, which `M2M/common.xdc` already constrains.
* Avalon traffic to the HyperRAM crosses with `avm_fifo`.
* The Hardware Floppy's word FIFO and its control synchronizers are raw
  two-flop and Gray-code crossings between `qnice_clk` and `main_clk`.
  `CORE.xdc` bounds them with a clock-pair `set_max_delay -datapath_only` of
  one QNICE period in both directions. It deliberately does not use a false
  path, because a clock-pair false path would also override the tighter
  object-scoped bounds of `common.xdc`.

`CORE.xdc` also bounds the asynchronous ping-pong buffers inside ascal with
`set_max_delay -datapath_only`. Without that, Vivado times them against
impossible inter-clock requirements and the router's hold fixes spoil the
genuine HyperRAM paths.

## 5. QNICE devices and the HyperRAM map

The QNICE CPU reaches core memories and registers through the framework's
device bus: a 16-bit device id (core devices start at `0x0100`), a 4k-word
window selector and an address inside the window. The core decodes its devices
in `mega65.vhd`; the ids are defined in `globals.vhd`.

| Id | Constant | Purpose |
|---|---|---|
| `0x0100` | `C_DEV_AMIGA_KICK` | Kickstart ROM. The Shell writes the ROM file into it at startup. |
| `0x0101`, `0x0102` | `C_DEV_AMIGA_CHIP`, `_SLOW` | Reserved and not connected (see [7.2](#72-no-qnice-ports-on-spread-out-block-ram)). |
| `0x0103` | `C_DEV_AMIGA_ADF0` | ADF mount device of `df0:`. |
| `0x0104` | `C_DEV_AMIGA_FDD` | Diagnostics register bank of the Hardware Floppy. |
| `0x0105` | `C_DEV_AMIGA_ADF1` | ADF mount device of `df1:`. |
| `0x0106` | `C_DEV_AMIGA_ADF2` | ADF mount device of `df2:`. |

The Hardware Floppy's id sits between the ADF devices because it is older than
the second and third drive, and its register map is referred to by number in
field test instructions, so it kept the id. The three ADF devices share one
layout: windows `0x0000` upwards are a byte window into the drive's image,
window `0xFFFE` holds the write-back registers and window `0xFFFF` the
framework's load handshake. The register maps are in
[floppy-adf.md](floppy-adf.md#12-reference).

The HyperRAM is 8 MB, addressed in 8 KB windows:

| Windows | Bytes | Owner |
|---|---|---|
| `0x000-0x1FF` | 0-4 MB | Framework (`C_HMAP_M2M`). The ascal frame buffer uses the first 2 MB. |
| `0x200-0x27F` | 4-5 MB | `df0:` slot: image pool, one guard window, spare |
| `0x280-0x2FF` | 5-6 MB | `df1:` slot |
| `0x300-0x37F` | 6-7 MB | `df2:` slot |
| `0x380-0x3FE` | 7-8 MB | unused |
| `0x3FF` | last 8 KB | top guard, so that a burst past the last region cannot wrap to 0 |

Each image pool holds the largest accepted ADF (166 tracks) and is followed by
an empty guard window, because the shared HyperRAM infrastructure (the read
cache's prefetch, the HyperRAM errata fix) can reach a few words beyond the
address a client asked for. `mega65.vhd` checks the ordering of the regions at
elaboration time. Keep ascal's triple buffering off (`qnice_ascal_triplebuf_o`
is tied to `'0'`): it would grow the frame buffer to 6 MB and overwrite the
disk images, and it would also break the flicker-free mode.

## 6. The QNICE firmware

The framework's Shell (`M2M/rom/`) does the generic work: SD card and FAT32,
the file browser, the menu, loading ROMs and disk images, saving the menu
settings. It calls back into the core-specific firmware in
`CORE/m2m-rom/m2m-rom.asm` at defined points. AExp uses these callbacks for:

* `FILTER_FILES` and `PREP_LOAD_IMAGE`: show only `.adf` files in the browser
  for a drive's mount line, reject files outside the accepted size range, flush
  and disarm the drive before a new image is loaded, and refuse to mount the
  same file into two drives.
* `PREP_START`: load the screen-adjustment file before the core leaves reset.
* `OSM_SEL_PRE` and `OSM_SEL_POST`: keep the drive configuration consistent
  (drive count, at most one Hardware Floppy, ejecting a drive that leaves Disk
  Image mode), reset the core when Slow RAM is toggled, load the HDMI filter
  coefficients, reload the screen configuration.
* `HANDLE_CORE_IO`, a callback AExp added to the framework (section
  [8](#8-the-modified-m2m-framework)): called in every iteration of the Shell's
  main loop and of all its wait loops. It handles the SPACE key that ejects a
  disk, detects Amiga screen-mode changes for the screen adjustment, runs the
  background write-back of changed ADF tracks to the SD card, reseeds the
  Amiga's real-time clock every minute and updates the live Hardware Floppy
  status in the menu.

The write-back is the subtle part. Read [floppy-adf.md](floppy-adf.md)
sections 8 and 9 before you change anything in it.

The menu settings are saved in `/amiga/aexp-<CORE_VERSION>.cfg`. The file is
`OPTM_SIZE` bytes long (one byte per menu line), and the firmware accepts a
settings file on its length alone.

The QNICE submodule tracks the `dev-V1.61` branch of QNICE-FPGA (set in
`.gitmodules`), not the commit that M2M V2.0.1 pins. That branch carries two
fixes to the FAT32 library that the ADF write-back depends on: the shared
sector buffer is written back before `DIR_OPEN` or `FILE_OPEN` reuse it, and
the 32-bit sector address overflow check. If you ever sync the framework from
the M2M template, make sure the submodule pointer does not move back. Update it
with `git submodule update --remote M2M/QNICE`; the next synthesis reassembles
the firmware against the new monitor.

## 7. Rules you have to know

Each of these rules exists because breaking it either does not build, does not
close timing, or fails in a way that is hard to trace back.

### 7.1 Block RAM is full

The core uses 364 of the 365 block RAM tiles of the XC7A200T. The Amiga
memories alone take 320 tiles (Chip RAM 128, Slow RAM 128, Kickstart 64), and
that is an exact mapping with nothing left to save. Any new buffer must go
into HyperRAM or into distributed RAM, which is why the disk images live in
HyperRAM and why the floppy engine's sector buffers are LUTRAM. Vivado
routinely reports `Synth 8-5835` (block RAM over-utilized, falls back to
LUTRAM); that is only a real failure if implementation then cannot place the
design. Re-enabling IDE would need 8 more tiles and does not fit.

### 7.2 No QNICE ports on spread-out block RAM

QNICE accesses device memory on the falling edge of its 50 MHz clock, which
leaves half a period, 10 ns, for the address to reach the RAM. Chip RAM and
Slow RAM are 256 tiles spread across the die, and the address bus cannot reach
them in time; an earlier version that tried missed timing by 0.76 ns. Only the
Kickstart ROM (64 tiles) has a QNICE port. The device ids `0x0101` and
`0x0102` stay reserved so that they are not reused by accident.

### 7.3 The timing margin is thin

Builds close with a worst negative slack of roughly +0.1 to +0.3 ns. Look at
the timing summary after every build; `build_all.sh` prints it for you. The
sign-off gates in `build_bitstream.tcl` also check that the flicker-free
constraints in `CORE.xdc` really matched: the instance names `i_clk_fast`
(in `clk.vhd`) and `hr_core_speed` (in `mega65.vhd`) are referenced by name
there, so keep them. Now and then a board misses timing by a few picoseconds of
hold in the framework's HyperRAM read capture; that is placement luck, and
[`timing_closure.md`](timing_closure.md) explains why `build_all.sh` simply
re-rolls such a board and why the HyperRAM IDELAY value must not be changed.

### 7.4 The firmware ROM must end below `0x7000`

M2M maps its 4k-word device window at `0x7000-0x7FFF`, so only 28,672 words of
the QNICE ROM are usable. `make_rom.sh` checks the assembled image against
this limit and fails the build loudly if it is exceeded. `WIP-V2-B1` uses
27,533 words. Vivado prints `Shell ROM: N/28672 words.` during synthesis.

### 7.5 Every growth of the menu needs a heap budget check

The Shell copies the menu text and four arrays of `OPTM_SIZE` words into a
heap of `MENU_HEAP_SIZE` words, and then uses the rest of that heap for one
line buffer per submenu, mount line and vdrive, plus a scratch buffer. When you
change `OPTM_SIZE`, `OPTM_ITEMS`, `OPTM_DX`, or the number of submenus or
mount lines, recompute the demand:

```
20 + (characters of OPTM_ITEMS, "\n" counts as 2) + 1 + 4 x OPTM_SIZE + 1
   + (vdrives + submenus + manual ROMs + 1) x (OPTM_DX + 2)
```

Round the result up to the next multiple of 32 and no further, because the
file browser's heap starts right behind the menu heap and every spare word is
taken from it. If `MENU_HEAP_SIZE` changes, change both `HEAP_SIZE` constants
in `m2m-rom.asm` (debug and release) by the same amount in the opposite
direction, so that the totals stay the same. Currently the 148-line menu needs
2325 words and `MENU_HEAP_SIZE` is 2336. A wrong budget is never silent: the
firmware stops with a fatal error at boot and on every menu open. Firmware
variables count too: they sit below the heap and push it upwards, so after
adding variables check the `HEAP` and `VAR$STACK_START` addresses in
`m2m-rom.lis`. The comments above `MENU_HEAP_SIZE` in `m2m-rom.asm` keep the
current calculation.

The help pages have a budget as well: they are printed into a full-screen frame
that leaves 34 rows of 43 characters. Each page uses exactly 33 rows of at most
42 characters, so a free row and column separate the text from the border and
the footer stays in place while paging; `tools/check_osm_menu.py` enforces it.

### 7.6 Menu line numbers are bit numbers

In `config.vhd`, the position of a line in the menu is the number of the bit
that carries its state to the core. `mega65.vhd` reads these bits through the
`C_MENU_*` constants, so inserting a line shifts every constant behind it, and
all of them have to be updated by hand. `make_rom.sh` scrapes these constants
(and the core's `OPTM_G_*` group ids from `config.vhd`, the device ids and the
ADF geometry from `globals.vhd`) into the firmware, so the firmware has no
hard-coded menu indexes. The scraper is a line-based `awk`: keep every one of
these constants on a single line.

### 7.7 `CORE_VERSION` names the settings file

`CORE_VERSION` in `config.vhd` is the only place the version string is
written. The welcome and help screens, the core name and the settings file name
`/amiga/aexp-<CORE_VERSION>.cfg` all derive from it, and `make_release.py`
checks that the release you package matches it. A new version therefore needs
a new settings file. Generate a fresh one (see
[developers.md](../developers.md#settings-file)) instead of copying an old one
forward: a used file holds the old selections, and because the firmware only
checks the length, a file of the right length restores them silently.

### 7.8 Keep the four Vivado projects in sync

Every change to the file list or to file properties goes into all four
`.xpr` files in the same commit. The expected differences between them are
the board top (`M2M/vhdl/top_mega65-r<n>.vhd`), the board constraints
(`M2M/MEGA65-R<n>.xdc`), and the audio output driver: R3 uses `max10.vhdl` and
`pcm_to_pdm.vhdl`, R4 and later use `audio.vhd`.

When you edit an `.xpr` by hand, the only valid `SFType` attributes are
`VHDL2008` and `SVerilog`, or none at all (the type is then inferred from the
file extension). Anything else, such as `Verilog` or `SystemVerilog`, makes
Vivado crash while opening the project.

### 7.9 Keep `OPTM_PAUSE` false

The framework can pause the core while the menu is open, but `main.vhd` does
not implement `pause_i` (Minimig has no clean point to stop at). `OPTM_PAUSE`
in `config.vhd` must stay `false`.

### 7.10 What the framework expects from the video

The framework wants active-high syncs (Minimig's are active low, so
`main.vhd` inverts them), blanking signals that cover the syncs, and a pixel
clock enable that is locked to the frame. The video clock is `main_clk`
(28.375 MHz). The enable runs at 7.09 MHz, every fourth clock, in frames with
only lowres lines, and at 14.19 MHz, every second clock, while a frame
contains hires lines. MiSTer's scandoubler doubles the lines with its Hq2x
filter, which needs at least four clocks per input pixel; at two clocks it
keeps only every second hires pixel. AExp therefore sets `VGA_LINEDOUBLER` in
`globals.vhd`, and the scandoubler uses the plain line doubler of section
[8.10](#810-line-doubler), which needs two clocks per pixel. Never use the
full 28 MHz as pixel clock enable: the line doubler would get only one clock
per pixel, and ascal accepts at most 1024 input pixels per line. The
scandoubler is on (`qnice_scandoubler_o = '1'`) in the standard VGA mode,
because the core outputs 15 kHz video, and off only in the two 15 kHz analog
modes.

## 8. The modified M2M framework

AExp V2 is built on MiSTer2MEGA65 V2.0.1, but not on an unmodified copy. The
framework in `M2M/` carries ten AExp changes that the core needs and that
V2.0.1 does not offer. Each change is marked in the code with a comment
`M2M-UPSTREAM <name>`, so this command finds all of them, together with the
two tagged bug fixes of section [8.11](#811-other-differences-to-v201):

```
grep -rn 'M2M-UPSTREAM' M2M CORE
```

The AExp V2 release is not reconciled with M2M V2.1.0. That framework release
will contain the features that make these changes unnecessary. Moving AExp to
it, dropping what V2.1.0 supersedes and carrying over the rest, is future work.
Until then, treat `M2M/` as part of AExp. Do not update it from the M2M
template, and do not make further changes there unless there is no other way.

> **Do not merge a newer M2M release into `M2M/`.** A plain `git merge` or a
> copy of a new framework version silently drops or breaks the changes AExp
> depends on, and the `grep` above does not find all of them: some changes
> carry no tag (sections [8.5](#85-osm-scale) and
> [8.11](#811-other-differences-to-v201)). Moving to a newer framework is a
> port, not a merge. Go through this section change by change, decide for
> each one whether the new framework replaces it or whether it has to be
> carried over, and test the result on hardware.

Constraints for framework paths go into `CORE/CORE.xdc`; `M2M/common.xdc`
stays as the framework ships it.

If you add the M2M repository as a git remote to compare, remember that its
tags (`V1.0.0`, `V2.0.0`, `V2.0.1` and so on) are framework releases, not AExp
releases. AExp's own tags are `V1`, `V2` and the `WIP-*` work-in-progress
builds.

### 8.1 `interlace`

* What: a new framework input `video_fl_i`, the interlace field flag, threaded
  from the core through `framework.vhd`, `av_pipeline.vhd` and
  `digital_pipeline.vhd` into ascal's `i_fl` input, and ascal instantiated with
  `INTER => true`.
* Files: `framework.vhd`, `av_pipeline/av_pipeline.vhd`,
  `av_pipeline/digital_pipeline.vhd`, the four board tops.
* Why: ascal weaves the two fields of an Amiga interlaced screen into one
  stable progressive picture on HDMI (the "flicker fixer").
* Other cores: the input defaults to `'0'`, and ascal only arms its
  deinterlacer when `i_fl` toggles, so progressive cores behave exactly as
  before.

### 8.2 `core-io-hook`

* What: `HANDLE_CORE_IO`, a new mandatory core callback, called from the
  Shell's `HANDLE_IO`. Contract: preserve all registers, return quickly, may
  change the selected RAMROM device and window.
* Files: `M2M/rom/shell.asm`.
* Why: `HANDLE_IO` runs in the main loop and in every blocking wait loop
  (menu, file browser, help screens), so a background task hooked there keeps
  running while the user sits in the menu. AExp's ADF write-back cannot use the
  framework's `vdrives` system and needs such a time slice.
* Other cores: they must provide the callback, at least as an empty
  subroutine, or the firmware does not assemble.

### 8.3 `screen-center`

* What: the plumbing of the screen adjustment. Four signed per-edge crop
  offsets for ascal's input window (HDMI), four signed overscan edges for a
  soft blank on the analog output, and two signed pan values that feed the new
  `analog_positioner.vhd`, which shifts the analog sync phase against the
  picture. The values come from QNICE general-purpose registers; a new
  read-only register `M2M$SYS_CORE_FLAGS` tells the firmware whether ascal
  currently sees interlaced input.
* Files: `framework.vhd`, `qnice_wrapper.vhd`, `av_pipeline/av_pipeline.vhd`,
  `av_pipeline/digital_pipeline.vhd`, `av_pipeline/analog_pipeline.vhd`,
  `av_pipeline/ascal.vhd`, the new `av_pipeline/analog_positioner.vhd`,
  `M2M/rom/sysdef.asm`.
* Why: Amiga software uses many different screen geometries; the core picks
  per-mode offsets from `aexp_screen.cfg` (see
  [`screen_adjust.md`](../screen_adjust.md)).
* Other cores: all new inputs default to 0, and a pan of 0 bypasses the
  positioner combinationally, so the output is unchanged.

### 8.4 `osm-hotkey`

* What: three core-driven inputs (`osm_key_a_i`, `osm_key_b_i`,
  `osm_combo_i`) choose which key, or which two-key combination, opens the
  menu. They are threaded from the core through `framework.vhd` into
  `m2m_keyb.vhd`, which builds the menu bit from the ungated keyboard scan.
* Files: `m2m_keyb.vhd`, `framework.vhd`, the four board tops.
* Why: Help is a useful key on the Amiga, so the user can pick another key to
  open the menu.
* Other cores: the defaults select Help alone, the classic behaviour. The
  firmware is unchanged.

### 8.5 `osm-scale`

* What: `tdp_ram.vhd` gets a `RAM_STYLE_SELECT` generic (default `"auto"`)
  that `2port2clk_ram.vhd` passes through, and ascal's small asynchronous
  ping-pong buffers (`i_dpram`) are forced into distributed RAM. The OSM
  renderer for the "OSM Scaling" menu option was reworked in the same change:
  the font ROM now stores the native 8x8 Anikki glyphs, the 100% size expands
  them to exactly the old 16x16 font, and smaller sizes use a sharpened
  bilinear filter.
* Files: tagged are `tdp_ram.vhd` and `av_pipeline/ascal.vhd`; the renderer
  change in `av_pipeline/vga_osm.vhd`, `av_pipeline/video_overlay.vhd`,
  `2port2clk_ram.vhd` and the font files in `M2M/font/` carries no tag.
* Why: left to its own heuristics, Vivado put ascal's buffers into four block
  RAM tiles the core does not have, and absorbed a register into the block RAM
  output, which broke the endpoints of the ascal constraints in `CORE.xdc`.
  The renderer change makes the scaled menu legible.
* Other cores: `"auto"` keeps every other caller as before. The ascal buffer
  attribute and the renderer apply to every core; at 100% the menu is pixel
  identical to the old renderer.

### 8.6 `raw-joyports`

* What: the joystick debouncer in `debouncer.vhd` is reduced to plain two-flop
  synchronizers; the 1 ms stable-time filters are gone. Port swapping and the
  joystick enable gating stay.
* Files: `debouncer.vhd`.
* Why: a real Amiga does not debounce its DB9 lines, and a quadrature mouse
  produces pulses faster than a 1 ms filter lets through, so the pointer
  freezes and jumps (section [11.1](#111-movement)).
* Other cores: this one is not default-off. Every core using this copy gets
  raw joystick lines. Upstream it should become a framework option.

### 8.7 `floppy-pins`

* What: the four board tops route the MEGA65's internal floppy connector into
  `MEGA65_Core`: the five inputs and the drive A outputs (motor, select, side,
  step direction, step, density), and the two write pins `f_wdata` and
  `f_wgate`. Drive B's motor and select stay tied inactive. `framework.vhd` is
  not involved.
* Files: the four board tops.
* Why: the Hardware Floppy. The pattern is the one C64MEGA65 uses for its
  physical 1581 drive.
* Other cores: the board tops now expect these ports on `MEGA65_Core`. Note
  that because the write pins are connected, the internal drive is not
  physically read-only any more; what protects a disk is the core's write gate
  and the disk's write-protect tab.

### 8.8 `osm-deps`

* What: menu dependencies, ported from C64MEGA65. A menu line tagged with
  `OPTM_DEP` or `OPTM_DEP2` in `config.vhd` is only visible while a given item
  of a "mother" group is selected. The validator checks the dependency rules
  at boot and stops with one of five new error messages.
* Files: the new `M2M/rom/optm_deps.asm`, plus `menu.asm`, `options.asm`,
  `strings.asm`, `sysdef.asm`.
* Why: each drive has two lines in the main menu, a mount line and a Hardware
  Floppy status line, and the menu shows the one that matches the drive's mode.
  Unlike the C64 original, this copy allows dependent ROM-loader
  (`OPTM_G_LOAD_ROM`) lines, through which AExp mounts its ADF images,
  partially visible radio groups and two-level chains, and its
  validator is correspondingly less strict in two of its rule classes (the
  reasons are in the header of `optm_deps.asm`).
* Other cores: a core whose `config.vhd` does not answer the feature probe
  sees every line, as before.

### 8.9 `live-text`

* What: `OPTM_LIVE_TEXT` in `menu.asm` replaces a fixed-width part of one menu
  line in the heap copy of the menu text and repaints just those characters if
  the line is visible. Ported from C64MEGA65.
* Files: `M2M/rom/menu.asm`.
* Why: the live status of the Hardware Floppy in its menu line. Unlike the
  C64 original, the caller decides whether the menu currently owns the screen
  (M2M V2.0.1 has no flag for that).
* Other cores: purely additive; nothing else calls it.

### 8.10 `line-doubler`

* What: a parameter `LINEDOUBLER` of MiSTer's `scandoubler.v` (default 0, the
  original Hq2x path) and a new module `linedoubler` in the same file, which
  replaces Hq2x when the parameter is 1. `video_mixer.sv` passes the parameter
  on; `analog_pipeline.vhd` and `av_pipeline.vhd` carry it as the generic
  `G_VGA_LINEDOUBLER` (default `false`), and `framework.vhd` sets that generic
  from the constant `VGA_LINEDOUBLER` in the core's `globals.vhd`, the way it
  takes `VGA_DX`.
* Files: `controllers/MiSTer/scandoubler.v`,
  `controllers/MiSTer/video_mixer.sv`, `av_pipeline/analog_pipeline.vhd`,
  `av_pipeline/av_pipeline.vhd`, `framework.vhd`.
* Why: Hq2x spends four clock enables on every input pixel, so it needs a
  video clock of at least four times the pixel rate. MiSTer's Minimig runs its
  video at 113.5 MHz and always meets that. AExp runs the video at `main_clk`,
  which is four times the lowres rate but only twice the hires rate (section
  [7.10](#710-what-the-framework-expects-from-the-video)); there Hq2x keeps
  only every second hires pixel, and hires screens on the analog Standard VGA
  output lose every second pixel column. The line doubler needs one clock to
  write an input pixel and one to read an output pixel, so two clocks per
  pixel are enough.
* How: the line doubler writes one pixel per input pixel enable into one half
  of a two-line buffer while it reads the other half, the previous input line,
  twice, one pixel per output pixel enable. The halves swap when the output
  window of a line's first copy opens: normally at the start of the active
  part of the input line, a few clocks earlier when an input line is longer
  than the one before it (while the analog overscan changes), because the
  scandoubler times its output windows from the previous line's length.
  Each half holds 1024 pixels of 24 bits
  in distributed RAM: a whole hires line including its blanking, also when an
  outward analog overscan widens the active window. The latency is one input
  line (64 µs) instead of Hq2x's one and a half, so the scandoubler takes its
  vsync and vblank outputs one output line earlier, and the Standard VGA
  picture leaves the MEGA65 32 µs sooner. In this mode the scandoubler also
  measures the pixel period in the vertical blanking lines, so a pixel rate
  that changes at vsync is in effect from the first active pixel on, and it
  samples the vertical blanking a second time 16 clocks into each line: the
  analog soft blank of section [8.3](#83-screen-center) changes vblank one
  clock after its hblank falls, and without the second sample the picture
  would show one line too late within the window. An outward left overscan
  of more than 15 clocks puts the core's vblank edge beyond that second
  sample; there the picture still shows one line late, as it does with
  Hq2x. There is
  no Hq2x filter in this mode (AExp never switches it on), no new clock and no
  clock-domain crossing; HDMI and the two 15 kHz modes do not pass the
  scandoubler and are unchanged. Hq2x's block RAM (5.5 tiles) is gone; the
  line doubler uses LUTRAM.
* Other cores: the parameter and both generics default to the original Hq2x
  path, but `framework.vhd` reads `VGA_LINEDOUBLER` from the core's
  `globals.vhd`, so another core that uses this copy of the framework has to
  add that constant (`false` keeps its behaviour).

### 8.11 Other differences to V2.0.1

Besides the ten changes of sections 8.1 to 8.10, AExp differs from M2M V2.0.1
in four more places. Three of them are in `M2M/`, the fourth in AExp's own
firmware.

* HyperRAM read watchdog (tag `qnice2hyperram-watchdog`, ported from
  C64MEGA65). QNICE waits for the answer to every HyperRAM read. If the
  answer is lost, for example because the reset button resets the HyperRAM
  side in the middle of a read, QNICE would otherwise wait until a framework
  reset (reset button held for 1.5 s) or a power cycle. The watchdog in
  `qnice2hyperram.vhd` sends the read again every 0.65 ms until an answer
  arrives.

    It has one known limit. If the reset only delayed the original read,
    because the command was still queued in the clock-crossing FIFO
    (`avm_fifo`) between QNICE and HyperRAM, both the original and the
    repeated read are answered. The module drops a surplus answer that
    arrives while no read is waiting. If QNICE has already issued its next
    read, the module takes the surplus answer for that read, which then
    returns the data of the previous address. Only a reset during a QNICE
    HyperRAM read can cause this. Closing the gap needs the QNICE side of
    `avm_fifo` to be reset together with the HyperRAM side; AExp resets each
    side from its own domain only.

* R7 fix in `gencfg.asm` (tag `gencfg-r7`, ported from C64MEGA65).
  `gencfg.asm` writes the control and status register through R7, but V2.0.1
  never loads R7 first, so those writes land wherever R7 happens to point and
  the core may never leave reset. This copy loads `M2M$CSR` into R7.

* HyperRAM placement. The board constraint files `M2M/MEGA65-R<n>.xdc`
  contain a pblock that keeps the HyperRAM controller next to its I/O pins.
  This keeps its receive path close to the input registers, so that it
  reliably meets the 2 ns maximum-delay constraints of `common.xdc`.

* A routine borrowed from the M2M V2.1.0 development line, kept in AExp's
  firmware rather than in `M2M/`. `m2m-rom.asm` carries a copy of
  `M2M$LOAD_POLYPHASE` from that line (C64MEGA65's copy of the framework,
  `M2M/rom/tools.asm` there), which V2.0.1 lacks; it loads the coefficients
  of the HDMI scaling filters. Delete this copy when AExp moves to M2M
  V2.1.0; the assembler then reports the duplicate label.

## 9. The Minimig submodule

`CORE/Minimig_MiSTerMEGA65` is AExp's fork of the MiSTer Minimig-AGA core
(`sy2002/Minimig_MiSTerMEGA65` on GitHub). It has three branches:

* `MiSTer` mirrors the upstream MiSTer core unchanged. Upstream changes enter
  here first.
* `develop` carries all MEGA65 changes and is the branch AExp tracks.
* `master` is the released state: it equals `develop` at each AExp release.

The fork keeps its changes small and traceable. Every change to an original
file has a dated provenance comment of the form
`// MiSTer2MEGA65 (AExp Amiga 500 port), <month> <year>: ...`, and the
original code stays next to it as a comment. The submodule's `README.md`
summarises the modifications. In short:

* Vivado compatibility: Altera memories replaced by inferred block RAM
  templates, and a sweep over constructs that Quartus accepts and Vivado does
  not (multiply driven registers, SystemVerilog array syntax and similar).
* `rtl/minimig_m65.v`, a new wrapper that renames `minimig.v`'s
  underscore-prefixed ports (illegal in VHDL) and ties off the unused
  subsystems.
* MEGA65 integration: keyboard with a real CIA handshake, mouse, real-time
  clock, the floppy host channel.
* The Hardware Floppy in `paula_floppy.v` (threaded through `paula.v`,
  `minimig.v` and `minimig_m65.v`): per-unit substitution of the real drive's
  status lines, the index pulse into CIA-B, a synthesized ready signal, and a
  faithful `DSKBYTR` register (`$DFF01A`), which Rob Northen Copylock needs to
  time the disk. With the Hardware Floppy switched off, the controller behaves
  exactly like the upstream one.
* Four upstream fixes that MiSTer made after AExp forked, backported in
  `WIP-V2-B1`: the CIA timers' `CNT` input (MiSTer PR 230, `cia_timera.v`,
  `cia_timerb.v`, `ciaa.v`, `ciab.v`), the blitter freeze when fill mode is
  switched off mid-blit (PR 236, `agnus_blitter.v`), the exact `VHPOSR`
  readback (PR 234, `agnus_beamcounter.v`), and the field flag that is only
  set while interlace is on (commit `d16cd84`, `agnus_beamcounter.v`).
  `VERSIONS.md` describes their effect.

Changes to the submodule are committed in the submodule on `develop` first;
the main repository then records the new submodule commit.

## 10. The MiSTer HPS code and its replacements

On MiSTer, Minimig is only half of the machine. The other half is software on
the ARM processor (the HPS): the `support/minimig/` folder of
[`Main_MiSTer`](https://github.com/MiSTer-devel/Main_MiSTer) configures the
core, uploads the Kickstart ROM and serves the floppy disk images over the
host channel, and generic parts of Main_MiSTer translate USB keyboards into
Amiga keycodes and send the real-time clock. The MEGA65 has no such processor.
The QNICE CPU runs the menu and the SD card, but it is neither fast enough nor
close enough to serve Paula's floppy channel word by word. So every HPS
function AExp needs became hardware in the core or moved into the QNICE
firmware:

| Main_MiSTer `support/minimig/` | Role on MiSTer | In AExp |
|---|---|---|
| `minimig_fdd.cpp` | The floppy service `HandleFDD`: MFM-encodes sectors of the `.adf` file for Paula's reads, decodes Paula's writes back into the file. | Ported to hardware as `adf_track_engine.vhd`. Reference copy: [`minimig_fdd.cpp`](minimig_fdd.cpp). What AExp changed and added is listed in [floppy-adf.md](floppy-adf.md#41-the-software-model-minimig_fddcpp). |
| `minimig_config.cpp` | The configuration menu and its presets, `ApplyConfiguration` (sends the userio commands `0xF1`..`0xF9`), the Kickstart upload into Minimig's memory. | `ApplyConfiguration` is the model for `amiga_config.vhd`, which sends the same commands with fixed A500 values after every reset. Reference copy: [`minimig_config.cpp`](minimig_config.cpp). The menu is the M2M menu in `config.vhd`; the Kickstart upload is replaced by the M2M Shell's ROM loader, which writes the file straight into the Kickstart BRAM (device `0x0100`). |
| `minimig_boot.cpp` | Draws Minimig's boot screen into Chip RAM. | Not used: the core boots straight into Kickstart. |
| `minimig_share.cpp` | Shared folder between Linux and AmigaOS. | Not used. |

Outside `support/minimig/`, `keyboard.vhd` takes the place of MiSTer's USB
keyboard translation (AExp's mapping of the MEGA65 keyboard is its own).
MiSTer's USB mouse path has no counterpart: a real Amiga mouse in the DB9 port
is read directly (section [11](#11-mouse-and-joystick)). The framework hands
the MEGA65's battery-backed clock to Minimig at reset, and the firmware's
`RTC_STEP` reseeds it once per minute, the same cadence the HPS uses.

Both reference copies are stored verbatim from Main_MiSTer commit
[`c738023`](https://github.com/MiSTer-devel/Main_MiSTer/tree/c73802332ff9c73659410084b6319ccd29f0b3aa)
("Release 20260603", 3 June 2026). That is the MiSTer release that goes with
the Minimig release AExp forked from, and neither file changed upstream while
the AExp blocks were written. The last commits that changed them before that
point are `aebed6b` (`minimig_fdd.cpp`, 2021) and `61611e0` (`minimig_config.cpp`,
2023). The line numbers quoted in the comments of `adf_track_engine.vhd`
refer to this copy. Main_MiSTer is licensed under the GPL v3, like AExp;
`minimig_fdd.cpp` carries its own GPL v3 (or later) header from the original
Minimig authors, and `minimig_config.cpp` has no header and falls under the
repository license.

Upstream has changed both files since, in September 2026: external floppy
drives, SCP and IPF flux images, clock bits in the MFM encoder, a zero-drive
setting, and new CD32, CDTV and Ethernet configuration. None of this is
reconciled with AExp. Compare against the reference copies first when you look
at upstream changes, so that you see only what changed after the port.

## 11. Mouse and joystick

The MEGA65's two DB9 ports are wired like the Amiga's, so a real Amiga mouse
or joystick plugs straight in, and Minimig reads the pins the way Denise,
Paula and CIA-A read them in an A500. A joystick needs nothing beyond that. A
mouse needs two things that are easy to break: every edge of its movement
signals has to reach Minimig, and its right and middle buttons sit on lines
that the MEGA65 can only partly read.

| DB9 pin | Mouse signal | The Amiga reads it through | Framework signal |
|---|---|---|---|
| 1, 3 | vertical quadrature pair | the `JOY0DAT`/`JOY1DAT` counters | joystick up, left |
| 2, 4 | horizontal quadrature pair | the same counters | joystick down, right |
| 6 | left button | CIA-A port A (`/FIR0`, `/FIR1`) | joystick fire |
| 9 | right button | `POTINP` bit 10 (`DATLY`) | `pot1_x` (`POTX`) |
| 5 | middle button | `POTINP` bit 8 (`DATLX`) | `pot1_y` (`POTY`) |

The `POTINP` bits are those of port 1 (the port the Hardware Reference Manual
numbers 0: `JOY0DAT` and the L bits of `POTINP`). Pins 9 and 5 carry a naming
trap: the
Amiga reads pin 9 through the channel it calls Y, while the MEGA65 schematics
and the framework follow the C64 and call the same pin X. Both are right in
their own world; on the core side, the right button is `pot1_x_i`.

`userio.v` swaps the two ports unless its `joy_swap` bit is set, and
`amiga_config.vhd` sets it (command `0xF9`, payload `0x0008`). MEGA65 port 1
is therefore Amiga port 1, the mouse port, and port 2 the joystick port, as on
an A500.

### 11.1 Movement

There is no dedicated mouse decoder. Minimig's `userio.v` keeps the counters
of the original Minimig that are fed from the joystick pins (`dmouse0dat`,
`dmouse1dat`, called "docking" counters in its comments), which count the
transitions of the two quadrature pairs into `JOYxDAT`, exactly like Denise. A
counter only notices a transition that is still there at its next sample, so
the whole path from the pin to the counter has to pass every edge:

* The framework's `debouncer.vhd` is reduced to plain two-flop synchronizers
  (section [8.6](#86-raw-joyports)). A 1 ms stable-time filter swallows the
  pulse trains of a moving mouse, and the pointer freezes and then jumps.
* The input synchronizer of `userio.v` (`_sjoy`/`_djoy`) shifts on `clk7_en`,
  the rate at which the counters sample. Shifted at the full 28 MHz, as in the
  upstream code, a transition would show as a difference between `_sjoy` and
  `_djoy` for a single clock only, and the counters, which look once every
  four clocks, would catch about one transition in four; the pointer would
  crawl at a quarter of its speed and jitter. MiSTer never shows this, because
  there these inputs come from gamepad states that the HPS latches.

A joystick takes the same path and needs nothing else: its directions and its
fire button are slow levels.

### 11.2 The right and middle buttons

On a real Amiga, the right and middle buttons are passive switches from pins 9
and 5 to ground; the mouse has no pull-up. Paula provides the high level:
`input.device` writes `$FF00` to `POTGO`, which drives all four POT pins high,
and then reads `POTINP`, where a pressed button reads 0. Minimig models this at
register level: `userio.v` builds the `POTINP` bits from its `mouse_btn` input
and the `POTGO` state, so the simulated Amiga always sees a clean register,
and the physical side ends at `main.vhd`.

The MEGA65 cannot drive those pins. On every board from R3 to R6, each POT pin
goes through 1 kΩ to a 1.2 nF capacitor with a discharge transistor and then
through an always-enabled buffer into the FPGA; this is the C64 paddle
circuit. There is no pull-up, and the FPGA can neither drive the pin nor reach
it with an internal pull-up. The bidirectional joystick lines of R4 and later
cover only the five digital pins (AExp keeps their outputs released). A
passive button that grounds pin 9 therefore looks exactly like an open pin:
the right and middle buttons of a real Amiga mouse are invisible, and no FPGA
design can change that.

What the MEGA65 can read is a device that drives the pin itself. The
framework's paddle sampler (`mouse_input.vhdl`, instantiated in
`qnice_wrapper.vhd`) discharges the capacitor for 256 µs and then counts, at
1 MHz and up to 255, how long the pin stays low; one cycle takes about
514 µs. The framework hands 255 minus that count to the core clock domain, so
an open or grounded pin reads `0x00` and a pin driven high reads close to
`0xFF`. The `pot_buttons` process in `main.vhd` takes bit 7 of `pot1_x_i` and
`pot1_y_i` with the Amiga's polarity, low means pressed, and guards it twice:

* A presence latch (`rmb_capable`, `mmb_capable`): a button is only read once
  its line has been seen high. An empty port and a passive mouse both read
  low and would otherwise hold the button down forever. On an Amiga, Paula's
  drive rules this case out; here the latch has to.
* A watchdog: after 30 seconds of uninterrupted "pressed"
  (`C_POT_BTN_TIMEOUT`), the latch clears, because that is what the floating
  line of an unplugged adapter looks like. A genuine hold of more than 30
  seconds is released once. The latch arms again within one sampler cycle,
  about half a millisecond, as soon as the line is driven high again.

Both latches and watchdogs clear with the Amiga reset. The result enters
Minimig as `mouse_btn <= pot_mmb & (kbd_mouse_rmb or pot_rmb) & '0'`, active
high in the order middle, right, left. The left button stays `'0'` here
because it reaches CIA-A through the fire line.

`kbd_mouse_rmb` is the keyboard substitute for the right button, `mouse_rmb_o`
of `keyboard.vhd`: RUN/STOP (matrix key 63) in MEGA65 keyboard mode, and the
up-arrow symbol key left of RESTORE (key 54) in Amiga mode, where RUN/STOP is
Esc. Neither key sends an Amiga keycode in the mode in which it is the
substitute, so the substitute never disturbs the key stream, and a reset
releases it. The middle button has no
substitute.

### 11.3 What works

| Device | Movement and left button | Right and middle button |
|---|---|---|
| Amiga mouse | works | invisible; use the keyboard substitute |
| Passive mouse behind a pull-up adapter (2 kΩ from pin 7 to pins 9 and 5, see [Mouse and joystick](../../README.md#mouse-and-joystick) in the README) | works | works |
| Adapter that drives the lines push-pull, high when released and low when pressed | works | works |
| Adapter that only grounds the lines | works | invisible; use the keyboard substitute |
| mouSTer in Amiga mouse mode, default settings | works | invisible; use the keyboard substitute |
| mouSTer firmware 3.23.5313 or newer with `activepotlines=true` in `[mouse]` | works | right button works |
| Commodore 1350 or 1351 | not supported | the 1351's changing POT value can cause phantom right clicks |

The buttons on the POT lines are read on port 1 only, because `userio.v` feeds
`mouse_btn` into the port-1 bits of `POTINP`; a mouse in port 2 moves and
clicks left, but nothing more. Passive Amiga mice have been tested on R3
(movement, left button, keyboard substitute, no phantom clicks) and a
push-pull USB adapter on R6 (right button). The middle button has not been
tried with a real three-button device.

## 12. Checking your work before a Vivado run

A synthesis takes long, so the project relies on a few local checks first. The
tools are free: [nvc](https://github.com/nickg/nvc) for VHDL, GHDL as a second
opinion, and Icarus Verilog for the Minimig sources.

* Analyse and elaborate the VHDL with `nvc --std=2008`, in dependency order
  (the M2M packages first). `clk.vhd` and `mega65.vhd` need small stub
  packages for the Xilinx `unisim` and `xpm` libraries.
  `CORE/sim/run_nvc_chain.sh` does both, with the stubs in `CORE/sim/stubs/`.
* Check the Verilog with `iverilog -g2012 -t null`, with stubs for `dpram` and
  `fx68k`.
* After any menu change, run the menu checker
  `tools/check_osm_menu.py`. It recomputes
  `OPTM_SIZE`, the submenu structure, the dependency rules, the visible menu
  height, the heap demand and the help page geometry from `config.vhd`, and
  checks every `C_MENU_*` constant against the text of the line it points to.
* After any firmware change, run the firmware checker
  `tools/check_firmware.py`. It checks the
  per-drive tables against the drive count, and it checks every `ADDC` and
  `SUBC` for a carry that comes from the right instruction. On QNICE only `ADD`, `ADDC`, `SUB`, `SUBC`, `SHL` and
  `SHR` write the carry flag, and an address calculation inserted between a
  32-bit `ADD` and its `ADDC` silently eats the carry.
* Assemble the firmware with a native build of the QNICE assembler to catch
  syntax errors. Run `make_rom.sh` itself only where the QNICE tool chain was
  built for the operating system you are on.

The testbenches live in `CORE/sim/`, one directory per area.
`CORE/sim/run_all.sh` runs the two checkers, the nvc chain and every bench
that finishes in minutes, and is the gate before a synthesis.
[Tools and testbenches](tools.md) describes each tool and bench, what it
verifies, how to run it and how long it takes. What the floppy benches
prove is described in
[hardware-floppy.md](hardware-floppy.md#11-how-it-was-verified).

In the Vivado log, check that the 68000's `microrom.mem` and `nanorom.mem` were
read successfully: a failure there is silent and produces a dead CPU.

## 13. Where to read next

* [developers.md](../developers.md): building the core from source.
* [floppy-adf.md](floppy-adf.md): the simulated floppy drives, from the Amiga
  disk format to the write-back invariants.
* [hardware-floppy.md](hardware-floppy.md): the MEGA65's internal drive as a
  real Amiga drive.
* [`minimig_fdd.cpp`](minimig_fdd.cpp) and
  [`minimig_config.cpp`](minimig_config.cpp): MiSTer's floppy service and
  configuration code, the software models of `adf_track_engine.vhd` and
  `amiga_config.vhd`.
* [`timing_closure.md`](timing_closure.md): the HyperRAM hold miss and the
  build re-roll.
* [audio.md](audio.md): the audio path and its filters.
* [`hdmi_latency.md`](hdmi_latency.md): HDMI latency and the flicker-free mode.
* The [M2M Wiki](https://github.com/sy2002/MiSTer2MEGA65/wiki): the framework
  itself, and the QNICE debug console.
* The [C64MEGA65](https://github.com/MJoergen/C64MEGA65) core: the reference
  M2M port, and the origin of several patterns used here (mount devices,
  physical drive, menu dependencies).
