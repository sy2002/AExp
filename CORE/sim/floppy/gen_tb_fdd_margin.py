#!/usr/bin/env python3
"""Generate stimulus and independently computed expectations for
tb_fdd_margin.vhd (the margin instrumentation of the Hardware Floppy read
front-end).

Prints a VHDL snippet with:
  * C_GAPS: the flux gap sequence in 50 MHz cycles (not cells), all phases
  * phase boundary indices (gap counts, 0-based, exclusive end)
  * expected register values at each checkpoint, computed by an independent
    Python model of the quantiser and the margin engine (exact Q4 integer
    arithmetic, the same rules as physical_fdd_mfm_quantise.vhd and
    margin_proc)

Phases (serving/ctrl changed by the TB at the boundaries):
  A: 20 nominal short gaps, serving=0, ctrl=0        -> nothing accumulates
  B: 64 nominal short gaps, serving=1, ctrl=0        -> S-class bin 4
  C: 4 medium gaps at 310 cycles                     -> M-class bin 4, min 640
  D: one 260-cycle gap (M, near boundary) + one 480  -> min 140, 1 reject
  [checkpoint 1, then clear]
  E: ctrl = window mode K=3; 20 nominal gaps (no window -> nothing), then a
     revolution of 8 MFM header blocks (sectors 0,1,2,4,5,6,7,8 on track 81,
     sector 3/9/10 absent): window opens at sector 2's capture publish,
     closes at sector 4's sync
  [checkpoint 2]
  F: index pulse -> miss profile for sectors 3,9,10, qual_revs 1
  [checkpoint 3 in the TB, no gaps]

Usage: python3 CORE/sim/floppy/gen_tb_fdd_margin.py
The constant block it prints (from C_A_END to the end of C_GAPS) replaces
the one in tb_fdd_margin.vhd. It imports the MFM encoder from
tools/decode_fdd_dump.py.
"""

import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                os.pardir, os.pardir, os.pardir, 'tools'))
from decode_fdd_dump import mfm_encode_long

Q = 16          # Q4
NOM = 100 * Q   # nominal est, Q4
STEP = 2        # C_QUANT_STEP_Q
EMIN, EMAX = 90 * Q, 110 * Q


def word_bits(w):
    return [(w >> i) & 1 for i in range(15, -1, -1)]


def header_block(sector, track=81):
    """channel bits: 2x AAAA pre-gap, 2x 4489, 4 info words, 4 label words"""
    bits = []
    for w in (0xAAAA, 0xAAAA, 0x4489, 0x4489):
        bits += word_bits(w)
    info = (0xFF << 24) | (track << 16) | (sector << 8) | 1
    iw = mfm_encode_long(info, prev_data_bit=1)
    lw = mfm_encode_long(0, prev_data_bit=iw[-1] & 1)
    for w in iw + lw[:4]:
        bits += word_bits(w)
    return bits, iw


def bits_to_cells(bits, carry):
    """distance (in cells) between successive 1-bits; carry = cells since
    the last 1 of the previous chunk. Returns (cells, new_carry)."""
    out = []
    run = carry
    for b in bits:
        run += 1
        if b:
            out.append(run)
            run = 0
    return out, run


# ---- build the gap sequence (cells first, phases tracked by gap index) ----
gaps = []          # cycles
marks = {}

def add_cells(cells):
    gaps.extend(c * 100 for c in cells)

