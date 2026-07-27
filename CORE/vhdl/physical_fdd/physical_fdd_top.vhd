-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_top: the complete read front-end for the MEGA65 internal
-- floppy drive used as a real Amiga drive. Runs on the 50 MHz QNICE clock
-- (all magnetic constants are proven at exactly this frequency on this
-- mechanism by the C64MEGA65 physical-1581 bring-up); the reconstructed
-- 16-bit MFM words leave through a dual-clock FIFO into the core clock
-- domain, where adf_track_engine serves them to Paula.
--
--   pins -> inputs conditioner -> mfm_gaps -> adaptive quantiser ->
--   bits/aligner -> word FIFO -> (core domain) engine
--
-- Beyond the decode chain this block:
--   * synchronizes the drive-control context (enable / selected / motor)
--     from the core clock domain (2-FF, async_reg),
--   * settle-filters the quasi-static DSKSYNC value from the engine (two
--     consecutive identical samples adopt; a torn sample can at worst cause
--     one transient misalignment that self-heals at the next true sync),
--   * holds the decode chain in reset unless the drive is enabled, selected
--     and its motor is on (RDATA is only driven then anyway; this gives each
--     selection a clean sync hunt),
--   * synthesizes the /RDY line (the 34-pin bus has no READY): motor off =
--     ready (the motor-off drive-ID protocol then reads 0xFFFFFFFF = 3.5"
--     DD drive for df1:), motor on = ready after the spin-up gate (505 ms +
--     2 qualified index edges + fresh index), then HELD while the motor
--     stays on - the mechanism gates INDEX on /SEL, so freshness starves
--     across deselect gaps (hardware round 4 evidence: /RDY flickered at
--     every operation start); a real drive holds RDY while spinning. Eject
--     detection is /DSKCHG's job (hardware-proven), not staleness',
--   * passes the conditioned active-low status levels (track0 / wprot /
--     dskchg) and the qualified INDEX level towards the CIA-A/CIA-B muxes
--     in paula_floppy.v (re-synced into the core domain in mega65.vhd),
--   * exposes diagnostic taps for the QNICE diag device (same 50 MHz
--     domain: no CDC, no tearing),
--   * captures the C_CAP_WORDS words that follow each DSKSYNC hit together
--     with the SIDE line and /TRK0 at the hit (the sector-header capture:
--     the double 0x4489 restarts the capture, so the buffer always holds
--     the words after the LAST sync of the pair = the encoded info long +
--     label start). Only COMPLETE captures are published to the diag
--     registers; a capture torn by deselect stays unpublished. The buffer
--     re-captures on every sector, so an idle dump shows the last sector
--     header of the last read - decode the info long by hand to compare
--     the header's track number against the recorded SIDE intent.
--
-- The FIFO reset discipline is load-bearing: both sides derive from the
-- QNICE reset (wr side directly, rd side synchronized in mega65.vhd) - a
-- one-sided reset would permanently desync the Gray pointers.
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity physical_fdd_top is
  port (
    -- 50 MHz front-end clock (= QNICE clock) + QNICE reset
    clk_i               : in  std_logic;
    rst_i               : in  std_logic;

    -- raw connector inputs (async, active-low at pin)
    f_index_i           : in  std_logic;
    f_track0_i          : in  std_logic;
    f_writeprotect_i    : in  std_logic;
    f_diskchanged_i     : in  std_logic;
    f_rdata_i           : in  std_logic;

    -- drive-control context from the core clock domain (async; synced here):
    enable_i            : in  std_logic;   -- OSM map: a physical unit exists
    selected_i          : in  std_logic;   -- '1' = the physical unit's /SEL is asserted
    motor_i             : in  std_logic;   -- '1' = the physical unit's motor latch is on
    side_i              : in  std_logic;   -- Minimig SIDE line ('1' = lower head = even tracks)
    dsksync_i           : in  std_logic_vector(15 downto 0);  -- live DSKSYNC from the engine

    -- conditioned drive status (50 MHz registers; re-sync in the consumer):
    track0_n_o          : out std_logic;   -- active low = head at track 0
    wprot_n_o           : out std_logic;   -- active low = write protected
    change_n_o          : out std_logic;   -- active low = disk change latched
    ready_n_o           : out std_logic;   -- active low = ready (synthesized, see header)
    index_o             : out std_logic;   -- qualified index LEVEL (1.5..5 ms per rev)
    present_o           : out std_logic;   -- '1' = disk present (= change latch clear)

    -- reconstructed MFM word stream, read side in the core clock domain
    rd_clk_i            : in  std_logic;
    rd_rst_i            : in  std_logic;   -- MUST derive from the same QNICE reset (synced)
    rd_en_i             : in  std_logic;
    rd_data_o           : out std_logic_vector(15 downto 0);
    rd_empty_o          : out std_logic;

    -- diagnostic taps (50 MHz domain, for physical_fdd_diag)
    diag_status_o       : out std_logic_vector(15 downto 0);
    diag_sync_o         : out std_logic_vector(15 downto 0);
    diag_est_o          : out unsigned(11 downto 0);
    diag_fifo_level_o   : out unsigned(5 downto 0);
    diag_index_period_o : out unsigned(31 downto 0);
    diag_index_width_o  : out unsigned(31 downto 0);
    diag_cnt_index_o    : out unsigned(15 downto 0);
    diag_cnt_sync_o     : out unsigned(15 downto 0);
    diag_cnt_word_o     : out unsigned(15 downto 0);
    diag_cnt_runt_o     : out unsigned(15 downto 0);
    diag_cnt_lol_o      : out unsigned(15 downto 0);
    diag_cnt_drop_o     : out unsigned(15 downto 0);
    -- sector-header capture: {3: live SIDE (synced), 2: /TRK0 at the hit,
    -- 1: SIDE at the hit, 0: capture valid} + completed-capture counter +
    -- the C_CAP_WORDS words following the last sync hit (published complete)
    diag_cap_flags_o    : out std_logic_vector(3 downto 0);
    diag_cap_count_o    : out unsigned(15 downto 0);
    diag_cap_words_o    : out t_fdd_cap_words;
    -- per-revolution scoreboard, latched at each accepted index edge: which
    -- sector numbers published a clean capture in the last full revolution,
    -- how many captures and loss-of-lock events that revolution had, plus a
    -- running count of captures whose decoded format byte was not 0xFF
    diag_rev_mask_o     : out std_logic_vector(10 downto 0);
    diag_rev_caps_o     : out unsigned(7 downto 0);
    diag_rev_lol_o      : out unsigned(7 downto 0);
    diag_fmt_bad_o      : out unsigned(15 downto 0)
  );
