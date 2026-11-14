#!/usr/bin/env python3
"""Shared library of the flux tools; not run directly.

A minimal SuperCard Pro (.scp) flux reader as written by Greaseweazle
(read_scp), an MFM PLL modelled on Greaseweazle's (pll_bits), and an
AmigaDOS sector decoder that keeps index-relative timing (decode_sectors).
Needs numpy.
"""
import struct, numpy as np
TICK_NS = 25.0
SYNC2 = "0100010010001001" * 2          # 0x4489 0x4489

def read_scp(path, only=None):
    d = open(path, "rb").read()
    assert d[:3] == b"SCP"
    nrev = d[5]
    offs = struct.unpack("<168I", d[0x10:0x10 + 168 * 4])
    tracks = {}
    for tn, o in enumerate(offs):
        if not o or (only is not None and tn not in only): continue
        assert d[o:o+3] == b"TRK"
        revs = []
        for r in range(nrev):
            idx_t, nflux, doff = struct.unpack("<3I", d[o+4+r*12:o+16+r*12])
            raw = np.frombuffer(d, dtype=">u2", count=nflux, offset=o+doff).astype(np.int64)
            if (raw == 0).any():
                out = []; acc = 0
                for v in raw.tolist():
                    if v == 0: acc += 65536
                    else: out.append(v + acc); acc = 0
                raw = np.array(out, dtype=np.int64)
            revs.append((idx_t * TICK_NS, raw * TICK_NS))
        tracks[tn] = revs
    return tracks

def pll_bits(flux_ns, clock=2000.0, period_adj=0.05, phase_adj=0.6):
    "returns (bitstring, list of bit times in ns from start of this flux array)"
    period = clock; pmin, pmax = clock*0.85, clock*1.15
    ticks = 0.0; t_abs = 0.0
    bits = []; times = []
    for f in flux_ns.tolist():
        ticks += f; t_abs += f
        if ticks < period/2: continue
        zeros = 0
        while True:
            ticks -= period
            if ticks < period/2: break
            zeros += 1
            bits.append("0"); times.append(t_abs - ticks - period*0)  # cell time approx
        bits.append("1"); times.append(t_abs)
        if zeros <= 3: period += ticks * period_adj
        else:          period += (clock - period) * period_adj
        period = min(max(period, pmin), pmax)
        ticks *= (1.0 - phase_adj)
    return "".join(bits), times

def il16(o, e):
    v = 0
    for i in range(15, -1, -1):
        v = (v << 2) | (((o >> i) & 1) << 1) | ((e >> i) & 1)
    return v

def dec_long(bs, at):
    return il16(int(bs[at:at+32][1::2], 2), int(bs[at+32:at+64][1::2], 2))

def csum(bs, pos, nbits):
    c = 0
    for k in range(0, nbits, 32):
        c ^= int(bs[pos+k:pos+k+32], 2)
    return c & 0x55555555

def decode_sectors(bs, times):
    out = []; p = 0
    need = 64 + 256 + 64 + 64 + 8192
    while True:
        p = bs.find(SYNC2, p)
        if p < 0: break
        q = p + 32
        if q + need > len(bs): break
        info = dec_long(bs, q)
        hck = dec_long(bs, q + 320); dck = dec_long(bs, q + 384)
        dpos = q + 448
        odd = bs[dpos:dpos+4096][1::2]; even = bs[dpos+4096:dpos+8192][1::2]
        data = int("".join(a + b for a, b in zip(odd, even)), 2).to_bytes(512, "big")
        out.append(dict(bitpos=p, t_ns=times[p], fmt=(info >> 24) & 255, trk=(info >> 16) & 255,
                        sec=(info >> 8) & 255, sug=info & 255,
                        hdr_ok=(csum(bs, q, 320) == hck), dat_ok=(csum(bs, dpos, 8192) == dck),
                        data=data, dpos=dpos))
        p = q
    return out
