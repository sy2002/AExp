# Real-Time Clock: date and time on the Amiga

AExp can feed the emulated Amiga 500 the MEGA65's own battery-backed clock. Once
it is set up, Workbench shows the real date and time, and the files you create
carry proper timestamps.

Setup takes a minute. There are also two small surprises worth knowing about: on
Kickstart 1.3 the year can come out wrong (stuck at 1978), and the time can be
off by an hour. Both have simple fixes, and neither is a fault in AExp. A real
Amiga 500 running Kickstart 1.3 behaves exactly the same way.

---

## Setting it up

The Amiga 500 shipped without a clock. It was an add-on that lived on the A501
trapdoor expansion, and Kickstart 1.3 does not read it on its own. So two things
need to be in place:

1. **Set the MEGA65's clock.** Make sure your MEGA65 clock is set to the
   correct date and time and that it works. (On some R3 machines you need a
   hardware fix for the RTC.)
2. **Load the clock at boot.** Your Workbench disk needs to run `SetClock LOAD`
   early in its `s:startup-sequence`. Stock Workbench 1.3 disks already do this,
   so there is usually nothing to add.

Now boot the core, open a Shell, and type `date`. You should see the current
date and time.

---

## Surprise: the year says 1978

If `date` prints something like this:

```
Sunday 09-Jul-78 16:48:20
```

then the day, month, and time are correct, but the year is wrong. It should read
2026.

### Why it happens

The Amiga's clock chip stores the year as just two digits, `00` to `99`. It
never records the century, so the software has to fill that part in. Commodore's
intended rule was:

- `78`–`99` means 1978–1999
- `00`–`77` means 2000–2077

By that rule, `26` becomes 2026. The trouble is the `SetClock` program on the
original Workbench 1.2 and 1.3 disks. It predates the year 2000 and never applies
that rule. It reads every two-digit year as `19xx`, and because 1926 is earlier
than the Amiga's starting point of 1 January 1978, it gives up and falls back to
1978. The day, month, and time are worked out separately, which is why they stay
correct while only the year looks wrong.

AExp hands the Amiga the right value the whole time (the digits `2` and `6`). The
century mix-up happens entirely inside that old `SetClock`. Commodore released a
corrected version back in 1998, and that update is the whole fix.

### Fix option A: replace the SetClock file

Swap the old `SetClock` on your Workbench disk for the corrected one, called
**SetClock 34.3**.

1. Download it from Olaf Barthel's site:
   [SetClock_v34.3.lha](https://amiga.de/diary/developers/SetClock_v34.3.lha).
   The page that explains the whole thing is
   [amiga.de/diary/developers/y2k.html](https://amiga.de/diary/developers/y2k.html).
2. Unpack the `.lha` archive. Inside is a single program, `SetClock` (about
   7 KB, dated September 1998).
3. Copy it into the `C:` drawer of your Workbench 1.3 disk image, replacing the
   old one. On a PC or Mac, `xdftool` from amitools does the job:
   ```
   xdftool workbench-1.3.adf delete c/SetClock
   xdftool workbench-1.3.adf write SetClock c/SetClock
   ```
   You can also mount the ADF in WinUAE and run `copy SetClock c:`.
4. Boot the disk. The `SetClock LOAD` line already in the startup-sequence takes
   care of the rest.
5. Check the result: `version c:setclock` should report `34.3`, and `date`
   should now show 2026.

Do not judge the file by its size. An old guide suggests a good `SetClock` is
under 1 KB, but the corrected 34.3 is itself around 7 KB, so size tells you
nothing here. Trust `version c:setclock`.

### Fix option B: download a Workbench that already has the fix

If you would rather not edit files by hand, grab a Workbench image that already
ships the corrected `SetClock`. The Internet Archive hosts the full Commodore
Workbench collection:

[archive.org/details/commodore-amiga-operating-systems-workbench](https://archive.org/details/commodore-amiga-operating-systems-workbench)

Look for **Workbench 1.3.3, Cloanto Amiga Forever Edition**. Cloanto's release
includes a Y2K-corrected `SetClock`, so once you boot it and `SetClock LOAD`
runs, the year is already right. The plain "(Commodore)" 1.3.3 images still carry
the original buggy `SetClock`, so after downloading, confirm with
`version c:setclock` and switch to Option A if it reports an older version.

Workbench 1.3.3 (revision 34.34) is the last release of the 1.3 line, so it is as
new as you can go while staying on Kickstart 1.3, which is what AExp runs.
Workbench itself is copyrighted software, so download it for a machine you are
entitled to use it on.

---

## A few things worth knowing

- The clock is read-only from the Amiga's side. Set the time on the MEGA65, not
  with `SetClock SAVE` inside the Amiga.
- Even while the year shows 1978, file dates still sort correctly against each
  other, because AmigaDOS counts days from its 1978 origin. Only the printed year
  looks off, so demos and everyday work are unaffected.
- Everything here matches a real Amiga 500 with Kickstart 1.3. The fixes are the
  same ones the Amiga community has relied on for years.

---

## Further reading

For the full background, these are worth a look:

- [The Amiga and the year 2000](https://amiga.de/diary/developers/y2k.html):
  Olaf Barthel's original write-up, and the home of the SetClock 34.3 download.
- [An English translation of the same article](http://obligement.free.fr/articles_traduction/amiga_bogue_an2000_en.php).
- [A friendly overview of the Amiga and Y2K](https://orphanedgames.com/articles/amiga_and_y2k/amiga_and_y2k.html).
