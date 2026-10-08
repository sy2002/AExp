#!/usr/bin/env python3
"""Compare a ground-truth .adf with a read-back .adf of the same disk.

Step 1 of the write-problem protocol in doc/developers/hardware-floppy.md
section 9.2: the source image the core wrote against the disk read back
(for example with X-Copy, df0: an image, df1: the Hardware Floppy).

Usage:
    python3 tools/adf_compare.py GROUND_TRUTH.adf READBACK.adf [--tracks SPEC]

    --tracks  restrict the comparison to the tracks the read-back actually
              covered, e.g. "1-19:odd" (cylinders 0-9, upper side), "20-39",
              "0-159:even". Amiga track = cylinder * 2 + head, so odd tracks
              are head 1.

Exit status: 0 if every compared track is byte-identical, 1 otherwise,
2 on a usage error.

Why the range matters: X-Copy writes only the cylinder range it is given into
an .adf that already exists, so everything outside that range is stale file
content from an earlier read-back, not a measurement, and comparing it gives a
misleading result. The arithmetic tells the two apart: a region that was never
written differs in thousands of bytes per track (a whole different
filesystem), while a stale region differs by the handful of bytes the previous
run happened to leave. The tool prints that distinction for every track.

The post-DSKBLK tail-cut signature, which the tool recognises by itself:
bytes differ only in sector 10, only on odd (head 1) tracks, only at byte
offsets 510/511. Those two bytes are both carried by MFM stream word 543, the
last word of the sector's 544-word body, immediately before the track gap.
Every XOR is a subset of 0x55, i.e. only the even-lane data cells are wrong,
because the odd lane sits in word 287, which survives. The cell-level model is
an intact prefix, one glitch cell, then a constant tail whose value is 0 or 1
at about 50/50: the fingerprint of a physical flux splice at an arbitrary bit
phase. An encoder bug cannot produce that; it would be deterministic and would
hit head 0 too.
"""
import sys

NS, SZ = 11, 512

def cells(b):
    "the four even-lane MFM data cells of a byte, MSB first"
    return [(b >> 6) & 1, (b >> 4) & 1, (b >> 2) & 1, b & 1]

def fit_splice(tc, gc):
    "intact prefix / one glitch cell / constant tail -> (split, tail) or None"
    for s in range(8):
        for v in (0, 1):
            if all(gc[i] == tc[i] for i in range(s)) and \
               all(gc[i] == v for i in range(s + 1, 8)):
                return s, v
    return None

def parse_tracks(spec):
    if not spec:
        return list(range(160))
    rng, _, par = spec.partition(':')
    a, _, b = rng.partition('-')
    t = list(range(int(a), int(b or a) + 1))
    if par == 'odd':   t = [x for x in t if x % 2]
    if par == 'even':  t = [x for x in t if x % 2 == 0]
    return t

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    spec = next((a.split('=', 1)[1] for a in sys.argv[1:]
                 if a.startswith('--tracks=')), None)
    if spec is None and '--tracks' in sys.argv:
        i = sys.argv.index('--tracks')
        spec = sys.argv[i + 1] if i + 1 < len(sys.argv) else None
    if len(args) < 2:
        print(__doc__); return 2
    A = open(args[0], 'rb').read()
    B = open(args[1], 'rb').read()
    if len(A) != 901120 or len(B) != 901120:
        print("!! not both standard 901,120-byte ADFs (%d / %d)" % (len(A), len(B)))
    tracks = parse_tracks(spec)
    print("comparing %s (truth) vs %s (read-back) over %d tracks"
          % (args[0], args[1], len(tracks)))
    total, damaged = 0, []
    for t in tracks:
        d = []
        for s in range(NS):
            o = (t * NS + s) * SZ
            for i in range(SZ):
                if A[o + i] != B[o + i]:
                    d.append((s, i, A[o + i], B[o + i]))
        if d:
            damaged.append((t, d)); total += len(d)
    print("\ndiffering bytes: %d over %d of %d tracks\n"
          % (total, len(damaged), len(tracks)))
    if not damaged:
        print("clean - every compared track is byte-identical to the truth image.")
        return 0
    for t, d in damaged:
        secs = sorted({s for s, _, _, _ in d})
        offs = sorted({i for _, i, _, _ in d})
        # a region that was never written at all differs in thousands of bytes
        kind = "never written / different content" if len(d) > 500 else "damaged"
        print("track %3d (cyl %2d head %d): %5d bytes  %s" % (t, t // 2, t % 2, len(d), kind))
        if len(d) <= 8:
            print("      sectors %s, offsets %s" % (secs, offs))
            for s, i, x, y in d:
                print("      sector %2d byte %3d: %02X -> %02X  (xor %02X%s)"
                      % (s, i, x, y, x ^ y,
                         ", even lane only" if (x ^ y) & 0xAA == 0 else ""))
            # the tail-cut signature lives in sector 10 bytes 510/511
            if secs == [10] and set(offs) <= {510, 511}:
                o = (t * NS + 10) * SZ
                tc = cells(A[o + 510]) + cells(A[o + 511])
                gc = cells(B[o + 510]) + cells(B[o + 511])
                f = fit_splice(tc, gc)
                print("      >> MFM stream word 543 (last word of the sector body)")
                print("      >> truth cells %s  got %s"
                      % (''.join(map(str, tc)), ''.join(map(str, gc))))
                print("      >> splice fit: %s"
                      % ("split at cell %d, tail %d - the post-DSKBLK tail-cut "
                         "signature" % f if f
                         else "does not fit the splice model - a different defect"))
    return 1

if __name__ == '__main__':
    sys.exit(main())
