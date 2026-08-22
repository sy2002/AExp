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
--   * carries the diag-map-v7 margin instrumentation (margin_proc): a
--     millisecond uptime counter (dump freshness), step/cylinder tracking,
--     per-class signed-error histograms of the quantiser's classification
--     margins with an optional armed-sector window, minimum-margin capture,
--     estimate-excursion tracking and a per-sector miss profile - the
--     measured interval-domain evidence the data-separator redesign needs
--     (2026-08-07 field falsification: media verdicts retracted, decode
--     margin under suspicion),
--   * gates the aligner's WORDSYNC-conditional framing hold (the sync-seam
--     fix, diag map v10) and carries the seam instruments (seam_proc):
--     mid-serve realign events with remainder context, the pre-sync word
--     tap, the per-session serve-start sector, the streaming-split
--     loss-of-lock twins and the chain-gated miss-profile qualifier,
--   * captures the C_CAP_WORDS words that follow each DSKSYNC hit together
--     with the SIDE line and /TRK0 at the hit (the sector-header capture:
--     the double 0x4489 restarts the capture, so the buffer always holds
--     the words after the LAST sync of the pair = the encoded info long +
--     label start). The capture consumes the aligner's sync-anchored
--     DIAGNOSTIC word stream, whose framing realigns at every sync match
--     even while the served framing is held across the write splice - so
--     the capture-based instruments (header words, rev mask, fmt_bad, miss
--     profile, armed-sector window) stay trustworthy during hold-mode
--     serves; while the hold has not been engaged since the framing
--     counters last coincided (any sync match, LOL or chain reset) the
--     diagnostic stream is identical to the served one - in particular
--     in the realign-always A/B arm, where the hold never engages.
--     Only COMPLETE captures are published to the diag
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
    step_n_i            : in  std_logic := '1';  -- registered mirror of the f_step pin (async; synced here)
    stepdir_i           : in  std_logic := '1';  -- registered mirror of f_stepdir ('1' = toward track 0)
    serving_i           : in  std_logic := '0';  -- engine phys_stream: a physical read session is open
    -- engine phys_stream AND past the serve-start sync (phys_hunt done):
    -- words are streaming into Paula. Gates the WORDSYNC-conditional
    -- framing hold - during the pre-serve hunt alignment must stay active
    -- (serve-from-sync depends on it), afterwards the framing free-runs
    -- while live WORDSYNC is 0 (real-Paula behavior; the sync-seam fix -
    -- see FRAMING HOLD in physical_fdd_bits.vhd)
    serving_data_i      : in  std_logic := '0';
    wordsync_i          : in  std_logic := '0';  -- live ADKCON WORDSYNC (core domain)

    -- margin-instrumentation control (QNICE domain = this clock, no sync):
    -- {5: histogram ALL gaps (ignore the serve gate), 4: window mode (only
    -- inside the armed-sector window), 3..0: armed sector K}; clear_i is a
    -- one-cycle pulse zeroing every "since clear" statistic
    ctrl_i              : in  std_logic_vector(5 downto 0) := (others => '0');
    clear_i             : in  std_logic := '0';
    -- '1' = run the LEGACY quantiser bit source instead of the DPLL data
    -- separator (diag control 0x35 bit 6; reset default '0' = DPLL - the
    -- field A/B switch, see physical_fdd_pkg.vhd)
    dpll_dis_i          : in  std_logic := '0';
    -- '1' = realign-always framing (the pre-v10 behavior; diag control
    -- 0x35 bit 7, reset default '0' = WORDSYNC-conditional framing hold -
    -- the sync-seam fix's field A/B switch)
    framehold_dis_i     : in  std_logic := '0';

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
    diag_fmt_bad_o      : out unsigned(15 downto 0);

    -- diag map v7: uptime, workload visibility, interval-domain margins
    diag_uptime_o       : out unsigned(31 downto 0) := (others => '0');  -- ms since reset
    diag_cnt_step_o     : out unsigned(15 downto 0) := (others => '0');  -- step pulses (wrapping)
    diag_cyl_o          : out unsigned(6 downto 0)  := (others => '0');  -- stepdir-integrated, /TRK0-referenced
    diag_min_margin_o   : out unsigned(15 downto 0) := (others => '1');  -- min(tol-|e|) Q4; 0xFFFF = none yet
    diag_min_est_o      : out unsigned(11 downto 0) := (others => '0');  -- est at the min-margin gap
    diag_min_gap_o      : out unsigned(15 downto 0) := (others => '0');  -- raw length of that gap (cycles)
    diag_margin_stat_o  : out std_logic_vector(15 downto 0) := (others => '0');
    diag_win_opens_o    : out unsigned(15 downto 0) := (others => '0');
    diag_gap_count_o    : out unsigned(15 downto 0) := (others => '0');  -- gaps histogrammed (saturating)
    diag_lol_gate_o     : out unsigned(15 downto 0) := (others => '0');  -- rejected gaps while gated
    diag_sync_gate_o    : out unsigned(15 downto 0) := (others => '0');  -- sync hits while gated
    diag_est_min_o      : out unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);
    diag_est_max_o      : out unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);
    diag_hist_o         : out t_fdd_hist := (others => (others => '0'));
    diag_miss_o         : out t_fdd_miss := (others => (others => '0'));
    diag_qual_revs_o    : out unsigned(15 downto 0) := (others => '0');
    diag_dpll_cell_o    : out unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);

    -- diag map v10: the sync-seam instruments (design rationale at
    -- seam_proc below and in physical_fdd_bits.vhd FRAMING HOLD)
    diag_realign_o      : out unsigned(15 downto 0) := (others => '0');
    diag_realign_ctx_o  : out std_logic_vector(15 downto 0) := (others => '0');
    diag_presync_o      : out t_fdd_cap_words := (others => (others => '0'));
    diag_srv_sec_o      : out std_logic_vector(15 downto 0) := x"00FF";
    diag_lol_srv_o      : out unsigned(15 downto 0) := (others => '0');
    diag_lol_idle_o     : out unsigned(15 downto 0) := (others => '0');
    diag_chain_win_o    : out unsigned(15 downto 0) := (others => '0');
    diag_frame_stat_o   : out std_logic_vector(3 downto 0) := (others => '0')
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
  signal dpll_en      : std_logic;
  signal gap_valid    : std_logic;
  signal gap_len      : unsigned(15 downto 0);
  signal runt         : std_logic;
  signal q_valid      : std_logic;
  signal q_class      : unsigned(1 downto 0);
  signal est_q        : unsigned(11 downto 0);
  signal q_e          : signed(15 downto 0);      -- signed error G - n*est, Q4
  signal q_tol        : unsigned(14 downto 0);    -- acceptance tolerance, Q4
  signal q_est        : unsigned(11 downto 0);    -- est the gap was classified with
  signal word_valid   : std_logic;
  signal word_data    : std_logic_vector(15 downto 0);
  -- diagnostic word stream: always sync-realigned framing over the same
  -- bits (physical_fdd_bits DIAGNOSTIC WORD STREAM). The capture path
  -- consumes THIS stream, so the capture instruments stay correctly framed
  -- while the served framing is held across the write splice (the A6 dump
  -- caveat); the streams coincide whenever the hold has not been engaged
  -- since the framing counters last coincided (see the bits header).
  signal dword_valid  : std_logic;
  signal dword_data   : std_logic_vector(15 downto 0);
  signal sync_hit     : std_logic;
  signal lol          : std_logic;

  -- WORDSYNC-conditional framing hold + seam instruments (diag map v10)
  signal srvd_meta    : std_logic := '0';
  signal srvd_s       : std_logic := '0';
  signal srvd_p       : std_logic := '0';
  signal ws_meta      : std_logic := '0';
  signal ws_s         : std_logic := '0';
  signal frame_hold   : std_logic;
  signal realign_evt  : std_logic;
  signal realign_rem  : unsigned(3 downto 0);
  signal realign_cnt  : unsigned(15 downto 0) := (others => '0');
  signal realign_odd  : unsigned(7 downto 0) := (others => '0');
  signal realign_lrem : unsigned(3 downto 0) := (others => '0');
  signal word_ring    : t_fdd_cap_words := (others => (others => '0'));
  signal presync_shad : t_fdd_cap_words := (others => (others => '0'));
  signal ses_cnt      : unsigned(7 downto 0) := (others => '0');
  signal srv_sec_r    : unsigned(7 downto 0) := x"FF";   -- 0xFF = none yet
  signal srvsec_arm   : std_logic := '0';
  signal lol_srv      : unsigned(15 downto 0) := (others => '0');
  signal lol_idle     : unsigned(15 downto 0) := (others => '0');
  signal rev_chain_ok : std_logic := '0';
  signal chain_win    : unsigned(15 downto 0) := (others => '0');

  -- margin instrumentation (diag map v7)
  signal step_meta    : std_logic := '1';
  signal step_s       : std_logic := '1';
  signal step_p       : std_logic := '1';
  signal trk0_p       : std_logic := '1';   -- /TRK0 assert-edge detect for the cyl zeroing
  signal dir_meta     : std_logic := '1';
  signal dir_s        : std_logic := '1';
  signal srv_meta     : std_logic := '0';
  signal srv_s        : std_logic := '0';
  attribute async_reg of step_meta : signal is "true";
  attribute async_reg of dir_meta  : signal is "true";
  attribute async_reg of srv_meta  : signal is "true";
  attribute async_reg of srvd_meta : signal is "true";
  attribute async_reg of ws_meta   : signal is "true";
  constant C_MS_CYC   : natural := C_FDD_HZ / 1000;   -- cycles per millisecond
  signal ms_div       : natural range 0 to C_MS_CYC - 1 := 0;
  signal uptime_ms    : unsigned(31 downto 0) := (others => '0');
  signal cnt_step     : unsigned(15 downto 0) := (others => '0');
  signal cyl          : unsigned(6 downto 0) := (others => '0');
  signal win_open     : std_logic := '0';
  signal win_opens    : unsigned(15 downto 0) := (others => '0');
  signal gap_cnt      : unsigned(15 downto 0) := (others => '0');
  signal lol_gate     : unsigned(15 downto 0) := (others => '0');
  signal sync_gate    : unsigned(15 downto 0) := (others => '0');
  signal min_margin   : unsigned(15 downto 0) := (others => '1');
  signal min_est      : unsigned(11 downto 0) := (others => '0');
  signal min_gap      : unsigned(15 downto 0) := (others => '0');
  signal min_cls      : unsigned(1 downto 0) := "11";
  signal est_min      : unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);
  signal est_max      : unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);
  signal hist         : t_fdd_hist := (others => (others => '0'));
  type t_miss_cnt is array (0 to 10) of unsigned(7 downto 0);
  signal miss_cnt     : t_miss_cnt := (others => (others => '0'));
  signal qual_revs    : unsigned(15 downto 0) := (others => '0');
  -- capture-publish export from cap_proc towards the window logic: a clean
  -- (format 0xFF, sector <= 10) capture published this cycle, and its sector
  signal pub_stb      : std_logic := '0';
  signal pub_sec      : unsigned(3 downto 0) := (others => '0');

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
  dpll_en   <= not dpll_dis_i;

  -- WORDSYNC-conditional framing hold (the sync-seam fix): once the engine
  -- streams words past its serve-start sync AND live WORDSYNC is 0, the
  -- aligner's word framing free-runs like a real Paula's shifter - no
  -- mid-capture realignment turning the write-splice slip into a
  -- rotation-inconsistent seam (tb_fdd_splice E2: RED without the hold in
  -- both separator modes, GREEN with it). During the pre-serve hunt and
  -- under WORDSYNC=1 realignment stays active (serve-from-sync and the
  -- X-Copy class depend on it, and real Paula re-syncs per matching word
  -- under WORDSYNC=1 too).
  frame_hold <= srvd_s and not ws_s and not framehold_dis_i;

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
      est_o       => est_q,
      gap_e_o     => q_e,
      gap_tol_o   => q_tol,
      gap_est_o   => q_est
    ); -- i_quantise

  i_bits : entity work.physical_fdd_bits
    port map (
      clk_i        => clk_i,
      rst_i        => chain_rst,
      gap_valid_i  => q_valid,
      gap_class_i  => q_class,
      sync_i       => sync_stable,
      dpll_en_i    => dpll_en,
      edge_valid_i => gap_valid,
      dpll_cell_o  => diag_dpll_cell_o,
      frame_hold_i => frame_hold,
      word_valid_o => word_valid,
      word_o       => word_data,
      dword_valid_o => dword_valid,
      dword_o      => dword_data,
      sync_hit_o   => sync_hit,
      realign_evt_o => realign_evt,
      realign_rem_o => realign_rem,
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

  -- diag map v7 taps
  diag_uptime_o               <= uptime_ms;
  diag_cnt_step_o             <= cnt_step;
  diag_cyl_o                  <= cyl;
  diag_min_margin_o           <= min_margin;
  diag_min_est_o              <= min_est;
  diag_min_gap_o              <= min_gap;
  diag_margin_stat_o          <= x"00" & "000"
                                 & ((srv_s or ctrl_i(5))
                                    and (win_open or not ctrl_i(4)))
                                 & srv_s & win_open
                                 & std_logic_vector(min_cls);
  diag_win_opens_o            <= win_opens;
  diag_gap_count_o            <= gap_cnt;
  diag_lol_gate_o             <= lol_gate;
  diag_sync_gate_o            <= sync_gate;
  diag_est_min_o              <= est_min;
  diag_est_max_o              <= est_max;
  diag_hist_o                 <= hist;
  diag_miss_gen : for i in 0 to 4 generate
    diag_miss_o(i) <= std_logic_vector(miss_cnt(2 * i + 1))
                      & std_logic_vector(miss_cnt(2 * i));
  end generate diag_miss_gen;
  diag_miss_o(5)              <= x"00" & std_logic_vector(miss_cnt(10));
  diag_qual_revs_o            <= qual_revs;

  -- diag map v10 taps (seam instruments)
  diag_realign_o              <= realign_cnt;
  diag_realign_ctx_o          <= std_logic_vector(realign_odd) & "0000"
                                 & std_logic_vector(realign_lrem);
  diag_presync_o              <= presync_shad;
  diag_srv_sec_o              <= std_logic_vector(ses_cnt)
                                 & std_logic_vector(srv_sec_r);
  diag_lol_srv_o              <= lol_srv;
  diag_lol_idle_o             <= lol_idle;
  diag_chain_win_o            <= chain_win;
  diag_frame_stat_o           <= framehold_dis_i & srvd_s & ws_s & frame_hold;

  -- The sync-seam instruments (diag map v10). All 50 MHz domain:
  --   * realign events: sync-window matches landing MID-WORD (bit_cnt /=
  --     15) while the engine streams words = framing seams. With the hold
  --     disabled these were taken (the pre-v10 realignment - one seam per
  --     splice crossing); with the hold they are suppressed but still
  --     counted, so the A/B dumps stay comparable. The remainder context
  --     (last event's bit phase + odd-remainder count) separates odd from
  --     even slips.
  --   * pre-sync tap: the last C_CAP_WORDS words emitted BEFORE the seam
  --     event = the [gap run][hybrid word] fingerprint the E2 testbench
  --     showed, live from hardware.
  --   * serve-start sector: the first clean capture published after the
  --     engine enters data streaming = where this session's serve began
  --     (the escape-arc observable of audit residue r1; 0xFF = none yet).
  --   * LOL twins: loss-of-lock events split by streaming state - the
  --     honest version of "LOL during reads" (cnt_lol counts everything).
  seam_proc : process (clk_i)
  begin
    if rising_edge(clk_i) then
      srvd_meta <= serving_data_i;  srvd_s <= srvd_meta;  srvd_p <= srvd_s;
      ws_meta   <= wordsync_i;      ws_s   <= ws_meta;

      if rst_i = '1' then
        realign_cnt  <= (others => '0');
        realign_odd  <= (others => '0');
        realign_lrem <= (others => '0');
        presync_shad <= (others => (others => '0'));
        ses_cnt      <= (others => '0');
        srv_sec_r    <= x"FF";
        srvsec_arm   <= '0';
        lol_srv      <= (others => '0');
        lol_idle     <= (others => '0');
      else
        -- ring of the last emitted words (reads below see the pre-push
        -- state, so a same-cycle snapshot excludes the sync word itself)
        if word_valid = '1' then
          for i in 0 to C_CAP_WORDS - 2 loop
            word_ring(i) <= word_ring(i + 1);
          end loop;
          word_ring(C_CAP_WORDS - 1) <= word_data;
        end if;

        if realign_evt = '1' and srvd_s = '1' then
          realign_cnt  <= realign_cnt + 1;
          realign_lrem <= realign_rem;
          if realign_rem(0) = '1' and realign_odd /= x"FF" then
            realign_odd <= realign_odd + 1;
          end if;
          presync_shad <= word_ring;
        end if;

        -- serve-start sector: latch the first clean publish per session
        if srvd_s = '1' and srvd_p = '0' then
          srvsec_arm <= '1';
          ses_cnt    <= ses_cnt + 1;
        elsif srvsec_arm = '1' and pub_stb = '1' then
          srv_sec_r  <= x"0" & pub_sec;
          srvsec_arm <= '0';
        end if;

        if lol = '1' then
          if srvd_s = '1' then
            lol_srv <= lol_srv + 1;
          else
            lol_idle <= lol_idle + 1;
          end if;
        end if;

        -- experiment clear (ses_cnt keeps running - it is a freshness
        -- counter like the dump nonce)
        if clear_i = '1' then
          realign_cnt  <= (others => '0');
          realign_odd  <= (others => '0');
          realign_lrem <= (others => '0');
          presync_shad <= (others => (others => '0'));
          srv_sec_r    <= x"FF";
          lol_srv      <= (others => '0');
          lol_idle     <= (others => '0');
        end if;
      end if;
    end if;
  end process seam_proc;

  -- The interval-domain margin engine (diag map v7). Everything below runs
  -- in the 50 MHz domain; step/stepdir/serving arrive from the core clock
  -- domain and are 2-FF synchronized here (step pulses are CIA-driven,
  -- microseconds wide - a 2-FF at 50 MHz cannot miss them).
  --
  --   * uptime: free-running millisecond counter since QNICE reset - the
  --     dump-freshness proof (two dumps can never read the same value).
  --   * head position: step pulses counted and direction-integrated into a
  --     cylinder estimate; /TRK0 asserting forces 0 (mechanical ground
  --     truth beats the integral). Makes seeks and the grinding position
  --     visible in one register.
  --   * margin statistics on every ACCEPTED gap while the gate is open:
  --     gate = (serving OR ctrl[5]) AND (window open OR NOT ctrl[4]).
  --     Default ctrl=0 = "during physical read sessions only" - seek noise
  --     and idle streaming stay out of the distributions. The signed error
  --     e = G - n*est lands in the per-class 8-bin histogram spanning
  --     [-tol..+tol) (bin width tol/4, saturating); the minimum acceptance
  --     margin tol - |e| is tracked together with the est, raw length and
  --     class of the gap that produced it. Rejected gaps (class "11") and
  --     sync hits are counted per gate so the histogram mass has its
  --     denominators. est min/max track the estimate excursion UNgated
  --     (drag is interesting wherever it happens).
  --   * armed-sector window (ctrl[4]=1, K=ctrl[3:0]): opens at the clean
  --     capture publish of sector K-1 (mod 11) and closes at the next sync
  --     hit - i.e. it spans the approach to sector K: the tail of the
  --     preceding sector's data field, the pre-sync gap bytes and K's sync.
  --     When K's sync is MISSED the window stays open across K's whole
  --     region until the next decoded sync - exactly the flux the failure
  --     lives in. clear_i (control-register write with bit 15) zeroes all
  --     "since clear" state for a fresh experiment without a power cycle.
  margin_proc : process (clk_i)
    variable v_off : unsigned(16 downto 0);
    variable v_tol : unsigned(16 downto 0);
    variable v_bin : unsigned(2 downto 0);
    variable v_idx : natural range 0 to 3 * C_HIST_BINS - 1;
    variable v_abs : unsigned(15 downto 0);
    variable v_mar : unsigned(15 downto 0);
    variable v_prv : unsigned(3 downto 0);
  begin
    if rising_edge(clk_i) then
      -- synchronizers always run
      step_meta <= step_n_i;  step_s <= step_meta;  step_p <= step_s;
      dir_meta  <= stepdir_i; dir_s  <= dir_meta;
      srv_meta  <= serving_i; srv_s  <= srv_meta;

      if rst_i = '1' then
        ms_div     <= 0;
        uptime_ms  <= (others => '0');
        cnt_step   <= (others => '0');
        cyl        <= (others => '0');
        win_open   <= '0';
        win_opens  <= (others => '0');
        gap_cnt    <= (others => '0');
        lol_gate   <= (others => '0');
        sync_gate  <= (others => '0');
        min_margin <= (others => '1');
        min_cls    <= "11";
        min_est    <= (others => '0');
        min_gap    <= (others => '0');
        est_min    <= to_unsigned(C_QUANT_EST_NOM_Q, est_min'length);
        est_max    <= to_unsigned(C_QUANT_EST_NOM_Q, est_max'length);
        hist       <= (others => (others => '0'));
      else
        -- uptime milliseconds (wraps after ~49.7 days)
        if ms_div = C_MS_CYC - 1 then
          ms_div    <= 0;
          uptime_ms <= uptime_ms + 1;
        else
          ms_div <= ms_div + 1;
        end if;

        -- step accounting on the accepted (synced) falling edge; the pin
        -- mirror is already select-gated in mega65.vhd, so only our unit's
        -- steps arrive here
        if step_s = '0' and step_p = '1' then
          cnt_step <= cnt_step + 1;
          if dir_s = '1' then                        -- toward track 0
            if cyl /= 0 then
              cyl <= cyl - 1;
            end if;
          elsif cyl /= 127 then
            cyl <= cyl + 1;
          end if;
        end if;
        -- mechanical ground truth on the /TRK0 ASSERT EDGE only: the level
        -- stays asserted for milliseconds after the first step away from
        -- track 0 (the head is still moving), and a level-sensitive zero
        -- swallowed that step - the 2026-08-08 field dumps read the
        -- cylinder one low against every decoded track number
        trk0_p <= track0_n;
        if track0_n = '0' and trk0_p = '1' then
          cyl <= (others => '0');
        end if;

        -- estimate excursion, ungated
        if est_q < est_min then
          est_min <= est_q;
        end if;
        if est_q > est_max then
          est_max <= est_q;
        end if;

        -- armed-sector window: K-1 mod 11 publishes -> open; sync -> close
        v_prv := unsigned(ctrl_i(3 downto 0));
        if v_prv = 0 or v_prv > 10 then
          v_prv := to_unsigned(10, 4);
        else
          v_prv := v_prv - 1;
        end if;
        if chain_rst = '1' then
          win_open <= '0';
        elsif pub_stb = '1' and pub_sec = v_prv then
          win_open <= '1';
          if win_opens /= x"FFFF" then
            win_opens <= win_opens + 1;
          end if;
        elsif sync_hit = '1' then
          win_open <= '0';
        end if;

        -- gated interval statistics
        if ((srv_s or ctrl_i(5)) and (win_open or not ctrl_i(4))) = '1' then
          if q_valid = '1' then
            if q_class = "11" then
              if lol_gate /= x"FFFF" then
                lol_gate <= lol_gate + 1;
              end if;
            else
              if gap_cnt /= x"FFFF" then
                gap_cnt <= gap_cnt + 1;
              end if;
              -- signed-error bin: off = e + tol in [0 .. 2*tol], three
              -- successive threshold subtractions = off / (tol/4), which
              -- lands e = -tol in bin 0, e = 0 on the bin 3/4 boundary
              -- and clamps e = +tol into bin 7
              v_tol := resize(q_tol, 17);
              v_off := unsigned(resize(signed(resize(q_e, 17))
                                       + signed(v_tol), 17));
              v_bin := (others => '0');
              if v_off >= v_tol then
                v_off := v_off - v_tol;
                v_bin(2) := '1';
              end if;
              if v_off >= shift_right(v_tol, 1) then
                v_off := v_off - shift_right(v_tol, 1);
                v_bin(1) := '1';
              end if;
              if v_off >= shift_right(v_tol, 2) then
                v_bin(0) := '1';
              end if;
              v_idx := to_integer(q_class) * C_HIST_BINS + to_integer(v_bin);
              if hist(v_idx) /= x"FFFF" then
                hist(v_idx) <= hist(v_idx) + 1;
              end if;
              -- acceptance margin tol - |e| with its context
              if q_e < 0 then
                v_abs := unsigned(resize(-q_e, 16));
              else
                v_abs := unsigned(resize(q_e, 16));
              end if;
              v_mar := resize(q_tol, 16) - v_abs;
              if v_mar < min_margin then
                min_margin <= v_mar;
                min_est    <= q_est;
                min_gap    <= gap_len;
                min_cls    <= q_class;
              end if;
            end if;
          end if;
          if sync_hit = '1' and sync_gate /= x"FFFF" then
            sync_gate <= sync_gate + 1;
          end if;
        end if;

        -- experiment clear (last assignment wins over the updates above)
        if clear_i = '1' then
          win_open   <= '0';
          win_opens  <= (others => '0');
          gap_cnt    <= (others => '0');
          lol_gate   <= (others => '0');
          sync_gate  <= (others => '0');
          min_margin <= (others => '1');
          min_cls    <= "11";
          min_est    <= (others => '0');
          min_gap    <= (others => '0');
          est_min    <= est_q;
          est_max    <= est_q;
          hist       <= (others => (others => '0'));
        end if;
      end if;
    end if;
  end process margin_proc;

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

  -- Sector-header capture. A sync hit (which accompanies its own diag-word
  -- emission) restarts the capture and latches SIDE + /TRK0; each following
  -- word of the DIAGNOSTIC stream fills the live buffer - the sync-anchored
  -- framing keeps the captured words correctly framed even while the SERVED
  -- framing is held across the write splice (in the realign-always arm the
  -- two streams are identical, so nothing changes there).
  -- Storing the last word publishes buffer + flags to the
  -- shadow in the same cycle, so the diag never exposes a torn capture: a
  -- capture cut short by deselect stays unpublished AND is abandoned - the
  -- chain reset parks the write pointer, so the free-running words of the
  -- next selection's pre-sync hunt can never complete a stale buffer into
  -- a mixed-session garbage publish. During a read every
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
        pub_stb       <= '0';
        miss_cnt      <= (others => (others => '0'));
        qual_revs     <= (others => '0');
        rev_chain_ok  <= '0';
        chain_win     <= (others => '0');
      else
        v_pub   := '0';
        pub_stb <= '0';
        if chain_rst = '1' then
          -- abandon a torn capture: without this, the free-running words
          -- of the NEXT selection's pre-sync hunt would complete a stale
          -- mid-capture buffer into a mixed-session garbage publish (one
          -- phantom fmt_bad tick - or worse, a phantom clean publish -
          -- per re-selection that deselected mid-capture)
          cap_wp <= to_unsigned(C_CAP_WORDS, cap_wp'length);
        elsif sync_hit = '1' then
          cap_wp    <= (others => '0');
          cap_side  <= side_s;
          cap_trk0n <= track0_n;
        elsif dword_valid = '1' and cap_wp /= C_CAP_WORDS then
          cap_live(to_integer(cap_wp(2 downto 0))) <= dword_data;
          if cap_wp = C_CAP_WORDS - 1 then
            -- publish: live words 0..N-2 + this word, atomically
            for i in 0 to C_CAP_WORDS - 2 loop
              cap_shad(i) <= cap_live(i);
            end loop;
            cap_shad(C_CAP_WORDS - 1) <= dword_data;
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
          -- per-sector miss profile (diag map v7, re-qualified in v10): a
          -- revolution that captured at least C_MISS_QUAL_CAPS headers AND
          -- kept the decode chain running for its whole index-to-index
          -- window was a read revolution; every sector absent from its
          -- mask is a miss. The chain condition is load-bearing: a
          -- deselect hole inside the window (trackdisk deselects around
          -- every attempt) leaves sectors uncaptured without any flux
          -- fault - the pre-v10 profile counted those as phantom misses
          -- (audit finding). Windows that met the capture floor but lost
          -- the chain are counted separately so the decoder sees how much
          -- was excluded.
          if rev_caps >= C_MISS_QUAL_CAPS then
            if rev_chain_ok = '1' then
              for s in 0 to 10 loop
                if rev_mask(s) = '0' and miss_cnt(s) /= x"FF" then
                  miss_cnt(s) <= miss_cnt(s) + 1;
                end if;
              end loop;
              if qual_revs /= x"FFFF" then
                qual_revs <= qual_revs + 1;
              end if;
            elsif chain_win /= x"FFFF" then
              chain_win <= chain_win + 1;
            end if;
          end if;
          rev_mask_last <= rev_mask;
          rev_caps_last <= rev_caps;
          rev_lol_last  <= rev_lol;
          rev_mask      <= (others => '0');
          rev_caps      <= (others => '0');
          rev_lol       <= (others => '0');
          rev_chain_ok  <= not chain_rst;
        else
          if chain_rst = '1' then
            rev_chain_ok <= '0';
          end if;
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
                -- clean publish towards the armed-sector window logic
                pub_stb <= '1';
                pub_sec <= unsigned(v_sec(3 downto 0));
              end if;
            else
              fmt_bad_cnt <= fmt_bad_cnt + 1;
            end if;
            if rev_caps /= x"FF" then
              rev_caps <= rev_caps + 1;
            end if;
          end if;
        end if;

        -- experiment clear (diag map v7/v10; last assignment wins)
        if clear_i = '1' then
          miss_cnt  <= (others => (others => '0'));
          qual_revs <= (others => '0');
          chain_win <= (others => '0');
        end if;
      end if;
    end if;
  end process cap_proc;

end architecture rtl;