end entity physical_fdd_top;

architecture rtl of physical_fdd_top is

  -- control context synchronizers (core domain -> 50 MHz)
  signal en_meta, en_s       : std_logic := '0';
  signal sel_meta, sel_s     : std_logic := '0';
  signal mot_meta, mot_s     : std_logic := '0';
  signal side_meta, side_s   : std_logic := '1';
  attribute async_reg            : string;
  attribute async_reg of en_meta  : signal is "true";
  attribute async_reg of sel_meta : signal is "true";
  attribute async_reg of mot_meta : signal is "true";
  attribute async_reg of side_meta : signal is "true";

  -- DSKSYNC settle filter
  signal sync_meta   : std_logic_vector(15 downto 0) := x"4489";
  signal sync_samp   : std_logic_vector(15 downto 0) := x"4489";
  signal sync_prev   : std_logic_vector(15 downto 0) := x"4489";
  signal sync_stable : std_logic_vector(15 downto 0) := x"4489";
  attribute async_reg of sync_meta : signal is "true";

  -- conditioned inputs
  signal rdata_sync   : std_logic;
  signal index_active : std_logic;
  signal index_edge   : std_logic;
  signal index_period : unsigned(31 downto 0);
  signal index_width  : unsigned(31 downto 0);
  signal track0_n     : std_logic;
  signal wprot_n      : std_logic;
  signal change_n     : std_logic;

  -- decode chain
  signal chain_rst    : std_logic;
  signal gap_valid    : std_logic;
  signal gap_len      : unsigned(15 downto 0);
  signal runt         : std_logic;
  signal q_valid      : std_logic;
  signal q_class      : unsigned(1 downto 0);
  signal est_q        : unsigned(11 downto 0);
  signal word_valid   : std_logic;
  signal word_data    : std_logic_vector(15 downto 0);
  signal sync_hit     : std_logic;
  signal lol          : std_logic;

  -- ready model
  signal spin_cnt     : natural range 0 to C_READY_MOTOR_CYC := 0;
  signal spun_up      : std_logic := '0';
  signal edge_cnt     : unsigned(1 downto 0) := (others => '0');  -- saturates at C_READY_MIN_EDGES
  signal stale_cnt    : natural range 0 to C_INDEX_STALE_CYC := C_INDEX_STALE_CYC;
  signal idx_fresh    : std_logic := '0';
  signal media_ready  : std_logic := '0';

  -- FIFO
  signal fifo_full    : std_logic;
  signal fifo_level   : unsigned(5 downto 0);

  -- diag counters (wrapping)
  signal cnt_index    : unsigned(15 downto 0) := (others => '0');
  signal cnt_sync     : unsigned(15 downto 0) := (others => '0');
  signal cnt_word     : unsigned(15 downto 0) := (others => '0');
  signal cnt_runt     : unsigned(15 downto 0) := (others => '0');
  signal cnt_lol      : unsigned(15 downto 0) := (others => '0');
  signal cnt_drop     : unsigned(15 downto 0) := (others => '0');

  -- sector-header capture: live buffer fills after each sync hit; only a
  -- COMPLETE buffer is published to the shadow (what the diag exposes)
  signal cap_live     : t_fdd_cap_words := (others => (others => '0'));
  signal cap_shad     : t_fdd_cap_words := (others => (others => '0'));
  signal cap_wp       : unsigned(3 downto 0) := to_unsigned(C_CAP_WORDS, 4);
  signal cap_side     : std_logic := '0';   -- SIDE at the live capture's hit
  signal cap_trk0n    : std_logic := '1';   -- /TRK0 at the live capture's hit
  signal cap_fside    : std_logic := '0';   -- published flags
  signal cap_ftrk0n   : std_logic := '1';
  signal cap_valid    : std_logic := '0';
  signal cap_count    : unsigned(15 downto 0) := (others => '0');

  -- per-revolution scoreboard (current revolution accumulators + the copy
  -- latched at the last accepted index edge)
  signal rev_mask      : std_logic_vector(10 downto 0) := (others => '0');
  signal rev_caps      : unsigned(7 downto 0) := (others => '0');
  signal rev_lol       : unsigned(7 downto 0) := (others => '0');
  signal rev_mask_last : std_logic_vector(10 downto 0) := (others => '0');
  signal rev_caps_last : unsigned(7 downto 0) := (others => '0');
  signal rev_lol_last  : unsigned(7 downto 0) := (others => '0');
  signal fmt_bad_cnt   : unsigned(15 downto 0) := (others => '0');

