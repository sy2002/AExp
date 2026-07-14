# DF1 (second floppy drive) — feasibility research

**Question:** is offering a second disk drive (`DF1:`) to users a low‑hanging
fruit, and if so how — if not, why?

**Short answer:** it is a *low‑branch* fruit, not one already on the ground.
The port was deliberately architected to make DF1 the next increment (reserved
HyperRAM window, generic base addresses, drive‑select already decoded, spare
device‑id space, multi‑image mount machinery), so it is far cheaper than the
original floppy milestone — **no new algorithms, no new protocol, no new source
files.** But it is **not** a one‑line or single‑afternoon change: it needs a
focused rework of `adf_track_engine` into a multi‑drive FSM, a second mount
wrapper plus plumbing in `mega65.vhd`, and — only if DF1 is to be *writable* —
a bounded refactor of the firmware write‑back. And it costs a full
synthesis + hardware‑test round under the project's full‑BRAM, thin‑timing
budget.

---

## 1. The one architectural fact that governs everything

The floppy stack is **two layers that scale very differently**:

- **Layer A — the M2M framework path** (OSM menu item → SD‑card → HyperRAM byte
  streaming → per‑image file handles). AExp routes the ADF through the
  framework's **manual CRT/ROM DEVICE loader** (`C_CRTROMS_MAN`), *not*
  vdrives. This layer is drive‑count‑agnostic and **scales by a config bump** —
  the Shell's load path is already indexed by ROM id, and file handles are
  auto‑generated from a count constant.
- **Layer B — AExp's own disk‑serving datapath** (`adf_mount_wrapper` CSR +
  `adf_track_engine` hardware‑MFM + HyperRAM arbiter + CDC + firmware
  write‑back). Everything here is single‑drive and must be **extended by hand.**
  This is where the real work is.

The other governing fact: **Paula exposes a single `IO_FPGA` floppy host
channel that time‑multiplexes all four drives** via a 2‑bit `sel` field. There
is exactly one `paula_floppy` controller and one host channel
(`main.vhd:766‑770`). So the correct model is **one drive‑aware engine**, mirroring
MiSTer's `HandleFDD` (which loops over `df[4]` on one channel) — **not** two
engine instances (they would collide on the shared `io_fpga`/`io_strobe`/
`io_din` lines and both see the same `io_dout`/`io_wait`).

---

## 2. What is already in place (deliberate groundwork)

| Groundwork | Evidence |
|---|---|
| Minimig implements **df0–df3 in full** — Paula and CIA‑B are 4‑wide throughout | `paula_floppy.v` `dsktrack[3:0]` (`:134`), `disk_present[3:0]`/`disk_writable[3:0]` (`:162‑163`), `_sel[3:0]` (`:88`), priority encoder `sel` (`:329`); CIA‑B PRB → SELx/motor/step (`minimig.v:649` → `:501`) |
| The **only** count‑gate in the chipset is the df1–3 `_ready` line | `paula_floppy.v:407‑410` |
| Drive count is a **single config value** already sent by AExp | `amiga_config.vhd:174` sends cmd `0xF7`, payload `x"0000"`; decoded to `floppy_config` (`userio.v:477,515`), count = `floppy_config[3:2]` (`minimig.v:520`), speed = `floppy_config[0]` (`minimig.v:471`) |
| The engine **already decodes the selected‑drive field** and has the df1 reject stub | status bits `[15:14]` = `sel`; `adf_track_engine.vhd:463‑469` ("df1..df3 selected: not ours") and `:890‑897` |
| Presence is announced for **all four drives in one word** (so one engine can announce both) | Paula `{disk_writable[3:0],disk_present[3:0]} <= rx_data[7:0]` on a `0x1xxx` command (`paula_floppy.v:558‑559`); ref model `UpdateDriveStatus()` packs all 4 (`minimig_fdd.cpp:603‑608`) |
| Both AExp modules are **generic on `G_BASE_ADDRESS`** (just instantiated once, for DF0) | engine `adf_track_engine.vhd:48‑50`; wrapper `adf_mount_wrapper.vhd:49‑51` |
| The **DF1 HyperRAM window is already reserved** (+1 MB) | `globals.vhd:88` `C_HMAP_ADF_DF1 = x"0280"` (word base `0x280000`), referenced nowhere yet |
| **Spare device‑id space** (`0x0104` free: `0x0100` kick, `0x0101/2` reserved, `0x0103` ADF) | `globals.vhd:96‑108` |
| Framework mount machinery supports **up to 16 manual images**, file handles auto‑generated | `make_rom.sh:102,135` emit `HANDLE_RM_FILE$i` + the indexable `HNDL_RM_FILES` table from `C_CRTROMS_MAN_NUM`; Shell load path is ROM‑id‑indexed (`shell.asm:686‑688,889‑891`) |
| The disk‑serving buffers are **shared, LUTRAM, not per‑drive** (key to BRAM) | `secbuf` 256×16 (`adf_track_engine.vhd:219‑224`), `wrbuf` 256×16 (`:232‑236`) — only one drive is ever selected at a time, so these need no duplication |

