# Handover: native analog position and overscan adjustment

Date: 2026-07-13

Status: analysis complete; implementation has not started.

This document hands the analog half of AExp screen adjustment to a fresh
implementation session. HDMI adjustment is already working and is outside the
implementation scope except for regression testing.

## Authority and architectural standard

The user is **sy2002**, maintainer of MiSTer2MEGA65 (M2M). He explicitly
authorizes an M2M framework enhancement in this AExp repository as a development
testbench, with the intention of merging a successful design upstream later.

That approval is conditional on the result being architecturally clean:

- core-agnostic framework behaviour;
- explicit semantics rather than accidental MiSTer compatibility;
- zero/default inputs inert for every existing M2M core;
- safe reset, acquisition, bounds, mode-change and CDC behaviour;
- authentic 15 kHz output must remain available;
- no AExp-specific policy hidden inside a generic timing block; and
- changes in `M2M/` must retain the `M2M-UPSTREAM screen-center` provenance.

Do not avoid the correct framework change merely because `M2M/` is normally
treated as upstream code. This enhancement is approved. Conversely, do not use
that approval to make unrelated M2M changes.

## User requirement

AExp needs two distinct facilities on its analog connector:

1. **Position:** move the complete analog picture left/right/up/down. Core RGB
   and the M2M OSM must move together.
2. **Visible area / overscan:** independently hide or reveal the Amiga border
   edges. Community feedback says this is needed because some demos otherwise
   expose odd-looking border/overscan material.

Do not call the second facility "size" unless the text explicitly says
"visible-window size." It does not geometrically scale objects. True picture
scale would require the monitor's H/V-size controls or a resampling/scaler path.

The intended user-facing model is therefore:

```text
HDMI
    source crop: left, right, top, bottom     (existing; works)

Analog native output
    position:   pan_x, pan_y                  (new)
    overscan:   left, right, top, bottom      (retain soft blank, clarify)
```

## Evidence from Byte's bug report

The local screenshots are:

- `/Users/mirko/Downloads/1.jpg` and `2.jpg`: C64 core;
- `/Users/mirko/Downloads/3.jpg` and `4.jpg`: AExp/Amiga core;
- all were photographed on the same Fujitsu Siemens monitor.

The strongest symptom is screenshot 4: the left side of the file list is cut
off while a substantial unused strip remains on the right. Qualitatively this
means the analog canvas is too far left and should first be panned right. It
does not initially look like a true horizontal-scale problem; a centered image
that was simply too wide would tend to lose content at both edges.

Screenshot 4 is the M2M browser/OSM, not an ideal core-content landmark. Before
choosing numeric defaults, repeat the observation with the OSM closed and an
Amiga-generated test card containing unambiguous left/right/top/bottom markers.
The photos are unsuitable for deriving FPGA-clock offsets because perspective,
camera crop and the cores' different analog timings confound pixel measurement.

The same physical monitor need not use identical geometry for the C64 and
Amiga signals. Different totals, sync phases and porches can produce different
positioning or separate monitor presets.

## Established root cause

Read both RCA documents completely before implementation:

- `doc/rca_vga.md` -- preferred, cautious architectural RCA;
- `doc/rca_vga_claude.md` -- simulation evidence and candidate comparison.

Also read `doc/screen_adjust.md`, but treat its VGA pan claims as incorrect.
The HDMI section is substantially correct.

Current AExp VGA adjustment faithfully ports MiSTer's Minimig soft-blank
equations. The data path from `aexp_screen.cfg` through firmware, CFD `gp_reg`,
CDC and the video-domain block works. The failure is the selected primitive:

```text
analog screen position = time(core/OSM RGB landmark) - time(sync reference)
```

`p_vga_softblank` changes only the blank/DE mask. In direct 15 kHz modes it
changes neither RGB timing nor sync timing. In Standard mode the line doubler
derives replayed RGB and regenerated sync from the same adjusted blank origin,
so there is still no independent programmable RGB-to-sync phase. Existing
pixels can be hidden/revealed but do not translate.

