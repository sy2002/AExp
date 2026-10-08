-------------------------------------------------------------------------------
-- tb_hwf_obs_tap: closed-loop test of the DSKBYTR observation tap
-- (main.vhd p_hwf_obs) against the real physical_fdd_wfifo and the real
-- engine ST_IDLE drain pattern.
--
-- What it guards: the engine's ST_IDLE drain re-asserts the registered
-- phys_rd_en_o for one extra cycle when it drains the last word - the
-- FIFO's empty flag asserts a cycle late, so the engine sees empty=0 and
-- schedules another pop. The FIFO correctly ignores that pop (r_do_read =
-- rd_en and not empty), but a tap that keyed only on phys_rd_en_o would fire
-- a phantom obs_stb carrying the stale first-word-fall-through head (a
-- lap-old word), which Paula's newest-wins receiver would publish over the
-- real word and so disturb the Copylock timing measurement.
--
-- The bench feeds the FIFO at flux pace, drives the read side with the exact
-- engine ST_IDLE logic (registered phys_rd_en_o set whenever rd_empty=0),
-- taps it both ways, and asserts:
--   * guarded tap (rd_en and not rd_empty, as in main.vhd): the obs stream
--     equals the written words 1,2,3,... in order, exactly - no stale, no
--     duplicate.
--   * unguarded tap (rd_en only): produces phantom/stale publishes - the
--     control that proves the bench can see a tap without the guard.
--
-- Run: CORE/sim/floppy/run_fdd_regression.sh (cell obs_tap); a few seconds.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_hwf_obs_tap is
end entity tb_hwf_obs_tap;

architecture sim of tb_hwf_obs_tap is
  constant C_AW    : natural := 5;                 -- depth 32, as instantiated
  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';

  signal wr_en     : std_logic := '0';
  signal wr_data   : std_logic_vector(15 downto 0) := (others => '0');
  signal wr_full   : std_logic;
  signal rd_en     : std_logic := '0';            -- the engine's phys_rd_en_o
  signal rd_data   : std_logic_vector(15 downto 0);
  signal rd_empty  : std_logic;

  -- the two taps
  signal obs_word_fix : std_logic_vector(15 downto 0) := (others => '0');
  signal obs_stb_fix  : std_logic := '0';
  signal obs_word_bad : std_logic_vector(15 downto 0) := (others => '0');
  signal obs_stb_bad  : std_logic := '0';

  constant C_NWORDS : natural := 80;              -- > 2 FIFO laps, flux-paced
  signal done       : boolean := false;

  -- captured obs streams
  type t_cap is array (0 to 4*C_NWORDS) of integer;
  signal cap_fix : t_cap := (others => -1);
  signal cap_bad : t_cap := (others => -1);
  signal nfix : natural := 0;
  signal nbad : natural := 0;
begin

  clk <= not clk after 5 ns when not done else '0';

  -- DUT: the real dual-clock word FIFO (both clocks tied - the Gray CDC still
  -- works, just adds sync latency; the empty-flag timing under test is intact)
  i_fifo : entity work.physical_fdd_wfifo
    generic map ( G_AW => C_AW )
    port map (
      wr_clk_i   => clk,
      wr_rst_i   => rst,
      wr_en_i    => wr_en,
      wr_data_i  => wr_data,
      wr_full_o  => wr_full,
      wr_level_o => open,
      rd_clk_i   => clk,
      rd_rst_i   => rst,
      rd_en_i    => rd_en,
      rd_data_o  => rd_data,
      rd_empty_o => rd_empty
    );

  -- the engine's ST_IDLE drain, verbatim: registered rd_en, set whenever the
  -- FIFO reads non-empty (adf_track_engine.vhd, state ST_IDLE)
  p_engine_idle : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        rd_en <= '0';
      else
        rd_en <= '0';
        if rd_empty = '0' then
          rd_en <= '1';
        end if;
      end if;
    end if;
  end process p_engine_idle;

  -- the guarded tap, as in main.vhd p_hwf_obs
  p_tap_fix : process (clk)
  begin
    if rising_edge(clk) then
      obs_stb_fix <= '0';
      if rd_en = '1' and rd_empty = '0' then
        obs_word_fix <= rd_data;
        obs_stb_fix  <= '1';
      end if;
    end if;
  end process p_tap_fix;

  -- the unguarded tap (rd_en only) - proves the phantom exists
  p_tap_bad : process (clk)
  begin
    if rising_edge(clk) then
      obs_stb_bad <= '0';
      if rd_en = '1' then
        obs_word_bad <= rd_data;
        obs_stb_bad  <= '1';
      end if;
    end if;
  end process p_tap_bad;

  -- capture both obs streams
  p_cap : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '0' then
        if obs_stb_fix = '1' then
          cap_fix(nfix) <= to_integer(unsigned(obs_word_fix)); nfix <= nfix + 1;
        end if;
        if obs_stb_bad = '1' then
          cap_bad(nbad) <= to_integer(unsigned(obs_word_bad)); nbad <= nbad + 1;
        end if;
      end if;
    end if;
  end process p_cap;

  -- writer: feed words 1..C_NWORDS at flux pace (~one every 64 clks, so the
  -- FIFO stays near-empty and the drain-burst-then-empty pattern recurs)
  p_writer : process
  begin
    wr_en <= '0';
    wait for 200 ns;
    rst <= '0';
    wait until rising_edge(clk);
    for i in 1 to C_NWORDS loop
      if wr_full = '0' then
        wr_data <= std_logic_vector(to_unsigned(i, 16));
        wr_en   <= '1';
        wait until rising_edge(clk);
        wr_en   <= '0';
      end if;
      for k in 1 to 64 loop wait until rising_edge(clk); end loop;
    end loop;
    -- let the last words drain
    for k in 1 to 400 loop wait until rising_edge(clk); end loop;
    done <= true;
    wait;
  end process p_writer;

  -- checker
  p_check : process
    variable errors : natural := 0;
  begin
    wait until done;
    wait for 1 ns;
    -- guarded tap: exactly C_NWORDS obs words, equal to 1..C_NWORDS in order
    assert nfix = C_NWORDS
      report "guarded tap published " & integer'image(nfix) & " words, expected "
             & integer'image(C_NWORDS) severity error;
    if nfix /= C_NWORDS then errors := errors + 1; end if;
    for i in 0 to nfix - 1 loop
      if cap_fix(i) /= i + 1 then
        report "guarded tap word " & integer'image(i) & " = " & integer'image(cap_fix(i))
             & " expected " & integer'image(i+1) & " (stale/dup/phantom!)" severity error;
        errors := errors + 1;
      end if;
    end loop;
    if errors = 0 then
      report "guarded tap: obs stream = the fed words 1.." & integer'image(C_NWORDS)
           & " exactly (no phantom, no stale, no dup)" severity note;
    end if;
    -- unguarded tap: must show the phantom (more publishes than words, or a
    -- stale/dup) - the failure the guard removes
    assert nbad > C_NWORDS
      report "unguarded tap did not reproduce the phantom (nbad=" & integer'image(nbad)
           & ") - the control is broken" severity error;
    if nbad > C_NWORDS then
      report "unguarded tap published " & integer'image(nbad) & " > "
           & integer'image(C_NWORDS) & " (phantom stale publishes present) - "
           & "the guard is required" severity note;
    else
      errors := errors + 1;
    end if;

    if errors = 0 then
      report "TB_HWF_OBS_TAP: ALL PASS" severity note;
    else
      report "TB_HWF_OBS_TAP: " & integer'image(errors) & " FAILURE(S)" severity error;
    end if;
    stop;
  end process p_check;

end architecture sim;
