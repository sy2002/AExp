Amiga 500 for MEGA65
====================

Experience the [Commodore Amiga 500](https://en.wikipedia.org/wiki/Amiga_500)
on your [MEGA65](https://mega65.org/)!

This core turns the MEGA65 into an Amiga 500 with the original OCS chipset
(PAL), a cycle accurate 68000 CPU, 512 KB of Chip RAM and a 512 KB memory
expansion in the trapdoor slot (known as Slow RAM, this is what the classic
Commodore A501 expansion did). The Amiga therefore has 1 MB of RAM in total.

The core is work in progress and not officially released yet. There are
rough edges and missing features, but the basics work: Workbench 1.3 boots
from a mounted ADF disk image and classic demos and games load and run.

![Amiga500](doc/a500_ocs.jpg)

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
* 512 KB Chip RAM plus 512 KB Slow RAM (trapdoor expansion), 1 MB in total
* One floppy drive (`df0:`): mount standard 880 KB `*.adf` disk images
  via the on-screen-menu, currently read-only
* Kickstart 1.3
* Real Amiga mouse in port 1, joystick in port 2, exactly like on a
  real Amiga
* MEGA65 keyboard mapped to the Amiga keyboard

### Kickstart ROM

The core needs the Kickstart 1.3 ROM (revision 34.5, the 256 KB version
that shipped with the Amiga 500). Put it on your SD card as

    /amiga/kick.rom

as a raw dump of exactly 256 KB (262,144 bytes), no byte swapping. Without
this file the core stops with an error message. Kickstart is copyrighted
software, so it is not part of this repository or of any release; you need
to obtain a legal copy yourself, for example from Cloanto's Amiga Forever.

### Floppy disks

Press <kbd>Help</kbd> to open the menu and mount a `*.adf` image via the
`ADF:` item. The disk boots after mounting. Writing is not supported yet:
every mounted disk appears write protected to the Amiga.

### Mouse and joystick

Plug the mouse into port 1 and the joystick into port 2, the same way you
would on a real Amiga. A real Amiga mouse (the classic "tank mouse") works:
movement and the left button behave exactly like on the original machine.

The right mouse button is the one exception: an Amiga mouse signals it on a
line that the MEGA65 hardware cannot read. The core therefore maps the right
mouse button to the <kbd>Run/Stop</kbd> key. Hold <kbd>Run/Stop</kbd> to
hold the right mouse button, for example to open the Workbench menus while
moving the mouse.

### Keyboard

The most important mappings:

| MEGA65                                                | Amiga                                    |
|-------------------------------------------------------|------------------------------------------|
| <kbd>MEGA</kbd>                                       | Left Amiga                               |
| <kbd>RESTORE</kbd>                                    | Right Amiga                              |
| <kbd>CTRL</kbd> + <kbd>MEGA</kbd> + <kbd>RESTORE</kbd> | Ctrl + Left Amiga + Right Amiga (reset) |
| <kbd>Run/Stop</kbd>                                   | Right mouse button (hold)                |
| <kbd>F1</kbd> <kbd>F3</kbd> <kbd>F5</kbd> <kbd>F7</kbd> <kbd>F9</kbd> | F1, F3, F5, F7, F9      |
| <kbd>Shift</kbd> + F-key                              | F2, F4, F6, F8, F10 (as printed on the MEGA65 keycaps) |
| <kbd>Help</kbd>                                       | Opens and closes the core's menu         |

<kbd>Esc</kbd>, <kbd>Tab</kbd> and <kbd>Caps Lock</kbd> work as expected.
Amiga keys that have no MEGA65 counterpart (for example the right Alt key
and most of the numeric keypad) cannot be typed at the moment.

### Video and audio

HDMI outputs 720p at 50 Hz by default. You can select other HDMI modes and
several scaling filters in the menu, from pixel sharp to CRT looks; the
default is a Lanczos filter. We are still figuring out which modes and
filters look best, so expect changes here. The VGA port carries an analog
picture in parallel. Audio is available on HDMI and on the 3.5 mm jack.

Constraints and roadmap
-----------------------

At this moment the core is an alpha version. The largest known gaps:

* Writing to disk images is not supported yet
* Only one floppy drive (`df0:`)
* No hard disk support
* OCS and PAL only: no ECS, no AGA, no NTSC, no Fast RAM

The list of work-in-progress builds lives in [doc/inofficial.md](doc/inofficial.md).

Installation
------------

There is no official release on the MEGA65 Filehost yet. If you have a
`*.cor` or `*.bit` file of one of the work-in-progress builds:

1. Use a FAT32 formatted SD card with a maximum capacity of 32 GB. The card
   in the back slot has precedence over the card in the bottom slot.
2. Copy the Kickstart ROM to `/amiga/kick.rom` as described above.
3. Optional: copy the `aexp-<version>.cfg` file that comes with the build
   into `/amiga` so that the core remembers your menu settings. Without the
   file nothing breaks, your settings are just not saved. The file name
   contains the core version, so after an upgrade you need the matching
   file and need to re-select your settings once.
4. Put your `*.adf` disk images into `/amiga`, the file browser starts
   there.
5. Flash the `*.cor` file using the MEGA65's bitstream utility, or, if you
   have a JTAG adaptor, load the `*.bit` file directly with the
   [M65 tool](https://github.com/MEGA65/mega65-tools):
   `m65 -q yourbitstream.bit`.
6. Press <kbd>Help</kbd> as soon as the core is running to mount a disk
   and to configure the core.
