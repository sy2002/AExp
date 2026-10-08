-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- tb_fdd_diag_ro: testbench for the registered readout of physical_fdd_diag
-- (QNICE device 0x0104). The addressed word latches on the falling clock
-- edge and the CPU consumes it at the rising edge that ends the bus cycle:
-- zero-wait timing identical to the Kickstart ROM device.
--
-- The bus model mirrors the QNICE CPU: the address is presented at a
-- rising edge (the state before the fetch registers it), the DUT latches
-- at the mid-cycle falling edge, and the "CPU" samples the data at the
-- next rising edge. The tests:
--   T1  fully pipelined sweep of all 128 addresses back-to-back (the
--       address changes every cycle) - each sampled word must match the
--       address presented one cycle earlier. Real QNICE MMIO is never
--       this fast, so anything slower passes a fortiori. Expectations
--       are an independent literal table derived from the register-map
--       header, not from the entity's own expressions - a packing bug
--       in the mux (wrong slice, swapped fields) fails here.
--   T2  address folding: addr[6:0] decode means 0x80 aliases register
--       0x00 and unmapped registers read 0xEEEE. The mapped range reaches
--       0x7D (the write instruments), so 0x7E/0x7F are the remaining
--       fillers.
--   T3  latch-instant proof: a tap changed shortly after the falling
--       edge must not reach the sampled word (no combinational
--       leak-through = the output really is registered); the very next
--       cycle must deliver the new value. A tap changed before the
--       falling edge must be picked up in the same cycle.
--   T4  slow cycles: the address held for several cycles keeps returning
--       the same correct word (a stalled CPU re-reading the bus).
--
-- The register map is described in doc/developers/hardware-floppy.md.
-- Run: CORE/sim/floppy/run_fdd_regression.sh (cell diag_ro); a few seconds.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity tb_fdd_diag_ro is
end entity tb_fdd_diag_ro;

