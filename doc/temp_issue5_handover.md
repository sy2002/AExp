# AExp Issue #5 — Screen Centering: Handover

**Date: 2026-07-08 (rev 2).** A map for a fresh session picking up issue #5.
Written to be *verified, not trusted*. This revision replaces the original
handover, whose premise ("VGA not started, decide the coupling, do it in
main.vhd") is now the **opposite** of reality — VGA is implemented and merged.

> **Source-of-truth ranking:** committed `develop` code > `git log`/`git show` >
> this doc > `.research/INTEGRATION-SPEC-screen-centering.md` (PARTLY STALE, see
> §2) > memory. When this doc and the code disagree, the code wins. **Line
> numbers are given as symbol names, not integers** — the #13 RTC merge already
> shifted them; re-grep the symbol.

---

## 0. Repo / branch state — read this FIRST (it churned a lot)

- **Issue #5 is DONE in code and MERGED into `develop`.** The commits, in order:
  `d9e5d2d` (per-mode HDMI centering) → `3d4e6dc` (VGA centering, decoupled) →
  `c825854` (rename the tool's HDMI fields). Then the **unrelated** #13 RTC work
  landed on top (`c3a99b8`, `04f231b` = current `develop` HEAD).
- **`fix_issue_5` no longer exists on the remote** (merged + deleted). The remote
  has only `develop` and `master`. Do NOT try to check out `fix_issue_5`.
- **The tree here is a moving target — a concurrent session commits to it.** As
  of this writing the tip is `8823921 "WIP-V1-A5"`, a concurrent WIP commit that
  folded in the #13 RTC work plus this session's `doc/screen_adjust.md` edit and
  unrelated changes (`README.md`, `doc/inofficial.md`, `.gitignore`, a
  `doc/synthesis-handoff.md` deletion). Only this handover is still untracked.
- **Consequence:** the issue #5 code is stable and lives in the committed history
  (`d9e5d2d` / `3d4e6dc` / `c825854`) — it is NOT affected by the concurrent WIP,
  and the tip commit's message ("WIP-V1-A5", #13) does NOT reflect #5 status. For
  #5 truth read the current files (they contain the merged #5 code) or
  `git show <#5-commit>:<path>`; do not trust the tip commit message.

## 1. TL;DR — what is done, what is left

Issue #5 = "the Amiga picture is off-centre, and it clips differently on HDMI vs
VGA." **One root cause, two decoupled fixes**, both now implemented:

- **HDMI — DONE and hardware-verified** (sy2002 confirmed on real R3 this
  session). Per-Amiga-mode ascal **input-crop**. Committed in `d9e5d2d` + the
  firmware follow-up that shipped with it.
- **VGA — IMPLEMENTED and HARDWARE-VERIFIED on R3** (sy2002 confirmed
  2026-07-09). A core-agnostic MiSTer-style **soft-blank in the framework**
  (`av_pipeline.vhd`), merged in `3d4e6dc`.

**Issue #5 is now hardware-complete on both outputs.** The VGA soft-blank was
synthesized and verified on real R3 hardware (sy2002, 2026-07-09) — HDL edits
only, no new file, no `.xpr` change. What remains is product polish, not core
engineering: (a) finalise the shipped default VGA offset values in
`aexp_screen.bin` for the release (they were 0 / untuned at merge time; HDMI had
real values), and (b) the eventual MiSTer-style *live* adjust that will replace
the edit-file-and-Reload flow (a stopgap). The `vbl_t` blackout footgun (§5) is
unchanged — minor, tool-mitigated, MiSTer-faithful.

**Longer term (explicitly a stopgap):** the current "edit an SD file + Reload"
flow is temporary. A future release is expected to add a MiSTer-style *live*
adjust (nudge with the keyboard, watch it move). Do not over-invest in the file
flow.

## 2. The design decision that supersedes the spec

`sy2002` chose to make VGA centering a **reusable, core-agnostic M2M framework
feature** (like HDMI already was), NOT an Amiga-specific thing in `main.vhd`.
This is "option (b) decouple" done in the framework.

⚠️ **`.research/INTEGRATION-SPEC-screen-centering.md` §3 increment-2 is now WRONG**
in one respect: it describes the VGA soft-blank living in `CORE/vhdl/main.vhd`
with a `qnice_gp_reg_i` port and threading a trimmed blank through the board tops.
**That is NOT what was built.** The soft-blank lives in the framework
(`av_pipeline.vhd`); `main.vhd`, `mega65.vhd`, and the four board tops were NOT
touched. The spec's *mechanism* (MiSTer `Minimig.sv` soft-blank, the edge
offsets) is still the right reference; only its *location/plumbing* is stale.

## 3. Root cause (both outputs, one origin)

`CORE/vhdl/main.vhd` forwards minimig's raw, unnormalised Agnus geometry (syncs +
blanking) to the framework. The two scalers then place that raw geometry in
**opposite** directions: HDMI (ascal) auto-detects the active window and puts
content where it sits *inside* the Agnus hard-blank (right-of-centre for WB 1.3);
VGA (scandoubler) positions by the raw back porch (too far left). One core-side
trim cannot centre both → **two decoupled levers**.

