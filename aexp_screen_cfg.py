#!/usr/bin/env python3
"""
aexp_screen_cfg.py -- create / edit the AExp screen-adjustment file.

AExp (the Amiga 500 core for the MEGA65) can adjust its picture on BOTH
outputs WITHOUT re-flashing the core. At start-up, and whenever you pick
"Reload screen cfg" in the on-screen menu, it reads a small table from

    /amiga/aexp_screen.cfg

on the SD card. This tool writes that file for you.

------------------------------------------------------------------------
ONE ROW PER AMIGA GRAPHICS MODE
------------------------------------------------------------------------
The Amiga OCS/PAL produces four picture geometries, and each one can want
slightly different values. The file holds FOUR rows and the core picks
the matching one automatically (it prints which mode it detected, plus
the values it applied, on the serial debug terminal):

    lores     Lores,  progressive   (e.g. Workbench lores, most games/demos)
    hires     Hires,  progressive   (e.g. Workbench 640-wide)
    lores-i   Lores,  interlaced
    hires-i   Hires,  interlaced

------------------------------------------------------------------------
TEN NUMBERS PER ROW, IN THREE GROUPS
------------------------------------------------------------------------
HDMI and the analog output are adjusted independently, and the analog
output has two separate controls: POSITION and OVERSCAN.

HDMI crop (digital scaler input crop) -- trims one edge of the Amiga
source rectangle inward; the core then scales the selected rectangle to
fill the screen (re-frame + slight zoom, not a pure slide). Values are
Amiga source pixels (a line is ~754 px hi-res, ~377 lo-res):

  himin  LEFT edge.    0 = full.  +N trims the left   -> picture LEFT
  himax  RIGHT edge.   0 = full.  -N trims the right  -> picture RIGHT
  vimin  TOP edge.     0 = full.  +N trims the top    -> picture UP
  vimax  BOTTOM edge.  0 = full.  -N trims the bottom -> picture DOWN

Analog position (pan) -- moves the COMPLETE analog picture, menu
included, by shifting the sync timing. Works in Standard, 15 kHz HS/VS
and 15 kHz CSYNC mode. Positive = right / down:

  pan_x  1 unit = one hires pixel (~1/908 of a line).  +N -> RIGHT
  pan_y  1 unit = one Amiga line.                      +N -> DOWN

  A CRT or sync-locked monitor follows the pan exactly. An analog-input
  LCD that auto-positions may partly or fully cancel it (that is the
  display re-centering itself, not a core fault).

Analog overscan (visible area) -- hides or reveals border material at
each edge. It cannot move the picture (use pan for that) and it does not
resize pixels. Horizontal steps are quarter lo-res pixels, vertical
steps are lines:

  os_l   left edge:    +N hides border on the left,  -N reveals more
  os_r   right edge:   -N hides border on the right, +N reveals more
  os_t   top edge:     +N hides border at the top,   -N reveals more
  os_b   bottom edge:  -N hides border at the bottom, 0 = untouched
         (+N is a legacy absolute mode -- avoid)

All ten = 0  ->  the full, unchanged picture on both outputs for that
mode. Within one row, one HDMI setting covers every HDMI resolution
(16:9, 4:3, 5:4) at once.

Tip: the core clamps pan so the sync pulse always stays inside the black
border region. If the picture stops moving before it is where you want
it, first hide some border on that side with overscan -- that widens the
safe region and unlocks more pan range.

------------------------------------------------------------------------
HOW TO RUN IT
------------------------------------------------------------------------
  Interactive (pick a row, edit by group): python3 aexp_screen_cfg.py
  Move the analog picture right:  python3 aexp_screen_cfg.py --mode lores --pan-x 8
  Set HDMI on the command line:   python3 aexp_screen_cfg.py --mode lores --himin 32
  Same value in every row:        python3 aexp_screen_cfg.py --mode all --pan-x 8
  Zero one group:                 python3 aexp_screen_cfg.py --mode all --reset pan
  Copy a tuned row:               python3 aexp_screen_cfg.py --mode lores-i --copy-from lores
  Show the current table:         python3 aexp_screen_cfg.py --list

If you do not pass a file name, the default aexp_screen.cfg is assumed.
Then copy aexp_screen.cfg into the /amiga folder of your SD card and pick
"Reload screen cfg" in the core menu (or reboot). Needs only Python 3.

The tool reads both the current v4 format and the older v3 format (no
pan fields); saving always writes v4. v4 needs core release WIP-V1-A9 or
newer -- older cores ignore a v4 file completely (no adjustments).
"""

