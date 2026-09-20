-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_inputs: asynchronous input conditioner for the MEGA65 internal
-- floppy drive (read milestone). Runs entirely on the 50 MHz front-end clock
-- (= QNICE clock).
--
-- All raw connector pins are asynchronous and active-low at the pin. This
-- block:
--   * 2-FF metastability-synchronizes every raw pin into clk_i. The first
--     flop of each synchronizer carries the Xilinx `async_reg` attribute so
--     the tool places the pair tightly and does not absorb it into SRLs.
--   * passes the static status lines (track0/write-protect/disk-change)
--     through with their ACTIVE-LOW sense preserved - the Amiga CIA-A status
--     mux in paula_floppy.v wants the native open-collector polarity.
--   * qualifies the (active-low) INDEX pulse with a leading-edge glitch
--     filter and measures its period and low-pulse width in clk_i cycles.
--   * passes RDATA through the 2-FF synchronizer with its ACTIVE-LOW sense
--     preserved, because the downstream gap stage (physical_fdd_mfm_gaps)
--     detects the falling edge of an active-low flux pulse.
--
-- INDEX qualification: the pin idles high and pulses low once per revolution.
-- An accepted leading (active-going) edge requires f_index to be seen low
-- continuously for >= C_INDEX_MIN_LOW_CYC cycles; only when the low run first
-- reaches that floor does index_edge_o pulse for exactly one cycle. A low run
-- shorter than the floor (electrical glitch) never pulses. The pin must
-- return high before another edge can be accepted. index_period_o latches
-- the cycle count between the last two accepted leading edges; index_width_o
-- latches the low-run length of the last accepted pulse (measured at
-- return-high); index_active_o is the filtered low level.
--
-- DSKCHG polarity: active-low (change asserted => f_diskchanged_i = '0') is
-- HARDWARE-PROVEN on the MEGA65 mechanism by the C64MEGA65 issue-#90 eject
-- test (raw pin low + change latched when ejected).
--
-- Adapted from C64MEGA65 CORE/vhdl/physical_1581/physical_1581_inputs.vhd
-- (sy2002 2026, GPLv3); changes: active-low pass-through of the status lines
-- (no positive conversion), constants from physical_fdd_pkg.
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity physical_fdd_inputs is
  port (
    clk_i            : in  std_logic;
    rst_i            : in  std_logic;
    -- raw async connector inputs (active-low at pin)
    f_index_i        : in  std_logic;
    f_track0_i       : in  std_logic;
    f_writeprotect_i : in  std_logic;
    f_diskchanged_i  : in  std_logic;
    f_rdata_i        : in  std_logic;
    -- conditioned outputs
    rdata_sync_o     : out std_logic;                  -- 2FF-synced flux, active-low sense preserved
    index_active_o   : out std_logic;                  -- '1' while a filtered index pulse is asserted
    index_edge_o     : out std_logic;                  -- 1-cycle pulse at an accepted index leading edge
    index_period_o   : out unsigned(31 downto 0);      -- cycles between the last two accepted edges
    index_width_o    : out unsigned(31 downto 0);      -- cycles of the last accepted low pulse
    track0_n_o       : out std_logic;                  -- 2FF-synced, active low = head at track 0
    wprot_n_o        : out std_logic;                  -- 2FF-synced, active low = write protected
    change_n_o       : out std_logic                   -- 2FF-synced, active low = disk change latched
  );
end entity physical_fdd_inputs;

architecture rtl of physical_fdd_inputs is

  -- 2-FF metastability synchronizers (idle high = pin deasserted).
  signal f_index_meta  : std_logic := '1';
  signal f_index_sync  : std_logic := '1';
  signal f_track0_meta : std_logic := '1';
  signal f_track0_sync : std_logic := '1';
  signal f_wprot_meta  : std_logic := '1';
  signal f_wprot_sync  : std_logic := '1';
  signal f_chg_meta    : std_logic := '1';
  signal f_chg_sync    : std_logic := '1';
  signal f_rdata_meta  : std_logic := '1';
  signal f_rdata_sync  : std_logic := '1';

  attribute async_reg               : string;
  attribute async_reg of f_index_meta  : signal is "true";
  attribute async_reg of f_track0_meta : signal is "true";
  attribute async_reg of f_wprot_meta  : signal is "true";
  attribute async_reg of f_chg_meta    : signal is "true";
  attribute async_reg of f_rdata_meta  : signal is "true";

  constant C_CNT_MAX  : unsigned(31 downto 0) := (others => '1');

  -- INDEX qualification / measurement state.
  signal idx_low_cnt  : unsigned(31 downto 0) := (others => '0');  -- consecutive low cycles
  signal idx_accepted : std_logic := '0';                          -- current low run accepted
  signal period_cnt   : unsigned(31 downto 0) := (others => '0');  -- free-running interval counter

begin

  -- Active-low pass-throughs for the CIA-A status mux.
  track0_n_o   <= f_track0_sync;
  wprot_n_o    <= f_wprot_sync;
  change_n_o   <= f_chg_sync;

  -- RDATA keeps its active-low sense for the downstream gap detector.
  rdata_sync_o <= f_rdata_sync;

  -- Filtered index low level.
  index_active_o <= idx_accepted;

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      -- 2-FF synchronizers (always run).
      f_index_meta  <= f_index_i;   f_index_sync  <= f_index_meta;
      f_track0_meta <= f_track0_i;  f_track0_sync <= f_track0_meta;
      f_wprot_meta  <= f_writeprotect_i; f_wprot_sync <= f_wprot_meta;
      f_chg_meta    <= f_diskchanged_i;  f_chg_sync   <= f_chg_meta;
      f_rdata_meta  <= f_rdata_i;   f_rdata_sync  <= f_rdata_meta;

      if rst_i = '1' then
        idx_low_cnt    <= (others => '0');
        idx_accepted   <= '0';
        period_cnt     <= (others => '0');
        index_edge_o   <= '0';
        index_period_o <= (others => '0');
        index_width_o  <= (others => '0');
      else
        -- Defaults for this cycle.
        index_edge_o <= '0';
        if period_cnt /= C_CNT_MAX then
          period_cnt <= period_cnt + 1;
        end if;

        if f_index_sync = '0' then
          -- INDEX asserted (low). Grow the low-run counter (saturating).
          if idx_low_cnt /= C_CNT_MAX then
            idx_low_cnt <= idx_low_cnt + 1;
          end if;
          -- Accept the leading edge exactly when the low run first reaches the
          -- glitch floor. Compared against the pre-increment value.
          if idx_accepted = '0' and
             idx_low_cnt = to_unsigned(C_INDEX_MIN_LOW_CYC - 1, idx_low_cnt'length) then
            idx_accepted   <= '1';
            index_edge_o   <= '1';
            index_period_o <= period_cnt;              -- cycles since previous accept
            period_cnt     <= to_unsigned(1, period_cnt'length);
          end if;
        else
          -- INDEX deasserted (high). Close an accepted pulse: latch its width.
          if idx_accepted = '1' then
            index_width_o <= idx_low_cnt;
          end if;
          idx_accepted <= '0';
          idx_low_cnt  <= (others => '0');
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
