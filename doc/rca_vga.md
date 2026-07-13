# RCA: Alpha 6 analog screen centering moves the OSM, not the Amiga picture

Date: 2026-07-12

Affected release: `WIP-V1-A6` (`d43ae8c`)

Feature commit: `3d4e6dc` (`Add VGA screen centering, decoupled from HDMI (#5)`)

Scope: root-cause analysis only; no implementation change is made here.

Repository history places the feature commits before `WIP-V1-A5`; Alpha 6
inherits the same analog implementation. No relevant analog-pipeline change was
made between the Alpha 6 tag and the current source.

## Executive conclusion

Inspection found no loader or transport defect. The reported OSM response proves
that non-zero values from `/amiga/aexp_screen.cfg` reach and affect the analog
video logic. Alpha 6 also faithfully ports the *soft-blank* equations from
MiSTer's Minimig. It does **not**, however, deliver the documented analog result:
moving the actual Amiga picture.

The analog offsets currently move the edges of an internal blanking/Data Enable
(DE) mask. In the direct 15 kHz modes they change neither Amiga RGB timing nor
sync timing, so pixels can be hidden or revealed but not translated. Standard
31 kHz does replay RGB through a line doubler, but data and regenerated sync are
both derived from the same adjusted HBlank origin; there is still no independent
control of RGB-to-sync phase. The reported hardware confirms the resulting lack
of dependable core-picture pan.

The OSM is different: AExp generates its analog OSM *after* the adjusted mask
and derives the OSM's coordinates from the adjusted DE edge. Moving DE therefore
moves the OSM's coordinate origin. The reported symptom—configuration loads,
the OSM moves, but the Amiga picture does not—is the exact signature predicted
by the RTL.

So there are three different answers to “did we implement it as intended?”:

| Meaning of “intended” | Verdict |
|---|---|
| File parsing, CFD transport, and application | **No defect found; OSM response confirms application** |
| All four mode-classification boundaries | **Code is coherent; not exhaustively hardware-verified by this RCA** |
| The soft-blank construction prescribed by the integration spec | **Yes at algorithm level** |
| The user-visible promise in `doc/screen_adjust.md`: pan the actual analog Amiga picture | **No** |
| MiSTer's end-to-end deterministic scaled-output behavior on the analog path | **No**—the copied block is present, but its coordinate-remapping scaler context is not |

This is not primarily a sign, file-format, CDC, or tuning-constant bug. It is an
architectural category error: **a soft-blank/DE window control—whose
deterministic reframing on MiSTer's scaled outputs depends on a downstream
scaler—was treated as a direct-analog raster-position control. Those are
different operations.**

Confidence in the root cause is high. It follows directly from the signal
topology and explains the observed split between OSM and core content.

## 1. What Alpha 6 promised

The current user contract is unambiguous about the desired outcome: analog
adjustment is supposed to move the Amiga picture.

- HDMI and analog are independently adjustable
  (`doc/screen_adjust.md:38-47`, `README.md:273-283`).
- “VGA” is defined as shorthand for the analog connector
  (`doc/screen_adjust.md:49-51`), while the README exposes Standard plus two raw
  15 kHz modes on that connector (`README.md:250-271`). The guide does not
  qualify its centering promise by mode, so a user reasonably reads it as
  applying to all three. The integration spec, however, reasons mainly about a
  scandoubler. That omission is a requirements ambiguity.
- Analog values are said to move the active-picture edges
  (`doc/screen_adjust.md:207-227`).
- Moving `hbl_l` and `hbl_r` together is specifically promised to slide the
  whole picture without changing its size (`doc/screen_adjust.md:229-240`).
- The summary table calls analog behavior “slides the active picture” and says
  that it can pan (`doc/screen_adjust.md:251-260`).

Only moving the OSM does not meet that contract. The OSM is framework UI, not
the Amiga picture.

### 1.1 The integration spec needs careful reading

`.research/INTEGRATION-SPEC-screen-centering.md` contains more than one design.
Its dated update at lines 6-20 supersedes the older HDMI output-window design:
the shipped HDMI implementation correctly uses an ascal **input crop**. Older
HDMI descriptions later in that file are historical.

