#!/usr/bin/env python3
"""Measure write precompensation on the medium.

Prints neighbour-conditioned interval means for tracks 60..103 (for example a
4 us interval whose right neighbour is 8 us, against a 4 us interval between
two 4s). Write precompensation shows as a step between track 79/80 (off) and
81/82 (on). A second step near track 88 also appears on A500-written disks; it
belongs to a drive, not to Paula or the core.

Usage: python3 tools/flux/precomp_step.py disk.scp LABEL [disk.scp LABEL ...]
Needs numpy.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scp_tool as st  # noqa: E402
def stat(tr, tn):
    out = {}
    L = []; Q = []
    for idx, fl in tr[tn]:
        us = fl / 1000.0
        c = np.median(us[(us > 3.4) & (us < 4.6)]) / 2.0
        q = np.rint(us / c).astype(int)
        c = us[(q >= 2) & (q <= 4)].sum() / q[(q >= 2) & (q <= 4)].sum()      # cell from total time / total cells
        q = np.rint(us / c).astype(int)
        L.append(us / c * 2.0); Q.append(q)                                     # lengths in nominal-us units (cell == 2.000)
    L = np.concatenate(L); Q = np.concatenate(Q)
    l, m, r = Q[:-2], Q[1:-1], Q[2:]; x = L[1:-1]
    def mean(a, b, c_):
        s = (l == a) & (m == b) & (r == c_)
        return (x[s].mean(), int(s.sum())) if s.sum() >= 30 else (np.nan, int(s.sum()))
    base, nb = mean(2, 2, 2)
    res = {}
    for name, key in (("4 before 8", (2, 2, 4)), ("4 after 8", (4, 2, 2)), ("4 before 6", (2, 2, 3)), ("4 after 6", (3, 2, 2)),
                      ("8 between 4s", (2, 4, 2)), ("6 between 4s", (2, 3, 2))):
        v, n = mean(*key); res[name] = (v - (base if key[1] == 2 else key[1]*2.0), n)
    return res
if len(sys.argv) < 3 or len(sys.argv) % 2 == 0:
    print(__doc__)
    sys.exit(2)
paths = sys.argv[1::2]; labels = sys.argv[2::2]
for p, lab in zip(paths, labels):
    tr = st.read_scp(p, only=set(range(60, 104)))
    print(f"\n=== {lab}   (values in ns: mean interval length minus reference; '4 before 8' = a 4 us interval whose RIGHT neighbour is 8 us, reference = a 4 between 4s)")
    for head in (1, 0):
        print(f"  head {head}:  track   4<8     8>4    4<6    6>4   [8 betw 4s] [6 betw 4s]    n(4<8)")
        rows = []
        for tn in range(60 + (head ^ (60 & 1)), 104, 2):
            if tn % 2 != head: continue
            r = stat(tr, tn)
            rows.append((tn, r))
            mark = "  <-- precomp ON from here (track >= 81)" if tn in (81, 82) else ""
            print(f"           {tn:4d}  " + " ".join(f"{r[k][0]*1000:+6.0f}" for k in ("4 before 8", "4 after 8", "4 before 6", "4 after 6")) +
                  f"     {r['8 between 4s'][0]*1000:+6.0f}      {r['6 between 4s'][0]*1000:+6.0f}     {r['4 before 8'][1]:6d}{mark}")
        off = [r for t, r in rows if t < 81]; on = [r for t, r in rows if t >= 81]
        for k in ("4 before 8", "4 after 8", "8 between 4s"):
            a = np.nanmean([r[k][0] for r in off[-5:]]) * 1000; b = np.nanmean([r[k][0] for r in on[:5]]) * 1000
            print(f"     step across the track-81 boundary, '{k}': last 5 tracks OFF {a:+.0f} ns -> first 5 tracks ON {b:+.0f} ns   (delta {b-a:+.0f} ns)")
