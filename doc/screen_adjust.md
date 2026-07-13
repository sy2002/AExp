# Getting the Picture Right (HDMI & VGA)

When you first run AExp — the Amiga 500 core for the MEGA65 — you may notice
that the Amiga's picture is not perfectly placed on your screen. It might sit
a little too far to one side, an edge might be cut off, or a demo might show
strange-looking leftovers in the border.

This is a well-known quirk of how the real Amiga produced its video signal.
The good news: AExp gives you an easy, safe way to fix it, usually just by
copying one file onto your SD card.

This guide explains, in plain terms, why the problem exists and how to make
the picture look just right on your particular screen.

---

## You are not alone: MiSTer has the same problem

If you have used **MiSTer**, you may know that it, too, offers a "screen
centering" adjustment for its Amiga core. That is not a coincidence. *Any*
faithful Amiga recreation runs into the same wall, because the wall is the
Amiga itself, not the recreation. AExp solves it in the same spirit as MiSTer,
so if you have centered a picture on MiSTer before, this will feel familiar.

---

## Why the Amiga is tricky to place

Two things work against a perfectly placed picture:

1. **The Amiga was generous and a little sloppy with its borders.** It drew a
   wide picture surrounded by a border, and different programs placed their
   image at slightly different spots inside that border. There was never one
   single "correct" position — a 1985 game and a demo from 1992 might not agree.
   Old TVs hid this because they overscanned (they cropped the edges anyway).
   A modern, pixel-exact display shows everything, including the wonkiness.

2. **HDMI and VGA need different tools.** AExp can send its picture two ways
   at once: as a modern **HDMI** signal to a TV or monitor, and as an
   old-school **analog VGA** signal for retro monitors. These two paths work
   completely differently, so each gets its **own** adjustment. One knob
   cannot fix both.

**Remember:** The core is not outputting a VGA signal at all. VGA is used here
as a shortcut for "analog signal". We use this shortcut because the hardware
connector looks like a VGA connector.

---

## The three controls

AExp gives you three independent controls, each stored per Amiga screen mode:

1. **HDMI crop** — picks a rectangle of the Amiga picture and scales it to
   fill your HDMI screen. Moving an edge re-frames (and slightly zooms) the
   HDMI picture. HDMI only.
2. **Analog position** (`pan_x`, `pan_y`) — moves the **complete** analog
   picture, on-screen menu included, left/right/up/down. Works in all three
   VGA modes (Standard, 15 kHz HS/VS, 15 kHz CSYNC).
3. **Analog overscan** (`os_l`, `os_r`, `os_t`, `os_b`) — hides or reveals
   the Amiga's border edges on the analog output. Handy when a demo leaves
   odd-looking material in the overscan area. It changes what is *visible*;
   it does not move anything.

One thing none of these controls do: **change the true size of the picture.**
Position moves it, overscan trims it, HDMI crop re-frames it — but if the
analog picture as a whole is too wide or too narrow for your monitor, that is
what the monitor's own H-size/V-size controls are for.

---

## The easy way: try one of the two ready-made files

AExp ships with **two** ready-made settings files, each tuned for a
different kind of screen:

* **`aexp_screen.cfg_16_9`** — for a plain **16:9** display that just fills
  the screen and has no "4:3" aspect mode of its own. It leaves the picture
  almost exactly as the Amiga draws it (only a tiny nudge on the hires
  modes). Tested to work well on a cheap 16:9 monitor with no 4:3 emulation.
* **`aexp_screen.cfg_4_3`** — a gentle "underscan" that pulls all four edges
  in a little. Tested to work very well on a **4:3 Checkmate display**, and —
  perhaps surprisingly — just as well on a **Samsung 55" 4K TV**.

Because every TV and monitor overscans and stretches a little differently,
there is no single file that is perfect everywhere. So the plan is simple:
**try both and keep whichever looks best on your screen.**

1. Copy **both** files into the **`/amiga`** folder on your SD card — the
   same folder that holds `kick.rom` and your disk images.
2. Pick one to try and **rename it to `aexp_screen.cfg`** — that is, remove
   the trailing `_16_9` or `_4_3` so the name ends in just `.cfg`. Only a
   file named exactly `aexp_screen.cfg` is read by the core.
3. Start the core, or — if it is already running — open the on-screen menu
   (press the **Help** key) and choose **"Reload screen cfg"**.
4. Look at the picture. Happy? You are done. If not, rename the *other* file
   to `aexp_screen.cfg` (replacing the first one) and use **"Reload screen
   cfg"** again to compare. Each reload takes about a second — no reboot
   needed.

The core adjusts automatically as programs change the picture shape: the
Amiga can show a few different "screen modes" (see below), and both files
carry the right settings for each mode, so AExp always applies the matching
one for you. You do not have to do anything.

One thing to know: these two presets adjust the **HDMI** picture and leave
the **analog** output untouched. If you use the analog output and it sits
off-center, tune it by hand as described below.

---

## The four Amiga screen modes

An OCS PAL Amiga displays one of these screen modes:

* Lores
* Hires
* Lores interlaced
* Hires interlaced

