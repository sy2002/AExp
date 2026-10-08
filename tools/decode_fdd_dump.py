#!/usr/bin/env python3
"""Decode register dumps of the Hardware Floppy diagnostics device.

The diagnostics device is QNICE device 0x0104. From the QNICE monitor, select
it and dump its window with `M D 7000 707D`; doc/developers/hardware-floppy.md
section 8 explains the registers and section 9 the field-report protocols.
The register map is in the header of
CORE/vhdl/physical_fdd/physical_fdd_diag.vhd. Register 0x01 holds the map
version (0x000D in current builds); the decoder knows every map version from
0x0006 on and decodes each dump by the version it reports.

Input: one or more text files (or stdin) containing register dumps in any of
these shapes, freely mixed:

    7000: FDD0 000D 079D ...        QNICE monitor style, N words per line
    0x7010: 0005                    single word with address
    0x20 = 0x40A8                   register-relative
    FDD0 000D 079D ...              bare words, assigned from reg 0 upward

A new dump starts at a separator line (---, ===, or a line containing the
word "dump"), or when an address already present in the current dump
re-appears. Trailing prose after the hex words of a line is warned about and
never parsed as data; hex tokens longer than 4 digits are rejected with a
warning.

Alias folding: map 0x0006 decodes addr[5:0] and later maps decode addr[6:0],
so a dump wider than 64 (or 128) words contains the same registers twice; the
second half is a re-read a moment later. Each half becomes its own snapshot
(labelled "alias re-read"). Counters identical between two halves of one dump
just mean the drive was idle during the dump, but two separate dumps that are
byte-identical including their alias halves are physically the same capture,
duplicated by the dump procedure, and the decoder says so. From map 0x0007 on
the uptime and dump-nonce registers make that verdict definitive.

Usage:
    python3 tools/decode_fdd_dump.py dump.txt [more.txt ...]
    pbpaste | python3 tools/decode_fdd_dump.py
    python3 tools/decode_fdd_dump.py --selftest
"""

import re
import sys

NOMINAL_EST_Q = 0x640          # 100.0 cycles, Q8.4
CLK_HZ        = 50_000_000
WORDS_PER_ATTEMPT = 7358       # KS1.3 trackdisk read DMA length, words
WORDS_PER_REV     = 6250       # ~200 ms at 500 kbit/s channel rate

STATUS_BITS = [
    (0, "enable"), (1, "selected"), (2, "motor"), (3, "media_ready"),
    (4, "spun_up"), (5, "index_fresh"), (6, "index_active"),
    (7, "track0_n"), (8, "wprot_n"), (9, "change_n"),
    (10, "rdata"), (11, "fifo_full"),
]

# free-running counters for the stale-instrument check (register, width bits)
MOVING_COUNTERS = [
    (0x0A, 16, "index edges"), (0x0B, 16, "sync hits"),
    (0x0C, 16, "words"),       (0x0E, 16, "loss-of-lock"),
    (0x12, 16, "captures"),    (0x1B, 16, "served"),
]

COUNTER_REGS = MOVING_COUNTERS + [
    (0x0D, 16, "runts"), (0x0F, 16, "FIFO drops"), (0x1E, 16, "fmt_bad"),
]


# --------------------------------------------------------------------------
# MFM arithmetic
# --------------------------------------------------------------------------

def mfm_decode_long(w0, w1, w2, w3):
    """Amiga MFM info-long decode per the diag header:
    odd = (W0<<16)|W1, even = (W2<<16)|W3,
    info = ((odd AND 0x55555555)<<1) OR (even AND 0x55555555)."""
    odd = (w0 << 16) | w1
    even = (w2 << 16) | w3
    return (((odd & 0x55555555) << 1) | (even & 0x55555555)) & 0xFFFFFFFF


def mfm_encode_long(info, prev_data_bit):
    """Inverse of mfm_decode_long, with legal clock bits (for self-test and
    for judging what a clean capture should look like). Returns 4 words.
    prev_data_bit = last data bit of the preceding word in the stream."""
    odd = (info >> 1) & 0x55555555
    even = info & 0x55555555
    words = []
    prev = prev_data_bit
    for long_val in (odd, even):
        for shift in (16, 0):
            data16 = (long_val >> shift) & 0x5555
            w = 0
            for pos in range(15, -1, -1):
                if pos % 2 == 0:            # data bit
                    bit = (data16 >> pos) & 1
                    prev = bit
                else:                       # clock bit = ~(prev | next)
                    nxt = (data16 >> (pos - 1)) & 1
                    bit = 0 if (prev | nxt) else 1
                w |= bit << pos
            words.append(w)
    return words


def mfm_clock_violations(words, prev_data_bit=None):
    """Count clock-rule violations (clock != ~(prev_data | next_data)) per
    word. prev_data_bit=None skips the first word's bit-15 check. A 0x4489
    sync word legitimately carries exactly one violation (the A1 missing
    clock at bit 5). Returns list of per-word violation counts."""
    out = []
    prev = prev_data_bit
    for w in words:
        viol = 0
        for pos in range(15, -1, -1):
            bit = (w >> pos) & 1
            if pos % 2 == 0:
                prev = bit
            else:
                nxt = (w >> (pos - 1)) & 1
                if prev is None:
                    continue
                if bit != (0 if (prev | nxt) else 1):
                    viol += 1
        out.append(viol)
    return out


def decode_info_words(words, label):
    """Decode 4 MFM words as a sector info long; return (info, lines)."""
    info = mfm_decode_long(*words)
    fmt = (info >> 24) & 0xFF
    trk = (info >> 16) & 0xFF
    sec = (info >> 8) & 0xFF
    gap = info & 0xFF
    lines = [f"  {label}: info long 0x{info:08X} -> "
             f"format 0x{fmt:02X}, track {trk} (cyl {trk // 2} head {trk % 2}), "
             f"sector {sec}, sectors-to-gap {gap}"]
    if fmt != 0xFF:
        lines.append(f"  !! format byte 0x{fmt:02X} != 0xFF - not a clean "
                     f"AmigaDOS header (junk phase, splice, or corruption)")
    if sec > 10:
        lines.append(f"  !! sector {sec} out of range 0..10")
    return info, lines


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

ADDR_LINE = re.compile(r"^\s*(?:0x)?([0-9A-Fa-f]{1,4})\s*[:=]\s*(.*)$")
HEXTOKEN = re.compile(r"^(?:0x)?([0-9A-Fa-f]{1,4})$")
LONGHEX = re.compile(r"^(?:0x)?[0-9A-Fa-f]{5,}$")
SEPARATOR = re.compile(r"^\s*(?:[-=~_*]{3,}.*|.*\bdumps?\b.*)$", re.I)


def _hex_tokens(tail, raw, warnings):
    """Consume leading valid hex-word tokens from a line tail; warn about
    (and never parse) anything after the first invalid token."""
    values = []
    toks = re.split(r"[\s,]+", tail.strip())
    for i, t in enumerate(toks):
        if not t:
            continue
        m = HEXTOKEN.match(t)
        if m:
            values.append(int(m.group(1), 16))
            continue
        rest = " ".join(toks[i:])
        if LONGHEX.match(t):
            warnings.append(f"rejected hex token > 4 digits ({t!r}) and the "
                            f"rest of the line: {raw!r}")
        else:
            warnings.append(f"ignored trailing non-hex text {rest!r}: {raw!r}")
        break
    return values