The OSM moves because `vga_recover_counters` resets its X coordinate on adjusted
DE rise. Its movement proves that the offset reached the soft blank; it does not
prove that core pixels moved.

HDMI works because AScale re-indexes the selected input crop into a fixed output
frame (`digital_pipeline.vhd`, `p_crop`, `iauto='0'`). This is a coordinate
mapping operation, not a direct analog mask.

MiSTer has two analog paths. Its direct path has the same crop-only limitation.
When MiSTer's optional VGA Scaler is enabled, the analog pins receive the
AScale/HDMI-scaled stream, where source crop visibly reframes the picture. AExp
does not currently route analog through AScale. A future scaled-analog mode may
be useful for LCDs, but it is not a replacement for native 15 kHz CRT/SCART
output and is not the first implementation target.

## Current topology and anchors

Current soft blank:

- `M2M/vhdl/av_pipeline/av_pipeline.vhd`, `p_vga_softblank`, around lines
  475-546;
- its adjusted HBlank/VBlank alone are passed to `analog_pipeline`; RGB and
  HS/VS remain raw.

Current analog pipeline:

```text
video_mixer / optional line doubler
    -> force RGB black outside mixer DE
    -> video_overlay (OSM)
    -> csync
    -> falling-edge output registers / VDAC pins
```

Relevant file: `M2M/vhdl/av_pipeline/analog_pipeline.vhd`, especially the
overlay around lines 174-206 and CSYNC around lines 208-214.

The preferred common insertion point for native analog positioning is **after
OSM compositing and before CSYNC generation**:

```text
core RGB + raw timing
    -> optional line doubler
    -> overscan soft blank / RGB black mask
    -> compose OSM
    -> analog positioner: change HS/VS phase relative to final RGB
    -> generate CSYNC from the positioned HS/VS
    -> existing falling-edge pin registers and VDAC
```

This location makes pan move core content and OSM together and covers Standard,
15 kHz HS/VS and 15 kHz CSYNC through one block.

## Architecture recommendation

Create a reusable M2M analog timing/positioning block with explicit signed
horizontal and vertical **visible-motion** controls. Suggested external names
are `analog_pan_x_i` and `analog_pan_y_i`; positive should mean picture right
and down, regardless of the inverse internal sync movement needed to achieve
that result.

The block changes sync phase relative to final RGB, equivalently redistributing
front and back porch, while preserving:

- line and field/frame periods;
- HSYNC and VSYNC pulse widths and polarity;
- progressive/interlaced field cadence;
- the interlaced field-dependent half-line phase; and
- adequate black guard around sync.

It must have a genuinely timing-equivalent zero-offset bypass. Do not insert a
permanent baseline phase shift merely to make signed arithmetic convenient.

### A naive delay is not the completed design

The existing simulation proves the physical principle for horizontal sync
delay: changing sync relative to unchanged content pans the picture. It does
**not** prove a complete production implementation of signed H/V positioning.

A positive-only shift register can delay a pulse but cannot advance it. Signed
positioning requires a scheduler based on previously acquired stable line/field
periods, modulo-safe edge placement, and periodic re-anchoring to source timing.
The implementation must define:

- acquisition and "timing stable" criteria;
- behaviour during reset, mode change and loss of sync;
- modulo scheduling when an edge crosses a line/field boundary;
- when new values commit (field-safe or complete two-field-frame-safe);
- how signed horizontal units map in Standard versus 15 kHz modes;
- how vertical movement preserves the original VS sub-line phase; and
- conservative clamps derived from measured porch/black availability.

Both edges of each sync pulse must move together. Never change pulse width as a
proxy for position. CSYNC must be generated from the final positioned HS/VS.

