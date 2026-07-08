#!/usr/bin/env python3
"""
aexp_screen_cfg.py -- create / edit the AExp HDMI screen-centering file.

AExp (the Amiga 500 core for the MEGA65) can re-center and crop its HDMI
picture WITHOUT re-flashing the core. At start-up, and whenever you pick
"Reload screen cfg" in the on-screen menu, it reads a small table from

    /amiga/aexp_screen.bin

on the SD card. This tool writes that file for you.

------------------------------------------------------------------------
ONE ROW PER AMIGA GRAPHICS MODE
------------------------------------------------------------------------
The Amiga OCS/PAL produces four picture geometries, and each one can want
a slightly different centering. The file therefore holds FOUR rows and the
core picks the matching one automatically (it prints which mode it detected
on the serial debug terminal):

    lores     Lores,  progressive   (e.g. Workbench lores, most games/demos)
    hires     Hires,  progressive   (e.g. Workbench 640-wide)
    lores-i   Lores,  interlaced
    hires-i   Hires,  interlaced

------------------------------------------------------------------------
WHAT THE FOUR NUMBERS PER ROW DO
------------------------------------------------------------------------
Picture the Amiga image as a rectangle of "source" pixels. Each number
trims one edge of that rectangle inward; the core then blows the selected
rectangle up to fill your screen. The numbers are in Amiga source pixels
(a whole line is about 754 px in hi-res, ~377 in lo-res).

  himin_off  LEFT edge.    0 = full.  Increase (+) to trim the left  -> LEFT
  himax_off  RIGHT edge.   0 = full.  Decrease (-) to trim the right -> RIGHT
  vimin_off  TOP edge.     0 = full.  Increase (+) to trim the top   -> UP
  vimax_off  BOTTOM edge.  0 = full.  Decrease (-) to trim the bottom-> DOWN

All four = 0  ->  the full, unchanged picture for that mode. Within one
row, one setting centers every HDMI resolution (16:9, 4:3, 5:4) at once.

------------------------------------------------------------------------
HOW TO RUN IT
------------------------------------------------------------------------
  Interactive (pick a row, edit it):   python3 aexp_screen_cfg.py
  Set one row on the command line:     python3 aexp_screen_cfg.py --mode lores --himin 32
  Set the same value in every row:     python3 aexp_screen_cfg.py --mode all --himin 32
  Show the current table:              python3 aexp_screen_cfg.py --list

If you do not pass a file name, the default aexp_screen.bin is assumed.
Then copy aexp_screen.bin into the /amiga folder of your SD card and pick
"Reload screen cfg" in the core menu (or reboot). Needs only Python 3.
"""

import argparse
import os
import struct
import sys

# ---- file format (must match the AExp firmware, LOAD_SCREEN_OFFSETS) --------
MAGIC        = b"AX"                       # bytes 0..1
VERSION      = 2                           # byte 2  (v2 = per-mode table)
COUNT        = 4                           # byte 3  (four mode rows)
HEADER       = MAGIC + bytes([VERSION, COUNT])
FIELDS       = ["himin_off", "himax_off", "vimin_off", "vimax_off"]
FILE_SIZE    = 4 + COUNT * len(FIELDS) * 2 # 4 header + 4 rows x 4 x int16 = 36

# fixed row order -- MUST match DETECT_SCREEN_MODE in m2m-rom.asm
# (index = hires_bit + (interlaced ? 2 : 0)):
MODES = [
    ("lores",   "Lores"),             # row 0: lores, progressive
    ("hires",   "Hires"),             # row 1: hires, progressive
    ("lores-i", "Lores interlaced"),  # row 2: lores, interlaced
    ("hires-i", "Hires interlaced"),  # row 3: hires, interlaced
]
MODE_KEYS = [k for k, _ in MODES]