def parse_dumps(text):
    """Return (dumps, warnings): dumps = list of {reg: value} dicts, with
    reg = raw word offset inside the 4k window (0x000..0xFFF) or a direct
    register index for address-free / register-relative inputs. Alias
    folding happens later in normalize_dumps."""
    dumps, cur, warnings = [], {}, []
    next_seq_reg = 0

    def close():
        nonlocal cur, next_seq_reg
        if cur:
            dumps.append(cur)
        cur = {}
        next_seq_reg = 0

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = ADDR_LINE.match(line)
        if m:
            addr = int(m.group(1), 16)
            if addr >= 0x8000 or (0x100 <= addr < 0x7000):
                warnings.append(f"ignored line (address 0x{addr:X} outside "
                                f"the diag window): {raw!r}")
                continue
            reg = addr - 0x7000 if addr >= 0x7000 else addr
            values = _hex_tokens(m.group(2), raw, warnings)
            if not values:
                warnings.append(f"ignored line (no hex words after address): {raw!r}")
                continue
            if any((reg + i) in cur for i in range(len(values))):
                close()
            for i, v in enumerate(values):
                cur[reg + i] = v
            next_seq_reg = reg + len(values)
            continue
        if SEPARATOR.match(line):
            close()
            continue
        if HEXTOKEN.match(line.split()[0]) or LONGHEX.match(line.split()[0]):
            for v in _hex_tokens(line, raw, warnings):
                if next_seq_reg in cur:
                    close()
                cur[next_seq_reg] = v
                next_seq_reg += 1
            continue
        warnings.append(f"ignored line (unparseable): {raw!r}")
    close()
    return dumps, warnings


