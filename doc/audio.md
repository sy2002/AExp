# Audio: volume, stereo and the Amiga's filters

AExp plays the Amiga's sound on HDMI and on the MEGA65's 3.5 mm audio jack at
the same time, and every setting described here affects both outputs equally.
All of it lives in the "Audio" section of the options menu (press Help). Out
of the box, AExp sounds like a real Amiga 500 — including the machine's two
famous audio filters, one of which is wired to the power LED. Really. The
story is below.

## Volume

The volume control works in 5% steps, and the percentages describe what you
hear: 50% sounds half as loud as 100%, 25% a quarter as loud. At the default
of 100% the control is completely transparent, and 0% is a true mute. Think
of it as the volume knob on your monitor — it sits outside the emulated
Amiga, so games and demos cannot tell it is there.

## Stereo Mix

The Amiga has four sound channels, and they are hard-wired in a way that was
common in the 1980s: channels 1 and 4 play entirely on the left, channels 2
and 3 entirely on the right. On speakers standing on a desk this sounds fine,
because the room blends the two sides for you. On headphones there is no
room: an instrument that lives only in your left ear, while the drums hammer
only in your right, gets tiring quickly — most Amiga music was simply not
mixed for headphones.

The Stereo Mix setting blends a little of each side into the other, exactly
like the MiSTer Amiga core does:

* **Full Stereo** — the authentic hard-panned output (the default).
* **Wide Stereo** — a gentle blend (87.5% own side, 12.5% opposite side).
* **Narrow Stereo** — a stronger blend (75% / 25%).
* **Mono** — both channels merged; useful for single-speaker setups.

If you listen on headphones, try Wide or Narrow Stereo — the music keeps its
direction, but stops tearing at your ears.

## A500 Filter

Paula, the Amiga's sound chip, plays digital samples: a rapid staircase of
discrete values. A real A500 never sends that staircase to the line output
directly — a simple, always-on analog low-pass filter (gently rolling off
above roughly 4.4 kHz) rounds the hardest digital edges off first. That
rounding is a big part of the warm, slightly soft signature sound people
remember, and musicians of the day composed with it in place.

The **A500 Filter** switch recreates exactly that filter, and it is on by
default. Switching it off removes the fixed filter from the path — which is
not a fantasy configuration, by the way: it is essentially what Commodore
itself did years later in the A1200, which shipped without this filter and
is known for its brighter, crisper sound. So: on = classic A500, off =
A1200-style freshness.

## LED Filter — or: why does a filter have an LED?

Fair question, because at first sight a power LED and a low-pass filter have
absolutely nothing to do with each other. The connection is a lovely piece of
1980s engineering pragmatism.

Beyond the fixed filter described above, the Amiga contains a second, much
stronger low-pass filter (it cuts in around 3 kHz) that software can switch
on and off at any time. A switchable filter needs a control wire, and control
wires come from I/O chips whose pins were a scarce resource. Instead of
spending a new pin, Commodore's engineers looked at one that was already
there: the output that controls the brightness of the power LED. They simply
connected the filter to the same signal. One wire, two jobs.

The result, on every real A500: **power LED bright = filter engaged, power
LED dimmed = filter off.** You can literally see the sound change. When a
game or demo switches the filter off for brighter music, the power LED
visibly dims at that exact moment — and Amiga musicians used this
deliberately. ProTracker exposes it as its FILTER setting, songs can toggle
it mid-tune with a command, and countless games switch it off the moment
their title music starts. After a reset the filter is always on (LED bright)
until software decides otherwise.

The **LED Filter** switch in the menu controls whether AExp honors this
mechanism. On (the default), the emulated Amiga behaves exactly like real
hardware: the software running inside decides, live, whether the filter is in
the audio path. Off, the filter never engages, no matter what the software
does. Note that the MEGA65's own power LED does not mirror the emulated one —
you will hear the filter switching, but the light stays as it is.

## Which settings should I use?

* **Authentic A500** — the defaults: A500 Filter on, LED Filter on, Full
  Stereo. This is how the machine on your desk in 1989 sounded.
* **Bright and modern** — A500 Filter off, LED Filter off. This is the raw,
  unfiltered output of the sound chip: crisper and more "digital" than any
  real A500 ever sounded through its own output stage.
* **Headphones** — whatever else you choose, set Stereo Mix to Wide or
  Narrow Stereo.

Like all menu settings, the audio configuration is saved on the SD card
automatically, so your choice survives switching the core off and on again.