**Net:** the hard, risky work — a cycle‑exact multi‑drive Paula, the bit‑exact
MFM encode/decode, the host protocol, the write‑back cache discipline — is
already solved and wired through to the seam. Adding DF1 consumes that
groundwork rather than inventing anything.

---

## 3. What DF1 requires, by layer

| Area | Change | Rating |
|---|---|---|
| **Chipset enable** | `amiga_config.vhd:174` payload `x"0000"` → `x"0004"` (`floppy_config[3:2]=01` = 2 drives, speed unchanged). Nothing else on the Minimig side. | **1 line** |
| **OSM menu** (`config.vhd`, `mega65.vhd`) | Add a `" DF1:%s"` item + its own group id (2nd `OPTM_G_LOAD_ROM` occurrence = ROM index 1); rename the DF0 item; keep `OPTM_G_START` on DF0. Bump `OPTM_SIZE` 44→45 (`config.vhd:298`) and `OPTM_DY` 12→13 (`:307‑310`); renumber the hardcoded `C_MENU_*` values (`mega65.vhd:362‑384`) by +1. Settings file auto‑generated by `make_release.py` (`:750`). | **Mechanical** |
| **Mount / SD→HyperRAM stream** (`globals.vhd` + M2M Shell) | `C_CRTROMS_MAN_NUM` 1→2 (`globals.vhd:147`); add a 2nd `C_CRTROMS_MAN` entry `(C_CRTROMTYPE_DEVICE, C_DEV_AMIGA_ADF_DF1)` with `C_DEV_AMIGA_ADF_DF1 = x"0104"`. Handles + streaming scale automatically — **no framework firmware edit.** | **Config bump** |
| **2nd mount wrapper** (`mega65.vhd`) | Instantiate `adf_mount_wrapper` again with `G_BASE_ADDRESS => C_HMAP_ADF_DF1(...)`, add a `when C_DEV_AMIGA_ADF_DF1 =>` arm to the device decode (`mega65.vhd:673‑690`). Its `0xFFFF`/`0xFFFE` windows come for free (same file). | **Mechanical (2nd instance)** |
| **HyperRAM arbiter** (`mega65.vhd:962`) | Today a 2‑master `avm_arbit` (engine reads + mount wrapper). A single multi‑drive engine makes it 3 masters (1 engine + 2 wrappers): either chain a 2nd `avm_arbit` (already in the tree — no `.xpr` change) or switch to `avm_arbit_general.vhd` (`G_NUM_SLAVES` generic — a `.xpr` add if not yet referenced). | **Mechanical** |
| **CDC + signals** (`mega65.vhd`) | Duplicate the per‑drive signal set (`main_adf_*` `:291‑297`, `qnice_adf_*` `:315‑324`) and the three `cdc_stable` chains (mount status, dirty‑event, ack; `:874‑922`). | **Mechanical but voluminous** |
| **Track engine → multi‑drive FSM** (`adf_track_engine.vhd`) | Stop bailing on `sel="01"`; select `G_BASE_ADDRESS` DF0/DF1 per poll (`:790‑794` commit, `:834‑838` fetch); extend the announce word to set bits `[1]`/`[5]` (`:415‑423`); **keep per‑drive rotation state** (`track_prev`/`track_valid`/`sector_next`, `:162‑165`) and — for writes — per‑drive write‑decoder state so interleaved df0/df1 access can't corrupt a mid‑flight write. `secbuf`/`wrbuf`/the host FSM stay shared. | **Tricky (the dominant HDL effort)** |
| **Firmware write‑back ×2** (`m2m-rom.asm`) — *writable DF1 only* | Everything is currently hard‑bound to one drive: single device `AEXP_DEV_ADF`, single WBC window `0xFFFE` (`:850‑854`), single state block `ADF_FDH`/`ADF_FDH_VALID`/`ADF_SD_SLOT`/`ADF_MOUNT_SEEN`/`ADF_FL_*` (`:891‑904`), hardcoded `HANDLE_RM_FILE1` (`:452`), `PREP_LOAD_IMAGE` keyed on `OPTM_G_ADF` (`:142`). DF1 needs per‑drive state (arrays), watch **both** devices' `PARSEST` for the mount edge, snapshot `HANDLE_RM_FILE1`/`2` via `HNDL_RM_FILES[drive]`, parametrize `FLUSH_ADF_STEP` by drive, and loop `HANDLE_CORE_IO` over the two drives — including the `§5a` arm‑state invariant per drive. Loopable, not duplicated. | **Tricky (bounded)** |
| **4× `.xpr` sync** | No new *source files* are strictly required (the 2nd wrapper is another instance of an existing file). The only possible file‑list change is `avm_arbit_general.vhd` if that arbiter option is chosen. | **Trivial / none** |

