# Floppy drives: disk images and real disks

The Amiga 500 was a floppy machine: everything arrived on 3.5" disks, and a
program that wanted more than one disk asked you to plug in another drive.
AExp gives you up to three drives, `df0:`, `df1:` and `df2:`, and each one is
either a disk image file on your SD card or the MEGA65's own built-in 3.5"
drive with a genuine Amiga disk in it.

Everything on this page happens in the options menu, which you open with the
**Help** key.

## The three drives

A drive is one of three things:

* **Disk Image**: an `.adf` file on the SD card. This is the normal case: a
  file that holds a complete Amiga floppy, which the Amiga reads and writes
  like the real thing.
* **Hardware Floppy**: the MEGA65's own internal 3.5" drive, reading and
  writing genuine Amiga disks, copy-protected originals included. Only one
  drive can have it, because there is only one mechanism. See
  [the Hardware Floppy](hardware_floppy.md) for details, including the
  write-protect tab, which is the only thing protecting your floppy from a
  program that writes.
* **Off**: as far as the Amiga is concerned, the drive does not exist.

Out of the box you get one drive: `df0:`, a Disk Image drive, which is also
the boot drive. `df1:` and `df2:` are Off, and no drive is the Hardware
Floppy.

This is deliberate. A number of games and demos do not work when the Amiga
has more than one drive (Riverraid Reloaded is one reported case), so AExp
starts with the single drive those titles expect. Everything else is one
visit to **Drive Settings** away.

## Drive Settings

Open the menu with **Help** and go into **Drive Settings**. At the top is
**Drives** (1, 2 or 3), and below it one mode selection per drive.

The count decides which drives exist. It starts at 1. Raise it to 2 and
`df1:` appears as a Disk Image drive; lower it again and `df1:` switches to
**Off** and disappears. A drive that comes back always comes back as a Disk
Image drive, whatever it was before. `df0:` always exists, because the Amiga
needs a boot drive, so it has no "Off".

Only one drive at a time can be the Hardware Floppy. Handing it to another
drive takes it away from the one that had it, which becomes a Disk Image
drive instead.

Changing anything here cold-boots the Amiga, because a real Amiga detects its
drives only at startup.

## What the menu shows

The top of the menu has one line per existing drive, and the line tells you
what kind of drive it is:

* A **Disk Image** drive shows the name of the mounted file, or `<Load>` when
  it is empty.
* A **Hardware Floppy** drive shows `dfN:Hardware Floppy` for whichever drive
  it is, and reports live status while the menu is open.
* A drive that is **Off** shows no line at all.

## Mounting and ejecting a disk image

Move the cursor onto the drive line and press **Space** to open the file
browser. **Return** does the same, also on a drive that already holds a
disk, which swaps disks in one step.

In the file browser:

| Key | Action |
| --- | --- |
| Up / Down | select a file |
| Left / Right | previous / next page |
| Return | mount the selected file |
| Run/Stop | cancel |
| F1 / F3 | switch between the two SD cards |

To eject, put the cursor on a drive line that holds a disk and press
**Space**.

The browser lists only `.adf` files. The Amiga picks up a mounted disk
immediately, without a reset, and a disk in `df0:` boots.

## Which files are accepted

A standard Amiga floppy holds 880 KB, which is exactly 901,120 bytes, and
almost every `.adf` file has that size. Some disks were dumped with a few
extra tracks (81 to 83 instead of 80), so files of up to 934,912 bytes are
accepted as well. Anything else is refused with a short message naming the
expected size.

## Disk images are read and write

Saved games, high scores, preferences and anything you create in Workbench
end up in the `.adf` file on the SD card, and they are still there next time.

The writing happens in the background while the Amiga keeps running, so the
machine never pauses to save. The drive LED shows what is going on:

* **green**: the Amiga is reading or writing the disk.
* **yellow**: changes are still being written back to the SD card.

## Wait for the LED

Before you eject a disk, reset the machine, or switch it off, **wait until
the LED has stayed off for a few seconds.** Yellow can come back briefly
while the last data is being flushed, so a single glance is not enough. It
is the same discipline as with a real floppy drive, where pulling the disk
out while the light was on could lose your work.

If you try to swap a disk while the Amiga is still writing to the drive,
AExp tells you that the unsaved changes could not be written back yet. Let
the disk activity finish and try again.

## One file, one drive

The same `.adf` file cannot be mounted into two drives at the same time. If
you try, AExp refuses the second mount with a message.

Each drive holds its own working copy of the disk and collects its own
changes. Two drives sharing one file would both write back to it, and
whichever saved last would silently overwrite what the other one saved.

If a program wants two disks, give it two files. If you want a copy of a
disk, make one on the SD card and mount that.

## Changing a drive's mode with a disk in it

Switching a Disk Image drive to Hardware Floppy or to Off first ejects the
disk in it and saves any pending changes, so you do not have to eject by
hand.

A useful combination is a real Amiga disk in the Hardware Floppy, a writable
image in another drive, and the Amiga's own copy tools in between.
[The Hardware Floppy page](hardware_floppy.md) walks through it.