architecture sim of tb_fdd_diag_ro is

  constant C_CLK : time := 20 ns;

  signal clk    : std_logic := '0';
  signal addr   : std_logic_vector(27 downto 0) := (others => '0');
  signal data   : std_logic_vector(15 downto 0);

  -- distinct tap values, one recognizable constant per port
  signal cap_count_live : unsigned(15 downto 0) := x"7777";

  function f_tap128 return std_logic_vector is
    variable v : std_logic_vector(127 downto 0);
  begin
    for i in 0 to 7 loop
      v(16 * i + 15 downto 16 * i) :=
        std_logic_vector(to_unsigned(16#2800# + i, 16));
    end loop;
    return v;
  end function;

  function f_hist return t_fdd_hist is
    variable v : t_fdd_hist;
  begin
    for i in v'range loop
      v(i) := to_unsigned(16#4000# + i, 16);
    end loop;
    return v;
  end function;

  function f_miss return t_fdd_miss is
    variable v : t_fdd_miss;
  begin
    for i in v'range loop
      v(i) := std_logic_vector(to_unsigned(16#5800# + i, 16));
    end loop;
    return v;
  end function;

  function f_caps return t_fdd_cap_words is
    variable v : t_fdd_cap_words;
  begin
    for i in v'range loop
      v(i) := std_logic_vector(to_unsigned(16#1300# + i, 16));
    end loop;
    return v;
  end function;

  function f_presync return t_fdd_cap_words is
    variable v : t_fdd_cap_words;
  begin
    for i in v'range loop
      v(i) := std_logic_vector(to_unsigned(16#6200# + i, 16));
    end loop;
    return v;
  end function;

  -- the independent expectation table: literals per the map header
  function expected (a : natural) return std_logic_vector is
  begin
    case a is
      when 16#00# => return x"FDD0";
      when 16#01# => return x"000D";              -- map version (0x70..0x7D = write block)
      when 16#02# => return x"0ABD";              -- status passthrough
      when 16#03# => return x"4489";              -- dsksync
      when 16#04# => return x"063A";              -- x0 & est
      when 16#05# => return x"002A";              -- fifo level 42 resized
      when 16#06# => return x"AB65";              -- period lo
      when 16#07# => return x"0098";              -- period hi
      when 16#08# => return x"F010";              -- width lo
      when 16#09# => return x"0001";              -- width hi
      when 16#0A# => return x"1111";
      when 16#0B# => return x"2222";
      when 16#0C# => return x"3333";
      when 16#0D# => return x"4444";
      when 16#0E# => return x"5555";
      when 16#0F# => return x"6666";
      when 16#10# => return x"0005";              -- x000 & 0 & map "101"
      when 16#11# => return x"001A";              -- 000 & sideinv 1 & flags 1010
      when 16#12# => return x"7777";              -- cap_count (live tap, T3)
      when 16#13# => return x"1300";
      when 16#14# => return x"1301";
      when 16#15# => return x"1302";
      when 16#16# => return x"1303";
      when 16#17# => return x"1304";
      when 16#18# => return x"1305";
      when 16#19# => return x"1306";
      when 16#1A# => return x"1307";
      when 16#1B# => return x"8888";              -- served
      when 16#1C# => return x"0555";              -- 00000 & "10101010101"
      when 16#1D# => return x"0B02";              -- caps & lol
      when 16#1E# => return x"9999";              -- fmt_bad
      when 16#1F# => return x"0001";              -- sideinv readback
      when 16#20# => return x"AAA1";
      when 16#21# => return x"012E";              -- 0000000 & done 1 & ses 2E
      when 16#22# => return x"AAA2";
      when 16#23# => return x"009C";              -- 0000000 & ws 0 & att 9C
      when 16#24# => return x"C640";
      when 16#25# => return x"C256";
      when 16#26# => return x"C641";
      when 16#27# => return x"C257";
      when 16#28# to 16#2F# =>
        return std_logic_vector(to_unsigned(16#2800# + a - 16#28#, 16));
      when 16#30# => return x"5678";              -- uptime lo
      when 16#31# => return x"1234";              -- uptime hi
      when 16#32# => return x"000D";              -- nonce
      when 16#33# => return x"00A0";              -- steps
      when 16#34# => return x"0028";              -- cylinder 40
      when 16#35# => return x"00D3";              -- ctrl "11010011"
      when 16#36# => return x"0090";              -- min margin
      when 16#37# => return x"0640";              -- min est
      when 16#38# => return x"0103";              -- min gap
      when 16#39# => return x"0009";              -- margin status
      when 16#3A# => return x"0001";
      when 16#3B# => return x"0045";
      when 16#3C# => return x"0002";
      when 16#3D# => return x"0003";
      when 16#3E# => return x"0638";              -- est min
      when 16#3F# => return x"0642";              -- est max
      when 16#40# to 16#57# =>
        return std_logic_vector(to_unsigned(16#4000# + a - 16#40#, 16));
      when 16#58# to 16#5D# =>
        return std_logic_vector(to_unsigned(16#5800# + a - 16#58#, 16));
      when 16#5E# => return x"0014";              -- qual revs
      when 16#5F# => return x"0611";              -- DPLL cell
      -- sync-seam instruments
      when 16#60# => return x"6060";              -- realign counter
      when 16#61# => return x"6161";              -- realign context
      when 16#62# to 16#69# =>
        return std_logic_vector(to_unsigned(16#6200# + a - 16#62#, 16));
      when 16#6A# => return x"6A6A";              -- serve-start sector
      when 16#6B# => return x"6B6B";              -- LOL serving
      when 16#6C# => return x"6C6C";              -- LOL idle
      when 16#6D# => return x"6D6D";              -- chain-broken windows
      when 16#6E# => return x"000B";              -- frame status "1011"
      -- the write instruments
      when 16#70# => return x"7070";              -- episodes bound
      when 16#71# => return x"1A9F";              -- words last episode (6815)
      when 16#72# => return x"7272";              -- words total
      when 16#73# => return x"5F00";              -- WGATE window low
      when 16#74# => return x"00A6";              -- WGATE window high
      when 16#75# => return x"7575";              -- underrun aborts
      when 16#76# => return x"7676";              -- tab-blocked episodes
      when 16#77# => return x"0302";              -- {inflight 3, tail-cut 2}
      when 16#78# => return x"7878";              -- precompensated pulses
      when 16#79# => return x"0128";              -- {flags completed, track 40}
      when 16#7A# => return x"7A7A";              -- gate-opened episodes
      when 16#7B# => return x"0090";              -- abort reason bitmask
      when 16#7C# => return x"0016";              -- ctrl "10110"
      when 16#7D# => return x"7D7D";              -- CDC overflow count
      when others => return x"EEEE";
    end case;
  end function;

begin

  clk <= not clk after C_CLK / 2;

  uut : entity work.physical_fdd_diag
    port map (
      qnice_clk_i         => clk,
      qnice_addr_i        => addr,
      qnice_data_o        => data,
      diag_status_i       => x"0ABD",
      diag_sync_i         => x"4489",
      diag_est_i          => x"63A",
      diag_fifo_level_i   => "101010",
      diag_index_period_i => x"0098AB65",
      diag_index_width_i  => x"0001F010",
      diag_cnt_index_i    => x"1111",
      diag_cnt_sync_i     => x"2222",
      diag_cnt_word_i     => x"3333",
      diag_cnt_runt_i     => x"4444",
      diag_cnt_lol_i      => x"5555",
      diag_cnt_drop_i     => x"6666",
      diag_map_i          => "101",
      diag_cap_flags_i    => "1010",
      diag_cap_count_i    => cap_count_live,
      diag_cap_words_i    => f_caps,
      diag_served_i       => x"8888",
      diag_rev_mask_i     => "10101010101",
      diag_rev_caps_i     => x"0B",
      diag_rev_lol_i      => x"02",
      diag_fmt_bad_i      => x"9999",
      diag_eng_sig_i      => x"AAA1",
      diag_eng_ses_i      => x"2E",
      diag_eng_done_i     => '1',
      diag_pau_sig_i      => x"AAA2",
      diag_pau_att_i      => x"9C",
      diag_eng_c64_i      => x"C640",
      diag_eng_c256_i     => x"C256",
      diag_pau_c64_i      => x"C641",
      diag_pau_c256_i     => x"C257",
      diag_pau_tap_i      => f_tap128,
      diag_pau_ws_i       => '0',
      sideinv_i           => '1',
      diag_uptime_i       => x"12345678",
      diag_nonce_i        => x"000D",
      diag_cnt_step_i     => x"00A0",
      diag_cyl_i          => to_unsigned(40, 7),
      diag_ctrl_i         => "11010011",
      diag_min_margin_i   => x"0090",
      diag_min_est_i      => x"640",
      diag_min_gap_i      => x"0103",
      diag_margin_stat_i  => x"0009",
      diag_win_opens_i    => x"0001",
      diag_gap_count_i    => x"0045",
      diag_lol_gate_i     => x"0002",
      diag_sync_gate_i    => x"0003",
      diag_est_min_i      => x"638",
      diag_est_max_i      => x"642",
      diag_hist_i         => f_hist,
      diag_miss_i         => f_miss,
      diag_qual_revs_i    => x"0014",
      diag_dpll_cell_i    => x"611",
      diag_realign_i      => x"6060",
      diag_realign_ctx_i  => x"6161",
      diag_presync_i      => f_presync,
      diag_srv_sec_i      => x"6A6A",
      diag_lol_srv_i      => x"6B6B",
      diag_lol_idle_i     => x"6C6C",
      diag_chain_win_i    => x"6D6D",
      diag_frame_stat_i   => "1011",
      dwr_epi_cnt_i       => x"7070",
      dwr_words_last_i    => x"1A9F",
      dwr_words_tot_i     => x"7272",
      dwr_wgate_lo_i      => x"5F00",
      dwr_wgate_hi_i      => x"00A6",
      dwr_underrun_i      => x"7575",
      dwr_discard_i       => x"7676",
      dwr_tail_i          => x"0302",
      dwr_precomp_cnt_i   => x"7878",
      dwr_flags79_i       => x"0128",
      dwr_gateopen_i      => x"7A7A",
      dwr_abortreason_i   => x"90",
      dwr_ctrl7c_i        => "10110",
      dwr_overflow_i      => x"7D7D"
    ); -- uut

  driver : process
    variable v_prev : integer := -1;
  begin
    wait until rising_edge(clk);

    -- T1: fully pipelined back-to-back sweep, address changes every cycle
    for a in 0 to 16#7F# loop
      if v_prev >= 0 then
        assert data = expected(v_prev)
          report "T1 addr " & integer'image(v_prev) & ": got 0x"
                 & to_hstring(data) & " expected 0x"
                 & to_hstring(expected(v_prev))
          severity failure;
      end if;
      addr <= std_logic_vector(to_unsigned(a, 28));
      v_prev := a;
      wait until rising_edge(clk);
    end loop;
    assert data = expected(v_prev) severity failure;
    report "T1 PASS (128 back-to-back reads, every word correct)";

    -- T2: 7-bit folding and unmapped registers
    addr <= std_logic_vector(to_unsigned(16#80#, 28));
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    assert data = x"FDD0" report "T2 alias 0x80" severity failure;
    addr <= std_logic_vector(to_unsigned(16#7F#, 28));
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    assert data = x"EEEE" report "T2 unmapped" severity failure;
    addr <= std_logic_vector(to_unsigned(16#FFF#, 28));
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    assert data = expected(16#7F#) report "T2 high fold" severity failure;
    report "T2 PASS (addr[6:0] folding, EEEE filler)";

    -- T3a: tap change after the falling edge must not leak into this
    -- cycle's word (the output is a register, not a mux)
    addr <= std_logic_vector(to_unsigned(16#12#, 28));
    wait for 15 ns;                     -- 5 ns past the falling edge
    cap_count_live <= x"1234";
    wait until rising_edge(clk);        -- the consuming edge
    assert data = x"7777"
      report "T3a leak-through: got 0x" & to_hstring(data) severity failure;
    -- T3b: the next cycle picks the new value up
    wait until rising_edge(clk);
    assert data = x"1234" report "T3b stale after change" severity failure;
    -- T3c: a change before the falling edge lands in the same cycle
    wait for 5 ns;                      -- 5 ns before the falling edge
    cap_count_live <= x"4321";
    wait until rising_edge(clk);
    assert data = x"4321" report "T3c pre-edge change missed" severity failure;
    report "T3 PASS (falling-edge snapshot, no combinational leak-through)";

    -- T4: a slow/stalled cycle - address held, every consuming edge sees
    -- the same correct word
    addr <= std_logic_vector(to_unsigned(16#1B#, 28));
    for k in 1 to 4 loop
      wait until rising_edge(clk);
      if k >= 2 then
        assert data = x"8888" report "T4 held-address read" severity failure;
      end if;
    end loop;
    report "T4 PASS (held address stays correct)";

    report "TB_FDD_DIAG_RO: ALL PASS";
    std.env.stop;
  end process driver;

end architecture sim;