The VGA part was never closed to the same standard. The spec prescribes a port
of MiSTer's soft blank at lines 159-168, but explicitly leaves its constants and
zero-offset reconstruction for hardware verification at lines 172-176. It does
not prove that changing a blanking envelope can translate pixels on a physical
analog link.

It also places the VGA logic in `CORE/vhdl/main.vhd`, whereas the final feature
commit deliberately moved it into the core-agnostic framework
`M2M/vhdl/av_pipeline/av_pipeline.vhd`. That relocation preserves HDMI isolation,
but it is another place where the “locked” build description no longer matches
the shipped design.

There are also stale transport details in the spec (two v1 `.bin` files and one
mode at lines 95-117). Alpha 6 actually uses one v3 `aexp_screen.cfg`, four mode
rows, and eight signed words per row. That current format is implemented
consistently by `aexp_screen_cfg.py:70-117` and
`CORE/m2m-rom/m2m-rom.asm:1188-1206`.

These inconsistencies are not the cause of the failure, but they helped obscure
which statements were requirements, which were historical, and which still
needed an analog hardware proof.

## 2. What Alpha 6 actually implements

### 2.1 There is no evidence of a data-path failure

The configuration path is coherent end to end in the inspected source:

1. Firmware reads and validates the v3, four-row table
   (`CORE/m2m-rom/m2m-rom.asm:1188-1266`).
2. It detects lores/hires and progressive/interlaced geometry
   (`CORE/m2m-rom/m2m-rom.asm:1303-1378`).
3. It pushes the selected VGA row into CFD words 0-3
   (`CORE/m2m-rom/m2m-rom.asm:1394-1415`).
4. The framework maps the low 12 bits of those four words to the analog edge
   controls (`M2M/vhdl/framework.vhd:936-941`).
5. The controls cross into the video clock domain
   (`M2M/vhdl/av_pipeline/av_pipeline.vhd:339-379`) and are latched per frame
   (`M2M/vhdl/av_pipeline/av_pipeline.vhd:538-544`).

Seeing the OSM react is end-to-end evidence that a non-zero row reached the video
logic. It does not by itself verify every classification boundary, but it rules
out a general loader or CFD failure as the cause of this symptom.

### 2.2 The analog control changes only blanking

The soft-blank block reconstructs active-window edges and produces
`analog_hblank` and `analog_vblank`
(`M2M/vhdl/av_pipeline/av_pipeline.vhd:475-546`). The analog pipeline then gets:

- the original core RGB (`av_pipeline.vhd:562-564`);
- the original HSYNC and VSYNC (`av_pipeline.vhd:565-566`); and
- only the substituted HBlank/VBlank (`av_pipeline.vhd:567-569`).

The downstream mixer receives that same combination at
`M2M/vhdl/av_pipeline/analog_pipeline.vhd:134-157`.

Outside the resulting DE window, AExp replaces mixer RGB with zero
(`analog_pipeline.vhd:159-172`). The soft-blank block itself has no independent
pixel-translation control. The MEGA65 VDAC blank input is not carrying this
internal DE; it is hard-wired inactive at `analog_pipeline.vhd:241-250`. At the
connector the display gets RGB plus HS/VS, or RGB plus CSYNC. The black RGB
interval is physically present and may influence a flat panel's active-area
guessing, but there is no separate DE/active-window command on the wire.

For the two scandoubler-bypassed 15 kHz modes, the physical invariant is:

```text
analog position of a landmark = time(landmark RGB) - time(sync reference)
```

The current offsets change neither term in those direct modes. They change only
whether RGB is forced to black around the landmark:

```text
RGB_direct_out(t) = adjusted_DE(t) ? RGB_core(t) : black
```

For every direct-path landmark that remains visible, its phase relative to sync
is unchanged. Two blank edges moving together may move a *logical rectangle*,
but that is not a physical pan on an analog wire.

Standard 31 kHz is less direct because the line doubler buffers/replays RGB and
regenerates sync. Its separate common-origin analysis is in section 3; it does
not use the direct-path equation above.

