#!/usr/bin/env python3
"""Verdicts for the scandoubler benches (tb_scandoubler.v and
tb_scandoubler_minimig.v), run by run_scandoubler.sh.

  check_scandoubler.py lines TRACE [--min-lines N] [--hs-period N]
                            [--moving-window] [--vertical]
  check_scandoubler.py same TRACE_A TRACE_B --shift S [--frames F0:F1]
                            [--skip-lines L] [--min-de N]

Both modes end with "RESULT PASS" (exit 0) or "RESULT FAIL" (exit 1).

A trace holds change records of the mixer input ("I t hblank vblank rgb ok")
and of the mixer output ("O t hs vs de ce rgb", rgb 0 outside DE), frame
markers ("F t frame ...") and an end record ("E t"); t counts video clocks.

lines: the reference comes from the input side only. An input pixel is a
maximal run of constant RGB (every pixel carries a unique ID), an input line is
a maximal run of HBlank low, and its vblank state is VBlank at its first clock.
A pixel is inside the line if all of its clocks are, and overlaps it if any
clock is. One output line is a run of DE high. Each output line is classified:

  OK         it shows consecutive input pixels of one input line outside
             vblank, starting no later than the first inside pixel and ending
             no earlier than the last inside pixel, nothing that does not
             overlap the line, each interior pixel for half its input clocks
             (an odd count alternates between the two neighbouring integers)
  DECIMATED  it shows every second input pixel of the line, covering it, each
             for as many output clocks as it had input clocks: the signature
             of Hq2x at two clocks per pixel
  WRONGHALF  its first k pixels are the first k pixels of an earlier input
             line, the rest continues with pixel k of the next input line to
             the end of that line: the read switched to the new line inside the
             window (the line doubler swapped its halves after the window had
             opened)
  BAD        anything else (the reason is printed)
  skipped    lines whose input pixels are flagged ok = 0 (the Minimig bench
             flags hires content at the lowres rate, a property of the
             frame-locked enable, not of the mixer), and input lines cut by
             the start or end of the trace

With an odd number of clocks per pixel the output pixels alternate between two
lengths, and the output window, which the scandoubler delays at the irregular
ce_x4o rate and video_mixer moves to CE_PIXEL edges, can hold one pixel more
than the input line at an edge. For odd periods only, one such neighbouring
pixel per edge is accepted; the CLASS line counts those lines as odd_edge.

--moving-window is for rasters whose hblank edges move from line to line
(jitter, a step), so that the lengths of the input lines differ. Two effects
of the scandoubler's output timing follow, and this mode accepts them:

  - An input line longer than the one before it: the scandoubler predicts the
    start of an output window from the length of the previous line and opens
    the first window of the next line early. That window shows the line from
    its first pixel and then pixels of the blanking after it.
  - The window length comes from hde_end, which the scandoubler measures at
    the end of every input line. The end of input line L+1 falls inside the
    second output copy of line L, so that copy has the window length of line
    L+1: if L+1 is shorter, the second copy of L ends early. The Hq2x path
    (LINEDOUBLER = 0) shares this timing and shows the same.

In this mode an OK line shows consecutive input pixels with no repeat or gap,
none of them from another input line, starting no later than the first inside
pixel, each interior pixel for half its input clocks. The first copy of an
input line must show every inside pixel; the second may end short by at most
ceil((length of line L - length of line L+1) / pixel period) pixels (lengths
of the HBlank-low runs in clocks), and the CLASS line counts those as
short_second. Pixels of the neighbouring blanking are accepted at either end,
and the two copies of a line may differ there.

--vertical is for rasters whose vblank edges trail the hblank falling edge by
a few clocks (the analog soft blank changes vblank one clock after its
hblank). The vblank state of an input line is then the VBlank value during
most of its active part instead of the one at its first clock. In addition,
for every run of active input lines whose display the output trace covers
completely (one per frame), the set of input lines shown from the line before
the run to the line after it must be exactly the run; the VERTICAL line counts
the frames that are exact, one line late (first line missing, the blanking
line below the run shown), one line early, or other.

Over the sequence of output lines, every input line outside vblank must be
shown on exactly two consecutive output lines with identical content (except
with --moving-window), in order, none left out (the first and last pair of the
trace may be cut). No X
or Z may appear on HS, VS, DE, CE or under DE, nor on the input. With
--hs-period, every interval between rising output HS edges must have that
length. At least --min-lines output lines (default 100) must be classified.

The verdict line "SIGNATURE" names the kind of failure: "none" when the trace
passes, "decimated" when the only failures are DECIMATED lines, every
two-clock line is DECIMATED and nothing else is wrong (what the red control
must show), "wronghalf" when the only failures are WRONGHALF lines and nothing
else is wrong, "vlate" (with --vertical) when every vertical window is one
line late and every other failure follows from that shift, "other" otherwise.

same: TRACE_A at clock t must equal TRACE_B at clock t + S in HS, VS, DE, CE
and RGB (RGB is 0 outside DE in both), over the range both traces cover,
limited with --frames to the clocks t where t and t + S both lie between the
frame markers F0 and F1 of TRACE_A, the first L lines (--skip-lines) left out.
The range must contain a VS edge and at least --min-de DE clocks (default
10000). The same comparison at shift S + 1 must differ, otherwise the
comparison proves nothing.
"""
import sys
from array import array
from collections import Counter, defaultdict


