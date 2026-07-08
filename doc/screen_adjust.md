# Getting a Nicely Centered Picture (HDMI & VGA)

When you first run AExp — the Amiga 500 core for the MEGA65 — you may notice
that the Amiga's picture is not perfectly centered on your screen. It might sit
a little too far to one side, or an edge might be cut off by your TV or monitor.

**This is normal, and it is not a fault in AExp.** It is a well-known quirk of
how the real Amiga produced its video signal. The good news: AExp gives you an
easy, safe way to fix it — usually just by copying one file onto your SD card.

This guide explains, in plain terms, why the problem exists and how to make the
picture look just right on your particular screen.

---

## You are not alone: MiSTer has the same problem

If you have used **MiSTer** (the popular FPGA platform for reviving old
computers and consoles), you may know that it, too, offers a "screen centering"
adjustment for its Amiga core. That is not a coincidence. *Any* faithful Amiga
recreation runs into the same wall, because the wall is the Amiga itself, not
the recreation. AExp solves it in the same spirit as MiSTer, so if you have
centered a picture on MiSTer before, this will feel familiar.

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

---

## The easy way: just drop in the ready-made file

Alpha 5 ships with a small settings file called **`aexp_screen.bin`**. It
already contains sensible, tested screen positions for both HDMI and VGA, so for
most people it is truly "set and forget":

1. Copy **`aexp_screen.bin`** into the **`/amiga`** folder on your SD card —
   the same folder that holds `kick.rom` and your disk images.
2. Start (or restart) the core.

That is it. The picture should now be nicely centered. If you are happy, you can
stop reading here.

The core even adjusts automatically as programs change the picture shape: the
Amiga can show a few different "screen modes" (see below), and AExp detects which
one is on screen and applies the matching settings for you. You do not have to
do anything.

---

## The four Amiga screen modes (just so you know)

You do **not** need to understand this to use AExp, but it explains why the file
has four sets of numbers. The Amiga can draw its picture in four shapes:

| Mode              | What it looks like                                    |
|-------------------|-------------------------------------------------------|
| Lores             | The normal, chunky Workbench / games picture          |
| Hires             | A finer, wider picture (e.g. 640-pixel Workbench)     |
| Lores interlaced  | Lores, but taller (used for tall screens; may flicker on VGA) |
| Hires interlaced  | Hires and tall                                        |

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
  1  Hires                     +33     +0     +0     +0           +0     +0     +0     +0
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
