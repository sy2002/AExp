# Getting the Picture Right (HDMI & VGA)

The Amiga's picture may not sit perfectly on your screen: it can be off to
one side, an edge can be cut off, or a demo can leave odd-looking material in
the border. This comes from how the real Amiga produced its video signal, and
copying one file onto your SD card usually fixes it.

---

## Why the Amiga is tricky to place

The Amiga drew a wide picture surrounded by a border, and programs placed
their image at slightly different spots inside that border. There is no
single correct position: a 1985 game and a 1992 demo may not agree. Old TVs
hid this because they overscanned and cropped the edges anyway; a modern,
pixel-exact display shows everything. Every faithful Amiga recreation runs
into this. **MiSTer** offers a "screen centering" adjustment for its Amiga
core for the same reason, and AExp solves it in the same spirit.

AExp also sends its picture two ways at once: as a digital **HDMI** signal
and as an **analog** signal on the VGA connector for retro monitors. The two
paths work completely differently, so each has its own adjustment. (Strictly
speaking, the core does not output a VGA signal; this page says "VGA" for the
analog output because the MEGA65's connector is a VGA connector.)

---

## The three controls

AExp has three independent controls:

1. **HDMI crop** picks a rectangle of the Amiga picture and scales it to fill
   your HDMI screen. Moving an edge re-frames (and slightly zooms) the HDMI
   picture. HDMI only.
2. **Analog position** (`pan_x`, `pan_y`) moves the **complete** analog
   picture, on-screen menu included, left/right/up/down. It works in all
   three VGA modes (Standard, 15 kHz HS/VS, 15 kHz CSYNC).
3. **Analog overscan** (`os_l`, `os_r`, `os_t`, `os_b`) hides or reveals the
   Amiga's border edges on the analog output, for example when a demo leaves
   odd-looking material in the overscan area. It changes what is visible and
   does not move anything.

An OCS PAL Amiga has four screen modes: lores, hires, lores interlaced and
hires interlaced. Each can need slightly different values, so the settings
file holds one row per mode, and AExp applies the matching row automatically
whenever a program changes the mode.

None of the controls changes the true size of the picture; see
[What about picture size?](#what-about-picture-size).

---

## The easy way: try one of the two ready-made files

AExp ships with two settings files for different kinds of screen:

* **`aexp_screen.cfg_16_9`** is for a plain **16:9** display that fills the
  screen and has no 4:3 mode of its own. It leaves the picture almost exactly
  as the Amiga draws it, with a small nudge on the hires modes only. Tested
  on a cheap 16:9 monitor without a 4:3 mode.
* **`aexp_screen.cfg_4_3`** is a gentle underscan that pulls all four edges
  in a little. Tested on a **4:3 Checkmate display**, where it works very
  well, and just as well on a **Samsung 55" 4K TV**.

Every TV and monitor overscans and stretches a little differently, so no
single file is perfect everywhere. Try both and keep the one that looks best:

1. Copy both files into the **`/amiga`** folder on your SD card, where
   `kick.rom` and your disk images are.
2. Rename one of them to **`aexp_screen.cfg`** (remove the trailing `_16_9`
   or `_4_3`). The core reads only a file with exactly that name.
3. Start the core or, if it is already running, open the on-screen menu with
   **Help** and choose **Reload Screen Config**.
4. Look at the picture. If you do not like it, rename the other file to
   `aexp_screen.cfg` (replacing the first) and choose **Reload Screen Config**
   again. A reload takes about a second and needs no reboot.

The two presets adjust only the **HDMI** picture and leave the **analog**
output untouched. If the analog picture sits off-center, tune it by hand as
described below.

---

## Fine-tuning it yourself

If your screen still trims an edge or the picture sits slightly off, adjust
the numbers yourself with the helper program **`aexp_screen_cfg.py`** that
ships with AExp. It needs only **Python 3** (Windows, macOS or Linux). The
tool edits an existing `aexp_screen.cfg` in place, so start by renaming the
preset that looked best to `aexp_screen.cfg`.

Open a terminal in the folder that contains the tool and run it without
options for its interactive mode:

```
python3 aexp_screen_cfg.py
```

It shows the current settings as a table and asks which mode row to edit,
then walks you through the three groups: HDMI crop, analog position, analog
overscan. Press Enter at a group prompt to skip the group, Enter on a value
to keep it, and Enter at the row prompt to **save** the file.

Everything also works from the command line:

```
python3 aexp_screen_cfg.py --mode lores --pan-x 8            # analog picture right
python3 aexp_screen_cfg.py --mode all --pan-y -3             # analog picture up, all modes
python3 aexp_screen_cfg.py --mode lores --himin 32           # trim HDMI left edge
python3 aexp_screen_cfg.py --mode all --reset pan            # undo all analog panning
python3 aexp_screen_cfg.py --mode lores-i --copy-from lores  # reuse tuned values
python3 aexp_screen_cfg.py --list                            # show the current table
```

After every change the tool prints which way the picture will move, so you
do not have to remember the sign conventions.

### HDMI crop: pick a rectangle, then blow it up to fill the screen

The HDMI output runs through a digital scaler. It takes a rectangle out of
the Amiga's picture and stretches it to fill the whole HDMI screen. Each of
the four numbers pulls one edge of that rectangle inward:

- `himin` (LEFT edge) and `vimin` (TOP edge): only `0` or a **positive**
  value has an effect; a bigger number cuts more off.
- `himax` (RIGHT edge) and `vimax` (BOTTOM edge): only `0` or a **negative**
  value has an effect; a more negative number cuts more off.

The signs differ because each number is measured from its own edge and can
only move toward the middle. There is nothing beyond the Amiga's own picture
to reveal, so a negative `himin` or a positive `himax` is ignored (it clamps
to "full"). On HDMI you can only trim inward.

So **an HDMI adjustment re-frames the picture rather than sliding it.** The
rectangle you choose always fills the same screen, so every change moves the
content and zooms it a little. To move the picture right, trim the right
edge (`himax` negative): the rest is stretched to fill the screen, so the
content shifts right and becomes slightly bigger. For centering, that is what
you want.

Quick recipe:

- Move the picture **left**: `himin` a little positive.
- Move it **right**: `himax` a little negative.
- Move it **up**: `vimin` a little positive.
- Move it **down**: `vimax` a little negative.
- An overscanning TV cuts the picture off on all sides: trim all four a
  little (`himin` +, `himax` -, `vimin` +, `vimax` -). This is the digital
  equivalent of "underscan".

Because the crop happens on the source side, one HDMI setting centers every
HDMI resolution (16:9, 4:3, 5:4) at once.

### Analog position: move the whole picture

`pan_x` and `pan_y` move the **complete analog picture** (Workbench, demo,
border and on-screen menu together) without changing its size or the HDMI
output. Positive values move it right and down, negative values left and up:

- `pan_x`: one step is one hires pixel (half a lores pixel), in Standard and
  in the 15 kHz modes alike.
- `pan_y`: one step is one Amiga picture line.

AExp shifts the sync pulses relative to the picture content, which is what
the H/V-position knobs of a monitor do. Two consequences follow:

- **CRTs and sync-locked monitors follow the pan exactly**, including
  SCART/RGB setups on the 15 kHz CSYNC mode, whose composite sync is
  generated from the shifted timing.
- **Some analog-input flat panels re-center themselves.** An LCD with
  auto-position logic measures the incoming signal and may undo part or all
  of your pan, immediately or on its next "Auto" run. That is the monitor,
  not a core bug. On such a display, use overscan trimming (below) and the
  HDMI output for exact placement, or the monitor's own position controls.

The same monitor may also place two cores differently: the C64 core and AExp
produce different analog timings, and a monitor may store separate settings
per timing. One core's numbers say nothing about another's.

**Safety and range.** The core never lets the pan push a sync pulse into the
visible picture. Horizontally it limits the pan to roughly an eighth of a
line, and to the black border room your current settings leave around the
sync. If the picture stops moving before it is where you want it, hide a
little border on that side first (overscan, below); that frees room, and the
pan limit grows with it. Vertical pan is limited to ±64 lines. So a pan value
cannot break the signal; at worst the picture moves less than you asked for.

### Analog overscan: hide or reveal the border edges

The four overscan values trim the visible area of the analog picture, edge
by edge. Use them for demos or games that leave garbage in the border, and
for displays that show more border than you like:

- `os_l` (left edge) and `os_t` (top edge): positive hides border, negative
  reveals more.
- `os_r` (right edge): **negative** hides border, positive reveals more.
- `os_b` (bottom edge): **negative** hides lines, `0` leaves the edge
  untouched. (A positive value selects a legacy "absolute line" mode you
  almost never want.)

Horizontal steps are quarter lores pixels, vertical steps are lines. Hidden
areas turn black. Overscan does **not** move the rest of the picture (that
is what position is for) and does not resize anything. The on-screen menu
stays inside the remaining visible area, so it remains usable while you trim.

### What about picture size?

If, after positioning and trimming, the analog picture is still too wide,
too narrow, too tall or too short as a whole, none of these controls can fix
it. That needs your monitor's H/V-size controls or a scaler in the signal
path. AExp keeps the analog output free of a scaler on purpose, because that
is what makes the 15 kHz modes authentic for CRTs.

### At a glance

| Aspect | HDMI crop | Analog position | Analog overscan |
|---|---|---|---|
| What it does | picks a source rectangle and zooms it to fill the HDMI screen | moves the complete analog picture (menu included) | hides/reveals analog border edges |
| Moves the picture? | re-frames it (plus slight zoom) | **yes**, a true slide | no |
| Resizes anything? | slight zoom is inherent | no | no (trimmed areas turn black) |
| Fields | `himin` `himax` `vimin` `vimax` | `pan_x` `pan_y` | `os_l` `os_r` `os_t` `os_b` |
| Units | Amiga source pixels | hires pixels / lines | quarter lores pixels / lines |
| Works on | HDMI only | all three VGA modes | all three VGA modes |
| Display caveats | none | auto-positioning LCDs may cancel it; CRTs follow exactly | none |

---

## The experiment loop: try, look, repeat

Whichever control you tune, change one number by a small amount, save,
reload and look. No reboot or re-flash is needed:

1. **Adjust and save** the file with the tool (it creates `aexp_screen.cfg`).
2. **Copy** `aexp_screen.cfg` into the **`/amiga`** folder on your SD card.
3. Open the on-screen menu (**Help**) and choose **Reload Screen Config**.
4. **Look** at the picture. If it is not right yet, go back to step 1.

A reload takes about a second, and the change appears at once. Position
changes settle almost instantly, and a reload never produces a torn or
broken picture.

> **If the analog picture goes black:** an overscan value is hiding
> everything. Nothing is broken: make the overscan values smaller (or delete
> `aexp_screen.cfg`) and reload. The **HDMI output is independent**, so the
> menu stays visible on HDMI the whole time. Pan values cannot cause this,
> because the hardware limits them.
