Version 1 - MONTH, 2026
=======================

BETA VERSION 2, RELEASE CANDIDATE

See [doc/inofficial.md](doc/inofficial.md) for details.

Experience the AMIGA 500 with great accuracy and already pretty good
compatibility on your MEGA65! It can run a ton of games and demos and it
offers convenient features.

* Amiga 500, OCS chipset, PAL
* Cycle accurate 68000 CPU
* 512 KB Chip RAM plus 512 KB Slow RAM (trapdoor expansion), 1 MB in total
* One floppy drive (`df0:`): mount standard 880 KB `*.adf` disk images
  via the on-screen-menu, read and write
* Kickstart 1.3
* Real Amiga mouse in port 1, joystick in port 2, exactly like on a
  real Amiga
* MEGA65 keyboard mapped to the Amiga keyboard and raw Amiga keyboard mode
* Interlace ("laced") modes with a built-in flicker fixer on HDMI
* Analog output in parallel to HDMI: scandoubled 31 kHz VGA or raw
  15 kHz RGB for CRTs (SCART), selectable in the menu
* Adjustable picture, per Amiga screen mode: HDMI crop plus analog
  position (pan) and analog overscan, via a config file and helper tool
* Battery-backed real-time clock

As this is a "Version 1" there are many large and small features missing. Here
are some of the larger features that are not there yet:

* Kickstart 1.3 (ROM size limited to 256kB)
* Only one floppy drive (`df0:`)
* No hard disk support
* OCS and PAL only: no ECS, no AGA, no NTSC, no Fast RAM
