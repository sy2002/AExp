-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- tb_fdd_dpll: testbench for the DPLL data separator against the legacy
-- interval classifier, end-to-end through physical_fdd_top (conditioner ->
-- gaps -> observer quantiser -> bits/aligner -> word FIFO). One source runs
-- in both modes via the G_LEGACY generic (nvc -e tb_fdd_dpll
-- -gG_LEGACY=true).
--
-- The stimulus is a real Amiga header stream: 4x 0xAAAA lock preamble, the
-- double 0x4489 sync, the MFM-encoded info long 0xFF510006 (the header of
-- track 81 as captured from a real disk) and encoded-zero label words. The
-- scenarios reproduce the interval events measured on real media (accepted
-- interval extremes at -19%/+12%, occasional outright rejects, single
-- sectors missed at random positions):
--
--   S1 clean     nominal flux                -> both modes decode exactly
--   S2 displace  one edge moved +40 cycles   -> both modes decode exactly
--                (the sub-boundary band: legacy classes hold, the DPLL
--                 window centers - documents the shared tolerance floor)
--   S3 dropout   one edge removed, merging a 2+3-cell pair into a single
--                500-cycle interval (a weak-bit event).
--                Legacy: class "11" -> loss-of-lock resync -> every word
--                after the event is corrupted until the next sync (the
--                amplification that turns one flux event into a lost
--                sector; the bench requires it, as a control). DPLL: the
--                removed '1' reads as '0' - exactly one word differs by one
--                bit and everything after stays exact (damage stays local).
--   S4 bias      whole stream at -3% cell length -> both modes track and
--                decode exactly.
--
-- Expected words are literals (the aligner emits sync-anchored from the
-- first 0x4489): 4489 4489 552A AAA9 5551 2AA4 AAAA x5.
--
-- Run: CORE/sim/floppy/run_fdd_regression.sh (cells dpll_dpll, dpll_legacy);
-- a few seconds each.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity tb_fdd_dpll is
  generic (
    G_LEGACY : boolean := false
  );
end entity tb_fdd_dpll;

architecture sim of tb_fdd_dpll is

  constant C_CLK : time := 20 ns;

  -- gap sequence of the stimulus stream, in cells (from the word list;
  -- the first '1' is the starter edge and emits no gap)
  type t_intvec is array (natural range <>) of integer;
  constant C_GAPS : t_intvec := (
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    3,4,3,4,3,2,4,3,4,3,2,2,2,2,3,2,2,2,2,2,2,2,2,2,3,2,2,2,2,2,2,
    4,3,2,2,2,2,3,3,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2 );
  -- gaps 54/55 are a 2+3-cell pair whose shared edge sits inside the info
  -- long (bit 124 = word 7 bit 3): S2 displaces it, S3 removes it
  constant C_EV : natural := 54;

  type t_wordvec is array (natural range <>) of std_logic_vector(15 downto 0);
  constant C_EXP : t_wordvec(0 to 10) := (
    x"4489", x"4489", x"552A", x"AAA9", x"5551", x"2AA4",
    x"AAAA", x"AAAA", x"AAAA", x"AAAA", x"AAAA" );
  constant C_EXP_DROP : t_wordvec(0 to 10) := (
    x"4489", x"4489", x"552A", x"AAA1", x"5551", x"2AA4",
    x"AAAA", x"AAAA", x"AAAA", x"AAAA", x"AAAA" );

  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal f_rdata  : std_logic := '1';
  signal enable   : std_logic := '0';
  signal selected : std_logic := '0';
  signal motor    : std_logic := '0';
  signal rd_data  : std_logic_vector(15 downto 0);
  signal rd_empty : std_logic;
  signal dpll_dis : std_logic;

  -- collector
  type t_col is array (0 to 63) of std_logic_vector(15 downto 0);
  signal col      : t_col := (others => (others => '0'));
  signal col_n    : natural := 0;
  signal col_rst  : std_logic := '0';