def normalize_dumps(raw_dumps):
    """Fold device-address aliasing and split each raw dump into snapshots.

    The device decodes addr[5:0] (v6; 64-word groups) or addr[6:0] (v7+;
    128-word groups), so a wide dump contains the same registers repeatedly;
    each repetition is a re-read a moment later = its own snapshot.
    Returns a list of (label_suffix, {reg: value}) with unmapped/filler
    registers dropped."""
    snaps = []
    for di, raw in enumerate(raw_dumps):
        ver = raw.get(0x01, 0x0006)
        group = 0x40 if ver <= 0x0006 else 0x80
        if ver <= 0x0006:
            mapped_end = 0x30
        elif ver <= 0x0008:
            mapped_end = 0x5F
        elif ver == 0x0009:
            mapped_end = 0x60
        elif ver <= 0x000C:
            mapped_end = 0x6F
        else:
            mapped_end = 0x7E          # 0x000D adds the WRITE block 0x70-0x7D
        n_groups = (max(raw) // group) + 1 if raw else 1
        for g in range(n_groups):
            snap = {}
            for reg, v in raw.items():
                if reg // group == g:
                    r = reg % group
                    if r < mapped_end:
                        snap[r] = v
            if snap:
                snaps.append(("" if g == 0 else f" (alias re-read {g})", snap, di))
    return snaps


# --------------------------------------------------------------------------
# Per-snapshot decode
# --------------------------------------------------------------------------

def fmt_reg(d, reg):
    return f"0x{d[reg]:04X}" if reg in d else "----"


def decode_dump(d, title):
    out = [f"===== {title} " + "=" * max(1, 60 - len(title))]

    def have(*regs):
        return all(r in d for r in regs)

    if 0x00 in d and d[0x00] != 0xFDD0:
        out.append(f"!! signature reg 0x00 = {fmt_reg(d, 0x00)}, expected "
                   f"0xFDD0 - not a diag dump / wrong window?")
    if 0x01 in d:
        # map version -> the build that reports it, so a pasted field dump
        # identifies the core it came from
        note = {0x0006: "",
                0x0007: "  (WIP-V2-A4: margin instruments)",
                0x0008: "  (WIP-V2-A5: registered readout; register content = v7)",
                0x0009: "  (WIP-V2-A5 with the DPLL data separator)",
                0x000A: "  (WIP-V2-A6: WORDSYNC-conditional framing hold "
                        "+ seam instruments)",
                0x000B: "  (WIP-V2-A7: sync-anchored capture framing; "
                        "register content = v10)",
                0x000C: "  (WIP-V2-A8: Paula DSKBYTR observation surface for "
                        "Rob Northen Copylock; register content = v10, the "
                        "surface is in paula_floppy.v - 0x35 bit 8 = A/B revert)",
                0x000D: "  (WIP-V2-A9 and later: the Hardware Floppy write "
                        "datapath; v10 content plus the 0x70-0x7D write "
                        "instruments)",
                }.get(d[0x01], "  !! unknown map version")
        out.append(f"map version:   {fmt_reg(d, 0x01)}{note}")

    if 0x02 in d:
        s = d[0x02]
        bits = ", ".join(name for bit, name in STATUS_BITS if s & (1 << bit))
        out.append(f"status 0x02:   0x{s:04X}  [{bits or 'all clear'}]")
        if not s & (1 << 9):
            out.append("               change_n LOW -> disk-change latched (no disk / ejected)")

    if 0x03 in d:
        sync = d[0x03]
        tag = " (standard)" if sync == 0x4489 else \
              " (0 = free-run!)" if sync == 0 else " (custom - trackloader?)"
        out.append(f"DSKSYNC:       0x{sync:04X}{tag}")

    if 0x04 in d:
        est = d[0x04]
        cyc = est / 16.0
        dev = (cyc - 100.0)
        tag = "  <- parked EXACTLY at nominal (chain reset / just re-seeded)" \
            if est == NOMINAL_EST_Q else f"  ({dev:+.2f} cyc = {dev:+.2f}% vs nominal)"
        out.append(f"half-cell est: 0x{est:04X} = {cyc:.2f} cycles{tag}")

    if 0x05 in d:
        out.append(f"FIFO level:    {d[0x05]}")

    if have(0x06, 0x07):
        period = (d[0x07] << 16) | d[0x06]
        if period:
            rpm = 60.0 * CLK_HZ / period
            out.append(f"index period:  {period} cyc = {period / CLK_HZ * 1e3:.2f} ms"
                       f" -> {rpm:.1f} RPM"
                       + ("" if 290 <= rpm <= 310 else "  !! outside 290..310")
                       + ("" if 295 <= rpm <= 306 else
                          "  (period spans deselect gating? only trustworthy"
                          " during continuous selection)" if 250 <= rpm <= 340 else ""))
        else:
            out.append("index period:  0 (no two accepted edges yet)")
    if have(0x08, 0x09):
        width = (d[0x09] << 16) | d[0x08]
        if width:
            ms = width / CLK_HZ * 1e3
            out.append(f"index width:   {width} cyc = {ms:.2f} ms"
                       + ("" if 1.0 <= ms <= 6.0 else "  !! outside 1..6 ms"))

    for reg, _w, name in COUNTER_REGS:
        if reg in d:
            out.append(f"cnt {name:<13s} (0x{reg:02X}): {d[reg]:5d} (0x{d[reg]:04X})")

    if 0x10 in d:
        v = d[0x10]
        out.append(f"drive map:     phys_en={v & 1} phys_unit=df{(v >> 1) & 3}:")

    # ---- sector-header capture -------------------------------------------
    if 0x11 in d:
        f = d[0x11]
        out.append(f"cap flags:     valid={f & 1} side_at_hit={'head0' if f & 2 else 'head1'}"
                   f" trk0_n={(f >> 2) & 1} side_live={'head0' if f & 8 else 'head1'}"
                   f" side_invert={(f >> 4) & 1}")
        if (f >> 4) & 1:
            out.append("!! side-invert (0x1F) is set - the side mapping is "
                       "correct as wired, so this must be 0")
    if have(*range(0x13, 0x17)):
        words = [d[r] for r in range(0x13, 0x1B) if r in d]
        info, lines = decode_info_words(words[:4], "capture")
        out += lines
        trk = (info >> 16) & 0xFF
        if 0x11 in d and (info >> 24) & 0xFF == 0xFF:
            side_head0 = bool(d[0x11] & 2)
            if (trk % 2 == 0) != side_head0:
                out.append("  !! capture track parity does NOT match the SIDE flag "
                           "(side-mapping alarm - the mapping is correct as "
                           "wired, so suspect the capture)")
            else:
                out.append("  side mapping consistent (track parity == SIDE flag)")
        viols = mfm_clock_violations(words[:4], prev_data_bit=1)
        if any(viols):
            out.append(f"  clock-rule violations per capture word: {viols} "
                       f"(0 expected after a true sync; nonzero = wrong bit "
                       f"phase or flux misdecode)")
        else:
            out.append("  clock bits legal in all 4 info words")

    # ---- per-revolution scoreboard ---------------------------------------
    if 0x1C in d:
        mask = d[0x1C] & 0x7FF
        missing = [s for s in range(11) if not mask & (1 << s)]
        out.append(f"last-rev mask: 0x{mask:04X} "
                   + ("= all 11 sectors" if mask == 0x7FF
                      else f"-> MISSING sectors {missing}"))
    if 0x1D in d:
        caps, lol = d[0x1D] >> 8, d[0x1D] & 0xFF
        tag = ""
        if lol >= 8:
            tag = "  !! LOL storm regime (shedding texture, or a SEEK phase)"
        elif caps < 11 and lol <= 1:
            tag = "  <- peak-shift texture: sectors missing WITHOUT LOL"
        if caps > 11:
            tag += "  !! >11 captures/rev = false syncs or seek crossings"
        out.append(f"last-rev:      {caps} captures, {lol} LOL{tag}")

    # ---- channel signature pairs -----------------------------------------
    if have(0x20, 0x22):
        eq = d[0x20] == d[0x22]
        out.append(f"sig pair:      engine 0x{d[0x20]:04X} vs Paula 0x{d[0x22]:04X}"
                   f"  {'EQUAL (channel word-exact)' if eq else '!! DIFFERENT'}")
    if have(0x24, 0x26):
        out.append(f"ckpt @64:      engine 0x{d[0x24]:04X} vs Paula 0x{d[0x26]:04X}"
                   f"  {'EQUAL' if d[0x24] == d[0x26] else '!! DIFFERENT'}")
    if have(0x25, 0x27):
        out.append(f"ckpt @256:     engine 0x{d[0x25]:04X} vs Paula 0x{d[0x27]:04X}"
                   f"  {'EQUAL' if d[0x25] == d[0x27] else '!! DIFFERENT'}")
    if 0x21 in d:
        out.append(f"engine:        sessions={d[0x21] & 0xFF} sig_done={(d[0x21] >> 8) & 1}")
    if 0x23 in d:
        out.append(f"Paula:         attempts={d[0x23] & 0xFF} "
                   f"WORDSYNC={'1' if d[0x23] & 0x100 else '0 (stores from first served word)'}"
                   f"  (attempts count ADF-unit reads too - only deltas over a"
                   f" physical-only workload pair 1:1 with sessions)")

    # ---- diag map v7: freshness, workload, margins ------------------------
    if have(0x30, 0x31):
        up = (d[0x31] << 16) | d[0x30]
        out.append(f"uptime:        {up} ms = {up / 1000.0:.1f} s since QNICE reset")
    if 0x32 in d:
        out.append(f"dump nonce:    {d[0x32]} (reads of reg 0x00 = dumps taken)")
    if 0x33 in d:
        out.append(f"cnt steps:     {d[0x33]}")
    if 0x34 in d:
        out.append(f"head cylinder: {d[0x34]} (stepdir-integrated, /TRK0-referenced)")
    if 0x35 in d:
        c = d[0x35]
        mode = "ALL gaps" if c & 0x20 else "serve-gated"
        win = f", window armed on sector {c & 0xF}" if c & 0x10 else ""
        sep = ""
        if d.get(0x01, 0) >= 0x0009:
            sep = ", separator: " + ("LEGACY quantiser" if c & 0x40 else "DPLL")
        if d.get(0x01, 0) >= 0x000A:
            sep += ", framing: " + ("realign-ALWAYS (A/B arm without the hold)"
                                    if c & 0x80 else "WORDSYNC-conditional hold")
        if d.get(0x01, 0) >= 0x000C:
            sep += ", DSKBYTR obs: " + ("OFF (constant stub - Copylock hangs)"
                                        if c & 0x100 else "ON (Copylock fix)")
        out.append(f"margin ctrl:   0x{c:04X} ({mode}{win}{sep})")
    if 0x5F in d and d.get(0x01, 0) >= 0x0009:
        cell = d[0x5F]
        out.append(f"DPLL cell:     0x{cell:04X} = {cell / 16.0:.2f} cycles"
                   + ("  <- parked at nominal (chain reset)"
                      if cell == NOMINAL_EST_Q else
                      f"  ({(cell / 16.0 - 100.0):+.2f} vs nominal)"))
    if d.get(0x01, 0) >= 0x000A:
        # Map 0x000A only: its capture path follows the served framing, so
        # with the framing hold active (ctrl bit 7 = 0, the default) the
        # capture-based instruments decode misframed words once a serve has
        # crossed the splice. From 0x000B on the captures follow the
        # sync-anchored diagnostic stream and are trustworthy in both
        # framing modes.
        if d.get(0x01, 0) == 0x000A and (d.get(0x35, 0) & 0x80) == 0:
            out.append("!! map 0x000A hold-mode dump: rev mask/caps (0x1C/0x1D), "
                       "fmt_bad (0x1E), header captures (0x11..0x1A), the "
                       "miss profile (0x58..0x5E) and the armed-sector "
                       "window are unreliable for reads in this mode "
                       "(capture path decodes misframed words after the "
                       "splice) - judge only the outcome, the seam "
                       "instruments 0x60..0x6C and 0x6E")
        if 0x60 in d:
            out.append(f"seam realigns: {d[0x60]} mid-serve sync matches at a "
                       "mid-word bit phase (the sync-seam events; taken when "
                       "framing is realign-always, suppressed under the hold)")
        if 0x61 in d and d.get(0x60, 0) != 0:
            out.append(f"seam context:  last bit phase {d[0x61] & 0xF}, "
                       f"odd-phase events {(d[0x61] >> 8) & 0xFF}")
        if all(r in d for r in range(0x62, 0x6A)) and d.get(0x60, 0) != 0:
            words = " ".join(f"{d[r]:04X}" for r in range(0x62, 0x6A))
            out.append(f"pre-seam tap:  {words} (the 8 words served before "
                       "the last seam event - expect [gap run][hybrid])")
        if 0x6A in d:
            sec = d[0x6A] & 0xFF
            ses = (d[0x6A] >> 8) & 0xFF
            out.append(f"serve start:   "
                       + ("none yet" if sec == 0xFF else f"sector {sec}")
                       + f" (session count {ses}; escape needs the "
                       "first-written sector = SG 11)")
        if 0x6B in d and 0x6C in d:
            out.append(f"LOL split:     {d[0x6B]} while streaming / "
                       f"{d[0x6C]} idle (since clear)")
        if 0x6D in d:
            out.append(f"chain windows: {d[0x6D]} index windows met the "
                       "capture floor but lost the chain (deselect hole; "
                       "excluded from the miss profile since v10)")
        if 0x6E in d:
            f = d[0x6E]
            out.append(f"framing live:  hold={'ON' if f & 1 else 'off'} "
                       f"wordsync={'1' if f & 2 else '0'} "
                       f"streaming={'1' if f & 4 else '0'} "
                       f"ctrl-bit7={'1' if f & 8 else '0'}")
    if 0x36 in d:
        if d[0x36] == 0xFFFF:
            out.append("min margin:    none measured yet (no gated gap since clear)")
        else:
            mm = d[0x36] / 16.0
            line = f"min margin:    {mm:.2f} cycles to the acceptance edge"
            if have(0x37, 0x38, 0x39):
                cls = ["short", "medium", "long", "-"][d[0x39] & 3]
                line += (f" ({cls} gap of {d[0x38]} cyc measured, "
                         f"est {d[0x37] / 16.0:.2f})")
            out.append(line)
            if mm < 6:
                out.append("  !! margin under 6 cycles - gaps are reaching the "
                           "classification boundaries")
    if 0x39 in d:
        s = d[0x39]
        out.append(f"margin status: win_open={(s >> 2) & 1} serving={(s >> 3) & 1} "
                   f"gate={(s >> 4) & 1}")
    parts = []
    for reg, name in ((0x3A, "win_opens"), (0x3B, "gaps"), (0x3C, "LOL-in-gate"),
                      (0x3D, "syncs-in-gate"), (0x5E, "qual_revs")):
        if reg in d:
            parts.append(f"{name}={d[reg]}")
    if parts:
        out.append("margin counts: " + " ".join(parts))
    if have(0x3E, 0x3F):
        out.append(f"est excursion: {d[0x3E] / 16.0:.2f} .. {d[0x3F] / 16.0:.2f} "
                   f"cycles since clear"
                   + ("" if d[0x3F] - d[0x3E] < 64
                      else "  !! excursion > 4 cycles = heavy drag or speed wander"))
    if all(r in d for r in range(0x40, 0x58)):
        tol16 = (d.get(0x3E, NOMINAL_EST_Q) + d.get(0x3F, NOMINAL_EST_Q)) / 4.0
        out.append("margin histograms (signed e in bins of tol/4; healthy = "
                   "mass in bins 3/4):")
        for ci, cname in enumerate(("short ", "medium", "long  ")):
            bins = [d[0x40 + ci * 8 + k] for k in range(8)]
            n = sum(bins)
            if n == 0:
                out.append(f"  {cname}: (empty)")
                continue
            com = sum(b * (k - 3.5) for k, b in enumerate(bins)) / n
            bias = com * tol16 / 4.0 / 16.0
            tails = bins[0] + bins[7]
            line = (f"  {cname}: " + " ".join(f"{b:5d}" for b in bins)
                    + f"  (n={n}, bias {bias:+.2f} cyc")
            if tails:
                line += f", TAIL MASS {tails} = {100.0 * tails / n:.1f}%"
            out.append(line + ")")
        biases = []
        for ci in range(3):
            bins = [d[0x40 + ci * 8 + k] for k in range(8)]
            n = sum(bins)
            if n:
                biases.append(sum(b * (k - 3.5) for k, b in enumerate(bins)) / n)
        # a perfectly centered class quantizes to bin 4 alone = com +0.5,
        # so "centered" tolerates up to 0.75 bins of quantization offset
        if len(biases) == 3 and abs(biases[0]) < 0.75 and (biases[1] > 1 or biases[2] > 1):
            out.append("  -> short centered but medium/long offset HIGH = the "
                       "short-gap-bias/est-drag signature")
    if all(r in d for r in range(0x58, 0x5E)) and 0x5E in d:
        miss = []
        for i in range(5):
            miss.append(d[0x58 + i] & 0xFF)
            miss.append(d[0x58 + i] >> 8)
        miss.append(d[0x5D] & 0xFF)
        q = d[0x5E]
        if any(miss):
            out.append(f"miss profile ({q} qualified revs): "
                       + " ".join(f"s{s}:{m}" for s, m in enumerate(miss) if m))
            hot = [s for s, m in enumerate(miss) if m and q and m / max(q, 1) > 0.5]
            if hot:
                out.append(f"  -> sectors {hot} miss in >50% of read revolutions "
                           f"= LOCALIZED failure spot")
            elif q >= 10 and sum(miss) >= 5:
                out.append("  -> misses spread across sectors = statistical "
                           "margin failure, not one physical spot")
        elif q:
            out.append(f"miss profile:  clean ({q} qualified revs, no missing "
                       f"sectors)")

    # ---- diag map 0x000D: the write instruments ---------------------------
    if d.get(0x01, 0) >= 0x000D and 0x70 in d:
        out.append("--- WRITE (diag map 0x000D) " + "-" * 33)
        out.append(f"episodes:      {d[0x70]} bound"
                   + (f", {d[0x7A]} opened WGATE" if 0x7A in d else ""))
        if 0x7A in d and d[0x70] and d[0x7A] == 0:
            out.append("               !! episodes ran but the gate NEVER "
                       "opened - write-protected tab, an unqualified "
                       "10 ms accumulator, or a lost gate term")
        if 0x71 in d and 0x72 in d:
            out.append(f"words:         {d[0x71]} last episode, {d[0x72]} total")
        if 0x73 in d and 0x74 in d:
            cyc = (d[0x74] << 16) | d[0x73]
            words = cyc / 1600.0
            out.append(f"WGATE window:  {cyc} cycles = {cyc / 50000.0:.2f} ms "
                       f"= {words:.2f} words x 16 cells")
            if 0x71 in d and d[0x71]:
                if abs(words - d[0x71]) < 0.01:
                    out.append("               window == words x 16 x 100 "
                               "EXACTLY (no lead-in/lead-out cells)")
                else:
                    out.append(f"               !! window is {words:.2f} "
                               f"words but {d[0x71]} were consumed - the "
                               f"tail was cut, or lead cells crept in")
        if 0x77 in d:
            inflt, cut = d[0x77] >> 8, d[0x77] & 0xFF
            out.append(f"tail:          max {inflt} word(s) in flight at "
                       f"DSKBLK, {cut} tail-cut(s)")
            if inflt > 3:
                out.append("               !! more than 3 words in flight - "
                           "the pipe is deeper than real-Amiga scale")
        for reg, name, bad in ((0x75, "underrun aborts", True),
                               (0x76, "tab-blocked episodes", False),
                               (0x7D, "CDC FIFO overflows", True)):
            if reg in d:
                line = f"cnt {name:<22s} (0x{reg:02X}): {d[reg]}"
                if bad and d[reg]:
                    line += "   !! MUST BE 0"
                out.append(line)
        if 0x78 in d:
            out.append(f"precomp:       {d[0x78]} shifted pulse(s) last episode")
        if 0x79 in d:
            fl, trk = d[0x79] >> 8, d[0x79] & 0xFF
            names = [n for b, n in ((0, "completed"), (1, "aborted"),
                                    (2, "discard"), (3, "underrun"),
                                    (4, "tail-cut")) if fl & (1 << b)]
            out.append(f"last episode:  track {trk} (cyl {trk // 2} head "
                       f"{trk % 2}), flags: {', '.join(names) or 'none'}")
        if 0x7B in d and d[0x7B]:
            rs = [n for b, n in ((0, "deselect"), (1, "motor/enable"),
                                 (2, "wprot"), (3, "disk change"),
                                 (4, "step"), (5, "side"), (6, "underrun"),
                                 (7, "engine abort"))
                  if d[0x7B] & (1 << b)]
            out.append(f"abort reason:  {', '.join(rs)}")
        if 0x7C in d:
            c = d[0x7C]
            mode = ["AUTO", "ON", "OFF", "AUTO"][c & 3]
            out.append(f"write ctrl:    precomp mode {mode}, active now "
                       f"{(c >> 2) & 1}, wr_ok (tab qualified) {(c >> 3) & 1}, "
                       f"episode open {(c >> 4) & 1}")
            if not (c >> 3) & 1:
                out.append("               (wr_ok 0 = the tab reads PROTECTED "
                           "or the 10 ms selected-time qualifier has not run "
                           "yet - no write can open the gate)")

    # ---- Paula store tap --------------------------------------------------
    tap = [d[r] for r in range(0x28, 0x30) if r in d]
    if len(tap) == 8:
        sync = d.get(0x03, 0x4489)
        out.append("Paula tap:     " + " ".join(f"{w:04X}" for w in tap))
        lead = 0
        while lead < len(tap) and tap[lead] == sync and sync != 0:
            lead += 1
        if lead == 0:
            out.append(f"  !! tap does NOT start with the sync word 0x{sync:04X} "
                       f"- serve-from-sync violated, or free-phase junk")
        else:
            out.append(f"  starts with {lead}x sync 0x{sync:04X} (serve-from-sync OK)")
            if len(tap) - lead >= 4:
                _, lines = decode_info_words(tap[lead:lead + 4], "tap header")
                out += lines
    elif tap:
        out.append(f"Paula tap:     partial ({len(tap)}/8 words) - not decoded")

    return out


# --------------------------------------------------------------------------
# Cross-snapshot deltas
# --------------------------------------------------------------------------

def delta(a, b, bits):
    return (b - a) % (1 << bits)


def wrap_ratio(num_d, denom, per_unit, tolerance):
    """Wrap-correct a 16-bit counter delta against an expected per-unit rate:
    among feasible candidates num_d + k*65536 (bounded by denom*(per_unit +
    tolerance)), return (ratio, k) nearest the expectation. A dead counter
    (num_d == 0 and no feasible wrap) honestly returns 0.0."""
    if denom == 0:
        return None, 0
    limit = denom * (per_unit + tolerance)
    best = None
    k = 0
    while True:
        cand = num_d + k * 65536
        if k > 0 and cand > limit:
            break
        ratio = cand / denom
        if best is None or abs(ratio - per_unit) < abs(best[0] - per_unit):
            best = (ratio, k)
        k += 1
    return best


def served_per_attempt(served_d, att_d):
    return wrap_ratio(served_d, att_d, WORDS_PER_ATTEMPT, 400)


def snap_key(d):
    """Byte-identity key over every register of a snapshot."""
    return tuple(sorted(d.items()))


def cross_dump(snaps):
    """snaps: list of (title, {reg: value}, dump_index). Alias halves of the
    same dump share dump_index; the hard duplicated-capture / stale-counter
    verdicts only apply across different dumps."""
    out = ["===== cross-dump analysis " + "=" * 40]

    # duplicated-capture check: same dump content appearing as separate dumps
    by_dump = {}
    for title, d, di in snaps:
        by_dump.setdefault(di, []).append((title, d))
    dump_ids = sorted(by_dump)
    for i in range(len(dump_ids) - 1):
        a_id, b_id = dump_ids[i], dump_ids[i + 1]
        a_all = [snap_key(d) for _t, d in by_dump[a_id]]
        b_all = [snap_key(d) for _t, d in by_dump[b_id]]
        if a_all == b_all and a_all:
            out.append(f"!! dumps {a_id + 1} and {b_id + 1} are BYTE-IDENTICAL "
                       f"including their alias re-reads - physically the SAME "
                       f"capture (duplicated by the dump procedure), NOT two "
                       f"observations. Treat as one data point.")

    # map 0x0007+: uptime/nonce make the duplicate question definitive
    for i in range(len(dump_ids) - 1):
        a = by_dump[dump_ids[i]][0][1]
        b = by_dump[dump_ids[i + 1]][0][1]
        if all(r in a and r in b for r in (0x30, 0x31)):
            ua = (a[0x31] << 16) | a[0x30]
            ub = (b[0x31] << 16) | b[0x30]
            if ua == ub:
                out.append(f"!! dumps {dump_ids[i] + 1}/{dump_ids[i + 1] + 1}: "
                           f"IDENTICAL uptime ({ua} ms) - definitively the "
                           f"same capture.")
            elif ub < ua:
                out.append(f"[dumps {dump_ids[i] + 1}/{dump_ids[i + 1] + 1}] "
                           f"uptime went backward ({ua} -> {ub} ms) = power "
                           f"cycle / new session between them.")
            else:
                out.append(f"[dumps {dump_ids[i] + 1}/{dump_ids[i + 1] + 1}] "
                           f"fresh: {(ub - ua) / 1000.0:.1f} s apart"
                           + (f", {delta(a[0x32], b[0x32], 16)} dump(s) in "
                              f"between" if 0x32 in a and 0x32 in b else ""))

    pairs = list(zip(snaps[:-1], snaps[1:]))

    for i, ((ta, a, da), (tb, b, db)) in enumerate(pairs):
        label = f"{ta or 'dump ' + str(da + 1)} -> {tb or 'dump ' + str(db + 1)}"
        same_dump = da == db
        moved, seen = [], []
        for reg, bits, name in MOVING_COUNTERS:
            if reg in a and reg in b:
                seen.append(name)
                if delta(a[reg], b[reg], bits):
                    moved.append(name)
        for reg, name, bits in ((0x21, "sessions", 8), (0x23, "attempts", 8)):
            if reg in a and reg in b:
                seen.append(name)
                if delta(a[reg] & 0xFF, b[reg] & 0xFF, bits):
                    moved.append(name)
        if seen and not moved:
            if same_dump:
                out.append(f"[{label}] counters frozen between the two halves "
                           f"of one dump = no drive activity during the dump "
                           f"itself (normal for an idle dump).")
            else:
                out.append(f"!! [{label}] NO free-running counter moved "
                           f"({', '.join(seen)}) - duplicated capture, stale "
                           f"instrument, or genuinely no drive activity. "
                           f"Decide before trusting anything else.")
        elif seen:
            out.append(f"[{label}] counters moving: {', '.join(moved)}")
        if 0x02 in a and 0x02 in b and a[0x02] != b[0x02]:
            changed = [n for bit, n in STATUS_BITS
                       if (a[0x02] ^ b[0x02]) & (1 << bit)]
            out.append(f"[{label}] status changed: {', '.join(changed)}")

    for i, ((ta, a, da), (tb, b, db)) in enumerate(pairs):
        label = f"{ta or 'dump ' + str(da + 1)} -> {tb or 'dump ' + str(db + 1)}"
        deltas = []
        for reg, bits, name in COUNTER_REGS:
            if reg in a and reg in b:
                d16 = delta(a[reg], b[reg], bits)
                if d16:
                    deltas.append(f"  {name:<14s} +{d16}")
        if not deltas and da == db:
            continue
        out.append(f"--- deltas {label} ---")
        backwards = sum(1 for reg, bits, _n in COUNTER_REGS
                        if reg in a and reg in b
                        and delta(a[reg], b[reg], bits) > 0x8000)
        if backwards >= 3:
            out.append(f"  !! {backwards} counters jumped backward/huge - "
                       f"likely a power cycle or different session between "
                       f"these dumps; the deltas below are meaningless")
        out += deltas
        ses_d = att_d = None
        if 0x21 in a and 0x21 in b:
            ses_d = delta(a[0x21] & 0xFF, b[0x21] & 0xFF, 8)
            if ses_d:
                out.append(f"  sessions       +{ses_d}")
        if 0x23 in a and 0x23 in b:
            att_d = delta(a[0x23] & 0xFF, b[0x23] & 0xFF, 8)
            if att_d:
                out.append(f"  attempts       +{att_d}")
        if ses_d is not None and att_d is not None and (ses_d or att_d):
            out.append(f"  sessions==attempts pairing: "
                       + ("1:1 OK" if ses_d == att_d else
                          f"({ses_d} vs {att_d} - unequal is EXPECTED when ADF"
                          f" units were also read; equal deltas only on a"
                          f" physical-only workload)"))
        if att_d and 0x1B in a and 0x1B in b:
            srv_d = delta(a[0x1B], b[0x1B], 16)
            ratio, k = served_per_attempt(srv_d, att_d)
            wrap = f" (raw +{srv_d}, +{k} wrap{'s' if k != 1 else ''} assumed)" if k else ""
            if ratio < 100:
                flag = ("  !! served counter did not advance -> never-armed/"
                        "never-served regime")
            elif abs(ratio - WORDS_PER_ATTEMPT) < 50:
                flag = ""
            else:
                flag = f"  !! off the {WORDS_PER_ATTEMPT}.0 metronomic standard"
            out.append(f"  served/attempt {ratio:.1f}{wrap}{flag}")
            if att_d > 8:
                out.append(f"    (attempts {att_d} > 8: the 16-bit served counter "
                           f"wrapped - ratio is wrap-corrected, treat as approximate)")
        if 0x0A in a and 0x0A in b:
            idx_d = delta(a[0x0A], b[0x0A], 16)
            if idx_d:
                for reg, name, rate, tol in ((0x12, "captures/rev", 11, 6),
                                             (0x0E, "LOL/rev", 1, 300),
                                             (0x0C, "words/rev", WORDS_PER_REV, 500)):
                    if reg in a and reg in b:
                        n_d = delta(a[reg], b[reg], 16)
                        if reg == 0x0C:
                            r, k = wrap_ratio(n_d, idx_d, rate, tol)
                            wraptxt = (f" (+{k} wraps assumed, approximate)"
                                       if k else "")
                        else:
                            r, wraptxt = n_d / idx_d, ""
                        note = ""
                        if name == "LOL/rev":
                            note = ("  (splice-only baseline ~0.6)" if r < 2
                                    else "  !! storm regime (8+ = shedding or seeks)")
                        if name == "captures/rev":
                            note = "  (healthy formatted track = 11.0)"
                        out.append(f"  {name:<14s} {r:.2f}{wraptxt}{note}")
    return out


# --------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------

def selftest():
    fails = []

    def check(name, cond):
        print(("PASS  " if cond else "FAIL  ") + name)
        if not cond:
            fails.append(name)

    # 1) golden vector (a real track 0 sector 2 header): info 0xFF000207
    #    round-trips, clocks legal
    words = mfm_encode_long(0xFF000207, prev_data_bit=1)
    check("encode->decode round-trip 0xFF000207",
          mfm_decode_long(*words) == 0xFF000207)
    check("encoded info words have legal clocks",
          mfm_clock_violations(words, prev_data_bit=1) == [0, 0, 0, 0])
    check("0x4489 shows the single missing-clock violation",
          mfm_clock_violations([0x4489], prev_data_bit=1) == [1])
    info80 = (0xFF << 24) | (80 << 16) | (1 << 8) | 10
    w80 = mfm_encode_long(info80, 1)
    check("track-80 vector decodes to cyl 40 head 0",
          (mfm_decode_long(*w80) >> 16) & 0xFF == 80)

    # 2) parser: three formats, three dumps
    text = """
    7000: FDD0 0006 079D 4489 0640
    0x7010: 0001
    --- second dump ---
    0x00 = 0xFDD0
    0x1B = 0x1234
    dump three
    FDD0 0006
    """
    dumps, warn = parse_dumps(text)
    check("parser finds 3 dumps", len(dumps) == 3)
    check("monitor-style line lands words at 0..4",
          dumps[0].get(0x02) == 0x079D and dumps[0].get(0x04) == 0x0640)
    check("register-relative style", dumps[1].get(0x1B) == 0x1234)
    check("bare-word style", dumps[2].get(0x01) == 0x0006)
    check("re-appearing address splits dumps",
          len(parse_dumps("0x00 = 1111\n0x00 = 2222")[0]) == 2)

    # 2b) overlap at a non-first register splits too
    dumps, _ = parse_dumps("0x02 = 0x1111\n0001: 2222 3333")
    check("multi-word overlap at non-first register splits dumps",
          len(dumps) == 2 and dumps[0][2] == 0x1111 and dumps[1][2] == 0x3333)
    # 2c) trailing prose never becomes register data
    dumps, warn = parse_dumps("7006: 5A01 0098 -> 300.5 RPM measured")
    check("trailing prose warned about, not parsed",
          dumps[0] == {6: 0x5A01, 7: 0x0098} and any("non-hex" in w for w in warn))
    dumps, warn = parse_dumps("0x1D = 0x0901  (9 caps, 1 lol)")
    check("parenthetical annotation not injected",
          dumps[0] == {0x1D: 0x0901})
    # 2d) 5+ digit hex tokens rejected loudly, not truncated
    dumps, warn = parse_dumps("0x00 = 0x12345")
    check("5-digit hex token rejected with warning",
          (not dumps or 0 not in dumps[0]) and any("4 digits" in w for w in warn))

    # 3) served/attempt wrap correction incl. feasibility
    srv = (11 * WORDS_PER_ATTEMPT) % 65536
    ratio, k = served_per_attempt(srv, 11)
    check("served/attempt wrap-corrects to 7358.0",
          abs(ratio - WORDS_PER_ATTEMPT) < 0.01 and k == 1)
    ratio, k = served_per_attempt(3 * WORDS_PER_ATTEMPT, 3)
    check("served/attempt exact without wrap",
          ratio == WORDS_PER_ATTEMPT and k == 0)
    ratio, k = served_per_attempt(0, 8)
    check("dead served counter reads 0.0, not a phantom wrap",
          ratio == 0.0 and k == 0)

    # 4) alias folding: a 0x7000..0x707F v6 dump becomes two snapshots
    text = ("7000: FDD0 0006 07BD 4489\n7040: FDD0 0006 07A1 4489\n")
    snaps = normalize_dumps(parse_dumps(text)[0])
    check("v6 wide dump folds into 2 snapshots",
          len(snaps) == 2 and snaps[0][1][2] == 0x07BD
          and snaps[1][1][2] == 0x07A1 and "alias" in snaps[1][0])
    check("alias halves share the dump index",
          snaps[0][2] == snaps[1][2])
    # EEEE filler at 0x30+ dropped in v6
    snaps = normalize_dumps(parse_dumps("7000: FDD0 0006\n7030: EEEE EEEE")[0])
    check("v6 filler regs dropped", 0x30 not in snaps[0][1])

    # 5) stale/duplicate verdicts
    a = {r: 0x100 for r, _b, _n in MOVING_COUNTERS}
    a[0x21] = a[0x23] = 5
    txt = "\n".join(cross_dump([("", a, 0), ("", dict(a), 1)]))
    check("stale instrument detected across dumps",
          "NO free-running counter moved" in txt)
    check("byte-identical dumps called duplicated capture",
          "BYTE-IDENTICAL" in txt)
    txt = "\n".join(cross_dump([("", a, 0), (" (alias re-read 1)", dict(a), 0)]))
    check("frozen alias pair reported as normal idle",
          "normal for an idle dump" in txt and "BYTE-IDENTICAL" not in txt)
    b = dict(a)
    b[0x1B] = (b[0x1B] + 7358) % 65536
    b[0x23] = 6
    b[0x21] = 6
    txt = "\n".join(cross_dump([("", a, 0), ("", b, 1)]))
    check("moving counters pass the stale check", "counters moving" in txt)
    check("pairing check OK in moving case", "1:1 OK" in txt)

    # 6) words/rev wrap correction
    a2 = {0x0A: 0, 0x0C: 0}
    b2 = {0x0A: 20, 0x0C: (20 * WORDS_PER_REV) % 65536}
    txt = "\n".join(cross_dump([("", a2, 0), ("", b2, 1)]))
    check("words/rev wrap-corrected near 6250",
          "words/rev" in txt and "6250.00" in txt and "wraps assumed" in txt)

    # 7) full decode of a synthetic idle dump with a realistic texture
    cap = mfm_encode_long((0xFF << 24) | (80 << 16) | (6 << 8) | 5, 1)
    d = {0x00: 0xFDD0, 0x01: 0x0006, 0x02: 0x079D, 0x03: 0x4489,
         0x04: 0x63E, 0x05: 0, 0x06: 9_983_361 & 0xFFFF,
         0x07: 9_983_361 >> 16, 0x08: 150_000 & 0xFFFF, 0x09: 150_000 >> 16,
         0x0A: 100, 0x0B: 1100, 0x0C: 40000, 0x0D: 0, 0x0E: 60, 0x0F: 0,
         0x10: 0x05, 0x11: 0x03, 0x12: 1100,
         0x13: cap[0], 0x14: cap[1], 0x15: cap[2], 0x16: cap[3],
         0x17: 0xAAAA, 0x18: 0xAAAA, 0x19: 0xAAAA, 0x1A: 0xAAAA,
         0x1B: 0x3C2A, 0x1C: 0x07F9, 0x1D: 0x0901, 0x1E: 2, 0x1F: 0,
         0x20: 0xE976, 0x21: 0x0114, 0x22: 0xE976, 0x23: 0x0014,
         0x24: 0x1111, 0x25: 0x2222, 0x26: 0x1111, 0x27: 0x2222,
         0x28: 0x4489, 0x29: 0x4489}
    d.update({0x2A + i: w for i, w in enumerate(cap[:4])})
    d[0x2E], d[0x2F] = 0xAAAA, 0xAAAA
    txt = "\n".join(decode_dump(d, "dump 1"))
    check("RPM decoded (300.5)", "300.5 RPM" in txt)
    check("sig pair equal detected", "EQUAL (channel word-exact)" in txt)
    check("missing sectors listed", "MISSING sectors [1, 2]" in txt)
    check("peak-shift texture flagged", "peak-shift texture" in txt)
    check("tap sync-first detected", "serve-from-sync OK" in txt)
    check("tap header decoded to track 80", "track 80 (cyl 40 head 0)" in txt)
    check("capture side consistency checked", "side mapping consistent" in txt)
    check("wordsync=0 reported", "WORDSYNC=0" in txt)

    d2 = dict(d)
    d2[0x28] = 0xA4A5
    txt = "\n".join(decode_dump(d2, "dump 1"))
    check("junk-phase tap flagged", "does NOT start with the sync word" in txt)

    # 8) diag map v7 decode
    d7 = {0x00: 0xFDD0, 0x01: 0x0007, 0x30: 45000 & 0xFFFF, 0x31: 0,
          0x32: 3, 0x33: 160, 0x34: 40, 0x35: 0x0000,
          0x36: 144, 0x37: 0x640, 0x38: 259, 0x39: 0x0009,
          0x3A: 0, 0x3B: 69, 0x3C: 1, 0x3D: 0, 0x3E: 1592, 0x3F: 1600,
          0x5E: 20}
    for k in range(24):
        d7[0x40 + k] = 0
    d7[0x44] = 64          # short bin 4
    d7[0x4C + 2] = 30      # medium bin 6 (offset)
    d7[0x4C + 1] = 4
    d7[0x54 + 2] = 10      # long bin 6
    for i in range(6):
        d7[0x58 + i] = 0
    d7[0x59] = 0x1200      # sector 3 misses 18 of 20 revs (hi byte of 0x59)
    txt = "\n".join(decode_dump(d7, "v7"))
    check("v7 uptime decoded", "45000 ms" in txt)
    check("v7 min margin context", "9.00 cycles" in txt and "259 cyc" in txt)
    check("v7 est excursion", "99.50 .. 100.00" in txt)
    check("v7 bias signature detected", "est-drag signature" in txt)
    check("v7 miss profile localized", "s3:18" in txt and "LOCALIZED" in txt)
    # v7 alias folding: 128-word groups
    snaps = normalize_dumps([{0x01: 0x0007, 0x40: 5, 0x81: 0x0007, 0x80 + 0x40: 6}])
    check("v7 alias groups fold at 0x80",
          len(snaps) == 2 and snaps[0][1][0x40] == 5 and snaps[1][1][0x40] == 6)
    # map 0x0008 = same layout, recognized without warning
    txt = "\n".join(decode_dump({0x00: 0xFDD0, 0x01: 0x0008}, "v8"))
    check("map 0x0008 recognized",
          "registered readout" in txt and "unknown" not in txt)
    snaps = normalize_dumps([{0x01: 0x0008, 0x40: 7}])
    check("map 0x0008 uses v7 grouping", snaps[0][1][0x40] == 7)
    # map 0x0009: DPLL registers decoded, 0x5F is real now
    txt = "\n".join(decode_dump(
        {0x00: 0xFDD0, 0x01: 0x0009, 0x35: 0x0040, 0x5F: 0x611}, "v9"))
    check("map 0x0009 shows separator mode and DPLL cell",
          "LEGACY quantiser" in txt and "97.06 cycles" in txt)
    snaps = normalize_dumps([{0x01: 0x0009, 0x5F: 0x611}])
    check("map 0x0009 keeps reg 0x5F", 0x5F in snaps[0][1])
    # map 0x000A: seam instruments decoded, framing bit shown
    txt = "\n".join(decode_dump({0x00: 0xFDD0, 0x01: 0x000A, 0x35: 0x0080,
                                 0x60: 3, 0x61: 0x0201, 0x6A: 0x05FF,
                                 0x6B: 2, 0x6C: 7, 0x6D: 4, 0x6E: 0x0005},
                                "v10"))
    check("map 0x000A shows framing mode",
          "realign-ALWAYS" in txt and "seam realigns: 3" in txt)
    check("map 0x000A serve-start none", "none yet" in txt)
    check("map 0x000A LOL split", "2 while streaming / 7 idle" in txt)
    check("map 0x000A framing live", "hold=ON" in txt and "streaming=1" in txt)
    snaps = normalize_dumps([{0x01: 0x000A, 0x6E: 1}])
    check("map 0x000A keeps reg 0x6E", 0x6E in snaps[0][1])
    # 8b) diag map 0x000D: the write instruments
    dW = {0x00: 0xFDD0, 0x01: 0x000D, 0x70: 3, 0x71: 6815, 0x72: 20445,
          0x73: (6815 * 1600) & 0xFFFF, 0x74: (6815 * 1600) >> 16,
          0x75: 0, 0x76: 1, 0x77: 0x0300, 0x78: 412,
          0x79: 0x0128, 0x7A: 2, 0x7B: 0x00, 0x7C: 0x0C, 0x7D: 0}
    txt = "\n".join(decode_dump(dW, "vD"))
    check("map 0x000D recognized",
          "WIP-V2-A9" in txt and "unknown map version" not in txt)
    check("0x000D window == words x 16 x 100 verified",
          "EXACTLY" in txt)
    check("0x000D tail decoded", "max 3 word(s) in flight" in txt)
    check("0x000D last-episode flags decoded",
          "track 40" in txt and "completed" in txt)
    check("0x000D wr_ok reported", "wr_ok (tab qualified) 1" in txt)
    check("0x000D tab-blocked episode counted",
          "tab-blocked episodes" in txt)
    # a window that does not match the consumed words must be flagged
    dW2 = dict(dW); dW2[0x73] = (6813 * 1600) & 0xFFFF
    dW2[0x74] = (6813 * 1600) >> 16
    txt = "\n".join(decode_dump(dW2, "vD"))
    check("0x000D short window flagged", "the tail was cut" in txt)
    # the two must-be-zero counters
    dW3 = dict(dW); dW3[0x7D] = 4
    txt = "\n".join(decode_dump(dW3, "vD"))
    check("0x000D CDC overflow flagged", "MUST BE 0" in txt)
    # episodes that never opened the gate
    dW4 = dict(dW); dW4[0x7A] = 0
    txt = "\n".join(decode_dump(dW4, "vD"))
    check("0x000D gate-never-opened flagged", "gate NEVER" in txt)
    snaps = normalize_dumps([{0x01: 0x000D, 0x7D: 0}])
    check("map 0x000D keeps reg 0x7D", 0x7D in snaps[0][1])

    # the hold-mode caveat fires only on 0x000A hold-mode dumps
    txt = "\n".join(decode_dump({0x00: 0xFDD0, 0x01: 0x000A, 0x35: 0x0000},
                                "v10-hold"))
    check("map 0x000A hold-mode dump carries the caveat",
          "map 0x000A hold-mode dump" in txt)
    # map 0x000B: content = v10, captures sync-anchored
    txt = "\n".join(decode_dump({0x00: 0xFDD0, 0x01: 0x000B, 0x35: 0x0000,
                                 0x60: 3, 0x6B: 2, 0x6C: 7, 0x6E: 0x0005},
                                "v11"))
    check("map 0x000B recognized",
          "WIP-V2-A7" in txt and "unknown map version" not in txt)
    check("map 0x000B hold-mode dump has no caveat",
          "hold-mode dump" not in txt)
    check("map 0x000B decodes the seam instruments",
          "seam realigns: 3" in txt and "2 while streaming / 7 idle" in txt)
    snaps = normalize_dumps([{0x01: 0x000B, 0x6E: 1}])
    check("map 0x000B uses the v10 grouping", 0x6E in snaps[0][1])
    # map 0x0007+ freshness verdicts
    fa = {0x30: 1000, 0x31: 0, 0x32: 1}
    fb = {0x30: 9000, 0x31: 0, 0x32: 2}
    txt = "\n".join(cross_dump([("", fa, 0), ("", fb, 1)]))
    check("v7 fresh dumps reported", "8.0 s apart" in txt and "1 dump(s)" in txt)
    txt = "\n".join(cross_dump([("", fa, 0), ("", dict(fa), 1)]))
    check("v7 identical uptime = definitive duplicate",
          "definitively the same capture" in txt)
    txt = "\n".join(cross_dump([("", fb, 0), ("", fa, 1)]))
    check("v7 uptime backward = power cycle", "power cycle" in txt)

    print()
    if fails:
        print(f"SELF-TEST: {len(fails)} FAILURES")
        return 1
    print("SELF-TEST: ALL PASS")
    return 0


# --------------------------------------------------------------------------

def main(argv):
    if "--selftest" in argv:
        return selftest()
    if argv:
        text = "\n".join(open(f).read() for f in argv)
    else:
        text = sys.stdin.read()
    raw_dumps, warnings = parse_dumps(text)
    for w in warnings:
        print(f"[parser] {w}")
    snaps = normalize_dumps(raw_dumps)
    if not snaps:
        print("no dumps found in input")
        return 1
    titled = []
    for title, d, di in snaps:
        t = f"dump {di + 1}{title}"
        titled.append((t, d, di))
        print("\n".join(decode_dump(d, t)))
        print()
    if len(titled) > 1:
        print("\n".join(cross_dump(titled)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