Each mode can want slightly different values, so the file holds one row of
settings per mode, and AExp picks the right row automatically.

---

## Fine-tuning it yourself (for the tinkerers)

If your specific TV or monitor still trims an edge or sits slightly off, you
can adjust the numbers to taste. AExp ships with a small helper program,
**`aexp_screen_cfg.py`**, that writes the settings file for you. You only need
**Python 3** installed on your computer (Windows, macOS or Linux) — nothing else.

Tip: the tool edits an existing `aexp_screen.cfg` in place if one is present, so
the easiest starting point is to rename whichever ready-made preset looked best
(`aexp_screen.cfg_16_9` or `aexp_screen.cfg_4_3`) to `aexp_screen.cfg` first, and
then fine-tune it from there.

Open a terminal in the folder that contains the tool and run it with no extra
options to enter its friendly, interactive mode:

```
python3 aexp_screen_cfg.py
```

It shows the current settings as a table and asks which mode row you want to
edit. Pick a row, and it walks you through the three groups — HDMI crop,
analog position, analog overscan. Press Enter at a group prompt to skip that
whole group, and Enter on any value to keep it as-is. When you are done, press
Enter at the row prompt to **save** the file.

Prefer one-liners? Everything works from the command line too:

```
python3 aexp_screen_cfg.py --mode lores --pan-x 8            # analog picture right
python3 aexp_screen_cfg.py --mode all --pan-y -3             # analog picture up, all modes
python3 aexp_screen_cfg.py --mode lores --himin 32           # trim HDMI left edge
python3 aexp_screen_cfg.py --mode all --reset pan            # undo all analog panning
python3 aexp_screen_cfg.py --mode lores-i --copy-from lores  # reuse tuned values
python3 aexp_screen_cfg.py --list                            # show the current table
```

The tool prints, after every change, which way the picture will move — so you
never have to memorize sign conventions.

### HDMI crop: pick a rectangle, then blow it up to fill the screen

The HDMI side runs through a digital scaler. It takes a rectangle out of the
Amiga's picture and stretches that rectangle to fill your entire HDMI screen.
Each of the four numbers pulls one edge of that rectangle *inward*:

- `himin` — the LEFT edge. Only `0` or a **positive** value does anything; a
  bigger number cuts more off the left.
- `himax` — the RIGHT edge. Only `0` or a **negative** value does anything; a
  more-negative number cuts more off the right.
- `vimin` — the TOP edge (`0` or **positive**).
- `vimax` — the BOTTOM edge (`0` or **negative**).

Why the mixed signs? Because each number is measured from *its own* edge and can
only move toward the middle. Giving `himin` a negative value to reveal more on
the left does nothing — there is nothing to the left of the Amiga's own picture,
so it is ignored (it clamps to "full"). A positive `himax` is ignored for the
same reason. On HDMI you always *trim inward*, never expand outward.

One consequence: **HDMI adjustment is a re-frame, not a pure slide.** Whatever
rectangle you choose is always blown up to fill the same screen, so every
change moves the content *and* zooms it a little. To move the picture right
you trim the right edge (`himax` negative); the remaining part is stretched to
fill the screen, so the content shifts right, but it also becomes slightly
bigger. In practice this is exactly what you want for centering.

Quick recipe:

- Move the picture **left** -> `himin` a little positive.
- Move it **right** -> `himax` a little negative.
- Move it **up** -> `vimin` a little positive.
- Move it **down** -> `vimax` a little negative.
- Whole picture cut off on all sides by an overscanning TV -> trim all four a
  touch (`himin` +, `himax` -, `vimin` +, `vimax` -). This is the digital
  equivalent of "underscan."

Because this all happens on the *source* side, one HDMI setting centers every
HDMI resolution (16:9, 4:3, 5:4) at the same time.

### Analog position: move the whole picture

`pan_x` and `pan_y` move the **complete analog picture** — Workbench, demo,
border and the on-screen menu together — without touching its size or the
HDMI output. Positive values move right and down, negative values left and up:

- `pan_x` — one step is one hires pixel (half a lores pixel). The step size
  is the same in Standard and in the 15 kHz modes.
- `pan_y` — one step is one Amiga picture line.

Under the hood, AExp shifts the timing of the sync pulses relative to the
picture content — exactly what the H/V-position knobs of a monitor do,
just from the core's side. Two honest consequences follow from that:

- **CRTs and sync-locked monitors follow the pan exactly.** This includes
  SCART/RGB setups on the 15 kHz CSYNC mode — the composite sync is generated
  from the already-moved timing, so everything stays consistent.
- **Some analog-input flat panels re-center themselves.** An LCD with
  auto-position logic measures the incoming signal and may quietly undo part
  or all of your pan, immediately or on its next "Auto" run. That is the
  monitor being helpful, not a core bug. On such a display, use overscan
  trimming (below) and the HDMI output for exact placement, or simply use the
  monitor's own position controls.

Also good to know: the **same physical monitor may place two different cores
differently.** The C64 core and AExp produce different analog timings, and a
monitor may even store separate settings per timing. Do not expect one core's
numbers to mean anything for another core.

