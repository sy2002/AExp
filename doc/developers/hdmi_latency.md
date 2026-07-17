# HDMI latency vs. the analog output

Side-by-side footage of a MEGA65 driving a CRT (analog out) and an HDMI
flat panel shows the HDMI picture trailing the CRT by several frames —
clearly visible when dragging the Workbench screen title bar. The same
effect shows on the C64 core, which suggested a MiSTer2MEGA65 (M2M)
framework cause. This note traces both video paths through the framework,
measures the observed lag from the available footage, and attributes the
delay to its actual sources.

The short version:

* The M2M HDMI pipeline is **not** a classic frame-buffered scaler. It
  runs the ascal scaler in **single-framebuffer ("Direct") mode**: the
  HDMI read beam races a few scanlines behind the core's write beam in
  one shared HyperRAM buffer.
* With **HDMI: Flicker-free ON** (the default in both AExp and
  C64MEGA65), the core clock is servo-locked to the HDMI output and the
  pipeline adds **≈0.3–1.3 ms** — under one tenth of a frame. The
  C64MEGA65 V5.1 release notes state this outright: flicker-free
  "reduces our output latency on HDMI to less than 1 ms".
* With Flicker-free OFF, the beams drift through each other: latency
  slides between 0 and 2 frames (≈1 frame on average) and a horizontal
  seam crawls through moving content once per beat period (every ~12.5 s
  on the Amiga, ~8 s on the C64). Even this worst case is bounded by
  ≈40 ms.
* The lag measured in the test videos is **70–100 ms** — far more than
  the pipeline can produce in any configuration. **The dominant share
  sits inside the HDMI monitors**, not in our FPGA design. A
  cross-check with the same core on a Samsung HDMI TV (2026-07-17)
  showed nearly no visible lag against the CRT, confirming the
  attribution.
* Consequently there is no meaningful in-pipeline latency left to
  optimize. What remains are the standing regression checks (section
  8), the monitor test protocol (section 7), and user guidance.

Everything below is the supporting detail.


## 1. What was measured

Two videos, both 24 fps camera footage (41.7 ms per camera frame), each
showing the analog output on a CRT (left) and the HDMI output on a flat
panel (right), driven simultaneously by the same MEGA65:

* `latency.mov` — AExp, Workbench 1.3. The user drags the Workbench
  screen title bar up and down; the CRT follows instantly, the HDMI
  panel (a Checkmate display, vendor-claimed "1 frame" latency)
  visibly trails.
* `latency_c64.mov` — C64 core. A BASIC program blinks the border
  (`POKE 53280,1` … `POKE 53280,0`), producing a sharp timing edge on
  both screens.

Method: frames were extracted with ffmpeg; per-frame luminance traces
were computed for each screen region (whole-screen mean for the border
blink, vertical row-profile tracking of the moving title bar for the
drag), and the lag was estimated by edge matching with sub-frame
interpolation (blink) and velocity cross-correlation (drag).

Results:

| Test | Estimate | Notes |
|---|---|---|
| C64 border blink, white→black edges | median **79 ms** (n=9, core cluster 72–81 ms) | tightest data set |
| C64 border blink, black→white edges | ~29 / ~63 ms bimodal (n=6 usable) | panel response + short-flash sampling make rising edges unreliable |
| Amiga title-bar drag, cross-correlation | **+98 ms** (peak at +2.35 camera frames, plateau 2.25–2.40) | onset inspection independently gives 2–3 camera frames |

Honest error bars: the 24 fps camera quantizes to ±20 ms per single
event, the CRT-vs-camera beat makes the CRT track noisy, and LCD panel
response time (black↔white ≈ 5–15 ms) is folded into the numbers. Taking
all of that into account, both setups show a total display-to-display lag
of roughly **3.5–5 PAL frames (70–100 ms)**.

One caveat on attribution: these videos measure the *sum* of our
pipeline and the monitor's internal processing, against a zero-latency
CRT reference. They cannot split the two — that is what the protocol in
section 7 is for. What they *can* prove is a lower bound on the
monitor's share, because our pipeline's worst case is known (section 4).

The split was subsequently confirmed by a third data point: the same
core driving a **Samsung HDMI TV shows nearly no visible lag** against
the CRT (hardware test, 2026-07-17; visual result, not frame-scored).
Same MEGA65, same pipeline, different display — so the 70–100 ms above
belongs to the first two displays, not to the HDMI signal we produce.


