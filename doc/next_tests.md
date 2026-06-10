# Next test rounds before the floppy milestone

Status: milestone 1 reached 2026-06-10 (Kickstart 1.3 "insert disk" hand on
real R3 hardware, first synthesis). The hand screen already proves: fx68k +
microcode, Kickstart fetch via OVL + bank remap, Chip RAM, Agnus
(copper/bitplane DMA/beam counters), Denise, Paula interrupts, CIA timers,
the userio config FSM, and the whole video path (scandoubler, ascal, HDMI).

NOT yet proven: Slow RAM ($C00000 decode + 0xF5 memory config), keyboard
end-to-end (MEGA65 -> Amiga scancodes -> CIA-A), audio (Paula DMA), blitter
under load, sprites, mouse/joystick. Stock Kick 1.3 offers no further
coverage (no boot menu - that came with Kickstart 2.0; ROMWack only speaks
via the unwired serial port).

## Test round A: DiagROM (zero code changes)

DiagROM by John "Chucky" Hertell - a diagnostic ROM that REPLACES Kickstart:
https://www.diagrom.com/ (downloads: https://www.diagrom.com/index.php/download/
source: https://github.com/ChuckyGang/DiagROM)

How to use with this core: put the 16-bit (A500) DiagROM image on the SD
card as /amiga/kick.rom. The mandatory ROM auto-loader does not care what
the 256 KB contain. No code changes whatsoever.

What it tests for us:
- Chip and Slow RAM detection + pattern tests  -> validates the $C00000
  decode and the 0xF5 memory configuration (512K+512K must be detected)
- Keyboard input visualization                 -> validates keyboard.vhd
  end-to-end (scancode table, kms_level protocol, CIA-A handshake)
- Audio output tests                           -> validates Paula audio path
- CIA chips, IRQ channels, video modes

Caveats:
- We need the 256 KB 16-bit build. Physical-EPROM users append it to itself
  for 512 KB chips, which matches our mirrored layout exactly - but verify
  the file size BEFORE putting it on the card: a 512 KB image would alias
  in our 256 KB kick BRAM. (Check on the Mac: ls -l, must be 262144 bytes;
  if 524288, check whether both halves are identical - then truncate.)
- Serial/parallel port tests will report failures: those ports are tied off
  in this milestone. Expected, not a core bug.

## Test round B: chip RAM loader ("beam a demo into RAM")

Goal: run a self-contained oldskool demo (cold-start memory image) without
floppy emulation. Maps onto the C64MEGA65 PRG-loader pattern.

IMPORTANT expectation for the content provider: a raw RAM dump taken
MID-EXECUTION is not resumable (CPU registers, write-only custom registers
such as DMACON/INTENA/COPxLC, CIA state and beam position are not in RAM).
What works is a COLD-START image + entry point: "load at $X, JMP $X",
self-initializing, takes over the machine, no OS. Classic demoscene form.

Mechanics sketch (no new BRAM ports, no timing exposure):
1. config.vhd: " Demo:%s" menu item (OPTM_G_LOAD_ROM) + C_CRTROMS_MAN entry
   -> Shell file browser streams the file to a new QNICE device (0x0103),
   manual-load CSR protocol at 4k window 0xFFFF (C64 CRT loader pattern).
2. The device is a small QNICE->main CDC FIFO feeding an "upload engine" in
   main.vhd that drives the EXISTING userio host path (kept intact from
   MiSTer): cmd 0xF1 halts+resets the CPU, cmd 0xF0 streams bytes through
   the halted m68k_bridge onto the chipset bus into Chip (or Slow) RAM.
   This is MiSTer's own upload mechanism - reused, not reinvented.
3. Starting the code: after reset the 68000 always boots through Kickstart
   (OVL). Cleanest: a tiny purpose-built "launcher Kickstart" (a few hundred
   bytes of asm padded to 256 KB) that reads an entry-point mailbox (written
   by the upload engine to a fixed chip RAM address) and JMPs to it.
   HRTmon/freeze-cart route is a dead end: its monitor needs backing memory
   at $A10000 and the BRAM is full (1.5 tiles free).
4. File format: small header (magic, load address, length, entry point) +
   payload; generated from the demo binary by a trivial script.

Value beyond the test itself: the QNICE->userio bridge is the same bus
discipline the floppy service will need on the IO_FPGA channel - reusable
plumbing for the next milestone.

## Order

1. DiagROM round (now, zero code).
2. Ask for the demo as cold-start image + entry point; build round B if
   available.
3. Floppy milestone (vdrives + HyperRAM ADF buffer + QNICE MFM service)
   runs everything as shipped. Reminder from the run-1 analysis: ALL future
   buffers must live in HyperRAM - BRAM is at 363.5/365 tiles.