**Safety and range.** The core never lets the pan push a sync pulse into the
visible picture: requests are automatically limited to roughly an eighth of a
line horizontally, and to whatever black border room your current settings
leave around the sync. If the picture stops moving before it is where you
want it, hide a little border on that side first (overscan, below) — that
frees up more room and the pan limit grows with it. Vertical pan is limited
to ±64 lines. Because of these built-in limits, a pan value cannot produce a
broken or lost signal; the worst case is that the picture moves less than
you asked for.

### Analog overscan: hide or reveal the border edges

The four overscan values trim the visible area of the analog picture, edge by
edge. This is the tool for demos or games that leave garbage-looking material
in the border, and for displays that show more border than you would like:

- `os_l` — left edge: positive hides border on the left, negative reveals more.
- `os_r` — right edge: **negative** hides border on the right, positive
  reveals more.
- `os_t` — top edge: positive hides lines at the top, negative reveals more.
- `os_b` — bottom edge: **negative** hides lines at the bottom, `0` leaves it
  untouched. (A positive value is a legacy "absolute line" mode you almost
  never want.)

Horizontal steps are quarter lores pixels; vertical steps are lines. Hidden
areas simply turn black — overscan does **not** move the remaining picture
(that is what position is for), and it does not resize anything. The on-screen
menu keeps itself inside the remaining visible area, so it stays fully usable
while you trim.

If you used the "VGA offsets" of an earlier AExp release: these are the same
four values, now with honest names. They always cropped the picture — they
never panned it, despite what older documentation said. Use `pan_x`/`pan_y`
for panning.

### What about picture size?

If, after positioning and trimming, the analog picture is still too wide,
too narrow, too tall or too short *as a whole*, none of these controls will
fix that — stretching the picture needs either your monitor's H/V-size
controls or a scaler in the signal path. AExp deliberately keeps the native
analog output scaler-free, because that is what makes the 15 kHz modes
authentic for CRTs.

### At a glance

| Aspect | HDMI crop | Analog position | Analog overscan |
|---|---|---|---|
| What it does | picks a source rectangle and zooms it to fill the HDMI screen | moves the complete analog picture (menu included) | hides/reveals analog border edges |
| Moves the picture? | re-frames it (plus slight zoom) | **yes** — a true slide | no |
| Resizes anything? | slight zoom is inherent | no | no (trimmed areas turn black) |
| Fields | `himin` `himax` `vimin` `vimax` | `pan_x` `pan_y` | `os_l` `os_r` `os_t` `os_b` |
| Units | Amiga source pixels | hires pixels / lines | quarter lores pixels / lines |
| Works on | HDMI only | all three VGA modes | all three VGA modes |
| Display caveats | none | auto-positioning LCDs may cancel it; CRTs follow exactly | none |

Whichever control you are tuning, the method is the same: change one number
by a small amount, save, reload, and look. Repeat until it is right.

---

## The experiment loop: try, look, repeat

Here is the whole cycle for dialing in your own perfect picture. It does **not**
require rebooting or re-flashing the core:

1. **Adjust and save** the file with the tool (it creates `aexp_screen.cfg`).
2. **Copy** `aexp_screen.cfg` into the **`/amiga`** folder on your SD card.
3. On the MEGA65, open the core's **on-screen menu** (press the **Help** key)
   and choose **"Reload screen cfg"**.
4. **Look** at the picture. Not right yet? Go back to step 1 and nudge the
   numbers a bit more.

Each reload takes about a second, and your changes appear immediately — no
reboot needed. Position changes settle within a blink; you never get a torn
or broken picture from a reload.

> **If the analog picture ever disappears (goes black):** an overscan value is
> hiding everything. Don't worry — nothing is broken. Set the overscan values
> smaller (or delete `aexp_screen.cfg` entirely) and reload again. The **HDMI
> output is completely independent**, so the menu stays visible on HDMI the
> whole time, which makes it easy to recover. (Pan values cannot cause this —
> they are limited in hardware.)

---

## File versions: v3 and v4

Older AExp releases used a version-3 settings file (68 bytes, no position
fields). The current format is version 4 (84 bytes: HDMI crop, analog
overscan and analog position per mode).

- The **core** reads both: a v3 file keeps working exactly as before, with
  the analog position simply at zero.
- The **tool** reads both and always saves v4. When it loads a v3 file it
  keeps your HDMI and overscan values and tells you it upgraded the format.
- Careful in the other direction: cores **older than WIP-V1-A9 ignore a v4
  file completely** (you lose your HDMI centering there). If you still run an
  older core, keep a copy of your old v3 file around until you upgrade.

---

## A note on this alpha version

The "edit a file, copy it over, reload" method described here is a **temporary
solution for the alpha releases.** It works well and is completely safe, but it
is admittedly a bit fiddly.

A future release will most likely add a far more convenient, **MiSTer-style**
approach on top: nudge the picture **live** with the keyboard, watch it move,
and save when it looks right — no separate tool, no copying files back and
forth. Until then, the method in this guide covers HDMI framing, analog
position and analog overscan for every Amiga screen mode.
