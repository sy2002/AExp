# AExp — Amiga 500 for MEGA65

Port of the MiSTer Minimig-AGA core to the MEGA65, scoped to an Amiga 500
OCS, built on the MiSTer2MEGA65 (M2M) framework V2.0.1.

**Status: VERSION 1 IS RELEASED (tag `V1` = commit `46ef60c`, 2026-07-23;
`VERSIONS.md` dates the release 2026-07-26).** Read the
"Released and working" box below before assuming anything in this file is
still pending - much of the prose here was written while a feature was in
flight and was never re-worded after it shipped. Development continues on
Version 2 (audio improvements, Hardware Floppy, more drives).

### Released and working - do not re-litigate these

- **ADF floppy df0:, READ AND WRITE** - shipped in Version 1, in daily use.
- Video (HDMI + analog, interlace flicker fixer, screen adjustment),
  keyboard (both modes), mouse/joystick, battery RTC, Slow RAM toggle.
- See `VERSIONS.md` for the authoritative Version 1 feature list and
  `doc/inofficial.md` for the alpha/beta history.
- **The AExp release tag is `V1`** (commit `46ef60c`), and the alphas/betas
  are `WIP-V1-*` / `WIP-V2-*`. There is no `V1.0.0` tag in this project.
  Version numbers like "V2.0.1" in this file refer to the **MiSTer2MEGA65
  framework**, never to an AExp release - do not read a framework version
  as a core release. (This repo was forked from the M2M template, so M2M's
  own tags `V0.9.0`, `V0.9.1`, `V1.0.0`, `V2.0.0`, `V2.0.1`,
  `Vivado-2019.2` used to be present locally; they were removed on
  2026-08-02 and `remote.upstream.tagOpt=--no-tags` keeps them from coming
  back. GitHub `origin` never had them. If you ever see them again,
  someone fetched upstream tags - they are framework releases.)

**Work in progress (Version 2):**

- `WIP-V2-A1` — audio filters (A500 + LED), Stereo Mix, master volume.
- `WIP-V2-A2` — Hardware Floppy read: works "OK-ish", real disks mount and
  browse, but old/marginal media still produce errors.
