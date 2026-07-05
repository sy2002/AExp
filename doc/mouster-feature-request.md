# Feature request to the mouSTer maintainer: active pot-line drive in Amiga *mouse* mode

**What this file is:** supporting material for a mouSTer user to add to the
existing, already-agreed request. **This is not a new request - it is already
filed as mouSTer GitHub issue #38** ("Amiga middle and right button pull-up",
<https://github.com/willyvmm/mouSTer/issues/38>), opened 2024-01-28 by Paul
Gardner-Stephen (the MEGA65's creator), with the exact root cause below. The
maintainer (willyvmm) already **agreed it is fixable in firmware** on
2024-01-30 ("I can add a fix for the MEGA65 in the firmware, that is what
exactly revpotlines do, except without reversing the signal polarity") - which
is precisely the behavior the MEGA65 needs. The issue then stalled (tied to a
future "new amiga protocol/driver"). So the useful action today is **not to
open a duplicate** but to **bump #38** with fresh context: the MEGA65 Amiga
core (AExp) is now live and has real users waiting, and the core already reads
active-drive, normal-polarity adapters, so the described fix would work out of
the box. The text below the line can be pasted as a comment on #38; feel free
to shorten.

---

## Request: expose `activepotlines` in the `[mouse]` section (Amiga mouse mode)

Hi, and thank you for the mouSTer. It's excellent.

I'm using a mouSTer (firmware `3.23.5308`) as an **Amiga mouse** on a **MEGA65**
running its Amiga 500 FPGA core. Movement and the left button are perfect. The
**right and middle buttons do not register at all**, and after analysis with
the core's author, we're confident this is *not* a mouSTer bug but a missing
configuration option. Here is the full reasoning and the small ask.

### Why it doesn't work today

On a real Amiga, the right/middle mouse buttons sit on the two **proportional
(POT) pins** (DE-9 pin 9 and pin 5). A normal Amiga mouse (and the mouSTer in
Amiga mouse mode) treats them **passively**: it pulls the pin to GND when the
button is pressed and lets it float otherwise. It relies on the Amiga's **Paula**
chip to drive those lines high, so that "grounded = pressed, high = released."

Your own INI documents exactly this behavior for mouse mode:

```
[mouse]
revpotlines=false   ; "connected to ground when active"  (passive, open-drain)
```

and there is **no `activepotlines` key in the `[mouse]` section**; that option
exists only in `[gamepad]`.

The catch on the MEGA65: its "Paula" is emulated **inside the FPGA** and never
reaches the physical DE-9 pin. The MEGA65's POT pin circuit is **sense-only**:

```
DE-9 pin --- 1k series --- node --- 1.2nF to GND
                            node --- discharge FET (can only pull LOW)
                            node --- buffer --- FPGA input
             (no pull-up anywhere)
```

It can *measure* the pin but cannot *drive* it or pull it high. So a passively
grounded button is **invisible**: "floating" and "grounded" both read low, in
every button state. There is nothing the core can do about it: a passive mouse
button simply produces no readable signal on this hardware.

Interestingly, the mouSTer FAQ already predicts this exact case:

> "Right Mouse Button is not working on My Amiga: this issue is caused by
> damaged PCB around the PAULA chip, or by a broken PAULA chip itself … mouSTer
> is not able to force the badly broken PAULA to work."

From the mouSTer's point of view, the MEGA65 looks precisely like an Amiga whose
Paula can't drive the pot lines: the FAQ scenario, but by design rather than by
damage.

### The ask

**Please expose the `activepotlines` option in the `[mouse]` section too**, with
the same meaning it has in `[gamepad]` (actively drive the 2nd/3rd button
lines). With:

```
[mouse]
activepotlines=true
revpotlines=false
```

the mouSTer would drive pin 9 / pin 5 **push-pull**: **HIGH when released, LOW
when pressed**. That is electrically identical to a healthy Amiga pin (Paula
high + button-to-ground), so the MEGA65 reads it perfectly, and it works on
every MEGA65 board revision, since the POT sense circuit is identical across
them.

If there is already a way to achieve active push-pull drive of the button lines
in mouse mode that I've missed, please just point me to it.

### Safety / why it should stay opt-in

I understand the `activepotlines` warning: on a **real** Amiga, actively driving
the pin can contend with a *healthy* Paula that is also driving it high (when the
button is pressed, mouSTer drives low, Paula drives high → contention). So this
option should remain **opt-in and default `false`**, exactly as it already is in
`[gamepad]`. On the MEGA65 the pin is input-only (the sense circuit never drives
it), so there is **no contention risk there at all**; active drive is completely
safe on that platform.

### Bonus benefit

This same option would also let the mouSTer's **right button work on real Amigas
with a weak or partially damaged Paula** (the very machines your FAQ mentions),
because the mouSTer would no longer depend on Paula's drive to establish the
high level.

Thanks very much for considering it!

---

## Context for the MEGA65 side (for reference, not part of the paste)

- The MEGA65 Amiga core is **AExp** (<https://github.com/sy2002/AExp>). Its full
  mouse analysis, including schematics of the POT sense circuit on all board
  revisions, is in `doc/mouse.md`.
- The core already ships a working fallback: the **RUN/STOP key** acts as the
  right mouse button, so mouSTer users are not stuck in the meantime.
- The core reads active adapters with **pressed = line low, released = line
  high** (Amiga-faithful polarity). An adapter that instead drives
  pressed = high (e.g. mouSTer with `revpotlines=true`, which is open-source and
  *readable* but inverted) would need the reversed polarity; the clean match is
  `activepotlines=true` + `revpotlines=false` as requested above.
- Confirmed data points: a different active adapter ("MicroTom") that already
  drives push-pull pressed-low works natively on MEGA65 R6; the passive
  mouSTer mouse mode does not. Both on the same core build.
