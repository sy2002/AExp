#!/usr/bin/env python3
"""Expected-MFM model of an AmigaDOS sector, and a per-sector residual map.

As a module (imported by patch_span.py): sector_raw() builds the exact
channel bits a sector should carry, from its track, sector, sectors-to-gap
and 512 data bytes; enc() is the MFM encoder.

As a script: for each named sector and revolutions 0 and 1, matches every
expected transition to the observed flux, removes the slow speed wander with a
301-point running median, and prints the residual per 0.25 ms angle window
(only windows with an rms above 0.30 us, missing or extra transitions).

Usage: python3 tools/flux/burst.py disk.scp source.adf TRACK:SECTOR [TRACK:SECTOR ...]
Needs numpy.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scp_tool as st  # noqa: E402

def split(bb):
    n = int.from_bytes(bb, "big"); L = len(bb)*8
    bits = [(n >> (L-1-i)) & 1 for i in range(L)]
    return bits[0::2], bits[1::2]
def enc(databits, prev):
    out = []
    for b in databits:
        out.append(1 if (prev == 0 and b == 0) else 0); out.append(b); prev = b
    return out, prev
def cksum(parts):
    c = 0
    for p in parts:
        o, e = split(p)
        for lane in (o, e):
            for k in range(0, len(lane), 16):
                v = 0
                for b in lane[k:k+16]: v = (v << 2) | b
                c ^= v
    return (c & 0x55555555).to_bytes(4, "big")
def sector_raw(trk, sec, sug, data):
    info = bytes([0xFF, trk, sec, sug]); label = bytes(16)
    raw = []; p = 1
    for part in (info, label, cksum([info, label]), cksum([data]), data):
        o, e = split(part)
        r, p = enc(o, p); raw += r
        r, p = enc(e, p); raw += r
    return raw
def trans_cells(raw):
    "cell index (1-based, counted from the last sync transition) of every expected transition"
    return np.array([i+1 for i, b in enumerate(raw) if b], dtype=float)

def analyse(scp, src, tn, sec, rev=0, verbose=True):
    revs = st.read_scp(scp, only={tn})[tn]
    flux = np.concatenate([r[1] for r in revs]); idx_cum = np.cumsum([0.0] + [r[0] for r in revs])
    tabs = np.cumsum(flux) / 1000.0                       # us, time of each transition
    bs, tm = st.pll_bits(flux); tm = np.array(tm) / 1000.0
    secs = st.decode_sectors(bs, tm)
    cand = [s for s in secs if s["sec"] == sec and s["hdr_ok"]]
    s = cand[rev]
    # exact time of the last transition of the 2nd 4489: nearest observed transition to tm[bitpos+31]
    k0 = int(np.argmin(np.abs(tabs - tm[s["bitpos"] + 31])))
    t0 = tabs[k0]
    # cell size from this sync to the next sector's sync (8704 cells later)
    nxt = [x for x in secs if x["bitpos"] > s["bitpos"] + 8000 and x["bitpos"] < s["bitpos"] + 9500]
    cell = (tabs[int(np.argmin(np.abs(tabs - tm[nxt[0]["bitpos"] + 31])))] - t0) / 8704.0 if nxt else 2.0
    data = src[(tn*11+sec)*512:(tn*11+sec+1)*512]
    raw = sector_raw(tn, sec, s["sug"], data)
    tc = trans_cells(raw)
    te = t0 + tc * cell
    obs = tabs[k0+1:]
    off = 0.0; j = 0; rows = []; used = set()
    for i, t in enumerate(te):
        tgt = t + off
        while j + 1 < len(obs) and abs(obs[j+1] - tgt) <= abs(obs[j] - tgt): j += 1
        d = obs[j] - tgt
        if abs(d) < cell * 0.95:
            rows.append((i, t, d + off, True)); off += 0.03 * d; used.add(j)
        else:
            rows.append((i, t, np.nan, False))
    jmax = max(used); extra = [obs[k] for k in range(jmax) if k not in used]
    ang0 = idx_cum[int(np.searchsorted(idx_cum, t0*1000.0, side="right") - 1)] / 1000.0
    return dict(cell=cell, rows=rows, extra=np.array(extra), tc=tc, te=te, ang0=ang0, t0=t0, raw=raw)

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    scp, srcf = sys.argv[1], sys.argv[2]
    src = open(srcf, "rb").read()
    for spec in sys.argv[3:]:
        tn, sec = map(int, spec.split(":"))
        for rev in (0, 1):
            r = analyse(scp, src, tn, sec, rev)
            rows = r["rows"]; te = r["te"]; ang = (te - r["ang0"]) / 1000.0
            dev = np.array([x[2] for x in rows]); ok = np.array([x[3] for x in rows])
            # slow component (speed wander) removed with a 301-point running median of matched devs
            dd = dev.copy(); m = np.where(ok)[0]
            base = np.interp(np.arange(len(dd)), m, np.convolve(np.pad(dd[m], 150, mode="edge"), np.ones(301)/301, mode="valid"))
            res = dd - base
            win = 0.25  # ms
            print(f"\ntrack {tn} sector {sec} rev {rev}: cell {r['cell']:.4f} us ({(r['cell']/2-1)*100:+.2f}% vs 2.000), expected transitions {len(rows)}, unmatched(expected but missing) {int((~ok).sum())}, extra observed pulses {len(r['extra'])}")
            print("   angle[ms]   n  rms_res[us]  max|res|  missing  extra")
            a0 = ang[0]; a1 = ang[-1]
            edges = np.arange(np.floor(a0*4)/4, a1 + win, win)
            exang = (r["extra"] - r["ang0"]) / 1000.0
            for lo in edges:
                sel = (ang >= lo) & (ang < lo + win)
                if not sel.any(): continue
                rr = res[sel & ok]
                rms = np.sqrt(np.mean(rr**2)) if len(rr) else float("nan")
                mx = np.max(np.abs(rr)) if len(rr) else float("nan")
                mis = int((sel & ~ok).sum()); ex = int(((exang >= lo) & (exang < lo + win)).sum())
                if rms > 0.30 or mis or ex:
                    print(f"   {lo:8.2f} {int(sel.sum()):4d}   {rms:7.3f}    {mx:6.3f}   {mis:4d}   {ex:4d}")
            quiet = res[ok & (np.abs(res) < 5)]
            print(f"   whole-sector rms residual {np.sqrt(np.mean(quiet**2)):.3f} us (clean-region reference)")