import argparse
import os
import struct
import sys

# ---- file format (must match the AExp firmware, LOAD_SCREEN_OFFSETS) --------
MAGIC        = b"AX"                       # bytes 0..1
VERSION      = 4                           # byte 2  (v4 = HDMI + overscan + pan)
VERSION_V3   = 3                           # legacy  (v3 = HDMI + overscan only)
COUNT        = 4                           # byte 3  (four mode rows)
HEADER       = MAGIC + bytes([VERSION, COUNT])
HDMI_FIELDS  = ["himin", "himax", "vimin", "vimax"]
OS_FIELDS    = ["os_l", "os_r", "os_t", "os_b"]
PAN_FIELDS   = ["pan_x", "pan_y"]
FIELDS       = HDMI_FIELDS + OS_FIELDS + PAN_FIELDS   # 10 words per row, file order
ROW_WORDS    = len(FIELDS)                 # 10
ROW_WORDS_V3 = 8                           # v3: HDMI + overscan only
FILE_SIZE    = 4 + COUNT * ROW_WORDS * 2   # 4 header + 4 rows x 10 x int16 = 84
FILE_SIZE_V3 = 4 + COUNT * ROW_WORDS_V3 * 2                                # 68

# display groups: (title, field names) -- position before overscan on purpose
GROUPS = [
    ("HDMI crop",       HDMI_FIELDS),
    ("Analog position", PAN_FIELDS),
    ("Analog overscan", OS_FIELDS),
]

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
# so the meaningful range is -2048..2047.
OFF_MIN, OFF_MAX = -2048, 2047
WARN_HDMI    = 400   # HDMI offsets are Amiga pixels (a whole line is ~754)
WARN_OS      = 48    # overscan trims are small border adjustments
WARN_PAN_X   = 96    # the core clamps pan_x to <= 1/8 line and the black porch
WARN_PAN_Y   = 48    # the core clamps pan_y to +/-64 lines
DEFAULT_NAME = "aexp_screen.cfg"

# human explanation of what a value does, for the direction echo:
# field -> (unit text, meaning for positive, meaning for negative)
DIRECTIONS = {
    "himin": ("px", "HDMI: trims the LEFT edge (picture shifts left)",
                    "ignored (cannot reveal beyond the source)"),
    "himax": ("px", "ignored (cannot reveal beyond the source)",
                    "HDMI: trims the RIGHT edge (picture shifts right)"),
    "vimin": ("px", "HDMI: trims the TOP edge (picture shifts up)",
                    "ignored (cannot reveal beyond the source)"),
    "vimax": ("px", "ignored (cannot reveal beyond the source)",
                    "HDMI: trims the BOTTOM edge (picture shifts down)"),
    "pan_x": ("hires px", "analog picture moves RIGHT",
                          "analog picture moves LEFT"),
    "pan_y": ("lines",    "analog picture moves DOWN",
                          "analog picture moves UP"),
    "os_l":  ("steps", "analog: hides border on the LEFT",
                       "analog: reveals more on the LEFT"),
    "os_r":  ("steps", "analog: reveals more on the RIGHT",
                       "analog: hides border on the RIGHT"),
    "os_t":  ("lines", "analog: hides border at the TOP",
                       "analog: reveals more at the TOP"),
    "os_b":  ("lines", "analog: legacy absolute bottom line (avoid)",
                       "analog: hides border at the BOTTOM"),
}