begin

  i_inputs : entity work.physical_fdd_inputs
    port map (
      clk_i            => clk_i,
      rst_i            => rst_i,
      f_index_i        => f_index_i,
      f_track0_i       => f_track0_i,
      f_writeprotect_i => f_writeprotect_i,
      f_diskchanged_i  => f_diskchanged_i,
      f_rdata_i        => f_rdata_i,
      rdata_sync_o     => rdata_sync,
      index_active_o   => index_active,
      index_edge_o     => index_edge,
      index_period_o   => index_period,
      index_width_o    => index_width,
      track0_n_o       => track0_n,
      wprot_n_o        => wprot_n,
      change_n_o       => change_n
    ); -- i_inputs

  -- the decode chain only runs while the drive can actually deliver flux;
  -- each selection starts with a clean sync hunt
  chain_rst <= rst_i or not (en_s and sel_s and mot_s);

  i_gaps : entity work.physical_fdd_mfm_gaps
    port map (
      clk_i       => clk_i,
      rst_i       => chain_rst,
      f_rdata_i   => rdata_sync,
      gap_valid_o => gap_valid,
      gap_len_o   => gap_len,
      runt_o      => runt
    ); -- i_gaps

  i_quantise : entity work.physical_fdd_mfm_quantise
    port map (
      clk_i       => clk_i,
      rst_i       => chain_rst,
      gap_valid_i => gap_valid,
      gap_len_i   => gap_len,
      gap_valid_o => q_valid,
      gap_class_o => q_class,
      est_o       => est_q
    ); -- i_quantise

  i_bits : entity work.physical_fdd_bits
    port map (
      clk_i        => clk_i,
      rst_i        => chain_rst,
      gap_valid_i  => q_valid,
      gap_class_i  => q_class,
      sync_i       => sync_stable,
      word_valid_o => word_valid,
      word_o       => word_data,
      sync_hit_o   => sync_hit,
      lol_o        => lol
    ); -- i_bits

  i_wfifo : entity work.physical_fdd_wfifo
    generic map (
      G_AW => 5
    )
    port map (
      wr_clk_i   => clk_i,
      wr_rst_i   => rst_i,
      wr_en_i    => word_valid,
      wr_data_i  => word_data,
      wr_full_o  => fifo_full,
      wr_level_o => fifo_level,
      rd_clk_i   => rd_clk_i,
      rd_rst_i   => rd_rst_i,
      rd_en_i    => rd_en_i,
      rd_data_o  => rd_data_o,
      rd_empty_o => rd_empty_o
    ); -- i_wfifo

  -- status towards the CIA muxes: registered 50 MHz levels
  track0_n_o <= track0_n;
  wprot_n_o  <= wprot_n;
  change_n_o <= change_n;
  ready_n_o  <= not ((not mot_s) or media_ready);
  index_o    <= index_active;
  present_o  <= change_n;         -- change latch clear = disk present (the
                                  -- mechanism clears it on STEP with a disk
                                  -- in - trackdisk's own change polling)

  -- diag taps
  diag_status_o(0)            <= en_s;
  diag_status_o(1)            <= sel_s;
  diag_status_o(2)            <= mot_s;
  diag_status_o(3)            <= media_ready;
  diag_status_o(4)            <= spun_up;
  diag_status_o(5)            <= idx_fresh;
  diag_status_o(6)            <= index_active;
  diag_status_o(7)            <= track0_n;
  diag_status_o(8)            <= wprot_n;
  diag_status_o(9)            <= change_n;
  diag_status_o(10)           <= rdata_sync;
  diag_status_o(11)           <= fifo_full;
  diag_status_o(15 downto 12) <= (others => '0');
  diag_sync_o                 <= sync_stable;
  diag_est_o                  <= est_q;
  diag_fifo_level_o           <= fifo_level;
  diag_index_period_o         <= index_period;
  diag_index_width_o          <= index_width;
  diag_cnt_index_o            <= cnt_index;
  diag_cnt_sync_o             <= cnt_sync;
  diag_cnt_word_o             <= cnt_word;
  diag_cnt_runt_o             <= cnt_runt;
  diag_cnt_lol_o              <= cnt_lol;
  diag_cnt_drop_o             <= cnt_drop;
  diag_cap_flags_o            <= side_s & cap_ftrk0n & cap_fside & cap_valid;
  diag_cap_count_o            <= cap_count;
  diag_cap_words_o            <= cap_shad;
  diag_rev_mask_o             <= rev_mask_last;
  diag_rev_caps_o             <= rev_caps_last;
  diag_rev_lol_o              <= rev_lol_last;
  diag_fmt_bad_o              <= fmt_bad_cnt;

  ctrl_proc : process (clk_i)
  begin
    if rising_edge(clk_i) then
      -- control-context synchronizers (always run)
      en_meta  <= enable_i;    en_s  <= en_meta;
      sel_meta <= selected_i;  sel_s <= sel_meta;
      mot_meta <= motor_i;     mot_s <= mot_meta;
      side_meta <= side_i;     side_s <= side_meta;

      -- DSKSYNC settle filter: adopt after two consecutive identical samples
      sync_meta <= dsksync_i;
      sync_samp <= sync_meta;
      sync_prev <= sync_samp;
      if sync_samp = sync_prev then
        sync_stable <= sync_samp;
      end if;

      if rst_i = '1' then
        spin_cnt    <= 0;
        spun_up     <= '0';
        edge_cnt    <= (others => '0');
        stale_cnt   <= C_INDEX_STALE_CYC;
        idx_fresh   <= '0';
        media_ready <= '0';
        cnt_index   <= (others => '0');
        cnt_sync    <= (others => '0');
        cnt_word    <= (others => '0');
        cnt_runt    <= (others => '0');
        cnt_lol     <= (others => '0');
        cnt_drop    <= (others => '0');
      else
        -- spin-up gate: motor high time + qualified index edges since motor-on
        if mot_s = '0' then
          spin_cnt <= 0;
          spun_up  <= '0';
          edge_cnt <= (others => '0');
        elsif spin_cnt = C_READY_MOTOR_CYC then
          spun_up <= '1';
        else
          spin_cnt <= spin_cnt + 1;
        end if;

        if index_edge = '1' then
          stale_cnt <= 0;
          if mot_s = '1' and edge_cnt /= C_READY_MIN_EDGES then
            edge_cnt <= edge_cnt + 1;
          end if;
        elsif stale_cnt /= C_INDEX_STALE_CYC then
          stale_cnt <= stale_cnt + 1;
        end if;
        if stale_cnt = C_INDEX_STALE_CYC then
          idx_fresh <= '0';
        else
          idx_fresh <= '1';
        end if;

        -- media_ready: qualified by spin-up + 2 index edges + freshness,
        -- then HELD while the motor stays on. The mechanism gates INDEX
        -- (like all outputs) on /SEL, so freshness starves across deselect
        -- gaps and at operation starts - a real drive holds RDY while
        -- spinning because its index sensing is internal. Eject detection
        -- is /DSKCHG's job (hardware-proven), not freshness'.
        if mot_s = '0' then
          media_ready <= '0';
        elsif edge_cnt = C_READY_MIN_EDGES and spun_up = '1'
              and idx_fresh = '1' then
          media_ready <= '1';
        end if;

        -- diag counters (wrapping)
        if index_edge = '1' then
          cnt_index <= cnt_index + 1;
        end if;
        if sync_hit = '1' then
          cnt_sync <= cnt_sync + 1;
        end if;
        if word_valid = '1' then
          cnt_word <= cnt_word + 1;
          if fifo_full = '1' then
            cnt_drop <= cnt_drop + 1;
          end if;
        end if;
        if runt = '1' then
          cnt_runt <= cnt_runt + 1;
        end if;
        if lol = '1' then
          cnt_lol <= cnt_lol + 1;
        end if;
      end if;
    end if;
  end process ctrl_proc;

  -- Sector-header capture. A sync hit (which accompanies its own word_valid)
  -- restarts the capture and latches SIDE + /TRK0; each following word fills
  -- the live buffer. Storing the last word publishes buffer + flags to the
  -- shadow in the same cycle, so the diag never exposes a torn capture (a
  -- capture cut short by deselect stays unpublished). During a read every
  -- sector re-captures; an idle dump therefore shows the last sector header
  -- of the last read burst.
  --
  -- Each publish also feeds the per-revolution scoreboard: the info long's
  -- format and sector bytes are decoded from the captured words (byte b of
  -- the long = ((odd_b and 0x55) shl 1) or (even_b and 0x55); odd bytes ride
  -- in words 0/1, even bytes in words 2/3). A clean 0xFF-format capture sets
  -- the sector's bit in the current revolution's mask; anything else counts
  -- as a bad-format capture (a slowly ticking count is normal - the write
  -- splice can fake a sync). The accumulators roll into the *_last copies at
  -- each accepted index edge, so one idle dump shows the last full
  -- revolution: which sectors decoded, how many captures, how many losses
  -- of lock.
  cap_proc : process (clk_i)
    variable v_fmt : std_logic_vector(7 downto 0);
    variable v_sec : std_logic_vector(7 downto 0);
    variable v_pub : std_logic;
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        cap_wp        <= to_unsigned(C_CAP_WORDS, cap_wp'length);
        cap_valid     <= '0';
        cap_count     <= (others => '0');
        rev_mask      <= (others => '0');
        rev_caps      <= (others => '0');
        rev_lol       <= (others => '0');
        rev_mask_last <= (others => '0');
        rev_caps_last <= (others => '0');
        rev_lol_last  <= (others => '0');
        fmt_bad_cnt   <= (others => '0');
      else
        v_pub := '0';
        if sync_hit = '1' then
          cap_wp    <= (others => '0');
          cap_side  <= side_s;
          cap_trk0n <= track0_n;
        elsif word_valid = '1' and cap_wp /= C_CAP_WORDS then
          cap_live(to_integer(cap_wp(2 downto 0))) <= word_data;
          if cap_wp = C_CAP_WORDS - 1 then
            -- publish: live words 0..N-2 + this word, atomically
            for i in 0 to C_CAP_WORDS - 2 loop
              cap_shad(i) <= cap_live(i);
            end loop;
            cap_shad(C_CAP_WORDS - 1) <= word_data;
            cap_fside  <= cap_side;
            cap_ftrk0n <= cap_trk0n;
            cap_valid  <= '1';
            cap_count  <= cap_count + 1;
            v_pub      := '1';
          end if;
          cap_wp <= cap_wp + 1;
        end if;

        -- per-revolution scoreboard. Rollover wins over a same-cycle event
        -- (a capture or LOL landing exactly on the index edge is dropped -
        -- a once-per-revolution don't-care).
        if index_edge = '1' then
          rev_mask_last <= rev_mask;
          rev_caps_last <= rev_caps;
          rev_lol_last  <= rev_lol;
          rev_mask      <= (others => '0');
          rev_caps      <= (others => '0');
          rev_lol       <= (others => '0');
        else
          if lol = '1' and rev_lol /= x"FF" then
            rev_lol <= rev_lol + 1;
          end if;
          if v_pub = '1' then
            -- decoded info bytes 0 (format) and 2 (sector); words 0..3 are
            -- long-stable registers by the time word 7 publishes
            v_fmt := ((cap_live(0)(14 downto 8) & '0') and x"AA")
                     or (cap_live(2)(15 downto 8) and x"55");
            v_sec := ((cap_live(1)(14 downto 8) & '0') and x"AA")
                     or (cap_live(3)(15 downto 8) and x"55");
            if v_fmt = x"FF" then
              if unsigned(v_sec) <= 10 then
                rev_mask(to_integer(unsigned(v_sec(3 downto 0)))) <= '1';
              end if;
            else
              fmt_bad_cnt <= fmt_bad_cnt + 1;
            end if;
            if rev_caps /= x"FF" then
              rev_caps <= rev_caps + 1;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process cap_proc;

end architecture rtl;
