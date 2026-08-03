# Floppy disks on the Amiga: how AExp reads and writes ADF images

This is the design-and-rationale document for the AExp floppy subsystem — the
three simulated drives `df0:` / `df1:` / `df2:`, each of which mounts an 880 KB
ADF disk image and reads *and* writes it. It merges and supersedes the two
internal integration specs.

It is written for a coder who **knows the MiSTer2MEGA65 (M2M) framework but
has never touched an Amiga**. The Amiga floppy is the single most un-M2M-like
subsystem in the whole port: it does not look like a disk drive, it cannot use
the framework's `vdrives` system, and almost every design decision is forced by
a hardware reality that has no analogue in the C64 or the other M2M cores. So
this document spends real effort teaching the Amiga side before explaining what
we built. If you only want the register maps, jump to
[§12 Reference](#12-reference).

## Table of contents

1. [The one idea you must accept first: the Amiga has no sectors](#1-the-one-idea-you-must-accept-first-the-amiga-has-no-sectors)
2. [Amiga floppy geometry and the ADF file](#2-amiga-floppy-geometry-and-the-adf-file)
3. [MFM: how 512 bytes of data become ~1088 bytes of flux](#3-mfm-how-512-bytes-of-data-become-1088-bytes-of-flux)
4. [The MiSTer/minimig model, and how AExp differs](#4-the-misterminimig-model-and-how-aexp-differs)
5. [Why we could **not** use the `vdrives` system](#5-why-we-could-not-use-the-vdrives-system)
6. [Three drives, one engine](#6-three-drives-one-engine)
7. [The read path (Milestone 1)](#7-the-read-path-milestone-1)
8. [The write path (Milestone 2)](#8-the-write-path-milestone-2)
9. [The arm-state invariant (the subtle correctness core)](#9-the-arm-state-invariant-the-subtle-correctness-core)
10. [Questions you are probably asking](#10-questions-you-are-probably-asking)
11. [How we verified it](#11-how-we-verified-it)
12. [Reference](#12-reference)
13. [Glossary for M2M coders](#13-glossary-for-m2m-coders)

---

## 1. The one idea you must accept first: the Amiga has no sectors

Every storage device you have integrated into M2M so far — the C64's 1541, an
SD card, a CRT/PRG loader — is a **block device**. Something asks for "block
number N," and you hand back 256 or 512 bytes. Writing is the reverse. The
codec that turns magnetic flux into bytes lives *inside the drive hardware*, out
of sight; the core only ever sees clean blocks.

**The Amiga floppy is not like that.** Its disk controller, a chip called
**Paula**, is deliberately dumb. Paula cannot read a sector. All Paula can do is
DMA a raw stream of **MFM-encoded flux words** — the literal magnetic signal on
the disk surface — into or out of Chip RAM, one whole track at a time. Turning
that raw flux stream into 512-byte sectors (and back) is done **in software**,
by the operating system's `trackdisk.device`, running on the 68000 CPU.

This one fact is the root of everything in this document:

> **The Amiga's disk codec is software. There is no sector interface to hook
> into, because on a real Amiga the sector abstraction does not exist below the
> CPU.**

Three consequences follow, and they shape the entire subsystem:

1. **An MFM codec has to exist somewhere in our design.** On a real Amiga it is
   `trackdisk.device`. In MiSTer it is a C function on the ARM. In AExp it is
   FPGA logic. Someone must encode sectors into flux (for reads) and decode
   flux back into sectors (for writes).
2. **The disk "protocol" is a raw word stream, not a block protocol.** There is
   no `read_sector(n)`. There is a channel over which Paula and its "disk
   surface" exchange 16-bit MFM words with a handshake. We have to speak that.
3. **`vdrives` — M2M's block-level disk-image system — is structurally useless
   here** (see [§5](#5-why-we-could-not-use-the-vdrives-system)). It bridges a
   sector protocol the Amiga floppy does not have.

If you internalise "the Amiga floppy is a flux stream, not a sector device,"
the rest of this document is a series of logical consequences.

---

## 2. Amiga floppy geometry and the ADF file

A standard Amiga double-density (DD) 3.5" floppy:

| Property | Value |
|---|---|
| Cylinders | 80 (numbered 0..79) |
| Heads / surfaces | 2 (top + bottom) |
| **Tracks** (cylinder × head) | **160** (numbered 0..159) |
| Sectors per track | 11 |
| Bytes per sector | 512 |
| **Bytes per track** | **5632** (`11 × 512`) |
| **Total capacity** | **901,120 bytes** = 880 KB |

That "880 KB" is exactly what the `info` command shows as the disk size once
Workbench boots. A "track" here means one cylinder on one head — the smallest
unit Paula reads or writes in one DMA pass.

Some disk dumps go slightly beyond 80 cylinders (81, 82, or 83) to capture
"over-dumped" copy-protected disks; the mechanics allow the head to step that
far. So AExp accepts **160 to 166 tracks** (up to 934,912 bytes). Anything
outside that range is rejected at mount time. The geometry constants live once,
in `CORE/vhdl/globals.vhd` (`C_ADF_TRACK_BYTES`, `C_ADF_MIN_TRACKS`,
`C_ADF_MAX_TRACKS`), and `make_rom.sh` scrapes them into the firmware so the
size gate can never drift from the hardware.

### The ADF file

An **ADF** ("Amiga Disk File") is the disk's *decoded* content: all the
512-byte sectors, in order, concatenated into one flat file. **No MFM, no sync
words, no gaps, no checksums** — just the clean payload. It is the equivalent
of the C64's D64: the "logical" image, not the "physical" flux.

The byte offset of any sector in an ADF is trivially:

```
offset(track T, sector S) = (T * 11 + S) * 512
                          = T * 5632 + S * 512
```

Both the read path (fetch a sector to encode) and the write path (store a
decoded sector) use exactly this arithmetic. Track starts are 512-aligned,
which later matters for how the firmware flushes to the SD card.

**The core tension of this whole subsystem:** the ADF on the SD card is
*decoded* (clean sectors), but Paula only ever speaks *encoded* MFM flux. So
every read has to encode, and every write has to decode. That codec is the
heart of the implementation.

---

## 3. MFM: how 512 bytes of data become ~1088 bytes of flux

You do not need to become an MFM expert, but you need the shape of it, because
our engine reproduces it **bit-for-bit** — any deviation and `trackdisk.device`
rejects the disk.

**Why encoding exists at all.** A floppy stores flux reversals, and the drive
recovers a clock from them. Long runs without a reversal lose the clock. MFM
(Modified Frequency Modulation) guarantees a bounded gap between reversals by
interleaving **clock bits** between data bits. The upshot: raw data cannot be
written to disk directly; it is expanded to roughly double the size, with the
extra bits carrying timing.

**The Amiga's specific scheme** has a quirk that will show up all over the code:
it does **not** interleave a data byte's bits with its own clock bits in place.
Instead it splits every data long word into its **odd-numbered bits** and its
**even-numbered bits**, encodes each half separately, and transmits the whole
"odd" half of a block followed by the whole "even" half. To decode, you read
the odd half and the even half and re-interleave. This is why you will see the
data field encoded as **256 words of odd bits, then 256 words of even bits**,
and why the decoder makes two passes.

**The sync word `0x4489`.** Before a sector's data, the stream contains a
special MFM word `0x4489` that can never occur inside normal encoded data. Paula
(in its default WORDSYNC mode) throws away everything on the wire until it sees
`0x4489`, then starts storing — that is how it finds sector boundaries in a
featureless flux stream. Two sync words are sent per sector because the first is
consumed by the match and the second is stored.

**One MFM sector = 544 sixteen-bit words** (= 1088 bytes), laid out like this
(this is exactly what the encoder emits and the decoder consumes):

| Words | Content |
|---|---|
| 2 | `0xAAAA` preamble |
| 2 | sync (`0x4489`) |
| 2 | **info** odd — format, track, sector, "sectors-to-gap", odd bits |
| 2 | **info** even — the even bits of the same |
| 16 | sector label (`0xAAAA`, unused by AmigaDOS) |
| 4 | header checksum |
| 4 | data checksum |
| 256 | **data** odd bits (`512` payload bytes → `512` MFM bytes) |
| 256 | **data** even bits |

After the 11th sector of a track, `350` filler words (`0xAAAA`) form the track
gap. So a full track is `11 × 544 + 350 = 6334` words of flux.

The **info long word** is the sector's self-description: a format tag (always
`0xFF`), the track number, the sector number (`0..10`), and how many sectors
remain until the gap. The **checksums** protect the header and the data with the
Amiga's odd/even XOR scheme. When we *write*, verifying these checksums is how
we know a decoded sector is trustworthy before committing it.

**Where the bit-exact reference comes from.** MiSTer already reverse-engineered
this codec into C, in `minimig_fdd.cpp` (upstream
`Main_MiSTer/support/minimig/`; functions `SendSector` for encode and
`FindSync` / `GetHeader` / `GetData` for decode). We transcribed those functions
into VHDL, and verified byte-identical output through the whole chain; it is the
ground truth for both the encoder and the decoder. Every "magic" mask (`0x55`,
`0xAA`, `0x5555`) in `adf_track_engine.vhd` traces directly to a line in that
file.

---

## 4. The MiSTer/minimig model, and how AExp differs

The Minimig core (the Amiga RTL we build on) inherited its floppy design from
MiSTer, and understanding that inheritance explains our architecture.

**In a real Amiga:** Paula's disk DMA reads flux from the physical drive head.
`trackdisk.device` on the 68000 does the MFM codec.

**In MiSTer:** there is no physical drive. Paula's disk DMA is redirected to a
**host channel** — a side-band interface (`IO_FPGA` in the RTL) over which Paula
requests/emits raw MFM words. On the other end sits the ARM CPU running Linux,
executing a C function called `HandleFDD` that plays the role of "the disk
surface": it encodes sectors from the ADF file for reads and decodes flux into
the ADF for writes. Paula still does the codec-*consuming* (WORDSYNC, FIFO), but
the flux itself is manufactured by software.

**In AExp there is no ARM and no Linux.** We split `HandleFDD`'s job across the
two brains we do have:

```
                 real Amiga            MiSTer                 AExp
                 ----------            ------                 ----
 the codec +     trackdisk.device      HandleFDD (C,          adf_track_engine
 host protocol   (68000 software)      ARM software)          (FPGA logic, main clk)

 the "medium"    magnetic surface      ADF file on SD         one ADF image per drive
                                       (read by the ARM)      in HyperRAM (served by
                                                              the engine)

 persistence     —                     ARM writes the ADF     QNICE firmware flushes
                                        file directly          each drive's dirty
                                                               tracks to its own ADF
```

The split is deliberate and is the key architectural decision:

- **The timing-touchy part — the MFM codec and the Paula host protocol — is
  FPGA logic** (`adf_track_engine.vhd`), running in the `28.375 MHz` main clock
  domain right next to Paula. It has to keep Paula's FIFO fed on reads and drain
  it on writes; putting it in hardware keeps that loop local and fast.
- **The slow part — persisting to the SD card — is QNICE firmware**, running in
  the QNICE domain, using the FAT32 library. SD I/O is milliseconds-slow and has
  no place near Paula's flux timing.
- **The "medium" is HyperRAM.** Each mounted disk image lives there, in its own
  pool. Reads serve from it; writes commit to it. Think of HyperRAM as the
  magnetic surface and the SD file as the archival backing store.

Everything else in this document is detail hung on that three-way split.

---

## 5. Why we could **not** use the `vdrives` system

This is the first question any M2M coder asks, so let us be precise. You know
`vdrives` (`M2M/vhdl/vdrives.vhd` + the Shell's `HANDLE_IO` / `FLUSH_CACHE`): it
is how C64MEGA65 gives the 1541 writable D64 images. It is a beautiful,
proven system. It is also **the wrong shape for the Amiga floppy**, for a reason
that is structural, not incidental.

**What `vdrives` actually bridges.** `vdrives` is a translator for MiSTer's
**"SD block" interface**: a MiSTer core (like the C64's `iec_drive`) exposes
`sd_lba`, `sd_rd`, `sd_wr`, `sd_buff_*` — *"please read/write logical block
number N, here is the 256-byte buffer."* `vdrives.vhd` turns that block request
into a QNICE MMIO transaction; the Shell firmware copies the block between the
core and a RAM-resident image, and `FLUSH_CACHE` lazily writes the whole image
to the SD card. It is, end to end, a **decoded-block** pipeline.

**Why the Amiga floppy has nothing to hand it.** The Minimig core does **not**
expose `sd_lba`/`sd_rd`/`sd_wr` for its floppy. As we established in
[§1](#1-the-one-idea-you-must-accept-first-the-amiga-has-no-sectors) and
[§4](#4-the-misterminimig-model-and-how-aexp-differs), the Amiga floppy speaks
raw MFM over the `IO_FPGA` **floppy host channel**, not a block protocol — a
legacy of MiSTer's minimig, where the ARM's `HandleFDD` services that channel
directly and the MiSTer block interface is bypassed for floppies entirely. There
are no block-request wires coming out of Paula for `vdrives` to connect to. The
thing `vdrives` translates simply does not exist on this core.

And you could not fake it cheaply: the block abstraction the C64 gets for free
(its 1541 model emits decoded sectors) only appears on the Amiga *after* the MFM
codec runs. To feed `vdrives` you would first have to build the entire codec —
at which point `vdrives` adds nothing but an impedance mismatch. Consistent with
all of this, AExp sets `C_VDNUM = 0`: there is no `vdrives` instance in the
core at all.

**But here is the important nuance, and the reusable lesson.** `vdrives` is
really *two* things bolted together:

1. a **hardware bridge** for a block protocol — unusable for us, and
2. a **firmware persistence discipline** — a write-back cache in HyperRAM, a
   background flush driven from `HANDLE_IO`, an anti-thrashing timer, a "disk is
   dirty" LED, and a "don't let the user unmount while dirty" policy.

The *hardware bridge* we had to throw away. The *firmware discipline* is exactly
what our problem needs — we too have HyperRAM-resident images that want lazy,
safe SD persistence. So we **transplanted the discipline onto our own devices**,
reusing even its `config.vhd` constants (the `2000 ms` anti-thrashing delay),
while replacing the block bridge with the floppy host channel + MFM codec.

> **The lesson:** when a framework system does not fit, separate its *mechanism*
> from its *pattern*. We rejected the `vdrives` mechanism and copied the
> `vdrives` pattern. That distinction is why the write path looks familiar to a
> C64MEGA65 reader even though not one wire of `vdrives.vhd` is involved.

---

## 6. Three drives, one engine

An Amiga addresses up to four floppy units; AExp offers three, `df0:` / `df1:` /
`df2:`. The OSM **Drive Settings** submenu decides how many exist (a `Drives`
radio: 1 / 2 / 3) and what each one *is* (a mode radio per drive):

- **Disk Image** — a simulated ADF drive, the subject of this document;
- **Hardware Floppy** — the MEGA65's own internal 3.5" mechanism reading real
  Amiga disks (read-only, and at most one drive at a time);
- **Off** — the unit does not exist. `df0:` always exists and has no Off item.

The main menu shows **two permanently allocated lines per drive** — the mount
item `" dfN:%s"` and a plain TEXT line reading `dfN:Hardware Floppy` — and the
menu-dependency layer (`M2M-UPSTREAM osm-deps`) puts exactly the one on screen
that matches the drive's mode, or neither while it is Off. The TEXT line is
space-padded to exactly `OPTM_DX` characters, because that trailing field is
where the firmware patches the live status of the real mechanism in place, in
the menu heap, through the framework helper `OPTM_LIVE_TEXT`
(`M2M-UPSTREAM live-text`) — a fixed width is what lets it be overwritten
without moving the arrays behind the menu-struct pointers.

### 6.1 The drive index is one number for everything

This is the fact the whole subsystem is built on, so it is worth stating flatly:

> **The drive index 0..2 is at the same time the Amiga unit number, the manual
> CRT/ROM id of the Shell, the QNICE device selector, the HyperRAM pool
> selector and the firmware array index.**

| Drive | QNICE device | HyperRAM pool (word base) | Manual id | Shell file handle | Mount menu group |
|---|---|---|---|---|---|
| 0 = `df0:` | `0x0103` `C_DEV_AMIGA_ADF0` | `C_HMAP_ADF_DF0`, `0x200000` | 0 | `HANDLE_RM_FILE1` | `OPTM_G_ADF0` |
| 1 = `df1:` | `0x0105` `C_DEV_AMIGA_ADF1` | `C_HMAP_ADF_DF1`, `0x280000` | 1 | `HANDLE_RM_FILE2` | `OPTM_G_ADF1` |
| 2 = `df2:` | `0x0106` `C_DEV_AMIGA_ADF2` | `C_HMAP_ADF_DF2`, `0x300000` | 2 | `HANDLE_RM_FILE3` | `OPTM_G_ADF2` |

(`0x0104` sits between the ADF devices and is the Hardware Floppy diagnostics
bank, `C_DEV_AMIGA_FDD`; its register map is documented by number elsewhere, so
it keeps its id.)

**Why the identity holds.** A manual CRT/ROM line is bound to its id by its
*position*: `CRTROM_M_GI` (`M2M/rom/crts-and-roms.asm`) counts `OPTM_G_LOAD_ROM`
occurrences in the **static** `OPTM_GROUPS` array of `config.vhd` and is
completely blind to menu-dependency visibility. The three mount lines sit in
`df0`, `df1`, `df2` order in that array, so occurrence *n* is drive *n* forever —
hiding a mount line (because that drive is currently the Hardware Floppy, or
Off) does **not** renumber the others. That is also why every unit which can
*ever* be an ADF drive needs its own permanently allocated mount line, and
therefore its own QNICE device: the binding is positional, not dynamic.

Three small ROM tables in `m2m-rom.asm` are the only place in the firmware that
knows this mapping — `ADF_DEV_TAB` (drive → device), `ADF_FDH_TAB` (drive → its
retained file handle) and `ADF_GRP_TAB` (drive → its mount menu group), plus
`ADF_MNT_LN_TAB` / `ADF_HW_LN_TAB` for the flat menu-line indexes of the twin
lines. Everything else indexes by the plain drive number.

### 6.2 Three of everything cheap, one of everything expensive

The mount side scales by **replication**: `mega65.vhd` instantiates three
`adf_mount_wrapper` entities in a generate loop, each with its own device id,
its own HyperRAM pool base, its own CSR, its own write-back CSR and its own
QNICE→HyperRAM CDC. They are completely independent.

The serve side scales by **time-sharing**: there is exactly one
`adf_track_engine`, because the expensive parts — the MFM encoder, the MFM write
decoder, the sector buffers, the Avalon master, the Paula host channel itself —
exist only once. The engine dispatches per poll on the `sel` bits of Paula's
status word.

The four HyperRAM masters (the engine plus the three wrappers) meet in an
`avm_arbit_general` with `G_NUM_SLAVES = 4`. Slave 0 is the engine, because it
is the only latency-sensitive one — Paula is waiting for its sector — and slaves
1..3 are the wrappers, which are busy only while the Shell streams an image off
the SD card.

### 6.3 Unit ownership: the load-bearing invariant

Because one engine serves several units, every piece of in-flight state must
know **which unit it belongs to**, and it must be *latched*, not re-derived.
Paula binds a transfer to one unit for its whole duration, but the `sel` field
of the status word is a priority encoder, so a change-poll click on another
drive can make a single poll report a foreign unit in the middle of a transfer.

- **`serve_unit`** is latched at the poll that accepted a read request and is
  what the fetch address, the track clamp and the mid-stream abort check use.
  **`adf_stream`** freezes it for the whole DMA, so a transient foreign `sel`
  sample cannot re-dispatch a running read to another drive and stream *its*
  image into the buffer the first drive is filling.
- **`drain_unit`** is latched when a write drain starts and is what the commit
  address, every commit gate and the dirty-track event use. The moment a poll
  reports a **different** unit, the drain is aborted — in *every* decoder phase,
  not just while hunting for a sync.
- **Rotation continuation** (`track_prev`, `track_valid`, `sector_next`) is
  **per unit**. Two drives stepping and reading in alternation must not inherit
  each other's head and sector position; a shared `sector_next` shows up as
  random sector-order corruption.
- The `0x1nnn` drive-status announce carries **per-unit nibbles** (see
  [§8.6](#86-write-protect-and-the-drive-status-announce)).

The unconditional drain abort deserves its own sentence, because it is the one
defect class that silently corrupts a disk image:

> **A frame belonging to unit B, fed into a decoder that was opened for unit A,
> would checksum-verify perfectly and be committed into unit A's image.** The
> price of aborting unconditionally is that a transient foreign `sel` sample
> costs the sector that was mid-decode. Losing a sector is recoverable —
> `trackdisk` verifies a track after writing it and retries. Committing it into
> the wrong drive's image is not.

### 6.4 The HyperRAM pools

Each drive owns a 128-window (1 MB) slot in the HyperRAM map: 115 windows of
image pool (942,080 bytes, enough for the largest accepted 166-track image),
one explicit 8 kB guard window, and reserved slack. `mega65.vhd` asserts the
size and ordering relations at elaboration time.

The guards are not decoration. The overreach they catch is created *downstream*
of our clients, in shared M2M infrastructure: `avm_cache` turns a read miss into
an 8-word burst and additionally pre-fetches the next half line, so it reaches
up to 8 words past the word the engine actually asked for, and
`hyperram_errata.vhd` turns every single-word write into a 2-word burst. A
160-track image is exactly 110 windows and therefore ends flush on a window
boundary — an end-of-image pre-fetch steps straight into whatever follows. One
guard window is 4096 words, roughly 500× the worst case.

---

## 7. The read path (Milestone 1)

Read support has two halves that meet at HyperRAM: **mount** (get the ADF into
that drive's HyperRAM pool, at load time) and **serve** (feed Paula from
HyperRAM, at run time).

```
 MOUNT (load time)                          SERVE (run time)
 =================                          ================
 OSM " dfN:" mount line                     Kickstart writes DSKLEN/DMACON
   -> Shell file browser (.adf filter)        -> Paula arms disk DMA (read)
   -> streams bytes into the QNICE           adf_track_engine (main clk):
      device of THAT drive                      polls Paula over IO_FPGA,
      = its adf_mount_wrapper                   latches the selected unit,
   -> qnice2hyperram + avm_fifo (CDC)           fetches the sector from that
   -> that drive's HyperRAM pool                unit's pool, MFM-encodes it,
   -> CSR handshake: size check, track          pushes 544 words into Paula's
      count, READY/ERROR back to the Shell      2048-word FIFO with status-
                                                bit-8 flow control
```

### 7.1 Mount: getting an ADF into HyperRAM

The user opens the OSM, puts the cursor on one of the three `dfN:` lines, picks
an `.adf`, and the Shell streams it byte by byte into that drive's QNICE device.
Three choices here are non-obvious:

**Why HyperRAM, not BRAM.** The Amiga's Chip/Slow/Kickstart RAM already fills
the FPGA's block RAM — there is no room for even one 880 KB disk image in BRAM,
let alone three. The images live in HyperRAM above the `4 MB` mark, past the
framework region that holds the ascal video framebuffer. This is the same "big
buffers live in HyperRAM" rule that governs the whole port.

**Why `C_CRTROMTYPE_DEVICE`, not `C_CRTROMTYPE_HYPERRAM`.** M2M has a manual-load
type that streams straight into HyperRAM, which looks perfect and is a trap. The
Shell's completion handshake (`HANDLE_CRTROM_M`) runs a CSR protocol against 4k
window `0xFFFF` of the *streaming device*. For the HYPERRAM type that "device"
is raw HyperRAM, whose window `0xFFFF` maps into HyperRAM *register* space —
there is no responder, and the Shell's parse-status poll has **no timeout**, so
it hangs forever. C64MEGA65 ships the DEVICE type with a core-side CSR for
exactly this reason; we mirror the shipping pattern. Our devices are the three
`adf_mount_wrapper` instances.

**The CSR handshake** is the familiar CRT/ROM loader dance, reused verbatim: the
Shell writes `ST_LDNG` before streaming, then the file size and `ST_OK`, then
polls `PARSEST` until the core answers `READY` or `ERROR`. Our "parser" is a
trivial size validator in the QNICE domain: it divides the file size by `5632`
by iterative subtraction and accepts exactly `160..166` tracks, rejecting
anything else with an "Invalid ADF size" string in the OSM. On success it
exposes that drive's `disk_mounted` and `tracks_total`; all three drives' status
bits cross to the main clock in one `cdc_stable` bundle.

The firmware adds its own guard *before* the streaming even starts, in
`PREP_LOAD_IMAGE`: an unsigned 32-bit range compare against the scraped
`C_ADF_MIN_SIZE` / `C_ADF_MAX_SIZE`, so an absurd (renamed) file can never
stream past the receiving drive's pool. `FILTER_FILES` and `PREP_LOAD_IMAGE` both
resolve the Shell's menu group id through `IS_ADF_GROUP`, which accepts all
three mount groups — if either callback only recognised `df0`, the extension
filter and the size guard would silently not apply to the other two drives.

The seconds-long streaming of a *new* mount is also that drive's **disk-eject
window**: its `disk_mounted` drops the moment the Shell starts the next load,
which is how Kickstart's disk-change logic notices an ADF swap.

**Ejecting.** With the OSM open and the cursor on a mount line whose drive holds
a disk, SPACE ejects it — the C64 gesture. The framework has no unmount path for
CRT/ROM devices, so `HANDLE_UNMOUNT_KEY` intercepts the key core-side, before the
`KEYB$SCAN` of the menu's own wait loop. It finds *which* drive the cursor is on
by comparing `OPTM_CUR_SEL` against the three build-time flat menu-line constants
in `ADF_MNT_LN_TAB` — three compares, versus rescanning the 146-line menu three
times on every key-wait poll. `ADF_UNMOUNT` then takes that drive index and, in
this order, ejects (writes `ST_IDLE` to that device's CSR, which drops
`disk_mounted` and reverts the menu label), force-flushes that drive's dirty
tracks, and disarms its write-back. Every other drive keeps running untouched.

### 7.2 Serve: `adf_track_engine`

The engine lives in `main.vhd`, in the `28.375 MHz` main clock domain — the same
clock as Paula. It needs no `clk7_en` gating, because Paula's own `io_wait`
handshake encapsulates its `clk7` pacing.

**The Paula host protocol** (the contract the engine implements — verified
against `paula_floppy.v`). A *frame* is `io_fpga` held high; within it, each
16-bit *word* is a one-clock `io_strobe` pulse answered with an `io_wait`
handshake. Three word-response pairs carry the state:

| Word sent | Response meaning |
|---|---|
| `w0` | status: `{sel[1:0], drives[1:0], "00", trackwr, trackrd & ~fifo_full, track[7:0]}` |
| `w1` | `dsksync` (the live sync register) |
| `w2` | `{dmaen, dsklen[14:0]}` on read / write-FIFO status on write |
| `w3+` | FIFO data words |

`sel[1:0]` in `w0` is what tells the engine which unit this poll is about, and
[§6.3](#63-unit-ownership-the-load-bearing-invariant) explains why it is latched
rather than trusted per poll.

Three gotchas here cost real debugging and are worth stating flatly:

- **`io_wait` is per-word pacing, not FIFO backpressure.** If you overrun
  Paula's FIFO it *silently drops the word* while `dsklen` keeps counting — a
  corrupted track with no error. The **only** real flow control is status
  **bit 8** (`trackrd & ~fifo_full`, masked while the FIFO holds ≥ 1024 words).
  Rule: re-poll status before every sector, and push at most one sector (+ track
  gap) per grant. Worst-case fill stays at `1023 + 544 + 350 = 1917 < 2048`.
- **Polling is what arms Paula's DMA.** Paula's disk-DMA state machine only
  leaves idle at word 1 of a poll frame — without polling, disk DMA never
  starts, and the arming poll itself still reports the stale `trackrd = 0`; the
  next poll sees the real request.
- **`disk_present` is wiped by *every* Amiga reset**, including the `RESET`
  instruction Kickstart executes on each reboot. So the engine re-sends the
  drive-status word **every poll cycle** (MiSTer does the same). That word must
  be a strict **one-word frame**, because its `0x1xxx` bit pattern also sets an
  internal Paula flag; a second word could spuriously arm disk DMA.

**The MFM encoder** is the [§3](#3-mfm-how-512-bytes-of-data-become-1088-bytes-of-flux)
layout realised as a word counter plus byte-lane masks — combinational, tiny.
For sector `S` of clamped track `T` it emits the 544 words (preamble, sync,
info, label, checksums, 256 odd data words, 256 even data words), computing the
data checksum on the fly as it fetches. It also reproduces MiSTer's "Copy Lock"
sync substitution and the sector-rotation continuation that some trackloaders
depend on. The track clamp and the rotation continuation both read the *serving
unit's* track count and rotation state, never a global one.

**The Avalon read chain** is the C64 REU pattern: the engine issues single-word
reads into an `avm_cache` (8-word cache line) → `avm_fifo` (main → HyperRAM CDC)
→ the 4-way arbiter → `hr_core_*`. The cache amortises the sequential reads into
one HyperRAM burst per eight words.

That cache is **shared by all three drives**, which makes its invalidation a
multi-drive concern: after the Shell has streamed a new image into *any* pool, a
stale line would serve up to eight words of the previous image. A change of the
mount vector is exactly the observable event, so any change arms a flush — but
the flush must not happen while anything is in flight. Two things can be: the
engine, which `avm_cache` would leave waiting forever for a burst response that
the reset threw away (`avm_busy_o` covers that, and it rises one state *before*
the first read or write is issued), and the cache's own master side, whose last
write of a committed sector may still be waiting for `waitrequest` to drop —
dropping it would tear a sector in the `.adf`. So the flush waits for a run of
quiet cycles on both.

---

## 8. The write path (Milestone 2)

### 8.1 The mirror insight

Here is the payoff of understanding the read path: **writing is reading run
backwards.** When the Amiga writes a track, Paula's disk DMA streams raw MFM
words *out* over the same `IO_FPGA` host channel. The protocol is identical; only
the direction of the data words reverses. So the write path is not a new
subsystem — it is a new consumer of the same frames.

There is a subtlety that makes even a read-only configuration care about it. The
engine must **drain** Amiga writes, because of a hard safety rule:

> **Paula's write DMA completes (raises `DSKBLK`) only when `dsklen` has expired
> AND the FIFO is empty. If the host never drains the write FIFO, Agnus stalls,
> the DMA never finishes, and the machine hangs forever.**

So the engine always has a `WDRAIN` path that pops write words; write support is,
at its core, the difference between "discard" and "decode and commit". A drive
whose write-back is not armed, and a unit backed by the Hardware Floppy, take
the pure-discard branch — the data must still be consumed, or the machine hangs.

### 8.2 The MFM write decoder

The decoder is the bit-exact inverse of the encoder, transcribed from
`minimig_fdd.cpp`'s `FindSync` / `GetHeader` / `GetData`. It runs as a small
mode machine (`HUNT` → `HDR` → `DATA`) layered onto the existing drain loop:

- **HUNT** (`FindSync`): pop words until one equals the literal `0x4489`. Note:
  the write path syncs on the **literal** `0x4489`, *not* the live `dsksync`
  register (MiSTer parity — custom-sync writers are unsupported, as on real
  MiSTer). The hunt is gated by `drain_commit`, so a drain owned by a unit that
  may not commit never even starts decoding.
- **HDR** (`GetHeader`): consume the 25 header words, decode the info long word
  (`((odd & 0x55) << 1) | (even & 0x55)` per byte), and validate: format `0xFF`,
  sector `0..10`, gap `1..11`, and the header checksum.
- **DATA** (`GetData`): consume the 4 data-checksum words, then 256 odd words,
  then 256 even words, re-interleaving into a 512-byte sector buffer and
  verifying the data checksum.

**A crucial simplification carried over from MiSTer:** a section is consumed
**only once Paula's FIFO already holds all of it** (header needs ≥ 25 buffered
words, data needs ≥ 516). This removes any mid-section starvation handling — the
decoder never blocks waiting for a word that has not arrived.

**Commit.** A sector that passes *every* gate — header checksum, data checksum,
format, sector range, gap range, **and** header-track equals the physical track,
**and** the physical track is inside the mounted image, **and** write-back is
armed on a mounted disk — is written into the HyperRAM image through the *same*
Avalon chain the reads use. Every one of those image-side gates is evaluated for
`drain_unit`, the unit that **owns** this drain, never for whatever unit Paula
happens to be polling by the time the last data word arrives; the commit address
is built from that unit's pool base too. `avm_cache` is **write-through**: a
write hit updates the cache line, so a subsequent read of that sector stays
coherent. A sector that fails any gate is **drained but never committed** —
exactly how MiSTer treats a write to a protected disk.

**Three deliberate, reviewed deviations from `minimig_fdd.cpp`**, all no-ops for
valid sectors and documented in the engine header:

1. MiSTer rejects header track `> 159`; we replace that with the commit-time
   checks (header-track equals physical track, physical track inside the image),
   which is what lets our accepted 160–166-track over-dumps be *writable* too.
2. MiSTer aborts a bad header after 5 words and re-hunts through the remaining
   label/checksum words; we reject after all 25. Both converge on the next true
   sync; ours simply drains more cleanly.
3. MiSTer's stored-checksum decode drops one lane's odd bits (a one-lane typo).
   We compare all lanes in full — strictly stricter, and a no-op because valid
   Amiga checksums only ever carry the masked bits anyway.

### 8.3 Getting "it's dirty" from the core to the firmware

Now a genuinely new problem the read path never had: **the core must tell the
QNICE firmware that a track changed**, so the firmware can flush it — and it
must say *which drive's* track.

Your first instinct as an M2M coder is `qnice_gp_reg`. It does not work: that
register is the QNICE SoC's `control_d_o` — it is **QNICE → core only**. The
reverse-direction registers `M2M$SPECIAL` / `M2M$GENERAL` exist but are tied to
`'0'` in the framework. **There is no existing core → QNICE signalling path.**

So we built one, out of parts you already know:

- **Our own register window, one per drive.** Every ADF device already owns the
  `0xFFFF` CSR window; each also carves out **window `0xFFFE`** for a small
  "write-back CSR" (WBC) — a `WR_EN` bit, a `166`-bit per-track **dirty bitmap**,
  an anti-thrashing delay register and a status register. Because each
  `adf_mount_wrapper` instance carries its own complete WBC, the **register
  offsets are identical for all three drives and only the device id differs**.
  That is the whole reason the firmware side can be a plain array: one helper,
  `ADF_SEL_WBC`, points the RAMROM window at the WBC of a given drive, and every
  register access afterwards is drive-agnostic.
- **A two-phase toggle handshake for the events.** When the engine commits a
  sector it must set that track's bit in that drive's bitmap, but the bitmap
  lives in the QNICE domain. So the engine holds the track number stable, waits
  ~1 µs, *then* flips a `req` toggle; the wrapper sets the bit and flips an `ack`
  toggle back. Because `cdc_stable` only propagates a value once it is stable,
  and the payload is held put for the whole round trip, the toggle can never
  arrive alongside a torn track number. Events are milliseconds apart (a sector's
  MFM takes that long to stream in), so the microsecond handshake is never a
  bottleneck. The engine clears its *pending* bit **before** starting the
  handshake, so a re-dirty during the handshake generates a fresh event rather
  than being lost.
- **One event channel, three consumers.** The track payload is *shared* and the
  `req`/`ack` toggles are *per drive*: the engine's scanner serves one event at a
  time, so the payload is stable for the whole round trip of the addressed
  drive, and the two idle drives see no toggle edge at all. The scanner walks
  tracks 0..165 of one drive and then moves on to the next, so a busy drive can
  never starve the others.

**Why the bitmap is per-*track*** (166 bits) rather than per-sector: the Amiga's
`trackdisk.device` rewrites a *whole track* even to change one block (read track,
edit, write track), so all 11 sectors stream through the decoder anyway.
Per-track keeps the bitmap tiny, keeps every SD seek 512-aligned
(`track × 5632`), and — as [§10](#10-questions-you-are-probably-asking) explains
— is why flushing is fast.

### 8.4 The firmware: persisting dirty tracks to the SD card

Now the second new problem: **the Shell's main loop has no core-specific hook.**
`MAIN_LOOP` calls `HANDLE_IO`, `KEYB$SCAN`, `HELP_MENU`, and friends — none of
which is core code, and AExp has no `vdrives` for `HANDLE_IO` to service. There
is nowhere for a background flusher to live.

**The framework change: `HANDLE_CORE_IO`.** We added one new mandatory core
callback, called from inside `HANDLE_IO` (in `M2M/rom/shell.asm`, tagged
`M2M-UPSTREAM core-io-hook` for a later upstream merge). Where it sits matters:

> We hook it into **`HANDLE_IO`, not `MAIN_LOOP`.** `HANDLE_IO` is also polled
> from *every blocking wait loop* — while the OSM is open, during file browsing,
> on help screens. That is exactly the property a background flusher needs: the
> flush must keep running even while the user sits in a menu. A hook in
> `MAIN_LOOP` alone would freeze mid-flush whenever the OSM opened. This is the
> same reason C64MEGA65's `vdrives` flush is driven from `HANDLE_IO`.

The callback contract: preserve all registers (`SYSCALL enter/leave`), return
quickly (cooperative multitasking), may change the active RAMROM device/window.

`HANDLE_CORE_IO` does three floppy things per poll, all of them per drive:

1. **SD guards** — see [§9.3](#93-the-invariant-and-the-four-rules).
2. **Mount tracking** — on a `PARSEST = READY` rising edge for drive *n*,
   snapshot the Shell handle `HNDL_RM_FILES[n]` into that drive's own storage and
   set `WR_EN` in that drive's WBC, which makes the engine announce that unit
   writable to the Amiga.
3. **Exactly one background flush step**, handed to **one drive per poll in
   round-robin order**.

That round-robin is what keeps the cost flat: at most one drive does SD I/O per
time slice, so three armed drives cost the main loop exactly what one did, and
handing the next slice on keeps a continuously re-dirtied drive from starving the
others. A drive that is idle, or sitting behind its anti-thrashing gate, does not
consume the slice — the scan simply moves on. That is what the tri-state return
code of `FLUSH_ADF_STEP` is for: `ADF_FL_IDLE` (clean, nothing to do),
`ADF_FL_DID` (this call consumed the slice) and `ADF_FL_GATED` (work remains but
the gate is shut).

Two details of that scheduler are load-bearing, and both are easy to get subtly
wrong:

* **The chunk that finishes a track still reports `ADF_FL_DID`.** It has just
  written and flushed a full sector, so it spent the slice. Reporting "clean and
  idle" because the bitmap happens to be empty afterwards would make the scan
  read it as "this drive did nothing" and immediately serve the next drive in the
  same poll — three chunk writes where the budget allows one. Whether anything is
  left is answered for free by the next call, from the top of the routine.
* **The rotation moves on per TRACK, not per chunk.** The drive that was served
  keeps the slice until its session closes. Rotating after every chunk would flip
  the owner of the one shared sector buffer ([§8.5](#85-the-one-sector-buffer-everybody-shares))
  on every poll, and `FAT32$READ_FDH` answers an owner change with a full 512-byte
  **read** of the very sector it is about to overwrite completely — a wasted SD
  read per chunk. Per track that becomes at most one per eleven. Fairness is still
  bounded: a drive can hold the slice for one track at most, and its anti-thrash
  gate applies again at the next session start.

**`FLUSH_ADF_STEP`** takes the drive in `R9` and does at most one small step per
call, mirroring the `vdrives` `FLUSH_CACHE` discipline:

1. **Idle, dirty tracks pending, anti-thrash gate open?** Scan that drive's
   bitmap for the lowest set bit, **clear it first** (write-1-to-clear), then
   `f32_fseek` **that drive's retained file handle** to `track × 5632`. Session
   open.
2. **Active session?** Stream **512 bytes** from that drive's ADF byte-window to
   `f32_fwrite`, then `f32_fflush` the chunk. At track end, close the session.

Every drive carries its own session state (`ADF_FL_STATE`, `ADF_FL_REMAIN`,
`ADF_FL_BADDR_LO/HI`), so two drives can each have a track session open and the
poll that serves one of them simply resumes where that drive left off.

Several details are load-bearing:

- **Per-track, not whole-image.** `vdrives` rewrites the *entire* image on any
  dirty cache — fine for a 174 KB D64, but an 880 KB ADF would be painfully slow.
  We flush only the dirty tracks: a rename touches ~1–2 tracks (~5–11 KB), not
  880 KB. This is the single most important departure from the `vdrives`
  discipline and the reason writes feel instant.
- **Anti-thrashing.** A `2000 ms` countdown (the `VD_ANTI_THRASHING_DELAY` you
  already have in `config.vhd`, general-config word 13, `M2M$CFG_VD_AT_DELAY`)
  restarts on every write event; the flush only starts after that much write
  silence. Each drive has its own countdown, in its own WBC. It coalesces bursts,
  spares the SD card, and — a happy side effect — means the firmware almost never
  flushes a track that is *actively* being written.
- **`f32_fflush` after *every* 512-byte chunk.** This one has its own section:
  see [§8.5](#85-the-one-sector-buffer-everybody-shares).
- **FAT32 constraints.** The QNICE FAT32 library can only **overwrite in place**
  (no grow, no create) and writes **one byte per call**; the ADF flush is a
  fixed-size in-place overwrite, which is exactly what the library supports.
  `f32_fseek` walks the cluster chain from the file start, so flushing tracks in
  ascending order amortises the cost.
- **Errors are fatal**, the C64MEGA65 `FLUSH_CACHE` policy — with the SD-removal
  cases pre-guarded, because a stale handle must never reach `f32_fwrite`.

The disk's LED policy comes straight from `vdrives`: the MEGA65 drive LED is
forced on and turns **yellow** while any track of **any** drive is dirty
(`main_adf_any_dirty` is the OR across all three), back to **green** once the
last drive is clean — "do not power off yet."

### 8.5 The one sector buffer everybody shares

This is a single hardware fact with two consequences, and both of them look like
gratuitous paranoia until you know it:

> **There is exactly ONE 512-byte sector buffer in the machine — the SD
> controller's hardware buffer. The FAT32 library tracks its current owner in the
> device handle's `FAT32$DEV_BUFFERED_FDH` field, as the ADDRESS of the file
> handle that filled it, and `FAT32$FLUSH(h)` writes that buffer to `h`'s
> cluster/sector if and only if `h` has its `FAT32$FDH_FLAGS` DIRTY bit set.**

**Consequence 1: flush every chunk before returning.** Our chunk is 512 bytes and
every track start is 512-aligned, so each chunk is exactly one FAT32 sector. If
we left it buffered and dirty across a time slice, anyone else touching the SD
card in the meantime would collide with it — and plenty of code does, from the
very wait loops that also poll us. The file browser is the sharpest case:
`FAT32$DIR_OPEN` and `FAT32$FILE_OPEN` simply *claim* the buffer, overwriting the
owner field **without flushing the previous owner**, so a dirty sector of ours
would be silently stranded. The OSM settings save is the other case: it runs on a
**second device handle** for the same card (`CONFIG_DEVH`), which has its own
owner field that knows nothing about ours, while the hardware buffer underneath
is still the single one. And with three drives it is also what makes
**interleaved track sessions safe**: `df0` and `df1` can each have an open
session, and the poll that serves one of them always finds the shared buffer
clean. The explicit flush costs nothing — the sector is written exactly once
either way, just earlier.

**Consequence 2: the handle snapshot must not start out DIRTY.** When
`HANDLE_CORE_IO` snapshots the Shell's file handle for a drive
([§9](#9-the-arm-state-invariant-the-subtle-correctness-core)), it `memcpy`s the
12-word struct — and then clears `FAT32$FDH_FLAGS` immediately. The copy lives at
a *different address*, so it can never be the recorded buffer owner; but if it
inherited a DIRTY flag, the next `FAT32$FLUSH` through it would push whatever the
shared buffer currently holds — some other file's sector — into **this drive's**
cluster and sector. The Shell only ever reads through that handle, so in practice
the flag is clear anyway; clearing it makes the copy unambiguously "owns no
buffer" instead of relying on that.

### 8.6 Write-protect and the drive-status announce

The engine re-sends one drive-status word per poll cycle:
`0x10` followed by a **writable** nibble and a **present** nibble, one bit per
Amiga unit. For a simulated drive, `present` is that drive's `disk_mounted` and
`writable` is `disk_mounted AND WR_EN` — both taken from *that drive's* wrapper.
A unit backed by the Hardware Floppy reports `present` from the real disk-change
latch and is **never** announced writable (the real `/WPROT` level still reaches
CIA-A through the `paula_floppy` mux). A unit that is Off contributes nothing.

So a drive is write-protected until its own mount completes and arms, across SD
card changes, and while it is being remounted — and each drive's protection state
is independent of the others. When `WR_EN` is set, Paula's `_wprot` line reflects
it, `trackdisk` sees a writable disk, and `info df1:` reports `Read/Write`.

---

## 9. The arm-state invariant (the subtle correctness core)

If you read only one section of the write path for correctness, read this one.
An adversarial multi-agent review found **three critical bugs here**, all the
same root cause, and the fixes are subtle enough that they are worth spelling
out — a future maintainer *will* be tempted to "simplify" them. Everything below
holds **per drive**.

### 9.1 Why every drive needs its own file handle

The firmware needs the mounted ADF's FAT32 file handle to flush to it. The Shell
keeps one open per manual CRT/ROM id, in `HNDL_RM_FILES[n]`. It is tempting to
keep a single "the current ADF" handle in the core firmware — and with more than
one armed drive that is immediate, silent cross-drive corruption: the background
flush of drive 1 would push drive 1's tracks through whatever handle was stored
last, straight into **drive 0's file**, at offsets that mean something completely
different there.

So each drive owns a **full 12-word snapshot of its own** (`ADF_FDH0` /
`ADF_FDH1` / `ADF_FDH2`, reached through `ADF_FDH_TAB`), and so does every other
piece of write-back state: `ADF_FDH_VALID`, `ADF_SD_SLOT`, `ADF_MOUNT_SEEN`, the
flush session variables. A flush of drive *n* can then only ever reach the file
that was mounted into drive *n*.

### 9.2 Why the obvious arming plan is broken

The obvious plan is: "when a mount reaches `PARSEST = READY`, remember that
handle and arm `WR_EN`." The firmware does arm on a `PARSEST = READY` *rising
edge*, observed by polling from `HANDLE_CORE_IO` — but **the entire mount flow
runs without a single `HANDLE_IO` poll**. `LOAD_IMAGE` writes `ST_LDNG`, opens
the file, runs `PREP_LOAD_IMAGE`, streams the bytes and busy-waits for `READY`,
none of it polling `HANDLE_IO`. So on a disk *swap*, the
`READY → LOADING → READY` transient is completely invisible to the callback: by
the time the next `HANDLE_CORE_IO` runs, `PARSEST` is already `READY` again and
that drive's arm state still thinks it is armed from the *previous* disk. Worse,
the Shell re-opens `HNDL_RM_FILES[n]` for the new file *before* `PREP_LOAD_IMAGE`
runs — so the old handle is already gone.

Result without the fix: after a disk swap, writes to disk B get flushed through a
stale handle **into disk A's file** — silent corruption, and if B has more tracks
than A, a fatal seek-past-EOF.

### 9.3 The invariant and the four rules

> **The mount flow owns the arm state, not the `PARSEST` level — per drive.**

Concretely, in `m2m-rom.asm`:

1. **Disarm in `PREP_LOAD_IMAGE`.** Every ADF load first force-flushes the
   dirty tracks of the disk currently in *that* drive (ignoring the anti-thrash
   gate) and then calls `ADF_DISARM` for it: `WR_EN := 0`, snapshot invalidated,
   session aborted, arming edge re-opened. The new mount's `READY` re-arms with a
   *fresh* handle snapshot. The drive being loaded is identified by the menu
   group id the Shell hands the callback, resolved through `IS_ADF_GROUP`. The
   force-flush is bounded (so a machine that re-dirties forever cannot starve the
   OSM) and falls back to a non-fatal "drive busy" message.
2. **Keep our own handle snapshot**, taken at `READY` and immediately stripped of
   its DIRTY flag ([§8.5](#85-the-one-sector-buffer-everybody-shares)), because
   the Shell's handle for that drive is re-opened for the next load before we
   would otherwise notice.
3. **Block re-arming from a stale `READY`.** `PARSEST` stays `READY` across an
   SD-card change (nothing rewrites the CSR), and the Shell clears `SD_CHANGED`
   inside the mount flow. So an SD teardown sets that drive's `ADF_MOUNT_SEEN`
   flag to "blocked", which only `PREP_LOAD_IMAGE` — a real new load — clears.
   The dirty bitmap of a torn-down drive is wiped as well (`ADF_WIPE_DIRTY`):
   those tracks can no longer be written anywhere sensible, and leaving the bits
   set would make a *later* mount flush them into a different file.
4. **Guard the active SD slot, per drive.** The file browser's F1/F3 card switch
   updates the active slot *without* raising `SD_CHANGED`. So each drive
   snapshots the active-slot bit at arm time (`ADF_SD_SLOT`) and is torn down as
   soon as the current slot differs — never flushing onto a card its handle was
   not opened on.

The two SD guards differ in blast radius, and that difference is the point of
having both:

- A **card change** (`SD_CHANGED`) tears **every** drive down. The card the
  handles describe is physically gone.
- An **active-slot switch** tears down exactly the drives whose handle was
  snapshotted on the *other* slot. Every file handle points at the ONE shared
  device handle, which after the switch describes the other card, so a flush
  through it would write into whatever file happens to live at those clusters
  over there. Drives armed on the slot that is now active survive: with two cards
  in use, `df0` from slot 1 and `df1` from slot 2 are independent, and only one
  of them dies.

`ADF_UNMOUNT` (the SPACE eject) applies the same card-change guard before it
flushes, because it runs *before* the SD guard in `HANDLE_CORE_IO` and its FAT32
errors are fatal. On a change it discards that drive's dirty bitmap instead of
flushing it, then disarms.

### 9.4 One file, one drive

There is one more way to lose data that no amount of handle discipline can catch,
because both handles would be perfectly valid:

> **The same image file may not be mounted into two drives at once.**

Each drive streams its **own copy** of the image into its **own HyperRAM pool**.
Mount `game.adf` into `df0:` and `df1:` and you have two independent copies of the
same disk. The Amiga writes a high score through `df0:`, saves a config through
`df1:` — both drives collect their own dirty tracks, both flush to the same file,
and whichever flushes last overwrites what the other one saved. Nothing errors,
nothing is torn; one of the two changes just quietly ceases to exist. Worse, the
two copies then diverge from each other while the machine keeps running, because
neither drive ever re-reads the file.

So `PREP_LOAD_IMAGE` refuses the second mount. `ADF_DUP_CHECK` identifies the
file behind the fresh handle by its **FAT32 start cluster** (unique per file on a
card) plus its device handle, and compares that against every **armed** drive:

- the drive being loaded is skipped, obviously;
- an unarmed drive cannot write and retains no file identity anyway, so it is
  skipped too;
- a start cluster of 0 means an empty file and is not a usable identity, so it
  never counts as a match (an ADF can never get that far — the size gate runs
  first — but `0` equalling `0` must not be read as "the same file");
- comparing the start cluster alone is enough, because the guards of
  [§9.3](#93-the-invariant-and-the-four-rules) have already verified that every
  armed drive sits on the currently active SD slot, and the fresh handle was just
  opened on that same slot.

On a match the load is rejected with the `WRN_ADF_DUP` message, which explains
the "each drive collects its own changes" reason in end-user words. The drive
simply stays empty — the Shell has already unmounted it with `ST_LDNG` — and the
user gets the file browser back.

That rule has a corollary about the *other* end of a mount. A drive whose mode
leaves `Disk Image` — because the user gave the mechanism to it, or turned it
off, or reduced the drive count — has its mount line hidden by the menu
dependency, and with it the only gesture that could eject the disk. Left alone,
that drive would sit on a stranded, invisible, still-armed mount, and its file
would stay locked against every other drive: take the disk out of `df1:` by
turning `df1:` off, and you could no longer put it into `df0:`. So leaving
`Disk Image` mode **is** an eject. `DRV_EJECT_GONE`, called from `OSM_SEL_POST`
once the two consistency helpers have settled the model, walks the drives and
hands every drive that is no longer a Disk Image but still reports
`PARSEST = READY` to the same `ADF_UNMOUNT` the SPACE gesture uses — so whatever
was pending is flushed into the right file before the drive is disarmed.

---

## 10. Questions you are probably asking

These are the questions that came up naturally while bringing the feature up on
real hardware; a reader will ask the same ones.

### "The disk shows `Read/Write` in `info df0:` — does that already prove writing works?"

It proves the **arming half**, which is a real, non-trivial slice: the firmware
read `PARSEST = READY` for that drive, snapshotted its handle, set its `WR_EN`;
that bit crossed the CDC into the engine; the engine started announcing that unit
writable; Paula turned that into `_wprot`, and AmigaDOS reported `Read/Write`. If
any link in that chain were broken you would see `Read Only`.

It does **not** prove that an actual write is MFM-decoded, committed to HyperRAM
with correct byte order, flagged dirty, and flushed to the SD file with correct
bytes. `Read/Write` is the *precondition*, not the payoff. The payoff is proven
only by writing something, watching the LED go yellow → green, and verifying the
bytes independently (see [§11](#11-how-we-verified-it)).

### "Do we flush the whole 880 KB image, or only the changed tracks?"

**Only the changed tracks**, at track granularity (5632 bytes each). The dirty
bitmap has one bit per track; the engine sets a bit when it commits a sector; the
firmware flushes just the set bits, lowest first. A rename touches one or two
tracks, so we write ~5–11 KB, not 880 KB — roughly a 100× reduction. That is the
deliberate departure from `vdrives`' whole-image rewrite, and the reason the
"yellow phase" is short.

One clarification about that yellow phase: most of its ~2 seconds is the
**anti-thrashing debounce**, not the writing. The actual SD write of a track or
two is milliseconds. The yellow duration stays short *regardless of disk size*
because only changed tracks are touched. (Format is the visible opposite: every
track dirtied, so the LED stays yellow far longer as the firmware grinds through
all 160.)

### "What if a new dirty track arrives while QNICE is mid-flush? Or the very track being flushed is rewritten mid-flush?"

Benign in both cases, and it **cannot lose a write**. The foundation: the running
Amiga **never reads from the SD card** — it reads the image out of HyperRAM,
which the engine always keeps coherent at full-sector granularity. The SD is only
read once, at mount. So no flush race can hand the Amiga bad data; the worst a
race can do is briefly desynchronise the *SD copy* from HyperRAM, and that
reconciles itself.

- **A *different* track goes dirty mid-flush:** the bitmap is the work queue; the
  new bit is just picked up on a later pass. Its data is in a different HyperRAM
  region, and the arbiter serialises all HyperRAM accesses, so nothing collides.
- **The *same* track is rewritten mid-flush:** the firmware **clears the dirty
  bit before it reads the track**, so the rewrite's event **re-sets** the bit and
  the track is flushed again on a later pass — the update is never dropped. Even
  an exact same-cycle collision is safe: the hardware resolves a simultaneous
  set-and-clear in favour of the **set** (`wbc_dirty(v_track) <= '1'` is the last
  assignment in the WBC process). The in-flight flush may write a *torn* track to
  SD (some chunks old, some new), but the guaranteed re-flush overwrites it with a
  coherent copy. There is no sub-word tearing either — the arbiter serialises each
  access, so a firmware byte-read sees either the old 16-bit word or the new one,
  never half of each.

The single honest caveat is inherent to any write-back cache: **cut power during
the yellow window and the not-yet-flushed tail is lost** (HyperRAM is volatile
too). That is not corruption of anything the machine is using — it is the same as
pulling a real floppy while the drive light is on, which is precisely what the
yellow LED tells you not to do.

### "What happens when two drives are written at the same time?"

Nothing special, by construction, and it is worth walking through because it
touches three different mechanisms:

- **In the engine**, the two write drains cannot overlap: Paula serves one unit
  at a time and the drain is bound to `drain_unit`, which is aborted the moment a
  poll reports another unit ([§6.3](#63-unit-ownership-the-load-bearing-invariant)).
- **In the wrappers**, nothing is shared at all: each drive has its own dirty
  bitmap and its own anti-thrash countdown, in its own WBC.
- **In the firmware**, both drives are armed, both accumulate dirty tracks, and
  the round-robin flush hands the slice to one of them per poll — so the machine
  gets slower to finish, never busier per poll. Both can have a track session
  open simultaneously, which is safe purely because of the per-chunk flush
  discipline of [§8.5](#85-the-one-sector-buffer-everybody-shares).

The one configuration that is *not* allowed is the same *file* in two drives, and
that is refused at mount time — see
[§9.4](#94-one-file-one-drive).

---

## 11. How we verified it

**Static, before any synthesis:** `nvc --std=2008` analyses and *elaborates* the
whole CORE VHDL set (which proves the port maps and slice widths — including the
three wrapper instances, the packed 4-way arbiter interface and the vectored
engine ports), and the firmware assembles warning-free with a native-built
`qasm`. The ADF path needs no Verilog change.

**Synthesis gates (R3):** BRAM is full, so the decoded-write buffer `wrbuf` and
the read `secbuf` **must** infer as distributed LUTRAM (same strict simple-dual-
port template for both — watch for `Synth 8-7186`, "not inferred as ram due to
incorrect usage"); the ADF pools must stay ordered and guarded (`mega65.vhd`
asserts that at elaboration time, so a broken map fails the build rather than the
disk); `WNS ≥ 0`, with the global critical path expected to stay on the framework
HyperRAM PHY rather than on any of the new logic.

**The decisive hardware test** (worth reproducing for any future storage work,
because it removes every alternative explanation): rename a file in Workbench,
then **power off** for ten seconds (HyperRAM is volatile — gone), then **load a
*different* ADF** first (overwriting the HyperRAM pool so no stale bits can
linger), and only *then* mount the test disk again **using a read-only build** —
a build that physically contains no write logic at all. A read-only core can only
display what it streams off the SD card, so seeing the renamed file proves the
change is genuinely in the file on the card. That is an independent oracle: the
reader cannot possibly be the source of the change.

**Host-side verification (on the Mac):** `xdftool` (from `amitools`, `pip install
amitools`) or `unadf` inspects the ADF straight off the SD card — `xdftool
disk.adf list` to see the change, and a byte-compare of a renamed file against
the pristine original (a rename must leave the file's data blocks identical) to
confirm nothing else was disturbed. Booting the image in FS-UAE is the ultimate
cross-check: if AmigaOS mounts it without a "not validated" requester, the disk
passed the operating system's own bitmap validator.

**The hardware test matrix:** write-protect state before arming;
rename → power-cycle → verify; a known-content file written and read back;
disk-swap while dirty (the arm-state invariant); `format` as the every-track
stress case; and, for the multi-drive part, two drives dirtied and flushed
concurrently, a rejected duplicate mount, an eject of one drive while another is
mid-flush, and an F1/F3 card switch with drives armed on both slots.

**Menu-side cross-check:** `.research/check_osm_menu.py` recomputes the menu
geometry and the heap budgets from `config.vhd` and verifies every `C_MENU_*`
constant against the text of the line it addresses — which is what keeps the six
flat menu-line constants (`C_MENU_DF{0,1,2}_MOUNT_LN` / `_HW_LN`) honest, since
the firmware trusts them without rescanning the menu.

---

## 12. Reference

### File inventory

| File | Role |
|---|---|
| `CORE/vhdl/adf_track_engine.vhd` | The codec + protocol, one instance for all units. Poll FSM with per-unit dispatch, MFM **encoder** (read) and **decoder** (write), unit-tagged sector commit to HyperRAM, per-drive dirty-event scanner. Main clock domain. |
| `CORE/vhdl/adf_mount_wrapper.vhd` | One ADF device (three instances). Byte-window bridge into that drive's HyperRAM pool, `0xFFFF` mount CSR + size validator, `0xFFFE` write-back CSR (dirty bitmap, anti-thrash, `WR_EN`). |
| `CORE/vhdl/main.vhd` | Instantiates the engine + the shared `avm_cache` (with the mount-change invalidation); the `IO_FPGA` bus mux; the write-back and drive-configuration ports. |
| `CORE/vhdl/mega65.vhd` | The three mount wrappers (generate loop), the HyperRAM CDC/arbiter chain, the `cdc_stable` bundles, the Drive Settings decode, the flat menu-line constants, the drive-LED policy. |
| `CORE/vhdl/globals.vhd` | Single source of truth for the device ids, the guarded HyperRAM map, the ADF geometry and the manual CRT/ROM array (`C_CRTROMS_MAN`, order load-bearing). Scraped by `make_rom.sh`. |
| `CORE/vhdl/config.vhd` | The OSM: the three twin line pairs, the Drive Settings submenu, the mount groups and the menu dependencies. |
| `CORE/m2m-rom/m2m-rom.asm` | Firmware: `HANDLE_CORE_IO`, `FLUSH_ADF_STEP`, the per-drive tables and helpers (`ADF_SEL_WBC`, `ADF_DISARM`, `ADF_WIPE_DIRTY`, `ADF_DUP_CHECK`, `IS_ADF_GROUP`), the `PREP_LOAD_IMAGE` guards, the arm-state logic, `HANDLE_UNMOUNT_KEY` / `ADF_UNMOUNT`, `.ADF` filter + size guard. |
| `M2M/rom/shell.asm` | The `HANDLE_CORE_IO` hook in `HANDLE_IO` (`M2M-UPSTREAM core-io-hook`). |
| `M2M/rom/optm_deps.asm`, `menu.asm`, `options.asm` | The menu-dependency layer that swaps each drive's twin lines (`M2M-UPSTREAM osm-deps`) and `OPTM_LIVE_TEXT`, which patches the live status field into a hardware-drive TEXT line (`M2M-UPSTREAM live-text`). |
| `CORE/vhdl/physical_fdd/` | The Hardware Floppy read front-end — what a unit is backed by when it is not a simulated ADF drive. Out of scope here; the engine's per-unit dispatch is the only contact point. |
| `Main_MiSTer/support/minimig/minimig_fdd.cpp` | Upstream MiSTer reference (not in this repo) — bit-exact source for the encoder and decoder. |

### Per-drive device window map

Identical for all three devices (`0x0103` / `0x0105` / `0x0106`); only the device
id selects the drive.

| Window | Purpose |
|---|---|
| `0x0000..0x00E4` | Byte-window bridge into that drive's HyperRAM ADF image (1 file byte per QNICE word address, two bytes packed per HyperRAM word) |
| `0xFFFE` | Write-back CSR (WBC) — see below |
| `0xFFFF` | Framework mount CSR (`qnice_csr.vhd`) — `ST_LDNG` / size / `ST_OK` / `PARSEST` |

### Write-back CSR (window `0xFFFE`), QNICE-domain registers

Word offsets inside the window; the firmware reaches them at
`M2M$RAMROM_DATA` (`0x7000`) plus the offset, after `ADF_SEL_WBC` has pointed the
device/window selectors at the drive in question.

| Offset | Name | Access | Meaning |
|---|---|---|---|
| `0x000` | `WBC_CTRL` | R/W | bit 0 = `WR_EN` (announce this unit writable; commit gate) |
| `0x001` | `WBC_STAT` | RO | bit 0 = `any_dirty`, bit 1 = `flush_start` (anti-thrash expired) |
| `0x002` | `WBC_ATDELAY` | R/W | anti-thrash delay in ms (reset default `2000`) |
| `0x010..0x01A` | `WBC_DIRTY0..10` | R/W1C | dirty bitmap, track = `word × 16 + bit`; write-1-to-clear; a same-cycle hardware set wins over the clear |

### HyperRAM map (word addresses)

| Region | Windows | Purpose |
|---|---|---|
| `0x000000..0x1FFFFF` | 512 | M2M framework (`C_HMAP_M2M`); the ascal video framebuffer really needs 256 of them = 2 MB (triple-buffering off, must stay off) |
| `0x200000..0x272FFF` | 115 | `df0:` ADF image pool (`C_HMAP_ADF_DF0`); an `880 KB` image occupies words `0x200000..0x26DFFF` (`450560` words) |
| `0x273000..0x273FFF` | 1 | guard (`C_HMAP_ADF_DF0_GUARD`) |
| `0x280000..0x2F2FFF` | 115 | `df1:` ADF image pool (`C_HMAP_ADF_DF1`) |
| `0x2F3000..0x2F3FFF` | 1 | guard (`C_HMAP_ADF_DF1_GUARD`) |
| `0x300000..0x372FFF` | 115 | `df2:` ADF image pool (`C_HMAP_ADF_DF2`) |
| `0x373000..0x373FFF` | 1 | guard (`C_HMAP_ADF_DF2_GUARD`) |
| `0x3FF000..0x3FFFFF` | 1 | top-of-die guard (`C_HMAP_TOP_GUARD`): a burst past the last region must never wrap to `0x000000` |

Each drive owns a 128-window (1 MB) slot (`C_HMAP_ADF_SLOT`): 115 windows of
pool, one guard, and reserved slack kept deliberately inside the owning drive's
slot. `C_HMAP_ADF_POOLS` indexes the three bases by Amiga unit for the generate
loops.

### Clock domains and CDC inventory

| Element | Clock |
|---|---|
| `adf_track_engine` (codec, protocol, commit, dirty scanner) | `main_clk` `28.375 MHz` |
| WBC, size validator, byte-window bridge (×3) | `qnice_clk` `50 MHz` (falling edge) |
| HyperRAM Avalon + 4-way arbiter | `hr_clk` `100 MHz` |

CDCs: mount + write-back status of all three drives (`disk_mounted`, `tracks`,
`WR_EN`, `any_dirty`) in **one** 33-bit `cdc_stable` bundle (qnice → main) — the
drives are independent, so per-bit settling skew between them is harmless; the
dirty-event handshake (shared track payload + three `req` toggles main → qnice,
three `ack` toggles qnice → main) with the two-phase toggle discipline; the
HyperRAM Avalon crossings via `avm_fifo` (one per wrapper, plus one for the
engine chain). All covered by the framework's `cdc_stable` `set_max_delay`
constraint.

### MFM sector on the wire (544 words)

See [§3](#3-mfm-how-512-bytes-of-data-become-1088-bytes-of-flux) for the table.
On write the decoder consumes `1` (matched sync) + `25` (header) + `516` (data)
= `542` words per sector; the preamble/gap words are eaten by the sync hunt.

---

## 13. Glossary for M2M coders

- **Paula** — the Amiga custom chip handling audio and the floppy. Its floppy
  side is a dumb raw-MFM DMA engine; it does *not* understand sectors.
- **Agnus** — the custom chip that owns DMA; it moves Paula's flux words to/from
  Chip RAM on DMA slots.
- **CIA** — the two 8520 I/O chips. Floppy control lines (motor, step, index,
  write-protect, disk-change) hang off CIA ports; `_wprot` reaches software here.
- **Unit / `df0:` `df1:` `df2:`** — the Amiga's drive numbers. Paula carries the
  selected unit in the `sel` field of its status word, and in AExp that number is
  also the drive index used everywhere else (see
  [§6.1](#61-the-drive-index-is-one-number-for-everything)).
- **`trackdisk.device`** — the Kickstart driver that does the MFM codec on the
  68000. On AExp its job is split between `adf_track_engine` and QNICE firmware.
- **MFM** — Modified Frequency Modulation, the on-disk flux encoding. The Amiga's
  variant splits each long word into odd-bit and even-bit halves.
- **`DSKSYNC` / `0x4489`** — the sync word Paula hunts for to find sector starts.
- **`DSKLEN` / `DMACON`** — Paula registers that arm and size disk DMA. Writing
  them is what triggers a track read or write.
- **ADF** — Amiga Disk File: the decoded 880 KB image (all sectors concatenated),
  the Amiga's D64 equivalent. No MFM.
- **Cylinder / track / head / sector** — 80 cylinders × 2 heads = 160 tracks; 11
  sectors × 512 bytes per track.
- **Kickstart** — the Amiga ROM OS (we load 1.3). It runs a `RESET` instruction on
  every reboot, which wipes Paula's `disk_present` — hence the per-poll
  re-announce.
- **Workbench / AmigaDOS** — the GUI and the CLI/filesystem layer above Kickstart.
- **OFS / FFS** — Old / Fast File System, the two AmigaDOS floppy filesystems.
  Standard 880 KB floppies are OFS.
- **fx68k** — the cycle-exact 68000 core AExp uses.
- **OCS / ECS / AGA** — Amiga chipset generations. AExp is OCS (Amiga 500) only.
- **Chip RAM / Slow RAM** — the 512 KB + 512 KB the Amiga 500 addresses; both live
  in FPGA BRAM here, which is why the disk images must live in HyperRAM instead.