def new_table():
    """A fresh table: four rows of ten zero values."""
    return [[0] * ROW_WORDS for _ in MODES]


def pack(table):
    """Return the 84 file bytes for a 4x10 table (validates range)."""
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
    """Validate the header and return (table, version) stored in `data`.

    Reads the current v4 format and the legacy v3 format; a v3 row gets
    pan_x = pan_y = 0 appended, so the returned table is always 4x10.
    """
    if len(data) < 4 or data[0:2] != MAGIC:
        raise ValueError('not an AExp screen file (first two bytes are not "AX")')
    version, count = data[2], data[3]
    if version not in (VERSION_V3, VERSION):
        raise ValueError(f"unsupported version {version} (this tool reads v3/v4, writes v{VERSION})")
    if count != COUNT:
        raise ValueError(f"unexpected mode count {count} (expected {COUNT})")
    words = ROW_WORDS if version == VERSION else ROW_WORDS_V3
    size  = 4 + COUNT * words * 2
    if len(data) < size:
        raise ValueError(f"file is {len(data)} bytes, expected {size} for v{version}")
    flat = list(struct.unpack(f">{COUNT * words}h", data[4:size]))
    table = [flat[i * words:(i + 1) * words] for i in range(COUNT)]
    if version == VERSION_V3:
        table = [row + [0, 0] for row in table]
    return table, version


def hexdump(data):
    return " ".join(f"{b:02X}" for b in data)


def show_table(table, data=None):
    print(f"  {'#':>1}  {'mode':<16}"
          f"  HDMI {'himin':>6} {'himax':>6} {'vimin':>6} {'vimax':>6}"
          f"  | pos {'pan_x':>6} {'pan_y':>6}"
          f"  | overscan {'os_l':>5} {'os_r':>5} {'os_t':>5} {'os_b':>5}")
    for i, (key, label) in enumerate(MODES):
        h = table[i]
        print(f"  {i:>1}  {label:<16}"
              f"       {h[0]:>+6} {h[1]:>+6} {h[2]:>+6} {h[3]:>+6}"
              f"        {h[8]:>+6} {h[9]:>+6}"
              f"             {h[4]:>+5} {h[5]:>+5} {h[6]:>+5} {h[7]:>+5}")
    if data is not None:
        print(f"\n  bytes: {hexdump(data)}")


def echo_direction(name, v):
    """One line of plain language about what the new value does."""
    unit, pos, neg = DIRECTIONS[name]
    if v == 0:
        print(f"      {name} = 0: untouched")
    elif v > 0:
        print(f"      {name} = +{v} {unit}: {pos}")
    else:
        print(f"      {name} = {v} {unit}: {neg}")


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
        if v != current:
            echo_direction(name, v)
        return v


def load_table(path):
    """Return (table, note). Falls back to a zero table for a missing/bad file."""
    if not os.path.exists(path):
        return new_table(), None
    try:
        with open(path, "rb") as f:
            data = f.read()
        table, version = unpack(data)
        if version == VERSION_V3:
            return table, (f"(migrating v3 file {path}: HDMI and overscan values kept, "
                           f"analog position starts at 0; saving writes v4, which needs "
                           f"core WIP-V1-A9 or newer -- older cores ignore v4 files)")
        return table, f"(editing existing {path})"
    except (OSError, ValueError) as e:
        return new_table(), f"(note: {path} is not a valid screen file [{e}]; starting from 0)"


def interactive(table):
    print("\nAExp screen adjustment -- per Amiga graphics mode.")
    print("Three groups per row: HDMI crop | analog position | analog overscan.")
    print("  HDMI:     himin +N -> LEFT   himax -N -> RIGHT   vimin +N -> UP   vimax -N -> DOWN")
    print("  Position: pan_x + -> RIGHT / - -> LEFT     pan_y + -> DOWN / - -> UP")
    print("  Overscan: os_l + / os_r - / os_t + / os_b -  hide border at that edge")
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
        print(f"\n  editing row {idx}: {MODES[idx][1]}")
        for title, names in GROUPS:
            raw = input(f"    {title} -- edit? (Enter = skip, y = edit): ").strip().lower()
            if raw not in ("y", "yes"):
                continue
            print("      (blank keeps the shown value)")
            for name in names:
                fi = FIELDS.index(name)
                table[idx][fi] = prompt_int(name, table[idx][fi])


