# RCA — VGA / analog screen centering does not move the picture (Issue #5)

**Status:** Root cause established and proven by cycle-accurate simulation
against the real MiSTer RTL, then independently reproduced by three separate
adversarial testbenches and confirmed by a code-only trace. **Verdict: the
VGA/analog "screen centering" can only crop the picture, never pan it. This is
an architectural limitation the design inherited from MiSTer, not a coding
mistake.** A validated fix (shift the analog sync, not the blank) and an
honest interim option are proposed at the end.

---

## 1. The symptom

On the analog output, changing the VGA offsets in `aexp_screen.cfg` moves the
**on-screen menu (OSM)** but produces **no visible change to the actual core
picture** (Workbench, games, demos). Confirmed by sy2002 in **Standard VGA
mode (scandoubler on)**, with *literally zero* change to the core picture — only
the OSM slides. HDMI centering, by contrast, works end-to-end.

The data path is not the problem. The firmware reads the file, validates it,
and pushes the four VGA words into the CFD `gp_reg` (words 0–3); the CDC
carries them into the video domain; `p_vga_softblank` consumes them and the DE
window visibly reacts (that is why the OSM moves). Everything up to and
including "the soft-blank is doing something" works. The defect is purely in
**what the soft-blank can and cannot do to an analog picture.**

---

## 2. Was it implemented as intended?

**Yes — the code faithfully implements the design.** `p_vga_softblank`
(`M2M/vhdl/av_pipeline/av_pipeline.vhd:498-546`) is a line-by-line
transliteration of MiSTer's `Minimig.sv:755-840` soft-blank: it reconstructs
the active window from the raw H/V blank and sync edges and trims it by four
signed per-edge offsets, exactly as the spec's Increment 2 prescribes. The
transport, the per-Amiga-mode table, the decoupled "feeds only the analog
pipeline" wiring — all present and correct.

**But the design's premise is wrong.** The spec
(`.research/INTEGRATION-SPEC-screen-centering.md` §0) states:

> *VGA → scandoubler, positioned by back-porch … Move those start and stop
> points and the picture slides around inside the frame.*

That is not how the scandoubler behaves. Moving the blank moves the DE window
and the OSM, but it **does not move the core content relative to the output
sync**. The implementation is a correct realization of an incorrect
assumption.

This is the *same class of defect the project already hit — and fixed — on
HDMI.* The original HDMI design (spec §1/§3, now marked "historical") biased
the ascal **output** window and "could NOT re-center" because ascal
auto-centers whatever sits in that window. On 2026-07-08 that was abandoned
for ascal **input**-crop (source-rectangle selection, `iauto=0`). The VGA
soft-blank is that same window/masking lever, reappearing on a datapath that
has no source-rectangle lever at all.

---

## 3. Root cause — the mechanism

On a sync-locked analog display the picture position obeys one rule:

> **screen position = (content time) − (sync time)**

The monitor draws each line/frame at a fixed offset from the HSync/VSync edge
it receives. To move the picture you must change *either* the content's
timing *or* the sync's timing. **The soft-blank changes neither.** It only
edits the blank/DE mask, which selects *which* pixels are shown — it re-masks
(crops) but never re-positions.

Two facts make this concrete in AExp's analog pipeline:

**(a) The OSM is anchored to DE; it is a decoy.**
`vga_recover_counters.vhd:58` resets the OSM's `pix_x` counter on the **rising
edge of DE**. So the OSM's origin *is* the DE edge — when the soft-blank
slides the DE window, the OSM slides with it, by construction. The OSM moving
is not evidence that centering works; it is evidence that DE moved.

**(b) The core content is anchored to the sync, and the soft-blank leaves the
sync raw.** `analog_pipeline.vhd:145-148` feeds the MiSTer `video_mixer` the
**raw** core sync (`HSync => video_hs_i`, `VSync => video_vs_i`) while only the
blank inputs carry the soft-blanked window. Two sub-cases:

- **Scandoubler ON (Standard VGA).** The scandoubler is a *line-doubler*, not
  a scaler. Its line-buffer **write** index resets on `req_line_reset <= hb_in`
  (`scandoubler.v:98`) *and* its readout frame **and** its regenerated output
  HSync are all measured from the same `hb_in` falling edge (`hde_start`,
  `hs_end`/`hs_start`, `sd_hcnt` all zeroed there, `scandoubler.v:186-203`).
  Moving the blank slides the write window, the readout window, and the output
  sync **in lockstep by the same amount** — so the content-to-output-HSync
  relationship is invariant. The net shift cancels.
