#!/usr/bin/env python3
"""Static consistency checker for the AExp On-Screen-Menu in CORE/vhdl/config.vhd.

It parses OPTM_ITEMS and OPTM_GROUPS out of config.vhd and verifies everything
that would otherwise only fail at boot on real hardware:

  * OPTM_SIZE equals the number of OPTM_ITEMS lines and OPTM_GROUPS entries
  * every menu-item line starts with a space, every line ends with \\n
  * submenu blocks are balanced and contiguous
  * exactly one OPTM_G_START, at a line that is selectable
  * the OPTM_DEP() declarations obey the rules that M2M/rom/optm_deps.asm
    validates at boot (mother exists, item mask in range, one mother per group,
    masks of a group cover every mother state, no dependent submenu/close line)
  * OPTM_DY is >= the tallest simultaneously visible menu view, over every
    reachable combination of the mother groups, and OPTM_DY + 2 <= CHARS_DY
  * the boot state: one OPTM_G_STDSEL per radio, every STDSEL line visible
    under the other defaults, at most one drive defaulting to Hardware Floppy
  * every C_MENU_* constant in mega65.vhd against the text of its line
  * the MENU_HEAP_SIZE demand of M2M/rom/options.asm HELP_MENU
  * the welcome and help pages against the framed help screen geometry

Run it from anywhere after any change to config.vhd or to a C_MENU_*
constant; the repository root is found from the location of this file. The
last line is "all checks passed", or the number of failed checks with a
non-zero exit status.

Usage: python3 tools/check_osm_menu.py [path/to/config.vhd]
"""

import itertools
import os
import re
import sys

# ---------------------------------------------------------------------------
# constants mirrored from config.vhd / globals.vhd / menu.asm
# ---------------------------------------------------------------------------
G_TEXT = 0x00000
G_CLOSE = 0x000FF
G_STDSEL = 0x00100
G_LINE = 0x00200
G_START = 0x00400
G_MOUNT_DRV = 0x00800
G_HEADLINE = 0x01000
G_HELP = 0x0A000
G_SINGLESEL = 0x08000
G_SUBMENU = 0x0C000
G_LOAD_ROM = 0x18000
G_DEPENDENT = 0x20000000

CHARS_DY = 36  # globals.vhd: VGA_DY / FONT_DY
OPTM_STRUCTSIZE = 20  # M2M/rom/menu.asm
NUM_VDRIVES = 0  # globals.vhd C_VDNUM


def fail(msg):
    print("FAIL: " + msg)
    fail.count += 1


fail.count = 0


