# AExp audio notes

This note explains the AExp audio path, the MiSTer "Improve audio" style
filter, and how this differs from the Amiga-specific filters in Minimig.

It is written for maintainers who know neither MiSTer nor the Amiga audio
hardware in detail. The short version is:

* AExp currently outputs raw Paula audio.
* The `audio_*` constants in `CORE/vhdl/globals.vhd` are correct for the
  generic MiSTer final audio filter.
* That generic filter is not the Amiga A500 low-pass filter.
* Enabling it affects both HDMI and the MEGA65 analog audio jack.
* For the current alpha, keeping it disabled is the conservative default.
  Porting Minimig's Amiga-specific filters is the more meaningful audio
  improvement milestone.

## 1. What is Paula?

The Amiga 500 audio chip is called Paula. In a real A500, Paula plays four
8-bit DMA audio channels: two are mixed to the left output and two to the
right output. The Amiga software writes sample data into RAM, Paula fetches
it at the programmed period, and the analog output circuitry turns the result
into left/right audio.

For our purposes, the important detail is that Minimig already models Paula
and exposes a left and right digital sample stream:

```verilog
ldata[14:0]
rdata[14:0]
```

Those are 15-bit signed Paula samples. MiSTer widens them to 16-bit signed PCM
by shifting left once:

```verilog
{ldata[14:0], 1'b0}
{rdata[14:0], 1'b0}
```

AExp does the same thing in VHDL:

```vhdl
audio_left_o  <= signed(aud_ldata & '0');
audio_right_o <= signed(aud_rdata & '0');
```

That is the clean raw-Paula path. It is not obviously wrong; it is simply not
the full analog output model of an A500.

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
  fixed A500 output RC filter.
* `lpf3275`: a second filter described in the source as "LPF 3000Hz 1st +
  3400Hz 1st". This models the extra Amiga LED filter behavior.

MiSTer controls those filters with these signals:

```verilog
wire flt_en    = ~status[48] ? pwr_led : status[47];
wire aud_1200  = status[49];
wire paula_pwm = status[50];
```

In plain language:

* `paula_pwm` selects an alternate PWM-volume Paula path.
* `aud_1200` selects A1200-style audio behavior, bypassing the A500 fixed
  low-pass stage.
* `flt_en` controls the LED filter. In one mode it follows the Amiga power
  LED state; in another mode it is forced by the menu.

For an A500 OCS-focused port, these filters are the historically interesting
ones. They are what make the audio more like a real A500 output chain. They
also change the sound much more than the generic MiSTer output filter.

### 2.2 The generic MiSTer final audio_out filter

After the core has produced its final audio stream, MiSTer routes it through
`audio_out`. In upstream Minimig this is wired in `sys/sys_top.v`.

The local source is:

* `CORE/Minimig_MiSTerMEGA65/sys/sys_top.v`

The upstream source is:

* <https://github.com/MiSTer-devel/Minimig-AGA_MiSTer/blob/MiSTer/sys/sys_top.v>

This final stage does several generic jobs:

* It synchronizes the core audio into the MiSTer audio clock domain.
* It can apply a configurable IIR filter.
* It applies a DC blocker.
* It supports attenuation and stereo-to-mono mixing.
* It produces the samples used by the physical audio outputs.

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

Those are generic MiSTer output-filter defaults. They are not specific to the
Amiga. The same values appear in several MiSTer cores because this is part of
the shared output path.

## 3. What AExp currently does

AExp currently ships the raw-Paula path:

```vhdl
audio_left_o  <= signed(aud_ldata & '0');
audio_right_o <= signed(aud_rdata & '0');
```

The README documents this as:

```text
Audio is available on HDMI and on the 3.5 mm jack, carrying Paula's
output as-is.
```

The generic MiSTer final filter is present in the M2M framework, and AExp has
the right constants for it in `CORE/vhdl/globals.vhd`, but AExp disables it:

```vhdl
qnice_audio_filter_o <= '0';
```

So the current chain is:

```text
Minimig Paula
  -> AExp main.vhd: widen 15-bit signed Paula to 16-bit signed PCM
  -> M2M av_pipeline: select raw audio because qnice_audio_filter_o = '0'
  -> HDMI audio and MEGA65 analog audio jack
```

The Amiga-specific `lpf4400` and `lpf3275` filters from MiSTer Minimig are
not currently ported into AExp.

## 4. Where the M2M "Improve audio" switch sits

M2M always instantiates its `audio_out` block in:

```text
M2M/vhdl/av_pipeline/av_pipeline.vhd
```

The important mux is conceptually this:

```vhdl
if audio_filter = '0' then
   audio_left  <= audio_left_i;
   audio_right <= audio_right_i;
else
   audio_left  <= audio_filt_left;
   audio_right <= audio_filt_right;
end if;
```

The selected audio stream is then passed to both output paths:

* `analog_pipeline.vhd`, which feeds the MEGA65 analog audio jack.
* `digital_pipeline.vhd`, which feeds HDMI audio.

So this is not HDMI-only. If `qnice_audio_filter_o` is enabled in AExp, both
HDMI and analog output hear the filtered version.

## 5. Are the AExp globals.vhd constants right?

Yes. AExp currently has the right constants for the generic MiSTer final
`audio_out` filter:

```vhdl
constant audio_flt_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_signed(7056000, 32));
constant audio_cx       : std_logic_vector(39 downto 0) := std_logic_vector(to_signed(4258969, 40));
constant audio_cx0      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(3, 8));
constant audio_cx1      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(3, 8));
constant audio_cx2      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(1, 8));
constant audio_cy0      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-6216759, 24));
constant audio_cy1      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed( 6143386, 24));
constant audio_cy2      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-2023767, 24));
constant audio_att      : std_logic_vector( 4 downto 0) := "00000";
constant audio_mix      : std_logic_vector( 1 downto 0) := "00";
```

The notable value is `audio_cx1 = 3`.

The M2M template and C64MEGA65 currently carry `audio_cx1 = 2`, but MiSTer
Minimig's `sys_top.v` uses `acx1 = 3`. AExp follows MiSTer here, which is the
right provenance for an Amiga port.

## 6. What would enabling the generic filter sound like?

Probably subtle.

The generic MiSTer filter runs at a high internal rate, with `audio_flt_rate`
set to 7.056 MHz. In the normal audible range it is mostly flat. Using the
MiSTer default coefficients, the response is approximately:

| Frequency | Approximate change |
| --------- | ------------------ |
| 100 Hz    | effectively flat   |
| 1 kHz     | reference          |
| 5 kHz     | effectively flat   |
| 10 kHz    | effectively flat   |
| 15 kHz    | about -0.4 dB      |
| 20 kHz    | about -2.6 dB      |

It also includes a DC blocker. That is useful housekeeping: it removes
constant offset from the signal, which can help avoid clicks, bias, or wasted
headroom. The DC blocker is not meant to change music in the normal audible
band.

This means the generic filter is best understood as final output conditioning.
It is not the warm, obviously bandwidth-limited A500 output filter. The A500
character comes from the `lpf4400` and `lpf3275` stages in `Minimig.sv`.

## 7. Should AExp enable it by default now?

Recommendation: keep the generic M2M filter disabled by default for the
current alpha.

Reasons:

* The current README and implementation promise raw Paula output.
* The current hardware-tested milestone had the audio-improvements menu item
  removed and `qnice_audio_filter_o` tied to zero.
* Enabling the generic filter is not the same as implementing Amiga-authentic
  A500 filtering.
* Any default-on audio change should be tested on both HDMI and analog output.

If the goal is "closer to MiSTer's final output chain", then tying
`qnice_audio_filter_o` to `'1'` is a reasonable low-risk experiment. It should
not require new coefficients, and it should affect both HDMI and analog in the
same way. But it should be described as generic MiSTer output conditioning,
not as "A500 audio filtering".

If the goal is "closer to a real A500", spend the effort on porting
Minimig's `lpf4400` and `lpf3275` filters first.

## 8. Suggested roadmap

### Step 1: Keep alpha behavior explicit

Leave the current raw-Paula path in place:

```vhdl
qnice_audio_filter_o <= '0';
```

Keep the README wording "Paula output as-is" accurate.

### Step 2: Optional hidden A/B test

For local testing only, tie:

```vhdl
qnice_audio_filter_o <= '1';
```

Then compare the same demos and Workbench sounds over:

* HDMI audio
* MEGA65 analog audio jack
* headphones or a line-in recording, if available

Listen for:

* clicks or pops at reset and menu transitions
* clipping
* unexpected volume change
* stereo imbalance
* whether the difference is audible enough to justify changing the default

### Step 3: Port the real Amiga filters

For A500-style audio, port the two Minimig filters into AExp's `main.vhd`:

* `lpf4400`: fixed A500 output low-pass
* `lpf3275`: LED low-pass behavior

For an OCS A500 core, a simple first policy could be:

* A500 fixed low-pass: default on
* LED filter: follow the emulated Amiga power LED state if available
* menu override: later, only if users need it

After that, decide separately whether the generic M2M output filter should
also be enabled to match MiSTer's final output stage.

## 9. Practical conclusion

AExp is not currently "wrong". It is currently simple:

```text
raw Paula -> HDMI and analog
```

The `globals.vhd` constants are already correct for the generic MiSTer
`audio_out` filter, but that filter is disabled. Enabling it by default is a
reasonable experiment, not a necessary fix.

For now, the recommended default remains raw Paula. The next meaningful audio
quality step is to port the Amiga-specific Minimig filters, then make an
intentional default decision based on A/B testing.