# A: 20 nominal short gaps (2 cells each)
add_cells([2] * 20)
marks['A_end'] = len(gaps)
# B: 64 nominal short
add_cells([2] * 64)
marks['B_end'] = len(gaps)
# C: 4 medium at 310 cycles (raw, not cell multiples)
gaps.extend([310] * 4)
marks['C_end'] = len(gaps)
# D: 260 then 480
gaps.extend([260, 480])
marks['D_end'] = len(gaps)
# E: 20 nominal, then the revolution. carry=1 stitches the bit-derived
# stream to the raw nominal cells (one cell since the last '1'), keeping
# every emitted gap a legal 2/3/4 cells.
add_cells([2] * 20)
marks['E_hdrs_start'] = len(gaps)
carry = 1
filler = [0xAAAA] * 8
E_SECTORS = [0, 1, 2, 4, 5, 6, 7, 8]
e_cells = []
sec_span = {}
for s in E_SECTORS:
    fb = []
    for w in filler:
        fb += word_bits(w)
    cells, carry = bits_to_cells(fb, carry)
    e_cells += cells
    hb, _ = header_block(s)
    cells, carry = bits_to_cells(hb, carry)
    sec_span[s] = (marks['E_hdrs_start'] + len(e_cells),
                   marks['E_hdrs_start'] + len(e_cells) + len(cells))
    e_cells += cells
# trailing filler so the last capture completes well before the index pulse
fb = []
for w in filler * 2:
    fb += word_bits(w)
cells, carry = bits_to_cells(fb, carry)
e_cells += cells
add_cells(e_cells)
marks['E_end'] = len(gaps)

# bit-exact aligner walk over the E header stream: find each sync-match gap
# index and each capture-publish gap index (128 bits = 8 words after the
# last sync of a block)
sync_idx, pub_idx = [], []
shifter = 0
bits_after_sync = None
for gi, cells in enumerate(e_cells):
    base = marks['E_hdrs_start'] + gi
    for b in [0] * (cells - 1) + [1]:
        shifter = ((shifter << 1) | b) & 0xFFFF
        if bits_after_sync is not None:
            bits_after_sync += 1
            if bits_after_sync == 128:
                pub_idx.append(base)
                bits_after_sync = None
        if shifter == 0x4489:
            sync_idx.append(base)
            bits_after_sync = 0


# ---- independent quantiser + margin model (integer Q4) -------------------
class Model:
    """Integer model of quantiser + margin engine. The gaps stage measures
    each interval exclusive of the edge cycle (edge-to-edge minus one, kept
    bit-for-bit from the C64MEGA65 stage), so the model receives the emitted
    gap and subtracts 1; the adaptive estimate then settles slightly below
    the true cell length exactly like the hardware."""

    def __init__(self):
        self.est = NOM
        self.hist = [0] * 24
        self.gap_cnt = 0
        self.lol_gate = 0
        self.min_margin = 0xFFFF
        self.min_est = 0
        self.min_gap = 0
        self.min_cls = 3
        self.est_min = NOM
        self.est_max = NOM

    def clear(self):
        self.hist = [0] * 24
        self.gap_cnt = 0
        self.lol_gate = 0
        self.min_margin = 0xFFFF
        self.min_cls = 3
        self.est_min = self.est
        self.est_max = self.est

    def gap(self, g_emit, gated):
        g_cyc = g_emit - 1              # the gaps stage's exclusive count
        g = g_cyc * Q
        est = self.est
        mid23 = 2 * est + est // 2
        mid34 = 3 * est + est // 2
        if g < mid23:
            n = 2
        elif g < mid34:
            n = 3
        else:
            n = 4
        e = g - n * est
        tol = est // 2
        if abs(e) <= tol:
            if gated:
                self.gap_cnt += 1
                off = e + tol
                b = 0
                if off >= tol:
                    off -= tol
                    b |= 4
                if off >= tol // 2:
                    off -= tol // 2
                    b |= 2
                if off >= tol // 4:
                    b |= 1
                self.hist[(n - 2) * 8 + b] += 1
                margin = tol - abs(e)
                if margin < self.min_margin:
                    self.min_margin = margin
                    self.min_est = est
                    self.min_gap = g_cyc
                    self.min_cls = n - 2
            if e > 0:
                self.est = min(EMAX, est + STEP)
            elif e < 0:
                self.est = max(EMIN, est - STEP)
        else:
            if gated:
                self.lol_gate += 1
            self.est = NOM
        self.est_min = min(self.est_min, self.est)
        self.est_max = max(self.est_max, self.est)