---

## 4. Two scoping options

There is a natural cheap first cut, mirroring the project's own "read‑only
first, write later" cadence:

**Option A — read‑only DF1 (recommended first step).**
Announce DF1 present + write‑protected; drain any writes harmlessly through the
existing `WDRAIN` path. This removes the single *tricky* firmware item entirely
— the write‑back stays df0‑only. Remaining work: the engine read‑path
multiplex (serve `sel="01"`), a 2nd mount wrapper (mount + CSR, WBC unused),
the arbiter/CDC plumbing, the menu, and the 1‑line chipset config. Mostly
mechanical plus one moderate engine change. This already covers a large share
of real‑world use: boot from DF0, read data/level disks from DF1, and the
convenience of a permanently‑present empty second drive.

**Option B — writable DF1 (full symmetry with DF0).**
Adds the per‑drive write‑back refactor (§3, last two rows). Structurally known
— C64MEGA65's `HANDLE_IO`/`FLUSH_CACHE`/`VD_INIT` loops over `VDRIVES_NUM` are
the proven template — but the `§5a` arm‑state invariant is subtle, and doubling
it doubles the chance of a subtle write‑back bug. Roughly 1.5–2× the Option A
effort, concentrated in firmware.

Sequencing note: DF0 *write* support shipped 2026‑07‑05 but is **not yet
hardware‑verified**. It is worth closing that loop before building writable
DF1 on top of it; read‑only DF1 (Option A) can proceed in parallel without that
dependency.

---

## 5. Risks & constraints

- **BRAM is full (363.5 / 365 tiles — hard rule 3).** With the recommended
  single‑engine multiplex, the expensive buffers (`secbuf`/`wrbuf`) stay
  shared, and the extra per‑drive state (a 2nd 166‑bit dirty bitmap, rotation
  scalars) is flip‑flops, not BRAM. The 2nd wrapper's `avm_fifo` is a 16‑deep
  CDC FIFO that normally maps to SRL/distributed RAM. So the expected BRAM cost
  is ≈ 0 tiles — **but this must be confirmed early** with
  `report_utilization -hierarchical`; a stray unattributed buffer or a FIFO
  that infers as BRAM would overflow. (Cloning the engine, by contrast, *would*
  add a 2nd `secbuf`+`wrbuf` — another reason not to.)
