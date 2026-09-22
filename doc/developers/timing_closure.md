# Timing closure and the build re-roll

Now and then a board fails timing although nothing is wrong with the design:
one hold check in the HyperRAM read path misses, usually by a few
picoseconds. Which board and which build it hits is a matter of placement
luck, so `build_all.sh` re-rolls such a board automatically. This note
explains the path, why at present neither a tool setting nor a design change
can fix it, and why the re-roll is safe.

The short version:

* The failing check is the **HyperRAM read capture** of the M2M framework.
  Its hold margin is only 0 to 0.5 ns, and it is decided by the fabric route
  of the RWDS strobe, which changes with every placement.
* **Vivado cannot repair it**, and building again unchanged gives the
  identical result: Vivado is deterministic and has no seed.
* The design-side lever, the **IDELAY tap of the strobe, is field-calibrated**
  and must not change.
* A new placement is a **fresh draw** from the same distribution that every
  shipped build came from. Most placements pass (12 of the 13 R3 and R6
  builds of August and September 2026), so `build_all.sh` keeps drawing until
  one does.

## The path

`M2M/vhdl/controllers/hyperram/hyperram_rx.vhd` samples the eight HyperRAM
data lines with IDDRs that are clocked by the RWDS strobe:

```
hr_d_io[n] -> IBUF -> IDDR D                                   (hard-wired)
hr_rwds_io -> IBUF -> IDELAYE2 (FIXED, 20 taps) -> fabric route -> IDDR C
```

The strobe is a clock on general fabric routing (`CLOCK_BUFFER_TYPE NONE` in
`M2M/common.xdc`) with 36 loads: the eight IDDRs, the receive FIFO and a
clock-domain-crossing flop. For each data bit, the hold slack in the slow
corner comes down to

```
hold slack = 1.544 ns - fabric route from the IDELAY to this IDDR
```

Everything else in the path is fixed silicon: the pins, the IDDR and IDELAY
sites and the constraints are identical on R3, R4, R5 and R6. The route is
not fixed. It depends on where the placer puts the fabric loads of the
strobe, and it moves by a few tenths of a nanosecond from build to build
(0.87 to 1.55 ns have been seen). The WIP-V2-A10 build is a typical case:
R3 closed with DQ4's branch at 1.356 ns (hold +0.187 ns). R6 placed the same
netlist so that the branch grew to 1.552 ns (hold −0.008 ns), and a re-roll
with the `ExtraTimingOpt` placer directive brought it to 1.285 ns
(hold +0.258 ns).

## Why the tools cannot fix it

* The router repairs hold violations by making the **data** path longer.
  Here the data path is the hard-wired pad-to-IDDR connection, so there is
  nothing to lengthen, and the router does not shorten the strobe route to
  gain hold.
* Post-route `phys_opt_design` only works on setup.
* Vivado is deterministic: the same sources, constraints and settings give
  the same bitstream, bit for bit. There is no placer seed; a different
  directive is the closest equivalent.

## Why we do not change the design

The sampling point of the HyperRAM read is the IDELAY delay plus the fabric
route of the strobe. The IDELAY value 20 is the result of a long field
process: individual MEGA65 machines (serial numbers, not board revisions)
differ slightly in their HyperRAM behaviour, and 20 works on 99.999% of
them. So:

* **Changing the tap** would move the sampling point of every MEGA65 away
  from the field-proven setting. That needs a new field campaign, not a build
  fix.
* **Forcing the strobe route**, with fixed routing or by re-routing single
  strobe branches with delay targets, moves the sampling point just the same.
  Re-routing a single branch does not even help much: the new branch has to
  hang off the existing strobe tree, so it cannot be faster than the slow
  trunk that caused the miss.
* **Loosening the input delay constraints** would only hide the missing
  margin.

A new placement changes none of this. It gives the strobe a new route from
the same distribution that every shipped build was drawn from, so the
sampling point stays inside the calibrated range.

## The re-roll in `build_all.sh`

After all selected boards are built, `build_all.sh` re-rolls every board
whose build only missed timing: `TIMING-FAILED` with a setup or hold miss of
at most `REROLL_MAX_MISS` (0.3 ns by default). Synthesis failures, failed
sign-off gates and crashes are never re-rolled, because they are real
problems.

`CORE/reroll_bitstream.tcl` then works through every attempt until one
meets setup and hold:

* After a **hold miss** it tries new placements first (ten placer
  directives), then five router directives on the existing placement.
* After a **setup-only miss** it first runs a harder post-route
  `phys_opt_design`, then the re-routes, then the new placements.
* An attempt that misses setup only gets one more, harder `phys_opt_design`
  pass before it counts as failed.

Every attempt starts from the checkpoints of the failed build, which
`build_all.sh` checks are newer than that build's start. That is the same
synthesized and optimized netlist with the same constraints; only placement,
routing and `phys_opt_design` are redone. The result passes the same sign-off
as a first pass: full timing analysis in both corners, the bitstream
design-rule check and the gates of `build_bitstream.tcl`. A re-rolled
bitstream is therefore exactly as valid as a first-pass one.

The winner replaces `mega65_<board>.bit` and `mega65_<board>.mmi` in
`CORE/CORE-<board>.runs/impl_1`, so `make_release.py`, `m65` and everything
else find it where they always do. Next to it, `mega65_<board>_reroll.txt`
records which attempt won, `mega65_<board>_reroll_timing.rpt` holds its
timing report and `mega65_<board>_reroll.dcp` its checkpoint. All other
reports in that folder describe the failed first pass. The console output
of a re-roll goes to `CORE/build_<board>_reroll.log`.

The summary at the end of `build_all.sh` shows the outcome per board, for
example:

```
RESULT R3 OK WNS=0.133346 WHS=0.031509 bit=CORE-R3.runs/impl_1/mega65_r3.bit
RESULT R6 OK after re-roll 2/15 (place_design ExtraTimingOpt, route_design Explore) WNS=0.093 WHS=0.055 bit=CORE-R6.runs/impl_1/mega65_r6.bit
    first pass: TIMING-FAILED WNS=0.201746 WHS=-0.008183
    REROLL R6 1/15 place_design ExtraPostPlacementOpt, route_design Explore: fail WNS=0.161 WHS=-0.017 (12 min)
    REROLL R6 2/15 place_design ExtraTimingOpt, route_design Explore: PASS WNS=0.093 WHS=0.055 (14 min)
```

An attempt takes about as long as the implementation part of a normal
build: roughly 15 minutes on R6 and 50 on R3. `./build_all.sh --no-reroll`
skips the re-roll pass, and `./build_all.sh --help` lists all options.
