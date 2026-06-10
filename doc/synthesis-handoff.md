# First synthesis — handoff notes (Milestone 1: Kickstart "insert disk" screen)

State as of 2026-06-10: all sources prepared and statically verified
(nvc 1.21 + GHDL 5.1 for VHDL, Icarus Verilog for Verilog; 5-agent
adversarial review completed, all blockers fixed). Vivado is the next
arbiter — it runs in the Parallels VM.

## 1. Pre-flight (on the Mac, already done — only repeat if sources changed)

The QNICE firmware is prebuilt because the Vivado pre-synth hook
(`synth_pre.tcl`) can FAIL SILENTLY on Mac/VM setups (known M2M issue):

```
cd CORE/m2m-rom && ./make_rom.sh     # produces m2m-rom.rom
```

Re-run whenever `m2m-rom.asm` or the `C_VDNUM`/`C_CRTROMS_*` constants in
`CORE/vhdl/globals.vhd` change. Check that `CORE/m2m-rom/m2m-rom.rom` is
newer than those files before synthesizing.

## 2. In the Parallels VM

1. Vivado 2022.2 or newer.
2. Open **`CORE/CORE-R3.xpr`** (top module `mega65_r3`, part xc7a200tfbg484-2).
   (R4/R5/R6 projects are synced too, but R3 is the target.)
3. Optional fast first check: *Open Elaborated Design* — catches port/binding
   errors in minutes instead of an hour of synthesis.
4. *Generate Bitstream*. Output: `CORE/CORE-R3.runs/impl_1/mega65_r3.bit`.

## 3. What to bring back to Claude

Whether it succeeds or fails, please bring:

| Artifact | Where |
|---|---|
| Synthesis log | `CORE/CORE-R3.runs/synth_1/runme.log` |
| Elaboration/synthesis error messages (if any) | Vivado messages pane — full text incl. file/line |
| Utilization report | `CORE/CORE-R3.runs/impl_1/*_utilization_placed.rpt` (**BRAM section is the critical one — expect ~90%**) |
| Timing summary | `CORE/CORE-R3.runs/impl_1/*_timing_summary_routed.rpt` (WNS/TNS) |

**Check the synthesis log specifically for** (these MUST NOT appear):

- `cannot open file ... microrom.mem` / `nanorom.mem` — fx68k microcode not
  found ⇒ would synthesize a *dead CPU without any error*. The paths are
  relative to the synth run dir (`../../Minimig_MiSTerMEGA65/rtl/fx68k/...`).
- Amiga memories implemented as registers/LUTRAM instead of block RAM
  (search for `dualport_2clk_ram` / `ram_t` in the utilization report; the
  six Amiga lanes are 2×256K×8 chip, 2×256K×8 slow, 2×128K×8 kick).

**Expected warnings (harmless, do not chase):**

- `rom_readonly` undriven in `minimig.v` (inherited from upstream; kick BRAM
  is write-protected by construction on our side)
- use-before-declaration style in the Minimig sources (upstream style)
- shared-variable warnings on `tdp_ram.vhd`/`2port2clk_ram.vhd` (framework)
- many unconnected-port warnings on `minimig_m65`, `cpu_wrapper`, `minimig`
  (deliberate tie-offs/opens)
- pruned logic in `cpu_wrapper` (the removed-68020 mux branches, cpucfg="00")
- `gamma_corr` black box inside `video_mixer.sv` (GAMMA=0 generate branch,
  never elaborated; identical in C64MEGA65)

## 4. SD card setup (for the hardware test after a successful build)

- FAT32, max 32 GB. Back slot has precedence over the bottom slot.
- **Mandatory:** `/amiga/kick.rom` — raw **256 KB** dump of
  **Kickstart 1.3 (rev 34.5, A500/A1000/A2000)**, big-endian as dumped,
  **no byte swapping**. Without it the Shell shows a fatal error with the
  file name and the core will not start (by design).
- Optional: `/amiga/aexpcfg` for persistent OSM settings
  (create with `M2M/tools/make_config.sh`, must be exactly 21 bytes =
  OPTM_SIZE; without it, settings simply aren't saved).

## 5. Running the core

- JTAG: `m65 -q CORE-R3.runs/impl_1/mega65_r3.bit` (mega65-tools)
- or convert: `bit2core mega65r3 <bit> "Amiga 500 AExp" V0.1 aexp.cor` and
  flash via the No Scroll boot menu.
- R3/R3A HDMI back-powering gotcha: power on the MEGA65 *before* the display.

## 6. Expected behavior on success

1. M2M welcome screen (mentions `/amiga/kick.rom`) — press Space.
2. Shell loads the Kickstart (mandatory auto-load) while the core is in reset.
3. Amiga boots: dark gray → light gray screen, then after ~2–4 s the
   Kickstart 1.3 **"insert disk" hand**, in color, stable 50 Hz PAL on both
   VGA (scandoubled 31.25 kHz) and HDMI (720p50).
4. Help key opens the OSM (HDMI modes / CRT emulation / Audio improvements).

If the screen stays black: bring the logs above plus, if possible, the QNICE
debug console output (115200 8N1 serial; Run/Stop+Cursor-Up, then Help).