def warn_row(i, row):
    """Print soft warnings for suspicious values in one row."""
    label = MODES[i][1]
    for j, (name, v) in enumerate(zip(FIELDS, row)):
        if name in HDMI_FIELDS:
            if abs(v) > WARN_HDMI:
                print(f"warning: row {i} ({label}) HDMI {name} = {v} is unusually "
                      f"large (a whole Amiga line is ~754 px)")
        elif name in OS_FIELDS:
            if abs(v) > WARN_OS:
                print(f"warning: row {i} ({label}) overscan {name} = {v} is a large trim; "
                      f"if the analog picture blanks after reloading, use a smaller value "
                      f"(HDMI is independent, so the menu stays visible to recover).")
        elif name == "pan_x":
            if abs(v) > WARN_PAN_X:
                print(f"warning: row {i} ({label}) pan_x = {v}: the core limits pan to "
                      f"about 1/8 of a line and keeps sync inside the black border, so "
                      f"the picture may move less than requested. Hiding border with "
                      f"overscan on that side unlocks more pan range.")
        elif name == "pan_y":
            if abs(v) > WARN_PAN_Y:
                print(f"warning: row {i} ({label}) pan_y = {v}: the core clamps vertical "
                      f"pan to +/-64 lines; large moves cut content at one edge.")