m = Model()
for i, g in enumerate(gaps[:marks['D_end']]):
    m.gap(g, gated=marks['A_end'] <= i)   # serving from B on, ctrl=0

print("-- ==== GENERATED by gen_tb_fdd_margin.py - do not edit by hand ====")
print(f"-- checkpoint 1 (after phase D, before clear):")
print(f"--   gap_cnt={m.gap_cnt} lol_gate={m.lol_gate} min_margin={m.min_margin}")
print(f"--   min_est={m.min_est} min_gap={m.min_gap} min_cls={m.min_cls}")
print(f"--   est now {m.est}")
nz = {i: v for i, v in enumerate(m.hist) if v}
print(f"--   hist nonzero: {nz}")
CK1 = dict(gap_cnt=m.gap_cnt, lol=m.lol_gate, mm=m.min_margin, mest=m.min_est,
           mgap=m.min_gap, mcls=m.min_cls, hist=list(m.hist),
           estmin=m.est_min, estmax=m.est_max)

# phase E model: window mode. The Python model of the window would need the
# full bit/capture pipeline; instead we compute the deterministic pieces:
# the window opens at sector 2's publish and closes at sector 4's first
# sync-matching word. Every gap in between is gated. We count them from the
# generated stream directly: gaps strictly after the last bit of sector 2's
# block up to and including the gap that completes the first 4489 of
# sector 4's sync... the aligner's sync_hit fires when the shifter equals
# 4489, i.e. at the gap that delivers its final '1' bit. For the assert we
# only bound the count loosely and check the invariants exactly:
#   win_opens=1, sync_gate=1 (the closing sync), lol_gate=0
m.clear()
# window: opens at sector 2's capture publish (the 3rd publish - sectors
# emit in order 0,1,2,...), closes at sector 4's first sync = the next
# sync-match after that publish. Both bit-exactly located above.
open_at = pub_idx[2]
close_at = next(s for s in sync_idx if s > open_at)
gated = close_at - open_at
print("-- checkpoint 2 (phase E window): win_opens=1 sync_gate=1 lol_gate=0;")
print(f"--   window opens at gap {open_at}, closes at {close_at} -> "
      f"~{gated} gated gaps (assert with +/-3 boundary slack)")
CK2 = (gated - 3, gated + 3)

print()
print(f"  constant C_A_END : natural := {marks['A_end']};")
print(f"  constant C_D_END : natural := {marks['D_end']};")
print(f"  constant C_E_START : natural := {marks['D_end']};")
print(f"  constant C_N_GAPS : natural := {len(gaps)};")
print(f"  -- checkpoint 1 expectations")
print(f"  constant C_CK1_GAPCNT : natural := {CK1['gap_cnt']};")
print(f"  constant C_CK1_LOL    : natural := {CK1['lol']};")
print(f"  constant C_CK1_MM     : natural := {CK1['mm']};")
print(f"  constant C_CK1_MEST   : natural := {CK1['mest']};")
print(f"  constant C_CK1_MGAP   : natural := {CK1['mgap']};")
print(f"  constant C_CK1_MCLS   : natural := {CK1['mcls']};")
print(f"  constant C_CK1_ESTMIN : natural := {CK1['estmin']};")
print(f"  constant C_CK1_ESTMAX : natural := {CK1['estmax']};")
hist_str = ", ".join(str(v) for v in CK1['hist'])
print(f"  constant C_CK1_HIST : t_int24 := ({hist_str});")
print(f"  -- checkpoint 2 gated-gap bounds")
print(f"  constant C_CK2_LO : natural := {CK2[0]};")
print(f"  constant C_CK2_HI : natural := {CK2[1]};")
print()


def fmt_gaps():
    out = []
    line = "    "
    for g in gaps:
        tok = f"{g},"
        if len(line) + len(tok) > 76:
            out.append(line)
            line = "    "
        line += tok
    out.append(line.rstrip(','))
    return "\n".join(out)


print("  constant C_GAPS : t_gapvec := (")
print(fmt_gaps())
print("  );")
