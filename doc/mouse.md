# Mouse support: findings, root cause, device/board matrix, fix concept

Status of this document: findings below are marked **[proven]** (verified against schematics, code or bench measurements) or **[assumption]** (plausible, still to be verified). Last updated 2026-07-04.

TL;DR: Movement and the left button of a real Amiga mouse work natively and smoothly. The right (and middle) button of a *passive* Amiga mouse is **electrically invisible to every MEGA65 board revision (R3 through R6)**, because the buttons short the POT pins to GND and nothing on the MEGA65 can pull those pins high; on a real Amiga, Paula itself drives them high. This is a board-level limitation, proven from the Trenz schematics, and the R4/R5/R6 "bidirectional joystick ports" do **not** help, because they cover only the five digital lines, not the POT pins. Active adapters (mouSTer style) that *drive* pin 9 can be supported on **all** revisions through the existing paddle sampler, once the core reads the line with Amiga-true polarity plus a device-presence latch. The RUN/STOP substitute stays as the universal fallback for passive tank mice.


## 1. Connector pinout and a naming trap

DE-9 gameport, as used by the Amiga mouse:

| Pin | Amiga function          | Amiga register channel      | MEGA65 schematic net (port A) |
|-----|-------------------------|-----------------------------|-------------------------------|
| 1   | V-pulse (quadrature)    | JOYxDAT                     | `JA_UP`                       |
| 2   | H-pulse (quadrature)    | JOYxDAT                     | `JA_DOWN`                     |
| 3   | VQ-pulse (quadrature)   | JOYxDAT                     | `JA_LEFT`                     |
| 4   | HQ-pulse (quadrature)   | JOYxDAT                     | `JA_RIGHT`                    |
| 5   | **Middle button** (opt.)| POTINP `DATLX` (bit 8)      | `JA_AY`                       |
| 6   | **Left button**         | CIA-A PRA (fire)            | `JA_FIRE`                     |
| 7   | +5 V                    |                             | `5V_JOY` (switched)           |
| 8   | GND                     |                             | GND                           |
| 9   | **Right button**        | POTINP `DATLY` (bit 10)     | `JA_AX`                       |

**[proven] Naming trap:** the Amiga reads pin 9 through the register channel it calls "Y" (`DATLY`/`OUTLY`, POTINP bit 10 for port 1), while the C64 world and the MEGA65 schematics call pin 9 "X" (`POTX`, net `JA_AX`). Minimig's `userio.v` follows the Amiga register view (`potcap[1]` gated by `potreg[11:10]` = `OUTLY`/`DATLY`, read back as POTINP bit 10); the M2M framework follows the C64 view (pin 9 = `paddle_i(0)` = "pot1 x"). Both are right in their own world. When wiring the right button, pin 9 therefore means `main_pot1_x_i` on the M2M side, even though the Amiga documentation calls that channel Y.


## 2. How a real Amiga reads the mouse buttons

**[proven]** The left button is a plain switch to GND on pin 6 (the fire line), read through CIA-A. Works identically in our port (fire input, 4K7 pull-up on the MEGA65 board).

**[proven]** The right and middle buttons are *passive switches to GND* on pins 9 and 5. There is no pull-up inside the mouse. The Amiga Hardware Reference Manual (chapter "Interface Hardware / Controller Port") describes the sanctioned read method:

> "To do this, set the proper pin to output, and drive the line high (set both OUT... and DAT... to 1). Reading POTGOR will produce a 0 if the button is pressed, a 1 if it is not."

In other words: **Paula itself acts as the pull-up.** AmigaOS (input.device) writes POTGO `$FF00`, which switches all four POT pins to weakly driven-high outputs, and then polls POTINP: bit 10 (port 1) / bit 14 (port 2) read 0 when the right button grounds the line. Minimig's `userio.v` models exactly this wired-AND: `potcap[1] <= _mright & _djoy1[5] & ~(potreg[11] & ~potreg[10])`.

Consequence: any hardware that wants to sense these buttons must be able to source current into pins 9/5. **The MEGA65 cannot** (next section).

Amiga software itself has no plausibility check on top of this ("was the line ever high?"): none is needed, because Paula's driver removes the ambiguous state physically. Even an *empty* port reads "released" on a real Amiga, since Paula holds the line high when nothing pulls it down. input.device simply polls POTINP every vertical blank and takes the bit at face value.

