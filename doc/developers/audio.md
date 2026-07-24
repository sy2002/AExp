# AExp audio notes

This note explains the AExp audio path: Paula, the Amiga-specific output
filters and the stereo crossfeed (both faithful ports from MiSTer's
`Minimig.sv`), the OSM master volume, and how all of that differs from the
generic MiSTer "audio improvements" filter that the M2M framework also
carries (and which AExp keeps disabled).

It is written for maintainers who know neither MiSTer nor the Amiga audio
hardware in detail. The short version is:

* The audio chain is: raw Paula -> A500 fixed low-pass (switchable) ->
  LED filter (follows the emulated power LED) -> stereo crossfeed ->
  OSM master volume -> both HDMI and analog output.
* The filters and the crossfeed live in `CORE/vhdl/audio_filters.vhd` and are
  bit-faithful to MiSTer `Minimig.sv`; the OSM defaults (A500 Filter on, LED
  Filter on, Full Stereo, 100% volume) reproduce a real A500.
* With both filters off and Full Stereo, the path is bit-transparent raw
  Paula, exactly the pre-filter behavior.
* The generic M2M `audio_out` filter is a different thing: MiSTer output
  conditioning, not an Amiga model. AExp has the right coefficients for it in
  `CORE/vhdl/globals.vhd` but keeps `qnice_audio_filter_o` tied to `'0'`.
* The end-user description of all of this is `doc/audio.md`.

## 1. What is Paula?

The Amiga 500 audio chip is called Paula. In a real A500, Paula plays four
8-bit DMA audio channels: two are mixed to the left output and two to the
right output. The Amiga software writes sample data into RAM, Paula fetches
it at the programmed period, and the analog output circuitry turns the result
into left/right audio.

Minimig models Paula and exposes a left and right digital sample stream:

```verilog
ldata[14:0]
rdata[14:0]
```

Those are 15-bit signed Paula samples (channels 0+3 summed to the left,
1+2 to the right — the sum of two sign-extended 14-bit voice products, so it
cannot overflow). MiSTer widens them to 16-bit signed PCM by shifting left
once (`{ldata, 1'b0}`); AExp does the same widening at the input of
`audio_filters.vhd`.

## 2. What MiSTer does

MiSTer has two relevant audio layers:

1. The core layer. For Minimig, this contains Paula and the Amiga-model
   filters.
2. The MiSTer system/output layer. This contains a generic final `audio_out`
   block used to prepare audio for the MiSTer output hardware.

This distinction matters. The MiSTer final `audio_out` filter and the
Amiga-specific A500 filters are not the same thing.

### 2.1 The Minimig/Amiga-specific filters

In MiSTer Minimig, Paula does not go straight to the final output stage.
`Minimig.sv` first builds `paula_smp_l` and `paula_smp_r`, then optionally
passes them through Amiga-model filters.

The local source is:

* `CORE/Minimig_MiSTerMEGA65/Minimig.sv`

The upstream source is:

* <https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/blob/MiSTer/Minimig.sv>

The relevant stages are:

* `lpf4400`: a first-order low-pass filter around 4.4 kHz. This models the
  fixed A500 output RC filter (the A1200 dropped it).
* `lpf3275`: a filter described in the source as "LPF 3000Hz 1st +
  3400Hz 1st". This models the switchable Amiga LED filter.

MiSTer controls those filters with these signals:

```verilog
wire flt_en    = ~status[48] ? pwr_led : status[47];
wire aud_1200  = status[49];
wire paula_pwm = status[50];
```

In plain language:

* `paula_pwm` selects an alternate PWM-volume Paula path (not ported).
* `aud_1200` bypasses the A500 fixed low-pass stage.
* `flt_en` controls the LED filter; the default "Auto(LED)" mode follows the
  Amiga power LED state live.

`pwr_led` is CIA-A PRA bit 1 inverted (`minimig.v`: `pwr_led = ~_led`), i.e.
`pwr_led = '1'` means "LED bright" means "filter engaged" — the classic
Amiga power-LED/audio-filter coupling.

MiSTer's stereo mix for Paula's hard-panned channels is a third piece: the
userio command `0xF2` stores a 2-bit `aud_mix` value that minimig merely
re-exports; the actual blending happens in MiSTer's framework
(`sys/audio_out.sv`, module `aud_mix_top`).

### 2.2 The generic MiSTer final audio_out filter

After the core has produced its final audio stream, MiSTer routes it through
`audio_out` (wired in `sys/sys_top.v`). This final stage synchronizes audio
into the output clock domain, can apply a configurable IIR filter, applies a
DC blocker, and supports attenuation and stereo-to-mono mixing.

The default coefficients in MiSTer Minimig are:

