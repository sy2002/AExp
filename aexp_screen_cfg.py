#!/usr/bin/env python3
"""
aexp_screen_cfg.py -- create / edit the AExp screen-centering file.

AExp (the Amiga 500 core for the MEGA65) can re-center its picture on BOTH
outputs WITHOUT re-flashing the core. At start-up, and whenever you pick
"Reload screen cfg" in the on-screen menu, it reads a small table from

    /amiga/aexp_screen.bin

on the SD card. This tool writes that file for you.

------------------------------------------------------------------------
ONE ROW PER AMIGA GRAPHICS MODE
------------------------------------------------------------------------
The Amiga OCS/PAL produces four picture geometries, and each one can want
a slightly different centering. The file holds FOUR rows and the core picks
the matching one automatically (it prints which mode it detected, plus the
HDMI and VGA offsets it applied, on the serial debug terminal):

    lores     Lores,  progressive   (e.g. Workbench lores, most games/demos)
    hires     Hires,  progressive   (e.g. Workbench 640-wide)
    lores-i   Lores,  interlaced
    hires-i   Hires,  interlaced

------------------------------------------------------------------------
EIGHT NUMBERS PER ROW: FOUR FOR HDMI, FOUR FOR VGA
------------------------------------------------------------------------
HDMI and VGA use different scalers and are centered independently.

HDMI (ascal input crop) -- trims one edge of the Amiga source rectangle
inward; the core then scales the selected rectangle to fill the screen.
Values are Amiga source pixels (a line is ~754 px hi-res, ~377 lo-res):

  himin_off  LEFT edge.    0 = full.  +N trims the left   -> picture LEFT
  himax_off  RIGHT edge.   0 = full.  -N trims the right  -> picture RIGHT
  vimin_off  TOP edge.     0 = full.  +N trims the top    -> picture UP
  vimax_off  BOTTOM edge.  0 = full.  -N trims the bottom -> picture DOWN

VGA (analog soft-blank) -- nudges the four edges of the active window that
the scandoubler reproduces. Values are ~quarter-lo-res-pixel steps; the
exact direction depends on your monitor, so tune while watching the screen:

  hbl_l  left active edge     hbl_r  right active edge
  vbl_t  top active edge      vbl_b  bottom active edge

All eight = 0  ->  the full, unchanged picture on both outputs for that
mode. Within one row, one HDMI setting centers every HDMI resolution
(16:9, 4:3, 5:4) at once.

------------------------------------------------------------------------
HOW TO RUN IT
------------------------------------------------------------------------
  Interactive (pick a row, edit it):   python3 aexp_screen_cfg.py
  Set HDMI on the command line:        python3 aexp_screen_cfg.py --mode lores --himin 32
  Set VGA on the command line:         python3 aexp_screen_cfg.py --mode lores --hbl-l 8
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
VERSION      = 3                           # byte 2  (v3 = HDMI + VGA per mode)
COUNT        = 4                           # byte 3  (four mode rows)
HEADER       = MAGIC + bytes([VERSION, COUNT])
HDMI_FIELDS  = ["himin_off", "himax_off", "vimin_off", "vimax_off"]
VGA_FIELDS   = ["hbl_l", "hbl_r", "vbl_t", "vbl_b"]
FIELDS       = HDMI_FIELDS + VGA_FIELDS    # 8 words per row, in file order
ROW_WORDS    = len(FIELDS)                 # 8
FILE_SIZE    = 4 + COUNT * ROW_WORDS * 2   # 4 header + 4 rows x 8 x int16 = 68

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
WARN_HDMI        = 400     # HDMI offsets are Amiga pixels (a whole line is ~754)
WARN_VGA         = 32      # VGA offsets are small analog nudges; large ones can blank VGA
DEFAULT_NAME     = "aexp_screen.bin"


def new_table():
    """A fresh table: four rows of eight zero offsets."""
    return [[0] * ROW_WORDS for _ in MODES]


def pack(table):
    """Return the 68 file bytes for a 4x8 table (validates range)."""
    if len(table) != COUNT:
        raise ValueError(f"table has {len(table)} rows, expected {COUNT}")
    flat = []
    for row in table:
        if len(row) != ROW_WORDS:
            raise ValueError(f"row has {len(row)} values, expected {ROW_WORDS}")
        for name, v in zip(FIELDS, row):
            if not (OFF_MIN <= v <= OFF_MAX):
                raise ValueError(f"{name} = {v} is out of range ({OFF_MIN}..{OFF_MAX})")
            flat.append(v)
    return HEADER + struct.pack(f">{COUNT * ROW_WORDS}h", *flat)


def unpack(data):
    """Validate the header and return the 4x8 table stored in `data`."""
    if len(data) < 4 or data[0:2] != MAGIC:
        raise ValueError('not an AExp screen file (first two bytes are not "AX")')
    version, count = data[2], data[3]
    if version != VERSION:
        raise ValueError(f"unsupported version {version} (this tool writes v{VERSION})")
    if count != COUNT:
        raise ValueError(f"unexpected mode count {count} (expected {COUNT})")
    if len(data) < FILE_SIZE:
        raise ValueError(f"file is {len(data)} bytes, expected {FILE_SIZE}")
    flat = list(struct.unpack(f">{COUNT * ROW_WORDS}h", data[4:FILE_SIZE]))
    return [flat[i * ROW_WORDS:(i + 1) * ROW_WORDS] for i in range(COUNT)]


def hexdump(data):
    return " ".join(f"{b:02X}" for b in data)


def show_table(table, data=None):
    print(f"  {'#':>1}  {'mode':<16}"
          f"  HDMI {'himin':>6} {'himax':>6} {'vimin':>6} {'vimax':>6}"
          f"   VGA {'hbl_l':>6} {'hbl_r':>6} {'vbl_t':>6} {'vbl_b':>6}")
    for i, (key, label) in enumerate(MODES):
        h = table[i]
        print(f"  {i:>1}  {label:<16}"
              f"       {h[0]:>+6} {h[1]:>+6} {h[2]:>+6} {h[3]:>+6}"
              f"       {h[4]:>+6} {h[5]:>+6} {h[6]:>+6} {h[7]:>+6}")
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
        return unpack(data), f"(editing existing {path})"
    except (OSError, ValueError) as e:
        return new_table(), f"(note: {path} is not a valid screen file [{e}]; starting from 0)"


def interactive(table):
    print("\nAExp screen centering -- per Amiga graphics mode, HDMI + VGA.")
    print("HDMI offsets are Amiga source pixels; VGA offsets nudge the analog edges.")
    print("  himin +N -> LEFT   himax -N -> RIGHT   vimin +N -> UP   vimax -N -> DOWN")
    print("  VGA hbl_l/hbl_r/vbl_t/vbl_b: tune on a real monitor (0 = untouched).")
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
        print("    HDMI:")
        for i in range(4):
            table[idx][i] = prompt_int(FIELDS[i], table[idx][i])
        print("    VGA:")
        for i in range(4, ROW_WORDS):
            table[idx][i] = prompt_int(FIELDS[i], table[idx][i])


def main():
    ap = argparse.ArgumentParser(
        description="Create/edit the AExp per-mode screen-centering file "
                    "(/amiga/aexp_screen.bin): HDMI input-crop + VGA soft-blank.",
        epilog="modes: " + ", ".join(MODE_KEYS) + " (or 'all'). "
               "HDMI: himin +N->LEFT, himax -N->RIGHT, vimin +N->UP, vimax -N->DOWN. "
               "VGA: hbl_l/hbl_r/vbl_t/vbl_b nudge the analog edges (tune on a monitor).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    intarg = lambda s: int(s, 0)
    ap.add_argument("--mode", metavar="M", choices=MODE_KEYS + ["all"],
                    help="which row to edit: " + ", ".join(MODE_KEYS) + ", or all")
    # HDMI offsets
    ap.add_argument("--himin", type=intarg, metavar="N", help="HDMI left-edge offset  (+N moves picture left)")
    ap.add_argument("--himax", type=intarg, metavar="N", help="HDMI right-edge offset (-N moves picture right)")
    ap.add_argument("--vimin", type=intarg, metavar="N", help="HDMI top-edge offset   (+N moves picture up)")
    ap.add_argument("--vimax", type=intarg, metavar="N", help="HDMI bottom-edge offset(-N moves picture down)")
    # VGA offsets
    ap.add_argument("--hbl-l", dest="hbl_l", type=intarg, metavar="N", help="VGA left active-edge offset")
    ap.add_argument("--hbl-r", dest="hbl_r", type=intarg, metavar="N", help="VGA right active-edge offset")
    ap.add_argument("--vbl-t", dest="vbl_t", type=intarg, metavar="N", help="VGA top active-edge offset")
    ap.add_argument("--vbl-b", dest="vbl_b", type=intarg, metavar="N", help="VGA bottom active-edge offset")
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

    cli = [args.himin, args.himax, args.vimin, args.vimax,
           args.hbl_l, args.hbl_r, args.vbl_t, args.vbl_b]
    if all(v is None for v in cli) and args.mode is None:
        table = interactive(table)
    else:
        if args.mode is None:
            print("error: --mode is required when setting offsets on the command line "
                  f"(one of: {', '.join(MODE_KEYS)}, all)", file=sys.stderr)
            return 1
        rows = range(COUNT) if args.mode == "all" else [MODE_KEYS.index(args.mode)]
        for r in rows:
            table[r] = [cli[i] if cli[i] is not None else table[r][i] for i in range(ROW_WORDS)]

    # --- validate, warn, write ----------------------------------------------
    try:
        data = pack(table)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    for i, row in enumerate(table):
        for j, (name, v) in enumerate(zip(FIELDS, row)):
            if j < 4:                                 # HDMI offset (Amiga pixels)
                if abs(v) > WARN_HDMI:
                    print(f"warning: row {i} ({MODES[i][1]}) HDMI {name} = {v} is unusually "
                          f"large (a whole Amiga line is ~754 px)")
            elif abs(v) > WARN_VGA:                   # VGA offset (small analog nudge)
                print(f"warning: row {i} ({MODES[i][1]}) VGA {name} = {v} is a large analog "
                      f"nudge; if the VGA picture blanks after reloading, use a smaller value "
                      f"(HDMI is independent, so the menu stays visible to recover).")

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
    print('If the VGA picture ever disappears, set its offsets smaller (or delete the file)')
    print('and reload -- HDMI is separate, so you can still see the menu to recover.')
    return 0


if __name__ == "__main__":
    sys.exit(main())
