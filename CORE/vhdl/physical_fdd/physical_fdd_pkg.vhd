-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_pkg: constants for the MEGA65 internal floppy drive used as a
-- real Amiga drive (df0:/df1:), read milestone.
--
-- All magnetic timing derives from a single front-end clock frequency
-- C_FDD_HZ = 50 MHz (the exact QNICE-domain clock). The values are the ones
-- proven on real R3 hardware by the C64MEGA65 physical-1581 bring-up (issue
-- #90 there): Amiga DD MFM uses the same 2 us channel cell / 4-6-8 us flux
-- gaps at 300 RPM as 1581/PC DD media, so the gap quantisation and index
-- qualification transfer unchanged.
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
  -- Adaptive gap quantiser (C64MEGA65 issue #90 round 12, verbatim)
  --
  -- The quantiser tracks the live half-cell length as a fixed-point estimate
  -- est with C_QUANT_FRAC fraction bits (unit: 50 MHz cycles; nominal 100.0).
  -- Each gap G is classified to the nearest class n in {2,3,4} half-cells via
  -- the midpoints 2.5*est / 3.5*est and ACCEPTED iff
  --     |G - n*est| is at most est / 2**C_QUANT_TOL_SHR
  -- With C_QUANT_TOL_SHR = 1 the acceptance windows touch at the midpoints:
  -- every gap in [1.5*est .. 4.5*est] gets a class, there are NO dead-bands,
  -- and everything outside is class "11" (loss of lock), which also re-seeds
  -- est to nominal. On every accepted gap est adapts by a FIXED step of
  -- C_QUANT_STEP_Q toward the gap (sign-based / median-seeking), hard-clamped
  -- to +/-10% of nominal. See the C64MEGA65 pkg for the full A/B-harness
  -- rationale (why sign-based beats a proportional IIR under peak shift).
  -- The adaptivity is a genuine win for the Amiga: "long track" protections
  -- write 2..5% denser than nominal and stay inside the tracked window.
  -----------------------------------------------------------------------------
  constant C_QUANT_FRAC      : natural := 4;   -- fraction bits of est (1/16 cycle)
  constant C_QUANT_EST_MIN   : natural := 90;  -- clamp, integer cycles (-10%)
  constant C_QUANT_EST_MAX   : natural := 110; -- clamp, integer cycles (+10%)
  constant C_QUANT_TOL_SHR   : natural := 1;   -- tolerance = est/2 (windows touch)
  constant C_QUANT_STEP_Q    : natural := 2;   -- adaptation step: 2/16 = 1/8 cycle
  constant C_QUANT_EST_NOM_Q : natural := C_HALF_CELL_CYC * 2**C_QUANT_FRAC;
  constant C_QUANT_EST_MIN_Q : natural := C_QUANT_EST_MIN * 2**C_QUANT_FRAC;
  constant C_QUANT_EST_MAX_Q : natural := C_QUANT_EST_MAX * 2**C_QUANT_FRAC;

  -- Runt-merge threshold for the gaps stage: only true electrical runts (the
  -- C64MEGA65 GAP_MIN = 0x0001 hardware evidence: edges 20-40 ns apart) merge
  -- into their successor; everything longer stays a loud out-of-window gap.
  -- Deliberately FAR below the shortest valid window (a larger value turns
  -- late-in-gap noise into a merge of the following REAL edge - the round-10
  -- regression over there).
  constant C_GAP_GLITCH   : natural := 16;     -- 320 ns; below: electrical glitch

  -----------------------------------------------------------------------------
  -- Flux-drought zero synthesis (Amiga-specific, physical_fdd_bits)
  --
  -- A real data separator keeps emitting '0' channel bits at the nominal cell
  -- rate when no transitions arrive (degaussed/unformatted regions). Without
  -- this the reconstructed bitstream would stall and Paula's DMA would hang
  -- harder than on real hardware. The filler arms beyond the longest legal
  -- gap acceptance span (4.5 * est_max = 495 cycles) and then emits one '0'
  -- per nominal cell. The next real edge produces an oversized gap = class
  -- "11" = a loud resync, so filler bits never corrupt locked data.
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
  --   * motor OFF: ready is asserted while selected - this is what makes
  --     AmigaOS's motor-off drive-ID shift protocol read 0xFFFFFFFF =
  --     "3.5 inch DD drive present" for df1:.
  --   * motor ON: ready after the spin-up gate = motor on for >= 505 ms AND
  --     >= 2 qualified index edges since motor-on AND a fresh index edge -
  --     then HELD while the motor stays on (the mechanism gates INDEX on
  --     /SEL, so freshness starves across deselect gaps; eject detection is
  --     /DSKCHG's job, hardware-proven).
  -----------------------------------------------------------------------------
  constant C_READY_MOTOR_CYC  : natural := 25_250_000;       -- 505 ms spin-up
  constant C_READY_MIN_EDGES  : natural := 2;                -- index edges gate
  constant C_INDEX_STALE_CYC  : natural := 12_500_000;       -- 250 ms = no disk

  -----------------------------------------------------------------------------
  -- Sector-header capture (physical_fdd_top -> physical_fdd_diag)
  --
  -- After every DSKSYNC alignment hit the front-end records the following
  -- C_CAP_WORDS reconstructed words. An Amiga sector starts with the double
  -- 0x4489; the words after the LAST sync of that pair are the MFM-encoded
  -- info longword (2 odd + 2 even words: 0xFF, track, sector, sectors-to-gap)
  -- followed by the label area - enough to read the track number the header
  -- claims, the one observation that separates a side-select inversion from
  -- every downstream suspect.
  -----------------------------------------------------------------------------
  constant C_CAP_WORDS : natural := 8;
  type t_fdd_cap_words is array (0 to C_CAP_WORDS - 1) of
    std_logic_vector(15 downto 0);

  -----------------------------------------------------------------------------
  -- Interval-domain margin instrumentation (diag map v7, physical_fdd_top)
  --
  -- The quantiser classifies each gap G to the nearest class n and accepts
  -- iff |G - n*est| <= tol (= est/2). The margin engine records, for every
  -- ACCEPTED gap inside its gate, the SIGNED error e = G - n*est in a
  -- per-class histogram of C_HIST_BINS bins spanning [-tol .. +tol) (bin
  -- width tol/4): a healthy channel concentrates every class around bin
  -- 3/4; a systematic short-gap read bias with the estimate dragged to
  -- compensate shows the short class centered and the medium/long classes
  -- complementarily offset; uniform speed error offsets all classes the
  -- same way. Together with the tracked minimum of (tol - |e|) this is the
  -- measured classification-margin profile the separator redesign needs.
  -- Bins are 16-bit SATURATING.
  --
  -- The per-sector miss profile counts, per sector number, the qualified
  -- read revolutions (>= C_MISS_QUAL_CAPS header captures) whose
  -- revolution mask lacked that sector - the discriminator between "the
  -- decode always fails at one physical spot" and "misses rove". 8-bit
  -- saturating counters, packed two per diag word.
  -----------------------------------------------------------------------------
  constant C_HIST_BINS      : natural := 8;
  type t_fdd_hist is array (0 to 3 * C_HIST_BINS - 1) of unsigned(15 downto 0);
  type t_fdd_miss is array (0 to 5) of std_logic_vector(15 downto 0);
  constant C_MISS_QUAL_CAPS : natural := 8;   -- captures/rev for a "read rev"

end package physical_fdd_pkg;
