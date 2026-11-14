#!/usr/bin/env python3
"""Whole-disk scan for analog damage patches in a Greaseweazle .scp dump.

A patch is 8 or more off-grid intervals inside 1 ms, found at the same angle
in revolution 0 and revolution 1. A healthy disk, core-written or
Amiga-written, scans to zero. Patches that line up in index-relative angle
across tracks are a physical feature of the medium: X-Copy's DOS writes start
at a random angle, so write logic cannot produce that alignment.

Usage: python3 tools/flux/patch_scan.py disk.scp LABEL [disk.scp LABEL ...]
Needs numpy; the .scp needs at least two revolutions per track.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scp_tool as st  # noqa: E402
def scan(path, label):
    tr = st.read_scp(path, only=set(range(160)))
    print(f"\n=== {label}: patches with >= 8 off-grid intervals inside 1 ms (rev 0 and rev 1 must agree in angle)")
    npatch = 0; perhead = [0, 0]
    for tn in range(160):
        found = []
        for rev in (0, 1):
            idx, fl = tr[tn][rev]; us = fl / 1000.0; t = np.cumsum(fl) / 1e6
            # adaptive cell: median of the ~4 us population / 2
            c = np.median(us[(us > 3.4) & (us < 4.6)]) / 2.0
            r = us / c
            off = (np.abs(r - np.rint(r)) > 0.35) | (r < 1.6) | (r > 4.5)
            ts = t[off]; cl = []
            for x in ts:
                if cl and x - cl[-1][1] < 0.5: cl[-1][1] = x; cl[-1][2] += 1
                else: cl.append([x, x, 1])
            found.append([c_ for c_ in cl if c_[2] >= 8])
        for a in found[0]:
            if any(abs(a[0] - b[0]) < 0.5 for b in found[1]):
                npatch += 1; perhead[tn % 2] += 1
                print(f"   track {tn:3d} (cyl {tn//2:2d} head {tn%2})  angle {a[0]:7.2f}..{a[1]:7.2f} ms  off-grid intervals {a[2]}")
    print(f"   -> {npatch} patches; head0 {perhead[0]}, head1 {perhead[1]}")
if len(sys.argv) < 3 or len(sys.argv) % 2 == 0:
    print(__doc__)
    sys.exit(2)
for p, l in zip(sys.argv[1::2], sys.argv[2::2]): scan(p, l)
