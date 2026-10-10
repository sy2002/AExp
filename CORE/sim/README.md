# Testbenches

Simulation testbenches for the core and for the framework parts it relies on,
one folder per area, each with its runner scripts; `run_all.sh` is the gate
before a synthesis, `run_long.sh` runs the long suites (the floppy stack, the
beam counter, the full scandoubler matrix), and `stubs/` holds the simulation
stubs of the Xilinx libraries. `video/` holds two benches: the analog
positioner (`run.sh`) and the analog Standard VGA scandoubler
(`run_scandoubler.sh`: 11 checks in the gate, all 57 in the long suites).

What each bench verifies, how to run it and how long it takes:
[Tools and testbenches](../../doc/developers/tools.md).
