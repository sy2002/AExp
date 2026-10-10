Version 2 - MONTH DAY, YEAR
===========================

Version 2 turns this core into a complete Amiga 500 experience: the MEGA65's
built-in drive reads and writes real Amiga disks, including copy-protected
originals, and up to three drives mix real disks and `*.adf` images. Together
with the authentic A500 sound filters and four chipset fixes, this is a pure,
faithful and field-tested Amiga 500.

## New Features

* Up to three floppy drives (`df0:`, `df1:`, `df2:`), each of them either a
  read/write `*.adf` disk image or the built-in MEGA65 drive. One drive
  (`df0:`, a disk image) is switched on by default, because a number of games
  and demos misbehave when the Amiga sees more than one. Choose how many
  drives you want and what each one is in the "Drive Settings" menu.

* Hardware Floppy: the built-in MEGA65 disk drive reads and writes real
  Amiga disks (double density media only). Copy-protected originals boot,
  including the widespread Rob Northen Copylock scheme, and disks written
  here are read back by real Amigas.

* New option "DVI (no sound)" in the HDMI menu: sends a plain DVI signal
  instead of HDMI, for displays that stay black on an HDMI stream.

* Authentic A500 sound: the A500's fixed audio output filter and its
  software-controlled "LED filter", which follows the power LED, are
  simulated. Both are on by default and can be switched off in the Audio
  menu.

* New option "Stereo Mix" in the Audio menu: it blends the hard-panned Amiga
  channels for headphones (Full Stereo, Wide Stereo, Narrow Stereo, Mono).

* Master volume in 5% steps. The percentages follow perceived loudness, so
  50% sounds half as loud as 100%.

## Improved Compatibility of the Core

* The CIA timers can count pulses on their external `CNT` pin, as the
  real 8520 chips do. Software that selects this mode, by accident or on
  purpose, no longer sees a timer running when it should stand still. Fixes
  the black screen at startup of Crystal Kingdom Dizzy (Fairlight release).
  MiSTer [PR 230](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/pull/230).

* The blitter freezes when a program switches off fill mode via
  `BLTCON1` while a fill blit is still running, exactly like a real Amiga.
  Fixes the "red vector cube inside a white object" scene of the demo
  Absolute Inebriation by Virtual Dreams. One other scene of that demo still
  shows garbage in the left border, a known issue in all Minimig cores.
  MiSTer [PR 236](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/pull/236).

* Reading the beam position register `VHPOSR` returns the exact value
  a real Agnus reports. It used to read one colour clock ahead and returned
  zero instead of the line length at the end of a line. This matters for
  programs that time their effects by polling the beam. Verified against the
  real-A500 reference images of the
  [vAmiga test suite](https://github.com/dirkwhoffmann/vAmigaTS).
  MiSTer [PR 234](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/pull/234).

* A non-interlaced screen is no longer mistaken for an interlaced one
  when a program clears or toggles the long-frame bit (`LOF`) without
  switching on interlace, which could make the HDMI flicker fixer treat it
  as interlaced. MiSTer
  [issue 231](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/issues/231),
  commit [`d16cd84`](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/commit/d16cd8458cf8e915c5622ecc7c12ce69d776753c).

## Bugfixes

* The analog VGA output shows hires screens (640 pixels wide) in full detail
  in the "Standard VGA" mode. It used to drop every second pixel column of
  hires content such as the Workbench or the text of The Guild of Thieves,
  which made thin fonts unreadable. HDMI and the two 15 kHz modes were not
  affected. GitHub issues [#35](https://github.com/sy2002/AExp/issues/35) and
  [#36](https://github.com/sy2002/AExp/issues/36).

## Improved developer documentation

* New developer documentation in `doc/developers`, also on the documentation
  website: an architecture overview (including every change AExp made to its
  copy of the MiSTer2MEGA65 V2.0.1 framework) and an in-depth design
  document for the Hardware Floppy.

* Documented how a build can miss timing by a few picoseconds in the HyperRAM
  read path, why the IDELAY value must not change, and how `build_all.sh`
  automatically re-rolls such a build.

* The track engine's lineage is documented: it is a hardware port of MiSTer's
  `minimig_fdd.cpp`. Reference copies of `minimig_fdd.cpp` and
  `minimig_config.cpp` are included.

* Testbenches and checker scripts are now part of the repository.

* Source code comments reworked: they describe the current design, without
  references to unpublished notes.
  
* `AGENTS.md` rewritten for AI coding assistants.

Version 1 - July 26, 2026
=========================

Experience the AMIGA 500 with great accuracy and sublime compatibility on your
MEGA65! It runs nearly all games and demos and it offers convenient features.

* Amiga 500, OCS chipset, PAL
* Cycle accurate 68000 CPU
* Kickstart 1.3
* 512 KB Chip RAM plus 512 KB Slow RAM (trapdoor expansion), 1 MB in total
* One floppy drive (`df0:`): read/write standard 880 KB `*.adf` disk images
* Real Amiga mouse in port 1, joystick in port 2
* MEGA65 keyboard mapped to the Amiga keyboard and raw Amiga keyboard mode
* Interlace ("laced") modes with a built-in flicker fixer on HDMI
* Analog output in parallel to HDMI: scandoubled 31 kHz VGA or raw
  15 kHz RGB for CRTs (SCART), selectable in the menu
* Adjustable picture, per Amiga screen mode: HDMI crop plus analog
  position (pan) and analog overscan, via a config file and helper tool
* Battery-backed real-time clock

As this is a "Version 1" there are many large and small features missing. Here
are some of the larger features that are not there yet:

* Kickstart ROM size limited to 256kB, so no Kickstart newer than 1.3.x
* Only one floppy drive (`df0:`)
* No hard disk support
* OCS and PAL only: no ECS, no AGA, no NTSC, no Fast RAM