- **Timing margin is thin (hard rule 5;** global WNS ≈ +0.017 ns**).** A wider
  arbiter and the enlarged engine FSM add paths on the ADF/HyperRAM side.
  Nothing here sits on the framework HyperRAM PHY path that owns the global WNS,
  but the AExp‑owned groups must be re‑checked after synthesis.
- **Engine FSM correctness.** Interleaved df0/df1 access from Kickstart is the
  real correctness risk: per‑drive rotation and write‑decoder state must be
  strictly separated, or a seek/write on one drive corrupts the other's
  in‑flight transfer. This is the part that needs care and a good hardware test
  matrix, not just a clean synth.
- **UX limitation (not a blocker).** The OSM `` `<Saving>` `` indicator is
  vdrives‑hardwired in `options.asm` and unavailable on AExp's LOAD_ROM path
  (write spec §7); DF1 (like DF0 today) shows write activity only via the drive
  LED, which already ORs across drives (`mega65.vhd:472‑473`).
- **Compatibility.** A permanently‑configured empty DF1 is exactly like a real
  A500 with a second drive and no disk — benign. A few copy‑protected titles
  probe DF1 and can behave differently; if that ever matters, drive count could
  later become an OSM toggle (extra work: `amiga_config` would re‑replay `0xF7`
  on change + a reset). Simplest V1 is a static two‑drive machine.

---

## 6. Effort estimate & work packages

Relative to the original floppy milestone (weeks: MFM from scratch, protocol
reverse‑engineering, CDC design, write‑back cache), DF1 is a small,
low‑architectural‑risk increment because it reuses all of that. But it is a
real feature with a mandatory build/verify round, not a config toggle.

Work packages (Option A / read‑only first; Option B adds WP6):

1. `amiga_config.vhd:174` `x"0000"` → `x"0004"` (2 drives).
2. `adf_track_engine.vhd`: serve `sel="01"`, base‑address select, per‑drive
   rotation state, dual‑drive announce word.
3. `mega65.vhd`: 2nd `adf_mount_wrapper` (device `0x0104`, base
   `C_HMAP_ADF_DF1`), device‑decode arm, 3rd arbiter master, duplicated CDC +
   signals; drive‑LED OR already present.
4. `globals.vhd`: `C_DEV_AMIGA_ADF_DF1 = x"0104"`, `C_CRTROMS_MAN_NUM` → 2,
   2nd `C_CRTROMS_MAN` entry.
5. `config.vhd` + `mega65.vhd` menu: `" DF1:%s"` item, group id, `OPTM_SIZE`/
   `OPTM_DY` bump, `C_MENU_*` renumber. (`make_rom.sh` re‑scrapes on synth;
   `make_release.py` regenerates the settings file.)
6. *(Option B only)* `m2m-rom.asm`: per‑drive write‑back state, dual `PARSEST`
   watch, `HANDLE_RM_FILE1/2` snapshot, parametrized `FLUSH_ADF_STEP`,
   two‑drive `HANDLE_CORE_IO` loop, per‑drive `§5a` arm‑state.
7. Local static checks (`nvc`/`iverilog`) → synthesis handoff → hardware test
   round: BRAM (`report_utilization -hierarchical`), timing, and a DF1 test
   matrix (empty DF1 seen by Kickstart; boot DF0 + read data disk from DF1;
   multi‑disk game using DF1; for Option B, write/format/persist on DF1).

---

## 7. Recommendation

**Yes — worth doing, and yes it qualifies as "low‑hanging" in the sense that the
expensive prerequisites are already paid for.** The honest caveat is that the
enabling `x"0004"` line does nothing on its own: DF1 becomes real only once the
single engine is made drive‑aware and a second mount path is plumbed in. Treat
it as a well‑scoped **medium** increment, not a five‑minute change.

Suggested path: land **read‑only DF1 (Option A)** first — it sidesteps the one
genuinely delicate part (per‑drive write‑back) and delivers most of the user
value — then add **writable DF1 (Option B)** as a follow‑up once DF0 write
support is hardware‑verified. Confirm BRAM and timing at the first synthesis,
since those are the only two places this feature can bite despite all the
groundwork.
