#!/usr/bin/env python3
"""td_check.py - independent Kickstart 1.3 trackdisk decode model and seam
analyser.

An independent reimplementation of the Kickstart 1.3 trackdisk.device read
decode; the testbench CORE/sim/floppy/tb_fdd_splice.vhd carries a second
one. Feed it a capture dump written by that testbench in G_DUMP mode
(splice_dump_att<N>.txt: a "# meta" header line, then
"<byte-offset> <hexword>" per line) and it:

  1. re-runs the full trackdisk decode (sync hunt with the 16 sync
     rotations, first-header checks, chunk-1 realign, the SG = 11 escape,
     the $67C gap re-hunt, chunk-2 realign at its own shift, the literal
     per-slot walk) with a per-step trace - its verdict must match the
     testbench checker's;
  2. maps the seam: the captured gap region between the last pre-gap
     sector and the first post-gap sync - word classes (AAAA/5555 run
     parity segments, irregular words), every 4489 word in the region
     (extra ones = aligner realigns on false window matches), the captured
     gap length in words, and the post-gap slot spacing (a spacing != $440
     reveals duplicated/lost words from mid-serve realignment).

td_write_check.py imports this module for its own trackdisk verdicts.

Usage: td_check.py <dumpfile> [more dumpfiles...]
"""

import sys

MASK = 0x55555555
SLOT = 0x440
NSEC = 11
DEC = 0x680          # decode destination (buffer + $680)
CAP = 0x684          # DMA capture start (buffer + $684)
HUNT1_LEN = 0xABC
HUNT2_LEN = 0x67C
DMA_WORDS = 7358


def sync_rot(k):
    """The long that ends a run of $AAAA/$5555 words when the word framing
    leaves k bits (0..15) of the $AAAA preamble in front of the sync pair
    $4489 $4489."""
    if k == 0:
        return 0x44894489
    return (((0xAAAA & ((1 << k) - 1)) << (32 - k)) | (0x44894489 >> k)) \
        & 0xFFFFFFFF


# the 16 sync-hunt patterns, compared in index order: odd table (run word
# $5555) entry e has k = 2e+1 and matches shift s = 15-2e; even table (run
# word $AAAA) entry e has k = 2e+2 and matches s = 14-2e, entry 7 being the
# plain $44894489 (k = 0, shift 0)
TBL_ODD = [sync_rot(2 * e + 1) for e in range(8)]
TBL_EVEN = [sync_rot((2 * e + 2) % 16) for e in range(8)]

TDERR = {0x15: "$15 no-sync", 0x16: "$16 preamble/sync", 0x17: "$17 sector id",
         0x18: "$18 header cksum", 0x19: "$19 data cksum",
         0x1A: "$1A gap re-hunt fail", 0x1B: "$1B first header bad"}


def word(buf, off):
    return (buf[off] << 8) | buf[off + 1]


def long_(buf, off):
    return (word(buf, off) << 16) | word(buf, off + 2)


def put_word(buf, off, w):
    buf[off] = (w >> 8) & 0xFF
    buf[off + 1] = w & 0xFF


def decode_pair(o, e):
    """Decode an odd/even MFM long pair."""
    return (((o & MASK) << 1) | (e & MASK)) & 0xFFFFFFFF


def ext32(buf, off, j):
    """32 bits at bit offset j of the 48 bits at off."""
    v = (long_(buf, off) << 16) | word(buf, off + 4)
    return (v >> (16 - j)) & 0xFFFFFFFF


def cksum(buf, off, nlongs, j=0):
    v = 0
    for i in range(nlongs):
        v ^= ext32(buf, off + 4 * i, j) if j else long_(buf, off + 4 * i)
    return v & MASK


def hunt(buf, start, length, trace):
    """The gap+sync hunt. Returns (ptr, srom) with ptr=-1 on failure."""
    a0, end = start, start + length
    while True:
        d2 = word(buf, a0)                       # next word
        a0 += 2
        if d2 == 0xAAAA:
            tbl, s0 = TBL_EVEN, 14
        elif d2 == 0x5555:
            tbl, s0 = TBL_ODD, 15
        else:
            if end > a0:                         # window not exhausted
                continue
            return -1, -1                        # fail
        # run skip
        while True:
            if end <= a0:                        # window exhausted
                trace.append(f"    window end inside a run at {a0:#x}")
                return -1, -1
            d1 = word(buf, a0)
            a0 += 2
            if d1 == d2:
                continue
            a0 -= 2                              # back to the run end
            dl = long_(buf, a0)
            hit = None
            for e in range(8):                   # 8 entries in order
                if dl == tbl[e]:
                    hit = s0 - 2 * e
                    break
            trace.append(f"    run({d2:04X}) ends at {a0:#x}: long "
                         f"{dl:08X} -> "
                         + (f"MATCH s={hit}" if hit is not None else "miss"))
            if hit is not None:
                return a0 - 4, hit
            break                                # resume the outer scan