## 2. The two output paths

Both outputs are always active and show the same core picture:

```
                                 +--> analog_pipeline ----------------> VGA/CSYNC pins
  core video (15.625 kHz PAL) ---+     video_mixer (scandoubler)
                                 |     video_overlay (OSM)
                                 |     analog_positioner, out-registers
                                 |
                                 +--> digital_pipeline ---------------> HDMI/TMDS pins
                                       ascal scaler via HyperRAM
                                       video_overlay (OSM)
                                       vga_to_hdmi, serializers
```

**Analog path** (`M2M/vhdl/av_pipeline/analog_pipeline.vhd`): the MiSTer
`video_mixer` optionally line-doubles 15.625 kHz to 31.25 kHz (one
scanline of buffering), the OSM overlay and the analog positioner add a
handful of clock cycles, and the output registers add half a video
clock. Total: **≈1–2 scanlines, ≈0.1 ms** in Standard VGA mode, and
practically zero in the two retro 15 kHz modes. A CRT displays the
electron beam as it arrives, so the analog picture is the real-time
reference — this is why the analog output exists in the first place.

**HDMI path** (`M2M/vhdl/av_pipeline/digital_pipeline.vhd`): the core
picture is written into a HyperRAM framebuffer by the ascal scaler's
input side and read back scaled to a fixed standard HDMI mode. AExp
offers 720p 50 Hz (default), 576p 4:3 and 576p 5:4; all three are
mathematically exact 50.000000 Hz (74.25 MHz / 1980 / 750 and
27 MHz / 864 / 625), and because the HDMI MMCM and the core MMCM share
the same 100 MHz oscillator, "exact" means zero-ppm exact, not
approximately. The OSM is overlaid after the scaler (so even the menu is
latency-free on HDMI), and `vga_to_hdmi` plus the serializers add
microseconds.

All potential latency on the HDMI side therefore lives in exactly one
place: the relationship between the ascal framebuffer's **write pointer**
(core side) and **read pointer** (HDMI side).


## 3. The key design fact: single framebuffer, not triple buffering

ascal supports two buffering modes, selected by mode bit 3
(`ascal.vhd` header: `MODE[3]`, 0 = "Direct. Single framebuffer.",
1 = "Triple buffering"). The M2M firmware programs this register through
`M2M$ASCAL_MODE` (0xFFE3), and the HDMI-filter dispatchers of **both**
cores only ever write the plain scaler-algorithm values 0–4
(`HDMI_FLT_TABLE` in `CORE/m2m-rom/m2m-rom.asm`; same structure in
C64MEGA65). `M2M$ASCAL_TRIPLEBUF` (0x0008) is never set.

With `MODE[3]='0'`, ascal forces all four internal buffer indices to
buffer 0 (`ascal.vhd`, "Triple buffer disabled": `o_obuf0<=0; o_obuf1<=0;
o_ibuf0<=0; o_ibuf1<=0;`). Input and output sides address the **same**
memory region starting at `RAMBASE=0`. The HDMI read beam literally
chases the core's write beam through one shared frame image:

```
  HyperRAM framebuffer (one frame, RAMBASE 0)

  0 +------------------------+
    | already rewritten:     |   read beam displays what the write
    | frame k                |   beam deposited a moment earlier
    |........................| <-- read pointer (HDMI, exactly 50.000 Hz)
    |  gap = "write lead"    |
    |........................| <-- write pointer (core, 49.92/50.12 Hz)
    | still frame k-1        |
    |                        |
    +------------------------+
```

This is the same architectural class as MiSTer's low-latency mode
(`vsync_adjust=2`), where the scaler's author quotes ~4–30 *lines* of
lag. The difference is the control knob: MiSTer re-tunes its HDMI PLL to
follow the core (Cyclone V PLLs support glitchless fractional
retuning), while M2M keeps the HDMI clock nailed to a standard mode and
**steers the core clock instead** — which is exactly what the
"HDMI: Flicker-free" feature does.


## 4. The three operating regimes and their latency

### 4.1 Flicker-free ON (default in AExp and C64MEGA65): parked beams

