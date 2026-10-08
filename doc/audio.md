# Audio: volume, stereo and the Amiga's filters

AExp plays the Amiga's sound on HDMI and on the MEGA65's 3.5 mm audio jack at
the same time, and every setting described here affects both outputs. The one
exception is the
[DVI (no sound)](../README.md#dvi-no-sound-when-the-screen-stays-black)
option, which switches the HDMI audio off and leaves the jack.

All settings are in the "Audio" section of the options menu (press Help). Out
of the box, AExp sounds like a real Amiga 500, including the machine's two
audio filters. One of them is coupled to the power LED, for reasons explained
below.

## Volume

The volume control works in 5% steps, and the percentages describe what you
hear: 50% sounds half as loud as 100%, 25% a quarter as loud. At the default
of 100% the sound passes through unchanged, and 0% is a true mute. The
control works like the volume knob on your monitor: it sits outside the
simulated Amiga, so games and demos cannot tell it is there.

## Stereo Mix

The Amiga has four sound channels, wired in a way that was common in the
1980s: channels 1 and 4 play only on the left, channels 2 and 3 only on the
right. On desk speakers this sounds fine, because the room blends the two
sides. Headphones have no room, and an instrument that plays only in your
left ear while the drums play only in your right gets tiring quickly. Most
Amiga music was not mixed for headphones.

The Stereo Mix setting blends some of each side into the other, the same way
the MiSTer Amiga core does:

* **Full Stereo**: the authentic hard-panned output (the default).
* **Wide Stereo**: a gentle blend (87.5% own side, 12.5% opposite side).
* **Narrow Stereo**: a stronger blend (75% / 25%).
* **Mono**: both channels merged, for single-speaker setups.

On headphones, try Wide or Narrow Stereo: the music keeps its direction but
is easier on the ears.

## A500 Filter

Paula, the Amiga's sound chip, plays digital samples: a rapid staircase of
discrete values. A real A500 never sends that staircase to the line output
directly. An always-on analog low-pass filter, rolling off gently above
roughly 4.4 kHz, first rounds off the hardest edges. That filter is a large
part of the warm, slightly soft sound people remember, and the musicians of
the time composed with it in place.

The **A500 Filter** switch recreates that filter and is on by default.
Switching it off removes the fixed filter from the path, which is essentially
what Commodore did in the A1200: it shipped without this filter and is known
for its brighter, crisper sound. On gives you the classic A500, off an
A1200-like sound.

## LED Filter

Besides the fixed filter, the Amiga contains a second, much stronger
low-pass filter (it cuts in around 3 kHz) that software can switch on and off
at any time. A switchable filter needs a control line, and the pins of the
Amiga's I/O chips were scarce. So Commodore connected the filter to a signal
that already existed: the one that sets the brightness of the power LED.

On every real A500, therefore, **power LED bright means filter on, power LED
dimmed means filter off.** When a game or demo switches the filter off for
brighter music, the power LED dims at the same moment. Amiga musicians used
this on purpose: ProTracker exposes it as its FILTER setting, songs can
toggle it mid-tune with a command, and many games switch it off when their
title music starts. After a reset the filter is on (LED bright) until
software changes it.

The **LED Filter** switch in the menu decides whether AExp honors this
mechanism. On (the default), the simulated Amiga behaves like real hardware:
the running software decides, live, whether the filter is in the audio path.
Off, the filter never engages, whatever the software does. The MEGA65's own
power LED does not mirror the simulated one, so you hear the filter switch
but the light stays as it is.

## Which settings should I use?

* **Authentic A500**: the defaults, A500 Filter on, LED Filter on, Full
  Stereo. This is how an A500 sounded in 1989.
* **Bright and modern**: A500 Filter off, LED Filter off. This is the raw,
  unfiltered output of the sound chip, crisper and more "digital" than any
  real A500 sounded through its own output stage.
* **Headphones**: whatever else you choose, set Stereo Mix to Wide or
  Narrow Stereo.

Like all menu settings, the audio configuration is saved on the SD card
automatically, so your choice survives switching the core off and on again.
