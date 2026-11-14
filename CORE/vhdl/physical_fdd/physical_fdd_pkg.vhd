-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_pkg: constants for the MEGA65 internal floppy drive used as a
-- real Amiga drive (the Hardware Floppy, which can be df0:, df1: or df2:).
-- The read front end takes its constants from here; the write constants
-- live in physical_fdd_writer, which takes only its cell length from this
-- package (C_CELL := C_HALF_CELL_CYC).
--
-- All magnetic timing derives from a single front-end clock frequency
-- C_FDD_HZ = 50 MHz (the exact QNICE-domain clock). The read values are the
-- ones proven on real R3 hardware by the C64MEGA65 physical-1581 bring-up
-- (C64MEGA65 GitHub #90): Amiga DD MFM uses the same 2 us channel cell and
-- 4/6/8 us flux gaps at 300 RPM as 1581 and PC DD media, so the gap
-- quantisation and the index qualification transfer unchanged.
--
-- Adapted from C64MEGA65 CORE/vhdl/physical_1581/physical_1581_pkg.vhd
-- (sy2002 2026, GPLv3; magnetic constants in turn rooted in mega65-core,
-- Paul Gardner-Stephen / MEGA65, LGPLv3).
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package physical_fdd_pkg is

  -- Front-end clock (exact; QNICE domain).
  constant C_FDD_HZ     : natural := 50_000_000;
  constant C_PERIOD_NS  : natural := 1_000_000_000 / C_FDD_HZ;   -- 20 ns
  constant C_CYC_PER_US : natural := C_FDD_HZ / 1_000_000;       -- 50

  -----------------------------------------------------------------------------
  -- DD MFM timing @ 50 MHz (250 kbit/s data = 500 kbit/s channel, 300 RPM)
  --
  -- "Half cell" = one MFM channel-bit period = 2 us. Flux transitions are
  -- 2, 3 or 4 channel cells apart (gaps of 4/6/8 us).
  -----------------------------------------------------------------------------
  constant C_HALF_CELL_CYC : natural := 100;   -- 2 us channel cell
  constant C_GAP_SHORT_CYC : natural := 200;   -- 4 us nominal flux gap
  constant C_GAP_MED_CYC   : natural := 300;   -- 6 us
  constant C_GAP_LONG_CYC  : natural := 400;   -- 8 us

  -----------------------------------------------------------------------------
  -- Adaptive gap quantiser (unchanged from the C64MEGA65 physical-1581
  -- decoder)
  --
  -- The quantiser tracks the live half-cell length as a fixed-point estimate
  -- est with C_QUANT_FRAC fraction bits (unit: 50 MHz cycles; nominal 100.0).
  -- Each gap G is classified to the nearest class n in {2,3,4} half-cells via
  -- the midpoints 2.5*est / 3.5*est and accepted iff
  --     |G - n*est| is at most est / 2**C_QUANT_TOL_SHR
  -- With C_QUANT_TOL_SHR = 1 the acceptance windows touch at the midpoints:
  -- every gap in [1.5*est .. 4.5*est] gets a class, there are no dead-bands,
  -- and everything outside is class "11" (loss of lock), which also re-seeds
  -- est to nominal. On every accepted gap est adapts by a fixed step of
  -- C_QUANT_STEP_Q toward the gap (sign-based, median-seeking), hard-clamped
  -- to +/-10% of nominal. physical_fdd_mfm_quantise explains why a
  -- sign-based step beats a proportional IIR under peak shift.
  -- The adaptivity also helps the Amiga: "long track" protections write
  -- 2..5% denser than nominal and stay inside the tracked window.
  -----------------------------------------------------------------------------
  constant C_QUANT_FRAC      : natural := 4;   -- fraction bits of est (1/16 cycle)
  constant C_QUANT_EST_MIN   : natural := 90;  -- clamp, integer cycles (-10%)
  constant C_QUANT_EST_MAX   : natural := 110; -- clamp, integer cycles (+10%)
  constant C_QUANT_TOL_SHR   : natural := 1;   -- tolerance = est/2 (windows touch)
  constant C_QUANT_STEP_Q    : natural := 2;   -- adaptation step: 2/16 = 1/8 cycle
  constant C_QUANT_EST_NOM_Q : natural := C_HALF_CELL_CYC * 2**C_QUANT_FRAC;
  constant C_QUANT_EST_MIN_Q : natural := C_QUANT_EST_MIN * 2**C_QUANT_FRAC;
  constant C_QUANT_EST_MAX_Q : natural := C_QUANT_EST_MAX * 2**C_QUANT_FRAC;

  -----------------------------------------------------------------------------
  -- Digital PLL data separator (physical_fdd_bits, the default bit source)
  --
  -- Measured on old media, read failures are rare single-transition events
  -- on top of a clean, est-tracked body: intervals up to about +/-20% off
  -- nominal (accepted extremes of 162 and 438 cycles, margins down to 0.19
  -- cycles) and about 40 outright rejects per failing read session.
  -- Interval classification amplifies every such event: the displaced edge
  -- distorts two adjacent intervals, a class flip inserts or deletes channel
  -- bits (a slip that corrupts everything up to the next sync), and a reject
  -- triggers the loud resync. The DPLL instead assigns each flux edge to a
  -- cell of a continuously phase- and frequency-tracked grid, like the
  -- separator in front of a real Paula:
  --
  --   every cycle:  phase += 1 cycle; at phase >= cell emit one channel bit
  --                 ('1' if an edge fell into the elapsed cell, else '0')
  --                 and wrap phase -= cell
  --   every edge:   err = phase - cell/2 (where the edge landed vs the
  --                 window center); phase -= err/2**C_DPLL_PGAIN (fast
  --                 phase pull toward centered edges); cell +=
  --                 err/2**C_DPLL_FGAIN (slow period tracking), hard-
  --                 clamped to the same +/-10% span as the quantiser
  --
  -- Tolerance per event: +/- cell/2 (= +/-1 us) of phase error at the
  -- decision point. Errors stay local (one bit position: no slip, no
  -- resync; droughts free-run '0's by construction), and the phase pull
  -- absorbs systematic bias and drift continuously instead of at 1/8 cycle
  -- per gap. The quantiser keeps running as a passive observer, so the
  -- margin instruments measure the same way in both modes; diagnostics
  -- register 0x35 bit 6 selects the legacy path at run time.
  -----------------------------------------------------------------------------
  constant C_DPLL_PGAIN : natural := 1;   -- phase correction: err/2 per edge
  constant C_DPLL_FGAIN : natural := 6;   -- period correction: err/64 per edge

  -- Runt-merge threshold for the gap stage: only true electrical runts
  -- (measured on this mechanism in the C64MEGA65 bring-up: edges 20-40 ns
  -- apart) merge into their successor; everything longer stays a loud
  -- out-of-window gap. It must stay far below the shortest valid window: a
  -- larger value turns late-in-gap noise into a merge of the following real
  -- edge, a regression the C64MEGA65 bring-up hit.
  constant C_GAP_GLITCH   : natural := 16;     -- 320 ns; below: electrical glitch

  -----------------------------------------------------------------------------
  -- Flux-drought zero synthesis (Amiga-specific, legacy bit source of
  -- physical_fdd_bits; the DPLL free-runs through droughts)
  --
  -- A real data separator keeps emitting '0' channel bits at the nominal cell
  -- rate when no transitions arrive (degaussed or unformatted regions).
  -- Without this the reconstructed bitstream would stall and Paula's DMA
  -- would hang where real hardware does not. The filler arms beyond the
  -- longest legal gap acceptance span (4.5 * est_max = 495 cycles) and then
  -- emits one '0' per nominal cell. The next real edge produces an
  -- oversized gap = class "11" = a loud resync, so filler bits never corrupt
  -- locked data.
  -----------------------------------------------------------------------------
  constant C_DROUGHT_ARM_CYC  : natural := 512;              -- > 4.5 * est_max
  constant C_DROUGHT_CELL_CYC : natural := C_HALF_CELL_CYC;  -- one '0' per 2 us

  -----------------------------------------------------------------------------
  -- INDEX qualification (physical_fdd_inputs)
  --
  -- The pin idles high and pulses low once per revolution (200 ms at 300
  -- RPM); valid low pulses are 1.5..5 ms wide. An accepted leading edge
  -- requires the pin low for a continuous glitch floor first.
  -----------------------------------------------------------------------------
  constant C_INDEX_MIN_LOW_CYC : natural := 10_000;          -- 200 us floor

  -----------------------------------------------------------------------------
  -- Drive-ready model (physical_fdd_top)
  --
  -- The 34-pin PC interface has no READY output, so RDY towards CIA-A is
  -- synthesized (the C64MEGA65 model of the Chinon FB-354 line):
  --   * motor off: ready is asserted, which makes the motor-off drive-ID
  --     shift protocol of AmigaOS read 0xFFFFFFFF = "3.5 inch DD drive
  --     present" for an external unit (df1:, df2:).
  --   * motor on: ready after the spin-up gate, i.e. motor on for >= 505 ms,
  --     >= 2 qualified index edges since motor-on and a fresh index edge,
  --     then held while the motor stays on. The mechanism gates INDEX on
  --     /SEL, so freshness starves across deselect gaps; an eject is
  --     detected through /DSKCHG instead.
  -----------------------------------------------------------------------------
  constant C_READY_MOTOR_CYC  : natural := 25_250_000;       -- 505 ms spin-up
  constant C_READY_MIN_EDGES  : natural := 2;                -- index edges gate
  constant C_INDEX_STALE_CYC  : natural := 12_500_000;       -- 250 ms: not fresh

  -----------------------------------------------------------------------------
  -- Sector-header capture (physical_fdd_top -> physical_fdd_diag)
  --
  -- After every DSKSYNC match the front end records the following
  -- C_CAP_WORDS words of the sync-anchored diagnostic word stream. An Amiga
  -- sector starts with the double 0x4489; the words after the last sync of
  -- that pair are the MFM-encoded info longword (2 odd + 2 even words: 0xFF,
  -- track, sector, sectors-to-gap) followed by the label area. That is
  -- enough to read the track and sector number the header claims, which
  -- shows directly whether the head sits on the cylinder and side the Amiga
  -- asked for.
  -----------------------------------------------------------------------------
  constant C_CAP_WORDS : natural := 8;
  type t_fdd_cap_words is array (0 to C_CAP_WORDS - 1) of
    std_logic_vector(15 downto 0);

  -----------------------------------------------------------------------------
  -- Interval-domain margin instrumentation (physical_fdd_top)
  --
  -- The quantiser classifies each gap G to the nearest class n and accepts
  -- iff |G - n*est| <= tol (= est/2). The margin engine records, for every
  -- accepted gap inside its gate, the signed error e = G - n*est in a
  -- per-class histogram of C_HIST_BINS bins spanning [-tol .. +tol) (bin
  -- width tol/4): a healthy channel concentrates every class around bin
  -- 3/4; a systematic short-gap read bias with the estimate dragged to
  -- compensate shows the short class centered and the medium/long classes
  -- complementarily offset; uniform speed error offsets all classes the
  -- same way. Together with the tracked minimum of (tol - |e|) this gives
  -- the classification-margin profile of a disk. Bins are 16-bit
  -- saturating.
  --
  -- The per-sector miss profile counts, per sector number, the qualified
  -- read revolutions whose revolution mask lacked that sector. A revolution
  -- qualifies if it produced >= C_MISS_QUAL_CAPS header captures and the
  -- decode chain ran for its whole index-to-index window (a deselect hole
  -- would leave sectors uncaptured without any flux fault). The profile
  -- tells "the decode always fails at one physical spot" from "misses
  -- rove". 8-bit saturating counters, packed two per diag word.
  -----------------------------------------------------------------------------
  constant C_HIST_BINS      : natural := 8;
  type t_fdd_hist is array (0 to 3 * C_HIST_BINS - 1) of unsigned(15 downto 0);
  type t_fdd_miss is array (0 to 5) of std_logic_vector(15 downto 0);
  constant C_MISS_QUAL_CAPS : natural := 8;   -- captures/rev for a "read rev"

end package physical_fdd_pkg;
