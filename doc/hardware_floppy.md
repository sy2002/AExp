# Hardware Floppy: real Amiga disks in the MEGA65 drive

Your MEGA65 has a proper 3.5" disk drive built in, and AExp can hand that
drive straight to the emulated Amiga. Put a genuine Amiga floppy — the one
from the shoebox in the attic, with the hand-written label — into the slot,
and the Amiga 500 inside your MEGA65 reads it, and writes it. No image files,
no converting on a PC first: the actual disk, spinning, in the machine you
are sitting in front of.

Both directions work on real hardware. Originals boot, copy protection and
all; disks the core writes are read back by real Amigas.

That is the Hardware Floppy. How drives are configured, and everything about
disk images, lives on [the floppy drives page](drives.md); this page is only
about the real one.

## Turning it on

Press **Help** to open the options menu, go to **Drive Settings**, and set
one of the drives to **Hardware Floppy**. Out of the box no drive has it:
AExp starts with a single disk image drive, `df0:`, because some games and
demos do not cope with more than one drive being present.

So you have a choice to make. Either hand `df0:` itself to the Hardware
Floppy — one drive, and it is the real one, which is what you want for
booting an original disk — or raise **Drives** to 2 or 3 and give the
Hardware Floppy to one of the extra drives, which is what you want for
copying between a real disk and a disk image.

There is only one mechanism in your MEGA65, so only one Amiga drive can be
the Hardware Floppy at a time. Giving it to another drive takes it away from
the one that had it. That is not a restriction AExp invented; it is simply
how many drives you own.

Changing anything in Drive Settings cold-boots the Amiga, because a real
Amiga counts and identifies its drives once, at power-on. So make your
choice, let the machine restart, and then insert your disk. There is nothing
to mount and no file to pick: the disk in the slot *is* the disk in the
drive.

## Writing: the one thing to be careful about

For a long time this feature only read disks. It writes them too now — the
first time any core on the MEGA65 has written a real floppy. That is worth
being careful with, so please read this section rather than skimming it.

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

Writing has been tested in simulation and then on real machines. What the
core writes, real Amigas read: an A500 (OCS, Kickstart 1.3) and an A500+
(ECS, Kickstart 2.0) read back all four disks written for the test, and a
repaired A1200 (Kickstart 3.2) read a disk the core had cloned. A complete,
bootable Workbench disk was written from end to end by the core and then
booted on real hardware. Formatting, copying and saving from Workbench all
behave as they should, and a game that writes in its own format — Giana
Sisters storing a high score — wrote to a real disk and read it back after a
power cycle.

Whole-disk copying works too: X-Copy copied 160 tracks with **verify on**
and the read-back was byte-for-byte identical to a known-good reference.
Leaving X-Copy's verify switched on is good advice generally — it costs a
little time and tells you immediately if a disk will not take the data.

Even so, treat this as what it is: a young feature in an alpha release. It
is careful, it is tested, and it can still surprise us.

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

The line is the one belonging to whichever drive you gave the Hardware
Floppy to, so the `df0:` below is `df1:` or `df2:` if you put it there:

* `df0:Hardware Floppy` — idle, nothing happening.
* `df0:HW Floppy: Motor` — the motor is spinning, but no data is reaching the
  Amiga.
* `df0:HW Floppy: Reading` — decoded data is streaming into the Amiga.

A write shows as `Motor`, not `Reading`: while the Amiga is writing, nothing
is being read back, so there is no data flowing towards it to report.

That makes a surprisingly useful little instrument. If a program sits there
and the line says "Motor", the drive is turning but nothing readable is
coming back — a blank, unformatted or badly worn disk. If it says "Reading",
the disk is talking.

## Copy-protected originals

Plenty of Amiga games never shipped as plain AmigaDOS disks. They used custom
track formats, their own loaders, and copy protection that deliberately
depends on how the disk *physically* behaves — sector timings a copier cannot
reproduce, deliberate errors, tracks that only make sense to the game.

Those disks work. One of the most widespread protection schemes on the Amiga
was **Copylock**, by Rob Northen Computing, and titles using it — Cannon
Fodder, The Chaos Engine, Terminator 2, The New Zealand Story — boot and play
from the real disk in the MEGA65's drive. So do custom trackloader formats and the
demoscene loaders that never touched AmigaDOS at all.

Getting there took a specific fix. Copylock does not just read the disk: it
*times* it, by watching one of Paula's registers while raw data goes past and
comparing a slightly short sector against a slightly long one. The Minimig
core that AExp is built on left that register as a stub, so the measurement
always came out the same, the check failed, and the game quietly parked
itself. The
register now reports what the real disk is actually doing, which is why these
titles run.

One thing protection does *not* survive is copying, and that is the whole
point of it. A copier running on the Amiga — X-Copy and friends — cannot
reproduce a Copylock track, on AExp no more and no less than on a real
Amiga. Read your originals directly; do not expect a working copy of one.

## What to expect from old media

Old disks are fine. Originals from the late 1980s and early 1990s boot
directly, including ones their owners described as marginal on real hardware.
For a while AExp read such disks badly and the disks got the blame; that was
wrong. The fault was in how the core re-synchronised at the point on every
track where the original duplicator stopped writing, and once that was fixed
the "bad media" went away.

That does not make every floppy immortal. The magnetic coating really does
shed, and a disk that read perfectly in 1994 may have lost whole tracks
since — invisibly, because that kind of damage does not show. But a failure
is now worth reporting rather than shrugging at: **if a disk fails, try
another one, and if something still looks wrong, please tell us.** A disk
that reads on a real Amiga and not on AExp is a bug, not a tired floppy.

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

1. In **Drive Settings**, set **Drives** to 3, leave `df0:` and `df1:` as
   Disk Image, and set `df2:` to Hardware Floppy. Out of the box only `df0:`
   exists, so this layout has to be set up once — and the Amiga cold-boots
   when you change it.
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
