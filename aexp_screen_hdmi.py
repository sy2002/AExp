#!/usr/bin/env python3
"""
aexp_screen_hdmi.py -- create / edit the AExp HDMI screen-centering file.

AExp (the Amiga 500 core for the MEGA65) can re-center and crop its HDMI
picture WITHOUT re-flashing the core. At start-up, and whenever you pick
"Reload screen cfg" in the on-screen menu, it reads four numbers from

    /amiga/screen_hdmi.bin

on the SD card. This little tool writes that 12-byte file for you.

------------------------------------------------------------------------
WHAT THE FOUR NUMBERS DO
------------------------------------------------------------------------
Picture the Amiga image as a rectangle of "source" pixels. Each number
trims one edge of that rectangle inward; the core then blows the selected
rectangle up to fill your screen. The numbers are in Amiga source pixels
(a whole line is about 754 px in hi-res, ~377 in lo-res).

  himin_off  LEFT edge.    0 = full.  Increase (+) to trim the left
                           border  ->  the picture moves LEFT.
  himax_off  RIGHT edge.   0 = full.  Decrease (-) to trim the right
                           border  ->  the picture moves RIGHT.
  vimin_off  TOP edge.     0 = full.  Increase (+) to trim the top
                           ->  the picture moves UP.
  vimax_off  BOTTOM edge.  0 = full.  Decrease (-) to trim the bottom
                           ->  the picture moves DOWN.

All four = 0  ->  the full, unchanged picture. ONE setting works for
every HDMI resolution (16:9, 4:3, 5:4) at the same time.

------------------------------------------------------------------------
THE USUAL FIX
------------------------------------------------------------------------
Picture too far to the RIGHT and clipped on the right edge?
  ->  increase himin_off  (try 32, then 48, 64 ...) until it is centered.

------------------------------------------------------------------------
HOW TO APPLY IT
------------------------------------------------------------------------
1. Run this tool to make screen_hdmi.bin.
2. Copy the file into the  /amiga  folder of your MEGA65 SD card.
3. In the core, open the on-screen menu and choose "Reload screen cfg"
   (or simply reboot the core). Adjust and repeat until it looks right.

------------------------------------------------------------------------
HOW TO RUN IT
------------------------------------------------------------------------
  Interactive (just run it):   python3 aexp_screen_hdmi.py
  Set on the command line:     python3 aexp_screen_hdmi.py --himin 48
  Look at an existing file:    python3 aexp_screen_hdmi.py --read screen_hdmi.bin

Needs only Python 3 (no extra packages).
"""

import argparse
import os
import struct
import sys

# ---- file format (must match the AExp firmware, LOAD_SCREEN_OFFSETS) --------
MAGIC       = b"AX"                       # bytes 0..1
VERSION     = 1                           # byte 2
COUNT       = 1                           # byte 3  (one entry in milestone 1)
HEADER      = MAGIC + bytes([VERSION, COUNT])
FILE_SIZE   = 12                          # 4 header + 4 x signed 16-bit (big-endian)
FIELDS      = ["himin_off", "himax_off", "vimin_off", "vimax_off"]

# The core keeps only the low 12 bits of each value, read as a signed number,
# so the meaningful range is -2048..2047. Anything wider than a video line is
# almost certainly a mistake.
OFF_MIN, OFF_MAX = -2048, 2047
WARN_ABS         = 400
DEFAULT_NAME     = "screen_hdmi.bin"


def pack(values):
    """Return the 12 file bytes for four integer offsets (validates range)."""
    for name, v in zip(FIELDS, values):
        if not (OFF_MIN <= v <= OFF_MAX):
            raise ValueError(f"{name} = {v} is out of range ({OFF_MIN}..{OFF_MAX})")
    return HEADER + struct.pack(">4h", *values)   # ">4h" = 4 big-endian signed 16-bit


def unpack(data):
    """Validate the header and return the four offsets stored in `data`."""
    if len(data) < FILE_SIZE:
        raise ValueError(f"file is {len(data)} bytes, expected {FILE_SIZE}")
    if data[0:2] != MAGIC:
        raise ValueError('not an AExp screen file (first two bytes are not "AX")')
    if data[2] != VERSION:
        raise ValueError(f"unsupported version {data[2]} (this tool writes v{VERSION})")
    if data[3] != COUNT:
        raise ValueError(f"unexpected entry count {data[3]} (expected {COUNT})")
    return list(struct.unpack(">4h", data[4:12]))