**What the emulated Amiga sees in our port [proven]:** Minimig's `userio.v` does not model the analog line at all. It *synthesizes* the POTINP bit from an abstract button boolean plus the emulated POTGO state: `potcap[1] <= _mright & _djoy1[5] & ~(potreg[11] & ~potreg[10])`, with `_mright = ~mouse_btn[1]` (our button signal; `_djoy1[5]` is tied inactive-high in our wiring). Paula's register-level semantics, including software driving the line low via POTGO, are emulated faithfully, but the default state is "released" and the only way to "press" the button is the `mouse_btn` input. The physical MEGA65 wire therefore ends at the `main.vhd` boundary; whatever ambiguity it carries must be resolved there (section 8), and inside the emulation Workbench always sees a clean, Paula-conformant register bit.


## 3. What the MEGA65 boards can and cannot do (schematic-proven)

Source: Trenz schematics in the local archive `~/.dev/MEGA65/doc/PCB/R{3,4,5,6,6A}/SCH-TE0765-0{3A,4...,5...,6...}.PDF` (sheets `JOY.SchDoc` and `B15.SchDoc`).

### 3.1 POT pins (5 and 9): sense-only, identical on R3, R4, R5, R6

**[proven]** Per POT pin, on *every* revision:

    DE-9 pin --- 1 kOhm (e.g. R14) ---+--- 1.2 nF to GND (e.g. C78)
                                      +--- 2N7002 drain FET, gate = Pulse-discharge
                                      +--- NC7SZ126 buffer (OE tied high) --- FPGA pin (CP0..CP3)

- **No pull-up** anywhere on the pin or the node. The only charge source is the connected device.
- The FPGA pin (`paddle_i[0..3]`, H13/G15/J14/J22) sits **behind a permanently enabled push-pull buffer**; an FPGA-internal pull-up therefore cannot reach the DE-9 pin, and the FPGA cannot drive the pin either.
- The only FPGA-controllable element is the shared discharge FET (`paddle_drain_o`), which can only pull the node LOW.
- R6's title-page note "schematics of analog signals JA_AX, JA_AY, JB_AX, JB_AY are changed" amounts to added 470 nF supply decoupling on the buffers; the signal topology is unchanged.

**Consequence [proven]:** a passive button that shorts pin 9 (or 5) to GND is indistinguishable from an unconnected pin on every MEGA65 revision. The tank mouse right/middle buttons cannot be made to work on this hardware, on any revision, by any FPGA change. Conversely, a device that **actively drives** the pin can be read fine: driving high charges the 1 kOhm / 1.2 nF node in about a microsecond, far faster than the sampler's 255 us counting window.

### 3.2 Digital lines (1, 2, 3, 4, 6): input-only on R3, "bidirectional" from R4 on

**[proven]** All revisions: each digital line has a **4.7 kOhm pull-up to the switched 5V_JOY rail** and an NC7SZ126 level-shifter buffer into the FPGA (input path).

**[proven]** R4, R5 and R6 additionally have, per line (10 in total), a `74AHCT1G125` tri-state gate wired as a **low-side driver**: its input is tied to GND, its active-low output-enable comes from a dedicated FPGA pin, its output sits on the DE-9 line. FPGA drives 0 = line pulled low, FPGA drives 1 = gate goes high-impedance and the 4K7 pull-up (or the device) owns the line. This is open-collector semantics, a wired-AND with whatever is plugged in. R3 does not have these gates; the corresponding FPGA pins were "NC" before R4 (change note: "Connected FPGA U1 pin J17 from NC to DBG0", etc.).

So the answer to "when did bidirectional joystick ports arrive" is: **R4** (and they stayed in R5 and R6). M2M exposes them on R4/R5/R6 as `fa_up_n_o` .. `fb_fire_n_o` (XDC pins J17/G16/K13/K14/N20/L16/M18/N19/ E18/M17 = DBG0..DBG9), passes the core's `main_joy*_o` straight through (`framework.vhd`, "Joystick outputs from the core are connected directly"), and the R4+ tops document the semantics: "0: Drive pin low (output). 1: Leave pin floating (input)". AExp currently parks all ten outputs at '1' (`CORE/vhdl/mega65.vhd`), i.e. all gates high-impedance: the ports behave as pure inputs. Correct and safe.

**Consequence [proven]:** the bidirectional capability is on the wrong pins for the mouse buttons. It cannot pull pins 9/5 high and it cannot read them. It does not help the tank mouse in any way. (Side note: it is also not enough for CD32 pads, which need the Amiga to *drive pin 5* and to read pin 9 at microsecond rates; both pins are POT pins. CD32 pads are therefore also impossible on current MEGA65 hardware.)