`M2M/vhdl/hdmi_flicker_free.vhd` samples the write pointer once per
output frame, at the instant the read pointer wraps to address 0. If the
write lead is below `G_THRESHOLD_LOW` (0x1000 words = 8 KiB) it asserts
`hr_low_o` ("core too slow"); above `G_THRESHOLD_HIGH` (0x2000 words =
16 KiB) it asserts `hr_high_o` ("core too fast"). The core's two-state
FSM answers by switching between two MMCM clocks:

| | AExp (`mega65.vhd`, `clk.vhd`) | C64MEGA65 |
|---|---|---|
| native core clock | 28.375000 MHz → 49.9201 Hz (below 50) | 31.527778 MHz → 50.1245 Hz (above 50) |
| twin core clock | 28.437500 MHz → 50.0301 Hz (above 50) | 31.448993 MHz → 49.9990 Hz (below 50) |
| `hr_low` (lead too small) | switch to fast twin | switch to native |
| `hr_high` (lead too big) | switch to native | switch to slow twin |
| toggle OFF | native, no dither | native, no dither |

The two legs straddle 50.000 Hz, so the bang-bang loop holds the sampled
write lead inside the 8–16 KiB window indefinitely (limit cycle
≈0.9 Hz on AExp progressive content; the mean core clock becomes exactly
50.000 Hz × 568,408 clocks/frame). For a ~720-pixel stored line
(720 × 3 bytes, packed into 128-byte bursts = 2176 bytes = 1088 words),
the parked window corresponds to **3.8–7.5 input scanlines, i.e.
0.24–0.48 ms of write lead** at the top of every output frame.

Across the rest of the frame the two beams diverge only by the
active/blanking geometry difference (the 720p output spends 19.2 ms of
its 20 ms frame in active video; the core writes its ~288 stored lines
in ≈18.4 ms), which accumulates to at most ≈0.8 ms by the bottom of the
screen. End-to-end HDMI pipeline latency, including the scaler's
read-ahead and the OSM stage:

**≈0.3 ms (top of screen) to ≈1.3 ms (bottom of screen), constant.**

This matches the shipped C64MEGA65 V5.1 release note verbatim: "Fully
dynamic flicker-free HDMI, which reduces our output latency on HDMI to
less than 1 ms and also eliminates the artifact, that moved from the top
to the bottom of the screen every once in a while."

### 4.2 Flicker-free OFF: sliding latency plus the crawling seam

With the servo off the core free-runs at 49.9201 Hz against the exact
50.000 Hz output. The write pointer slips backwards by 32 µs per frame;
the beams cross once per beat period:

| | AExp progressive | C64 PAL |
|---|---|---|
| rate offset vs 50.000 Hz | −0.0799 Hz | +0.1245 Hz |
| beat period (seam interval) | 12.5 s | 8.0 s |

At any instant the screen is split by the crossing point: content above
it is fresh (age ≈ φ), content below is one frame older (age ≈ φ +
20 ms), and φ itself saws from 0 to 20 ms over the beat period. The
visible symptom is the well-known horizontal **seam** that crawls
through moving content every ~12.5 s (Amiga) / ~8 s (C64); the latency
consequence is:

**0–40 ms, position- and time-dependent, ≈20 ms (one frame) on
average.**

Two useful corollaries. First, even this worst case cannot explain the
70–100 ms in the videos. Second, the seam doubles as a **free diagnostic
for the servo**: if scrolling content shows the periodic seam although
Flicker-free is ON, the loop is not engaged (see section 8).

Interlaced content is a special case: the Amiga's alternating 312/313
field pair averages **exactly** 50.000000 Hz (625 × 1816 clocks =
2 × 28,375,000), so laced screens are drift-free even with the servo
off, and the servo settles on the native clock with zero dither. The
weave deinterlacer necessarily displays the previous field's lines at
one field age (20 ms) — that is the nature of weave, identical on
MiSTer, and unrelated to the buffer management discussed here.

### 4.3 Triple buffering: not used, and it must stay that way

If `M2M$ASCAL_TRIPLEBUF` were ever set, latency would rise to the
classic 1–2 frames (20–40 ms sliding) *and* the flicker-free measurement
would break outright: the monitor's "read address wrapped to 0" trigger
assumes the single-buffer layout, and with rotating buffer bases the
sampled write lead would be nonsense. Triple buffering and flicker-free
are mutually exclusive by construction. This invariant is also recorded
in `.research/INTEGRATION-SPEC-hdmi-flicker-free.md` §7; a future
"triple buffering" OSM item would silently destroy both properties.