```verilog
aflt_rate = 7056000
acx       = 4258969
acx0      = 3
acx1      = 3
acx2      = 1
acy0      = -6216759
acy1      =  6143386
acy2      = -2023767
```

Those are generic MiSTer output-filter defaults, not Amiga-specific: the
same values appear in several MiSTer cores because this is part of the
shared output path.

## 3. What AExp implements

```text
Minimig Paula (15-bit signed L/R)
  -> audio_filters.vhd: widen to 16-bit signed ({data, 1'b0})
  -> audio_filters.vhd: lpf4400 A500 fixed low-pass   [OSM "A500 Filter", default ON]
  -> audio_filters.vhd: lpf3275 LED filter            [OSM "LED Filter" arms it; engaged = armed AND pwr_led]
  -> audio_filters.vhd: stereo crossfeed              [OSM "Stereo: %s", default Full Stereo]
  -> main.vhd audio_volume_proc: OSM master volume    [default 100% = bit-transparent]
  -> M2M av_pipeline (raw path, qnice_audio_filter_o = '0')
  -> HDMI audio and MEGA65 analog audio jack
```

`CORE/vhdl/audio_filters.vhd` is a faithful port of the `Minimig.sv` output
stage between Paula and the MiSTer framework:

* The two IIR instances reuse M2M's copy of MiSTer's 3-tap stereo IIR
  (`M2M/vhdl/controllers/MiSTer/iir_filter.v` — functionally identical to the
  submodule's `sys/iir_filter.v`, only declaration order differs) with the
  `Minimig.sv` coefficients verbatim; coefficient ports that `Minimig.sv`
  leaves unconnected are tied to zero, which is what synthesis makes of an
  unconnected input port.
* `ce` is `clk7_en or clk7n_en` (14.19 MHz). The IIR time-multiplexes both
  channels on it, so each channel updates at the 7.09 MHz rate the
  coefficients are designed for — the same clocking as MiSTer after their
  "Move filters to system clock" change.
* The lpf4400 runs unconditionally so its state is warm when switched into
  the path; the A500 Filter toggle only selects it. The lpf3275 is chained
  behind the model select exactly as in `Minimig.sv` (with the A500 Filter
  off it operates on the raw Paula mix).
* LED filter engagement is `led_filter_i and pwr_led_i`: the OSM toggle arms
  the mechanism, the emulated software controls it live (MiSTer "Auto(LED)"
  semantics; there is no "force always on" mode).
* MiSTer's `old_l0/old_l1` double-latch after the filter mux is their CDC
  into `CLK_AUDIO`; AExp does not need it because the M2M framework's
  `cdc_stable` handles the domain crossing downstream.

### 3.1 Filter properties worth knowing

Both filters have an intrinsic DC gain slightly above unity — a property of
the MiSTer coefficient sets, verified in simulation and present on MiSTer
hardware as well:

* `lpf4400`: gain 17/16 = +0.53 dB
* `lpf3275`: about x1.137 = +1.11 dB

Full-scale material can therefore hit the IIR's internal 16-bit saturating
clamp (`iir_filter.v`) with filters engaged. That is faithful MiSTer
behavior: graceful saturation, same clamp, same coefficients. Apart from the
gain, the measured responses match the analytic RC prototypes (4400 Hz
1st-order; 3000 Hz + 3400 Hz cascade) to within about 2% across the audio
band.

### 3.2 The stereo crossfeed

The crossfeed replicates MiSTer's `aud_mix_top` blends with identical
floor-shift arithmetic. In `aud_mix_top`, `pre_in` is the halved opposite
channel (`pre_out <= a2[16:1]`), so the effective blends are:

| OSM setting   | aud_mix | own side  | opposite side |
| ------------- | ------- | --------- | ------------- |
| Full Stereo   | 00      | 100%      | 0%            |
| Wide Stereo   | 01      | 87.5%     | 12.5%         |
| Narrow Stereo | 10      | 75%       | 25%           |
| Mono          | 11      | 50%       | 50%           |

All three blends are energy-preserving (the weights sum to 1.0), so the
crossfeed itself cannot clip; the MiSTer-style 17-bit clamp is kept as a
guard anyway. AExp computes both channels in the same cycle instead of
MiSTer's registered `pre_out` ping-pong — value-identical per sample, minus
one sample of opposite-channel delay that only exists at 48 kHz in MiSTer.

MiSTer configures the mix via userio command `0xF2`; in AExp that command is
a no-op (minimig's `aud_mix` output is unconnected in `minimig_m65.v`) and
`amiga_config.vhd` keeps sending `0xF2 = 0`. The OSM radio drives the
crossfeed directly instead.

### 3.3 The OSM master volume

The "Volume" control is a 21-position radio from 100% down to 0% in 5%
steps. `mega65.vhd` decodes the one-hot selection into a step index (0 =
mute, 20 = 100%, the default), and `main.vhd` turns the index into an
amplitude gain via `C_VOL_LUT` and multiplies the filtered stereo mix with
it (registered, so Vivado maps it to two DSP48 slices).

Design properties:

* The taper is perceptual, not linear in amplitude: each 5% step is a
  5 percentage-point change in perceived loudness, so 50% sounds half as loud
  as 100% (-10 dB) and 25% a quarter (-20 dB). The gain follows
  `(percent/100)^1.661`, stored as unsigned Q15. The LUT values are identical
  to C64MEGA65, so both cores sound alike at the same slider position.
* 100% multiplies by Q15 `0x8000`, which is exactly transparent.
* The gain never exceeds 1.0, so the multiply can never clip; 0% is a true
  digital mute.
* The volume is the last stage in `main.vhd`, after the filters and the
  crossfeed: it models the volume knob on the monitor or amplifier, not part
  of the emulated machine. Everything Amiga-side stays untouched upstream:
  Paula's per-channel 6-bit volume registers, the 4-channel mix, and the
  filters.
* It is applied at the single point ahead of the M2M split into the HDMI and
  analog paths, so both outputs track exactly.

### 3.4 Menu plumbing

* `config.vhd`: "Stereo: %s" submenu (lines 83..91, radio group
  `OPTM_G_STEREO`), "A500 Filter" (line 92, `OPTM_G_A500FILT`) and
  "LED Filter" (line 93, `OPTM_G_LEDFILT`), both single-select with
  `OPTM_G_STDSEL` = default ON. All three are HDL-read; no firmware logic is
  involved.
* `mega65.vhd`: `C_MENU_STEREO` (86..89) is decoded into MiSTer's 2-bit
  `aud_mix` encoding; `C_MENU_A500FILT`/`C_MENU_LEDFILT` are wired straight
  into `main.vhd`. All in the core clock domain from the static
  `main_osm_control_i` vector, like the keyboard and VGA bits.
* The menu growth (OPTM_SIZE 103 -> 114, OPTM_DY 28 -> 31) required the
  usual QNICE menu-heap rebudget; the calculation lives next to
  `MENU_HEAP_SIZE` in `CORE/m2m-rom/m2m-rom.asm`.

## 4. The generic M2M "audio improvements" filter stays off

M2M always instantiates its `audio_out` block
(`M2M/vhdl/av_pipeline/av_pipeline.vhd`), a port of MiSTer's generic output
conditioning: an IIR low-pass with its -3 dB point around 18-20 kHz plus a
DC blocker. A mux selects raw versus filtered audio for both the analog and
the HDMI path, controlled by `qnice_audio_filter_o` — which AExp ties to
`'0'` in `mega65.vhd`.

The C64 and Game Boy MEGA65 cores expose exactly this switch as their
"Audio improvements" menu item. For AExp it stays off:

* Its audible effect on Amiga material is marginal (about -0.4 dB at 15 kHz,
  -2.6 dB at 20 kHz, plus DC removal).
* With the real A500 filters in place it is redundant, and a second,
  overlapping filter system in the menu would only confuse.

The `globals.vhd` coefficients for it are nevertheless correct and
MiSTer-Minimig-faithful (`audio_cx1 = 3`; the M2M template and C64MEGA65
carry a `cx1 = 2` typo worth roughly 0.4 dB), so enabling it later would be a
one-line experiment.

## 5. Verification

* `.research/tb_iir_amiga.v` (iverilog) drives both IIR instances exactly as
  `audio_filters.vhd` instantiates them and checks the measured gains at DC,
  1 kHz, 3.2 kHz, 4.4 kHz and 10 kHz against the analytic RC prototypes
  scaled by the intrinsic DC gains, plus channel-separation of the
  time-multiplexed stereo core (right channel silent while the left plays).
* `.research/tb_audio_filters.vhd` (nvc, with the `+100`-offset IIR stub
  `iir_stub_sim.vhd`) proves the glue: bit-transparent bypass with everything
  off, the A500/LED mux decisions, LED gating (armed AND live `pwr_led`),
  and all crossfeed blends against golden values computed by an independent
  Python implementation of the `aud_mix_top` arithmetic.

## 6. Practical conclusion

The default sound of AExp is the sound of a real A500: fixed filter in,
LED filter under software control, hard-panned stereo. The brightest possible
configuration (both filters off) remains available in the menu and is
bit-transparent raw Paula. The stereo crossfeed is a pure listening-comfort
option with no authenticity cost while it is off. The generic M2M output
filter remains a deliberate non-feature.