def die(msg):
    print('ERROR', msg)
    print('RESULT FAIL')
    sys.exit(1)


def bad_val(v):
    return 'x' in v or 'z' in v


def opt(args, name, default):
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            die('%s needs a value' % name)
        return args[i + 1]
    return default


def open_trace(path):
    try:
        return open(path)
    except OSError as e:
        die('cannot read %s: %s' % (path, e))


def scan_meta(path):
    """header, frame markers and end of a trace; dies if the run did not end"""
    hdr, frames, end = {}, {}, None
    with open_trace(path) as fh:
        for ln in fh:
            c = ln[:1]
            if c in ('I', 'O'):
                continue
            p = ln.split()
            if c == 'P':
                hdr = dict(kv.split('=', 1) for kv in p[1:] if '=' in kv)
            elif c == 'F' and len(p) >= 3:
                frames.setdefault(int(p[2]), int(p[1]))
            elif c == 'E' and len(p) == 2:
                end = int(p[1])
    if end is None:
        die('%s has no end record: the simulation did not finish' % path)
    return hdr, frames, end


def out_records(path, end):
    """output segments (start, end, 'hs vs de ce rgb') in time order"""
    prev = None
    with open_trace(path) as fh:
        for ln in fh:
            if ln[:2] != 'O ':
                continue
            t, rest = ln[2:].split(' ', 1)
            t = int(t)
            if prev is not None:
                yield prev[0], t, prev[1]
            prev = (t, rest.rstrip('\n').lower())
    if prev is None:
        die('%s has no output records' % path)
    yield prev[0], end, prev[1]


