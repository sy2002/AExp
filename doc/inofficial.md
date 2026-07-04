# Work-in-Progress: List of inofficial builds

The purpose of this list is to track down regressions introduced in newer
builds that were not there in older builds. By finding the last known-to-work
build, we have a better chance to hunt down problems. The name of the build
can be checked in the "About & Help" menu of the core.

## Version 1

| Name          | Date     | Commit  | Comment
|---------------|----------|---------|----------------------------------------
| WIP-V1-A1     | 06/10/26 | fcf0a90 | First sign of life: THE HAND. No disk drive support, yet.
| WIP-V1-A2     | 07/03/26 | 61f4106 | Disk drive support, Amiga mouse support, HDMI scaling filters with Lanczos default, versioned config file
| WIP-V1-A3     | 07/04/26 |         | Interlace support: Deinterlacing on HDMI (laced screens like 640x512 Workbench and demo parts no longer flicker). VGA modes: Standard (31 kHz) or retro 15 kHz RGB with HS/VS or CSYNC for CRTs/SCART. Right and middle mouse button work with active mouse adapters (mouSTer, MicroTom, etc.); fixes the inverted right button that stalled Workbench folder loading.
