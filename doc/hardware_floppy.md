# Hardware Floppy: real Amiga disks in the MEGA65 drive

Your MEGA65 has a 3.5" disk drive built in, and AExp can hand it to the
simulated Amiga. Put a genuine Amiga floppy into the slot, and the Amiga 500
inside your MEGA65 reads it and writes it: no image files, no converting on a
PC first. Originals boot, copy protection included, and real Amigas read the
disks the core writes.

This page is only about the real drive. How drives are configured, and
everything about disk images, is on [the floppy drives page](drives.md).

## Turning it on

Press **Help** to open the options menu, go to **Drive Settings**, and set
one of the drives to **Hardware Floppy**. Out of the box no drive has it:
AExp starts with a single disk image drive, `df0:`, because some games and
demos do not cope with more than one drive.

You have two choices. Give `df0:` itself to the Hardware Floppy, so the one
drive is the real one; that is what you want for booting an original disk.
Or raise **Drives** to 2 or 3 and give the Hardware Floppy to one of the
extra drives; that is what you want for copying between real disks and disk
images.

There is only one mechanism in your MEGA65, so only one Amiga drive can be
the Hardware Floppy at a time. Giving it to another drive takes it away from
the one that had it.

Changing anything in Drive Settings cold-boots the Amiga, because a real
Amiga detects its drives only at power-on. Make your choice, let the machine
restart, and then insert your disk. There is nothing to mount and no file to
pick: the disk in the slot *is* the disk in the drive.

## Writing: the one thing to be careful about

The Hardware Floppy writes disks as well as reading them, so please read this
section before you insert a disk you care about.

**The disk's own write-protect tab is the only thing protecting your
floppy.** There is no switch in the menu, no "are you sure", nothing in AExp
that stops a write. If the tab is closed, the simulated Amiga can write, and
it will.

On a 3.5" disk the tab is the little sliding shutter in the corner:

* **Hole open**: the disk is protected and nothing can be written to it. Use
  this for anything you care about.
* **Hole closed**: the disk can be written.

So the rule for your collection is: **originals stay open.** Slide the tab
open on every game, every old disk and every disk you could not replace
before it goes near the slot. Then the drive physically cannot alter it,
whatever a program tries.

For writing, use blank disks or ones whose contents you would not miss.
Writing real disks is the youngest part of the core.

The Amiga does not check its own writes: nothing on a real Amiga reads a
track back to confirm it, so a failed write goes unnoticed until you next
read that disk. This is why X-Copy's verify option is worth keeping on, and
another reason to keep the tab open on anything irreplaceable.

For everyday saving, formatting and Workbench work, disk images in the other
drives remain the easy and safe choice.

## Double density only

Amiga floppies are double density (DD), 880 KB formatted. The MEGA65's drive
is a PC-style mechanism, and such a mechanism physically cannot read an Amiga
high-density (HD) disk. So:

* **DD disks**, the normal Amiga kind with one square hole in the corner,
  work.
* **HD disks**, with two square holes and usually marked "HD", do not, and no
  setting changes that. It is a property of the mechanism, not of AExp.

Almost every Amiga disk ever pressed, duplicated or copied at home is DD, so
this rules out very little in practice.

## Watching it work

While the options menu is open, the Hardware Floppy line shows what the drive
is doing. The line belongs to whichever drive has the Hardware Floppy, so
read the `df0:` below as `df1:` or `df2:` if you put it there:

* `df0:Hardware Floppy`: idle.
* `df0:HW Floppy: Motor`: the motor is spinning, but no data is reaching the
  Amiga.
* `df0:HW Floppy: Reading`: decoded data is streaming into the Amiga.

A write shows as `Motor`, not `Reading`: while the Amiga writes, nothing is
read back, so no data flows towards it.

This helps when something does not load. If a program waits and the line
says `Motor`, the drive is turning but nothing readable comes back: the disk
is blank, unformatted or badly worn. If it says `Reading`, the disk is being
read.

## Copy-protected originals

Many Amiga games never shipped as plain AmigaDOS disks. They used custom
track formats, their own loaders, and copy protection that depends on how
the disk *physically* behaves: sector timings a copier cannot reproduce,
deliberate errors, tracks that only make sense to the game.

Those disks work. One of the most widespread protection schemes on the Amiga
was **Copylock** by Rob Northen Computing, and titles using it (Cannon
Fodder, The Chaos Engine, Terminator 2, The New Zealand Story) boot and play
from the real disk in the MEGA65's drive. So do custom trackloader formats
and demoscene loaders that never used AmigaDOS at all.

Copylock does not just read the disk, it *times* it: it watches one of
Paula's registers while raw data goes past and compares a slightly short
sector against a slightly long one. AExp feeds that register with what the
real disk is doing, so the check passes.