### 2.3 Why the OSM moves

The analog OSM is composed after the mixer
(`M2M/vhdl/av_pipeline/analog_pipeline.vhd:174-206`). Its coordinate recovery
uses the adjusted mixer DE:

- horizontal position resets on the rising DE edge
  (`M2M/vhdl/av_pipeline/vga_recover_counters.vhd:56-60`);
- vertical position advances only for a line seen as active
  (`vga_recover_counters.vhd:64-78`); and
- the recovered coordinates drive OSM placement
  (`M2M/vhdl/av_pipeline/video_overlay.vhd:78-133`).

Consequently:

```text
adjust blank edge
    -> adjust mixer DE
        -> change recovered OSM origin
            -> OSM pixels are generated at a different time

adjust blank edge
    -> direct 15 kHz: mask RGB without changing RGB or sync timing
    -> Standard 31 kHz: derive replayed RGB and sync from one moved origin
        -> no independent Amiga-landmark-to-sync phase control
```

The OSM is not being “moved instead of” the core by a bad mux. It is newly drawn
from a coordinate system that the feature moves, whereas the core pixels already
exist in a timing system that the feature leaves alone.

## 3. Behavior by AExp analog mode

The documentation groups three electrically different modes under “VGA.” The
RCA must not assume that a result in one mode proves the other two.

| AExp mode | Relevant pipeline | What the current offsets can reliably do | True core pan? |
|---|---|---|---|
| Standard, 31 kHz | MiSTer line doubler + DE mask + OSM | Change/crop the reconstructed active envelope; move the OSM origin | **No dependable pan; fails on the reported hardware** |
| 15 kHz HS/VS | Direct RGB/sync path + DE mask + OSM | Black/reveal edge samples; move the OSM origin | **No** |
| 15 kHz CSYNC | Same direct path, then CSYNC generation | Same as HS/VS | **No** |

The raw 15 kHz case is conclusive: with the scandoubler bypassed, the mixer
selects unmodified RGB and sync; blanking only controls DE
(`M2M/vhdl/controllers/MiSTer/video_mixer.sv:174-176,207-223`).

The Standard path does contain a line buffer, but it is a line doubler rather
than an independently positioned 2D scaler. It derives its output data window
and regenerated sync from the same adjusted HBlank origin
(`M2M/vhdl/controllers/MiSTer/scandoubler.v:149-204`). Moving that common origin
does not create an independent RGB-to-sync phase control; the origin term
cancels conceptually:

```text
pixel phase from output origin - sync phase from output origin
= (pixel - HBlank origin) - (sync - HBlank origin)
= pixel - sync
```

Fixed pipeline latency does not create a programmable pan. Cropping can change,
but a surviving source landmark is not guaranteed to translate. The hardware
result confirms that this does not provide the promised pan in AExp.

An analog flat panel's “Auto” function might react to changed black borders and
make some settings appear to move the picture. That would be monitor-specific
active-area guessing, not a deterministic AExp feature. A CRT will be governed
directly by RGB-to-sync phase.

## 4. What MiSTer really does

MiSTer's README documents its screen-adjustment UI at
`CORE/Minimig_MiSTerMEGA65/README.md:36-45`. Its core implementation is indeed
the source of Alpha 6's soft-blank logic:

- raw Minimig video enters at `Minimig.sv:592-605`;
- `hbl_l/hbl_r/vbl_t/vbl_b` construct `hde/vde` at `Minimig.sv:755-840`;
- the mixer receives raw RGB and sync, but adjusted HBlank/VBlank, at
  `Minimig.sv:681-699`; and
- values are exchanged through `hps_ext.v:165-182`.

The important fact is not just where the block starts, but what consumes its DE.

### 4.1 Why it visibly affects MiSTer's scaled picture

