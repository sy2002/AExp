# How to port a MiSTer core to the MEGA65
## The complete MiSTer-to-MEGA65 (M2M) porting guide

Version 1.0, June 2026. Written during and validated by the Amiga 500 (AExp)
port; examples reference the C64MEGA65 production port and the M2M framework
V2.0.1. Audience: human FPGA developers and AI assistants performing a port
in a clean session.

This guide covers PORTING a core that uses the MiSTer framework (sys/ +
emu module + HPS services) to the MEGA65 using the MiSTer2MEGA65 framework.
It is intended to supersede, for porting purposes, the M2M wiki chapters
"2. First Steps", "4. Understand the MiSTer core", "6. Basic wiring" and
"7. Get the core to synthesize". It does NOT cover the release process
(see the wiki chapter "XYZ. How to release your core") or M2M framework
development itself.

How to read this document:

- Part I    builds the mental model: what MiSTer provides, what M2M
            provides, and what replaces what. Read it once, completely.
- Part II   is the walkthrough: numbered steps S1..S130 in thirteen phases (0-12),
            from studying the MiSTer core to a released bitstream. Work
            through it in order.
- Part III  is the reference catalog of Quartus-to-Vivado and MiSTer-to-M2M
            patterns (sections A..J). Part II references it; you will grep
            it whenever Vivado errors at you.
- Part IV   is the debugging playbook and the appendices (port tables,
            repository map, glossary).

Conventions: "**RULE:**" marks hard requirements, "**TRAP:**" marks mistakes
that cost real debugging time (every one of them happened), "**Why:**"
explains rationale. File references are repo-relative; "C64MEGA65" means
the reference port at github.com/MJoergen/C64MEGA65, "the Amiga port" means
the AExp repo this guide was written in. Verify line numbers against the
repos when in doubt - code moves.

---

## Table of contents

- **Part I - The mental model**
  - 1.1 What a MiSTer core is made of - the anatomy every porter must know
  - 1.2 What M2M is made of
  - 1.3 The replacement map - one row per MiSTer service
  - 1.4 Hardware budget realities
- **Part II - The porting walkthrough (S1..S130)**
  - 2.0 Phase 0 - Study the MiSTer core before touching anything
  - 2.1 Phase 1 - Project setup from the template
  - 2.2 Phase 2 - Fork the MiSTer core and curate the file list
  - 2.3 Phase 3 - Make the RTL Vivado-clean
  - 2.4 Phase 4 - Clocks: clk.vhd
  - 2.5 Phase 5 - Wire main.vhd
  - 2.6 Phase 6 - Memories: BRAM, the QNICE side, HyperRAM
  - 2.7 Phase 7 - Replace the HPS services
  - 2.8 Phase 8 - The Vivado project files
  - 2.9 Phase 9 - First synthesis and what the logs tell you
  - 2.10 Phase 10 - Timing closure methodology
  - 2.11 Phase 11 - Hardware bring-up and testing
  - 2.12 Phase 12 - Towards release
- **Part III - The Quartus-to-Vivado pattern catalog**
  - 3.A Memory primitives (the biggest category)
  - 3.B PLL and clocking
  - 3.C Verilog/SystemVerilog constructs Vivado rejects (with exact error codes)
  - 3.D VHDL constructs
  - 3.E The mixed-language boundary (VHDL <-> Verilog/SV)
  - 3.F CDC and constraints (M2M-specific + general)
  - 3.G ROM/init data handling
  - 3.H The .xpr project file (full anatomy + the crash)
  - 3.I M2M framework integration reference
  - 3.J Local verification without Vivado
- **Part IV - Debugging playbook and appendices**
  - 4.1 The black-screen decision tree
  - 4.2 Reading Vivado's outputs - quick reference
  - 4.3 ILA / hardware debug
  - 4.4 Appendix A - main.vhd entity quick reference
  - 4.5 Appendix B - mega65.vhd port groups quick reference
  - 4.6 Appendix C - repository map
  - 4.7 Appendix D - glossary
  - 4.8 Appendix E - sources and further reading

---

# Part I - The mental model: MiSTer architecture, M2M architecture, and what replaces what

Porting a MiSTer core to the MEGA65 with the MiSTer2MEGA65 (M2M) framework is, at its
heart, a transplant operation: you take the machine (the "retro core") out of one body
(the MiSTer framework, which assumes a DE10-Nano with an ARM/Linux co-processor and
SDRAM) and stitch it into another body (M2M, which assumes a MEGA65 with a QNICE
softcore co-processor, BRAM and HyperRAM). Everything that goes wrong in a port goes
wrong because the porter misunderstood one of the two bodies, or assumed an organ
exists in the new body that does not. This part builds the complete mental model:
what a MiSTer core consists of (1.1), what M2M consists of (1.2), the exact
service-by-service replacement map (1.3), and the hardware budget you are porting
into (1.4). Parts II and III then turn this model into concrete porting steps.

## 1.1 What a MiSTer core is made of - the anatomy every porter must know

Before you touch any M2M file, you must be able to read a MiSTer core repository
fluently. MiSTer is a very disciplined project; every core repository has the same
three-layer layout, and your entire port is an exercise in understanding layer 3
(the glue) well enough to re-create it on top of M2M.

Also: understand the core as an end user first. Run it on a real MiSTer if you can,
or watch videos of it. You need to know how the core mounts disks, loads ROMs, and
what options its menu offers, because all of that is encoded in `CONF_STR` (see
1.1.3) and all of it translates into work items for your port.

### 1.1.1 The three layers: rtl/, sys/, and the root <Core>.sv

* **`rtl/` - the actual machine.** This folder contains the hardware description of
  the retro computer or arcade board itself: CPU, video chip, sound chip, glue
  chips, often the floppy controller, plus the core's PLL definition (`rtl/pll/`)
  and frequently the ROMs. This is the part you will carry over to the MEGA65
  mostly unchanged (Part II covers the Quartus-to-Vivado mechanics). For the C64
  core, `rtl/` contains `fpga64_sid_iec.vhd` (the C64 board), `video_vicII_656x.vhd`
  (the VIC-II), the `sid/` and `t65/` folders, `iec_drive/` (the 1541/1581), and
  `roms/` (see C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/).

* **`sys/` - the MiSTer framework.** This is MiSTer's hardware abstraction layer:
  `sys_top.v` (the real synthesis top-level, ~1700 lines in the C64 core's copy),
  `hps_io.sv` (the bridge to the ARM co-processor, see 1.1.4), the video pipeline
  (`video_mixer.sv`, `video_freak.sv`, `scandoubler.v`, `ascal.vhd`, `osd.v`), audio
  output (`audio_out.v`, `i2s.v`, `spdif.v`), and the framework PLLs (`pll_hdmi`,
  `pll_audio`, `pll_cfg`). **You never port anything from `sys/` into your M2M
  project** - M2M provides equivalents for all of it (the replacement map in 1.3 is
  exactly the mapping from `sys/` services to M2M services). You read `sys/` only
  to understand what a service does when the glue code uses it. Note one exception
  pattern: a few cores keep framework-flavored helpers outside `sys/` (the Minimig
  core has `hps_ext.v` in the repo root for Amiga-specific HPS communication); such
  files are part of the HPS contract and must be *replaced*, not compiled.

* **The root `<Core>.sv` - the glue, your study object and porting oracle.** Every
  MiSTer core has exactly one SystemVerilog file in the repository root named after
  the core (`c64.sv`, `Minimig.sv`, `Gameboy.sv`, ...). It contains a single module
  that is always called `emu`. `sys_top.v` instantiates `emu`; `emu` instantiates
  the actual machine from `rtl/` plus all glue logic. **RULE:** you do NOT compile
  `emu` in your M2M port and you do not port `sys_top.v`. You re-implement `emu`'s
  glue role yourself, in M2M's `main.vhd` (see Part III). The `<Core>.sv` file is
  nevertheless the single most important file of the whole port: it documents,
  in compilable form, every signal the actual machine needs, every default value,
  every piece of conditioning between the machine and the framework. When in doubt
  at any later stage ("what do I wire to input X?"), the answer is in `<Core>.sv`.
  Treat it as your oracle and keep it open during the entire port.

The official MiSTer developer documentation is worth reading once before you start,
even though we port *from* MiSTer rather than *to* it: the chapters "Porting Cores",
"Core Configuration String", "Overview of emu module" and "sys - hps_io" at
https://mister-devel.github.io/MkDocs_MiSTer/developer/ describe layer 2 and 3 from
the authors' perspective. You do not need to understand every detail; you need to
know where to look things up.

### 1.1.2 The emu module interface

Open the C64 specimen: C64MEGA65 CORE/C64_MiSTerMEGA65/c64.sv:26 declares
`module emu`. Its port list (lines 26-178) is the standardized contract between any
MiSTer core and the MiSTer framework, and it is worth knowing by heart because every
port group of it corresponds to one row of the replacement map in 1.3:

```systemverilog
module emu
(
   input         CLK_50M,          // master input clock, 50 MHz
   input         RESET,            // async reset from sys_top
   inout  [45:0] HPS_BUS,          // opaque bus to/from the ARM (hps_io)
   output        CLK_VIDEO,        // base video clock, usually == clk_sys
   output        CE_PIXEL,         // pixel clock enable relative to CLK_VIDEO
   output [12:0] VIDEO_ARX, VIDEO_ARY,  // aspect ratio for HDMI scaler
   output  [7:0] VGA_R, VGA_G, VGA_B,
   output        VGA_HS, VGA_VS,
   output        VGA_DE,           // = ~(VBlank | HBlank)
   ...
   output [15:0] AUDIO_L, AUDIO_R, // 16-bit audio
   output        AUDIO_S,          // 1 = samples are signed
   ...
   output        DDRAM_CLK, ...    // high-latency DDR3 interface
   output        SDRAM_CLK, ...    // lower-latency SDRAM interface
   input         UART_CTS, ...     // physical UART
   input   [6:0] USER_IN,          // user port
   output reg [6:0] USER_OUT,
   input         OSD_STATUS        // 1 while MiSTer OSD menu is open
);
```

(Abbreviated; verify against c64.sv:26-178. The exact list varies slightly per core
because of `ifdef`s like `MISTER_FB` and `MISTER_DUAL_SDRAM`.)

Three observations that shape your whole port:

* The machine in `rtl/` knows nothing of this interface. Only `emu` does. That is
  why porting the machine is feasible at all.
* Everything HPS-related (menu, file loading, disk images, keyboard, RTC) funnels
  through the single opaque `HPS_BUS` into the `hps_io` module. On M2M the same
  services funnel through the QNICE device bus (1.2.5) - structurally the two
  frameworks are siblings.
* The first thing `emu` typically does is tie off what the core does not use, e.g.
  c64.sv:180-181 zeroes the whole DDRAM interface and tristates SD-SPI. These
  tie-offs tell you which services you can ignore in your port. The C64 uses SDRAM
  but not DDRAM; the Minimig uses DDRAM (for the HPS-side HDD bridge) but the
  MEGA65 port replaces that path entirely.

### 1.1.3 CONF_STR - the configuration string is the core's requirements document

Inside `emu` you will find a `localparam CONF_STR` (c64.sv:197-270): a long
concatenated string that the ARM side parses to build the MiSTer on-screen menu.
**CONF_STR is paramount.** It is the most compact, most reliable statement of what
the core needs from its environment: every menu option maps to a status bit the core
consumes, every `F`/`S` entry declares a file or disk-image type the core loads, and
the option labels tell you what each status bit *means*. You will translate CONF_STR
into M2M's `config.vhd` almost mechanically (see Part III), so learn to read it now.
Annotated excerpts from the C64 core:

```systemverilog
localparam CONF_STR = {
   "C64;UART9600:2400;",            // core name; UART feature declaration
   "H7S0,D64G64T64D81,Mount #8;",   // S0: disk image slot 0 (vdrive 0),
                                    //     extensions D64/G64/T64/D81;
                                    //     H7 = hidden when menumask bit 7 set
   "F1,PRGCRTREUTAP;",              // F1: file loader, ioctl_index 1
   "P1O2,Video Standard,PAL,NTSC;", // page 1; O2 = status[2], 2 choices
   "P1O45,Aspect Ratio,...;",       // O45 = status[5:4], up to 4 choices
   "P2FC8,ROM,System ROM C64+C1541 ;", // FC8: file loader, ioctl_index 8,
                                    //     C = remember and auto-load at start
   "oEF,Turbo mode,Off,C128,Smart;",// lower-case o = upper status word:
                                    //     oEF = status[47:46]
   "R0,Reset;",                     // R0: momentary trigger on status[0]
   "J,Fire 1,Fire 2,...;",          // joystick button mapping
   "V,v",`BUILD_DATE                // version string
};
```

Reading rules you will use constantly (full grammar in MiSTer's "Core Configuration
String" doc): `O<n>` / `O<nm>` define option fields in `status[31:0]`, with positions
given as base-36 digits (0-9, then A=10 ... V=31); lower-case `o<n>` addresses the
upper 32 bits, i.e. `o0` = status[32]. `R<n>`/`r<n>` are momentary reset-style
triggers. `T<n>` are momentary toggles. `F<index>,<EXTS>` declares a file selector
whose downloads arrive over ioctl with that index; `S<slot>,<EXTS>` declares a
mountable disk image on virtual-drive slot `<slot>` served over the sd/img block
interface. `P<n>` prefixes put entries on submenu pages; `H<n>`/`h<n>`/`D<n>`/`d<n>`
hide or disable entries depending on the `status_menumask` input of `hps_io`
(c64.sv:438 shows the C64 building that mask out of runtime conditions such as
"tape loaded"). The comment block at c64.sv:189-194 ("Status Bit Map") is the
core author's own ledger of which of the 64 status bits are taken - most cores
have one; consult it before you re-purpose any bit.

**RULE:** for every CONF_STR line, decide early: (a) replicate in the M2M menu,
(b) hard-wire to a sensible constant, or (c) drop the feature for now. Status bits
you hard-wire must get exactly the constant value the core expects - find the
encoding by reading how `status[n]` is consumed inside `emu`. A status bit wired
wrong is one of the classic "core synthesizes but does not boot" causes.

### 1.1.4 The HPS services - what the ARM does for the core

The DE10-Nano is a SoC: an ARM Cortex-A9 running Linux ("HPS" = Hard Processor
System) sits next to the FPGA fabric. MiSTer's `Main_MiSTer` Linux program draws
the menu, browses files, reads SD cards - and the `hps_io` module
(sys/hps_io.sv) is the fabric-side endpoint. In M2M, the QNICE softcore plus the
Shell firmware play exactly this role. `hps_io` is instantiated once in `emu`
(c64.sv:422: `hps_io #(.CONF_STR(CONF_STR), .VDNUM(2), .BLKSZ(1))` - 2 virtual
drives, 256-byte blocks; block size is 128 << BLKSZ, see hps_io.sv:28) and
provides these service groups (port refs are
C64MEGA65 CORE/C64_MiSTerMEGA65/sys/hps_io.sv):

* **Status word**: `output reg [63:0] status` (hps_io.sv:71) carries all menu
  choices into the core; `status_in`/`status_set` lets the core write bits back.
  This is the core's entire configuration interface.
* **ioctl - file download**: `ioctl_download`, `ioctl_index[15:0]`, `ioctl_wr`,
  `ioctl_addr[26:0]`, `ioctl_dout`, plus upload and `ioctl_wait` for backpressure
  (hps_io.sv:101-110). When the user picks a file for an `F` entry, the ARM streams
  it byte-by-byte (or word-wise in WIDE mode) into the core; `ioctl_index`
  identifies which `F` entry it came from. The core decodes the index into load
  targets - c64.sv:470-476 is a textbook example (`load_prg = ioctl_index=='h01`,
  `load_rom = ioctl_index==8`, ...). ROMs, cartridges, tapes and custom filter
  files all arrive this way.
* **sd/img - block-level disk image interface**: per virtual drive, the core
  requests blocks (of the BLKSZ-configured size) of a mounted image:
  `sd_lba[VDNUM]` (logical block
  address, hps_io.sv:88), `sd_rd`/`sd_wr` request strobes, `sd_ack` handshake, and
  a byte stream `sd_buff_addr`/`sd_buff_dout`/`sd_buff_din`/`sd_buff_wr`
  (hps_io.sv:88-99). Mount events arrive on `img_mounted[VD:0]` with
  `img_size[63:0]` and `img_readonly` (hps_io.sv:83-85). The core-side disk
  controller (e.g. the C64's `iec_drive`) implements the drive emulation against
  this protocol; the ARM serves the actual file. **This protocol is preserved
  bit-compatibly by M2M's vdrives mechanism** - the single best piece of news in
  the whole replacement map (see 1.3).
* **PS/2 keyboard and mouse**: `ps2_key[10:0]` (hps_io.sv:143) delivers PS/2 scan
  codes: bits [7:0] code, [8] extended, [9] pressed, [10] a toggle that flips on
  every new event (hps_io.sv:279). `ps2_mouse[24:0]` similarly. Cores either
  consume these directly or convert to a matrix. M2M does NOT speak PS/2 (1.3).
* **Joysticks/paddles**: `joystick_0..5[31:0]`, `paddle_0..5[7:0]`, button mapping
  per the `J`/`jn`/`jp` CONF_STR lines.
* **RTC**: `RTC[64:0]` in MSM6242B layout (hps_io.sv:116-117) plus a Unix
  `TIMESTAMP[32:0]` (hps_io.sv:120) - wall-clock time from Linux.
* **Misc**: `buttons`, `forced_scandoubler`, `gamma_bus` (video pipeline coupling),
  `EXT_BUS` for core-specific extensions (the Minimig uses this with `hps_ext.v`
  for its keyboard/mouse/HDD/RTC sideband - cores with an `EXT_BUS`/`hps_ext`
  construct need extra analysis because they bypass the standard services).

### 1.1.5 Walkthrough: dissecting c64.sv in fifteen minutes

Apply this drill to any core; here it is for the specimen
(C64MEGA65 CORE/C64_MiSTerMEGA65/c64.sv):

1. **Find the actual machine.** Search the `emu` body for instantiations whose
   names are not framework-ish. c64.sv:929 instantiates `fpga64_sid_iec fpga64`
   from `rtl/fpga64_sid_iec.vhd` - one look at its ports (`clk32`, `ps2_key`,
   `ramAddr/ramDout/ramDin`, `hsync/vsync/r/g/b`, c64.sv:929-969) confirms it: this
   is the C64. *This module, not `emu`, is what you will instantiate in M2M's
   `main.vhd`.* Other examples: Apple-II.sv -> `apple2_top`, Gameboy.sv -> `gb`,
   Minimig.sv -> `minimig` (plus, for the Amiga, the CPU and chip-RAM controller
   live as siblings next to `minimig` inside `emu` - some cores split the machine
   across several top-level instances, and then `main.vhd` must host all of them).
2. **Find the PLL and extract the clock plan.** c64.sv:278-287: `pll` produces
   `clk48`, `clk64`, `clk_sys`. The Quartus PLL config in `rtl/pll/pll_0002.v`
   gives the exact frequencies: clk_sys = 31.527954 MHz (the machine; /32 = the PAL
   CPU clock 985248 Hz), clk64 = 2x clk_sys (video + SDRAM), clk48 for the OPL
   audio expander. Also note c64.sv:296-308: a `pll_cfg` reconfigures the PLL at
   runtime to switch PAL/NTSC - dynamic reconfiguration like this is a porting
   decision point (M2M cores typically synthesize one fixed clock plan per video
   standard or instantiate parallel MMCMs; see Part II on clk.vhd). **RULE:** hit
   the original frequencies as exactly as the MMCM allows; "close enough" clocks
   cause subtle compatibility damage (CIA timers, tape loaders, audio pitch).
3. **Find hps_io and inventory the services used.** c64.sv:422-468: status (64
   bits), menumask, 4 joysticks + 4 paddles, 2-slot sd/img, ps2 keyboard+mouse,
   RTC, ioctl with backpressure. Each connected port becomes a row in your
   replacement worksheet (1.3).
4. **Trace video.** From `fpga64` outputs `hsync/vsync/r/g/b` through the
   `video_sync` module in rtl/ (which generates hblank/vblank and crops the frame)
   onward to `emu`'s VGA_* outputs and the `video_mixer` in sys/. Where the analog
   signal is complete (RGB + HS + VS + HBlank + VBlank) is your M2M tap point.
5. **Trace audio.** Find what feeds `AUDIO_L/R` and whether `AUDIO_S` says signed.
6. **Inventory memory.** Search for `SDRAM_`, `DDRAM_`, and every BRAM-inferring
   pattern in rtl/ (Part II covers the full memory census; the budget rules are
   in 1.4).

Time spent here pays off tenfold. The single biggest porting mistake is starting to
wire `main.vhd` before being able to answer, for every input of the actual machine
module, "what does `emu` drive into this and why".

## 1.2 What M2M is made of

M2M mirrors MiSTer's structure deliberately: a framework HAL plus a thin layer of
user-owned glue. This chapter walks the stack top-down as it exists in M2M V2.0.1
(the version vendored in this repo at AExp/M2M).

### 1.2.1 The split rule: CORE/ vs M2M/

An M2M-based project (clone of the MiSTer2MEGA65 template) has two top-level source
trees:

* **`M2M/`** - the framework. *Board-dependent, core-independent.* You normally do
  not modify anything here; framework updates are taken by fast-forwarding the
  folder (or submodule) to a newer M2M release.
* **`CORE/`** - your port. *Core-dependent, board-independent.* Everything specific
  to the machine you are porting lives here: the MiSTer core sources (conventionally
  as a git submodule, e.g. C64MEGA65 CORE/C64_MiSTerMEGA65, or in this repo
  CORE/Minimig_MiSTerMEGA65), your glue VHDL in `CORE/vhdl/`, the firmware overlay
  in `CORE/m2m-rom/`, the Vivado projects and constraints.

**RULE:** if you find yourself editing a file under `M2M/`, stop and reconsider.
Either you are working around a missing framework feature (acceptable, but document
it and expect merge pain on the next framework update) or you misunderstood where
the change belongs. The clean port touches only `CORE/`.

### 1.2.2 The hardware stack: board top, framework.vhd, MEGA65_Core

The synthesis top-level is one of four board tops: `M2M/vhdl/top_mega65-r3.vhd`
(entity `mega65_r3`, AExp M2M/vhdl/top_mega65-r3.vhd:17) and its R4/R5/R6 siblings.
The MEGA65 was produced in several hardware revisions (R3/R3A, R4, R5, R6) that
differ in audio DAC, RTC chip, expansion-port wiring and similar board details -
but NOT in the FPGA (see 1.4). Each board top owns the physical pins and
instantiates exactly two things:

* `i_framework : entity work.framework` (top_mega65-r3.vhd:487) - the HAL, and
* `CORE : entity work.MEGA65_Core` (top_mega65-r3.vhd:670) - *your* code
  (`CORE/vhdl/mega65.vhd`), passed a `G_BOARD` generic string so the rare
  board-specific behavior can be handled inside the core if needed.

`framework.vhd` is worth skimming once to know what you get for free. Its
instantiations (all refs AExp M2M/vhdl/framework.vhd) are the M2M services:

* `i_clk_m2m` (framework.vhd:440): the framework clocks - QNICE @ 50 MHz, HyperRAM
  @ 100 MHz (plus a 200 MHz delay-calibration clock), audio @ 12.288 MHz (see
  M2M/vhdl/clk_m2m.vhd:28-36); the HDMI video clocks come from `i_video_out_clock`
  (framework.vhd:467), which dynamically reconfigures for the selected HDMI mode.
* `i_reset_manager` (framework.vhd:490): power-on/long-press reset sequencing,
  giving the core the two distinct resets `main_reset_m2m` (whole machine) and
  `main_reset_core` (core only).
* `i_m2m_keyb` (framework.vhd:556): the MEGA65 keyboard controller (see 1.3.4).
* `i_qnice_wrapper` (framework.vhd:585): the QNICE SoC, its memory-mapped devices
  (SD card, UART, on-screen-display VRAM, config data), and the bridge that turns
  QNICE memory accesses into the device bus your code sees (1.2.5).
* `i_avm_arbit_general` (framework.vhd:684): the Avalon memory-mapped arbiter in
  front of `i_hyperram` (framework.vhd:968) - HyperRAM is shared between the
  scaler, QNICE and (optionally) your core (see 1.4.2).
* `i_av_pipeline` (framework.vhd:864): the entire audio/video output machine -
  OSM overlay, scandoubler, ascal polyphase scaler, HDMI encoding, audio filters
  (see 1.3.5/1.3.6).
* `i_rtc_wrapper` (framework.vhd:1012): I2C access to the board RTC chip, exposed
  to QNICE and to the core (see 1.3.9).

**Why:** the point of this architecture is the same as MiSTer's `sys_top`/`emu`
split - your `MEGA65_Core` never touches a pin, a PLL primitive for HDMI, or an SD
card; it speaks only the tidy port list of `mega65.vhd`, so one port runs on all
board revisions by building four nearly identical Vivado projects.

### 1.2.3 The files the porter owns

These are the files you create or substantially edit; everything else is framework
or imported MiSTer code. The C64MEGA65 set (C64MEGA65 CORE/vhdl/ and CORE/) is the
canonical example of all of them:

| File | Role |
|---|---|
| `CORE/vhdl/mega65.vhd` | Entity `MEGA65_Core`: your half of the framework contract. Hosts the QNICE-domain devices (vdrives, ROM loaders), the clock-domain crossings, and instantiates `clk.vhd` and `main.vhd`. The template version works out of the box; you extend it. |
| `CORE/vhdl/main.vhd` | The machine wrapper, your re-implementation of `emu`'s glue role: instantiates the actual MiSTer core module(s) and adapts keyboard, video, audio, joysticks. Lives entirely in the core clock domain. |
| `CORE/vhdl/clk.vhd` | Your MMCM(s) generating the core clock(s) - the replacement for `rtl/pll` (see 1.3.7). |
| `CORE/vhdl/globals.vhd` | Core constants for the framework: `CORE_CLK_SPEED`, ROM/CRT load lists (`C_CRTROMS_AUTO`/`C_CRTROMS_MAN`), vdrive configuration (`C_VDNUM`, `C_VD_DEVICE`, `C_VD_BUFFER`), QNICE device IDs. |
| `CORE/vhdl/config.vhd` | The Shell configuration: OSM menu structure, welcome/help screens, file-browser defaults - M2M's CONF_STR equivalent (see 1.3.1). |
| `CORE/vhdl/keyboard.vhd` | Core-specific keyboard mapping from M2M's key-number protocol to whatever the core wants (see 1.3.4). |
| `CORE/m2m-rom/m2m-rom.asm` | The QNICE firmware build file: includes the framework firmware and your callback implementations (see 1.2.4). |
| `CORE/CORE.xdc` | Core-specific timing constraints: your generated clocks, CDC exceptions (see 1.3.8 and Part II). |
| `CORE/CORE-R3.xpr` ... `CORE-R6.xpr` | Four Vivado project files, one per board revision, identical except for the board top and pin XDC they pull from `M2M/`. Keep them in sync - a file added to only one of them is a classic source of "works on my board" releases. |

### 1.2.4 QNICE, Monitor, firmware, Shell - who is the "ARM" here

M2M replaces MiSTer's ARM/Linux co-processor with **QNICE**, a 16-bit softcore CPU
(M2M/vhdl/QNICE/) running at 50 MHz with its own RAM and ROM inside the FPGA. Three
distinct software layers run on it, and the terminology matters when you read M2M
documentation:

* **Monitor** - the QNICE "operating system" (M2M/rom/monitor/): low-level routines
  and, in debug builds, an interactive serial console. Comparable to a BIOS.
* **Firmware** - everything assembled into `m2m-rom.rom` and loaded at startup. The
  framework part lives in `M2M/rom/` (`main.asm`, `shell.asm`, `menu.asm`,
  `dirbrowse.asm`, `vdrives.asm`, ...); your part is `CORE/m2m-rom/m2m-rom.asm`,
  which `#include`s the framework files and implements core-specific callback
  functions (C64MEGA65 CORE/m2m-rom/m2m-rom.asm:30-39 shows the pattern: include
  `../../M2M/rom/main.asm`, include `../../M2M/rom/shell.asm`, then
  `START_FIRMWARE RBRA START_SHELL, 1`).
* **Shell** - the standard M2M user interface implemented by the framework firmware:
  the on-screen menu (OSM), file browser, disk mounting, ROM loading, settings
  persistence. Almost every port simply starts the Shell and customizes it via
  `config.vhd` plus a handful of assembly callbacks (submenu summaries, file-type
  checks, custom messages). You *can* write firmware that bypasses the Shell, but
  for a MiSTer port you should not - the Shell is the part of M2M that replaces
  MiSTer's `Main_MiSTer` menu program.

The practical takeaway: things MiSTer does "in software on the ARM" (browse SD
card, parse a disk image header, decide where a ROM goes, draw the menu) are done
in QNICE assembly on M2M - mostly by the existing Shell, occasionally by callbacks
you write. You will write VHDL for the hardware services and a little assembly for
the software services; budget for both.

### 1.2.5 The QNICE device bus - how firmware reaches your hardware

QNICE has a 16-bit address space, so it cannot linearly address core memories. M2M
solves this with a windowed MMIO scheme (defined in M2M/rom/sysdef.asm:195-211):

* Register `0xFFF4` (`M2M$RAMROM_DEV`) selects a **device** by 16-bit ID.
* Register `0xFFF5` (`M2M$RAMROM_4KWIN`) selects a **4k window** within that device.
* Address range `0x7000-0x7FFF` (`M2M$RAMROM_DATA`) is the 4k window itself: reads
  and writes there go to the selected device at
  `address = window * 4096 + offset`.

**RULE:** device IDs below `0x0100` are reserved for the framework
(M2M/vhdl/qnice_wrapper.vhd:280-282); your devices start at `0x0100`. Framework
devices include the OSM video RAM (`0x0000`/`0x0001`), the `config.vhd` data
(`0x0002`), the ascal polyphase filter RAM (`0x0003`), HyperRAM (`0x0004`), and the
**sysinfo device** `0x00FF` (`M2M$SYS_INFO`, sysdef.asm:208) through which the
firmware reads hardware facts at runtime: vdrive constants from `globals.vhd`,
screen geometry per graphics adaptor, and the ascal-measured visible picture size
of your core (sysdef.asm:214-245) - this is how the Shell adapts to your core
without recompilation.

On the hardware side, `mega65.vhd` receives the decoded bus in the QNICE clock
domain (C64MEGA65 CORE/vhdl/mega65.vhd:61-67):

```vhdl
qnice_dev_id_i   : in  std_logic_vector(15 downto 0);  -- device selector
qnice_dev_addr_i : in  std_logic_vector(27 downto 0);  -- window & 4096 + offset
qnice_dev_data_i : in  std_logic_vector(15 downto 0);
qnice_dev_data_o : out std_logic_vector(15 downto 0);
qnice_dev_ce_i   : in  std_logic;
qnice_dev_we_i   : in  std_logic;
qnice_dev_wait_o : out std_logic;  -- stretch the QNICE access (e.g. slow RAM)
```

You decode `qnice_dev_id_i` against the IDs you defined in `globals.vhd` and route
the access to the right RAM/ROM/CSR. The C64 defines seven devices this way
(C64MEGA65 CORE/vhdl/globals.vhd:85-91): the C64 main RAM (`0x0100`, lets the Shell
inject PRG files and take RAM snapshots), the vdrives device, a disk-image buffer
RAM, the CRT cartridge device, the PRG loader, and two custom-Kernal ROM devices.
Anything that "behaves like a RAM or ROM from the perspective of QNICE" can be a
device - this one mechanism carries ROM loading, disk buffering, core control
registers and debug visibility (see Part III).

### 1.2.6 Clock domains, the prefix convention, OSM control vector, gp register

M2M is rigorously multi-clock, and the codebase encodes the domain of every signal
in its name. Internalize this convention before reading or writing a single line -
it is the difference between CDC bugs you see at a glance and CDC bugs you chase
for weeks:

* `main_*` - the **core clock** domain: whatever your `clk.vhd` generates as the
  machine clock (C64: ~31.528 MHz; Amiga port: 28.375 MHz). Your `main.vhd`
  lives here.
* `qnice_*` - the **QNICE 50 MHz** domain: device bus, vdrives, loaders, all
  Shell-facing logic.
* `hr_*` - the **HyperRAM 100 MHz** domain: the Avalon interface to the arbiter.
* `video_*` - the **video output** domain: what you feed into the AV pipeline.
  Often `video_clk == main_clk` (the C64 keeps them identical), but the framework
  treats it as a separate domain so cores with a distinct video clock work too.
* `audio_*` - the framework's 12.288 MHz audio domain (you rarely touch it; you
  hand over `main_audio_*` and the framework crosses it for you).

The port list of `MEGA65_Core` is grouped by domain with explicit banner comments
(mega65.vhd:30, :70, :88, :104), and every crossing between domains inside
`mega65.vhd` goes through the framework's CDC primitives (`cdc_stable`,
`cdc_pulse`, XPM FIFOs - see mega65.vhd:927-954 for the CORE->HyperRAM and
CORE<->QNICE crossings in the C64 port). **TRAP:** wiring a `qnice_*` signal
directly into `main_*` logic will usually work in simulation and fail rarely and
unreproducibly on hardware. The naming convention exists so reviewers can spot
this; honor it in every signal you add. (Part III covers the CDC patterns in
detail.)

Two 256-bit vectors travel from QNICE to your core, pre-synchronized by the
framework into each domain:

* **The OSM control vector** (`qnice_osm_control_i` /  `main_osm_control_i`,
  mega65.vhd:55 and :122): one bit per on-screen-menu item, set by the Shell
  according to the user's menu selections that you declared in `config.vhd`. This
  is M2M's `status` word - wider than MiSTer's 64 bits and 1-bit-per-menu-line
  rather than bit-field encoded. You define named index constants for the bits
  (C64MEGA65 mega65.vhd:320-345, `C_MENU_*`) and decode combinations where a
  MiSTer core expected a multi-bit field (mega65.vhd:498-517 turns four mutually
  exclusive menu lines back into the 2-bit `c64_rom` select). The indices must
  match the menu line positions in `config.vhd` - see 1.3.1.
* **The general-purpose register** (`qnice_gp_reg_i` / `main_qnice_gp_reg_i`,
  mega65.vhd:58 and :125): 256 bits of free-form data the firmware can write for
  core-specific purposes that do not fit the menu model (the C64 uses it to pass
  flags from Shell callbacks). Think of it as your private mailbox from assembly
  to hardware.

## 1.3 The replacement map - one row per MiSTer service

This is the heart of the mental model: for every service that MiSTer's `sys/` and
the HPS provide, the M2M replacement, side by side. Build a worksheet from your
core's `hps_io` instantiation and tick off every connected port against this table.

| MiSTer service (sys/ + HPS) | M2M replacement | Your work product |
|---|---|---|
| `status[63:0]` menu bits from CONF_STR | 256-bit `osm_control` vector, one bit per menu line | `config.vhd` menu + `C_MENU_*` decode in `mega65.vhd`/`main.vhd` |
| ioctl file/ROM download (`F` entries) | CRTROM auto/manual loading: Shell reads FAT32 file, streams it into a QNICE device | device IDs + `C_CRTROMS_AUTO`/`_MAN` in `globals.vhd`, a RAM/loader device behind the QNICE bus |
| sd/img block interface (`S` entries) | `M2M/vhdl/vdrives.vhd` - bit-compatible `sd_*`/`img_*` protocol, served by QNICE FAT32 | instantiate `vdrives` next to the unmodified MiSTer drive logic; vdrive constants in `globals.vhd`; menu mount entries in `config.vhd` |
| `ps2_key`/`ps2_mouse` from hps_io | `m2m_keyb` key-number scan (no PS/2!) | your own `CORE/vhdl/keyboard.vhd` mapping 80 MEGA65 keys to the core's expectation |
| `video_mixer`/`video_freak`/`ascal`/OSD in sys/ | the framework `av_pipeline` (OSM, optional scandoubler, ascal to HDMI) | feed raw RGB + HS/VS + HBlank/VBlank + pixel CE out of `main.vhd`; set video mode/scaler options via OSM |
| `audio_out.v`, I2S/SPDIF in sys_top | framework audio path incl. the same IIR filter | drive `main_audio_left_o/right_o` (signed 16 bit); copy filter coefficients into `globals.vhd` |
| Quartus `pll` + `pll_cfg` | your `CORE/vhdl/clk.vhd` with Xilinx MMCME2_ADV | recompute multipliers/dividers for the original frequencies |
| `sys.sdc` / `<core>.sdc` timing constraints | `M2M/MEGA65-RX.xdc` + `M2M/common.xdc` (framework) and `CORE/CORE.xdc` (yours) | translate core-specific SDC content to XDC; add CDC constraints |
| `RTC[64:0]` from Linux | `main_rtc_i : in std_logic_vector(64 downto 0)` from the framework RTC wrapper (same MSM6242B-style layout) | wire it through if the core uses it |
| joysticks/paddles via hps_io | framework-debounced MEGA65 joystick ports + paddle ADC, delivered into `main.vhd` | wire and (optionally) offer swap via OSM |
| `Main_MiSTer` menu/browser on Linux | QNICE Shell + your `m2m-rom.asm` callbacks | `config.vhd` + assembly callbacks |

The subsections add the detail you need to actually do each row.

### 1.3.1 Status bits -> config.vhd and the osm_control vector

In MiSTer, CONF_STR defines the menu and the ARM packs the user's choices into
`status[63:0]`, including multi-bit fields (`O45` = a 2-bit field). In M2M you
declare the menu in `CORE/vhdl/config.vhd` as a list of menu items with group IDs,
defaults (`OPTM_G_STDSEL`), separator lines, submenus and headlines (the `OPTM_G_*`
flag constants are documented in C64MEGA65 CORE/vhdl/config.vhd:338-346), and the
Shell maintains one bit per *menu line* in the 256-bit `osm_control` vector. Three
consequences:

* A MiSTer 2-bit field with four choices becomes four mutually exclusive menu
  lines (a "group"), i.e. four one-hot bits that you re-encode in VHDL
  (C64MEGA65 CORE/vhdl/mega65.vhd:498-500 re-creates the 2-bit Kernal select from
  three `C_MENU_*` bits plus a default).
* The bit index *is* the menu line position. Keep the `C_MENU_*` constants
  (C64MEGA65 mega65.vhd:320-345) in lockstep with `config.vhd` - inserting a menu
  line shifts every constant below it. **TRAP:** a misaligned `C_MENU_*` constant
  produces a core that works but obeys the wrong menu items; after every menu
  edit, re-check the constants. (M2M V2.0.1 has no automatic consistency check.)
* The Shell persists the vector to a config file on the SD card
  (`config.vhd`'s `CFG_FILE` mechanism, C64MEGA65 config.vhd:281-282), so user
  settings survive power cycles - something MiSTer does ARM-side in `MiSTer.ini`
  style files; you get it for free, but it means changed menu layouts need a new
  config-file version (see the `OPTM` documentation in config.vhd).

The OSM is rendered by the framework into a dedicated VRAM overlaid by
`av_pipeline`; unlike MiSTer there is no `OSD_STATUS`-style signal you must handle
in the core, but M2M offers `main_pause_core_i` (mega65.vhd:119) if you want
"pause when OSD is open" behavior.

### 1.3.2 ioctl ROM download -> CRTROM loading via the QNICE device bus

MiSTer streams files into the core over ioctl, addressed by `ioctl_index`. M2M
replaces this with the **CRT/ROM loading** mechanism: the Shell (QNICE software)
reads a file from the FAT32 SD card and writes it, word by word through the 4k
MMIO window, into a QNICE device that you implement - typically a dual-clock RAM
or a small loader state machine sitting between the QNICE bus and the core's ROM.

Two flavors, both declared in `globals.vhd`:

* **Manual loading** (`C_CRTROMS_MAN`): bound to "Load ..." menu items in
  `config.vhd`; the user picks a file in the Shell's file browser and the Shell
  streams it to the device. The C64 binds its PRG loader and CRT cartridge device
  this way (C64MEGA65 CORE/vhdl/globals.vhd:148-149).
* **Automatic loading** (`C_CRTROMS_AUTO`): loaded by the Shell at startup/reset,
  before the core runs, with a per-entry `C_CRTROMTYPE_MANDATORY` or
  `C_CRTROMTYPE_OPTIONAL` flag and a zero-terminated filename packed into
  `C_CRTROMS_AUTO_NAMES` (C64MEGA65 globals.vhd:171-181; the C64 auto-loads
  optional JiffyDOS ROMs). A MANDATORY entry that is missing on the SD card stops
  the Shell with an error screen - this is the mechanism a port uses for
  must-have system ROMs that cannot be shipped in the bitstream for legal
  reasons. (Amiga port: the Kickstart ROM is exactly such a case -
  AExp CORE/vhdl/globals.vhd:151-153 declares `C_DEV_AMIGA_KICK` as a
  `C_CRTROMTYPE_MANDATORY` auto-load CRTROM with filename `/amiga/kick.rom`.)

The target of either flavor is identified by `C_CRTROMTYPE_DEVICE` plus your
device ID (loading into HyperRAM instead is provided for via
`C_CRTROMTYPE_HYPERRAM`, C64MEGA65 globals.vhd:127-129). Note the structural
difference from MiSTer: there is no single linear `ioctl_addr` bus into the core;
each loadable object gets its own device, which makes the data path explicit and
keeps clock domains clean (QNICE writes on `qnice_clk`, the core reads on
`main_clk` from the other port of a dual-clock BRAM). Parsing logic that MiSTer
runs on the ARM (e.g. C64 `.CRT` header parsing) becomes either QNICE assembly or
a hardware parser - the C64 port chose hardware (`crt_parser.vhd`,
`crt_cacher.vhd` in C64MEGA65 CORE/vhdl/).

### 1.3.3 sd/img disk interface -> vdrives.vhd + QNICE FAT32

The best-engineered replacement in M2M: `M2M/vhdl/vdrives.vhd` re-implements the
virtual-drives part of `hps_io.sv` **protocol-compatible at the signal level**. Its
header says it plainly: "this module can be directly wired to the 'SD' interface
of MiSTer's drives" (AExp M2M/vhdl/vdrives.vhd:1-12; note the documented V2.0.1
constraint there: 8-bit data/14-bit address only, hps_io's "WIDE" mode is not
supported). The consequence for your port: **the MiSTer drive emulation logic is
ported unmodified.** The C64 port instantiates MiSTer's `iec_drive` straight from
the submodule and wires its `sd_lba/sd_blk_cnt/sd_rd/sd_wr/sd_ack/sd_buff_*` and
`img_mounted/img_readonly/img_size` ports 1:1 to `vdrives`
(C64MEGA65 CORE/vhdl/main.vhd:1452-1505 and 1537-1586).

Division of labor:

* **Hardware (vdrives.vhd)**: exposes the MiSTer-protocol signals to the drive
  logic (core clock domain for `img_*`, QNICE clock domain for the `sd_*` block
  access, exactly like MiSTer splits them between `clk_sys` of the core and of
  hps_io), and presents control/data registers to QNICE as a device (the register
  map is documented in vdrives.vhd:14-46). It adds a write-cache management layer
  (`cache_dirty_o`, flush timing) that MiSTer does not need because Linux buffers
  writes.
* **Software (Shell, M2M/rom/vdrives.asm)**: implements the reverse-engineered
  MiSTer SD protocol (documented step by step in vdrives.vhd:48 onward): on
  `sd_rd` it seeks into the mounted image file on the FAT32 SD card, streams 
  the requested blocks into the drive's buffer RAM via `sd_buff_*`, handles
  writes back to the file, and strobes `img_mounted` with size/readonly when the
  user mounts an image via the file browser.
* **Your glue**: set `C_VDNUM` (number of drives), `C_VD_DEVICE` (the QNICE device
  ID of the vdrives instance) and `C_VD_BUFFER` (the device ID of the disk image
  buffer RAM) in `globals.vhd` (C64MEGA65 globals.vhd:114-116), add mount menu
  items in `config.vhd`, instantiate `vdrives` with the right `BLKSZ` (the C64
  uses 256-byte blocks to match `iec_drive`, main.vhd:1540), and generate any
  clock enables the drive logic expects (the C64 derives a drift-compensated
  16 MHz CE for the 1541, main.vhd:1517-1535).

**Why this matters strategically:** disk drives are usually the most complex and
most timing-sensitive part of a retro core (GCR encoding, half-tracks, copy
protection). Because the sd/img protocol survives the port bit-for-bit, all of
that complexity stays untouched MiSTer code - your risk concentrates in the
QNICE-side file handling, which the Shell already implements generically.

### 1.3.4 PS/2 keyboard -> the M2M key-number scan + your keyboard.vhd

MiSTer delivers PS/2 scan codes (`ps2_key[10:0]`, see 1.1.4) because its cores
historically grew out of MiST. M2M does **not** emulate PS/2. The framework's
`m2m_keyb` (AExp M2M/vhdl/m2m_keyb.vhd) talks to the MEGA65's keyboard
microcontroller and presents, in the core clock domain, the simplest possible
interface (C64MEGA65 mega65.vhd:132-133, main.vhd:76-77):

```vhdl
main_kb_key_num_i       : in integer range 0 to 79;  -- cycles through all keys
main_kb_key_pressed_n_i : in std_logic;              -- low-active, debounced
```

The scanner sweeps the 80 MEGA65 key numbers at 1 kHz (the whole keyboard 1000
times per second; generic `SCAN_FREQUENCY`, m2m_keyb.vhd:28), so your
`CORE/vhdl/keyboard.vhd` simply latches "pressed" state per key into whatever
structure the core wants. You have two implementation strategies, in order of
preference:

1. **Matrix injection (preferred).** Most 8-bit/16-bit machines scan a keyboard
   matrix; the MiSTer core contains a PS/2-to-matrix converter you can bypass.
   The C64 port does exactly this: its `keyboard.vhd` emulates the C64 matrix
   directly against the CIA1 ports, replacing MiSTer's `fpga64_keyboard` entity
   entirely (rationale and matrix-scan details in C64MEGA65
   CORE/vhdl/keyboard.vhd:1-23). This needs a small modification of the core (the
   C64 port routes CIA1 ports A/B out of `fpga64_sid_iec`) but yields exact
   semantics, including multi-key combinations and row/column scanning tricks.
2. **Scan-code synthesis.** Keep the core's PS/2 input and generate PS/2 make/break
   codes from key-number edges. More code than it sounds (typematic, E0 prefixes,
   ordering) and only worth it when the core's keyboard handling is too entangled
   to bypass - e.g. when the keyboard protocol is itself part of the emulated
   machine. (Amiga port: the Minimig consumes raw Amiga keycodes through its MOS
   keyboard controller emulation, so the port translates key numbers to Amiga
   keycodes instead - the strategy generalizes to "speak the most native protocol
   the core offers".)

**TRAP:** the MEGA65 keyboard has fewer and different keys than most original
machines (no separate numeric keypad, different modifier layout). Decide the
mapping deliberately and document it for users; check how C64MEGA65 maps
MEGA65-specific keys before inventing your own conventions. Also note the M2M
reserved key: Help opens the OSM (the framework intercepts it via the
`enable_core_i` decoupling in m2m_keyb, so your core does not see keys while the
menu is open).

### 1.3.5 MiSTer video pipeline -> M2M av_pipeline

In MiSTer, `emu` sends video through `sys/`'s `video_mixer` (scandoubler, scanline
effects, gamma), `video_freak` (crop/scale tricks) and finally the ascal scaler in
`sys_top` for HDMI. In M2M, the entire chain after the raw retro signal is the
framework's `av_pipeline` (framework.vhd:864), and the contract is: **you deliver
the unprocessed retro video plus a pixel clock enable; everything downstream is
framework business.** From `main.vhd` you output (C64MEGA65 mega65.vhd:91-101):

```vhdl
video_clk_o    : out std_logic;   -- often the same as main_clk
video_ce_o     : out std_logic;   -- pixel clock enable relative to video_clk
video_ce_ovl_o : out std_logic;   -- CE for the OSM overlay (2x in 15 kHz mode)
video_red_o, video_green_o, video_blue_o : out std_logic_vector(7 downto 0);
video_vs_o, video_hs_o    : out std_logic;
video_hblank_o, video_vblank_o : out std_logic;
```

Compare with `emu`'s video outputs (1.1.2): M2M wants HBlank and VBlank
*separately* instead of MiSTer's combined `VGA_DE`, and it wants a CE instead of a
separate pixel clock. In practice you tap the MiSTer design at the point where the
analog signal is complete: the C64 port reuses MiSTer's own `video_sync` module
from rtl/ to derive blanks and crop the frame, then divides the main clock by 4
for the CE (C64MEGA65 main.vhd:1236-1264 - including the instructive warning at
main.vhd:1233-1235 that the *MiSTer rtl version* of video_sync must be used, not
the same-named M2M file; name collisions between vendored MiSTer helpers and your
core's files are a real hazard, see Part II).

Inside the framework, the analog (VGA/D-sub) branch actually reuses vendored
MiSTer components - `M2M/vhdl/controllers/MiSTer/` contains `video_mixer.sv`,
`scandoubler.v`, `hq2x.sv`, `gamma_corr.sv`, and `analog_pipeline.vhd` instantiates
`video_mixer` (analog_pipeline.vhd:134; `gamma_bus` is left open, so gamma
correction is present in source but not wired up in V2.0.1). The digital branch
scales via `ascal.vhd` (same Avalon scaler MiSTer uses) through HyperRAM into a
fixed HDMI mode. The Shell's standard OSM offers the user VGA standard/15 kHz
retro/CSYNC choices and the HDMI mode list from
`M2M/vhdl/av_pipeline/video_modes_pkg.vhd` (720p 50/60, 576p, 480p, ...; see the
`C_HDMI_*` constants there) - these arrive in `mega65.vhd` as `qnice_*` mode
signals which the template already wires (mega65.vhd:38-50). Aspect ratio
correctness on HDMI is handled by ascal with black pillarboxes; you do not
implement `VIDEO_ARX/ARY` logic.

**RULE:** M2M expects `CLK_VIDEO == clk_sys` semantics, i.e. your video timing
must be expressible as a CE against a single video clock that is phase-related to
your core clock. Cores where MiSTer uses a truly separate video PLL output need a
decision: derive the CE (preferred when frequencies are integer-related, like the
C64's /4) or run a real second clock domain into `video_clk_o` and CDC inside your
own code first.

### 1.3.6 Audio -> signed 16-bit PCM into the framework filters

You output `main_audio_left_o`/`main_audio_right_o` as `signed(15 downto 0)` in
the core clock domain (C64MEGA65 mega65.vhd:128-129); the framework CDCs them to
its 12.288 MHz audio domain and plays them out via the board DAC and HDMI. That is
the whole hardware contract. Match MiSTer's conditioning in two places:

* **Width/mixing glue**: replicate what `emu` does between the sound chips and
  `AUDIO_L/R`. The C64 port converts the SID's 18-bit output to 16 bits with an
  anti-overflow clamp (C64MEGA65 main.vhd:1326-1345) - copied conceptually from
  `c64.sv`. Check `AUDIO_S` in `emu`: if the MiSTer core outputs unsigned, you
  must convert, because M2M's path is signed-only (the framework instantiates
  MiSTer's own `audio_out.v` with `is_signed => '1'`,
  M2M/vhdl/av_pipeline/av_pipeline.vhd:312-343).
* **Filter coefficients**: MiSTer applies a per-core IIR low-pass configured in
  `sys_top.v`; M2M vendors the same filter and reads its coefficients
  (`audio_flt_rate`, `audio_cx*`, `audio_cy*`, `audio_att`, `audio_mix`) from your
  `globals.vhd` (C64MEGA65 globals.vhd:184-204). **Copy the values from the
  MiSTer core's `sys/sys_top.v` of the core you are porting** - the defaults in
  the template are C64 values, and wrong coefficients audibly change the sound
  character. The Shell's standard menu offers an "Improve audio" style toggle
  (`qnice_audio_filter_o`) that switches the filter in and out.

### 1.3.7 Quartus pll -> clk.vhd MMCM

MiSTer's `pll` (an Intel IP instantiation under `rtl/pll/`) becomes your handwritten
`CORE/vhdl/clk.vhd` using Xilinx `MMCME2_ADV` primitives. The C64 version
(C64MEGA65 CORE/vhdl/clk.vhd) is the reference for every technique you may need:
exact-frequency synthesis from the 100 MHz input (header math at clk.vhd:1-41),
cascaded MMCMs when one stage cannot hit the target frequency within VCO limits
(the file documents the 600-1200 MHz VCO constraint reasoning), and even two
parallel MMCMs with glitch-free BUFGMUX switching for the HDMI flicker-free
mechanism. Key differences from the Quartus world to internalize now (the full
conversion recipe is in Part II):

* You compute `CLKFBOUT_MULT_F` / `DIVCLK_DIVIDE` / `CLKOUT0_DIVIDE_F` yourself
  (or with Vivado's clocking wizard) to approximate the frequencies you extracted
  from `rtl/pll/pll_0002.v` in step 2 of the 1.1.5 drill.
* Dynamic reconfiguration a la `pll_cfg` (the C64's PAL/NTSC switch) has no
  drop-in equivalent; M2M ports typically pick one standard at synthesis time or
  instantiate alternatives. MMCM dynamic reconfiguration (DRP) exists but no M2M
  V2.0.1 port uses it for core clocks.
* Every clock you generate must be declared to Vivado in `CORE.xdc` (see 1.3.8).

### 1.3.8 sys.sdc / <core>.sdc -> M2M XDCs + CORE.xdc

MiSTer carries Quartus timing constraints (`sys/sys_top.sdc`, plus a core-specific
`.sdc` like `Minimig.sdc`). On the M2M side the framework ships board XDCs
(`M2M/MEGA65-R3.xdc` ... `MEGA65-R6.xdc` with the pin assignments, plus
`M2M/common.xdc`), and everything concerning *your* clocks and *your* CDCs goes
into `CORE/CORE.xdc`. Read the core's `.sdc` files once: they tell you which
clock relationships the original author considered asynchronous
(`set_clock_groups`/`set_false_path`) and which multicycle exceptions the design
needs - you will have to express the same intent in XDC syntax against the MMCM
output pins of your `clk.vhd`. Do not copy SDCs blindly: clock names, generated
clock derivation and the physical clock network are all different. Part II covers
the syntax translation; the takeaway here is architectural: **constraints are
split exactly like the code - framework constraints in M2M/, core constraints in
CORE/CORE.xdc - and the porter owns the latter.**

### 1.3.9 RTC -> main_rtc_i

If the MiSTer core consumes `RTC[64:0]` from hps_io (1.1.4), wire M2M's
`main_rtc_i : in std_logic_vector(64 downto 0)` (C64MEGA65 mega65.vhd:165) to the
same input - the framework's `rtc_wrapper` (framework.vhd:1012) reads the MEGA65's
battery-backed I2C RTC chip and delivers the same MSM6242B-style BCD layout
MiSTer uses, already synchronized into the core domain. The C64 port feeds it to
the core's `rtcF83` emulation for GEOS (mega65.vhd:585-586). There is no
`TIMESTAMP` (Unix time) equivalent in the V2.0.1 core-facing interface.

### 1.3.10 What is NOT replaced - know the holes before you fall in

Equally important is the list of MiSTer services with **no** M2M equivalent in
V2.0.1. Check your core's `hps_io`/`emu` usage against this list early, because
each hit is a feature you must drop, stub, or build yourself:

* **UART to the core.** The MEGA65's USB-UART belongs to QNICE
  (M2M/vhdl/top_mega65-r3.vhd:28-29 routes `uart_rxd/txd` straight into the
  framework, framework.vhd wires it to the QNICE wrapper for the Monitor/Shell
  debug console and logging). A CONF_STR `UART` feature (the C64's UP9600 modem
  modes) or MiSTer's MIDI/mt32-pi paths cannot be offered to the core without
  inventing your own hardware path. Treat core UART features as dropped.
* **Dynamic output resolutions / video_freak semantics.** MiSTer can change the
  scaler output geometry at runtime per core request (`video_freak` crop/integer
  scale, `VIDEO_ARX/ARY`, `HDMI_WIDTH/HEIGHT` feedback). M2M outputs a fixed,
  user-selected HDMI mode from `video_modes_pkg.vhd`; the core has no channel to
  request output-side geometry changes. Crop/zoom exists only as the framework's
  own OSM options (`qnice_zoom_crop_o`, mega65.vhd:44).
* **DDRAM-style framebuffer (`MISTER_FB`).** No equivalent; cores that render
  into a DDR framebuffer for the scaler need rearchitecting (HyperRAM via the
  arbiter is the raw material, but you build the logic).
* **Arcade screen rotation (`arcade_video`).** Arcade cores wire video through
  `sys/arcade_video.sv` (a wrapper around `video_mixer`); tap the raw
  RGB/sync/CE upstream of it like any other core. Its screen-rotation path for
  vertical games renders through the DDR framebuffer and has no M2M
  equivalent - treat rotation as a dropped feature or build it yourself.
* **ioctl upload (core -> file).** The CRTROM path is download-only. Saving state
  back to SD card exists only via the vdrives write path (mounted images) or
  custom QNICE devices plus your own firmware code.
* **PS/2 mouse stream.** No `ps2_mouse` equivalent; the MEGA65 has analog/1351
  style mouse hardware on its joystick ports, which the framework exposes as
  paddle/POT values - mapping that onto a MiSTer core's mouse input is
  core-specific work (the C64 port does this for the 1351).
* **gamma correction**: vendored but unwired (`gamma_bus => open`,
  M2M/vhdl/av_pipeline/analog_pipeline.vhd:141); scanline/CRT effects exist only
  insofar as the vendored `video_mixer`/ascal modes provide them.
* **ADC_BUS, SD-SPI direct access, SDRAM2, cheats, alternative cores via
  `BUTTONS`** - DE10-specific, no equivalent, tie off per the defaults you saw in
  `emu`.

None of these holes blocks a first successful port - they define its initial
scope. The C64MEGA65 port shipped for years while the UART/RS232 CONF_STR options
remained dropped.

## 1.4 Hardware budget realities

The DE10-Nano gives MiSTer cores a luxury the MEGA65 does not have: 32-128 MB of
fast SDRAM plus 1 GB DDR3. Every porting decision about memory flows from the
budget below; read this chapter before you promise anyone a feature list.

### 1.4.1 One FPGA across all boards

All MEGA65 revisions R3 through R6 use the **same FPGA: xc7a200tfbg484-2** (Xilinx
Artix-7 200T, speed grade -2; verify in any project file - both AExp
CORE/CORE-R3.xpr and C64MEGA65 CORE/CORE-R6.xpr specify `xc7a200tfbg484-2`). The
four Vivado projects per port exist because of *board* differences (pinout, DAC,
RTC), not fabric differences - your resource budget is identical on every MEGA65.
Headline resources of the 200T:

* 134,600 LUTs / 269,200 flip-flops
* 365 RAMB36 tiles (36 Kbit each) = 13,140 Kbit, i.e. about 1.6 MB of BRAM
* 740 DSP48E1 slices
* plus, on the board: 8 MB HyperRAM (expandable via the trapdoor slot)

### 1.4.2 BRAM and the 1.4 MB rule of thumb

BRAM is the only memory in the system that behaves like the SRAM/SDRAM a retro
core expects: single-digit-nanosecond, fixed 1-cycle latency, dual-ported,
dual-clock. Everything latency-critical must live there. But the framework eats
into the 1.6 MB first: QNICE program ROM and RAM plus the video pipeline
(OSM VRAM, ascal buffers) cost roughly 200 KB. Measured in the Amiga port's
synthesis: 32 tiles QNICE ROM+RAM plus ~11.5 tiles video pipeline = ~43.5 tiles
= ~196 KB (AExp doc/synthesis-handoff.md:110-111).

**RULE (the 1.4 MB rule):** if the sum of all "fast" RAM and "fast" ROM the
MiSTer core needs - SDRAM usage, in-fabric BRAMs, ROMs, hidden frame buffers and
FIFOs across the whole `rtl/` tree - is below ~1.4 MB, the port is
straightforward: map it all to BRAM via M2M's RAM components. Above that, you
must split into fast (BRAM) and slow (HyperRAM) parts, shrink the supported
memory configuration, or redesign.

When you do the census (Part II gives the procedure), count *everything*: the C64
port fits easily (64 KB main RAM + ROMs + drive RAM), the Amiga port fits *only*
in its minimal A500 configuration - 512 KB chip RAM + 512 KB slow RAM + 256 KB
Kickstart = 1.25 MB, which synthesizes to exactly 320 RAMB36 tiles with zero
waste (synthesis-handoff.md:110). A "small" addition like ECS 1 MB chip RAM or an
HDD sector buffer is not small in tiles.

### 1.4.3 HyperRAM: 8 MB, 100 MHz, Avalon, shared

The board's 8 MB HyperRAM is M2M's replacement for MiSTer's bulk memory, with
three caveats that must be in your head at architecture time:

* **Interface**: a 16-bit Avalon MM bus in the 100 MHz `hr_clk` domain
  (controller: M2M/vhdl/controllers/hyperram/hyperram.vhd, word-based addressing,
  burst-capable). Your core reaches it through dedicated `hr_core_*` ports on
  `MEGA65_Core` (C64MEGA65 mega65.vhd:75-83) and must CDC its own requests into
  the hr domain (the framework provides `avm_fifo` and the C64 REU shows the
  full pattern: CDC FIFO + `avm_cache` + width converters,
  C64MEGA65 main.vhd:1594 onward).
* **Latency**: the HyperRAM device plus controller costs on the order of 5 cycles
  per random read at 100 MHz, and the mandatory clock domain crossing adds
  roughly 4 more - budget **~9 cycles at 100 MHz (~90 ns) per random access**
  from the core's perspective. Rule of thumb: a retro CPU at ~11 MHz can hide
  this completely; anything faster, or any video DMA, needs caching, prefetch, or
  genuine wait-state tolerance in the emulated machine. Burst transfers are fast
  (HyperRAM is designed for ~200 MB/s in bursts), so DMA-style block moves work
  well; scattered single-word traffic does not.
* **It is shared.** M2M V2.0.1 ships a general arbiter (`avm_arbit_general`,
  framework.vhd:684) with three masters: the digital video pipeline (ascal uses
  HyperRAM as its scaler framebuffer), your core, and QNICE. The ascal
  framebuffer traffic is continuous and bursty (individual bursts can occupy the
  memory for over a hundred cycles), so your core's worst-case latency is far
  above the 9-cycle average. **RULE:** never put anything with a hard real-time
  deadline (chip RAM that video DMA fetches from, for instance) behind the
  HyperRAM arbiter without a FIFO/cache layer that absorbs arbitration jitter.
  (Note: older M2M wiki text states there is no arbiter and HyperRAM use is "on
  your own" - that is outdated; V2.0.1 has the arbiter and the C64 REU uses it
  in production.)

### 1.4.4 When BRAM saturates: the Amiga case study

What actually happens when you push the budget to the wall - measured data from
this repo's first synthesis runs (AExp doc/synthesis-handoff.md:97-130):

* The A500 configuration plus framework landed at **363.5 of 365 tiles**. Vivado
  initially *requested* 380 tiles and silently auto-demoted ~16.5 tiles worth of
  small memories to LUTRAM (warning `Synth 8-5835`) - among them the ascal line
  buffers (~4600 extra LUTs), Paula's floppy FIFO and the Denise color lookup
  tables. **TRAP:** auto-demotion is a warning, not an error; a port can "fit"
  while quietly burning thousands of LUTs and hurting timing. Always read the
  BRAM section of the utilization report and search the synth log for demotion
  warnings.
* Run 1 failed timing with WNS -6.7 ns; with near-total BRAM occupancy the
  placer has almost no freedom left, routes detour around congested columns, and
  hold fixes add further detours. After constraint fixes the same design closed
  at WNS +0.387 ns (synthesis-handoff.md:120-130) - i.e. it *works*, but the
  margin is a rounding error, and every future change must re-verify timing.
* Concrete consequence recorded in the handoff notes: re-enabling the Minimig's
  IDE/HDD support would cost +8 RAMB36 - **does not fit**; any future buffer
  (ADF track buffers, HDD sector buffers) must be architected into HyperRAM from
  the start (synthesis-handoff.md:112-113).

The meta-lesson generalizes beyond the Amiga: BRAM exhaustion does not announce
itself as "out of memory" - it shows up as LUTRAM inflation, congestion, and
timing failure. Plan the memory map *before* wiring (Part II), and keep a
two-digit tile reserve if you can.

### 1.4.5 LUTs, FFs, DSPs: plenty

134,600 LUTs comfortably hold any 8/16-bit-era machine plus the framework - the
fully populated Amiga port (68000, OCS chipset, QNICE, ascal, scandoubler) closed
with ample logic headroom even after the ~4600-LUT line-buffer demotion. DSP
slices (740) dwarf what retro audio/video needs. The practical constraints on
the MEGA65 are, in this order: **BRAM tiles, HyperRAM latency, timing closure at
high BRAM occupancy** - not logic. If your candidate core is logic-heavy
(3D-era arcade, big soft-CPUs at high clocks), reassess, but for the classic
home-computer and console catalog, logic is never the reason a port fails.

---

# Part II - The porting walkthrough, step by step

## 2.0 Phase 0 - Study the MiSTer core before touching anything

**Why:** Every hour spent in Phase 0 saves a day later. A MiSTer core is not a black box you "wrap"; it is a machine plus an ecosystem of HPS-provided services (file loading, OSD options, video scaling, drive emulation) that M2M replaces piece by piece. You cannot replace what you have not inventoried. The output of Phase 0 is a written dossier: feature list, CONF_STR dissection, clock table with exact Hz, memory map with byte counts, peripheral semantics, and a scoped milestone 1. Keep this dossier in your port repo (the Amiga port keeps it under `.research/`; any location works, but write it down - the porting effort spans months and an AI assistant in a fresh session needs it as much as you do).

**S1 - Run the core as a user and catalog every user-facing feature.**
Before reading a single line of RTL, use the core the way an end user does: on a real MiSTer if you own one, otherwise via YouTube reviews of the core, the core's GitHub README/releases page, and an emulator of the original machine to learn the machine itself. Open the MiSTer OSD (F12) and walk through every menu page, every option, every file-mount slot. Write each one down in a table: feature, what it does, do-I-need-it-for-milestone-1.

**RULE:** Every feature you can see in the MiSTer OSD comes back later as concrete porting work: a menu item in `config.vhd`, a status bit wired through `main.vhd`, a loader in the QNICE firmware, or an explicit decision to cut it. There are no free features. The catalog you write in S1 is the master checklist for the whole port.

Expected outcome: a feature table with a "milestone 1?" column, mostly "no".

**S2 - Read the MiSTer developer documentation chapters.**
Read these chapters of the MiSTer developer docs (MiSTer-devel documentation site, mister-devel.github.io/MkDocs_MiSTer, "Developer" section, plus the wiki of the MiSTer Template_MiSTer repo):

- "Porting Cores" - how a MiSTer core is structured around the `emu` module.
- "Core Config String" - the `CONF_STR` grammar (you will dissect your core's instance in S4).
- The `emu` module interface and `hps_io` - the ARM-side services contract.
- `video_mixer` and `video_freak` - the sys-side video post-processing you will NOT port (M2M has its own copies/equivalents, see S39 and Part III).
- "sys - arcade_video" (if porting an arcade core) - see 1.3.10 for the M2M consequences.

Just as important: the authoritative documentation is the source itself. Your core's `sys/` directory contains the same files with doc comments, e.g. `hps_io.sv` documents its parameters (`WIDE=1 for 16 bit file I/O`, `VDNUM 1..4`, `BLKSZ 0..7`) right above the module header (C64MEGA65 CORE/C64_MiSTerMEGA65/sys/hps_io.sv:23-30). When docs and source disagree, the source wins.

Expected outcome: you can explain, without looking it up, what `hps_io` does, what `ioctl_*` signals are, and why the `emu` module ports are the boundary you will re-implement.

**S3 - Locate and read the emu module (the core's top-level .sv).**
The core's repo root contains one `.sv` file named after the core (e.g. `c64.sv` for C64, `Minimig.sv` for the Amiga). This file IS the `emu` module: it instantiates the machine RTL from `rtl/`, the PLL, `hps_io`, `video_mixer`/`video_freak`, the SDRAM controller, and contains all the glue (reset logic, loader address decoding, status-bit fan-out). Read it top to bottom, twice. Annotate a printout or a copy. This single file answers 80% of all porting questions; for the C64 it is ~1500 lines.

Pay special attention to its port list: every `emu` port group (`CLK_50M`, `VGA_*`, `AUDIO_*`, `SDRAM_*`, `DDRAM_*`, `UART_*`, `USER_*`, `ioctl_*` via hps_io) is a contract with the MiSTer platform that M2M must satisfy differently. Note which groups are actually used and which are tied off - e.g. the C64 core ties off the entire DDR3 interface with `assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;` (C64MEGA65 CORE/C64_MiSTerMEGA65/c64.sv:180) - a tied-off port group is porting work you do NOT have.

**S4 - Dissect CONF_STR line by line.**
`CONF_STR` is a `localparam` string near the top of the emu file (C64MEGA65 CORE/C64_MiSTerMEGA65/c64.sv:197-270). It is the machine-readable definition of the core's entire user interface, and it is passed as a parameter into `hps_io` (c64.sv:422: `hps_io #(.CONF_STR(CONF_STR), .VDNUM(2), .BLKSZ(1)) hps_io`). Make a table with one row per CONF_STR line and four columns: raw line, meaning, status bits used, porting consequence. The grammar essentials (full grammar in the "Core Config String" doc from S2):

- `S<n>,<exts>,<label>;` = a mountable block device (disk drive). C64: `"H7S0,D64G64T64D81,Mount #8;"` (c64.sv:199) = virtual drive 0, accepting D64/G64/T64/D81 images. Each `S` entry becomes one M2M virtual drive (`C_VDNUM` in `globals.vhd`, see Part III) plus a QNICE-firmware mount menu entry.
- `F<n>,<exts>,<label>;` = a file loader streamed via `ioctl`. C64: `"F1,PRGCRTREUTAP;"` (c64.sv:202) and ROM loaders like `"P2FC8,ROM,System ROM C64+C1541 ;"` (c64.sv:252). Each becomes an M2M "CRT/ROM loader" or a custom QNICE loader you must write.
- `O<bit(s)>,<label>,<choices>;` / `o<bits>` (second status word) = an option mapped to bits of the 64-bit `status` vector. C64: `"P1O2,Video Standard,PAL,NTSC;"` (c64.sv:210) = status bit 2. Each becomes an OSM menu item in `config.vhd` plus a wire from `main.vhd` into the core.
- `P<n>,<label>;` = submenu page; `H<n>`/`h<n>`/`D<n>`/`d<n>` prefixes = hide/disable masks driven by `status_menumask` (c64.sv:438); `R<bit>`/`r<bit>` = momentary reset-style triggers (C64: `"R0,Reset;"`, c64.sv:264); `J,...`/`jn,...` = joystick button mapping; `V,v` = version string.

**TRAP:** Do not skip the conditional-prefix lines (`H`/`D` masks). They encode real hardware dependencies (e.g. "this menu only when a tape is loaded", c64.sv:438 builds the mask from `tap_loaded`, `vcrop`, status bits). If you ignore them you will later wonder why two options conflict.

Expected outcome: the complete CONF_STR table. Count the `S` entries (= virtual drives), the `F` entries (= loaders), and the status bits actually consumed (grep the emu file and rtl/ for `status[`).

**S5 - Map file extensions to the loaders you must replace.**
For every extension found in S4, answer: what does the MiSTer/HPS side do with this file, and what must M2M do instead?

- Disk images mounted on `S` entries are served on demand, block by block, by the ARM side. In M2M the QNICE firmware + the framework's virtual-drive machinery (`vdrives.vhd`, SD card via `sysdef.asm` config) take this over (see Part III and Part IV).
- `F`-loaded files (cartridges, ROMs, tapes) are streamed once into the core over the `ioctl` bus (`ioctl_download`, `ioctl_addr`, `ioctl_dout`, `ioctl_index`). In M2M this is replaced either by the framework's CRT/ROM-loading mechanism or by BRAM initialization at synthesis time.
- Mandatory ROMs deserve special attention: if the machine cannot boot without a ROM (C64 Kernal/Basic/Char, Amiga Kickstart), decide now whether it will be baked into the bitstream (BRAM init file) or loaded from SD card at startup. The C64 port bakes the ROMs in; the Amiga port must load Kickstart from SD card because shipping it would violate copyright (Amiga port) - this decision shapes the whole memory and firmware architecture (see S86 and Part III, 3.I.2).

**S6 - Map status bits to future OSM options.**
From the S4 table, produce the definitive status-bit map: bit index -> meaning -> default value -> milestone. You need this twice later: once when you write `config.vhd` menu items, and once when you hard-wire the de-featured bits in `main.vhd` (a cut feature is not "unwired", it is wired to its safe default). Grep the rtl for each bit to see where it lands: `grep -rn "status\[" rtl/ *.sv`. Record the defaults the MiSTer core assumes when status is all zeros - that is the configuration the machine model itself was tested with.

**S7 - Inventory the clocks: find the PLL and record EXACT frequencies in Hz.**
In the emu file, find the `pll` instantiation. C64: c64.sv:278-287 instantiates `pll` with `refclk(CLK_50M)` and three outputs `clk48`, `clk64`, `clk_sys`. The instantiation does not tell you the frequencies - the generated Quartus IP does. Open `rtl/pll/pll_0002.v` (sometimes `pll/pll_0002.v`) and read the `output_clock_frequency*` parameters. C64 (C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/pll/pll_0002.v:31-42): `reference_clock_frequency("50.0 MHz")`, `output_clock_frequency0("47.291931 MHz")` (clk48), `output_clock_frequency1("63.055908 MHz")` (clk64), `output_clock_frequency2("31.527954 MHz")` (clk_sys). Amiga Minimig for comparison: `113.500640 MHz` and `28.375160 MHz` (Amiga port, CORE/Minimig_MiSTerMEGA65/rtl/pll/pll_0002.v:33,36).

Build a clock table: name in emu -> exact Hz -> what runs on it -> M2M plan. Note that MiSTer's reference clock is 50 MHz while the MEGA65 board clock entering your `clk.vhd` is 100 MHz - all multiplier/divider math must be redone for Xilinx MMCMs anyway, so what you carry over is the TARGET frequency, not the Quartus parameters.

**Why exactness matters:** these are not "about 32 MHz" clocks. The C64 port pins `CORE_CLK_SPEED_PAL : natural := 31_527_778;` with the comment "Will lead to a C64 clock of 985,243 Hz" (C64MEGA65 CORE/vhdl/globals.vhd:47), and the clock generator documents the consequence chain down to the frame rate: "This has a frame rate of 31527777/(312*63*32) = 50.124 Hz" (C64MEGA65 CORE/vhdl/clk.vhd:90). Everything in a retro machine - CPU phase clocks, CIA timers and time-of-day chains, video line/frame timing, audio pitch - is an integer division of this one number. A "close enough" master clock detunes music, breaks copy-protection timing loops and shifts HDMI frame rates out of display tolerance. Record the exact Hz and re-derive your MMCM settings to hit it as closely as the fractional dividers allow; the Amiga port's `clk.vhd` documents this style of derivation including the residual error ("28.375000 MHz, ideal: 28.3751600 MHz, -5.6 ppm", Amiga port, CORE/vhdl/clk.vhd:53).

**S8 - Check for dynamic PLL reconfiguration - you will NOT port it.**
Search the emu file for `reconfig_to_pll`, `pll_cfg`, `cfg_write`. Many cores reprogram the Altera PLL at runtime to switch video standards: the C64 core instantiates `pll_cfg` (c64.sv:296-308) and runs a small state machine that writes magic M-counter values into the PLL whenever the PAL/NTSC status bit flips (`cfg_data <= ntsc_r ? 3357876127 : 1503512573;`, c64.sv:341). This is Altera-IP-specific and has no direct Xilinx equivalent that is worth the trouble (the MMCM DRP interface exists but is a project of its own).

**RULE:** Replace dynamic PLL reconfiguration with one fixed MMCM output per video standard you support - in milestone 1 that is exactly one (see S13). If you later support both standards, generate both clocks and multiplex glitch-free (BUFGMUX), or re-synthesize per standard. Where MiSTer derives sub-clocks (e.g. a 2x or 4x clock plus the system clock), prefer one fast MMCM clock plus accumulator/strobe clock-enables over multiple related MMCM outputs - fewer clock domains means fewer CDCs and easier timing closure (the M2M template and the C64/Amiga ports follow this pattern; details in Part III's clock chapter).

Expected outcome: your clock table now has an "M2M realization" column: which MMCM, which output, which clock-enables, and a note "pll_cfg: dropped, fixed PAL clock only".

**S9 - Inventory external memory: SDRAM_* and DDRAM_* usage in emu.**
MiSTer boards have an optional SDRAM module (`SDRAM_*` ports) and the DE10-Nano's DDR3 via the HPS (`DDRAM_*` ports). Grep the emu file for both. Three outcomes per bus: unused/tied off (free lunch - c64.sv:180 ties off DDRAM as quoted in S3), used for the machine's main memory (your biggest porting decision), or used by sys-side helpers only (e.g. `ascal` scaler in DDR - irrelevant, M2M has its own scaler in HyperRAM). For every used bus, find the controller (`sdram.v` or similar in rtl/) and write down: address width, data width, which machine subsystem talks to it, and the access pattern (random single-beat? page bursts? fixed slot schedule?). The access pattern decides whether MEGA65 HyperRAM (5-cycle read latency at 100 MHz, ~9 cycles after CDC) can substitute, or whether the memory must live in BRAM.

**S10 - Crawl rtl/ for every internal RAM and ROM.**
Every `altsyncram`/`altdpram` instance, every inferred `reg [..] mem [..]` array, every `dprom`/`spram`/`dpram` wrapper. For each, record: size in bytes, port widths (both ports - mixed-width ports are a Vivado problem, see Part III), single- or dual-clock, and the init file if any (`.mif`/`.hex`). Useful sweep commands from the repo root of the MiSTer fork:

```bash
grep -rn "altsyncram\|altdpram" rtl/ | grep -v "^Binary"
grep -rn "\.mif\|\$readmemh\|\$readmemb" rtl/
grep -rln "module.*[sd]p\(ram\|rom\)" rtl/
```

**TRAP:** Quartus `.mif` ROM init files do not work in Vivado, and neither does Intel-HEX without conversion - the C64 port has dedicated history commits "Convert C1541 and C1581 roms from Intel format" and "Port ROM initialization to Vivado" (C64_MiSTerMEGA65 submodule, develop branch, commits a8853be and the surrounding series). Budget conversion work for every init file you find. Details of the conversion and of M2M's `dualport_2clk_ram` drop-in replacement are in Part III.

**S11 - Total the "fast" RAM+ROM against the 1.4 MB BRAM rule; plan BRAM vs HyperRAM.**
Sum everything from S9+S10 that the machine needs at full speed. The MEGA65 (R3 and newer, Artix-7 XC7A200T) has about 1.6 MB of BRAM, and the M2M framework itself consumes about 200 KB of it (QNICE ROM/RAM, OSM video RAM, buffers) - both numbers from the M2M wiki chapter "4. Understand the MiSTer core" (MiSTer2MEGA65.wiki/4.-Understand-the-MiSTer-core.md:535,569).

**RULE:** "If the sum of 'fast' RAM and 'fast' ROM that the MiSTer core you want to port needs is below 1.4 MB, then it is straightforward to port" (MiSTer2MEGA65.wiki/4.-Understand-the-MiSTer-core.md:572-574). Above 1.4 MB you need one of: (a) the original machine had slow RAM with wait states that tolerate HyperRAM latency, (b) a fast/slow split between BRAM and HyperRAM, or (c) a smaller machine configuration (same wiki chapter, lines 583-600 - which explicitly names the Amiga: support OCS instead of ECS/AGA so it fits BRAM).

Worked example (Amiga port): A500 OCS = 512 KB Chip RAM + 512 KB Slow RAM + 256 KB Kickstart ROM = 1280 KB for the machine, plus ~200 KB M2M = roughly 90% of total BRAM. That fits - barely - and it is the reason milestone 1 is "A500 OCS only" and not "A1200". Note: the wiki chapter still claims there is no HyperRAM arbiter and that core use is "on your own" (MiSTer2MEGA65.wiki/4.-Understand-the-MiSTer-core.md:556-561) - that is outdated: M2M V2.0.1 ships avm_arbit_general and exposes an hr_core_* Avalon master to your core (see 1.4.3 and S77/S78). Still plan latency-tolerant: the scaler shares the bus, so anything with hard real-time deadlines belongs in BRAM.

Expected outcome: a memory map table with a BRAM/HyperRAM/cut decision per memory, plus the grand total vs 1.4 MB.

**S12 - Inventory the peripherals and their exact semantics.**
For each peripheral, determine WHAT representation the core expects, because M2M gives you raw MEGA65 hardware and you must produce exactly that representation:

- Keyboard: does the core consume a PS/2 scancode stream (`ps2_key` from hps_io), a custom key matrix, or something else? M2M scans the MEGA65 keyboard as key numbers 0..79 at 1 kHz with debounced pressed/released state. The C64 port's answer is instructive: instead of synthesizing fake PS/2 traffic into the core's `fpga64_keyboard`, it bypasses that entity entirely and emulates the C64 keyboard matrix at the CIA1 ports, "instead of going the detour of converting the MEGA65 keystrokes into PS/2 keystrokes first" (C64MEGA65 CORE/vhdl/keyboard.vhd:7-14). Find your core's equivalent boundary now; it determines how much of the MiSTer keyboard path you keep.
- Mouse: MiSTer delivers PS/2-style mouse packets via hps_io. Does your machine need a mouse for milestone 1 (Amiga: yes, Workbench is mouse-driven; C64: only for paddles/1351)? If yes, plan the M2M-side source (MEGA65 mouse port) and the conversion.
- Joysticks: usually trivial (digital directions + buttons), but note swap options and multi-button mappings from CONF_STR (`J,...` lines).
- UART/RS232, parallel port, expansion port: list them, then almost certainly de-feature them for milestone 1 (S14).

**S13 - DECIDE THE SCOPE: pick the simplest viable machine configuration as milestone 1.**
This is the single most important Phase 0 decision. Choose the minimal configuration of the machine that (a) real software ran on, (b) fits the memory budget from S11, and (c) needs the fewest peripherals from S12. Precedents: the C64 port went PAL-only first (NTSC came later; globals.vhd:48 still carries the note that the NTSC value is unadjusted: "This is MiSTer's value; we will need to adjust it to ours", C64MEGA65 CORE/vhdl/globals.vhd:48). The Amiga port chose "A500 OCS, PAL, 512K Chip + 512K Slow, Kickstart 1.3" - not ECS, not AGA, no fast RAM, no RTG (Amiga port, see `.research/PORTING-PLAN.md`). One video standard also means one master clock and one fixed MMCM (S8), which simplifies everything downstream.

**S14 - Write the de-feature list: subsystems to tie off or disable first.**
Go back through S1/S4/S6/S12 and mark everything that is not needed for milestone 1. For each item write down HOW it will be neutralized: status bit hard-wired to default, module instantiation commented out, input tied to idle level. The C64 port did exactly this to reach its first bitstream: the C1581 drive and G64 (raw GCR) handling were disabled by commenting out - the submodule history has commits "disabled C1581 (temporarily)" (a2c35c4), "disabled core for G64 handling (temporarily)" (da8fe85) and, tellingly, "fixed bugs due to disabling C1581" (854e504); the disabling itself is visible in the code as `assign led = /*c1581_led |*/ c1541_led;` (C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/iec_drive.sv:66).

**TRAP:** "fixed bugs due to disabling C1581" is the lesson: tying off a subsystem is itself a change that can break the remaining logic (floating inputs, AND/OR reduction trees missing a term, bus contention). Disable at clean module boundaries, tie every input of the disabled module's clients to its documented idle level, and keep each disable in its own commit so you can bisect.

**S15 - Define milestone 1 as a visible-success criterion.**
Write one sentence that an outside observer can verify on a screen. C64: "the PAL C64 boots to the blue BASIC `READY.` screen on HDMI and VGA, keyboard works". Amiga port: "the Kickstart 1.3 insert-disk hand screen appears" - chosen precisely because it exercises CPU + Chip RAM + Kickstart ROM + Agnus/Denise video without needing any disk, mouse or OSD work yet. Everything in Phases 1-5 is ordered to reach this criterion as early as possible; resist any temptation to widen it. Also fix the order of later milestones now (e.g. milestone 2 = floppy mount + Workbench boot), so de-featured items from S14 have a designated place to come back.

## 2.1 Phase 1 - Project setup from the template

Phase 1 ends with a proof, not with a pile of files: the UNMODIFIED M2M template (its built-in demo core) synthesized by you, on your machine, running on your MEGA65. Only then do you know that your toolchain, your Vivado, your board and your flashing workflow all work - so that when Phase 3 fails, you know it is your port and not your setup.

**S16 - Create your port repo from the M2M template (NOT a fork).**
Go to https://github.com/sy2002/MiSTer2MEGA65 and press the green "Use this template" button (MiSTer2MEGA65.wiki/2.-First-Steps.md:65). Name the repo after your port (convention: `<Machine>MEGA65`, e.g. `C64MEGA65`).

**Why not a fork:** a fork is for contributing back; a template instantiation gives you an independent repo with its own issues/releases, which is what a core port is. You still want framework updates - that is what the `upstream` remote in S17 is for. (Working offline/locally? `git clone https://github.com/sy2002/MiSTer2MEGA65.git <MyPort> && cd <MyPort> && rm -rf .git && git init` is the local equivalent; you lose nothing because the template history is not yours anyway.)

**TRAP:** This guide and the Amiga port target M2M V2.0.1. The template on GitHub moves; check `VERSIONS.md` in your fresh clone and note the version in your port docs. Where this guide says "V2.0.1 does X", verify against your actual checkout if you started from a newer template.

**S17 - Clone, init submodules, add the upstream remote.**

```bash
git clone https://github.com/<you>/<MyPort>.git
cd <MyPort>
git submodule update --init --recursive
git remote add upstream https://github.com/sy2002/MiSTer2MEGA65.git
```

(Commands per MiSTer2MEGA65.wiki/2.-First-Steps.md:84-85.) The recursive submodule init pulls in QNICE (`M2M/QNICE`), the 16-bit SoC that runs the M2M firmware ("Shell"). The `upstream` remote lets you later `git fetch upstream` and merge framework releases into your port.

Expected outcome: `M2M/QNICE/` is populated (not an empty directory). An empty `M2M/QNICE` is the classic symptom of a missing `--recursive`.

**S17b - Clone the reference port next to yours.** `git clone --recurse-submodules https://github.com/MJoergen/C64MEGA65` - this guide treats it as required reference material: Phase 7 has you work with the C64 files open in a second window, and S62/S79 copy framework-ABI tables from it. (The full 80-key `m65_*` constant table that S62 references also ships in the M2M template's own CORE/vhdl/keyboard.vhd:45 onward, so a fresh template port already carries it.)

**S18 - Build the QNICE toolchain.**

```bash
cd M2M/QNICE/tools
./make-toolchain.sh
```

Answer every interactive question by pressing Enter. This builds the QNICE assembler, emulator and the Monitor (QNICE's "operating system"). Requires a native GNU toolchain (`gcc`, `make`, `bash`) - Linux, macOS, or Windows via WSL.

Expected outcome: `M2M/QNICE/monitor/monitor.rom` exists (verification command per MiSTer2MEGA65.wiki/2.-First-Steps.md:109: `ls -l ../monitor/monitor.rom`), and `M2M/QNICE/assembler/qasm` exists - the firmware build script in S19 checks for exactly that file and prints a helpful recovery message if it is missing (Amiga port, CORE/m2m-rom/make_rom.sh:7-21; same file in every template instantiation).

**S19 - Build the M2M firmware ROM.**

```bash
cd CORE/m2m-rom
./make_rom.sh
```

Expected outcome: `CORE/m2m-rom/m2m-rom.rom` (the 16-bit QNICE ROM image that gets baked into the bitstream), plus regenerated `globals.asm`, `shell_fhandles.asm`, `shell_fh_ptrs.asm`.

**S20 - Understand what make_rom.sh scrapes from globals.vhd - and keep those constants single-line.**
`make_rom.sh` is not just an assembler call. It generates QNICE assembly constants from your VHDL so that firmware and hardware agree on the number of virtual drives and ROM loaders: it runs `awk '/constant C_VDNUM/ ...' ../vhdl/globals.vhd` and the same for `C_CRTROMS_MAN_NUM` and `C_CRTROMS_AUTO_NUM` (Amiga port, CORE/m2m-rom/make_rom.sh:35-37), then generates one FAT32 file-handle block per drive/ROM slot (make_rom.sh:50-64).

**RULE:** The declarations of `C_VDNUM`, `C_CRTROMS_MAN_NUM` and `C_CRTROMS_AUTO_NUM` in `CORE/vhdl/globals.vhd` must each stay on a single line of the form `constant C_VDNUM : natural := 1;`. The awk patterns match line-wise; a line break after `:=`, a renamed constant, or a computed expression silently produces wrong or empty `.EQU` values in `globals.asm`, and the firmware will index past its file-handle table at runtime. When you change these constants, rerun `make_rom.sh` AND re-synthesize - both sides must move together.

**S21 - TRAP: the Vivado pre-synthesis hook can fail SILENTLY - always prebuild the ROM on the host.**
The Vivado projects register `CORE/m2m-rom/synth_pre.tcl` as a TCL.PRE hook on synth_design (Amiga port, CORE/CORE-R3.xpr:1082: `PreStepTclHook="$PPRDIR/m2m-rom/synth_pre.tcl"`); the hook just `cd`s into `CORE/m2m-rom` and runs `./make_rom.sh` (CORE/m2m-rom/synth_pre.tcl:4-5). The idea: every synthesis rebuilds the firmware automatically.

**TRAP:** On macOS hosts, VMs and other setups where Vivado's Tcl `exec` environment differs from your shell (PATH, permissions, line endings, a Windows Vivado looking at a Unix shell script), this hook can fail WITHOUT failing the build - synthesis proceeds with a stale `m2m-rom.rom` and you debug "impossible" firmware behavior in hardware. The Amiga port runs Vivado in a Parallels VM and therefore prebuilds as a rule: "The QNICE firmware is prebuilt because the Vivado pre-synth hook (synth_pre.tcl) can FAIL SILENTLY on Mac/VM setups" (Amiga port, doc/synthesis-handoff.md:10-14). Protocol: run `make_rom.sh` manually on the host before every synthesis that follows a firmware or globals.vhd change, and verify `CORE/m2m-rom/m2m-rom.rom` has a NEWER timestamp than `m2m-rom.asm` and `CORE/vhdl/globals.vhd` before you press "Generate Bitstream". A second benefit: assembling manually gives readable error messages (e.g. unresolved labels), while errors inside the hook are buried in the synthesis log if they surface at all.

**S22 - Install Vivado and know your part.**
Vivado 2022.2 or newer, the free WebPACK/Standard edition suffices; choose "Full Product Installation" with Artix-7 support. The M2M V2.0.1 projects were created with Vivado v2022.2 and target part `xc7a200tfbg484-2` (Amiga port, CORE/CORE-R3.xpr:2,10) - the Artix-7 200T on all supported MEGA65 revisions. Newer Vivado versions open the projects after an automatic upgrade; record which version you standardize on, because synthesis results (and timing closure) are version-dependent and you want reproducible comparisons during the port.

**S23 - Know the four board projects: CORE-R3/R4/R5/R6.xpr.**
The `CORE/` folder ships four Vivado projects, one per MEGA65 board revision: `CORE-R3.xpr` (DevKit and first retail batch), `CORE-R4.xpr`, `CORE-R5.xpr`, `CORE-R6.xpr` (current retail). They share ALL core sources and differ only in the board HAL. In M2M V2.0.1 the board top files and board constraints live in framework space and the projects reference them relative to the project dir:

- board top: `M2M/vhdl/top_mega65-r3.vhd` ... `top_mega65-r6.vhd` (top modules `mega65_r3` ... `mega65_r6`)
- board constraints: `M2M/MEGA65-R3.xdc` ... `M2M/MEGA65-R6.xdc`, plus the shared `M2M/common.xdc` and your port's `CORE/CORE.xdc`

**TRAP (wiki correction):** the old wiki chapter "2. First Steps" documents the top file as `CORE/vhdl/top_mega65-r3.vhd`, i.e. in user space. Since the multi-board refactoring (in effect in V2.0.1), the tops are framework files under `M2M/vhdl/` - do not create or edit a top in `CORE/vhdl/`.

The audio HAL is the one genuine source-list difference between the boards: R3 drives the audio DAC through `M2M/vhdl/controllers/M65/pcm_to_pdm.vhdl` and talks to the MAX10 system controller via `M2M/vhdl/controllers/M65/max10.vhdl`; R4/R5/R6 have no MAX10 and drive a real audio DAC (AK4432VT) via `M2M/vhdl/controllers/M65/audio.vhd` instead (per that file's header, M2M/vhdl/controllers/M65/audio.vhd:4-6). Verify it yourself in any M2M project pair, e.g. the Amiga port: CORE-R3.xpr lists `pcm_to_pdm.vhdl` + `max10.vhdl` + `top_mega65-r3.vhd` + `MEGA65-R3.xdc`, while CORE-R4.xpr lists `audio.vhd` + `top_mega65-r4.vhd` + `MEGA65-R4.xdc`; everything else is identical (extract with `grep -o 'File Path="[^"]*"' CORE-R3.xpr`).

**S24 - RULE: keep all four project file lists in sync forever.**
Every source file you add, remove or rename during the port must be applied to ALL FOUR `.xpr` files in the same commit, with exactly three expected deltas between them: the board top, the board XDC, and the R3-vs-R4+ audio/MAX10 pair from S23. Anything else that differs between the four lists is a bug waiting for the first user with a different board revision. Practical technique: treat one project (your own board) as the master, and after each file-list change run a diff of the extracted file lists:

```bash
for f in CORE-R3 CORE-R4 CORE-R5 CORE-R6; do
  grep -o 'File Path="[^"]*"' CORE/$f.xpr | sort > /tmp/$f.lst
done
diff /tmp/CORE-R4.lst /tmp/CORE-R5.lst   # must show ONLY top/xdc lines
```

The Amiga port learned this the hard way: its review phase produced a dedicated fix commit "Review fixes: R4/R5/R6 project sync, ..." (Amiga port, git history) because development had only touched CORE-R3.xpr. You can edit the `.xpr` files as XML in a text editor (they diff cleanly), or maintain them via Vivado's GUI four times - the text editor is less error-prone for bulk file additions, but see Part III for `.xpr`-editing traps (file-type tokens).

**S25 - Synthesize the UNMODIFIED template (the demo core).**
Before changing one line: open Vivado FROM INSIDE the `CORE/` directory (so generated run folders land next to the project where `.gitignore` expects them), open the `.xpr` matching your board, and "Generate Bitstream". The template's `CORE/vhdl/main.vhd` instantiates M2M's built-in demo core (a pong-like game, sources in `M2M/vhdl/democore/`), so the project is complete and synthesizable as shipped. Expected outcome: `CORE/CORE-R<x>.runs/impl_1/mega65_r<x>.bit` with zero timing violations. Budget roughly 20-60 minutes per run depending on your machine.

Optional but recommended habit from day one: "Open Elaborated Design" before synthesizing - it catches port-mismatch and missing-file errors in minutes instead of an hour (Amiga port practice, doc/synthesis-handoff.md:26-27).

**S26 - Run the demo core on real hardware via JTAG.**
The fast path needs a JTAG adapter (Trenz TE0790-03 "XMOD"): either use Vivado's Hardware Manager, or - much better for the edit-synthesize-test loop - the `m65` tool from the mega65-tools repo:

```bash
m65 -q CORE-R3.runs/impl_1/mega65_r3.bit
```

`-q` is the correct option for non-MEGA65-OS ("alternative") cores (MiSTer2MEGA65.wiki/2.-First-Steps.md:191). Keep a `CORE/load_bitstream.sh` one-liner for this; the C64 reference repo carries the same convenience pattern (C64MEGA65 CORE/load_bitstream.sh). The wiki's verdict stands: JTAG makes the workflow "100x faster" than flashing - treat the adapter as a required tool for a serious port. Prebuilt binaries: github.com/MEGA65/mega65-tools/releases/tag/CI-latest; on macOS you must clear the Gatekeeper quarantine on the unsigned `m65`/`bit2core` binaries once before they run.

**S27 - Alternative without JTAG: bit2core and the No Scroll menu.**
Convert the bitstream to a `.cor` core file and flash it via the MEGA65's built-in core menu (hold "No Scroll" at power-on):

```bash
bit2core mega65r3 CORE-R3.runs/impl_1/mega65_r3.bit "MyPort" "V0.1" myport.cor
```

(Tool from mega65-tools; usage per MiSTer2MEGA65.wiki/2.-First-Steps.md:211-221; pass the board revision matching your `.xpr`.) Flash into a free core slot, never slot 0. This path works but turns every iteration into minutes of flashing - acceptable for occasional testing on a second board revision, not for development.

**S28 - Acceptance test for Phase 1.**
Expected outcome on the connected display: the M2M demo core boots, video and audio work, Help (the OSM key) opens the on-screen menu, the keyboard controls the demo. Note: the template boots into a welcome screen first (`WELCOME_ACTIVE := true` in the template config.vhd:210) - press Space to dismiss it and reach the demo game. If this works, your ENTIRE chain - submodules, QNICE toolchain, firmware build, Vivado, constraints, bitstream transfer, board - is proven good. Do not proceed to Phase 2 before this passes; every later "nothing on screen" debugging session starts with the question "did the demo core work?", and you want that answered once, now.

**S29 - Make the repo yours: AUTHORS, README, LICENSE notes.**
The template ships placeholder metadata - `AUTHORS` literally starts with "YOUR PROJECT NAME for MEGA65 aka GITHUB REPO SHORT NAME ... done in YEAR by YOUR NAME" (Amiga port, AUTHORS:1-4, still in template state at the time of writing). Fill in: yourself, the M2M authors (sy2002, MJoergen), and the upstream MiSTer core authors you are about to fork in Phase 2 (check the MiSTer repo's README/copyright headers - typically the original MiST author plus MiSTer maintainers). M2M is GPL v3; your port must remain GPL v3 (`LICENSE` is already correct), and parts under other free licenses must be credited as such in the source. Update `README.md` with the port's name, status and milestone 1 definition from S15.

**S30 - Commit the baseline.**
Commit the verified-working template state (including the four untouched `.xpr` files and your metadata edits) and tag it (e.g. `template-baseline`). Every future regression hunt ("did this ever work?") bisects against this commit. From here on, the repo history IS your porting log - the C64 and Amiga ports both demonstrate the value of small single-purpose commits whose messages document each fix; this guide cites several of them as evidence in later parts.

## 2.2 Phase 2 - Fork the MiSTer core and curate the file list

Phase 2 establishes the second repository of the port: your fork of the MiSTer core, wired into the M2M project as a submodule. The governing philosophy, straight from the M2M wiki and proven by both reference ports: avoid touching the original, document every touch you cannot avoid, and delete nothing - selection happens in the Vivado project file list, not in the file system.

**S31 - Fork <Core>_MiSTer to your own <Core>_MiSTerMEGA65.**
On GitHub, fork the upstream core repo (e.g. `MiSTer-devel/C64_MiSTer`) into your account and rename the fork `<Core>_MiSTerMEGA65` (the C64 port's fork is `MJoergen/C64_MiSTerMEGA65`, see C64MEGA65 .gitmodules). This time it IS a fork, not a template: you want to pull upstream fixes for the lifetime of the port, and you want GitHub to show the fork relationship so users can find the original. The rename signals unmistakably that this tree contains MEGA65-specific changes and must never be confused with upstream.

**S32 - Branch model: master mirrors upstream, develop carries ALL your changes.**
Leave `master` exactly as upstream's master and never commit to it - it is your clean reference and the merge base for updates. Create a `develop` branch; every Xilinx fix, every MEGA65 adaptation, every de-feature from S14 goes there. The C64 fork's develop history shows the full lifecycle this enables:

- upstream updates arrive as merges, either of upstream's branch ("Merge branch 'master' of https://github.com/MiSTer-devel/C64_MiSTer", commits abfd88c, b057c72) or of a specific upstream SHA ("Merge commit 'cd2ff15788fb2051a967ad54e782c683a616bd38' into develop", 4a54016);
- single upstream fixes that you want before the next full merge arrive as cherry-picks with the upstream author credited in the message: "CIA: Disk parport: ignore inputs on pins configured as output (sorgelig)" (93712ad);
- your own porting work is many small single-purpose commits ("disabled C1581 (temporarily)", "Convert C1541 and C1581 roms from Intel format.") - this granularity is what makes the porting diff readable years later, and it is what made it possible to reconstruct the Quartus-to-Vivado playbook in Part III from the C64 history.

**S33 - Add the fork as a git submodule under CORE/, pinned to develop.**

```bash
cd <MyPort>
git submodule add -b develop https://github.com/<you>/<Core>_MiSTerMEGA65.git CORE/<Core>_MiSTerMEGA65
git submodule update --init --recursive
```

Then verify `.gitmodules` carries the branch pin. C64 reference (C64MEGA65 .gitmodules):

```ini
[submodule "C64_MiSTerMEGA65"]
    path = CORE/C64_MiSTerMEGA65
    url = https://github.com/MJoergen/C64_MiSTerMEGA65
    branch = develop
```

The Amiga port does the same (`branch = develop` for `CORE/Minimig_MiSTerMEGA65` in the AExp .gitmodules). The port repo records a specific submodule SHA per commit, as git submodules always do - the `branch` line documents intent and serves `git submodule update --remote`. Bump the recorded SHA deliberately, in its own commit, whenever the fork's develop advances ("Update submodule" commits in both reference ports).

**TRAP:** the parent repo build breaks silently for everyone else if you push fork commits but forget to push the parent commit that bumps the submodule SHA - or vice versa. After any change in the fork: commit+push in the submodule FIRST, then commit the SHA bump in the port repo.

**S34 - Provenance discipline: every modification to an original MiSTer file is marked, dated, and reversible.**
M2M ships the convention as a template: `doc/m2m/example-file-headers.md` shows the headers to use, and the rule for modified MiSTer files: "When you modify a MiSTer file, make sure that you leave the original MiSTer header intact and just add your own header" (Amiga port, doc/m2m/example-file-headers.md:51-52, present in every template instantiation). On top of the file-level header, mark each individual change in place. The C64 fork is the model; from `rtl/fpga64_sid_iec.vhd` alone:

- file header: "MEGA65 port, done by sy2002 and MJoergen in 2022, 2023, 2025, 2026" (C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/fpga64_sid_iec.vhd:36);
- dated inline change notes: "4/7/23 by sy2002: added 'and (romL = '0' ...)'" (fpga64_sid_iec.vhd:890), "Expansion Port-faithful PHI2 generation (sy2002 26/05/03)" (fpga64_sid_iec.vhd:449);
- removals explained, not silent: "Removed by sy2002 when switching from the PS/2 keyboard to a faithful CIA1-based implementation" (fpga64_sid_iec.vhd:125) - the original code stays in the file, commented out, as with the C1581 tie-off `assign led = /*c1581_led |*/ c1541_led;` (rtl/iec_drive/iec_drive.sv:66).

**RULE:** keep the original code commented out next to your replacement, with WHAT changed and WHY. **Why:** every upstream merge (S32) will conflict exactly at your changes; the commented original plus the dated rationale is what lets future-you (or an AI session) re-apply the change against moved upstream code instead of re-deriving it. The Amiga port follows the same style in its own files, e.g. "MiSTer2MEGA65 (AExp Amiga 500 port), June 2026: template made 54 MHz ... changed to 28.375 MHz Amiga PAL master clock, see header for the math" (Amiga port, CORE/vhdl/clk.vhd:81-83).

**S35 - Log every deviation in doc/m2m/exceptions.md.**
The template ships `doc/m2m/exceptions.md` as a pre-structured example ("The following changes have been made to MiSTer, MiSTer2MEGA65 and QNICE. As soon as you update one of these modules, make sure you are applying the changes described here.", Amiga port, doc/m2m/exceptions.md:4-6). Maintain it as a how-to for your future self with one section per upstream module (MiSTer core / M2M / QNICE), each entry written as an update recipe - the shipped example is exactly that: "Replace all 'dpram' with 'dualport_2clk_ram' ... this replacement can be done via search/replace because both RAMs are pin compatible" (doc/m2m/exceptions.md:21-23). Inline comments (S34) answer "what is this change?"; exceptions.md answers "what must I redo after pulling a new version?". Keep both.

**S36 - RULE: NOTHING is deleted from the fork - the Vivado file list is the only filter.**
Do not delete `sys/`, do not delete the Quartus project files, do not delete subsystems you de-featured in S14. Inclusion in the build is controlled solely by which files are added to the four Vivado projects (S24). **Why:** deletions guarantee merge conflicts with upstream forever, destroy the ability to diff your fork against upstream cleanly, and buy you nothing - Vivado only compiles what the project lists. The C64 fork still contains its complete `sys/` directory, `c64.sv`, all `.qpf/.qsf` files and even `clean.bat`, years into the port; none of them are in any `.xpr`. (The democore README's "When porting a new core, these files may be deleted" applies to M2M's demo files in your OWN repo, not to the fork - and even there, the C64 and Amiga ports simply drop them from the file list.)

**S37 - Enumerate what goes IN the file list.**
From your Phase 0 dossier, list the rtl/ files that implement the machine within your milestone-1 scope, plus the small helper modules they instantiate. List them only - the `.xpr` surgery that adds them to all four projects (S24 discipline) is Phase 8, S96. Calibration from the reference port: the C64 project compiles EXACTLY 28 files from the submodule, all under `rtl/` (count and list via `grep -o '[^" ]*C64_MiSTerMEGA65[^" ]*' CORE-R6.tcl | sort -u` in C64MEGA65/CORE; the `.tcl` is the project exported as script and mirrors the `.xpr`). The 28 are instructive: the machine proper (`fpga64_buslogic`, `fpga64_sid_iec`, `fpga64_rgbcolor`, `video_vicII_656x.vhd`, `video_sync.vhd`), CPU (`cpu_6510.vhd` plus the four `t65/` files), sound (five `sid/` files), CIAs (`mos6526.v`), drives within scope (`iec_drive/` c1541 files, via6522), loaders/expansions within scope (`reu.v`, `rtcF83.sv`) and the memory helpers (`dprom.vhd`, `spram.vhd`). Notably IN despite being "infrastructure": the core's own small RAM/ROM wrappers - on the develop branch they have been rewritten Vivado-clean (e.g. `dprom.vhd` is a portable VHDL BRAM with textio-based init, keeping the Quartus wrapper's exact name and port interface, C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/dprom.vhd:7-29; the techniques are in Part III) so that the machine files instantiating them need no edits.

**S38 - Enumerate what stays OUT.**
Equally instructive is what the C64 file list does NOT contain, and the same categories apply to every port:

- the entire `sys/` directory - that is the MiSTer platform framework; M2M IS the replacement for it (see S39 for the exceptions);
- the emu top (`c64.sv` / `Minimig.sv`) - replaced by your `CORE/vhdl/main.vhd` wrapper (Part III); it remains in the fork as the single most valuable reference document of the port;
- all Quartus build files: `.qpf`, `.qsf`, `.qip`, `.sdc`, `.srf` - Vivado equivalents are the `.xpr` projects and `.xdc` constraints in the port repo;
- the PLL IP: `rtl/pll/` (and `pll.v`, `pll_cfg`, `pll_hdmi*` under sys/) - replaced by your `CORE/vhdl/clk.vhd` MMCMs (S7/S8);
- the MiSTer SDRAM controller (`sdram.v`) - MEGA65 has no SDRAM; its role is taken by BRAM/HyperRAM per your S11 plan;
- subsystems outside milestone-1 scope: for C64 that is `fpga64_keyboard.vhd` (replaced by the CIA1-level `CORE/vhdl/keyboard.vhd`, S12), `c1530.vhd` (tape), `c1351.v` (mouse), the `opl3/` directory, `cartridge.v` (added later when cartridges came into scope). They stay in the fork, off the list, until their milestone arrives.

Expected outcome of S37+S38: a written IN/OUT table in your port docs, one row per file/directory of the fork, with the OUT rows annotated by reason (sys-replaced / Quartus / out-of-scope / reference-only).

**S39 - Never re-port the sys/ components that M2M already ported.**
A handful of MiSTer `sys/` components are genuinely needed inside the core-facing video/audio path, and M2M V2.0.1 already contains ported, Vivado-clean versions of them under `M2M/vhdl/controllers/MiSTer/`: `scandoubler.v`, `video_mixer.sv`, `hq2x.sv`, `gamma_corr.sv`, `csync.sv`, `video_freezer.sv`, `video_sync.vhd` (CAUTION: for the C64, the submodule's rtl/video_sync.vhd must be used instead - the M2M copy is stale, see S65) and the audio IIR filter `iir_filter.v` (Amiga port tree, M2M/vhdl/controllers/MiSTer/; MiSTer's `audio_out.v` lives next door in `M2M/vhdl/av_pipeline/`). **RULE:** when your emu file instantiates `video_mixer`, `video_freak`, the scandoubler or audio filters, do NOT copy those from your fork's `sys/` into the build - wire up the M2M copies (Part III shows where they are instantiated). The M2M copies carry framework-specific fixes; a second, subtly different copy from your fork's `sys/` produces name collisions or, worse, silently shadows the fixed version. (`video_freak`'s cropping/scaling function is handled by M2M's own crop/scaler infrastructure rather than a 1:1 port - treat any `video_freak` instantiation in emu as OUT, covered in Part III's video chapter.)

**S40 - Commit the curated baseline and snapshot the upstream state.**
Finish Phase 2 with: (1) in the fork, a `develop` branch whose only delta against `master` is, so far, nothing or documentation - record the upstream SHA you forked from in the fork's README or your exceptions.md ("based on C64_MiSTer commit <sha>" - the C64 fork's merge commits like 4a54016 show this SHA-explicit practice); (2) in the port repo, the submodule added and pinned and the IN/OUT table committed to `doc/` (the IN-list files enter the four projects in Phase 8, S96). The project will NOT synthesize yet - the files are Quartus-flavored and nothing instantiates them. That is expected: making them compile is Phase 3 (basic wiring, Part II continues in chapter 2.3) and Phase 4/5 (Vivado-porting the RTL, Part III). What you have is the foundation every later step builds on: a reproducible, documented, upstream-traceable source base.

---

## 2.3 Phase 3 - Make the RTL Vivado-clean

You now have a curated file list (Phase 2): the machine RTL you intend to compile, and nothing else. Before you let Vivado touch a single file, run a proactive, grep-driven sweep over exactly that list. **Why:** every Quartus-ism you find by grep costs you thirty seconds; every one you find via a Vivado elaboration error costs you a full round-trip (open project, elaborate, read cryptic error, locate file, fix, re-elaborate) - and if, like the Amiga port, your Vivado lives on a different machine than your editor, a round-trip costs minutes to hours. The C64 port found these problems the slow way across a dozen commits ("Fix (minor) errors reported by Vivado", commits d4745fd, f2a27da, 7855ad6, ffbef1e in C64MEGA65 CORE/C64_MiSTerMEGA65); the Amiga port swept all 49 kept plain-Verilog Minimig RTL files (excluding the fx68k .sv files and the VHDL) in one editor pass before first Vivado contact and got through elaboration in two iterations. This chapter is the process; the per-pattern fix recipes live in Part III - apply them as cross-referenced.

**RULE:** sweep only the kept file list. Do not "fix" files you excluded in Phase 2 (MiSTer's `sys/`, the `emu` top, disabled subsystems). The C64 team initially patched `sys/osd.v` and `sys/hq2x.sv` before M2M existed - wasted work that was abandoned. Dead files stay dead; inclusion is controlled solely by the project file list, nothing is ever deleted from the fork.

**S41 - Grep for Intel/Altera primitives and ROM-init attributes.** Over the kept list, search for vendor megafunctions and Quartus memory attributes:

```bash
grep -rn -E 'altsyncram|altdpram|altera_mf|lpm_|dcfifo|scfifo|altpll|cyclonev' <kept files>
grep -rn -E 'ram_init_file|\.mif|ramstyle|altera message' <kept files>
```

Every hit is real work, not a mechanical edit: `altsyncram`/`altdpram` instantiations and `ram_init_file` attributes become instantiations of M2M's `dualport_2clk_ram` or a Vivado-inferrable behavioral template (apply the fixes of Part III, section A), and every `.mif` initialization file must be converted to plain hex and re-pathed (Part III, section G). Also grep for mixed-width or byte-enabled dual-port memories (one port 8 bit, the other 16/32 bit, or `wren` per byte lane) - Quartus infers them, Vivado frequently cannot; the C64 port hit this with `iecdrv_bitmem` ("Vivado was not able to synthesize iecdrv_bitmem", header of C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/iecdrv_misc.sv) and the fix is lane-splitting (Part III, section A; also section 2.6 below for the strategy when QNICE needs access). Record each hit and its planned replacement in a worklist file before editing anything - memory work interacts with Phase 6 decisions (where does this RAM live, does QNICE need a port), so do not blind-fix.

**S42 - Grep for the Verilog constructs Vivado rejects.** Three patterns cover the vast majority of MiSTer-style Verilog that Quartus accepts and Vivado does not:

1. *Unnamed `always` blocks containing local declarations* (`Synth 8-1873`). MiSTer code constantly declares `reg old_x;` inside `always` blocks; Vivado requires the block to be named (`always @(posedge clk) begin : label0`). Grep candidate: every `always` block, then eyeball for a `reg`/`integer` declaration on the lines after `begin`. The C64 fix style is visible at C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/mos6526.v:154 (`always @(posedge clk) begin : label0`); the Amiga sweep named 18 such blocks across minimig.v, denise_bitplanes.v, userio.v, ide.v and others (Amiga port, .research/phase-a/sweep-minimig.md, section A).
2. *Procedural assignment to nets* (`Synth 8-2576`). Anything written inside `always`/`always_comb` must be declared `reg` (or `output reg`), not `wire`/plain `output`. Grep each module's output list against its `always` blocks; typical fixes are `output [7:0] x` -> `output reg [7:0] x`.
3. *Multi-driven registers* - one `reg` written from two or more `always` blocks. Quartus merges the drivers if the bit ranges are disjoint; Vivado errors out. This one greps poorly (you must search for each register name appearing in multiple `@(posedge ...)` blocks), but it is common in old Minimig-lineage code: the Amiga sweep found nine cases including `agnus_beamcounter.v`'s `hpos` (bits [8:1] written in a clocked block, bit [0] in a separate combinational block) and `agnus_blitter.v`'s `bltcon0` (three clocked blocks writing [15:12], [11:8], [7:0]). The fix pattern - split into per-driver registers plus a recombining `assign` - is Part III, section C. **TRAP:** when the drivers are *combinational* and reference each other's bits (the Amiga `agnus_blitter_fill.v` `carry` case, where a for-loop indexes `carry[j-1]`), splitting is not clean; merge the blocks into one `always @(*)` instead.

**S43 - Grep the VHDL files for Vivado-hostile constructs.** If your core contains VHDL (Gideon-style drive emulation, T65/T80 CPUs, TG68):

1. *`alias` of a vector slice that is written inside a process.* Vivado 2019.2-2021.2 silently drops the write - no error, just wrong hardware. This cost the C64 port a debugging session (commit 7a264a2 "Workaround for nasty Vivado bug" in C64_MiSTerMEGA65: writes to `alias timer_a_flag : std_logic is irq_flags(6)` did nothing; the alias was replaced by a discrete `signal timer_a_flag` and recombined manually - see the commented-out alias at C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/iecdrv_via6522.vhd around line 109 vs. the read-only aliases at lines 101-107, which are fine). `grep -rn 'alias' *.vhd` and check every hit: read-only aliases may stay, written ones must go. Details in Part III, section D.
2. *Entity instantiation without the `entity` keyword.* Quartus accepts `cpu: work.T65 port map (...)`; Vivado requires `cpu: entity work.T65` (fixed form at C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/cpu_6510.vhd:58). Grep for `: work.` not preceded by `entity`.
3. *Incomplete sensitivity lists.* Quartus often produces the intended logic anyway; Vivado takes the list literally and builds latches or stale logic. Either add the missing signals or convert to VHDL-2008 `process(all)` - which then requires the file to be read with `read_vhdl -vhdl2008` (the C64 project reads all submodule VHDL that way). Part III, section D.

**S44 - Sweep the mixed-language boundary: port names.** Vivado's VHDL/Verilog boundary is case-sensitive and identifier-strict in ways Quartus is not. Two sub-checks:

1. *VHDL entities instantiated from (System)Verilog need all-lowercase port names*, and ports must not collide with Verilog keywords. The C64 port renamed every T65 port to lowercase and had to rename `DO`/`DI` to `dout`/`din` because `do` is a Verilog keyword (long explanatory comment in C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/t65/T65.vhd; error signature `[Synth 8-448] named port connection '...' does not exist`). Grep every VHDL entity that a `.v`/`.sv` file instantiates.
2. *Verilog modules instantiated from VHDL must not use ports that are illegal VHDL identifiers* - above all the MiSTer/Minimig habit of leading underscores for active-low signals (`_cpu_as`, `_hsync`, `_joy1`). VHDL basic identifiers cannot start with `_`, so `main.vhd` cannot map such ports. Do not rename ports inside the upstream files (merge pain forever); write a thin renaming wrapper module instead. The Amiga port's `minimig_m65.v` exists for exactly this reason - "minimig.v uses port names with a leading underscore (_cpu_as, _hsync, _joy1, ...) which are not legal VHDL identifiers, so ... main.vhd cannot instantiate minimig directly. This wrapper renames all underscore-prefixed ports to the M2M convention (active-low signals get a _n suffix instead of the _ prefix)" and adds constant tie-offs for unused subsystems, no logic (Amiga port, CORE/Minimig_MiSTerMEGA65/rtl/minimig_m65.v:1-19). Full boundary rules: Part III, section E.

**S45 - Decide the `-sv` read list.** Vivado will not parse SystemVerilog constructs in a file read as plain Verilog. Some MiSTer `.v` files contain SV-isms (`logic`, typed parameters, `int` loop variables, SV array sizes like `reg [15:0] mem[256]`); the C64 port marks such files explicitly ("Vivado needs interpret this as SystemVerilog even though it is 'just' a .v file", C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/fdc1772.v:25) and its build script reads a broad list with `read_verilog -sv`. You have two valid policies: (a) read everything `-sv` (the C64 precedent; safe, since legal Verilog-2001 is a subset for synthesizable code), or (b) keep plain `.v` files Verilog-2001-clean and reserve `-sv`/SystemVerilog file type for the genuinely-SV files (the Amiga port fixed the single SV-ism in its plain-Verilog set - `reg [15:0] custom_mirror[256]` -> `[0:255]` in cart.v - and types only fx68k's `.sv` files as SystemVerilog). Whichever you pick, record it now; in a GUI-managed `.xpr` project the equivalent is the per-file `FILE_TYPE` property (SystemVerilog vs. Verilog - see Part III, section H for how wrong type tokens can crash the project parser).

**S46 - Optional but strongly recommended: a local lint loop without Vivado.** If Vivado is not on your editing machine (the Amiga port's setup: editing on a Mac, Vivado in a Windows VM), build a fast local checker from open-source tools so that the S41-S45 fixes are verified *before* the next Vivado round-trip:

- **Verilog:** `iverilog -g2012 -t null <kept .v/.sv files>` parses and elaborates without generating anything. Dependencies that iverilog cannot digest get *stub modules*: an empty `module dpram #(parameter ADDRWIDTH=12, DATAWIDTH=16) (input clock, ...); endmodule` standing in for a VHDL memory, and a port-only stub for SV-heavy code iverilog chokes on (fx68k's unpacked structs, in the Amiga case).
- **VHDL:** `nvc --std=2008 -a` (best diagnostics) and/or `ghdl` as a second opinion, analyzing in dependency order. For `clk.vhd` and anything else referencing Xilinx libraries, compile *stub packages* named `vcomponents` into libraries named `unisim` and `xpm` - declarations of just the components you instantiate (MMCME2_ADV, BUFG, xpm_cdc_*), empty architectures - and point the tool at them (`nvc -L <dir>`). The M2M files you need to analyze first as dependencies: `M2M/QNICE/vhdl/tools.vhd`, `M2M/vhdl/controllers/HDMI/types_pkg.vhd`, `M2M/vhdl/av_pipeline/video_modes_pkg.vhd`, `M2M/vhdl/tdp_ram.vhd`, `M2M/vhdl/2port2clk_ram.vhd`. Note `M2M/vhdl/bram.vhd` is VHDL-93; analyze it with `--std=93`.

**TRAP:** know the false-positive noise of these tools so you do not "fix" legal code. iverilog flags use-before-declaration ordering (a wire used above its declaration) that Vivado accepts, and emits follow-on zero-width-concatenation errors in code Vivado is fine with; nvc/ghdl may complain about constructs Vivado's VHDL front end tolerates. The rule: the local loop is for catching *your* regressions and the S42/S43 categories, not for achieving zero warnings. The full recipe, including stub file contents, is Part III, section J.

**S47 - First Vivado contact: the Open Elaboration loop.** Now, and only now, open the project in Vivado and run *Open Elaborated Design* (GUI) or `synth_design -rtl` (Tcl). Elaboration is fast (tens of seconds against minutes for synthesis) and surfaces language-level errors. Caveat: out-of-hierarchy files are only parsed, not elaborated; the full S42/S43 long tail surfaces once main.vhd instantiates the core (Phase 5) - re-run the elaboration loop then, or instantiate the core top from a temporary dummy wrapper to make Phase 3 elaboration meaningful. Work strictly one error at a time: Vivado aborts at the first hard error per file, so the visible error count is meaningless - fix the top one, re-elaborate, repeat. Resist batching speculative fixes; an error message often changes meaning once the error above it is gone. Expect the long tail of S42/S43 patterns you could not grep reliably (multi-driven nets across `generate` blocks, width mismatches at the VHDL/Verilog boundary, the occasional black-boxed module from a typo'd name). When elaboration completes with only warnings, skim the warning list once for `Synth 8-` codes about inferred latches and multi-driven nets - those are functional bugs in waiting, not noise. Synthesis itself (and the timing fight) is Phases 9 and 10; do not chase timing now.

**S48 - Leave provenance at every change site.** Every modified upstream line gets a comment naming the port, the date, and the why - the C64 convention is "Adjusted to MiSTer2MEGA65 by sy2002 in March 2022: <reason>", the Amiga convention "MiSTer2MEGA65 (AExp Amiga 500 port), June 2026: <reason>", with the original code kept commented out where reasonable. **Why:** you will merge upstream MiSTer fixes into `develop` for years (the C64 port still does); provenance comments turn every merge conflict from archaeology into a mechanical re-application. After the sweep, run mechanical sanity checks over the edited files - balanced `begin`/`end`, `case`/`endcase`, `module`/`endmodule` counts catch the classic slip of deleting an `end` while commenting out a block. Commit the sweep in small, single-purpose commits ("named always blocks", "split multi-driven registers in agnus_blitter.v") - the C64 history's archaeological readability is what made its porting playbook extractable, and yours will serve the next port.

## 2.4 Phase 4 - Clocks: clk.vhd

Division of labor first: the M2M framework already generates every clock it needs for itself - QNICE 50 MHz, HyperRAM 100/100-delayed/200 MHz, audio 12.288 MHz (M2M/vhdl/clk_m2m.vhd:24-37) - plus the HDMI pixel clocks. Your job in `CORE/vhdl/clk.vhd` is ONLY the core's own clock domain(s). The MEGA65 board feeds you 100 MHz (`sys_clk_i`), and you derive the core clock from it with a Xilinx `MMCME2_ADV` primitive. There is no Quartus-style PLL megafunction and no dynamic PLL reconfiguration; both get replaced by patterns described below (and catalogued in Part III, section B).

**S49 - Decide the clock architecture: one clock if at all possible.** List every clock the MiSTer core's `pll` instantiation produces and every clock port the emu module distributes (`clk_sys`, `clk_vid`, memory clocks, 2x clocks). Then ruthlessly reduce: a single core clock with *clock enables* for every derived rate is the M2M default and by far the easiest to constrain, to make timing on, and to reason about. MiSTer cores usually already work this way internally (Minimig: everything on one 28 MHz clock, the 7 MHz CPU bus and 3.5 MHz color clock are enables generated in amiga_clk.v). A second genuine clock is justified only when the core truly needs an unrelated frequency that cannot be an enable (e.g. a DDR memory PHY) - in that case add one more `CLKOUTn` output plus its own BUFG and its own synchronized reset, and treat every signal crossing between the two as formal CDC (Part III, section F). **RULE:** a rate that is an integer or fractional division of the core clock is a clock ENABLE, never a derived clock (see S53). MiSTer's runtime PLL reconfiguration (PAL/NTSC switching) is replaced by either two precomputed MMCM parameter sets (advanced, S54) or simply by supporting one video standard first. Also check the actual machine module(s) for inputs fed with `CLK_50M` (MiSTer's framework clock) directly - e.g. Apple-II's apple2_top uses it to derive a 6551 UART clock via a /27 divider. Classify each: if the frequency is genuinely needed by the emulated hardware, add a dedicated MMCM output (or adjust the internal divider constant for a frequency you already generate, with a provenance comment); never reuse the framework's QNICE 50 MHz clock for core logic - that creates an undeclared CDC.

**S50 - Compute legal MMCME2_ADV parameters.** The math, for `CLKIN1_PERIOD => 10.0` (the 100 MHz board clock):

```text
f_VCO = 100 MHz * CLKFBOUT_MULT_F / DIVCLK_DIVIDE
f_OUT = f_VCO / CLKOUT0_DIVIDE_F
```

Legality rules for the MEGA65's Artix-7 (XC7A200T speed grade -2; see Xilinx DS181/UG472, and note M2M's own clk_m2m.vhd conservatively designs to the -1 range, M2M/vhdl/clk_m2m.vhd:66):

- VCO frequency must be within 600..1440 MHz for -2 (600..1200 MHz for -1; check DS181 against your exact part).
- PFD frequency `100 MHz / DIVCLK_DIVIDE` must stay within 10..500 MHz.
- `CLKFBOUT_MULT_F` is fractional in steps of 0.125, range 2.000..64.000.
- Fractional divide is allowed ONLY on `CLKFBOUT` and `CLKOUT0` (also 0.125 steps, `CLKOUT0_DIVIDE_F` range 1.000..128.000); `CLKOUT1..6` are integer-only. If you need two fractional outputs, you need two MMCMs.
- Fine phase shift conflicts with fractional mode; do not combine them.

Worked example 1 (C64MEGA65 CORE/vhdl/clk.vhd:99-105): target 31.5278 MHz -> `DIVCLK_DIVIDE => 6`, `CLKFBOUT_MULT_F => 56.750` (VCO 945.833 MHz), `CLKOUT0_DIVIDE_F => 30.000` -> 100 * 56.750 / 6 / 30 = 31.527778 MHz. Worked example 2 (Amiga port, CORE/vhdl/clk.vhd:79-88): target 28.37516 MHz (PAL Amiga, 4 x 7.09379 MHz) -> `DIVCLK_DIVIDE => 5`, `CLKFBOUT_MULT_F => 56.750` (VCO 1135.000 MHz), `CLKOUT0_DIVIDE_F => 40.000` -> exactly 28.375000 MHz, -5.6 ppm off ideal. Search the parameter space exhaustively with a ten-line script over all legal (DIVCLK, MULT, DIV0) triples using exact rational arithmetic (Python `fractions.Fraction`) and pick the candidate with the smallest ppm error whose VCO is comfortably in range - higher VCO generally means less jitter. Document the whole derivation in the clk.vhd header (both reference ports do; it is the first thing you will need when adding NTSC later).

**S51 - Decide how close is close enough.** Compare your achievable frequency against the original machine's *crystal tolerance*, not against zero: a consumer-grade crystal is +/-50 ppm or worse, so any MMCM solution within single-digit ppm is better than the real hardware ever was (the Amiga port's -5.6 ppm is well inside the +/-50 ppm of a real Amiga crystal). What you must NOT wave through: errors in the 0.1% range and above. Those audibly detune audio, visibly change video refresh, and - worst - cause drift between subsystems that real software relies on. If no single-MMCM solution gets close, cascade two MMCMs (the C64 clk.vhd header lines 28-37 shows the technique: factor the required ratio into two legal MMCM ratios; mind the second MMCM's VCO range) or reconsider whether the "required" frequency is really required.

**S52 - Write clk.vhd: template structure.** Start from the M2M template's `CORE/vhdl/clk.vhd` (in the template it produces a 54 MHz demo clock via `DIVCLK_DIVIDE=1, CLKFBOUT_MULT_F=6.750, CLKOUT0_DIVIDE_F=12.500`) and change only the generics. Keep the structure, which per output clock is:

1. the `MMCME2_ADV` instance with `BANDWIDTH => "OPTIMIZED"`, `CLKIN1_PERIOD => 10.0`, your computed dividers;
2. a `BUFG` on the feedback path and a `BUFG` on each clock output (never use an un-buffered MMCM output as a clock);
3. reset generation: an `xpm_cdc_async_rst` per output clock, `RST_ACTIVE_HIGH => 1`, `DEST_SYNC_FF => 6`, with `src_arst => not locked` and `dest_clk` = the buffered output clock, producing `main_rst_o` (C64MEGA65 CORE/vhdl/clk.vhd:209-230 shows BUFG plus the xpm_cdc_async_rst driven by `not (main_locked_orig and main_locked_slow)` - with a single MMCM that is just `not main_locked`).

Keep the entity ports byte-identical to the template (`sys_clk_i`, `main_clk_o`, `main_rst_o`) unless you genuinely add clocks - the framework instantiates this entity from `mega65.vhd` and every renamed port is a needless diff. **Why** the xpm reset block: it converts the asynchronous MMCM `LOCKED` deassertion into a reset that is asynchronously asserted but *synchronously released* in the destination domain - the only reset style that is safe to fan out to your whole core. **TRAP:** do not invent your own two-flop reset synchronizer here; `xpm_cdc_async_rst` is already constrained correctly by the XPM library.

**S53 - Derived rates become clock enables: the fractional accumulator.** Everywhere the MiSTer core used a second PLL output or a divided clock for a slower subsystem, generate a one-clock-wide enable instead, using the fractional-accumulator pattern parameterized by `clk_main_speed_i` (the exact core clock in Hz, a `natural` input of main.vhd - see section 2.5). The reference is the C64's 16 MHz IEC-drive enable, C64MEGA65 CORE/vhdl/main.vhd:1517-1535:

```vhdl
iec_drive_ce_proc : process (all)
   variable msum, nextsum : integer;
begin
   msum    := clk_main_speed_i;
   nextsum := iec_dce_sum + 16000000;
   if rising_edge(clk_main_i) then
      iec_drive_ce <= '0';
      if reset_core_n = '0' then
         iec_dce_sum <= 0;
      else
         iec_dce_sum <= nextsum;
         if nextsum >= msum then
            iec_dce_sum  <= nextsum - msum;
            iec_drive_ce <= '1';
         end if;
      end if;
   end if;
end process iec_drive_ce_proc;
```

This is drift-free over time (the accumulator never loses the remainder), produces exactly `16000000 / clk_main_speed` enables per second on average, and - because it is parameterized by `clk_main_speed_i` rather than a hard-coded divider - keeps the derived rate correct when you later add a second core speed (flicker-free, NTSC). **Why** this matters beyond convenience: the C64 team learned that deriving the drive clock independently of the main clock changes the frequency *ratio* between machine and drive and breaks fast loaders (comment above the process, main.vhd:1507-1516, referencing C64MEGA65 GitHub issue #2). Gate logic with `if ce = '1' then` inside the full-speed clocked process; never use the enable as a clock.

**S54 - Advanced option: dual MMCM + BUFGMUX_CTRL for HDMI flicker-free.** The MEGA65 outputs HDMI at exactly 50/60 Hz; a core whose native frame rate is slightly off (the PAL C64: 50.124 Hz) beats against the ascaler's buffer and produces a visible stutter every few seconds. The C64's solution, which you can adopt wholesale once the basic port works: instantiate TWO complete MMCMs - the original-speed clock and a ~0.25% slower one whose frame rate is exactly 50 Hz (C64MEGA65 CORE/vhdl/clk.vhd:93-105 original, 147-159 slow: `DIVCLK 9 / MULT 60.500 / DIV0 21.375` -> 31.449 MHz) - and switch between them at runtime with a `BUFGMUX_CTRL` primitive, a glitch-free clock mux whose select input may change asynchronously (clk.vhd:197-204; select driven by `core_speed_i`, which mega65.vhd derives from the OSM "HDMI: Flicker-free" setting). The reset must then depend on BOTH `LOCKED` signals (clk.vhd:225). Because `clk_main_speed_i` and all S53 accumulators retune automatically, the core does not notice the switch. File this under "later": it costs a second MMCM, more constraints, and is worthless before video output is stable. (See Part III, section B for the alternatives the C64 header documents: MMCM fine phase shifting, and cascaded MMCMs for exact ratios.)

**S55 - Constrain the clock and freeze its value in globals.vhd.** Two bookkeeping duties that bite when skipped:

1. In `CORE/CORE.xdc`, name the autogenerated clock with `create_generated_clock` on the MMCM output pin, BEFORE any other constraint references it: `create_generated_clock -name main_clk [get_pins CORE/clk_gen/i_clk_c64_orig/CLKOUT0]` (C64MEGA65 CORE/CORE.xdc:9; Amiga equivalent `[get_pins CORE/clk_gen/i_clk_main/CLKOUT0]`, AExp CORE/CORE.xdc:19). The hierarchical pin path is `CORE/clk_gen/<your MMCM instance label>/CLKOUT0` - `CORE` is the framework's label for the whole core wrapper, `clk_gen` is mega65.vhd's label for your clk entity. Vivado derives the clock automatically even without this line, but with an auto-generated name; naming it is what lets later constraints (`set_max_delay`, false paths, the M2M framework's CDC constraints) refer to it robustly. This only works because M2M synthesizes with `-flatten_hierarchy none` - do not change that setting (Part III, section F).
2. In `CORE/vhdl/globals.vhd`, set `CORE_CLK_SPEED` to the EXACT frequency the MMCM produces - the achieved value, not the ideal target: the C64 uses `constant CORE_CLK_SPEED_PAL : natural := 31_527_778` (C64MEGA65 CORE/vhdl/globals.vhd:47-50), the Amiga port `28_375_000` (AExp CORE/vhdl/globals.vhd:49). This constant feeds `clk_main_speed_i` and therefore every S53 accumulator; framework timekeeping and your derived rates are only as accurate as this number. When you ever retune the MMCM, update this constant in the same commit.

## 2.5 Phase 5 - Wire main.vhd

`CORE/vhdl/main.vhd` is the heart of the port: "Wrapper for the MiSTer core that runs exclusively in the core's clock domain" (C64MEGA65 CORE/vhdl/main.vhd:1-8). It is the M2M replacement for MiSTer's `emu` module - but where `emu` talks to the HPS, main.vhd talks to the M2M framework through a fixed port contract, and where `emu` lives in a soup of clocks, main.vhd contains ONLY logic clocked by `clk_main_i`. Everything that needs another domain (QNICE-facing memories, HyperRAM, the AV pipeline) lives in `mega65.vhd` or the framework. Keep this invariant sacred; it is what makes the port constrainable.

**S56 - Internalize the role split.** main.vhd instantiates the actual machine (the modules you kept in Phase 2) plus your adapters: keyboard.vhd, clock-enable generators, reset logic, audio/video output shaping. It does NOT instantiate: scandoubler/video_mixer/ascal (framework, driven from mega65.vhd), OSD (QNICE), SD card (QNICE + vdrives), HyperRAM (mega65.vhd). If you find yourself wanting a second clock inside main.vhd, you are about to make a mistake - push that logic up to mega65.vhd where the framework's CDC helpers live (see section 2.6).

**S57 - Use the emu module as your wiring oracle.** Open the MiSTer core's top `.sv` (`c64.sv`, `Minimig.sv`, ...) side by side with your empty main.vhd and replicate, signal by signal, what `emu` does around the machine instantiation: every tie-off, every inversion, every glue process (pixel-CE generation, audio mixing, reset stretching). You are not porting that code - you are re-expressing its *intent* with M2M sources on the other end. Three reading rules: (1) trace every `status[n]` bit from the `CONF_STR` to its consumer - these become OSM menu inputs (section 2.7); (2) trace every `.*` wildcard connection explicitly - print the module's port list and match by name, because wildcards hide tie-offs; (3) note every place `emu` *inverts or reshapes* a signal between core and `sys/` - you must replicate those (the video sync polarity trap of S64 comes from exactly here). Document the resulting contract before coding; the Amiga port wrote a full port-by-port table (direction, width, active level, "connect to") for minimig before wiring anything, and main.vhd's header points to it (Amiga port, CORE/vhdl/main.vhd:10).

**S58 - Walk the main.vhd entity contract.** The template fixes the entity; you fill the middle. The port groups, with the C64 instance as the worked example (C64MEGA65 CORE/vhdl/main.vhd:25-122):

- `clk_main_i` - the core clock from your clk.vhd. `clk_main_speed_i : natural` - its exact Hz (from `CORE_CLK_SPEED`, S55); feed it to every fractional-accumulator CE (S53).
- `reset_soft_i`, `reset_hard_i` - framework resets; do NOT use directly (S60).
- `pause_i` - pull high pauses the core (main.vhd:40-41); wire it to the core's pause input if it has one (the C64 routes it into `fpga64_sid_iec` and the IEC drives, main.vhd:681,1468). If the core cannot pause, leave it unconnected - but then you must NOT enable `OPTM_PAUSE` in config.vhd (section 2.7, S82).
- Core-specific option inputs - one port per OSM-controlled setting (`c64_ntsc_i`, `c64_sid_ver_i`, ...). You define these; mega65.vhd drives them from menu bits (section 2.7, S81).
- Keyboard: `kb_key_num_i : integer range 0 to 79` plus `kb_key_pressed_n_i` (low-active, debounced) - the M2M keyboard scan interface (S61).
- Joysticks: `joy_1_*_n_i` / `joy_2_*_n_i`, all ACTIVE-LOW ('0' = pressed), plus the corresponding `_n_o` outputs (the framework lets the core drive the port for bidirectional uses; loop inputs to outputs if unused). Paddles: `pot1_x/y_i`, `pot2_x/y_i`, 8-bit unsigned each.
- Video out: `video_ce_o`, `video_ce_ovl_o`, `video_red/green/blue_o` (8 bit each), `video_vs_o`, `video_hs_o`, `video_hblank_o`, `video_vblank_o` (S64-S67).
- Audio out: `audio_left_o`, `audio_right_o`, `signed(15 downto 0)` (S68).
- `drive_led_o`, `drive_led_col_o` - the MEGA65 drive LED and its 24-bit RGB color (S70).
- The memory/device ports you add yourself for mega65.vhd-hosted RAMs and vdrives (section 2.6).

**RULE:** extend this entity freely with core-specific ports (the C64 added dozens for cartridge and IEC), but never repurpose or rename the framework-defined ones - mega65.vhd and the framework templates reference them by name.

**S59 - Instantiate the machine and tie off what you do not use - at the correct idle LEVELS.** Every input of the core that nothing drives yet gets an explicit constant. "Correct" means the *inactive* level, which for MiSTer-lineage cores is very often NOT '0': active-low buses idle at all-ones (Minimig joystick ports: `16'hFFFF`), RS232 modem inputs idle high (the Amiga wrapper ties `rxd/cts/dsr/cd/ri` to 1, matching MiSTer's own tie-offs - Amiga port, CORE/Minimig_MiSTerMEGA65/rtl/minimig_m65.v header: "ties off every subsystem that the ... milestone-1 configuration never uses"), enables idle at the level that *disables* the subsystem. Crib every tie-off level from the emu module (S57) - if `emu` ties `ri(1'b1)`, so do you. **TRAP:** tying an active-low input to '0' does not "disable" it, it asserts it permanently; symptoms range from a core that never leaves reset to phantom serial interrupts. Where a whole subsystem is disabled, also force its *outputs* into the OR-mux idle value if the core uses OR-bus muxing (Minimig's `toccata_out = 16'h0000` so the dead module cannot corrupt the CPU data bus). Putting all tie-offs into a thin Verilog wrapper around the core (S44's renaming wrapper) keeps main.vhd readable and lets synthesis constant-fold the dead logic.

**S60 - Implement the reset semantics.** Read the RESET SEMANTICS block at C64MEGA65 CORE/vhdl/main.vhd:340-388 in full; it is the canonical specification. The distilled rules:

- The framework gives you two inputs: `reset_soft_i` (short reset button press, OSM-triggered resets, QNICE `M2M$CSR_RESET`; pulses are guaranteed >= 32 clk cycles) and `reset_hard_i` (long button press >= 1.5 s).
- **RULE:** "CAUTION: NEVER DIRECTLY USE THE INPUT SIGNALS reset_soft_i and reset_hard_i IN MAIN.VHD AS YOU WILL RISK DATA CORRUPTION!" (main.vhd:371-374, verbatim). Instead derive a protected `reset_core_n` and use only that.
- The protection: `prevent_reset <= '0' when unsigned(cache_dirty) = 0 else '1';` (main.vhd:549) - when any virtual drive's write cache has not been flushed to SD card yet, reset is held off, because resetting mid-flush corrupts the user's disk image. The protected reset is then formed as `reset_core_int_n <= prevent_reset and (not reset_hard_i)` inside the reset process (main.vhd:580) - note the hard reset deliberately punches through the protection (the user held the button 1.5 s; they mean it).
- Hard vs soft is also a *core-semantic* distinction you define: on the C64, soft reset respects cartridge reset traps (games that hijack the reset vector) while hard reset clears the simulated cartridge state and forces a cold start, with `hard_reset_n` stretched for `C_HARD_RST_DELAY = 100_000` core clocks (main.vhd:390; ~3.2 ms at 31.5 MHz - the in-source comment says "roundabout 1/30 of a second", which does not match the arithmetic) so slow subsystems see it. Decide what "soft" and "hard" mean for your machine (Amiga: soft = CPU reset / keyboard reset equivalent, hard = power cycle with Kickstart re-entry) and write it down in your own RESET SEMANTICS block.
- If you have no virtual drives yet (first milestone), `prevent_reset` degenerates to '0' - still build the structure now; retrofitting it after drives exist is error-prone.

**S61 - Keyboard: pick the adaptation strategy.** M2M's keyboard interface is a continuous hardware scan: `kb_key_num_i` cycles through MEGA65 key numbers 0..79 at 1 kHz per full sweep, `kb_key_pressed_n_i` reports (low-active, debounced) whether that key is currently down (documented in C64MEGA65 CORE/vhdl/keyboard.vhd:17-19). Your `CORE/vhdl/keyboard.vhd` converts this into whatever the core natively consumes. Two proven strategies:

1. *Matrix emulation* (use when the core scans a key matrix through an I/O chip): delete the core's PS/2 keyboard module, export the I/O chip's matrix ports from the core, and synthesize the matrix state. The C64 removed `fpga64_keyboard.vhd` and the `ps2_key` input entirely and instead drives/reads the CIA1 ports (`cia1_pa_i/o`, `cia1_pb_i/o`); CORE/vhdl/keyboard.vhd ("Convert MEGA65 keystrokes to the C64 keyboard matrix that the CIA1 can scan", keyboard.vhd:2) computes the column response from the row drive combinationally, key by key, including the sneaky bidirectional cases (joystick and keyboard sharing CIA lines).
2. *Scancode-stream translation* (use when the core consumes a serial keycode protocol): keep the core's keyboard input path and replace the HPS/PS2 source with a generated event stream. The Amiga port does this: Minimig's CIA-A consumes raw Amiga keycodes via the `kbd_mouse_data/kbd_mouse_type/kms_level` protocol that MiSTer's HPS normally feeds, so AExp keyboard.vhd translates MEGA65 scan events into exactly that protocol (Amiga port, CORE/vhdl/keyboard.vhd:4-27).

Strategy 1 is more work but timing-exact (matrix ghosting, multi-key behavior come for free); strategy 2 is less invasive but you inherit protocol pacing duties - the Amiga module needed a FIFO plus a 1-event-per-millisecond pacer because Kickstart's keyboard.device cannot swallow back-to-back keycodes, and a 100 ms post-reset hold-off because the core's stretched internal reset would swallow early events (AExp keyboard.vhd:33-46). **TRAP:** whichever strategy, events can be lost or duplicated if you sample the M2M scan asynchronously - see S62.

**S62 - Keyboard: the mirror-register pattern and the m65 key table.** The robust consumption pattern for the 1 kHz scan, used by both reference ports: keep an 80-bit *mirror register* of the last known state of every MEGA65 key; each scan tick, compare the reported state of key `kb_key_num_i` against the mirror bit; on mismatch you have exactly one clean press or release EDGE - update the mirror and act on the event (matrix update, or push a translated scancode into the FIFO). This gives inherent debouncing-by-construction on top of the framework's own debouncing, and exactly one event per physical edge (AExp keyboard.vhd:33-36 describes this; the C64 keyboard.vhd does the equivalent with its `key_pressed_n` matrix registers). The MEGA65 key numbering is fixed by the framework; both reference keyboards carry the full constant table - `constant m65_ins_del : integer := 0; constant m65_return : integer := 1; ... ` (C64MEGA65 CORE/vhdl/keyboard.vhd:81-98 and onward, all 80 keys) - copy that table verbatim into your keyboard.vhd and build your translation against the `m65_*` names, never against bare numbers. Budget real design time for the *mapping policy* (which MEGA65 key means what on your target machine); document it in a table in the file header like the Amiga port does (AExp keyboard.vhd:48-60), because users WILL ask.

**S63 - Joysticks and paddles.** The framework's joystick ports are active-low and pre-debounced; map directions and fire straight onto the core's inputs, minding the core's own polarity. The Amiga case is typical: Minimig's `_joy` ports are also active-low with the layout `{...,fire2,fire,up,down,left,right}`, so the mapping is a plain concatenation with unused buttons idled high - `joy1_n <= "1111111111" & '1' & joy_1_fire_n_i & joy_1_up_n_i & joy_1_down_n_i & joy_1_left_n_i & joy_1_right_n_i;` (Amiga port, CORE/vhdl/main.vhd:456). If the core wants active-high, invert per signal - never blanket-invert a vector that mixes buttons and reserved bits. Drive the `joy_*_n_o` outputs (loop the inputs back if the core never drives the port - the C64 needs the outputs because CIA writes can pull joystick lines). Paddles arrive as four 8-bit unsigned values (`pot1_x_i` etc.); cores expecting MiSTer's `paddle_*`/`pd_*` analogue format can usually take them unchanged, cores emulating capacitor-discharge POT inputs (the C64 SID) need the reference port's converter logic. Tie unused joystick ports of the core to all-inactive (Minimig `_joy3/_joy4 => x"FFFF"`).

**S64 - Video polarity: ACTIVE-HIGH syncs toward the framework.** **RULE:** `video_hs_o` and `video_vs_o` must be positive pulses. Both framework sinks state it: MiSTer's video_mixer as ported into M2M declares `// Positive pulses.` over its HSync/VSync/HBlank/VBlank inputs (M2M/vhdl/controllers/MiSTer/video_mixer.sv:42-46), and ascal receives them directly (`i_hs => video_hs_i, i_vs => video_vs_i`, M2M/vhdl/av_pipeline/digital_pipeline.vhd:322-323). Now check what your core outputs: most 80s machines produce active-LOW syncs, and MiSTer emu modules often invert them on the way into `sys/` - find that inversion (S57) and replicate it. Minimig outputs `_hsync/_vsync` active-low, so the Amiga port drives `video_hs_o <= not _hsync` (Amiga port, .research/INTEGRATION-SPEC-video-audio.md:19-20 documents the full evidence chain); the C64 routes the VIC-II syncs through the submodule's video_sync entity which already emits positive pulses plus matching blanks (C64MEGA65 CORE/vhdl/main.vhd:1236-1248). **TRAP:** wrong sync polarity does not give you "no picture" - it gives you a *shifted, possibly rolling* picture on analog out and a confused ascaler on HDMI, which wastes debugging hours on the wrong suspects.

**S65 - Blanking: both blanks must fully cover their syncs - there is no DE input.** The framework derives display enable itself: `i_de => not (video_hblank_i or video_vblank_i)` (M2M/vhdl/av_pipeline/digital_pipeline.vhd:325). Consequences: (1) you must output real `video_hblank_o`/`video_vblank_o` (active-high), not a DE you happen to have; (2) each blank must START at or before its sync's leading edge and END at or after its trailing edge - a sync pulse outside blanking puts sync-colored garbage into the active picture and breaks ascal's geometry detection; (3) blank widths define the visible window the scaler sees, so blanking that is too narrow shows overscan trash, too wide crops the picture. If the core only gives you syncs, generate blanks with a small counter-based sync/blank regenerator - that is exactly what the C64's `video_sync` module does (and note the warning at C64MEGA65 CORE/vhdl/main.vhd:1233-1235: use the SUBMODULE's video_sync, not a stale M2M copy). Minimig outputs proper Agnus blanks already, which pass through unmodified.

**S66 - video_ce_o: the NATIVE pixel clock enable, pre-scandoubler.** `video_ce_o` qualifies which `clk_main_i` cycles carry a pixel; the framework samples RGB/syncs/blanks only when it is '1'. It must pulse at the machine's native pixel rate (the rate at which the RGB outputs actually change), NOT at the post-scandoubler rate and NOT permanently '1' unless the pixel rate truly equals the core clock. Standard implementation: a small divider. The C64's pixel rate is core clock / 4, implemented as a free-running 2-bit counter with `video_ce_o <= '1' when video_ce = 0 else '0';` (C64MEGA65 CORE/vhdl/main.vhd:1253-1264). For non-integer ratios use the S53 fractional accumulator; for cores that already produce a `ce_pix`, you may pass it through after checking it is one-clock-wide pulses synchronous to `clk_main_i`. **TRAP:** the CE must be a clean 1-of-N qualifier, not a divided *clock* - never put a divided clock signal on `video_ce_o`, and never gate `clk_main_i` to make one.

**S67 - video_ce_ovl_o: the post-scandoubler / overlay rate.** The second CE clocks the framework's OSD overlay and the analog output stage, which run at the scan-doubled rate. Rule of thumb: `video_ce_ovl_o <= '1'` (full core clock) when the doubled pixel rate equals or exceeds what the overlay needs - both reference ports do this in the normal case; only the retro-15 kHz analog mode (no scandoubling, native line rate to the VGA port) halves it: `video_ce_ovl_o <= '1' when video_retro15khz_i = '0' else not video_ce(0);` (C64MEGA65 CORE/vhdl/main.vhd:1255-1256). The Amiga port, which fixes retro-15 kHz off for its first milestone, simply drives `video_ce_ovl_o <= '1'` (Amiga port, CORE/vhdl/main.vhd:564). If you do not plan 15 kHz output initially, hardwire '1' and revisit later.

**S68 - Respect the input width limits; frame-lock the CE if resolution switches mid-frame.** Two hard buffer limits bound what you may feed the pipeline: the video_mixer/scandoubler line buffer is `LINE_LENGTH = 768` pixels (parameter default, M2M/vhdl/controllers/MiSTer/video_mixer.sv:21; the M2M analog_pipeline instantiates it without override, analog_pipeline.vhd:134-157), and ascal's input line buffer is `IHRES => 1024` (M2M/vhdl/av_pipeline/digital_pipeline.vhd:312). **RULE:** per path: analog/scandoubler path <= 768 active pixels per line (LINE_LENGTH), HDMI/ascal path <= 1024 active pixels per line (IHRES), both counted at `video_ce_o` rate between blanks - never feed wider, exceeding either wraps silently into garbage. This constrains your CE choice for high-resolution modes: the Amiga's native 28 MHz "super-hires" sampling would produce ~1500 pixels per line and is therefore impossible; the port samples at 7.09 MHz (lores, 377 px) or 14.19 MHz (hires, 754 px - inside 768 with little headroom). And when the core can change resolution MID-FRAME (Amiga copper screen splits; comparable tricks exist elsewhere), a CE that follows the instantaneous mode would give one frame lines of different lengths, which neither scandoubler nor ascal can represent. The MiSTer-proven fix is a *frame-locked* CE: accumulate the highest resolution seen during the active frame, and switch the CE rate only at the start of vertical sync (the Amiga port transplanted this from Minimig.sv:653-675; Amiga port, CORE/vhdl/main.vhd:544-560: `fs_res <= fs_res or vid_res` during active video, latch `frame_hires` at the vsync edge, then `video_ce_o <= clk7_en or (clk7n_en and frame_hires)`). If your core has a fixed pixel rate, skip this; if not, budget for it from day one.

**S69 - Audio: signed 16-bit, and saturate anything wider.** `audio_left_o`/`audio_right_o` are `signed(15 downto 0)` (C64MEGA65 CORE/vhdl/main.vhd:117-118) at the core clock; the framework filters and resamples downstream (filter constants come from globals.vhd, section 2.7, S84). If the core's mixer is wider than 16 bits, do NOT just truncate or take the top bits - scale and *saturate*. The C64's 18-bit SID path is the worked example (`audio_processing_proc`, C64MEGA65 CORE/vhdl/main.vhd:1330-1356): build a 17-bit intermediate from the 18-bit source (sign + top 16), then clamp: if the two top bits disagree (`alm(16) /= alm(15)`), output sign-extended full-scale, else pass through. The comment explains why the headroom exists: MiSTer mixes SID + OPL + DAC + tape noise into the same sum, and the moment you add a second source the overflow becomes audible wrap-around without this clamp. If the core is narrower than 16 bits, left-justify (shift left, zero-fill LSBs) - the Amiga's Paula outputs 15 bits and the port forms `audio_left_o <= signed(aud_ldata & '0')` exactly like MiSTer does (Amiga port, CORE/vhdl/main.vhd:570-571). **TRAP:** the ports are SIGNED PCM; feeding unsigned samples produces a violently DC-offset signal that sounds like distortion and can pop speakers.

**S70 - LEDs, and close the phase.** Drive `drive_led_o` (on/off) and `drive_led_col_o` (24-bit RGB) with real information; the C64 convention is worth copying verbatim: LED green in normal operation, yellow while a write cache is dirty/being flushed, and ON whenever the core writes a virtual disk OR a flush is pending - `drive_led_col_o <= x"00FF00" when unsigned(cache_dirty) = 0 else x"FFFF00";` and `drive_led_o <= c64_drive_led when unsigned(cache_dirty) = 0 else '1';` (C64MEGA65 CORE/vhdl/main.vhd:555-561). This is not cosmetics: together with `prevent_reset` (S60) it is the user-visible half of the data-loss protection - the user learns "yellow = do not reset/power off". With S56-S70 done, main.vhd elaborates against the framework, the core boots blind (no ROMs yet, no video judgment until the Phase 11 hardware tests), and you have defined every port mega65.vhd must serve: memories (Phase 6) and OSM/ROM/drive services (Phase 7).

## 2.6 Phase 6 - Memories: BRAM, the QNICE side, HyperRAM

MiSTer cores get their memory from the HPS-managed DDR3 and from `ioctl` downloads; M2M gives you three substitutes: on-chip BRAM (fast, dual-ported, scarce - the MEGA65's Artix-7 xc7a200t has 365 36-kbit blocks, about 1.6 MB total, and the framework already uses some), the QNICE service CPU as the data source/sink for everything file-shaped, and 8 MB of HyperRAM for anything big or merely "RAM-shaped". This phase decides, for every memory in the core, where it lives and who can touch it.

**S71 - Learn the one building block: dualport_2clk_ram.** M2M's `M2M/vhdl/2port2clk_ram.vhd` (`entity dualport_2clk_ram`) is THE memory primitive of the framework; nearly every BRAM in both reference ports is an instance of it. Its generics (2port2clk_ram.vhd:14-24):

- `ADDR_WIDTH` (RAM size = 2**ADDR_WIDTH words) and `DATA_WIDTH` (word width);
- `MAXIMUM_SIZE` - caps the actual word count independently of ADDR_WIDTH, for non-power-of-two memories (saves BRAM when a device has, say, 40000 words addressed by a 16-bit bus);
- `ROM_PRELOAD : boolean` + `ROM_FILE : string` + `ROM_FILE_HEX : boolean` - build-time initialization from a file, `hread` (one hex byte/word per line) when ROM_FILE_HEX is true, `read` (binary textio) otherwise (S76);
- `FALLING_A` / `FALLING_B` - per-port clock edge selection; this innocuous-looking pair is the framework's CDC convention (S73).

Both ports are fully independent (own clock, address, data, write enable) and reads are synchronous with one cycle latency (S75). For byte-enabled wide memories there is the wrapper `dualport_2clk_ram_byteenable` (M2M/vhdl/2port2clk_ram_byteenable.vhd) which internally instantiates one 8-bit `dualport_2clk_ram` per byte lane and AND-gates `wren` with the lane's byteenable bit (2port2clk_ram_byteenable.vhd:37-48) - see S74 for when to use it versus splitting by hand.

**S72 - Decide where each memory lives.** The rule is access-driven:

- *QNICE must reach it* (ROM loading, disk buffers, anything the Shell reads/writes) -> the memory is instantiated in `mega65.vhd`, port A wired into the core clock domain (toward main.vhd via ports you add), port B wired to the QNICE device bus (`qnice_dev_*`) through the `core_specific_devices` process (section 2.7, S85). The Amiga port's Kickstart ROM, Chip RAM and Slow RAM all live in mega65.vhd this way (Amiga port, CORE/vhdl/mega65.vhd:590-700).
- *Private to the core* -> instantiate inside main.vhd or keep it inside the ported RTL (the C64's VIC color RAM, the drives' internal RAMs). No QNICE port, no mega65.vhd involvement.

The CDC between the domains is *by construction*: port A is clocked by `main_clk` on the rising edge, port B by the QNICE 50 MHz clock on the FALLING edge (`FALLING_B => true`), and true-dual-port BRAM hardware arbitrates the rest. There is no handshake and no synchronizer chain for the data path - the protocol discipline (QNICE only touches the memory while the core is in reset, or touches dedicated buffers) is supplied by the framework's Shell and by you (Part III, section F discusses why this is safe). **RULE:** port A = core, rising edge; port B = QNICE, falling edge. Do not invent other arrangements; all framework tooling assumes this shape (the comment block at Amiga port, CORE/vhdl/mega65.vhd:577-584 states it as the "M2M convention").

**S73 - Understand the falling-edge timing price - and only wire QNICE ports you NEED.** **Why** the falling edge exists: QNICE issues an address and expects data within the same QNICE cycle pattern the rest of its device bus uses; by clocking the BRAM port on the falling edge, the BRAM samples the address half a QNICE period (10 ns at 50 MHz) after QNICE launched it, and QNICE registers read data on its next rising edge, again half a period later. The convention costs nothing logically but means every QNICE-to-BRAM path must close timing in HALF a 50 MHz period: 10 ns from QNICE's address registers to the BRAM pins, through whatever routing the placer needed. For a small memory (a handful of BRAM tiles placed close together) that is trivial. For a big one it is not: **TRAP:** a QNICE port on a memory whose BRAM tiles spread across the die WILL fail timing. The Amiga port learned this with its 512 KB Chip RAM and 512 KB Slow RAM - 256 BRAM tiles spread over the whole die, and the QNICE address fanout missed the 10 ns half-period by -0.757 ns WNS on exactly those paths in the first synthesis run. The fix was architectural, not constraint-tweaking: Chip and Slow RAM do not need QNICE access at all (nothing is ever file-loaded into them), so their port B was tied off completely, removing all QNICE-domain routing to those tiles; only the 256 KB Kickstart ROM (64 tiles, needed for the mandatory ROM auto-load) keeps its QNICE port - and that meets timing (Amiga port, CORE/vhdl/mega65.vhd:284-292, comment "Chip and Slow RAM deliberately have NO QNICE port ... first R3 run: WNS -0.757 ns on exactly these paths"). Generalize: wire a QNICE port ONLY where QNICE has actual business; every unnecessary falling-edge port is free timing risk.

**S74 - 16-bit cores: split byte-enabled memories into two 8-bit lanes, big-endian.** A 68000-style core writes bytes via upper/lower data strobes into 16-bit memory. Two implementation options: the `dualport_2clk_ram_byteenable` wrapper (S71), or explicit lane splitting - two `dualport_2clk_ram` instances with `DATA_WIDTH => 8`, lane U carrying data bits 15:8 and lane L bits 7:0, with separate write enables (`... and not main_ram_bhe_n` / `... and not main_ram_ble_n`). The Amiga port splits explicitly (Amiga port, CORE/vhdl/mega65.vhd:11-12 and 590-626), and the reason to prefer this over the wrapper when QNICE is involved is the *byte addressing on the QNICE side*: QNICE is an 8/16-bit CPU loading a raw big-endian ROM dump byte by byte. Map QNICE's byte address so that the EVEN byte goes to lane U (bits 15:8) and the ODD byte to lane L - big-endian lane mapping, matching the 68000's memory order - and a raw Kickstart image loads unmodified, no byte swapping anywhere: `qnice_kick_we_u <= ... and not qnice_dev_addr_i(0); qnice_kick_we_l <= ... and qnice_dev_addr_i(0);` (Amiga port, CORE/vhdl/mega65.vhd:565-566). **TRAP:** get the lane polarity wrong and everything still synthesizes and loads - the core just executes byte-swapped garbage; on a 68000 the symptom is an immediate illegal-instruction halt, easily misdiagnosed as a CPU bug.

**S75 - Budget the read latency against the core's bus timing.** `dualport_2clk_ram` reads are synchronous: address sampled at the clock edge, data valid after the next edge - one core-clock cycle of latency. Asynchronous (combinational-read) RAM does not exist in BRAM; if the original core used Quartus distributed/latch-style memory with same-cycle reads, you must either find slack in the bus protocol or pipeline. Do the worked reasoning the Amiga port documents (Amiga port, CORE/vhdl/mega65.vhd:580-583): the chipset presents a stable address from the start of each 7.09 MHz bus cycle; the consumer samples read data in the second half of that cycle; one 28.375 MHz clock of BRAM latency (35 ns) fits inside the first half (70 ns) with margin - so a 1-cycle synchronous BRAM is a drop-in for the original asynchronous SRAM. Run this analysis for every memory you re-home: cycle structure of the consumer, when the address is guaranteed stable, when data is sampled, how many fast-clock cycles fit between. If it does not fit, options in order of preference: serve the memory at a higher clock-enable phase (many cores have a 2x or 4x master clock precisely for this), add a wait state if the bus supports it, or keep the memory as LUT RAM (`ram_style = "distributed"`) if it is small.

**S76 - Build-time ROMs: preload from .hex, with paths relative to the synthesis run.** For ROMs that never change (character generators, drive ROMs, boot ROMs you are licensed to embed), use `ROM_PRELOAD => true, ROM_FILE => "<path>", ROM_FILE_HEX => true` and commit a plain-hex conversion of the ROM (one byte per line for 8-bit memories; conversion recipes in Part III, section G). The path gotcha: Vivado resolves relative paths from the *synthesis run directory* (`CORE/CORE-R6.runs/synth_1` or similar), NOT from the source file. Hence the C64 convention of prefixing `../../` to climb back to `CORE/` and then into the submodule: `.INITFILE("../../C64_MiSTerMEGA65/rtl/iec_drive/c1541_rom.mif.hex")` (C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/c1541_multi.sv:183). **TRAP:** a wrong path is not an error - Vivado happily synthesizes an all-zero ROM and you chase a "dead CPU" on hardware. Check the synthesis log for the file actually being read. Note also what NOT to preload: ROMs the user must supply (Kickstart!) are loaded at runtime by QNICE (section 2.7, S86) into a RAM-shaped `dualport_2clk_ram` without preload; simulation testbenches can still preload the same entity for speed. Hybrid pattern: when a free replacement ROM exists (open-source GB boot ROM, AROS), preload it via `ROM_PRELOAD` and declare the same device as a `C_CRTROMTYPE_OPTIONAL` auto-load - users with the original ROM on SD get it loaded over the preload at startup; users without it still get a working core.

**S77 - HyperRAM for big or slow data: the hr_core Avalon master.** Anything too big for BRAM (REU expansion memory, cartridge images, large track buffers) goes to the 8 MB HyperRAM. Your access point is the `hr_core_*` port group that mega65.vhd exposes upward into the framework: a 16-bit Avalon-MM master with burst support, clocked at `hr_clk` = 100 MHz (`hr_core_write/read/address/writedata/byteenable/burstcount/readdata/readdatavalid/waitrequest`, C64MEGA65 CORE/vhdl/mega65.vhd:75-83). Inside the framework this master is arbitrated against the OTHER HyperRAM clients - the ascaler's frame buffers and QNICE - by `avm_arbit_general` (M2M/vhdl/framework.vhd:684-699: `hr_dig_* & hr_core_* & hr_qnice_*`). Consequences: you do not own the HyperRAM, you share it; your worst-case latency includes the scaler's bursts, so design client logic latency-tolerant (honor `waitrequest`, use `readdatavalid`, never assume fixed timing). Addresses are 16-bit-word addresses; partition the 8 MB via `C_HMAP_*` constants in globals.vhd, following the C64 layout: `C_HMAP_M2M = x"0000"` (first 4 MB reserved for the framework/ascal), then your regions, e.g. `C_HMAP_CRT = x"0200"`, `C_HMAP_REU = x"03BF"`, with `C_HMAP_SIZE = x"0400"` marking the 8 MB top and the final 8 kB kept as a burst guard (C64MEGA65 CORE/vhdl/globals.vhd:97-100). **RULE:** never allocate below the M2M region; the ascaler will overwrite you.

**S78 - Bridge your core to hr_clk with the avm_fifo + avm_cache pattern.** Your core-side client runs at `clk_main`; the HyperRAM at 100 MHz. The C64's REU chain is the canonical three-stage recipe, documented in-source (C64MEGA65 CORE/vhdl/main.vhd:1592-1599): (1) a protocol adapter turning the core's native memory interface into Avalon-MM (`reu_mapper`, main.vhd:1601, with `G_BASE_ADDRESS` placing it in the C_HMAP region); (2) `avm_cache` in the CORE clock domain to coalesce and prefetch so that sequential accesses do not each pay the full HyperRAM+arbiter latency (main.vhd:1625, `G_CACHE_SIZE => 8`); (3) `avm_fifo` doing the actual CDC from `main_clk` to `hr_clk` via `xpm_fifo_axis` (instantiated in mega65.vhd: `main2hr_avm_fifo`, C64MEGA65 CORE/vhdl/mega65.vhd:1052-1084, `s_clk_i => main_clk_o, m_clk_i => hr_clk_i`). All blocks are stock M2M (`M2M/vhdl/memory/avm_fifo.vhd`, `avm_cache.vhd`). If you have several HyperRAM clients of your own (the C64: REU + CRT cacher), merge them with your own `avm_arbit` instance in mega65.vhd before driving `hr_core_*` (C64MEGA65 CORE/vhdl/mega65.vhd:453-489). **TRAP:** put the cache on the CORE side of the FIFO (cache hits must not cross the CDC), and put nothing combinational between the FIFO and `hr_core_*` - the framework arbiter assumes registered Avalon behavior.

## 2.7 Phase 7 - Replace the HPS services

On MiSTer, the ARM-side Linux (HPS) provides the OSD menu, ROM/file loading, disk-image mounting, configuration persistence, and core configuration. M2M replaces all of it with the QNICE service CPU running the Shell firmware, configured almost entirely through two VHDL files: `config.vhd` (everything the user sees) and `globals.vhd` (everything the hardware needs to know), plus the device-decode process in `mega65.vhd` and, where needed, a few assembler callbacks in `CORE/m2m-rom/m2m-rom.asm`. This phase replaces each `hps_io`/`CONF_STR` service one by one. Work with the C64 files open in a second window; they exercise every mechanism described here.

**S79 - config.vhd: build the OSM menu (OPTM_SIZE / OPTM_ITEMS / OPTM_GROUPS).** The menu is defined by three constants that MUST stay consistent (C64MEGA65 CORE/vhdl/config.vhd:370-386):

- `OPTM_ITEMS : string` - the visible text, one menu line per `\n`-terminated substring. **RULE** (verbatim from the source, config.vhd:371-375): "End each line (also the last one) with a \n and make sure empty lines / separator lines are only consisting of a \n. Do use a lower case \n. If you forget one of them or if you use upper case, you will run into undefined behavior." And: "Start each line that contains an actual menu item (multi- or single-select) with a Space character, otherwise you will experience visual glitches."
- `OPTM_SIZE : natural` - the total number of lines INCLUDING empty/separator lines; must equal both the number of `\n` lines in OPTM_ITEMS and the element count of OPTM_GROUPS (the C64: 110, config.vhd:376).
- `OPTM_GROUPS : OPTM_GTYPE` - one integer per line, position-matched 1:1 to OPTM_ITEMS. Each entry is a *group ID* (your own constants, e.g. `OPTM_G_MOUNT_8 : integer := 1`, config.vhd:514) OR-combined (`+`) with attribute flags (S80). Group semantics: lines sharing a group ID form a radio (multi-select) group of which exactly one is active; group IDs are user-defined starting at 1, maximum 254 (0 = "no menu item" for text/lines, 255 = Close), and **must be monotonically increasing down the menu**; single-select (toggle) items and drive-mount items need their own unique IDs (the rules verbatim in the template comment kept by the Amiga port, CORE/vhdl/config.vhd:324-328). Study the C64's full array (config.vhd:536-onward) - it demonstrates every construct: headline + line, mount item, load items, toggles, radio groups, submenus.

There is no parser protecting you: a missed `\n`, a group count mismatch, or a non-monotonic ID produces garbled menus or Shell crashes at runtime, not synthesis errors. Change the menu in small steps and retest.

**S80 - The OPTM_G_* attribute flags and menu geometry.** The flag constants are framework ABI - "DO NOT TOUCH" (C64MEGA65 CORE/vhdl/config.vhd:339-357): `OPTM_G_TEXT` 16#00000# (unselectable text), `OPTM_G_CLOSE` 16#000FF# (the "Close Menu" line), `OPTM_G_STDSEL` 16#00100# (selected by default - the factory default for SAVE_SETTINGS), `OPTM_G_LINE` 16#00200# (separator), `OPTM_G_START` 16#00400# (initial cursor position - use exactly once), `OPTM_G_HEADLINE` 16#01000#, `OPTM_G_SINGLESEL` 16#08000# (on/off toggle), `OPTM_G_MOUNT_DRV` 16#08800# (mount a disk image; the FIRST occurrence in the menu is virtual drive 0, the second drive 1, ...), `OPTM_G_HELP` 16#0A000# (first occurrence shows WHS(1), second WHS(2), ...), `OPTM_G_SUBMENU` 16#0C000# (marks both the entry line in the main menu AND the closing line of the submenu block), `OPTM_G_LOAD_ROM` 16#18000# (first occurrence = manual ROM 0, second = ROM 1, ... - the positional link to `C_CRTROMS_MAN`, S87). Lines of type MOUNT_DRV, LOAD_ROM and the saving indicator contain a `%s` placeholder that the Shell replaces at runtime with `OPTM_S_MOUNT` ("<Mount Drive>"), `OPTM_S_CRTROM` ("<Load>"), `OPTM_S_SAVING` ("<Saving>") or the mounted/loaded filename (config.vhd:367-369 and the ` 8:%s\n` line at config.vhd:395).

Geometry: `OPTM_DX`/`OPTM_DY` are the NET menu size in characters; the frame adds two more in each direction. **TRAP** (submenu visibility counting, config.vhd:382): "Without submenus: Use OPTM_SIZE as height, otherwise count how large the actually visible main menu is" - with submenus, OPTM_DY is the number of lines of the MAIN menu view only (submenu lines replace the main menu when open, they do not add height); the C64 has OPTM_SIZE 110 but OPTM_DY 31 (config.vhd:383-384). An OPTM_DY larger than what fits the screen, or wider OPTM_DX than your longest line + 1, gives clipped or glitched rendering.

**S81 - Menu bit positions ARE line numbers: define C_MENU_* constants in mega65.vhd.** The Shell exports the menu state as a 256-bit vector (`qnice_osm_control_i` in the QNICE domain, `main_osm_control_i` CDC-ed into the core domain). Bit n of that vector is the selected-state of the ZERO-BASED line n of OPTM_ITEMS - counting EVERY line, including headlines, separators and empty lines. Define one named constant per consumed line in mega65.vhd and never use bare numbers; the C64's block (C64MEGA65 CORE/vhdl/mega65.vhd:321-364) maps its whole menu: `constant C_MENU_EXP_PORT_HW : natural := 7; ... constant C_MENU_KERNAL_JIFFY : natural := 49; constant C_MENU_HDMI_16_9_50 : natural := 58; ...`. **TRAP:** inserting one menu line shifts every constant below it - update them all (this is the single most common OSM bug; the Amiga port keeps the same convention with a comment "zero-based line numbers in config.vhd's OPTM_ITEMS" right at the constants, Amiga port CORE/vhdl/mega65.vhd:294-300). Decode the bits into core inputs; the canonical multi-bit example is the HDMI mode (C64MEGA65 CORE/vhdl/mega65.vhd:771-774):

```vhdl
qnice_video_mode_o <= C_VIDEO_HDMI_5_4_50   when qnice_osm_control_i(C_MENU_HDMI_5_4_50)  = '1' else
                      C_VIDEO_HDMI_4_3_50   when qnice_osm_control_i(C_MENU_HDMI_4_3_50)  = '1' else
                      C_VIDEO_HDMI_16_9_60  when qnice_osm_control_i(C_MENU_HDMI_16_9_60) = '1' else
                      C_VIDEO_HDMI_16_9_50;
```

**RULE:** use `qnice_osm_control_i` only for things consumed in the QNICE domain (framework controls like the video mode), and `main_osm_control_i` for everything routed into main.vhd - the framework has already done the CDC for you; do not mix domains.

**S82 - Welcome/help screens and the general settings block.** Help/welcome text lives in config.vhd as string constants assembled into `WHS_DATA` (C64MEGA65 CORE/vhdl/config.vhd:43-81, 200-208): set `WHS_RECORDS` (1..16; array position 0 is RESERVED for the welcome screen - if you only want help topics, leave position 0 empty) and `WHS_MAX_PAGES` (1..256 pages per topic); write each screen as a string constant (`SCR_WELCOME`, `HELP_1`, ...), concatenate them (`constant WHS_DATA : string := SCR_WELCOME & HELP_1 & HELP_2 & HELP_3;`) and compute each start offset with VHDL `'length` arithmetic - `HELP_1_START := SCR_WELCOME'length; HELP_2_START := HELP_1_START + HELP_1'length;` (config.vhd:206-208) - then fill the `WHS` record array (page_count, per-page page_start/page_length). Menu lines flagged `OPTM_G_HELP` bind positionally: first such line shows WHS(1), second WHS(2) (S80).

The general settings (selector x"0110") in the same file:

- `RESET_COUNTER : natural := 100` - how long the Shell keeps the core's reset asserted at system start, in QNICE polling loops (C64MEGA65 config.vhd:248).
- `OPTM_PAUSE : boolean` - pause the core while the OSM is open. **RULE:** set true ONLY if your main.vhd actually implements `pause_i` (S58); the C64 has it `false` (config.vhd:251), and so does the Amiga port, with the reason documented: "minimig has no clean pause point" (Amiga port, CORE/vhdl/config.vhd:172-174). A true here with an unimplemented pause_i silently does nothing except confuse you later.
- `WELCOME_ACTIVE` / `WELCOME_AT_RESET : boolean` - show the welcome screen at power-on / additionally after every reset (config.vhd:254-258).
- `ASCAL_USAGE` / `ASCAL_MODE : natural` - HDMI scaler policy: ASCAL_USAGE 0 = fix the mode to the ASCAL_MODE constant, 1 = leave it to custom QNICE code, 2 = sync it with the core's `ascal_mode_i` input, i.e. menu-controlled (C64MEGA65 config.vhd:270-277; the C64 uses 1 because its m2m-rom.asm drives the filter selection itself).
- `SAVE_SETTINGS : boolean` + `CFG_FILE : string` - OSM persistence on SD card (config.vhd:279-283 and 236). The mechanics are strict: the file must already exist and be EXACTLY OPTM_SIZE bytes long, else settings are not saved; a first byte of 0xFF means "use the OPTM_G_STDSEL defaults". Create the file with `M2M/tools/make_config.sh` and ship it with your release. **TRAP:** "If SAVE_SETTINGS is true and OPTM_SIZE changes: Make sure to re-generate and re-distribute the config file" (config.vhd:378-379) - a stale config file of the wrong length silently disables persistence, and one of the RIGHT length but from an older menu layout applies the wrong bits to the wrong lines. The C64 sidesteps the second failure mode by versioning the filename: `CFG_FILE := "/c64/c64mega65-" & CORE_VERSION` (config.vhd:236).
- Also here: `VD_ANTI_THRASHING_DELAY` and `VD_ITERATION_SIZE` for virtual drives (S89).

**S83 - globals.vhd: the hardware-facing constants.** `CORE/vhdl/globals.vhd` tells the framework what your core IS. Walk every section:

- `CORE_CLK_SPEED` - the exact achieved core clock in Hz (S55; C64MEGA65 CORE/vhdl/globals.vhd:47-50). Fed to main.vhd as `clk_main_speed_i`.
- `VGA_DX` / `VGA_DY` - the core's output resolution as seen AFTER the scandoubler, i.e. the resolution `video_ce_ovl_o` corresponds to; this sizes the OSM video RAM and the analog timing (C64: 720x540, globals.vhd:69-70; Amiga port: 720x576). Rule of thumb for MiSTer cores: twice the native machine resolution per axis (HDMI is auto-scaled to 720p regardless).
- `QNICE_FIRMWARE` - leave at the M2M release ROM; the alternative monitor ROM is for QNICE-level debugging.
- Device IDs for everything QNICE-addressable - your own constants from x"0100" upward, IDs x"0000"-x"00FF" are framework-reserved: the C64 declares `C_DEV_C64_RAM x"0100", C_DEV_C64_VDRIVES x"0101", C_DEV_C64_MOUNT x"0102", C_DEV_C64_CRT x"0103", C_DEV_C64_PRG x"0104", C_DEV_C64_KERNAL_C64 x"0105", C_DEV_C64_KERNAL_C1541 x"0106"` (globals.vhd:85-91). Reserve IDs even for devices you have not built yet (the Amiga port keeps `C_DEV_AMIGA_CHIP`/`C_DEV_AMIGA_SLOW` reserved although they have no QNICE port, S73).
- Virtual-drive constants `C_VDNUM`, `C_VD_DEVICE`, `C_VD_BUFFER` (S88) and the CRT/ROM declarations `C_CRTROMS_MAN*`, `C_CRTROMS_AUTO*` (S86/S87).
- `C_HMAP_*` HyperRAM partitioning (S77).
- The audio filter constants (S84).

**S84 - Audio filter constants: copy from sys_top, and mind the template typo.** The framework's audio post-processing (the same IIR filter chain MiSTer uses) is parameterized by `audio_flt_rate, audio_cx, audio_cx0/1/2, audio_cy0/1/2, audio_att, audio_mix` in globals.vhd (C64MEGA65 CORE/vhdl/globals.vhd:191-200). Source of truth: the `sys_top.v` of the MiSTer core you are porting - copy its default filter coefficients. **TRAP:** the M2M template (and the C64 port) carry `audio_cx1 = 2`, but MiSTer's sys_top default is `cx1 = 3` (the binomial 1,3,3,1 low-pass); the Amiga port spotted and fixed this, documenting it as an apparent template typo (Amiga port, CORE/vhdl/globals.vhd:162-170: "cx1=3 per MiSTer sys_top (binomial 1,3,3,1); the M2M template and C64MEGA65 carry cx1=2, which appears to be a template typo"). Verify against YOUR core's sys_top rather than trusting either template.

**S85 - mega65.vhd: the core_specific_devices process.** Every QNICE-addressable device you declared in S83 must be decoded in exactly one place: the `core_specific_devices` process in mega65.vhd. The pattern is fixed (C64MEGA65 CORE/vhdl/mega65.vhd:805-881; Amiga port, CORE/vhdl/mega65.vhd:553-575):

```vhdl
core_specific_devices : process(all)
begin
   -- make sure that this is x"EEEE" by default and avoid a register here by having this default value
   qnice_dev_data_o <= x"EEEE";
   qnice_dev_wait_o <= '0';
   -- default-assign every write-enable/strobe you drive below
   qnice_kick_we_u  <= '0';
   qnice_kick_we_l  <= '0';

   case qnice_dev_id_i is
      when C_DEV_AMIGA_KICK =>
         qnice_kick_we_u <= qnice_dev_ce_i and qnice_dev_we_i and not qnice_dev_addr_i(0);
         qnice_kick_we_l <= qnice_dev_ce_i and qnice_dev_we_i and     qnice_dev_addr_i(0);
         if qnice_dev_addr_i(0) = '0' then
            qnice_dev_data_o <= x"00" & qnice_kick_q_u;
         else
            qnice_dev_data_o <= x"00" & qnice_kick_q_l;
         end if;
      when others => null;
   end case;
end process core_specific_devices;
```

(the case body shown is the Amiga Kickstart device, mega65.vhd:559-572). Rules baked into the pattern: it is COMBINATIONAL (`process(all)`, no clock - the falling-edge registering happens inside the RAMs and the framework); `qnice_dev_data_o` defaults to x"EEEE" so unmapped reads return the framework's "empty" marker without inferring a latch or a register; every write strobe gets a '0' default before the case; the case selects on `qnice_dev_id_i` with your `C_DEV_*` constants; `qnice_dev_addr_i` is the 28-bit address within the device (4k-window selector in the upper bits, offset in the lower 12 - mostly you just slice the bits your RAM needs). For devices with handshaking (loader CSRs, vdrives) you also route `qnice_dev_wait_o`.

**S86 - Automatic ROM loading at boot (C_CRTROMS_AUTO).** For ROMs the user must provide (Kickstart, system ROMs you may not distribute) and optional enhancement ROMs, the Shell loads files from SD card into your devices at every system start, WHILE THE CORE IS STILL HELD IN RESET - the un-reset happens only after all auto-loads completed, so the core never sees a half-loaded ROM. Declaration in globals.vhd as flat 4-tuples in `crtrom_buf_array`, terminated by x"EEEE" (the `crtrom_buf_array`/`vd_buf_array` types and all `C_CRTROMTYPE_*` constants ship in the template's globals.vhd boilerplate - keep them and only edit the `C_CRTROMS_*` values):

1. storage type: `C_CRTROMTYPE_DEVICE` (stream into a QNICE device = your BRAM, S85) or `C_CRTROMTYPE_HYPERRAM` (stream into HyperRAM; the second element is then the start 4k-window instead of a device ID);
2. device ID or HyperRAM window;
3. `C_CRTROMTYPE_MANDATORY` or `C_CRTROMTYPE_OPTIONAL`;
4. the start offset of the filename within `C_CRTROMS_AUTO_NAMES`.

`C_CRTROMS_AUTO_NAMES` is one concatenated string of FAT32 paths, EACH terminated with `& ENDSTR` (the NUL character), and the offsets are computed with `'length` arithmetic exactly like the WHS pages. The two reference declarations show both modes. Mandatory (Amiga port, CORE/vhdl/globals.vhd:146-152):

```vhdl
constant KICK_ROM_NAME        : string := "/amiga/kick.rom" & ENDSTR;
constant KICK_ROM_NAME_START  : std_logic_vector(15 downto 0) := x"0000";
constant C_CRTROMS_AUTO_NUM   : natural := 1;
constant C_CRTROMS_AUTO_NAMES : string  := KICK_ROM_NAME;
constant C_CRTROMS_AUTO       : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_AMIGA_KICK,
                                                      C_CRTROMTYPE_MANDATORY, KICK_ROM_NAME_START,
                                                      x"EEEE");
```

Optional, two files (C64MEGA65 CORE/vhdl/globals.vhd:171-180): `JIFFY_DOS_C64 := "/c64/jd-c64.bin" & ENDSTR;` ... `JIFFY_DOS_C1541_START := std_logic_vector(to_unsigned(JIFFY_DOS_C64'length, 16));` with both 4-tuples carrying `C_CRTROMTYPE_OPTIONAL`. Semantics: a missing MANDATORY file produces a fatal error screen naming the missing file, and the core never starts - this is the right choice for a boot ROM, and it is exactly how the Amiga port implements the "core is useless without a Kickstart" policy; a missing OPTIONAL file is logged and skipped, and YOU must handle the absence gracefully (S91 shows the C64's PREP_START fallback). The loading itself is byte-wise: the Shell streams the file through the device's 4k windows (`M2M$RAMROM_4KWIN` increments every 4096 bytes), which is why the byte-lane mapping of S74 matters and why no header parsing happens unless your device implements a parser (S87). **RULE:** the framework does no consistency checking on the names string or the offsets - an off-by-one in a `'length` sum loads a file into the wrong device or fatals on a garbled filename (warning verbatim at C64MEGA65 globals.vhd:165-168).

**S87 - Manual ROM/cartridge loading via the OSM (C_CRTROMS_MAN + the CSR protocol).** Menu lines flagged `OPTM_G_LOAD_ROM` (S80) open the file browser; the Nth such line maps positionally to the Nth pair in `C_CRTROMS_MAN` - pairs of (storage type, device ID), x"EEEE"-terminated, `C_CRTROMS_MAN_NUM` of them (max 16). The C64 has two: the PRG loader and the CRT cartridge loader (C64MEGA65 CORE/vhdl/globals.vhd:147-149: `C_CRTROMTYPE_DEVICE, C_DEV_C64_PRG` and `C_CRTROMTYPE_DEVICE, C_DEV_C64_CRT`). Unlike auto-load ROMs, manual loads happen while the core RUNS, and the file content may need parsing (PRG load addresses, CRT chip packets) - so a manually-loadable QNICE device is more than a RAM: it must implement the Control-and-Status window protocol. The contract (M2M/vhdl/qnice_csr.vhd:67-77, the framework helper that implements it for you): the 4k window x"FFFF" of the device (`C_CSR_CASREG`) holds the CSR registers - offset 0x000 status (the Shell writes `C_CSR_REQ_LDNG` while streaming, then file size to 0x001/0x002 (FS_LO/FS_HI) and `C_CSR_REQ_OK` to the status when done), offset 0x010 the parser's response status (your device answers `C_CSR_RESP_PARSING`, then `C_CSR_RESP_READY` or `C_CSR_RESP_ERROR`), 0x011 an error code, 0x012/0x013 an address (loaders that relocate), and 0x100-0x1FF an error STRING the Shell displays verbatim to the user. Implement it by instantiating `entity work.qnice_csr` (M2M framework) next to your device decode and wiring its `qnice_req_*`/`qnice_resp_*` to your parser FSM - the C64's `sw_cartridge_csr.vhd` is a complete worked example (it wraps qnice_csr and bridges to the HyperRAM-based CRT parser; C64MEGA65 CORE/vhdl/sw_cartridge_csr.vhd:96-103 shows the request handshake `qnice_req_valid_o <= '1' when qnice_req_status = C_CSR_REQ_OK`), and `prg_loader.vhd` is the simpler BRAM-targeted one. The 0xFFFF window is also why your device's real address space must keep out of that window: device payload addressing uses windows 0x0000 upward, the CSR sits at the very top.

**S88 - Virtual drives: vdrives.vhd speaks MiSTer's sd_* protocol.** Disk images (floppy, hard disk, tape) are served by `M2M/vhdl/vdrives.vhd`, which "covers the virtual drives part of the MiSTer framework's hps_io.sv module ... so this module can be directly wired to the 'SD' interface of MiSTer's drives" (M2M/vhdl/vdrives.vhd:6-9). This is the single biggest porting shortcut in the framework: the MiSTer core's drive logic - `sd_lba`, `sd_blk_cnt`, `sd_rd`, `sd_wr`, `sd_ack`, `sd_buff_addr`, `sd_buff_dout`, `sd_buff_din`, `sd_buff_wr`, `img_mounted`, `img_readonly`, `img_size`, `img_type` - stays bit-compatible and unmodified; you connect it to vdrives exactly as `emu` connected it to `hps_io` (your S57 oracle shows you the wiring). Setup:

1. globals.vhd: `C_VDNUM` (number of drives, max 15), `C_VD_DEVICE` (the QNICE device ID of vdrives itself), `C_VD_BUFFER : vd_buf_array` (one device ID per drive for the image buffer, x"EEEE"-terminated) - C64: `C_VDNUM := 1; C_VD_DEVICE := C_DEV_C64_VDRIVES; C_VD_BUFFER := (C_DEV_C64_MOUNT, x"EEEE")` (C64MEGA65 CORE/vhdl/globals.vhd:114-116). If you have no drives yet, the documented "off" values are C_VDNUM 0, C_VD_DEVICE x"EEEE", C_VD_BUFFER (x"EEEE", x"EEEE") (globals.vhd:108-110).
2. Instantiate `entity work.vdrives` with `VDNUM => G_VDNUM` where the drives live - the C64 does it inside main.vhd (C64MEGA65 CORE/vhdl/main.vhd:1537-1539), with the QNICE clock passed down; generic `BLKSZ` sets the LBA block size (0..7 = 128..16384 bytes, default 2 = 512; M2M/vhdl/vdrives.vhd:118-119) - match your image format's natural sector size.
3. mega65.vhd: route `C_VD_DEVICE` to the vdrives QNICE port in `core_specific_devices`, and create one buffer RAM per drive under its `C_VD_BUFFER` device ID.
4. config.vhd: one `OPTM_G_MOUNT_DRV` menu line per drive (positional: first line = drive 0).

Mount flow at runtime: the user picks a file in the browser; the Shell streams the ENTIRE image into the drive's buffer device, writes size/read-only/type, then strobes that drive's `img_mounted_o` bit - MiSTer logic latches the metadata on that strobe, exactly as on MiSTer. From then on the core's reads (`sd_rd` + `sd_lba`) are served by the QNICE firmware out of the buffer RAM via `sd_ack`/`sd_buff_*` byte pumping, and writes go into the buffer. Where the buffer lives is your capacity decision: the C64 buffers a complete D64 in BRAM (`mount_buf_ram`, ADDR_WIDTH 18 with `MAXIMUM_SIZE => 197376` for the largest 40-track D64, C64MEGA65 CORE/vhdl/mega65.vhd:886-900 - note the in-source @TODO "Switch to HyperRAM at a later stage"); an Amiga ADF is 901120 bytes and would eat more than half the FPGA's BRAM, so larger formats belong in HyperRAM via a buffer device that forwards to the `hr_core_*` path (S77) or, milestone-permitting, you start with the BRAM variant for the smallest image type you support.

**S89 - Virtual drives: write-back, anti-thrashing, and the safety interlocks.** Core writes only dirty the RAM cache; the SD card is written in the background. Two config.vhd constants govern this (C64MEGA65 CORE/vhdl/config.vhd:285-302): `VD_ANTI_THRASHING_DELAY := 2000` - milliseconds of write inactivity before flushing starts, because every new core write invalidates the flush in progress; 2 s suits most systems, tune it if your machine's OS writes in long bursts - and `VD_ITERATION_SIZE := 100` - bytes written back per Shell loop iteration, keeping the OSM responsive during flushes. The hardware side exports `cache_dirty_o` and `cache_flushing_o` per drive (M2M/vhdl/vdrives.vhd:146-147), and you MUST close the safety loop you prepared in Phase 5: `cache_dirty` drives `prevent_reset` (S60) so a reset cannot corrupt a half-flushed image, and it drives the LED policy (S70) so the user can see when powering off would lose data. This triple - prevent_reset + LED color + anti-thrashing delay - is the complete data-integrity story; implement all three or none.

**S90 - Plumbing recap: keyboard, joystick, paddle paths through mega65.vhd.** Phase 5 built the consumers; verify the supply chain once: the framework delivers keyboard (`kb_key_num_i`/`kb_key_pressed_n_i`), joysticks and paddles to mega65.vhd already debounced and already in the CORE clock domain - mega65.vhd just passes them through to main.vhd's ports, plus two policy outputs you control from the OSM if you wish: `qnice_flip_joyports_o` (swap physical ports 1/2 - wire it to a menu bit or tie '0') and the framework's keyboard/joystick connect bits in `M2M$CSR` that the Shell manages (keyboard and joysticks are disconnected from the core while the OSM is open, automatically). The only work left in this phase is OSM-driven options like the flip (the C64 wires `qnice_flip_joyports_o <= qnice_osm_control_i(C_MENU_FLIP_JOYS)`; the Amiga port ties it '0' for now, Amiga port CORE/vhdl/mega65.vhd:541). **TRAP:** do not add your own debouncing or synchronizers on these inputs - they are already clean and already synchronous to `main_clk`; double-synchronizing keyboard scan signals breaks the 1 kHz scan alignment of S62.

**S91 - m2m-rom.asm: the two callbacks you will actually use.** The QNICE firmware top-level `CORE/m2m-rom/m2m-rom.asm` is mostly boilerplate; two callbacks matter for a standard port:

- `FILTER_FILES` (C64MEGA65 CORE/m2m-rom/m2m-rom.asm:68-82): called by the file browser per directory entry; R8 = pointer to the zero-terminated name, R9 = 0 for files / 1 for directories; return R8 = 0 to show the entry, nonzero to hide it. Use the `M2M$CHK_EXT` helper to filter by extension (".d64", ".adf", ".rom") so users only see mountable files.
- `PREP_START` (C64MEGA65 CORE/m2m-rom/m2m-rom.asm:193-251): runs after settings and auto-ROMs are loaded but BEFORE the core is released from reset; return R8 = 0 for OK or an error-string pointer to go fatal. This is where you reconcile saved settings with reality. The C64's worked example is the JiffyDOS fallback: if the saved configuration selects the JiffyDOS Kernal (an OPTIONAL auto-ROM, S86) but the ROM files were not found (the firmware's `CRTROM_AUT_LDF` load-flags array reports it), PREP_START prints a warning to the debug console and flips the menu setting back to the standard Kernal via `M2M$GET_SETTING`/`M2M$SET_SETTING` (m2m-rom.asm:228-248) - so a missing optional ROM degrades gracefully instead of booting a core that expects ROM contents that never arrived. Pattern to copy for every OPTIONAL auto-ROM that has a menu switch.

Building the firmware is automated: Vivado's pre-synthesis hook assembles m2m-rom.asm; for iteration without synthesis run `CORE/m2m-rom/make_rom.sh` (S19) directly. (`CORE/make_qasm.sh` is a different, one-time helper: it only compiles the QNICE assembler binaries that make_rom.sh invokes.)

**S92 - When the core has its own host-command protocol: replicate the HPS with a small FSM.** Everything so far assumed the core consumes plain wires (option bits, sd_*, keycodes). Some cores instead expect the HPS to TALK to them through a command protocol - Minimig is the prime example: its `userio.v` is configured (chipset type, CPU type, memory sizes, floppy count, IDE, joystick modes) through an SPI-like word protocol on the `IO_UIO/IO_STROBE/IO_DIN/IO_WAIT` port, normally driven by MiSTer's `hps_ext.v`. Do NOT rip out the protocol receiver and hardwire the config registers - that is invasive surgery in upstream code you would re-do at every merge. Instead, leave the core's receiver untouched and write a small FSM that *replays* the configuration sequence the HPS would have sent. The Amiga port's `amiga_config.vhd` is the worked specimen (Amiga port, CORE/vhdl/amiga_config.vhd:1-15: "The MEGA65 has no HPS, so this small FSM replays the configuration sequence after every M2M reset, leaving rtl/userio.v completely UNTOUCHED"). The method generalizes:

1. *Reverse-engineer the protocol from the core's receiver*, not from the HPS source - the receiver defines what is actually required. The amiga_config header documents userio.v's framing rules line by line (enable low resets the protocol state; every strobed clock consumes one word, so the strobe must be exactly one clock wide; first word = command byte, payload words follow; which commands latch on which word) with citations into the upstream file (amiga_config.vhd:17-60).
2. *Find the latching window.* Config protocols often only take effect during reset or a specific state - Minimig copies the shadow registers into the live configuration only while the CPU is halted/reset, so the FSM must run its sequence inside that window, then release the CPU as the final command (the documented reason the FSM runs after every M2M reset).
3. *Drive the values from M2M sources*: hardcode the milestone-1 machine configuration first (the Amiga port fixes A500 OCS PAL, 68000, 512K+512K), then graduate the interesting fields to OSM menu bits (S81) once the core is stable.
4. Keep the FSM in the core clock domain in main.vhd, treat `IO_WAIT` as a real handshake even if "it can never assert", and re-run the sequence on every core reset.

The same pattern covers MiSTer cores with `hps_ext`-style sideband channels (RTC injection, status uploads): one FSM per protocol, upstream untouched, M2M data sources behind it.

With S79-S92 done, the port is functionally complete: the core boots its ROMs, mounts images, and every user-facing knob runs through the OSM. What remains is the project files, the first synthesis, the timing fight and the hardware bring-up - Phases 8 through 11, starting next chapter.

---

## 2.8 Phase 8 - The Vivado project files

At this point every source file is prepared: the machine RTL is Vivado-clean (Phase 3), clk.vhd, main.vhd and mega65.vhd are wired (Phases 4-5), memories are placed (Phase 6) and the QNICE/Shell side is configured (Phase 7). What remains before the first synthesis is to make the Vivado *project files* describe exactly that set of sources, with the correct per-file language settings, for all four MEGA65 board revisions. M2M V2.0.1 ships GUI-style `.xpr` projects (one per board: `CORE/CORE-R3.xpr`, `CORE-R4.xpr`, `CORE-R5.xpr`, `CORE-R6.xpr`), and the fastest, most reviewable way to maintain them is to treat the `.xpr` as what it is: a plain, hand-editable XML file. This chapter covers the structure, the one trap that can crash Vivado outright, the file-type conventions proven by the C64MEGA65 reference, and the discipline of keeping four near-identical projects in sync. The full `.xpr` anatomy reference lives in Part III, section H; this chapter is the workflow.

**S93 - Understand the .xpr structure before you edit it.** Open `CORE/CORE-R3.xpr` in a text editor. The relevant skeleton (everything else is boilerplate Vivado regenerates or ignores):

```xml
<Project Version="7" Minor="61" Path="...">
  <Configuration>
    <Option Name="Part" Val="xc7a200tfbg484-2"/>   <!-- MEGA65 = Artix-7 200T -->
    ...
  </Configuration>
  <FileSets Version="1" Minor="31">
    <FileSet Name="sources_1" Type="DesignSrcs" ...>
      <File Path="$PPRDIR/../M2M/QNICE/vhdl/alu_shifter.vhd">
        <FileInfo SFType="VHDL2008">
          <Attr Name="UsedIn" Val="synthesis"/>
          <Attr Name="UsedIn" Val="simulation"/>
        </FileInfo>
      </File>
      ... one File element per source ...
      <Config>
        <Option Name="TopModule" Val="mega65_r3"/>
      </Config>
    </FileSet>
    <FileSet Name="constrs_1" Type="Constrs" ...>   <!-- the .xdc files -->
    <FileSet Name="utils_1" Type="Utils" ...>        <!-- synth_pre.tcl lives here -->
  </FileSets>
  <Runs>
    <Run Id="synth_1" ... > ... </Run>
    <Run Id="impl_1" ... > ... </Run>
  </Runs>
</Project>
```

Key facts: `$PPRDIR` expands to the directory containing the `.xpr` (i.e. `CORE/`), so framework files are referenced as `$PPRDIR/../M2M/...` and your core files as `$PPRDIR/<Submodule>/rtl/...` and `$PPRDIR/vhdl/...` (compare C64MEGA65 CORE/CORE-R3.xpr:617, which references `$PPRDIR/C64_MiSTerMEGA65/rtl/dprom.vhd`). Each `<File>` carries a `<FileInfo>` with optional `SFType` (source file type) and `UsedIn` attributes. The top module is named in the `sources_1` `<Config>` (Amiga port: CORE/CORE-R3.xpr:1000); depending on how Vivado last saved the file it can *additionally* appear as a `TopModule` option inside the `<Runs>` section (the Amiga R4/R5/R6 files carry it twice, e.g. CORE-R4.xpr:994 and :1039) - when editing the top module name, grep for `TopModule` and change every occurrence, they must agree. `SourceMgmtMode` is `DisplayOnly` in the M2M projects, meaning Vivado does not rescan directories - the `<File>` list *is* the compile list, which is exactly what you want: files you exclude in Phase 2 stay excluded without deleting them from the fork.

**Why** edit the XML instead of using the GUI's "Add Sources" dialog? Because you have four projects to keep identical (S98), because a text diff of the change is reviewable and committable, and because adding ~60 files with per-file type settings through a GUI is slow and error-prone. The GUI remains useful for verifying the result (open the project, check the hierarchy resolves).

**S94 - Know the legal SFType tokens - the wrong ones crash Vivado.** This is the single most dangerous trap in this phase, because the failure mode is not an error message but a segfault of the Vivado process *while opening the project*:

**RULE:** the only values you may write for `SFType` are:

| Token | Meaning | Example in the wild |
|---|---|---|
| `SFType="VHDL2008"` | VHDL, 2008 mode | C64MEGA65 CORE/CORE-R3.xpr:617-618 (dprom.vhd) |
| `SFType="SVerilog"` | SystemVerilog parsing | C64MEGA65 CORE/CORE-R3.xpr:175-176 (reu.v) |
| *no SFType attribute* | inferred from extension: `.v` = Verilog-2001, `.sv` = SystemVerilog, `.vhd` = VHDL-93 | C64MEGA65 CORE/CORE-R3.xpr:91-92 (mos6526.v, plain `<FileInfo>`), :147 (hq2x.sv, plain) |

The "obvious" tokens `SFType="Verilog"`, `SFType="VHDL"` and `SFType="SystemVerilog"` are NOT legal, and Vivado's project parser does not validate them: it dereferences a null file-type object and the whole tool dies. The Amiga port hit exactly this (Vivado 2022.2): the project open aborts with a segmentation fault and the crash dump shows `HDDASrcFileType::getId` on a null `this` at the top of the native stack (on Linux look for the `hs_err_pid<N>.log` JVM crash file next to the journal, on Windows the equivalent crash popup; the journal/`vivado.log` ends mid-open with no error message). If you ever see Vivado die *while loading a project you just hand-edited*, suspect an SFType token first. The fix and the full story are recorded in the Amiga port's commit 9201048 ("Fix .xpr file-type tokens that crashed Vivado's project parser"); the proven-token table above is extracted from the working C64MEGA65 and M2M template projects.

**TRAP:** because the crash happens at project open, you cannot fix it from within Vivado - and a crashing project is easy to misdiagnose as a corrupted install or VM problem. Keep the `.xpr` under version control and diff against the last-known-good state before blaming the tool.

**S95 - Apply the file-type convention from the reference projects.** With the legal tokens known, this is the convention the C64MEGA65 reference and the M2M template use, and which the Amiga port adopted (commit d861f56):

1. **Every `.vhd` file gets `SFType="VHDL2008"`** - framework, QNICE, your CORE/vhdl files, and the submodule's VHDL, *including VHDL-93-era files with shared-variable true-dual-port RAM templates*. **Why:** strict VHDL-2008 (LRM rules) would demand `protected` types for shared variables, but Vivado's relaxed 2008 mode accepts the classic UG901 `shared variable ram : ram_t` TDP template with only a warning. The C64 project compiles `dprom.vhd` (shared variable at C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/dprom.vhd:51) as VHDL2008, and the Amiga port does the same with the Minimig `bram.vhd` (shared variables at CORE/Minimig_MiSTerMEGA65/rtl/bram.vhd:249 and :440 (Amiga port)). Expect and ignore the corresponding warnings (S104).
2. **`.sv` files get no SFType** - the extension already means SystemVerilog. C64MEGA65 CORE/CORE-R3.xpr:147 (hq2x.sv) and the Amiga project's fx68k entries follow this.
3. **`.v` files get no SFType** (Verilog-2001) - *except* files that contain SystemVerilog constructs despite the `.v` extension, which get `SFType="SVerilog"`. In C64MEGA65 these are exactly four: `rtl/reu.v` (CORE-R3.xpr:175) plus three M2M framework files, `M2M/vhdl/av_pipeline/audio_out.v` (:98), `M2M/vhdl/controllers/MiSTer/iir_filter.v` (:168) and `M2M/vhdl/controllers/MiSTer/scandoubler.v` (:189). The Amiga port inherits the same three framework entries and adds none of its own, because its Phase 3 sweep chose policy (b) of step S45: keep plain `.v` files Verilog-2001-clean.

This is also where your S45 decision materializes: whatever `-sv` list you recorded there becomes `SFType="SVerilog"` entries here. (The GUI-safe route for individual files: select the file in the Sources tab and change *Source File Properties > Type* - Vivado then writes the legal token itself. The error that tells you a `.v` file needed SystemVerilog parsing is typically `[Synth 8-2671] single value range is not allowed in this mode of verilog` at elaboration.)

**S96 - Script the file-list surgery.** The edit you need to perform is: remove the demo-core entries the M2M template ships (`M2M/vhdl/democore/*.vhd` - five files in the V2.0.1 template projects), and add your submodule's kept file list plus any new CORE/vhdl files. For the Amiga port that meant removing 5 entries and adding 57 (the 56 kept Minimig sources plus `amiga_config.vhd`), times four board files - nearly 250 edits. Do not do this by hand. The `<File>` elements are uniform, so either generate them textually or use an XML-aware script:

```python
#!/usr/bin/env python3
# add_sources.py - batch-edit an M2M .xpr file list (pattern, adapt paths)
import re, sys

FILE_TMPL = """      <File Path="$PPRDIR/{path}">
        <FileInfo{sftype}>
          <Attr Name="UsedIn" Val="synthesis"/>
          <Attr Name="UsedIn" Val="simulation"/>
        </FileInfo>
      </File>
"""

def entry(path, sftype=None):
    sf = f' SFType="{sftype}"' if sftype else ""
    return FILE_TMPL.format(path=path, sftype=sf)

xpr = open(sys.argv[1]).read()

# 1) remove democore entries (File element = 6 lines, non-greedy match)
xpr = re.sub(r'      <File Path="\$PPRDIR/\.\./M2M/vhdl/democore/.*?</File>\n',
             "", xpr, flags=re.S)

# 2) insert the new entries before the sources_1 <Config> block
new = "".join(entry(p, "VHDL2008") for p in VHDL_FILES) \
    + "".join(entry(p)            for p in VERILOG_AND_SV_FILES)
xpr = xpr.replace("      <Config>\n        <Option Name=\"DesignMode\"",
                  new + "      <Config>\n        <Option Name=\"DesignMode\"", 1)

open(sys.argv[1], "w").write(xpr)
```

(Adapt the anchor strings to your `.xpr`; `xml.etree.ElementTree` also works and was used for *verifying* the Amiga projects - parse, collect all `File` `Path` attributes, check each exists on disk and appears exactly once. That check caught nothing the day it was written and exists precisely so it stays that way.) Whichever route you take, finish with three mechanical checks before opening Vivado: (1) the XML still parses (`python3 -c "import xml.etree.ElementTree as ET; ET.parse('CORE-R3.xpr')"`), (2) every `Path` resolves on disk with `$PPRDIR` = the CORE directory, (3) every `SFType` value is one of the two legal tokens from S94 - grep for `SFType="` and eyeball the unique values.

**S97 - What stays untouched in the .xpr.** Three things the template put there must survive your surgery:

1. **The QNICE firmware pre-synthesis hook.** `m2m-rom/synth_pre.tcl` is listed in the `utils_1` fileset and wired as the synthesis pre-step: `<Step Id="synth_design" PreStepTclHook="$PPRDIR/m2m-rom/synth_pre.tcl"/>` (C64MEGA65 CORE/CORE-R3.xpr:1019; Amiga port CORE/CORE-R3.xpr:1082). It rebuilds `m2m-rom.rom` from the QNICE assembly before every synthesis. Keep it - but also pre-build the ROM manually (`cd CORE/m2m-rom && ./make_rom.sh`), because the hook shells out to bash and can fail silently on exotic setups (the Amiga port's Mac-host/VM-guest combination; see S101).
2. **The constraint fileset**: `MEGA65-R<X>.xdc` (board pins), `common.xdc` and your `CORE.xdc` (Amiga port CORE/CORE-R3.xpr:1005-1017). You will be editing `CORE.xdc` heavily in Phase 10, but the fileset structure stays.
3. **The part**: `xc7a200tfbg484-2` for all current boards.

**S98 - Keep all four board projects in sync.** **RULE:** every file-list or file-type change is applied identically to `CORE-R3.xpr`, `CORE-R4.xpr`, `CORE-R5.xpr` and `CORE-R6.xpr`, in the same commit. The *only* expected deltas between the four are board-specific:

- the M2M top-level wrapper source: `$PPRDIR/../M2M/vhdl/top_mega65-r3.vhd` vs `-r4`/`-r5`/`-r6` (Amiga port CORE/CORE-R3.xpr:938 vs CORE-R6.xpr:986),
- the `TopModule` option, in *both* places it occurs: `mega65_r3` vs `mega65_r4`/`mega65_r5`/`mega65_r6` (Amiga port CORE/CORE-R4.xpr:994 and :1039),
- the board constraint file: `MEGA65-R3.xdc` vs `-R4`/`-R5`/`-R6` (Amiga port CORE/CORE-R5.xpr:999),
- the audio/MAX10 HAL pair from S23: CORE-R3.xpr lists `M2M/vhdl/controllers/M65/max10.vhdl` and `M65/pcm_to_pdm.vhdl`, while CORE-R4/R5/R6.xpr list `M65/audio.vhd` instead (see 3.H.4 for the full table),
- incidental XML noise (element ordering, project `Path`, simulator options) that Vivado rewrites when it saves - harmless, but it makes naive whole-file diffs useless; diff the extracted `File Path` lists instead (`grep -o 'File Path="[^"]*"' CORE-R3.xpr | sort` against the same for R6).

**TRAP:** it is very easy to develop against one board's project and forget the other three - they elaborate-fail only when someone with that board tries to build. The Amiga port shipped exactly this bug: the first core commit updated only `CORE-R3.xpr`, leaving R4/R5/R6 with the template's democore list and none of the Minimig sources - guaranteed elaboration failure on the *current production board* (R6). It was caught by a scripted review and fixed in commit 0ca916d ("Review fixes: R4/R5/R6 project sync, ..."). Make the four-way sync part of your change ritual, and verify with the file-list diff above (expected output: zero lines once the per-board deltas are excluded).

**S99 - XPM libraries, if and only if you use them.** If your port instantiates Xilinx Parameterized Macros - `xpm_cdc_array_single` for quasi-static CDC is the common case, `xpm_fifo_*` another - synthesis must be told to load the XPM libraries, or every `xpm_*` instance black-boxes. In a Tcl flow that is one line, as the C64 build script shows: `set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO} [current_project]` (C64MEGA65 CORE/CORE-R6.tcl:9, used because c1541_multi.sv instantiates `xpm_cdc_array_single`). In project mode (.xpr) Vivado auto-detects XPM usage when (re)reading the sources - the Amiga project carries no XPM property and the run log shows the XPM XDCs applied (runme.log:1566); the manual `set_property XPM_LIBRARIES` line is required only in non-project Tcl flows like C64MEGA65's CORE-R6.tcl:9. If an `xpm_*` instance in your submodule's Verilog nevertheless black-boxes, set the property via the Tcl console and re-verify - it is harmless belt-and-braces. Note the asymmetry: the M2M *framework* uses `xpm_fifo_axis` inside its own VHDL and Vivado resolves XPM instantiated from VHDL through the `xpm` library clause without this property - the property question only arises for Verilog/SV instantiations in *your submodule*. The Amiga port needs none (its CDC uses the framework's VHDL primitives plus handwritten synchronizers), and after dropping a leftover unused `library xpm` clause (commit 7a78697) its projects carry no XPM configuration at all. If in doubt: grep your kept file list for `xpm_` - any hit in a `.v`/`.sv` file means you set the property.

**S100 - Commit the project files and prepare the handoff.** Commit the four `.xpr` files together with a message that states what changed in the file list (the Amiga port's history is the worked example: commits b7407a6, 9201048, d861f56, 0ca916d each describe one project-file aspect). If Vivado runs on a different machine than your editor (the Amiga setup: sources on a Mac, Vivado in a Parallels Windows/Linux VM), this commit is the handoff point - everything the Vivado side needs is now in the repository, including the pre-built `m2m-rom.rom`. Write down what you expect the first run to produce before you run it; that list is the next chapter.

## 2.9 Phase 9 - First synthesis and what the logs tell you

The first full synthesis is not a pass/fail event; it is a measurement. Even a "successful" run can hide a dead CPU (silently zero-initialized microcode ROM), a BRAM budget blown by auto-demotion, or constraints that never applied. This chapter is the reading protocol for the run outputs - what to look at, in what order, and which messages are signal versus noise. All examples are from the Amiga port's run 1 (the only specimen with a preserved log in this repository - C64MEGA65 does not ship its run logs); the messages are generic Vivado and transfer to any port.

**S101 - Elaborate before you synthesize.** *Open Elaborated Design* (or `synth_design -rtl` in Tcl) takes minutes; a full 200T synthesis plus implementation takes the better part of an hour. Every port/binding/type error that elaboration can catch is an order of magnitude cheaper there. Run the elaboration loop (Part II, step S47) until it is clean, *then* start the full run. Also re-verify the QNICE firmware is fresh: the `synth_pre.tcl` hook rebuilds `m2m-rom.rom` automatically, but it shells out and can fail silently on Mac-host/VM-guest setups - pre-build with `cd CORE/m2m-rom && ./make_rom.sh` and check the `.rom` is newer than `m2m-rom.asm` and `globals.vhd` (the Amiga port's standing pre-flight rule, doc/synthesis-handoff.md (Amiga port)).

**S102 - The handoff discipline when Vivado runs on another machine.** If your editing environment and your Vivado are separate (the Amiga setup: sources and AI tooling on a Mac, Vivado 2022.2 in a Parallels VM), turn every round-trip into a written contract: prepare everything on the source side, then request a *specific artifact list* back - not "tell me if it worked". The list that has proven sufficient:

| Artifact | Path | What it answers |
|---|---|---|
| Synthesis log | `CORE/CORE-R3.runs/synth_1/runme.log` | everything in S103-S106 |
| Utilization report | `CORE/CORE-R3.runs/impl_1/*_utilization_placed.rpt` | BRAM/LUT/FF budget (S107) |
| Timing summary | `CORE/CORE-R3.runs/impl_1/*_timing_summary_routed.rpt` | Phase 10, all of it |
| Route status | `CORE/CORE-R3.runs/impl_1/*_route_status.rpt` | fully routed? |
| Per-module utilization | Tcl: `report_utilization -hierarchical -file util_hier.rpt` on the routed design | which module eats which BRAM (S107) |

Plus, on failure, the full text of the messages pane. Write the expected-warning list (S105) into the handoff note *before* the run so the person (or agent) at the Vivado end can triage without you. The Amiga port's `doc/synthesis-handoff.md` (Amiga port) is a complete worked example of such a contract, including the "these MUST NOT appear" and "expected warnings, do not chase" sections.

**S103 - First grep: did the ROMs actually load?** Search the synthesis log for the `$readmem` confirmations:

```text
INFO: [Synth 8-3876] $readmem data file '../../Minimig_MiSTerMEGA65/rtl/fx68k/nanorom.mem' is read successfully
INFO: [Synth 8-3876] $readmem data file '../../Minimig_MiSTerMEGA65/rtl/fx68k/microrom.mem' is read successfully
```

(Amiga port, CORE/CORE-R3.runs/synth_1/runme.log:961 and :964; the source statements are fx68k.sv:2480/:2493.) **TRAP:** if a `$readmemb`/`$readmemh` file is *not* found, Vivado does not error out - it warns (`cannot open file ...`) and initializes the memory to all zeros. For a microcoded CPU like fx68k that means a bitstream that synthesizes, meets timing, loads, and executes nothing: a dead CPU with no error anywhere downstream. The same applies to VHDL textio-initialized ROMs (M2M's `tdp_ram.vhd` with `G_ROM_FILE`). **RULE:** for every init file in the design, positively confirm its "read successfully" line (or the absence of a "cannot open" warning) in every synthesis log, forever - a path that breaks when a file moves fails just as silently the second time. Note the path resolution subtlety: Verilog `$readmem` paths resolve relative to the synthesis run directory (`CORE/CORE-R3.runs/synth_1/`, hence the `../../` prefix above), while Vivado provably also searches the *source file's* directory for VHDL textio reads (the C64 port's `G_ROM_FILE="../font/Anikki-16x16-m2m.rom"` only resolves source-relative, yet its builds succeed). Belt and braces: make the path correct run-dir-relative *and* keep the file near the source.

**S104 - Second pass: the RAM inference reports.** The synthesis log contains "Block RAM: Final Mapping Report" and "Distributed RAM: Final Mapping Report" tables (Amiga port, runme.log:3262 and :3283). Read them against your Phase 6 memory plan - every planned BRAM must appear with the expected geometry. The Amiga port's table shows exactly the plan: six Amiga lanes (`chip_ram_u/l` 256Kx8 = 64 RAMB36 each, `slow_ram_u/l` the same, `kick_rom_u/l` 128Kx8 = 32 each, total 320 RAMB36), QNICE's 32Kx16 system RAM (16 RAMB36), the OSM VRAMs (RAMB18s), and the hq2x buffer. Three implementation classes to distinguish:

- **Block RAM** (RAMB36/RAMB18 columns nonzero): what you want for big memories.
- **Distributed RAM / LUTRAM** (`RAM64M`/`RAM32M` primitives in the distributed table): correct for small or sub-threshold memories (register files, FIFOs, the ascal polyphase tables), wasteful for big ones.
- **"Implemented as registers"** or absent from both tables: an inference failure - the memory became thousands of flip-flops or got dissolved. Almost always a coding-template problem (Part III, section A).

Then search for this warning:

```text
WARNING: [Synth 8-5835] Resources of type BRAM have been overutilized. Used = 760, Available = 730. Will try to implement using LUT-RAM.
```

(Amiga port, runme.log:3057 - note the units are RAMB18-equivalents, i.e. half-tiles: 760/2 = 380 tiles requested against 365 physical.) This is Vivado *auto-demoting* memories to LUTRAM to make the design fit. It is not fatal - the Amiga run 1 completed and booted with ~16.5 tiles demoted (ascal line buffers, Paula's floppy FIFO, the Denise color tables, costing ~4600 extra LUTs) - but it means your BRAM plan and reality disagree, the demotion choices are Vivado's, not yours, and the demoted memories now burn LUTs and routing in whatever clock domain they sit. Reconcile: either the budget was wrong (recount), or something inferred double-width by accident, or you must move a consumer to HyperRAM. The Amiga conclusion after run 1: BRAM is at true capacity (363.5/365 tiles placed), and *every future buffer must live in HyperRAM* (doc/synthesis-handoff.md, "Post-run-1 findings" (Amiga port)).

**S105 - Triage the warnings: the stop-list and the expected-list.** Process: zero CRITICAL WARNINGs is the bar (the Amiga run 1 had none; any critical warning - black boxes, multi-driven nets, constraint failures, inferred latches on real state - is a stop-and-fix before trusting the bitstream). Plain WARNINGs number in the hundreds (560 in Amiga run 1) and most are upstream code style. Build an expected-warnings list once, verify each entry once, and carry the list forward in your handoff note. The Amiga list (each verified harmless, doc/synthesis-handoff.md (Amiga port)):

- *Undriven nets that are genuinely unconnected upstream or at the top level*: `Synth 8-3848` on `rom_readonly` in minimig.v (inherited tie-off; the Kickstart BRAM is write-protected on the M2M side by construction), on ascal's unused `i_ldrm` inputs and the top level's `kb_tck_o`/JTAG pins (runme.log:1365-1389, all in framework files - present in every M2M port).
- *Use-before-declaration style* in old Minimig/MiSTer Verilog - legal, parsed fine, noisy.
- *Shared-variable warnings* on the VHDL TDP templates: `WARNING: [Synth 8-4747] shared variables must be of a protected type` on bram.vhd:249/:440 (runme.log:142-143) and on M2M's `tdp_ram.vhd`/`2port2clk_ram.vhd` - this is the expected price of the S95 "all VHDL as 2008" convention; the hardware is correct.
- *Unconnected-port warnings* on your wrapper instantiations (`minimig_m65`, `cpu_wrapper`): deliberate `open`/tie-offs from Phase 2's de-featuring.
- *Pruned logic and unused sequential elements* (`Synth 8-3332`, e.g. paula_uart's rx FSM, runme.log:3050): the synthesizer removing the subsystems you tied off - confirmation, not a problem.
- *Constant-driven outputs / trimmed registers* (`Synth 8-3936` on denise_colortable_ram_mf, runme.log:3058): consequences of tie-offs.
- *One black box that is fine*: `gamma_corr` inside M2M's video_mixer.sv sits in a `generate if (GAMMA)` branch with `GAMMA=0` - never elaborated, identical in the working C64MEGA65 project.

**RULE:** "expected" status is earned per-warning by reading the source, once - and then re-earned whenever the count changes between runs. A list you copy without verifying is how real regressions hide.

**S106 - "Constraints were found ... will be ignored for synthesis" is normal.** The log will contain blocks of:

```text
INFO: [Project 1-236] Implementation specific constraints were found while reading constraint
file [.../CORE/CORE.xdc]. These constraints will be ignored for synthesis but will be used in
implementation. Impacted constraints are listed in the file [.Xil/mega65_r3_propImpl.xdc].
```

(Amiga port, runme.log:1546-1564, covering MEGA65-R3.xdc, common.xdc, CORE.xdc and the XPM-internal tcl constraints.) This is Vivado deferring constraints that reference post-synthesis cell names (`*_reg` patterns, `set_max_delay` on specific registers) to implementation, where those cells exist. Your Phase 10 CDC constraints (written against `_reg` cells) will land in this bucket - the INFO is confirmation of correct staging, not a problem. What you *do* check: open the named `propImpl.xdc` once and confirm your constraints are in it rather than dropped with a `Constraints 18-xxxx` critical warning (an empty match - a pattern that found no cells - is silent in synthesis and only visible as a critical warning at implementation; see also S111).

**S107 - The utilization reports: totals and per-module.** From `*_utilization_placed.rpt` read three numbers: Block RAM Tile (the Amiga port: `363.5 / 365 = 99.59%`, mega65_r3_utilization_placed.rpt:106 (Amiga port)), Slice LUTs, and Registers. For *attribution* - which module eats what - request `report_utilization -hierarchical` on the open (routed or synthesized) design; the flat report cannot tell you whether the 64 RAMB36 went to chip RAM or to something inferring double. Reconcile against the Phase 6 budget line by line. The Amiga reconciliation: 320 tiles = the six Amiga lanes (exact, zero waste), 32 = QNICE ROM+RAM, ~11.5 = video pipeline/OSM, total 363.5 - and therefore re-enabling the de-featured IDE support (+8 RAMB36) provably does not fit in BRAM and must wait for HyperRAM-backed buffers. Write that conclusion down where the next milestone will find it (the Amiga port keeps it in doc/synthesis-handoff.md and repeats it in doc/next_tests.md (Amiga port)).

**S108 - The VM memory trap: close the implemented design before re-synthesizing.** Operational, learned the hard way (Amiga run 2a crashed; doc/synthesis-handoff.md "Run-2 OOM lesson" (Amiga port)): a routed xc7a200t design *open in the Vivado GUI* holds several gigabytes of resident memory. If you then hit "Run Synthesis", the synthesis child process competes with the GUI's loaded design for the VM's RAM; the failure signature is the synthesis log ending near completion with `out of memory allocating N bytes` and/or the child segfaulting - which looks deceptively like a design problem. **RULE:** in a memory-constrained VM, *File > Close Implemented Design* before relaunching synthesis, and size the VM generously (synthesis alone peaked at ~6.5 GB PSS / ~13 GB VSS in the Amiga run, runme.log:3054-3055). If the crash already happened: nothing is corrupted; close the design, re-run, expect identical results.

## 2.10 Phase 10 - Timing closure methodology

Your first fully-routed build will almost certainly fail timing. This is normal and - if you read the report correctly - usually cheap to fix: in an M2M port, the dominant cause of spectacular-looking timing failure is not slow logic but *unconstrained clock-domain crossings being timed as if they were synchronous*, plus the secondary damage those phantom paths cause. The Amiga port's two-run history is the worked example used throughout this chapter (it is the only port whose timing reports are preserved in-repo): run 1 came back with WNS -6.7 ns / TNS -1317 ns and looked catastrophic; the fix was about ten lines of XDC plus one architectural retreat, and run 2 closed at WNS +0.387 ns with zero failing endpoints out of 99468 (Amiga port, CORE/CORE-R3.runs/impl_1/mega65_r3_timing_summary_routed.rpt:153). The method below is written to generalize: it is the same triage that closed C64MEGA65, applied with more telemetry.

**S109 - Read the Design Timing Summary first, then the route status.** The timing summary report (`*_timing_summary_routed.rpt`, or *Reports > Timing > Report Timing Summary* on the open routed design) begins with one line of four numbers (Amiga port, mega65_r3_timing_summary_routed.rpt:147-153):

- **WNS** (worst negative slack, setup): the single worst path. Negative = at least one path fails setup.
- **TNS** (total negative slack): sum over all failing endpoints, with the **failing endpoint count** next to it. This is your damage estimate: WNS -6.7/TNS -1317 over hundreds of endpoints is a different disease than WNS -6.7 on three endpoints.
- **WHS/THS** (hold): worst/total hold slack. Hold failures are *fatal in hardware regardless of clock speed* - but in this flow you rarely cause them yourself; see S113 for how they arise indirectly.
- **WPWS/TPWS** (pulse width): min-period/pulse checks on clock primitives; failures here usually mean a clock is simply too fast for the part, not a routing problem.

All four must be non-negative before you trust the bitstream on hardware. ("All user specified timing constraints are met" appears at the top of the report when they are.) Also open `*_route_status.rpt` and confirm zero unrouted/error nets - a design can "complete" implementation with routing errors, and a timing report over a partially-routed design is fiction. One important nuance for spectacular failures: the worst paths' slack can be *route-dominated garbage* rather than honest logic delay (S113), so do not start optimizing logic based on WNS alone - classify first.

**S110 - Learn the report's three resolutions: clock tables, path groups, path detail.** Below the summary the report has, in order:

1. The **Clock Summary** - every primary and MMCM-generated clock with waveform and period (Amiga port, mega65_r3_timing_summary_routed.rpt:160-181: `main_clk` 35.242 ns/28.375 MHz, `qnice_clk` 20 ns, `hr_clk` 10 ns, `hdmi_clk` 13.468 ns ...). Sanity-check this against clk.vhd *every run*: a wrong MMCM setting shows up here first.
2. The **Intra Clock Table** (mega65_r3_timing_summary_routed.rpt:186) - per-clock WNS/TNS for paths that start and end in the same domain. These are your *real* speed problems: logic depth, fanout, placement.
3. The **Inter Clock Table** (:211) - one row per (source clock, destination clock) pair that has timed paths. **In an M2M port this table is where the phantoms live.** Any row between domains you *know* are asynchronous (core clock vs HyperRAM clock vs HDMI clock) represents paths Vivado is timing because nobody told it not to.

For any suspicious row, get the per-path detail: `report_timing -from [get_clocks A] -to [get_clocks B] -max_paths 20 -nworst 1` (or click through in the GUI). Anatomy of one path (real example, Amiga port, mega65_r3_timing_summary_routed.rpt:268-302):

```text
Slack (MET) :             3.806ns  (required time - arrival time)
  Source:                 i_framework/i_video_out_clock/MMCM/DCLK   (... clocked by clk {rise@0.000ns ... period=10.000ns})
  Destination:            i_framework/i_video_out_clock/cfg_di_reg[10]/CE
  Requirement:            10.000ns  (clk rise@10.000ns - clk rise@0.000ns)
  Data Path Delay:        5.978ns  (logic 0.821ns (13.734%)  route 5.157ns (86.266%))
  Logic Levels:           1  (LUT2=1)
  Clock Path Skew:        -0.045ns (DCD - SCD + CPR)
```

Read four things, always in this order: (1) the **Requirement** - is it the period you expect, or something absurd (see S112)? (2) the **Data Path Delay split** between logic and route - logic-dominated means too many LUT levels (an RTL problem), route-dominated means distance/congestion/detour (a placement or constraint problem; 86% route on 1 logic level, as above, is pure placement distance). (3) **Logic Levels** - on an Artix-7 -2 at the typical M2M clock rates, double-digit logic levels deserve a pipeline stage. (4) **Clock Path Skew / CPR** - normally small; large skew points at cascaded clocking or a clock routed as data.

**S111 - Triage: group the failures, do not read paths one by one.** With hundreds of failing endpoints, the unit of work is the *group*, not the path. Group by (source clock, destination clock) from the Inter/Intra tables, then within a group look at the **endpoint count**: a group whose failing endpoints number exactly a power of two or a bus width (8, 16, 24, 128 ...) and whose paths land in consecutively-indexed registers is *one structure* - one FIFO, one bus, one RAM port - and will be fixed by one constraint or one edit, no matter how bad its TNS looks. In the Amiga run-2 report you can still see the (now passing) signature of the run-1 phantom groups: `main_clk -> hr_clk`, 128 endpoints, and `hr_clk -> hdmi_clk`, 128 endpoints (mega65_r3_timing_summary_routed.rpt:221-222) - each "group" is exactly one 128-bit buffer-read register (ascal's Avalon data width, `N_DW = 128`: avl_dr/o_dr at M2M/vhdl/av_pipeline/ascal.vhd:381/:445), i.e. two constraints' worth of work for 256 endpoints. Sort your groups: (a) phantom inter-clock groups (S112) first - they are free fixes and their secondary damage (S113) inflates everything else; (b) then genuine intra-clock failures by TNS; (c) re-run analysis after (a) before investing in (b), because (b)'s numbers are probably polluted.

**S112 - Phantom inter-clock paths: recognize, identify the protocol, constrain honestly.** The recognition signature is a **tiny, sub-nanosecond requirement** on an inter-clock path: the Amiga run-1 failures between `main_clk` (28.375 MHz) and `hr_clk` (100 MHz) showed requirements of **44 ps**, and between `hr_clk` and `hdmi_clk` (74.25 MHz) **34 ps** (Amiga port, commit fcf0a90; reasoning preserved in CORE/CORE.xdc:25-37). No path can make 44 ps - and no real path has to: for unrelated clock pairs Vivado times the *worst-case edge alignment* over the clocks' common period, and for MMCM outputs with no rational relationship that worst case approaches zero. A ps-scale requirement is therefore not a speed problem; it is Vivado telling you "these domains are asynchronous and you have not declared the crossing".

**RULE:** never "fix" such a path by pipelining, and never blanket-`set_false_path` between two clocks just to make the table green. Instead, find the crossing in the source and classify the protocol; the constraint must encode *why* the crossing is safe:

- **Handshake-protected or synchronizer-terminated** (2-FF sync, quasi-static config bits, ping-pong *control* flags): `set_false_path` on exactly those register pins. This is what M2M's framework already does for ascal's control crossings - five regexp patterns in M2M/common.xdc:113-117 cut `i_*`/`avl_*`/`o_*` register-to-register paths between ascal's three domains.
- **FIFO/buffer *data* protected by a handshake elsewhere** (async FIFO payload, ping-pong buffer contents read only after the bank-switch flag has crossed): `set_max_delay -datapath_only <destination clock period>` from the memory cells to the capture registers. **Why this and not false_path:** the data must arrive within one destination cycle of the handshake or you capture stale words; `-datapath_only` bounds that staleness while excluding clock skew from the calculation - *and it removes hold analysis on the path entirely*, which is what stops the router's hold-fix vandalism (S113). The Amiga constraints (CORE/CORE.xdc:38-43 (Amiga port)):

```tcl
set_max_delay -datapath_only 10.000 \
   -from [get_cells -hierarchical -regexp {.*/i_ascal/i_dpram_reg.*}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/avl_dr_reg\[[0-9]+\]}]
set_max_delay -datapath_only 13.400 \
   -from [get_cells -hierarchical -regexp {.*/i_ascal/o_dpram_reg.*}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/o_dr_reg\[[0-9]+\]}]
```

(10.000 = hr_clk period, 13.400 = one hdmi_clk period rounded down; `-from` names the LUTRAM *cells*, see the TRAP below.)

**TRAP: false-path patterns written against register `/C` pins do not match LUTRAM read paths.** This is the precise reason the framework's own constraints did not save the Amiga port: M2M/common.xdc:113-117 matches pins named `.../i_.*_reg.*/C` - the clock pin of a flip-flop. But ascal's ping-pong buffers are *distributed RAM* (`ramstyle "no_rw_check"` LUTRAM; and in the Amiga build the BRAM-saturation demotion of S104 guaranteed it), and a timing path that *launches from a LUTRAM* starts at the RAM cell's `/CLK` pin, not a register's `/C` pin. The crossing's control paths were cut; the 128-bit data read paths were not, and were timed at 44 ps. If you use the framework's ascal with HDMI output, audit this in *your* build: `report_timing -from [get_clocks <core>] -to [get_clocks hr_clk]` and check the startpoints. The Amiga fix above is deliberately written against `get_cells` (which covers the RAM primitives regardless of pin name) and lives in CORE.xdc because M2M/common.xdc should not be modified per-port - it is flagged in-file as a candidate for upstreaming into the framework (CORE/CORE.xdc:22-23 (Amiga port); see also S130).

**S113 - The hold-fix detour phenomenon: phantom paths poison real ones.** This is the least obvious and most instructive lesson of the Amiga run 1, and the reason S111 orders phantom groups first. A path timed against a 44 ps requirement fails *hold* as catastrophically as setup; the router's standard hold fix is to *add* routing delay until the hold check passes. So the router dutifully inserted multi-nanosecond detours into the unconstrained CDC nets - and any *genuine, same-domain* setup path that shares those nets or that routing region inherits the damage. The Amiga fingerprint: fanout-1 nets between *adjacent slices* carrying 7.5 ns of route delay (commit fcf0a90 - "router detours (7.5ns on fo=1 nets between adjacent slices!) were poisoning the genuine intra-hr_clk paths"). A net with fanout 1 between neighboring slices should cost a few hundred picoseconds; when you see such a net at 7+ ns in a path detail, you are not looking at congestion - you are looking at a deliberate detour, and the question is *which hold constraint forced it*. Check `report_timing -hold` for ps-requirement paths through the same nets. The proof of mechanism: after the `-datapath_only` constraints removed hold analysis from the CDC paths (S112), the Amiga port's intra-`hr_clk` group "recovered to +0.87 once the hold-fix detours disappeared", and "the two hairline stragglers resolved on their own" without further intervention (doc/synthesis-handoff.md, Run 2 (Amiga port)). **RULE:** never start fixing intra-clock paths while unconstrained inter-clock paths exist in the same region of the design; you would be optimizing against artifacts.

**S114 - Genuine failures: congestion, logic depth, BRAM geography, and the QNICE half-period.** Once the phantoms are constrained, what remains obeys ordinary STA logic. Classify by the logic/route split from S110:

- **Logic-dominated** (route < ~50%, many logic levels): genuine depth - pipeline it, or check whether the path even needs to be fast (a settings bus sampled once per frame can be a multicycle or a registered handshake instead).
- **Route-dominated with high fanout**: register-duplicate or `max_fanout` the driver.
- **Route-dominated, low fanout, long distance**: *geography*. The instructive Amiga case: QNICE's debug access to chip/slow RAM required the QNICE address bus to reach **256 BRAM tiles spread across the whole die** - 4 x 64-tile memories, physically everywhere - and to do it within QNICE's *falling-edge half-period*. M2M's dual-clock memories serve the QNICE port on the falling edge (`FALLING_B => true`, e.g. Amiga port CORE/vhdl/mega65.vhd:673; implementation in M2M/vhdl/2port2clk_ram.vhd:23-24) so that QNICE's rising-edge logic sees BRAM reads "combinationally" within one cycle - the price is that QNICE-to-BRAM paths get *half* of qnice_clk's 20 ns, i.e. 10 ns, minus clock skew across the die. Reaching 256 scattered tiles in 10 ns is not possible on a saturated 200T (WNS -0.757 ns, commit fcf0a90). The honest fix was architectural retreat, not constraints: the debug port on chip/slow RAM was removed (QNICE keeps its port on the 64-tile Kickstart ROM, which the mandatory auto-load needs), with the device IDs left reserved (commit fcf0a90 (Amiga port)). **Why this matters generally:** at 99.6% BRAM utilization (S107) the placer has *no freedom* - every BRAM-adjacent path is at the mercy of where the tiles physically are. Expect BRAM-heavy M2M ports to lose timing margin to geography, and budget QNICE-visible memories accordingly: every QNICE-accessible BRAM is a half-period, die-wide bus.

**S115 - Standing tricks from the C64 port.** Three techniques from the reference implementation that transfer to any port:

1. **`set_case_analysis` to halve constraint work on muxed clocks.** The C64 core can run at two slightly different clock rates (original vs digital-exact), muxed at runtime; timing both would double every constraint and analysis. The C64 XDC pins the analysis to the faster case: `set_case_analysis 0 [get_pins CORE/hr_core_speed_reg[0]/Q]` with the comment "This halves the number of set_false_path needed" (C64MEGA65 CORE/CORE.xdc:5-7). If your core has a BUFGMUX/clock-select, tell the timer which case to analyze (and make sure the other case is genuinely covered - here, by being strictly slower).
2. **Manual 2-FF synchronizers plus targeted `set_false_path`, documented in the source.** For multi-bit but quasi-static crossings the C64 port deliberately kept sorgelig's `iecdrv_sync` two-stage synchronizer and added per-instantiation false paths (C64MEGA65 CORE/CORE.xdc:12-22: `-from ... id1_reg[*]/C`, `-to ... */reset_sync/s1_reg[*]/D` etc.) rather than converting to per-bit XPM CDC, which can produce glitchy multi-bit words. The contract lives *in the source*: "The iecdrv_sync needs appropriate set_false_path settings in the XDC for each instantiation" (C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/iecdrv_misc.sv:4). **RULE:** every manual synchronizer you keep gets (a) its false-path constraints and (b) a comment at the module binding them together - an XDC line without a source comment is a future deletion.
3. **`-flatten_hierarchy none` keeps your XDC paths valid.** All those hierarchical patterns (`CORE/i_main/iec_drive_inst/...`, `.*/i_ascal/...`) survive only if synthesis preserves the hierarchy. The M2M projects synthesize with flattening off - visible as `synth_design -top mega65_r6 -flatten_hierarchy none` in the C64 Tcl flow (C64MEGA65 CORE/CORE-R6.tcl:158), as `<Option Id="FlattenHierarchy">1</Option>` in the project files (C64MEGA65 CORE/CORE-R3.xpr:1020; identical at Amiga port CORE/CORE-R3.xpr:1083), and provably in effect in the Amiga run log (`Command: synth_design -top mega65_r3 ... -flatten_hierarchy none`, runme.log:15 (Amiga port)). Do not "optimize" this setting away: the cost is small, and with flattening enabled your cell-pattern constraints silently match nothing (an empty `get_cells` with `-quiet` is invisible; without `-quiet` it is only a warning).

**S116 - Re-check WNS after every build, forever.** Timing closure is a state, not an achievement. The Amiga port closed at WNS +0.387 ns - under 4% of one hr_clk period - and the repository's standing instruction is explicit: "overall WNS margin is +0.387 ns - re-check the timing summary after every build" (doc/synthesis-handoff.md, Run 2 (Amiga port)). Any change can flip a thin margin: adding a feature, a different placer seed from an unrelated edit, even a framework update. Build the check into the handoff ritual of S102 (the timing summary is already on the artifact list). And when a build *does* go red: re-run the S111 triage from the top - new failures after a change are usually one new group with one cause, and the worst thing you can do is sprinkle constraints until it is green. Every constraint you add must restate a property of the *design* (a protocol, a static signal, a clock relationship), never a property of one build's placement.

## 2.11 Phase 11 - Hardware bring-up and testing

A bitstream that synthesizes, meets timing, and routes cleanly has earned exactly one thing: a hardware test. This chapter is the bring-up sequence - SD card, loading, what a healthy first boot looks like, and the layered diagnosis when the screen stays black - plus the cheapest test strategies for the period right after first boot, when you have a working machine and almost no peripherals.

**S117 - Prepare the SD card.** The Shell's FAT32 stack has hard requirements: **FAT32 only, capacity at most 32 GB** (the wiki's standing answer to most "SD Card:" fatal errors, MiSTer2MEGA65 wiki, Fatal-Errors.md), partition 1 of the card, and the back (external) slot has precedence over the bottom (internal) slot when both hold a card. Onto the card go:

1. **Every auto-load ROM** at the exact path configured in `C_CRTROMS_AUTO_NAMES` in your globals.vhd (see Part II, Phase 7). For the Amiga port: `/amiga/kick.rom`, a raw 256 KB Kickstart 1.3 dump, big-endian as dumped, no byte swapping (doc/synthesis-handoff.md, section 4 (Amiga port)). Verify the *file size byte-exactly* before the first test - a wrong-sized image aliases or truncates silently in BRAM and produces undebuggable behavior (the Amiga note: a 512 KB doubled-up DiagROM image would alias in the 256 KB kick BRAM; check with `ls -l`, doc/next_tests.md (Amiga port)).
2. **The OSM config file**, if your config.vhd sets `SAVE_SETTINGS := true`: a file named like `CFG_FILE` (Amiga port: `/amiga/aexp-wip-V1-A2.cfg`, CORE/vhdl/config.vhd; the tracked master copy is `CORE/m2m-rom/aexpcfg`) that must be **exactly OPTM_SIZE bytes** (Amiga port: 35, config.vhd). Generate it with `M2M/tools/make_config.sh <filename> <OPTM_SIZE|auto>` - it writes OPTM_SIZE bytes of `0xFF`, and a first byte of `0xFF` means "use the OPTM_G_STDSEL defaults". Without the file nothing breaks; settings simply do not persist. **TRAP:** whenever OPTM_SIZE changes (you added a menu line), the shipped config file must be regenerated, or the size check fails and settings silently stop persisting (see S127).

**S118 - Load the bitstream: JTAG for iteration, .cor for flashing.** Two routes (MiSTer2MEGA65 wiki, 2.-First-Steps.md:147-157):

- **JTAG** (TE0790-03 XMOD adapter on R3; the tooling is the mega65-tools repo): `m65 -q CORE/CORE-R3.runs/impl_1/mega65_r3.bit` pushes the bitstream and starts the core in seconds, no flash wear, gone at power-off. This is your development loop.
- **Flash**: convert with `bit2core` (also mega65-tools; run without arguments for usage - it takes the board model, e.g. `bit2core mega65r3 mega65_r3.bit "Amiga 500 AExp" V0.1 aexp.cor`), then flash the `.cor` into a core slot via the menu you get by holding **No Scroll** during power-on. This is how users will install it, so test it before release (S128).

**TRAP - the R3/R3A HDMI back-powering problem.** On board revisions R3 and R3A, a powered HDMI sink back-feeds the MEGA65 and causes anything from display problems to SD-card failures to general instability. Discipline: **power the MEGA65 on first, the HDMI device second** - or hold No Scroll during power-on (with the HDMI device off) and select the core from the core menu after switching the display on, or put a cheap HDMI switch in between (MiSTer2MEGA65 wiki, HDMI-back-powering-problem.md). If your first hardware test shows SD errors or refuses to boot with HDMI connected, suspect this before suspecting your core. R4 and later boards fixed it.

**S119 - Know what a healthy first boot looks like before you boot.** The M2M startup order matters for interpreting symptoms (M2M/rom/shell.asm: `CRTROM_AUTOLOAD` at :114, reset management after it, un-reset and keyboard/joystick connect at :157-160): the Shell initializes, **loads all mandatory and optional auto-ROMs from SD into the core's BRAM while the core is still held in reset**, runs the reset countdown from config.vhd, optionally shows the welcome screen, and only then releases the core's reset. Consequences:

- A noticeable SD-card pause (about 2-3 seconds, plus load time) before the core starts is *normal*.
- **A missing mandatory ROM is a designed-in fatal**: the Shell shows a fatal error screen naming the missing file (M2M/rom/crts-and-roms.asm:687, `_CRMA_FATAL`) and the core never starts. This screen is your friend - it proves the framework, video path, SD card, and config plumbing all work.
- **Fatal "SD Card:" errors carry a 16-bit code `XXYY`** with a documented decoding chain: `XX < 0xEE` = controller-level error, decode `YY` via `t_error_code` and the `calcDebugOutputs` block in M2M/QNICE/vhdl/sd_spi.vhd; `0xEE21` = read/write collision between sd_spi.vhd and sdcard.vhd; `0xEEFF` = timeout in M2M/QNICE/monitor/sd_library.asm; other `0xEEYY` = FAT32 stack errors, decoded via the "FAT32 ERROR CODES" section of M2M/QNICE/monitor/sysdef.asm (MiSTer2MEGA65 wiki, Fatal-Errors.md). A "Heap corruption: Hint: MENU_HEAP_SIZE or OPTM_HEAP_SIZE" fatal means your config.vhd menu outgrew the Shell memory layout; the error code is the overrun in words.
- Then the moment of truth: for the Amiga port, dark gray, then light gray, then after a few seconds the Kickstart 1.3 "insert disk" hand in color, stable 50 Hz PAL on VGA (scandoubled) and HDMI (720p50) simultaneously (doc/synthesis-handoff.md, section 6 (Amiga port)). Define your core's equivalent expectation *in writing* before the test, including the timing - "gray for 4 seconds then hand" reads very differently from "gray forever" only if you knew the schedule.

**S120 - The black-screen split: does the OSM show?** If the screen stays black, the single highest-value test is pressing **Help**: the On-Screen-Menu is rendered by the framework, not by your core. The full decision tree is Part IV, section 4.1; the first split:

- **OSM appears** over a black background: the bitstream, clocks, video pipeline, QNICE, and keyboard all work - *your core* is producing no video (or is held in reset, or its video signals are mis-wired into the M2M pipeline). Proceed with the QNICE console (S121) and core-level checks.
- **No OSM either**: do not conclude the framework is dead yet - OSM compositing depends on the core's video timing on both paths (4.1.2). Connect the serial console (4.1) first: banner present means the framework is alive and the core's video timing is absent/unusable (go to 4.1.4/4.1.5); no banner means the framework is dead - suspect the bitstream (did it load? does the flash slot match the board revision?), the board-revision mismatch (an R3 bitstream on an R6 does nothing), HDMI back-powering (S118), or - rare once Phases 9/10 were done honestly - a clk.vhd problem.

**S121 - The QNICE debug console: look inside the running system.** M2M has a built-in monitor that turns "black screen" from a guessing game into an inspection: connect a terminal at **115200 baud, 8-N-1** (M2M/vhdl/qnice_wrapper.vhd:27; the UART is carried over the same TE0790 USB module as JTAG on R3), then on the MEGA65 keyboard hold **Run/Stop + Cursor Up and, while holding both, press Help** (M2M/rom/shell.asm:1350-1352). The Shell drops into the QNICE Monitor on the serial port. Even before that, the UART is worth watching passively: the Shell logs its startup progress, and **the first press of Help also dumps a memory report** ("Maximum available QNICE memory", heap/stack utilization, "OSM heap utilization" - emitted once, from the HELP_MENU path, M2M/rom/coreinfo.asm:230-236) - useful when you are tuning MENU_HEAP_SIZE.

In the Monitor, commands are two letters (group, then command). The ones that matter for bring-up:

- `M` `D` (MEMORY/DUMP, prompts for start/end address, M2M/QNICE/monitor/qmon.asm:216) and `M` `C` (MEMORY/CHANGE, :199).
- `C` `R` (CONTROL/RUN, :176) - the Monitor prints the addresses to use to return to the Shell when you enter debug mode.

The killer application is **verifying that your ROMs actually landed in BRAM**. The core's memories are QNICE devices reachable through the MMIO window: `M C` at `0xFFF4` sets the device ID (M2M$RAMROM_DEV, M2M/rom/sysdef.asm:195; Amiga Kickstart = device 0x0100, CORE/vhdl/globals.vhd:92 (Amiga port)), `M C` at `0xFFF5` selects the 4K window (sysdef.asm:210), and `M D` from `0x7000` to `0x7010` shows the first words of the loaded ROM (sysdef.asm:211). If the dump shows your Kickstart's reset vector instead of zeros, the entire Shell-side loading chain is proven and your bug is on the core side of the BRAM - and vice versa. This fifteen-second check replaces hours of speculation about whether "the ROM maybe didn't load".

**S122 - ILA, when you need waveforms from real hardware.** Vivado's Internal Logic Analyzer works on the MEGA65 over the same JTAG, with two non-obvious rules from M2M practice (MiSTer2MEGA65 wiki, Debugging.md): **do not use auto-connect** in the Hardware Manager - manually add the server and set the JTAG frequency explicitly (5 MHz is the known-good value); and **keep the JTAG clock below one third of the sampled signal's clock**, or the waveform windows come back empty (the documented M2M case: an 18 MHz core needed JTAG < 6 MHz; a 32 MHz core never showed the problem). Budget for the BRAM cost of capture windows - on a BRAM-saturated design (S107) a wide/deep ILA simply will not fit, which is one more reason to lean on the QNICE console first.

**S123 - Zero-code test rounds: let alternative ROMs exercise the hardware.** Between "first boot" and "full peripheral support" there is a long, valuable test phase that requires *no RTL changes at all*: the mandatory-ROM auto-loader does not care what the ROM bytes contain, so any image at the right path boots. For the Amiga, the canonical choice is **DiagROM** (John "Chucky" Hertell, diagrom.com): placed on the SD card as `/amiga/kick.rom` it replaces Kickstart and systematically tests chip/slow RAM decode and memory config, keyboard end-to-end, Paula audio, CIA/IRQ channels and video modes - precisely the subsystems the Kickstart hand screen does *not* prove (doc/next_tests.md, "Test round A" (Amiga port); the port's milestone-1 hand screen proves CPU/microcode, ROM loading, chip RAM, Agnus/Denise/Paula-IRQ/CIA-timer basics and the whole video path, but not slow RAM, keyboard, audio, blitter-under-load or sprites). Analogous diagnostic ROMs exist for most systems with a socketed-ROM heritage (C64 diag carts, NES test carts, MSX diagnostics); for any port, ask: *what is the most demanding software I can run purely by substituting a ROM image?* Expect documented false alarms - DiagROM's serial/parallel tests fail because those ports are tied off in the milestone build, which is correct, not a bug. Plan such rounds explicitly, with expected-pass and expected-fail lists, like the Amiga port's doc/next_tests.md does (Amiga port).

**S124 - Re-enable the de-featured list, one item at a time.** Phase 2 of the port deliberately disabled subsystems (Part II, section 2.2) to reach a minimal first milestone. Bring-up is not finished until that list is worked back down - and the discipline is strict: **one feature per build**, with the full S102 artifact round-trip and the S116 timing re-check after each, because every re-enabled subsystem changes utilization, placement, and timing on a design that closed at +0.387 ns with BRAM at 99.6% (Amiga port). Re-read your Phase 2/Phase 6 budget notes before each step - the Amiga port's run-1 analysis already proves, for example, that re-enabling IDE/HDD costs +8 RAMB36 and *cannot fit* in BRAM, so that feature's plan starts with "move the buffers to HyperRAM", not with "uncomment the instantiation" (doc/synthesis-handoff.md, post-run-1 findings (Amiga port)). Keep the de-feature list as a living checklist with, per item: gating mechanism (tie-off/generate/file exclusion), estimated resource cost, prerequisite infrastructure, and the test that will prove it works.

## 2.12 Phase 12 - Towards release

The walkthrough ends where the M2M wiki's release chapter begins. This phase is deliberately brief: the full release checklist is maintained in the framework wiki ("XYZ. How to release your core to the MEGA65 community" - source-code hygiene, binaries, GitHub repository conventions, the MEGA65 FileHost, community announcement channels), and it is good and current enough that this guide only needs to cover what the porting work specifically feeds into it, plus two disciplines the checklist does not cover: staying mergeable with upstream, and paying your framework debts forward.

**S125 - Replace every template placeholder in the identity files.** The M2M template ships `AUTHORS` and `VERSIONS.md` as placeholders - the Amiga repo at the time of writing still carries "YOUR PROJECT NAME for MEGA65 aka GITHUB REPO SHORT NAME / done in YEAR by YOUR NAME" in AUTHORS and the *framework's own* V2.0.1 release notes in VERSIONS.md (Amiga port, AUTHORS and VERSIONS.md - this is a standing release blocker, kept visibly unfixed until release). The C64MEGA65 files are the model: AUTHORS names the porters, the license, *and the upstream MiSTer contributors being ported* (C64MEGA65 AUTHORS); VERSIONS.md is a reverse-chronological user-facing changelog per release version. The same placeholder sweep applies to source headers: the release wiki's first section is literally "grep for @TODO and template phrases in CORE/vhdl and m2m-rom.asm". Do this with the wiki checklist open, not from memory.

**S126 - Decide the welcome screen, then write the help pages.** config.vhd's `WELCOME_ACTIVE`/`WELCOME_AT_RESET` control a framework-rendered welcome/splash page (WHS array position 0, which must exist even when unused). The C64MEGA65 reference ships with both set `false` (C64MEGA65 CORE/vhdl/config.vhd:254 and :258) and boots straight into the core; the Amiga port follows, with the reasoning recorded at the constant: the mandatory-ROM fatal screen already names `/amiga/kick.rom` when it is missing, and the About & Help OSM pages document the SD-card setup, "so nothing is lost" (Amiga port, CORE/vhdl/config.vhd:176-181). Whatever you decide: the Help/About pages in config.vhd are your *user manual inside the core* - SD card layout, mandatory files, key bindings belong there, because that is the only documentation guaranteed to be present when the user is staring at the machine.

**S127 - OPTM defaults and the config-file regeneration rule.** Before release, set `OPTM_G_STDSEL` deliberately for every menu group - it defines both what a fresh user gets and what "first byte 0xFF" in the config file resets to (C64MEGA65 CORE/vhdl/config.vhd:340; Amiga port config.vhd:255). **RULE:** whenever `OPTM_SIZE` changes - any added, removed, or reordered menu line - the shipped config file must be regenerated with `M2M/tools/make_config.sh <name> auto` and re-shipped with the release; the warning is written directly at the constant ("IMPORTANT: If SAVE_SETTINGS is true and OPTM_SIZE changes: Make sure to re-generate and re-distribute the config file", Amiga port config.vhd:286-287). A stale config file does not crash anything - the size check fails and users silently lose settings persistence, which is worse, because nobody reports it.

**S128 - Build, test, and package for every supported board.** This is where the S98 four-project sync pays out: generate bitstreams from `CORE-R3.xpr`, `CORE-R4.xpr`, `CORE-R5.xpr`, `CORE-R6.xpr`, convert each with `bit2core` using the matching board model string, and ship `.cor` (plus, best practice, `.bit`) per board. R3 and R3A share a binary. **TRAP:** the wiki release chapter's board list predates R4/R5/R6 (it still says "currently only R3 and R3A are supported") - the *process* it describes is current, the board enumeration is not; your .xpr set is the authoritative list. Test at minimum one flashed `.cor` via the No Scroll menu on real hardware before publishing - JTAG-only testing misses the flash/slot path your users will actually use (S118). Then follow the wiki chapter for FileHost upload, README-as-user-manual, tagging, and the community announcement - all of it applies unchanged to a new port.

**S129 - Stay mergeable with upstream MiSTer.** Your core fork (the `<Core>_MiSTerMEGA65` submodule) will outlive the port: upstream fixes bugs you also have. The C64 reference demonstrates the discipline over years of history - recurring `Merge branch 'master' of https://github.com/MiSTer-devel/C64_MiSTer` commits (C64_MiSTerMEGA65 submodule commits a13f217, b057c72, abfd88c among others) plus targeted adoption commits like "New CIA version from MiSTer upstream" (2638ece). What makes those merges survivable is everything Phase 2/3 insisted on: nothing upstream is ever deleted (exclusion happens in the .xpr file list), every modification is marked with a provenance comment (S48), and de-featuring is done by tie-off rather than surgery. Keep the upstream remote configured in the submodule, merge (or cherry-pick, for surgical fixes) on a branch, and re-run the whole verification ladder afterwards - local lint (S46), elaboration (S47), full build with log triage (S103-S107), timing (S116), hardware smoke test. An upstream merge is a port-in-miniature; budget it as such.

**S130 - Upstream your framework fixes to M2M.** Anything you fixed *in or around the framework* during the port is, by construction, a fix every future M2M port needs. The Amiga port's running example: the ascal LUTRAM CDC constraints live in CORE/CORE.xdc only because `M2M/common.xdc` must not be modified per-port, and are explicitly marked "framework paths, constrained here because M2M/common.xdc must not be modified - candidate for upstreaming" (Amiga port, CORE/CORE.xdc:22-23; same flag in commit fcf0a90). The same applies to framework bugs (the silently-failing `synth_pre.tcl` on Mac/VM setups, S101), documentation gaps you closed, and constraint patterns you generalized. File them as issues or PRs against sy2002/MiSTer2MEGA65 with the evidence you already have (the commit messages and timing reports from your own history). **Why:** beyond good citizenship, upstreamed fixes come back to you - your next framework update otherwise re-introduces every problem you quietly fixed downstream, and your port-local workarounds (like a CORE.xdc carrying framework constraints) can be deleted once the framework carries them itself.

This closes the walkthrough: from a MiSTer tree and an empty M2M template to a released, maintainable MEGA65 core. The remaining parts of this guide are reference material - Part III is the pattern catalog the walkthrough has been pointing into, and Part IV holds the debugging playbook and the appendices.

---

# Part III - The Quartus-to-Vivado pattern catalog

This part is the reference catalog you will grep while porting. Every MiSTer core is written
for Quartus (Intel/Altera); the MEGA65 lives in Vivado (AMD/Xilinx). The two tools disagree
on language strictness, on vendor primitives, and on what "legal Verilog" even means. The
patterns below are the complete set of incompatibilities encountered while porting the
C64 core (reference: C64MEGA65, github.com/MJoergen/C64MEGA65, submodule CORE/C64_MiSTerMEGA65)
and the Amiga 500 core (this repo, submodule CORE/Minimig_MiSTerMEGA65). Each pattern gives
the Vivado symptom (error code verbatim where one exists), the root cause, the fix with
before/after code, and a verified example citation into one of the two repositories.

Sections 3.E-3.J cover the mixed-language boundary, CDC/constraints, ROM data handling,
the .xpr project file, M2M integration and local verification.

## 3.A Memory primitives (the biggest category)

MiSTer cores get their RAMs and ROMs in three ways: (1) behavioral templates that Quartus
infers as block RAM, often decorated with Quartus-only attributes; (2) raw `altsyncram`
megafunction instantiations with `defparam` lists; (3) wrapper files (`bram.vhd`,
`dpram.vhd`, `spram.v`, ...) that instantiate `altera_mf` library components. Vivado
understands none of the vendor parts. Expect this to be the single largest porting
category by line count and by debugging time, because the failure modes range from hard
errors (unknown module `altsyncram`) to silently wrong read-during-write semantics.

**RULE:** before touching any RAM file, write down the contract of the original: port
widths, clocking (one clock or two), read latency in clock edges, byte-enable lane order,
read-during-write behavior on the same port and across ports, and power-up contents. Every
altsyncram encodes all of this in its `defparam` list (`outdata_reg_b`,
`read_during_write_mode_mixed_ports`, `byte_size`, `power_up_uninitialized`, ...). Your
replacement must reproduce that contract exactly; the consumers were written against it.

### 3.A.1 ram_init_file attribute on inferred RAM

**Symptom:** No Vivado error. The attribute `(* ram_init_file = "..." *)` (Verilog) or
`attribute ram_init_file : string;` (VHDL) is silently ignored; the memory powers up
all-zero, and the subsystem that expected ROM contents (a drive CPU, a character
generator) is dead on the first bitstream while synthesis reports success.

**Cause:** `ram_init_file` is a Quartus synthesis attribute that points at a `.mif` file.
Vivado neither parses the attribute nor reads `.mif` files.

**Fix:** Split into two cases.

1. The memory is a plain RAM that happens to carry the attribute with a default like
   `INITFILE=" "` (MiSTer template laziness): delete the attribute and the parameter. The
   behavioral dual-port template itself (registered address/wren, `always @(posedge clk)`)
   infers correctly in Vivado unchanged.

```verilog
// before (Quartus)
module iecdrv_mem #(parameter DATAWIDTH, ADDRWIDTH, INITFILE=" ") ( ... );
(* ram_init_file = INITFILE *) reg [DATAWIDTH-1:0] ram[1<<ADDRWIDTH];

// after (Vivado)
module iecdrv_mem #(parameter DATAWIDTH, ADDRWIDTH) ( ... );
reg [DATAWIDTH-1:0] ram[1<<ADDRWIDTH];
```

2. The memory is genuinely a preloaded ROM: use pattern 3.A.2 (wrapper around the M2M
   `dualport_2clk_ram`) or 3.A.3 (VHDL textio initializer), plus the `.mif` to `.hex`
   conversion from 3.A.4.

**Example:** C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/iecdrv_misc.sv:37 (`iecdrv_mem`
without `INITFILE`); the file header at iecdrv_misc.sv:1-14 documents the decision
("iecdrv_mem's data loading mechanism did not work in Vivado").

### 3.A.2 Initialized ROM as a wrapper around M2M's dualport_2clk_ram

**Symptom:** as 3.A.1 - ROM contents missing after synthesis, or you simply need a ROM that
the M2M service CPU (QNICE) can also write at runtime (loadable Kernal/Kickstart).

**Cause:** Quartus loads ROM contents from `.mif` via attribute; Vivado needs either an
inference template with an initializer (3.A.3/3.A.5) or an instantiated component that does
file loading in VHDL.

**Fix:** The M2M framework ships `dualport_2clk_ram`
(M2M/vhdl/2port2clk_ram.vhd:13-42 in the
V2.0.1 tree of this repo), a dual-port dual-clock RAM with these ROM-relevant generics:
`ROM_PRELOAD : boolean` (preload at all), `ROM_FILE : string`, `ROM_FILE_HEX : boolean`
(true = one hex word per line read with `hread`, false = binary `read`), plus
`FALLING_A/FALLING_B : boolean` to clock a port on the falling edge (that is how QNICE
accesses core memories - the QNICE side is covered in the ROM-loading/OSM part of this
guide). The C64 port wraps it in a
Verilog shim so that the MiSTer call sites keep their original look:

```systemverilog
module iecdrv_mem_rom #(parameter DATAWIDTH, ADDRWIDTH, INITFILE=" ",
                        FALLING_A=1'b0, FALLING_B=1'b0) ( ...same ports... );
dualport_2clk_ram #(
   .ADDR_WIDTH(ADDRWIDTH), .DATA_WIDTH(DATAWIDTH),
   .FALLING_A(FALLING_A), .FALLING_B(FALLING_B),
   .ROM_PRELOAD(INITFILE != " " ? 1'b1 : 1'b0),
   .ROM_FILE(INITFILE), .ROM_FILE_HEX(1'b1)
) ram ( ... );
```

and instantiates it like the original Quartus template:

```systemverilog
iecdrv_mem_rom #(
   .DATAWIDTH(8), .ADDRWIDTH(14),
   .INITFILE("../../C64_MiSTerMEGA65/rtl/iec_drive/c1541_rom.mif.hex"),
   .FALLING_A(1'b1)
) romstd ( ... );
```

**TRAP:** the `INITFILE` path is resolved relative to the directory Vivado is started in /
the project directory, NOT relative to the source file. Quartus resolves relative to the
`.qip`, so the original short paths ("c1541_rom.mif") will not be found. See Part III,
section G for the exact path rules (project mode vs. the M2M build script).

**TRAP:** note the wrapper reproduces MiSTer's one-cycle address/wren delay registers for
the rising-edge port but bypasses them when `FALLING_A=1` ("QNICE expects the data to flow
instantly on the falling edge, not delayed", iecdrv_misc.sv:129-141). If you copy this
pattern, keep that asymmetry, or QNICE reads will be off by one cycle.

**Example:** C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/iecdrv_misc.sv:92-127
(`iecdrv_mem_rom`), instantiated at rtl/iec_drive/c1541_multi.sv:157 and :180.

### 3.A.3 Initialized VHDL ROM via textio impure-function initializer

**Symptom:** as 3.A.1, for VHDL ROMs (`dprom.vhd` style: shared-variable RAM with
`attribute ram_init_file`).

**Cause:** same Quartus-only attribute, VHDL flavor.

**Fix:** initialize the memory array with an impure function that reads the file at
elaboration time. This is the standard UG901-documented technique and Vivado executes it
during synthesis. Before (upstream MiSTer, C64MEGA65 submodule commit 189d354):

```vhdl
type memory_t is array(2**ADDR_WIDTH-1 downto 0) of word_t;
shared variable ram : memory_t;
attribute ram_init_file : string;
attribute ram_init_file of ram : variable is INIT_FILE;
```

After (C64MEGA65 submodule, current develop):

```vhdl
use STD.textio.ALL;
type memory_t is array(0 to 2**ADDR_WIDTH-1) of word_t;   -- direction flipped!

impure function read_romfile(rom_file_name : in string) return memory_t is
   file     rom_file : text;
   variable line_v   : line;
   variable rom_v    : memory_t;
begin
   file_open(rom_file, rom_file_name, read_mode);
   for i in memory_t'range loop
      if not endfile(rom_file) then
         readline(rom_file, line_v);
         hread(line_v, rom_v(i));
      end if;
   end loop;
   return rom_v;
end function;

shared variable ram : memory_t := read_romfile(INIT_FILE & ".hex");
```

Two details cost the C64 port three commits, so get them right the first time:

- **Use `hread`, not `read`.** `read` parses `std_logic_vector` literals ('0'/'1'
  characters); the converted files are hex (3.A.4). The initial port (commit a264f44 "Port
  ROM initialization to Vivado") used `read`; commit d8b0a71 switched to `hread`.
- **Flip the array direction from `downto` to `to`.** The loop iterates
  `memory_t'range`; with the original `(2**ADDR_WIDTH-1 downto 0)` range, file line 0
  lands at the HIGHEST address. With `(0 to 2**ADDR_WIDTH-1)` line 0 = address 0. This
  was the final fix, commit b63324f "fixed ROM loader" (a one-line diff).

**Why:** the synthesized RTL is otherwise identical; both bugs produce a bitstream that
synthesizes cleanly and boots a scrambled ROM. If a ported subsystem with a preloaded ROM
"almost works", check byte format and address direction of the loader first.

**Example:** C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/dprom.vhd:34-52 (current develop);
history: `git -C <C64MEGA65>/CORE/C64_MiSTerMEGA65 log --oneline
-- rtl/dprom.vhd` shows a264f44, d8b0a71, b63324f.

### 3.A.4 .mif to .hex conversion

**Symptom:** you have pattern 3.A.2/3.A.3 in place but no input files: MiSTer ships ROM
contents as Quartus `.mif` (Memory Initialization File), which neither Vivado nor the
textio loader can read.

**Cause:** `.mif` is an Altera-proprietary text format (address/value records with a
header block).

**Fix:** convert once with Quartus' own `mif2hex` utility and strip the Intel-HEX framing
down to plain one-byte-per-line hex, then commit the generated files. The C64 script
(C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/roms/convert_mif_to_hex.sh, verbatim):

```sh
MIF2HEX=/opt/altera/21.1/quartus/bin/mif2hex
for i in *.mif ../iec_drive/*.mif; do \
   echo "Processing" $i; \
   $MIF2HEX $i tmp.tmp; \
   cat tmp.tmp | cut -c 10-11 | head -n -1 > $i.hex; \
   rm tmp.tmp; \
done;
```

`cut -c 10-11` extracts the single data byte from each Intel-HEX record (works because
`mif2hex` emits one byte per record for 8-bit memories); `head -n -1` drops the EOF
record. The naming convention `<name>.mif.hex` keeps the provenance visible, and the
instantiation generics keep the historical `.mif` name while `dprom` appends `".hex"`
(`read_romfile(INIT_FILE & ".hex")`), e.g. `generic map ("./roms/chargen.mif", 12)` at
rtl/fpga64_buslogic.vhd:184. The C64 port committed roughly 140k lines of `*.mif.hex` under
rtl/roms/ and rtl/iec_drive/ - generated files in git are fine here, they change never.

**TRAP:** for memories wider than 8 bits, `cut -c 10-11` is wrong (one record carries
more bytes); check the `mif2hex` output format before reusing the recipe, or write the
width-aware two-liner in Python. The Amiga port sidesteps this entirely: its big ROMs
(Kickstart) are not baked into the bitstream at all but loaded at runtime by QNICE (see
the ROM-loading part of this guide), and the only preloaded ROMs (fx68k microcode)
already come as `$readmemb` files from upstream.

**Example:** C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/roms/convert_mif_to_hex.sh:1-7; consumed
by rtl/dprom.vhd (3.A.3) and iecdrv_mem_rom (3.A.2).

### 3.A.5 Raw altsyncram megafunction instantiations: UG901 behavioral rewrite

**Symptom:** elaboration error - `altsyncram` (or `altdpram`) is an unknown module; or, if
you naively stub it, silently wrong data.

**Cause:** `altsyncram` is the Altera megafunction for every flavor of on-chip RAM. Its
behavior is controlled by ~25 `defparam`s; there is no Xilinx equivalent component, and
Vivado cannot map it.

**Fix:** rewrite the file body as a behavioral template per Vivado UG901 ("Synthesis"),
keeping the module name and ports byte-identical so no caller changes. The Amiga Denise
color table is the canonical worked example because it exercises every tricky defparam at
once. Original contract (decoded from the defparams kept in the comment block at
denise_colortable_ram_mf.v:146-197 (Amiga port)): simple dual-port 256x32, single clock,
`clocken0` gates BOTH the write and the read capture, four byte enables (`byte_size` 8),
`address_reg_b = CLOCK0` + `outdata_reg_b = UNREGISTERED` = exactly one cycle read
latency, `read_during_write_mode_mixed_ports = OLD_DATA`, `power_up_uninitialized =
FALSE` (zeros). The replacement (Amiga port,
CORE/Minimig_MiSTerMEGA65/rtl/denise_colortable_ram_mf.v:117-144):

```verilog
reg [31:0] ram [0:255];
reg [31:0] q_reg;

integer i;
initial begin                      // power_up_uninitialized="FALSE" => zeros;
   for (i = 0; i < 256; i = i + 1) // Vivado honors initial blocks for RAM init
      ram[i] = 32'd0;
   q_reg = 32'd0;
end

always @(posedge clock) begin
   if (enable) begin               // = clocken0: gates write AND read capture
      q_reg <= ram[rdaddress];     // read FIRST => OLD_DATA on collisions
      if (wren) begin
         if (byteena_a[0]) ram[wraddress][ 7: 0] <= data[ 7: 0];
         if (byteena_a[1]) ram[wraddress][15: 8] <= data[15: 8];
         if (byteena_a[2]) ram[wraddress][23:16] <= data[23:16];
         if (byteena_a[3]) ram[wraddress][31:24] <= data[31:24];
      end
   end
end

assign q = q_reg;
```

This is UG901's "byte-write enable, read-first" template, so Vivado infers a BRAM in
READ_FIRST collision mode - the OLD_DATA semantics hold in hardware, not just in RTL sim.

**TRAP (byte lane order):** altsyncram defines `byteena_a[0]` = `data[7:0]` ...
`byteena_a[3]` = `data[31:24]`. Get this wrong and the Amiga's 12-bit palette writes
(`wr_bs = loct ? 4'b0011 : 4'b1111`, denise_colortable.v:33 (Amiga port)) hit the wrong
half of the color word. Both consumers (denise_colortable.v:39, denise_hamgenerator.v:38)
were audited against the rewrite - always enumerate ALL instantiation sites; the second
consumer (HAM generator) was not mentioned anywhere in the obvious place.

**TRAP (read-first vs write-first):** the order of statements inside the clocked block is
semantics. `q_reg <= ram[rdaddress]` BEFORE the writes = READ_FIRST/OLD_DATA;
putting the read after a blocking-assignment write, or reading `ram[waddr]` written with
blocking `=`, gives WRITE_FIRST/NEW_DATA. Match what the defparams said, not what looks
natural.

**Example:** Amiga port CORE/Minimig_MiSTerMEGA65/rtl/denise_colortable_ram_mf.v:104-144
(rewrite + rationale comment), :146-197 (original altsyncram kept as reference). The C64
port had no raw altsyncram in compiled files, which is why this example is from the Amiga
port.

### 3.A.6 altera_mf wrapper files (spram/dpram families): portable rewrite in place

**Symptom:** elaboration error on `library altera_mf; use altera_mf.altera_mf_components.all;`
(VHDL) or unknown `altsyncram` inside MiSTer's generic RAM wrapper files (`bram.vhd`,
`dpram.vhd`, `spram.v` and friends).

**Cause:** MiSTer cores typically funnel all memory through a small family of wrapper
entities (`spram`, `spram_sz`, `dpram`, `dpram_dif`, `dpram_difclk`, ...) that internally
instantiate altsyncram.

**Fix:** rewrite each wrapper's architecture behaviorally but keep the entity names,
generic names, generic ORDER, generic defaults and port names/defaults exactly as
upstream, so the dozens of call sites all over the core remain untouched. The Amiga port's
bram.vhd does this for all five entities; comment out the `library altera_mf` clauses and
keep the original generic/port maps as comments for auditability.

**TRAP (positional generics from Verilog):** Verilog callers often pass parameters
positionally into the VHDL entity: `dpram #(12,16) io_buf0 (...)` (Amiga port,
CORE/Minimig_MiSTerMEGA65/rtl/ide.v:285 and :300). If your rewrite reorders the generics
(`addr_width` first, `data_width` second in bram.vhd:74-75 (Amiga port)), the caller
silently gets a 16-deep 12-bit RAM. Either preserve the order religiously or convert the
callers to named association.

**TRAP (unconnected ports relying on VHDL defaults):** the same ide.v instantiations
leave `enable_a/enable_b/cs_a/cs_b` unconnected and rely on the VHDL port defaults
`:= '1'`. Keep those defaults in the rewrite; UG901 documents cross-language default
binding as supported and it works in practice (this core synthesized).

**TRAP (faithfully reproduce the warts):** the original `spram_sz` IGNORED its `enable`
port (`clock_enable_input_a => "BYPASS"`, `clocken0` unconnected) and `cs` forces `q` to
all-ones when deasserted. Reproduce exactly that - "fixing" the wrapper changes timing or
bus behavior for every consumer. Document each wrapper's contract in a header comment:
read latency = 1 enabled clock edge, same-port RDW = NEW data (write-first), mixed-port
RDW = undefined (altsyncram default DONT_CARE).

If a wrapper variant supports features no compiled consumer uses (mixed widths,
`mem_init_file`), do not port them speculatively - guard them out with an elaboration-time
`assert ... severity failure` so a future caller fails loudly instead of misbehaving.

**Example:** Amiga port CORE/Minimig_MiSTerMEGA65/rtl/bram.vhd (entities at :72 spram_sz,
:217 dpram_dif, :354 dpram, :407 dpram_difclk); consumers at rtl/ide.v:285,:300. The C64
analog is rtl/dpram.vhd, which was simply not compiled (replaced by M2M's
dualport_2clk_ram at the call sites).

### 3.A.7 Mixed-port-width RAM is not inferable

**Symptom:** Vivado fails to synthesize (or grossly mis-implements) a behavioral RAM whose
two ports have different data widths - e.g. port A reads/writes bytes, port B single bits
via part-select: `ram[addr_b[A+2:3]][addr_b[2:0]] <= data_b;`.

**Cause:** Quartus' inference engine accepts asymmetric-port templates including
bit-addressed part-selects on a byte array; Vivado's does not (the C64 port hit this with
Vivado 2019.2; the in-source comment notes newer versions were not retried:
iecdrv_misc.sv:259-261 "Original MiSTer Intel/Quartus code that does not synthesize with
Vivado v2019.2").

**Fix:** decompose into per-bit (or per-byte) lanes of a symmetric dual-port RAM inside a
`generate` loop, with a registered lane-select mux on the narrow port. The C64 rewrite
builds `iecdrv_bitmem` (8-bit port A, 1-bit port B) from eight 1-bit `dualport_2clk_ram`
instances: lane `i` gets `wren_b_d && (address_b_d[2:0] == i)` on the narrow side, and the
read path muxes `q_b_bit` of lane `bit_selector_dd` (the selector must be DELAYED by one
cycle to line up with the RAM's read latency). Alternatively, if the asymmetry is
byte-enables rather than widths, use M2M's
`dualport_2clk_ram_byteenable` (M2M/vhdl/2port2clk_ram_byteenable.vhd),
which instantiates one `dualport_2clk_ram` per byte lane and ANDs `wren` with the
byte-enable bit (lines 36-54).

**TRAP:** N x 1-bit lanes can explode resource usage (each lane may become its own BRAM)
- check utilization. For larger asymmetric memories prefer restructuring the narrow port
to read-modify-write full bytes.

**Example:** C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/iecdrv_misc.sv:158-257 (the
generate-loop rewrite; note the whole block is currently commented out because the only
consumer, G64 support, was deferred - the pattern itself is what to copy), :259-300
(original Quartus-only code). The header note is at iecdrv_misc.sv:10-12.

### 3.A.8 ramstyle attribute translation

**Symptom:** no error - Quartus `(* ramstyle = "..." *)` / `ATTRIBUTE ramstyle` is ignored
by Vivado. Consequences are indirect: a memory the author forced into logic fabric or a
specific RAM type may infer differently, costing timing or BRAM budget; and
`no_rw_check` carries semantic information you must not throw away.

**Cause:** vendor attribute namespace. Vivado's equivalent is `ram_style` (underscore)
with values `block`, `distributed`, `registers`, `ultra`.

**Fix:** translate by intent:

| Quartus | Meaning | Vivado |
|---|---|---|
| `ramstyle = "logic"` | force LUT/FF fabric | `(* ram_style = "distributed" *)` (or `"registers"`) |
| `ramstyle = "M10K"`/`"M9K"` | force block RAM | `(* ram_style = "block" *)` |
| `ramstyle = "no_rw_check"` | designer guarantees no read-during-write at the same address; Quartus may drop bypass logic | no direct equivalent - informs YOUR choice |

`no_rw_check` is the important one: it tells you the original author asserts that
read-during-write never happens on that memory. That means (a) your behavioral rewrite is
free to pick read-first or write-first - both are correct by assumption; (b) you do not
need to add collision bypass logic; (c) if a simulation mismatch ever points there, the
guarantee is the first thing to re-verify. The M2M framework's ascal scaler carries these
attributes (M2M/vhdl/av_pipeline/ascal.vhd:345,:353,:420-421 in this repo) - harmless,
ignored by Vivado. Where M2M itself wants distributed RAM it uses the Xilinx attribute
(M2M/vhdl/controllers/hyperram/hyperram_fifo.vhd:37-38).

**Example:** C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/cartridge.v:64-65
(`(* ramstyle = "logic" *) reg [6:0] lobanks[0:63];` - this file was ultimately not
compiled; its VHDL rewrite CORE/vhdl/cartridge.vhd replaced it). Amiga port:
CORE/Minimig_MiSTerMEGA65/rtl/fpga-toccata/toccata_fifo.sv:25 (`(* ramstyle = "M10K" *)`,
file not in the Vivado file list).

### 3.A.9 BRAM output-register merge note (Synth 8-7052)

**Symptom:** synthesis log INFO (verbatim, from this repo's run log
CORE/CORE-R3.runs/synth_1/runme.log:3346):

```text
INFO: [Synth 8-7052] The timing for the instance ... (implemented as a Block RAM) might
be sub-optimal as no optional output register could be merged into the ram block.
Providing additional output register may help in improving timing.
```

**Cause:** Xilinx BRAMs have an optional hardware output register (DOA_REG); merging it
costs one extra cycle of latency. Your faithful one-cycle-latency rewrites (3.A.5/3.A.6)
cannot use it, so Vivado tells you the BRAM output feeds fabric logic directly.

**Fix:** usually none - this is informational, and core-internal memories run at the
core clock (tens of MHz), where the unregistered BRAM output is fine. Do NOT "fix" it by
adding an output register inside a contract-compatible rewrite: that changes read latency
from 1 to 2 cycles and breaks every consumer. Only if timing analysis later flags a path
out of that BRAM should you consider restructuring the consumer to tolerate an extra
register stage. Expect dozens of these messages (the Amiga run-1 log shows them for the
chip RAM, the QNICE memories and the OSM font ROM alike).

**Example:** Amiga port, CORE/CORE-R3.runs/synth_1/runme.log:3346-3350 and
doc/synthesis-handoff.md (run-1 findings). Related: when BRAM is over-budget Vivado
auto-demotes to LUTRAM with WARNING [Synth 8-5835] "Resources of type BRAM have been
overutilized" (runme.log:3057) - on a 95%-full part like this Amiga port that warning is
a capacity alarm, not noise (see doc/synthesis-handoff.md, "BRAM is at TRUE capacity").

## 3.B PLL and clocking

### 3.B.1 altera_pll / pll_0002.v does not synthesize: shim first, then move clocking out

**Symptom:** elaboration/synthesis failure on the generated PLL files: `altera_pll` is an
unknown component. Every MiSTer core ships `pll.v` (a thin wrapper) plus
`pll/pll_0002.v` (the `altera_pll` instantiation; see Amiga port
CORE/Minimig_MiSTerMEGA65/rtl/pll.v:14-25 with its 64-bit `reconfig_to_pll` /
`reconfig_from_pll` buses).

**Cause:** `altera_pll` is an Intel hard-macro wrapper. The Xilinx equivalents are
`MMCME2_ADV`/`PLLE2_ADV` primitives (or the Clocking Wizard), with completely different
generics and ports.

**Fix:** two strategies, used in sequence by the C64 port:

1. **Early elaboration shim:** write a VHDL/Verilog module with the SAME module name and
   port list (`refclk, rst, outclk_0..2, locked, reconfig_to_pll, reconfig_from_pll` -
   the reconfig buses as ignored dummy 64-bit vectors) that instantiates an `MMCME2_ADV`
   plus `BUFG`s with hand-computed dividers. This lets the untouched MiSTer top level
   elaborate so you can flush out all the other errors in this catalog quickly. C64MEGA65
   CORE/C64_MiSTerMEGA65/rtl/pll.vhd:19-30 (entity, port-compatible), :42-67 (MMCME2_ADV
   generics: DIVCLK_DIVIDE=3, CLKFBOUT_MULT_F=56.750 from a 50 MHz refclk); added in
   commit ac57765 "Fix minor errors during elaboration".

2. **Production:** do not compile the MiSTer PLL files at all (drop them from the file
   list, see 3.H.3) and generate every clock in the parent repo's
   CORE/vhdl/clk.vhd, which the M2M template provides. The C64 production clock generator
   is C64MEGA65 CORE/vhdl/clk.vhd:53-71 (entity `clk`) with two MMCME2_ADV instances
   (:93, :147) and a BUFGMUX_CTRL (:201) for the HDMI flicker-free trick; the Amiga port's
   single-MMCM version is CORE/vhdl/clk.vhd (Amiga port) producing exactly 28.375000 MHz
   (DIVCLK_DIVIDE=5, CLKFBOUT_MULT_F=56.750, CLKOUT0_DIVIDE_F=40.000 from the 100 MHz
   board clock).

**Why:** clocking belongs to the MEGA65 side of the port anyway: the board clock is
100 MHz (not 50 MHz as on the DE10-Nano), M2M brings its own QNICE/HDMI/HyperRAM clocks
(M2M/vhdl/clk_m2m.vhd), and the core clock must be derived to ppm accuracy for correct
video and audio. Hand-compute the MMCM settings and verify legality against the
datasheet: VCO range (600-1440 MHz for Artix-7 speed grade -2, DS181), PFD range, MULT_F
a multiple of 0.125, and fractional divide only on CLKFBOUT and CLKOUT0. The Amiga port
documents this arithmetic in the clk.vhd header - 28.375000 MHz vs the ideal PAL
28.37516 MHz is -5.64 ppm, well inside a real crystal's tolerance.

**TRAP:** every MMCM output that leaves the clk module must go through a `BUFG`, and the
reset must be synchronized to the new clock - the M2M template does this with
`xpm_cdc_async_rst` driven by `not locked`. Keep that structure; do not invent your own
reset bridge.

### 3.B.2 Dynamic PLL reconfiguration (PAL/NTSC switching) is not portable

**Symptom:** unknown modules `pll_cfg` / Avalon-MM `mgmt_write`/`mgmt_waitrequest`
state machines in the MiSTer top level (Amiga port CORE/Minimig_MiSTerMEGA65/
Minimig.sv:125-148 wires `reconfig_to_pll`/`reconfig_from_pll` between `pll` and a
`pll_cfg` instance). Even if you stub it, the feature (runtime clock switching for
NTSC/PAL or turbo modes) silently does nothing.

**Cause:** MiSTer retunes the Altera PLL at runtime through its reconfiguration port.
Xilinx MMCMs have DRP-based reconfiguration, but it is a different mechanism, and the
M2M-recommended architecture avoids runtime retuning of the core clock altogether (the
HDMI clock must stay fixed).

**Fix:** two complementary techniques:

1. If the use case is "two fixed video standards", generate both clocks statically (two
   MMCMs, or two parameter sets) and select with a glitch-free `BUFGMUX_CTRL`, as the C64
   does for its flicker-free pair (C64MEGA65 CORE/vhdl/clk.vhd:93,:147,:201).
2. For everything derived FROM the core clock, pass the exact current frequency in Hz
   into the core as a `natural` port and replace all hardcoded divider constants with
   fractional accumulators. The C64 added `clk32_speed : in natural` to
   rtl/fpga64_sid_iec.vhd (commit a455c46 "Refactored hardcoded clock speeds") and
   `clk_main_speed_i` to CORE/vhdl/main.vhd. The pattern, from the time-of-day clock in
   that commit:

```vhdl
process(clk32)
   variable sum       : natural;
   variable sum_max   : natural;
   variable add_value : natural;
begin
   sum_max   := clk32_speed;                         -- exact Hz, e.g. 31527778
   add_value := 120 when ntscMode = '1' else 100;    -- 2*60 resp. 2*50
   if rising_edge(clk32) then
      if reset = '1' then
         todclk <= '0'; sum := 0;
      else
         sum := sum + add_value;
         if sum >= sum_max then
            sum    := sum - sum_max;
            todclk <= not todclk;
         end if;
      end if;
   end if;
end process;
```

   (Note the conditional variable assignment `:= 120 when ... else 100` is VHDL-2008
   syntax - this file must be compiled in 2008 mode, see 3.D.7.)

   The same accumulator generates the 16 MHz IEC-drive clock enable in C64MEGA65
   CORE/vhdl/main.vhd:1517-1535 (`iec_dce_sum + 16000000`, wrap at `clk_main_speed_i`).
   This is drift-free (the error never accumulates beyond one master-clock period),
   retunes itself automatically when the master clock changes (HDMI flicker-free slows
   the whole system by ~0.25%), and costs one adder and one comparator.

**Why** pass the speed as a port instead of a generic: the C64's flicker-free mode
switches the physical clock frequency at runtime; a generic would bake in one value. The
comment block above iec_drive_ce_proc (C64MEGA65 CORE/vhdl/main.vhd:1507-1516) documents a
real bug class: a CE that compensates for the slowed clock when it should scale with it
changes the C64:1541 frequency ratio and breaks fastloaders (GitHub issue MJoergen/
C64MEGA65#2). Decide per CE whether it must track the master clock (ratio-locked, use a
constant divider) or hold absolute time (TOD, UART baud - use the Hz port).

**Example:** C64MEGA65 commits ac57765, a455c46; C64MEGA65 CORE/vhdl/main.vhd:1517-1535.
The Amiga port (milestone 1, PAL only) ties the frequency down statically and documents
the exact-0-ppm NTSC MMCM setting for later in the clk.vhd header (Amiga port).

### 3.B.3 Derived clocks inside the core: convert to clock enables

**Symptom:** no Vivado error. Upstream code clocks logic with the output of a divider
register (`reg clk_div; always @(posedge clk) clk_div <= ~clk_div;` ... `always
@(posedge clk_div)`). It will synthesize, but timing analysis now sees an unconstrained
generated clock on fabric routing, hold/skew problems appear, and every signal crossing
between the "divided domain" and the master domain becomes an undeclared CDC.

**Cause:** Quartus projects shipped with `.sdc` files that called `derive_pll_clocks` and
often constrained such dividers; on Xilinx fabric, register-driven clocks additionally
suffer from clock-path-on-general-routing skew (no BUFG).

**Fix:** **RULE:** one master clock per core; everything slower is a one-cycle-wide clock
enable on that master clock. Rewrite `always @(posedge clk_div)` blocks as
`always @(posedge clk) if (ce_div)`. Modern MiSTer cores are largely already structured
this way - verify rather than assume. The Amiga chipset is the model citizen: the whole
machine runs on 28 MHz and rtl/amiga_clk.v (Amiga port) emits `clk7_en`/`clk7n_en` (:7,
one pulse in four), the color clock `cck` (:11) and the one-hot 10-phase E-clock `eclk`
(:12,:64) as enables - the wrapper then feeds them into minimig as ordinary data signals.
The C64 equivalent is the accumulator CE of 3.B.2. If you find a genuine ripple-divider
clock in an older core, rewriting it to a CE is mandatory before any timing work; the M2M
framework also assumes single-clock cores at its `main.vhd` boundary (see the basic
wiring part of this guide).

### 3.B.4 negedge-clocked logic is fine in Vivado - but document and audit it

**Symptom:** none. This is an anti-pattern trap in the other direction: porters coming
from app notes sometimes rewrite `always @(negedge clk)` logic "for Xilinx", introducing
bugs.

**Cause/Why:** Vivado times both edges of a defined clock automatically; falling-edge
clocking is fully supported (FDRE with IS_C_INVERTED, or the C pin driven by the same
BUFG). A negedge process simply gets half a period of setup to the next posedge consumer
- which at Amiga/C64 clock rates (28/32 MHz, i.e. 17+ ns half-periods) is plenty. The M2M
framework depends on this: QNICE accesses all core memories on the FALLING edge of its
50 MHz clock (the `FALLING_A/B` generics of 3.A.2), giving glitch-free pseudo-asynchronous
access from the service CPU.

**Fix:** keep the logic, write down where it is, and check those paths once in the first
timing report. Both repos do exactly that:

- Amiga port CORE/Minimig_MiSTerMEGA65/rtl/cpu_wrapper.v:369-372: "This is the only
  negedge-clk logic in the core (constrain accordingly)" - `always @(negedge clk, negedge
  reset) begin : chipbus_fsm`.
- Amiga port CORE/CORE.xdc:15-18 records the consequence at the constraints level: "...
  cpu_wrapper.v contains a (pruned with cpucfg=00) negedge-clk FSM - both edges of
  main_clk are therefore timed automatically."

**TRAP:** what is NOT automatically safe are asynchronous set/reset pins driven by logic
signals, which some MiSTer code uses as a poor man's latch: Amiga port
rtl/minimig_m68k_bridge.v:148 (`always @(posedge clk or posedge _as_and_cs)` infers an
FDPE whose preset is a bus signal) and rtl/paula_floppy.v:200,:223 (`posedge clk or
negedge IO_ENA`). Vivado synthesizes these; flag them for review in the XDC (Amiga port
CORE/CORE.xdc:45-50 does) because recovery/removal timing on a fabric-driven async pin is
a genuine hazard if the signal is not quasi-static.

### 3.B.5 Old .sdc multicycle/false-path constraints: re-derive, never copy

**Symptom:** none at synthesis. Either you ignore the core's Quartus `.sdc` files and
possibly miss constraints the design genuinely needs, or you transliterate them to XDC
and constrain the wrong paths (Quartus name patterns like `emu|cpu_wrapper|cpu_inst*` do
not match Vivado netlist names anyway).

**Cause:** MiSTer cores ship `.sdc` files written for the DE10-Nano's Cyclone V and the
MiSTer framework hierarchy, e.g. Amiga port CORE/Minimig_MiSTerMEGA65/Minimig.sdc
(`set_multicycle_path -from {emu|cpu_wrapper|cpu_inst*} -to {emu|ram*} -setup 2`, plus
false paths on quasi-static config registers, plus an honest comment "these constraints
aren't really correct, but help fitting") and rtl/fx68k/fx68k.sdc (multicycle 2 from
`Ir[*]` to `microAddr[*]`/`nanoAddr[*]`).

**Fix:** treat the old `.sdc` as DOCUMENTATION of which paths the original author found
slow or quasi-static, not as constraints to port. On the MEGA65:

- The hierarchy is different (no `emu|`, your wrapper instance names instead), so every
  pattern must be re-written - and with M2M you synthesize with `-flatten_hierarchy none`
  precisely so hierarchical XDC patterns remain valid (see Part III, section F).
- The timing situation is different: the Amiga port closed timing at 28 MHz on the
  Artix-7 WITHOUT porting any of the fx68k or Minimig multicycle exceptions (run 2: WNS
  +0.387 ns, all endpoints met - doc/synthesis-handoff.md, "Run 2 ... TIMING CLOSED").
  A multicycle exception you do not need is pure risk.
- The false-path candidates (quasi-static config words like `USERIO1|cpu_config*`) map to
  the CDC strategy of the M2M port instead: synchronizers plus `set_false_path`/
  `set_max_delay -datapath_only` written fresh against your own netlist names (see the
  C64's CORE.xdc drive-sync false paths and the Amiga's ascal `set_max_delay` at Amiga
  port CORE/CORE.xdc:38-43, with a 16-line rationale comment).

**RULE:** add a timing exception only in response to a concrete failing or
absurdly-tight path in YOUR timing report, with a comment explaining why the exception is
safe. The Amiga port's ascal constraint comment (CORE.xdc:22-37) is the template: what
the path is, why the default analysis is wrong, what the bound means physically.

## 3.C Verilog/SystemVerilog constructs Vivado rejects (with exact error codes)

Work through these with Vivado's elaboration loop: open the project, run "Open
Elaborated Design" (or `synth_design -rtl` in a script), fix the first error, re-run.
The C64 port's commits d4745fd, f2a27da, 7855ad6, ffbef1e ("Fix (minor) errors reported
by Vivado") are exactly this loop made visible; the Amiga port did the same in one sweep
(submodule commit cbd0d65, all fixes carried provenance comments). The final subsection
(3.C.10) lists constructs that look suspicious but need NO action - resist the urge to
churn the diff against upstream.

### 3.C.1 Declarations in unnamed blocks: [Synth 8-1873]

**Symptom:**

```text
[Synth 8-1873] declarations not allowed in unnamed block
```

**Cause:** MiSTer code constantly declares working `reg`s inside `always` blocks
(`always @(posedge clk) begin reg old_state; ... end`). Verilog-2001 only allows
block-item declarations in NAMED blocks; Quartus does not enforce this, Vivado does.

**Fix:** name the block - a label after `begin` is the entire fix:

```verilog
// before
always @(posedge clk_sys) begin
   reg old_status;
   ...
// after
always @(posedge clk_sys) begin : label0
   reg old_status;
   ...
```

**Example:** C64MEGA65 commit d4745fd and siblings; surviving labels at
CORE/C64_MiSTerMEGA65/rtl/mos6526.v:154 (`begin : label0`),
rtl/iec_drive/fdc1772.v:174,:284,:365,:739,:808 (label0-label4),
rtl/iec_drive/iecdrv_mos8520.v:143,:443. The Amiga port used descriptive labels instead
of label0-style: rtl/minimig.v:869 `: rtc_reg_blk`, :951 `: rst_blk`, plus blocks in
agnus_bitplanedma.v, denise_bitplanes.v (8 blocks), denise_sprites_shifter.v, ciaa.v,
gayle.v, ide.v, userio.v (Amiga port, commit cbd0d65). Expect dozens per core.

### 3.C.2 Procedural assignment to nets: [Synth 8-2576]

**Symptom:**

```text
[Synth 8-2576] procedural assignment to a non-register <name> is not permitted
```

**Cause:** a signal assigned inside `always`/`always_comb` is declared as `wire` or as a
plain `output`. Quartus silently promotes such nets to variables; Vivado follows the LRM.

**Fix:** make the declaration a variable. The flavors seen in practice (all from
C64MEGA65 commit d4745fd):

```verilog
// 1. output port driven from an always block
-  output  [7:0] par_data_o,
+  output reg [7:0] par_data_o,

// 2. local wire driven from always_comb
-  wire [3:0] nibble_out;
+  reg [3:0] nibble_out;

// 3. multiple outputs in one declaration
-  output [15:0] out1, out2
+  output reg [15:0] out1, out2

// 4. arrays of outputs (SystemVerilog ports)
-  output [31:0] sd_lba[NDR],
+  output reg [31:0] sd_lba[NDR],
```

**Example:** C64MEGA65 commit d4745fd (rtl/iec_drive/c1541_multi.sv, c1541_gcr.sv,
iec_drive.sv sd_* arrays, rtl/sid/sid_top.sv F0, rtl/opl3/compressor.sv out1/out2).

**TRAP:** if the same net is ALSO driven by a continuous `assign` somewhere, converting
it to `reg` produces a new error (procedural + continuous drivers). Then the real
problem is 3.C.7 (multiple drivers) - investigate before mechanically adding `reg`.

### 3.C.3 wire with initializer inside a generate branch, used outside

**Symptom:** elaboration error - the identifier is undeclared outside the `generate`
branch (the wire's scope is the generate block), typically reported as an unknown signal
where the surrounding code uses it.

**Cause:** code like `generate if(GAMMA) begin wire [7:0] R_in = ...; end endgenerate`
declares `R_in` inside the generate scope, then uses `R_in` after `endgenerate`. Quartus
hoists it; Vivado scopes it correctly.

**Fix:** hoist the declaration to module scope; keep per-branch `assign`s inside the
generate:

```systemverilog
wire [7:0] R_in;                                 // hoisted
generate
   if(GAMMA && HALF_DEPTH) begin
      assign R_in = frz ? 8'd0 : {R,R};          // was: wire [7:0] R_in = ...
   end else begin
      assign R_in = frz ? 1'd0 : R;
   end
endgenerate
```

**Example:** C64MEGA65 M2M/vhdl/controllers/MiSTer/video_mixer.sv:91-105 (the file is
MiSTer's sys/video_mixer.sv, ported once into the M2M framework; identical in this
repo's M2M V2.0.1 at M2M/vhdl/controllers/MiSTer/video_mixer.sv:91).

### 3.C.4 Block-local variable declarations WITH initializers

**Symptom:** elaboration error in plain-Verilog mode (iverilog -g2001 words it
"Variable declaration assignments are only allowed at the module level"). Distinct from
3.C.1: the block is already named, but the local declaration has an `= value` initializer.

**Cause:** `reg [5:0] ide_cfg = 0;` inside a named block is a SystemVerilog feature. The
Verilog-2001/2005 grammar's block_item_declaration has no initializer form. Quartus and
Vivado-in-SV-mode accept it; Vivado reading the file as plain Verilog must not.

**Fix:** hoist the declaration to module scope and KEEP the initializer there (module-
level initializers are legal Verilog-2001 and set the power-up value):

```verilog
// before (inside 'always @(posedge clk) begin : config_blk')
   reg [5:0] ide_cfg = 0;
   reg [1:0] cpu_cfg = 0;
// after (module scope, above the block)
reg [5:0] ide_cfg = 0;
reg [1:0] cpu_cfg = 0;
```

The alternative is to read the file as SystemVerilog (3.C.5), but mixing strategies per
file is confusing; the Amiga port hoisted instead.

**Example:** Amiga port submodule commit 9eca30b "Fix LRM violations found by
adversarial review" (rtl/userio.v); current state at
CORE/Minimig_MiSTerMEGA65/rtl/userio.v:426-429 with the rationale comment.

### 3.C.5 SystemVerilog constructs in .v files: [Synth 8-2671] and friends

**Symptom:**

```text
[Synth 8-2671] single value range is not allowed in this mode of verilog
```

(for unpacked-array sizes like `reg [15:0] mem[256];`), or other parse errors that make
no sense for code that "works on MiSTer".

**Cause:** Vivado selects the language mode from the file extension (`.v` = Verilog-2005,
`.sv` = SystemVerilog) unless overridden. MiSTer freely uses SV constructs in `.v` files
because Quartus reads everything permissively.

**Fix:** two valid strategies; pick per file and be consistent:

1. Read the file as SystemVerilog. GUI: Sources -> Source File Properties -> Type =
   SystemVerilog. In a .tcl build script: list it under `read_verilog -sv {...}`. In an
   .xpr, the file's `<FileInfo SFType="SVerilog">` (see 3.H.2). The C64
   reads its whole Verilog list this way (C64MEGA65 CORE/CORE-R6.tcl: `read_verilog -sv`
   block), and rtl/iec_drive/fdc1772.v:25 documents the reason in-source: "Vivado needs
   interpret this as SystemVerilog even though it is 'just' a '.v' file".
2. Fix the construct so the file is genuinely Verilog-2001. For the array case:
   `[256]` -> `[0:255]`. The Amiga port chose this for its single offender:
   rtl/cart.v `reg [15:0] custom_mirror[256];` -> `custom_mirror[0:255]` (Amiga port,
   commit cbd0d65) - after which none of the 51 retained minimig .v files needed
   SystemVerilog typing; only the fx68k .sv files are SystemVerilog (by extension,
   no SFType token), plus the three inherited M2M framework .v files listed in 3.H.2.

**Why** prefer strategy 2 when the count is small: a file typed SystemVerilog gets ALL
of SV's semantics, which can mask other latent issues (and the .xpr type token is an
easy thing to lose when regenerating projects - see 3.H.2).

### 3.C.6 Same local variable in two always blocks: [Synth 8-9339]

**Symptom:**

```text
[Synth 8-9339] data object 'old_vs' is already declared
```

**Cause:** after naming blocks (3.C.1), code that declared the same helper reg inside TWO
different always blocks (legal per-block scoping in SV, sloppy in practice) or that
relied on Quartus merging the scopes now collides or double-declares.

**Fix:** give each block its own variable (`old_vs_1`, `old_vs_2`) - the registers were
always distinct hardware anyway. (Message text from the M2M wiki's porting log, observed
on Arcade-Galaga's sys/arcade_video.v:264; neither the C64 nor the Amiga RTL had an
instance, but you will meet it in cores with copy-pasted edge detectors.)

**TRAP:** do not confuse with 3.C.7. Here two DECLARATIONS collide; in 3.C.7 one declaration
is WRITTEN from two processes. The error codes differ ([Synth 8-9339] vs multi-driver
errors) and so do the fixes.

### 3.C.7 THE BIG ONE: disjoint bit ranges of one reg written from multiple always blocks

**Symptom:** multi-driver errors at elaboration/synthesis (wording varies by Vivado
version - "multi-driven net", "variable ... is driven by more than one process"), or in
older versions silent mis-synthesis. In Quartus this code is and always was legal as long
as the bit ranges are disjoint, which is why older MiSTer cores are full of it and why it
survives upstream untouched.

**Cause:** Verilog allows a variable to be assigned from only one process; Quartus
relaxes this to per-BIT exclusivity, so original Amiga-chipset code freely splits a
register's fields across always blocks:

```verilog
// upstream rtl/agnus_beamcounter.v (Amiga port, submodule base eb7a26e)
output reg [8:0] hpos,            // horizontal beam counter
...
always @(posedge clk) begin       // driver 1: bits [8:1]
   if (clk7_en) begin
      if (reg_address_in[8:1]==VHPOSW[8:1])
         hpos[8:1] <= data_in[7:0];
      else if (end_of_line)
         hpos[8:1] <= 0;
      else if (cck && (~ersy || |hpos[8:1]))
         hpos[8:1] <= hpos[8:1] + 1'b1;
   end
end
always @(cck) hpos[0] = cck;      // driver 2: bit [0], a DIFFERENT process
```

**Fix:** split into one reg per writing process plus a concatenation wire (or `assign`
on a now-plain output port). Two rules make the edit mechanical and reviewable:

1. **Preserve the original bit indices in the declarations.** Declare
   `reg [8:1] hpos_hi;` not `reg [7:0]` - every part-select in the writing process
   (`hpos_hi[8:1] <= ...`) then survives as a pure rename and the diff against upstream
   stays one-token-per-line.
2. **The reassembled name keeps its old name** so all readers are untouched:

```verilog
// ported rtl/agnus_beamcounter.v (Amiga port)
output [8:0] hpos,                          // was: output reg
...
reg [8:1] hpos_hi;                          // driver-1 bits, original indices kept
assign hpos = {hpos_hi[8:1], cck};          // bit 0 was always just cck
```

The full inventory from the Amiga port (commit cbd0d65; this is how often you should
expect it in a 2005-era codebase like Minimig):

- agnus_beamcounter.v `hpos` (above; the worst case, clocked + combinational driver),
  current code at rtl/agnus_beamcounter.v:263-271.
- agnus_blitter.v `bltcon0` written by THREE clocked blocks (ASH/USE/LF fields) ->
  `bltcon0_ash[15:12]`, `bltcon0_use[11:8]`, `bltcon0_lf[7:0]` + concat wire
  (rtl/agnus_blitter.v:141-144); same for `bltcon1` (two blocks).
- agnus_diskdma.v `address_out` ([20:16] and [15:1] in two blocks) -> `_hi`/`_lo` regs.
- denise.v `hdiwstrt`/`hdiwstop` ([7:0] vs bit [8]) -> rtl/denise.v:78-80
  (`hdiwstrt_l`, `hdiwstrt_h8`, `wire [8:0] hdiwstrt = {hdiwstrt_h8, hdiwstrt_l};`).
- paula_floppy.v `dsklen` ([14:0] vs [15]), `motor_on` (four 1-bit drivers!).
- userio.v `memory_config` (output reg; bits [5:0] and [7] latched during reset, bit [6]
  free-running) -> rtl/userio.v:418-421.

**TRAP (combinational for-loops):** agnus_blitter_fill.v wrote `carry[0]` and
`carry[15:1]` from two COMBINATIONAL blocks where the second indexes `carry[j-1]` in a
for-loop - splitting would break the loop indexing, so the correct fix there was merging
both into ONE `always @(*)` block (Amiga port, rtl/agnus_blitter_fill.v). Splitting is
the default; merging is for combinational chains that read their own earlier bits.

**TRAP (don't trust one Vivado version):** whether every instance hard-errors is
version-dependent. Split them ALL anyway - the pattern is illegal Verilog, and a version
upgrade must not change your netlist. The C64 core needed essentially none of this
(2000s-era VHDL/SV codebase, single-writer style throughout - the category simply does
not exist there), which is why all examples here are from the Amiga port.

### 3.C.8 Stray 'end;' - null statements after end

**Symptom:** syntax error at the semicolon (plain-Verilog mode). `end;` inside a
sequential block is an empty statement, which Verilog-2001 does not allow there
(SystemVerilog does).

**Fix:** delete the semicolon.

**Example:** Amiga port commit cbd0d65, rtl/userio.v (one stray `end;` in the host_cmd
FSM; the diff in `git -C CORE/Minimig_MiSTerMEGA65 show cbd0d65 -- rtl/userio.v` shows
the removal with comment "removed stray ';' after 'end' (null statement, not legal
Verilog-2001)").

### 3.C.9 'initial' block ordering and literal sizing

**Symptom:** upstream MiSTer code sometimes places an `initial` block ABOVE the
declarations of the variables it initializes. Current Vivado tolerates the
use-before-declaration (3.C.10), but strict tools reject it and the LRM does not bless it;
the unsized literals (`= 1` on a 1-bit reg) add lint noise on top.

**Fix:** move the `initial` block after the declarations it touches, and size the
literals while you are there:

```verilog
// before (upstream)                      // after (port)
initial begin                             reg rom_32k_i;
   rom_32k_i = 1;                         reg rom_16k_i;
   ...                                    reg empty8k;
end
reg rom_32k_i;                            initial begin
reg rom_16k_i;                               rom_32k_i = 1'b1;
reg empty8k;                                 ...
                                          end
```

**Example:** C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/c1541_multi.sv:101-109
(current); the reorder happened in commit 2051d3f (compare
`git show 189d354:rtl/iec_drive/c1541_multi.sv`, lines 89-97, where the initial block
precedes the regs). Note `initial` blocks on registers ARE honored by Vivado synthesis
(power-up values) - keep them, just order them legally.

### 3.C.10 Non-problems: what NOT to fix

Listed explicitly because porters (and AI assistants) waste time and diff-noise on them:

- **casex/casez are legal Verilog-2001.** No `-sv` needed, no rewrite needed. Amiga port
  rtl/paula_floppy.v:240 (`casex ({cmd_cnt, cmd_fdd, trackrd, trackwr})` with x-digits in
  the items) and rtl/paula_intcontroller.v:152 (`casez (intreqena[14:0])`) synthesize
  fine in plain mode.
- **Use-before-declaration of module-scope signals is accepted by Vivado.** Pervasive in
  minimig (minimig.v `ovl`/`rtc_reg`/`_rst`, gayle.v `port_num`, agnus.v `hpos`/`vpos`,
  ...). iverilog flags it; Vivado does not care. **RULE:** do not reorder declarations
  just to silence a linter - every needless line moved is upstream-merge pain later.
- **[Synth 8-7137] "Register ... has both Set and Reset with same priority"** is a
  WARNING about possible simulation/hardware mismatch, not an error. The Amiga run-1 log
  has four (cpu_wrapper.v:387/:405, paula_floppy.v:208/:214 - recorded as benign,
  doc/synthesis-handoff.md "Later-milestone cleanups"). Review them once, then leave
  them.
- **$readmemb/$readmemh ARE supported by Vivado synthesis** for ROM/RAM initialization.
  The fx68k microcode ROMs load this way (Amiga port rtl/fx68k/fx68k.sv:2480,:2493). The
  only thing that needs fixing is the PATH, which - like 3.A.2's INITFILE - resolves
  relative to the synthesis run directory, not the source file:
  `$readmemb("../../Minimig_MiSTerMEGA65/rtl/fx68k/microrom.mem", uRam);` (commit
  051864a). Path rules in detail: Part III, section G.
- **`<= #1` intra-assignment delays** (everywhere in agnus/denise/paula) are ignored by
  synthesis; harmless. Same for `// altera message_off` comment pragmas and
  `2'bxx` don't-care defaults in FSM case items.

## 3.D VHDL constructs

MiSTer cores carry less VHDL than Verilog, but what they carry is old (T65, Gideon-style
peripherals, generic RAM wrappers) and was only ever compiled by Quartus' permissive
analyzer. The patterns below also cover the two places where VHDL meets the rest of the
project: the mixed-language boundary (3.D.4) and the language-mode setting per file (3.D.7).

### 3.D.1 Direct instantiation requires the 'entity' keyword - and order your design units

**Symptom:** analysis/elaboration error at an instantiation written as
`label : work.entity_name` (Vivado wordings vary: syntax error, or the name is not
recognized as a component). A second, related failure: an entity instantiated before the
file position where it is defined within the SAME file is not found.

**Cause:** two Quartus tolerances at once.

1. The VHDL LRM's direct-instantiation syntax is
   `label : entity work.entity_name`. Bare `label : work.entity_name` is illegal VHDL
   that Quartus accepted for years; Vivado (and ghdl/nvc) reject it.
2. Vivado analyzes a file top-to-bottom; a design unit must be analyzed before it is
   referenced. Quartus is order-insensitive within a file, so MiSTer wrapper files often
   define `spram` (the user) ABOVE `spram_sz` (the used entity).

**Fix:** add the keyword, and reorder design units so referenced entities precede their
users:

```vhdl
-- before (Quartus-only)
spram_sz : work.spram_sz
ram      : work.dpram_dif generic map(addr_width,data_width, ...)
-- after
spram_sz : entity work.spram_sz
ram      : entity work.dpram_dif generic map(addr_width,data_width, ...)
```

**Example:** Amiga port submodule commit 9eca30b ("add mandatory 'entity' keyword to
direct instantiations ... reorder design units so referenced entities precede their
users"); current state CORE/Minimig_MiSTerMEGA65/rtl/bram.vhd:186 and :385 (with
provenance comments), unit order ENTITY spram_sz at :72 before its user spram at :162,
dpram_dif at :217 before dpram at :354. C64 precedent: commit d4745fd changed
rtl/cpu_6510.vhd `cpu: work.T65` to `cpu: entity work.T65`.

**Why** this matters doubly: the same fix makes the file acceptable to ghdl/nvc, which
you want for cheap static checking before each Vivado round-trip (the Amiga port's
commit message records "now passes GHDL 5.1 and nvc 1.21 in VHDL-93 mode").

### 3.D.2 Missing sensitivity-list entries: Vivado synthesizes what you wrote, not what you meant

**Symptom:** NO error. Quartus historically synthesizes the implied-combinational
behavior regardless of the sensitivity list; Vivado also synthesizes combinational logic
(synthesis ignores sensitivity lists) BUT (a) it emits latch/sensitivity warnings you
must read, and (b) your SIMULATION now disagrees with both synthesis results, so you
debug ghosts. In the worst case the incomplete list hides a real combinational loop or
latch that the two tools resolve differently.

**Cause:** hand-maintained sensitivity lists in big combinational decode processes;
upstream authors add a signal to the body and forget the list.

**Fix:** two options, both used in the C64 port:

1. Add the missing signal(s). C64MEGA65 commit 68fca2e "Add missing signal to
   sensitivity list" - a one-line fix adding `cs_UMAXnomapLoc` to the giant bus-decode
   process in rtl/fpga64_buslogic.vhd.
2. Convert the process to VHDL-2008 `process(all)` so the problem class disappears.
   C64MEGA65 commit b439b84 did this in rtl/fpga64_sid_iec.vhd (`process(clk32)` ->
   `process(all)` on a process that was effectively combinational). **This requires the
   file to be compiled as VHDL-2008** - see 3.D.7.

**RULE:** when you touch a MiSTer VHDL file for any other reason, scan its combinational
processes' sensitivity lists once. Every missing entry is a future
simulation-vs-hardware divergence.

### 3.D.3 The Vivado alias-write bug: writes to an alias of a vector slice are dropped

**Symptom:** SILENT misbehavior, no message of any kind. A signal assignment whose
target is an `alias` of a vector slice (e.g. `alias timer_a_flag : std_logic is
irq_flags(6); ... timer_a_flag <= '1';`) synthesizes to nothing - the flip-flop never
changes. Simulation is correct; hardware is wrong. Observed in the Vivado
2019.2-2021.2 era during the C64 port (the 1541 drive's VIA timer IRQ flag never set).

**Cause:** Vivado synthesis bug in alias resolution for write targets.

**Fix:** eliminate the alias: declare a discrete signal, write that, and recombine
manually wherever the full vector is read:

```vhdl
-- before
signal irq_flags    : std_logic_vector(6 downto 0) := (others => '0');
alias  timer_a_flag : std_logic is irq_flags(6);
...
data_out <= irq_out & irq_flags;

-- after (commit 7a264a2 "Workaround for nasty Vivado bug")
signal irq_flags    : std_logic_vector(5 downto 0) := (others => '0');
signal timer_a_flag : std_logic;
...
data_out <= irq_out & timer_a_flag & irq_flags(5 downto 0);
```

**Example:** C64MEGA65 CORE/C64_MiSTerMEGA65/rtl/iec_drive/iecdrv_via6522.vhd, commit
7a264a2 (the diff shrinks `irq_flags` to 5:0 and splits bit 6 out everywhere).

**RULE:** whether current Vivado versions (2022.x+) still mis-handle alias writes is
unverified - nobody has re-tested, and the cost of being wrong is a silent hardware bug.
Grep every VHDL file for `alias` EARLY in the port and rewrite write-targets
unconditionally. Read-only aliases are safe.

### 3.D.4 Mixed-language boundary: lowercase port names, no Verilog keywords - [Synth 8-448]

**Symptom (verbatim, preserved in-source at C64MEGA65 rtl/t65/T65.vhd:140-152):**

```text
[Synth 8-448] named port connection '...' does not exist for instance 'cpu' of
module 'T65' [.../rtl/iec_drive/c1541_logic.sv:77]
```

**Cause:** when a VHDL entity is instantiated FROM (System)Verilog, Vivado matches port
names case-sensitively against a lowercased view of the VHDL entity. VHDL is
case-insensitive, so MiSTer's mixed designs use whatever casing Quartus tolerated
(`Res_n`, `Clk`, `DO`). Two distinct failures result:

1. Any port whose VHDL declaration is not all-lowercase cannot be connected by name from
   SV.
2. A port that lowercases to a Verilog KEYWORD (`do`, `if`, ...) cannot be connected at
   all.

**Fix:** rename the VHDL ports to lowercase, and rename keyword-colliding ports to
something else project-wide. In T65 (commit af9eca6): all ports lowercased
(`Res_n -> res_n` etc.) because c1541_logic.sv and c1581_drv.sv instantiate it; `DO`/`DI`
could not become `do`/`di` (`do` is a Verilog keyword), so they became `dout`/`din`
(T65.vhd:178-179), with every reference adjusted. The long in-source comment block at
T65.vhd:140-152 is there specifically as upstream-merge insurance - copy that habit.

**The same trap in the other direction** (Verilog module instantiated from VHDL) is
harmless - Verilog port names are case-sensitive and VHDL association is
case-insensitive, Vivado handles it. And note the Amiga corollary: minimig's ports begin
with underscores (`_cpu_as`), which are ILLEGAL VHDL identifiers, so the port's VHDL
wrapper could not name them at all; the fix was a thin Verilog shim renaming them to a
`_n` suffix convention (Amiga port, submodule commit 051864a, rtl/minimig_m65.v) - if
your main.vhd is VHDL and the core top is Verilog, audit the port names for VHDL
legality, not just case.

**RULE:** before wiring main.vhd, list every module that crosses the language boundary
and normalize: lowercase, no leading underscores, no keywords in either language.

### 3.D.5 Universal-integer array bounds: write 'natural range' for portability

**Symptom:** Vivado accepts `type ram_t is array (0 to 2**addr_width-1) of ...;`
unchanged - but ghdl/nvc in strict LRM mode reject or warn on generic-dependent
universal-integer bounds, and you want those tools in your loop (see 3.D.1 Why).

**Cause:** the index range of an unconstrained-integer expression defaults to type
universal_integer; strict analyzers demand an explicit index subtype when bounds depend
on generics.

**Fix:** qualify the range:

```vhdl
type ram_t is array (natural range 0 to 2**addr_width_a - 1)
   of std_logic_vector(data_width_a - 1 downto 0);
```

**Example:** Amiga port CORE/Minimig_MiSTerMEGA65/rtl/bram.vhd:93,:248,:439 (commit
9eca30b, "'natural range' on generic-dependent array bounds (GHDL strictness)"). Vivado
behavior is identical with and without; this is purely a portability hardening so your
offline checkers stay clean.

### 3.D.6 Shared-variable true-dual-port templates: [Synth 8-4747] is expected

**Symptom (verbatim, Amiga run-1 log CORE/CORE-R3.runs/synth_1/runme.log:142-143):**

```text
WARNING: [Synth 8-4747] shared variables must be of a protected type
[.../CORE/Minimig_MiSTerMEGA65/rtl/bram.vhd:249]
```

**Cause:** the UG901-sanctioned template for a true-dual-port BRAM with two write ports
uses a non-protected `shared variable ram : ram_t;` written from two clocked processes.
That is the VHDL-93 idiom; VHDL-2002+ requires shared variables to be protected types,
so when the file is analyzed as VHDL-2008 Vivado emits this warning - and then
synthesizes the correct TDP BRAM anyway.

**Fix:** none - accept the warning. There is no LRM-clean alternative: a protected type
is not synthesizable, and two processes cannot both write a plain `signal`. This is the
ONE sanctioned use of shared variables in synthesis (3.A.3's dprom and 3.A.6's dpram_dif all
use it). If the warning bothers you, mark the file as plain VHDL (not VHDL-2008) IF it
needs no 2008 features - bram.vhd (Amiga port) is deliberately written VHDL-93-compatible
for that reason, though the project currently compiles it in 2008 mode and tolerates the
two warnings.

**TRAP:** do not "fix" it by merging the two write processes or demoting to one write
port without checking all consumers; the C64's dprom (3.A.3) and the ide.v io_buf dprams
(3.A.6) genuinely need write ports on both sides (core writes, QNICE/host writes).

### 3.D.7 VHDL-2008 features require the VHDL-2008 file type - per file

**Symptom:** analysis errors on perfectly good VHDL-2008: `process(all)` rejected,
or - the classic from the M2M wiki's porting notes - **"port map is not a static name or
globally static expression"** when an expression or a function call is used as a port
actual.

**Cause:** Vivado's default VHDL mode is VHDL-93-ish; 2008 features are opt-in PER FILE.

**Fix:** mark the file VHDL-2008 in whatever drives your build:

- Tcl build script: `read_vhdl -vhdl2008 { ... }` - the C64 compiles its entire VHDL
  list this way (C64MEGA65 CORE/CORE-R6.tcl:10).
- .xpr project (the Amiga port): per-file `<FileInfo SFType="VHDL2008">` (Amiga port
  CORE/CORE-R3.xpr:92 and following). GUI: Source File Properties -> Type = VHDL 2008.
- The M2M framework's own files already expect 2008 mode (the template project ships
  with the types set; see 3.H.2 for the .xpr file-type token pitfalls).

Features you will actually use and that need the flag: `process(all)` (3.D.2), expression/
function-call port actuals, `unsigned`/`signed` condition operators and other 2008
conveniences in new wrapper code. Conversely, files using the shared-variable TDP
template (3.D.6) generate a warning in 2008 mode - both type choices are defensible; just
choose deliberately and per file.

**TRAP:** when Vivado regenerates or you hand-edit the .xpr, the file-type tokens are
easy to corrupt or lose - the Amiga port's git history contains both failure modes
("Fix .xpr file-type tokens that crashed Vivado's project parser", parent repo commit
9201048, and the follow-up alignment commit d861f56). After any project-file surgery,
re-open Vivado and check the Sources tab's Type column before trusting a synthesis run.

---

## 3.E The mixed-language boundary (VHDL <-> Verilog/SV)

Every M2M port is a mixed-language design: the framework and your `main.vhd`/`mega65.vhd` are VHDL, the MiSTer core is (System)Verilog. Quartus and Vivado both support mixed language, but their binding rules differ in exactly the places that bite during a port. This section is the complete rule set for M2M V2.0.1 under Vivado.

### 3.E.1 How binding works: by name, per direction

Vivado binds across the language boundary purely by name. There are no cross-language configurations or libraries to set up; the elaborator looks up the instantiated unit by its name and matches the ports by their names. The case rules are asymmetric:

**RULE (VHDL instantiates Verilog):** declare a VHDL `component` whose name matches the Verilog module name and whose port list replicates every Verilog port name. Matching is case-insensitive on the VHDL side (VHDL identifiers have no case), but the Verilog spelling is authoritative: if the Verilog module has port `IO_STROBE`, your component port `io_strobe` binds fine, because case-insensitive lookup resolves it - but two Verilog ports that differ only in case cannot both be reached from VHDL. Widths must match exactly; the index direction may be re-expressed, so a Verilog `[23:1]` port is correctly declared as `std_logic_vector(23 downto 1)` in the component (see C64MEGA65 `CORE/vhdl/main.vhd:499-526`, the `component reu` declaration mirroring `CORE/C64_MiSTerMEGA65/rtl/reu.v`; note it even declares `cpu_addr : in unsigned(15 downto 0)` against a Verilog `[15:0]` port - Vivado maps any one-dimensional array of std_ulogic-class elements onto a Verilog vector, so `unsigned`/`signed`/`std_logic_vector` all work).

**RULE (Verilog/SV instantiates VHDL):** the lookup is case-sensitive and the VHDL unit is normalized to lowercase, so the Verilog caller must spell the entity name and all port names in lowercase, or you get `[Synth 8-448] named port connection '...' does not exist`. This is documented in the C64 port itself: C64MEGA65 `CORE/C64_MiSTerMEGA65/rtl/t65/T65.vhd:140-153` records that the `T65` entity had to be instantiated as lowercase from `c1541_logic.sv`, with the error message and the Xilinx support link preserved in the comment.

**TRAP (Verilog keywords in VHDL port names):** a VHDL port that is legal VHDL but a Verilog keyword cannot be connected from a (System)Verilog caller at all. The C64 port hit this with T65's classic `DO` data-output port: lowercased it becomes `do`, a Verilog keyword. The fix was a project-wide rename `DO`/`DI` -> `dout`/`din` (T65.vhd:151-152). Scan any VHDL entity that Verilog will instantiate for names like `do`, `reg`, `wire`, `output`, `input`, `begin`, `table`.

**TRAP (direct instantiation syntax):** Quartus accepts `cpu: work.T65 port map (...)`; the LRM and Vivado require the `entity` keyword: `cpu: entity work.T65 port map (...)`. The C64 port had to fix this in `rtl/cpu_6510.vhd` (the corrected form is at C64MEGA65 `CORE/C64_MiSTerMEGA65/rtl/cpu_6510.vhd:58`); the Amiga port's rewritten `bram.vhd` documents the same fix ((Amiga port) `CORE/Minimig_MiSTerMEGA65/rtl/bram.vhd:383-385`: "bare 'work.dpram_dif' is LRM-illegal; only Quartus tolerated it").

### 3.E.2 Leading-underscore Verilog ports: the rename shim

MiSTer cores of Amiga lineage use a Minimig-era convention where active-low signals carry a leading underscore: `_hsync`, `_vsync`, `_cpu_as`, `_cpu_dtack`, `_joy1`, `_ram_we`, and so on. `_hsync` is a perfectly legal Verilog identifier and a flatly illegal VHDL basic identifier (VHDL identifiers must start with a letter). You therefore cannot write a VHDL component declaration for such a module, and `main.vhd` cannot instantiate it.

There are two escape hatches:

1. **VHDL extended identifiers** (`\_hsync\ : out std_logic`). Legal VHDL since 1993 and Vivado accepts them, but support is uneven across the rest of the toolchain (simulators, linters, netlist viewers, XDC name matching after flattening), and every signal touch drags backslashes through your code. Treat this as a last resort.

2. **A thin Verilog rename shim** - the robust pattern. Write one Verilog module that instantiates the underscore-ported module by named association (Verilog can of course spell `._cpu_as(...)`), renames every port to a legal, M2M-conventional name on its own boundary, and ties off everything your milestone does not use. The shim must contain *no logic*: pure renaming and constant tie-offs, so it adds nothing to verify and constant-folds away in synthesis.

The worked example is (Amiga port) `CORE/Minimig_MiSTerMEGA65/rtl/minimig_m65.v` - C64MEGA65 has no equivalent because none of the C64 core's modules use underscore ports (verified by grep over its rtl/). The shim:

- renames active-low `_x` ports to the M2M `x_n` suffix convention (`._cpu_as` -> `cpu_as_n`, `._hsync` -> `hsync_n`, ...) - minimig_m65.v:107-114, 174-175;
- ties off whole unused subsystems at inactive levels so `main.vhd` stays clean and the logic prunes: RS232 inputs high (lines 140-147), `_joy3`/`_joy4` to `16'hFFFF` (active low, idle; lines 152-153), `chip48` to `48'h0` (AGA-only; line 126), `rtc` to `65'b0` (line 163), the whole IDE port group to zeros (lines 212-220);
- absorbs width mismatches explicitly: minimig's `ram_address[23]` is constant after a port-side change, so the shim concatenates a dummy wire and exposes only `[22:1]` (lines 98-99, 121).

On the VHDL side, `main.vhd` then declares the shim as an ordinary component with the now-legal names ((Amiga port) `CORE/vhdl/main.vhd:114-178`, instantiated at line 463). The header comment at main.vhd:96-98 states the contract: "Mixed-language binding is by name; all port names are legal VHDL identifiers (see rtl/minimig_m65.v)".

**Why** a shim and not editing minimig.v itself: the underscore names appear hundreds of times inside the core and in every upstream diff you will ever want to merge. The shim quarantines the rename at one boundary file you own.

### 3.E.3 Generics/parameters across the boundary

Verilog callers can parameterize VHDL entities, including positionally. The live example: (Amiga port) `CORE/Minimig_MiSTerMEGA65/rtl/ide.v:285` and `:300` instantiate the VHDL entity `dpram` as `dpram #(12,16) io_buf0 (...)`. Positional association maps onto the VHDL generic declaration order, here `addr_width` then `data_width` (bram.vhd:354-359). **RULE:** if you rewrite such a VHDL entity (as the Amiga port did when replacing the altsyncram wrappers), you must preserve the generic order, or switch every Verilog caller to named association (`#(.addr_width(12), .data_width(16))`). The string generic `mem_init_file` after them is safely defaulted.

Unconnected VHDL ports with default expressions also work from Verilog callers: ide.v leaves `enable_a/enable_b/cs_a/cs_b` unconnected and relies on the `:= '1'` defaults at bram.vhd:366-376. Vivado honors this. (The reverse - a Verilog port left dangling from a VHDL caller - requires an explicit `open` in the port map, or simply omit the port from the component declaration if you never touch it; the shim instead connects them all and dangles unused outputs on its own Verilog side with empty named associations, e.g. `.ldata_okk( )`, `.rdata_okk( )`, `.aud_mix( )` at minimig_m65.v:193-195, which is the cleaner discipline.)

### 3.E.4 What cannot cross the boundary

**RULE:** SystemVerilog constructs richer than plain vectors do not cross into VHDL. You cannot instantiate, from VHDL, an SV module whose ports are packed structs, unpacked arrays, enums, or SV interfaces/modports - Vivado's mixed-language elaboration only maps scalar and one-dimensional vector ports. If a MiSTer module exposes such ports, write an SV wrapper that flattens them to plain vectors and instantiate the wrapper from VHDL. SV-internal richness is fine: fx68k.sv uses structs, enums and `unique case` internally but exposes only plain ports, which is why `cpu_wrapper.v` (Verilog) and ultimately `main.vhd` can use it untouched.

Related, not strictly boundary issues but always co-occurring: `.v` files that use SV constructs must be compiled as SystemVerilog. In the C64 port's build this is an explicit `read_verilog -sv { ... }` list (C64MEGA65 `CORE/CORE-R6.tcl:136`); in project mode (section 3.H) it is the per-file `SVerilog` file type. A plain-Verilog file misclassified as Verilog-2001 dies on the first `logic` or `always_ff`.

## 3.F CDC and constraints (M2M-specific + general)

MiSTer cores are effectively single-clock designs (clk_sys plus enables); the M2M environment is not. Your core clock, the 50 MHz QNICE clock, the HyperRAM clock, the HDMI/video clocks and the audio clock all coexist, and every signal that moves between them is a clock domain crossing that Quartus never had to see. This chapter covers what the framework already handles, what you must handle, and how to constrain it.

### 3.F.1 What the framework crosses for you

M2M V2.0.1's `framework.vhd` contains a central CDC block (M2M `vhdl/framework.vhd:721-846`). You get, without writing anything:

- QNICE -> core: one 615-bit `xpm_cdc_array_single` (framework.vhd:776-808) carrying the CSR bits (reset, pause, keyboard/joystick enables), the full 256-bit OSM control vector, the 256-bit general-purpose register block, paddle values and the 65-bit RTC vector. This is why `main_osm_control_i` and `main_qnice_gp_reg_i` arrive in `main.vhd` already synchronized to your core clock.
- core -> QNICE: the 16-bit keyboard vector `main_qnice_keys_n` (framework.vhd:749-758).
- core -> audio: `cdc_stable` on the 2x16-bit audio samples (framework.vhd:761-773).
- resets into every domain via `xpm_cdc_async_rst` (M2M `vhdl/clk_m2m.vhd:165-192`).
- vdrives traffic in both directions (M2M `vhdl/vdrives.vhd:237-273`).

**RULE:** treat these as solved. Your CDC work is exactly (a) memories shared with QNICE, (b) signals you route yourself between your own clocks, and (c) CDC that is *hidden inside the MiSTer core* (3.F.4).

### 3.F.2 QNICE-shared memories: dualport_2clk_ram and the falling-edge contract

QNICE accesses core memories (ROM loading, debugging, cartridge/disk buffers) through the second port of M2M's `dualport_2clk_ram` (M2M `vhdl/2port2clk_ram.vhd:13`). The convention: port A belongs to the core on its rising edge, port B to QNICE with `FALLING_B => true` - QNICE registers its bus on the falling edge of its 50 MHz clock, which gives every QNICE<->BRAM path only a half period (10 ns) of setup budget but makes the crossing race-free by construction (the framework relies on this everywhere; see C64MEGA65 `CORE/vhdl/mega65.vhd:972-980`, where the comment spells it out: "C64 expects read/write to happen at the rising clock edge" / "QNICE expects read/write to happen at the falling clock edge"). The Amiga Kickstart ROM uses the same pattern ((Amiga port) `CORE/vhdl/mega65.vhd:669-693`, `FALLING_B => true`).

**TRAP (the Amiga lesson):** only give a QNICE port to memories that actually need one. A QNICE port means the QNICE address/data/control nets must reach every BRAM tile of that memory within the 10 ns half-period. For a small ROM that is trivial; for a die-spread memory it is fatal. The Amiga port initially wired QNICE debug ports to the 512 KB chip RAM + 512 KB slow RAM (256 RAMB36 tiles spread across the whole xc7a200t die) and failed timing with WNS -0.757 ns on exactly those paths; the fix was to remove the QNICE port entirely and tie port B off (AExp commit fcf0a90: "the QNICE address bus cannot reach all 256 die-spread BRAM tiles within the falling-edge half-period"; the resulting tie-off with the explanatory comment is at (Amiga port) `CORE/vhdl/mega65.vhd:587-607`). The Kick ROM port (64 tiles, required for the mandatory auto-load) stayed and meets timing.

### 3.F.3 Quasi-static configuration signals: xpm vs. kept 2-FF synchronizers

Two valid patterns exist for slow-moving multi-bit config words, and the C64 history documents when to use which:

1. `xpm_cdc_array_single` - what the framework itself uses. Synchronizes each bit independently; therefore only safe when the consumer tolerates bits arriving in different cycles (true for resets, enables, OSM menu bits - each bit is an independent boolean).
2. Keep the MiSTer core's own 2-FF synchronizers (sorgelig's `iecdrv_sync` style) and declare the input paths false in the XDC. This is mandatory for multi-bit *words* whose value is consumed as a whole. **Why:** per-bit synchronization can deliver a torn word for one cycle - C64 submodule commit 90e44b5 ("Roll-back CDC fixes using XDC macros") records the decision: "Sorgelig's solution is preferable ... precisely because [xpm_cdc_array_single] treats each bit individually, and therefore there may be glitches. Sorgelig's solution avoids glitches, but requires the input to be sufficiently slowly varying ... But we need to add the correct constraints (e.g. false paths)."

Those "correct constraints" live in C64MEGA65 `CORE/CORE.xdc:11-22`: `set_false_path -from [get_pins -hier id1_reg[*]/C]` etc. for the manually-synchronized IEC drive signals, plus false paths from/to the very slow `dtype_reg` mount-type register.

**RULE:** hierarchical pin names in your XDC only survive if synthesis keeps the hierarchy. Both reference ports synthesize with `-flatten_hierarchy none` - in the C64 Tcl flow explicitly (C64MEGA65 `CORE/CORE-R6.tcl:158`), in the Amiga project flow via the synthesis strategy option in the .xpr (`<Option Id="FlattenHierarchy">1</Option>`, CORE-R3.xpr:1083, which the run executes as `synth_design -top mega65_r3 ... -flatten_hierarchy none` - verified in `CORE/CORE-R3.runs/synth_1/runme.log:15`). Do not change this option; half the framework's and your constraints silently stop matching if you do.

XPM availability: in a non-project Tcl flow you must enable it yourself - `set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO} [current_project]` (C64MEGA65 `CORE/CORE-R6.tcl:9`). In project mode (.xpr, the M2M V2.0.1 default) Vivado auto-detects XPM usage; the Amiga run log shows "28 XPM XDC files have been applied to the design" with no manual property.

### 3.F.4 Hidden CDC inside the MiSTer core

**TRAP:** a MiSTer module with two clock *ports* is not necessarily CDC-safe - on MiSTer both ports usually receive the same clk_sys, so no synchronizers were ever needed or written. On the MEGA65 you may feed them different clocks and create real, unprotected crossings. The canonical case: the C64 port's 1541 "Dual ROM" mode fed the drive ROM's second port from the QNICE clock and could not close timing; C64 submodule commit 2051d3f ("1541 Dual ROM: Fixed Clock Domain Crossing") explains: "while the original MiSTer implementation offered two clock inputs (clk and clk_sys), there was no clock domain crossing implemented. MiSTer works in one clock domain which is why nobody noticed so far, but we work in two." The fix added explicit synchronizers in `rtl/iec_drive/c1541_multi.sv`. Audit every dual-clock primitive in the core for which domains you actually connect.

### 3.F.5 The framework's CDC helper entities

For crossings you build yourself, M2M V2.0.1 ships three helpers in `M2M/vhdl/`:

- `cdc_stable` (cdc_stable.vhd): for slowly varying data, double-FF per bit with `ASYNC_REG` attributes, optional source register (`G_REGISTER_SRC`). Its required constraint is already in the framework: M2M `common.xdc:32-33` applies `set_max_delay 8 -datapath_only` from all clocks to the `*cdc_stable_gen.dst_*_d_reg[*]/D` destination pins (the entity's header comment, cdc_stable.vhd:8-9, tells you the same line in case you instantiate it under a clock the pattern misses).
- `cdc_pulse` (cdc_pulse.vhd): toggle-based single-pulse crossing; the pulse must be 1 source cycle wide and pulses must be at least 4 cycles of the slower clock apart (header comment, cdc_pulse.vhd:5-8).
- `cdc_slow` (cdc_slow.vhd): like cdc_stable but with a valid handshake - "only propagate when all bits are stable", for multi-bit words that must arrive untorn.

### 3.F.6 Unrelated MMCM clocks and async-FIFO data paths: the Amiga timing war story

The M2M video pipeline crosses pixel data through ping-pong buffers inside ascal (core clock -> HyperRAM clock -> HDMI clock). These clocks come from *different MMCMs* and are unrelated, but Vivado does not know that: by default it times every path between any two clocks at their worst-case edge alignment. Between, say, 28.375 MHz and 100 MHz from different MMCMs that worst case can be tens of *picoseconds* - a requirement that is impossible by construction and meaningless besides.

This is exactly what the first Amiga R3 run produced: WNS -6.7 ns / TNS -1317 ns. The framework's false-path patterns in M2M `common.xdc:113-117` cut the ascal *handshake registers* (`set_false_path ... -regexp ".*/i_ascal/i_.*_reg.*/C" ...`), but the *data* path through the ascal double buffers was still timed, because those buffers synthesize to LUTRAM whose launch pin is `/CLK`, not the `/C` the regexps match (see 3.F.7). Worse than the bogus setup numbers, the *hold* analysis on these paths made the router insert huge detours (7.5 ns on fanout-1 nets between adjacent slices), and those detours poisoned legitimate same-clock paths sharing the routing.

The fix ((Amiga port) `CORE/CORE.xdc`, "ascal asynchronous FIFO data crossings" block):

```tcl
set_max_delay -datapath_only 10.000 \
   -from [get_cells -hierarchical -regexp {.*/i_ascal/i_dpram_reg.*}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/avl_dr_reg\[[0-9]+\]}]
set_max_delay -datapath_only 13.400 \
   -from [get_cells -hierarchical -regexp {.*/i_ascal/o_dpram_reg.*}] \
   -to   [get_cells -hierarchical -regexp {.*/i_ascal/o_dr_reg\[[0-9]+\]}]
```

**RULE:** for any data path between unrelated clocks that is already made safe by a handshake/gray-code protocol, constrain it with `set_max_delay -datapath_only <destination clock period>`. This (a) bounds data staleness to one destination period, (b) removes clock skew/jitter from the calculation, and (c) implies no hold check on the path - which is what stops the router detours. After this fix (plus 3.F.2) the second run closed at WNS +0.387 ns (`doc/synthesis-handoff.md`, "Run 2 (2026-06-11): TIMING CLOSED").

### 3.F.7 XDC pattern-matching traps

- **TRAP (register patterns miss LUTRAM):** `get_pins ... "*_reg*/C"` matches flip-flop clock pins only. Distributed RAM (LUTRAM) cells launch from a pin named `/CLK`, and BRAMs from `/CLKARDCLK` etc. A "covering" false-path written against `/C` silently exempts nothing for memory-launched paths - the ascal case above is the live example (the cells are `i_dpram_reg.*` LUTRAMs; M2M common.xdc:113-117 missed them). When you write or audit such patterns, check the timing report's actual start points.
- **TRAP (`-regexp` is full-match):** `get_pins -hierarchical -regexp {pattern}` must match the *entire* hierarchical name - Vivado anchors both ends. Write `{.*/i_ascal/o_dr_reg\[[0-9]+\]}`, not `{i_ascal/o_dr_reg}`. A pattern that quietly matches nothing produces no error unless you add `-quiet`-free checking; run `report_exceptions` or query the pattern in the Tcl console of the implemented design to confirm it binds.
- `set_false_path -quiet` (as the framework uses for the ascal patterns) suppresses the "no objects matched" warning - convenient for constraints shared across cores where a unit may be absent, dangerous for your own core-specific constraints. Do not use `-quiet` while bringing the design up.

### 3.F.8 Clock definitions, case analysis, and where constraints live

- **create_generated_clock for your core MMCM output:** name the clock the rest of your XDC will reference. C64MEGA65 `CORE/CORE.xdc:9`: `create_generated_clock -name main_clk [get_pins CORE/clk_gen/i_clk_c64_orig/CLKOUT0]`; Amiga identically with `CORE/clk_gen/i_clk_main/CLKOUT0` ((Amiga port) `CORE/CORE.xdc`). **Why:** Vivado auto-derives MMCM clocks with unwieldy names; naming them up front keeps later constraints readable and stable, and the definition must appear before any statement that uses the name.
- **set_case_analysis for build-time/run-time muxed clocks:** when a clock mux selects between two frequencies and you only ever need to close timing at one of them, pin the select: C64MEGA65 `CORE/CORE.xdc:5-7`: "Assume the core is running at the original (slightly faster) clock. This halves the number of set_false_path needed" - `set_case_analysis 0 [get_pins CORE/hr_core_speed_reg[0]/Q]`.
- **INFO [Project 1-236] is expected, not an error:** constraints that target synthesized cell names (everything hierarchical) cannot bind during synthesis elaboration; Vivado reports "Implementation specific constraints were found ... will be ignored for synthesis but will be used in implementation" for M2M's XDCs and your CORE.xdc alike (verified in `CORE/CORE-R3.runs/synth_1/runme.log:1546-1566` of the Amiga run). Only worry if the constraint then fails to bind at *implementation*.
- **Ownership:** `CORE/CORE.xdc` is yours - all core-specific constraints go there. `M2M/common.xdc` and `M2M/MEGA65-RX.xdc` are framework files: do not edit them in your port; if a framework constraint is wrong or incomplete (as with the ascal LUTRAM gap above), add the missing constraint to CORE.xdc with a comment marking it as an upstreaming candidate, exactly as the Amiga CORE.xdc does ("constrained here because M2M/common.xdc must not be modified - candidate for upstreaming").

## 3.G ROM/init data handling

MiSTer cores ship lookup tables and boot ROMs as `$readmem` files or Quartus .mif files; M2M adds the QNICE firmware ROM and optional VHDL-preloaded memories. All of them share one failure mode under Vivado: a path that resolves differently than under Quartus, producing a silently empty memory.

### 3.G.1 $readmem path resolution: the run-directory convention

**RULE:** in Vivado project mode, a relative path in `$readmemb`/`$readmemh` resolves against the *synthesis run directory*, i.e. `CORE/CORE-RX.runs/synth_1/` - not against the location of the source file (Quartus' behavior) and not against the project root. Two `../` therefore land in `CORE/`, three in the repo root.

The C64 port established the convention of writing paths from that anchor; the precedent is the INITFILE parameters in C64MEGA65 `CORE/C64_MiSTerMEGA65/rtl/iec_drive/c1541_multi.sv:142` and `:183`:

```systemverilog
.INITFILE("../../C64_MiSTerMEGA65/rtl/iec_drive/c1541_rom.mif.hex"),
```

(`synth_1` -> `CORE-RX.runs` -> `CORE/` -> into the submodule.) The Amiga port follows it for the fx68k microcode ((Amiga port) `CORE/Minimig_MiSTerMEGA65/rtl/fx68k/fx68k.sv:2476-2493`):

```systemverilog
// Original: $readmemb("microrom.mem", uRam);
$readmemb("../../Minimig_MiSTerMEGA65/rtl/fx68k/microrom.mem", uRam);
```

**TRAP:** the same relative path is wrong for xsim, whose working directory is deeper (`CORE/CORE-RX.sim/sim_1/behav/xsim/`). If you simulate these modules in the project, you must either add the .mem directory to the simulation search path, copy the files, or override the path for sim. Synthesizability comes first; the references accept the sim breakage.

The alternative - adding the .mem files as project sources so Vivado finds them by basename - keeps the source pristine but makes the file list/board sync (section 3.H) carry data files too; neither reference port does it (verified: no `.mem` entries in either C64MEGA65 `CORE/CORE-R3.xpr` or the Amiga `CORE/CORE-R3.xpr`). Path-patching the handful of `$readmem` calls, with the original line kept as a comment, is the established pattern.

### 3.G.2 Verify every load in the synthesis log - missing files are not errors

**TRAP:** if Vivado cannot open a `$readmem` file, synthesis *continues* and the memory initializes to all zeros. For a CPU microcode ROM that means a synthesized, perfectly routed bitstream with a dead CPU and no diagnostics anywhere ((Amiga port) `doc/synthesis-handoff.md:43-45` flags exactly this for the fx68k microcode). 

**RULE:** after every synthesis, grep the log for one `is read successfully` per init file and treat any `cannot open` as fatal:

```text
INFO: [Synth 8-3876] $readmem data file '../../Minimig_MiSTerMEGA65/rtl/fx68k/nanorom.mem'
      is read successfully [...fx68k.sv:2493]
```

(verified in the Amiga run log, `CORE/CORE-R3.runs/synth_1/runme.log:961-964`).

### 3.G.3 VHDL-side preloads: ROM_FILE/ROM_FILE_HEX and the same depth math

M2M's `dualport_2clk_ram` can preload itself at elaboration via plain VHDL file I/O: generics `ROM_PRELOAD`, `ROM_FILE`, and `ROM_FILE_HEX` (M2M `vhdl/2port2clk_ram.vhd:18-20`; the actual `file_open`/`readline`/`hread` loop is in the underlying `tdp_ram.vhd:45-49`, `ROM_FILE_HEX` selecting `hread` (hex) over `read` (binary/bit format)). VHDL `file_open` with a relative path resolves against the same synthesis run directory, so the identical depth math applies - and Vivado additionally searches the *source file's* directory (the C64's source-relative font path `G_ROM_FILE="../font/Anikki-16x16-m2m.rom"` succeeds this way). Write paths run-dir-relative anyway, and keep the file near the source as belt and braces (S103). The QNICE firmware in the Amiga port ((Amiga port) `CORE/vhdl/globals.vhd:31-32`) goes three levels up to the repo root:

```vhdl
constant QNICE_FIRMWARE_MONITOR : string := "../../../M2M/QNICE/monitor/monitor.rom";  -- debug/development
constant QNICE_FIRMWARE_M2M     : string := "../../../CORE/m2m-rom/m2m-rom.rom";       -- release
```

A wrong path here is *louder* than the Verilog case - VHDL elaboration fails on `file_open` - but only if `ROM_PRELOAD` is actually true; an accidentally-false `ROM_PRELOAD` gives you the same silent zero ROM (`InitRAM` returns all zeros in that branch, tdp_ram.vhd:61-68; the comment above it, "Vivado 2019.2 crashes, if we are not using this indirection", is also why the function wrapper must not be 'simplified away').

### 3.G.4 Converting binary ROMs

Quartus .mif files do not work in this flow (the Amiga port's rewritten `bram.vhd` explicitly asserts against `mem_init_file` use - elaboration-time `assert ... report "mem_init_file is not supported"` at (Amiga port) `CORE/Minimig_MiSTerMEGA65/rtl/bram.vhd:99-100`). Convert binary ROM dumps to a hex text file, one byte (two hex digits) per line, and feed it through `ROM_FILE`/`ROM_FILE_HEX => true`. The C64 port's `c1541_rom.mif.hex` is the format reference (first lines: `97`, `AA`, `AA`, ...), consumed via the `iecdrv_mem_rom` wrapper that forwards INITFILE into `dualport_2clk_ram` (`.ROM_FILE(INITFILE), .ROM_FILE_HEX(1'b1)` - C64MEGA65 `CORE/C64_MiSTerMEGA65/rtl/iec_drive/iecdrv_misc.sv:107-115`; note this is also a clean example of an SV parameter *string* crossing into a VHDL generic). Note the guard `ROM_PRELOAD(INITFILE != " " ? 1'b1 : 1'b0)` - a single space, not the empty string, is the "no file" sentinel in this code base.

For data that QNICE loads at runtime instead (CRT/ROM windows, section 3.I), `M2M/tools/bin2qnice.py` converts a binary into QNICE-loadable hexdump chunks (`0xADDR 0xBYTE` per line, optional offset and chunk size). Large ROMs that the *Shell* loads from SD card (like the Amiga Kickstart) need no conversion at all - they are read as raw files by the firmware via the CRTROM manual-load mechanism.

## 3.H The .xpr project file (full anatomy + the crash)

M2M V2.0.1 uses Vivado *project mode*: four checked-in `.xpr` files (`CORE/CORE-R3.xpr` ... `CORE-R6.xpr`), one per MEGA65 board revision. Unlike the C64 port's parallel non-project Tcl flow (`CORE-R6.tcl`), the .xpr *is* the build definition in an M2M V2.0.1 port - and you will edit it by hand or script, because adding ~60 core files through the GUI four times is not realistic. This chapter is the anatomy you need for safe surgery, including the one edit that crashes Vivado outright.

### 3.H.1 XML structure

An .xpr is plain XML. The parts that matter (all line references (Amiga port) `CORE/CORE-R3.xpr`):

```xml
<Project Version="7" Minor="61" Path=".../CORE/CORE-R3.xpr">     <!-- line 6 -->
  <Configuration>
    <Option Name="Part" Val="xc7a200tfbg484-2"/>                 <!-- line 10 -->
    ...
  </Configuration>
  <FileSets Version="1" Minor="31">
    <FileSet Name="sources_1" Type="DesignSrcs" ...>
      <File Path="$PPRDIR/Minimig_MiSTerMEGA65/rtl/minimig.v">
        <FileInfo>
          <Attr Name="UsedIn" Val="synthesis"/>
          <Attr Name="UsedIn" Val="simulation"/>
        </FileInfo>
      </File>
      ...
      <Config>
        <Option Name="DesignMode" Val="RTL"/>
        <Option Name="TopModule" Val="mega65_r3"/>               <!-- line 1000 -->
      </Config>
    </FileSet>
    <FileSet Name="constrs_1" Type="Constrs" ...>                <!-- line 1003 -->
      <File Path="$PPRDIR/../M2M/MEGA65-R3.xdc"> ... </File>
      <File Path="$PPRDIR/../M2M/common.xdc"> ... </File>
      <File Path="$PPRDIR/CORE.xdc"> ... </File>
    </FileSet>
  </FileSets>
  <Runs Version="1" Minor="14">
    <Run Id="synth_1" ... ConstrsSet="constrs_1" ...>            <!-- line 1079 -->
      <Strategy ...>
        <Step Id="synth_design" PreStepTclHook="$PPRDIR/m2m-rom/synth_pre.tcl">  <!-- line 1082 -->
          <Option Id="FlattenHierarchy">1</Option>               <!-- = -flatten_hierarchy none -->
        </Step>
      </Strategy>
    </Run>
    <Run Id="impl_1" .../>
  </Runs>
</Project>
```

Key facts:

- `$PPRDIR` is the directory containing the .xpr (here `CORE/`). Framework sources are referenced as `$PPRDIR/../M2M/...`, your core as `$PPRDIR/vhdl/...` and `$PPRDIR/<submodule>/...`. Paths are forward-slash even on Windows.
- Every source is one `<File>` element; the nested `<FileInfo>` carries an optional `SFType` attribute (the file type, 3.H.2) and one `<Attr Name="UsedIn" Val=.../>` per stage (`synthesis`, `implementation`, `simulation`). The C64 reference files use synthesis+implementation+simulation for core RTL (C64MEGA65 `CORE/CORE-R3.xpr:91-96`, mos6526.v); the Amiga project uses synthesis+simulation - implementation inherits from synthesis output, so both work.
- The synthesis strategy hook `PreStepTclHook="$PPRDIR/m2m-rom/synth_pre.tcl"` rebuilds the QNICE firmware ROM before each synthesis. **TRAP:** this hook can fail silently on Mac/VM setups (known M2M issue, documented in (Amiga port) `doc/synthesis-handoff.md:9-19`); prebuild `m2m-rom.rom` with `CORE/m2m-rom/make_rom.sh` and verify its timestamp before synthesizing.
- Generated state lives next to the .xpr and must be gitignored, never committed: the AExp `.gitignore` covers `CORE/*.cache`, `CORE/*.hw`, `CORE/*.runs`, `CORE/*.sim`, `CORE/.Xil`, `CORE/vivado*.jou`, `CORE/vivado*.log`, `CORE/vivado_pid*`, `CORE/*ip_user_files`, plus the generated QNICE ROM artifacts under `CORE/m2m-rom/`.

### 3.H.2 File types: the legal SFType tokens and the segfault

**RULE:** the only `SFType` values you may write are `SFType="VHDL2008"`, `SFType="SVerilog"`, or *no SFType attribute at all*. With the attribute absent, Vivado infers the type from the extension: `.v` = Verilog-2001, `.sv` = SystemVerilog, `.vhd` = VHDL-93, `.xdc` = XDC.

**TRAP (the crash):** Vivado's project parser does not validate unknown SFType tokens - it segfaults. The Amiga port wrote the plausible-looking tokens `SFType="Verilog"`, `SFType="VHDL"` and `SFType="SystemVerilog"` into its first .xpr and Vivado 2022.2 died *at project open*, before any error message: the journal ends mid-open, and the native crash dump (`hs_err_pid<N>.log` next to the journal) shows `HDDASrcFileType::getId` called on null, reached from `HAPPFileSetXMLParser3::parseFileType_`. Because the crash happens while loading, you cannot fix it from inside Vivado, and it is easy to misdiagnose as a broken installation or VM. The fix is recorded in AExp commit 9201048 ("Fix .xpr file-type tokens that crashed Vivado's project parser": "Vivado 2022.2 segfaults (HDDASrcFileType::getId on null) when an .xpr contains an SFType value it does not know"). If Vivado ever dies opening a project you just hand-edited, suspect SFType first and diff against the last committed .xpr.

The working convention, taken from the C64 reference and adopted by AExp commit d861f56:

| Files | SFType | Verified example |
|---|---|---|
| every `.vhd` (framework, QNICE, your CORE/vhdl, submodule VHDL) | `VHDL2008` | C64MEGA65 `CORE/CORE-R3.xpr:617-618` (dprom.vhd) |
| `.sv` files | none (extension-inferred) | C64MEGA65 `CORE/CORE-R3.xpr:147-148` (hq2x.sv, plain `<FileInfo>`) |
| plain `.v` files | none (Verilog-2001) | C64MEGA65 `CORE/CORE-R3.xpr:91-92` (mos6526.v) |
| `.v` files containing SV constructs | `SVerilog` | C64MEGA65 `CORE/CORE-R3.xpr:175-176` (reu.v) |

**Why** all-VHDL2008 even for VHDL-93-era files: Vivado's 2008 mode is a superset in practice - it accepts the classic UG901 shared-variable dual-port RAM template with a warning instead of demanding `protected` types (commit d861f56: "Vivado's relaxed 2008 mode accepts the UG901 shared-variable TDP template with a warning, exactly like C64's dprom.vhd"), and framework files genuinely need 2008. Typing everything 2008 removes a whole class of per-file decisions.

The `SFType="SVerilog"` on `.v` entries is the project-mode equivalent of the C64 Tcl flow's `read_verilog -sv` list (3.E.4). In M2M V2.0.1 three framework `.v` files need it (inherited from the template): `M2M/vhdl/av_pipeline/audio_out.v`, `M2M/vhdl/controllers/MiSTer/iir_filter.v`, `M2M/vhdl/controllers/MiSTer/scandoubler.v`. Check whether your core adds more (the Amiga port deliberately kept its retained `.v` files Verilog-2001-clean and added none).

### 3.H.3 Scripted editing of the file list

The edit a port needs: remove the five demo-core entries the M2M template ships (`M2M/vhdl/democore/democore.vhd`, `vga_controller.vhd`, `democore_audio.vhd`, `democore_video.vhd`, `democore_game.vhd` - the exact removals are in AExp commit b7407a6) and add your core's file list - for the Amiga port 56 Minimig sources plus one new CORE/vhdl file, times four board files. Do this with a script, not by hand. The pattern used in AExp:

1. Treat the file textually with `re` for the surgery - the `<File>` blocks are rigidly uniform, so removing an entry is deleting the lines from its `<File Path="...">` to the matching `</File>`, and adding entries is inserting rendered blocks after a fixed anchor line (e.g. after the last existing submodule `<File>` element, inside `sources_1`):

```python
import re, xml.etree.ElementTree as ET

FILE_TMPL = ('      <File Path="$PPRDIR/{path}">\n'
             '        <FileInfo{sftype}>\n'
             '          <Attr Name="UsedIn" Val="synthesis"/>\n'
             '          <Attr Name="UsedIn" Val="simulation"/>\n'
             '        </FileInfo>\n'
             '      </File>\n')

def entry(path, sftype=None):
    return FILE_TMPL.format(path=path,
                            sftype=f' SFType="{sftype}"' if sftype else '')

xpr = open(xpr_path).read()
# remove democore blocks
xpr = re.sub(r'      <File Path="\$PPRDIR/\.\./M2M/vhdl/democore/[^"]*">.*?</File>\n',
             '', xpr, flags=re.S)
# insert new entries after an anchor <File> block
anchor = '</File>\n'  # use a unique, full anchor block in practice
new_blocks = ''.join(entry(p, t) for p, t in file_list)
xpr = xpr.replace(anchor_block, anchor_block + new_blocks, 1)
```

2. *Validate* the result with `xml.etree.ElementTree.parse()` before writing it back - ET parsing catches structural damage (unbalanced tags, encoding accidents) that Vivado would punish with the 3.H.2 crash or silent misbehavior. Do not *write* with ElementTree: it re-serializes the whole file (attribute order, self-closing tags, whitespace) and produces an unreviewable diff against the Vivado-written original.
3. Re-typing decisions (which entries get which SFType) follow the 3.H.2 table mechanically from the extension plus your SV-in-.v list.
4. Open the project in Vivado once and run *Open Elaborated Design* as the cheap smoke test (minutes, catches binding errors) before burning an hour on synthesis ((Amiga port) `doc/synthesis-handoff.md:26-27`).

### 3.H.4 Four boards, one rule

**RULE:** every file-list change must be replicated to all four board projects. They drift silently otherwise - the Amiga port did the R3 surgery first and synced R4/R5/R6 in a separate review fix (AExp commit 0ca916d: "replicate the R3 file-list changes (57 Minimig sources + amiga_config.vhd added, democore removed) so all four board projects elaborate" - the commit message overcounts; each project carries 56 Minimig File entries). A board .xpr you never open still has to elaborate, because releases ship cores for all board revisions.

The *expected* deltas between the four files - anything beyond this list is drift (verified by diffing the four AExp project files):

| Delta | R3 | R4 | R5 | R6 |
|---|---|---|---|---|
| `TopModule` | `mega65_r3` | `mega65_r4` | `mega65_r5` | `mega65_r6` |
| Framework top wrapper | `M2M/vhdl/top_mega65-r3.vhd` | `-r4.vhd` | `-r5.vhd` | `-r6.vhd` |
| Board XDC | `M2M/MEGA65-R3.xdc` | `-R4.xdc` | `-R5.xdc` | `-R6.xdc` |
| Board-specific framework files | `M2M/vhdl/controllers/M65/max10.vhdl`, `M65/pcm_to_pdm.vhdl` | `M65/audio.vhd` | `M65/audio.vhd` | `M65/audio.vhd` |

(R3 has the MAX10 companion FPGA and PDM audio; R4/R5/R6 use the I2C audio DAC, hence `audio.vhd`. R4/R5/R6 are otherwise file-identical to each other.) Also tolerate cosmetic differences in `<Project Path=...>` (absolute path of last save), generated-Id options and GUI state options - they are rewritten whenever Vivado saves the project and carry no meaning. `CORE.xdc` and `common.xdc` are referenced by all four.

## 3.I M2M framework integration reference

This chapter is the compact reference of every surface where your code meets the M2M V2.0.1 framework. Each section gives the signals, the protocol, and a verified example to copy from. The two files you own are `CORE/vhdl/main.vhd` (core clock domain, wraps the MiSTer core) and `CORE/vhdl/mega65.vhd` (multi-domain integration layer); `CORE/vhdl/globals.vhd` and `CORE/vhdl/config.vhd` carry the static configuration the framework and the Shell firmware read.

### 3.I.1 The QNICE device bus (core side)

QNICE (the 50 MHz Shell CPU) reaches core-owned memories and devices through one multiplexed bus, presented to `mega65.vhd` as ((Amiga port) `CORE/vhdl/mega65.vhd:74-80`):

```vhdl
qnice_dev_id_i   : in  std_logic_vector(15 downto 0);  -- device selector
qnice_dev_addr_i : in  std_logic_vector(27 downto 0);  -- address within device
qnice_dev_data_i : in  std_logic_vector(15 downto 0);  -- write data
qnice_dev_data_o : out std_logic_vector(15 downto 0);  -- read data
qnice_dev_ce_i   : in  std_logic;                      -- chip enable
qnice_dev_we_i   : in  std_logic;                      -- write enable
qnice_dev_wait_o : out std_logic;                      -- stall QNICE
```

Protocol and conventions:

- **Window arithmetic.** On the QNICE side the firmware selects a device in `M2M$RAMROM_DEV` (0xFFF4), a 4k window number in `M2M$RAMROM_4KWIN` (0xFFF5), and accesses 0x7000-0x7FFF (`M2M$RAMROM_DATA`); the framework presents you the flat address `dev_addr = window * 4096 + offset`, hence 28 bits: "we have a 16-bit window selector and a 4k window: 65536*4096 = 2^28" (M2M `vhdl/vdrives.vhd:169`; selector constants in M2M `rom/sysdef.asm:195-212`). Device IDs 0x0000-0x00FF are reserved for the framework (VRAM, config, ascal polyphase RAM, HyperRAM at 0x0004, sysinfo at 0x00FF); your devices start at 0x0100.
- **The decode process is combinational** with defaults assigned first to avoid latches, and `x"EEEE"` is the convention for "no device/open bus". The reference is C64MEGA65 `CORE/vhdl/mega65.vhd:805-881` (`core_specific_devices : process(all)`): line 808 sets `qnice_dev_data_o <= x"EEEE"`, line 809 `qnice_dev_wait_o <= '0'`, then every device-specific enable gets a '0' default before the `case qnice_dev_id_i is` dispatch at line 828. **RULE:** copy this shape exactly - defaults, then case, `when others => null`. Every signal assigned inside the case must have a default above it.
- **dev_wait** stalls the QNICE CPU mid-access for devices that cannot answer combinationally; C64's PRG loader and CRT parser use it (`qnice_dev_wait_o <= qnice_prg_wait;` mega65.vhd:856, and :863). Keep it '0' otherwise.
- **Byte semantics on a word bus.** QNICE transfers 16-bit words; when your storage is byte-lane split, use dev_addr bit 0 to select the lane and present the byte in the low half. The Amiga Kickstart device is the worked example ((Amiga port) `CORE/vhdl/mega65.vhd:562-574`): even addresses hit the upper (big-endian first) byte lane, odd the lower, each returning `x"00" & byte`. The C64's flat 8-bit RAM instead just returns `x"00" & ram_byte` at word-per-byte addressing (C64 mega65.vhd:830-834) - choose per device, the firmware side just sees words.
- **CSR window 0xFFFF.** For devices that receive *manually loaded* ROMs/CRTs, window 0xFFFF of the device address space is reserved as control/status: `CRTROM_CSR_4KWIN .EQU 0xFFFF` with `CRTROM_CSR_STATUS/FS_LO/FS_HI` (QNICE to device) at offsets 0x7000-0x7002 and `CRTROM_CSR_PARSEST/PARSEE1/ADDR_LO/ADDR_HI` plus an error-string window (device to QNICE) at 0x7010-0x7013/0x7100 (M2M `rom/sysdef.asm:376-385`; the C64's `sw_cartridge_csr.vhd` implements the device side). Auto-loaded ROMs that are plain memories (like the Amiga Kickstart) need no CSR.
- **Sysinfo windows** (device 0x00FF) are how the *firmware* learns about your core - vdrives constants (window 0x0000), VGA/HDMI adaptor info (0x0010/0x0011), CRT/ROM declarations (0x0020), and ascal's live resolution measurements (0x0030 - `M2M$SYS_CORE_*`, sysdef.asm:218-245). The framework serves these from globals.vhd automatically; you do not implement them, but reading them via the QNICE debug console is a first-class debugging tool.

### 3.I.2 CRTROM declarations in globals.vhd

The Shell loads ROM/cartridge files into your devices based on two constant arrays in `CORE/vhdl/globals.vhd`. Syntax rules (all verified against C64MEGA65 `CORE/vhdl/globals.vhd:124-181` and (Amiga port) `CORE/vhdl/globals.vhd:133-152`). The `crtrom_buf_array`/`vd_buf_array` types and all `C_CRTROMTYPE_*` constants ship in the template's globals.vhd boilerplate (template CORE/vhdl/globals.vhd:96-112) - keep them and only edit the `C_CRTROMS_*` values:

**Manual loads** (user picks a file via OSM): flat array of pairs (type, target), terminated with `x"EEEE"`, max 16 entries:

```vhdl
constant C_CRTROMS_MAN_NUM : natural := 2;
constant C_CRTROMS_MAN     : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_C64_PRG,
                                                   C_CRTROMTYPE_DEVICE, C_DEV_C64_CRT,
                                                   x"EEEE");   -- terminator, always
```

Types: `C_CRTROMTYPE_DEVICE` (x0000, second value = QNICE device ID), `C_CRTROMTYPE_HYPERRAM` (x0001, second value = 4k window in HyperRAM), `C_CRTROMTYPE_SDRAM` (x0002, reserved). If unused: `C_CRTROMS_MAN_NUM = 0` and the array = `(x"EEEE", x"EEEE", x"EEEE")`.

**Auto loads** (loaded by the Shell before the core starts): quadruples (type, target, mandatory/optional, name offset), same `x"EEEE"` terminator, max 16. The file names are one concatenated string of zero-terminated substrings, and the offsets are computed with VHDL's `'length`:

```vhdl
constant ENDSTR : character := character'val(0);
constant JIFFY_DOS_C64         : string := "/c64/jd-c64.bin" & ENDSTR;
constant JIFFY_DOS_C1541       : string := "/c64/jd-c1541.bin" & ENDSTR;
constant JIFFY_DOS_C64_START   : std_logic_vector(15 downto 0) := x"0000";
constant JIFFY_DOS_C1541_START : std_logic_vector(15 downto 0) :=
   std_logic_vector(to_unsigned(JIFFY_DOS_C64'length, 16));   -- offset = length of all strings before it

constant C_CRTROMS_AUTO_NUM   : natural := 2;
constant C_CRTROMS_AUTO_NAMES : string := JIFFY_DOS_C64 & JIFFY_DOS_C1541;
constant C_CRTROMS_AUTO       : crtrom_buf_array := (
   C_CRTROMTYPE_DEVICE, C_DEV_C64_KERNAL_C64,   C_CRTROMTYPE_OPTIONAL, JIFFY_DOS_C64_START,
   C_CRTROMTYPE_DEVICE, C_DEV_C64_KERNAL_C1541, C_CRTROMTYPE_OPTIONAL, JIFFY_DOS_C1541_START,
   x"EEEE");
```

`C_CRTROMTYPE_MANDATORY` (x0003) makes a missing file fatal: the Shell shows an error screen naming the file and refuses to start the core - the Amiga port uses exactly this for `/amiga/kick.rom` ((Amiga port) globals.vhd:145-152), which is the right semantic for a machine that is useless without its boot ROM. `C_CRTROMTYPE_OPTIONAL` (x0004) skips silently. **TRAP:** the framework does *no* consistency checking on `C_CRTROMS_AUTO_NAMES` versus your offsets (globals.vhd comment, C64 lines 165-168): a forgotten `& ENDSTR` or a wrong `'length` chain loads garbage file names. Every substring must be zero-terminated, every array `x"EEEE"`-terminated.

### 3.I.3 vdrives (virtual disk drives)

`M2M/vhdl/vdrives.vhd` replaces the virtual-drive part of MiSTer's `hps_io.sv`: it speaks MiSTer's "SD" protocol toward the core's drive models and exposes a QNICE register file toward the firmware. Declaration side, in globals.vhd (C64MEGA65 `CORE/vhdl/globals.vhd:114-117`):

```vhdl
constant C_VDNUM    : natural := 1;                                       -- # drives, max 15
constant C_VD_DEVICE: std_logic_vector(15 downto 0) := C_DEV_C64_VDRIVES; -- QNICE device ID
constant C_VD_BUFFER: vd_buf_array := ( C_DEV_C64_MOUNT, x"EEEE" );       -- per-drive image buffer devices
```

If unused (as in the Amiga port milestone 1): `C_VDNUM = 0`, `C_VD_DEVICE = x"EEEE"`, `C_VD_BUFFER = (x"EEEE", x"EEEE")` ((Amiga port) globals.vhd:110-112).

Instantiation (C64MEGA65 `CORE/vhdl/main.vhd:1537-1586` is the complete worked example): generics `VDNUM` (drive count) and `BLKSZ` (LBA block size code, 0..7 = 128..16384 bytes; C64 uses 1 = 256). The entity takes *both clocks* (`clk_qnice_i`, `clk_core_i`) and its ports split into the two domains (vdrives.vhd:126-175):

- Core domain: `img_mounted_o` (one strobe bit per drive; `img_readonly_o`/`img_size_o`/`img_type_o` are only valid while the strobe is high - MiSTer latches them on its rising edge, so never mount two drives simultaneously with different values), `drive_mounted_o` (latched version, use for drive reset), `cache_dirty_o`/`cache_flushing_o` (use dirty to *prevent* core resets while a write-back is pending - C64 main.vhd computes `prevent_reset` from it).
- QNICE domain: MiSTer's `sd_lba_i`/`sd_blk_cnt_i`/`sd_rd_i`/`sd_wr_i`/`sd_ack_o` block interface and the `sd_buff_*` byte interface. **TRAP:** on MiSTer these are clocked by "clk_sys", which makes them *look* core-domain; in M2M they run on the QNICE clock, and vdrives does the CDC internally (xpm_cdc instances at vdrives.vhd:237-273). Wire your drive model's SD-side ports to the QNICE clock exactly as C64's `iec_drive` does, not to the core clock.
- The QNICE register map (window 0x0000 = control/data incl. `img_mounted`, buffer pump registers; window N+1 = drive N with lba/blk_cnt/rd/wr/ack and cache control) plus the full reverse-engineered mount/read protocol are documented in the 100-line header comment of vdrives.vhd:14-95 - read it before implementing; it is the authoritative spec.

The firmware reads `C_VDNUM` and the buffer list through sysinfo window 0x0000 and runs the SD-card side; with the declarations and the wiring above, mounting from the OSM file browser works without core-specific firmware code.

### 3.I.4 The OSM control vector

The On-Screen-Menu state arrives as a 256-bit vector in *both* clock domains: `qnice_osm_control_i` (QNICE domain, mega65.vhd:68) and `main_osm_control_i` (core domain, mega65.vhd:135; the crossing is the framework's, 3.F.1). The contract:

- **Bit index = zero-based line number in config.vhd's `OPTM_ITEMS` string.** Menu line 15 = vector bit 15. The firmware comment in sysdef.asm:185-186 states it: "the bit order is: bit 0 = topmost menu entry, the mapping is 1-to-1 to OPTM_ITEMS / OPTM_GROUPS in config.vhd". Define named constants for the indices next to where you consume them; the convention is `C_MENU_*` constants (C64MEGA65 `CORE/vhdl/mega65.vhd:320-342`; (Amiga port) mega65.vhd decodes its HDMI-mode lines 5-11 and CRT/audio lines 15-16 the same way, with the line-number mapping documented in config.vhd:294-297 right above `OPTM_ITEMS`).
- A bit is '1' when the menu item is selected/checked. Group behavior (single-select vs multi-select vs submenu plumbing) is defined by `OPTM_GROUPS` in config.vhd (Amiga config.vhd:340-358 is a complete example incl. a submenu block); only *selectable* lines carry meaning in the vector - headline/line entries stay '0'.
- Use the QNICE-domain copy for QNICE-domain consumers (e.g. `qnice_video_mode_o` selection, mega65.vhd:499-505) and the core-domain copy inside main.vhd; never cross them yourself.
- **Persistence:** with `SAVE_SETTINGS = true` (config.vhd:210) the firmware persists the vector to the file named by `CFG_FILE` if it exists and is exactly `OPTM_SIZE` bytes. **The first-byte-0xFF convention:** if byte 0 of that file is 0xFF, the file is treated as "factory default" and the `OPTM_G_STDSEL` defaults from config.vhd apply instead (config.vhd:206-209). Generate the file with `M2M/tools/make_config.sh`, and re-generate and re-distribute it whenever `OPTM_SIZE` changes (config.vhd:286-287) - a stale config file of the wrong length is simply ignored, but one of the right length with old semantics silently mis-sets your new menu.

### 3.I.5 General-purpose registers

A second 256-bit vector, free of any Shell semantics, flows QNICE -> core: `qnice_gp_reg_i` (mega65.vhd:71) / `main_qnice_gp_reg_i` (mega65.vhd:138), again pre-crossed by the framework (framework.vhd:789/803). The firmware writes it as sixteen 16-bit slices via `M2M$CFD_ADDR`/`M2M$CFD_DATA` (0xFFF0/0xFFF1, sysdef.asm:177-181 - select slice 0..15, write data). Use it for custom firmware-to-core controls that are not menu items (custom Shell code in `CORE/m2m-rom/m2m-rom.asm` on one side, plain vector slicing on the other). There is additionally a single pass-through 16-bit input register `M2M$GENERAL` (0xFFE5, sysdef.asm:143) reserved for core-defined use in the other direction.

### 3.I.6 Video pipeline knobs

`mega65.vhd` drives a set of QNICE-domain configuration outputs into the framework's AV pipeline. The complete list with semantics and safe defaults, verified against (Amiga port) `CORE/vhdl/mega65.vhd:51-62` (ports) and `:499-538` (assignments; the Amiga values shown are a sane minimal configuration):

| Signal | Meaning | Default / note |
|---|---|---|
| `qnice_dvi_o` | '0' = HDMI with sound, '1' = DVI (no sound, no infoframes) | '0'; tie to a menu bit if displays need it |
| `qnice_video_mode_o` | HDMI output mode, type `video_mode_type` from `video_modes_pkg` | mux from the HDMI-mode menu group (mega65.vhd:499-505); last `else` = your default mode |
| `qnice_scandoubler_o` | '1' doubles the analog VGA output's scanrate | **RULE: must be '1' for 15 kHz cores.** The Amiga outputs 15.625 kHz PAL; "without the scandoubler, most VGA monitors will not lock. MUST be '1' (the M2M template has '0' here)" (mega65.vhd:511-514). The C64 (already ~31 kHz via its doubled clock) differs - check what *your* core emits |
| `qnice_retro15kHz_o` | '1' outputs the raw 15 kHz signal on VGA | '0'; pair with csync for CRT/SCART users |
| `qnice_csync_o` | '1' = composite sync instead of separate HS/VS | '0'; "often used as a pair" with retro15kHz (mega65.vhd:520-523) |
| `qnice_zoom_crop_o` | '1' = crop/zoom the HDMI picture | '0' until you add the menu item |
| `qnice_ascal_mode_o` | ascal scaler filter: 00 nearest, 01 bilinear, 10 sharp bilinear, 11 bicubic | "00" (mega65.vhd:526-531); only honored per config.vhd's `ASCAL_USAGE` policy (config.vhd:198-204) |
| `qnice_ascal_polyphase_o` | '1' = polyphase filters (overrides ascal_mode) - this is the "CRT emulation" look | wire to a menu bit under `ASCAL_USAGE=2`; with `ASCAL_USAGE=1` (AUSE_CUSTOM, the Amiga + C64 V6 pattern) tie to '0' and let the firmware's HDMI Filter dispatcher (CORE/m2m-rom/m2m-rom.asm) program `M2M$ASCAL_MODE` + the polyphase RAM directly |
| `qnice_ascal_triplebuf_o` | ascal triple buffering | **'0' - "the M2M framework only supports OFF, so do not touch"** (mega65.vhd:536-538) |
| `qnice_osm_cfg_scaling_o` | 9-bit OSM scaling configuration | `(others => '1')` (mega65.vhd:524) |
| `qnice_audio_mute_o` / `qnice_audio_filter_o` | mute; raw ('0') vs filtered ('1') audio | '0' / menu bit (mega65.vhd:516-517) |

All of these live in the QNICE clock domain and are typically pure functions of `qnice_osm_control_i` bits - no registers needed.

### 3.I.7 Audio filter coefficients

The `audio_*` constants in globals.vhd parameterize the framework's port of MiSTer's IIR audio filter (`M2M/vhdl/controllers/MiSTer/iir_filter.v`), active when `qnice_audio_filter_o = '1'`. **RULE:** these are not free parameters - "you need to copy the correct values from the MiSTer core that you are porting: sys/sys_top.v" (C64MEGA65 `CORE/vhdl/globals.vhd:186-187`). The set (C64 globals.vhd:191-200): `audio_flt_rate` (filter sample rate, 32-bit), `audio_cx` plus `audio_cx0..cx2` (numerator coefficients of the 3-tap IIR), `audio_cy0..cy2` (24-bit signed denominator coefficients), `audio_att` (output attenuation, 5 bits) and `audio_mix` (stereo mix-down: 00 none, 01 25%, 10 50%, 11 mono - comment at :200). Find the corresponding `assign` lines for your core in MiSTer's `sys_top.v`/the core's `*.sv` top and transcribe the decimal literals; the Amiga port reuses MiSTer's Minimig values the same way.

### 3.I.8 HyperRAM (Avalon MM)

The core gets a 16-bit Avalon Memory-Mapped master into the 8 MB HyperRAM, exposed in `mega65.vhd`'s HyperRAM clock domain section ((Amiga port) mega65.vhd:86-98): `hr_core_write_o`, `hr_core_read_o`, `hr_core_address_o(31:0)` (word address), `hr_core_writedata_o(15:0)`, `hr_core_byteenable_o(1:0)`, `hr_core_burstcount_o(7:0)`, and back `hr_core_readdata_i`, `hr_core_readdatavalid_i`, `hr_core_waitrequest_i`. Standard Avalon rules: hold a request while `waitrequest` is high; read data arrives on `readdatavalid` strobes (burstcount of them per read request). Everything you drive here must be synchronous to `hr_clk_i` - crossing from the core clock into the HyperRAM domain is your job (the C64 uses a `cdc_slow`-style handshake plus an Avalon FIFO stack for its REU).

- **Arbitration:** your master is one of three inputs to the framework's round-robin arbiter `avm_arbit_general` (M2M `vhdl/framework.vhd:684-695`: digital/ascal, core, QNICE) - you share bandwidth with the HDMI scaler's framebuffer traffic, so expect waitrequest under load and design for latency.
- **Address map:** partition HyperRAM via the `C_HMAP_*` constants in globals.vhd, in units of one 4k-word window (4096 16-bit words = 8 KB). `C_HMAP_M2M = x"0000"` reserves the first 4 MB (windows 0x000-0x1FF) for the framework - never touch it; the core's space starts at `x"0200"` (C64MEGA65 globals.vhd:97-100, which also documents the total `C_HMAP_SIZE = x"0400"` = 8 MB with the final 8 KB kept as a burst guard). Usage example: C64 turns a window constant into a byte/word base address as `C_HMAP_CRT(9 downto 0) & X"000"` (C64 mega65.vhd:1001) and `X"0" & C_HMAP_REU & X"000"` (C64 main.vhd:1602).
- `hr_high_i`/`hr_low_i` are feedback flags ("core is too fast"/"too slow", mega65.vhd:97-98) used for optional flow control of cores that stream against the scaler.
- **Why you will need this even if the MiSTer core used SDRAM/DDR:** BRAM is scarce (the Amiga port sits at 363.5/365 RAMB36 after using BRAM for all Amiga memory; "any future buffer (ADF floppy images, HDD sector buffers) MUST live in HyperRAM" - (Amiga port) `doc/synthesis-handoff.md:110-113`).

### 3.I.9 Keyboard

The framework scans the MEGA65 keyboard for you and presents, in the core clock domain, a continuously cycling interface (mega65.vhd:145-146): `main_kb_key_num_i : integer range 0 to 79` sweeps all matrix positions ("with a frequency of 1 kHz, i.e. the whole keyboard is scanned 1000 times per second", C64MEGA65 `CORE/vhdl/keyboard.vhd:17`), and `main_kb_key_pressed_n_i` is the debounced, low-active state of the currently presented key. Your `CORE/vhdl/keyboard.vhd` converts this stream into whatever the core wants. The key numbering is the MEGA65 matrix order, with the full named list `m65_ins_del = 0`, `m65_return = 1`, `m65_horz_crsr = 2`, ... in C64MEGA65 `CORE/vhdl/keyboard.vhd:81` onward - copy these constants verbatim into your keyboard module. Two reference conversion targets: C64 (matrix emulation) and the Amiga port (event queue producing raw Amiga scancodes with make/break bit, plus CAPS LOCK special-casing - (Amiga port) `CORE/vhdl/keyboard.vhd`). The framework's own OSM keyboard handling (Help key, navigation) is independent and can be enabled/disabled per CSR; your core only sees keys when the OSM is closed (CSR keyboard enable, crossed for you as `main_csr_keyboard_on`).

### 3.I.10 Pause, reset, LEDs, RTC

- **Pause:** `main_pause_core_i` (mega65.vhd:132) is asserted when the Shell wants the core frozen (e.g. OSM open with `OPTM_PAUSE = true` in config.vhd). Only honor it if your core has a clean pause point - gate clock *enables*, never the clock. The Amiga port documents the opposite decision: `OPTM_PAUSE := false` because "minimig has no clean pause point; would need gating of the clk7/c1/c3/cck enables - later milestone" ((Amiga port) `CORE/vhdl/config.vhd:172-174`). **TRAP:** setting OPTM_PAUSE true without implementing pause_i freezes nothing but *tells the firmware the core is frozen* - audio/video keep running while the user believes otherwise.
- **Reset:** you receive `main_reset_m2m_i` (whole machine) and `main_reset_core_i` (core only) plus the rule set: derive your own protected reset inside main.vhd and never use the raw inputs in core logic. The definitive write-up - three-tier reset hierarchy (long button = hard, short = soft, QNICE CSR pulse = strict subset), the 32-cycle minimum pulse width, and "CAUTION: NEVER DIRECTLY USE THE INPUT SIGNALS reset_soft_i and reset_hard_i IN MAIN.VHD AS YOU WILL RISK DATA CORRUPTION" - is the RESET SEMANTICS comment at C64MEGA65 `CORE/vhdl/main.vhd:340-385`. Read it once per port. Use `prevent_reset` (computed from vdrives `cache_dirty_o`) to defer resets while disk writes are pending.
- **LEDs:** `main_power_led_o` / `main_drive_led_o` with 24-bit RGB colors `main_power_led_col_o` / `main_drive_led_col_o` (mega65.vhd:147-150). Conventions from the C64 port: power LED blue while in reset, green otherwise (`x"0000FF" when main_reset_m2m_i else x"00FF00"`, C64 mega65.vhd:534); drive LED green for activity, yellow (`x"FFFF00"`) while the write cache is dirty or flushing (C64 main.vhd:552-560 - this is genuinely useful, it tells the user when pulling the SD card would corrupt data).
- **RTC:** `main_rtc_i : std_logic_vector(64 downto 0)` (mega65.vhd:178), pre-crossed into the core domain. Format (M2M `vhdl/i2c/rtc_controller.vhd:53-62`): BCD bytes seconds/minutes/hours/day-of-month/month/year in bits 47:0, day-of-week in 55:48, constant 0x40 in 63:56, and bit 64 a toggle flag that flips on any change. This is bit-compatible with what MiSTer cores expect on their `rtc` input (C64 feeds it straight into MiSTer's `rtcF83.sv` via the component at C64 main.vhd:528-542).

### 3.I.11 The main.vhd / mega65.vhd extension pattern

**RULE:** the template's `main.vhd` entity is a *starting point*, not a fixed interface. The pattern is: `mega65.vhd` instantiates `main` (the Amiga port's instantiation: (Amiga port) `CORE/vhdl/mega65.vhd:400-463`), and whenever your core needs another connection between the domains-layer and the core - a RAM bus, LED outputs, an extra config bit, drive interfaces - you *add matching ports to the main entity and the instantiation*. The Amiga port added the whole 16-bit Amiga memory bus (`ram_addr_o`/`ram_data_o`/`ram_data_i`/byte enables, mega65.vhd:429-436) plus `pwr_led_o`/`fdd_led_o`; the C64's main entity has grown dozens of ports beyond the template (IEC physical port, cartridge bus, custom kernal interfaces, REU/HyperRAM hookup - compare C64MEGA65 `CORE/vhdl/main.vhd:27-250` with the template). Keep the discipline that goes with it:

- Everything in `main.vhd` is core-clock domain only. If a new port carries another domain's signal, the CDC happens in `mega65.vhd` (or is one of the framework's pre-crossed vectors), never inside main.
- Prefix conventions name the domain, not the direction: `main_*` core clock, `qnice_*` QNICE clock, `hr_*` HyperRAM clock, `video_*` video clock. Both reference ports follow this strictly; a signal whose prefix lies about its domain is a CDC bug waiting to be found by the next reader.
- `mega65.vhd`'s entity (toward the framework) is fixed by M2M V2.0.1 - you do not add ports there; everything custom enters through the QNICE device bus, the OSM/GP vectors, or HyperRAM.

## 3.J Local verification without Vivado

If Vivado runs somewhere slow or remote (in the Amiga port's case: a Parallels VM, with the development itself happening on a Mac - see `doc/synthesis-handoff.md`), every syntax error that survives to the Vivado round-trip costs an hour. The Amiga port developed a local static-check recipe using open-source tools that caught essentially all mechanical errors before the first Vivado run; the first synthesis was clean of language errors and the run-1 failures were exclusively things only Vivado can see (timing, BRAM capacity). This chapter is that recipe.

### 3.J.1 The toolchain

Installed via Homebrew (versions as used): `nvc` 1.21 (VHDL analyzer/elaborator, best diagnostics of the three), `ghdl` 5.1.1 (VHDL second opinion; on macOS you may have to clear the Gatekeeper quarantine on its binaries once), `icarus-verilog` (iverilog, Verilog/SV parser).

**RULE (scope):** this is *analysis-level* verification. No open-source tool elaborates a mixed VHDL+Verilog design, so the cross-language boundary itself (3.E) is checked only structurally (by-hand or scripted port-list comparison), and nothing here checks synthesis semantics, inference, project file types, or timing. Know what you are buying (3.J.5).

### 3.J.2 Verilog: iverilog -g2012 -t null

Run the parser over the *kept* Verilog/SV file set (your equivalent of the .xpr file list), with `-t null` (no target, parse/elaborate-check only):

```bash
iverilog -g2012 -t null -i <kept .v/.sv files> <stubs>
```

Two kinds of stubs make the set self-contained:

- **Stub modules for VHDL dependencies:** any VHDL entity that the Verilog instantiates (3.E.3) needs an empty Verilog module with the same name, parameters and ports - for the Amiga set that was `dpram` (instantiated from ide.v into bram.vhd's entity).
- **Stub modules for SV that iverilog cannot parse:** iverilog (13.x) does not support unpacked structs in some positions; fx68k.sv triggers this. Since fx68k is upstream-untouched, stubbing it out (an empty `module fx68k(...)` with the port list) loses nothing - you are checking *your* edits, not Gardner's CPU.

Use `-g2001` instead of `-g2012` selectively to check that files you intend to keep plain-Verilog (no `SFType="SVerilog"`, 3.H.2) really are Verilog-2001-clean - this is how the Amiga review proved the policy and how it caught a real bug (3.J.4). Running iverilog on the *upstream original* of each modified file separates pre-existing tool noise from introduced problems ((Amiga port) `.research/review/verilog-diffs.md:5` describes this discipline).

### 3.J.3 VHDL: nvc --std=2008 with stub unisim/xpm libraries

VHDL must be analyzed in dependency order, packages first. The order that works for an M2M V2.0.1 core set:

```bash
nvc --std=2008 -a M2M/QNICE/vhdl/tools.vhd \
                  M2M/vhdl/controllers/HDMI/types_pkg.vhd \
                  M2M/vhdl/av_pipeline/video_modes_pkg.vhd \
                  M2M/vhdl/tdp_ram.vhd M2M/vhdl/2port2clk_ram.vhd \
                  CORE/vhdl/globals.vhd CORE/vhdl/config.vhd \
                  CORE/vhdl/keyboard.vhd CORE/vhdl/amiga_config.vhd \
                  CORE/vhdl/clk.vhd CORE/vhdl/main.vhd CORE/vhdl/mega65.vhd
```

(Adapt the CORE list to your port; run `ghdl -a --std=08` over the same order as a second opinion - the two tools flag different things. Files that are deliberately VHDL-93, like the Amiga's rewritten `bram.vhd`, get a separate `--std=1993` pass.)

`clk.vhd` and anything else that references Xilinx primitives needs hand-written stub `vcomponents` packages compiled into libraries *named* `unisim` and `xpm` (nvc: `nvc --work=unisim -a unisim_stub.vhd`, then point the main analysis at the directory containing the library dirs via `-L`). The stubs only need component declarations for what the design instantiates - for an M2M core that is exactly three primitives. The Amiga port's stubs, reproduced as the template (they were developed at `/tmp/unisim_stub.vhd` / `/tmp/xpm_stub.vhd`):

```vhdl
-- unisim_stub.vhd: compile with --work=unisim
library ieee; use ieee.std_logic_1164.all;
package vcomponents is
  component MMCME2_ADV is
    generic ( BANDWIDTH : string := "OPTIMIZED"; ...
      DIVCLK_DIVIDE : integer := 1; CLKFBOUT_MULT_F : real := 5.0;
      CLKOUT0_DIVIDE_F : real := 1.0; ... CLKIN1_PERIOD : real := 0.0; ... );
    port ( CLKFBOUT, CLKOUT0, ... : out std_ulogic; LOCKED : out std_ulogic;
           CLKFBIN, CLKIN1, ... : in std_ulogic; ... RST : in std_ulogic );
  end component;
  component BUFG is
    port ( O : out std_ulogic; I : in std_ulogic );
  end component;
end package vcomponents;

-- xpm_stub.vhd: compile with --work=xpm
library ieee; use ieee.std_logic_1164.all;
package vcomponents is
  component xpm_cdc_async_rst is
    generic ( DEST_SYNC_FF : integer := 4; INIT_SYNC_FF : integer := 0;
              RST_ACTIVE_HIGH : integer := 0 );
    port ( src_arst : in std_logic; dest_clk : in std_logic;
           dest_arst : out std_logic );
  end component;
end package vcomponents;
```

**TRAP:** the generic and port names/types must match the real primitives exactly (copy from Vivado's `unisim_VCOMP.vhd` if in doubt), or you will "verify" against a fantasy and the real elaboration diverges. The full MMCME2_ADV stub carries all CLKOUTn generics precisely so that a generics typo in clk.vhd is caught locally.

The payoff goes beyond syntax: nvc *elaborates* all-VHDL subtrees. The Amiga review ran `nvc -e` over the complete CORE VHDL set and thereby proved that the 60-port `i_main` instantiation in mega65.vhd matched main.vhd's entity, including all newly added ports and slice widths, before Vivado ever saw the files (`.research/review/boundaries.md:13`).

### 3.J.4 Known noise (ignore) vs real findings (fix)

Expected, ignorable diagnostics over a MiSTer-derived code base:

- **iverilog use-before-declaration errors** for module-scope nets referenced above their declaration (e.g. Minimig's `long_frame` in agnus_beamcounter.v, `stealth` in cart.v): legal Verilog, upstream style, Vivado accepts it. Confirm each is byte-identical to upstream rather than a sweep artifact.
- **iverilog unpacked-struct errors** in fx68k.sv: tool limitation; the file is `SystemVerilog` typed for Vivado and synthesizes fine (stub it, 3.J.2).
- **Zero-width-concatenation complaints and their follow-on errors** (in the Amiga set iverilog flags concatenation expressions at cpu_wrapper.v:176 and minimig.v:416 that Vivado accepts), with cascading secondary errors in the same file. Evaluate the first message per file only, against upstream.
- **nvc unbound-component warnings** for every Verilog module and primitive instantiated from VHDL: by construction - those bind only in Vivado's mixed elaboration.
- **shared-variable warnings** on the UG901 dual-port templates under `--std=2008` (see 3.H.2) - expected in Vivado too.

Real findings this recipe produced in practice, each of which would otherwise have cost a Vivado round-trip: the `iverilog -g2001` pass caught that userio.v used declaration initializers on block-local variables - not legal Verilog-2001, only the *initializer-less* form has C64 precedent in Vivado, so the declarations were hoisted to module scope (fixed in AExp commit 0ca916d, "userio.v declaration hoisting"; full analysis in `.research/review/verilog-diffs.md:60`); the programmatic port-list diff of the rename shim against minimig.v verified all 95 connections incl. widths (verilog-diffs.md:42); and the nvc elaboration repeatedly caught port-map/width mismatches in mega65.vhd while the BRAM lanes and the config FSM were being built.

### 3.J.5 What this catches vs what only Vivado catches

| Caught locally | Only caught by Vivado |
|---|---|
| VHDL syntax/semantics, package/dependency errors, port-map and width mismatches in all-VHDL subtrees (nvc/ghdl) | mixed-language binding (VHDL component <-> Verilog module, case rules, 3.E) |
| Verilog/SV syntax, named-block/`output reg` violations, V2001-vs-SV policy compliance (iverilog) | .xpr legality incl. SFType tokens (3.H.2) and file-list completeness |
| structural completeness of rename shims and tie-offs (scripted port diffs) | $readmem path resolution at the run directory (3.G.1) |
| obvious latch-shaped processes (nvc warnings) | inference quality: BRAM vs LUTRAM, DSP mapping, retiming (the Amiga's 363.5/365 RAMB36 budget was pure Vivado territory) |
| | constraints binding, CDC analysis, timing closure (3.F) |
| | primitive behavior (MMCM lock, XPM internals) |

**RULE:** run the local battery after every editing session and before every synthesis handoff; treat the Vivado runs as the arbiter for the right column only. The division of labor in the Amiga port was explicit: "all sources prepared and statically verified (nvc 1.21 + GHDL 5.1 for VHDL, Icarus Verilog for Verilog ...). Vivado is the next arbiter" ((Amiga port) `doc/synthesis-handoff.md:3-6`) - and the two Vivado runs it then took to a timing-closed bitstream contained zero language-level errors.

---

# Part IV - Debugging playbook and reference appendices

## 4.1 The black-screen decision tree

You synthesized successfully, programmed the FPGA, and the screen is black.
This chapter is the structured diagnosis path for that moment. Work it top
to bottom; each stage isolates one layer of the stack (board -> framework ->
video pipeline -> core), and each branch names the concrete signal or file
to check.

**RULE:** Connect the serial console BEFORE you start guessing. Almost every
branch of this tree is decided by what the M2M firmware prints over UART,
not by what you see on the screen. The console runs at **115200 baud, 8N1,
no flow control** (divisor table in M2M/QNICE/vhdl/env1_globals.vhd:46 and
M2M/vhdl/QNICE/qnice_globals.vhd:35, both list "115200 -> 54"). On a MEGA65
with the JTAG adapter (TE0790-03 XMOD), the same USB cable that carries JTAG
exposes a serial port; open it with any terminal program (e.g.
`screen /dev/cu.usbserial-XXXX 115200`).

### 4.1.1 Stage 0: does the bitstream load and start at all?

- Programming via Vivado Hardware Manager succeeds but nothing happens:
  check that you programmed the right `.bit` for the right board revision
  (R3/R3A vs R4/R5/R6 use different XDC pinouts and different Vivado
  projects; a R3 bitstream on a R6 board produces exactly "nothing").
- **TRAP:** On MEGA65 board revisions R3 and R3A there is a hardware bug
  known as the *HDMI back-powering problem*: a powered HDMI sink feeds
  current back into the unpowered MEGA65 and corrupts startup. Symptoms
  range from display problems over SD card errors to general instability,
  and it perfectly masquerades as "my port is broken". Always power on the
  MEGA65 first, then the HDMI device; or hold "No Scroll" during power-on
  and select the core from the core menu; or put a cheap HDMI switch in
  between. Rule this out before debugging anything else.

### 4.1.2 Stage 1: is the framework alive? (serial banner, Help key)

Within a second of the bitstream starting, the Shell prints its banner to
the serial console (M2M/rom/strings.asm:41-47):

```text
MiSTer2MEGA65 Firmware and Shell, done by sy2002 & MJoergen in 2022 & 2023
https://github.com/sy2002/MiSTer2MEGA65

Press 'Run/Stop' + 'Cursor Up' and then while holding these press 'Help'
to enter the debug mode.
```

followed by `Core: <name from config.vhd>` (M2M/rom/coreinfo.asm:10-23).

- **No banner at all:** the QNICE subsystem is not running. This is almost
  never a core-space problem: suspect a broken framework checkout, a wrong
  board target, the QNICE clock not being generated, or - the classic - the
  firmware ROM being garbage because `synth_pre.tcl` failed silently. On
  Windows/WSL and on Macs running Vivado in a VM, the QNICE assembler
  toolchain that `synth_pre.tcl` invokes may be in the wrong binary format
  and fail without any error in the Vivado log (documented in the wiki page
  "Caution and loose ends"). Check that `CORE/m2m-rom/m2m-rom.rom` exists
  and has a recent timestamp after synthesis.
- **Banner present:** the framework (QNICE CPU, firmware, SD card stack,
  keyboard controller) is alive. Continue.

Now press **Help**. The on-screen menu (OSM) should open. Two things to
know about what that proves:

- The OSM is rendered inside the framework's video pipeline, but on both
  the analog and the HDMI path it is composited relative to the *core's*
  video timing (the analog path recovers screen coordinates from the
  core's HS/VS in M2M/vhdl/av_pipeline/vga_recover_counters.vhd; the HDMI
  path needs ascal to lock onto the core's input). So:
  **OSM visible** = framework alive AND core video timing present and
  plausible - the remaining problem is the core's *content* (CPU not
  running, ROM not loaded, palette black...): verify ROM delivery and
  reset release with the tools in 4.1.6 and the reset checks in 4.1.4.
  **OSM not visible but banner present** = the core's video timing itself
  is absent or unusable: read the video report (4.1.3) and follow its
  table into 4.1.4 or 4.1.5.
- The first Help press also prints the heap report to the serial console -
  see section 4.1.6.

### 4.1.3 Stage 2: read the 2.5-second core video report

2.5 seconds after the core starts, the firmware prints a measurement of
what your core actually outputs (M2M/rom/coreinfo.asm:49-227, routine
`LOG_COREINFO`, called from the Shell main loop). The format (field labels
verified against M2M/rom/strings.asm:49-63; the numbers below are
illustrative for a PAL machine, not a captured log):

```text
Core's visible area in pixels:
  ASCAL: DX=720  DY=576
  M2M:   DX=720  DY=576
Core's video timing parameters:
  Horizontal pulse:       <pixels>
  Horizontal front porch: <pixels>
  Horizontal back porch:  <pixels>
  Vertical pulse:         <lines>
  Vertical front porch:   <lines>
  Vertical back porch:    <lines>
  Horizontal frequency:   15.625 kHz
  Frame rate:             50.0 Hz
  Pixel rate:             14.190 MHz
```

Frame rate and pixel rate are *derived* by the firmware from the measured
horizontal frequency and the counted totals (coreinfo.asm:154-214), so a
wrong `video_ce_o` shows up directly as a wrong pixel rate line.

This single report decides most black-screen cases. It contains *two
independent measurements* of the visible area: one made by ascal (the HDMI
scaler) and one by the framework's own counters. If they diverge, the
firmware prints `Warning: ASCAL and M2M measurements diverge.`
(M2M/rom/strings.asm:53, check at coreinfo.asm:100-110).

Interpret it like this:

| Observation | Diagnosis | Go to |
|---|---|---|
| All values zero or absurd (DX=0, frame rate 0 Hz) | No video timing reaches the framework: clocks/reset/CE dead | 4.1.4 |
| ASCAL DX/DY zero or wildly different from M2M DX/DY | ascal cannot lock: sync polarity or blank/sync coverage wrong | 4.1.5 |
| Plausible geometry, correct frame rate, still black | Timing fine, content black: core-internal problem (ROM, CPU, reset) | 4.1.6 |
| Pixel rate not what you calculated for your core | `video_ce_o` divides wrongly | 4.1.4 |
| DX/DY plausible but not your core's nominal resolution | blanking window wrong (crops into picture) or CE wrong | 4.1.5 |

### 4.1.4 Branch: no video timing at all - clk.vhd, reset chain, video_ce

Three suspects, in order of likelihood:

1. **The core's MMCM never locks.** Your CORE/vhdl/clk.vhd derives the
   core's reset from the MMCM/PLL `LOCKED` outputs. In the C64 port the
   pattern is (C64MEGA65 CORE/vhdl/clk.vhd:219-229):

   ```vhdl
   i_xpm_cdc_async_rst_main : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not (main_locked_orig and main_locked_slow),
         dest_clk  => main_clk_o,
         dest_arst => main_rst_o
      );
   ```

   If `LOCKED` never asserts, `main_rst_o` is asserted *forever* and the
   core sits in permanent reset while the framework runs happily - exactly
   the "banner yes, video zeros" picture. Causes: illegal MMCM settings
   that the tools warned about but you ignored (VCO range!), a cascaded
   MMCM whose first stage is unlocked, or a typo in CLKFBOUT_MULT_F /
   DIVCLK_DIVIDE. Cross-check the synthesized clock against the clock
   summary in the timing report (section 4.2.4). To observe `LOCKED` on
   hardware, route it temporarily to a board LED or add an ILA (4.3).

2. **The reset chain holds the core down.** The framework feeds two resets
   into your core space: `main_reset_m2m_i` (framework/system reset) and
   `main_reset_core_i` ("Reset core" menu item / reset key) arrive in
   mega65.vhd (C64MEGA65 CORE/vhdl/mega65.vhd:116-117) and are combined
   with port-specific reset sources before reaching main.vhd's reset
   inputs (C64: `reset_soft_i => main_reset_core_i or main_reset_core`,
   `reset_hard_i => main_reset_m2m_i or main_reset_from_prgloader`,
   mega65.vhd:547-548). If you OR in a signal with the wrong polarity or
   never terminate your own power-on counter, the core never starts.
   Verify with an ILA on your core's internal reset net, or temporarily
   drive a LED. The C64 port even color-codes it: the power LED is blue
   while `main_reset_m2m_i` is asserted, green afterwards
   (mega65.vhd:534).

3. **`video_ce_o` is stuck.** Every consumer of your video output samples
   on `video_ce`. A stuck-low CE means the analog pipeline and the OSM
   counters see zero pixels even though HS/VS toggle. A CE with the wrong
   ratio shows up as a wrong "Pixel rate" line in the 2.5 s report and as
   a horizontally squashed/stretched picture. **RULE:** `video_ce_o` must
   be a one-`clk_main`-period pulse train whose rate equals the core's
   native (pre-scandoubler) pixel clock; `video_ce_ovl_o` must run at the
   post-scandoubler rate that matches `VGA_DX`/`VGA_DY` from globals.vhd
   (see Part III for derivation and the Amiga/C64 values).

### 4.1.5 Branch: ascal never locks - sync polarity and blank coverage

**RULE:** main.vhd's `video_hs_o`/`video_vs_o`/`video_hblank_o`/
`video_vblank_o` must be ACTIVE-HIGH pulses. The canonical sink documents
it: M2M/vhdl/controllers/MiSTer/video_mixer.sv:42-46 declares the four
inputs HSync/VSync/HBlank/VBlank literally under the comment
`// Positive pulses.`, and ascal detects start-of-frame on the RISING edge
of its vsync input (`IF i_pvs='1' AND i_vs_pre='0' THEN i_sof<='1'`,
M2M/vhdl/av_pipeline/ascal.vhd:1194).

**TRAP:** Most MiSTer cores output ACTIVE-LOW syncs internally (Minimig's
`_hsync`/`_vsync` are asserted low, and MiSTer's own emu glue inverts them
before video_mixer). If you forget the inversion in main.vhd, ascal treats
the *end* of vsync as start-of-frame: frame capture and size detection are
wrong, the measured `ASCAL: DX/DY` values are garbage or diverge from the
`M2M:` values (the divergence warning in the serial log is your tell), and
HDMI stays black or rolls - while a forgiving multisync VGA monitor may
still show a stable picture. "VGA works, HDMI black" therefore points
straight at sync polarity. (Amiga port: `video_hs_o <= not _hsync` etc. in
CORE/vhdl/main.vhd.)

Second requirement: **blanking must cover the sync pulse and the porches**.
The framework derives the data-enable and visible-area measurement from
HBlank/VBlank, not from the syncs. If your core has no blanking outputs
and you tie them low, the "visible area" becomes the whole scan line
including sync - the measured DX exceeds the real picture, ascal's line
buffer (IHRES = 1024 pixels) can overflow on cores with long lines, and
the OSM is positioned wrongly. Generate blanks that envelop the syncs
(blank asserts before sync, deasserts after), exactly like C64MEGA65's
video_sync module does for the VIC-II (instantiated in C64 main.vhd, see
Appendix C for the location).

### 4.1.6 Tool: the QNICE debug console

The framework contains a full machine monitor you can drop into at any
time. This is the single most underused debugging feature of M2M.

- **Enter:** hold `Run/Stop` + `Cursor Up`, and while holding both press
  `Help` (M2M/rom/shell.asm:1350-1371, routine `CHECK_DEBUG`; key combo
  documented in M2M/rom/strings.asm:27). The core keeps running; only the
  Shell main loop is suspended.
- On entry the console prints (M2M/rom/strings.asm:30-39):
  `Entering MiSTer2MEGA65 debug mode. Press H for help and press C R
  <addr1> to return to where you left off and press C R <addr2> to restart
  the Shell.` In RELEASE builds you get both addresses; in DEBUG builds
  only the restart address (shell.asm:1377-1403).
- **Resume:** type `C` then `R` (CONTROL/RUN, verified in
  M2M/QNICE/monitor/qmon.asm:174-181) and enter the hex address the
  banner gave you.
- Commands are two letters, group then command, with prompted hex
  arguments. The ones that matter for porting (all verified in
  M2M/QNICE/monitor/qmon.asm:190-309): `M D` dump memory range, `M E`
  examine one word, `M C` change one word, `M F` fill, `M M` move,
  `M S` disassemble; `C R` run from address, `C C` cold start, `C H`
  halt. `H` prints the full help.

**The memory-inspector recipe** (verify that a ROM actually arrived in
your core's memory): all core devices are mapped into QNICE's address
space through a 4k-word MMIO window at 0x7000. Select the device by
writing its ID to 0xFFF4 (`M2M$RAMROM_DEV`) and the 4k-word page within
the device to 0xFFF5 (`M2M$RAMROM_4KWIN`); then dump 0x7000-0x7FFF
(constants: M2M/rom/sysdef.asm:195,210,211). In the console:

```text
QMON> MEMORY/CHANGE ADDRESS=FFF4 CURRENT VALUE=xxxx NEW VALUE=0100
QMON> MEMORY/CHANGE ADDRESS=FFF5 CURRENT VALUE=xxxx NEW VALUE=0000
QMON> MEMORY/DUMP START ADDRESS=7000 END ADDRESS=7040
```

(You type only `M`, `C`/`D` and the hex values; the Monitor echoes the
command names and prompts - prompt strings verified in
M2M/QNICE/monitor/qmon.asm:616-646. `0x0100` here is the device ID, e.g.
the Kickstart buffer; window `0000` selects the first 4k words.)

Compare the dump against a hex dump of the ROM file on your PC. Device IDs
come from your own globals.vhd: C64 uses 0x0100 for the C64's main RAM and
0x0105/0x0106 for the custom Kernal devices (C64MEGA65
CORE/vhdl/globals.vhd:85-91); the Amiga port uses 0x0100 for the Kickstart
buffer (CORE/vhdl/globals.vhd:92) (Amiga port). Note that QNICE is
word-addressed: one 16-bit word per address, so a 4k window covers 8 KiB
of byte-oriented ROM, and you must know how your qnice_dev glue packs
bytes into words (see Part III) before declaring a dump "wrong".

This also works on *live* core memory: with the C64 port you can watch the
C64's RAM change while a program runs - device 0x0100, window = address
div 4096.

### 4.1.7 Tool: the serial memory report (first Help press)

The first time you open the OSM after a core start, the firmware logs the
Shell's heap utilization to the serial console (`LOG_HEAP1`/`LOG_HEAP2`,
implemented in M2M/rom/coreinfo.asm:230 ff., called from the menu code at
M2M/rom/options.asm:135 and :188; strings at M2M/rom/strings.asm:69-78):
`OSM heap utilization:` followed by `MENU_HEAP_SIZE`, `Free menu heap
space` (or `FATAL overflow of menu heap`), `OPTM_HEAP_SIZE`, `Free OPTM
heap space`, plus a general QNICE memory summary. Watch this whenever you
grow the menu in config.vhd: it tells you how close you are to the next
fatal error before it happens.

### 4.1.8 Reading the fatal error screen

When the Shell hits an unrecoverable condition it paints a full-screen
message starting with `FATAL ERROR:` (string catalog in
M2M/rom/strings.asm:163-219) plus an error code, mirrors it to the serial
console, and halts into the QNICE monitor. The two you will actually meet
while porting:

- **`Heap corruption: Hint: MENU_HEAP_SIZE` / `OPTM_HEAP_SIZE`**
  (strings.asm:201-202): your menu in config.vhd has outgrown the Shell's
  memory layout. The error code is the overrun in words - grow exactly
  that. The layout lives in *your* firmware file CORE/m2m-rom/m2m-rom.asm:
  C64 sets `MENU_HEAP_SIZE .EQU 1920` (C64MEGA65
  CORE/m2m-rom/m2m-rom.asm:576) and `STACK_SIZE .EQU 1536` /
  `B_STACK_SIZE .EQU 768` (:612-613); the Amiga port starts smaller with
  `MENU_HEAP_SIZE .EQU 1024` (CORE/m2m-rom/m2m-rom.asm:215) (Amiga port).
  The check that fires is in M2M/rom/options.asm:129-145 (menu heap) and
  :156-198 (OPTM heap).
- **`SD Card: <message>` with a 16-bit code `XXYY`** - decode in this
  order:
  - `XX < 0xEE`: hardware-layer error inside the SPI SD controller
    M2M/QNICE/vhdl/sd_spi.vhd. `YY` is a `t_error_code`
    (sd_spi.vhd:250-258: 01 R1Error, 02 CRCError/WriteTimeout,
    03 DataRespError, 04 DataError, 05 WPError, 06 SDError, 07 NoSDError);
    the block `calcDebugOutputs` (sd_spi.vhd:1277-1340) produces `XX`.
  - `0xEE21`: read/write jam between sd_spi.vhd and the QNICE adapter
    M2M/QNICE/vhdl/sdcard.vhd (sdcard.vhd:320, `SD$ERR_READWRITEJAM`,
    M2M/QNICE/monitor/sysdef.asm:273). **TRAP:** 0xEE21 is double-booked -
    the FAT32 layer defines `FAT23$ERR_SEEKTOOLARGE .EQU 0xEE21`
    (sysdef.asm:295). If the error happened during a file seek it is the
    latter.
  - `0xEEFF`: timeout in QNICE's SD routines (`SD$ERR_TIMEOUT`,
    sysdef.asm:274, raised in M2M/QNICE/monitor/sd_library.asm:161).
  - any other `0xEEYY`: FAT32 stack error - decode against the
    "FAT32 ERROR CODES" section, M2M/QNICE/monitor/sysdef.asm:282-295
    (EE10 no/illegal MBR, EE11 bad partition number, EE12 no FAT32
    partition, EE15 illegal volume id, EE19 directory not found,
    EE20 file not found, ...).
  - **Why** SD errors cluster on real hardware: M2M's controller is
    SPI-based and cannot gracefully degrade with aging cards; and on
    R3/R3A boards the HDMI back-powering problem (4.1.1) corrupts SD
    traffic. Card must be FAT32 and at most 32 GB. Reformat or replace
    before suspecting your port.

## 4.2 Reading Vivado's outputs - quick reference

After every run, Vivado leaves a forest of files under
`CORE/CORE-R3.runs/` (one `.runs` tree per board revision project). You
rarely need the GUI to answer a porting question - the right file plus the
right grep is faster, and if (like the Amiga port) your Vivado runs in a
VM while you analyze on the host, files are all you get. All paths below
were verified against the Amiga port's real run outputs; the file names
are `<top>_*` where `<top>` is e.g. `mega65_r3`.

### 4.2.1 Which file answers which question

| Question | File |
|---|---|
| Did synthesis elaborate my sources, and what did it warn about? | `synth_1/runme.log` (the `.vds` file next to it is the same synthesis log; `runme.log` wraps it) |
| Did my `$readmemh`/`.mem` init files load? | `synth_1/runme.log`, see 4.2.2 |
| How full is the chip (after placement, the number that counts)? | `impl_1/<top>_utilization_placed.rpt` |
| Which module eats my BRAM/LUTs? | not a default file - run `report_utilization -hierarchical` (4.2.3) |
| Does the design meet timing? | `impl_1/<top>_timing_summary_routed.rpt` |
| Is the design even fully routed? | `impl_1/<top>_route_status.rpt` - `# of nets with routing errors` must be 0 |
| Structural lint (CDC, reset, clocking style) | `impl_1/<top>_methodology_drc_routed.rpt` |
| Hard design-rule violations | `impl_1/<top>_drc_*.rpt` (one per stage: `_opted`, `_routed`) |
| Estimated power per domain | `impl_1/<top>_power_routed.rpt` |
| The bitstream | `impl_1/<top>.bit` |

The synthesis-stage `synth_1/<top>_utilization_synth.rpt` exists too, but
use the *_placed* one for decisions: it reflects what was actually
implemented, including BRAM-to-LUTRAM demotions and replication.

### 4.2.2 The greps that matter (synthesis log)

```bash
R=CORE/CORE-R3.runs

# 1. ROM/microcode init files actually found and read?
grep "read successfully" $R/synth_1/runme.log
```

Expected (Amiga port; the fx68k CPU is dead without these two):

```text
INFO: [Synth 8-3876] $readmem data file '../../Minimig_MiSTerMEGA65/rtl/fx68k/nanorom.mem' is read successfully
INFO: [Synth 8-3876] $readmem data file '../../Minimig_MiSTerMEGA65/rtl/fx68k/microrom.mem' is read successfully
```

**TRAP:** A missing `.mem` file is only a warning, not an error - Vivado
happily synthesizes a CPU whose microcode ROM is all zeros, which presents
as a perfectly healthy bitstream with a dead core. The paths inside
Verilog `$readmemh()` calls are resolved relative to the synthesis run
directory (`$R/synth_1/`), not relative to the source file. Check this
grep after every change to the project structure.

```bash
# 2. Did Vivado silently demote block RAM to LUTRAM?
grep "Synth 8-5835" $R/synth_1/runme.log
```

Real example from the Amiga port's first run:

```text
WARNING: [Synth 8-5835] Resources of type BRAM have been overutilized.
Used = 760, Available = 730. Will try to implement using LUT-RAM.
```

This is the single most consequential warning for big cores: the design
still builds, but several thousand LUTs vanish into demoted memories and
timing gets harder. (Units here are RAMB18 halves: 760/730 halves = 380
requested vs 365 RAMB36 tiles.) If you see it, do the per-module hunt in
4.2.3 and decide *yourself* what moves to LUTRAM or HyperRAM instead of
letting Vivado pick.

```bash
# 3. Anything Vivado itself flags as serious?
grep "CRITICAL" $R/synth_1/runme.log $R/impl_1/runme.log
```

A clean port synthesizes with zero `CRITICAL WARNING` lines (the Amiga
port's run 2 has zero). Typical critical warnings during bring-up:
constraints referencing not-yet-existing cells (`set_max_delay` on a
renamed net path) and multi-driven nets after a botched merge. Never ship
with unexplained criticals.

```bash
# 4. Timing pass/fail without opening the GUI
grep -c "VIOLATED" $R/impl_1/*_timing_summary_routed.rpt   # 0 = met
grep "All user specified timing constraints are met" $R/impl_1/*_timing_summary_routed.rpt
```

### 4.2.3 Hunting BRAM (and LUTs) per module

The stock reports only give totals. To see which entity uses what, open
the design checkpoint once and ask for the hierarchical report - either in
the Vivado GUI Tcl console or batch:

```tcl
open_checkpoint CORE/CORE-R3.runs/impl_1/mega65_r3_routed.dcp
report_utilization -hierarchical -hierarchical_depth 4 \
    -file util_hier.rpt
```

(`open_run impl_1` instead of `open_checkpoint` if the project is open.)
The resulting table has one row per instance with columns for Logic LUTs,
RAMB36/RAMB18, DSPs. Sort by the RAMB36 column and you instantly see
whether the six Amiga memory lanes, the QNICE ROM, ascal's line buffers or
some accidental 32-bit-wide register file is eating the budget. This is
how the Amiga port established its BRAM ledger: 320 tiles for the Amiga
memories (chip/slow/kick), 32 for QNICE, ~11.5 for the video pipeline -
363.5 of 365 tiles, i.e. the row to watch in
`<top>_utilization_placed.rpt` section "3. Memory":

```text
| Block RAM Tile    | 363.5 |     0 |          0 |       365 | 99.59 |
```

**RULE:** Re-check the `Block RAM Tile` row after every feature you add.
When a core sits at >95% BRAM, any new buffer must be justified against
the ledger or moved to HyperRAM (the Amiga port found that re-enabling the
IDE/HDD subsystem costs +8 RAMB36 and simply does not fit).

### 4.2.4 The timing summary's structure

`<top>_timing_summary_routed.rpt` is organized top-down; read it in this
order (section names and line numbers from the Amiga port's run 2):

1. **check_timing report** (near the top, line ~60): counts of
   `no_clock`, `unconstrained_internal_endpoints`, etc. Nonzero
   `no_clock` means part of your design is *not being timed at all* -
   fix constraints before believing any WNS number.
2. **Design Timing Summary** (line ~147): the one-line verdict -
   WNS/TNS (setup), WHS/THS (hold), WPWS/TPWS (pulse width) and failing
   endpoint counts. `All user specified timing constraints are met.` is
   the sentence you want (present in run 2, WNS +0.387 ns across 99468
   endpoints).
3. **Clock Summary**: every generated clock with its actual period -
   cross-check that your MMCM really produces what clk.vhd intended.
4. **Intra Clock Table**: worst slack per clock domain. A porting
   failure usually lives in exactly one row here.
5. **Inter Clock Table**: domain crossings the timer is timing. **TRAP:**
   rows you did not expect here mean you forgot a CDC constraint or a
   `set_false_path`/`set_max_delay` - the tools will then try (and often
   fail) to meet a meaningless synchronous requirement across unrelated
   clocks. See the CDC constraints discussion in Part III.
6. **Other Path Groups Table**: where `set_max_delay -datapath_only`
   constraints (the M2M CDC idiom) report their slack.
7. **Timing Details**: per-clock worst paths with full cell-by-cell
   delay breakdown - this is where you identify the actual failing logic.

**Why** the placed/routed report and not synthesis estimates: synthesis
timing is pre-placement fiction on a 200T part this full; the Amiga port
went from "WNS -6.7 ns" (run 1) to "+0.387 ns" (run 2) on two targeted
fixes (ascal-FIFO CDC max_delay constraints in CORE.xdc plus removing a
QNICE debug port from the chip/slow RAMs), and only `*_routed.rpt` tells
the truth about either.

### 4.2.5 Methodology and DRC reports

`<top>_methodology_drc_routed.rpt` is Vivado's structural lint
(TIMING-/SYNTH-/XDC- rule ids): unsafe CDCs, missing input delays,
combinational loops, BUFG recommendations. It is noisy on inherited
MiSTer code; triage once, record the accepted warnings in your port's
docs (the Amiga port keeps that list in doc/synthesis-handoff.md), then
watch only for *new* entries. `<top>_drc_routed.rpt` must be clean of
errors or `write_bitstream` would have refused; its warnings are worth a
scan before the first hardware test.

One operational note for VM setups (Amiga port experience): close an open
implemented design in the GUI before relaunching synthesis - a loaded,
routed 200T design holds several GB of RAM and can starve the child
synthesis process to an out-of-memory crash.

## 4.3 ILA / hardware debug

### 4.3.1 Choosing the tool: QNICE console vs ILA

Use the **QNICE debug console** (4.1.6) when the question is about *state
that is memory-mapped*: ROM/RAM contents, vdrive status, framework CSR
bits, anything behind a RAMROM device window. It costs zero FPGA
resources, needs no rebuild, and works interactively at runtime.

Use a **Vivado ILA** when the question is about *waveforms*: is `LOCKED`
asserting, is my reset releasing, does the CPU's address bus move, are
HS/VS/CE pulsing with the right relationship, does a bus handshake
deadlock. An ILA gives you cycle accuracy but costs a synthesis round trip
per probe change - and BRAM.

**TRAP:** ILA capture buffers are built from block RAM. On a BRAM-starved
port (the Amiga port sits at 363.5 of 365 tiles, section 4.2.3) there is
no room for a default-depth ILA. Either keep the capture depth at the
1024 minimum with few probes, or temporarily comment out a memory you do
not need for the experiment (e.g. one Amiga slow-RAM lane) to make room.
Check the `Block RAM Tile` row again after inserting the ILA.

### 4.3.2 JTAG connection rules

These rules come from hard-won M2M experience (MJoergen, recorded in the
M2M wiki's Debugging page) and Xilinx AR 63292:

- In Vivado Hardware Manager, **do not use Auto Connect**. Manually
  "Open New Target", add the server, and set the JTAG clock explicitly.
- Set the **JTAG frequency to 5 MHz** (a too-high default TCK is the
  usual reason that "no data appears" when arming an ILA trigger).
- **RULE:** the JTAG frequency must stay **below one third** of the clock
  of the signals being captured. Example from the Galaga port: 18 MHz
  signal clock -> JTAG must be < 6 MHz. With a 32 MHz core clock (C64) or
  the Amiga's 28.375/113.5 MHz domains you do not notice the problem at
  5 MHz - which is why it bites exactly when you port a slow-clocked
  arcade core and conclude, wrongly, that your design is dead.
- On the MEGA65 the JTAG interface is the TE0790-03 "XMOD" adapter board;
  the same USB connection also carries the serial console (4.3.4). You
  can push bitstreams over it with `m65 -q <file>.bit` (mega65-tools)
  without touching flash.

### 4.3.3 Inserting an ILA: mark_debug plus the batch script

The maintainable workflow (used by the reference port) is attribute-driven
rather than instantiating `ila_0` IP by hand:

1. Mark signals in your VHDL:

   ```vhdl
   attribute mark_debug : string;
   attribute mark_debug of main_rst       : signal is "true";
   attribute mark_debug of main_locked    : signal is "true";
   attribute mark_debug of video_vs       : signal is "true";
   ```

2. Run the batch insertion script after synthesis. C64MEGA65 ships it as
   CORE/debug.tcl (J. McCluskey's `batch_insert_ila`): it collects all
   `MARK_DEBUG` nets, groups them by traced clock domain, creates one ILA
   core per domain (cross-triggered if there are several), connects the
   probes, runs `implement_debug_core` and writes the probe file
   `debug_nets.ltx` (C64MEGA65 CORE/debug.tcl:20-232). The bottom of the
   file invokes `batch_insert_ila {1024}` - the capture depth in samples
   (debug.tcl:232); raise it only if BRAM allows.

3. **RULE:** the script must run *after synthesis and before opt_design*
   (stated in its header, debug.tcl:3) - hook it as a `tcl.pre` on the
   implementation's first step, or source it manually on the opened
   synthesized design. If opt_design runs first, marked nets may already
   be optimized away.

4. Per-net overrides exist as extra attributes (debug.tcl:7-10):
   `mark_debug_clock` (force a sampling clock when the tracer cannot
   find one - needed for nets driven by combinational logic),
   `mark_debug_depth`, `mark_debug_adv_trigger`.

After bitstream programming, Hardware Manager finds the ILA via the
`.ltx` file; respect the JTAG rules from 4.3.2 or the waveform window
stays empty.

**Why** attribute-driven: probes live next to the signal declarations they
watch, survive renames better than XDC-based `mark_debug`, and removing
the debug build is one commit revert.

### 4.3.4 UART notes

- There is exactly **one** UART in an M2M system and it belongs to QNICE:
  framework.vhd exposes `uart_rxd_i`/`uart_txd_o`
  (M2M/vhdl/framework.vhd:32-33) and wires them to the QNICE subsystem
  (framework.vhd:592-593). The pins are the MEGA65 debug UART
  (`DBG_UART_RX`/`DBG_UART_TX`, pins L14/L13 on R3 boards,
  M2M/MEGA65-R3.xdc:18-19), surfaced on the host as the TE0790's USB
  serial port. 115200 8N1.
- The MiSTer core's own UART features (if the upstream core had any, e.g.
  MIDI or modem on the MiSTer user port) are NOT connected by the
  framework; tie them off unless you deliberately multiplex the pins.
- The serial console doubles as your **printf channel**: everything in
  section 4.1 (banner, 2.5 s video report, heap report, fatal errors)
  arrives there, and your own firmware additions in CORE/m2m-rom/
  m2m-rom.asm can print with `SYSCALL(puts, 1)` exactly like the Shell
  does - often the cheapest "probe" of all, because the firmware can read
  any RAMROM-mapped core state and print it without any FPGA cost.
- **TRAP:** while you sit in the QNICE Monitor (debug mode), the Shell
  main loop is frozen: the OSM does not react and vdrive requests are not
  serviced (the core itself keeps running). Do not diagnose "the core
  hung" while you are the one holding it in the Monitor - type `C R
  <addr>` to resume first (4.1.6).

## 4.4 Appendix A - main.vhd entity quick reference

main.vhd is *your* file (core space). It wraps the MiSTer core and runs
entirely in the core's clock domain - the framework never reaches into
it, and everything below is the contract at its boundary. Two specimens:
the minimal template entity (MiSTer2MEGA65 template V2.0.1,
CORE/vhdl/main.vhd:16-67 - the same V2.0.1 the vendored M2M/ framework
tree in this repo carries) and the full-grown C64 entity (C64MEGA65
CORE/vhdl/main.vhd:19-253).

### 4.4.1 The template entity, port by port

Generic:

| Name | Type | Meaning |
|---|---|---|
| `G_VDNUM` | natural | Number of virtual drives, passed down from `C_VDNUM` in globals.vhd; sizes the vdrive vectors when you add them later |

Ports (template V2.0.1 CORE/vhdl/main.vhd:21-65; all in the
`clk_main_i` domain):

| Port | Dir | Width | Meaning / typical wiring |
|---|---|---|---|
| `clk_main_i` | in | 1 | The core clock from your clk.vhd. Everything in main.vhd is synchronous to it |
| `reset_soft_i` | in | 1 | "Reset core" from the Shell (menu item, reset button short press). Min pulse 32 clock cycles. OR into the MiSTer core's reset |
| `reset_hard_i` | in | 1 | Framework/M2M reset (long reset press, core start). Treat as power-on reset |
| `pause_i` | in | 1 | High = please pause. Wire to the core's pause/cpu-halt input if it has one; the Shell asserts it while the OSM is open if config.vhd's `OPTM_PAUSE` says so. Safe to ignore for a first port |
| `clk_main_speed_i` | in | natural | The exact core clock frequency in Hz (from globals.vhd `CORE_CLK_SPEED`). Used by cores/glue that derive timers; pass exact numbers or derived clocks drift |
| `video_ce_o` | out | 1 | Pixel clock enable, one `clk_main_i` pulse per native (pre-scandoubler) pixel. See 4.1.4 |
| `video_ce_ovl_o` | out | 1 | Clock enable for OSM overlay / post-scandoubler sampling; rate must match `VGA_DX`x`VGA_DY` from globals.vhd |
| `video_red_o` / `video_green_o` / `video_blue_o` | out | 8 each | RGB, full 8 bit per channel. Expand smaller core outputs by bit replication, not zero padding |
| `video_vs_o` / `video_hs_o` | out | 1 | Sync pulses, ACTIVE HIGH (4.1.5). Invert active-low MiSTer syncs here |
| `video_hblank_o` / `video_vblank_o` | out | 1 | Blanking, ACTIVE HIGH, must envelop the sync pulses |
| `audio_left_o` / `audio_right_o` | out | signed 16 | Signed PCM at core clock; the framework resamples/filters downstream |
| `kb_key_num_i` | in | int 0..79 | M2M keyboard scanner: cycles through all 80 MEGA65 key numbers (Part II has the matrix table) |
| `kb_key_pressed_n_i` | in | 1 | Low-active, debounced: is `kb_key_num_i` pressed *right now*. Build your core's key matrix from this pair |
| `joy_1_*_n_i`, `joy_2_*_n_i` | in | 1 each | Both MEGA65 joystick ports, low-active (up/down/left/right/fire) |
| `pot1_x_i`/`pot1_y_i`/`pot2_x_i`/`pot2_y_i` | in | 8 each | Paddle/mouse potentiometers, 0..255 |

That is the whole contract for a video-and-sound core with no storage.
The template architecture instantiates the demo core (template
main.vhd:79-107); your first integration step is replacing exactly that
instantiation (see Part II).

### 4.4.2 Standard extensions in a full-grown port (C64 as specimen)

Real ports add ports to this entity; the framework does not care, because
main is instantiated by *your* mega65.vhd, which supplies the new signals.
The recurring categories, with the C64 entity as the reference (all line
numbers C64MEGA65 CORE/vhdl/main.vhd):

- **Configuration option inputs** (lines 50-69): `c64_rom_i`,
  `c64_ntsc_i`, `c64_sid_ver_i`, `c64_cia_ver_i`,
  `c64_exp_port_mode_i`... These are OSM menu bits, sliced out of the
  256-bit `main_osm_control_i` vector in mega65.vhd using named constants
  (`C_MENU_*`, C64MEGA65 CORE/vhdl/mega65.vhd:320-347) and fed in as
  typed signals. **RULE:** decode OSM bit positions in mega65.vhd, never
  inside main.vhd - main.vhd should receive semantic signals, not menu
  indices.
- **External RAM buses** (lines 124-128): `c64_ram_addr_o`,
  `c64_ram_data_o/_i`, `c64_ram_we_o` - the core's main memory lives
  outside main.vhd (in mega65.vhd BRAM or HyperRAM) so that QNICE can
  reach it through a device window. The Amiga port does the same with an
  SRAM-style banked bus for chip/slow/kick (`ram_addr_o(22 downto 1)`,
  byte enables, active-low we/oe; Amiga port CORE/vhdl/main.vhd:53-63).
- **Avalon memory-master ports** (lines 194-203): `avm_*`
  (waitrequest/read/write/address/burstcount...) - the M2M idiom for
  HyperRAM-backed expansions; the C64 uses it for the simulated REU.
  Goes to the framework's HyperRAM arbiter via CDC in mega65.vhd.
- **Drive LED outputs** (lines 120-122): `drive_led_o`,
  `drive_led_col_o` (24-bit RGB) - the Shell lets the core drive the
  MEGA65's drive LED when no framework activity overrides it.
- **vdrive/QNICE bridge** (lines 130-136): `c64_clk_sd_i` (the QNICE
  clock!), `c64_qnice_addr_i/_data_i/_data_o/_ce_i/_we_i` - the virtual
  drive subsystem's path into the core's disk buffer RAM. **TRAP:** these
  ports carry QNICE-domain signals *into* the core-domain entity; the
  dual-clock RAMs inside (e.g. the C1541 sector buffer) are the CDC
  boundary. Do not casually mix them with `clk_main_i` logic.
- **ROM-load interfaces** (lines 229-239): `c64rom_we_i/_addr_i/_data_i`
  and `c1541rom_*` - write ports (again in the QNICE clock domain) that
  let the Shell stream custom Kernal/DOS ROM files into the core's ROM
  BRAMs. (Where the ROM BRAM lives outside main.vhd, this interface lives
  there instead: the Amiga port streams the Kickstart into the kick BRAM
  inside mega65.vhd via `qnice_kick_we_*` write enables, Amiga port
  CORE/vhdl/mega65.vhd:289-292,559-560.)
- **Physical expansion port** (lines 152-192): `cart_*` with `_i`/`_o`/
  `_oe_o` triples per pin group - only for cores that drive the MEGA65's
  hardware cartridge slot; the OE signals control board-level tristate
  drivers in the board wrapper.
- **Software cartridge/CRT parser interface** (lines 205-227):
  `cartridge_*`/`crt_*` - the C64's .CRT streaming machinery between the
  QNICE CRT/ROM loader and the cartridge emulation.
- **RTC input** (line 251): `rtc_i(64 downto 0)` - BCD-encoded date/time
  snapshot in MiSTer's user_io format (seconds/minutes/hours/day/month/
  year/weekday plus a toggle bit), for cores that expose a clock.
- **Core-specific reset refinements** (lines 27-44): the C64 splits reset
  semantics further (`cart_soft_reset_i/_o`, `trigger_run_i` for PRG
  autostart). Expect to grow such ports as your port matures; document
  the semantics in a comment block like C64's "RESET SEMANTICS".

**Why** this shape: main.vhd stays a pure single-clock island whose ports
are either core-domain signals or explicitly-documented QNICE-domain
streams terminating in dual-clock RAMs. All real CDC happens one level up
in mega65.vhd (Appendix B), which keeps the core wrapper reviewable.

## 4.5 Appendix B - mega65.vhd port groups quick reference

mega65.vhd (entity `MEGA65_Core`) is the framework-facing side of your
port. Unlike main.vhd, its entity is a FIXED contract: the framework's
board top-levels instantiate it (`CORE : entity work.MEGA65_Core`,
M2M/vhdl/top_mega65-r3.vhd:670 in V2.0.1), so you implement its
architecture but **RULE: never add, remove or retype its ports** - the
template (MiSTer2MEGA65 V2.0.1 CORE/vhdl/mega65.vhd:21-219) and the C64
port (C64MEGA65 CORE/vhdl/mega65.vhd:24-222) have the identical port
list, and so must you. The entity is explicitly organized into clock
domain groups by comment banners; all line numbers below refer to the C64
file.

### 4.5.1 QNICE clock domain group (lines 34-67)

| Port(s) | Dir | One-line semantics |
|---|---|---|
| `qnice_clk_i`, `qnice_rst_i` | in | 50 MHz QNICE clock/reset; everything `qnice_*` is synchronous to it |
| `qnice_dvi_o` | out | 1 = DVI mode (no HDMI sound); usually an OSM bit |
| `qnice_video_mode_o` | out | HDMI output mode (`video_mode_type` from video_modes_pkg.vhd), from the HDMI resolution OSM bits |
| `qnice_osm_cfg_scaling_o` | out | OSM scaling config; tie to OSM bits or a constant |
| `qnice_scandoubler_o` | out | 1 = scandouble analog out (15 kHz -> 30 kHz) |
| `qnice_audio_mute_o`, `qnice_audio_filter_o` | out | Audio path switches; typically `'0'` and an OSM "improve audio" bit |
| `qnice_zoom_crop_o` | out | HDMI zoom/crop ("flicker-free" overscan handling) |
| `qnice_ascal_mode_o`, `_polyphase_o`, `_triplebuf_o` | out | ascal scaler mode/filters/buffering; OSM bits or constants |
| `qnice_retro15kHz_o`, `qnice_csync_o` | out | Analog retro modes: 15 kHz horizontal rate, composite sync on HS pin |
| `qnice_flip_joyports_o` | out | Swap joystick ports 1/2 (OSM convenience bit) |
| `qnice_osm_control_i` | in | 256 menu item states, index = line number in config.vhd's `OPTM_ITEMS` |
| `qnice_gp_reg_i` | in | 256-bit general purpose register written by firmware (M2M$GP regs); free for port-specific QNICE->core signaling |
| `qnice_dev_id_i`, `_addr_i(27:0)`, `_data_i`, `_data_o`, `_ce_i`, `_we_i`, `_wait_o` | in/out | THE device-window bus: the Shell reads/writes your core's RAMs/ROMs/buffers by device ID (your `C_DEV_*` constants from globals.vhd). Decode `qnice_dev_id_i`, mux per device; assert `_wait_o` to stall QNICE on slow devices |

**Why** the mode outputs sit in this group: the Shell samples and applies
them via QNICE, so they must be stable in the QNICE domain - derive them
from `qnice_osm_control_i` bits (combinational is fine), not from
`main_*` signals.

### 4.5.2 HyperRAM clock domain group (lines 73-85)

| Port(s) | Dir | One-line semantics |
|---|---|---|
| `hr_clk_i`, `hr_rst_i` | in | HyperRAM controller clock (~100 MHz) and reset |
| `hr_core_write_o`, `_read_o`, `_address_o(31:0)`, `_writedata_o(15:0)`, `_byteenable_o`, `_burstcount_o`, `_readdata_i`, `_readdatavalid_i`, `_waitrequest_i` | out/in | Avalon-MM master into the framework's HyperRAM arbiter (your slice of the 8 MB HyperRAM, shared with ascal's framebuffer) |
| `hr_high_i`, `hr_low_i` | in | Fill-level feedback from the HDMI flicker-free machinery ("core too fast/slow"); consume only if you implement dynamic speed adjustment |

A port without HyperRAM needs ties: drive write/read low and the buses to
zeros, exactly like the Amiga port does (Amiga port
CORE/vhdl/mega65.vhd:310-315); inputs may stay unread. The C64 uses this
group for the REU, bridged from main.vhd's `avm_*` ports through a CDC
plus the `avm_fifo`/arbitration chain in its mega65.vhd architecture.

### 4.5.3 Video clock domain group (lines 91-101)

All OUTPUTS - you hand the framework a video clock plus the picture:

| Port(s) | Dir | One-line semantics |
|---|---|---|
| `video_clk_o`, `video_rst_o` | out | The clock the video signals are synchronous to. Usually simply the core clock: `video_clk_o <= main_clk_o` (C64 mega65.vhd:429-430; same in the Amiga port, CORE/vhdl/mega65.vhd:382) |
| `video_ce_o`, `video_ce_ovl_o` | out | Pass-through of main.vhd's clock enables |
| `video_red_o`, `_green_o`, `_blue_o` (8 each), `video_vs_o`, `_hs_o`, `_hblank_o`, `_vblank_o` | out | Pass-through of main.vhd's video bundle (active-high syncs/blanks, see 4.1.5) |

Typical implementation: pure wiring from the main.vhd instance. A
separate video clock is only needed if your core renders in a different
domain than it computes (rare; keep them equal until proven otherwise).

### 4.5.4 Core clock domain group (lines 107-165)

| Port(s) | Dir | One-line semantics |
|---|---|---|
| `clk_i` | in | The board's raw 100 MHz oscillator - input to YOUR clk.vhd |
| `main_clk_o`, `main_rst_o` | out | Your core clock and its synchronized reset, generated in clk.vhd, handed to the framework so it can CDC everything `main_*` for you |
| `main_reset_m2m_i`, `main_reset_core_i` | in | The two framework resets (machine vs core-only); combine into main.vhd's `reset_hard_i`/`reset_soft_i` (4.1.4) |
| `main_pause_core_i` | in | Pause request (OSM open + `OPTM_PAUSE`); to main.vhd's `pause_i` |
| `main_osm_control_i` | in | The same 256 menu bits as in the QNICE group, already CDC'd to the core domain - slice with your `C_MENU_*` constants (C64 mega65.vhd:320-347) |
| `main_qnice_gp_reg_i` | in | gp_reg CDC'd to core domain; unused by most ports (C64 declares and ignores it) |
| `main_audio_left_o`, `main_audio_right_o` | out | Signed 16-bit PCM from main.vhd |
| `main_kb_key_num_i`, `main_kb_key_pressed_n_i` | in | Keyboard scanner pair, to main.vhd |
| `main_power_led_o`, `main_power_led_col_o(23:0)`, `main_drive_led_o`, `main_drive_led_col_o(23:0)` | out | Board LEDs with 24-bit RGB color; e.g. C64 makes the power LED blue while in reset (mega65.vhd:534) |
| `main_joy_1_*_n_i/_o`, `main_joy_2_*_n_i/_o` | in/out | Low-active joystick lines; the `_o` side drives the port (for cores that write to control ports) - tie to `'1'` if unused (Amiga port CORE/vhdl/mega65.vhd:360-364) |
| `main_pot1/2_x/y_i` | in | Paddle ADC values |
| `main_rtc_i(64:0)` | in | BCD real-time clock snapshot (format in 4.4.2) |

### 4.5.5 IEC group (lines 168-178) and cartridge group (lines 181-220)

Hardware passthrough pins for the MEGA65's physical CBM-488/IEC connector
and the C64-style expansion port. They exist in every port's entity
(fixed contract!) but only Commodore-family cores use them.

- IEC: `iec_*_en_o` are tristate driver enables, `iec_*_n_i/_o` the
  low-active signals. Unused -> drive enables `'0'` and outputs `'1'`
  (Amiga port CORE/vhdl/mega65.vhd:350-358).
- Cartridge: `cart_*` triples (`_i`, `_o`, `_oe_o`) per pin group plus
  `cart_en_o` for the level shifters. Unused -> all `_oe_o` to `'0'`,
  benign defaults on outputs (Amiga port CORE/vhdl/mega65.vhd:317-348).
  **TRAP:** due to a bug on R5/R6 boards, `cart_en_o` must be `'1'` even
  when the port is unused, or joystick port 2 stops working (comment and
  fix: Amiga port CORE/vhdl/mega65.vhd:322-323; the C64 is not affected
  because it always enables the port anyway, C64MEGA65
  CORE/vhdl/main.vhd:881).

### 4.5.6 Which groups a typical port really uses

| Group | Demo/template | C64 (full) | Amiga (milestone 1) |
|---|---|---|---|
| QNICE: AV mode outputs | constants/OSM bits | OSM bits | OSM bits |
| QNICE: dev windows | default `x"EEEE"` + demo vdrive (template mega65.vhd:451-464) | 7 devices (RAM, vdrives, mount buf, CRT, PRG, 2x Kernal) | 3 devices (kick, chip, slow) |
| HyperRAM | tied off | used (REU) | tied off (future ADF/HDD buffers) |
| Video | pass-through | pass-through | pass-through |
| Core: keyboard/joy/LEDs | keyboard+joy | all incl. paddles, RTC, LEDs | keyboard, joy, LEDs |
| IEC | tied off | used (hardware IEC option) | tied off |
| Cartridge | tied off | used (hardware + simulated carts) | tied off (cart_en_o='1' workaround) |

## 4.6 Appendix C - repository map

### 4.6.1 Anatomy of an M2M port repository

Both the C64MEGA65 reference and the Amiga port follow the template
layout. Annotated tree (directories verified against both repos):

```text
<port-repo>/
|-- M2M/                     vendored framework tree, V2.0.1 - NEVER EDIT
|   |-- vhdl/                framework HDL: framework.vhd, top_mega65-rX.vhd
|   |   |-- av_pipeline/     analog_pipeline, digital_pipeline, ascal, OSM
|   |   |-- controllers/     keyboard, MiSTer helpers (video_mixer, scandoubler)
|   |   `-- QNICE/           QNICE integration wrappers
|   |-- rom/                 Shell firmware sources (shell.asm, options.asm,
|   |                        coreinfo.asm, sysdef.asm ...) - read, never edit
|   |-- QNICE/               QNICE submodule: CPU, monitor, assembler toolchain
|   |-- MEGA65-R3.xdc ...R6  board pin constraints (one per revision)
|   |-- common.xdc           board-independent framework constraints
|   |-- font/                OSM font
|   |-- video_filters/       ascal polyphase coefficient sets
|   `-- tools/               make_config.sh and friends
|-- CORE/                    YOUR port - everything you edit lives here
|   |-- vhdl/                clk.vhd, globals.vhd, config.vhd, main.vhd,
|   |                        mega65.vhd, keyboard.vhd + port-specific modules
|   |-- m2m-rom/             m2m-rom.asm (firmware config/extension),
|   |                        make_rom.sh; generated *.rom etc. are gitignored
|   |-- <MiSTer submodule>/  the adapted MiSTer core
|   |                        (C64_MiSTerMEGA65 / Minimig_MiSTerMEGA65)
|   |-- CORE-R3.xpr ...R6    one Vivado project per board revision
|   |-- CORE.xdc             port-specific constraints (clocks, CDC waivers)
|   `-- CORE-RX.runs/...     Vivado outputs (gitignored, see 4.2)
|-- doc/                     your port documentation
|-- AUTHORS, LICENSE, README.md, VERSIONS.md
```

What you edit vs never touch:

| Area | Rule |
|---|---|
| `CORE/vhdl/*`, `CORE/m2m-rom/m2m-rom.asm`, `CORE/*.xpr`, `CORE/CORE.xdc` | Yours - edit freely |
| `CORE/<MiSTer submodule>/` | Yours, but keep it a faithful fork of upstream: every divergence is a future merge cost. Adapt in dedicated commits on a develop branch (see Part I) |
| `M2M/**` | **RULE:** Never edit. It is vendored framework code (folder, not a submodule; only M2M/QNICE inside it is a git submodule); local changes block framework updates. If the framework needs a fix, fix it upstream |
| `M2M/rom/*`, `M2M/QNICE/*` | Read constantly (this guide cites them), edit never |
| `CORE/CORE-RX.{cache,hw,runs,sim}`, `vivado*.jou/log` | Build outputs/droppings - gitignored, safe to delete |

Gitignored generated files (from C64MEGA65's .gitignore, top of file):
the whole Vivado `*.cache/*.hw/*.runs/*.sim/.Xil` set, `vivado*.jou/log`,
and the QNICE build artifacts `CORE/m2m-rom/*.{def,lis,out,rom}` plus the
generated includes `osm_const.asm`, `globals.asm`, `shell_fhandles.asm`,
`shell_fh_ptrs.asm` and `M2M/rom/*.rom`. **TRAP:** because `m2m-rom.rom`
is gitignored *and* required for synthesis, a fresh clone must run
`CORE/m2m-rom/make_rom.sh` (normally done by the `synth_pre.tcl` hook -
which can fail silently on non-Linux hosts, see 4.1.2).

### 4.6.2 The C64MEGA65 file map - where to find every cited pattern

CORE/vhdl/ inventory (C64MEGA65; the five files marked * are the
mandatory set every port has - the rest is C64 feature growth):

| File | Role |
|---|---|
| `clk.vhd` * | MMCMs for the core clocks + reset generation (LOCKED chain, 4.1.4) |
| `globals.vhd` * | Core name/IDs, `CORE_CLK_SPEED`, `VGA_DX/DY`, `C_DEV_*` device IDs, vdrive/CRTROM tables |
| `config.vhd` * | OSM menu structure, welcome/help screens, Shell behavior flags |
| `main.vhd` * | Core wrapper, single clock domain (Appendix A) |
| `mega65.vhd` * | Framework-facing top (Appendix B), CDC, BRAMs, QNICE devices |
| `keyboard.vhd` | M2M key-number stream -> C64 matrix converter |
| `cartridge*.vhd`, `crt_*.vhd`, `sw_cartridge_*.vhd` | .CRT parsing/banking machinery |
| `prg_loader.vhd`, `reu_mapper.vhd` | PRG injection, REU-over-HyperRAM |
| `test/` | testbenches |

C64 main.vhd section line ranges (file is 1673 lines; banners verified):

| Lines | Section |
|---|---|
| 19-253 | Entity (the full-grown port list, Appendix A) |
| 257-339 | Signal declarations (MiSTer C64 signals, IEC, drives) |
| 340-393 | "RESET SEMANTICS" comment block - read it once in full; defines soft/hard reset tiers and the protected `reset_core_n` |
| 562-623 | Hard reset process + combined reset generation |
| 624-666 | C64 RAM and cartridge ROM access muxing |
| 667-812 | The MiSTer core instantiation (`fpga64_sid_iec`) - the heart of the wrapper |
| 813-1127 | Expansion port handling (incl. the output-registration rationale) |
| 1128-1162 | Simulated REU |
| 1163-1224 | Simulated cartridge |
| 1225-1266 | Video output conditioning for M2M (video_sync, sync-width fix, 382x270 crop, pixel-clock divider for `video_ce`) |
| 1267-1324 | Keyboard and joystick controller (the m2m_keys -> matrix pattern) |
| 1377-1536 | IEC bus arbitration: hardware port + simulated drives (`iec_drive_inst` at 1452) |
| 1537-1586 | `vdrives_inst` - the QNICE virtual-drive bridge |

Amiga port equivalents, for cross-reading (Amiga port): CORE/vhdl/ holds
the same mandatory five plus `amiga_config.vhd` (the Minimig config FSM
that replaces MiSTer's HPS config strobe) and `keyboard.vhd` (MEGA65 ->
Amiga keycodes); the BRAM lanes and Kickstart streaming live in
mega65.vhd as shown in 4.4.2/4.5.5.

## 4.7 Appendix D - glossary

M2M terms:

- **M2M / MiSTer2MEGA65**: the porting framework. Provides clocking,
  QNICE subsystem, Shell, OSM, video/audio pipelines, SD card, HyperRAM,
  keyboard/joystick controllers; you provide the core wrapper.
- **Framework space vs core space**: the M2M/ tree (never edit) vs the
  CORE/ tree (yours). The boundary entities are `MEGA65_Core`
  (mega65.vhd, Appendix B) downward-facing and `main` (main.vhd,
  Appendix A) core-facing.
- **QNICE**: the 16-bit soft CPU (one word = 16 bits, word-addressed)
  embedded by the framework as a service processor; runs at 50 MHz
  (M2M/vhdl/clk_m2m.vhd:75). It executes the firmware, owns the SD card,
  OSM, config, ROM loading - everything "operating system"-like.
- **Monitor**: QNICE's built-in machine monitor/debugger
  (M2M/QNICE/monitor/), reachable over serial as the "debug console"
  (4.1.6). Not to be confused with the Shell.
- **Firmware**: the QNICE program assembled from CORE/m2m-rom/m2m-rom.asm
  (which includes the framework's Shell sources from M2M/rom/) into
  m2m-rom.rom, synthesized into the bitstream as the QNICE ROM.
- **Shell**: the framework-provided standard firmware behavior
  (M2M/rom/shell.asm and friends): startup, welcome/help screens, file
  browser, mounting, options menu, fatal error handling.
- **OSM** ("On-Screen-Menu", also called OSD in MiSTer language): the
  Help-key overlay menu rendered by the framework; its structure is
  declared in config.vhd, its state arrives as the 256-bit
  `osm_control` vector (Appendix B).
- **vdrives** ("virtual drives"): the M2M subsystem
  (M2M/vhdl/vdrives.vhd + M2M/rom/vdrives.asm) that lets the Shell mount
  disk image files from SD card and present them to the core as
  MiSTer-compatible block devices (sd_rd/sd_wr/sd_buff handshake).
- **CRTROM**: the Shell's generalized cartridge/ROM loading mechanism;
  "manual" CRTROMs are user-browsable (C64 .CRT/.PRG), "auto" CRTROMs
  load at startup (C64 JiffyDOS, Amiga Kickstart) - declared in
  globals.vhd `C_CRTROMS_MAN/AUTO`, implemented in
  M2M/rom/crts-and-roms.asm.
- **Democore**: the placeholder core in the template (paddle ball game);
  proves the framework synthesizes and runs before you insert the real
  core.
- **HyperRAM**: the MEGA65's 8 MB external RAM; the framework arbitrates
  it between ascal's HDMI framebuffer and your core's `hr_core_*`
  Avalon-MM port (4.5.2).
- **CDC** (clock domain crossing): in M2M practice, the framework does
  the heavy lifting (`main_*`, `qnice_*` prefixed copies of signals are
  delivered already-synchronized); inside your port you use the M2M
  helpers (cdc_stable/cdc_pulse/cdc_slow, XPM macros) and constrain the
  rest in CORE.xdc.
- **CSR**: QNICE's control & status register (M2M$CSR) through which the
  firmware pulses resets, pauses the core, controls keyboard/joystick
  routing etc.

MiSTer terms (what you migrate *from*):

- **emu module**: the top-level SystemVerilog module of a MiSTer core
  (in the Amiga case: Minimig.sv); its port list is the HPS/framework
  contract on MiSTer. Your main.vhd + mega65.vhd replace it - it becomes
  your "porting oracle", not compiled code.
- **HPS / hps_io**: MiSTer's ARM CPU (Hard Processor System) and the
  module (`hps_io`, e.g. Minimig.sv:71) through which it injects config,
  files, keyboard, RTC into the core. M2M's QNICE+Shell substitute for
  it.
- **CONF_STR**: the configuration string (e.g. Minimig.sv:21) that
  declares a MiSTer core's OSD menu; its options map to your config.vhd
  menu and `C_MENU_*` bits.
- **ioctl**: MiSTer's file-download bus (ioctl_download/index/wr/addr/
  dout) used by the HPS to stream ROMs/images into the core; M2M
  equivalents are the CRTROM device windows and vdrives.
- **sys folder**: MiSTer's framework directory (sys/*.sv) shipped inside
  every core repo - scaler, hps_io, video_mixer etc. Parts of it (e.g.
  video_mixer, scandoubler) exist, adapted, inside
  M2M/vhdl/controllers/MiSTer/.
- **ascal**: Temlib's "Avalon scaler" (M2M/vhdl/av_pipeline/ascal.vhd) -
  polyphase-filtering framebuffer scaler used by both MiSTer and M2M for
  HDMI output; locks onto the core's analog timing (see 4.1.5).
- **scandoubler**: line-doubling component turning ~15 kHz retro video
  into ~31 kHz VGA-compatible video on the analog path.
- **CE (clock enable)**: MiSTer's idiom for running slow logic on a fast
  clock - a 1-clock-wide pulse train. M2M adopts it; `video_ce`,
  `ce_pix` etc. (see 4.1.4). Never gate clocks; gate enables.

Amiga terms used in this guide (Amiga port):

- **Minimig**: Dennis van Weeren's FPGA re-implementation of the Amiga
  OCS chipset, the basis of MiSTer's Amiga core
  (CORE/Minimig_MiSTerMEGA65/rtl/minimig.v).
- **Kickstart**: the Amiga's OS ROM (256 KB for 1.3); not
  redistributable, hence loaded from SD card at every start as a
  mandatory auto CRTROM.
- **chip RAM / slow RAM**: Amiga memory classes (chipset-accessible vs
  CPU-only "ranger" RAM); in this port both are BRAM lanes behind the
  SRAM-style bus (4.4.2).
- **OCS**: Original Chip Set (Agnus/Denise/Paula) - the A500 chipset
  generation this port targets.

## 4.8 Appendix E - sources and further reading

### 4.8.1 What this guide supersedes

This guide replaces the porting-track chapters of the M2M wiki
(MiSTer2MEGA65.wiki, on GitHub at
github.com/sy2002/MiSTer2MEGA65/wiki). For porting purposes you should no
longer need:

- `2.-First-Steps.md` (covered by Part I)
- `4.-Understand-the-MiSTer-core.md` (covered by Part I/II)
- `6.-Basic-wiring.md` (covered by Part II and Appendices A/B)
- `7.-Get-the-core-to-synthesize.md` (covered by Part III and 4.2)
- `Debugging.md`, `Fatal-Errors.md` (both subsumed and extended by 4.1
  and 4.3 - the wiki versions are explicitly marked incomplete)
- `Video-pipeline-and-output.md`, `Clock-Domain-Crossing-(CDC).md`
  (both @TODO stubs in the wiki; the verified facts live in Part III and
  4.1.5)
- `Caution-and-loose-ends.md` (its actionable items are folded into
  4.1.2 and 4.6.1)

This guide deliberately does NOT supersede:

- `XYZ.-How-to-release-your-core-to-the-MEGA65-community.md` - the
  release process (versioning, .cor flashing, community publication) is
  out of scope here.
- Framework-internal development documentation: `Architecture.md`,
  `QNICE.md`, `Shell-memory-layout.md`, `m2m-rom.asm.md`,
  `On-Screen-Menu.md`, `Virtual-Drives.md`,
  `File--and-Directory-Browser.md` - consult these when you go beyond
  the Shell's standard behavior and write substantial custom firmware.
- `HDMI-back-powering-problem.md` - still the canonical description of
  the R3/R3A hardware issue summarized in 4.1.1 (it links Dan's MEGA65
  Welcome Guide hardware-issues page for tested HDMI switches).
- `3.-"Hello-World"-Tutorial.md` - a gentler on-ramp if you have never
  built the unmodified template.

### 4.8.2 MiSTer-side references

- The MiSTer developer wiki: github.com/MiSTer-devel/Wiki_MiSTer/wiki -
  core structure, the HPS interface, video guidelines. Read it to
  understand what the upstream core *expects*; this guide tells you what
  to do about it.
- `Main_MiSTer` (github.com/MiSTer-devel/Main_MiSTer), especially
  `user_io.cpp` and `file_io.cpp`: the authoritative definition of the
  hps_io protocol, CONF_STR options, RTC format (cited by C64
  main.vhd:241 for `rtc_i`), and ioctl semantics. When the meaning of an
  emu-module port is unclear, the HPS source is the truth.
- `Template_MiSTer` (github.com/MiSTer-devel/Template_MiSTer): the
  upstream skeleton; comparing your MiSTer core against it separates
  core logic from MiSTer boilerplate.
- Your core's upstream repo and its git history (for the Amiga:
  github.com/MiSTer-devel/Minimig-AGA_MiSTer) - port fixes upstream
  applies after your fork are candidates for cherry-picking.

### 4.8.3 The reference ports as living documentation

- **C64MEGA65** (github.com/MJoergen/C64MEGA65): the most complete M2M port and the
  source of most patterns in this guide. Its `CORE/C64_MiSTerMEGA65`
  submodule's develop-branch history documents, commit by commit, how a
  Quartus-targeted MiSTer core was adapted to Vivado - read it before
  inventing your own fix for a Verilog construct Vivado rejects.
- **This Amiga port** (AExp): a second, smaller specimen, valuable
  precisely because it diverges where the C64 does not (no HPS-style
  config strobe -> amiga_config.vhd FSM; BRAM at 99.6%; SRAM-bus memory
  architecture). Its git log records every porting fix with rationale,
  and doc/synthesis-handoff.md preserves the timing-closure war story
  summarized in 4.2.
- The M2M template repo (github.com/sy2002/MiSTer2MEGA65, tag V2.0.1): the pristine
  starting point; diff your port against it to see everything you have
  touched.

### 4.8.4 Xilinx documentation worth actually reading

- **UG901** (Vivado Synthesis Guide): the "HDL Coding Techniques"
  chapter - RAM/ROM inference rules, `ram_style`/`rom_style`
  attributes, why your dual-clock RAM did or did not become a RAMB36.
  Directly relevant to 4.2.3's BRAM hunting.
- **UG903** (Using Constraints): the chapters on defining clocks
  (`create_clock`, `create_generated_clock`) and on timing exceptions
  (`set_false_path`, `set_max_delay -datapath_only`, multicycle paths) -
  the entire vocabulary of CORE.xdc and of M2M's CDC constraints.
- **UG949** (UltraFast Design Methodology): the timing closure
  methodology and CDC sections; its checklist mindset is what 4.2.4
  compresses for the porting case.
- **UG908** (Programming and Debugging): ILA usage details behind 4.3,
  including trigger/capture setup; plus Xilinx answer record AR 63292
  (JTAG frequency vs ILA, the 1/3 rule).

### 4.8.5 Closing rule of thumb

**RULE:** When this guide, the wiki, and the source code disagree, the
source code of M2M V2.0.1 and the C64MEGA65 reference port win - and the
fastest way to re-establish truth is a grep in those two trees, exactly
as every file:line citation in this document was produced.

---
