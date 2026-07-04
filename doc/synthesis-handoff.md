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
- Optional: `/amiga/aexp-<version>.cfg` for persistent OSM settings
  (the name derives from `CORE_VERSION` in config.vhd: `aexp-<version>.cfg`)
  (release packages built by `make_release.py` include it; for a dev SD
  card create it with `M2M/tools/make_config.sh <name> auto`, run from
  inside `M2M/tools`; must be exactly OPTM_SIZE bytes — 44 as of
  WIP-V1-A3; without it, settings simply aren't saved).

## 5. Running the core

- JTAG: `m65 -q CORE-R3.runs/impl_1/mega65_r3.bit` (mega65-tools)
- or convert: `bit2core mega65r3 <bit> "Amiga 500 AExp" V0.1 aexp.cor` and
  flash via the No Scroll boot menu.
- R3/R3A HDMI back-powering gotcha: power on the MEGA65 *before* the display.

## 6. Expected behavior on success

1. No welcome screen (switched off like in C64MEGA65): the Shell loads the
   Kickstart (mandatory auto-load) while the core is held in reset, then
   starts the core directly. If `/amiga/kick.rom` is missing, a fatal error
   screen names the file instead.
2. Amiga boots: dark gray → light gray screen, then after ~2–4 s the
   Kickstart 1.3 **"insert disk" hand**, in color, stable 50 Hz PAL on both
   VGA (scandoubled 31.25 kHz) and HDMI (720p50).
3. Help key opens the OSM (ADF mount / HDMI modes / HDMI Filter with eight
   options, default "Scanlines" / Audio improvements / About & Help, which
   documents the SD card setup).

If the screen stays black: bring the logs above plus, if possible, the QNICE
debug console output (115200 8N1 serial; Run/Stop+Cursor-Up, then Help).

---

## Post-run-1 findings (2026-06-10, run succeeded on HW, timing failed)

Run 1 verdict: boots to the Kickstart hand on real hardware; WNS -6.7 ns.
Fixes committed (fcf0a90): ascal FIFO CDC constraints in CORE.xdc + QNICE
debug port removed from chip/slow RAM. Re-run and re-check.

Facts from the run-1 synthesis log (full analysis: .research/review/ and
git log), relevant for all future milestones:

- BRAM is at TRUE capacity: 363.5/365 tiles. Vivado requested 380 and
  auto-demoted ~16.5 tiles to LUTRAM (warning Synth 8-5835), including the
  ascal line buffers (~4600 LUTs), Paula's floppy FIFO and the Denise CLUTs.
  There is nothing left to demote.
- Budget: 320 tiles = the six Amiga lanes (exact, no waste), 32 = QNICE
  ROM+RAM, ~11.5 = video pipeline.
- Re-enabling IDE/HDD costs +8 RAMB36 -> DOES NOT FIT. Any future buffer
  (ADF floppy images, HDD sector buffers) MUST live in HyperRAM.
- Synthesis is clean: 0 critical warnings, no inferred latches, no
  multi-driven nets, fx68k microcode ROMs read successfully.
- Later-milestone cleanups (benign today): 4x Synth 8-7137 set/reset same
  priority (cpu_wrapper.v:387/:405, paula_floppy.v:208/:214 - sim-mismatch
  risk only), minimig.v:709 memory_config width truncation to bankmapper.

## Run 2 (2026-06-11): TIMING CLOSED

WNS +0.387 ns, TNS 0, all 99468 endpoints met (setup/hold/pulse-width),
fully routed. The ascal CDC max_delay constraints bind at implementation
(auto-deferred from synthesis, INFO Project 1-236 - expected). Both former
phantom groups now +11.2/+8.0 ns; intra-hr_clk recovered to +0.87 once the
hold-fix detours disappeared; the two hairline stragglers resolved on their
own. BRAM unchanged at 363.5/365.

Note for future changes: overall WNS margin is +0.387 ns - re-check the
timing summary after every build.

Run-2 OOM lesson (run 2a crashed): close the implemented design in the
Vivado GUI before relaunching synthesis - a loaded routed 200T design holds
several GB and starves the child synth process in the VM.

## Run 3 (2026-07-03, ADF floppy milestone): TIMING CLOSED, one area finding

First build with the ADF floppy support (commit 6a2c867 + submodule
e2e4810). Fully routed, 0 errors, all 118109 endpoints met.

- WNS +0.017 ns - but NOT on our logic: the single tightest path is the
  framework HyperRAM PHY (hyperram_ctrl hb_ck_ddr_o_reg -> hr_clk_del
  ODDR, hr_clk->hr_clk_del inter-clock group, 1 endpoint). This path's
  slack wobbles with placement run-to-run; every AExp-owned group has
  comfortable margin: main_clk +8.1, qnice_clk +0.24, qnice->main CDC
  (mount-status cdc_stable bundle) +6.7, main->hr (avm_fifo) +8.0.
- The paula_floppy 'posedge clk or negedge IO_ENA' async-clear pins are
  LIVE now (io_fpga driven by adf_track_engine): they appear as the
  async_default main_clk group, 75 endpoints, recovery +28.7 / removal
  +0.64 - met, keep watching this group.
- BRAM unchanged at 363.5/365 (the Synth 8-5835 'used 766 of 730
  half-tiles, demoting to LUT-RAM' message is the same pre-existing
  demotion regime as run 1/2).
- FINDING (fixed after the run): Synth 8-7186 - the track engine's 256x16
  sector buffer (secbuf) was NOT inferred as distributed RAM and fell
  back to ~4096 flip-flops (total slice registers 23619, 8.77% - purely
  an area waste, no functional or timing impact; the run-3 bitstream is
  valid for hardware testing). Cause: reading the array through a
  function-computed index expression at the io_din_o assignment sites is
  not a Vivado RAM template. Fix: strict simple-dual-port form - one
  unconditional registered read (secbuf_q <= secbuf(secbuf_raddr)) at the
  top of the process, address primed one MFM word ahead. Verify in the
  NEXT build that Synth 8-7186 is gone and slice registers drop by ~4k.
- Benign new warning: Synth 8-3936 trims the engine's status register
  16->9 bits (exactly the bits the FSM consumes).