## 5. So why does the HDMI picture lag by 70–100 ms?

Adding up our side (Flicker-free ON, the shipped default in AExp since
WIP-V1-A6 and in C64MEGA65 since V5.1):

| Stage | Latency |
|---|---|
| core → analog VGA pins | ≈0.1 ms |
| core → HDMI TMDS pins | ≈0.3–1.3 ms |
| difference attributable to M2M | **≈1 ms** |
| difference measured on the monitors | **70–100 ms** |

The remaining ≈70–95 ms happen inside the receiving display. That is
entirely plausible for LCD monitors outside a dedicated low-latency
path:

* **Frame-rate conversion.** Panels that run natively at 60 Hz must
  rate-convert a 50 Hz HDMI input; typical implementations buffer 2–3
  input frames (40–60 ms) and add a variable component that slides with
  the 50/60 beat. The bimodal rising-edge results in the C64
  measurement (~29 vs ~63 ms) look exactly like such a variable
  component sampled at two different beat phases.
* **Scaling/deinterlacing pipelines.** 576p and 720p sources often take
  a TV-style processing path (noise filtering, deinterlacer heuristics,
  overdrive) that costs 1–3 frames even on a "monitor".
* **Panel response** adds another 5–15 ms of visible transition time.

Against that, the vendor claim of "1 frame" for the Checkmate display
in the Amiga video is not what the footage shows: the measured total of
≈95 ms minus our ≈1 ms leaves ≈4–5 frames inside the monitor in the
mode it was actually operating in. Possible benign explanations —
the display may not have been in its low-lag path for this input
timing, may have been rate-converting to a 60 Hz panel mode, or the
"1 frame" figure may refer to a specific input/mode combination (its
vendor pages state no measurable specification we could retrieve).
The Samsung cross-check (section 7) settled the question on our side:
the ≈95 ms is specific to that display in that configuration, not to
the MEGA65's HDMI output.

For perspective, this is the same split MiSTer users see: the FPGA-side
scaler in low-latency mode contributes lines, not frames, and the
end-to-end experience is decided by the attached display. On a CRT (or
a gaming monitor in game mode) MiSTer measures at "less than one frame"
total; on an ordinary office LCD it does not — and neither can we.


## 6. Comparison with MiSTer, for orientation