# The core keeps only the low 12 bits of each value, read as a signed number,
# so the meaningful range is -2048..2047. Anything wider than a video line is
# almost certainly a mistake.
OFF_MIN, OFF_MAX = -2048, 2047
WARN_ABS         = 400
DEFAULT_NAME     = "aexp_screen.bin"


def new_table():
    """A fresh table: four rows of four zero offsets."""
    return [[0, 0, 0, 0] for _ in MODES]


def pack(table):
    """Return the 36 file bytes for a 4x4 table (validates range)."""
    if len(table) != COUNT:
        raise ValueError(f"table has {len(table)} rows, expected {COUNT}")
    flat = []
    for row in table:
        for name, v in zip(FIELDS, row):
            if not (OFF_MIN <= v <= OFF_MAX):
                raise ValueError(f"{name} = {v} is out of range ({OFF_MIN}..{OFF_MAX})")
            flat.append(v)
    return HEADER + struct.pack(f">{COUNT * len(FIELDS)}h", *flat)


def unpack(data):
    """Validate the header and return the 4x4 table stored in `data`.

    A v1 file (one global row) is migrated: its single offset set is copied
    into every mode row, so earlier tuning is not lost.
    """
    if len(data) < 4 or data[0:2] != MAGIC:
        raise ValueError('not an AExp screen file (first two bytes are not "AX")')
    version, count = data[2], data[3]

    if version == 1 and count == 1:            # migrate a v1 single-row file
        if len(data) < 12:
            raise ValueError(f"v1 file is {len(data)} bytes, expected 12")
        one = list(struct.unpack(">4h", data[4:12]))
        return [list(one) for _ in MODES]

    if version != VERSION:
        raise ValueError(f"unsupported version {version} (this tool writes v{VERSION})")
    if count != COUNT:
        raise ValueError(f"unexpected mode count {count} (expected {COUNT})")
    if len(data) < FILE_SIZE:
        raise ValueError(f"file is {len(data)} bytes, expected {FILE_SIZE}")
    flat = list(struct.unpack(f">{COUNT * len(FIELDS)}h", data[4:FILE_SIZE]))
    return [flat[i * 4:i * 4 + 4] for i in range(COUNT)]


def hexdump(data):
    return " ".join(f"{b:02X}" for b in data)


def show_table(table, data=None):
    print(f"  {'#':>1}  {'mode':<16}  {'himin':>6} {'himax':>6} {'vimin':>6} {'vimax':>6}")
    for i, (key, label) in enumerate(MODES):
        h, hx, v, vx = table[i]
        print(f"  {i:>1}  {label:<16}  {h:>+6} {hx:>+6} {v:>+6} {vx:>+6}")
    if data is not None:
        print(f"\n  bytes: {hexdump(data)}")


def prompt_int(name, current):
    while True:
        raw = input(f"      {name} [{current:+d}]: ").strip()
        if raw == "":
            return current
        try:
            v = int(raw, 0)            # accepts 48, -48, 0x30, ...
        except ValueError:
            print("        please enter a whole number (blank = keep current)")
            continue
        if not (OFF_MIN <= v <= OFF_MAX):
            print(f"        out of range ({OFF_MIN}..{OFF_MAX})")
            continue
        return v


def load_table(path):
    """Return (table, note). Falls back to a zero table for a missing/bad file."""
    if not os.path.exists(path):
        return new_table(), None
    try:
        with open(path, "rb") as f:
            data = f.read()
        table = unpack(data)
        note = f"(editing existing {path})"
        if data[2] == 1:
            note = f"(imported v1 {path}: its offsets were copied into all four modes)"
        return table, note
    except (OSError, ValueError) as e:
        return new_table(), f"(note: {path} is not a valid screen file [{e}]; starting from 0)"


