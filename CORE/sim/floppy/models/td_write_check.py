#!/usr/bin/env python3
"""td_write_check.py - independent twin of the Hardware Floppy writer.

A second, independent implementation of the write serialization rules of
physical_fdd_writer.vhd, used to cross-check the flux that tb_fdd_write.vhd
records:

  * cell/pulse geometry: 100 cycles/cell at 50 MHz, one channel bit per
    cell MSB-first per word, active-low WDATA pulse launched at cycle 50
    of the cell (early = cycle 43, late = cycle 57, i.e. +/-7 cycles =
    140 ns), pulse width 25 cycles (the testbench checks the width, which
    it sees on the pin; this twin checks edge positions);
  * precomp direction from the wall-clock table of the MEGA65 core's
    floppy writer (mfm_bits_to_gaps.vhdl in
    https://github.com/MEGA65/mega65-core): gap-before shorter than
    gap-after -> early, the mirror -> late, symmetric or invalid-MFM
    neighborhood -> no shift; the written bit sits at index 3 of a 7-bit
    neighborhood;
  * boundary rule: a bit whose 7-cell window reaches before the episode's
    first bit or beyond its last bit gets no shift;
  * the output pipeline delays the whole window rigidly, so the delay
    cancels in every position relative to the WGATE window start - the
    dump's `wstart` is the disk position of the window's first cell
    boundary, and expected edge k sits at (wstart + 100*c + L_c) mod T_rev.

The twin consumes a dump written by tb_fdd_write.vhd (G_DUMP mode), one
file per writing scenario:

    # meta t_rev=<cycles> cell=100 precomp=<0|1> wstart=<pos> wlen=<cycles>
           words=<N> scen=<name> [free tokens]
    W <hexword>       source word list, N lines, write order
    P <pos>           pre-seed flux edge positions (before the episode)
    E <pos>           final flux edge positions (after the episode)

and verifies, failing on the first violation:

  V1  the WGATE window length equals words*16*100 exactly (wlen);
  V2  every expected edge exists in the final flux within +/-1 cycle, and
      every final-flux edge inside the written span is expected (+/-1) -
      i.e. the flux model and this reconstruction agree edge for edge;
  V3  the written span contains no surviving pre-seed edge (the old flux
      is gone, so the gate really opened and erased);
  V4  outside the written span the final flux equals the pre-seed exactly
      (the writer touched nothing beyond its window);
  V5  interval histogram: consecutive final edges inside the written span
      are {200,300,400} +/- (7 precomp + 2 slack) cycles apart when the
      content is legal MFM (--mfm strict mode; otherwise reported only).

--predict replays the final flux continuously through the legacy adaptive
quantiser (physical_fdd_pkg constants) and a realign-at-every-sync
aligner, captures 7358 words from the serve-from-sync start of each
sector anchor k = 0..10, and runs td_check.py's trackdisk decode on each
capture: the verdicts a realign-always framing would give for that flux.

--selftest runs the twin's own red controls: an LSB-first, 99-cycle-cell,
sign-inverted-precomp or one-word-dropped reconstruction must each
disagree with the correct reference (the writer mutants i, ii, iii and vii
of run_write_mutants.sh must be visible to this checker).

Usage:
    td_write_check.py dump.txt [more...] [--mfm]
    td_write_check.py --predict dump.txt [--track 40]
    td_write_check.py --selftest
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import td_check  # the independent KS1.3 trackdisk decode model

CELL = 100                 # cycles per channel cell at 50 MHz
LAUNCH = 50                # nominal pulse launch cycle within the cell (midpoint)
PRE_SHIFT = 7              # precomp magnitude, cycles (140 ns)
IV_TOL    = 2 * PRE_SHIFT + 2   # per-INTERVAL budget: both ends can move
TOL = 1                    # edge position agreement tolerance, cycles

# legacy adaptive quantiser constants (physical_fdd_pkg.vhd, Q8.4)
EST_NOM_Q = 100 * 16
EST_MIN_Q = 90 * 16
EST_MAX_Q = 110 * 16
STEP_Q = 2                 # 1/8 cycle per accepted gap
DMA_WORDS = 7358


# ---------------------------------------------------------------------------
# serialization twin
# ---------------------------------------------------------------------------

def words_to_bits(words):
    """MSB-first channel bits of the word list."""
    bits = []
    for w in words:
        for j in range(15, -1, -1):
            bits.append((w >> j) & 1)
    return bits


def gap_before(bits, c):
    """Cells to the previous '1' seen from bit c: 2, 3, 4 (=4+), or None
    for an invalid-MFM neighborhood (adjacent '1')."""
    if bits[c - 1]:
        return None
    if bits[c - 2]:
        return 2
    if bits[c - 3]:
        return 3
    return 4


def gap_after(bits, c):
    if bits[c + 1]:
        return None
    if bits[c + 2]:
        return 2
    if bits[c + 3]:
        return 3
    return 4


def launch_cycle(bits, c, precomp):
    """Launch cycle of bit c's pulse within its cell (wall-clock table:
    before < after -> early = launch earlier; before > after -> late)."""
    if not precomp:
        return LAUNCH
    if c - 3 < 0 or c + 3 >= len(bits):
        return LAUNCH               # boundary rule: no shift
    b, a = gap_before(bits, c), gap_after(bits, c)
    if b is None or a is None or b == a:
        return LAUNCH
    return LAUNCH - PRE_SHIFT if b < a else LAUNCH + PRE_SHIFT


def expected_edges(words, wstart, t_rev, precomp,
                   msb_first=True, cell=CELL, sign=+1, drop_word=None,
                   wlen=None):
    """Expected falling-edge positions (mod t_rev) of the episode.

    The self-overlap: a trackdisk write is 109 % of a revolution (X-Copy
    106-115 %), so the write's tail sweeps its own leading gap a second
    time and the earlier edges there are erased. An edge written at
    absolute offset a inside the window survives iff the head never
    reaches that position again, i.e. iff a + t_rev >= wlen. That is the
    splice, and it is by design: it lands inside the written gap.

    The mutant knobs (msb_first/cell/sign/drop_word) exist for --selftest
    only; the real check always uses the defaults."""
    ws = list(words)
    if drop_word is not None:
        del ws[drop_word]
    bits = []
    for w in ws:
        rng = range(15, -1, -1) if msb_first else range(0, 16)
        for j in rng:
            bits.append((w >> j) & 1)
    edges = []
    for c, b in enumerate(bits):
        if not b:
            continue
        lc = launch_cycle(bits, c, precomp)
        if sign < 0 and lc != LAUNCH:
            lc = 2 * LAUNCH - lc    # mutant vii: inverted precomp sign
        a_off = cell * c + lc
        if wlen is not None and a_off + t_rev < wlen:
            continue                # overwritten by the write's own tail
        edges.append((wstart + a_off) % t_rev)
    return bits, edges


def check_dump(path, mfm_strict):
    words, pre, fin = [], [], []
    meta = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                for tok in line[1:].split():
                    if "=" in tok:
                        k, v = tok.split("=", 1)
                        try:
                            meta[k] = int(v, 0)
                        except ValueError:
                            meta[k] = v
                continue
            tag, val = line.split()
            if tag == "W":
                words.append(int(val, 16))
            elif tag == "P":
                pre.append(int(val))
            elif tag == "E":
                fin.append(int(val))
    t_rev = meta["t_rev"]
    wstart = meta["wstart"]
    precomp = bool(meta.get("precomp", 0))
    n = len(words)
    fails = []

    # V1: window length
    wlen = meta["wlen"]
    if wlen != n * 16 * CELL:
        fails.append(f"V1 window length {wlen} != words*16*100 = {n*16*CELL}")

    # the written span as a position-set (handles the wrap)
    span = set()
    for k in range(wlen):
        span.add((wstart + k) % t_rev)

    bits, exp = expected_edges(words, wstart, t_rev, precomp, wlen=wlen)
    fin_set = set(fin)
    pre_set = set(pre)

    def present(pos, s):
        return any(((pos + d) % t_rev) in s for d in (-TOL, 0, TOL))

    # V2a: every expected edge present
    missing = [p for p in exp if not present(p, fin_set)]
    if missing:
        fails.append(f"V2a {len(missing)} expected edge(s) missing from the "
                     f"flux (first at {missing[0]})")
    # V2b: every final edge inside the span is expected. The last cell's
    # pulse may extend past the span end (launch+width), but its EDGE is in.
    exp_set = set(exp)
    stray = [p for p in fin if p in span and not present(p, exp_set)]
    if stray:
        fails.append(f"V2b {len(stray)} unexpected edge(s) inside the "
                     f"written span (first at {stray[0]})")
    # V3: old flux gone (only pre-seed edges not re-written count)
    survivors = [p for p in pre if p in span and not present(p, exp_set)
                 and present(p, fin_set)]
    if survivors:
        fails.append(f"V3 {len(survivors)} pre-seed edge(s) survived inside "
                     f"the written span (first at {survivors[0]}) - the gate "
                     f"did not erase")
    # V4: untouched outside the span
    out_fin = sorted(p for p in fin if p not in span)
    out_pre = sorted(p for p in pre if p not in span)
    if wlen >= t_rev:
        out_fin, out_pre = [], []       # the window covers the whole track
    if out_fin != out_pre:
        d1 = set(out_fin) - set(out_pre)
        d2 = set(out_pre) - set(out_fin)
        fails.append(f"V4 flux outside the written span changed "
                     f"(+{len(d1)}/-{len(d2)}; the writer leaked past its "
                     f"window)")
    # V5: interval histogram inside the span
    #
    # The splice is exempt. A track write is ~109 % of a revolution, so its
    # last edge abuts flux this same write laid down one revolution earlier
    # at that angular position. That junction is a discontinuity by
    # construction - it is the write splice, the thing the format's gap
    # exists to absorb, and a real Amiga's splice looks the same. Its
    # interval is therefore not legal-MFM content and must not be judged as
    # such. Whether it happens to land between two edges closer than 200
    # cycles depends on the payload, so leaving it to chance would make this
    # check pass or fail per track.
    splice_pos = (wstart + wlen) % t_rev
    span_edges = sorted(p for p in fin if p in span)
    bad_iv = 0
    hist = {}
    for a, b in zip(span_edges, span_edges[1:]):
        iv = b - a
        hist[iv] = hist.get(iv, 0) + 1
        if a < splice_pos <= b:
            continue
        # The budget is per interval, not per edge: precomp shifts each
        # edge by +/-PRE_SHIFT independently, so two adjacent pulses moved
        # in opposite directions displace their interval by 2*PRE_SHIFT
        # (the minimum pulse spacing stays 4 us - 280 ns). A per-edge
        # tolerance here would reject the twin's own expectation on every
        # precomp-active dump.
        if not any(abs(iv - nom) <= IV_TOL for nom in (200, 300, 400)):
            bad_iv += 1
    if mfm_strict and bad_iv:
        fails.append(f"V5 {bad_iv} interval(s) outside {{200,300,400}}"
                     f"+/-{IV_TOL} cycles in legal-MFM content")

    print(f"== {path}: {n} words, {len(exp)} expected edges, "
          f"{len(span_edges)} span edges, precomp={int(precomp)}, "
          f"t_rev={t_rev}, slip={t_rev % CELL}")
    if precomp:
        early = sum(1 for c, b in enumerate(bits) if b
                    and launch_cycle(bits, c, True) == LAUNCH - PRE_SHIFT)
        late = sum(1 for c, b in enumerate(bits) if b
                   and launch_cycle(bits, c, True) == LAUNCH + PRE_SHIFT)
        print(f"   precomp: {early} early, {late} late shifts expected")
    for f_ in fails:
        print(f"   FAIL {f_}")
    if not fails:
        print("   twin agrees edge-for-edge (V1..V5 clean)")
    return not fails


# ---------------------------------------------------------------------------
# realign-arm verdict predictor (legacy quantiser + realign-always aligner)
# ---------------------------------------------------------------------------

def quantise_stream(edge_positions, t_rev, start_pos, nbits):
    """Replay the flux from start_pos; legacy adaptive quantiser
    (physical_fdd_pkg constants) -> channel bit stream. Returns bits."""
    edges = sorted(edge_positions)
    if not edges:
        return []
    # rotate so replay begins at the first edge at/after start_pos
    import bisect
    i0 = bisect.bisect_left(edges, start_pos)
    seq = edges[i0:] + [e + t_rev for e in edges[:i0]]
    # extend over enough revolutions
    ext = list(seq)
    rev = 1
    while len(ext) * 2 < nbits:      # ~2 bits per edge minimum
        ext += [e + rev * t_rev for e in seq]
        rev += 1
    est_q = EST_NOM_Q
    bits = []
    prev = ext[0]
    for e in ext[1:]:
        g = e - prev
        prev = e
        g_q = g * 16
        # classify to nearest n in {2,3,4} via midpoints 2.5/3.5 est
        if g_q < (est_q * 5) // 2:
            n = 2
        elif g_q < (est_q * 7) // 2:
            n = 3
        else:
            n = 4
        err = g_q - n * est_q
        tol = est_q // 2
        if -tol <= err <= tol:
            # accept: (n-1) zeros + a one; sign-based est adaptation
            bits.extend([0] * (n - 1) + [1])
            if err > 0:
                est_q = min(est_q + STEP_Q, EST_MAX_Q)
            elif err < 0:
                est_q = max(est_q - STEP_Q, EST_MIN_Q)
        else:
            # loss of lock: resync, drop pending, re-seed the estimate
            est_q = EST_NOM_Q
        if len(bits) >= nbits:
            break
    return bits[:nbits]


def capture_realign(bits, sync, nwords):
    """Realign-at-every-sync aligner + serve-from-sync capture (framing
    without the hold = the realign-always A/B arm)."""
    sh = 0
    cnt = 0
    hunting = True
    out = []
    for b in bits:
        sh = ((sh << 1) | b) & 0xFFFF
        cnt += 1
        emit = None
        if sh == sync:
            emit = sh                # realign: emit and restart framing
            cnt = 0
        elif cnt == 16:
            emit = sh
            cnt = 0
        if emit is None:
            continue
        if hunting:
            if emit == sync:
                hunting = False
                out.append(emit)
        else:
            out.append(emit)
        if len(out) >= nwords:
            break
    return out


def predict(path, exp_track):
    words, fin = [], []
    meta = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#"):
                for tok in line[1:].split():
                    if "=" in tok:
                        k, v = tok.split("=", 1)
                        try:
                            meta[k] = int(v, 0)
                        except ValueError:
                            meta[k] = v
            elif line.startswith("E "):
                fin.append(int(line.split()[1]))
            elif line.startswith("W "):
                words.append(int(line.split()[1], 16))
    t_rev = meta["t_rev"]
    wstart = meta["wstart"]
    slip = t_rev % CELL
    print(f"== predict {path}: t_rev={t_rev} slip={slip} track={exp_track}")
    # locate each sector anchor: sector k's first sync word ends at bit
    # k*8704+... - instead, hunt from k slots into the WRITTEN stream:
    # the written track is [gap][11 sectors] in trackdisk order; sector 0
    # starts after the leading gap. We schedule the capture hunt shortly
    # before each sector's sync by angular position of its WRITTEN cells.
    # gap words = total - 11*544 - 1 pad word region: derive from words.
    n = len(words)
    gap_words = meta.get("gap_words", n - 11 * 544 - 1)
    verdicts = []
    for k in range(11):
        # position (cycles) of sector k's first sync word: written cell
        # index of that word's first bit + wstart. Words: [gap][sec0..10],
        # each sector 544 words with syncs at word offsets 2,3.
        w_idx = gap_words + k * 544 + 2
        pos = (wstart + w_idx * 16 * CELL - 60 * CELL) % t_rev
        bits = quantise_stream(fin, t_rev, pos, (DMA_WORDS + 400) * 16 + 64)
        cap = capture_realign(bits, 0x4489, DMA_WORDS)
        buf = [0] * 20480
        td_check.put_word(buf, td_check.DEC, 0xAAAA)      # stale leader
        td_check.put_word(buf, td_check.DEC + 2, 0xAAAA)
        for i, w in enumerate(cap):
            td_check.put_word(buf, td_check.CAP + 2 * i, w)
        out = []
        err = td_check.td_decode(buf, exp_track, out)
        name = td_check.TDERR.get(err, f"GREEN({err})")
        verdicts.append((k, err, name))
        print(f"   k={k:2d}: {name}")
    greens = [k for k, e, _ in verdicts if e < 11]
    reds = [(k, n_) for k, e, n_ in verdicts if e >= 0x15]
    print(f"   summary: green anchors {greens}, red {[k for k, _ in reds]}")
    return verdicts


# ---------------------------------------------------------------------------
# self-test: the twin's own red controls
# ---------------------------------------------------------------------------

def selftest():
    fails = []

    def check(name, cond):
        print(("PASS  " if cond else "FAIL  ") + name)
        if not cond:
            fails.append(name)

    # a legal-MFM word list with every neighborhood class (2->4, 4->2,
    # 2->3, 3->2 and symmetric ones):
    words = [0x4489, 0x4489, 0x5522, 0xAAAA, 0x9254, 0x4A92, 0x2AA4, 0x5525]
    t_rev = 1_000_000
    ws = 12345
    bits, ref = expected_edges(words, ws, t_rev, precomp=True)

    check("reference reconstructs deterministically",
          expected_edges(words, ws, t_rev, True)[1] == ref)

    # direction spot-checks against the wall-clock table
    b2 = [0, 1, 0, 1, 0, 0, 0]          # 0101000: short->long = EARLY
    check("0101000 -> early",
          launch_cycle(b2, 3, True) == LAUNCH - PRE_SHIFT)
    b3 = [0, 0, 0, 1, 0, 1, 0]          # 0001010: long->short = LATE
    check("0001010 -> late",
          launch_cycle(b3, 3, True) == LAUNCH + PRE_SHIFT)
    b4 = [0, 1, 0, 1, 0, 1, 0]          # 0101010: symmetric = none
    check("0101010 -> none", launch_cycle(b4, 3, True) == LAUNCH)
    b5 = [1, 0, 0, 1, 0, 0, 1]          # 1001001: medium->medium = none
    check("1001001 -> none", launch_cycle(b5, 3, True) == LAUNCH)
    b6 = [0, 0, 0, 1, 0, 0, 1]          # 0001001: long->medium = LATE
    check("0001001 -> late",
          launch_cycle(b6, 3, True) == LAUNCH + PRE_SHIFT)
    # boundary rule: a '1' whose window reaches past either stream end
    # must stay unshifted even in an asymmetric neighborhood
    bh = [0, 0, 1, 0, 1, 0, 0, 0, 1]      # written bit at c=2: c-3 < 0
    check("head-boundary bit unshifted", launch_cycle(bh, 2, True) == LAUNCH)
    bt = [1, 0, 0, 0, 1, 0, 1, 0, 0]      # written bit at c=6: c+3 > end
    check("tail-boundary bit unshifted", launch_cycle(bt, 6, True) == LAUNCH)

    # red controls: each writer mutant class must change the edge list
    for name, kw in (("mutant i (LSB-first)", dict(msb_first=False)),
                     ("mutant ii (99-cycle cell)", dict(cell=99)),
                     ("mutant vii (precomp sign)", dict(sign=-1)),
                     ("mutant iii (dropped word)", dict(drop_word=3))):
        _, mut = expected_edges(words, ws, t_rev, True, **kw)
        check(f"{name} visibly differs", mut != ref)

    # quantiser round-trip: serialize the reference edges, quantise them
    # back, and the bit stream must reproduce the source bits
    qb = quantise_stream(ref, t_rev, (ws - 50) % t_rev, len(bits))
    # the quantised stream starts at the first '1'; align on first 1
    # the first edge itself emits nothing (bits come from inter-edge gaps),
    # so the reconstruction reproduces the source from the bit after the
    # first '1'; the trailing bits after the last '1' are unreproducible
    first1 = bits.index(1)
    last1 = len(bits) - 1 - bits[::-1].index(1)
    want = bits[first1 + 1:last1 + 1]
    check("quantiser round-trips the serialized bits", qb[:len(want)] == want)

    # aligner: a 4489 embedded mid-stream realigns and is emitted
    stream = [0] * 40 + [0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1] + \
             [1, 0, 1, 0] * 8
    cap = capture_realign(stream, 0x4489, 3)
    check("aligner serves from the sync word",
          len(cap) >= 1 and cap[0] == 0x4489)

    print()
    if fails:
        print(f"SELF-TEST: {len(fails)} FAILURES")
        return 1
    print("SELF-TEST: ALL PASS")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if "--predict" in argv:
        argv = [a for a in argv if a != "--predict"]
        track = 40
        if "--track" in argv:
            i = argv.index("--track")
            track = int(argv[i + 1])
            del argv[i:i + 2]
        for p in argv:
            predict(p, track)
        return 0
    mfm = "--mfm" in argv
    argv = [a for a in argv if a != "--mfm"]
    if not argv:
        print(__doc__)
        return 1
    ok = True
    for p in argv:
        ok &= check_dump(p, mfm)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
