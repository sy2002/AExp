
Developers
----------

Want to build the core from source? Here is the whole path from a fresh
clone to a `*.cor` file. This core is built on the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M) framework,
whose [Wiki](https://github.com/sy2002/MiSTer2MEGA65/wiki) is the
authoritative reference for the build environment and its
operating-system specific details.

### What you need

* **Xilinx Vivado 2022.2** to synthesize the FPGA bitstream. The free
  *ML Standard Edition* covers the MEGA65's Artix-7 (XC7A200T). Vivado runs
  on **Linux and Windows only** — there is no macOS build.
* A **`bash` shell with GCC, `make`, `awk` and `git`**, to build the QNICE
  helper CPU's tool chain and the on-screen-menu firmware.
* A **MEGA65** (R3/R3A, R4, R5 or R6) and a legal **Kickstart 1.3 ROM**
  (see the Kickstart ROM section above) to actually run the result.

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

1. **Clone with all submodules** (the Minimig core, the M2M framework and
   QNICE-FPGA):

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

4. **Turn the `*.bit` into a MEGA65 `*.cor` file** with `coretool`, part of
   the [MEGA65 tools](https://github.com/MEGA65/mega65-tools):

   ```bash
   cd CORE/CORE-R3.runs/impl_1
   coretool -B AExp-WIP-V1-A3-R3.cor --bit mega65_r3.bit --target mega65r3 --bit-name "Amiga 500 for MEGA65" --bit-version "WIP-V1-A3"
   ```

   Use the target string that matches your board — `mega65r3`, `mega65r4`,
   `mega65r5` or `mega65r6` — and the version string from the `CORE_VERSION`
   constant in `CORE/vhdl/config.vhd`. Unlike the C64 core, the Amiga core
   registers no MEGA65 file type (ADFs are mounted from inside its own
   menu), so no `--flags` or `--caps` arguments are needed. The
   `make_release.py` packaging script runs this step for you and prefers
   `coretool` when both it and `bit2core` are installed.

5. **Deploy and run.** Copy the `*.cor` to the MEGA65 (or, with a JTAG
   adaptor, flash the `*.bit` directly with `m65 -q mega65_r3.bit`) and
   follow the Installation steps above. Remember that the Kickstart ROM at
   `/amiga/kick.rom` is mandatory — without it the core stops at an error
   screen.

### Settings file

For the core to remember your menu settings, the SD card needs an
`aexp-<version>.cfg` file in `/amiga` (see Installation). Release
packages made with `make_release.py` already contain the matching file.
If you build from source yourself, create one with default settings
using the M2M helper; the `auto` argument reads the required size
straight from `config.vhd`:

```bash
cd M2M/tools
./make_config.sh aexp-WIP-V1-A3 auto
```

Run it from inside `M2M/tools` — the `auto` argument reads the required
size from `config.vhd` via a relative path. Use the same `<version>` as
the `CORE_VERSION` constant in `CORE/vhdl/config.vhd`.

### Going deeper

* `doc/how_to_port.md` is the engineering reference for this port: the M2M
  architecture, the MiSTer-to-MEGA65 porting walkthrough and a
  Quartus-to-Vivado pattern catalog.
* The [M2M Wiki](https://github.com/sy2002/MiSTer2MEGA65/wiki) documents the
  build environment in depth and explains the QNICE debug console — a
  real-time serial log and interactive monitor, available if you have a
  JTAG adaptor.
  