def interactive(table):
    print("\nAExp HDMI screen centering -- per Amiga graphics mode.")
    print("Offsets are Amiga source pixels; 0 leaves that edge untouched.")
    print("  himin +N -> LEFT   himax -N -> RIGHT   vimin +N -> UP   vimax -N -> DOWN")
    while True:
        print()
        show_table(table)
        raw = input("\n  edit which row 0-3 (Enter = save & exit): ").strip()
        if raw == "":
            return table
        try:
            idx = int(raw, 0)
            if not (0 <= idx < COUNT):
                raise ValueError
        except ValueError:
            print("  please enter a row number 0..3 (or Enter to finish)")
            continue
        print(f"\n  editing row {idx}: {MODES[idx][1]} (blank keeps the shown value)")
        table[idx] = [prompt_int(FIELDS[i], table[idx][i]) for i in range(4)]


def main():
    ap = argparse.ArgumentParser(
        description="Create/edit the AExp per-mode HDMI screen-centering file "
                    "(/amiga/aexp_screen.bin).",
        epilog="modes: " + ", ".join(MODE_KEYS) + " (or 'all'). "
               "himin +N->LEFT, himax -N->RIGHT, vimin +N->UP, vimax -N->DOWN.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    intarg = lambda s: int(s, 0)
    ap.add_argument("--mode", metavar="M", choices=MODE_KEYS + ["all"],
                    help="which row to edit: " + ", ".join(MODE_KEYS) + ", or all")
    ap.add_argument("--himin", type=intarg, metavar="N", help="left-edge offset  (+N moves picture left)")
    ap.add_argument("--himax", type=intarg, metavar="N", help="right-edge offset (-N moves picture right)")
    ap.add_argument("--vimin", type=intarg, metavar="N", help="top-edge offset   (+N moves picture up)")
    ap.add_argument("--vimax", type=intarg, metavar="N", help="bottom-edge offset(-N moves picture down)")
    ap.add_argument("-o", "--output", default=DEFAULT_NAME, metavar="FILE",
                    help=f"file to write (default: {DEFAULT_NAME})")
    ap.add_argument("--list", "--read", dest="listfile", nargs="?", const=DEFAULT_NAME,
                    metavar="FILE", help=f"show the table in FILE (default: {DEFAULT_NAME}) and exit")
    args = ap.parse_args()

    # --- list/read an existing file -----------------------------------------
    if args.listfile is not None:
        try:
            with open(args.listfile, "rb") as f:
                data = f.read()
            table = unpack(data)
        except (OSError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        print(f"{args.listfile}:")
        show_table(table, data)
        return 0

    # --- start from the existing output file (if any), else all zeros -------
    table, note = load_table(args.output)
    if note:
        print(note)

    cli = [args.himin, args.himax, args.vimin, args.vimax]
    if all(v is None for v in cli) and args.mode is None:
        table = interactive(table)
    else:
        if args.mode is None:
            print("error: --mode is required when setting offsets on the command line "
                  f"(one of: {', '.join(MODE_KEYS)}, all)", file=sys.stderr)
            return 1
        rows = range(COUNT) if args.mode == "all" else [MODE_KEYS.index(args.mode)]
        for r in rows:
            table[r] = [cli[i] if cli[i] is not None else table[r][i] for i in range(4)]

    # --- validate, warn, write ----------------------------------------------
    try:
        data = pack(table)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    for i, row in enumerate(table):
        for name, v in zip(FIELDS, row):
            if abs(v) > WARN_ABS:
                print(f"warning: row {i} ({MODES[i][1]}) {name} = {v} is unusually "
                      f"large (a whole Amiga line is ~754 px)")

    try:
        with open(args.output, "wb") as f:
            f.write(data)
    except OSError as e:
        print(f"error: could not write {args.output}: {e}", file=sys.stderr)
        return 1

    print(f"\nwrote {args.output} ({len(data)} bytes):")
    show_table(table, data)
    print(f'\nNext: copy {os.path.basename(args.output)} to the /amiga folder on your SD card,')
    print('then choose "Reload screen cfg" in the core menu (or reboot the core).')
    return 0


if __name__ == "__main__":
    sys.exit(main())
