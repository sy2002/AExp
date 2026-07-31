Amiga 500 for MEGA65
====================

Experience the [Commodore Amiga 500](https://en.wikipedia.org/wiki/Amiga_500)
on your [MEGA65](https://mega65.org/)!

This core turns the MEGA65 into an Amiga 500 with the original OCS chipset
(PAL), a cycle accurate 68000 CPU, 512 KB of Chip RAM and a 512 KB memory
expansion in the trapdoor slot (known as Slow RAM, this is what the classic
Commodore A501 expansion did). The Amiga therefore has 1 MB of RAM in total.

This is Version 1, the first official release. The core is feature complete
and, as far as we can assess, rock solid: it runs 99.9% of all games and demos.

![Amiga500](doc/assets/a500_ocs.jpg)

Credits
-------

* This core is based on the
  [Minimig-AGA core of the MiSTer project](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer).
  Minimig was originally created by Dennis van Weeren and has been improved
  by many others over the years.
* The CPU is [fx68k](https://github.com/ijor/fx68k) by Jorge Cwik, a cycle
  accurate implementation of the 68000.
* [sy2002](http://www.sy2002.de) ported the core to the MEGA65 in 2026.
* The core uses the [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65)
  framework and [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) for
  FAT32 support (loading the Kickstart ROM, mounting disks) and for the
  on-screen-menu.

Features
--------

* Amiga 500, OCS chipset, PAL
* Cycle accurate 68000 CPU
* 512 KB Chip RAM plus 512 KB Slow RAM (trapdoor expansion), 1 MB in
  total; the Slow RAM can be switched off in the menu for the few games
  that need a chip-RAM-only A500
* One floppy drive (`df0:`): mount standard 880 KB `*.adf` disk images
  via the on-screen-menu, read and write
* Kickstart 1.3
* Real Amiga mouse in port 1, joystick in port 2, exactly like on a real
  Amiga — and either device works in either port, so dual-mouse and
  two-player (two-joystick) setups work too
* MEGA65 keyboard mapped to the Amiga keyboard and raw Amiga keyboard mode
* Interlace ("laced") modes with a built-in flicker fixer on HDMI
* Analog output in parallel to HDMI: scandoubled 31 kHz VGA or raw
  15 kHz RGB for CRTs (SCART), selectable in the menu
* Adjustable picture, per Amiga screen mode: HDMI crop plus analog
  position (pan) and analog overscan, via a config file and helper tool  
* Battery-backed real-time clock

### Kickstart ROM

The core needs the Kickstart 1.3 ROM (revision 34.5, the 256 KB version
that shipped with the Amiga 500). Put it on your SD card as

    /amiga/kick.rom

as a raw dump of exactly 256 KB (262,144 bytes), no byte swapping. Without
this file the core stops with an error message. Kickstart is copyrighted
software, so it is not part of this repository or of any release; you need
to obtain a legal copy yourself, for example from Cloanto's Amiga Forever.

### Slow RAM (A501)

A small number of programs — typically early games — do not work correctly
on an Amiga that has expansion RAM: they place their graphics in the
expansion memory, which the Amiga's custom chips cannot display. **Rogue**
is a well-known example: with Slow RAM switched on it fails to draw the
dungeon and the player. On a real A500 the fix was to pull the trapdoor
card out of the machine; here it is a menu item. Open the menu with
<kbd>Help</kbd> and deselect **Slow RAM (A501)**: the Amiga automatically
reboots as a 512 KB chip-RAM-only A500, authentic down to the detail that
the expansion memory area behaves exactly like on a machine without the
trapdoor card. The setting is remembered, so switch it back on for
software that wants the full 1 MB. The battery-backed real-time clock —
on real hardware a part of the A501 — stays available either way.

### Floppy disks

Press <kbd>Help</kbd> to open the menu and mount a `*.adf` image via the
`ADF:` item. The disk boots after mounting. Disks are **read/write**: when
the Amiga writes to a disk — saving a file, formatting, storing a high
score — the change is written back to the `*.adf` file on your SD card.

To **eject** the disk, open the menu with <kbd>Help</kbd>, move the highlight
to the `ADF:` item and press <kbd>Space</kbd>. On
an empty drive that same <kbd>Space</kbd> opens the file browser to mount a
disk instead, so one key both mounts and ejects.

Saving happens in the background, so the Amiga never stalls. The MEGA65's
drive LED lights **green** during disk access — reading or writing — just like
the drive light on a real Amiga. After a write it turns **yellow** while the
change is being written back to the `*.adf` file on the SD card, and goes
**off** once everything is safely saved. Please **wait until the LED has stayed
off for a few seconds** before you unmount a disk, swap disks, reset, or switch
the machine off — the yellow light can briefly come back on as more data is
flushed. Switching off while it is yellow loses the not-yet-saved changes,
exactly like ejecting a real floppy while its drive light is still on.

### Mouse and joystick

Plug the mouse into **port 1** and the joystick into **port 2** — the usual
setup, exactly like on a real Amiga. Both ports accept either device, though,
so a mouse in each port, or a joystick in each port for two-player games, works
just as well. The **original Amiga "Tank Mouse"** is the directly
supported passive mouse; compatible active adapters are listed below.
Commodore C64 mice do **not** work: neither the 1350 ("joystick mouse") nor
the 1351 (proportional mouse) speaks the Amiga's protocol. We may add support
for them in a future version.

The Amiga Tank Mouse works out of the box: movement and the **left button**
behave just like on the original machine.

The **right mouse button** (in Workbench it pulls down the menu bar) is the
tricky one. On a real Amiga the mouse signals it on a special line that the
Amiga's Paula chip actively drives high. The MEGA65 can only *read* that
line, not drive it, so it cannot sense the right button of an original Tank
Mouse. This is a hardware property, identical on every MEGA65 model from R3
to R6. The built-in answer is always available: **hold the <kbd>Run/Stop</kbd>
key** as a right mouse button (hold it while moving the mouse to open the
Workbench menus). This works when your keyboard is in the MEGA65 mode.
In the positional Amiga keyboard mode this substitute moves to the
<kbd>&uarr;</kbd> symbol key (left of <kbd>RESTORE</kbd>), because
there <kbd>Run/Stop</kbd> is the Amiga's <kbd>Esc</kbd>. Both keyboard modes are
summarized in the Keyboard section below.

So what works depends on what you plug in:

| What you use                                                        | Move + left button | Right / middle buttons                    |
|---------------------------------------------------------------------|--------------------|-------------------------------------------|
| Original Amiga "Tank" Mouse                                         | Yes                | Right via <kbd>Run/Stop</kbd>; no middle  |
| Original Amiga "Tank" Mouse with DIY adapter (see below)            | Yes                | Yes                                       |
| Adapter that *actively drives* the line (e.g. Micro Tom, USBAMI)    | Yes                | Yes                                       |
| Faithful Tank Mouse replica that *actively drives* the line (e.g. Alfa Data MegaMouse 400, Amitech Amiga Mouse, Amigakit Mouse)      | Yes                | Yes                                       |
| mouSTer in Amiga-mouse mode                                         | Yes                | Yes(*)                                    |
| Commodore 1350 (C64 "joystick mouse")                               | No                 | No (maybe supported later)                |
| Commodore 1351 (C64 "proportional mouse")                           | No                 | No (maybe supported later)                |

(*) Note on the mouSTer: it emulates a real tank mouse so faithfully that it
inherits the exact same limitation. Therefore you need to
[download firmware version `3.23.5313`](https://github.com/willyvmm/mouSTer/releases/tag/3.23.5313)
or newer. With new firmware, mouSTer supports a new setting in the
`[mouse]` section: `activepotlines=true`. With that, you can use the right
button on your mouse, without it, you need to stick to <kbd>Run/Stop</kbd>.
Here is an example of a known-to-work [MOUSTER.INI](https://github.com/user-attachments/files/29939083/MOUSTER.INI.zip).

**A simple DIY adapter makes the right button work**, even with an original
Tank Mouse. The only missing piece is the pull-up that a real
Amiga's Paula chip provides, and you can add it externally: build a
straight-through DB9 male-to-female passthrough (all nine pins wired 1:1) and
solder two resistors inside the shell, roughly 2 kΩ from pin 7 (+5V) to
pin 9 (right button) and another 2 kΩ from pin 7 to pin 5 (middle button).
With that adapter in line, the right (and middle) button of any faithful
passive mouse works natively.

One heads-up for actively-driving adapters: if you unplug one while the Amiga
is running, the right button can stay "stuck" for up to half a minute
(Workbench shows its menu bar and stops redrawing) before it clears on its
own. Just give it a moment after swapping devices.

#### No mouse? Drive the pointer from the keyboard

Have no Amiga mouse or adapter at hand? You can still operate Workbench. The
Amiga's operating system can move the mouse pointer from the keyboard, and
that feature works on this core too. It is provided by Intuition (the Amiga's
windowing system), so it is available in Workbench and other OS-friendly
programs — but **not** in games or demos that take over the machine.

The MEGA65 keys map onto the Amiga's built-in combinations like this:

| Action                      | Keys                                                                   |
|-----------------------------|------------------------------------------------------------------------|
| Move the pointer            | <kbd>MEGA</kbd> + <kbd>&uarr;</kbd> <kbd>&darr;</kbd> <kbd>&larr;</kbd> <kbd>&rarr;</kbd> |
| Move the pointer **faster** | <kbd>MEGA</kbd> + <kbd>Shift</kbd> + <kbd>&uarr;</kbd> <kbd>&darr;</kbd> <kbd>&larr;</kbd> <kbd>&rarr;</kbd> |
| **Left** mouse button       | <kbd>MEGA</kbd> + <kbd>Alt</kbd> *(Amiga mode: <kbd>MEGA</kbd> + <kbd>F13</kbd>)* |
| **Right** mouse button      | <kbd>Run/Stop</kbd> *(Amiga mode: <kbd>&uarr;</kbd> key)*               |

<kbd>MEGA</kbd> is the Amiga's *left Amiga* key and <kbd>Alt</kbd> is its
*left Alt*, so <kbd>MEGA</kbd> + <kbd>Alt</kbd> is exactly the Amiga's
built-in "left click". (In the positional Amiga keyboard mode the *left Alt* key
moves to <kbd>F13</kbd>, so use <kbd>MEGA</kbd> + <kbd>F13</kbd> there.) The
pointer keeps accelerating the longer you hold an arrow, so tap the keys for fine
positioning and hold them to cross the screen.

### Keyboard

The MEGA65 keyboard drives the Amiga, and you choose **how**. Two mapping
modes are available in the menu's **Keyboard** section:

* **MEGA65 mode** (default) — *the cap is law*: you get exactly the character
  printed on the MEGA65 keycap, including the front-face symbols typed with
  <kbd>MEGA</kbd> (so `{` is <kbd>MEGA</kbd>+<kbd>:</kbd>, `~` is
  <kbd>MEGA</kbd>+<kbd>,</kbd>, and so on). Best if the MEGA65 is the keyboard
  you know.
* **Amiga mode** — *positional*: each key sends the Amiga key in the same
  place on a real Amiga keyboard, so the shifted number row and a few
  punctuation keys follow the Amiga's own labels. Best for Amiga muscle memory
  and for games such as Pinball Dreams that require the original Amiga
  mapping.

The most important keys (the meanings below are for the default MEGA65 mode;
where Amiga keyboard mode differs from the MEGA65 keyboard mode is noted in the right column):

| MEGA65 keyboard                                                       | Amiga                                         |
|-----------------------------------------------------------------------|-----------------------------------------------|
| <kbd>MEGA</kbd>                                                       | Left Amiga; in MEGA65 mode it also selects front-face symbols |
| <kbd>CTRL</kbd> + <kbd>MEGA</kbd> + <kbd>RESTORE</kbd>                | Ctrl + Left Amiga + Right Amiga (reset)       |
| <kbd>RESTORE</kbd>                                                    | Right Amiga · *Amiga mode:* Right Alt         |
| <kbd>Run/Stop</kbd>                                                   | Right mouse button, hold · *Amiga mode:* Esc  |
| <kbd>F1</kbd> <kbd>F3</kbd> <kbd>F5</kbd> <kbd>F7</kbd> <kbd>F9</kbd> | F1, F3, F5, F7, F9 *(MEGA65 mode)*            |
| <kbd>Shift</kbd> + <kbd>F1</kbd>/<kbd>F3</kbd>/<kbd>F5</kbd>/<kbd>F7</kbd>/<kbd>F9</kbd> | F2, F4, F6, F8, F10 *(MEGA65 mode)* |
| Top row from <kbd>Run/Stop</kbd> through <kbd>F11</kbd>               | Esc, F1–F10 *(Amiga mode)*                    |
| <kbd>Help</kbd>                                                       | Amiga Help; default menu key                   |

In the default **MEGA65 mode** <kbd>Esc</kbd>, <kbd>Tab</kbd> and
<kbd>Caps Lock</kbd> work as expected. In **Amiga mode** the entire top row is
positional — <kbd>Run/Stop</kbd> is Esc, <kbd>Esc</kbd> is F1, <kbd>Alt</kbd> is
F2, <kbd>Caps Lock</kbd> is F3 … <kbd>F11</kbd> is F10 — the right mouse button
moves to the <kbd>&uarr;</kbd> symbol key (left of <kbd>RESTORE</kbd>), and
<kbd>F13</kbd> becomes Left Alt. The full per-key breakdown is in the guide below.

By default <kbd>Help</kbd> opens the menu, but you can reassign it — to
<kbd>F11</kbd>, <kbd>F13</kbd> or <kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> — in the
Keyboard menu, which reserves <kbd>Help</kbd> solely for the Amiga. In MEGA65
mode, <kbd>F11</kbd> and <kbd>F13</kbd> are clean menu keys that send nothing to
the Amiga. In Amiga mode they also send F10 and Left Alt respectively; see the
guide for the effect of every menu-key choice.

**The full keyboard guide — complete per-mode tables for typing, special keys,
menu keys, and steering the mouse from the keyboard — is in
[doc/keyboard.md](doc/keyboard.md).**

### Video: HDMI

HDMI outputs 720p at 50 Hz (16:9) by default. The first `HDMI:` menu
entry offers the other 50 Hz modes: 576p at 50 Hz in 4:3 or 5:4.

**An OCS PAL Amiga is a 50 Hz machine**, so only faithful 50 Hz modes are
offered. 

The second `HDMI:` menu entry, directly below the display mode, selects
the scaling filter:

| Filter          | Look                                                      |
|-----------------|-----------------------------------------------------------|
| No Filter       | nearest neighbor: maximum sharpness, visible pixel stairs |
| Sharp Bilinear  | pixel sharp, but with softened stair edges                |
| Bicubic         | smooth all-round interpolation                            |
| Smooth          | soft polyphase scaling                                    |
| Lanczos         | crisp polyphase scaling; the default                      |
| Scanlines       | Lanczos plus visible scanlines                            |
| CRT (S-Video)   | scanlines plus a slightly softened picture, like S-Video  |
| CRT (Composite) | scanlines plus heavy horizontal blur, like an antenna or composite cable |

These two features both fight "flicker", but they cure two entirely
different things — one the shimmer of interlaced screens, the other a
periodic hitch in smooth motion:

#### Interlace flicker fixer (automatic)

Laced screens such as the 640x512 Workbench or the interlaced pictures that
demos love are woven into a stable, full-resolution HDMI picture — the same
job the A3000's "Amber" chip or an Indivision does on real hardware. This
runs automatically; there is no menu entry for it. Demos that flicker *on
purpose* (alternating two images at 50 Hz to fake extra colors, transparency
or glowing lights) keep flickering: that is the intended look, and only a CRT
softens it.

#### Flicker-free: smooth motion (menu entry)

The third `HDMI:` menu entry, **Flicker-free** (on by default), keeps the
HDMI picture perfectly smooth. An Amiga runs a hair below 50 Hz while HDMI
is locked to exactly 50 Hz, so without correction the picture drops or
repeats one frame roughly every twelve seconds — a small judder or tear,
most visible on horizontal scrollers. Flicker-free nudges the Amiga clock
by a fraction of a percent so its frame rate averages exactly 50 Hz and
the seam disappears. **Turn it off for the analog VGA / 15 kHz outputs**:
there it would make the sync frequency step, which analog monitors
dislike. (With it on, the machine also runs about 0.16 % fast, so software
clocks gain a few seconds per hour — turn it off if you need authentic
timing.)

#### Latency on the Checkmate Retro Monitor

Because the Checkmate is a popular choice, it deserves a note of its own.
The monitor appears to use a native 60 Hz panel and introduces considerable
latency when displaying the 50 Hz output of our PAL AExp core, although
scrolling remains smooth with Flicker-free enabled. We suspect that the
latency comes from the internal conversion required to display a 50 Hz
signal on a 60 Hz panel. Deft recorded 
[several videos demonstrating the effect (click here)](https://github.com/sy2002/MiSTer2MEGA65/issues/72),
comparing the Checkmate with a 15 kHz analog monitor and a Samsung HDMI
monitor in Gaming Mode, which adds almost no HDMI latency.

### Video: VGA port (analog RGB)

The VGA connector always carries the picture in parallel to HDMI. The
`VGA:` menu selects one of three modes:

* **Standard** (default): the Amiga's 15.6 kHz picture is line-doubled to
  31 kHz so that VGA monitors accept it. Note that it is still a 50 Hz
  signal, which not every flat panel likes.
* **15 kHz with HS/VS**: the raw 15.6 kHz RGB signal with separate
  horizontal and vertical sync, for retro monitors with a VGA-style
  input.
* **15 kHz with CSYNC**: the raw 15.6 kHz RGB signal with composite sync,
  which is what RGB SCART cables and most CRT setups expect.

On a 15 kHz CRT you get the most authentic Amiga picture possible:
interlace is displayed natively by the tube (no flicker fixer needed) and
the intentional flicker effects of demos melt on the phosphor exactly as
their authors intended.

For how to connect real CRT monitors — BNC, SCART and DB9 RGB, including
important safety cautions — see [doc/retrotubes.md](doc/retrotubes.md).

The on-screen menu is oversized in both raw 15 kHz modes. Open the
**`OSM: 100%`** menu entry (the percentage changes with your selection) and
choose a smaller size, down to 50%, until the menu fits your display
comfortably. This changes only the menu, not the Amiga picture. The setting
is global, so it also changes the menu size on HDMI and in Standard VGA mode.

Careful: a regular VGA monitor shows **no picture at all** in the 15 kHz
modes — including the on-screen-menu. If you locked yourself out, connect
an HDMI display and switch back there; both outputs share the same menu.

### Screen adjustment

The Amiga's picture may not sit perfectly on your screen — an old quirk that
every faithful Amiga recreation shares. AExp fixes it: drop a small 
`aexp_screen.cfg` file into `/amiga` and the core adjusts the
picture, automatically per Amiga screen mode. Three independent controls are
available: **HDMI crop** re-frames the picture on HDMI; **analog position**
moves the complete analog picture (OSM included) left/right/up/down in all
three VGA modes; **analog overscan** hides or reveals the Amiga border edges,
which some demos fill with odd-looking material. Two ready-made files ship
with the core (one for 16:9 displays, one tuned like a 4:3 monitor); pick the
one that looks best, or fine-tune your own with the included
`aexp_screen_cfg.py` tool. The full guide is in
[doc/screen_adjust.md](doc/screen_adjust.md).

### Audio

Audio is available on HDMI and on the 3.5 mm jack, carrying Paula's
output as-is.

### Real-time clock

AExp can feed the Amiga the MEGA65's own battery-backed clock, so Workbench
shows the real date and time and your files get proper timestamps. It takes a
minute to set up, and Kickstart 1.3 has two quirks worth knowing about (the
year can come out as 1978, and the time can be an hour off — both with simple
fixes, neither a fault of AExp). The full walkthrough is in
[doc/RTC.md](doc/RTC.md).

Constraints and roadmap
-----------------------

Version 1 is feature complete, so — among other things — the following known
gaps remain in this release:

* Kickstart ROM size limited to 256 KB, so no Kickstart newer than 1.3.x
* Only one floppy drive (`df0:`)
* No hard disk support
* OCS and PAL only: no ECS, no AGA, no NTSC, no Fast RAM

The development history — all the alpha and beta work-in-progress builds — is
documented in [doc/inofficial.md](doc/inofficial.md).

Installation
------------

To install the core you need its `*.cor` file (or a `*.bit` file if you flash
via JTAG). Then:

1. Use a FAT32 formatted SD card with a maximum capacity of 32 GB. The card
   in the back slot has precedence over the card in the bottom slot.
2. Copy the Kickstart ROM to `/amiga/kick.rom` as described above.
3. Optional: copy the `aexp-<version>.cfg` file that comes with the build
   into `/amiga` so that the core remembers your menu settings. Without the
   file nothing breaks, your settings are just not saved. The file name
   contains the core version, so after an upgrade you need the matching
   file and need to re-select your settings once.
4. Optional: copy the `aexp_screen.cfg` file into `/amiga` and the core
   adjusts the picture, automatically per Amiga screen mode.
5. Put your `*.adf` disk images into `/amiga`, the file browser starts
   there.
6. Flash the `*.cor` file using the MEGA65's bitstream utility, or, if you
   have a JTAG adaptor, load the `*.bit` file directly with the
   [M65 tool](https://github.com/MEGA65/mega65-tools):
   `m65 -q yourbitstream.bit`.
7. Press <kbd>Help</kbd> as soon as the core is running to mount a disk
   and to configure the core.

Developers
----------

Want to build the core from source? In [doc/developers.md](doc/developers.md)
you will find the whole path from a fresh clone to a `*.cor` file. This core
is built on the [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M)
framework, whose [Wiki](https://github.com/sy2002/MiSTer2MEGA65/wiki) is the
authoritative reference for the build environment and its
operating-system specific details.
