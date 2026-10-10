Developers
----------

Want to build the core from source? Here is the whole path from a fresh
clone to a `*.cor` file. This core is built on the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M) framework,
whose [Wiki](https://github.com/sy2002/MiSTer2MEGA65/wiki) is the
authoritative reference for the build environment and its
operating-system specific details. If you want to understand or change the
core, start with the [developer documentation](#developer-documentation) at
the end of this page.

### What you need

* **Xilinx Vivado 2022.2** to synthesize the FPGA bitstream. The free
  *ML Standard Edition* covers the MEGA65's Artix-7 (XC7A200T). Vivado runs
  on **Linux and Windows only** — there is no macOS build.
* A **`bash` shell with GCC, `make`, `awk` and `git`**, to build the QNICE
  helper CPU's tool chain and the on-screen-menu firmware.
* A **MEGA65** (R3/R3A, R4, R5 or R6) and a legal **Kickstart 1.3 ROM**
  (see [Kickstart ROM](../README.md#kickstart-rom) in the main README) to
  actually run the result.

Operating-system hints for the `bash` tool chain:

* **Linux:** install `build-essential` (or your distribution's GCC and
  `make` packages), `gawk` and `git`. Everything, including Vivado, runs
  natively.
* **macOS:** `xcode-select --install` provides the compiler and `make`;
  `git` and `awk` are already there. You can build the tool chain and the
  firmware natively, but since Vivado has no macOS build you need to run
  the synthesis on Linux or Windows — for example in a Linux VM (Parallels,
  UTM, VirtualBox) that mounts this working folder.
* **Windows:** Vivado runs natively. For the `bash` tool chain use **WSL2**
  (Ubuntu) or **MSYS2 / Git Bash**.

### Build the core

1. **Clone with all submodules** (the Minimig core and QNICE-FPGA; the M2M
    framework is part of this repository):

    ```bash
    git clone --recursive https://github.com/sy2002/AExp.git
    cd AExp
    ```

    Already cloned without `--recursive`? Pull the submodules in afterwards:

    ```bash
    git submodule update --init --recursive
    ```

2. **Build the QNICE tool chain.** This compiles the assembler, the
    QNICE C compiler, etc. natively for your operating system:

    ```bash
    cd M2M/QNICE/tools
    ./make-toolchain.sh
    ```

    Answer every prompt by pressing <kbd>Enter</kbd>. When it finishes,
    return to the repository root (`cd ../../..`).

3. **Open the Vivado project for your board and generate the bitstream.**
    There is one project per MEGA65 revision:

    | Board      | Vivado project     |
    |------------|--------------------|
    | R3 / R3A   | `CORE/CORE-R3.xpr` |
    | R4         | `CORE/CORE-R4.xpr` |
    | R5         | `CORE/CORE-R5.xpr` |
    | R6         | `CORE/CORE-R6.xpr` |

    Run **Generate Bitstream**. Vivado rebuilds the QNICE on-screen-menu
    firmware automatically in a pre-synthesis step, so there is nothing else
    to prepare. The bitstream ends up in
    `CORE/CORE-R3.runs/impl_1/mega65_r3.bit` (substitute your board).

    Check the timing summary of the implemented design: the worst negative
    slack (WNS) and the worst hold slack (WHS) must both be 0 or positive.

4. **Turn the `*.bit` into a MEGA65 `*.cor` file** with `coretool`, part of
    the [MEGA65 tools](https://github.com/MEGA65/mega65-tools):

    ```bash
    cd CORE/CORE-R3.runs/impl_1
    coretool -B AExp-WIP-V2-B2-R3.cor --bit mega65_r3.bit --target mega65r3 --bit-name "Amiga 500 for MEGA65" --bit-version "WIP-V2-B2"
    ```

    Use the target string that matches your board — `mega65r3`, `mega65r4`,
    `mega65r5` or `mega65r6` — and the version string from the `CORE_VERSION`
    constant in `CORE/vhdl/config.vhd` (`WIP-V2-B2` in this example). Unlike
    the C64 core, the Amiga core registers no MEGA65 file type (ADFs are
    mounted from inside its own menu), so no `--flags` or `--caps` arguments
    are needed.

5. **Deploy and run.** Copy the `*.cor` to the MEGA65 (or, with a JTAG
    adaptor, flash the `*.bit` directly with `m65 -q mega65_r3.bit`) and
    follow the [installation steps](../README.md#installation) in the main
    README. Remember that the Kickstart ROM at `/amiga/kick.rom` is
    mandatory — without it the core stops at an error screen.

### Build all boards in batch mode

To build several boards without the Vivado GUI, source the Vivado environment
and run the build script, which is made for overnight runs:

```bash
cd CORE
source /tools/Xilinx/Vivado/2022.2/settings64.sh  # adjust this path
nohup ./build_all.sh > build_all.out 2>&1 &
```

Without arguments it builds R3, R4, R5 and R6, one after another. Pass board
names to build only a subset (for example `./build_all.sh R3 R6`), and set
`JOBS=<n>` to choose how many parallel workers Vivado may use for each board
(the default is 4), for example `JOBS=8 ./build_all.sh R3 R6`. Each board
writes `build_R<n>.log`, and the run ends with a compact summary of the
timing and sign-off result of every board. `./build_all.sh --help` lists all
options.

Now and then a board misses timing although the design is fine, usually by a
few picoseconds of hold in the HyperRAM read capture of the framework. Whether
it happens, and to which board, depends on where the placer happens to put
things. `build_all.sh` handles this pragmatically: once all boards are built,
it implements every board that missed by no more than 0.3 ns again, from the
same synthesized netlist but with other placer and router directives, until
one attempt meets timing. The winning bitstream replaces the failed one in the
usual place, `build_R<n>_reroll.log` records the attempts, and the summary
shows the first pass and every attempt. `./build_all.sh --no-reroll` skips
this pass.

The obvious fix, changing the delay value of the HyperRAM read strobe, is not
an option: that value is calibrated on many MEGA65 machines in the field.
[`timing_closure.md`](developers/timing_closure.md) explains the failing path,
why the delay must stay as it is, and why a re-rolled bitstream passes the
same sign-off and is exactly as valid as a first-pass one.

### Settings file

For the core to remember your menu settings, the SD card needs an
`aexp-<version>.cfg` file in `/amiga` (see the
[installation steps](../README.md#installation)). Release packages made with
`make_release.py` already contain the matching file. If you build from source
yourself, create one with default settings using the M2M helper; the `auto`
argument reads the required size straight from `config.vhd`:

```bash
cd M2M/tools
./make_config.sh aexp-WIP-V2-B2.cfg auto
```

Run it from inside `M2M/tools` — the `auto` argument reads the required
size from `config.vhd` via a relative path. Use the same `<version>` as
the `CORE_VERSION` constant in `CORE/vhdl/config.vhd`, and do type the
`.cfg` suffix: the script writes exactly the file name you give it, and a
file without the suffix is never found, so settings are silently not saved.

The file is created empty, which means "use the defaults from
`config.vhd`". Do not copy an older `aexp-*.cfg` forward under the new
name even when the two have the same size: a file you have already used
holds your saved selections, and they override the defaults the new build
ships with.

### Packaging a release

`make_release.py` in the repository root packages a release: it converts the
bitstreams of all boards into `*.cor` files (with `coretool`, or `bit2core`
if `coretool` is not installed), creates the settings file and collects the
documentation and the screen-adjustment files into one folder:

```bash
python3 make_release.py WIP-V2-B2 /tmp/builds
```

The version must match `CORE_VERSION`. A work-in-progress build (`WIP-*`)
also needs its row in [inofficial.md](inofficial.md). Run
`python3 make_release.py --help` for the options, for example packaging only
some boards.

### Developer documentation

* [Architecture overview](developers/architecture.md): what the core
  simulates, how it is layered from the board top down to Minimig, the
  repository layout, clock domains, QNICE devices and HyperRAM map, the rules
  to respect when you change something, the changes to the M2M framework and
  to the Minimig core, and the MiSTer software the core replaces.
* [Floppy drives with ADF images](developers/floppy-adf.md): how the
  simulated drives read and write `*.adf` images, from the Amiga disk format
  to the write-back to the SD card.
* [The Hardware Floppy](developers/hardware-floppy.md): the MEGA65's
  internal drive as a real Amiga drive.
* [Timing closure and the build re-roll](developers/timing_closure.md).
* [Audio](developers/audio.md): the audio path, the A500 and LED filters and
  the stereo mix.
* [HDMI latency](developers/hdmi_latency.md): how much the HDMI path delays
  the picture, and the flicker-free mode.
* [Tools and testbenches](developers/tools.md): the menu and firmware
  checkers, the Hardware Floppy diagnostics decoder and flux analysis
  scripts, the simulation testbenches, and the checks to run before a
  synthesis.
* MiSTer's floppy service [`minimig_fdd.cpp`](developers/minimig_fdd.cpp) and
  configuration code [`minimig_config.cpp`](developers/minimig_config.cpp):
  verbatim copies of the software that `adf_track_engine.vhd` and
  `amiga_config.vhd` were modelled on.
* The [M2M Wiki](https://github.com/sy2002/MiSTer2MEGA65/wiki) documents the
  build environment in depth and explains the QNICE debug console — a
  real-time serial log and interactive monitor, available if you have a
  JTAG adaptor.