An analog LCD may auto-position and cancel porch/sync changes. A CRT or a
strictly sync-locked display should follow them. Document this honestly. If a
later requirement demands deterministic geometry on auto-centering LCDs, study
an optional scaled-analog mode separately.

## Retaining and hardening overscan soft blank

Keep `p_vga_softblank`, because its crop/reveal function has a real community
use case. Stop describing it as pan or centering.

Before calling it production-ready, address the RCA's robustness findings:

- add an explicit reset/acquisition state rather than relying on initializers;
- use signed, width-safe arithmetic and safe clamps rather than 12-bit wrap;
- define horizontal units separately from vertical line units;
- define whether outward adjustment may reveal pixels beyond raw active DE;
- make impossible edge requests degrade safely instead of leaving the picture
  permanently blank; and
- deliberately specify how crop changes affect OSM coordinates.

The current OSM coordinate recovery is based on adjusted DE, so crop also moves
or resizes the OSM's coordinate canvas. That may be desirable (OSM stays inside
the remaining visible area), but it must become a documented choice rather than
an accidental side effect. Pan, applied after the overlay, must move both the
resulting OSM and core RGB together.

Do not stack equal-edge soft-blank motion and sync pan as two competing
"centering" mechanisms. Overscan fields control edges; pan fields control
position.

## Suggested transport and file-format evolution

Current v3 rows contain four HDMI crop words followed by four VGA soft-blank
edge words. Preserve v3 parsing long enough to avoid breaking existing custom
files, but treat its VGA words as overscan only.

A clean v4 can append explicit `pan_x` and `pan_y` to each mode row:

```text
HDMI:   himin, himax, vimin, vimax
Analog: crop_left, crop_right, crop_top, crop_bottom, pan_x, pan_y
```

One low-disruption CFD mapping is to leave existing words 0-7 unchanged and
use currently reserved `gp_reg` words 8 and 9 for analog pan X/Y. Verify the
actual current allocation before committing this map. The firmware already
pushes only the active mode row, so ten active words fit in the sixteen-word
CFD register bank.

At the M2M level, expose generic default-zero pan signals. Keep AExp's file
format, mode table and sign/unit conversion in AExp firmware/tooling rather than
inside the generic positioner.

Files likely affected after the HDL design is agreed:

- `M2M/vhdl/av_pipeline/analog_pipeline.vhd`;
- `M2M/vhdl/av_pipeline/av_pipeline.vhd`;
- `M2M/vhdl/framework.vhd` and any necessary defaulted framework boundary;
- possibly a new focused `analog_positioner.vhd` plus all four `.xpr` files if
  a new source file is used;
- `CORE/m2m-rom/m2m-rom.asm`;
- `aexp_screen_cfg.py`;
- `doc/screen_adjust.md`, `README.md`, release/status documentation; and
- focused simulation/testbench sources.

Respect the project's rule that all R3/R4/R5/R6 Vivado project file lists stay
in sync.

## Python tool is a required part of the feature

`aexp_screen_cfg.py` is already heavily used by community members. Enhancing it
is not optional cleanup: the analog feature is incomplete until the tool can
create, inspect and safely edit the final configuration format.

Preserve the existing workflows unless a deliberate, documented migration is
necessary:

- interactive editing with `python3 aexp_screen_cfg.py`;
- command-line editing of one named mode or all modes;
- `--list` output;
- editing an existing file in place;
- clear range validation and warnings; and
- operation on Windows, macOS and Linux using only Python 3's standard library.

The updated tool should:

- read existing v3 files and preserve their HDMI plus analog-overscan values;
- write the selected final format (expected to be v4) without silently changing
  unrelated rows or fields;
- offer explicit analog `pan_x` and `pan_y` controls with user-facing directions
  such as positive = right/down;
- relabel the existing VGA edge fields as analog overscan/visible-area controls,
  not pan and not true picture size;
- show HDMI crop, analog position and analog overscan as visibly separate
  groups in the table and interactive prompts;