- **Scandoubler OFF (15 kHz HS/VS and CSYNC).** The RGB is passed through
  un-retimed and the output HSync is the raw core HSync. Nothing repositions;
  the moved DE only masks.

In both cases the RGB outside the (moved) DE is forced black
(`analog_pipeline.vhd:161-163`), so a large offset simply **crops** the
picture at one edge. Because that crop lands in the Amiga's overscan border
(usually black), it is invisible — hence "zero change to the core."

---

## 4. Evidence (cycle-accurate simulation, real MiSTer RTL)

A testbench drives a synthetic Amiga line (active-high syncs, blank-covers-sync,
7.09 MHz `ce` on 28.375 MHz) with a trackable 4-pixel white marker through a
faithful mirror of `p_vga_softblank` into the **real** `video_mixer.sv` +
`scandoubler.v` + `hq2x.sv` (the scandoubler copy differs only by a mechanical
declaration reorder that iverilog requires; behavior identical). It measures,
per output line, the distance from output-HSync-rising to (a) the DE rising
edge (the OSM anchor) and (b) the content marker (the actual picture).

**Result 1 — the bug: the offset moves the DE/OSM, not the content.**

| Mode | offset | de_start (OSM anchor) | marker (core picture) |
|---|---|---|---|
| Scandoubler ON | 0 / +40 / −40 | 185 / **203** / **163** | 355 / **353** / **353** |
| Scandoubler OFF | 0 / +40 / −40 | 359 / **399** / **319** | 699 / **699** / **699** |

The DE window slides by the offset; the content marker is offset-invariant
(the `±2` is doubling rounding). "Only the OSM moves" — reproduced in **both**
modes.

**Result 2 — it is a crop, not a pan.** Sweeping the marker across the active
width, every input column maps to a **fixed** output column regardless of
offset; a positive offset makes the blank **swallow** the edge column (input
column 95 is cropped away at offset +40) rather than shifting it into view.

**Result 3 — the real lever: shifting the SYNC pans it.** With the blank and
content left raw and the *sync* delayed instead, the content marker moves with
the frame:

| Mode | sync delay 0 / 40 / 80 | marker (core picture) |
|---|---|---|
| Scandoubler ON | | 355 / **335** / **315** |
| Scandoubler OFF | | 699 / **659** / **619** |

The HSync period (and thus the H-frequency) is unchanged, so the monitor stays
locked while the whole picture — content *and* OSM together — pans.

**Independent corroboration.** A from-scratch second testbench (different
geometry, its own generator, driving byte-identical MiSTer RTL, not reusing the
first soft-blank model) reproduced the same offset-invariance
(`de_start 118/198/38` while `marker 238/238/238`), triangulating the result.
A third, code-only trace reached the same conclusion by reading the RTL alone.
Every attempt to make the content pan via the soft-blank failed; only moving
the sync (or delaying the content) pans it.

---

## 5. Comparison to MiSTer — how MiSTer actually centers

MiSTer positions its **analog** picture exactly as AExp does: raw core sync
into `video_mixer`, DE-anchored line-doubler, and `sys/vga_out.sv` passes
HSync/VSync/DE straight through to the DAC (registered delays only, no
re-derivation). So **on MiSTer's own direct-analog output the same soft-blank
also only crops** — it cannot pan a sync-locked display either.

The reason MiSTer's arrow-key "screen centering" *appears* to work is that in
MiSTer a **single** soft-blank DE stream fans out to two places:

- the analog pins (where it crops), **and**
- the ascal **scaler** on the HDMI path, where `iauto=1` auto-detects the DE
  window and re-centers the scaled image (`ascal.vhd`). Moving DE moves the
  HDMI source rectangle → a real HDMI pan.

So MiSTer's soft-blank is fundamentally a **scaler-centering / source-window
tool**. On MiSTer, users center a real CRT with the **monitor's own H/V
position controls**; the arrow-key adjust is for the scaled (HDMI) output.

**What AExp did:** it split MiSTer's one DE lever into two and kept the halves
in different places.