### 3.3 Port power

**[proven]** 5V_JOY is switched by an MP5010BDQ power switch on all revisions (R3 included); it defaults to ON, and the M2M R4+ tops keep it on (`joystick_5v_disable_o <= '0'`). Relevant for active adapters (mouSTer draws its power from pin 7).


## 4. The measuring path in our port (M2M framework)

**[proven]** The framework samples all four POT pins continuously (`M2M/vhdl/controllers/M65/mouse_input.vhdl`, instantiated in `qnice_wrapper.vhd` as a plain paddle ADC): drive `Pulse-discharge` for 256 us, release, then count (0..255, 1 MHz) how long the node stays below the buffer threshold. One full cycle every ~514 us (~1.9 kHz update rate).

- Undriven pin (nothing connected, or connected switch open): node stays low forever, **raw = 255**.
- Pin shorted to GND (tank mouse button pressed): node stays low, **raw = 255**. Same value: invisible, as per section 3.1.
- Pin actively driven high: node crosses the threshold in ~1 us, **raw = 0..2**.
- C64 paddle (pot to +5V): raw = charge time, the classic proportional reading.

The framework then inverts (`255 - raw`, `qnice_wrapper.vhd`) and delivers the values CDC'd into the core clock domain as `main_pot1_x_i` etc. So on the core side: undriven or grounded pin reads **0x00**, actively-driven-high pin reads **~0xFF**.

The `255 - raw` inversion is intentional framework behavior and must not be changed: it makes proportional paddle values run in the direction C64 software expects (C64MEGA65 depends on it). It is a value-scale convention for paddles, not a button convention; the C64 world never reads buttons through POT values (C64 paddle fire buttons sit on the digital left/right lines, and the 1351 mouse signals its right button on the digital UP line), which is why button semantics on the POT lines were simply outside the framework's original scope. Any button-polarity fix therefore belongs in this core's *interpretation* of the delivered value, not in the framework.

**[proven, bench 2026-07-03]** Two different physical tank mice, tested on real R3 hardware: movement and left button work; the right button changes nothing. Cross-check on the stock MEGA65 core in C64 mode (SID paddle registers `$D419`/`$D41A`, port select via `$DC00`): reading is 255 with the button released AND pressed, for both mice. This matches the schematic analysis exactly (raw 255 = "never charges" in both states).


## 5. Movement and left button (working since WIP-V1-A2)

Covered here for completeness; the deep material is in the git history of `rtl/userio.v`, `M2M/vhdl/debouncer.vhd` and `CORE/vhdl/main.vhd`:

- **Quadrature decoding [proven]:** Minimig's `userio.v` still contains the original 2007 "docking" mouse counters, which count the DE-9 quadrature transitions into JOYxDAT exactly like Denise. Two port-side defects had to be fixed for real mice: the input synchronizer ran at 28 MHz while the counters sample at `clk7_en` (3 of 4 transitions lost; fixed by gating the synchronizer with `clk7_en`), and the M2M framework debounced every direction line with a 1 ms stable-time filter that swallowed quadrature edges (fixed by turning the debouncer into plain 2-FF synchronizers; a real Amiga has no debouncing on these lines either).
- **Port mapping [proven]:** `userio.v` cross-maps its joystick inputs by default; `amiga_config.vhd` sets `joy_swap` (command `0xF9`, payload bit 3), so MEGA65 port 1 = Amiga port 1 (mouse) and port 2 = joystick, like on a real A500.
- **Left button [proven]:** rides the fire line into CIA-A, nothing special.


## 6. Right mouse button: current state (WIP-V1-A2) and its limits

The A2 build maps the right button as `mouse_btn(1) <= RUN/STOP-held OR main_pot1_x_i(7)`:

- **RUN/STOP substitute [proven working]:** key 63 has no Amiga keycode, its held state is exported from the keyboard mirror (`keyboard.vhd`) and acts as the right button. Universal fallback, works on all boards with all mice.
- **POT threshold [proven inert, wrong polarity]:** `main_pot1_x_i(7)` says "pressed" when the pin is *driven high*. With a tank mouse or an empty port the term never fires (reads 0x00, section 4), so it is harmless in practice. But it is **inverted with respect to real Amiga semantics** (pressed = line LOW, released = line HIGH). A spec-faithful active adapter that drives pin 9 high when released reads as *pressed when released and released when pressed* on the A2 build. Do not use an active mouse adapter with A2; the fix is the proposal in section 8. Note that with such an adapter plugged in, the RUN/STOP fallback is masked at idle (the OR term already asserts "held"), so A2 offers no clean workaround on the core side.