MiSTer's system ascal consumes the adjusted `hde_emu` as its input DE with
`iauto=1` (`CORE/Minimig_MiSTerMEGA65/sys/sys_top.v:714-786`). The scaler treats
the DE rectangle as source coordinates, discards its absolute phase within the
original raster, and maps the selected rectangle into a fixed output box. The
implementation resets its input horizontal counter on DE rise, measures the
right edge on DE fall, and selects the measured limits in auto mode
(`CORE/Minimig_MiSTerMEGA65/sys/ascal.vhd:1263-1281`).

Changing soft blank therefore changes which core pixels become scaler x=0..N.
The scaled core picture is visibly reframed, cropped, and possibly zoomed. This
is the success normally seen on MiSTer's HDMI output. When MiSTer's **VGA
Scaler** is enabled, analog VGA is sourced from that same scaled stream
(`sys_top.v:1473-1487,1516-1525`), so it works there too.

MiSTer's HDMI OSD is added after scaling (`sys_top.v:1183-1200`), so it stays in
the fixed output frame rather than being used as a source-coordinate marker.

### 4.2 MiSTer's direct analog path has the same limitation

With VGA Scaler disabled, MiSTer's direct path is core stream -> scanlines ->
VGA OSD -> `vga_out` (`sys_top.v:1381-1425,1492-1525`). `vga_out` pipelines RGB,
DE, and sync equally; it has no positioning buffer
(`CORE/Minimig_MiSTerMEGA65/sys/vga_out.sv:63-71`).

Its OSD also measures and resets from DE (`sys/osd.v:102-121,192-203`), so direct
MiSTer can show the same “OSD moves, core does not” signature. MiSTer's README
documents adjustment without specifying guarantees for each output path.

The comparison is therefore:

| Stage | MiSTer scaled output | MiSTer direct analog | AExp HDMI | AExp analog |
|---|---|---|---|---|
| Soft blank changes source DE | Yes | Yes | Separate explicit crop | Yes |
| Framebuffer/coordinate scaler re-indexes that source rectangle | **Yes** | No | **Yes** | No |
| Existing core pixels change phase relative to analog sync | Not relevant after scaling | No | Not analog | **No** |
| Actual content visibly reframes | **Yes** | Crop only / monitor-dependent | **Yes** | Crop only / monitor-dependent |

Alpha 6 copied MiSTer's DE-window code, but not the end-to-end scaled-output
context that makes it a deterministic reframe. The feature commit feeds the new
blanking **only** to the analog pipeline, not to a framebuffer/coordinate scaler.
In the examined MiSTer design, ascal is the relevant consumer that turns this DE
change into deterministically reframed content.

## 5. Why HDMI succeeds

The HDMI half is architecturally sound because it uses a real source-coordinate
operation:

- measured input size and signed edges build an explicit crop rectangle
  (`M2M/vhdl/av_pipeline/digital_pipeline.vhd:276-321`);
- ascal runs with `iauto='0'` and receives that rectangle
  (`digital_pipeline.vhd:451-464`); and
- the selected source rectangle is scaled into a fixed output window.

Absolute source timing is discarded by the framebuffer/scaler, so asymmetric
crop changes which content fills the display. It is a reframe plus zoom, not a
pure pan, exactly as the current guide explains at
`doc/screen_adjust.md:161-205`.

This also demonstrates why “the same style of four edges” does not imply “the
same physical operation” on analog.

## 6. Root cause and contributing factors

### Root cause

The design equated **moving DE/blanking** with **moving an analog picture**.
That operation becomes a deterministic reframe when a downstream
coordinate-remapping scaler uses DE as a new source rectangle. It is only a
mask/crop on a direct RGB + sync connection.

### Contributing factors

1. **MiSTer was compared at block level, not end to end.** The soft-blank RTL
   was ported accurately, but the deterministic behavior of MiSTer's scaled
   output depends on the downstream ascal stage, which AExp analog does not use.
2. **The documentation overstates what the analog signal communicates.**
   `doc/screen_adjust.md:209-214` says AExp tells the analog monitor where the
   active picture starts and stops. There is no DE pin on this link, and the
   VDAC blank input is hard-wired inactive. AExp emits black RGB intervals plus
   sync; those can be detected heuristically by a flat panel but are not an
   independent raster-position command.