begin

  dpll_dis <= '1' when G_LEGACY else '0';
  clk <= not clk after C_CLK / 2;

  uut : entity work.physical_fdd_top
    port map (
      clk_i            => clk,
      rst_i            => rst,
      f_index_i        => '1',
      f_track0_i       => '1',
      f_writeprotect_i => '1',
      f_diskchanged_i  => '1',
      f_rdata_i        => f_rdata,
      enable_i         => enable,
      selected_i       => selected,
      motor_i          => motor,
      side_i           => '1',
      dsksync_i        => x"4489",
      dpll_dis_i       => dpll_dis,
      rd_clk_i         => clk,
      rd_rst_i         => rst,
      rd_en_i          => '1',
      rd_data_o        => rd_data,
      rd_empty_o       => rd_empty
    ); -- uut

  collector : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or col_rst = '1' then
        col_n <= 0;
      elsif rd_empty = '0' and col_n < col'length then
        col(col_n) <= rd_data;
        col_n      <= col_n + 1;
      end if;
    end if;
  end process collector;

  driver : process
    variable v_cyc  : integer;
    variable v_sync : integer;
    variable v_mism : natural;

    procedure edge is
    begin
      f_rdata <= '0';
      wait for 500 ns;
      f_rdata <= '1';
    end procedure;

    -- emit the stream; cell = cycles per cell; disp = extra cycles on the
    -- C_EV edge (0 = none); drop = true removes that edge entirely
    procedure emit (cell : in integer; disp : in integer; drop : in boolean) is
      variable v_gap : integer;
      variable i     : natural;
    begin
      edge;
      i := 0;
      while i < C_GAPS'length loop
        v_gap := C_GAPS(i) * cell;
        if i = C_EV then
          if drop then
            v_gap := (C_GAPS(i) + C_GAPS(i + 1)) * cell;  -- merged interval
          else
            v_gap := v_gap + disp;
          end if;
        elsif i = C_EV + 1 and not drop then
          v_gap := v_gap - disp;
        end if;
        wait for v_gap * C_CLK - 500 ns;
        if not (drop and i = C_EV) then
          null;
        end if;
        edge;
        if drop and i = C_EV then
          i := i + 2;                                     -- edge between was removed
        else
          i := i + 1;
        end if;
      end loop;
      wait for 100 us;                                    -- flush the tail
    end procedure;

    -- locate the first sync word in the collected stream
    impure function find_sync return integer is
    begin
      for k in 0 to col_n - 1 loop
        if col(k) = x"4489" then
          return k;
        end if;
      end loop;
      return -1;
    end function;

    procedure start_scenario is
    begin
      rst <= '1';
      col_rst <= '1';
      wait for 10 * C_CLK;
      rst <= '0';
      col_rst <= '0';
      wait for 10 * C_CLK;
      enable <= '1'; selected <= '1'; motor <= '1';
      wait for 2 us;
    end procedure;
  begin
    -- S1 clean: both modes bit-exact
    start_scenario;
    emit(100, 0, false);
    v_sync := find_sync;
    assert v_sync >= 0 report "S1 no sync decoded" severity failure;
    for k in C_EXP'range loop
      assert col(v_sync + k) = C_EXP(k)
        report "S1 word " & integer'image(k) & " got 0x"
               & to_hstring(col(v_sync + k)) severity failure;
    end loop;
    report "S1 PASS (clean stream bit-exact)";

    -- S2 displace +40 cycles: both modes bit-exact
    start_scenario;
    emit(100, 40, false);
    v_sync := find_sync;
    assert v_sync >= 0 report "S2 no sync decoded" severity failure;
    for k in C_EXP'range loop
      assert col(v_sync + k) = C_EXP(k)
        report "S2 word " & integer'image(k) & " got 0x"
               & to_hstring(col(v_sync + k)) severity failure;
    end loop;
    report "S2 PASS (+40-cycle displaced edge tolerated)";

    -- S3 dropout: legacy must corrupt the tail, the DPLL must not
    start_scenario;
    emit(100, 0, true);
    v_sync := find_sync;
    assert v_sync >= 0 report "S3 no sync decoded" severity failure;
    if G_LEGACY then
      -- legacy: the loss-of-lock resync must have shifted the tail - count
      -- mismatches strictly after the event word
      v_mism := 0;
      for k in 4 to C_EXP'high loop
        if col(v_sync + k) /= C_EXP(k) then
          v_mism := v_mism + 1;
        end if;
      end loop;
      assert v_mism >= 2
        report "S3 LEGACY expected the resync to corrupt the tail, but only "
               & integer'image(v_mism) & " words differ (did legacy get better?)"
        severity failure;
      report "S3 PASS (legacy control: the dropout resync corrupted "
             & integer'image(v_mism) & " downstream words)";
    else
      -- DPLL: exactly the event word differs, by exactly the removed bit
      for k in C_EXP_DROP'range loop
        assert col(v_sync + k) = C_EXP_DROP(k)
          report "S3 DPLL word " & integer'image(k) & " got 0x"
                 & to_hstring(col(v_sync + k)) & " expected 0x"
                 & to_hstring(C_EXP_DROP(k)) severity failure;
      end loop;
      report "S3 PASS (DPLL: dropout contained to one bit flip, "
             & "tail intact)";
    end if;

    -- S4 bias -3%: both modes track and decode bit-exact
    start_scenario;
    emit(97, 0, false);
    v_sync := find_sync;
    assert v_sync >= 0 report "S4 no sync decoded" severity failure;
    for k in C_EXP'range loop
      assert col(v_sync + k) = C_EXP(k)
        report "S4 word " & integer'image(k) & " got 0x"
               & to_hstring(col(v_sync + k)) severity failure;
    end loop;
    report "S4 PASS (-3% cell bias tracked)";

    if G_LEGACY then
      report "TB_FDD_DPLL (LEGACY MODE): ALL PASS";
    else
      report "TB_FDD_DPLL (DPLL MODE): ALL PASS";
    end if;
    std.env.stop;
  end process driver;

end architecture sim;