- **`WIP-V2-A3` — MULTIPLE SIMULATED DRIVES. The HDL, the menu and the
  framework were R3-built (`5f2869d`: BRAM 364/365, WNS +0.120 ns) and
  HARDWARE-VERIFIED on 2026-08-03 (boot from df0, Workbench Tools in df1,
  a program reading both drives, the Hardware Floppy, and live drive-
  configuration switching all work). The per-drive firmware write-back
  followed on top and is statically verified but NOT yet synthesized or
  hardware-tested.** Three Amiga units `df0`/`df1`/`df2`, each either a
  read/write ADF disk image or the Hardware Floppy (at most one). The
  drive index IS the Amiga unit: per-drive twin lines in the main menu (a
  mount line and a hardware-status TEXT line) whose visibility comes from
  the backported M2M menu-dependency feature, a `Drive Settings` submenu
  with a `Drives 1/2/3` radio plus one mode radio per drive, three
  `adf_mount_wrapper` instances with their own guarded HyperRAM pools
  behind a 4-way `avm_arbit_general`, and a unit-tagged
  `adf_track_engine` whose write drain aborts the moment Paula selects a
  different unit. **All three drives are writable**: the eight write-back
  variables are arrays indexed by the drive, each drive owns its own
  FAT32 handle snapshot (`ADF_FDH0/1/2`), `FLUSH_ADF_STEP` takes a drive
  index, and `HANDLE_CORE_IO` runs per-drive SD guards, per-drive mount
  tracking and ONE round-robin flush slice per poll, so three armed
  drives cost the main loop what one used to. Three rules keep it safe
  and are load-bearing: a drive may only ever be flushed through ITS OWN
  handle; the same image file may not be mounted into two drives at once
  (`ADF_DUP_CHECK` rejects the second mount, because each drive holds its
  own HyperRAM copy and the later flush would overwrite the earlier one);
  and no handle may be left FAT32-DIRTY across a return to the main loop,
  because the machine has exactly ONE sector buffer whose owner the
  device handle tracks by ADDRESS, and the file browser steals it without
  flushing.
  **The authoritative working document is
  `.research/HANDOVER-multi-drive.md`** - read it before touching the
  floppy stack; it carries the design rationale, what is already in the
  tree, the defect classes to avoid (above all the untagged write drain,
  which would write one drive into another drive's image), the ordered
  remaining work and the verification recipes.
  Note that `CORE_VERSION` drives `CFG_FILE`, so the OSM settings file on
  the SD card becomes `/amiga/aexp-WIP-V2-A3.cfg` - regenerate it with
  `M2M/tools/make_config.sh` (see hard rule 10; `OPTM_SIZE` is now 146).
  The `doc/inofficial.md` row for A3 is added at packaging time, because
  `make_release.py check_inofficial_md` requires a real commit hash.
- **`WIP-V2-A4` — HARDWARE FLOPPY MARGIN INSTRUMENTATION (diag map v7).
  Field testing falsified the old-media verdicts (2026-08-07): a
  tester's original disk, verified on a real Amiga before AND after,
  read-errors in our core - the front-end decode margin is the suspect,
  and the A2-era dumps had no freshness marker (seven field "dumps"
  turned out to be two observations).** A4 adds, all in the 50 MHz
  domain with zero firmware/menu/BRAM impact: millisecond uptime + dump
  nonce (dumps can never silently duplicate again), step counter +
  /TRK0-referenced cylinder tracker, per-class SIGNED-error margin
  histograms of the adaptive quantiser (serve-gated; optional
  armed-sector window spanning exactly the approach to a chosen
  sector), minimum-margin capture with est/length/class context,
  estimate-excursion min/max, and a per-sector miss profile over
  qualified read revolutions ("always sector 4 or roving?" - the
  field signature is a deterministic sector-4 header miss on track 81
  with zero LOL/fmt_bad). Device decodes addr[6:0] now; dump =
  `M 7000 705F`; version reg 0x01 = 0x0007. Statically verified
  (nvc clean, all three existing TBs pass unchanged, new
  `tb_fdd_margin` checked against an independent integer model - which
  is how the "gaps stage counts intervals exclusive of the edge cycle"
  fact was found), NOT yet synthesized. The working doc is the Part-4
  section of `.research/HANDOVER-hardware-floppy-round2.md` (decoded
  field dumps, test.adf flux analysis, build + tester recipe incl. the
  German dump instructions, and the phase-3/4 separator plan). The SD
  settings file just needs a rename/copy to `/amiga/aexp-WIP-V2-A4.cfg`
  (`OPTM_SIZE` unchanged at 146).

**ADF floppy milestone history (2026-07-03).** Read-only ADF
support verified on real R3 hardware: Workbench 1.3.2 boots to the
desktop, demoscene trackloaders run (State of the Art, Batman, TBL Eon).
Mount via OSM " ADF:" → Shell streams to HyperRAM (QNICE device 0x0103,
`adf_mount_wrapper.vhd`) → `adf_track_engine.vhd` serves Paula over the
IO_FPGA host channel with bit-exact minimig_fdd.cpp MFM encoding. Design
spec: `.research/INTEGRATION-SPEC-floppy-adf.md` (supersedes the vdrives
advice). Milestone 1
(Kickstart hand, 2026-06-10/11) preceded it. Timing closed (run 3: all
AExp-owned groups ≥ +0.24 ns; global WNS +0.017 ns sits on the framework
HyperRAM PHY path). **Interlace weave deinterlacing shipped 2026-07-04**
(minimig `field1` → `video_fl` chain → ascal `i_fl`, `INTER => true`;
verified on R3 hardware — Batman Rises' laced intro is stable; commit
29c1aa2, WNS +0.108 ns). **VGA analog modes +
OSM restructure implemented 2026-07-04** (VGA: Standard / 15 kHz HS+VS /
15 kHz CSYNC radio, C64MEGA65-style decode + retro15kHz OSM-CE in
main.vhd; filter submenu now directly under the HDMI resolution submenu;
Audio-improvements item removed, `qnice_audio_filter_o` tied '0';
OPTM_SIZE 35→44) — synthesized (WNS +0.165 ns, BRAM unchanged) and
verified on R3 hardware 2026-07-04. Firmware OSM
constants are now autogenerated like in C64MEGA65 (`make_rom.sh` →
`osm_const.asm`; refactor proven ROM-byte-identical); the settings file
is generated by `make_release.py` at packaging — the tracked `aexpcfg`
master was removed. **Screen adjustment (issue #5): HDMI crop is
hardware-verified (2026-07-09, both outputs of the old increment). The old
"VGA centering" was an RCA-confirmed false positive — the soft blank only
crops, it never pans. Replaced 2026-07-13 (A9) by a TRUE analog
positioner — implemented + sim-proven (5-scenario nvc TB), NOT yet
synthesized/hardware-tested.** New generic
`M2M/vhdl/av_pipeline/analog_positioner.vhd` (M2M-UPSTREAM screen-center, in
all four .xpr): post-OSM, pre-CSYNC edge rescheduler that shifts HS/VS phase
vs. final RGB (delay = predicted period − pan; two-back VS predictor keeps
interlace half-line phase + parity; width-exact per-pulse delays; seamless
engage/bypass; porch-measured H clamps from post-crop DE + structural
line/8, V ±64 lines; pan=0 = combinational bypass → other cores
bit-identical). Units mode-normalized via `doubled_i` ← scandoubler: pan_x =
1 hires px, pan_y = 1 line in ALL three VGA modes. Data path: v4
`aexp_screen.cfg` (84 B, per-mode rows [4 HDMI][4 overscan][2 pan]; firmware
still accepts v3, pan=0) → `LOAD_SCREEN_OFFSETS`/`DETECT_SCREEN_MODE` → CFD
gp_reg words 8-9 → `i_qnice2video` CDC (142→166). The soft blank stays as
honest analog OVERSCAN (crop/reveal borders) and was hardened: reset +
geometry-acquisition gate, clamped edge targets (no more
permanent-blank/12-bit wrap). Tool v4 (grouped UI, --pan-x/-y, --reset,
--copy-from, direction echo, v3 migration, `test_aexp_screen_cfg.py` = 25
tests); presets regenerated v4; `doc/screen_adjust.md` rewritten around
position/overscan/no-true-scale. Interactive OSD adjust still pending. **HDMI flicker-free (issue #12)
— Increment 1 implemented 2026-07-09, statically verified (nvc analyze +
elaborate against the real `clk`/`cdc_stable`; adversarial swarm) but NOT
yet synthesized/hardware-tested.** CORE-only (clk.vhd + mega65.vhd +
config.vhd + CORE.xdc; zero M2M/.xpr/firmware edits). A second MMCM
`i_clk_fast` = 28.437500 MHz (313-line = 50.030 Hz, above 50) + a
glitch-free `BUFGMUX_CTRL` are dithered native↔fast by a 2-state FSM in
the `hr_clk` domain driven by the already-plumbed ascal over/underflow
loop (`hr_high_i`/`hr_low_i`, mega65.vhd:97-98) → the core's time-average
frame rate is exactly 50.000 Hz; interlace already averages 50.000 and
settles on native (zero dither). **Direction inverted vs C64MEGA65:
native 49.92 is BELOW 50 → the twin is FASTER.** HDL-read OSM toggle
"HDMI: Flicker-free" (top-level between the HDMI Filter and VGA submenus,
single-select default ON; `C_MENU_HDMI_FF`=25, OPTM_SIZE 41→42, OPTM_DY
12→13, VGA `C_MENU_*`/lines +1; ships in the unreleased `WIP-V1-A6`, no
version bump). CORE.xdc times
the fast leg (`set_case_analysis 1` on `hr_core_speed_reg[0]/Q`,
`create_generated_clock` on `i_clk_fast/CLKOUT0`) — the leaf names
`i_clk_fast`/`hr_core_speed` are load-bearing (a "no pins matched" warning
silently no-ops STA). Recommend FF OFF for VGA/15 kHz (H-sync frequency
step). Real synthesis risk = the R6 global HyperRAM-PHY WNS (+0.058 ns
baseline), NOT core timing (~+7 ns). Increment 2 (3-clock, adds
`i_clk_slow`=28.3125 for the rare >50 content) deferred. Spec:
`.research/INTEGRATION-SPEC-hdmi-flicker-free.md`. Everything below is the
distilled project knowledge —
the deep material lives in `doc/` (see "Key documents").

## The emulated machine

- Amiga 500, **OCS only** (no ECS/AGA), **PAL only**, 68000 (fx68k,
  cycle-exact)
- 512 KB Chip RAM ($000000–$07FFFF) + 512 KB Slow RAM ($C00000–$C7FFFF,
  the "trapdoor" expansion) + 256 KB Kickstart 1.3 — **all in FPGA BRAM**,
  no SDRAM involved (R3 has none; R4+ SDRAM is unused). The Slow RAM is
  OSM-switchable: "Slow RAM (A501)" toggle, default on (issue #20, for
  programs like Rogue that break with expansion RAM; **implemented
  2026-07-16, NOT yet synthesized/HW-tested**). The toggle drives
  `slow_ram_i` → `amiga_config.vhd`, which sets userio 0xF5 payload bit 2
  (SS[0]); the firmware auto-soft-resets on toggle (`RESET_CORE` in
  `OSM_SEL_POST`) so the replayed config takes effect at once. With slow
  RAM off, minimig decodes $C00000+ as the custom-register mirror
  (authentic chip-only A500); the RTC at $DC0000 stays mapped (deliberate,
  matches MiSTer). The slow BRAM stays instantiated either way (no BRAM
  delta).
- Kickstart is loaded from SD card at boot: `/amiga/kick.rom` (raw 256 KB
  dump, big-endian, no byte swapping), **mandatory** — missing file =
  fatal error screen, core never starts (`C_CRTROMTYPE_MANDATORY` in
  `CORE/vhdl/globals.vhd`)
- One core clock: **28.375 MHz** (PAL ideal 28.37516, −5.6 ppm), MMCM in
  `CORE/vhdl/clk.vhd` (100 MHz × 56.750 / 5 / 40). No 113.5 MHz clock —
  everything SDRAM/turbo/AGA that needed it is out of scope.
- Floppy: up to THREE drive units `df0`/`df1`/`df2` (WIP-V2-A3; Version 1
  shipped one). Each unit is either a simulated ADF drive (read/write ADF
  mount from the OSM, image staged in its own HyperRAM pool
  `C_HMAP_ADF_DF0/1/2` at words 0x200000/0x280000/0x300000) or the
  Hardware Floppy = the MEGA65's internal mechanism reading real Amiga DD
  disks (read-only milestone, at most one unit). The OSM "Drive Settings"
  submenu holds a `Drives 1/2/3` radio and one Disk Image / Hardware
  Floppy / Off radio per drive; the main menu shows one line per drive,
  swapped between the mount item and a hardware-status text by the M2M
  menu-dependency layer. **ADF read AND write are
  RELEASED and work: they shipped in Version 1 (tag `V1`, 2026-07-23) and
  have been in daily use since. Do not treat the ADF drive as unproven** -
  `VERSIONS.md` lists "One floppy drive (df0:): read/write standard 880 KB
  *.adf disk images" as a Version 1 feature. What was never formally
  recorded is the write test MATRIX of the write spec §8 (rename persists
  across power cycle, format, write+verify, swap-while-dirty, wprot
  regression); the feature itself is fine.
  The write path is a
  hardware MFM write decoder (bit-exact minimig_fdd.cpp
  FindSync/GetHeader/GetData) commits verified sectors to HyperRAM;
  per-track dirty bitmap + vdrives-style anti-thrash (2 s, config.vhd
  word 13) in `adf_mount_wrapper` window 0xFFFE ("WBC"); firmware
  flushes dirty tracks to the SD file in the background via the new
  `HANDLE_CORE_IO` hook (512 B + fflush per slice, one FDH snapshot PER
  DRIVE — the Shell re-opens `HNDL_RM_FILES[n]` before `PREP_LOAD_IMAGE`!);
  drive LED yellow while any drive is dirty. Design + review findings:
  `.research/INTEGRATION-SPEC-floppy-adf-write.md` (the arm-state
  invariant in §5a is load-bearing and now has to hold PER DRIVE). A unit
  is announced write-protected until the firmware arms its WR_EN, on SD
  change, and while remounting.
  No IDE. Keyboard + joysticks + mouse work.
- Audio (**implemented + sim-verified 2026-07-24, NOT yet synthesized/
  HW-tested; ships in the unreleased WIP-V2-A1, no version bump**): Paula →
  `CORE/vhdl/audio_filters.vhd` (bit-faithful Minimig.sv port reusing M2M's
  `iir_filter.v`: A500 fixed 4400 Hz low-pass = OSM "A500 Filter", CIA-A-PA1
  LED filter 3000+3400 Hz following `pwr_led` live = OSM "LED Filter", both
  single-select default ON; MiSTer `aud_mix` crossfeed = OSM "Stereo: %s"
  radio Full/Wide/Narrow/Mono, default Full) → master volume (Q15,
  monitor-knob = last) → HDMI + analog alike. All HDL-read OSM bits
  (`C_MENU_STEREO` 96..99, `C_MENU_A500FILT` 102, `C_MENU_LEDFILT` 103 since
  the Configure Drives block shifted lines ≥3 by +10), zero
  firmware logic, zero BRAM; both filters have intrinsic DC gain (+0.53 /
  +1.11 dB, MiSTer-faithful incl. the IIR's 16-bit clamp). Everything-off =
  bit-transparent raw Paula (the V1 sound). OPTM_SIZE 103→114, OPTM_DY
  28→31, MENU_HEAP 1536→1664. The generic M2M "audio improvements" filter
  stays tied off. End-user doc: `doc/audio.md`; details:
  `doc/developers/audio.md`; TBs in `.research/` (tb_iir_amiga.v +
  tb_audio_filters.vhd, all green).
- **Hardware Floppy (read milestone) — implemented 2026-07-26; first R3
  build closed timing after the CDC fix, OSM reworked after hardware round
  1; read path partially proven on hardware (real flux decoded, boot
  attempt started), ships in WIP-V2-A2.** The MEGA65's internal 3.5" drive
  as a real Amiga unit: OSM "Configure Drives" submenu with four combos
  (`C_MENU_HWFC_*` 7..10) A: df0:ADF+df1:HW (default) / B: df0:HW+df1:ADF
  / C: df0:ADF only / D: df0:HW only (no ADF drive - the engine gates its
  ADF service, announcements and commits with `adf_en_i`); a combo change
  cold-boots only the Amiga via `amiga_cold_boot`, drive count via userio
  0xF7 bits [3:2] (two drives only in A/B). Research:
  `.research/RESEARCH-physical-floppy-drive.md`. Minimig has NO flux layer,
  so three surfaces: (1) 50 MHz read front-end `CORE/vhdl/physical_fdd/`
  (C64MEGA65 physical-1581 codec: input conditioner + index qualification,
  runt-filtered gap stage, ADAPTIVE quantiser — constants hardware-proven at
  exactly 50 MHz on this mechanism — plus the new gap→raw-channel-bit
  rebuild with drought filler and a bit-level DSKSYNC aligner/deserializer
  into a Gray dual-clock word FIFO; BOTH FIFO resets derive from the QNICE
  reset, load-bearing); (2) `adf_track_engine` per-unit backend mux (status
  sel bits dispatch ADF vs physical; physical words stream at real disk
  pace; raw dsksync exported to the aligner — no Copy Lock substitution;
  physical writes drain-DISCARD, `drain_commit` gates the MFM decoder so
  they can never commit into the ADF image; per-unit 0x1nnn announce,
  physical always announced write-protected); (3) CIA-line muxes inside
  `paula_floppy.v` (per-unit substitution into the open-collector status
  AND-terms, real /TRK0 for recalibration, real INDEX edge into CIA-B FLAG,
  `motor_on` export; `phys_mask=0` = bit-identical) + connector driving in
  mega65.vhd (`f_side1 <= side` straight wire — HARDWARE-CONFIRMED correct
  2026-07-26 by the diag sector-header capture, the C64 side-select lesson
  laid to rest). /RDY is synthesized (motor off
  = ready → drive-ID 0xFFFFFFFF for df1:; motor on = 505 ms + 2 qualified
  index edges + index freshness = eject detection). Diag device 0x0104
  (`physical_fdd_diag`, QNICE domain, CDC-free — the bring-up instrument).
  The A2 menu had a static two-line structure whose LABELS a firmware
  routine (`HWF_LABEL_SYNC`) rewrote in the menu heap to follow the
  selected combo. **That routine is GONE in WIP-V2-A3**: the M2M
  menu-dependency layer swaps whole lines now, which is what the twin
  pairs are. A positional REORDER of the lines is
  impossible within the framework invariants and was HARDWARE-REFUTED on
  R3 (fatal 0x001F on submenu exit): submenu blocks are contiguity-defined
  (head..closer) and CFM bit i is positionally bound to line i.
  OPTM_SIZE 114→124, OPTM_DY 31→33,
  MENU_HEAP 1664→1920. f_wgate/f_wdata stay tied '1' (write = a later
  milestone; DD media only, PC HD mechanisms cannot do Amiga HD). TB
  `.research/tb_physical_fdd_top.vhd`: 5 closed-loop scenarios (nominal /
  ±3% speed / jitter / runts / drought re-lock) ALL PASS; firmware
  qasm-clean; nvc + iverilog clean. Dev SD card: regenerate the settings
  file (`M2M/tools/make_config.sh aexp-WIP-V2-A2.cfg auto`). First R3
  synthesis (2026-07-26) FAILED timing exactly like the C64 precedent: WNS
  -6.331, all 47 failing endpoints = the new RAW qnice<->main crossings
  (word-FIFO Gray syncs + LUTRAM read into the engine's io_din register,
  control/dsksync 2-FF metas) - the first unconstrained fabric paths
  between these MMCM-unrelated clocks. FIXED in `CORE/CORE.xdc`:
  clock-pair `set_max_delay -datapath_only 20.000` qnice<->main in BOTH
  directions (deliberately NOT the C64 blanket false path: a clock-pair
  false path would override common.xdc's object-scoped cdc_stable bounds,
  while max_delay yields to them). Round 2 on R3 (2026-07-26, rebuilt
  core WNS +0.131): the flux front-end PROVEN healthy on real media (284
  sync hits = exactly 22/rev over ~13 revs, 300.5 RPM, 0 runts, 0 drops)
  yet `DF1:BAD` → suspected side inversion → sector-header CAPTURE
  (diag regs 0x11..0x1A: SIDE//TRK0-tagged 8 words after the double
  0x4489) + runtime side-invert (writable diag reg 0x1F → XOR on
  f_side1) added = map v2. **Round 3 (2026-07-26): SIDE INVERSION
  REFUTED — polarity CORRECT as wired** (capture at cylinder 0/head 0
  returned info long 0xFF000207 = track 0 sector 2, hand-verified
  bit-exact MFM incl. clock bits; keep 0x1F at 0; mega65.vhd comment
  updated). Full delivery-chain audit (engine ST_PHYS, wfifo FWFT,
  paula_floppy receiver/WORDSYNC/DMA FSM): loss-free by construction,
  everything after Paula rx shared with the WORKING ADF path — but NO
  existing counter separates "read 6400 words and rejected them" from
  "DMA never armed" (both end `DF1:BAD`). Response = **diag map v3**
  (reg 0x01 = 0x0003; R3 build closed WNS +0.182, BRAM 365): 0x1B =
  words SERVED into Paula (engine ST_PHYS_DATA count, Gray-crossed —
  the go/no-go observable; 1 track read = 6400), 0x1C =
  last-revolution sector-seen mask (0x07FF = all 11), 0x1D =
  {captures,LOL} last rev, 0x1E = bad-format-capture count. The
  DiskDoctor whole-disk sweep (v2 build) then PROVED: disk HEALTHY
  (18254 captures = 11.00 headers/rev over 1659 streamed revs, LOL
  0.60/rev = splice only), side mapping correct on BOTH heads (track
  74 @ cyl37/h0 + track 105 @ cyl52/h1, cylinder == DiskDoctor
  display → stepping 1:1), index edges 1:1 with streamed revs — yet
  hard errors on ~every track at ~10 fast retries × 2 surfaces per
  cylinder. Open findings: (a) /RDY WART — the PC mechanism gates
  INDEX on /SEL, so idx_fresh starves across deselect gaps and the
  synthesized /RDY flickers at operation STARTS (fix: drop the
  idx_fresh term from steady-state media_ready, keep the spin-up
  gate, eject via the proven /DSKCHG); (b) co-selection hole (Paula
  sel = priority encoder: a df0: change-poll click during a df1: read
  makes the engine abort/discard ~1 ms or dispatch the ADF service
  into the phys DMA — refuted as root cause by round-1 combo D, MUST
  still be fixed). THE FORK = v3 reg 0x1B served delta over one read
  workload: ≈N×6400 → served-and-rejected → next instrument = a
  Paula-side capture tap (first fifo_wr words after trackrdok rise);
  ≈0 → never armed → the ready-model fix is the prime candidate.
  Round 4 DECIDED the fork: **served-and-rejected** (0x1B ticking at the
  full word rate live, media_ready/idx_fresh = 1 during reads, scoreboard
  0x07FF/11/2 = complete revolutions into Paula — trackdisk rejects
  anyway). The engine→Paula-receiver segment was then exonerated in sim
  (`.research/tb_engine_paula.vhd`: REAL engine vs a line-by-line VHDL
  model of paula_floppy.v's receiver at real-flux cadence — 2 attempts ×
  6400 stored words, all ring-exact) and the same TB caught the
  co-selection hole red-handed (foreign-sel pulse mid-read → 6242 shifted
  words = poisoned buffer). **v4 = diag map 0x0004 (implemented + TB/nvc
  verified 2026-07-27, NOT synthesized):** (a) store-signature pair — XOR
  over the first 1024 post-sync words per attempt, engine-side
  (`phys_sig_*`) AND inside the real paula_floppy.v (`fdd_dsig`, threaded
  paula.v → minimig.v → minimig_m65.v → main.vhd), diag regs 0x20..0x23
  (decode widened to addr[5:0]) — equal-on-hardware exonerates the real
  channel, different = corruption caught; (b) co-selection FIX
  (`phys_stream` session latch: no abort/discard/ADF-dispatch on
  transient foreign sel while trackrd=1; red→green in the TB); (c) /RDY
  HOLD fix (media_ready latches once qualified, holds while motor on —
  INDEX is /SEL-gated so freshness starves across deselect gaps; eject =
  /DSKCHG). Round 5 (v4 build) showed the signatures differing — round 6
  (v5 instruments: checkpoint sigs 0x24..0x27, 8-word Paula tap
  0x28..0x2F, WORDSYNC bit 0x23.8) revealed WHY and found the ROOT
  CAUSE: **ADKCON WORDSYNC is 0 in this system** (measured live; the sig
  windows were differently anchored — the "corruption" verdict is
  retracted, the channel is clean), Paula therefore stores from the VERY
  FIRST served word, and after the deselect-induced chain reset between
  attempts the engine served up to ~570 free-running PRE-LOCK words (the
  taps showed them: legal MFM at wrong bit phase, `A4A5 12A9...`) at the
  buffer start — which trackdisk rejects (the WORKING ADF path's tap
  shows its first aligned 0x4489 at offset 2 = the tolerance
  calibration). Explains the ~100% failure incl. round 1's boot. **v6 =
  THE FIX (implemented + red/green verified 2026-07-27, NOT synthesized;
  version reg = 0x0006, map unchanged): serve-from-sync gate** in
  `adf_track_engine` (`phys_hunt`: discard FIFO words until head equals
  the live DSKSYNC, serve from the sync word; correct under either
  wordsync setting; engine sig window now sync-inclusive = Paula's exact
  window → 0x20 and 0x22 must read EQUAL on an intact channel). TB
  reworked to measured reality (wordsync=0 model, hardware-taken junk
  prefix per selection, strict sync-at-start check, phys_sel vs sel_stat
  separation): old engine RED with the exact hardware junk signature,
  fixed engine ALL PASS. Also: the two m2m-rom.asm genitive apostrophes
  reworded (0 cpp warnings, 26261 ROM lines). **Round 7 (2026-07-27, v6
  build): READ MILESTONE REACHED — the real disk MOUNTS with its volume
  name and browses; signature pairs EQUAL on every dump (channel proven
  word-exact end to end); one-time validate popup (authentic old-media
  retry or the dirty-bitmap-needs-write case = correct wprot behavior)
  and one Guru 00000025 while loading (suspect: 1994 disk content, not
  the core) under observation. Round-8 checklist (eject/re-insert,
  browse+Type, combo-D boot, wprot regression, DiskDoctor re-run) +
  commit decision + R4/R5/R6 + docs pass pending.** Full playbook:
  `.research/HANDOVER-hardware-floppy-round2.md`.

## Repository map

- `M2M/` — the framework. **NEVER modify**, with NINE sanctioned
  exceptions (all testbeds for a later M2M upstream merge, tagged
  `M2M-UPSTREAM <name>` in-code, greppable): (1) `interlace` — new
  `video_fl_i` input through framework → av_pipeline → digital_pipeline
  → ascal `i_fl`, `INTER => true`; new inputs default to '0'
  (progressive cores unaffected). (2) `core-io-hook` — `HANDLE_CORE_IO`,
  an 8th mandatory core callback called from `HANDLE_IO` (shell.asm,
  at the `_HANDLE_IO_0` label): a per-iteration time slice in the main
  loop AND all blocking wait loops (OSM/browser/help), for background
  tasks like non-vdrives write-back caches; contract: preserve all regs,
  return fast, may change RAMROM selection. (3) `screen-center` — the
  screen-adjustment plumbing (issue #5): (a) four signed per-edge offsets
  threaded framework → av_pipeline (`i_qnice2video` CDC) → digital_pipeline
  driving ascal's INPUT crop (`iauto=0`, `himin/himax/vimin/vimax`) for HDMI
  (hardware-verified 2026-07-09); (b) four signed analog OVERSCAN soft-blank
  edges (hardened `p_vga_softblank`, feeds only the analog pipeline); (c) two
  signed analog PAN inputs (gp_reg words 8-9) into the new
  `analog_positioner.vhd`, a post-OSM/pre-CSYNC sync-phase shifter (2026-07-13,
  awaiting synthesis). All new inputs default to 0 = bit-identical for other
  cores.
  (4) `osm-hotkey` — three core-driven inputs (`osm_key_a_i`/`osm_key_b_i`
  default 67=Help, `osm_combo_i` default '0') threaded core →
  `framework.vhd` → `m2m_keyb.vhd` so the core picks which key(s) drive the
  menu-open bit (`qnice_keys` bit 7, the *ungated* scan); the defaults
  reproduce the classic Help-only behaviour and leave the firmware ROM
  byte-identical, so every existing M2M core is unchanged. Issue #8,
  2026-07-11 — implemented, awaiting synthesis; **the 4th exception still
  needs sy2002's explicit sign-off** (spec §8).
  (5) `osm-scale` — a RAM-inference override: `tdp_ram.vhd` gains a
  `RAM_STYLE_SELECT` generic (default `"auto"` = every existing caller
  unchanged) driving the block RAM's `ram_style`; `ascal.vhd` uses it to pin its
  shallow async ping-pong buffers (`i_dpram`) to `"distributed"` LUTRAM.
  Otherwise Vivado maps them to BRAM, burning 4 RAMB36s AND absorbing `avl_dr`
  into the BRAM output, invalidating the ascal-FIFO CDC max-delay endpoints
  (`CORE/CORE.xdc`) that MEGA65 cores depend on.
  (6) `raw-joyports` — `M2M/vhdl/debouncer.vhd`: the ten `work.debounce`
  instances (1 ms stable-time) replaced by plain 2-FF synchronizers, so the DB9
  direction/fire (and mouse quadrature) lines reach the core raw — authentic (a
  real Amiga has no DB9 debouncing) and mandatory for quadrature mice, whose fast
  pulse trains the 1 ms filter swallowed (frozen-then-jumping pointer). Port-flip
  + joy on/off gating kept; `CLK_FREQ`/`reset_n` now unused. sy2002-approved
  2026-07-22, to become a framework option when upstreamed.
  (7) `floppy-pins` — the four board tops route the 11 read-path floppy pins
  (f_motora/f_selecta/f_side1/f_stepdir/f_step/f_density + the 5 inputs)
  into `MEGA65_Core` for the Hardware Floppy feature (the C64MEGA65
  issue-#90 pattern: board top → core direct, `framework.vhd` untouched);
  f_motorb/f_selectb/f_wdata/f_wgate stay tied '1'. sy2002-approved
  2026-07-26.
  (8) `osm-deps` — SMART MENU DEPENDENCIES, backported from C64MEGA65 issue
  #229 (dependency format 2): a menu line can be tagged in config.vhd with
  `OPTM_DEP`/`OPTM_DEP2` so that it is only visible while one of the items
  of a "mother" group is selected. New `M2M/rom/optm_deps.asm`, plus
  `M2M$CFG_OPTM_DEPS`, `OPTM_IR_DEPS`, the third visibility pass in
  `_OPTM_STRUCT`, the live redraw and cursor normalisation in `_OPTM_RUN`,
  the `OPTM_SELECT` carry guard, the boot validator call and the five
  `ERR_F_DEP*` strings. Every line is unconditionally visible when
  config.vhd does not serve the feature probe, so other cores are
  unaffected. AExp needs it for the per-drive twin lines: this instance
  additionally allows dependent `OPTM_G_LOAD_ROM` lines, PARTIALLY VISIBLE
  radio groups and two-level chains, which is why `OPTM_DEPS_VAL` classes
  2 and 3 are weaker here than in the C64 original (reasons in its header).
  (9) `live-text` — `OPTM_LIVE_TEXT` (+ its `_OPTM_LT_ISEND` helper) in
  `M2M/rom/menu.asm`, backported from C64MEGA65, where it drives the live
  status field of the `8:Internal 1581` line. It replaces a fixed-width slice
  of one menu item in the writable `OPTM_IR_ITEMS` heap copy and repaints just
  those characters when that line is visible; it never triggers the fatal menu
  callback. AExp uses it for the live Hardware Floppy status in the three
  `dfN:Hardware Floppy` twin lines. **Purely ADDITIVE** — nothing else in the
  framework calls it, so every other core is byte-identical. One deliberate
  difference to the C64 original: M2M V2.0.1 has no `OPTM_FOREGROUND` flag and
  introducing one would mean touching `OPTM_RUN` and the selection-callback
  path, so the "does the menu own the screen right now" question is left to the
  caller (AExp answers it with `M2M$CSR_OSM` + its own `OSM_SUB_ACTIVE` +
  `OPTM_MENULEVEL`). Getting that wrong is cosmetic, never fatal.
  sy2002-approved 2026-08-04. When this goes upstream it should grow the
  `OPTM_FOREGROUND` flag of the C64 original, so the "does the menu own the
  screen" test lives in the framework instead of in each caller.
  All other framework fixes
  go into `CORE/CORE.xdc` (constraints) or get documented for upstreaming.
  Git remote `upstream` = sy2002/MiSTer2MEGA65 (master = V2.0.1).
- `CORE/vhdl/` — the port (all files ours):
  - `mega65.vhd` — BRAM lanes (2×256K×8 chip, 2×256K×8 slow, 2×128K×8
    kick), banked-address decode, QNICE devices 0x0100 (kick) + 0x0103
    (ADF), HyperRAM plumbing (avm_fifo CDC + 2-master arbiter →
    hr_core_*), OSM wiring
  - `main.vhd` — wraps minimig_m65 + cpu_wrapper + amiga_clk; fx68k phase
    enables, frame-locked video CE, sync inversion, interlace field
    export (`video_fl_o` ← minimig `field1`), reset mapping, host
    bus mux (amiga_config ↔ adf_track_engine) + avm_cache
  - `amiga_config.vhd` — FSM replaying MiSTer's HPS config via the userio
    protocol after every reset (0xF1=0x07 halt+reset, 0xF3=OCS,
    0xF4=68000, **0xF5=0x04** = 512K+512K, 0xF6/0xF7/0xF8/0xF9/0xF2=0,
    0xF1=0x00 release)
  - `adf_mount_wrapper.vhd` — QNICE device 0x0103: byte-window bridge
    into HyperRAM + M2M CSR (window 0xFFFF) + ADF size validator
    (160–166 tracks × 5632 bytes; "mounted"+track count → cdc_stable)
    + write-back CSR "WBC" (window 0xFFFE: WR_EN, 166-bit dirty bitmap
    W1C, anti-thrash ms countdown, dirty-event receiver)
  - `adf_track_engine.vhd` — Paula floppy host service (MiSTer HandleFDD
    in hardware): 1 ms poll + drive-status re-announce, per-sector MFM
    streaming with status-bit-8 flow control, MFM write decoder
    (drain-and-commit: verified sectors → HyperRAM via avm writes,
    dirty-track events → wrapper via two-phase cdc_stable toggle
    handshake); since WIP-V2-A2 also the Hardware Floppy backend (per-unit
    dispatch on the status sel bits, real-flux word streaming, dsksync
    export, drain-discard for physical writes); the protocol contract is
    documented in its header
  - `physical_fdd/` — the Hardware Floppy 50 MHz read front-end (pkg,
    input conditioner, runt-filtered gap stage, adaptive quantiser,
    raw-bit rebuild + DSKSYNC aligner, dual-clock word FIFO, top, QNICE
    diag device 0x0104); codec stages adapted from the C64MEGA65
    physical-1581 bring-up (hardware-proven at exactly this clock)
  - `keyboard.vhd` — MEGA65 keys → raw Amiga scancodes (kms_level toggle)
  - `clk.vhd`, `globals.vhd`, `config.vhd` (OSM menu — bit = line number,
    must match `C_MENU_*` constants in mega65.vhd; exception: the HDMI
    Filter radio, lines 19–26, is read by the firmware (`OSM_FLT_*` in
    m2m-rom.asm must mirror them), not mega65.vhd; VGA radio lines
    32/36/37)
- `CORE/m2m-rom/` — core QNICE firmware (`m2m-rom.asm`): ADF size guard
  + ADF write-back (`HANDLE_CORE_IO` + `FLUSH_ADF_STEP`: FDH snapshot,
  SD-change + SD-slot guards, per-chunk fflush, force-flush + disarm in
  `PREP_LOAD_IMAGE` — the §5a arm-state invariant of the write spec)
  + HDMI Filter dispatcher `LOAD_HDMI_FILTER` (C64MEGA65-V6 port;
  `ASCAL_USAGE=1`, includes a backported `M2M$LOAD_POLYPHASE` — delete it
  when M2M is upgraded to V2.1+; coefficient blobs in `video_filters/`).
  OSM menu constants are autogenerated: `make_rom.sh` scrapes `C_MENU_*`
  (mega65.vhd) and the core `OPTM_G_*` (config.vhd) into `osm_const.asm`
  (`AEXP_OSM_*` / `AEXP_OPTM_G_*`, gitignored) — no hardcoded menu
  indexes in the firmware. The OSM settings file (72 bytes = OPTM_SIZE;
  SD name `/amiga/aexp-<CORE_VERSION>.cfg`) is generated by
  `make_release.py` at packaging — no tracked master. `CORE_VERSION` in
  config.vhd is the single version source (welcome/help
  screens, CORENAME, CFG_FILE all derive from it; `make_release.py`
  validates it and packages releases, alpha rows live in
  `doc/inofficial.md`).
- `CORE/Minimig_MiSTerMEGA65/` — git submodule, upstream
  MiSTer-devel/Minimig-AGA_MiSTer. Branch **develop** carries all
  Xilinx/MEGA65 changes; **MiSTer** mirrors upstream; **master** is the
  released state (= `develop` at each AExp release). Every change to
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
   Do NOT add a `Co-Authored-By: Claude` trailer — Claude is credited in
   the `AUTHORS` file instead.
9. Do not delete `/tmp/claude-501` task outputs (deny rules in
   `.claude/settings.local.json`); tell workflow subagents not to run
   cleanup commands.
10. `CORE/m2m-rom/make_rom.sh` scrapes globals.vhd (`C_VDNUM`/
    `C_CRTROMS_*_NUM`), mega65.vhd (`C_MENU_*` → `AEXP_OSM_*`) and
    config.vhd (core `OPTM_G_*` → `AEXP_OPTM_G_*`) via awk into generated
    .asm files — keep all those constants single-line; the Vivado
    pre-synth hook rebuilds the firmware, so menu changes need a
    synthesis (or VM-side make_rom.sh) to reach the ROM. Changing
    `OPTM_SIZE` ⇒ `make_release.py` generates the matching settings file
    at packaging (no tracked master; manual for dev SD cards:
    `M2M/tools/make_config.sh <name> auto` from inside `M2M/tools`).
11. **Every OSM growth needs a QNICE heap rebudget.** `OPTM_SIZE` is not
    only the settings-file length: `HELP_MENU` copies the item string plus
    three `OPTM_SIZE` arrays into `MENU_HEAP_SIZE`, then uses the remainder
    as `OPTM_HEAP` for one `SCR$OSM_O_DX`-wide (`OPTM_DX + 2` frame
    characters) buffer per vdrive, submenu and manual ROM, plus one scratch
    buffer. After changing `OPTM_SIZE`,
    `OPTM_ITEMS`, `OPTM_DX`, or any of those counts, verify both
    `LOG_HEAP1`/`LOG_HEAP2` budgets (a fatal naming `MENU_HEAP_SIZE` or
    `OPTM_HEAP_SIZE` is the corresponding failed check). If
    `MENU_HEAP_SIZE` changes, normally subtract the identical delta from both
    debug and release `HEAP_SIZE` constants so the combined heap totals stay
    unchanged. Only raise a combined total after the assembled `HEAP`/stack
    addresses prove that `STACK_SIZE` still fits. Keep `MENU_HEAP_SIZE` tight:
    every extra word directly reduces
    file-browser capacity (a file entry costs three list words plus its name,
    terminator and directory flag). Round the calculated demand only to the
    next 128-word boundary, not to a large power of two. The exact demand
    formula (from `HELP_MENU` in `M2M/rom/options.asm`): 19 (menu struct) +
    `OPTM_ITEMS` string chars (`\n` = 2 chars) + 1 (terminator) + 3 ×
    `OPTM_SIZE` + 1, plus (vdrives + submenus + manual ROMs + 1) ×
    (`OPTM_DX` + 2) for `OPTM_HEAP`. WIP-V2-A3 with the 146-item menu needs
    exactly 2298 words and uses `MENU_HEAP_SIZE` 2304, headroom 6 —
    `.research/check_osm_menu.py` recomputes all of this from `config.vhd`.
    **Firmware VARIABLES count too**, even though this rule is about the menu:
    they sit below the heap, so every word added there pushes `HEAP` up and
    comes straight out of the stack. The per-drive write-back and the live
    Hardware Floppy status line added 66 variable words, so the combined total
    was lowered from the C64 figure of 30208 to **30080** to buy the margin
    back: `HEAP=0x8280` + 30080 = `0xF800` against `VAR$STACK_START 0xFEE0`
    leaves 1760 words for a `STACK_SIZE` of 1536. Recheck both live heap
    budgets and the `HEAP`/`VAR$STACK_START` symbols in `m2m-rom.lis` manually
    whenever the menu or the firmware variables grow.

## Build & verification workflow

- **No Vivado on this Mac.** It runs in the user's Parallels Ubuntu VM on
  a shared folder. Prepare everything, then ask the user to synthesize
  and return: `CORE/CORE-R3.runs/synth_1/runme.log`,
  `impl_1/*_utilization_placed.rpt`, `impl_1/*_timing_summary_routed.rpt`,
  `impl_1/*_route_status.rpt`. Per-module BRAM: ask for
  `report_utilization -hierarchical`.
- **QNICE firmware**: the Vivado pre-synth hook rebuilds it inside the
  VM on every build — the VM works directly in this (mounted) folder,
  which is why `M2M/QNICE/assembler/qasm`/`qasm2rom` are Linux ELF
  binaries. Never overwrite them, and NEVER run
  `CORE/m2m-rom/make_rom.sh` on the Mac: the `asm` wrapper deletes
  `m2m-rom.out`/`m2m-rom.rom` BEFORE assembling, then dies on the Linux
  binaries. For Mac-side sanity checks compile temporary native tools
  into a temp dir (`cc -O2 -o "$TMP"/qasm M2M/QNICE/assembler/qasm.c`,
  same for `qasm2rom`), then from `CORE/m2m-rom`: `cc -xc -E
  m2m-rom.asm | sed '/^#.*/d' > __t.asm && "$TMP"/qasm __t.asm
  m2m-rom.out && "$TMP"/qasm2rom m2m-rom.out m2m-rom.rom` (verified to
  produce a `.def`-identical ROM vs the VM build).
- **Headless QNICE menu regression**: `M2M/rom/menu_percent_test.asm` runs
  the real `OPTM_SHOW` scanner and guards the C64 `%`-at-end-of-label fix.
  The QNICE snapshot pinned here predates multi-image `-b` mode, even when
  rebuilt; use a current batch-capable QNICE emulator externally (the C64
  repository has one) without importing that emulator feature. Assemble the
  test with the native/VM assembler, then run `$QNICE_HEADLESS -b 0x8000
  M2M/QNICE/monitor/monitor.out M2M/rom/menu_percent_test.out`. Expected:
  `PASS: percentage labels preserve later %s indices`. Run this after every
  change to `M2M/rom/menu.asm` or percentage-bearing `OPTM_ITEMS` labels.
- **Local static checks before any Vivado round-trip** (installed:
  nvc 1.21, ghdl 5.1, iverilog). Two Python checkers live in `.research/`
  (untracked, like the rest of it): `check_osm_menu.py` recomputes
  `OPTM_SIZE`, the submenu balance, the `OPTM_DEP` rules, the worst-case
  visible height per menu view and the `MENU_HEAP_SIZE` demand from
  `config.vhd`, and cross-checks every `C_MENU_*` constant in `mega65.vhd`
  against the TEXT of the line it addresses - run it after ANY menu change.
  `check_firmware.py` checks the per-drive tables and arrays against
  `ADF_DRIVES` and requires every `ADDC`/`SUBC` in `m2m-rom.asm` to take its
  carry from a producer that writes the same storage class; on QNICE only
  `ADD`/`ADDC`/`SUB`/`SUBC`/`SHL`/`SHR` write Carry and `MOVE` does not, so
  inserting address arithmetic between a 32-bit `ADD` and its `ADDC` silently
  eats the carry (this exact slip once made the ADF write-back address every
  chunk past a 64 KB boundary 64 KB too low). Then analyze all CORE VHDL with
  `nvc --std=2008` in dependency order (M2M packages first: tools.vhd,
  types_pkg, video_modes_pkg, tdp_ram, 2port2clk_ram); clk.vhd/mega65.vhd
  need stub `unisim`/`xpm` vcomponents packages (recipe in memory).
  iverilog `-g2012 -t null` over the kept
  Verilog set with stubs for `dpram` and `fx68k`. Known noise to ignore:
  forward references, fx68k unpacked structs, zero-width-concat
  follow-ons.
- Synthesis log checks: `microrom.mem`/`nanorom.mem` "read successfully"
  (silent failure = dead CPU with no error), Amiga RAMs as block RAM,
  `Synth 8-5835` (BRAM over-utilized, "Will try to implement using LUT-RAM")
  now fires routinely — BRAM sits at 365/365, so Vivado spills the excess to
  LUT-RAM and the build still fits; it is a real failure only if implementation
  then cannot place/route. Vivado OOM in the VM: close the implemented design in
  the GUI before relaunching a run.

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

## Roadmap

1. **Floppy: ADF read/write DONE and RELEASED in Version 1 (tag `V1`).**
   Read-only landed 2026-07-03, write 2026-07-05 (`WIP-V1-A4`), and both
   rode through A5..A11 and the release candidates B2/B3 into the Version 1
   release. This is a working, shipped, daily-driven feature - do NOT
   re-open it as "unverified". The only thing still unrecorded is the
   formal write test matrix
   (`.research/INTEGRATION-SPEC-floppy-adf-write.md` §8: WB rename
   persists across power cycle, format, write+verify, swap-while-dirty,
   wprot regression). Before touching floppy code, read BOTH specs in
   `.research/` — the read spec is authoritative on three verified points
   (DEVICE-type mount, bit-8 flow control not
   IO_WAIT, disk_present re-announce per poll); the write spec's §5a
   arm-state invariant closed three review-confirmed critical bugs
   (stale FDH across re-mounts, stale-READY re-arm, F1/F3 slot switch).
   Future increments: df1 (HyperRAM window `C_HMAP_ADF_DF1` reserved),
   mount-status OSM feedback (`<Saving>` needs an M2M options.asm
   generalization, noted in the write spec §7).
2. **DiagROM test round** — zero code: 256 KB DiagROM as /amiga/kick.rom
   exercises slow RAM, keyboard, audio, CIAs (diagrom.com).
3. **RamDump loader** — run deft's demo without floppy (possibly obsolete
   now that ADFs boot — confirm with deft whether .A5R is still wanted):
   the `.A5R` format (192-byte header with full CPU context
   D0-D7/A0-A6/USP/SSP/SR/PC, segment table, RTE-based launcher entry) plus the
   German delivery contract for deft. Loader = OSM manual-load → QNICE→main CDC FIFO
   → upload engine drives userio 0xF0 → launcher ROM replaces kick.
   Hardware state deliberately NOT restored (V1); brief color flicker OK.
4. Pending decision: publish to GitHub as sy2002/AExp (plan exists:
   fork Minimig upstream → sy2002/Minimig_MiSTerMEGA65, fix .gitmodules
   URL, add origin, push master+develop).

## Key documents (read before working)

User-facing docs (also the source for the a500.mega65.org website, built by
`doc/make_doc.py`; see `doc/make_doc.md`):

- `doc/keyboard.md` — full keyboard mapping guide, both modes, per-key tables.
- `doc/retrotubes.md` — connecting real 15 kHz CRTs (BNC / SCART / DB9 RGB) to
  the analog output, including the wiring-safety cautions.
- `doc/audio.md` — end-user guide to volume, stereo mix and the A500/LED
  filters (including the power-LED/filter story).
- `doc/screen_adjust.md` — HDMI crop + analog position/overscan, the
  `aexp_screen.cfg` format and the `aexp_screen_cfg.py` tool.
- `doc/RTC.md` — real-time clock setup and the Kickstart 1.3 quirks.
- `doc/developers.md` — build the core from source (clone → `*.cor`).

Internal engineering notes:

- `doc/developers/floppy-adf.md` — ADF floppy (read/write) design.
- `doc/developers/audio.md` — audio path.
- `doc/developers/hdmi_latency.md` — HDMI latency analysis.
- `doc/developers/research_df1.md` — second-drive (df1) research.
- `doc/inofficial.md` — alpha/beta build history (shipped only in WIP releases).
- `.research/` (local only, untracked) — integration specs and agent review
  reports from the porting sessions.

## People & communication

- The user IS sy2002 — author of the M2M framework and co-author of
  C64MEGA65. Expert level; framework questions can be asked directly.
- deft — MEGA65 project lead and Amiga demo author; provides test
  content (RamDump deliveries). Communication with deft is in German;
  documents intended for him: German, PDF via pandoc + xelatex
  (both installed; strip the English context header first).
