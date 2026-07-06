# Floppy disks on the Amiga: how AExp reads and writes ADF images

This is the design-and-rationale document for the AExp floppy subsystem —
read-only ADF mounting (shipped 2026-07-03) and full read/write support
(shipped 2026-07-05). It merges and supersedes the two internal integration
specs.

It is written for a coder who **knows the MiSTer2MEGA65 (M2M) framework but
has never touched an Amiga**. The Amiga floppy is the single most un-M2M-like
subsystem in the whole port: it does not look like a disk drive, it cannot use
the framework's `vdrives` system, and almost every design decision is forced by
a hardware reality that has no analogue in the C64 or the other M2M cores. So
this document spends real effort teaching the Amiga side before explaining what
we built. If you only want the register maps, jump to
[§11 Reference](#11-reference).

## Table of contents

1. [The one idea you must accept first: the Amiga has no sectors](#1-the-one-idea-you-must-accept-first-the-amiga-has-no-sectors)
2. [Amiga floppy geometry and the ADF file](#2-amiga-floppy-geometry-and-the-adf-file)
3. [MFM: how 512 bytes of data become ~1088 bytes of flux](#3-mfm-how-512-bytes-of-data-become-1088-bytes-of-flux)
4. [The MiSTer/minimig model, and how AExp differs](#4-the-mistermimig-model-and-how-aexp-differs)
5. [Why we could **not** use the `vdrives` system](#5-why-we-could-not-use-the-vdrives-system)
6. [The read path (Milestone 1)](#6-the-read-path-milestone-1)
7. [The write path (Milestone 2)](#7-the-write-path-milestone-2)
8. [The arm-state invariant (the subtle correctness core)](#8-the-arm-state-invariant-the-subtle-correctness-core)
9. [Questions you are probably asking](#9-questions-you-are-probably-asking)
10. [How we verified it](#10-how-we-verified-it)
11. [Reference](#11-reference)
12. [Glossary for M2M coders](#12-glossary-for-m2m-coders)

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
outside that range is rejected at mount time.

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

 the "medium"    magnetic surface      ADF file on SD         ADF image in HyperRAM
                                       (read by the ARM)      (served by the engine)

 persistence     —                     ARM writes the ADF     QNICE firmware flushes
                                        file directly          dirty tracks to the ADF
```

The split is deliberate and is the key architectural decision:

- **The timing-touchy part — the MFM codec and the Paula host protocol — is
  FPGA logic** (`adf_track_engine.vhd`), running in the `28.375 MHz` main clock
  domain right next to Paula. It has to keep Paula's FIFO fed on reads and drain
  it on writes; putting it in hardware keeps that loop local and fast.
- **The slow part — persisting to the SD card — is QNICE firmware**, running in
  the QNICE domain, using the FAT32 library. SD I/O is milliseconds-slow and has
  no place near Paula's flux timing.
- **The "medium" is HyperRAM.** The mounted disk image lives there. Reads serve
  from it; writes commit to it. Think of HyperRAM as the magnetic surface and
  the SD file as the archival backing store.

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
[§4](#4-the-mistermimig-model-and-how-aexp-differs), the Amiga floppy speaks raw
MFM over the `IO_FPGA` **floppy host channel**, not a block protocol — a legacy
of MiSTer's minimig, where the ARM's `HandleFDD` services that channel directly
and the MiSTer block interface is bypassed for floppies entirely. There are no
block-request wires coming out of Paula for `vdrives` to connect to. The thing
`vdrives` translates simply does not exist on this core.

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
what our problem needs — we too have a HyperRAM-resident image that wants lazy,
safe SD persistence. So we **transplanted the discipline onto our own device**,
reusing even its `config.vhd` constants (the `2000 ms` anti-thrashing delay),
while replacing the block bridge with the floppy host channel + MFM codec.

> **The lesson:** when a framework system does not fit, separate its *mechanism*
> from its *pattern*. We rejected the `vdrives` mechanism and copied the
> `vdrives` pattern. That distinction is why the write path looks familiar to a
> C64MEGA65 reader even though not one wire of `vdrives.vhd` is involved.

---

## 6. The read path (Milestone 1)

Read support has two halves that meet at HyperRAM: **mount** (get the ADF into
HyperRAM, at load time) and **serve** (feed Paula from HyperRAM, at run time).

```
 MOUNT (load time)                          SERVE (run time)
 =================                          ================
 OSM " ADF:" selector                       Kickstart writes DSKLEN/DMACON
   -> Shell file browser (.adf filter)        -> Paula arms disk DMA (read)
   -> streams bytes to QNICE device 0x0103   adf_track_engine (main clk):
      = adf_mount_wrapper                       polls Paula over IO_FPGA,
   -> qnice2hyperram + avm_fifo (CDC)           fetches the sector from HyperRAM,
   -> HyperRAM at word 0x200000 (= 4 MB)        MFM-encodes it, pushes 544 words
   -> CSR handshake: size check, track          into Paula's 2048-word FIFO with
      count, READY/ERROR back to the Shell       status-bit-8 flow control
```

### 6.1 Mount: getting the ADF into HyperRAM

The user opens the OSM, picks an `.adf`, and the Shell streams it byte by byte
into a QNICE device. Three choices here are non-obvious:

**Why HyperRAM, not BRAM.** The Amiga's Chip/Slow/Kickstart RAM already fills
the FPGA's block RAM to `363.5 / 365` tiles — there is no room for an 880 KB
disk image in BRAM. The ADF lives in HyperRAM at word address `0x200000`
(the `4 MB` mark; the `0..2 MB` region is the ascal video framebuffer). This is
the same "big buffers live in HyperRAM" rule that governs the whole port.

**Why `C_CRTROMTYPE_DEVICE`, not `C_CRTROMTYPE_HYPERRAM`.** M2M has a manual-load
type that streams straight into HyperRAM, which looks perfect and is a trap. The
Shell's completion handshake (`HANDLE_CRTROM_M`) runs a CSR protocol against 4k
window `0xFFFF` of the *streaming device*. For the HYPERRAM type that "device"
is raw HyperRAM, whose window `0xFFFF` maps into HyperRAM *register* space —
there is no responder, and the Shell's parse-status poll has **no timeout**, so
it hangs forever. C64MEGA65 ships the DEVICE type with a core-side CSR for
exactly this reason; we mirror the shipping pattern. Our device is `0x0103`
(`C_DEV_AMIGA_ADF`), implemented in `adf_mount_wrapper.vhd`.

**The CSR handshake** is the familiar CRT/ROM loader dance, reused verbatim: the
Shell writes `ST_LDNG` before streaming, then the file size and `ST_OK`, then
polls `PARSEST` until the core answers `READY` or `ERROR`. Our "parser" is a
trivial size validator in the QNICE domain: it divides the file size by `5632`
by iterative subtraction and accepts exactly `160..166` tracks, rejecting
anything else with an "Invalid ADF size" string in the OSM. On success it
exposes `disk_mounted` and `tracks_total`, both CDC'd to the main clock via
`cdc_stable`.

The seconds-long streaming of a *new* mount is also the **disk-eject window**:
`disk_mounted` drops the moment the Shell starts the next load, which is how
Kickstart's disk-change logic notices an ADF swap.

### 6.2 Serve: `adf_track_engine`

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
depend on.

**The Avalon read chain** is the C64 REU pattern: the engine issues single-word
reads into an `avm_cache` (8-word cache line) → `avm_fifo` (main → HyperRAM CDC)
→ `avm_arbit` (shares HyperRAM with the mount wrapper) → `hr_core_*`. The cache
amortises the sequential reads into one HyperRAM burst per eight words. The cache
is held in reset whenever nothing is mounted or the Amiga resets, so stray
in-flight responses from an aborted fetch are discarded.

---

## 7. The write path (Milestone 2)

### 7.1 The mirror insight

Here is the payoff of understanding the read path: **writing is reading run
backwards.** When the Amiga writes a track, Paula's disk DMA streams raw MFM
words *out* over the same `IO_FPGA` host channel. The protocol is identical; only
the direction of the data words reverses. So the write path is not a new
subsystem — it is a new consumer of the same frames.

There is a subtlety that made the read-only build already half-ready for this.
Even read-only, the engine had to **drain** Amiga writes, because of a hard
safety rule:

> **Paula's write DMA completes (raises `DSKBLK`) only when `dsklen` has expired
> AND the FIFO is empty. If the host never drains the write FIFO, Agnus stalls,
> the DMA never finishes, and the machine hangs forever.**

So the read-only engine had a `WDRAIN` state that popped and *discarded* write
words purely to keep the machine alive. Write support is, at its core, replacing
"discard" with "decode and commit."

### 7.2 The MFM write decoder

The decoder is the bit-exact inverse of the encoder, transcribed from
`minimig_fdd.cpp`'s `FindSync` / `GetHeader` / `GetData`. It runs as a small
mode machine (`HUNT` → `HDR` → `DATA`) layered onto the existing drain loop:

- **HUNT** (`FindSync`): pop words until one equals the literal `0x4489`. Note:
  the write path syncs on the **literal** `0x4489`, *not* the live `dsksync`
  register (MiSTer parity — custom-sync writers are unsupported, as on real
  MiSTer).
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
Avalon chain the reads use. `avm_cache` is **write-through**: a write hit updates
the cache line, so a subsequent read of that sector stays coherent. A sector that
fails any gate is **drained but never committed** — exactly how MiSTer treats a
write to a protected disk (the data must still be consumed, or the machine
hangs).

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

### 7.3 Getting "it's dirty" from the core to the firmware

Now a genuinely new problem the read path never had: **the core must tell the
QNICE firmware that a track changed**, so the firmware can flush it.

Your first instinct as an M2M coder is `qnice_gp_reg`. It does not work: that
register is the QNICE SoC's `control_d_o` — it is **QNICE → core only**. The
reverse-direction registers `M2M$SPECIAL` / `M2M$GENERAL` exist but are tied to
`'0'` in the framework. **There is no existing core → QNICE signalling path.**

So we built one, out of parts you already know:

- **Our own register window.** Device `0x0103` already owns the `0xFFFF` CSR
  window; we carved out **window `0xFFFE`** for a small "write-back CSR" (WBC) —
  a `WR_EN` bit, a `166`-bit per-track **dirty bitmap**, an anti-thrashing delay
  register, and a status register. The firmware polls it exactly like it polls a
  `vdrives` register.
- **A two-phase toggle handshake for the events.** When the engine commits a
  sector it must set that track's dirty bit, but the bit lives in the QNICE
  domain. So the engine holds the track number stable, waits ~1 µs, *then* flips
  a `req` toggle; the wrapper sets the bit and flips an `ack` toggle back.
  Because `cdc_stable` only propagates a value once it is stable, and the payload
  is held put for the whole round trip, the toggle can never arrive alongside a
  torn track number. Events are milliseconds apart (a sector's MFM takes that
  long to stream in), so the microsecond handshake is never a bottleneck. The
  engine clears its *pending* bit **before** starting the handshake, so a
  re-dirty during the handshake generates a fresh event rather than being lost.

**Why the bitmap is per-*track*** (166 bits) rather than per-sector: the Amiga's
`trackdisk.device` rewrites a *whole track* even to change one block (read track,
edit, write track), so all 11 sectors stream through the decoder anyway.
Per-track keeps the bitmap tiny, keeps every SD seek 512-aligned
(`track × 5632`), and — as [§9](#9-questions-you-are-probably-asking) explains —
is why flushing is fast.

### 7.4 The firmware: persisting dirty tracks to the SD card

Now the second new problem: **the Shell's main loop has no core-specific hook.**
`MAIN_LOOP` calls `HANDLE_IO`, `KEYB$SCAN`, `HELP_MENU`, and friends — none of
which is core code, and AExp has no `vdrives` for `HANDLE_IO` to service. There
is nowhere for a background flusher to live.

**The framework change: `HANDLE_CORE_IO`.** We added one new mandatory core
callback, called from inside `HANDLE_IO` (in `M2M/rom/shell.asm`, tagged
`M2M-UPSTREAM core-io-hook` for a later upstream merge). It is the write path's
only framework modification, and where it sits matters:

> We hook it into **`HANDLE_IO`, not `MAIN_LOOP`.** `HANDLE_IO` is also polled
> from *every blocking wait loop* — while the OSM is open, during file browsing,
> on help screens. That is exactly the property a background flusher needs: the
> flush must keep running even while the user sits in a menu. A hook in
> `MAIN_LOOP` alone would freeze mid-flush whenever the OSM opened. This is the
> same reason C64MEGA65's `vdrives` flush is driven from `HANDLE_IO`.

The callback contract: preserve all registers (`SYSCALL enter/leave`), return
quickly (cooperative multitasking), may change the active RAMROM device/window.

**`FLUSH_ADF_STEP`** is the resumable flush, one small step per call, mirroring
the `vdrives` `FLUSH_CACHE` discipline:

1. **Idle, dirty tracks pending, anti-thrash gate open?** Scan the bitmap for the
   lowest set bit, **clear it first** (write-1-to-clear), then `f32_fseek` the
   retained file handle to `track × 5632`. Session open.
2. **Active session?** Stream **512 bytes** from the ADF byte-window
   (device `0x0103`) to `f32_fwrite`, then `f32_fflush` the chunk. At track end,
   close the session.

Several details are load-bearing:

- **Per-track, not whole-image.** `vdrives` rewrites the *entire* image on any
  dirty cache — fine for a 174 KB D64, but an 880 KB ADF would be painfully slow.
  We flush only the dirty tracks: a rename touches ~1–2 tracks (~5–11 KB), not
  880 KB. This is the single most important departure from the `vdrives`
  discipline and the reason writes feel instant.
- **Anti-thrashing.** A `2000 ms` countdown (the `VD_ANTI_THRASHING_DELAY` you
  already have in `config.vhd`, general-config word 13, `M2M$CFG_VD_AT_DELAY`)
  restarts on every write event; the flush only starts after that much write
  silence. It coalesces bursts, spares the SD card, and — a happy side effect —
  means the firmware almost never flushes a track that is *actively* being
  written.
- **`f32_fflush` after *every* 512-byte chunk.** The SD controller has a single
  hardware sector buffer shared with every other SD user (the OSM settings save
  runs from the very wait loops that also poll us). Leaving a dirty buffered
  sector across time slices would let a settings save clobber it, and vice
  versa. Flushing each sector-aligned chunk keeps that buffer clean. It costs
  nothing: the sector is written exactly once either way.
- **FAT32 constraints.** The QNICE FAT32 library can only **overwrite in place**
  (no grow, no create) and writes **one byte per call**; the ADF flush is a
  fixed-size in-place overwrite, which is exactly what the library supports.
  `f32_fseek` walks the cluster chain from the file start, so flushing tracks in
  ascending order amortises the cost.

The disk's LED policy comes straight from `vdrives`: the MEGA65 drive LED is
forced on and turns **yellow** while any track is dirty, back to **green** once
the flush completes — "do not power off yet."

### 7.5 Write-protect and the drive-status announce

The engine announces the drive as writable (`0x1011`) only while the firmware
has armed `WR_EN`; otherwise it announces write-protected (`0x1001`), and the
`WDRAIN` path drains-and-discards. The disk is therefore write-protected until a
mount completes and arms, across SD-card changes, and while remounting. When
`WR_EN` is set, Paula's `_wprot` line reflects it, `trackdisk` sees a writable
disk, and `info df0:` reports `Read/Write`.

---

## 8. The arm-state invariant (the subtle correctness core)

If you read only one section of the write path for correctness, read this one.
An adversarial multi-agent review found **three critical bugs here**, all the
same root cause, and the fixes are subtle enough that they are worth spelling
out — a future maintainer *will* be tempted to "simplify" them.

**The setup.** The firmware needs the mounted ADF's FAT32 file handle to flush
to it. The Shell keeps that handle open in `HANDLE_RM_FILE1`. The obvious plan:
"when a mount reaches `PARSEST = READY`, remember that handle and arm `WR_EN`."

**Why the obvious plan is broken.** The firmware arms on a `PARSEST = READY`
*rising edge*, observed by polling from `HANDLE_CORE_IO`. But **the entire mount
flow runs without a single `HANDLE_IO` poll** — `LOAD_IMAGE` writes `ST_LDNG`,
opens the file, runs `PREP_LOAD_IMAGE`, streams the bytes, and busy-waits for
`READY`, none of it polling `HANDLE_IO`. So on a disk *swap*, the
`READY → LOADING → READY` transient is completely invisible to the callback: by
the time the next `HANDLE_CORE_IO` runs, `PARSEST` is already `READY` again and
the arm state still thinks it is armed from the *previous* disk. Worse, the Shell
re-opens `HANDLE_RM_FILE1` for the new file *before* `PREP_LOAD_IMAGE` runs — so
the old handle is already gone.

Result without the fix: after a disk swap, writes to disk B get flushed through a
stale handle **into disk A's file** — silent corruption, and if B has more tracks
than A, a fatal seek-past-EOF.

**The fix, and the invariant it enforces:**

> **The mount flow owns the arm state, not the `PARSEST` level.**

Concretely, in `m2m-rom.asm`:

1. **Disarm in `PREP_LOAD_IMAGE`.** Every ADF load first force-flushes the old
   disk's dirty tracks (ignoring the anti-thrash gate) and then *disarms*
   (`WR_EN := 0`, snapshot invalidated). The new mount's `READY` re-arms with a
   *fresh* handle snapshot. The force-flush is bounded (so a machine that
   re-dirties forever cannot starve the OSM) and falls back to a non-fatal "drive
   busy" message.
2. **Keep our own handle snapshot** (`ADF_FDH`, a 12-word copy taken at
   `READY`), because the Shell's `HANDLE_RM_FILE1` is re-opened for the next load
   before we would otherwise notice.
3. **Block re-arming from a stale `READY`.** `PARSEST` stays `READY` across an
   SD-card change (nothing rewrites the CSR), and the Shell clears `SD_CHANGED`
   inside the mount flow. So the SD teardown sets a "blocked" flag that only
   `PREP_LOAD_IMAGE` (a real new load) clears.
4. **Guard the active SD slot.** The file browser's F1/F3 card switch updates the
   active slot *without* raising `SD_CHANGED`. So the firmware snapshots the
   active-slot bit at arm time and tears down whenever the current slot differs —
   never flushing onto a card the handle was not opened on.

A fourth confirmed finding, unrelated to arming: the shared SD sector buffer race
that forces the per-chunk `f32_fflush` in [§7.4](#74-the-firmware-persisting-dirty-tracks-to-the-sd-card).

---

## 9. Questions you are probably asking

These are the questions that came up naturally while bringing the feature up on
real hardware; a reader will ask the same ones.

### "The disk shows `Read/Write` in `info df0:` — does that already prove writing works?"

It proves the **arming half**, which is a real, non-trivial slice: the firmware
read `PARSEST = READY`, snapshotted the handle, set `WR_EN`; that bit crossed the
CDC into the engine; the engine started announcing the drive writable (`0x1011`);
Paula turned that into `_wprot`, and AmigaDOS reported `Read/Write`. If any link
in that chain were broken you would see `Read Only`.

It does **not** prove that an actual write is MFM-decoded, committed to HyperRAM
with correct byte order, flagged dirty, and flushed to the SD file with correct
bytes. `Read/Write` is the *precondition*, not the payoff. The payoff is proven
only by writing something, watching the LED go yellow → green, and verifying the
bytes independently (see [§10](#10-how-we-verified-it)).

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

---

## 10. How we verified it

**Static, before any synthesis:** `nvc --std=2008` analyses and *elaborates* the
whole CORE VHDL set (which proves the port maps and slice widths, including the
new engine/wrapper ports), and the firmware assembles warning-free with a
native-built `qasm`. No Verilog changed for the write path.

**Synthesis gates (R3):** BRAM must stay exactly `363.5 / 365` (the decoded-write
buffer `wrbuf` must infer as distributed LUTRAM, same strict template as the read
`secbuf` — watch for `Synth 8-7186`); `WNS ≥ 0`. The write build landed at
`WNS +0.112 ns`, BRAM unchanged, all constraints met, with the global critical
path still on the framework HyperRAM PHY — none of the new logic near critical.

**The decisive hardware test** (worth reproducing for any future storage work,
because it removes every alternative explanation): rename a file in Workbench,
then **power off** for ten seconds (HyperRAM is volatile — gone), then **load a
*different* ADF** first (overwriting the HyperRAM ADF region so no stale bits can
linger), and only *then* mount the test disk again **using the read-only Alpha 3
build** — a build that physically contains no write logic at all. A read-only
core can only display what it streams off the SD card, so seeing the renamed file
proves the change is genuinely in the file on the card. That is an independent
oracle: the reader cannot possibly be the source of the change.

**Host-side verification (on the Mac):** `xdftool` (from `amitools`, `pip install
amitools`) or `unadf` inspects the ADF straight off the SD card — `xdftool
disk.adf list` to see the change, and a byte-compare of a renamed file against
the pristine original (a rename must leave the file's data blocks identical) to
confirm nothing else was disturbed. Booting the image in FS-UAE is the ultimate
cross-check: if AmigaOS mounts it without a "not validated" requester, the disk
passed the operating system's own bitmap validator.

**The full hardware test matrix:** write-protect state before arming;
rename → power-cycle → verify; a known-content file written and read back;
disk-swap while dirty (the arm-state invariant); and `format` as the every-track
stress case.

---

## 11. Reference

### File inventory

| File | Role |
|---|---|
| `CORE/vhdl/adf_track_engine.vhd` | The codec + protocol. Poll FSM, MFM **encoder** (read) and **decoder** (write), sector commit to HyperRAM, dirty-event scanner. Main clock domain. |
| `CORE/vhdl/adf_mount_wrapper.vhd` | QNICE device `0x0103`. Byte-window bridge into HyperRAM, `0xFFFF` mount CSR + size validator, `0xFFFE` write-back CSR (dirty bitmap, anti-thrash, `WR_EN`). |
| `CORE/vhdl/main.vhd` | Instantiates the engine + `avm_cache`; the `IO_FPGA` bus mux; the write-back ports. |
| `CORE/vhdl/mega65.vhd` | Instantiates the mount wrapper, the HyperRAM CDC/arbiter chain, the `cdc_stable` bundles, the drive-LED policy. |
| `CORE/m2m-rom/m2m-rom.asm` | Firmware: `HANDLE_CORE_IO`, `FLUSH_ADF_STEP`, the `PREP_LOAD_IMAGE` guard, the arm-state logic, `.ADF` filter + size guard. |
| `M2M/rom/shell.asm` | The one framework change: the `HANDLE_CORE_IO` hook in `HANDLE_IO` (`M2M-UPSTREAM core-io-hook`). |
| `Main_MiSTer/support/minimig/minimig_fdd.cpp` | Upstream MiSTer reference (not in this repo) — bit-exact source for the encoder and decoder. |

### Device `0x0103` window map

| Window | Purpose |
|---|---|
| `0x0000..0x00E4` | Byte-window bridge into the HyperRAM ADF image (1 file byte per QNICE word address, two bytes packed per HyperRAM word) |
| `0xFFFE` | Write-back CSR (WBC) — see below |
| `0xFFFF` | Framework mount CSR (`qnice_csr.vhd`) — `ST_LDNG` / size / `ST_OK` / `PARSEST` |

### Write-back CSR (window `0xFFFE`), QNICE-domain registers

| Offset | Name | Access | Meaning |
|---|---|---|---|
| `0x000` | `WBC_CTRL` | R/W | bit 0 = `WR_EN` (announce df0 writable; commit gate) |
| `0x001` | `WBC_STAT` | RO | bit 0 = `any_dirty`, bit 1 = `flush_start` (anti-thrash expired) |
| `0x002` | `WBC_ATDELAY` | R/W | anti-thrash delay in ms (reset default `2000`) |
| `0x010..0x01A` | `WBC_DIRTY0..10` | R/W1C | dirty bitmap, track = `word × 16 + bit`; write-1-to-clear; a same-cycle hardware set wins over the clear |

### HyperRAM map (word addresses)

| Region | Words | Purpose |
|---|---|---|
| `0x000000..0x1FFFFF` | 2 MB | ascal video framebuffer (triple-buffering off, must stay off) |
| `0x200000..` | 4 MB region | ADF image (`C_HMAP_ADF_DF0`); an `880 KB` image occupies words `0x200000..0x26DFFF` (`450560` words) |
| `0x280000..` | reserved | future `df1` (`C_HMAP_ADF_DF1`) |

### Clock domains and CDC inventory

| Element | Clock |
|---|---|
| `adf_track_engine` (codec, protocol, commit, dirty scanner) | `main_clk` `28.375 MHz` |
| WBC, size validator, byte-window bridge | `qnice_clk` `50 MHz` (falling edge) |
| HyperRAM Avalon + arbiter | `hr_clk` `100 MHz` |

CDCs: mount + write-back status (`disk_mounted`, `tracks`, `WR_EN`,
`any_dirty`) via one `cdc_stable` bundle (qnice → main); the dirty-event
handshake (track + `req` main → qnice, `ack` qnice → main) via three small
`cdc_stable` instances with the two-phase toggle discipline; the HyperRAM
Avalon crossings via `avm_fifo`. All covered by the framework's `cdc_stable`
`set_max_delay` constraint.

### MFM sector on the wire (544 words)

See [§3](#3-mfm-how-512-bytes-of-data-become-1088-bytes-of-flux) for the table.
On write the decoder consumes `1` (matched sync) + `25` (header) + `516` (data)
= `542` words per sector; the preamble/gap words are eaten by the sync hunt.

---

## 12. Glossary for M2M coders

- **Paula** — the Amiga custom chip handling audio and the floppy. Its floppy
  side is a dumb raw-MFM DMA engine; it does *not* understand sectors.
- **Agnus** — the custom chip that owns DMA; it moves Paula's flux words to/from
  Chip RAM on DMA slots.
- **CIA** — the two 8520 I/O chips. Floppy control lines (motor, step, index,
  write-protect, disk-change) hang off CIA ports; `_wprot` reaches software here.
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
  in FPGA BRAM here, which is why the disk image must live in HyperRAM instead.
