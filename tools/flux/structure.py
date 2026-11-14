#!/usr/bin/env python3
"""Track structure summary of an AmigaDOS .scp dump, for a few sample tracks.

Per track: cell size, the spindle speed of the drive that wrote it, cells per
revolution, the leftover gap, the angle of sector 0, the count of good
sectors, and the off-grid intervals of the write splice. Rows that report a
gap near 0 picked the wrong sector-10 instance; ignore them.

Usage: python3 tools/flux/structure.py disk.scp LABEL [disk.scp LABEL ...]
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
    tr = st.read_scp(p, only={0, 1, 40, 41, 80, 81, 120, 121, 158, 159})
    print(f"\n=== {lab}")
    print("  track  read-rev[ms]  cell[us]  writer-rev[ms]  writer-RPM  cells/rev  gap[cells]  gap[ms]  sector0-angle[ms]  sectors OK  splice: off-grid intervals in gap / largest [us]")
    for tn in sorted(tr):
        revs = tr[tn]
        flux = np.concatenate([r[1] for r in revs]) / 1000.0; idx_cum = np.cumsum([0.0] + [r[0] for r in revs]) / 1000.0
        tabs = np.cumsum(flux)
        bs, tm = st.pll_bits(flux * 1000.0); tm = np.array(tm) / 1000.0
        secs = st.decode_sectors(bs, tm)
        ok = sum(1 for s in secs if s["hdr_ok"] and s["dat_ok"])
        s0 = [s for s in secs if s["sec"] == 0 and s["hdr_ok"]]
        if len(s0) < 2: print(f"  {tn:5d}  (fewer than two sector-0 instances)"); continue
        # revolution measured sync-to-sync on the disk itself
        tA = tabs[int(np.argmin(np.abs(tabs - tm[s0[0]["bitpos"] + 31])))]; tB = tabs[int(np.argmin(np.abs(tabs - tm[s0[1]["bitpos"] + 31])))]
        rev_read = tB - tA
        # cell from one clean sector: sync(sec k) -> sync(sec k+1) = 8704 cells, averaged over all consecutive pairs
        cells = []
        for a, b in zip(secs[:-1], secs[1:]):
            if a["hdr_ok"] and b["hdr_ok"] and b["sec"] == a["sec"] + 1:
                cells.append((tm[b["bitpos"]] - tm[a["bitpos"]]) / 8704.0)
        c = float(np.median(cells))
        cells_rev = rev_read / c
        # gap: from end of sector 10 body to sector 0 sync
        s10 = [s for s in secs if s["sec"] == 10 and s["bitpos"] < s0[1]["bitpos"]][-1]
        t_end10 = tm[s10["bitpos"]] + (32 + 448 + 8192) * c          # end of sector 10 data
        t_s0 = tm[s0[1]["bitpos"]] - 32 * c                           # start of the two 0x00 lead bytes of sector 0 (approx)
        gap_cells = (t_s0 - t_end10) / c
        g = (tabs > t_end10) & (tabs < t_s0)
        giv = flux[g]; r = giv / c
        off = giv[(np.abs(r - np.rint(r)) > 0.30) | (r > 4.5) | (r < 1.6)]
        ridx = int(np.searchsorted(idx_cum, tA, side="right") - 1)
        writer_rev = rev_read * 2.0 / c
        print(f"  {tn:5d}   {rev_read/1000:9.3f}   {c:7.4f}     {writer_rev/1000:9.3f}     {60e6/writer_rev:7.2f}   {cells_rev:8.0f}   {gap_cells:8.0f}   {gap_cells*c/1000:6.2f}      {(tA-idx_cum[ridx])/1000:8.2f}        {ok:3d}/{len(secs):<3d}     {len(off):3d} / {off.max() if len(off) else 0:5.1f}")
