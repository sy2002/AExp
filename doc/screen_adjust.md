# Getting a Nicely Centered Picture (HDMI & VGA)

When you first run AExp — the Amiga 500 core for the MEGA65 — you may notice
that the Amiga's picture is not perfectly centered on your screen. It might
sit a little too far to one side, or an edge might be cut off by your TV or
monitor.

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

## Why the Amiga is tricky to center

Two things work against a perfectly centered picture:

1. **The Amiga was generous and a little sloppy with its borders.** It drew a
   wide picture surrounded by a border, and different programs placed their
   image at slightly different spots inside that border. There was never one
   single "correct" position — a 1985 game and a demo from 1992 might not agree.
   Old TVs hid this because they overscanned (they cropped the edges anyway).
   A modern, pixel-exact display shows everything, including the wonkiness.

2. **HDMI and VGA drift in opposite directions.** AExp can send its picture two
   ways at once: as a modern **HDMI** signal to a TV or monitor, and as an
   old-school **analog VGA** signal for retro monitors. These two paths process
   the Amiga's timing differently, so they end up nudged the *opposite* way —
   the HDMI picture tends to drift right, the VGA picture tends to drift left.
   Because they misbehave in opposite directions, they each need their **own**
   adjustment. One knob cannot fix both.

That is the whole reason the adjustment file (below) has separate settings for
HDMI and for VGA.

**Remember:** The core is not outputting a VGA signal at all. VGA is used here
as a shortcut for "analog signal". We use this shortcut because the hardware
connector looks like a VGA connector.

---

## The easy way: just drop in the ready-made file

Alpha 5 (and later) ships with a small settings file called
**`aexp_screen.bin`**. It already contains sensible, tested screen positions
for both HDMI and VGA, so for most people it is truly "set and forget":

1. Copy **`aexp_screen.bin`** into the **`/amiga`** folder on your SD card —
   the same folder that holds `kick.rom` and your disk images.
2. Start (or restart) the core.

That is it. The picture should now be nicely centered. If you are happy, you
can stop reading here.

The core even adjusts automatically as programs change the picture shape: the
Amiga can show a few different "screen modes" (see below), and AExp detects which
one is on screen and applies the matching settings for you. You do not have to
do anything.

---

## The four Amiga screen modes

An OCS PAL Amiga displays one of these screen modes:

* Lores
* Hires
* Lores interlaced
* Hires interlaced

Each mode can want a slightly different centering, so the file holds one row of
settings per mode, and AExp picks the right row automatically.

---

## Fine-tuning it yourself (for the tinkerers)

If your specific TV or monitor still trims an edge or sits slightly off, you can
adjust the numbers to taste. AExp ships with a small helper program,
**`aexp_screen_cfg.py`**, that writes the settings file for you. You only need
**Python 3** installed on your computer (Windows, macOS or Linux) — nothing else.

Open a terminal in the folder that contains the tool and run it with no extra
options to enter its friendly, interactive mode:

```
python3 aexp_screen_cfg.py
```

It shows the current settings as a table and asks which mode row you want to
edit. Pick a row, then nudge its numbers a little at a time. It looks like this:

```
AExp screen centering -- per Amiga graphics mode, HDMI + VGA.

  #  mode              HDMI  himin  himax  vimin  vimax   VGA  hbl_l  hbl_r  vbl_t  vbl_b
  0  Lores                      +0     +0     +0     +0           +0     +0     +0     +0
  1  Hires                      +0     +0     +0     +0           +0     +0     +0     +0
  2  Lores interlaced           +0     +0     +0     +0           +0     +0     +0     +0
  3  Hires interlaced           +0     +0     +0     +0           +0     +0     +0     +0

  edit which row 0-3 (Enter = save & exit):
```

Type a row number, and it walks you through the eight numbers for that mode —
four for HDMI, then four for VGA. Press Enter on any value to keep it as-is.
When you are done, press Enter at the row prompt to **save** the file.

What the numbers do, in everyday language:

- **HDMI numbers** (`himin`, `himax`, `vimin`, `vimax`) nudge the Amiga picture
  **left / right / up / down** on your HDMI screen. Start with small steps; the
  tool prints a reminder of which direction each one moves the picture.
- **VGA numbers** (`hbl_l`, `hbl_r`, `vbl_t`, `vbl_b`) nudge the **left, right,
  top and bottom** edges of the analog VGA picture. Because analog monitors vary
  so much, the best approach is simply to change a value, look at the screen, and
  repeat until it is centered.

A value of `0` means "leave that edge exactly as it is." Setting everything back
to `0` gives you the original, unchanged picture again.

### How the numbers really work: HDMI and VGA are different animals

The HDMI and VGA numbers do not just have different names — they drive two
completely different mechanisms. Once you know which is which, tuning becomes
predictable, and it explains a surprise: **on HDMI you can never truly slide
(pan) the picture, while on VGA you can.**