- define the units actually implemented by the HDL rather than retaining the
  current vague "approximately quarter-lores-pixel" wording;
- use safety limits consistent with the hardware clamps and explain when a
  request is reduced by those clamps;
- provide a clear migration/result message when a v3 file is loaded and later
  saved as v4; and
- update its module docstring, `argparse` help, examples, warnings and field
  direction reminders together so they cannot contradict one another.

Add or extend automated tests for file packing/unpacking, v3-to-v4 migration,
per-mode edits, `--mode all`, bounds, preservation of untouched values and
command-line help/argument names. Do not remove a heavily used option without
either retaining an alias or providing a precise migration error.

## `doc/screen_adjust.md` rewrite is a required deliverable

The user-facing guide currently makes false VGA claims, especially the section
beginning around line 207 and the summary table around line 251. Updating this
document is part of completing the feature, not a follow-up task.

Preserve the accessible, plain-language style and the confirmed HDMI guidance,
but rewrite the analog explanation around three distinct ideas:

1. **Position** (`pan_x`, `pan_y`) moves the complete native analog result,
   including the OSM, relative to sync.
2. **Overscan / visible area** (four edge controls) hides or reveals border
   material and is useful for demos; it does not translate surviving pixels.
3. **True size / scale** is not provided by these native-output controls. Use
   monitor H/V-size controls, or a future optional scaled-analog mode if one is
   eventually implemented.

The guide must also:

- distinguish Standard 31 kHz, 15 kHz HS/VS and 15 kHz CSYNC;
- warn honestly that an analog LCD's auto-position logic may partially or fully
  cancel a porch/sync position change, whereas a sync-locked CRT should follow
  it;
- explain that the same monitor can position two cores differently because
  their timings and porches differ;
- retain recovery instructions for unsafe/blank configurations, updated for the
  new hardware clamps and tool behaviour;
- document v3 migration and the exact v4 file/tool workflow;
- update all command examples and table examples to match the enhanced Python
  tool exactly;
- remove the claims that soft blanking tells the monitor an independent DE
  position, that equal edge changes provide "rock-solid" pan, and that the old
  VGA fields give full centering control; and
- keep HDMI described accurately as source crop/reframe plus some zoom rather
  than pure geometric pan.

Afterward, search all claim surfaces for stale terminology. At minimum inspect
`README.md`, `aexp_screen_cfg.py`, `doc/inofficial.md`, project status text and
any help/release text that calls the old VGA edge fields centering or pan.

## Recommended implementation sequence

Do not attempt the whole feature as one opaque change.

1. **Lock the timing-block contract.** Write down exact units, sign convention,
   zero bypass, acquisition, clamps, interlace and commit semantics.
2. **Horizontal fixed-offset experiment.** With no new file/UI format, apply one
   obvious, safely bounded post-OSM HS phase change. Verify core and OSM move
   together on real hardware in Standard and both 15 kHz modes. Use a scope or
   ILA if possible. This is experimental proof, not the mergeable final block.
3. **Production horizontal signed positioner.** Add acquisition, advance/delay,
   modulo scheduling, clamps, reset and atomic update; prove it in simulation.
4. **Vertical/interlace positioner.** Preserve the source VS sub-line phase and
   validate both fields. Do not regenerate VS only from whole-line counts.
5. **CSYNC integration.** Generate CSYNC after final HS/VS and inspect the full
   interlaced waveform, not just nominal pulse counts.
6. **Transport/UI/tool v4.** Add explicit pan fields only after the hardware
   contract and units are stable. Enhance `aexp_screen_cfg.py`, including v3
   compatibility/migration and automated tests; this is required for release.
7. **Soft-blank hardening.** Retain overscan behaviour but give it safe reset,
   clamps and honest labels.
8. **Documentation and upstream-quality cleanup.** Rewrite
   `doc/screen_adjust.md`, update every other stale user-facing claim,
   default-zero generic M2M ports, provenance comments, and no AExp policy in
   generic RTL.