3. **Three analog modes were collapsed into one requirement.** The design text
   reasons mainly about the scandoubler, while Alpha 6 also supports two direct
   15 kHz modes and the screen-adjustment guide does not exclude them.
4. **OSM motion was an attractive false positive.** It proves the adjusted DE
   reached the overlay coordinate recovery, not that core RGB moved.
5. **The analog acceptance criterion remained implicit.** The spec left
   hardware tuning open and supplied no test based on an identifiable core
   landmark's phase relative to sync.
6. **Official presets could not expose the defect.** Both
   `aexp_screen.cfg_16_9` and `aexp_screen.cfg_4_3` contain zero for all VGA
   fields in all four rows. The guide explicitly says the presets leave analog
   untouched (`doc/screen_adjust.md:89-92`). Alpha 6's shipped artifacts
   therefore exercised HDMI, not the analog claim.
7. **There is no dedicated soft-blank simulation.** No repository testbench
   asserts that equal edge changes translate a core landmark while preserving
   its width.

### Five-whys summary

1. Why did only the OSM move? Its coordinates reset from adjusted DE; core RGB
   timing does not.
2. Why was there no independent core RGB-to-sync phase change? Direct 15 kHz
   only changes the mask; Standard derives replayed RGB and sync from the same
   adjusted origin.
3. Why was blanking expected to pan? MiSTer's soft blank visibly reframes its
   scaled output when ascal consumes the adjusted DE.
4. Why did that inference fail on AExp analog? AExp analog has no
   framebuffer/coordinate-remapping scaler that re-indexes the DE rectangle.
5. Why was this not caught before Alpha 6? Analog hardware verification was
   left open, shipped presets used zero analog offsets, and the acceptance test
   did not distinguish OSM movement from core-pixel movement.

### Secondary robustness findings (not the root cause)

- `p_vga_softblank` has no `video_rst_i` branch
  (`M2M/vhdl/av_pipeline/av_pipeline.vhd:498-546`). Its counters, learned
  geometry, flags, and latched offsets rely on power-up initializers and signal
  edges to recover after a video/core reset. A redesign should have an explicit,
  safe reset/acquisition state.
- The 12-bit offset arithmetic wraps, and the RTL does not clamp a requested
  edge to a reachable point in the measured line/frame. The helper accepts the
  full signed 12-bit range and only warns above 32 for VGA
  (`aexp_screen_cfg.py:91-96,272-281`). An unreachable compare can leave a blank
  flag asserted, consistent with the documented “VGA picture disappears”
  recovery case. This can cause a blackout, but it does not explain stationary
  core pixels while the OSM moves.
- Units are contradictory. The integration spec calls horizontal VGA values
  signed lores pixels (`.research/INTEGRATION-SPEC-screen-centering.md:74-79`),
  while the helper describes the VGA values generally as approximately
  quarter-lores-pixel steps (`aexp_screen_cfg.py:40-45`). In RTL, the horizontal
  counter advances every 28.375 MHz video clock—four counts per lores pixel
  before the line doubler—but the vertical counter advances in lines. A
  successor format must define axis-specific source units and conversion into
  each final analog mode.

## 7. Recommended route to a real analog success

### 7.1 Preferred low-storage candidate: programmable porch/sync phase after compositing

For a direct analog display, change the phase of sync relative to the final RGB
stream. In video-timing language, redistribute front and back porch while
keeping the line/frame totals and sync widths constant.

A promising insertion point is **after the analog OSM has been composited and
before CSYNC generation / the output pins**:

```text
core RGB + raw timing
        -> optional line doubler
        -> compose OSM
        -> analog positioner: adjust HS/VS phase, preserve totals and widths
        -> generate CSYNC from adjusted HS/VS
        -> VDAC / connector
```

At that point the positioner changes core and OSM RGB-to-sync phase together. It
is also common to Standard 31 kHz, 15 kHz HS/VS, and 15 kHz CSYNC. A CRT should
turn that phase change directly into displacement; an analog-input LCD may
auto-position or normalize porch changes, so visible behavior still needs the
display matrix in section 8.

Requirements for that block:

