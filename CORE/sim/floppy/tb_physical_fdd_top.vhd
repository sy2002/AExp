-------------------------------------------------------------------------------
-- tb_physical_fdd_top: closed-loop testbench for the Hardware Floppy read
-- front-end (physical_fdd_top).
--
-- Generates properly clocked MFM flux (clock bit = 1 iff both neighbouring
-- data bits are 0; unlike the simulated-ADF host stream, real disks carry
-- legal clocking) for three pseudo-sectors of pseudo-random data, each led
-- in by a 0x00-data preamble and the standard double 0x4489 sync, converts
-- the channel bits into timed RDATA edges (600 ns low pulses, pulse time
-- debt-compensated) and requires the front-end to reproduce the exact
-- word-aligned channel stream from the first sync onward, popped through
-- the real dual-clock FIFO at the real 28.375 MHz core clock. Words emitted
-- before the first sync are free-running (arbitrary phase, like real
-- hardware) and are skipped by the checker, exactly as Paula's WORDSYNC
-- gate would skip them.
--
-- Scenarios (all must pass):
--   S1 nominal speed (100 cycles/cell), no jitter
--   S2 +3% speed (97 cycles/cell)     - the adaptive quantiser must track
--   S3 -3% speed (103 cycles/cell) with +/-6 cycle per-edge jitter
--   S4 nominal with injected runt double-edges (200 ns spacing, below the
--      C_GAP_GLITCH filter) before every 97th edge
--   S5 flux drought mid-stream (drought filler words are ignored), then a
--      fresh sync train - the stream must re-lock on its sync
--
-- Every scenario also verifies the sector-header capture: after the stream
-- drains, the published capture must hold exactly the 8 words that follow
-- the last double-sync of the stream, the completed-capture counter must
-- have advanced by one per sector (3, or 6 in S5's two runs), and the flags
-- must reproduce the SIDE line driven for that scenario.
--
-- Run: CORE/sim/floppy/run_fdd_regression.sh (cells top_dpll, top_legacy);
-- a few seconds per separator mode.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use work.physical_fdd_pkg.all;

entity tb_physical_fdd_top is
  generic (
    -- false = DPLL data separator (the default), true = legacy quantiser
    -- bit source; the five scenarios must pass in both modes
    -- (nvc -e tb_physical_fdd_top -gG_LEGACY=true for the legacy run)
    G_LEGACY : boolean := false
  );
end entity tb_physical_fdd_top;

architecture sim of tb_physical_fdd_top is

  function f_dpll_dis return std_logic is
  begin
    if G_LEGACY then
      return '1';
    end if;
    return '0';
  end function;
  signal tb_dpll_dis : std_logic := f_dpll_dis;

  constant C_CLK50_PER  : time := 20 ns;
  constant C_CLK28_PER  : time := 35.242 ns;   -- ~28.375 MHz

  signal clk50    : std_logic := '0';
  signal clk28    : std_logic := '0';
  signal rst      : std_logic := '1';

  signal f_rdata  : std_logic := '1';
  signal rd_en    : std_logic := '0';
  signal rd_data  : std_logic_vector(15 downto 0);
  signal rd_empty : std_logic;

  signal enable   : std_logic := '0';
  signal selected : std_logic := '0';
  signal motor    : std_logic := '0';
  signal side_tb  : std_logic := '1';

  signal diag_cnt_runt  : unsigned(15 downto 0);
  signal diag_cnt_drop  : unsigned(15 downto 0);
  signal diag_cap_flags : std_logic_vector(3 downto 0);
  signal diag_cap_count : unsigned(15 downto 0);
  signal diag_cap_words : t_fdd_cap_words;
  signal diag_fmt_bad   : unsigned(15 downto 0);

  -- channel bit stream model, published stim -> checker via signals
  constant C_MAX_BITS : natural := 8192;
  type t_bitvec is array (0 to C_MAX_BITS - 1) of std_logic;
  signal s_bits    : t_bitvec := (others => '0');
  signal s_nbits   : natural := 0;
  signal s_syncpos : integer := -1;              -- bit index where the first
                                                 -- sync word completes
  signal s_lastsync : integer := -1;             -- bit index where the last
                                                 -- double-sync completes
  type t_syncend is array (0 to 2) of integer;   -- per-sector double-sync
  signal s_syncend : t_syncend := (others => -1);-- completion positions
  signal stim_done : boolean := false;
  signal scenario  : natural := 0;

begin

  clk50 <= not clk50 after C_CLK50_PER / 2;
  clk28 <= not clk28 after C_CLK28_PER / 2;

  uut : entity work.physical_fdd_top
    port map (
      clk_i               => clk50,
      rst_i               => rst,
      f_index_i           => '1',
      f_track0_i          => '1',
      f_writeprotect_i    => '1',
      f_diskchanged_i     => '1',
      f_rdata_i           => f_rdata,
      enable_i            => enable,
      selected_i          => selected,
      motor_i             => motor,
      side_i              => side_tb,
      dsksync_i           => x"4489",
      dpll_dis_i          => tb_dpll_dis,
      track0_n_o          => open,
      wprot_n_o           => open,
      change_n_o          => open,
      ready_n_o           => open,
      index_o             => open,
      present_o           => open,
      rd_clk_i            => clk28,
      rd_rst_i            => rst,
      rd_en_i             => rd_en,
      rd_data_o           => rd_data,
      rd_empty_o          => rd_empty,
      diag_status_o       => open,
      diag_sync_o         => open,
      diag_est_o          => open,
      diag_fifo_level_o   => open,
      diag_index_period_o => open,
      diag_index_width_o  => open,
      diag_cnt_index_o    => open,
      diag_cnt_sync_o     => open,
      diag_cnt_word_o     => open,
      diag_cnt_runt_o     => diag_cnt_runt,
      diag_cnt_lol_o      => open,
      diag_cnt_drop_o     => diag_cnt_drop,
      diag_cap_flags_o    => diag_cap_flags,
      diag_cap_count_o    => diag_cap_count,
      diag_cap_words_o    => diag_cap_words,
      diag_rev_mask_o     => open,           -- no index pulses in this TB
      diag_rev_caps_o     => open,
      diag_rev_lol_o      => open,
      diag_fmt_bad_o      => diag_fmt_bad
    );

  -----------------------------------------------------------------------------
  -- stimulus: build the channel stream, then drive flux edges
  -----------------------------------------------------------------------------
  stim : process
    variable seed1, seed2 : positive := 42;

    variable v_bits     : t_bitvec;
    variable v_nbits    : natural;
    variable v_syncpos  : integer;
    variable v_lastsync : integer;
    variable v_syncend  : t_syncend;

    procedure put_bit(b : std_logic) is
    begin
      v_bits(v_nbits) := b;
      v_nbits := v_nbits + 1;
    end procedure;

    -- one data byte with proper MFM clocking (clock 1 between two 0 data bits)
    procedure put_data_byte(byte   : std_logic_vector(7 downto 0);
                            prev_d : inout std_logic) is
    begin
      for i in 7 downto 0 loop
        if prev_d = '0' and byte(i) = '0' then
          put_bit('1');
        else
          put_bit('0');
        end if;
        put_bit(byte(i));
        prev_d := byte(i);
      end loop;
    end procedure;

    -- literal 16-bit channel word (the missing-clock syncs)
    procedure put_raw_word(w      : std_logic_vector(15 downto 0);
                           prev_d : inout std_logic) is
    begin
      for i in 15 downto 0 loop
        put_bit(w(i));
      end loop;
      prev_d := w(0);
    end procedure;

    -- 3 sectors: preamble (4 x data 0x00) + 2x sync + 64 random data bytes
    procedure build_stream is
      variable prev_d : std_logic := '0';
      variable b      : std_logic_vector(7 downto 0);
      variable r      : real;
    begin
      v_nbits     := 0;
      v_syncpos   := -1;
      v_lastsync  := -1;
      for sector in 0 to 2 loop
        for k in 0 to 3 loop
          put_data_byte(x"00", prev_d);
        end loop;
        if v_syncpos < 0 then
          v_syncpos := v_nbits + 16;
        end if;
        put_raw_word(x"4489", prev_d);
        put_raw_word(x"4489", prev_d);
        v_lastsync         := v_nbits;           -- second sync just completed
        v_syncend(sector)  := v_nbits;
        for k in 0 to 63 loop
          uniform(seed1, seed2, r);
          b := std_logic_vector(to_unsigned(integer(trunc(r * 255.0)), 8));
          put_data_byte(b, prev_d);
        end loop;
      end loop;
      s_bits     <= v_bits;
      s_nbits    <= v_nbits;
      s_syncpos  <= v_syncpos;
      s_lastsync <= v_lastsync;
      s_syncend  <= v_syncend;
    end procedure;

    -- drive the stream; cell = cycles per channel bit; jit = +/- jitter
    -- cycles per edge; runts injects a 200 ns double edge before every 97th
    -- edge. The low-pulse and runt times are debt-compensated so the cell
    -- grid stays exact.
    procedure drive_stream(cell : natural; jit : natural; runts : boolean) is
      variable t_cells : natural := 0;
      variable debt    : natural := 0;           -- cycles already spent low/high
      variable vwait   : integer;
      variable j       : integer;
      variable r       : real;
      variable ecount  : natural := 0;
    begin
      for i in 0 to v_nbits - 1 loop
        if v_bits(i) = '1' then
          j := 0;
          if jit > 0 then
            uniform(seed1, seed2, r);
            j := integer(trunc(r * real(2 * jit + 1))) - jit;
          end if;
          vwait := t_cells * cell + j - debt;
          if vwait < 1 then
            vwait := 1;
          end if;
          wait for vwait * C_CLK50_PER;
          debt    := 0;
          t_cells := 0;
          ecount  := ecount + 1;
          if runts and (ecount mod 97 = 0) then
            f_rdata <= '0';                      -- runt double edge, 200 ns
            wait for 100 ns;
            f_rdata <= '1';
            wait for 100 ns;
            debt := debt + 10;
          end if;
          f_rdata <= '0';                        -- flux pulse, 600 ns low
          wait for 600 ns;
          f_rdata <= '1';
          debt := debt + 30;
        end if;
        t_cells := t_cells + 1;
      end loop;
      wait for 200 * C_CLK50_PER;
    end procedure;

  begin
    wait for 200 ns;
    rst <= '0';
    wait for 200 ns;

    for sc in 1 to 5 loop
      -- deselect: clean chain reset + fresh sync hunt for each scenario
      enable <= '0'; selected <= '0'; motor <= '0';
      wait for 5 us;
      build_stream;
      -- alternate the SIDE line per scenario; the capture must latch it
      if (sc mod 2) = 1 then
        side_tb <= '1';
      else
        side_tb <= '0';
      end if;
      wait for 1 us;
      scenario  <= sc;
      stim_done <= false;
      enable <= '1'; selected <= '1'; motor <= '1';
      wait for 2 us;

      case sc is
        when 1      => drive_stream(100, 0, false);
        when 2      => drive_stream(97,  0, false);
        when 3      => drive_stream(103, 6, false);
        when 4      => drive_stream(100, 0, true);
        when others =>
          drive_stream(100, 0, false);
          f_rdata <= '1';
          wait for 200 us;                       -- drought >> arm threshold
          drive_stream(100, 0, false);
      end case;

      if sc = 4 then
        assert diag_cnt_runt /= 0
          report "S4: runt filter never fired" severity failure;
      end if;

      stim_done <= true;
      wait for 30 us;                            -- checker drains + reports
    end loop;

    assert diag_cnt_drop = 0
      report "FIFO overflowed during the run" severity failure;
    report "ALL SCENARIOS DRIVEN";
    wait for 10 us;
    stop;
  end process stim;

  -----------------------------------------------------------------------------
  -- checker: pop words at the core clock and compare against the model
  -----------------------------------------------------------------------------
  check : process
    variable exp_word : std_logic_vector(15 downto 0);
    variable bitpos   : integer;
    variable words_ok : natural;
    variable cur_sc   : natural;
    variable resynced : boolean;
    variable cap_tot  : natural := 0;            -- expected cumulative captures
    variable fmt_tot  : natural := 0;            -- expected cumulative bad-format captures
    variable w0b, w2b : std_logic_vector(7 downto 0);
    variable fmtv     : std_logic_vector(7 downto 0);

    procedure expected_at(p : in integer; w : out std_logic_vector(15 downto 0)) is
    begin
      for i in 0 to 15 loop
        w(15 - i) := s_bits(p - 16 + i);
      end loop;
    end procedure;

  begin
    wait until rst = '0';

    for sc in 1 to 5 loop
      wait until scenario = sc;
      cur_sc   := sc;
      words_ok := 0;
      resynced := false;
      bitpos   := -1;

      while not (stim_done and rd_empty = '1') loop
        wait until rising_edge(clk28);
        if rd_empty = '0' then
          if bitpos < 0 then
            -- pre-sync words are free-running: skip until the sync word
            if rd_data = x"4489" then
              bitpos   := s_syncpos;
              words_ok := 1;
            end if;
          else
            bitpos := bitpos + 16;
            if bitpos <= s_nbits then
              expected_at(bitpos, exp_word);
              if rd_data = exp_word then
                words_ok := words_ok + 1;
              else
                report "S" & integer'image(cur_sc) & ": word mismatch at bit "
                       & integer'image(bitpos) & " got " & to_hstring(rd_data)
                       & " want " & to_hstring(exp_word)
                  severity failure;
              end if;
            else
              -- beyond the model: only S5 gets here meaningfully (drought
              -- filler words, then the second train). Re-anchor on its sync;
              -- ignore the filler.
              if cur_sc = 5 and rd_data = x"4489" and not resynced then
                bitpos   := s_syncpos;
                resynced := true;
                words_ok := words_ok + 1;
              end if;
            end if;
          end if;
          rd_en <= '1';
          wait until rising_edge(clk28);
          rd_en <= '0';
        end if;
      end loop;

      assert words_ok >= 100
        report "S" & integer'image(cur_sc) & ": only "
               & integer'image(words_ok) & " words matched"
        severity failure;
      if cur_sc = 5 then
        assert resynced
          report "S5: never re-locked after the drought" severity failure;
      end if;

      -- sector-header capture: one completed capture per sector (S5 streams
      -- twice), holding the 8 words after the last double-sync, with the
      -- scenario's SIDE line and the (deasserted) /TRK0 in the flags
      if cur_sc = 5 then
        cap_tot := cap_tot + 6;
      else
        cap_tot := cap_tot + 3;
      end if;
      assert diag_cap_flags(0) = '1'
        report "S" & integer'image(cur_sc) & ": capture not valid"
        severity failure;
      assert diag_cap_flags(1) = side_tb and diag_cap_flags(3) = side_tb
        report "S" & integer'image(cur_sc) & ": capture SIDE flags wrong"
        severity failure;
      assert diag_cap_flags(2) = '1'
        report "S" & integer'image(cur_sc) & ": capture /TRK0 flag wrong"
        severity failure;
      assert diag_cap_count = cap_tot
        report "S" & integer'image(cur_sc) & ": capture count "
               & integer'image(to_integer(diag_cap_count)) & " expected "
               & integer'image(cap_tot)
        severity failure;
      for k in 0 to C_CAP_WORDS - 1 loop
        expected_at(s_lastsync + 16 * (k + 1), exp_word);
        assert diag_cap_words(k) = exp_word
          report "S" & integer'image(cur_sc) & ": capture word "
                 & integer'image(k) & " got "
                 & to_hstring(diag_cap_words(k)) & " want "
                 & to_hstring(exp_word)
          severity failure;
      end loop;

      -- bad-format counter: every publish decodes the info format byte from
      -- capture words 0/2; the TB's random payload is almost never 0xFF, so
      -- the counter must advance by exactly the model's prediction
      for k in 0 to 2 loop
        expected_at(s_syncend(k) + 16, exp_word);
        w0b := exp_word(15 downto 8);
        expected_at(s_syncend(k) + 48, exp_word);
        w2b := exp_word(15 downto 8);
        fmtv := ((w0b(6 downto 0) & '0') and x"AA") or (w2b and x"55");
        if fmtv /= x"FF" then
          if cur_sc = 5 then
            fmt_tot := fmt_tot + 2;              -- S5 streams the model twice
          else
            fmt_tot := fmt_tot + 1;
          end if;
        end if;
      end loop;
      assert diag_fmt_bad = fmt_tot
        report "S" & integer'image(cur_sc) & ": bad-format count "
               & integer'image(to_integer(diag_fmt_bad)) & " expected "
               & integer'image(fmt_tot)
        severity failure;

      report "S" & integer'image(cur_sc) & " PASS ("
             & integer'image(words_ok) & " words verified, capture OK)";
    end loop;

    report "CHECKER DONE - ALL PASS";
    wait;
  end process check;

end architecture sim;