- **HDMI (works):** AExp did *not* reuse the soft-blank. It uses a separate,
  explicit ascal **input**-crop (`digital_pipeline.vhd` `p_crop`, `iauto=0`,
  `himin/himax/vimin/vimax` from HDMI offset words 4–7). Because ascal is a
  frame-buffering scaler that decouples input timing from a fixed,
  independently generated output window, re-selecting the input source
  rectangle genuinely repositions content in the frame. **This is MiSTer's
  real centering lever, correctly used.**
- **VGA (does not pan):** AExp separately re-created only the *crop* half
  (`p_vga_softblank`, offset words 0–3) and wired it to the analog pipeline —
  which has **no scaler**. The scandoubler reframes but never repositions, so
  the ported lever can only crop.

The port is faithful. The mistake is placing a source-window/mask lever on a
stage that can crop with it but cannot center with it.

### Why HDMI works and VGA does not — at a glance

| | HDMI (works) | VGA / analog (only crops) |
|---|---|---|
| Positioning stage | ascal — a **framebuffer scaler** | scandoubler — a **line-doubler** |
| Output window | fixed, generated from HDMI mode constants, independent of input timing | none; output timing *is* the (doubled) input timing, sync-locked |
| Lever used | input **source-rectangle** crop (`iauto=0`, `himin/himax`) | blank/DE **mask** shift (`p_vga_softblank`) |
| Effect of the lever | selects which input pixels fill the fixed frame → **pans** | selects which pixels are unmasked → **crops** |

---

## 6. The fix

The physical requirement is fixed: to move an analog picture you must change
`(content time − sync time)`. Six approaches were designed and each scored
adversarially (with an independent iverilog re-run per candidate):

| Approach | Verdict | correct | cost | clean | ux |
|---|---|---|---|---|---|
| **A. Shift the analog sync** (programmable HS/VS delay, content/blank raw) | **SHIP w/ caveats** | 8 | 9 | 7 | 7 |
| B. Hybrid: sync-shift pan + keep soft-blank as crop trim | SHIP w/ caveats | 7 | 7 | 6 | 5 |
| C. No HW change: re-document the knob as crop/underscan + monitor centering | SHIP w/ caveats | 2 | 10 | 8 | 4 |
| D. RGB/DE content delay line (sync raw) | REJECT | 5 | 7 | 5 | 4 |
| E. Force scandoubler always-on | REJECT | 1 | 9 | 4 | 1 |
| F. Drive the analog DAC from the ascal scaler | REJECT | 3 | 2 | 1 | 2 |

Why the rejects fail: **E** was disproven by the sim (scandoubler-on *still*
only crops with the current blank shift) and would kill the two 15 kHz CRT
modes; **F** forces a fixed 31 kHz signal (killing both 15 kHz modes), needs a
second HyperRAM reader on a thin global WNS, and demolishes the framework
decoupling; **D** genuinely pans horizontally but **cannot pan vertically** —
vertical needs a line buffer and **BRAM is full** (rule 3) — and it only pans
one direction.

### Recommended real fix — A: shift the analog sync

Add a small retiming stage in the framework analog path that **delays the
analog HSync/VSync edges** by a programmable amount (H in output-pixels within
the line, V as a phase-preserving whole-line-length clock delay), leaving RGB
and the DE/blank raw. A sync-locked monitor then positions each line/frame off
the moved sync while the content stays put — the whole picture pans (content
and OSM together), which the sim's Result 3 proves in both scandoubler modes.

- **Cost:** none in BRAM — a couple of 12-bit counters plus a short HS/VS
  pulse delay in the 28.375 MHz video domain; off the HyperRAM PHY critical
  path (rules 3 and 5 both safe). No `.xpr`, `mega65.vhd`, or board-top edit.
- **Placement:** `analog_pipeline.vhd` (new sync-delay stage on
  `vga_hs_ps`/`vga_vs_ps`, **before** `i_csync` so the CSYNC mode pans too) +
  `av_pipeline.vhd` (thread the already-CDC'd VGA offset signals down). Stays
  inside the existing `M2M-UPSTREAM screen-center` exception; defaults of 0
  keep every other M2M core bit-identical.
- **Coverage:** all three VGA modes (Standard, 15 kHz HS/VS, 15 kHz CSYNC).

**Caveats — these are load-bearing, not footnotes:**

1. **This is an analog H/V-position control, so its effect is at the mercy of
   the display.** Sync-locked CRTs and lenient VGA monitors: it pans perfectly.
   **Auto-centering VGA-LCDs re-detect the timing and re-center every frame,
   silently cancelling the shift** — on that display class the symptom returns.
   Document this honestly.
2. **Pan range is bounded by the Amiga's sync porch** (the sim shows roughly
   185 output-clocks of back-porch room in Standard mode before content
   collides with HS). Clamp the offset to the available porch; beyond it the
   monitor clips the leading edge or drops lock.
