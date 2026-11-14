-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_diag: the diagnostics register bank of the Hardware Floppy
-- (QNICE device C_DEV_AMIGA_FDD = 0x0104). It is the on-hardware instrument
-- of the feature: a register window into the live front-end, the writer and
-- the engine counters, read from the QNICE monitor without a scope or a logic
-- analyzer. How to read it: doc/developers/hardware-floppy.md, section 8
-- (The diagnostics device); section 12.2 carries the same register map.
--
-- Every tap is in the 50 MHz QNICE clock domain by the time it reaches this
-- bank. Most come from physical_fdd_top; the drive map, the dump nonce and
-- the readbacks of the writable registers 0x1F and 0x35 come from
-- mega65.vhd. The core-clock values (0x1B, the store signatures
-- 0x20..0x2F and the track in 0x79) are crossed in mega65.vhd, and 0x7D in
-- physical_fdd_top. The bank itself therefore needs no CDC, and nothing
-- tears. The readout is
-- registered on the falling clock edge, the M2M device convention: the
-- address is stable at the falling edge of a bus cycle, which the kick ROM's
-- falling-edge BRAM port and every M2M write register rely on as well. The
-- address mux thus gets its own half period into one local register, and the
-- shared qnice_dev_data_o cone sees a plain 16-bit flip-flop. A
-- combinational mux would sit inside that cone, which also carries the
-- kick-ROM half-period path. No wait state is needed because the data source
-- is register-fast: this is the WBC-CSR pattern of adf_mount_wrapper ("plain
-- FFs, no wait states"), not its HyperRAM-window pattern, which waits because
-- its data arrives late. Should the mux ever outgrow the half period, the
-- next step is a rising-edge pre-stage plus a one-cycle wait.
--
-- The bank decodes addr[6:0] (128 words); unmapped addresses read 0xEEEE.
-- The writable registers 0x1F (side invert), 0x35 (control) and 0x7C
-- (precomp mode) are decoded in mega65.vhd; writes to any other address are
-- ignored.
--
-- Register map, version 0x000D. Word addresses; the QNICE monitor sees
-- register n at 0x7000 + n. All counters wrap at 16 bits unless marked
-- saturating; rate them by diffing two dumps. "Since clear" means since the
-- last write of 0x35 with bit 15 set. Recommended dump: 0x7000..0x707D.
--
-- Identity and front-end state
--   0x00  signature 0xFDD0 (every read advances the dump nonce at 0x32)
--   0x01  map version 0x000D
--   0x02  status: {0 enable, 1 selected, 2 motor, 3 media_ready, 4 spun_up,
--         5 index_fresh, 6 index_active, 7 /TRK0, 8 /WPROT, 9 /CHNG,
--         10 RDATA, 11 read FIFO full}
--   0x03  the settled DSKSYNC value the aligner uses
--   0x04  quantiser half-cell estimate, Q8.4 (nominal 0x640 = 100.0 cycles)
--   0x05  read FIFO fill level, seen from its write side (conservative-high)
--   0x06  index period, low word     0x07  index period, high word (cycles)
--   0x08  index low-pulse width, low word
--   0x09  index low-pulse width, high word (cycles)
--   0x0A  accepted index edges
--   0x0B  DSKSYNC alignment hits
--   0x0C  reconstructed words
--   0x0D  merged runt gaps
--   0x0E  losses of lock (gap class "11"; the quantiser reports them in both
--         separator modes)
--   0x0F  words dropped on a full read FIFO
--   0x10  drive map in force: {0 a physical unit exists, 2:1 its unit number}
--
-- Sector-header capture and revolution scoreboard
--   0x11  capture flags: {0 valid, 1 SIDE at the capture's sync hit ('1' =
--         lower head = even Amiga tracks expected), 2 /TRK0 at the hit,
--         3 live SIDE, 4 side invert in force (readback of 0x1F)}
--   0x12  completed sector-header captures
--   0x13..0x1A  capture words 0..7: the eight words that follow the last
--         sync of the double 0x4489 in the sync-anchored diagnostic stream,
--         i.e. the MFM-encoded info long (words 0..1 odd bits, 2..3 even
--         bits) and the first four label words.
--         Decode: odd = (W0<<16)|W1, even = (W2<<16)|W3,
--         info = ((odd AND 0x55555555)<<1) OR (even AND 0x55555555)
--         = 0xFF, track, sector, sectors-to-gap. The parity of the track
--         number against flag bit 1 shows whether the side polarity is
--         right. Dump with the drive idle; an active read re-captures every
--         sector.
--   0x1B  physical data words the track engine served into Paula
--         (ST_PHYS_DATA completions, Gray-crossed from the core clock).
--         The front-end counters 0x0B/0x0C tick whether or not Paula ever
--         started its DMA; this one ticks only for words that entered Paula.
--         A Kickstart 1.3 trackdisk read is 7358 words; diff two dumps
--         around a read.
--   0x1C  sector-seen mask of the last full revolution (bits 10:0, one per
--         sector number decoded from a clean 0xFF capture that revolution;
--         0x07FF = all 11 sectors present)
--   0x1D  last full revolution: {15:8 captures, 7:0 losses of lock}, both
--         8-bit saturating (a healthy formatted track reads 0x0B01..0x0B02:
--         eleven captures, plus the splice)
--   0x1E  captures whose decoded format byte was not 0xFF (a slow tick is
--         splice noise; a tick per sector is real corruption)
--   0x1F  write: bit 0 side invert, XORed onto the f_side1 pin in
--         mega65.vhd (reset 0, the correct polarity for this mechanism);
--         reads back the bit
--
-- Store signatures: is the io channel between engine and Paula word-exact?
--   0x20  engine side: XOR of the first 1024 words served in the last
--         physical stream session, starting with its first DSKSYNC word
--   0x21  {8 engine signature done, 7:0 stream-session count}
--   0x22  Paula side: XOR of the first 1024 words paula_floppy.v wrote into
--         its read FIFO in the last track-read attempt
--   0x23  {8 live ADKCON WORDSYNC, 7:0 track-read attempt count}
--   0x24  engine signature after 64 words    0x25  after 256 words
--   0x26  Paula signature after 64 words     0x27  after 256 words
--   0x28..0x2F  the first eight words Paula stored in the last attempt
--   With WORDSYNC off (0x23 bit 8 = 0, as under Kickstart 1.3 trackdisk)
--   Paula stores from the first served word, which serve-from-sync makes the
--   sync word, so both sides sign the same window: 0x20 equals 0x22 on an
--   intact channel, and the first differing pair of 0x24/0x26, 0x25/0x27,
--   0x20/0x22 brackets the first bad word in 0..63, 64..255 or 256..1023.
--   With WORDSYNC on, Paula drops the matching word and stores from the
--   next, so the two windows are one word apart and the pair does not
--   compare; word 0 of the tap is then the second 0x4489 and words 1..4 hold
--   the info long that 0x13..0x16 capture. Paula has one disk DMA channel,
--   so ADF-unit reads also advance 0x22..0x2F: compare only the last attempt
--   before an idle dump, and pair the 0x21/0x23 deltas only across a
--   workload that reads the physical unit alone.
--
-- Freshness, head position and margin instruments (margin_proc in
-- physical_fdd_top.vhd)
--   0x30  uptime since the QNICE reset in milliseconds, low word
--   0x31  uptime, high word. Two dumps taken at different times never show
--         the same pair, so identical values mean one dump pasted twice.
--   0x32  dump nonce: counts QNICE reads of register 0x00, i.e. one per dump
--         of the bank (the firmware status poll reads only 0x02 and 0x1B).
--         Consecutive dumps differ by the number of dumps taken in between.
--   0x33  STEP pulses towards the mechanism (select-gated)
--   0x34  current cylinder: the step pulses integrated by direction, zeroed
--         on the /TRK0 assert edge. With 0x33 it separates seeks from reads
--         and shows where the drive is working.
--   0x35  write: control {15 clear every "since clear" statistic
--         (self-clearing strobe, not stored), 8 disable the DSKBYTR
--         observation surface in paula_floppy.v and fall back to the
--         constant stub (Copylock titles then hang; the surface lives in the
--         core clock domain and leaves no other trace in this bank),
--         7 realign-always word framing instead of the WORDSYNC-conditional
--         framing hold, 6 legacy quantiser bit source instead of the DPLL
--         data separator, 5 histogram all gaps (ignore the serve gate),
--         4 window mode (histogram only inside the armed-sector window),
--         3..0 armed sector K}. Reset default 0x0000: framing hold, DPLL,
--         histograms during physical read sessions only, surface on. Reads
--         back bits 7:0; bit 8 is not read back.
--   0x36  minimum acceptance margin tol - |e| since clear, Q4 (sixteenths of
--         a cycle; 0xFFFF = no gap measured yet). tol = est/2, so a margin
--         near 0 is a gap on a classification boundary.
--   0x37  half-cell estimate (Q8.4) at the minimum-margin gap
--   0x38  raw length (50 MHz cycles) of the minimum-margin gap
--   0x39  margin status: {1:0 class of the minimum-margin gap (0 short,
--         1 medium, 2 long, 3 none yet), 2 armed window open, 3 serving
--         (engine phys_stream, synchronized), 4 gate open}
--   0x3A  armed-sector window openings since clear (saturating)
--   0x3B  gaps histogrammed since clear (saturating)
--   0x3C  rejected gaps (class "11") while the gate was open, since clear
--         (saturating): the loss-of-lock mass of the gated region
--   0x3D  sync hits while the gate was open, since clear (saturating)
--   0x3E  half-cell estimate minimum since clear (Q8.4)
--   0x3F  half-cell estimate maximum since clear (Q8.4). With 0x3E it shows
--         the estimate excursion (drag) independently of when the dump is
--         taken.
--   0x40..0x47  short-class histogram: 8 saturating bins of the signed
--         classification error e = G - n*est over [-tol .. +tol), bin
--         width tol/4: bin 0 = e in [-tol, -0.75tol) ... bin 3 ends at 0,
--         bin 4 starts at 0 ... bin 7 = [0.75tol, tol]. A healthy channel
--         concentrates in bins 3/4; mass in 0/7 means gaps at the boundary.
--         A per-class offset pattern is the bias signature: a centred short
--         class with offset medium/long classes is an estimate dragged by a
--         short-gap read bias; all classes offset the same way is speed.
--   0x48..0x4F  medium-class histogram, same binning
--   0x50..0x57  long-class histogram, same binning
--   0x58..0x5D  per-sector miss profile: 8-bit saturating counters of
--         "qualified read revolution whose mask lacked sector s", two per
--         word (0x58 = {s1,s0}, 0x59 = {s3,s2}, ... 0x5D = {0,s10}). A
--         qualified read revolution has at least 8 captures and kept the
--         decode chain running for its whole index window. The profile tells
--         "the decode always fails at one physical spot" from "misses rove".
--   0x5E  qualified read revolutions since clear (saturating): the miss
--         profile's denominator
--   0x5F  DPLL cell period, Q8.4 (nominal 0x640 = 100.0 cycles): the
--         separator's tracked half-cell, the counterpart of the quantiser
--         estimate at 0x04 and clamped to the same +/-10%
--
-- Sync-seam instruments (seam_proc in physical_fdd_top.vhd; background in
-- doc/developers/hardware-floppy.md, section 4.4, The aligner and the
-- framing hold)
--   0x60  mid-serve realign events since clear: sync-window matches landing
--         mid-word (bit phase /= 15) while the engine streams words, i.e.
--         framing seams. Taken while the framing hold is off (0x35 bit 7
--         set, or WORDSYNC on), suppressed while it is in force, and counted
--         either way, so dumps of the two framing arms compare directly.
--         Expect about one per splice crossing.
--   0x61  realign context: {15:8 events with an odd bit-phase remainder
--         (8-bit saturating), 3:0 the bit phase of the last event}
--   0x62..0x69  the eight served-stream words emitted before the last
--         mid-serve realign event: the [gap run][hybrid word] fingerprint
--         of the seam
--   0x6A  {15:8 serving-session count (wraps; freshness), 7:0 the sector
--         number of the first clean header capture published after the
--         latest session entered data streaming, i.e. the serve-start
--         sector (0xFF = none since reset or clear; a session without a
--         clean capture leaves the previous value)}
--   0x6B  losses of lock while streaming, since clear
--   0x6C  losses of lock while not streaming, since clear (0x6B and 0x6C
--         split the events of 0x0E by workload phase)
--   0x6D  index windows that met the miss-profile capture floor but lost
--         the decode chain mid-window (a deselect hole), since clear
--         (saturating); these windows are excluded from 0x58..0x5E
--   0x6E  live framing status: {3 0x35 bit 7 readback, 2 serving data
--         (synchronized), 1 WORDSYNC (synchronized), 0 framing hold in force}
--
-- Write instruments (doc/developers/hardware-floppy.md, section 6, The write
-- datapath). All come from physical_fdd_writer in this clock domain, with
-- two exceptions: 0x7D, whose event exists only on the core-clock write
-- side of the write FIFO and is Gray-crossed in physical_fdd_top, and 0x79
-- bits 7:0, the episode track, which the engine latches in the core clock
-- domain and mega65.vhd crosses with a cdc_stable. They count since the
-- QNICE reset; the 0x35 clear does not touch them.
--   0x70  write episodes bound (wraps; freshness)
--   0x71  words consumed by the serializer in the last episode, latched when
--         the writer returns to idle so that the post-DSKBLK tail is
--         included (latching at the trackwr fall would under-report by the
--         in-flight residue)
--   0x72  words consumed, running total
--   0x73  WGATE window of the last episode, low word (50 MHz cycles)
--   0x74  WGATE window, high word. A full trackdisk write is
--         6815 x 16 x 100 = 10,904,000 cycles pin to pin.
--   0x75  underrun aborts
--   0x76  episodes that discarded at arm time because streaming was not
--         allowed: tab qualifier not met, Hardware Floppy disabled, drive
--         deselected, motor off, select settle not complete, or the live
--         tab reading protected; in practice a write to a write-protected
--         disk. trackdisk refuses in software before any DMA, so this stays
--         0 there; X-Copy runs the DMA and ticks it.
--   0x77  {15:8 in-flight words at the DSKBLK moment (FIFO plus shift
--         register, expected <= 3), 7:0 tail cuts: WGATE closed by an abort
--         term during the post-DSKBLK drain}, both for the last episode
--   0x78  precompensated pulses in the last episode
--   0x79  {15:8 flags of the last episode: 8 completed, 9 aborted,
--         10 discarded, 11 underrun, 12 tail cut; 7:0 its Amiga track}
--   0x7A  episodes in which WGATE opened
--   0x7B  abort reason of the last episode, one bit each (0 = no abort):
--         0 deselect, 1 motor or enable lost, 2 write protect, 3 disk
--         change, 4 step, 5 side, 6 underrun, 7 engine abort
--   0x7C  write: {1:0 precomp mode, 00/11 = AUTO (the Kickstart policy,
--         tracks >= 81), 01 = on, 10 = off}; reads back {1:0 mode,
--         2 precomp active now, 3 wr_ok (the tab qualifier), 4 write
--         episode open (synchronized)}
--   0x7D  write-FIFO overflow: engine pushes refused by a full write FIFO.
--         Must read 0, because a refused push is a word missing from the
--         written track; the occupancy bound that keeps it there is in
--         doc/developers/hardware-floppy.md, section 6.1 (The structure,
--         and the elastic-buffer argument).
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity physical_fdd_diag is
  port (
    -- QNICE device interface (word-addressed inside the 4k window; the
    -- readout registers on the falling clock edge - see header)
    qnice_clk_i         : in  std_logic;
    qnice_addr_i        : in  std_logic_vector(27 downto 0);
    qnice_data_o        : out std_logic_vector(15 downto 0);

    -- live taps from physical_fdd_top (same clock domain)
    diag_status_i       : in  std_logic_vector(15 downto 0);
    diag_sync_i         : in  std_logic_vector(15 downto 0);
    diag_est_i          : in  unsigned(11 downto 0);
    diag_fifo_level_i   : in  unsigned(5 downto 0);
    diag_index_period_i : in  unsigned(31 downto 0);
    diag_index_width_i  : in  unsigned(31 downto 0);
    diag_cnt_index_i    : in  unsigned(15 downto 0);
    diag_cnt_sync_i     : in  unsigned(15 downto 0);
    diag_cnt_word_i     : in  unsigned(15 downto 0);
    diag_cnt_runt_i     : in  unsigned(15 downto 0);
    diag_cnt_lol_i      : in  unsigned(15 downto 0);
    diag_cnt_drop_i     : in  unsigned(15 downto 0);
    diag_map_i          : in  std_logic_vector(2 downto 0);  -- {unit[1:0], enable}
    diag_cap_flags_i    : in  std_logic_vector(3 downto 0);  -- {side_live, trk0n, side, valid}
    diag_cap_count_i    : in  unsigned(15 downto 0);
    diag_cap_words_i    : in  t_fdd_cap_words;
    diag_served_i       : in  unsigned(15 downto 0);          -- engine words into Paula (binary,
                                                              -- Gray-synced + decoded in mega65)
    diag_rev_mask_i     : in  std_logic_vector(10 downto 0);
    diag_rev_caps_i     : in  unsigned(7 downto 0);
    diag_rev_lol_i      : in  unsigned(7 downto 0);
    diag_fmt_bad_i      : in  unsigned(15 downto 0);
    diag_eng_sig_i      : in  std_logic_vector(15 downto 0);  -- store-signature pair
    diag_eng_ses_i      : in  std_logic_vector(7 downto 0);   -- (cdc_stable'd in mega65)
    diag_eng_done_i     : in  std_logic;
    diag_pau_sig_i      : in  std_logic_vector(15 downto 0);
    diag_pau_att_i      : in  std_logic_vector(7 downto 0);
    diag_eng_c64_i      : in  std_logic_vector(15 downto 0);  -- checkpoint prefixes
    diag_eng_c256_i     : in  std_logic_vector(15 downto 0);
    diag_pau_c64_i      : in  std_logic_vector(15 downto 0);
    diag_pau_c256_i     : in  std_logic_vector(15 downto 0);
    diag_pau_tap_i      : in  std_logic_vector(127 downto 0); -- first 8 stored words
    diag_pau_ws_i       : in  std_logic;                      -- live WORDSYNC level
    sideinv_i           : in  std_logic;                      -- readback of the 0x1F bit

    -- freshness, head position and margin instrument taps (physical_fdd_top)
    diag_uptime_i       : in  unsigned(31 downto 0);
    diag_nonce_i        : in  unsigned(15 downto 0);          -- counted in mega65 (bus side)
    diag_cnt_step_i     : in  unsigned(15 downto 0);
    diag_cyl_i          : in  unsigned(6 downto 0);
    diag_ctrl_i         : in  std_logic_vector(7 downto 0);   -- readback of the 0x35 bits
    diag_min_margin_i   : in  unsigned(15 downto 0);
    diag_min_est_i      : in  unsigned(11 downto 0);
    diag_min_gap_i      : in  unsigned(15 downto 0);
    diag_margin_stat_i  : in  std_logic_vector(15 downto 0);
    diag_win_opens_i    : in  unsigned(15 downto 0);
    diag_gap_count_i    : in  unsigned(15 downto 0);
    diag_lol_gate_i     : in  unsigned(15 downto 0);
    diag_sync_gate_i    : in  unsigned(15 downto 0);
    diag_est_min_i      : in  unsigned(11 downto 0);
    diag_est_max_i      : in  unsigned(11 downto 0);
    diag_hist_i         : in  t_fdd_hist;
    diag_miss_i         : in  t_fdd_miss;
    diag_qual_revs_i    : in  unsigned(15 downto 0);
    diag_dpll_cell_i    : in  unsigned(11 downto 0);

    -- sync-seam instrument taps (physical_fdd_top)
    diag_realign_i      : in  unsigned(15 downto 0) := (others => '0');
    diag_realign_ctx_i  : in  std_logic_vector(15 downto 0) := (others => '0');
    diag_presync_i      : in  t_fdd_cap_words := (others => (others => '0'));
    diag_srv_sec_i      : in  std_logic_vector(15 downto 0) := x"00FF";
    diag_lol_srv_i      : in  unsigned(15 downto 0) := (others => '0');
    diag_lol_idle_i     : in  unsigned(15 downto 0) := (others => '0');
    diag_chain_win_i    : in  unsigned(15 downto 0) := (others => '0');
    diag_frame_stat_i   : in  std_logic_vector(3 downto 0) := (others => '0');

    -- write instrument taps (physical_fdd_writer, via physical_fdd_top)
    dwr_epi_cnt_i       : in  unsigned(15 downto 0) := (others => '0');
    dwr_words_last_i    : in  unsigned(15 downto 0) := (others => '0');
    dwr_words_tot_i     : in  unsigned(15 downto 0) := (others => '0');
    dwr_wgate_lo_i      : in  unsigned(15 downto 0) := (others => '0');
    dwr_wgate_hi_i      : in  unsigned(15 downto 0) := (others => '0');
    dwr_underrun_i      : in  unsigned(15 downto 0) := (others => '0');
    dwr_discard_i       : in  unsigned(15 downto 0) := (others => '0');
    dwr_tail_i          : in  unsigned(15 downto 0) := (others => '0');
    dwr_precomp_cnt_i   : in  unsigned(15 downto 0) := (others => '0');
    dwr_flags79_i       : in  std_logic_vector(15 downto 0) := (others => '0');
    dwr_gateopen_i      : in  unsigned(15 downto 0) := (others => '0');
    dwr_abortreason_i   : in  std_logic_vector(7 downto 0) := (others => '0');
    dwr_ctrl7c_i        : in  std_logic_vector(4 downto 0) := (others => '0');
    dwr_overflow_i      : in  unsigned(15 downto 0) := (others => '0')
  );
end entity physical_fdd_diag;

architecture rtl of physical_fdd_diag is

  -- the registered readout: qnice_data_o is this flip-flop bank, so nothing
  -- combinational reaches the shared device-data cone
  signal data_q : std_logic_vector(15 downto 0) := x"EEEE";

begin

  qnice_data_o <= data_q;

  -- Latched on every falling edge, unconditionally: within a read cycle the
  -- address is stable at the falling edge and the CPU consumes the data at
  -- the rising edge that ends the cycle, so the register holds the addressed
  -- word whenever it is sampled. This is the zero-wait timing of the kick
  -- ROM's falling-edge BRAM port, without the BRAM clock-to-out and the
  -- die-spread routing. Between accesses the register holds whatever the
  -- floating address selects; nothing consumes it then.
  read_mux : process (qnice_clk_i)
    variable v_addr : unsigned(6 downto 0);
    variable v_data : std_logic_vector(15 downto 0);
  begin
    if falling_edge(qnice_clk_i) then
    v_addr := unsigned(qnice_addr_i(6 downto 0));
    case to_integer(v_addr) is
      when 16#00# => v_data := x"FDD0";
      when 16#01# => v_data := x"000D";
      when 16#02# => v_data := diag_status_i;
      when 16#03# => v_data := diag_sync_i;
      when 16#04# => v_data := x"0" & std_logic_vector(diag_est_i);
      when 16#05# => v_data := std_logic_vector(resize(diag_fifo_level_i, 16));
      when 16#06# => v_data := std_logic_vector(diag_index_period_i(15 downto 0));
      when 16#07# => v_data := std_logic_vector(diag_index_period_i(31 downto 16));
      when 16#08# => v_data := std_logic_vector(diag_index_width_i(15 downto 0));
      when 16#09# => v_data := std_logic_vector(diag_index_width_i(31 downto 16));
      when 16#0A# => v_data := std_logic_vector(diag_cnt_index_i);
      when 16#0B# => v_data := std_logic_vector(diag_cnt_sync_i);
      when 16#0C# => v_data := std_logic_vector(diag_cnt_word_i);
      when 16#0D# => v_data := std_logic_vector(diag_cnt_runt_i);
      when 16#0E# => v_data := std_logic_vector(diag_cnt_lol_i);
      when 16#0F# => v_data := std_logic_vector(diag_cnt_drop_i);
      when 16#10# => v_data := x"000" & '0' & diag_map_i;
      when 16#11# => v_data := x"00" & "000" & sideinv_i
                                     & diag_cap_flags_i;
      when 16#12# => v_data := std_logic_vector(diag_cap_count_i);
      when 16#13# => v_data := diag_cap_words_i(0);
      when 16#14# => v_data := diag_cap_words_i(1);
      when 16#15# => v_data := diag_cap_words_i(2);
      when 16#16# => v_data := diag_cap_words_i(3);
      when 16#17# => v_data := diag_cap_words_i(4);
      when 16#18# => v_data := diag_cap_words_i(5);
      when 16#19# => v_data := diag_cap_words_i(6);
      when 16#1A# => v_data := diag_cap_words_i(7);
      when 16#1B# => v_data := std_logic_vector(diag_served_i);
      when 16#1C# => v_data := "00000" & diag_rev_mask_i;
      when 16#1D# => v_data := std_logic_vector(diag_rev_caps_i)
                                     & std_logic_vector(diag_rev_lol_i);
      when 16#1E# => v_data := std_logic_vector(diag_fmt_bad_i);
      when 16#1F# => v_data := x"000" & "000" & sideinv_i;
      when 16#20# => v_data := diag_eng_sig_i;
      when 16#21# => v_data := "0000000" & diag_eng_done_i
                                     & diag_eng_ses_i;
      when 16#22# => v_data := diag_pau_sig_i;
      when 16#23# => v_data := "0000000" & diag_pau_ws_i
                                     & diag_pau_att_i;
      when 16#24# => v_data := diag_eng_c64_i;
      when 16#25# => v_data := diag_eng_c256_i;
      when 16#26# => v_data := diag_pau_c64_i;
      when 16#27# => v_data := diag_pau_c256_i;
      when 16#28# => v_data := diag_pau_tap_i( 15 downto   0);
      when 16#29# => v_data := diag_pau_tap_i( 31 downto  16);
      when 16#2A# => v_data := diag_pau_tap_i( 47 downto  32);
      when 16#2B# => v_data := diag_pau_tap_i( 63 downto  48);
      when 16#2C# => v_data := diag_pau_tap_i( 79 downto  64);
      when 16#2D# => v_data := diag_pau_tap_i( 95 downto  80);
      when 16#2E# => v_data := diag_pau_tap_i(111 downto  96);
      when 16#2F# => v_data := diag_pau_tap_i(127 downto 112);
      -- freshness, head position, margin instruments
      when 16#30# => v_data := std_logic_vector(diag_uptime_i(15 downto 0));
      when 16#31# => v_data := std_logic_vector(diag_uptime_i(31 downto 16));
      when 16#32# => v_data := std_logic_vector(diag_nonce_i);
      when 16#33# => v_data := std_logic_vector(diag_cnt_step_i);
      when 16#34# => v_data := std_logic_vector(resize(diag_cyl_i, 16));
      when 16#35# => v_data := x"00" & diag_ctrl_i;
      when 16#36# => v_data := std_logic_vector(diag_min_margin_i);
      when 16#37# => v_data := x"0" & std_logic_vector(diag_min_est_i);
      when 16#38# => v_data := std_logic_vector(diag_min_gap_i);
      when 16#39# => v_data := diag_margin_stat_i;
      when 16#3A# => v_data := std_logic_vector(diag_win_opens_i);
      when 16#3B# => v_data := std_logic_vector(diag_gap_count_i);
      when 16#3C# => v_data := std_logic_vector(diag_lol_gate_i);
      when 16#3D# => v_data := std_logic_vector(diag_sync_gate_i);
      when 16#3E# => v_data := x"0" & std_logic_vector(diag_est_min_i);
      when 16#3F# => v_data := x"0" & std_logic_vector(diag_est_max_i);
      when 16#40# to 16#57# =>
        v_data := std_logic_vector(diag_hist_i(to_integer(v_addr) - 16#40#));
      when 16#58# to 16#5D# =>
        v_data := diag_miss_i(to_integer(v_addr) - 16#58#);
      when 16#5E# => v_data := std_logic_vector(diag_qual_revs_i);
      when 16#5F# => v_data := x"0" & std_logic_vector(diag_dpll_cell_i);
      -- sync-seam instruments
      when 16#60# => v_data := std_logic_vector(diag_realign_i);
      when 16#61# => v_data := diag_realign_ctx_i;
      when 16#62# to 16#69# =>
        v_data := diag_presync_i(to_integer(v_addr) - 16#62#);
      when 16#6A# => v_data := diag_srv_sec_i;
      when 16#6B# => v_data := std_logic_vector(diag_lol_srv_i);
      when 16#6C# => v_data := std_logic_vector(diag_lol_idle_i);
      when 16#6D# => v_data := std_logic_vector(diag_chain_win_i);
      when 16#6E# => v_data := x"000" & diag_frame_stat_i;
      -- write instruments
      when 16#70# => v_data := std_logic_vector(dwr_epi_cnt_i);
      when 16#71# => v_data := std_logic_vector(dwr_words_last_i);
      when 16#72# => v_data := std_logic_vector(dwr_words_tot_i);
      when 16#73# => v_data := std_logic_vector(dwr_wgate_lo_i);
      when 16#74# => v_data := std_logic_vector(dwr_wgate_hi_i);
      when 16#75# => v_data := std_logic_vector(dwr_underrun_i);
      when 16#76# => v_data := std_logic_vector(dwr_discard_i);
      when 16#77# => v_data := std_logic_vector(dwr_tail_i);
      when 16#78# => v_data := std_logic_vector(dwr_precomp_cnt_i);
      when 16#79# => v_data := dwr_flags79_i;
      when 16#7A# => v_data := std_logic_vector(dwr_gateopen_i);
      when 16#7B# => v_data := x"00" & dwr_abortreason_i;
      when 16#7C# => v_data := "00000000000" & dwr_ctrl7c_i;
      when 16#7D# => v_data := std_logic_vector(dwr_overflow_i);
      when others => v_data := x"EEEE";
    end case;
    data_q <= v_data;
    end if;
  end process read_mux;

end architecture rtl;
