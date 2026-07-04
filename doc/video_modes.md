# Amiga video modes, flicker, and interlace handling in AExp

This document collects everything the AExp port needs to know about Amiga OCS display modes: which modes exist, which of them flicker and *why*, how the AExp video chain (minimig → M2M framework → ascal → HDMI 720p50) handles each case, and how to test it. It also contains the Batman Rises case study, because that demo exercises nearly every flicker category at once.

Companion documents: `doc/how_to_port.md` (M2M architecture, video pipeline contract), `doc/synthesis-handoff.md` (build history).

## 1. OCS video modes primer

### 1.1 Baseline timing (PAL, what AExp emulates)

- Denise outputs **lores 320** or **hires 640** pixels per line (140 ns / 70 ns pixels; 7.09 / 14.19 MHz pixel rates).
- Line rate 15.625 kHz (from the 28.375 MHz master clock), 312/313 lines per frame, ~50 Hz vertical.
- **Non-interlaced PAL output is NOT broadcast-style alternating fields**: minimig's Agnus resets `long_frame` to 1 and only toggles it when LACE is set (`agnus_beamcounter.v:334-338`), so progressive PAL is a constant stream of 313-line frames at 15625/313 = 49.92 Hz. Every scanline is repainted every frame — rock stable on any display.
- Visible area: 256 lines standard, up to ~288 with overscan; the copper and display windows make "resolution" a soft concept on Amiga (any line can change mode — see §5.4).

### 1.2 Color modes — all purely spatial, none of these flicker

| Mode | Planes | Colors | Mechanism |
|---|---|---|---|
| Standard | 1–5 | 2–32 of 4096 | palette registers |
| EHB (Extra Half-Brite) | 6 | 64 | 6th plane halves RGB of the 32 base colors |
| HAM6 (Hold-And-Modify) | 6 | all 4096 | 2 control + 4 data bits: "set" indexes 16 base registers, "modify" copies the previous pixel and replaces one RGB nibble; artifact is up to 3 px horizontal fringing |
| Dual playfield | 2×1–3 | 2×8 | two independently scrolling playfields |
| Copper tricks | — | hundreds | per-line palette rewrites (raster bars, Sliced HAM, Dynamic HiRes) — identical every frame |

### 1.3 Interlace — the resolution doubler that flickers

Interlace is enabled by **BPLCON0 bit 2 (LACE)**. Agnus then:

- auto-toggles the **LOF** ("long frame") flag — readable as VPOSR bit 15, writable via VPOSW bit 15 (demos abuse the write to force field parity);
- alternates a **long field (313 lines)** with a **short field (312 lines)**;
- marks field identity **solely by a half-scanline vertical-sync offset**: the long field starts vsync at `hsstrt`, the short field at `hcenter` (mid-line) — `agnus_beamcounter.v:388-394`, exactly like real hardware.

On a CRT the half-line offset shifts the raster of every other field down by half a line pitch, weaving the two fields into **320×512 / 640×512**. The software side (copper list) re-points the bitplane pointers each field: odd picture lines in one field, even lines in the next. The price:

- each screen line is repainted only at **25 Hz** → "interlace twitter": one-line-high, high-contrast detail blinks visibly even on a real CRT;
- Commodore sold **flicker fixers** against this (A2320, the A3000's Amber, later Indivision): store fields in RAM, output both woven at 31 kHz progressive. A field-aware deinterlacer in an FPGA scaler is the same idea.

Minimig exports both `lace` and `field1` (`field1 = ~long_frame`, `agnus_beamcounter.v:361`) up through `minimig.v` to our shim `minimig_m65.v` (ports `lace`, `field1`).

Typical OCS use of interlace: static high-resolution imagery — laced hires title pictures, laced HAM slideshows, Workbench 640×512 — where the twitter was tolerated in exchange for resolution.

### 1.4 Temporal tricks — flicker BY DESIGN

Alternating two images or palettes on successive 50 Hz frames fakes:

- extra colors ("flicker blending", 50%-mix shades),
- transparency and glow effects,
- more than 8 sprites/objects.

On a CRT, phosphor decay plus eye integration averages consecutive frames into a soft in-between shade with mild shimmer. On a sample-and-hold LCD each variant is held at full brightness for 20 ms, so the eye sees a hard 25 Hz square-wave blink. **This is authentic behavior — it looks the same on a real A500 connected to a flat panel.** No core change can or should "fix" it; only a CRT (or an artificial frame-blend filter, which AExp deliberately does not have) softens it.

Distinguishing the two flicker classes:

| | Interlace (fixable) | Temporal blend (authentic) |
|---|---|---|
| What alternates | odd/even *line sets* of one image | two *whole images/palettes* |
| Field-blind scaler shows | violent line shimmer, text strokes vibrate | clean 25 Hz brightness/color blink |
| Real A500 + CRT shows | mild line twitter | soft blended mix |
| Cure | field-aware weave (§3) | none (by design) |

## 2. Case study: Batman Rises (Batman Group, 2022)

Reference: pouet.net prod 93011; official 50 fps capture `youtube.com/watch?v=bEiouXja3PI`. The release readme states: *"This demo uses special video modes. If possible, watch it on the real hardware and CRT monitor"* and requires a true 50 Hz display in WinUAE (*"if not available some demo parts will not be displayed correctly"*). Hardware requirements match AExp exactly: OCS, 512 KB Chip + 512 KB Slow.

What the opening minutes contain:

- **0–13 s, red poem text**: static in the reference capture. On a field-blind chain it flickers violently — the signature of a **laced screen** (static content, but each field scaled as a full frame). Suspected laced; to be confirmed on hardware with the weave fix in place (§3). The demo verifiably uses interlace somewhere (pouet: "bold usage of interlacing").
- **36–53 s, Gotham nightscape**: the window lights and neon signs alternate every frame — **intentional** 25 Hz temporal flicker. Frame analysis of the official capture shows only ~0.03% of pixels alternating, exactly the windows/neons, with no field signature. Coder Rhino on pouet: *"Some flickering on some screens is even wanted, for example on the Gotham City lights."*
- **64–75 s, the explosion**: full-screen strobe — intentional.
- An official "60 Hz" video exists in which the city-lights alternation is blended away — made for 60 Hz displays precisely because the temporal effects need true 50 Hz.

So Batman Rises shows **both flicker classes**: the temporal effects stay (authentic), the laced screens are what the weave deinterlacer fixes. Running the core in HDMI 720p **50 Hz** mode is required viewing — at 60 Hz output the temporal effects would break up irregularly.

## 3. How AExp handles interlace: field-aware weave in ascal

### 3.1 The signal chain

The interlace field flag travels from Agnus to the scaler entirely inside the 28.375 MHz video clock domain (no CDC anywhere):

```
agnus_beamcounter.v  field1 = ~long_frame
  -> minimig.v -> minimig_m65.v (ports lace, field1)
  -> CORE/vhdl/main.vhd         field1 => video_fl_o   (lace stays open, see 3.4)
  -> CORE/vhdl/mega65.vhd       video_fl_o
  -> M2M/vhdl/top_mega65-r*.vhd signal video_fl        (all four boards)
  -> M2M/vhdl/framework.vhd     video_fl_i (default '0')
  -> M2M/vhdl/av_pipeline/av_pipeline.vhd   (bypasses i_crop: fl is
       frame-level metadata; ascal evaluates it only at frame granularity)
  -> M2M/vhdl/av_pipeline/digital_pipeline.vhd
  -> ascal port i_fl, generic INTER => true
```

This mirrors MiSTer exactly: `Minimig.sv:702` (`assign VGA_F1 = field1`) → `sys_top.v` (`.i_fl(f1)`) → ascal with INTER left at its default `true`.

All M2M framework changes are tagged **`M2M-UPSTREAM interlace (AExp 2026-07-04)`** (greppable) and are meant to be upstreamed to MiSTer2MEGA65; the new framework inputs default to `'0'` so existing progressive-only cores are unaffected. Until upstreamed, this is the one sanctioned local modification of `M2M/`.

### 3.2 What ascal does with the field flag

ascal (temlib) detects interlace **only from `i_fl` toggling** — never from line counts or the half-line vsync offset (`ascal.vhd:1184-1191`): an `i_fl` edge arms a 3-frame counter; while it is nonzero, `i_inter` is high. Consequences:

- **Progressive content (`i_fl` constant): behavior is bit-identical to the old `INTER => false` build.** The detector never arms.
- **Laced content**: each field is written to every other line of the HyperRAM framebuffer, the odd field with a one-line address offset (`ascal.vhd:1205-1214`, 1528-1538); the stored image height doubles (`i_vsize <= 2*i_vmaxmin`, `ascal.vhd:1290-1294`). The output side reads the woven full-height image → **weave deinterlacing**: laced static pictures (the dominant Amiga use case) render as stable full-resolution 512-line images. Motion shows classic weave combing — same as MiSTer.
- Detection disarms three vsyncs after toggling stops, so laced↔progressive switches recover automatically (up to ~3 frames of transition artifacts, same as MiSTer).
- The input geometry is sampled only on one field while interlaced (`ascal.vhd:1243,1251`), so the alternating 312/313-line field lengths do not make the auto-detected window jitter.

### 3.3 Sizing and configuration facts (why nothing else had to change)

- **Framebuffer**: `RAMSIZE` is 2^ceil(log2(720×576×3)) = 2 MB (`digital_pipeline.vhd`, from `VGA_DX`/`VGA_DY` 720×576 in `globals.vhd`). A woven PAL frame is ≤ ~577 lines × 2176 bytes ≈ 1.25 MB — fits. The ADF image window starts at HyperRAM byte address 4 MB (`C_HMAP_ADF_DF0`) — no collision.
- **Half-frame fallback**: ascal weaves only if the output height is at least 2× the field height (`ascal.vhd:1286-1294`); at 720p out vs ≤288 active lines per field this always holds for PAL. (A hypothetical 480-line output mode would silently fall back to scaled half-frames = bob.)
- **Triple buffering stays off**: the firmware's HDMI Filter dispatcher writes only ascal modes 0x0000-0x0004 (`M2M/rom/sysdef.asm:119-123`, `m2m-rom.asm` HDMI_FLT_TABLE) — bit 3 (triple buffering) is never set. Weave works in the single buffer. Do not enable triple buffering without re-checking the HyperRAM map: 3 × 2 MB would collide with the ADF window at 4 MB.
- **vsync path**: minimig's half-line vsync offset physically survives to ascal's `i_vs` (only combinational inversion in `main.vhd` and one register in `crop.vhd`), but ascal ignores it — field identity comes exclusively from `i_fl`. No sync conditioning was needed.
- The frame-locked video CE in `main.vhd` (7.09/14.19 MHz) is unaffected: it latches per vsync edge and has no fixed-frame-length assumption.

### 3.4 Known limitations (deliberate)

- **VGA/analog output stays field-blind.** The M2M scandoubler (`video_mixer.sv`/`scandoubler.v`) has no field input and line-doubles each field independently — laced content bobs on VGA. MiSTer's answer is to switch the analog output to raw 15 kHz during lace (`Minimig.sv:678`: `scandoubler = ... & ~lace`), which is ideal for 15 kHz CRTs and fatal for VGA LCDs. AExp keeps the scandoubler always on for now (`qnice_scandoubler_o <= '1'`, `mega65.vhd`); minimig's `lace` output is left unconnected in `main.vhd` until a decision is made (candidate: OSM option "VGA: 15 kHz when laced"). HDMI is the primary output and is fully handled.
- **Weave combing on motion.** Content that moves between fields shows comb artifacts, as on every weave deinterlacer (MiSTer included). Static imagery — the dominant use of Amiga lace — is perfect.
- **Polyphase filter appearance changes on laced screens.** The HDMI Filter presets are tuned for the 2.5× vertical scale of 288→720; a woven 576-line frame scales 1.25×, so scanline/CRT presets look different (finer) there. Cosmetic; MiSTer has a separate interlace-filter setting for the same reason (`vfilter_interlace`), which M2M does not implement.
- **Frame-rate seam.** The core's 49.92 Hz vs HDMI's exact 50.000 Hz means one repeated/dropped frame roughly every 12 s (single-buffer read/write crossover drift). Pre-existing behavior, independent of interlace; on laced content the seam can appear as a one-frame comb blip.

## 4. Test recipes

- **Workbench 1.3 interlace**: the Preferences "Interlace" setting is stored in `devs:system-configuration` on the boot floppy and takes effect at reboot. **On AExp the boot ADF is mounted read-only (writes are silently discarded), so saving it on the core does not survive a reboot** — the toggle appears to "jump back to off". Recipe: in WinUAE, mount a *copy* of the WB 1.3 ADF writable, set Preferences → Interlace ON, Save, quit; copy the modified ADF to the SD card; boot it on AExp. Workbench then comes up in 640×512 laced — the definitive interlace test image (crisp static text: weave shows it rock-solid, bob makes it vibrate).
- **Batman Rises**: the poem text at the very start (suspected laced) and the demo's laced part(s); the Gotham city lights (36–53 s) and the explosion strobe (64–75 s) must keep flickering — they are the demo's intended look. Compare against the official 50 Hz capture.
- **Behavior checklist for hardware verification**: laced static screens stable at full vertical resolution; progressive demos/games pixel- identical to the previous build (INTER is neutral while `i_fl` is constant); laced↔progressive switches recover within a few frames; OSM overlay unaffected; VGA output unchanged (still bobs on laced — known limitation).

## 5. Reference notes

### 5.1 Key registers

| Register | Bit | Meaning |
|---|---|---|
| BPLCON0 (`$DFF100`) | 2 | LACE — interlace enable |
| BPLCON0 | 15 / 11 / 10 | HIRES / HAM / dual playfield |
| VPOSR (`$DFF004`) | 15 | LOF — long frame flag (auto-toggles when LACE) |
| VPOSW (`$DFF02A`) | 15 | LOF write (demos force field parity) |

(Register addresses appear here in code spans on purpose; see the Amiga Hardware Reference Manual, Appendix A.)

### 5.2 Where things live in the code

| Concern | Location |
|---|---|
| Field/lace generation | `CORE/Minimig_MiSTerMEGA65/rtl/agnus_beamcounter.v` (`long_frame`, `field1`, half-line vsync) |
| Field export from the core | `CORE/vhdl/main.vhd` (`video_fl_o`), `CORE/vhdl/mega65.vhd` |
| Framework plumbing | `M2M/vhdl/top_mega65-r*.vhd`, `framework.vhd`, `av_pipeline/av_pipeline.vhd`, `av_pipeline/digital_pipeline.vhd` — all tagged `M2M-UPSTREAM interlace (AExp 2026-07-04)` |
| Weave engine | `M2M/vhdl/av_pipeline/ascal.vhd` (generic `INTER`, port `i_fl`) |
| MiSTer precedent | submodule `Minimig.sv:678,702`, `sys/sys_top.v` (`.i_fl(f1)`) |

### 5.3 Upstreaming to MiSTer2MEGA65

`grep -rn "M2M-UPSTREAM interlace" M2M/` lists the complete framework delta: one `std_logic` input (`video_fl_i`, default `'0'`) through framework → av_pipeline → digital_pipeline, `INTER => true` on the ascal instance, and the four board tops. Newer MiSTer ascal versions add a `bob_deint` input (half-line-compensated bob as an alternative to weave); worth considering when M2M upgrades its ascal copy.

### 5.4 Why Amiga scaling stays hard

MiSTer's author on Minimig scaling: the Amiga has no fixed resolutions and no reliable blanking to hook — resolution can change on any line, and demos switch laced/progressive mid-run. Occasional glitches on mode switches (a few frames) are inherent to any scaler-based approach; AExp's fixed 720p50 output timing means such switches never renegotiate the HDMI link (no screen blanking), unlike MiSTer with `vsync_adjust=2`.