#### HDMI: pick a rectangle, then blow it up to fill the screen

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

The big consequence: **you cannot pan the picture on HDMI.** Whatever rectangle
you choose is always blown up to fill the exact same screen, so every change does
two things at once — it re-frames *and* zooms. To move the picture to the right
you trim the right edge (`himax` negative); the part that remains is stretched to
fill the screen, so the content shifts right, but it also becomes a little
bigger. There is no "move without resizing."

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

#### VGA: slide the picture around inside the monitor's own frame

The VGA side is analog, and it works the other way round. Your monitor — not
AExp — decides how big a pixel is, from its own timing and its size and position
knobs. All AExp does is tell the monitor where the active picture starts and
stops within each line and each frame (the "blanking"). Move those start and
stop points and the picture slides around inside the frame the monitor is
already drawing.

Here **both signs are meaningful**, and each number moves one edge of the active
window:

- `hbl_l` — the LEFT edge. A positive value moves it right; a negative value
  moves it left.
- `hbl_r` — the RIGHT edge. Positive extends it to the right; negative pulls it
  in from the right.
- `vbl_t` — the TOP edge. Positive moves it down; negative moves it up.
- `vbl_b` — the BOTTOM edge. This one is special: `0` leaves the bottom at its
  natural place, a **negative** value pulls the bottom up, and a positive value
  is an unusual "absolute" mode you almost never want — so treat `vbl_b` as
  **"0 or negative."**

The big consequence: **on VGA you can pan.** Move both horizontal edges the
*same* way and the whole picture slides without changing size — `hbl_l` and
`hbl_r` both positive slides it right, both negative slides it left. Move them in
*opposite* directions and you widen or narrow the window instead. (On an analog
monitor the exact width also depends on the monitor's own size control, so the
"resize" half is a little fuzzy; the "slide" half is rock-solid.)

Quick recipe:

- Picture too far **left** (the usual VGA symptom) -> raise `hbl_l` and `hbl_r`
  together.
- Too far **right** -> lower both together (into negative).
- Too **high** -> `vbl_t` negative.
- Too **low** -> `vbl_t` positive.
- Bottom edge overscanned -> `vbl_b` a little negative.

One safety note: keep the vertical values modest. A *large* negative `vbl_t`
(more than about 30 lines) can accidentally blank the whole VGA picture. If that
ever happens, do not panic — set the value smaller (or delete the file) and
reload. The HDMI output is independent, so the menu stays visible the whole time
and you can always recover. (The tool warns you when a VGA value gets this large.)

#### At a glance

| Aspect | HDMI | VGA |
|---|---|---|
| What it does | picks a rectangle of the Amiga picture and zooms it to fill the screen | slides the active picture around inside the monitor's own frame |
| Can it pan (slide without resizing)? | **No** — every change re-frames *and* zooms | **Yes** — move both edges the same way |
| Left edge (`himin` / `hbl_l`) | `0` or positive (trims left) | either sign (positive = right, negative = left) |
| Right edge (`himax` / `hbl_r`) | `0` or negative (trims right) | either sign (positive = right, negative = left) |
| Top edge (`vimin` / `vbl_t`) | `0` or positive (trims top) | either sign (positive = down, negative = up) |
| Bottom edge (`vimax` / `vbl_b`) | `0` or negative (trims bottom) | `0` or negative |

Whichever output you are tuning, the method is the same: start from the shipped
defaults, change one number by a small amount, save, reload, and look. Repeat
until it is centered.

---

## The experiment loop: try, look, repeat

Here is the whole cycle for dialing in your own perfect picture. It does **not**
require rebooting or re-flashing the core:

1. **Adjust and save** the file with the tool (it creates `aexp_screen.bin`).
2. **Copy** `aexp_screen.bin` into the **`/amiga`** folder on your SD card.
3. On the MEGA65, open the core's **on-screen menu** (press the **Help** key)
   and choose **"Reload screen cfg"**.
4. **Look** at the picture. Not centered yet? Go back to step 1 and nudge the
   numbers a bit more.

Each reload takes about a second, and your changes appear immediately — no
reboot needed.

> **If the VGA picture ever disappears (goes black):** you nudged a VGA value too
> far. Don't worry — nothing is broken. Just set that value smaller (or delete
> `aexp_screen.bin` entirely) and reload again. The **HDMI output is completely
> independent**, so the menu stays visible on HDMI the whole time, which makes it
> easy to recover.

---

## A note on this alpha version

The "edit a file, copy it over, reload" method described here is a **temporary
solution for the alpha releases.** It works well and is completely safe, but it
is admittedly a bit fiddly.

A future release will most likely replace it with a far more convenient,
**MiSTer-style** approach: you will nudge the picture **live** using the keyboard
and watch it move on screen in real time, then simply save when it looks right —
no separate tool, no copying files back and forth. Until then, the method in this
guide gives you full control over how your Amiga picture looks on both outputs.