def read_config(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def strip_comments(text):
    return re.sub(r"--[^\n]*", "", text)


def parse_scalar(src, name):
    match = re.search(
        r"constant\s+%s\s*:\s*natural\s*:=\s*(\d+)" % name, src)
    if not match:
        raise SystemExit("cannot find constant " + name)
    return int(match.group(1))


def parse_items(src):
    """Return the list of menu lines and the raw OPTM_ITEMS character count."""
    body = re.search(
        r"constant OPTM_ITEMS\s*:\s*string\s*:=(.*?);\s*\n", src, re.S)
    if not body:
        raise SystemExit("cannot find OPTM_ITEMS")
    text = strip_comments(body.group(1))
    parts = re.findall(r'"((?:[^"]|"")*)"', text)
    joined = "".join(part.replace('""', '"') for part in parts)
    if not joined.endswith("\\n"):
        raise SystemExit("OPTM_ITEMS does not end with a newline escape")
    lines = joined.split("\\n")[:-1]
    return lines, len(joined)


def parse_groups(src):
    """Return the list of OPTM_GROUPS expressions (one string per entry)."""
    body = re.search(
        r"constant OPTM_GROUPS\s*:\s*OPTM_GTYPE\s*:=\s*\((.*?)\n\s*\);", src, re.S)
    if not body:
        raise SystemExit("cannot find OPTM_GROUPS")
    text = strip_comments(body.group(1))
    entries, depth, current = [], 0, ""
    for char in text:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            entries.append(current)
            current = ""
        else:
            current += char
    if current.strip():
        entries.append(current)
    return [" ".join(entry.split()) for entry in entries]


def parse_group_ids(src):
    ids = {}
    for name, value in re.findall(
            r"constant\s+(OPTM_G_\w+)\s*:\s*integer\s*:=\s*(\d+)\s*;", src):
        ids[name] = int(value)
    return ids


def evaluate(expr, ids):
    """Evaluate one OPTM_GROUPS entry into (flags, dependency-or-None)."""
    names = dict(ids)
    names.update({
        "OPTM_G_TEXT": G_TEXT, "OPTM_G_CLOSE": G_CLOSE,
        "OPTM_G_STDSEL": G_STDSEL, "OPTM_G_LINE": G_LINE,
        "OPTM_G_START": G_START, "OPTM_G_MOUNT_DRV": G_MOUNT_DRV,
        "OPTM_G_HEADLINE": G_HEADLINE, "OPTM_G_SINGLESEL": G_SINGLESEL,
        "OPTM_G_HELP": G_HELP, "OPTM_G_SUBMENU": G_SUBMENU,
        "OPTM_G_LOAD_ROM": G_LOAD_ROM, "OPTM_G_DEPENDENT": G_DEPENDENT,
    })

    def dep(mother, item):
        return G_DEPENDENT + (2 ** item) * 0x02000000 + mother * 0x00020000

    def dep2(mother, item_a, item_b):
        return (G_DEPENDENT + (2 ** item_a + 2 ** item_b) * 0x02000000
                + mother * 0x00020000)

    value = eval(expr, {"__builtins__": {}},  # noqa: S307 - fixed local input
                 dict(names, OPTM_DEP=dep, OPTM_DEP2=dep2))
    if value < 0 or value >= 2 ** 30:
        fail("group word out of the OPTM_GTC=30 range: %s" % expr)
    return value


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        root, "CORE", "vhdl", "config.vhd")
    src = read_config(path)

    size = parse_scalar(src, "OPTM_SIZE")
    dx = parse_scalar(src, "OPTM_DX")
    dy = parse_scalar(src, "OPTM_DY")
    lines, item_chars = parse_items(src)
    exprs = parse_groups(src)
    ids = parse_group_ids(src)
    words = [evaluate(expr, ids) for expr in exprs]

    print("OPTM_SIZE=%d  OPTM_DX=%d  OPTM_DY=%d" % (size, dx, dy))
    print("OPTM_ITEMS: %d lines, %d characters" % (len(lines), item_chars))
    print("OPTM_GROUPS: %d entries" % len(exprs))

    # -- counts ------------------------------------------------------------
    if len(lines) != size:
        fail("OPTM_ITEMS has %d lines but OPTM_SIZE is %d" % (len(lines), size))
    if len(exprs) != size:
        fail("OPTM_GROUPS has %d entries but OPTM_SIZE is %d"
             % (len(exprs), size))
    if len(lines) != len(exprs):
        return report()

    # -- per-line sanity ---------------------------------------------------
    for index, (line, word) in enumerate(zip(lines, words)):
        group = word & 0xFF
        is_line = bool(word & G_LINE)
        selectable = bool(word & G_SUBMENU) or group != 0
        if is_line and line != "":
            fail("line %d is a separator but carries text %r" % (index, line))
        if selectable and not line.startswith(" "):
            fail("line %d is selectable but does not start with a space: %r"
                 % (index, line))
        if len(line) > dx:
            fail("line %d is %d characters, wider than OPTM_DX=%d: %r"
                 % (index, len(line), dx, line))

    # -- submenu structure -------------------------------------------------
    depth, opener = 0, None
    submenus = 0
    for index, word in enumerate(words):
        if word & G_SUBMENU == G_SUBMENU:
            if depth == 0:
                depth, opener = 1, index
                submenus += 1
            else:
                depth = 0
    if depth != 0:
        fail("unbalanced submenu block starting at line %d" % opener)
    print("submenus: %d" % submenus)

    load_roms = [i for i, w in enumerate(words) if w & G_LOAD_ROM == G_LOAD_ROM]
    mounts = [i for i, w in enumerate(words)
              if w & G_MOUNT_DRV == G_MOUNT_DRV and w & G_LOAD_ROM != G_LOAD_ROM]
    print("OPTM_G_LOAD_ROM lines: %s" % load_roms)
    if mounts:
        print("OPTM_G_MOUNT_DRV lines: %s" % mounts)

    starts = [i for i, w in enumerate(words) if w & G_START]
    start = starts[0] if starts else None
    if len(starts) != 1:
        fail("expected exactly one OPTM_G_START, found %s" % starts)
    else:
        if not (words[start] & G_SUBMENU or words[start] & 0xFF):
            fail("OPTM_G_START at line %d is not selectable" % start)

    # -- dependency declarations ------------------------------------------
    members = {}
    for index, word in enumerate(words):
        group = word & 0xFF
        if group in (0, 0xFF) or word & G_SUBMENU == G_SUBMENU:
            continue
        members.setdefault(group, []).append(index)

    deps = {}
    for index, word in enumerate(words):
        if not word & G_DEPENDENT:
            continue
        mother = (word >> 17) & 0xFF
        mask = (word >> 25) & 0x0F
        deps[index] = (mother, mask)
        if mother in (0, 0xFF) or mother not in members:
            fail("line %d depends on group %d which has no members"
                 % (index, mother))
            continue
        if mask == 0:
            fail("line %d has an empty dependency mask" % index)
        count = len(members[mother])
        single = bool(words[members[mother][0]] & G_SINGLESEL)
        limit = 2 if single else min(count, 4)
        if mask >> limit:
            fail("line %d dependency mask 0x%X exceeds the %d item(s) of "
                 "mother group %d" % (index, mask, limit, mother))
        if words[index] & G_SUBMENU == G_SUBMENU or (words[index] & 0xFF) == 0xFF:
            fail("line %d is a submenu/close line and must not be dependent"
                 % index)
        if (words[index] & 0xFF) and index in members.get(mother, []):
            fail("line %d depends on its own group %d" % (index, mother))

    # one mother per group, and the masks must cover every mother state
    for group, member_lines in sorted(members.items()):
        mothers = {deps[i][0] for i in member_lines if i in deps}
        tagged = [i for i in member_lines if i in deps]
        if not tagged:
            continue
        if len(tagged) != len(member_lines):
            fail("group %d mixes dependent and unconditional members: %s"
                 % (group, member_lines))
        if len(mothers) != 1:
            fail("group %d members reference several mothers: %s"
                 % (group, sorted(mothers)))
            continue
        mother = mothers.pop()
        # Coverage only applies to real radios: a single-select item (toggle,
        # mount or load line) that is hidden in some mother state is exactly
        # what the twin-line pattern is for. A multi-item radio, however, must
        # always offer at least one member, otherwise the user is locked out
        # of a setting that still holds a selection.
        if len(member_lines) < 2 or words[member_lines[0]] & G_SINGLESEL:
            continue
        count = min(len(members[mother]), 4)
        union = 0
        for i in tagged:
            union |= deps[i][1]
        missing = [k for k in range(count) if not union & (1 << k)]
        if missing:
            fail("radio group %d is completely hidden while mother group %d "
                 "has item(s) %s selected" % (group, mother, missing))

    # -- the boot state: OPTM_G_STDSEL ------------------------------------
    # The settings file that ships with a release is all 0xFF, which makes the
    # firmware fall back to the OPTM_G_STDSEL flags (M2M/rom/options.asm
    # _HLP_STDSEL). So the STDSEL flags are the shipped configuration, and two
    # properties have to hold that nothing else in this file checks:
    #   * every radio group carries exactly one of them, and
    #   * the line carrying it is visible in the state the other STDSEL flags
    #     produce - otherwise the menu boots with a radio whose selected item
    #     the user cannot see, and the only way back is to disturb the mother.
    # Nothing at boot reconciles the two: the firmware helpers that keep the
    # drive radios consistent only run after the user changes something.
    stdsel = {}
    for group, member_lines in sorted(members.items()):
        flagged = [i for i in member_lines if words[i] & G_STDSEL]
        single = bool(words[member_lines[0]] & G_SINGLESEL)
        if not single:
            # A radio group - including a one-member one - is addressed by the
            # ordinal of its selected member (optm_deps.asm _ODO_RADIO scans
            # from the first member), so a lone member is ordinal 0, not 1.
            if len(flagged) != 1:
                fail("radio group %d must carry exactly one OPTM_G_STDSEL, "
                     "found %s" % (group, flagged))
                continue
            stdsel[group] = member_lines.index(flagged[0])
        else:
            if len(flagged) > 1:
                fail("group %d carries %d OPTM_G_STDSEL flags: %s"
                     % (group, len(flagged), flagged))
            stdsel[group] = 1 if flagged else 0

    boot_hidden = []
    for group, member_lines in sorted(members.items()):
        ordinal = stdsel.get(group)
        if ordinal is None:
            continue
        single = bool(words[member_lines[0]] & G_SINGLESEL)
        line = member_lines[0] if single else member_lines[ordinal]
        if not (words[line] & G_STDSEL):
            continue
        index = line
        if index in deps:
            mother, mask = deps[index]
            if not mask & (1 << stdsel.get(mother, 0)):
                boot_hidden.append((index, group, mother))
    for index, group, mother in boot_hidden:
        fail("line %d carries OPTM_G_STDSEL for group %d but is hidden at "
             "boot: mother group %d defaults to item %d"
             % (index, group, mother, stdsel.get(mother, 0)))

    if start is not None and start in deps:
        mother, mask = deps[start]
        if not mask & (1 << stdsel.get(mother, 0)):
            fail("the OPTM_G_START line %d is hidden at boot (mother group %d "
                 "defaults to item %d)" % (start, mother, stdsel.get(mother, 0)))

    # The other unreconciled drive invariant: exactly one physical mechanism
    # exists, and DRV_STEAL_HW only runs after a user change, so the defaults
    # must not hand "Hardware Floppy" to two drives at once. The HDL would
    # degrade the second one to Disk Image silently while the menu kept
    # showing it as the hardware drive.
    hw_default = [g for g, m in sorted(members.items())
                  if g in stdsel and not (words[m[0]] & G_SINGLESEL)
                  and len(m) > stdsel[g]
                  and lines[m[stdsel[g]]].strip() == "Hardware Floppy"]
    if len(hw_default) > 1:
        fail("%d drive mode groups default to \"Hardware Floppy\" (%s); only "
             "one physical mechanism exists" % (len(hw_default), hw_default))

    def boot_visible(index):
        if index not in deps:
            return True
        mother, mask = deps[index]
        return bool(mask & (1 << stdsel.get(mother, 0)))

    print("boot state (all-0xFF settings file = OPTM_G_STDSEL):")
    for group, member_lines in sorted(members.items()):
        if len(member_lines) < 2 or words[member_lines[0]] & G_SINGLESEL:
            continue
        sel = member_lines[stdsel[group]]
        print("   group %3d default -> line %3d  %r"
              % (group, sel, lines[sel].strip()))

    # -- worst-case visible height per menu view ---------------------------
    mother_groups = sorted({m for m, _ in deps.values()})
    states = []
    for mother in mother_groups:
        # Mirror the dependency validator above (and OPTM_DEP_OK): a
        # single-select mother has two states, off and on, not one per member.
        if words[members[mother][0]] & G_SINGLESEL:
            count = 2
        else:
            count = min(len(members[mother]), 4)
        states.append(range(count))

    def visible(index, selection):
        if index not in deps:
            return True
        mother, mask = deps[index]
        return bool(mask & (1 << selection[mother]))

    # assign every line to its menu view: 0 = main menu, n = n-th submenu
    view = [0] * size
    current, level = 0, 0
    for index, word in enumerate(words):
        if word & G_SUBMENU == G_SUBMENU:
            if level == 0:
                level, current = 1, current + 1
                view[index] = 0            # the opener shows in the main menu
                continue
            level = 0
            view[index] = current
            continue
        view[index] = current if level else 0

    worst = {}
    for combo in itertools.product(*states) if states else [()]:
        selection = dict(zip(mother_groups, combo))
        counts = {}
        for index in range(size):
            if visible(index, selection):
                counts[view[index]] = counts.get(view[index], 0) + 1
        for key, value in counts.items():
            if value > worst.get(key, 0):
                worst[key] = value
    for key in sorted(worst):
        label = "main menu" if key == 0 else "submenu %d" % key
        print("view %-12s max %2d simultaneously visible lines"
              % (label, worst[key]))
    tallest = max(worst.values())
    if dy < tallest:
        fail("OPTM_DY=%d is smaller than the tallest view (%d lines)"
             % (dy, tallest))
    if dy > tallest:
        print("note: OPTM_DY=%d exceeds the tallest view (%d) by %d"
              % (dy, tallest, dy - tallest))
    if dy + 2 > CHARS_DY:
        fail("OPTM_DY + 2 = %d exceeds the %d character rows of the OSM canvas"
             % (dy + 2, CHARS_DY))

    # -- C_MENU_* in mega65.vhd must point at the line it claims -----------
    # This is the check that catches a menu renumbering that was applied to
    # config.vhd but not (or wrongly) to the HDL: every constant is verified
    # against the text of the line it addresses.
    mega = os.path.join(root, "CORE", "vhdl", "mega65.vhd")
    expected = {
        "C_MENU_DRIVES_1": "1", "C_MENU_DRIVES_2": "2", "C_MENU_DRIVES_3": "3",
        "C_MENU_DF0_IMG": "Disk Image", "C_MENU_DF0_HW": "Hardware Floppy",
        "C_MENU_DF1_IMG": "Disk Image", "C_MENU_DF1_HW": "Hardware Floppy",
        "C_MENU_DF1_OFF": "Off",
        "C_MENU_DF2_IMG": "Disk Image", "C_MENU_DF2_HW": "Hardware Floppy",
        "C_MENU_DF2_OFF": "Off",
        "C_MENU_DF0_MOUNT_LN": "df0:%s", "C_MENU_DF0_HW_LN": "df0:Hardware Floppy",
        "C_MENU_DF1_MOUNT_LN": "df1:%s", "C_MENU_DF1_HW_LN": "df1:Hardware Floppy",
        "C_MENU_DF2_MOUNT_LN": "df2:%s", "C_MENU_DF2_HW_LN": "df2:Hardware Floppy",
        "C_MENU_HDMI_16_9_50": "720p 50 Hz 16:9", "C_MENU_HDMI_4_3_50": "576p 50 Hz 4:3",
        "C_MENU_HDMI_5_4_50": "576p 50 Hz 5:4", "C_MENU_HDMI_DVI": "DVI (no sound)",
        "C_MENU_FLT_NO_FILTER": "No Filter", "C_MENU_FLT_SHARP": "Sharp Bilinear",
        "C_MENU_FLT_BICUBIC": "Bicubic", "C_MENU_FLT_SMOOTH": "Smooth",
        "C_MENU_FLT_LANCZOS": "Lanczos", "C_MENU_FLT_SCANLINES": "Scanlines",
        "C_MENU_FLT_CRT_SVIDEO": "CRT (S-Video)", "C_MENU_FLT_CRT_COMPOSITE": "CRT (Composite)",
        "C_MENU_HDMI_FF": "HDMI: Flicker-free", "C_MENU_VGA_STD": "Standard",
        "C_MENU_VGA_15KHZHSVS": "15 kHz with HS/VS", "C_MENU_VGA_15KHZCS": "15 kHz with CSYNC",
        "C_MENU_A500FILT": "A500 Filter", "C_MENU_LEDFILT": "LED Filter",
        "C_MENU_KBD_AMIGA": "Amiga", "C_MENU_OSMKEY_HELP": "Help",
        "C_MENU_OSMKEY_F11": "F11", "C_MENU_OSMKEY_F13": "F13",
        "C_MENU_OSMKEY_COMBO": "MEGA + Run/Stop", "C_MENU_SLOWRAM": "Slow RAM (A501)",
    }
    ranges = {  # subtype name -> (first line text, last line text)
        "C_MENU_OSM_SCALING": ("50%", "100%"),
        "C_MENU_VOLUME": ("0%", "100%"),
        "C_MENU_STEREO": ("Mono", "Full Stereo"),
    }
    if os.path.exists(mega):
        with open(mega, encoding="utf-8") as handle:
            hdl = handle.read()
        found = dict(re.findall(
            r"constant\s+(C_MENU_\w+)\s*:\s*natural\s*:=\s*(\d+)\s*;", hdl))
        for name, text in sorted(expected.items()):
            if name not in found:
                fail("mega65.vhd has no %s" % name)
                continue
            index = int(found[name])
            if index >= size:
                fail("%s = %d is beyond OPTM_SIZE" % (name, index))
            elif lines[index].strip() != text:
                fail("%s = %d points at %r, expected %r"
                     % (name, index, lines[index].strip(), text))
        for name, (lo_text, hi_text) in sorted(ranges.items()):
            match = re.search(
                r"subtype\s+%s\s+is\s+natural\s+range\s+(\d+)\s+downto\s+(\d+)\s*;"
                % name, hdl)
            if not match:
                fail("mega65.vhd has no subtype %s" % name)
                continue
            hi, lo = int(match.group(1)), int(match.group(2))
            if lines[hi].strip() != lo_text or lines[lo].strip() != hi_text:
                fail("%s range %d downto %d spans %r..%r, expected %r..%r"
                     % (name, hi, lo, lines[hi].strip(), lines[lo].strip(),
                        lo_text, hi_text))
        print("C_MENU_* constants: %d singles + %d ranges cross-checked "
              "against the item text" % (len(expected), len(ranges)))

    # -- heap demand (M2M/rom/options.asm HELP_MENU) -----------------------
    permanent = OPTM_STRUCTSIZE + item_chars + 1 + 4 * size + 1
    optm_heap = (NUM_VDRIVES + submenus + len(load_roms) + 1) * (dx + 2)
    boot_scratch = OPTM_STRUCTSIZE + 3 * size
    demand = permanent + optm_heap
    # Round to the next 32-word boundary and no further: FB_HEAP starts at
    # HEAP + MENU_HEAP_SIZE (M2M/rom/shell.asm), so every word reserved here
    # is taken straight out of the file browser. A small quantum absorbs the
    # usual menu-text tweak without an edit; anything larger is dead weight.
    rounded = ((demand + 31) // 32) * 32
    print("MENU_HEAP demand: %d (menu %d + OPTM_HEAP %d), boot scratch %d"
          % (demand, permanent, optm_heap, boot_scratch))
    print("MENU_HEAP_SIZE should be %d (next 32-word boundary, headroom %d)"
          % (rounded, rounded - demand))

    rom = os.path.join(root, "CORE", "m2m-rom", "m2m-rom.asm")
    if os.path.exists(rom):
        with open(rom, encoding="utf-8") as handle:
            text = handle.read()
        match = re.search(r"MENU_HEAP_SIZE\s+\.EQU\s+(\d+)", text)
        if match:
            actual = int(match.group(1))
            print("m2m-rom.asm MENU_HEAP_SIZE = %d" % actual)
            if actual < demand or actual < boot_scratch:
                fail("MENU_HEAP_SIZE %d is below the demand %d"
                     % (actual, max(demand, boot_scratch)))
            elif actual != rounded:
                fail("MENU_HEAP_SIZE %d should be %d" % (actual, rounded))

    check_help_pages(src, root)

    return report()


def check_help_pages(src, root):
    """The welcome and help screens are drawn into a full-screen frame.

    M2M/rom/shell.asm FRAME_FULLSCR draws the frame at SCR$OSM_M_X/Y with
    SCR$OSM_M_DX/DY = the whole character canvas, and SCR$PRINTFRAME leaves
    the cursor at (x+1, y+1). M2M/rom/whs.asm WHS_SHOW_PAGES then prints the
    page from there with no GOTOXY, so rendered row i lands on screen row
    i+1. With the canvas CHARS_DX x CHARS_DY and a one-character frame, the
    area inside the frame is rows 1..CHARS_DY-2 and columns 1..CHARS_DX-2.

    The pages use one row and one column less. Every page starts with an
    empty row and every line with a space, and the free last row and column
    mirror them: text on the last row inside the frame touches the bottom
    border on screen. Each help page has exactly that many rows, so its
    footer stays on the same two rows while the reader pages through, and
    the footer carries the page counter "(n/N)", which must match the page.
    Nothing else in the build catches any of this, because it is plain
    string concatenation in config.vhd.
    """
    globals_vhd = os.path.join(root, "CORE", "vhdl", "globals.vhd")
    try:
        with open(globals_vhd, encoding="utf-8") as handle:
            gtext = strip_comments(handle.read())
    except OSError:
        print("note: globals.vhd not readable, help-page geometry not checked")
        return

    def constant(name):
        match = re.search(r"constant\s+%s\s*:\s*natural\s*:=\s*(\d+)" % name, gtext)
        return int(match.group(1)) if match else None

    vga_dx, vga_dy = constant("VGA_DX"), constant("VGA_DY")
    font_dx, font_dy = constant("FONT_DX"), constant("FONT_DY")
    if not all((vga_dx, vga_dy, font_dx, font_dy)):
        print("note: screen geometry not found in globals.vhd, pages not checked")
        return
    chars_dx, chars_dy = vga_dx // font_dx, vga_dy // font_dy
    max_rows, max_cols = chars_dy - 3, chars_dx - 3

    version = re.search(r'constant CORE_VERSION\s*:\s*string\s*:=\s*"([^"]+)"', src)
    version = version.group(1) if version else ""

    nocom = strip_comments(src)
    pages = re.findall(r"constant\s+(SCR_WELCOME|HELP_\d+)\s*:\s*string\s*:=", nocom)
    if not pages:
        fail("no SCR_WELCOME/HELP_* pages found in config.vhd")
        return

    def page_text(body):
        """Collect the concatenated literals up to the terminating semicolon.

        Scanned rather than split on ";": a page that contains a semicolon in
        its own prose ("Writes are saved in the background;") would otherwise
        be truncated, and the page would be measured far too short - i.e. the
        check would pass for exactly the page most likely to be too long.
        """
        out, inside, i = [], False, 0
        while i < len(body):
            char = body[i]
            if inside:
                if char == '"':
                    inside = False
                else:
                    out.append(char)
            elif char == '"':
                inside = True
            elif char == ";":
                break
            i += 1
        return "".join(out)

    help_count = sum(1 for name in pages if name != "SCR_WELCOME")
    worst = 0
    for name in pages:
        body = nocom.split("constant %s : string :=" % name, 1)[1]
        # CORE_VERSION is concatenated into some pages; measure the real width
        body = body.replace("CORE_VERSION", '"%s"' % version)
        text = page_text(body)
        rows = text.replace("\\n", "\n").split("\n")
        worst = max(worst, len(rows))
        if name == "SCR_WELCOME":
            if len(rows) > max_rows:
                fail("%s renders %d rows; the welcome screen holds %d"
                     % (name, len(rows), max_rows))
        else:
            if len(rows) != max_rows:
                fail("%s renders %d rows; every help page has exactly %d, so "
                     "that its footer stays on rows %d and %d"
                     % (name, len(rows), max_rows, max_rows - 1, max_rows))
            expected = "(%s/%d)" % (name.split("_")[1], help_count)
            footer = rows[-2].rstrip() if len(rows) > 1 else ""
            if not footer.endswith(expected):
                fail("%s footer %r does not end with the page counter %s"
                     % (name, footer.strip(), expected))
        for index, row in enumerate(rows):
            if len(row) > max_cols:
                fail("%s row %d is %d characters wide; the help screen "
                     "takes %d" % (name, index, len(row), max_cols))
    print("help pages: %d checked, tallest %d of %d rows, width limit %d"
          % (len(pages), worst, max_rows, max_cols))


def report():
    if fail.count:
        print("\n%d check(s) FAILED" % fail.count)
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