- move both edges of HSYNC together; never change pulse width, polarity, or line
  period;
- move both edges of VSYNC together; never change pulse width, polarity, or
  field rate;
- preserve interlace field alternation and VS's field-dependent sub-line phase;
  validate the complete RGBHV and CSYNC serration/equalization waveforms rather
  than regenerating VS from whole-line counts alone;
- apply new values at a field-safe boundary (define whether that means every
  field or a complete two-field frame);
- guarantee minimum front porch, back porch, and black guard on both axes with
  conservative clamps;
- generate CSYNC *after* phase adjustment;
- keep HDMI and its mode detector on the unmodified source timing;
- define units at the final analog raster, not vaguely as “VGA pixels”; and
- provide a zero-offset bypass that is timing-equivalent to Alpha 6 with this
  feature disabled.

A signed phase control needs more than delaying today's edge. An “advance” must
be scheduled from the previously measured stable line/field period. The design
therefore needs acquisition and lock states, mode-change/loss-of-lock recovery,
modulo scheduling when a pulse crosses a line or field boundary, and periodic
anchoring to the source so phase error cannot accumulate.

This candidate should be cheaper than translating RGB because it needs timing
measurement and edge scheduling rather than a frame-sized pixel store. That is
a design hypothesis to prove, not a completed design. A first experiment does
not need a full UI: one fixed, easily visible HS phase change can validate the
principle and the monitor response.

For Standard mode only, a smaller prototype could add an independent offset to
the scandoubler's generated `hs_start/hs_end` while leaving its data read window
and HBlank schedule untouched. Both pulse edges must use modulo-line arithmetic;
a plain unsigned addition is unsafe at wrap. This would not solve either direct
15 kHz mode, so the common final positioner remains the better candidate for the
product architecture.

### 7.2 Preserve useful four-edge semantics by separating common and differential motion

The current four analog fields can still express something useful if their
common-mode and differential-mode components drive different mechanisms.

For horizontal values `L` and `R`:

```text
pan_x       = (L + R) / 2       -> sync/porch phase (true translation)
left_crop   = L - pan_x         -> optional soft blank
right_crop  = R - pan_x         -> optional soft blank
```

The same decomposition applies vertically. Then:

- equal edge changes produce pure pan, as the guide promises;
- opposite edge changes produce crop/extent changes; and
- a one-edge change naturally combines half pan with half crop.

The arithmetic must sign-extend both 12-bit inputs before addition and define
rounding for odd sums. The external sign convention should describe visible
motion (for example, positive = right/down), then convert it to the generally
opposite sync-phase direction. It must also convert config units separately to
the final 31 kHz and 15 kHz raster clocks.

This decomposition is conceptually clean, but the present MiSTer-compatible
`vbl_b` has an odd positive “absolute” mode, and the current unit descriptions
already conflict (section 6). A file-format v4 with explicit signed edge or
`pan_x/pan_y/crop_*` semantics would be safer than silently changing v3.
Firmware can continue reading v3 as legacy crop-only data or migrate it with a
clearly documented rule.

### 7.3 Alternative: route a scaled stream to analog

A MiSTer-like optional **VGA Scaler** mode could send the already scaled digital
stream to the analog DAC. It would make DE crop visibly reframe the core and may
be attractive for analog-input LCDs.

It is not a complete replacement:

- it would not preserve authentic 15 kHz CRT output;
- it may couple analog geometry to the HDMI mode/crop;
- it changes latency and interlace behavior; and
- it cannot satisfy SCART/15 kHz users.

Treat it as an additional output mode, not the fix for native analog centering.

### 7.4 Alternative: translate RGB with storage

A post-overlay raster shifter can keep sync fixed and move final RGB instead.
Horizontal movement needs a line FIFO or circular line buffer. Bidirectional
movement needs baseline delay or look-ahead; vertical movement needs multiple
line stores or a framebuffer. This is deterministic and flexible, but costs
more memory, control logic, and latency than porch/sync phase adjustment.

### 7.5 Approaches that will not solve the root cause

- More tuning of `fhbl/shbl/fvbl/svbl` constants cannot turn a mask into a
  translation.
