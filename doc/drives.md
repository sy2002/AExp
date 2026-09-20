# Floppy drives: disk images and real disks

The Amiga 500 was a floppy machine. Everything arrived on 3.5" disks, and a
program that wanted more than one disk simply asked you to plug in another
drive. AExp gives you up to three of them — `df0:`, `df1:` and `df2:` — and
each one is either a disk image file on your SD card or the MEGA65's own
built-in 3.5" drive with a genuine Amiga disk in it.

Everything on this page happens in the options menu, which you open with the
**Help** key.

## The three drives

A drive is one of three things:

* **Disk Image** — an `.adf` file on the SD card. This is the normal case: a
  file that holds a complete Amiga floppy, which the Amiga reads and writes
  just like the real thing.
* **Hardware Floppy** — the MEGA65's own internal 3.5" drive. Read-only, and
  only one drive can have it, because there is only one mechanism. See
  [the Hardware Floppy](hardware_floppy.md) for the whole story.
* **Off** — the drive does not exist at all, as far as the Amiga is concerned.

Out of the box you get three drives: `df0:` and `df1:` are Disk Image, and
`df2:` is the Hardware Floppy. `df0:` is the boot drive.

## Drive Settings

Open the menu with **Help** and go into **Drive Settings**. At the top is
**Drives** — 1, 2 or 3 — and below it one mode selection per drive.

The count decides which drives exist. Set it to 2 and `df2:` switches to
**Off** and disappears; set it back to 3 and `df2:` returns as a Disk Image
drive. `df0:` always exists, which is why it has no "Off" — an Amiga without
a boot drive would be a doorstop.

Only one drive at a time can be the Hardware Floppy. Handing it to another
drive takes it away from the one that had it, which becomes a Disk Image
drive instead.

Changing anything here cold-boots the Amiga. That is not AExp being dramatic:
a real Amiga counts and identifies its drives while it starts up, so the only
honest way to add, remove or swap one is to start the machine again.

## What the menu shows

The top of the menu has one line per drive that exists, and the line tells
you what kind of drive it is:

* A **Disk Image** drive shows the name of the mounted file, or `<Load>` when
  it is empty.
* A **Hardware Floppy** drive shows `df2:Hardware Floppy` (or whichever drive
  it is), and reports live status while the menu is open.
* A drive that is **Off** shows nothing at all. No line, no placeholder.

## Mounting and ejecting a disk image

Move the cursor onto the drive line and press **Space**: the file browser
opens. **Return** does the same, including on a drive that already holds a
disk, which is how you swap disks in one go.

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

The browser only lists `.adf` files, so you cannot accidentally hand the
drive a picture of your cat. A mounted disk is picked up by the Amiga
immediately — no reset needed — and a disk in `df0:` boots.

## Which files are accepted

A standard Amiga floppy holds 880 KB, which is exactly 901,120 bytes, and
that is what almost every `.adf` file out there is. Some disks were dumped
with a few extra tracks (81 to 83 instead of 80), so files of up to 934,912
bytes are accepted as well. Anything else is refused with a short message
naming the expected size.

## Disk images are read and write

Saved games, high scores, preferences and anything you create in Workbench
end up in the `.adf` file on the SD card, and they are still there next time.

The writing happens in the background while the Amiga keeps running, so there
is never a pause where the machine freezes to "save". The drive LED tells you
what is going on:

* **green** — the Amiga is reading or writing the disk.
* **yellow** — changes are still being written back to the SD card.

## Wait for the LED

Before you eject a disk, reset the machine, or switch it off: **wait until
the LED has stayed off for a few seconds.** Yellow can come back briefly
while the last data is being flushed, so a single glance is not enough.

This is the same discipline as with a real floppy drive, where pulling the
disk out while the light was on was the classic way to lose an afternoon of
work. The mechanism is different, the lesson is identical.

If you try to swap a disk while the Amiga is hammering the drive, AExp tells
you that the unsaved changes could not be written back yet. Let the disk
activity finish and try again.

## One file, one drive

The same `.adf` file cannot be mounted into two drives at the same time. If
you try, AExp refuses the second mount with a message.

The reason is worth understanding, because the rule looks arbitrary until you
see it. Each drive holds its own working copy of the disk and collects its
own changes. Two drives sharing one file would both write back to it, and
whichever one saved last would silently paint over what the other one saved.
Rather than let you discover that at the worst possible moment, AExp
declines.

If a program wants two disks, give it two files. If you want a copy of a
disk, make one on the SD card and mount that.

## Changing a drive's mode with a disk in it

Switching a Disk Image drive to Hardware Floppy or to Off ejects whatever was
in it first, saving any pending changes before the disk goes away, so you do
not have to eject by hand.

One combination is particularly useful: a real Amiga disk in the Hardware
Floppy, a writable image in another drive, and the Amiga's own copy tools in
between. [The Hardware Floppy page](hardware_floppy.md) walks through it.
