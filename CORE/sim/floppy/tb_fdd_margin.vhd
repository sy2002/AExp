-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- tb_fdd_margin: directed testbench for the margin instrumentation in
-- physical_fdd_top (margin_proc and the cap_proc miss profile), read through
-- the diagnostics device registers. The stimulus and every expected register
-- value come from CORE/sim/floppy/gen_tb_fdd_margin.py, which contains an
-- independent integer model of the quantiser and the margin engine: the VHDL
-- and the model must agree bit-exactly on the deterministic checks
-- (histograms, min-margin context, counts), and exact aligner walking bounds
-- the window check.
--
-- Phases: A gating-off, B nominal short gaps, C medium bias, D boundary +
-- reject, checkpoint/clear, E armed-sector window over a synthetic
-- revolution of 8 real MFM header blocks (sector 3/9/10 absent), F index
-- pulse -> per-sector miss profile, G step/cylinder tracking, H uptime.
--
-- The constants between C_A_END and the end of C_GAPS are generated:
-- python3 CORE/sim/floppy/gen_tb_fdd_margin.py prints them.
--
-- Run: CORE/sim/floppy/run_fdd_regression.sh (cell margin); a few seconds.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity tb_fdd_margin is
end entity tb_fdd_margin;

architecture sim of tb_fdd_margin is

  type t_gapvec is array (natural range <>) of natural;
  type t_int24 is array (0 to 23) of natural;
  constant C_A_END : natural := 20;
  constant C_D_END : natural := 90;
  constant C_E_START : natural := 90;
  constant C_N_GAPS : natural := 1429;
  -- checkpoint 1 expectations
  constant C_CK1_GAPCNT : natural := 69;
  constant C_CK1_LOL    : natural := 1;
  constant C_CK1_MM     : natural := 144;
  constant C_CK1_MEST   : natural := 1600;
  constant C_CK1_MGAP   : natural := 259;
  constant C_CK1_MCLS   : natural := 1;
  constant C_CK1_ESTMIN : natural := 1592;
  constant C_CK1_ESTMAX : natural := 1600;
  constant C_CK1_HIST : t_int24 := (0, 0, 0, 0, 64, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  -- checkpoint 2 gated-gap bounds
  constant C_CK2_LO : natural := 81;
  constant C_CK2_HI : natural := 87;

  constant C_GAPS : t_gapvec := (
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,310,310,310,310,260,480,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,300,400,300,400,300,200,400,300,
    400,300,200,200,200,200,300,200,200,200,200,200,200,200,200,200,200,300,
    200,200,200,200,200,400,300,200,200,200,200,200,300,300,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,300,400,
    300,400,300,200,400,300,400,300,200,200,200,200,300,200,200,200,200,200,
    200,200,200,200,200,300,200,200,200,200,200,400,300,200,300,300,200,300,
    300,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,300,400,300,400,300,200,400,300,400,300,200,200,200,200,300,
    200,200,200,200,200,300,300,200,200,300,200,200,200,200,200,400,300,200,
    200,200,200,200,300,300,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,300,400,300,400,300,200,400,300,400,300,
    200,200,200,200,300,200,200,200,200,200,200,200,200,200,200,300,200,200,
    200,200,200,400,300,300,300,200,200,300,300,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,300,400,300,400,300,
    200,400,300,400,300,200,200,200,200,300,200,200,200,200,200,200,200,200,
    200,200,300,200,200,200,200,200,400,300,300,200,300,200,300,300,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    300,400,300,400,300,200,400,300,400,300,200,200,200,200,300,200,200,200,
    200,200,300,300,200,200,300,200,200,200,200,200,400,300,300,300,200,200,
    300,300,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,300,400,300,400,300,200,400,300,400,300,200,200,200,200,
    300,200,200,200,200,200,300,300,200,200,300,200,200,200,200,200,400,300,
    300,200,300,200,300,300,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,300,400,300,400,300,200,400,300,400,300,
    200,200,200,200,300,200,200,200,200,300,300,200,200,200,300,200,200,200,
    200,200,400,300,200,200,200,200,200,300,300,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,
    200,200,200,200,200,200,200
  );
  constant C_CLK : time := 20 ns;

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal f_index    : std_logic := '1';
  signal f_track0   : std_logic := '1';
  signal f_wprot    : std_logic := '1';
  signal f_chg      : std_logic := '1';
  signal f_rdata    : std_logic := '1';
  signal enable     : std_logic := '0';
  signal selected   : std_logic := '0';
  signal motor      : std_logic := '0';
  signal side       : std_logic := '1';
  signal dsksync    : std_logic_vector(15 downto 0) := x"4489";
  signal step_n     : std_logic := '1';
  signal stepdir    : std_logic := '1';
  signal serving    : std_logic := '0';
  signal ctrl       : std_logic_vector(5 downto 0) := (others => '0');
  signal clr        : std_logic := '0';
  signal rd_data    : std_logic_vector(15 downto 0);
  signal rd_empty   : std_logic;

  signal d_uptime   : unsigned(31 downto 0);
  signal d_cnt_step : unsigned(15 downto 0);
  signal d_cyl      : unsigned(6 downto 0);
  signal d_mm       : unsigned(15 downto 0);
  signal d_mest     : unsigned(11 downto 0);
  signal d_mgap     : unsigned(15 downto 0);
  signal d_mstat    : std_logic_vector(15 downto 0);
  signal d_wopen    : unsigned(15 downto 0);
  signal d_gapcnt   : unsigned(15 downto 0);
  signal d_lolg     : unsigned(15 downto 0);
  signal d_syncg    : unsigned(15 downto 0);
  signal d_estmin   : unsigned(11 downto 0);
  signal d_estmax   : unsigned(11 downto 0);
  signal d_hist     : t_fdd_hist;
  signal d_miss     : t_fdd_miss;
  signal d_qual     : unsigned(15 downto 0);
  signal d_capcnt   : unsigned(15 downto 0);
  signal d_revmask  : std_logic_vector(10 downto 0);

begin

  clk <= not clk after C_CLK / 2;

  uut : entity work.physical_fdd_top
    port map (
      clk_i             => clk,
      rst_i             => rst,
      f_index_i         => f_index,
      f_track0_i        => f_track0,
      f_writeprotect_i  => f_wprot,
      f_diskchanged_i   => f_chg,
      f_rdata_i         => f_rdata,
      enable_i          => enable,
      selected_i        => selected,
      motor_i           => motor,
      side_i            => side,
      dsksync_i         => dsksync,
      step_n_i          => step_n,
      stepdir_i         => stepdir,
      serving_i         => serving,
      ctrl_i            => ctrl,
      clear_i           => clr,
      rd_clk_i          => clk,
      rd_rst_i          => rst,
      rd_en_i           => '1',
      rd_data_o         => rd_data,
      rd_empty_o        => rd_empty,
      diag_uptime_o     => d_uptime,
      diag_cnt_step_o   => d_cnt_step,
      diag_cyl_o        => d_cyl,
      diag_min_margin_o => d_mm,
      diag_min_est_o    => d_mest,
      diag_min_gap_o    => d_mgap,
      diag_margin_stat_o => d_mstat,
      diag_win_opens_o  => d_wopen,
      diag_gap_count_o  => d_gapcnt,
      diag_lol_gate_o   => d_lolg,
      diag_sync_gate_o  => d_syncg,
      diag_est_min_o    => d_estmin,
      diag_est_max_o    => d_estmax,
      diag_hist_o       => d_hist,
      diag_miss_o       => d_miss,
      diag_qual_revs_o  => d_qual,
      diag_cap_count_o  => d_capcnt,
      diag_rev_mask_o   => d_revmask
    ); -- uut

  driver : process
    procedure edge is
    begin
      f_rdata <= '0';
      wait for 500 ns;
      f_rdata <= '1';
    end procedure;
  begin
    wait for 200 ns;
    rst <= '0';
    wait for 200 ns;
    enable <= '1'; selected <= '1'; motor <= '1';
    wait for 1 us;

    -- open a well-defined index-to-index window with the chain active:
    -- the miss-profile qualifier requires the decode chain to run for the
    -- whole window (a deselect hole would be a phantom-miss window and is
    -- excluded), so the window covering the synthetic revolution must start
    -- at an index edge taken after the chain came up
    f_index <= '0';
    wait for 300 us;
    f_index <= '1';
    wait for 10 us;

    edge;                                    -- starts the first gap
    for i in 0 to C_N_GAPS - 1 loop
      if i = C_A_END then
        serving <= '1';                      -- zero-time flip: phase B on
      end if;
      if i = C_E_START then
        -- checkpoint 1: settle, verify phases A-D, then clear + window mode
        wait for 10 us;
        assert d_gapcnt = C_CK1_GAPCNT
          report "CK1 gap_cnt " & integer'image(to_integer(d_gapcnt))
          severity failure;
        assert d_lolg = C_CK1_LOL
          report "CK1 lol_gate" severity failure;
        assert d_mm = C_CK1_MM
          report "CK1 min_margin " & integer'image(to_integer(d_mm))
          severity failure;
        assert d_mest = C_CK1_MEST report "CK1 min_est" severity failure;
        assert d_mgap = C_CK1_MGAP report "CK1 min_gap" severity failure;
        assert to_integer(unsigned(d_mstat(1 downto 0))) = C_CK1_MCLS
          report "CK1 min class" severity failure;
        for k in 0 to 23 loop
          assert to_integer(d_hist(k)) = C_CK1_HIST(k)
            report "CK1 hist bin " & integer'image(k) & " = "
                   & integer'image(to_integer(d_hist(k)))
            severity failure;
        end loop;
        assert d_estmin = C_CK1_ESTMIN and d_estmax = C_CK1_ESTMAX
          report "CK1 est excursion" severity failure;
        report "CK1 PASS (gating, bins, min-margin context, est excursion)";
        -- clear + arm the sector-4 window (ctrl = win mode, K=3.. armed
        -- sector K means window opens at K-1's publish; we arm K=3 so it
        -- opens at sector 2's publish and closes at sector 4's sync,
        -- sector 3 being absent - a deterministic one-sector miss)
        clr <= '1';
        wait for C_CLK;
        clr <= '0';
        wait for 5 * C_CLK;
        assert d_gapcnt = 0 and d_lolg = 0 and d_mm = x"FFFF"
               and to_integer(d_hist(4)) = 0 and d_wopen = 0
          report "clear did not zero the statistics" severity failure;
        report "CLEAR PASS";
        ctrl <= "010011";                    -- window mode, K=3
        wait for 2 us;
      end if;
      wait for C_GAPS(i) * C_CLK - 500 ns;
      edge;
    end loop;

    -- checkpoint 2: the armed-sector window over the synthetic revolution
    wait for 20 us;
    assert d_wopen = 1
      report "CK2 win_opens " & integer'image(to_integer(d_wopen))
      severity failure;
    assert d_syncg = 1
      report "CK2 sync_gate " & integer'image(to_integer(d_syncg))
      severity failure;
    assert d_lolg = 0 report "CK2 lol_gate" severity failure;
    assert to_integer(d_gapcnt) >= C_CK2_LO and
           to_integer(d_gapcnt) <= C_CK2_HI
      report "CK2 gated gaps " & integer'image(to_integer(d_gapcnt))
      severity failure;
    assert d_capcnt = 8 report "CK2 capture count" severity failure;
    report "CK2 PASS (window opened at s2 publish, closed at s4 sync, "
           & integer'image(to_integer(d_gapcnt)) & " gaps gated)";

    -- checkpoint 3: index pulse latches the revolution -> miss profile
    f_index <= '0';
    wait for 300 us;
    f_index <= '1';
    wait for 10 us;
    assert d_revmask = "00111110111"
      report "CK3 rev mask" severity failure;
    assert d_qual = 1 report "CK3 qual_revs" severity failure;
    assert unsigned(d_miss(1)(15 downto 8)) = 1     -- sector 3
      report "CK3 miss s3" severity failure;
    assert unsigned(d_miss(4)(15 downto 8)) = 1     -- sector 9
      report "CK3 miss s9" severity failure;
    assert unsigned(d_miss(5)(7 downto 0)) = 1      -- sector 10
      report "CK3 miss s10" severity failure;
    assert unsigned(d_miss(0)) = 0 and unsigned(d_miss(2)) = 0 and
           unsigned(d_miss(3)) = 0 and
           unsigned(d_miss(1)(7 downto 0)) = 0 and
           unsigned(d_miss(4)(7 downto 0)) = 0 and
           unsigned(d_miss(5)(15 downto 8)) = 0
      report "CK3 spurious miss" severity failure;
    report "CK3 PASS (miss profile: exactly sectors 3/9/10, 1 qualified rev)";

    -- checkpoint 4: step / cylinder tracking
    stepdir <= '0';                          -- away from track 0
    for k in 1 to 5 loop
      step_n <= '0'; wait for 2 us; step_n <= '1'; wait for 8 us;
    end loop;
    assert d_cyl = 5 report "CK4 cyl after 5 in" severity failure;
    stepdir <= '1';                          -- toward track 0
    for k in 1 to 2 loop
      step_n <= '0'; wait for 2 us; step_n <= '1'; wait for 8 us;
    end loop;
    assert d_cyl = 3 report "CK4 cyl after 2 out" severity failure;
    assert d_cnt_step = 7 report "CK4 step count" severity failure;
    f_track0 <= '0';
    wait for 2 us;
    assert d_cyl = 0 report "CK4 track0 ground truth" severity failure;
    f_track0 <= '1';
    report "CK4 PASS (7 steps, cylinder integral, /TRK0 reset)";

    -- checkpoint 5: uptime moved and is plausible for the elapsed sim time
    assert to_integer(d_uptime) >= 4 and to_integer(d_uptime) <= 30
      report "CK5 uptime " & integer'image(to_integer(d_uptime))
      severity failure;
    report "CK5 PASS (uptime " & integer'image(to_integer(d_uptime))
           & " ms)";

    report "TB_FDD_MARGIN: ALL PASS";
    std.env.stop;
  end process driver;

end architecture sim;