**Field confirmation [proven, 2026-07-04]:** an R6 user (NeonKnight, USB mouse adapter "MicroTom", no original Amiga mouse) reported that Workbench folder contents only load *while the right button is held* and stall when it is released. That is the textbook signature of the inversion: physically releasing the button makes the core report "RMB down", Intuition enters menu mode, and menu mode locks the screen's layers (standard Intuition behavior, also on real hardware: rendering blocks while menus are active), which stalls Workbench's read-icon/draw-icon loop; physically pressing ends menu mode and loading resumes. Joystick games were fine (digital lines, untouched path). The report simultaneously proves that this adapter class drives pin 9 to *both* levels through our sampler on R6, i.e. exactly the device class the section 8 latch serves; after the fix its right button is expected to work natively.


## 7. Device matrix

"Active adapter" means a device that drives pin 9 itself (mouSTer style, push-pull). "Open-drain adapter" means a device that only pulls pin 9 low when pressed and floats it otherwise (faithful clone of a passive mouse).

| Device / board              | R3                       | R4 / R5 / R6             |
|-----------------------------|--------------------------|--------------------------|
| Tank mouse: movement, LMB   | works                    | works (same circuit)     |
| Tank mouse: RMB/MMB         | impossible on pins 9/5, RUN/STOP substitute | identical, RUN/STOP substitute |
| Active adapter: RMB         | readable via paddle sampler, needs the polarity fix of section 8 | identical |
| Open-drain adapter: RMB     | invisible (same physics as tank mouse), RUN/STOP substitute | identical |
| Empty port                  | must not phantom-click: guaranteed by the presence latch (section 8) | identical |

The board revision does not appear in any row as a differentiator: **the mouse situation is identical on R3 through R6.** The R4+ bidirectional digital lines change nothing for mice.


## 8. Fix concept (implemented 2026-07-04 in `main.vhd`, `pot_buttons` process; targeted for the WIP-V1-A3 build)

One board-independent change in `CORE/vhdl/main.vhd`, no M2M changes, no XDC changes, no per-revision builds:

1. **Amiga-true polarity with a presence latch.**
   - `rmb_capable` latch: set once `main_pot1_x_i(7) = '1'` is observed (the line was actively driven high at least once, so an adapter that can signal the button is present); cleared on core reset.
   - `pot_rmb <= rmb_capable and not main_pot1_x_i(7);` (pressed = line low, exactly like POTINP on a real Amiga)
   - `mouse_btn(1) <= run_stop_held or pot_rmb;`
   - The latch is not an optional refinement, it is the load-bearing half
     of the fix: with Amiga-true polarity alone, an undriven line (tank
     mouse or empty port reads 0x00, section 4) would register as a
     permanently held right button. On a real Amiga, "low = pressed" is
     only safe because Paula guarantees the released state by driving the
     line high; the MEGA65 cannot provide that guarantee, so the latch
     substitutes it with observed evidence that the line can go high at
     all.
   - Tank mouse / empty port: line is never high, latch never sets, no phantom clicks, RUN/STOP does the job. Active adapter: RMB works natively, on every board revision.
   - Unplug support (required): auto-clear the latch when "pressed" persists for an implausibly long time (order 30-60 s; value to be fixed at implementation, via a constant/generic). Unplugging an active adapter leaves the pin floating, which reads exactly like "pressed"; the timeout ends the phantom press. Worst case for a legitimate marathon menu-hold: the button releases once, one extra click re-opens the menu. Re-arming is automatic: as soon as an adapter drives the line high again (replug, button release), the latch sets again within one sampler cycle (~0.5 ms).
2. **Middle button (optional, same pattern):** `mouse_btn(2)` from `main_pot1_y_i` (pin 5) with its own latch. Costs a handful of LUTs and makes 3-button adapters fully functional (`_mthird` feeds POTINP bit 8 in `userio.v`).
3. **Port 2 mouse buttons (out of scope for now):** `userio.v` wires the `mouse_btn` inputs to port 1's POTINP bits only; a second mouse in port 2 would need a small provenance-commented change there. Movement and LMB of a port 2 mouse already work.

Validation plan: bench-test with a real mouSTer (or any active adapter). Multimeter on its pin 9 against GND with the adapter powered: released should read high (3.3 V or 5 V), pressed low. If instead it floats when released (open-drain firmware), the adapter behaves like a tank mouse on MEGA65 hardware and only RUN/STOP can serve it; that is a firmware property of the adapter, not something the core can compensate.