# ----------------------------------------------------------------- lines mode
class Inputs:
    """pixel runs (rs, re, rgb, ok, win) and lines (ws, we, vb, cut, ov, inside, ok, p)"""

    def __init__(self, path, end, during=False):
        self.rs, self.re, self.rgb, self.ok = array('q'), array('q'), [], bytearray()
        self.xz = []
        wins = []                     # [start, end, vblank at start, cut, clocks vb 0, clocks vb 1]
        hb_prev, vb_prev, t_prev, first = None, None, None, True
        with open_trace(path) as fh:
            for ln in fh:
                if ln[:2] != 'I ':
                    continue
                t, hb, vb, rgb, ok = ln[2:].split()
                t = int(t)
                rgb = rgb.lower()
                if hb_prev == '0' and wins:
                    wins[-1][4 if vb_prev == '0' else 5] += t - t_prev
                if hb not in ('0', '1') or vb not in ('0', '1') or bad_val(rgb):
                    self.xz.append(t)
                if not self.rgb or rgb != self.rgb[-1]:
                    if self.rgb:
                        self.re.append(t)
                    self.rs.append(t)
                    self.rgb.append(rgb)
                    self.ok.append(ok == '1')
                elif ok != '1':
                    self.ok[-1] = 0
                if hb == '0' and hb_prev != '0':
                    wins.append([t, None, vb, first, 0, 0])
                elif hb != '0' and hb_prev == '0':
                    wins[-1][1] = t
                hb_prev, vb_prev, t_prev, first = hb, vb, t, False
        if not self.rgb:
            die('%s has no input records' % path)
        self.re.append(end)
        if hb_prev == '0' and wins:
            wins[-1][4 if vb_prev == '0' else 5] += end - t_prev
        if wins and wins[-1][1] is None:
            wins[-1][1], wins[-1][3] = end, True
        n = len(self.rgb)
        self.win = array('l', [-1]) * n
        self.wins = []
        k = 0
        for wi, (ws, we, vb, cut, c0, c1) in enumerate(wins):
            if during:
                vb = '0' if c0 >= c1 else '1'
            while k > 0 and self.re[k - 1] > ws:
                k -= 1
            while k < n and self.re[k] <= ws:
                k += 1
            ov, inside = [], []
            j = k
            while j < n and self.rs[j] < we:
                ov.append(j)
                if self.win[j] < 0:
                    self.win[j] = wi
                if self.rs[j] >= ws and self.re[j] <= we:
                    inside.append(j)
                j += 1
            k = j
            lens = Counter(self.re[j] - self.rs[j] for j in inside)
            self.wins.append({
                's': ws, 'e': we, 'vb': vb, 'cut': cut,
                'ov': (ov[0], ov[-1]) if ov else None,
                'in': (inside[0], inside[-1], len(inside)) if inside else None,
                'first': {x for x in (ov[:1] + inside[:1])},
                'ok': all(self.ok[j] for j in ov),
                'p': lens.most_common(1)[0][0] if lens else None})


def wrong_half(pix, ri, I, find):
    """(k, window of the second line) if the first k shown pixels are the
    first k pixels of the input line of ri and the rest continues with pixel k
    of a later input line to the end of that line, else None"""
    rgb, n = I.rgb, len(pix)
    wa = I.win[ri]
    if wa < 0 or ri not in I.wins[wa]['first']:
        return None
    k = 0
    while k < n and ri + k < len(rgb) and rgb[ri + k] == pix[k][0]:
        k += 1
    if k == 0 or k == n:
        return None
    rk = find(pix[k][0])
    if rk is None or I.win[rk] <= wa:
        return None
    wb = I.win[rk]
    if rk - k not in I.wins[wb]['first'] or rk + (n - 1 - k) >= len(rgb):
        return None
    if any(rgb[rk + j - k] != pix[j][0] for j in range(k, n)):
        return None
    if I.wins[wb]['in'] is None or rk + (n - 1 - k) < I.wins[wb]['in'][1]:
        return None
    return k, wb


