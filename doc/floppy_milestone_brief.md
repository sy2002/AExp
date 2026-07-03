# Floppy milestone brief (ADF support) — architecture handover

Written 2026-06-12 by the session that completed milestone 1, to transfer
design knowledge that exists nowhere else. Read together with CLAUDE.md.

**MVP definition:** While the Kickstart hand is shown, the user opens the
OSM, selects an .ADF from the SD card, the hand blinks, the disk boots
(Workbench 1.3 reaches the desktop; a game/demo trackloads and runs).
READ-ONLY in the MVP - write support is a later increment.

## 1. THE critical insight (overrides all other documentation!)

Minimig's floppy does NOT use the hps_io sd_* block protocol that
`M2M/vhdl/vdrives.vhd` implements. Do not wire vdrives to Paula - it will
not fit. The M2M wiki, how_to_port.md 3.I and the C64 reference all
recommend vdrives for disk images; that advice applies to cores whose
drives speak sd_*/img_mounted (like the C64's iec_drive). Minimig is
different:

- `rtl/paula_floppy.v` owns the second host channel: `IO_ENA = IO_FPGA`
  (minimig.v:510-514). On MiSTer, the ARM-side software
  (`Main_MiSTer/support/minimig/minimig_fdd.cpp`, `HandleFDD()`) polls
  Paula's status, reads the requested track number, MFM-ENCODES the ADF
  sectors IN SOFTWARE and pushes raw MFM words into Paula's 2048x16 FIFO
  (`paula_floppy_fifo.v`, already ported, LUTRAM).
- Protocol facts (verified in rtl/paula_floppy.v, current tree):
  - IO_STROBE and IO_DIN are SHARED with the userio channel; only the
    enables differ (IO_UIO vs IO_FPGA, minimig.v:510-513 vs 547-550).
    Our `amiga_config.vhd` FSM owns the bus only during the reset
    sequence; a floppy engine is idle then -> trivial priority mux in
    main.vhd.
  - Words are paced by clk7_en with an IO_WAIT handshake (two clk7
    phases per word via `stb7`; paula_floppy.v:200-221).
  - Command word 0: bits [15:13]==000 -> floppy buffer access
    (`cmd_fdd`, :233); bits [15:12]==0001 -> set
    {disk_writable[3:0], disk_present[3:0]} from rx_data[7:0] (insert/
    eject/write-protect signalling - the mount engine must send this).
  - During cmd_fdd the core answers on IO_DOUT: word0 status
    {sel[1:0], drives[1:0], 2'b00, trackwr, trackrd&~fifo_cnt[10],
    track[7:0]}, word1 dsksync, word2 {dmaen, dsklen[14:0]}; then data
    words stream into (read) / out of (write) the FIFO. dsksync match
    (typically $4489) raises the sync interrupt.
  - TRAP: paula_floppy.v has `always @(posedge clk or negedge IO_ENA)`
    async-clear registers. The note in CORE.xdc says they are inert
    while IO_FPGA is tied 0 - that stops being true with this milestone.
    Re-examine those paths in the first timing report.

## 2. Recommended architecture (three pieces)

### 2a. Mount path = the PROVEN C64 CRT pattern, not vdrives

OSM menu item `" ADF:%s"` with `OPTM_G_LOAD_ROM` + a `C_CRTROMS_MAN`
entry of type `C_CRTROMTYPE_HYPERRAM`: the Shell's file browser streams
the whole ADF (901,120 bytes) from SD into a HyperRAM window. This exact
flow ships in C64MEGA65 for multi-MB .CRT files (manual HYPERRAM-type
loads are handled in M2M/rom/crts-and-roms.asm:102-104/186-188 - the
type is remapped to the M2M$HYPERRAM device). Firmware side needs only:
`.adf` in FILTER_FILES (m2m-rom.asm) and the globals.vhd/config.vhd
declarations. VERIFY EARLY: how the manual-HYPERRAM flow signals
completion + file size to the core (for .CRT a core-side CSR device
window 0xFFFF is involved - study C64's sw_cartridge_wrapper.vhd +
crts-and-roms.asm HANDLE_CRTROM_M end-to-end and mirror the minimal CSR).

### 2b. Core-side "track engine" replaces the HPS software (main_clk domain)

A new FSM in CORE/vhdl (wired in main.vhd) that does what HandleFDD did:
1. After mount-complete: send disk_present via the [15:12]==0001 command.
2. Poll Paula via cmd_fdd status reads; when trackrd asserts, read the
   requested track number.
3. Fetch that track's 11 sectors (5,632 bytes) from the ADF in HyperRAM
   over the `hr_core_*` Avalon port (un-tie it; use the avm_cache +
   avm_fifo CDC chain - C64 REU is the wiring precedent, see CLAUDE.md).
4. Produce the MFM track stream and push words into Paula's FIFO
   honoring IO_WAIT (the FIFO backpressures; Paula consumes at
   ~500 kbit/s = 1 word per 32 us - bandwidth is a non-issue here).

### 2c. MFM encoding - two viable options, decide early

- Option A - hardware encoder in the track engine: Amiga MFM sector
  format is well documented (sync $4489 $4489, info longword + label in
  odd/even bit split, header/data checksums, 512 data bytes odd/even).
  Reference algorithm = minimig_fdd.cpp. Moderate FSM, zero mount-time
  cost, tracks served in microseconds.
- Option B - QNICE pre-encodes the whole disk at mount time into a
  second HyperRAM region (~2.2 MB MFM image); the track engine becomes a
  dumb HyperRAM->FIFO streamer. Simpler hardware, but adds QNICE encode
  time to every mount and roughly triples the HyperRAM footprint.
- (Rejected: QNICE encoding per track on demand - couples seek latency
  to QNICE performance for no benefit.)
- HyperRAM budget: 8 MB total, framework reserves below C_HMAP_DEMO
  (0x0200 in 4kW units); one raw ADF (0.86 MB) + optional MFM image
  (~2.2 MB) fit comfortably; plan the C_HMAP_* map for 2 drives later.

## 3. The bandwidth question (promised to deft: "ist M2M schnell genug?")

- Paula consumption: ~1 word / 32 us -> trivial for any option.
- Track latency: HW engine from HyperRAM = microseconds (real drive:
  >= one rotation = 200 ms; we will be FASTER than real hardware, which
  is fine - MiSTer behaves the same).
- The only real number to measure: MOUNT time (SD -> HyperRAM via the
  Shell, 880 KB through the QNICE FAT32 stack). Same path as C64 .CRT
  loading - measure a 1 MB CRT load on C64MEGA65 or just test. If it is
  tens of seconds, it is a UX topic, not a blocker (and NOT fixable in
  the core - it is Shell/SD-SPI bound).

## 4. Touchpoint checklist

- m2m-rom.asm: FILTER_FILES accepts .adf (pattern: C64/JiffyDOS docs;
  rebuild firmware - make_rom.sh scrapes C_CRTROMS_MAN_NUM).
- config.vhd: " ADF:%s" menu item (OPTM_G_LOAD_ROM), OPTM_SIZE/OPTM_DY
  bump, regenerate the settings file (make_config.sh) since OPTM_SIZE
  changes.
- globals.vhd: C_CRTROMS_MAN entry (HYPERRAM type + 4k window), HyperRAM
  map constant for the ADF region, device ID for the engine CSR.
- mega65.vhd: un-tie hr_core_*, avm chain + CDC, CSR device decode,
  C_MENU_* constants shift if menu lines move.
- main.vhd: track-engine instance + IO_STROBE/IO_DIN priority mux with
  amiga_config; drive LED already wired (fdd_led).
- New file(s): CORE/vhdl/adf_track_engine.vhd (+ MFM encoder if opt. A).
- CORE.xdc: revisit the paula_floppy async-IO_ENA note (now live paths).
- All four CORE-R*.xpr get the new files (CLAUDE.md rule 1).
- Timing: WNS margin is +0.387 ns - check after every build. BRAM cost
  of this milestone must be ~0 (engine in logic/LUTRAM; rule 3).

## 5. Test plan

1. Workbench 1.3 ADF: boots from the hand to the desktop - THE canonical
   read test (exercises trackdisk heavily, no timing tricks).
2. deft's demo as ADF, then games (start with friendly trackloaders;
   copy-protected/timing-exact loaders may need the index/timing details
   later).
3. Regression: /amiga/kick.rom mandatory load + hand screen still work;
   DiagROM round unaffected.

## 6. Open questions for the implementing session

- Manual-HYPERRAM CRTROM completion/size signalling (see 2a) - verify
  before designing the CSR.
- Exact dsklen/track length semantics and the write path (trackwr) in
  paula_floppy.v - read the file fully before coding; the write path is
  out of MVP scope but the status words interleave.
- Index pulses / disk-change timing: check what minimig expects for
  disk-change detection when swapping ADFs (re-send of disk_present).
- floppy_config speed bit (cmd 0xF7, currently 0 = normal): MiSTer
  offers "turbo" floppy; keep normal for compatibility in the MVP.