## 9. mouSTer notes and the "works on R3" rumor

**[proven]** mouSTer (retrohax.net) is an active, port-powered USB-to-DE-9 adapter that emulates Amiga, Atari ST and C64 (1351) mice. Its configuration offers reversing the "2nd and 3rd button line polarity", which implies the button pins are MCU-driven rather than passive contacts.

**[assumption]** Whether its Amiga mode drives pin 9 push-pull (readable on MEGA65) or open-drain (invisible on MEGA65, see matrix) is not documented publicly and must be bench-verified; the polarity-reverse option and the 1351 mode (which *requires* actively driving the POT lines) make push-pull plausible. **[proven for at least one adapter]** The 2026-07-04 field report (section 6) shows a "MicroTom" USB adapter driving pin 9 to both levels through the sampler on an R6 board, so at least this adapter class is fully served by the section 8 fix. Adapters with a configurable button polarity (mouSTer has such an option) can even cancel the A2 inversion as a user-side workaround, at the price of having to flip the option back once the fixed core ships.

**Rumor assessment:** "with mouSTer, the right button already works on R3 today" is most plausibly an observation from the **C64 core** with mouSTer in **1351 mode**: the 1351 protocol signals the right button on the *digital UP line* (pin 1), which works through the plain joystick input path on every board revision and has nothing to do with pin 9. No MEGA65 Amiga-mode data point is known to us; the A2 build would actually show a push-pull mouSTer's RMB as *inverted* (section 6). After the section 8 fix, a push-pull mouSTer RMB is expected to work on all revisions, R3 included, which would make the rumor true for AExp going forward.


## 10. Open items

- [x] Implement the section 8 fix: done 2026-07-04, `main.vhd` `pot_buttons`
      process (RMB from `pot1_x`, MMB from `pot1_y`, per-button presence
      latch and watchdog, cleared on core reset). Synthesized in run 4
      (timing closed, see doc/synthesis-handoff.md) and regression-verified
      on real R3 hardware with a tank mouse the same day: movement, left
      button and RUN/STOP unchanged, no phantom clicks. Adapter-side
      verification still open (next item).
- [x] Latch auto-clear timeout fixed at 30 s (`C_POT_BTN_TIMEOUT`,
      30 x 28,375,000 clk_main cycles). Rationale: without it, unplugging
      an active adapter jams the right button permanently (only a core
      reset recovers) and even the routine mouse-to-joystick swap for
      two-player games breaks; with it, the worst legitimate cost is one
      interrupted 30-second-plus button hold.
- [ ] Bench-verify a mouSTer in Amiga mode (drive style, then RMB in Workbench on the fixed build); ask the R6 field tester to re-test with the fixed build.
- [ ] Consider upstreaming a note to mega65-core: its `mouse_input.vhdl` Amiga-mouse right-button mapping (`pota_x_internal(7)`, pressed = line high) cannot trigger with passive Amiga mice for the same board-level reason (no pull-up on the POT pins); it likely only ever worked with active adapters, if at all.


## 11. Sources

- Trenz schematics (local): `~/.dev/MEGA65/doc/PCB/R3/SCH-TE0765-03A.PDF` (JOY sheet p. 13, paddle circuit p. 6), `R4/SCH-TE0765-04-82C69-A.PDF` (JOY p. 12), `R5/SCH-TE0765-05-T001C.PDF` (JOY p. 14), `R6/SCH-TE0765-06-T001C.PDF` (JOY p. 14, paddle p. 8, change list p. 1).
- Amiga Hardware Reference Manual, "Interface Hardware / Controller Port": <https://www.theflatnet.de/pub/cbm/amiga/AmigaDevDocs/hard_8.html>
- mouSTer product page: <https://retrohax.net/shop/modulesandparts/mouster/> and Hackaday coverage: <https://hackaday.com/2023/02/16/the-mouster-adapter-now-has-amiga-scroll-support/>
- Code: `CORE/Minimig_MiSTerMEGA65/rtl/userio.v` (POTINP emulation, docking quadrature counters), `M2M/vhdl/controllers/M65/mouse_input.vhdl` (paddle sampler), `M2M/vhdl/qnice_wrapper.vhd` (inversion), `M2M/MEGA65-R{3,4,5,6}.xdc` and `M2M/vhdl/top_mega65-r{3,4,5,6}.vhd` (pin capabilities per revision), `CORE/vhdl/main.vhd` (mouse_btn wiring), `CORE/vhdl/keyboard.vhd` (RUN/STOP substitute).
