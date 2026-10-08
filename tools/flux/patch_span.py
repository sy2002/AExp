#!/usr/bin/env python3
"""Measure the extent of a damage patch inside one sector.

Walks the expected transitions (from the source image) and the observed flux
in lockstep, forward from the sector's sync and backward from the next sync,
and reports where each walk loses step: the patch extent in time and cells,
the expected and observed transition counts, and the interval mix inside the
patch. A clean sector matches all of its roughly 3400 transitions sync to
sync.

The backward walk starts at the sync of the sector that directly follows, so
SECTOR must be 0..9: sector 10 is followed by the track gap and has no such
anchor.

Usage: python3 tools/flux/patch_span.py disk.scp source.adf TRACK:SECTOR [TRACK:SECTOR ...]
Needs numpy. Reads revolutions 0..2 of each named sector.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scp_tool as st  # noqa: E402
from burst import sector_raw, enc

SYNCBITS = [int(c) for c in "0100010010001001"] * 2

def span(scp, src, tn, sec, rev):
    revs = st.read_scp(scp, only={tn})[tn]
    flux = np.concatenate([r[1] for r in revs]) / 1000.0; idx_cum = np.cumsum([0.0] + [r[0] for r in revs]) / 1000.0
    tabs = np.cumsum(flux)
    bs, tm = st.pll_bits(flux * 1000.0); tm = np.array(tm) / 1000.0
    allsecs = st.decode_sectors(bs, tm)
    cand = [s for s in allsecs if s["sec"] == sec and s["hdr_ok"]]
    if rev >= len(cand): return None
    s = cand[rev]
    # the next sync on disk after this sector (any sector, header need not be ok) located in the flux domain:
    k0 = int(np.argmin(np.abs(tabs - tm[s["bitpos"] + 31])))
    data = src[(tn*11+sec)*512:(tn*11+sec+1)*512]
    raw = sector_raw(tn, sec, s["sug"], data)
    gap, _ = enc([0]*16, raw[-1])
    full = raw + gap + SYNCBITS
    pos = np.array([i+1 for i, b in enumerate(full) if b]); exp = np.diff(np.concatenate([[0], pos]))
    # find the far anchor: the observed transition that ends the next 4489 4489. Its nominal time:
    t_nom = tabs[k0] + pos[-1] * 2.0
    # search observed flux for the sync interval signature (cells): 4489 4489 -> intervals ...4,3,4,3,2? use exp tail of 10 intervals
    tail = exp[-10:]
    best = None
    for j in range(k0 + len(exp) - 400, min(k0 + len(exp) + 400, len(flux) - 10)):
        seg = flux[j:j+10]
        c = seg.sum() / tail.sum()
        if 1.85 < c < 2.15 and np.abs(seg - tail*c).max() < 0.35*c:
            tj = tabs[j+9]
            if best is None or abs(tj - t_nom) < abs(best[1] - t_nom): best = (j+9, tj)
    k1 = best[0]
    # forward lockstep
    def walk(start, step, seq):
        cell = 2.0; n = 0; at = 0.0; ac = 0
        while n < len(seq):
            o = flux[start + step*n]
            if abs(o - seq[n]*cell) > 0.40*cell: break
            at += o; ac += seq[n]; n += 1
            if ac > 200: cell = at/ac
        return n, cell
    nF, cF = walk(k0+1, +1, exp)
    nB, cB = walk(k1, -1, exp[::-1])
    total = len(exp)
    ridx = int(np.searchsorted(idx_cum, tabs[k0], side="right") - 1)
    if nF >= total - 2: return dict(clean=True, total=total, cell=cF)
    # transitions: forward-good up to expected index nF-1 (time tabs[k0+nF]); backward-good from expected index total-nB-1 (time tabs[k1-nB])
    tA = tabs[k0 + nF]; cA = pos[nF-1] if nF else 0
    tB = tabs[k1 - nB]; cBpos = pos[total - nB - 1]
    cells = cBpos - cA; cell = (cF + cB) / 2
    err = (tB - tA)/cell - cells
    obs_n = (k1 - nB) - (k0 + nF); exp_n = (total - nB - 1) - (nF - 1)
    iv = flux[k0+nF+1 : k1-nB+1]
    return dict(clean=False, tA=(tA-idx_cum[ridx])/1000, tB=(tB-idx_cum[ridx])/1000, cells=int(cells), err=err, cF=cF, cB=cB,
                obs_n=obs_n, exp_n=exp_n, iv=iv, wordA=(cA-448)//16 if cA > 448 else -1, wordB=(cBpos-448)//16)

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    scp, srcf = sys.argv[1], sys.argv[2]; src = open(srcf, "rb").read()
    for spec in sys.argv[3:]:
        tn, sec = map(int, spec.split(":"))
        for rev in (0, 1, 2):
            r = span(scp, src, tn, sec, rev)
            if r is None: continue
            if r["clean"]:
                print(f"track {tn:3d} sec {sec:2d} rev {rev}: CLEAN sync-to-sync, {r['total']} transitions, cell {r['cell']:.4f} us"); continue
            iv = r["iv"]; h = np.histogram(iv, bins=[0,3.0,3.5,4.6,5.4,6.6,7.4,8.6,10,20,1e9])[0]
            print(f"track {tn:3d} sec {sec:2d} rev {rev}: patch {r['tA']:.3f}..{r['tB']:.3f} ms ({(r['tB']-r['tA'])*1000:.0f} us, {r['cells']} cells, data words {r['wordA']}..{r['wordB']});"
                  f" elapsed-time error {r['err']:+.2f} cells (cell fwd {r['cF']:.4f} / bwd {r['cB']:.4f});  transitions exp {r['exp_n']} obs {r['obs_n']}")
            print(f"        intervals inside patch: <3:{h[0]} 3-3.5:{h[1]} ~4:{h[2]} ~5:{h[3]} ~6:{h[4]} ~7:{h[5]} ~8:{h[6]} 8.6-10:{h[7]} 10-20:{h[8]} >20:{h[9]}   max {iv.max():.1f} us")