3. **Interlace half-line trap.** The vertical delay must be a true
   sub-line-preserving clock delay (N × measured line length), **not**
   whole-line HSync-edge counting, or it re-quantizes VSync to a line boundary
   and destroys the inter-field half-line offset — laced analog content
   (Batman Rises intro, interlaced Workbench modes) would lose interlace lock.
   This case is outside the current sim (no field toggling / no CSYNC module)
   and must be hardware-verified.
4. **The four signed per-edge offsets collapse to ~2 net-position DOF on VGA.**
   The same numbers then mean "per-edge crop" on HDMI but "net H/V pan" on VGA
   — a mental-model wart. Either document the mapping explicitly or expose
   pan-oriented VGA words. Note `gp_reg` words 0–7 are fully allocated (0–3 VGA,
   4–7 HDMI), so adding words means widening the `i_qnice2video` CDC plus
   firmware/tool/file-format churn — avoid by re-deriving pan from the existing
   four words.
5. **The current `p_vga_softblank` becomes vestigial** and should be bypassed
   (not stacked — two window moves would fight), unless option B keeps it as a
   deliberate border-trim.
6. **Needs sy2002's sign-off**: it edits the framework `M2M-UPSTREAM
   screen-center` exception.

Option **B** (hybrid) is A plus keeping the soft-blank as an explicit overscan
*trim* — the most MiSTer-faithful result (move the sync to position, adjust the
blank to size), at the price of more UX/plumbing work.

### Honest interim option — C: re-document the knob

Zero-risk and immediately shippable: state plainly that the VGA offsets are a
**crop / underscan** (they pull the wonky Amiga border in), **not** a pan, and
that analog *centering* is done with the monitor's own H/V-position controls —
which is exactly what MiSTer users do and what option A does in hardware. The
crop is genuinely useful (it hides the border garbage), and the shipped
firmware/HDL is already correct for *that* purpose. This stops users chasing a
knob that cannot pan. It does **not** achieve HDMI parity, so it must not be
recorded as the resolution of Issue #5 for VGA — a real fix (A or B) is still
owed.

---

## 7. Recommendation

1. **Now (docs-only, no synthesis):** apply option C — reframe the VGA section
   of `doc/screen_adjust.md` as underscan-trim + monitor centering, so the
   feature is honest and the crop's real value is clear.
2. **Next (the real fix):** implement option A — the framework analog sync
   shift — behind the existing screen-center exception, with the six caveats
   above, and hardware-verify it (especially the interlace half-line and CSYNC
   cases the sim cannot cover). Consider option B if border-trim is also
   wanted.
3. Do **not** pursue E or F (both regress the 15 kHz CRT modes for no gain),
   and treat D only as the horizontal half of a hybrid whose vertical axis
   comes from A (D alone cannot pan vertically under the BRAM budget).

The one-line takeaway: **the analog picture is positioned by the sync, and the
VGA knob moves the blank — so it crops instead of pans. Move the sync (option
A) and it pans.**

---

## Appendix — reproduction

The simulation harness (real MiSTer `video_mixer.sv`/`scandoubler.v`/`hq2x.sv`,
a faithful `p_vga_softblank` mirror, a synthetic Amiga generator with a
trackable marker) and its numeric results live under the scratchpad
`vgasim/` directory used for this RCA (`EVIDENCE.md` documents the exact build
and run commands). Rebuild with iverilog 13:

```
iverilog -g2012 -o tb.out -s tb tb.v soft_blank.v amiga_gen.v \
  scandoubler_sim.v hq2x.sv video_freezer.sv gamma_corr.sv \
  <repo>/M2M/vhdl/controllers/MiSTer/video_mixer.sv
vvp tb.out +SD=<1|0> +OFF=<n> +SIGN=<1|0> +HSHIFT=<n> +MARK_S=<c> +MARK_E=<c+4>
```

`SD` selects scandoubler on/off (Standard vs 15 kHz), `OFF` is the blank-shift
offset (the shipped lever — crops), `HSHIFT` is the sync-shift lever (the
proposed fix — pans), `MARK_*` places the content marker.