def main():
    ap = argparse.ArgumentParser(
        description="Create/edit the AExp per-mode screen-adjustment file "
                    "(/amiga/aexp_screen.cfg): HDMI crop + analog position (pan) "
                    "+ analog overscan.",
        epilog="modes: " + ", ".join(MODE_KEYS) + " (or 'all'). "
               "HDMI: himin +N->LEFT, himax -N->RIGHT, vimin +N->UP, vimax -N->DOWN. "
               "Analog position: pan_x +N->RIGHT, pan_y +N->DOWN (CRTs follow exactly; "
               "auto-positioning LCDs may cancel it). "
               "Analog overscan: os_l +/os_r -/os_t +/os_b - hide border at that edge.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    intarg = lambda s: int(s, 0)
    ap.add_argument("--mode", metavar="M", choices=MODE_KEYS + ["all"],
                    help="which row to edit: " + ", ".join(MODE_KEYS) + ", or all")
    # HDMI crop
    ap.add_argument("--himin", type=intarg, metavar="N", help="HDMI left-edge crop  (+N moves picture left)")
    ap.add_argument("--himax", type=intarg, metavar="N", help="HDMI right-edge crop (-N moves picture right)")
    ap.add_argument("--vimin", type=intarg, metavar="N", help="HDMI top-edge crop   (+N moves picture up)")
    ap.add_argument("--vimax", type=intarg, metavar="N", help="HDMI bottom-edge crop(-N moves picture down)")
    # analog position
    ap.add_argument("--pan-x", dest="pan_x", type=intarg, metavar="N",
                    help="analog position: +N moves the whole analog picture RIGHT (hires pixels)")
    ap.add_argument("--pan-y", dest="pan_y", type=intarg, metavar="N",
                    help="analog position: +N moves the whole analog picture DOWN (lines)")
    # analog overscan (with the pre-v4 option names as compatible aliases)
    ap.add_argument("--os-l", "--os-left", "--hbl-l", dest="os_l", type=intarg, metavar="N",
                    help="analog overscan left edge  (+N hides left border)")
    ap.add_argument("--os-r", "--os-right", "--hbl-r", dest="os_r", type=intarg, metavar="N",
                    help="analog overscan right edge (-N hides right border)")
    ap.add_argument("--os-t", "--os-top", "--vbl-t", dest="os_t", type=intarg, metavar="N",
                    help="analog overscan top edge   (+N hides top border)")
    ap.add_argument("--os-b", "--os-bottom", "--vbl-b", dest="os_b", type=intarg, metavar="N",
                    help="analog overscan bottom edge(-N hides bottom border)")
    # group operations
    ap.add_argument("--reset", choices=["pan", "overscan", "hdmi", "all"], metavar="GROUP",
                    help="zero one group (pan, overscan, hdmi) or all values of the "
                         "selected --mode row(s)")
    ap.add_argument("--copy-from", dest="copy_from", choices=MODE_KEYS, metavar="M",
                    help="copy the complete row of mode M into the --mode row(s) first")
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
            table, version = unpack(data)
        except (OSError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        print(f"{args.listfile} (v{version}):")
        show_table(table, data)
        if version == VERSION_V3:
            print("\n  note: v3 file (no analog position fields; pan shown as 0)")
        return 0

    # --- start from the existing output file (if any), else all zeros -------
    table, note = load_table(args.output)
    if note:
        print(note)

    cli = {name: getattr(args, name.replace("-", "_")) for name in
           ["himin", "himax", "vimin", "vimax", "os_l", "os_r", "os_t", "os_b",
            "pan_x", "pan_y"]}
    has_sets = any(v is not None for v in cli.values())
    has_ops  = has_sets or args.reset is not None or args.copy_from is not None

    if not has_ops and args.mode is None:
        try:
            table = interactive(table)
        except EOFError:            # input ended (pipe/Ctrl-D): save, like Enter
            print("\n(input ended -- saving)")
        except KeyboardInterrupt:   # Ctrl-C: abort WITHOUT saving
            print("\naborted -- nothing was written", file=sys.stderr)
            return 1
    else:
        if args.mode is None:
            print("error: --mode is required when editing on the command line "
                  f"(one of: {', '.join(MODE_KEYS)}, all)", file=sys.stderr)
            return 1
        rows = range(COUNT) if args.mode == "all" else [MODE_KEYS.index(args.mode)]
        # order: copy-from, then reset, then individual values
        if args.copy_from is not None:
            src = MODE_KEYS.index(args.copy_from)
            for r in rows:
                if r != src:
                    table[r] = list(table[src])
            print(f"copied row '{args.copy_from}' -> {args.mode}")
        if args.reset is not None:
            reset_fields = {"pan": PAN_FIELDS, "overscan": OS_FIELDS,
                            "hdmi": HDMI_FIELDS, "all": FIELDS}[args.reset]
            for r in rows:
                for name in reset_fields:
                    table[r][FIELDS.index(name)] = 0
            print(f"reset {args.reset} -> 0 for mode(s): {args.mode}")
        if has_sets:
            for name, v in cli.items():
                if v is None:
                    continue
                for r in rows:
                    table[r][FIELDS.index(name)] = v
                echo_direction(name, v)

    # --- validate, warn, write ----------------------------------------------
    try:
        data = pack(table)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    for i, row in enumerate(table):
        warn_row(i, row)

    try:
        with open(args.output, "wb") as f:
            f.write(data)
    except OSError as e:
        print(f"error: could not write {args.output}: {e}", file=sys.stderr)
        return 1

    print(f"\nwrote {args.output} ({len(data)} bytes, v{VERSION}):")
    show_table(table, data)
    print(f'\nNext: copy {os.path.basename(args.output)} to the /amiga folder on your SD card,')
    print('then choose "Reload screen cfg" in the core menu (or reboot the core).')
    print('Recovery: if the analog picture is ever gone, lower the overscan/pan values')
    print('(or delete the file) and reload -- HDMI is independent, so the menu stays')
    print('visible. Note: v4 files need core WIP-V1-A9 or newer.')
    return 0


if __name__ == "__main__":
    sys.exit(main())
