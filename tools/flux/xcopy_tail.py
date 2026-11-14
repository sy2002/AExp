#!/usr/bin/env python3
"""Where does each X-Copy DOS write end, relative to the last data bit of sector 10?

X-Copy writes [500 x AAAA][11 sectors][1 x AAAA]: the entire post-payload
margin is one pad word, 16 cells. After it the head meets this same write's
own lead-in, laid down one revolution earlier at an unrelated bit phase, so
the end of the write shows as the first off-grid interval (not an integer
number of cells; the legal 2/3/4-cell interval at the data/pad boundary is not
a splice). The pad word AAAA puts its last transition 15 cells after the data
end, so a fully written tail has the off-grid interval starting at about 15
cells, on both heads. Earlier means the post-DSKBLK tail is being cut (inside
the pad, or inside the data, which also shows as data errors). A junction
whose phase step is under 0.25 cell is invisible; about half are, by
construction.

Usage: python3 tools/flux/xcopy_tail.py disk.scp LABEL [disk.scp LABEL ...]
Needs numpy.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scp_tool as st  # noqa: E402
if len(sys.argv) < 3 or len(sys.argv) % 2 == 0:
    print(__doc__)
    sys.exit(2)
for p, lab in zip(sys.argv[1::2], sys.argv[2::2]):
    tr = st.read_scp(p, only=set(range(160)))
    res = {0: [], 1: []}; invisible = {0: 0, 1: 0}; nosec = 0
    for tn in range(160):
        revs = tr[tn]
        flux = np.concatenate([r[1] for r in revs]) / 1000.0; tabs = np.cumsum(flux)
        bs, tm = st.pll_bits(flux * 1000.0); tm = np.array(tm) / 1000.0
        secs = st.decode_sectors(bs, tm)
        s10 = [s for s in secs if s["sec"] == 10 and s["hdr_ok"] and s["dat_ok"] and s["bitpos"] + 8672 + 400 < len(tm)]
        if not s10: nosec += 1; continue
        s = s10[0]
        # local cell from this sector: sync -> data end = 8672 raw bits
        t_end = tm[s["bitpos"] + 8672 - 1]; cell = (t_end - tm[s["bitpos"]]) / (8672 - 1)
        k = int(np.searchsorted(tabs, t_end - 40.0 * cell))          # start 40 cells before the data end: a cut inside the data must show
        found = None
        for j in range(k, k + 120):                                   # look 120 transitions = 240 cells ahead
            r = flux[j] / cell                                        # interval ending at transition j
            if abs(r - np.rint(r)) > 0.25 or r < 1.6 or r > 4.4:
                found = (tabs[j - 1] - t_end) / cell; break           # junction = start of the odd interval
        if found is None: invisible[tn % 2] += 1
        else: res[tn % 2].append(found)
    print(f"\n=== {lab}")
    for h in (1, 0):
        a = np.array(res[h])
        if not len(a): print(f"  head {h}: no visible junctions"); continue
        hist = np.histogram(a, bins=[-1e9, -0.5, 8, 13, 19, 40, 1e9])[0]
        print(f"  head {h}: junction visible on {len(a)} tracks (invisible {invisible[h]}): median {np.median(a):5.1f} cells after the data end, min {a.min():5.1f}, max {a.max():5.1f}"
              f"   | inside data (<0): {hist[0]}  inside the pad word (0..13): {hist[1]+hist[2]}  at the pad end (13..19): {hist[3]}  later: {hist[4]+hist[5]}")
    if nosec: print(f"  ({nosec} tracks without a clean sector 10)")