## Acceptance matrix

Use a core-generated test card with fixed-size rectangles and distinct edge
markers. Measure core content separately from the OSM.

For `pan_x = +N`, `0`, `-N` and analogous Y values, verify:

- core landmark moves in the requested visible direction;
- OSM moves by the same amount when open;
- distance between two core landmarks is unchanged (pan is not scale);
- HS/VS widths and line/field periods are unchanged;
- landmark-to-sync phase changes by the defined converted amount;
- crop values change visibility but do not translate surviving landmarks;
- HDMI pixels, crop, mode classification and AScale geometry are unchanged;
- zero pan/crop is timing- and pixel-equivalent to the intended baseline; and
- live reload never produces a malformed sync pulse or permanent blank state.

Run the matrix for:

- Standard 31 kHz;
- 15 kHz HS/VS;
- 15 kHz CSYNC;
- lores and hires;
- progressive and interlaced;
- OSM closed and open;
- at least one CRT and two analog flat panels, noting any auto-positioning.

True geometric size adjustment is not part of this native-positioner acceptance
test. If, after correct pan and overscan trim, content remains too wide or tall
while both edges are simultaneously required, that is a separate scaler/monitor
size requirement.

## Repository state warning

At handover creation, both RCA files are untracked user/worktree content:

```text
?? doc/rca_vga.md
?? doc/rca_vga_claude.md
```

Preserve them. Inspect `git status` again before editing, do not overwrite
unrelated user changes, and do not commit unless explicitly asked.

## Starter prompt for the next Codex session

Copy and paste the following into a fresh session:

```text
I am sy2002, maintainer of MiSTer2MEGA65. Implement the native analog VGA
position-and-overscan solution described in doc/handover_vga_adjustment.md.

Read that handover completely first, then read both doc/rca_vga*.md files,
doc/screen_adjust.md, and the relevant current RTL. Treat doc/rca_vga.md as the
more cautious authority where the RCAs differ. HDMI adjustment already works
and must not regress.

I explicitly approve an architecturally clean M2M enhancement in this AExp
repository as a development testbench for later upstreaming. Default-zero
behaviour must leave other M2M cores unchanged, and M2M changes must be generic,
beautiful, reset-safe, bounded, and tagged with M2M-UPSTREAM screen-center.

Requirements:
- retain and harden the existing soft blank as a separately named analog
  overscan/crop facility because demos need adjustable borders;
- add genuine analog pan_x/pan_y by changing final RGB-to-sync phase after OSM
  compositing and before CSYNC generation;
- pan must move core and OSM together in Standard, 15 kHz HS/VS and 15 kHz
  CSYNC;
- do not confuse crop with pan or with true picture scaling;
- preserve interlace half-line timing, sync widths/periods/polarity, porch
  safety, HDMI independence, and a genuinely inert zero setting;
- do not implement signed positioning as a naive positive-only delay;
- evolve the config/UI explicitly (prefer v4 with pan X/Y) only after the HDL
  timing contract is stable; and
- enhance the heavily used aexp_screen_cfg.py as a required deliverable: keep
  interactive/CLI/list workflows, read and migrate v3 safely, expose separate
  pan and overscan controls, update all help text, and add automated tests;
- rewrite doc/screen_adjust.md in plain language so HDMI remains accurate and
  analog pan, overscan/visible-area adjustment, and true scaling are clearly
  distinguished; search and correct the same stale claims elsewhere; and
- keep all four Vivado project files synchronized if adding an HDL source.

Start by inspecting the worktree and validating/refining the timing-block
contract in the handover. Then implement in reviewable increments with focused
simulation. If full signed H/V interlace-safe implementation cannot be proven
in one pass, complete the strongest safe increment and clearly identify what
remains; do not disguise an experiment as the production solution. Do not
commit unless I explicitly ask.
```
