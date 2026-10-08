# The Hardware Floppy: how AExp reads and writes real Amiga disks

This is the design-and-rationale document for the **Hardware Floppy**: the
MEGA65's own internal 3.5" mechanism acting as a genuine Amiga drive, reading
and writing real DD disks, copy-protected originals included. The user-facing
story (how to switch it on, the write-protect tab, what to expect from old
media) is on [the Hardware Floppy page](../hardware_floppy.md) and is not
repeated here; this document is about how the thing is built and why.

It is written for an FPGA developer who knows the MiSTer2MEGA65 (M2M)
framework and the MEGA65, but who is **not an Amiga floppy expert**. The
Amiga side is taught as far as the design decisions need it, and no further.
The companion document [Floppy disks on the Amiga: how AExp reads and writes
ADF images](floppy-adf.md) covers the *simulated* drives; the parts the two
features share (the track engine, the Paula host channel, unit ownership, the
drive index) are explained there and only referenced here.

The design described is the one in the current tree (`WIP-V2-B1`, diagnostics
map `0x000D`).

## Table of contents

1. [What the Hardware Floppy is, and what it is not](#1-what-the-hardware-floppy-is-and-what-it-is-not)
2. [What a real Amiga does with a floppy](#2-what-a-real-amiga-does-with-a-floppy)
3. [Why Minimig needed three new surfaces](#3-why-minimig-needed-three-new-surfaces)
4. [The read chain](#4-the-read-chain)
5. [Copylock and the DSKBYTR observation surface](#5-copylock-and-the-dskbytr-observation-surface)
6. [The write datapath](#6-the-write-datapath)
7. [Clock domains and CDC](#7-clock-domains-and-cdc)
8. [The diagnostics device](#8-the-diagnostics-device)
9. [When a user reports a problem](#9-when-a-user-reports-a-problem)
10. [Questions you are probably asking](#10-questions-you-are-probably-asking)
11. [How it was verified](#11-how-it-was-verified)
12. [Reference](#12-reference)
13. [Glossary](#13-glossary)

---

## 1. What the Hardware Floppy is, and what it is not

A MEGA65 has one 34-pin PC-style floppy mechanism on its internal cable. The
Hardware Floppy feature hands that mechanism to the simulated Amiga as one of
its drive units, `df0:`, `df1:` or `df2:`, chosen in the OSM's **Drive
Settings** submenu. From the Amiga's point of view the unit is simply a disk
drive: Kickstart steps it, spins it, reads flux from it and writes flux to it
exactly as it would on a real A500, and the drive sounds are the real ones.

The limits follow from the hardware and from deliberate decisions:

* **DD media only.** Amiga disks are double density, 2 µs channel cells at
  300 RPM. A PC HD mechanism cannot read Amiga HD disks at all (those spin at
  150 RPM in a real Amiga), so HD is out of scope, and the density pin is
  held at the DD level permanently.
* **At most one unit.** There is one mechanism, so exactly one of the three
  Amiga units can be the Hardware Floppy at a time; the drive-map decoder
  enforces this even if the menu state were inconsistent.
* **The disk's write-protect tab is the only write guard.** There is no OSM
  switch and no runtime disable: if the tab window is closed and a program
  writes, the disk is written. The core adds safety *around* a write (a
  qualified tab reading, latched aborts, a hard-gated WGATE), never a policy
  layer on top of it. This was a deliberate decision, and the user page says
  so in plain words.
* **The drive is physically writable.** The four board tops route `f_wdata`
  and `f_wgate` from the core instead of tying them inactive, so nothing in
  the pin plumbing prevents a write; the writer's gate conjunction and the
  tab are the walls.

### 1.1 How it plugs into the three-drive design

Everything about *which* units exist and what they are is explained in
[the ADF document, section 6](floppy-adf.md#6-three-drives-one-engine). The
short version for this page:

* `drv_decode` in `mega65.vhd` turns the Drive Settings radios into a mode per
  unit (Disk Image, Hardware Floppy, Off) plus a drive count, clamps units
  beyond the count to Off, and lets the **lowest** unit that asks for the
  mechanism have it; any other unit asking for it silently becomes a Disk
  Image drive. The result is `main_hwf_en` (a physical unit exists) and
  `main_hwf_unit` (which one), and in `main.vhd` a one-hot `hwf_phys_mask`
  for Paula. A change of the map cold-boots the Amiga through
  `amiga_cold_boot`, because Paula latches the drive count only at reset and
  AmigaOS enumerates its units at boot.
* The single `adf_track_engine` dispatches per poll on Paula's `sel` field. A
  unit that is the Hardware Floppy is served from the front-end's word FIFO
  instead of from HyperRAM, and its writes are tapped into the writer instead
  of being decoded into an image. The **drive index is the Amiga unit number**
  here as everywhere else.
* The main menu shows, for the unit that owns the mechanism, a plain text line
  `dfN:Hardware Floppy` in place of the mount line. While the menu is open
  the firmware patches a live status into it, `HW Floppy: Motor` or
  `HW Floppy: Reading`, by polling two diagnostic registers about 95 times a
  second (section [8.4](#84-the-live-status-line)).

---

## 2. What a real Amiga does with a floppy

If you have read the ADF document you know the first fact: Paula has no
sector interface. It shifts raw MFM channel bits in and out of a 16-bit
register and DMAs words to and from Chip RAM; everything above that is
software. The Hardware Floppy adds the layer *below* Paula that the ADF path
never needed: the magnetic one.

### 2.1 Flux, cells and the data separator

A DD Amiga track is a stream of **channel bits** at 2 µs per cell, 500 kbit/s.
A `1` is a flux reversal, a `0` is the absence of one. MFM guarantees that two
reversals are 2, 3 or 4 cells apart, so what the read head delivers is a train
of pulses with intervals of nominally 4, 6 or 8 µs, and nothing else. The
drive's spindle is only accurate to a few percent, the medium shifts pulse
positions (peak shift, worse on the inner cylinders), and old coatings drop
the occasional reversal entirely.

Turning that pulse train back into a bit stream is the job of a **data
separator**. A real Amiga has one at Paula's disk input, a digital
phase-locked loop that tracks the live cell period and assigns every pulse to
the cell it belongs to; Paula's shifter only ever sees clean cells.

### 2.2 DSKSYNC and WORDSYNC

Paula's shifter has no idea where a word starts. The `DSKSYNC` register holds
a 16-bit pattern, normally `$4489`, which cannot occur inside encoded data
because it carries a deliberately missing clock bit; `ADKCON`'s `WORDSYNC`
bit decides what Paula does with a match:

* **WORDSYNC on:** Paula discards everything until the shifter equals
  `DSKSYNC`, swallows that word, and stores from the *next* word on, re-framed
  at the match. Copiers and most trackloaders run like this.
* **WORDSYNC off:** Paula stores every word from the moment DMA starts, at
  whatever bit phase the shifter happens to have. Kickstart 1.3's
  `trackdisk.device` runs like this: it clears WORDSYNC when it acquires the
  disk resource and never writes `DSKSYNC` at all. It can afford to, because
  its software decoder finds the sector boundaries itself, at any of the 16
  possible bit phases, with a set of pre-shifted lookup tables.

That second mode has a consequence that shaped the single most important read
fix in this subsystem: under WORDSYNC off, **a real Paula never re-frames
mid-capture**. One capture, one framing. Section [4.4](#44-the-aligner-and-the-framing-hold)
explains why that matters.

### 2.3 trackdisk's habits

A few ROM facts about Kickstart 1.3 `trackdisk.device` recur throughout the
design, so here they are in one place:

* A read DMA is 7358 words, about 1.18 revolutions, so every sector passes
  under the head at least once. The decode is all-or-nothing: a single bad
  word fails the whole attempt, and there are 11 attempts per track with a
  full recalibrate before the 5th and the 9th.
* **The drive is deselected around every attempt**, for the milliseconds the
  CPU spends decoding the previous capture, and between every step pulse. A
  real drive does not care; a front-end that resets its state on deselect has
  to be designed so that this is harmless.
* A write DMA is 6815 words, about 109 % of a revolution, so the tail of a
  written track overwrites its own head. That overlap is the **write splice**:
  a point on every track where the bit phase jumps, because the writer's
  spindle was never exactly on speed. Every disk written by any Amiga carries
  one per track; trackdisk places it inside the inter-sector gap on purpose.
* trackdisk waits 2 ms after the write-complete interrupt before it touches a
  drive line, and it **never verifies a write**. A write that goes wrong is
  silent until the next read.
* For every track from 81 upwards it programs Paula's 140 ns write
  precompensation; track 80 is excluded. Section [6.2](#62-the-writer) is
  faithful to that.

X-Copy, the other field workload, behaves differently in exactly the ways
that matter: it keeps the drive selected across whole operations, runs with
WORDSYNC on, writes 6485 words through its DOS engine with a single padding
word of margin after the last sector, and toggles the side line about 30 µs
after the write-complete interrupt.

### 2.4 Copylock

Rob Northen's Copylock, the most widespread Amiga protection, does not read
the disk through DMA at all. It programs `DSKSYNC` to one of eleven per-sector
sync words, arms a zero-length DMA, and then polls `DSKBYTR`: bit 12
(`WORDEQUAL`) tells it the sync passed under the head, after which it counts
how many poll iterations it takes for `$3FF` raw bytes to arrive, watching bit
15 (`BYTEREADY`, set per byte and cleared by reading). It does that for a
sector written 5 % short and one written 5 % long and requires the ratio to
come out at a few percent. The protection track *is* a density modulation
that only a drive, not a copier, can reproduce. Section
[5](#5-copylock-and-the-dskbytr-observation-surface) explains what this
demanded of Minimig.

---

## 3. Why Minimig needed three new surfaces

The original expectation was that an Amiga core would mostly have to
"connect the Paula pins to the drive and mux the input lines with the virtual
drive". The outcome is right, but Minimig has no Paula *pins* to connect. `paula_floppy.v` fuses the disk controller with a token
drive model (a track counter, a motor latch, an index pulse derived from the
video frame counter), and everything below the level of pre-encoded,
word-aligned 16-bit MFM words lives in the host, which on AExp is the track
engine. There is no data separator and no bit layer. So the feature is three
surfaces, each as small as it could be made:

1. **A flux front-end** (`CORE/vhdl/physical_fdd/`): real pins in, 16-bit MFM
   words out, and for writing words in, write pulses out.
   Its decode stages are adapted from the C64MEGA65 project's physical-1581
   bring-up, whose magnetic constants were proven on this very mechanism at
   exactly 50 MHz, which is why the whole block runs on the 50 MHz QNICE
   clock rather than the 28.375 MHz core clock.
2. **A second backend behind the engine's host channel.** The engine already
   owned the seam between Paula and "the disk surface"; a unit backed by the
   mechanism is served from the front-end's FIFO instead of from HyperRAM,
   and its writes are tapped out instead of decoded.
3. **The CIA-line muxes inside `paula_floppy.v`.** The four status inputs a
   drive drives, `/RDY`, `/TRK0`, `/WPROT` and `/CHNG`, are modelled as
   open-collector AND terms across the four units; for the unit in
   `phys_mask` the virtual term is replaced by the conditioned real level,
   still gated by that unit's select line like a real drive. The real index
   is injected into the CIA-B FLAG source. With `phys_mask` all zero every
   expression reduces to the original Minimig logic, which is what keeps the
   ADF-only configuration bit-identical.

The control lines go the other way: CIA-B's port B byte,
`{motor, sel3..0, side, direc, step}`, is tapped out of Minimig as
`fdd_ctrl` and driven onto the connector in `mega65.vhd`. The eleven read-path
pins and the two write pins are routed board top to `MEGA65_Core` directly,
bypassing `framework.vhd`, under the sanctioned M2M exception tagged
`M2M-UPSTREAM floppy-pins`; drive B's select and motor lines stay tied
inactive.

Polarity facts, all proven on hardware: select, motor, step, index, track 0,
write protect and disk change are active low; `f_stepdir` high means toward
track 0, which is Minimig's `direc`; `f_side1` is a straight wire from
Minimig's `side` line (Minimig's side 0 selects the upper head, which is the
PC connector's side 1), confirmed by decoding a sector header captured at
cylinder 0, head 0, that claimed track 0. The diagnostics keep a side-invert
bit for other mechanisms; on this one it must stay 0.

---

## 4. The read chain

```
 pins -> inputs conditioner -> gap stage -> data separator -> raw-bit rebuild
      -> DSKSYNC aligner (+ framing hold) -> dual-clock word FIFO
      -> [core clock] adf_track_engine physical service -> Paula host channel
```

Everything up to the FIFO runs on the 50 MHz clock inside `physical_fdd_top`.
The FIFO's read side and the engine run on the 28.375 MHz core clock. All
cycle counts below are 50 MHz cycles unless stated otherwise; the constants
live in `physical_fdd_pkg.vhd`.

### 4.1 Input conditioning and index qualification

`physical_fdd_inputs` puts every raw pin through a two-flip-flop synchronizer
(the first stage carries `async_reg`). The static lines `/TRK0`, `/WPROT` and
`/CHNG` pass through with their active-low sense preserved, because Paula's
status muxes want the native open-collector polarity, and `RDATA` keeps its
active-low sense for the gap stage.

`INDEX` is qualified rather than just synchronized: the pin idles high and
pulses low once per revolution for 1.5 to 5 ms, and an edge is accepted only
after the line has been low for a continuous 200 µs (`C_INDEX_MIN_LOW_CYC`).
The block measures the period between accepted edges and the width of the
last pulse, both visible in the diagnostics. Nothing in the decode chain
depends on the index; it feeds the ready model, the per-revolution
instruments and CIA-B's FLAG input.

### 4.2 The gap stage

`physical_fdd_mfm_gaps` counts cycles between falling edges of `RDATA` and
emits the count as a **gap** with a one-cycle `gap_valid`. Two details are
deliberate:

* A gap shorter than 16 cycles (320 ns, `C_GAP_GLITCH`) is an electrical
  runt, never a legitimate DD interval. The runt edge is dropped and its
  length folds into the following gap, so downstream stages only ever see
  full-length intervals. The threshold must stay far below the shortest
  valid gap: a larger value would merge late-in-gap noise with the *following
  real edge* and silently corrupt the stream, a regression the C64 bring-up
  actually hit.
* The first edge after a reset only *starts* a gap and emits nothing.

### 4.3 Two data separators

This is where the magnetic reality of section [2.1](#21-flux-cells-and-the-data-separator)
is dealt with, and the front-end carries two implementations, selectable at
run time through diagnostics register `0x35` bit 6.

**The adaptive quantiser** (`physical_fdd_mfm_quantise`, the C64 lineage)
classifies each gap as short, medium or long by comparing it against 2.5 and
3.5 times a live half-cell estimate `est` (Q8.4 fixed point, nominal 100.0
cycles), accepts the class if the gap lies within `est/2` of the class
centre, and nudges `est` by a fixed 1/8 cycle toward every accepted gap. The
estimate is clamped to ±10 % of nominal; a gap outside every acceptance window
is a loss of lock, which re-seeds the estimate and, downstream, flushes the
bit assembly. The sign-based step rather than a proportional filter is a
measured choice: under peak shift a proportional filter settles to a biased
estimate.

Classification has a weakness that the field eventually exposed: a single
displaced flux edge distorts *two* adjacent intervals, a class flip inserts
or deletes a channel bit, and from that point on every word until the next
sync is shifted. One rare analog event on an old disk thus costs a whole
sector. Measured on real media, the failing intervals were exactly that kind
of rare extreme, sitting on a clean body.

**The digital PLL** (inside `physical_fdd_bits`, the default) does what a
real Paula's separator does. A phase accumulator advances one
cycle per clock and emits one channel bit every `cell` cycles: a `1` if an
edge fell into the elapsed cell, else a `0`. On every edge the phase error
against the cell centre is measured; the phase is pulled toward the centre by
half the error (`C_DPLL_PGAIN`) and the period by a 64th of it
(`C_DPLL_FGAIN`), with the period clamped to the same ±10 % span. There is
nothing to classify, nothing to re-seed, no filler to synthesize: a wild
interval degrades one bit position and the loop re-centres within a few
edges. A dropped reversal becomes a single `0` where a `1` should have been,
and the rest of the sector stays intact.

The quantiser keeps running as a passive observer in DPLL mode. Its gap
classes feed the margin instruments and the loss-of-lock counters, so a field
A/B between the two separators measures the same statistics either way; only
the bit source changes. In legacy mode the bit stage also synthesizes `0`
cells every 100 cycles once no edge has arrived for 512 cycles, so that an
unformatted region keeps Paula's DMA moving instead of stalling it; the DPLL
free-runs through droughts by construction.

### 4.4 The aligner and the framing hold

`physical_fdd_bits` shifts channel bits MSB-first into a 16-bit register,
exactly like Paula's own shifter, and emits a word every 16 bits. On top of
that it does **word alignment**: whenever the 16 most recent bits equal the
live `DSKSYNC` value (which the engine captures from Paula's response word 1
and exports raw, without the Copy Lock substitution the ADF path applies),
the register is emitted immediately and the bit counter restarts. The sync
word itself is emitted, so a sector's double `$4489` behaves exactly as it
does on the ADF path, where Paula's WORDSYNC gate drops the first match and
stores from the second.

The obvious rule, "re-align on every sync match", is what the first builds
did, and it is wrong for trackdisk. Recall section [2.2](#22-dsksync-and-wordsync):
under WORDSYNC off a real Paula never re-frames. Its capture of a track
carries one constant framing, the write splice shows up as a *constant* phase
shift between the words before and after the gap, and trackdisk's decoder
absorbs that shift with its 16 rotation tables and a second gap hunt that
takes its own shift. Re-aligning at every sync turns the once-per-revolution
splice slip into something no table matches: a run of gap words at the old
framing, one hybrid word, then a word-aligned sync. trackdisk's gap re-hunt
either exhausts its window or anchors one sector late, and the whole attempt
dies with error `$1A` or `$17`, on every attempt whose decode anchor is not
the first-written sector, in both separator modes. X-Copy was immune because
it runs with WORDSYNC on, where a real Paula does re-frame at every match;
the ADF drives were immune because an encoded image has no splice. In the
field this looked exactly like "old media": grinding retries on original
disks that a real A500 read fine.

The fix is the **framing hold**: while `frame_hold_i` is high, a sync match
is still reported to the instruments but neither restarts the bit counter
nor emits early, so the framing free-runs like a real shifter. The hold is
asserted in `physical_fdd_top` as

```
frame_hold <= serving_data and not wordsync and not framehold_dis
```

and each term is there for a reason:

* `serving_data` is the engine's `phys_data_o`: the physical read session is
  open *and* the engine has passed its serve-start sync. During the hunt
  before the first served word the aligner must keep realigning, or the
  serve-from-sync gate of [4.6](#46-the-engine-side-of-the-read-path) could
  never find a word-aligned sync. The engine state is the truth here; a
  bits-local "first match" heuristic would leave a residual case where a
  splice passes between an early FIFO-queued sync and the actual serve start.
* `wordsync` is Paula's live `ADKCON` WORDSYNC level, exported from
  `paula_floppy.v`. With WORDSYNC on, realignment stays active because that is
  what a real Paula does in that mode, and X-Copy and most trackloaders depend
  on it.
* `framehold_dis` is diagnostics register `0x35` bit 7, the field A/B switch
  back to realign-always.

**The diagnostic word stream.** The capture instruments (sector header
capture, per-revolution sector mask, bad-format counter, miss profile) need
correctly framed words, which the served stream deliberately is not once it
has free-run across a splice. So the stage carries a second framing counter
over the same shift register that *always* realigns on a sync match, exposed
as `dword_valid_o/dword_o`, and the capture path consumes that stream. The
two counters are cleared together by reset, loss of lock and every sync match
taken outside the hold, so they coincide whenever the hold has not engaged
since; in the realign-always arm they are identical by construction, and the
served stream into Paula is untouched in every mode.

### 4.5 The word FIFO and the chain reset

The words leave the 50 MHz domain through `physical_fdd_wfifo`, a textbook
Gray-pointer asynchronous FIFO (Cummings), 32 words deep, distributed LUTRAM,
first-word-fall-through on the read side. It is an elastic queue for the
clock crossing, never a pacing element: words arrive at real disk pace, one
per 32 µs, and the engine drains far faster. **Both of its resets derive from
the QNICE reset**, the write side directly and the read side through a
`cdc_stable` into the core domain; a one-sided reset permanently desynchronizes
the Gray pointers and produces silent corruption. The engine's own resets
deliberately never touch the FIFO.

The decode chain, from the gap stage to the aligner, is held in reset unless
the drive is enabled, selected and its motor is on, so every selection starts
with a clean sync hunt; `RDATA` is only driven while selected anyway. The
reset also covers the whole write episode and the writer's tail (section [6.4](#64-safety-wgate-the-tab-qualifier-and-the-read-chain)).

### 4.6 The engine side of the read path

The track engine's poll loop, frames and flow control are described in
[the ADF document, section 7.2](floppy-adf.md#72-serve-adf_track_engine).
A unit backed by the mechanism adds a physical service with three states,
`ST_PHYS_OPEN`, `ST_PHYS_HDR` and `ST_PHYS_DATA`, and a few rules:

* **The requested track is ignored.** Data comes from wherever the real head
  is, in rotation order, like on a real Amiga. Minimig's per-unit track
  counter still follows the step pulses for the physical unit and is what the
  status word reports; the engine uses that number only to detect a head step
  during a write drain and to decide precompensation. trackdisk's recalibrate
  sees the real `/TRK0`, so a counter that trails the head converges with it
  at cylinder 0; a counter that leads the head (a step the mechanism did not
  execute) would not, which at worst moves the precomp threshold by a few
  tracks.
* **Serve from the sync.** When a physical read session opens, the engine
  enters `phys_hunt` and discards FIFO words, one per frame, until the head
  word equals the live `DSKSYNC`; it then serves from that word on. The
  reason is the WORDSYNC-off mode again: Paula stores from the very first
  served word, and after a chain reset (every trackdisk attempt starts with
  one, because trackdisk deselected between attempts) the front-end emits
  hundreds of free-running pre-lock words before the first real sync. Served
  raw, those junk words land at the start of trackdisk's buffer and the
  attempt fails. Starting at the sync gives a buffer that begins sync-aligned
  exactly like a real drive behind Paula's WORDSYNC gate, and it is correct
  under either WORDSYNC setting.
* **Pacing.** A physical data frame pushes at most 16 words
  (`C_PHYS_BURST_MAX`), and an empty FIFO closes the frame and re-polls after
  about 4.5 µs (`C_PHYS_POLL_GAP`) instead of the normal 1 ms poll period, so
  the status re-check stays fresh and the latency added to a word is a
  fraction of a word time. Flow-control bit 8 can never engage at real disk
  pace.
* **Session ownership.** `phys_stream` latches when the service is dispatched
  and holds while Paula's `trackrd` stays up. Paula's `sel` field is a
  priority encoder, so another unit's change-poll click can make a single
  poll report a foreign unit in the middle of a read; without the latch the
  engine would abort into the idle discard or, worse, dispatch the ADF service
  into the running physical DMA and stream image data into the buffer. While
  the latch is set a transient foreign sample neither aborts nor re-dispatches,
  and `ST_PHYS_HDR`'s status re-check deliberately does not compare the `sel`
  bits at all.
* **Idle drain.** While the engine waits in `ST_IDLE` it pops and discards the
  FIFO, so words decoded while the disk spins without a pending DMA never go
  stale by more than a poll period. That same pop stream is what feeds the
  Copylock surface of section [5](#5-copylock-and-the-dskbytr-observation-surface).
* **Announce.** The per-poll `0x1nnn` drive-status word carries the physical
  unit's presence from the real disk-change latch, and its writable bit from
  the writer's tab qualifier (section [6.4](#64-safety-wgate-the-tab-qualifier-and-the-read-chain)).
  The writable bit is reporting only: at the CIA level Paula's mux
  substitutes the real `/WPROT` line regardless.

### 4.7 The CIA side: status lines, ready, index

For the unit in `phys_mask`, `paula_floppy.v` substitutes the conditioned real
levels into the open-collector AND terms of `/CHNG`, `/WPROT` and `/RDY`, and
picks the real `/TRK0` sensor as the track-0 source whenever that unit is the
selected one. The real index is edge-detected in the `clk7` grid into the
CIA-B FLAG source, gated like the fake one on "unit selected and motor on";
CIA-B's FLAG is a negative-edge interrupt on real silicon, and a one-tick pulse
reproduces that. The per-unit motor latch, which Minimig sets on the falling
edge of a unit's select line from the motor line, is exported and drives the
real motor pin.

The 34-pin interface has **no READY output**, so `/RDY` is synthesized in
`physical_fdd_top`:

* **Motor off: ready while selected.** This is what makes AmigaOS's motor-off
  drive-identification protocol read `0xFFFFFFFF`, "3.5 inch DD drive
  present", for `df1:` and `df2:`.
* **Motor on: ready after the spin-up gate**, 505 ms of motor time plus two
  qualified index edges plus a fresh index, and then **held** for as long as
  the motor stays on. The obvious model, ready while the index is fresh,
  flickers at the start of every operation, because the PC mechanism gates
  its INDEX output on `/SEL` and freshness starves across trackdisk's
  deselect gaps. A real drive holds ready while spinning because its index
  sensing is internal.

Disk presence is the disk-change latch itself: the mechanism asserts `/CHNG`
on eject and clears it on the next step with a disk inserted, which is exactly
the step-based change polling trackdisk does, so eject detection needs no
staleness logic of its own.

---

## 5. Copylock and the DSKBYTR observation surface

Section [2.4](#24-copylock) described what Copylock measures. Minimig's
`DSKBYTR` was a constant stub: `BYTEREADY` always set, `WORDEQUAL` always set,
data byte always zero. Every poll iteration "found" a byte at once, the short
and the long sector took the same number of iterations, the ratio was zero, the
check failed, and after its retries the loader parked the machine with the
motor on and a black screen. Every runtime A/B of the read chain failed
identically, which was itself the clue: the flux decoded perfectly in every
arm, and the loss was inside Paula's register surface. Fixing this was the
first time a Minimig Paula ever had to serve real protection flux.

**The tap.** `main.vhd` watches the engine's pop strobe on the front-end FIFO,
qualified with "FIFO not empty", and publishes each popped word as a one-clock
`obs_word/obs_stb` pulse. The engine pops in every phase, idle drain, hunt and
serve, so this stream *is* the reconstructed word stream of the real disk at
true, density-modulated flux pace, in the core clock domain, with no new
clock crossing. The qualifier matters: the engine's idle drain re-asserts its
pop for one extra cycle when it takes the last word (the FIFO's empty flag
comes a cycle late), the FIFO correctly ignores that pop, and an unqualified
tap would publish a phantom, lap-old word over every real one.

**The receiver** (`paula_floppy.v`) synthesizes `DSKBYTR` from that stream
while

```
obs_gate = |(phys_mask & ~_sel & motor_on) & ~obs_legacy
```

that is, only while the physical unit is the selected, motor-on drive and the
A/B bit is clear. Each observed word is delivered as two raw MFM bytes, high
byte first; `BYTEREADY` is set per byte and cleared when the CPU's read access
ends, which presents the next byte; `WORDEQUAL` is the live compare of the
latched word against `DSKSYNC`. Under WORDSYNC on, a word that matches
`DSKSYNC` sets `WORDEQUAL` and enqueues nothing, because a real Paula swallows
the sync word and re-frames at it, and Copylock's sector routine requires the
first byte pair after `WORDEQUAL` to be the encoded sector index, not the
sync. When the gate is low, the register expression is the original constant
stub, verbatim.

Deliberate, documented approximations, all behind the A/B bit: `WORDEQUAL`
is held for about one word rather than a real Paula's few microseconds (it
only makes the sync easier to catch); the low byte becomes available on the
read rather than 16 µs after the high byte; the `DMAON` bit keeps the stub's
meaning. None of the field titles or the regression net depends on these.

**The A/B.** Diagnostics register `0x35` bit 8 disables the surface and
reverts to the stub. In the field that bit brought the hang back on all three
original titles and the default brought them back to life, on the same disks
in the same session. The bit is not read back in the dump; the proof is the
boot outcome.

Two interactions with the rest of the design are worth knowing. During a
normal DMA read of the physical unit `BYTEREADY` toggles too, which is
harmless because no loader polls `DSKBYTR` for timing during its own DMA. And
during a write episode the engine never pops the FIFO (section
[6.3](#63-the-write-episode-and-who-owns-it)), so the surface shows no fresh
bytes while writing, like a real Paula.

---

## 6. The write datapath

### 6.1 The structure, and the elastic-buffer argument

```
 Paula write DMA  (Chip RAM -> 2048-word FIFO; Agnus supplies ~21.3 us/word)
      |  host-pull frames: the engine pops ONE word per frame, and only
      |  when the writer is nearly dry
 adf_track_engine, ST_WDRAIN_POP tap (physical episodes only)
      |  16-bit words, core clock
 physical_fdd_wfifo, 4 words deep: clock crossing only, occupancy 1..2
      |
 physical_fdd_writer (50 MHz): serializer, precomp, WDATA pulses, WGATE
      |
 mega65.vhd -> board top -> f_wdata / f_wgate
```

The writer is a dumb, format-agnostic bit pipe. Nothing parses what is
written, so AmigaDOS tracks, X-Copy images and trackloader formats pass
through identically; what the block owns is the magnetic and safety
discipline Paula has no concept of.

Two facts fix the shape of the pipe. First, **Paula's own FIFO plus its DMA
request loop is the elastic buffer**: Agnus supplies words faster than the
serializer consumes them (21.3 µs against 32 µs per word), so with the engine
popping one word per frame only when the writer is nearly dry, the backlog
sits in Paula's FIFO and the pipe can never starve mid-track. Second, **Paula
fires the write-complete interrupt (DSKBLK) when the host empties its FIFO**,
not when the flux is on the disk. Every word still in our pipe at that moment
is flux the Amiga already believes written. A real Paula owes exactly one
word at that instant, its own output shifter; ours owes the word just popped
plus whatever the CDC FIFO and the shift register hold. Keeping the CDC FIFO
at 4 words and the occupancy at 1 to 2 bounds that residue to 3 word times,
about 104 µs. Shallowness is the whole mechanism; there is no timer and no
withheld-pop heuristic. It is necessary and, as section
[6.5](#65-the-post-dskblk-drain-hold) explains, not sufficient.

The engine computes "nearly dry" from the CDC FIFO's write-side occupancy,
which lives in the engine's own clock domain, so no ready signal ever crosses
clocks. A physical episode's drain frame carries exactly one data word and is
admitted only while the occupancy is at most 1; otherwise the frame closes and
the engine re-polls on its fast cadence. Diagnostics register `0x7D` counts
pushes refused by a full FIFO and must read zero forever.

### 6.2 The writer

`physical_fdd_writer` runs at 50 MHz with fixed 100-cycle cells, 2.000 µs,
and serializes each word MSB-first, the mirror of the aligner's and Paula's
shift order. The shift register reloads from the FIFO head in the cycle its
last bit leaves; first-word-fall-through means the pop *is* the reload and
there is no holding register, which the tail bound depends on.

**WDATA** idles high and emits one active-low pulse of 25 cycles (500 ns) per
`1` bit, launched at cycle 50 of the cell, the midpoint. The falling edge is
the flux reversal, so only the launch position matters; the width merely has
to be one the mechanism registers (its window is 0.2 to 1.1 µs), and the
midpoint leaves 860 ns to either cell boundary after precompensation has
moved the edge. The output is registered, with no combinational path to the
pin, because a runt low from any producer becomes a written flux transition.

**WGATE** is defined at the output stage: it opens in the cell in which the
episode's first bit reaches the pulse generator and closes at the boundary of
the cell in which the last bit left it. The window is therefore exactly
`words x 16 x 100` cycles pin to pin, with zero lead-in and zero lead-out
cells. A real Paula starts and ends mid-stream, and trailing erased cells
would put a flux drought at the end splice.

**Precompensation** is ROM-faithful. A seven-bit window holds the three bits
before and the three after the one being written; if the gap before is
shorter than the gap after, the pulse launches 7 cycles early, in the mirror
case 7 cycles late, and symmetric or invalid neighbourhoods are left alone.
That is textbook peak-shift compensation with one magnitude, 140 ns, which is
Paula's `PRECOMP0`. A bit whose window reaches before the episode's first bit
or beyond its last gets no shift; zero-filling the window would classify the
missing side as a long gap and shift the very first and last pulses. Whether
precomp is on for an episode is decided **in the engine**, at the moment the
episode binds, from Paula's own track register (the number Kickstart compares)
and the mode in diagnostics register `0x7C`: AUTO means on for every track
from 81 upwards, which is Kickstart 1.3's policy including its exclusion of
track 80. The decision arrives at the writer as one level held for the
episode, so no multi-bit track value has to cross a clock domain. The 140 ns
step was later measured on the medium from flux dumps of core-written disks,
at exactly the track 80/81 boundary on both heads, the same size as on a disk
a real A500 formatted.

### 6.3 The write episode, and who owns it

The obvious unit of write state is the engine's drain, and it is the wrong
one. Paula's write DMA survives every engine-side drain abort: `trackwr` stays
high until the host has drained the FIFO, so after an abort the next poll
sees the same DMA again and would open a fresh drain for it. A session that is
scoped to the drain would clear its abort and write the remainder of the track
as a flux splat at a random position, or onto the next cylinder after a step.
The unit of write-session state is therefore the **trackwr episode**, from
the first drain that sees `trackwr` to the cycle in which the engine observes
the DMA complete.

Ownership is bound **once**, at the episode's first drain. The physical unit
owns it only if three things hold at that poll: the physical unit is
configured, Paula's `sel` field names it, **and the unit's real per-drive
select line is asserted** (`phys_sel_i`, derived in `mega65.vhd` from the same
CIA bit that drives the connector). The third condition is not redundant.
Paula's `sel` field is a priority encoder whose "nothing selected" value is
`2'd0`, identical to "`df0:` selected"; with the mechanism at `df0:` an
ordinary deselect gap during an ADF write would otherwise bind the episode as
physical. And binding physical is irreversible: it suspends the ownership
guard for the whole episode and pins the drain at non-committing, so one such
sample sent an entire `.adf` track write into the writer and committed nothing
while trackdisk, which never verifies, believed the track written. Failing
the other way is safe: the episode stays ADF-owned, and the writer's own
select term keeps WGATE shut.

Once bound, `wr_epi = epi_bound and epi_phys` is the level everything keys
on, and while it is set:

* every re-latched drain **inherits** physical ownership: `drain_unit` is the
  physical unit, `drain_commit` is `0`, the decoder stays pinned in its hunt
  state, and the track latched at the binding poll is kept. A transient
  foreign `sel` sample can therefore never re-latch the remainder of a
  physical DMA as an ADF-owned, committing drain that would decode perfectly
  valid AmigaDOS sectors off the real disk and write them into a mounted
  image. That cross-contamination path exists on the pre-episode engine, and
  the testbench that demonstrates it is the strongest argument for the model;
* the ownership guard that aborts an ADF drain on a foreign sample is
  suspended; a foreign selection must instead **persist for 100 µs**
  (`C_WR_FOREIGN`, measured in time, because the fast re-poll cadence is
  about 2 µs per frame while a software change-poll click spans 5 µs or more)
  to abort the episode;
* the engine **never enters `ST_IDLE`**: every exit that would park there
  re-targets to a fast re-poll. This keeps the pipe fed (a one-poll sample of
  a non-existent unit would otherwise starve it into an underrun), suspends
  the `0x1nnn` announce, and above all suspends the idle discard-pop of the
  read FIFO, each of which would fire the Copylock tap into `DSKBYTR` in the
  middle of a write;
* the tap pulses once per popped word, `phys_wr_valid_o/phys_wr_data_o`;
* a head step observed on a poll whose `sel` is the physical unit, the
  persisting foreign selection, and the engine's global abort (core reset,
  bus-grant loss) raise the **abort level** `epi_abort`. It is a level held
  for the episode, never a pulse, because it crosses to the 50 MHz domain
  through a plain two-flop synchronizer. An aborted episode is dead: the
  engine keeps re-opening inherited drains and popping so Paula's DMA
  completes and DSKBLK fires, the writer discards, and the Amiga is left with
  a track it believes written and the disk does not hold, which is exactly
  what a real Amiga leaves after a mid-write fault.

The episode ends when the engine observes DMA completion: the drain frame's
status word reports DMA inactive with an empty FIFO, or any poll shows
`trackwr` low. Both clear the bind, the abort level and the foreign timer.
The abort level is initialised at the bind rather than cleared at the end,
because the global abort block runs after the episode-end branches in the
same process and would re-assert it in the very cycle an end branch clears
it; a level left latched would make the next episode abort before WGATE ever
opened.

Two interlocks complete the picture. The engine does not **bind** a new
episode, nor dispatch a physical **read**, while the writer reports busy with
a previous episode's tail; Paula's FIFO simply fills for the hundred
microseconds that takes, and the read defers on the fast cadence rather than
the 1 ms park (X-Copy's index-synced verify read is the case that would
otherwise start a sector and a half late). Re-latches inside an open episode
are never gated on busy, so there is no deadlock between the engine waiting
for the writer and the writer waiting for the episode to end.

### 6.4 Safety: WGATE, the tab qualifier and the read chain

The writer's state machine is `IDLE -> ARM -> STREAM | DISCARD -> ABORTED`.
`ARM` is entered when the episode level rises; `STREAM` when the FIFO holds
at least two words (so the serializer rides out Agnus's three-words-then-pause
line bursts) and the tab is qualified; otherwise the episode discards for its
whole duration. `DISCARD` and `ABORTED` keep consuming words at cell pace into
nowhere, so the FIFO drains, the engine keeps popping, Paula's DMA completes
and DSKBLK fires.

**WGATE is a conjunction evaluated every cycle**, not a flag a monitor is
trusted to revoke:

```
WGATE asserted  <=>  a real episode bit is at the output stage
                 and not abort_latched and state = STREAM
                 and enable and (selected or drain_hold) and motor
                 and wr_ok
```

The gate must fall out of the terms directly, because the abort monitor is
blind for the 50 µs select-settle window after a select edge, and a `wr_ok`
left qualified by a *previous* disk would otherwise open WGATE on a
just-swapped, write-protected one. `ST_ARM` therefore also requires the
settle to have completed and the live tab reading to be clean in this
selection before streaming.

**The tab qualifier `wr_ok`.** The PC mechanism drives its outputs only while
selected, so `/WPROT` means something only while the unit is selected and the
first 50 µs after a select edge are ignored. `wr_ok` is set once the tab has
read writable for 10 ms of *cumulative selected* time; deselect merely pauses
the accumulator (a per-deselect reset would block trackdisk, which arms its
write 2 ms after selecting). It is revoked by a protected level that persists
four samples (80 ns, the runt-filter class: a 20 ns line glitch must not kill
a 218 ms write that will never be verified), by the **assert edge** of the
disk-change line through the same filter, and by reset. The change latch is
an event here and not a gate term, deliberately: the mechanism holds `/CHNG`
asserted until the next step with a disk inserted, and a level gate would
block X-Copy's single-drive mode, which swaps disks and rewrites the same
track without stepping. A real Amiga has no such interlock either.

**The abort latch.** While streaming, any of deselect, motor off, enable off,
the qualified protected level, the qualified change edge, a step pulse edge, a
side-line change, an underrun or the engine's abort level closes WGATE in the
same cycle and latches the abort for the rest of the episode. A returning
term, a re-opened drain or a re-select cannot re-open the gate until the
episode has ended and a new one arms. The underrun is detected at the cell
boundary where it happens, not when the whole precomp window has emptied: a
dry spell of one to six cells would otherwise pass as a WGATE deassert and
re-assert in mid-track, an erased hole with no abort and no reason code.

**The read chain is held in reset for the whole episode**, and through the
writer's tail: `chain_rst` includes the synchronized episode level and the
writer's busy level, not merely WGATE. A tab-blocked or aborted episode keeps
the gate shut while the disk keeps spinning, and a decoding front-end would
refill the read FIFO behind the write, pollute the read instruments and feed
the Copylock surface with bytes in the middle of a write DMA, where a real
Paula shows none. The tail term exists because the episode level falls when
Paula completes the DMA, while the writer is still laying down its last three
words.

### 6.5 The post-DSKBLK drain hold

This is the one place where the shallow pipe is not enough on its own, and it
was found on the bench rather than in simulation. X-Copy's DOS engine writes
`[500 x $AAAA][11 sectors][1 x $AAAA]`, 6485 words: its whole post-DSKBLK
margin is one padding word, sized for a real Paula that owes one word. It
then toggles the side line about 30 µs after DSKBLK. Our writer still owed
about 100 µs of flux at that point, treated the side change as a gate term,
and cut the tail, which destroyed the last word of sector 10 on every
upper-side track: 85 bytes of 901,120, all sector 10, all head 1, all at
offset 510/511.

Once the episode level has fallen the host has already been told the write
completed, and the flux still owed is flux the Amiga believes is on the disk.
Cutting it is strictly worse than writing it. So a **pair** of changes, which
must never ship apart:

* `mega65.vhd` holds `f_selecta_o` and `f_side1_o` at their episode values
  while the writer is busy **and** the episode has fallen **and** the held
  select is the asserted one. The window is the drain only, the pipe depth,
  at most about 104 µs, far inside X-Copy's own 253 µs post-side settle and
  trackdisk's 2 ms wait. Keying on busy alone would freeze the pins for a
  whole 207 ms track, for the rest of a blocked or aborted episode, and
  across a reset (a held reset leaves the episode latched), right where
  trackdisk recalibrates with a burst of steps. Holding a *deselected* value
  would protect nothing and could make the drive ignore a step that reaches
  its pin while it is pinned deselected.
* `physical_fdd_writer` stops treating a select or side change as an abort
  term once the episode has fallen (`v_hold`). Every other term stays live:
  motor and enable, because a stopped spindle or disabled unit means the flux
  would land nowhere or in the wrong place; the tab and change revokes; and
  **STEP, deliberately**. A seek moves the head, and writing across it smears
  the data over two cylinders, so the step edge still closes WGATE in the
  same cycle.

**STEP and DIR are not held.** STEP is a pulse, and nothing in the hold logic
latches or replays one; a pulse that began and ended inside a hold would be
destroyed rather than delayed, the host would advance its cylinder counter
while the head stayed put, and every later access would silently go to the
wrong cylinder. Holding it would also buy nothing, since the writer's step
abort closes the gate in tens of nanoseconds while a head needs milliseconds
to move.

The two pins are held for different reasons. A mechanism switches heads the
moment `/SIDE1` moves, so without the side hold the tail lands on the other
surface. A mechanism gates its write circuitry on `/SELn`, so without the
select hold a deselected drive ignores WGATE and the tail is lost silently,
with no abort and no tail-cut count. Holding select asserted past a host
deselect is safe on this board because there is exactly one drive on the
cable. Only the pins are held; the engine's bind qualifier and the
diagnostics keep following the live Amiga values. The mega65-side window is a
strict superset of the writer's own `v_hold`, because the episode level is
native to the core domain and falls first while busy returns through a
`cdc_stable` and falls last. This extends the framework's `floppy-pins` exception and the writer's abort
contract.

After the fix X-Copy copied all 160 tracks with verify on, byte-identical to a
proven reference, and the flux dumps of three X-Copy-written disks show every
write ending 15 cells after sector 10's last data bit, the end of the pad
word, on both heads.

---

## 7. Clock domains and CDC

| Element | Clock |
|---|---|
| Input conditioner, gap stage, quantiser, DPLL, aligner, read FIFO write side, writer, write FIFO read side, diagnostics bank, margin and seam instruments | `qnice_clk` 50 MHz |
| `adf_track_engine`, Paula, the observation tap, the connector pin registers, `drv_decode`, the drain hold | `main_clk` 28.375 MHz |

The 50 MHz choice is the C64 precedent and buys three things: the magnetic
constants and the testbench vectors transfer verbatim, the diagnostics bank
sits in the QNICE domain without any crossing, and the write cells are an
exact 100 cycles with an integer 7-cycle precomp offset. The cost is one set
of crossings, every one of which is one of the following patterns:

* **Gray-pointer FIFOs**, both directions: the 32-word read FIFO (50 MHz to
  core) and the 4-word write FIFO (core to 50 MHz). Both sides of both reset
  from the QNICE reset.
* **Two-flop level synchronizers into the 50 MHz domain** for quasi-static or
  slow levels from the core: enable, selected, motor, side, step and direction
  (for the cylinder tracker), the serving and serving-data levels, Paula's
  WORDSYNC, and the writer's episode, abort and precomp levels. The live
  `DSKSYNC` value crosses as a 16-bit word through a settle filter that adopts
  a value only after two identical samples; a torn sample could at worst cause
  one transient misalignment that heals at the next true sync.
* **Gray-coded counters** for values that increment one step at a time: the
  engine's served-word count (core to 50 MHz) and the write-FIFO overflow
  count (core to 50 MHz).
* **`cdc_stable`** for the rest: the conditioned drive status levels into the
  core (`/CHNG`, `/WPROT`, `/TRK0`, `/RDY`, index, present); the writer's busy
  and tab-qualified levels and the precomp mode into the core; the episode's
  track number, the side-invert bit and the surface A/B bit; the
  store-signature bundle into the diagnostics; and the QNICE reset into the
  core for the FIFO read side.

`CORE/CORE.xdc` bounds all raw synchronizer paths between the two clocks with
a clock-pair `set_max_delay -datapath_only 20.000` in both directions. It is
deliberately a max-delay and not the C64's blanket false path: a clock-pair
false path would override the framework's object-scoped `cdc_stable` bounds
in `common.xdc`, while a max-delay yields to them. The first synthesis of the
front-end failed timing by more than 6 ns on exactly these paths, which is
how the constraint earned its place. Nothing in the feature uses block RAM:
the FIFOs and the engine's buffers are distributed LUTRAM, and the rest is
registers.

---

## 8. The diagnostics device

The whole feature was brought up without a scope or a logic analyzer; the
only on-hardware instrument is `physical_fdd_diag`, a read-only register bank
at QNICE device `0x0104` (`C_DEV_AMIGA_FDD`), decoding 128 word addresses.
Every tap comes from `physical_fdd_top` in the same 50 MHz domain, so nothing
tears. The readout is registered on the falling clock edge (the M2M device
convention), so the CPU-facing data path is a plain flip-flop bank rather than
a 128-word mux cloud, with zero wait states; this mattered because one build
grazed the kick-ROM half-period path through the shared device-data cone.
Three registers are writable; they are decoded in `mega65.vhd`.

### 8.1 Reading it from the QNICE monitor

With a JTAG or serial connection to the QNICE debug console, once per session:

```
M C FFF4 0104        select the device (M2M$RAMROM_DEV)
M C FFF5 0000        select 4k window 0 (M2M$RAMROM_4KWIN)
```

then per dump:

```
M D 7000 707D        dump the whole bank, register n at 0x7000 + n
```

Sanity on every dump: the word at `0x7001` must read `000D`, and the uptime
pair at `0x7030/0x7031` must differ from the previous dump. The uptime and the
dump nonce (`0x7032`, which counts reads of register 0) exist because a field
session once delivered seven byte-identical "dumps" that were two
observations pasted several times; a dump without a freshness marker is not
evidence. Dumps should be taken with the drive idle, because the capture
instruments re-capture on every sector of an active read.

### 8.2 The runtime switches

Register `0x35` (write; the low 8 bits read back):

| Bit | Meaning when set | Default |
|---|---|---|
| 3..0 | armed sector `K` for the window mode | 0 |
| 4 | window mode: histogram only inside the armed-sector window | 0 |
| 5 | histogram all gaps, not only during physical read sessions | 0 |
| 6 | **legacy quantiser bit source** instead of the DPLL separator | 0 = DPLL |
| 7 | **realign-always framing** instead of the WORDSYNC-conditional hold | 0 = hold |
| 8 | **disable the DSKBYTR observation surface** (revert to the stub); not read back | 0 = surface on |
| 15 | self-clearing strobe: clear every "since clear" statistic | - |

So `M C 7035 8000` clears the statistics with every switch at its default,
`M C 7035 8040` selects the legacy separator, `M C 7035 8080` the old framing,
`M C 7035 8100` switches the Copylock surface off, and a reset restores the
defaults. Register `0x1F` bit 0 inverts the side line (keep it 0 on this
mechanism). Register `0x7C` bits 1:0 select the precomp mode: `00` or `11`
AUTO (the Kickstart policy), `01` always on, `10` always off; it reads back
the mode plus "precomp active now", the tab qualifier and "episode open".

The write instruments `0x70..0x7D` count since the QNICE reset, not since the
`0x35` clear, so a write dump must come from the same boot session as the
write it describes.

### 8.3 Reading a dump

The full register map is in section [12.2](#122-diagnostics-register-map).
The registers that answer the questions that actually come up:

* **Is the front-end alive and locked?** `0x02` status bits (enable,
  selected, motor, media ready, the raw status lines), `0x04` the quantiser
  estimate and `0x5F` the DPLL cell period (both nominal `0x640` = 100.0
  cycles; a value pinned at `0x5A0` or `0x6E0` is sitting on the ±10 % clamp),
  `0x0B` sync hits and `0x0C` words reconstructed, `0x0D` runts, `0x0E` losses
  of lock.
* **Did data reach the Amiga?** `0x1B` counts the words the engine actually
  served into Paula; a trackdisk read is 7358 of them. The front-end counters
  tick whether or not Paula's DMA ever armed, this one does not. The firmware
  uses the same register for the `Reading` status.
* **Is the channel word-exact?** The store-signature pair `0x20` (engine side)
  and `0x22` (Paula side) XOR the first 1024 words of the last session on both
  sides of the host channel and must be equal; the checkpoints at `0x24..0x27`
  bracket the first diverging word if they are not.
* **What did the disk look like?** `0x13..0x1A` are the eight words after the
  last sync hit, decoding to the sector header's info long (format `$FF`,
  track, sector, sectors-to-gap); `0x1C` is the sector mask of the last full
  revolution (`0x07FF` = all eleven seen); `0x1D` the captures and losses of
  lock in that revolution; `0x58..0x5E` the per-sector miss profile.
* **Was the seam involved?** `0x60` counts mid-serve realign events (they are
  counted even while the hold suppresses them, so the two framing arms compare
  directly), `0x62..0x69` hold the eight words before the last one, `0x6E` is
  the live framing status.
* **What did the last write do?** `0x70` episodes bound, `0x7A` episodes in
  which WGATE opened, `0x76` tab-blocked episodes, `0x79` the last episode's
  track and flags, `0x7B` the last abort reason, `0x73/0x74` the WGATE window
  in cycles (a full trackdisk write is exactly `6815 x 16 x 100` =
  10,904,000), `0x77` the in-flight residue at DSKBLK (expected 3 or less) and
  the tail-cut count, `0x7D` refused pushes (must be 0).

A decoder script, `tools/decode_fdd_dump.py`, turns a pasted dump into prose,
flags stale instruments and duplicated captures, and knows every map version.

### 8.4 The live status line

`HWF_STATUS_STEP` in `m2m-rom.asm`, called from `HANDLE_CORE_IO`, is the one
piece of firmware in this feature. Four cheap gates decide whether there is
anything to show (the OSM is on screen, no file browser or help page owns it,
the main menu level is active, and some drive is the Hardware Floppy); only
then, about 95 times a second, does it read the status word at `0x02` and the
served-word counter at `0x1B`: motor off is idle, motor on with the counter
unchanged is `Motor`, a moving counter is `Reading`. The label is painted
through the framework helper `OPTM_LIVE_TEXT` into a fixed 22-character field
of the drive's text line, and only when the coarse state changes. A write
shows as `Motor`, because nothing is served *to* the Amiga while it writes.

---

## 9. When a user reports a problem

The standing lesson of this feature is that a failure pattern must be
**classified before it is theorised about**. A pervasive read failure that
was long blamed on old media turned out to be the sync seam, and a field
report of "intermittent write failures" turned out to be a voided test, a
disk that was never written, and physical media damage, none of it the core.
The protocols below exist so that the next report lands on measurements.

### 9.1 A disk reads on a real Amiga but not on the core

Ask for, in this order:

1. **The configuration and the phenomenology.** Drive Settings (how many
   drives, which one is the mechanism), the exact title, whether it is an
   original, a cracked copy or a self-written disk, and how the failure looks:
   the boot hand never leaves, a grinding retry with a requester, a silent
   hang, a Guru, partial loading. A phone video of the failure moment is worth
   a page of description. If the drive knocks and reads nothing right after
   power-on, that is the mechanism's own controller in a wedged power-on
   state; a power cycle cures it and it is not a core bug.
2. **A control.** A disk known to work on the core, booted in the same session
   on the same unit. This separates a per-unit or per-session factor from a
   per-disk one.
3. **An X-Copy map** (DOSCOPY+, X-Copy 2.0). X-Copy shows one digit per
   cylinder and side, and the digits are error codes, not bad-sector counts.
   Localized structure on specific tracks is a format or protection signature
   and may be perfectly normal for the title (a Copylock track shows errors on
   a real Amiga's X-Copy too); roving scatter points at the medium; a clean
   map on a disk that still will not boot points at Paula's register surface
   or the serve protocol.
4. **Dumps with the uptime discipline**: `M C 7035 8000` before the attempt,
   then `M D 7000 707D` before, at the failure point, and after a retry. The
   decoder script does the reading.
5. **The runtime A/B arms** on one failing title: `M C 7035 8080` (realign
   always), `M C 7035 8040` (legacy separator), `M C 7035 8100` (surface off).
   A behaviour change under one of them localizes the layer for free;
   identical failure in all arms means the cause is below framing and
   separator choice, or in the flux itself.
6. **A flux dump** if the tester owns a Greaseweazle or SuperCard Pro: the
   whole disk, three revolutions, raw `.scp`. Real flux decoded offline is
   the evidence that settles most questions, and the SCP tools can replay it
   through independent separators.

### 9.2 A disk the core wrote reads badly

Get the failing disk **untouched**, not rewritten and not reformatted, and ask
for three files: the source `.adf`, the disk X-Copied back to an `.adf` on the
MEGA65 (`df0:` an image, `df1:` the Hardware Floppy), and a raw `.scp` of it.
Then:

1. Compare source and read-back (`tools/adf_compare.py`). Differences
   confined to sector 10, offsets 510/511, head 1 only, mean the post-DSKBLK
   tail is being cut again. Thousands of differing bytes on every track mean
   the disk was never written. Anything else is classified before it is
   theorised.
2. Scan the flux for analog damage patches (`tools/flux/patch_scan.py`). A
   healthy disk, core-written or Amiga-written, scans to zero. Patches that
   line up in rotational angle across tracks are a physical feature of the
   medium: X-Copy's writes start at a random angle, so write logic cannot
   produce them. Wrong data in clean, legal MFM is the opposite signature and
   points at logic.
3. Find where each X-Copy write ends relative to sector 10's last data bit
   (`tools/flux/xcopy_tail.py`). Healthy is 15 cells after it, on both heads.
   Earlier means the tail is being cut.
4. For a disk that comes back virgin, have the tester repeat the recipe and
   dump `M D 7000 707D` **before any reset**. `0x70` and `0x7A` both up by the
   number of tracks: the core wrote, look at the drive and the disk. `0x70` up
   but `0x7A` flat, with `0x76` counting: the core discarded, look at the tab
   qualifier. `0x70` flat: the write never reached the physical unit; X-Copy
   was aimed at another drive.
5. Before blaming a single track, fingerprint which drive wrote it
   (`tools/flux/writer_fingerprint.py`): the cells per revolution reveal the
   writing spindle's speed, and a track rewritten by the tester's own Amiga
   says nothing about our writer. The precomp step can be measured on the
   medium the same way (`tools/flux/precomp_step.py`).
6. The advice that prevents the whole class: **copy with verify on**. X-Copy's
   verify reads every track back, flags a bad blank on the spot, and cannot
   miss a disk that was never written.

---

## 10. Questions you are probably asking

### "Why does the front-end run on the QNICE clock and not on the core clock?"

Because every magnetic constant in it was proven on this mechanism at exactly
50 MHz, and a rescale to 28.375 MHz would have been bring-up risk in a project
whose only instrument was a register bank. The diagnostics then live in the
QNICE domain without any crossing, and the writer gets exact 100-cycle cells.
The crossings this costs are all of proven shapes (section [7](#7-clock-domains-and-cdc)).

### "Can I drop the legacy quantiser now that the DPLL is the default?"

Not without touching the instruments. The quantiser's gap classes feed the
margin histograms, the loss-of-lock counters and the miss profile in both
modes, and the legacy bit source is the runtime A/B that lets a field tester
answer "is it the separator?" without a rebuild. It costs registers, not
block RAM.

### "Why is the framing hold conditional on WORDSYNC? Would always holding be simpler?"

Simpler and wrong. Under WORDSYNC on, a real Paula re-frames its shifter at
every match, and X-Copy and most trackloaders are written against that.
Holding there would hand them the seam problem trackdisk had. The hold
reproduces real Paula in both modes; the mode comes from Paula's own register.

### "What stops a physical write from landing in a mounted `.adf`?"

The episode model. Once an episode is bound physical, every drain re-latched
for it inherits non-committing ownership, so no foreign `sel` sample can turn
the remainder of the DMA into a decoding drain. The testbench that drives a
physical write carrying valid AmigaDOS sectors, with a write-armed image at
the same track and a persisting foreign selection injected mid-stream, is red
against the pre-episode engine and green against this one.

### "The Amiga says the write succeeded. Was it written?"

Not necessarily, and that is a property of the Amiga, not of this core. Paula
reports completion when its FIFO is drained, trackdisk never verifies, and an
aborted episode is a track the Amiga believes written. The diagnostics tell
the truth: `0x79`'s flags and `0x7B`'s reason for the last episode, and the
`0x7A` versus `0x70` counts over a session.

### "Can the Hardware Floppy write an HD disk if I tape over the hole?"

The density pin is held at the DD level and the mechanism was never tested
writing HD media; the user page says DD only, and the recommendation is DD
blanks for anything written.

### "Why no OSM switch to make the drive read-only?"

A deliberate decision: the physical tab is the guard every Amiga user already
knows, the core adds nothing a user could set
wrong, and a software switch would have to be answered by a second switch for
the cases where it is in the way. The documentation says in plain words that
originals stay with the window open.

---

## 11. How it was verified

Every bench below ran in simulation before the hardware round it prepared,
and the testbenches, the independent model twins and the runner scripts are
kept as the regression gate for any change to the floppy stack. They live in
`CORE/sim/floppy/` and `CORE/sim/minimig/`;
[Tools and testbenches](tools.md) has the commands and runtimes. They are grouped by what they prove; the hardware and field
evidence comes last.

**The read front-end.** A closed-loop bench turns properly clocked MFM into
timed `RDATA` edges and requires the front-end to reproduce the exact
word-aligned stream through the real dual-clock FIFO, at nominal speed, ±3 %
speed with per-edge jitter, with injected runts and across a flux drought,
in both separator modes (`tb_physical_fdd_top.vhd`).
A red/green bench for the DPLL replays the measured failure classes (a
displaced edge, a dropped reversal, a 3 % bias) and shows the dropped
reversal corrupting the rest of the sector under the legacy classifier while
staying a single bit under the DPLL (`tb_fdd_dpll.vhd`).
The margin instruments are checked against an independent integer model of
the quantiser and the histogram engine, which must agree bit-exactly
(`tb_fdd_margin.vhd`, with the model in `gen_tb_fdd_margin.py`).

**The sync seam.** The decisive bench builds a real eleven-sector AmigaDOS
track with a write splice, loops it as flux through the real front-end at
trackdisk's exact cadence (deselect between attempts, the 1 ms select wait,
the 7358-word DMA, serve-from-sync), and decodes every capture with a literal
port of Kickstart 1.3's trackdisk decoder, hunt tables and all. It goes red
with realign-always framing in both separator modes and green with the hold,
and a constant-framing model of the same flux (what a real A500 delivers)
decodes green. An independent Python implementation of the same ROM algorithm
returned identical verdicts on the dumped captures. The bench also covers
WORDSYNC on, where the hold must stay off and an X-Copy-style decode must
succeed (`tb_fdd_splice.vhd`, the Python twin `models/td_check.py`).

**The engine and Paula.** The physical delivery segment, the real engine's
physical states against a line-by-line VHDL model of Paula's host receiver and
disk DMA, with two attempts back to back and every stored word compared to
the feed (`tb_engine_paula.vhd`). The same bench can log every real FIFO pop
with its cycle timestamp, and that pop stream was shown cycle-exact between
the engine as it was before the write datapath and the current one, because
that stream feeds the Copylock surface.
The multi-drive ownership bench drives the real engine with a behavioural
Paula and a behavioural Avalon slave and includes the physical cases: a
physical write drained without any Avalon write, the cross-contamination
scenario above, the `df0:` bind ambiguity, an ADF write against a busy writer,
and a reset inside an open episode (`tb_adf_multidrive.vhd`).
A golden trace of the engine's complete io-channel word stream over an
ADF-only workload, diffed against the engine as it was before the write
datapath, came out byte-identical with no physical unit configured, and with
one configured differed only in the announce's writable nibble.

**The Copylock surface.** An iverilog bench instantiates the current
`paula_floppy.v` beside a frozen copy of the pre-surface module, drives both
with identical randomized register and host-channel traffic in every gate-off
regime, and asserts all outputs bit-identical every cycle; a CPU model then
polls `DSKBYTR` like the Copylock loop and must measure the 5 % timing ratio
with the surface on and zero with it off. A separate bench proves the tap
against the real FIFO and the real idle-drain pattern, red without the
not-empty qualifier (`CORE/sim/minimig/run_paula_obs.sh` with
`tb_paula_obs.v` and the frozen `paula_floppy_ref.v`; the tap bench is
`CORE/sim/floppy/tb_hwf_obs_tap.vhd`).

**The write datapath.** The write bench closes the loop Paula write model,
real engine, real CDC FIFO, real writer, a live rotating flux model in 50 MHz
cycle timestamps, the real read chain, real engine read service, and three
verdicts: the ROM-exact trackdisk checker, the constant-framing real-Paula
referee, and a per-sector byte compare after an independent bit-level
re-sync. The flux model is pre-seeded with a different track before every
writing scenario and every scenario asserts that the gate opened and the old
flux is gone, so a writer that never opens its gate cannot pass. Scenarios
cover the trackdisk cadence over an RPM sweep in both separator modes and
both framing arms, the precomp policy at tracks 80, 81 and 90, X-Copy's
cadence with the side toggle, the tab in three episodes plus bounce and
deselected-line cases, engine aborts, every gate term, the tail sweep,
co-selection clicks, the `df0:` ambiguity, residue hygiene under all reset
classes, and the busy interlock. An independent Python twin reconstructs the
expected edge-time list from the serialization rules and must agree with the
VHDL flux model to one cycle, precomp included. A mutant matrix applies
single-site edits to copies of the HDL (LSB-first serialization, 99-cycle
cells, a dropped word, a runt pulse, a short gate window, the drain hold
removed or over-applied, the ready threshold loosened, the precomp sign
inverted, abort on the first foreign sample, the abort level never set, each
interlock gate removed, the inheritance removed, the precomp threshold off by
one) and requires every one to turn a verdict red, credited only if the cell
is green on the unmutated design (`tb_fdd_write.vhd`, the twin
`models/td_write_check.py`, the runners `run_write_matrix.sh` and
`run_write_mutants.sh`).

**The diagnostics readout** is swept over all 128 addresses against a literal
expectation table, with a latch-instant proof that the output really is
registered (`tb_fdd_diag_ro.vhd`).

**The regression gate** runs every read-side bench, the ownership bench, the
tap bench and the Paula golden diff in one script,
`CORE/sim/floppy/run_fdd_regression.sh`. It tests a copy of the sources taken
when it starts and fails loudly if a source changes during the run.

**On hardware and in the field.** Reads: the referee for the seam fix was the
community's shoebox, with originals from the late 1980s booting under
trackdisk and X-Copy copies staying bit-perfect; the referee for the Copylock
surface was the causal A/B on three original titles plus an 18-title
regression sweep. Writes: Workbench `format`, copy, reboot and run; X-Copy
whole-disk with verify on, byte-identical to a proven reference; an A500
(OCS, Kickstart 1.3), an A500+ (ECS, Kickstart 2.0) and an A1200 (Kickstart
3.2) reading core-written disks; a bootable Workbench disk written end to end
by the core; a trackloader's high score surviving a power cycle; and flux
analysis of Greaseweazle dumps showing the precomp step on the medium and the
X-Copy tail fully written on both heads (the flux tools in `tools/flux/`,
described in [Tools and testbenches](tools.md)). For a tester
without a JTAG console, trackdisk's per-attempt error codes can also be
logged on the Amiga side.

---

## 12. Reference

### 12.1 File inventory

| File | Role |
|---|---|
| `CORE/vhdl/physical_fdd/physical_fdd_pkg.vhd` | Every magnetic, timing and instrument constant: cell and gap lengths, quantiser and DPLL gains and clamps, runt threshold, drought, index qualification, ready model, capture and histogram sizes. |
| `CORE/vhdl/physical_fdd/physical_fdd_inputs.vhd` | Two-flop synchronizers for the five input pins, index qualification and measurement, active-low pass-through of the status lines. |
| `CORE/vhdl/physical_fdd/physical_fdd_mfm_gaps.vhd` | Flux edge to gap interval, runt filter, first-edge rule. |
| `CORE/vhdl/physical_fdd/physical_fdd_mfm_quantise.vhd` | The adaptive gap classifier (legacy bit source and permanent observer), with the signed-error taps for the margin engine. |
| `CORE/vhdl/physical_fdd/physical_fdd_bits.vhd` | Raw channel-bit rebuild from gap classes, the DPLL bit source, drought filler, the DSKSYNC aligner with the framing hold, and the sync-anchored diagnostic word stream. |
| `CORE/vhdl/physical_fdd/physical_fdd_wfifo.vhd` | The Gray-pointer dual-clock word FIFO, instantiated twice (read, 32 deep; write, 4 deep). |
| `CORE/vhdl/physical_fdd/physical_fdd_writer.vhd` | Serializer, write precompensation, WDATA pulse generation, the WGATE conjunction, the tab qualifier, the abort latch, the drain hold, the write instruments. |
| `CORE/vhdl/physical_fdd/physical_fdd_top.vhd` | The front-end: instantiates the chain and the writer, synchronizes the control context, settle-filters DSKSYNC, generates the chain reset and the framing hold, synthesizes `/RDY`, and carries the capture, scoreboard, margin and seam instruments. |
| `CORE/vhdl/physical_fdd/physical_fdd_diag.vhd` | The read-only register bank at device `0x0104`, registered readout. |
| `CORE/vhdl/adf_track_engine.vhd` | The physical read service (`ST_PHYS_*`, serve-from-sync, session latch), the write episode (bind, inherit, abort level, pacing, tap, interlocks), the raw DSKSYNC export and the served-word counter. Shared with the ADF drives. |
| `CORE/vhdl/main.vhd` | Threads the front-end signals to the engine and Paula, builds the one-hot `phys_mask`, carries the DSKBYTR observation tap. |
| `CORE/vhdl/mega65.vhd` | `drv_decode` (the drive map), the connector pin process with the drain hold, the front-end instance, the diagnostics device and its three writable registers, every `cdc_stable` crossing. |
| `CORE/vhdl/amiga_cold_boot.vhd` | Cold-boots the Amiga on a drive-map change. |
| `CORE/vhdl/globals.vhd` | `C_DEV_AMIGA_FDD`. |
| `CORE/CORE.xdc` | The clock-pair max-delay between `qnice_clk` and `main_clk`. |
| `CORE/Minimig_MiSTerMEGA65/rtl/paula_floppy.v` | The CIA-line muxes, the real index injection, the motor export, the store-signature taps and the DSKBYTR observation surface. Ports threaded through `paula.v`, `minimig.v` and `minimig_m65.v`. |
| `M2M/vhdl/top_mega65-r{3,4,5,6}.vhd` | The thirteen routed floppy pins (`M2M-UPSTREAM floppy-pins`). |
| `CORE/m2m-rom/m2m-rom.asm` | `HWF_STATUS_STEP`, the live status line. |
| `CORE/vhdl/config.vhd` | The `dfN:Hardware Floppy` text lines and the Drive Settings radios. |

### 12.2 Diagnostics register map

Device `0x0104`, word addresses; reach register `n` at `0x7000 + n` after the
device and window selection of section [8.1](#81-reading-it-from-the-qnice-monitor).
All counters wrap at 16 bits unless marked saturating; rate them by diffing two
dumps. "Since clear" means since the last `0x35` bit-15 strobe.

| Reg | Content |
|---|---|
| `0x00` | signature `0xFDD0` (reading it advances the dump nonce) |
| `0x01` | map version, `0x000D` |
| `0x02` | status: bit 0 enable, 1 selected, 2 motor, 3 media ready, 4 spun up, 5 index fresh, 6 index active, 7 `/TRK0`, 8 `/WPROT`, 9 `/CHNG`, 10 `RDATA`, 11 read FIFO full |
| `0x03` | the settled DSKSYNC value the aligner uses |
| `0x04` | quantiser half-cell estimate, Q8.4 (nominal `0x640`) |
| `0x05` | read FIFO fill level, write side |
| `0x06/0x07` | index period, low/high word (cycles) |
| `0x08/0x09` | index low-pulse width, low/high word (cycles) |
| `0x0A` | accepted index edges |
| `0x0B` | DSKSYNC alignment hits |
| `0x0C` | reconstructed words |
| `0x0D` | merged runt gaps |
| `0x0E` | losses of lock (gap class 3), counted in both separator modes |
| `0x0F` | words dropped on a full read FIFO |
| `0x10` | drive map: bit 0 physical unit exists, bits 2:1 its unit number |
| `0x11` | capture flags: bit 0 valid, 1 SIDE at the sync hit, 2 `/TRK0` at the hit, 3 live SIDE, 4 side-invert in force |
| `0x12` | completed sector-header captures |
| `0x13..0x1A` | capture words 0..7: the eight words after the last sync of the double `$4489` (info long odd, even, then label); info = ((odd and `$55555555`) shl 1) or (even and `$55555555`) |
| `0x1B` | physical words served into Paula by the engine |
| `0x1C` | sector-seen mask of the last full revolution, bits 10:0 |
| `0x1D` | last full revolution: captures (15:8), losses of lock (7:0) |
| `0x1E` | captures whose format byte was not `$FF` |
| `0x1F` | write: bit 0 side invert; reads back |
| `0x20` | store signature, engine side |
| `0x21` | bit 8 engine signature done, 7:0 stream-session count |
| `0x22` | store signature, Paula side |
| `0x23` | bit 8 live WORDSYNC, 7:0 Paula read-attempt count |
| `0x24..0x27` | signature checkpoints after 64 and 256 words, engine then Paula |
| `0x28..0x2F` | the first eight words Paula stored in the last attempt |
| `0x30/0x31` | uptime in milliseconds since QNICE reset, low/high |
| `0x32` | dump nonce |
| `0x33` | step pulses toward the mechanism |
| `0x34` | current cylinder, direction-integrated, zeroed on the `/TRK0` assert edge |
| `0x35` | write: the control register of section [8.2](#82-the-runtime-switches); reads back bits 7:0 |
| `0x36` | minimum acceptance margin since clear, Q4 (`0xFFFF` = none yet) |
| `0x37` | estimate at the minimum-margin gap |
| `0x38` | raw length of that gap (cycles) |
| `0x39` | margin status: bits 1:0 class of the minimum-margin gap, 2 armed window open, 3 serving, 4 gate open |
| `0x3A` | armed-sector window openings since clear |
| `0x3B` | gaps histogrammed since clear (saturating) |
| `0x3C` | rejected gaps while gated, since clear (saturating) |
| `0x3D` | sync hits while gated, since clear |
| `0x3E/0x3F` | estimate minimum / maximum since clear |
| `0x40..0x47` | short-class histogram, 8 saturating bins of the signed error over [-tol, +tol) |
| `0x48..0x4F` | medium-class histogram |
| `0x50..0x57` | long-class histogram |
| `0x58..0x5D` | per-sector miss profile, two 8-bit saturating counters per word (`0x58` = sectors 1,0 ... `0x5D` = sector 10) |
| `0x5E` | qualified read revolutions since clear (the profile's denominator) |
| `0x5F` | DPLL cell period, Q8.4 (nominal `0x640`) |
| `0x60` | mid-serve realign events since clear (counted whether taken or suppressed) |
| `0x61` | realign context: 15:8 events with an odd bit-phase remainder, 3:0 the last event's remainder |
| `0x62..0x69` | the eight words emitted before the last mid-serve realign event |
| `0x6A` | 15:8 serving-session count, 7:0 serve-start sector of the last session (`0xFF` = none) |
| `0x6B` | losses of lock while streaming, since clear |
| `0x6C` | losses of lock while not streaming, since clear |
| `0x6D` | index windows excluded from the miss profile because the chain was lost mid-window |
| `0x6E` | framing status: bit 3 realign-always in force, 2 serving data, 1 WORDSYNC, 0 hold in force |
| `0x6F` | unmapped (reads `0xEEEE`) |
| `0x70` | write episodes bound |
| `0x71` | words consumed by the serializer, last episode (latched when the writer returns to idle, so the tail is included) |
| `0x72` | words consumed, running total |
| `0x73/0x74` | WGATE window of the last episode, low/high (cycles) |
| `0x75` | underrun aborts |
| `0x76` | tab-blocked (discard) episodes |
| `0x77` | 15:8 maximum in-flight words at the DSKBLK moment (FIFO plus shift register), 7:0 tail-cut count |
| `0x78` | precompensated pulses, last episode |
| `0x79` | 7:0 the last episode's track; bit 8 completed, 9 aborted, 10 discard, 11 underrun, 12 tail cut |
| `0x7A` | episodes in which WGATE opened |
| `0x7B` | last abort reason, one bit each: 0 deselect, 1 motor or enable lost, 2 write protect, 3 disk change, 4 step, 5 side, 6 underrun, 7 engine abort |
| `0x7C` | write: bits 1:0 precomp mode (`00`/`11` AUTO, `01` on, `10` off); reads back mode, bit 2 precomp active, 3 tab qualified, 4 episode open |
| `0x7D` | write-FIFO overflow count; must read 0 |
| `0x7E..0x7F` | unmapped (`0xEEEE`) |

### 12.3 Constants worth knowing

| Constant | Value | Where |
|---|---|---|
| front-end clock | 50 MHz, 20 ns | `physical_fdd_pkg` |
| channel cell | 100 cycles = 2 µs | `C_HALF_CELL_CYC` |
| nominal gaps | 200 / 300 / 400 cycles | `C_GAP_*_CYC` |
| runt threshold | 16 cycles = 320 ns | `C_GAP_GLITCH` |
| estimate / cell clamp | 90..110 cycles | `C_QUANT_EST_MIN/MAX` |
| quantiser step, tolerance | 1/8 cycle, est/2 | `C_QUANT_STEP_Q`, `C_QUANT_TOL_SHR` |
| DPLL gains | phase err/2, period err/64 | `C_DPLL_PGAIN/FGAIN` |
| drought arm, filler period (legacy) | 512 cycles, 100 cycles | `C_DROUGHT_*` |
| index low floor, stale timeout | 200 µs, 250 ms | `C_INDEX_*` |
| spin-up gate | 505 ms + 2 index edges | `C_READY_*` |
| read FIFO, write FIFO | 32 words, 4 words | `physical_fdd_top` |
| physical burst per frame, empty re-poll gap | 16 words, 127 cycles (core clock) | `adf_track_engine` |
| poll period | ~1 ms (28374 core cycles) | `G_POLL_DELAY` |
| foreign-selection persistence | 100 µs | `C_WR_FOREIGN` |
| WDATA launch, pulse, precomp | cycle 50, 25 cycles, ±7 cycles | `physical_fdd_writer` |
| tab qualification, select settle, revoke filter | 10 ms selected, 50 µs, 4 samples | `C_WPROT_QUAL`, `C_SEL_SETTLE`, `C_FILT` |
| trackdisk read / write DMA | 7358 / 6815 words | Kickstart 1.3 |
| X-Copy DOS write | 6485 words | X-Copy 2.0 |

### 12.4 The connector pins

| Pin | Direction | Driven from / consumed by |
|---|---|---|
| `f_density` | out | constant DD level |
| `f_motora` | out | the physical unit's Minimig motor latch |
| `f_selecta` | out | the unit's CIA select bit, held during the write drain |
| `f_side1` | out | Minimig `side` xor the `0x1F` invert bit, held during the write drain |
| `f_stepdir` | out | Minimig `direc` |
| `f_step` | out | Minimig `step`, gated on the unit being selected |
| `f_wdata`, `f_wgate` | out | `physical_fdd_writer` |
| `f_index`, `f_track0`, `f_writeprotect`, `f_diskchanged`, `f_rdata` | in | `physical_fdd_inputs` |
| `f_motorb`, `f_selectb` | out | tied inactive in the board tops |

---

## 13. Glossary

* **Channel bit, cell** - one 2 µs slot of the MFM stream; a `1` is a flux
  reversal. Two channel bits carry one data bit.
* **Data separator** - the circuit that turns the drive's pulse train back
  into channel bits by tracking the cell period; the DPLL in
  `physical_fdd_bits` is ours.
* **Gap** - the interval between two flux reversals, 2, 3 or 4 cells in valid
  MFM.
* **`DSKSYNC`, WORDSYNC** - Paula's sync pattern register and the `ADKCON`
  bit that makes Paula wait for it and re-frame at it.
* **Write splice** - the point on every written track where the writer's tail
  overlapped its head; a once-per-revolution bit-phase jump that lives in the
  inter-sector gap.
* **Framing hold** - the aligner mode in which word framing free-runs across
  the splice instead of re-anchoring at every sync, engaged while the engine
  serves and WORDSYNC is off.
* **Serve-from-sync** - the engine discarding free-running pre-lock words
  until the FIFO head equals DSKSYNC before serving anything to Paula.
* **Episode** - the lifetime of one `trackwr` assertion in Paula, the unit of
  write-session state; bound once to an owner, dead once aborted.
* **Drain** - the engine's consumption of Paula's write FIFO; several drains
  can serve one episode.
* **Tap** - the one-pulse-per-popped-word stream from the engine to the write
  FIFO (write tap) or from the read FIFO pop to Paula's `DSKBYTR` surface
  (observation tap).
* **Tab qualifier `wr_ok`** - the writer's debounced, selected-time-qualified
  reading of the write-protect line.
* **Drain hold** - the window after DSKBLK during which the select and side
  pins are held so the writer can finish the flux the Amiga already believes
  written.
* **`DSKBYTR`** - Paula's byte-level disk register: `BYTEREADY` (bit 15),
  `WORDEQUAL` (bit 12) and the last raw byte; what Copylock polls.
* **Copylock** - Rob Northen's protection, which times a density-modulated
  track through `DSKBYTR`.
* **X-Copy** - the Amiga's most used disk copier; runs with WORDSYNC on,
  keeps the drive selected, and provides the second field workload besides
  trackdisk.
* **Cylinder, track, head** - 80 cylinders, two heads; Amiga track = cylinder
  times two plus head, so odd tracks are head 1.
* **Mechanism** - the MEGA65's internal 3.5" drive, a PC-style unit with a
  small controller of its own that occasionally powers up confused.