| | MiSTer | MiSTer2MEGA65 |
|---|---|---|
| scaler | ascal (same author, same core code) | ascal (same, older snapshot) |
| low-latency mechanism | `vsync_adjust=2`: HDMI PLL re-tuned to follow the core's rate/phase (`o_lltune` + `pll_hdmi_adj`) | HDMI clock fixed to a standard mode; **core clock** dithered by the flicker-free servo |
| scaler latency in that mode | ~4–30 lines (per the scaler's author) | ≈0.3–1.3 ms ≈ 5–20 lines — same class |
| why the difference in mechanism | Cyclone V PLLs re-tune fractionally without glitching | Xilinx 7-series MMCMs cannot (DRP reconfiguration drops the clock; dynamic fine phase shift slews only ~hundreds of ppm, we need ±1600 ppm) — so M2M moves the core instead |
| fallback mode | `vsync_adjust=0`: fixed output, buffered, up to 1–2 frames | Flicker-free OFF: beam race free-runs, 0–2 frames sliding + seam |
| "zero-lag" analog | direct video / analog IO board | the VGA/15 kHz analog output |

M2M's `o_lltune` port is left open — nothing is lost by that, since the
core-clock servo replaces the PLL-side mechanism entirely.

One honest asymmetry: with the servo ON the emulated machine runs
0.16 % fast on average (+2.77 cents of pitch, a ~0.9 Hz inaudible
dither); MiSTer's approach keeps the core cycle-exact and bends the
display timing instead. Purists can switch Flicker-free OFF and get the
authentic 49.9201 Hz at the cost of the seam and the sliding 0–40 ms.
Both options exist today; there is no third setting that would be
strictly better on Xilinx silicon (see section 9).


## 7. How to attribute lag correctly: the test protocol

A monitor test separates our share from the monitor's share only if
run like this:

1. **Flicker-free ON** (OSM default), progressive content, HDMI mode
   720p 50 Hz (also repeat with 576p 4:3 — some displays route 576p
   through a slower "SD/TV" path than 720p).
2. **Game Mode ON** on the display under test. This is the single
   biggest variable: on current Samsung TVs it is the difference
   between ≈10 ms and ≈80–120 ms of set-internal delay.
3. Film both screens at the highest camera frame rate available
   (240 fps slow-motion on a phone turns the ±20 ms quantization of
   these first measurements into ±4 ms).
4. Use a hard timing edge, not motion judgment. The C64 border blink
   BASIC program is ideal:

   ```
   10 FOR I=0 TO 300:NEXT I
   20 POKE 53280,1
   25 FOR I=1 TO 10:NEXT
   30 POKE 53280,0
   40 GOTO 10
   ```

   On the Amiga, dragging the Workbench screen works, but a flashing
   full-screen color (e.g. a tiny AMOS/asm flasher writing COLOR00) is
   easier to score frame-exactly.

Expected outcomes:

| Scenario | Expected total lag vs CRT |
|---|---|
| modern TV/monitor in game mode, 720p50 | ≈10–25 ms (mostly the display; our ≈1 ms is negligible) |
| same display, standard picture mode | ≈60–120 ms — the league of the section-1 videos |
| any display, Flicker-free OFF instead of ON | + up to 40 ms, varying over ~12 s, seam visible |

The first row is not just theory: a Samsung HDMI TV driven by the same
core (2026-07-17) showed nearly no visible lag against the CRT, while
the same signal measured 70–100 ms on the two displays of section 1.
That closes the attribution — the pipeline is fine, and the display's
choice and configuration decide the experience. Should a future
display land near 70–100 ms even in its game mode, run the seam check
of section 8 before suspecting the pipeline.

Two further discriminating experiments, if the Checkmate is available
for a second session:

* Feed the **same monitor** on two inputs: MEGA65 VGA/RGB into its
  analog input vs. HDMI. Any lag difference is then pure monitor-side
  HDMI processing (the panel and its base pipeline cancel out).
* Check whether the display has a fast/game/low-latency setting and
  whether it reports the input as 50 Hz (panel OSDs usually show the
  detected mode) — a 60 Hz panel readout on a 50 Hz source proves
  internal rate conversion.


## 8. Verifying the flicker-free servo end-to-end (AExp)

The latency story above assumes the servo actually engages on hardware —
and for AExp this is already verified, not assumed: on R3 (2026-07-09,
TAS-IntroPack side-scroller, the dominant 49.92 Hz progressive case) the
seam crawls with Flicker-free OFF, disappears completely with
Flicker-free ON, and the live toggle switches cleanly; the accompanying
synthesis passed the constraint gate (fast leg timed at 35.165 ns, no
"no pins matched", global WNS positive). So on the hardware generation
the latency video was shot with, the parked ≈1 ms regime is real.

The two checks remain the standing regression procedure for every
future build and board:

* **Seam test (no tools needed).** Horizontally scrolling content
  (e.g. State of the Art intro scroller, or dragging the Workbench
  screen continuously): with Flicker-free OFF a tear/seam must crawl
  through the picture roughly every 12.5 s; switching Flicker-free ON
  must make it disappear completely. "Seam visible in both settings"
  means the FSM never leaves the native clock — then re-check the
  synthesis logs.
* **XDC gate (once per synthesis).** The two flicker-free constraints
  in `CORE/CORE.xdc` (`set_case_analysis` on `hr_core_speed_reg[0]/Q`,
  `create_generated_clock` on `i_clk_fast/CLKOUT0`) silently become
  no-ops if the leaf names drift — Vivado only emits a "no pins
  matched" warning. Any log audit of a new build should grep for that
  warning; an untimed fast leg would not change latency, but it would
  make the servo's fast phase run on unverified timing. R6 has the
  tightest global margin (HyperRAM PHY) and deserves the check most.

If deeper visibility is ever needed: `hdmi_flicker_free.vhd` already
maintains `dbg_min_diff`/`dbg_max_diff`/toggle counters (currently
unconnected). Surfacing them via a QNICE CSR would show the parked
write lead and the limit-cycle rate live from the Shell — a small,
purely additive M2M change, worth doing only if the seam test ever
raises doubts.


## 9. Could we do better than ≈1 ms? (assessed and answered)

Ideas considered for reducing the HDMI-side latency further, and why
none of them is worth pursuing:

* **Tighter servo window.** The parked lead is 8–16 KiB because the
  window must swamp the interlace ±1-line wobble and leave margin
  against the scaler's read-ahead. Halving it would save ≈0.2 ms and
  risk read-overtakes-write corruption. Not worth it.
* **True output-side genlock (MiSTer-style).** Would let purists keep
  the exact 28.375 MHz core *and* have a locked, seam-free picture. On
  Xilinx 7-series this requires either glitch-full MMCM DRP
  reconfiguration (drops the HDMI link) or dynamic V-total/porch
  "breathing" (off-spec timing some sinks re-sync on). High effort and
  risk to replace a shipped mechanism that already achieves the same
  latency. Documented here precisely so the idea does not get
  re-invented; not recommended.
* **Scaler bypass ("direct video" over HDMI).** Line-double 15.625 kHz
  to a 49.92 Hz pseudo-576p and skip the framebuffer entirely. Would
  save well under a millisecond versus the parked beam race, cost a
  parallel output path with its own OSM injection, and produce
  off-spec 49.92 Hz timing that some displays reject. Obsolete now
  that the beam-race latency is known; the analog output already
  serves the zero-latency use case.
* **Anything frame-buffered** (motion interpolation, latency
  "compensation", vsync re-alignment) only adds frames. Rejected on
  principle.

The honest conclusion: at ≈0.3–1.3 ms the M2M HDMI pipeline is within a
scanline-count of the theoretical minimum for a scaled output. The
end-to-end experience on HDMI is decided by the display; the analog
output remains the reference for latency-critical use, which is exactly
what `doc/retrotubes.md` recommends to users for other reasons as well.


## 10. References

Repository:

* `M2M/vhdl/av_pipeline/ascal.vhd` — scaler; `MODE[3]` semantics in the
  header, single-buffer forcing in the "Triple buffer disabled" clause.
* `M2M/vhdl/av_pipeline/digital_pipeline.vhd` — ascal instantiation
  (`RAMBASE=0`, `RAMSIZE` = one frame, `o_lltune` open, OSM after
  scaler).
* `M2M/vhdl/hdmi_flicker_free.vhd` — write-lead monitor; thresholds in
  `M2M/vhdl/av_pipeline/av_pipeline.vhd` (0x1000/0x2000).
* `M2M/vhdl/av_pipeline/analog_pipeline.vhd` — analog path (scandoubler,
  OSM, positioner).
* `CORE/vhdl/clk.vhd`, `CORE/vhdl/mega65.vhd` — dual-MMCM core clock and
  the two-state servo FSM (AExp); the C64MEGA65 repository contains the
  mirror-image implementation.
* `CORE/m2m-rom/m2m-rom.asm` `HDMI_FLT_TABLE` — proof that
  `M2M$ASCAL_TRIPLEBUF` is never set.
* `.research/INTEGRATION-SPEC-hdmi-flicker-free.md` — exact rate
  derivations (49.920128 / 50.080128 / 50.000000 Hz), threshold and
  dither analysis (local research note, not tracked).

External:

* C64MEGA65 `VERSIONS.md`, V5.1: "Fully dynamic flicker-free HDMI, which
  reduces our output latency on HDMI to less than 1ms …" — the shipped
  confirmation of the beam-race analysis, plus the user-facing
  explanation at
  <https://c64.mega65.org/hdmi-and-analog-output.html#the-hdmi-flicker-free-option>.
* MiSTer video configuration and lag documentation:
  <https://mister-devel.github.io/MkDocs_MiSTer/basics/video/> and
  <https://mister-devel.github.io/MkDocs_MiSTer/advanced/lag/>
  (`vsync_adjust=2`, "around 4 to 30 lines of lag" per the scaler's
  author), plus the original sub-frame lag report at
  <https://retrorgb.com/mister-hdmi-core-now-sub-1-frame-of-lag.html>.
* Measurement footage: `latency.mov` (AExp vs. Checkmate display),
  `latency_c64.mov` (C64 core border blink), both 2026-07-17; plus the
  Samsung HDMI TV cross-check of the same date (visual result: nearly
  no lag vs. the CRT).
