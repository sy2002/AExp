# FAQ

Common questions and problems, each with a short answer and a link to the
page with the details.

## Startup and settings

### The core stops with an error message at startup

The core loads the Kickstart ROM from `/amiga/kick.rom` on the SD card and
cannot start without it. The error appears when no SD card can be mounted or
the file is missing or unreadable. Put a raw 256 KB (262,144 bytes) dump of
Kickstart 1.3 there, without byte swapping, on a FAT32 card of at most 32 GB.
See [Kickstart ROM](../README.md#kickstart-rom) and
[Installation](../README.md#installation).

### My menu settings are forgotten after switching off

The core saves the menu settings only into the file `aexp-<version>.cfg` in
`/amiga`, and only if that file already exists. Copy the one that comes with
the core onto the SD card. The file name contains the core version, so after
an upgrade you need the new file and have to choose your settings once more.
See step 3 of the [Installation](../README.md#installation).

## Video

### My HDMI display stays black or says "no signal" or "unsupported format"

Some displays reject the extra data an HDMI signal carries. Switch on
**DVI (no sound)** in the first `HDMI:` menu; the sound then comes only from
the 3.5 mm jack. Since you cannot see the menu, use the blind key sequence in
[DVI (no sound): when the screen stays black](../README.md#dvi-no-sound-when-the-screen-stays-black).

### The picture on my analog monitor is unstable

Switch off **HDMI: Flicker-free** whenever you use the VGA port. It makes the
sync frequency step slightly, which analog monitors dislike. See
[Flicker-free](../README.md#flicker-free-smooth-motion-menu-entry).

### My VGA monitor shows nothing at all

A regular VGA monitor cannot show the two 15 kHz modes, not even the menu.
Connect an HDMI display, which always runs in parallel, and set `VGA:` back to
**Standard**. Standard is still a 50 Hz signal, which not every flat panel
accepts. See [Video: VGA port](../README.md#video-vga-port-analog-rgb).

### The menu is too big on my 15 kHz screen

Open the **`OSM: 100%`** entry and choose a smaller size, down to 50%. It
changes only the menu, on every output. See
[Video: VGA port](../README.md#video-vga-port-analog-rgb).

### The picture is off-center or an edge is cut off

Copy one of the two ready-made files, `aexp_screen.cfg_16_9` or
`aexp_screen.cfg_4_3`, into `/amiga`, rename it to `aexp_screen.cfg`, and
choose **Reload Screen Config** in the menu. Try both and keep the one that
looks best; the presets adjust HDMI only. See
[Getting the Picture Right](screen_adjust.md).

### There is a lot of lag on my HDMI monitor

AExp's HDMI output is practically lag-free: with **HDMI: Flicker-free** on it
adds less than 1 ms, and most HDMI displays show no noticeable lag. Some
displays with a native 60 Hz panel, such as the Checkmate, have to convert
the Amiga's 50 Hz and add 70 to 100 ms themselves. See
[Latency on the Checkmate Retro Monitor](../README.md#latency-on-the-checkmate-retro-monitor)
and [HDMI latency](developers/hdmi_latency.md).

## Games and demos

### A game or demo does not work

Try these, one at a time:

* **One drive only.** Some titles fail when the Amiga has more than one drive
  (Riverraid Reloaded is a known case). One drive is the default; check
  **Drive Settings**. See [Floppy drives](drives.md).
* **Slow RAM (A501) off.** A few early games, such as Rogue, need an Amiga
  without expansion RAM. See [Slow RAM (A501)](../README.md#slow-ram-a501).
* **Amiga keyboard mode.** Some games, such as Pinball Dreams, need the
  original key positions. See [Keyboard Mappings](keyboard.md).

Software that needs a Kickstart newer than 1.3, ECS, AGA, Fast RAM or NTSC
cannot run on this core. See
[Constraints and roadmap](../README.md#constraints-and-roadmap).

### A game asks for the next disk

Open the menu, move the cursor to the drive line and press **Return**: the
file browser opens, and the file you pick replaces the current disk. See
[Mounting and ejecting a disk image](drives.md#mounting-and-ejecting-a-disk-image).

## Disk images

### A disk image is refused

The core accepts only `.adf` files of 901,120 bytes (a standard 880 KB disk)
and over-dumps of up to 934,912 bytes. See
[Which files are accepted](drives.md#which-files-are-accepted).

### The second mount of the same ADF is refused

One `.adf` file can be in only one drive at a time, because each drive keeps
its own copy and the later save would overwrite the earlier one. Use two
files. See [One file, one drive](drives.md#one-file-one-drive).

### My saved changes are missing from the ADF

Changes reach the SD card in the background while the drive LED is yellow.
Before you eject, reset or switch off, wait until the LED has stayed off for
a few seconds. See [Wait for the LED](drives.md#wait-for-the-led).

## Real disks (Hardware Floppy)

### A real Amiga disk does not read

Check that a drive is set to **Hardware Floppy** in **Drive Settings**; out
of the box none is. The drive reads only double-density (DD) disks; HD disks
cannot work in this mechanism. While the menu is open, the drive line shows
`Motor` if the disk turns but nothing readable comes back, and `Reading` if
data flows. Try another disk, and if a disk reads on a real Amiga but not on
AExp, please report it. See [Hardware Floppy](hardware_floppy.md).

### The drive knocks and reads nothing right after power-on

The drive's own controller occasionally starts up in a bad state, and only a
power cycle resets it. Switch the MEGA65 off and on again. See
[If the drive knocks](hardware_floppy.md#if-the-drive-knocks-and-reads-nothing-after-switching-on).

## Mouse and keyboard

### The right mouse button does not work

The MEGA65 cannot read the right button of an original passive Tank Mouse.
Hold <kbd>Run/Stop</kbd> instead (in Amiga keyboard mode the
<kbd>&uarr;</kbd> symbol key left of <kbd>RESTORE</kbd>), or use an
actively-driving mouse or adapter, a mouSTer with `activepotlines=true`, or
the simple DIY pull-up adapter. C64 mice (1350, 1351) do not work. See
[Mouse and joystick](../README.md#mouse-and-joystick).

### I need the Help key inside the Amiga

Move the menu to <kbd>F11</kbd>, <kbd>F13</kbd> or
<kbd>MEGA</kbd>+<kbd>Run/Stop</kbd> in the **Keyboard** section of the menu;
<kbd>Help</kbd> then belongs to the Amiga alone. See
[Opening the menu and freeing the Help key](keyboard.md#opening-the-menu-and-freeing-the-help-key).

## Clock

### The year shows 1978

The `SetClock` on Workbench 1.2 and 1.3 disks predates the year 2000.
Replace it with SetClock 34.3. See
[the year says 1978](RTC.md#surprise-the-year-says-1978).

### The time is an hour off

Kickstart 1.3 knows no time zones or daylight saving time and shows the
MEGA65's clock as it is set. Set the MEGA65's clock to your local time. See
[the time is an hour off](RTC.md#surprise-the-time-is-an-hour-off).
