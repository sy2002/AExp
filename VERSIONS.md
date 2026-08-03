Version 2 - MONTH DAY, YEAR
===========================

WORK-IN-PROGRES see doc/inofficial.md

* Authentic A500 sound: A500 Filter + LED Filter (both default on)

* Stereo Mix option

* Master volume control (perceptual loudness taper)

* Up to three floppy drives (`df0:`, `df1:`, `df2:`), each of them either a
  read/write `*.adf` disk image or the built-in MEGA65 drive. Choose how many
  drives you want and what each one is in the "Drive Settings" menu

* Hardware Floppy: the built-in MEGA65 disk drive reads real Amiga disks
  (read-only, double density media only)

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
