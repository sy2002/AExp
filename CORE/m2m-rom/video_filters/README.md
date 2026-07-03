# Core-local polyphase filter coefficients

Coefficient blobs for the HDMI Filter options that are NOT already linked
into the firmware by the M2M framework. The framework (M2M V2.0.1,
`M2M/rom/filters.asm`) only ships `lanczos2_12.asm` and `Scan_Br_110_80.asm`;
the three blobs here were taken from C64MEGA65 V6 (`M2M/video_filters/` of
the M2M V2.1 line) and cover the remaining polyphase options:

| File | Label | Used by (H/V) |
|---|---|---|
| `GS_Sharpness_050.asm` | `GS_SHARPNESS_050` | Smooth (H and V) |
| `CRT_Sim_SVideo_H.asm` | `CRT_SIM_SVIDEO_H` | CRT (S-Video) (H only) |
| `CRT_Sim_Composite_H.asm` | `CRT_SIM_COMPOSITE_H` | CRT (Composite) (H only) |

Both CRT options reuse `SCAN_BR_110_80` as the vertical file: the original
MiSTer `CRT_Sim_*_V` blobs are designed to be combined with the MiSTer gamma
LUT and shadow mask, which M2M does not support, and standalone they crush
bright content into a dark band. The Composite-vs-S-Video character lives
entirely in the horizontal file.

Format: 64 phases x 4 signed 10-bit taps = 256 words per blob (see
`M2M/video_filters/README.md`). The `.txt` files are the MiSTer-format
sources; `.asm` files were generated with C64MEGA65's
`M2M/video_filters/convert.py`.

When the M2M submodule/framework is upgraded to V2.1+, these files (and the
`M2M$LOAD_POLYPHASE` backport in `m2m-rom.asm`) can be deleted in favor of the
framework copies.
