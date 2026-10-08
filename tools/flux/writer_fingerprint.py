#!/usr/bin/env python3
"""Which drive wrote each track of an AmigaDOS .scp dump?

A writer lays down exact 2.000 us cells at its own spindle speed, so the
number of cells per revolution is a fingerprint of the writing drive
(300.2 RPM gives about 99,930 cells, 296.5 RPM about 101,200). It is measured
as the PLL bit count between the same sector's sync in two consecutive
revolutions, independent of the reading drive's speed. The script also reports
the first sector after the gap: X-Copy's DOS engine always starts a track with
sector 0, trackdisk keeps whatever rotation its read buffer had, so a rotated
track was (re)written by trackdisk. A track written by a different drive than
the rest of the disk says nothing about the writer under test.

Usage: python3 tools/flux/writer_fingerprint.py disk.scp LABEL [disk.scp LABEL ...]
Needs numpy; the .scp needs at least two revolutions per track.
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
    rows = []
    for tn in range(160):
        flux = np.concatenate([r[1] for r in tr[tn]]); bs, tm = st.pll_bits(flux)
        secs = [s for s in st.decode_sectors(bs, tm) if s["hdr_ok"] and s["trk"] == tn and s["sec"] < 11]
        cpr = []
        for a in secs:
            for b in secs:
                if b["sec"] == a["sec"] and 90000 < b["bitpos"] - a["bitpos"] < 110000: cpr.append(b["bitpos"] - a["bitpos"])
        first = [s["sec"] for s in secs if s["sug"] == 11]
        good = len({s["sec"] for s in secs if s["dat_ok"]})
        rows.append((tn, float(np.median(cpr)) if cpr else float("nan"), first[0] if first else -1, good))
    c = np.array([r[1] for r in rows]); base = np.nanmedian(c)
    print(f"\n=== {lab}: median {base:,.0f} cells/rev = writer at {300.0 * 100000.0 / base * (200.0/200.0):.1f} RPM-equivalent (2 us cells)")
    odd = [r for r in rows if not np.isnan(r[1]) and abs(r[1] - base) > 500]
    rot = [r for r in rows if r[2] not in (0, -1)]
    print(f"   tracks written by a DIFFERENT drive (cells/rev off by more than 500): {len(odd)}")
    for tn, v, f, g in odd: print(f"      track {tn:3d} (cyl {tn//2:2d} head {tn%2}): {v:,.0f} cells/rev = {300.0*100000.0/v:.1f} RPM-equivalent, first sector after the gap {f}, good sectors {g}/11")
    print(f"   tracks whose first sector after the gap is not 0 (trackdisk-style rotation): {len(rot)}  {[r[0] for r in rot][:40]}")