def td_decode(buf, exp_track, out):
    """The per-attempt decode, trace lines appended to out. Returns the
    error code, or the first sector (< 11) on success."""
    trace = []
    p, s1 = hunt(buf, DEC + 2, HUNT1_LEN, trace)
    out += [f"  hunt1 from {DEC+2:#x} len {HUNT1_LEN:#x}:"] + trace
    if p < 0:
        out.append("  -> $15")
        return 0x15
    j = (16 - s1) % 16
    out.append(f"  anchor={p:#x} srom={s1} (bit offset j={j})")

    if s1 == 0:
        io, ie = long_(buf, p + 8), long_(buf, p + 12)
        ck = cksum(buf, p + 8, 10)
        st = decode_pair(long_(buf, p + 0x30), long_(buf, p + 0x34))
    else:
        io, ie = ext32(buf, p + 8, j), ext32(buf, p + 12, j)
        ck = cksum(buf, p + 8, 10, j)
        st = decode_pair(ext32(buf, p + 0x30, j), ext32(buf, p + 0x34, j))
    if ck != st:
        out.append(f"  first header cksum {ck:08X} != stored {st:08X} -> $1B")
        return 0x1B
    info = decode_pair(io, ie)
    fmt, trk, sec, sg = (info >> 24) & 0xFF, (info >> 16) & 0xFF, \
                        (info >> 8) & 0xFF, info & 0xFF
    out.append(f"  first header info={info:08X} fmt={fmt:02X} trk={trk} "
               f"sec={sec} SG={sg}")
    if fmt != 0xFF or trk != exp_track:
        out.append("  -> $1B")
        return 0x1B
    d4 = sg * SLOT

    # chunk 1 realign: bits j.. of src words -> DEC
    blit(buf, p, DEC, d4, j)

    if sg != 11:
        trace = []
        p2, s2 = hunt(buf, p + d4 + 2, HUNT2_LEN, trace)
        out += [f"  re-hunt from {p+d4+2:#x} len {HUNT2_LEN:#x}:"] + trace
        if p2 < 0:
            out.append("  -> $1A")
            return 0x1A
        j2 = (16 - s2) % 16
        out.append(f"  chunk2 anchor={p2:#x} srom={s2} (j={j2}); "
                   f"distance from expected gap start: {p2-(p+d4)} bytes")
        blit(buf, p2, DEC + d4, (NSEC - sg) * SLOT, j2)
    else:
        out.append("  SG=11: gap re-hunt skipped (the escape)")

    # (the clock-bit repair of the byte at DEC+d4 is not modelled - it only
    # toggles bit 7 of the first post-gap pre-sync byte, which the walk's
    # two accepted literals differ in; verdict-neutral)
    padw = 0x2AA8 if buf[DEC + 0x2EC0 - 1] & 1 else 0xAAA8
    put_word(buf, DEC + 0x2EC0, padw)
    put_word(buf, DEC, 0xAAAA)

    exp_sec = sec
    for slot in range(NSEC):
        off = DEC + slot * SLOT
        pre = long_(buf, off)
        if pre not in (0xAAAAAAAA, 0x2AAAAAAA):
            out.append(f"  slot {slot}: pre-sync {pre:08X} -> $16")
            return 0x16
        if long_(buf, off + 4) != 0x44894489:
            out.append(f"  slot {slot}: sync {long_(buf, off+4):08X} -> $16")
            return 0x16
        if cksum(buf, off + 8, 10) != decode_pair(long_(buf, off + 0x30),
                                                  long_(buf, off + 0x34)):
            out.append(f"  slot {slot}: header cksum -> $18")
            return 0x18
        info = decode_pair(long_(buf, off + 8), long_(buf, off + 12))
        fmt, trk, sec_i = (info >> 24) & 0xFF, (info >> 16) & 0xFF, \
                          (info >> 8) & 0xFF
        if fmt != 0xFF or trk != exp_track or sec_i != exp_sec:
            out.append(f"  slot {slot}: info={info:08X} fmt={fmt:02X} "
                       f"trk={trk} sec={sec_i} (expected sec {exp_sec}) "
                       "-> $17")
            return 0x17
        if cksum(buf, off + 0x40, 256) != decode_pair(long_(buf, off + 0x38),
                                                      long_(buf, off + 0x3C)):
            out.append(f"  slot {slot}: data cksum -> $19")
            return 0x19
        exp_sec = (exp_sec + 1) % NSEC
    out.append(f"  walk complete -> success, returns first sector {sec}")
    return sec