def hexdump(data):
    return " ".join(f"{b:02X}" for b in data)


def show(values, data=None):
    for name, v in zip(FIELDS, values):
        print(f"  {name:10s} = {v:+5d}")
    if data is not None:
        print(f"  bytes      : {hexdump(data)}")


def prompt_int(name, current):
    while True:
        raw = input(f"    {name} [{current:+d}]: ").strip()
        if raw == "":
            return current
        try:
            v = int(raw, 0)            # accepts 48, -48, 0x30, ...
        except ValueError:
            print("      please enter a whole number (blank = keep current)")
            continue
        if not (OFF_MIN <= v <= OFF_MAX):
            print(f"      out of range ({OFF_MIN}..{OFF_MAX})")
            continue
        return v


EPILOG = """\
offsets (Amiga source pixels, 0 = that edge untouched):
  himin_off  LEFT   : +N trims left   -> picture moves LEFT   (fixes "too far right")
  himax_off  RIGHT  : -N trims right  -> picture moves RIGHT
  vimin_off  TOP    : +N trims top    -> picture moves UP
  vimax_off  BOTTOM : -N trims bottom -> picture moves DOWN
Then copy the file to /amiga on the SD card and pick "Reload screen cfg" in the menu.
"""


def main():
    ap = argparse.ArgumentParser(
        description="Create/edit the AExp HDMI screen-centering file (/amiga/screen_hdmi.bin).",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    intarg = lambda s: int(s, 0)
    ap.add_argument("--himin", type=intarg, metavar="N", help="left-edge offset  (+N moves picture left)")
    ap.add_argument("--himax", type=intarg, metavar="N", help="right-edge offset (-N moves picture right)")
    ap.add_argument("--vimin", type=intarg, metavar="N", help="top-edge offset   (+N moves picture up)")
    ap.add_argument("--vimax", type=intarg, metavar="N", help="bottom-edge offset(-N moves picture down)")
    ap.add_argument("-o", "--output", default=DEFAULT_NAME, metavar="FILE",
                    help=f"file to write (default: {DEFAULT_NAME})")
    ap.add_argument("--read", metavar="FILE", help="show the offsets in FILE and exit")
    args = ap.parse_args()

    # --- read/show an existing file -----------------------------------------
    if args.read:
        try:
            with open(args.read, "rb") as f:
                data = f.read()
            values = unpack(data)
        except (OSError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        print(f"{args.read}:")
        show(values, data)
        return 0

    # --- start from the existing output file (if any), else all zeros -------
    current = [0, 0, 0, 0]
    if os.path.exists(args.output):
        try:
            with open(args.output, "rb") as f:
                current = unpack(f.read())
            print(f"(editing existing {args.output})")
        except (OSError, ValueError):
            print(f"(note: {args.output} exists but is not readable as a screen file; starting from 0)")

    cli = [args.himin, args.himax, args.vimin, args.vimax]
    if all(v is None for v in cli):
        # interactive
        print("\nAExp HDMI screen centering -- enter offsets in Amiga source pixels.")
        print("Blank keeps the shown value; 0 leaves that edge untouched.\n")
        print("  himin_off  LEFT   : +N trims left   -> picture LEFT   (fixes 'too far right')")
        print("  himax_off  RIGHT  : -N trims right  -> picture RIGHT")
        print("  vimin_off  TOP    : +N trims top    -> picture UP")
        print("  vimax_off  BOTTOM : -N trims bottom -> picture DOWN\n")
        values = [prompt_int(FIELDS[i], current[i]) for i in range(4)]
    else:
        values = [cli[i] if cli[i] is not None else current[i] for i in range(4)]

    # --- validate, warn, write ----------------------------------------------
    try:
        data = pack(values)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    for name, v in zip(FIELDS, values):
        if abs(v) > WARN_ABS:
            print(f"warning: {name} = {v} is unusually large (a whole Amiga line is ~754 px)")

    try:
        with open(args.output, "wb") as f:
            f.write(data)
    except OSError as e:
        print(f"error: could not write {args.output}: {e}", file=sys.stderr)
        return 1

    print(f"\nwrote {args.output} ({len(data)} bytes):")
    show(values, data)
    print(f'\nNext: copy {os.path.basename(args.output)} to the /amiga folder on your SD card,')
    print('then choose "Reload screen cfg" in the core menu (or reboot the core).')
    return 0


if __name__ == "__main__":
    sys.exit(main())