## 4. HDMI — the SHIPPED, hw-verified mechanism (do not break)

- **Where:** `M2M/vhdl/av_pipeline/digital_pipeline.vhd`, process `p_crop`, ascal
  instantiated with `iauto => '0'`.
- **What:** `p_crop` builds the ascal input crop `himin = 0 + himin_off ..
  himax = measured_size + himax_off` (V analogue) from ascal's tapped measured
  input size + four signed offsets `himin_off_i/himax_off_i/vimin_off_i/
  vimax_off_i`, clamped so `0 <= himin < himax <= size` (min box 16).
  **Zero offsets ⇒ `[0, size]` = the full auto-detected window (pixel-identical
  to the old `iauto=1`).** An asymmetric trim re-centres content; note it also
  mildly zooms (inherent to source-rectangle selection — you CANNOT pan on HDMI).
- **Per-mode:** a 4-row table `{lores,hires} × {progressive,interlaced}`.
- **Detection (`DETECT_SCREEN_MODE`, firmware, inside `HANDLE_CORE_IO`):** reads
  ascal's measured `hdmax` (`M2M$SYS_CORE_X`) and a core-agnostic interlace flag
  (`M2M$SYS_CORE_FLAGS` = `0x700B`, bit 0 = `M2M$SYS_CORE_FL_INT`), classifies via
  the `in_range_u` SYSCALL (lores window `[367,388)`, hires `[744,765)`),
  debounces (`SCR_DEBOUNCE=3`), throttled to every 256th poll (`SCR_TICK_MASK`),
  and on a stable change pushes that mode's offsets. The interlace flag is ascal's
  internal `i_inter` exposed as a new port → widened 137-bit video→QNICE CDC →
  `qnice_wrapper` (M2M-UPSTREAM screen-center).

## 5. VGA — the IMPLEMENTED mechanism (Option B, core-agnostic)

- **Where:** `M2M/vhdl/av_pipeline/av_pipeline.vhd`, process `p_vga_softblank`
  (runs on `video_clk_i`). A VHDL port of MiSTer's `Minimig.sv` soft-blank
  (submodule `CORE/Minimig_MiSTerMEGA65/Minimig.sv`, the `hcnt/vcnt` /
  `shbl/fhbl/svbl/fvbl` block, ~lines 755-840 — re-grep).