def blit(buf, src, dst, nbytes, j):
    """The blitter realign copy: out[i] = bits j..j+15 of source words
    i, i+1."""
    for i in range(0, nbytes, 2):
        if j == 0:
            put_word(buf, dst + i, word(buf, src + i))
        else:
            v = (word(buf, src + i) << 16) | word(buf, src + i + 2)
            put_word(buf, dst + i, (v >> (16 - j)) & 0xFFFF)


def seam_map(buf, meta, out):
    """Annotated map of the captured gap region (pristine capture)."""
    k = meta["k"]
    sg_true = NSEC - k                    # SG of the serve-start sector
    fresh = meta["fresh"]
    # in the capture, the serve-start sector's slot begins 4 bytes before
    # CAP (its pre-sync is not captured); the gap follows sg_true slots
    gap_start = CAP - 4 + sg_true * SLOT
    out.append(f"  capture gap region (serve start sector {k}, "
               f"{sg_true} slots to the gap, gap at {gap_start:#x}):")
    # scan from 16 words before the expected gap start until 2 slots later
    o = gap_start - 32
    syncs = []
    segs = []                             # (start, class, count)
    cur_cls, cur_start, cur_n = None, None, 0
    end = gap_start + meta["gap_b"] + 2 * SLOT
    while o < end:
        w = word(buf, o)
        cls = {0xAAAA: "A", 0x5555: "5", 0x4489: "S"}.get(w, "x")
        if w == 0x4489:
            syncs.append(o)
        if cls == cur_cls:
            cur_n += 1
        else:
            if cur_cls is not None:
                segs.append((cur_start, cur_cls, cur_n))
            cur_cls, cur_start, cur_n = cls, o, 1
        o += 2
    segs.append((cur_start, cur_cls, cur_n))
    for st, cls, n in segs:
        if cls in "A5S" and n > 2:
            out.append(f"    {st:#x}: {n} x "
                       + {"A": "AAAA", "5": "5555", "S": "4489"}[cls])
        else:
            words = " ".join(f"{word(buf, st + 2*i):04X}" for i in range(n))
            out.append(f"    {st:#x}: {words}")
    if syncs:
        out.append(f"  4489 words in the region: "
                   + " ".join(f"{s:#x}" for s in syncs))
        gap_words = (syncs[0] - gap_start) // 2
        out.append(f"  captured gap length to the first post-gap sync: "
                   f"{gap_words} words ({2*gap_words} bytes; physical gap "
                   f"was {meta['gap_b']} bytes + splice slip)")
        if len(syncs) >= 4:
            # spacing between the post-gap sector boundaries: the first
            # sync pair belongs to the first post-gap sector; a following
            # pair 0x440 bytes later is nominal - anything else means
            # words were duplicated/lost by mid-serve realignment
            pair2 = [s for s in syncs if s >= syncs[0] + SLOT - 32]
            if pair2:
                out.append(f"  post-gap slot spacing: {pair2[0]-syncs[0]:#x} "
                           f"(nominal {SLOT:#x})")


def load_dump(path):
    buf = [0] * 20480
    meta = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#"):
                for tok in line[1:].split():
                    if "=" in tok:
                        key, val = tok.split("=")
                        meta[key] = (val == "true") if val in ("true", "false") \
                                    else int(val)
                continue
            off_s, w_s = line.split()
            put_word(buf, int(off_s), int(w_s, 16))
    if not meta.get("fresh", False):
        put_word(buf, DEC, 0xAAAA)        # stale leader after any prior
        put_word(buf, DEC + 2, 0xAAAA)    # attempt's chunk-1 blit
    return buf, meta


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for path in sys.argv[1:]:
        buf, meta = load_dump(path)
        print(f"== {path} {meta}")
        out = []
        seam_map(buf, meta, out)
        err = td_decode(buf, 81, out)
        for line in out:
            print(line)
        name = TDERR.get(err, f"success (first sector {err})")
        print(f"  VERDICT: {name}")
        print()


if __name__ == "__main__":
    main()