def classify(start, pix, ri, I, find, moving):
    """-> (kind, window index or None, reason, extra); kind OK, DECIMATED,
    WRONGHALF, BAD, SKIP or (moving only) SHORT, which the pairing stage
    resolves; extra is True for an OK line that used the odd-period edge
    allowance and the number of missing end pixels for SHORT. ri is the
    latest input pixel with the colour of the first output pixel that started
    before the output line, find looks up the same for any colour"""
    if ri is None:
        return 'BAD', None, 'first pixel %s is no earlier input pixel' % pix[0][0], False
    wi = I.win[ri]
    if wi < 0:
        return 'BAD', None, 'first pixel %s lies in no input line' % pix[0][0], False
    w = I.wins[wi]
    n, rgb = len(pix), I.rgb
    stride = None
    for st in (1, 2):
        if ri + (n - 1) * st < len(rgb) and all(rgb[ri + j * st] == pix[j][0] for j in range(n)):
            stride = st
            break
    if stride is None:
        wh = wrong_half(pix, ri, I, find)
        if wh is not None:
            k, wb = wh
            if I.wins[wb]['cut'] or not I.wins[wb]['ok']:
                return 'SKIP', wb, '', False
            return 'WRONGHALF', wb, 'starts with %d pixel(s) of the input line at t=%d' % (
                k, I.wins[wi]['s']), False
    if w['cut'] or not w['ok']:
        return 'SKIP', wi, '', False
    if w['vb'] != '0':
        return 'BAD', wi, 'shows an input line inside vblank', False
    if w['in'] is None:
        return 'BAD', wi, 'input line without inside pixels', False
    if stride is None:
        return 'BAD', wi, 'not a sequence of consecutive input pixels (%d shown)' % n, False
    first, last = ri, ri + (n - 1) * stride
    in0, in1, nin = w['in']
    ov0, ov1 = w['ov']
    inl = [I.re[ri + j * stride] - I.rs[ri + j * stride] for j in range(n)]
    outl = [p[1] for p in pix]
    odd = w['p'] % 2 == 1
    if stride == 1:
        if moving:
            other = [j for j in range(n) if I.win[ri + j] not in (-1, wi)]
            if other:
                return 'BAD', wi, 'shows %d pixel(s) of another input line' % len(other), False
        else:
            slack = 1 if odd else 0
            if first < ov0 - slack or last > ov1 + slack:
                return 'BAD', wi, 'shows %d pixel(s) before, %d after its input line' % (
                    max(ov0 - first, 0), max(last - ov1, 0)), False
        if first > in0 or (last < in1 and not moving):
            return 'BAD', wi, 'misses %d pixel(s) at the start, %d at the end of %d' % (
                max(first - in0, 0), max(in1 - last, 0), nin), False
        for j in range(1, n - 1):
            a, b = inl[j], outl[j]
            if a % 2 == 0:
                good = b == a // 2
            else:
                good = b in (a // 2, a // 2 + 1)
                if good and j > 1 and inl[j - 1] == a and outl[j - 1] == b:
                    good = False          # odd periods alternate
            if not good:
                return 'BAD', wi, 'pixel %d of %d shown for %d clocks, input %d clocks' % (
                    j, n, b, a), False
        if last < in1:
            return 'SHORT', wi, 'misses %d pixel(s) at the end of %d' % (in1 - last, nin), in1 - last
        return 'OK', wi, '', not moving and (first < ov0 or last > ov1)
    if first > in0 + 1 or last < in1 - 1 or first < ov0 or last > ov1:
        return 'BAD', wi, 'every second pixel, not covering the line', False
    if any(outl[j] != inl[j] for j in range(1, n - 1)):
        return 'BAD', wi, 'every second pixel, with irregular lengths', False
    return 'DECIMATED', wi, 'every second pixel (%d of %d)' % (n, nin), False


def mode_lines(args):
    path = args[0]
    min_lines = int(opt(args, '--min-lines', '100'))
    hs_period = opt(args, '--hs-period', None)
    moving = '--moving-window' in args
    vertical = '--vertical' in args
    hdr, frames, end = scan_meta(path)
    I = Inputs(path, end, during=vertical)
    W = I.wins
    errors = []
    if I.xz:
        errors.append('%d X/Z input record(s), first at t=%d' % (len(I.xz), I.xz[0]))

    # stream the output: DE runs become lines, classified at once
    nrun, ptr = len(I.rgb), 0
    latest = {}                       # colour -> latest input pixel started so far
    results = []                      # [start, window, kind, why, extra, content hash]
    xz, hs_rise = [], []
    cur, hs_prev, first_seg = None, None, True
    for s, e, key in out_records(path, end):
        hs, vs, de, ce, rgb = key.split()
        if any(v not in ('0', '1') for v in (hs, vs, de, ce)) or (de == '1' and bad_val(rgb)):
            xz.append('t=%d %s' % (s, key))
        if hs == '1' and hs_prev == '0':
            hs_rise.append(s)
        hs_prev = hs
        if de == '1':
            if cur is None:
                cur = [s, [], first_seg]
            if cur[1] and cur[1][-1][0] == rgb:
                cur[1][-1][1] += e - s
            else:
                cur[1].append([rgb, e - s])
        elif cur is not None:
            if not cur[2]:
                start, pix = cur[0], cur[1]
                while ptr < nrun and I.rs[ptr] < start:
                    latest[I.rgb[ptr]] = ptr
                    ptr += 1
                kind, wi, why, extra = classify(start, pix, latest.get(pix[0][0]), I,
                                                latest.get, moving)
                results.append([start, wi, kind, why, extra,
                                hash(tuple(tuple(p) for p in pix))])
            cur = None
        first_seg = False

    if xz:
        errors.append('%d X/Z output record(s), first: %s' % (len(xz), xz[0]))
    if hs_period is not None:
        iv = Counter(b - a for a, b in zip(hs_rise, hs_rise[1:]))
        if len(hs_rise) < 3 or set(iv) != {int(hs_period)}:
            errors.append('output HS period %s, expected %s' % (dict(iv.most_common(4)), hs_period))

    # pairing: every input line outside vblank on two consecutive output lines
    groups = []
    for r in results:
        if groups and r[1] is not None and groups[-1][0] == r[1]:
            groups[-1][1].append(r)
        else:
            groups.append([r[1], [r]])
    def active(j):
        return 0 <= j < len(W) and W[j]['vb'] == '0'

    pair_err = []                     # (text, one line late at a frame edge)
    for gi, (wi, members) in enumerate(groups):
        if wi is None:
            continue                      # already counted as BAD
        edge = gi == 0 or gi == len(groups) - 1
        if len(members) != 2 and not (edge and len(members) == 1):
            pair_err.append(('input line at t=%d shown on %d output lines'
                             % (W[wi]['s'], len(members)), False))
        if len(members) == 2 and members[0][5] != members[1][5] and not moving:
            pair_err.append(('the two output lines of the input line at t=%d differ'
                             % W[wi]['s'], False))
        if gi + 1 < len(groups) and groups[gi + 1][0] is not None:
            nxt = wi + 1
            while nxt < len(W) and W[nxt]['vb'] != '0':
                nxt += 1
            got = groups[gi + 1][0]
            if got != nxt:
                # one line late at a frame edge: the line after the last active
                # line follows it, or the second active line follows the blanking
                late = (got == wi + 1 and active(wi) and not active(got)) or \
                       (got == nxt + 1 and not active(nxt - 1))
                pair_err.append(('after the input line at t=%d comes the one at t=%d, expected t=%s'
                                 % (W[wi]['s'], W[got]['s'],
                                    W[nxt]['s'] if nxt < len(W) else 'none'), late))
        # --moving-window: the second copy may end short by what the next
        # input line is shorter (the scandoubler sizes the window with the
        # length it measures at the end of the next line, which falls inside
        # the second copy); the first copy must be complete
        for ci, r in enumerate(members):
            if r[2] != 'SHORT':
                continue
            second = ci == 1 or (gi == 0 and len(members) == 1)
            p = W[wi]['p']
            shorter = W[wi]['e'] - W[wi]['s'] - (W[wi + 1]['e'] - W[wi + 1]['s']) \
                if wi + 1 < len(W) else 0
            allowed = max(0, -(-shorter // p)) if second else 0
            if r[4] <= allowed:
                r[2], r[4] = 'OK', 'short'
            else:
                r[2] = 'BAD'
                r[3] = '%s copy %s (allowed %d)' % ('second' if second else 'first', r[3], allowed)

    per_class = defaultdict(Counter)
    shown_bad = []
    for start, wi, kind, why, extra, h in results:
        cls = 'P%s' % (W[wi]['p'] if wi is not None else '?')
        per_class[cls][kind] += 1
        if extra is True:
            per_class[cls]['EDGE'] += 1
        if extra == 'short':
            per_class[cls]['SHORT2'] += 1
        if kind in ('BAD', 'WRONGHALF') and len(shown_bad) < 5:
            shown_bad.append('  %s output line at t=%d (%s): %s' % (
                'wrong-half' if kind == 'WRONGHALF' else 'bad', start, cls, why))

    tot = Counter()
    for c in per_class.values():
        tot.update(c)
    checked = tot['OK'] + tot['DECIMATED'] + tot['WRONGHALF'] + tot['BAD']
    if checked < min_lines:
        errors.append('only %d output lines checked, at least %d required' % (checked, min_lines))

    # --vertical: per active run of input lines whose display the output trace
    # covers completely, the set of input lines shown around it
    vert = Counter()
    if vertical:
        out_start = next(out_records(path, end))[0]
        shown = set(g[0] for g in groups if g[0] is not None)
        j = 0
        while j < len(W):
            if not active(j) or W[j]['cut']:
                j += 1
                continue
            a = j
            while j + 1 < len(W) and active(j + 1) and not W[j + 1]['cut']:
                j += 1
            b = j
            j += 1
            if a < 1 or W[a]['s'] < out_start or b + 3 >= len(W) or W[b + 3]['s'] > end:
                continue
            got = set(x for x in shown if a - 1 <= x <= b + 1)
            for kind, lo in (('exact', a), ('late', a + 1), ('early', a - 1)):
                if got == set(range(lo, lo + b - a + 1)):
                    vert[kind] += 1
                    break
            else:
                vert['other'] += 1
        frames_v = sum(vert.values())
        if frames_v == 0:
            errors.append('no vertical window completely inside the trace')
        elif vert['exact'] != frames_v:
            errors.append('vertical window: %d of %d frame(s) not exact' % (frames_v - vert['exact'], frames_v))

    print('trace %s: %s' % (path, ' '.join('%s=%s' % kv for kv in hdr.items())))
    print('input: %d pixels, %d lines (%d outside vblank); output: %d lines, %d skipped'
          % (len(I.rgb), len(W), sum(1 for w in W if w['vb'] == '0'), len(results), tot['SKIP']))
    for cls in sorted(per_class):
        c = per_class[cls]
        print('CLASS %s lines=%d ok=%d decimated=%d bad=%d skipped=%d%s%s%s'
              % (cls, c['OK'] + c['DECIMATED'] + c['WRONGHALF'] + c['BAD'], c['OK'],
                 c['DECIMATED'], c['BAD'], c['SKIP'],
                 ' wronghalf=%d' % c['WRONGHALF'] if c['WRONGHALF'] else '',
                 ' odd_edge=%d' % c['EDGE'] if c['EDGE'] else '',
                 ' short_second=%d' % c['SHORT2'] if c['SHORT2'] else ''))
    for s in shown_bad:
        print(s)
    if vertical:
        print('VERTICAL frames=%d exact=%d late=%d early=%d other=%d'
              % (sum(vert.values()), vert['exact'], vert['late'], vert['early'], vert['other']))
    for s, _ in pair_err[:5]:
        print('  pairing:', s)
    for s in errors:
        print('  error:', s)
    print('pairing errors: %d' % len(pair_err))

    clean = not errors and not pair_err and tot['BAD'] == 0
    passed = clean and tot['DECIMATED'] == 0 and tot['WRONGHALF'] == 0
    p2 = per_class.get('P2', Counter())
    # one line late: every vertical window shifted down by one line, and every
    # other failure is a consequence of that shift (a blanking line below the
    # window shown, the first line of the window missing)
    late_bad = all(r[3] == 'shows an input line inside vblank' and r[1] is not None
                   and active(r[1] - 1) for r in results if r[2] == 'BAD')
    vlate = (vertical and vert['late'] > 0 and vert['late'] == sum(vert.values())
             and all(late for _, late in pair_err) and late_bad
             and tot['DECIMATED'] == 0 and tot['WRONGHALF'] == 0
             and all(e.startswith('vertical window') for e in errors))
    if passed:
        sig = 'none'
    elif vlate:
        sig = 'vlate'
    elif clean and tot['WRONGHALF'] == 0 and tot['DECIMATED'] > 0 and \
            p2['DECIMATED'] == tot['DECIMATED'] and p2['OK'] == 0:
        sig = 'decimated'
    elif clean and tot['DECIMATED'] == 0 and tot['WRONGHALF'] > 0:
        sig = 'wronghalf'
    else:
        sig = 'other'
    print('SIGNATURE', sig)
    print('RESULT', 'PASS' if passed else 'FAIL')
    return 0 if passed else 1


# ------------------------------------------------------------------ same mode
def compare(pa, ea, pb, eb, shift, lo, hi):
    """A(t) against B(t + shift) for t in [lo, hi): mismatching clocks, DE
    clocks, VS edges and the first mismatch; both traces are streamed"""
    ga, gb = out_records(pa, ea), out_records(pb, eb)
    sa, sb = next(ga), next(gb)
    t, mism, de, vs_edges, first, vs_prev = lo, 0, 0, 0, None, None
    try:
        while t < hi:
            while sa[1] <= t:
                sa = next(ga)
            while sb[1] - shift <= t:
                sb = next(gb)
            if sa[0] > t or sb[0] - shift > t:
                die('the traces do not cover t=%d' % t)
            nxt = min(sa[1], sb[1] - shift, hi)
            ka, kb = sa[2], sb[2]
            if ka != kb:
                mism += nxt - t
                if first is None:
                    first = 't=%d: %s against %s' % (t, ka, kb)
            fa = ka.split()
            if fa[2] == '1':
                de += nxt - t
            if vs_prev is not None and fa[1] != vs_prev:
                vs_edges += 1
            vs_prev = fa[1]
            t = nxt
    except StopIteration:
        die('a trace ended before t=%d' % hi)
    return mism, de, vs_edges, first


def mode_same(args):
    pa, pb = args[0], args[1]
    shift = opt(args, '--shift', None)
    if shift is None:
        die('--shift is required')
    shift = int(shift)
    frames = opt(args, '--frames', None)
    skip = int(opt(args, '--skip-lines', '0'))
    min_de = int(opt(args, '--min-de', '10000'))
    ha, fa, ea = scan_meta(pa)
    hb, fb, eb = scan_meta(pb)
    H = int(ha.get('H', '0'))
    oa0 = next(out_records(pa, ea))[0]
    ob0 = next(out_records(pb, eb))[0]
    lo = max(oa0, ob0 - shift)
    hi = min(ea, eb - shift)
    if frames:
        f0, f1 = (int(x) for x in frames.split(':'))
        if f0 not in fa or f1 not in fa:
            die('frame markers %d and %d not both in %s (have %s)' % (f0, f1, pa, sorted(fa)))
        lo = max(lo, fa[f0] + skip * H)
        hi = min(hi, fa[f1] - shift)
    else:
        lo += skip * H
    if hi - lo < 2 * H:
        die('compared range [%d, %d) is too short' % (lo, hi))
    mism, de, vs_edges, first = compare(pa, ea, pb, eb, shift, lo, hi)
    cm, _, _, _ = compare(pa, ea, pb, eb, shift + 1, lo, hi - 1)
    print('same %s at t against %s at t+%d, t in [%d, %d): %d clocks, %d under DE, %d VS edges'
          % (pa, pb, shift, lo, hi, hi - lo, de, vs_edges))
    print('mismatching clocks: %d%s' % (mism, '' if first is None else ', first ' + first))
    print('control at shift %d: %d mismatching clocks (must not be 0)' % (shift + 1, cm))
    ok = mism == 0 and cm > 0 and de >= min_de and vs_edges >= 1
    if de < min_de:
        print('  error: only %d DE clocks compared, at least %d required' % (de, min_de))
    if vs_edges < 1:
        print('  error: no VS edge inside the compared range')
    print('RESULT', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('lines', 'same') or \
       (sys.argv[1] == 'same' and len(sys.argv) < 4):
        print(__doc__)
        sys.exit(2)
    if sys.argv[1] == 'lines':
        sys.exit(mode_lines(sys.argv[2:]))
    sys.exit(mode_same(sys.argv[2:]))


if __name__ == '__main__':
    main()
