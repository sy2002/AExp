# Hardware Floppy: real Amiga disks in the MEGA65 drive

Your MEGA65 has a proper 3.5" disk drive built in, and AExp can hand that
drive straight to the emulated Amiga. Put a genuine Amiga floppy — the one
from the shoebox in the attic, with the hand-written label — into the slot,
and the Amiga 500 inside your MEGA65 reads it. No image files, no converting
on a PC first: the actual disk, spinning, being read by the machine you are
sitting in front of.

That is the Hardware Floppy. How drives are configured, and everything about
disk images, lives on [the floppy drives page](drives.md); this page is only
about the real one.

## Turning it on

Press **Help** to open the options menu, go to **Drive Settings**, and set
one of the drives to **Hardware Floppy**. Out of the box that is already done
for you: `df2:` is the Hardware Floppy, while `df0:` and `df1:` are disk
image drives.

There is only one mechanism in your MEGA65, so only one Amiga drive can be
the Hardware Floppy at a time. Giving it to another drive takes it away from
the one that had it. That is not a restriction AExp invented; it is simply
how many drives you own.

Changing anything in Drive Settings cold-boots the Amiga, because a real
Amiga counts and identifies its drives once, at power-on. So make your
choice, let the machine restart, and then insert your disk. There is nothing
to mount and no file to pick: the disk in the slot *is* the disk in the
drive.

## It is read-only, and that is fine

AExp never writes to a real disk. Not a byte, not a sector, not ever. The
emulated Amiga sees the Hardware Floppy as a write-protected drive, exactly
as if the little plastic tab were open, so programs will politely tell you
the disk is protected rather than falling over.

In practice this matters less than it sounds. Hardly anybody wants to write
to a 30-year-old floppy; what people want is to get things *off* one before
it dies. Read-only also rules out the worst thing that can happen to an
original disk: being damaged by a half-finished write. The disk you put in
comes out exactly as it went in.

For saving games, formatting and everyday Workbench work, use a disk image in
one of the other drives. Those are fully read/write.

## Double density only

Amiga floppies are double density (DD), 880 KB formatted. The MEGA65's drive
is a PC-style mechanism, and such a mechanism physically cannot read an Amiga
high-density (HD) disk. So:

* **DD disks** — the normal Amiga kind, one square hole in the corner. These
  work.
* **HD disks** — two square holes, usually marked "HD". These do not, and no
  setting will change that. It is a property of the mechanism, not of AExp.

Since virtually every Amiga disk ever pressed, duplicated or copied at home
is DD, this rules out very little in practice. If a disk has two holes, put
it back in the box.

## Watching it work

While the options menu is open, the Hardware Floppy line shows what the drive
is doing right now:

* `df2:Hardware Floppy` — idle, nothing happening.
* `df2:HW Floppy: Motor` — the motor is spinning, but no data is reaching the
  Amiga.
* `df2:HW Floppy: Reading` — decoded data is streaming into the Amiga.

That makes a surprisingly useful little instrument. If a program sits there
and the line says "Motor", the drive is turning but nothing readable is
coming back — a blank, unformatted or badly worn disk. If it says "Reading",
the disk is talking.

## What to expect from old media

This is an early feature, and it is worth being plain about what that means.
Clean, well-kept disks mount and read. Old or marginal ones produce read
errors, sometimes on a handful of tracks, sometimes on most of them.

The read path has been measured against real disks, and on healthy media it
decodes the magnetic flux correctly, revolution after revolution. The usual
culprit is therefore the disk itself. Floppies from the late 1980s and early
1990s are decades past their design life; the magnetic coating genuinely
sheds, and a disk that read perfectly in 1994 may have lost whole tracks
since. A disk can also *look* immaculate and be unreadable, because the
damage is invisible.

So the practical advice is simple: **if a disk fails, try another one before
suspecting the core.** If three disks read fine and a fourth does not, you
have learned something about the fourth disk. If nothing at all reads, then
something else is going on, and that is worth reporting.

## If the drive knocks and reads nothing after switching on

Very rarely, the drive mechanism itself wakes up confused: right after
switching the MEGA65 on, you insert a disk, the drive answers with a few
seconds of odd knocking, and nothing reads — not even a disk that worked
perfectly yesterday. Ejecting and re-inserting does not help, and neither
does resetting the Amiga.

This is not the core and not your disk. The built-in drive has a small
controller of its own, and once in a blue moon it starts up in a bad state.
That controller only resets with the power, which is exactly why nothing
short of that helps: **switch the MEGA65 off and on again**, and the drive
is back to normal.

If a disk merely produces read errors *without* the knocking, that is a
different story — see the previous section, and try another disk first.

## Getting files off a real disk

Here is what the Hardware Floppy is really good for: rescuing the contents of
a real disk into a disk image, using nothing but the Amiga's own tools.

1. Keep the default drive layout: `df0:` and `df1:` as Disk Image, `df2:` as
   the Hardware Floppy.
2. Mount a Workbench image in `df0:` and a writable image in `df1:` — a
   formatted, empty one is ideal. See [the floppy drives page](drives.md) for
   mounting.
3. Boot Workbench, put your real Amiga disk into the MEGA65's slot, and copy
   across. From the Shell that is something like `copy df2:#? df1: all` — or
   drag the icons between the two disk windows on the Workbench screen, which
   is more fun and does exactly the same thing.
4. Wait until the drive LED has stayed off for a few seconds, so everything
   is safely written back to the SD card.

What you end up with is an ordinary `.adf` file on your SD card, holding the
contents of a disk that will not survive forever. You can back it up, copy it
to a PC, and keep using it long after the original has given up.