- Moving only the OSM in the opposite direction can disguise one test image but
  leaves core timing unchanged.
- Changing Amiga DIW/DDF or beam behavior would be core-specific, software
  visible, and risky for compatibility; analog positioning belongs after the
  emulated machine.
- Relying on a monitor's Auto Adjust is nondeterministic and excludes CRTs.

## 8. Required validation before calling the analog feature complete

The acceptance test must observe core content and OSM separately. A convenient
test image should contain a distinctive vertical line, horizontal line, and
fixed-size rectangle in the Amiga-generated RGB—not only in the framework OSM.

### 8.1 Core pan invariants

For equal horizontal edge values `+N/+N` and `-N/-N`:

- the core landmark moves in the requested direction;
- the distance between two core landmarks is unchanged;
- HSYNC width and total line period are unchanged; and
- after defining/converting the request in final-raster clock units, the measured
  landmark-to-HSYNC phase changes by that amount.

Repeat the analogous test vertically and verify frame rate, VSYNC width, field
parity, field-dependent sub-line timing, and the complete shifted VS/CSYNC
waveform including interlace serration/equalization behavior.

### 8.2 Mode matrix

Run the invariants with OSM closed and open for:

- Standard 31 kHz;
- 15 kHz HS/VS;
- 15 kHz CSYNC;
- lores progressive;
- hires progressive;
- lores interlaced; and
- hires interlaced.

When OSM is open, core and OSM must move together under pan. If the OSM moves but
the core landmark does not, the test fails.

### 8.3 Independence and safety

- Changing analog fields must not alter HDMI pixels, HDMI crop, ascal geometry,
  or mode classification.
- Zero values must be pixel- and timing-equivalent to the pre-positioner output.
- Boundary values must clamp safely and must not move sync into visible color.
- Live reload must change at a defined field-safe boundary without malformed
  sync pulses.
- CSYNC must be regenerated from the final adjusted HS/VS.
- Test on a CRT and at least two analog flat panels; do not use Auto Adjust as
  the pass criterion.

An oscilloscope or ILA capture makes the decisive assertion simple: measure the
time from a sync edge to a distinctive non-black core transition. Alpha 6 changes
DE/black edges and OSM transitions; a successful fix must change the core
transition's phase too.

## 9. Release/documentation disposition

Until a true analog positioner passes the matrix above:

- reopen or keep incomplete the analog half of issue #5; HDMI remains complete;
- keep the official preset VGA values at zero;
- treat Alpha 6 analog offsets as unsupported/experimental and consider hiding
  or deprecating their editor fields until a supported behavior is defined;
- explain that the current internal DE mask blackens/crops RGB and may perturb a
  flat panel's active-area detection, but is not an independent position command;
- do not call equal `hbl_l/hbl_r` motion “rock-solid” analog pan; and
- distinguish Standard, 15 kHz HS/VS, and 15 kHz CSYNC behavior explicitly.

The correction needs to cover every current claim surface, not only this RCA:
`README.md:273-283`, `doc/screen_adjust.md`, the help and argument text in
`aexp_screen_cfg.py`, the release table in `doc/inofficial.md`, and the project
status in `CLAUDE.md`. In particular, `doc/screen_adjust.md:301` currently says
the method gives full control over both outputs.

The HDMI feature can remain advertised: its implementation uses the correct
scaler input-crop lever and is independent of this RCA.

## Final verdict

Alpha 6 implemented the written MiSTer-style soft-blank algorithm, but the
specification selected the wrong analog primitive for the promised outcome.
The deterministic success of MiSTer's scaled output comes from a downstream
scaler turning adjusted DE into a new source rectangle. AExp's analog path has
no framebuffer/coordinate-remapping stage of that kind.

The current result therefore “works as coded,” but **not as the feature is
intended or documented**. The preferred first experiment is an analog-only,
post-OSM programmable sync/porch phase control, with the existing soft blank
retained only for cropping if desired. It must still prove signed scheduling,
porch safety, interlace/CSYNC fidelity, and real-display behavior before it can
be selected as the final design.