- **How it works:** it reconstructs the active window from the raw
  `video_hs_i/vs_i/hblank_i/vblank_i` edges and shifts each edge by a signed
  offset. Polarity note: MiSTer's syncs are active-LOW, the framework's are
  active-HIGH, so MiSTer's `~hs` maps to `video_hs_i`, `~vs` to `video_vs_i`, etc.
  Interlace uses ONLY `video_fl_i` (the framework's field flag): because AExp
  drives `video_fl_i='0'` when progressive, MiSTer's `~lace|~field1` reduces
  exactly to `~field1` (`video_fl_i='0'`).
- **Decoupling (verified):** the soft-blank feeds ONLY `i_analog_pipeline`
  (signals `analog_hblank`/`analog_vblank`). ascal/HDMI still gets the **raw**
  blanking via `i_crop` (`video_crop_hblank`), and `i_video_counters` (the
  SYS_CORE geometry) still gets the **raw** blanking. So HDMI and the measured
  geometry are untouched.
- **Neutral by default:** per axis, `vga_h_active`/`vga_v_active` gate a mux —
  if the (latched) offsets for that axis are all zero, the RAW core blanking
  passes straight through (bit-identical to no soft-blank). So a zero/missing file
  leaves VGA exactly as before, and any other M2M core is unaffected.
- **Sign semantics (matters for tuning + the manual):**
  - HDMI (trim-inward only): `himin` `0`-or-positive (trims left), `himax`
    `0`-or-negative (trims right), `vimin` `0`-or-positive (top), `vimax`
    `0`-or-negative (bottom). Opposite signs are clamped away. No pan.
  - VGA (both signs, can pan): `hbl_l`/`hbl_r`/`vbl_t` use either sign; move
    `hbl_l`+`hbl_r` together to pan. `vbl_b` is special: `0` = natural bottom,
    NEGATIVE pulls it up, positive is an odd absolute mode → treat as "0 or
    negative."
- **KNOWN ISSUE (minor, confirmed by the adversarial review, deliberately left
  MiSTer-faithful in HDL):** a large NEGATIVE `vbl_t` (magnitude greater than the
  measured vertical-blank height, ~30 lines) wraps the 12-bit exact-equality
  unblank test and blanks the whole VGA picture. It matches MiSTer's own code, is
  fully recoverable (smaller value / delete file / Reload; HDMI stays live), and
  is self-announced on the UART. **Mitigated in the tool** (`WARN_VGA=32` warning
  + a recovery note), NOT in HDL. If you ever want to harden it, the review's
  suggestion was a hardware clamp saturating the unblank target to `[0, vmax-1]`.

## 6. Transport chain (one line, end to end)

`/amiga/aexp_screen.bin` (v3) → firmware `LOAD_SCREEN_OFFSETS` into RAM
`SCR_TABLE` (32 words) → `DETECT_SCREEN_MODE` pushes the matching row's **HDMI
half to CFD `gp_reg` words 4-7** (`SCR_CFD_HDMI`) and **VGA half to words 0-3**
(`SCR_CFD_VGA`) via `M2M$CFD_ADDR`/`M2M$CFD_DATA` (`0xFFF0`/`0xFFF1`) → in
`framework.vhd` the HDMI offsets are sliced from `qnice_gp_reg_o` words 4-7 and
the VGA offsets from words 0-3 (bits `(11:0)/(27:16)/(43:32)/(59:48)`) → the
`i_qnice2video` CDC in `av_pipeline.vhd` (**widened `WIDTH 94→142`**) crosses both
sets into the video domain → HDMI offsets go to `digital_pipeline` `p_crop`; VGA
offsets are latched per-frame in `p_vga_softblank`.

## 7. File format, tool, firmware, manual — the concrete artefacts

- **SD file v3** `/amiga/aexp_screen.bin`, **68 bytes, big-endian**: `41 58 03 04`
  = "AX", version 3, count 4; then 4 rows in the fixed order lores-prog,
  hires-prog, lores-interlaced, hires-interlaced; each row = 8 signed-16 words =
  an HDMI half `[himin,himax,vimin,vimax]` then a VGA half
  `[hbl_l,hbl_r,vbl_t,vbl_b]`. **v2→v3 is BREAKING (no migration, per sy2002)** —
  a stale v2 file is rejected → all zeros until re-written by the tool.
- **Tool** `aexp_screen_cfg.py` (repo root): v3; `HDMI_FIELDS` renamed to the
  friendly `himin/himax/vimin/vimax` (the `_off` suffix was dropped in `c825854`;
  the RTL signals are still `himin_off_i` etc, deliberately, to differ from
  ascal's own `himin`). VGA fields are MiSTer's `hbl_l/hbl_r/vbl_t/vbl_b`.
  Interactive mode edits all 8 per mode; range warnings (`WARN_HDMI=400`,
  `WARN_VGA=32`) + a recovery note. No v1/v2 migration.
- **Firmware** `CORE/m2m-rom/m2m-rom.asm` (`SCR_*`): version check `0x0003`,
  `SCR_TABLE_WORDS=32`, `SCR_ROW_WORDS=8`, `SCR_HALF_WORDS=4`, `SCR_CFD_HDMI=4`,
  `SCR_CFD_VGA=0`; `DETECT_SCREEN_MODE` pushes row×8 → both halves; two-line
  `HDMI:`/`VGA:` UART trace (`MSG_SCR_HDMI`/`MSG_SCR_VGA`); `SCR_INIT` boot-inits
  the 32-word table; the "Reload screen cfg" path (`OSM_SEL_POST`) remounts
  `CONFIG_DEVH` via `f32_mnt_sd` before reading (the R3 same-slot-swap fix).
- **Manual** `doc/screen_adjust.md` — a general-audience guide, committed on
  `develop`. A detailed `### How the numbers really work` sub-chapter (HDMI-vs-VGA,
  pan vs no-pan, +/- meanings) was added this session and is **now committed** (it
  was folded into the concurrent `8823921` WIP commit). Do not re-add it.

## 8. What changed where (the whole #5 footprint)

HDL (all tagged `M2M-UPSTREAM screen-center`, all edits — NO new file, NO `.xpr`
change): `ascal.vhd` (expose `i_inter`), `digital_pipeline.vhd` (`p_crop`,
`iauto=0`, interlace out), `av_pipeline.vhd` (VGA soft-blank + widened CDC + the
analog-blank mux), `framework.vhd` (gp_reg slices for HDMI words 4-7 + VGA words
0-3), `qnice_wrapper.vhd` + `M2M/rom/sysdef.asm` (`SYS_CORE_FLAGS 0x700B`).
Firmware: `CORE/m2m-rom/m2m-rom.asm`. Tool: `aexp_screen_cfg.py`. Docs:
`doc/screen_adjust.md`. Core config: `CORE/vhdl/config.vhd` — the OSM menu (the
functional " Reload screen cfg" item at menu index 36, its `OPTM_G_SCRRELOAD := 6`
group entry, and `OPTM_SIZE` bumped 40→41; this is the OSM item §7's Reload path
fires, introduced in the `f078732` WIP commit). Also changed in the #5 commit
range but non-functional: `CORE/vhdl/globals.vhd` (comment-only VGA_* notes) and
`CLAUDE.md`. **`main.vhd`, `mega65.vhd`, the four `top_mega65-r*.vhd`, and all
`.xpr` files were NOT touched.**

## 9. Build & verify (no Vivado on the Mac)

- Vivado runs in sy2002's Parallels VM on this shared folder. Prepare, then ask
  for the synthesis logs. Timing margin is thin — check the summary after every
  build.
- Local static checks that were run and passed this session: `nvc --std=2008`
  analysis of `av_pipeline.vhd` + `framework.vhd` (clean) + a full `framework`
  elaboration with the CDC bound to a real generic-width xpm entity (proved the
  142-bit mapping; only an environmental missing-`.rom` init read failed). Native
  `qasm`/`qasm2rom` compiled to a temp dir assembled the firmware clean (never run
  `make_rom.sh` on the Mac). `python3 aexp_screen_cfg.py` round-trips to 68 bytes.
  Reuse the nvc stub recipe from prior scratchpads / `doc/how_to_port.md`.
- The VGA change passed an adversarial review swarm: only the §5 `vbl_t` cliff was
  confirmed (minor), everything else refuted (notably the `~field1` reduction was
  verified correct).

## 10. Anchors (symbol names — re-grep, line numbers have drifted)

- VGA soft-blank: `av_pipeline.vhd` `p_vga_softblank`, signals `analog_hblank`/
  `analog_vblank`, `sb_off_vb(11)` (the vbl_b sign special case), `WIDTH => 142`,
  `qnice_vga_hbl_l_i`.
- HDMI crop: `digital_pipeline.vhd` `p_crop`, `iauto => '0'`, `himin_off_i`,
  `i_interlaced`.
- gp_reg slices: `framework.vhd` `qnice_vga_hbl_l_i => qnice_gp_reg_o(11 downto 0)`
  (VGA) and `qnice_himin_off_i => qnice_gp_reg_o(75 downto 64)` (HDMI).
- Firmware: `m2m-rom.asm` `LOAD_SCREEN_OFFSETS`, `DETECT_SCREEN_MODE`,
  `_DSM_PLOOPH`/`_DSM_PLOOPV`, `SCR_INIT`, constants `SCR_*`, strings `MSG_SCR_*`.
- Interlace flag: `sysdef.asm` `M2M$SYS_CORE_FLAGS = 0x700B`,
  `M2M$SYS_CORE_FL_INT = 0x0001`.
- Spec: `.research/INTEGRATION-SPEC-screen-centering.md` (VGA §3 location is STALE —
  see §2; MiSTer ref `Minimig.sv` soft-blank block still valid).