Protection does not survive copying, which is its purpose. A copier running
on the Amiga, such as X-Copy, cannot reproduce a Copylock track, on AExp just
as on a real Amiga. Use your originals directly and do not expect a working
copy of one.

## What to expect from old media

Old disks are fine. Originals from the late 1980s and early 1990s boot
directly, including ones their owners described as marginal on real
hardware. The core copes with the point on every track where the original
duplicator stopped writing, which is where old disks are hardest to read.

Floppies still age. The magnetic coating sheds, and a disk that read
perfectly in 1994 may have lost whole tracks since, without any visible
damage. **If a disk fails, try another one, and if something still looks
wrong, please tell us.** A disk that reads on a real Amiga but not on AExp is
a bug, not a tired floppy.

## If the drive knocks and reads nothing after switching on

Rarely, the drive mechanism itself starts up in a bad state: right after you
switch the MEGA65 on and insert a disk, the drive knocks for a few seconds
and nothing reads, not even a disk that worked yesterday. Ejecting and
re-inserting does not help, and neither does resetting the Amiga.

Neither the core nor your disk is at fault. The built-in drive has a small
controller of its own, which occasionally starts up in a bad state and
resets only with the power. **Switch the MEGA65 off and on again**, and the
drive is back to normal.

Read errors *without* the knocking are a different matter: see the previous
section, and try another disk first.

## What you can do with it

Real Amigas read what the core writes: an A500 (OCS, Kickstart 1.3) and an
A500+ (ECS, Kickstart 2.0) read back disks the core had written, an A1200
with Kickstart 3.2 read a disk the core had cloned, and a bootable Workbench
disk cloned end to end by the core booted on real hardware. Everything below
has been done on real hardware.

Most recipes use this three-drive layout. In **Drive Settings**, set
**Drives** to 3, leave `df0:` and `df1:` as Disk Image, and set `df2:` to
Hardware Floppy. Out of the box only `df0:` exists, so you set this up once.
The Amiga cold-boots when you change it, so do it before you load X-Copy or
Workbench. See [the floppy drives page](drives.md) for mounting disk images.

Whenever a recipe writes to a real disk, the write-protect tab is the only
guard: keep it open (protected) on the disk you copy from, and close it only
on the disk you mean to overwrite.

### Make a real disk from an ADF with X-Copy

1. Set up the three-drive layout above.
2. Mount the ADF you want to write in `df1:`, then the X-Copy ADF in `df0:`.
   A disk in `df0:` boots as soon as it is mounted.
3. Put a blank disk, or one you do not need, into the MEGA65's drive with its
   tab closed.
4. In X-Copy, select `df1:` as the source and `df2:` as the target, switch
   verify on, and start the copy.

With verify on, X-Copy reads every track back and tells you at once if the
disk does not take the data. A whole-disk copy of 160 tracks made this way
was byte-identical to a known-good reference.

### Copy a real disk into an ADF, and back

With the same layout and X-Copy in `df0:`, mount an ADF you can overwrite in
`df1:` and put the real disk, tab open, into the drive. In X-Copy, copy from
`df2:` to `df1:` with verify on, and you have the disk as an ADF on your SD
card; wait for the drive LED to stay off before you unmount it. To write it
to another real disk, insert a blank one with its tab closed and copy from
`df1:` to `df2:`, again with verify on. Copy-protected tracks do not survive
this, as explained above.

X-Copy can also copy through memory with a single drive: choose the Hardware
Floppy as both source and target, switch verify on, and swap the disks when
X-Copy asks.

### Format a disk and work with it in Workbench

Boot Workbench 1.3 from an ADF in `df0:` with the Hardware Floppy as another
drive. Format a real disk in the Hardware Floppy, copy files and programs
onto it, and they load and run from it after you switch off and boot again.

Games that save in their own non-DOS format work too: Giana Sisters saved a
high score to a real disk, and it was still there after a power cycle.

### Getting files off a real disk

You can rescue the contents of a real disk into a disk image with nothing
but the Amiga's own tools:

1. Set up the three-drive layout above.
2. Mount a Workbench image in `df0:` and a writable image in `df1:`; a
   formatted, empty one is ideal.
3. Boot Workbench, put your real Amiga disk into the MEGA65's slot with its
   tab open, and copy across. From the Shell that is something like
   `copy df2: to df1: all`, or drag the icons between the two disk windows
   on the Workbench screen.
4. Wait until the drive LED has stayed off for a few seconds, so everything
   is safely written back to the SD card.

The result is an ordinary `.adf` file on your SD card, holding the contents
of a disk that will not last forever. You can back it up, copy it to a PC,
and keep using it long after the original has given up.
