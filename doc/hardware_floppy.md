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

## Writing: new, and the one thing to be careful about

For a long time this feature only read disks. It can now write them too —
the first time any core on the MEGA65 has written a real floppy. That is
worth being careful with, so please read this section rather than skimming
it.

**The disk's own write-protect tab is the only thing standing between a
program and your floppy.** There is no switch in the menu, no "are you sure",
nothing in AExp that will stop a write. If the tab is closed, the emulated
Amiga can write, and it will.

On a 3.5" disk the tab is the little sliding shutter in the corner:

* **Hole open** — the disk is protected. Nothing can be written to it. This
  is what you want for anything you care about.
* **Hole closed** — the disk can be written.

So the rule for your own collection is short: **originals stay open.** Every
disk from the attic, every game, every disk you could not replace — slide the
tab open before it goes anywhere near the slot. Then the drive physically
cannot alter it, no matter what a program tries.

For writing, use blank disks or ones whose contents you would not miss.

### How far along this is

Writing has been tested extremely thoroughly in simulation — the flux the
core produces has been decoded back by a faithful model of the Amiga's own
disk routines, edge for edge — but at the time of writing **no real disk has
been written yet**. You may well be the first. Treat it as what it is: a new
feature in an alpha release, being tried on hardware for the first time.

Also worth knowing: the Amiga does not check its own writing. Nothing on a
real Amiga reads a track back to confirm it landed correctly, so a write that
goes wrong does so quietly, and you will only find out the next time you read
that disk. That is not an AExp quirk; it is how the machine has always
behaved. It is another reason to keep the tab open on anything irreplaceable.

For everyday saving, formatting and Workbench work, disk images in the other
drives remain the easy and safe choice, and they always will be.

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

A write shows as `Motor`, not `Reading`: while the Amiga is writing, nothing
is being read back, so there is no data flowing towards it to report.

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
