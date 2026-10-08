# Tools and testbenches

Two folders hold everything that checks the core outside Vivado:

* `tools/`: Python scripts that run on the machine you edit on. Two of them
    check the menu and the firmware before a synthesis; the others analyse
    what a user sends in with a floppy report.
* `CORE/sim/`: the simulation testbenches, one subfolder per area, each with
    a runner script, plus top-level runners for the pre-synthesis gate and
    for the long floppy suites.

Run every command from the repository root.

## What you need

* Python 3 (known to work with 3.11). The checkers and the dump decoder use
    only the standard library; `tools/flux/` also needs numpy (known to work
    with 1.25).
* [nvc](https://github.com/nickg/nvc) 1.21 or later for the VHDL benches.
* [Icarus Verilog](https://github.com/steveicarus/iverilog) for the Verilog
    benches (known to work with 13.0).
* bash. The runners also work with the bash 3.2 that macOS ships.
* The Minimig submodule with its history: the Minimig golden diffs read their
    baseline (commit `fa40334`, the fork before the upstream ports) with
    `git show`.

GHDL is a useful second opinion for VHDL errors that nvc reports unclearly,
but no runner needs it. Nothing here needs Vivado.

## The gate before a synthesis

A synthesis takes a long time, so check locally first:

* After any change to `CORE/vhdl/config.vhd` or to a `C_MENU_*` constant:
    `python3 tools/check_osm_menu.py`.
* After any change to `CORE/m2m-rom/m2m-rom.asm`:
    `python3 tools/check_firmware.py`.
* Before every synthesis: `CORE/sim/run_all.sh`. It runs both checkers, the
    nvc analysis of all CORE VHDL and every bench that finishes in minutes,
    about 4 minutes in all.
* After a change to the floppy stack (`adf_track_engine.vhd`,
    `physical_fdd/`, `paula_floppy.v`, the drive parts of `main.vhd` and
    `mega65.vhd`): also `CORE/sim/run_long.sh`, or at least the suite that
    covers the change.

```bash
python3 tools/check_osm_menu.py
python3 tools/check_firmware.py
CORE/sim/run_all.sh
JOBS=8 CORE/sim/run_long.sh
```

`run_all.sh` prints one line per step:

| Step | What it runs | Runtime |
|---|---|---|
| `check_osm_menu`, `check_firmware` | the two checkers below | under a second each |
| `nvc_chain` | `CORE/sim/run_nvc_chain.sh` | a few seconds |
| `audio`, `video`, `misc` | the audio, analog positioner and cold-boot benches | about 30 s together |
| `keyboard` | the three keyboard benches | about 75 s |
| `cia_inmode`, `blitter_freeze` | the two fast Minimig golden diffs | about 75 s together |
| `fdd_quick` | the floppy regression without the splice cells | about 40 s, 11 s with `JOBS=4` |

`run_long.sh` runs the full floppy regression, the full write matrix, the
write mutants and the beam-counter golden diff: about three and a half hours
with `JOBS=1` and about an hour with `JOBS=8`.

## How the runners behave

* Each runner takes an optional work directory. It must be an existing
    directory or a path containing a slash (`./work` rather than `work`);
    any other unknown argument is rejected, so a mistyped mode or mutant
    name cannot turn into a work directory. Without one the runner creates
    a fresh directory with `mktemp` under `$TMPDIR` (or `/tmp`) and prints
    it. Simulators write into their invocation directory, so the runners
    never simulate inside the repository.
* Logs stay in the work directory. A reused work directory has the logs,
    cell directories, source copies and cached baselines of the earlier run
    removed first, so a result can never come from an earlier run.
* The exit status is 0 only if everything passed; the floppy runners return
    the number of failures. Every selected cell or mutant must report a
    result, so a cell that never ran counts as failed. The last line is a
    summary.
* `JOBS=<n>` runs independent cells in parallel where a runner supports it
    (the floppy suites, the blitter mutants). Every parallel cell gets its own
    directory and its own nvc library. The cells are compute-bound, so use at
    most the number of physical cores.
* The three floppy runners copy the HDL, the benches and the Python twins
    into the work directory when they start, and every cell uses that copy,
    so all cells of one run test the same tree even if a file is edited
    while the suite runs. At the end a source that no longer matches its
    copy fails the run as CHANGED: the results then describe the tree as it
    was at the start. The other runners read the tree directly and finish
    in minutes; there, nvc's "older than its source file" warning fails a
    cell as STALE. Do not edit a runner while it runs: bash reads a script
    as it goes.

## Host tools (`tools/`)

### Menu and firmware checkers

Both find the repository from their own location, finish in well under a
second, end with `all checks passed` and exit non-zero otherwise.

* `check_osm_menu.py` recomputes, from `config.vhd`, `OPTM_SIZE`, the
    submenu structure, the `OPTM_DEP` rules, the tallest visible menu view
    against `OPTM_DY`, the boot defaults (one `OPTM_G_STDSEL` per radio,
    every default visible, at most one drive defaulting to Hardware Floppy),
    the `MENU_HEAP_SIZE` demand of the firmware and the geometry of the
    welcome and help pages. It also checks every `C_MENU_*` constant in
    `mega65.vhd` against the text of the line it points to. The rules behind
    it are in [the architecture overview](architecture.md), section 7.
* `check_firmware.py` requires every `ADDC`/`SUBC` in `m2m-rom.asm` to take
    its carry from an instruction that works on the same storage class
    (memory or register). On QNICE only `ADD`, `ADDC`, `SUB`, `SUBC`, `SHL`
    and `SHR` write the carry flag, so an address calculation placed between
    a 32-bit `ADD` and its `ADDC` silently eats the carry. It also checks that
    every per-drive table and array has exactly `ADF_DRIVES` entries.

### Floppy field reports

The protocols for a user's floppy report in
[the Hardware Floppy documentation](hardware-floppy.md), section 9, use these
tools.

* `decode_fdd_dump.py` turns dumps of the Hardware Floppy diagnostics device
    into prose: the `M D 7000 707D` dump from the QNICE monitor (section 8.1
    of the same document explains how to take it). It accepts monitor
    output, `0x20 = 0x40A8` style lines and bare words, several dumps per
    file, decodes each one by the map version it reports, and compares
    consecutive dumps: moving counters, deltas per revolution and per read
    attempt, and whether two dumps are really the same capture pasted twice.
    `--selftest` checks the decoder itself.

    ```bash
    python3 tools/decode_fdd_dump.py dump.txt [more.txt ...]
    pbpaste | python3 tools/decode_fdd_dump.py
    python3 tools/decode_fdd_dump.py --selftest
    ```

* `adf_compare.py` compares the source `.adf` of a disk the core wrote with
    the disk read back to an `.adf`. It prints the differing bytes per track,
    tells a never-written region (thousands of bytes per track) from damage,
    and recognises the post-`DSKBLK` tail-cut signature in sector 10. Use
    `--tracks` to restrict the comparison to the tracks the read-back really
    covered, for example `--tracks 0-159:even`; outside that range an
    existing `.adf` holds stale content, not a measurement. Exit status 0
    means every compared track is identical.

    ```bash
    python3 tools/adf_compare.py source.adf readback.adf [--tracks 1-19:odd]
    ```

### Flux analysis

The scripts in `tools/flux/` read raw SuperCard Pro (`.scp`) files as written
by a Greaseweazle: the whole disk, at least two revolutions per track, three
are better. Most take one or more pairs of a file and a label, so several
disks can be compared in one run, and all print their usage when called
without arguments. A whole disk takes from under a second to about twenty
seconds, depending on the script. `scp_tool.py` (the reader, an MFM PLL and an
AmigaDOS sector decoder) and `burst.py` (the expected MFM of a sector) are
shared by the others.

* `patch_scan.py disk.scp LABEL ...` scans every track for analog damage
    patches: 8 or more off-grid intervals within 1 ms, at the same angle in
    two revolutions. A healthy disk scans to zero. Patches that line up in
    angle across tracks are a property of the medium, because X-Copy's writes
    start at a random angle.
* `patch_span.py disk.scp source.adf TRACK:SECTOR ...` walks the expected
    and the observed transitions of one sector in lockstep from both of its
    sync marks and reports the extent of a patch and the interval mix inside
    it. A clean sector matches sync to sync. Sectors 0 to 9 only.
* `burst.py disk.scp source.adf TRACK:SECTOR ...` prints the timing residual
    of one sector per 0.25 ms of angle, with missing and extra transitions.
* `xcopy_tail.py disk.scp LABEL ...` finds where each X-Copy write ends
    relative to the last data bit of sector 10. Healthy is about 15 cells
    after it on both heads (the end of X-Copy's single pad word); earlier
    means the tail of the write is being cut.
* `precomp_step.py disk.scp LABEL ...` measures write precompensation on the
    medium: neighbour-conditioned interval means for tracks 60 to 103 step at
    the track 80/81 boundary when precomp is on from track 81. A second step
    near track 88 also shows on A500-written disks and belongs to a drive.
* `writer_fingerprint.py disk.scp LABEL ...` reports the cells per
    revolution of every track, which is the spindle speed of the drive that
    wrote it, and the first sector after the gap (always 0 for X-Copy,
    rotated for trackdisk). A track rewritten by another drive says nothing
    about the writer under test.
* `structure.py disk.scp LABEL ...` summarises ten sample tracks: cell size,
    writer speed, cells per revolution, the gap, the angle of sector 0, good
    sectors, and the splice.

```bash
python3 tools/flux/patch_scan.py disk.scp mydisk
python3 tools/flux/xcopy_tail.py disk.scp mydisk reference.scp reference
```

## Testbenches (`CORE/sim/`)

### Static analysis

`CORE/sim/run_nvc_chain.sh` analyses the M2M packages and framework files the
core depends on and every file in `CORE/vhdl` in dependency order, then
elaborates `config.vhd`. The order is a list in the script; a new `.vhd`
file under `CORE/vhdl` that is not in the list fails the run until it is
added. `clk.vhd` and `mega65.vhd` instantiate Xilinx
primitives, so the chain first compiles the stub packages in
`CORE/sim/stubs/` (`unisim_stub.vhd`, `xpm_stub.vhd`) into libraries named
`unisim` and `xpm`. The stubs declare components only, which is enough for
analysis but not for simulation. A menu edit that leaves `OPTM_GROUPS` with
more or fewer than `OPTM_SIZE` entries fails here. Runtime: a few seconds.

### Floppy (`CORE/sim/floppy/`)

The benches behind section 11 of
[the Hardware Floppy documentation](hardware-floppy.md#11-how-it-was-verified).
They drive the real `physical_fdd/` front end, writer and
`adf_track_engine.vhd`; `tb_adf_multidrive.vhd` also covers the simulated
ADF drives.

| Bench | What it verifies |
|---|---|
| `tb_physical_fdd_top.vhd` | The read front end from flux to the word FIFO, closed loop: nominal and ±3 % speed with jitter, runts, re-lock after a drought, the sector-header capture, in both separator modes |
| `tb_fdd_dpll.vhd` | The DPLL keeps a dropped flux reversal to a single bit error where the legacy classifier corrupts the rest of the sector; a displaced edge and a 3 % bias decode in both modes |
| `tb_fdd_margin.vhd` | The margin and miss-profile instruments against an independent integer model; `gen_tb_fdd_margin.py` regenerates its stimulus and expectations |
| `tb_fdd_diag_ro.vhd` | The registered readout of diagnostics device `0x0104`: all 128 addresses against a literal table, alias folding, and proof that the output is registered |
| `tb_fdd_splice.vhd` | The write-splice sync seam through the real front end, judged by an independent model of the Kickstart 1.3 trackdisk read decode: realign-always framing fails, the framing hold and a constant-framing model of a real Paula decode; with `WORDSYNC` on, the hold stays off |
| `tb_engine_paula.vhd` | The engine's physical delivery against a line-by-line model of Paula's receiver and disk DMA: two attempts stored word for word, a buffer that starts at the sync word, a co-selection click |
| `tb_adf_multidrive.vhd` | Multi-drive ownership: no drive writes into another drive's image, physical writes never commit, the `df0:` select ambiguity, a busy writer, a reset inside a write episode |
| `tb_hwf_obs_tap.vhd` | The `DSKBYTR` observation tap publishes exactly the real read-FIFO pops, with no phantom pop while the engine drains the FIFO |
| `tb_fdd_write.vhd` | The write datapath, closed loop from a Paula write model through the real engine, CDC FIFO and writer into a rotating flux model and back through the real read chain, judged by the trackdisk decode model, a constant-framing Paula model and a per-sector byte compare. Twelve scenarios: full tracks over speed, separator and framing, precomp, X-Copy cadence, the write-protect tab, aborts, every gate term, the tail, co-selection, `df0:`, reset hygiene, the busy interlock |

`models/` holds two independent Python reimplementations used as twins.
`td_check.py` decodes a capture the way trackdisk does and maps the seam; the
splice bench writes such captures as `splice_dump_att<N>.txt` when asked to.
`td_write_check.py` rebuilds the expected flux edges from the writer's
serialization and precomp rules and must agree with every flux dump of the
write bench to one cycle; it has its own `--selftest`.

Three runners:

* `run_fdd_regression.sh [workdir] [quick|full]` runs every bench above
    except `tb_fdd_write`, plus the `paula_floppy.v` golden diff from
    `CORE/sim/minimig/`. `quick` skips the four splice cells, which take 10
    to 15 minutes each; the other ten cells take about 40 s together.
* `run_write_matrix.sh [workdir] [quick|full|fullonly]` runs the write
    bench over 42 short-transfer cells (`quick`, the default), the 35
    full-track cells (`fullonly`) or all 77 (`full`), then checks every flux
    dump with `td_write_check.py`. A cell takes about 74 s on
    average: the full matrix needs about 95 minutes serially and about 25
    with `JOBS=8`. `CELLS=<regex>` restricts the run to matching cells.
* `run_write_mutants.sh [workdir] [id ...]` applies 15 single-site edits to
    copies of the writer and engine, such as LSB-first serialization, a
    99-cycle cell, a runt pulse, an inverted precomp sign or a removed
    interlock, and requires each one to make a write-bench verdict or the
    twin fail. A kill counts only if the same cell passes on the unmutated
    design (and, for a kill by the twin, the twin accepts the unmutated
    dump), and a mutant that survives is a failure of the bench. About 40
    minutes serially, about 11 with `JOBS=8`. `--anchors` checks in about a
    second that every mutation site still matches the HDL; run it after
    editing the writer or the engine.

### Minimig (`CORE/sim/minimig/`)

These benches simulate files of the Minimig submodule with Icarus Verilog.
Where the RTL uses an identifier before declaring it (Vivado accepts that,
Icarus does not), `run_paula_obs.sh` and `run_tb_beamcounter_readback.sh`
move only those declarations in a copy and check that the copy differs from
the original in nothing else.

* `run_paula_obs.sh`: `tb_paula_obs.v` runs the current `paula_floppy.v`
    beside `paula_floppy_ref.v`, a frozen copy with the constant `DSKBYTR`
    stub, and requires bit-identical outputs whenever the observation surface
    is gated off; a CPU model then polls `DSKBYTR` like the Copylock loop and
    must measure the 5 % timing ratio with the surface on and none with it
    off. A few seconds; part of the floppy regression.
* `run_tb_cia_inmode.sh`: the CIA timers with CNT input and the INMODE bits
    (upstream PR 230) against the timers of `fa40334`. About 80 s.
* `run_tb_blitter_freeze.sh`: the blitter freeze of upstream PR 236 against
    the pre-port blitter, followed by a 19-mutant matrix. `MUTANTS=0` runs
    the bench alone in a few seconds; the matrix honours `JOBS`.
* `run_tb_beamcounter_readback.sh [builddir] [--red]`: the beam counter with
    the `VHPOSR` readback (upstream `06f30af`) and the `field1` gate
    (`d16cd84`) against `fa40334`. About ten minutes. `--red` runs six
    controls (broken expectations and mutants) that must all fail, about ten
    minutes on six free cores.

These golden diffs pin the behaviour of individual upstream ports. When a
later submodule update changes one of these files on purpose, update the
bench with it.

### Audio, keyboard, video, cold boot

* `CORE/sim/audio/run.sh`: `tb_iir_amiga.v` measures the A500 and LED
    filters as `audio_filters.vhd` instantiates them against the analytic RC
    prototypes, plus channel separation; `tb_audio_filters.vhd` checks the
    glue (bypass, filter muxes, LED gating, stereo crossfeed) with the
    `+100`-offset filter stub `CORE/sim/stubs/iir_stub_sim.vhd`. Details in
    [the audio notes](audio.md), section 5. A few seconds.
* `CORE/sim/keyboard/run.sh`: three benches for `keyboard.vhd` in MEGA65
    mode. `tb_keyboard` checks balanced make and break codes for shifted
    F-keys and chords, `tb_keyboard_guard` that an acknowledge inside the
    settling window does not release the next code, and `tb_keyboard_lossy`
    the send-then-wait-for-acknowledge flow control against a single-byte
    CIA serial register with a fast, a slow and a non-reading consumer.
    About 75 s.
* `CORE/sim/video/run.sh`: the contract of `analog_positioner.vhd` (the
    analog screen position) over five rasters, progressive and interlaced,
    native and line-doubled: exact bypass at zero offset, both directions,
    pulse widths, interlace phase, clamps, mode changes and reset. About 25 s.
* `CORE/sim/misc/run.sh`: `amiga_cold_boot.vhd` must not cold-boot the Amiga
    at power-on with the default drive map, must with a different map, and a
    deliberately wrong expectation must fail. A few seconds.
