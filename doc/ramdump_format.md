# RamDump V1 (.A5R) - cold-start memory image format for the Amiga core

Status: SPECIFICATION ONLY (loader, launcher ROM and packer script are the
"loader milestone", not yet implemented). Companion documents:
doc/demo_delivery_spec.md (delivery contract / briefing for the demo
author), doc/next_tests.md round B (loader mechanics sketch).

Purpose: a single, community-distributable file per title (demo/game) that
the core's future loader streams into Chip/Slow RAM and cold-starts at a
defined entry point - no Kickstart services, no floppy. Authoring happens
on a PC, typically with WinUAE; the core-side loader stays dumb by design
(validate, clear RAM, copy segments, jump). All title-specific complexity
(including, later, hardware-state restore stubs) lives INSIDE the file as
ordinary code/data segments.

## 1. File layout (all multi-byte fields BIG-ENDIAN, 68000-native)

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | Magic: ASCII "A5R1" (version is part of the magic) |
| 0x04 | 4 | Entry PC (even; inside chip or slow range) |
| 0x08 | 4 | Initial SSP (even; 0 = loader default $00080000) |
| 0x0C | 4 | Flags: bit0 = title requires Slow RAM; all other bits 0 |
| 0x10 | 2 | Segment count N (1..16) |
| 0x12 | 2 | Data checksum: 16-bit sum of all segment-data bytes mod 65536; 0 = no check |
| 0x14 | 12 | Reserved, must be 0 |
| 0x20 | 32 | Title, ASCII, zero-padded |
| 0x40 | 32 | Author/packager, ASCII, zero-padded |
| 0x60 | 32 | Reserved, must be 0 |
| 0x80 | N*8 | Segment table: per segment {target address BE32, length BE32} |
| 0x80+N*8 | ... | Segment data, concatenated in table order, no padding |

Segment rules: address and length even; each segment entirely inside
Chip ($000000-$07FFFF) or Slow ($C00000-$C7FFFF); segments must not
overlap. A full-dump delivery is simply N=2: {$000000, $80000} +
{$C00000, $80000}.

## 2. Loader semantics (the contract the core implements)

1. Validate magic, segment table, flags (reject Slow-RAM titles if a
   future core variant lacks slow RAM).
2. Hold the system in reset, clear Chip and Slow RAM to zero
   (deterministic environment - packaged titles are tested against
   exactly this).
3. Stream all segments to their target addresses; verify the checksum.
4. Publish Entry PC and SSP to the launcher mailbox; release the CPU
   into the launcher ROM (which replaces kick.rom for this use case).
5. Launcher: OVL off, SSP loaded, all data/address registers = 0,
   SR = $2700 (supervisor, interrupts masked), custom chips and CIAs in
   reset state (DMACON/INTENA/INTREQ = 0), then JMP Entry.

This is exactly the "Vertrag" of doc/demo_delivery_spec.md; the entry
must be a no-return takeover entry (own hardware init, no ROM/Kickstart
calls, no disk access).

## 3. Authoring tiers (how titles get packaged)

- **Tier 1 - own production** (works on day one): the author controls the
  takeover point; dump chip/slow at the "packer done, hardware untouched"
  moment (WinUAE debugger: Shift+F12, `S chip.bin 0 80000`,
  `S slow.bin c00000 80000`) or export segments + entry straight from the
  build system. Pack with the packer script.
- **Tier 2 - foreign single-load titles, scener method**: locate the
  natural takeover entry (bootblock loads -> depacks -> JMP mainpart with
  full re-init) by reverse engineering, then proceed as tier 1. This is
  the classic "one-filer" technique from the cracking scene; per-title
  skill and effort required.
- **Tier 3 - savestate conversion (future tooling, format-compatible)**:
  a PC-side converter takes a WinUAE savestate (.uss) captured at a QUIET
  moment (no disk activity, e.g. title screen), extracts CHIP/SLOW RAM +
  custom-chip + CIA + CPU state, and emits an .A5R whose entry points at a
  generated RESTORE STUB segment: the stub rewrites the custom registers
  (savestates contain the write-only register values), restores CIA and
  CPU context, then jumps to the captured PC. Fragile cases (in-flight
  blitter/disk DMA, mid-sample audio) are avoided by the quiet-moment
  rule. Requires NO core/loader change - the complexity ships inside the
  file. This would open up "pause & package" for most single-load titles
  without reverse engineering.

Multi-load titles (anything that returns to the floppy after the first
load) are out of scope for this format - that is the floppy milestone.

## 4. Packer

A ~30-line Python script (tools/a5r_pack.py, to be written with the
loader): inputs = segment files + addresses (or chip.bin/slow.bin full
dumps) + entry + SSP + title/author; output = .a5r. Computes the
checksum, validates the rules above.

## 5. Open points (decide during loader implementation)

- Final file extension (working name .a5r) and FILTER_FILES entry.
- Whether the OSM shows the Title field from the header in the file
  browser flow (nice-to-have; V1 can ignore it).
- Where header parsing lives: QNICE firmware (m2m-rom.asm callback,
  flexible) vs hardware CSR device (rigid). Tendency: QNICE parses the
  128-byte header + table, hardware only streams payload words.
