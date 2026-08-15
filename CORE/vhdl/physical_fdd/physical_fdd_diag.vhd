-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_diag: read-only QNICE diagnostic register bank for the
-- physical floppy front-end (device C_DEV_AMIGA_FDD = 0x0104). The only
-- on-hardware instrument for the bring-up (the C64MEGA65 issue-#90 pattern:
-- no scope, no logic analyzer - a register window into the live front-end).
--
-- Every tap comes from physical_fdd_top, which runs in the same 50 MHz QNICE
-- clock domain: no CDC, no tearing. READS ARE REGISTERED on the falling
-- clock edge (the M2M device convention - the address is guaranteed stable
-- at the falling edge of a bus cycle, exactly what the kick ROM's
-- falling-edge BRAM port and every M2M write register already rely on),
-- so the CPU-facing data path is a plain 16-bit flip-flop instead of the
-- 96-word mux cloud: the mux gets its own half period into one local
-- register bank, and the shared qnice_dev_data_o cone stops carrying it
-- (an R6 build grazed the kick-ROM half-period path through that cone).
-- No wait state is needed - the data source is register-fast, so this is
-- the mount wrapper's WBC-CSR pattern ("plain FFs, no wait states"), not
-- its HyperRAM-window pattern (wait exists there because the data arrives
-- late, which is never the case here). Should the mux ever outgrow the
-- half period, the escalation path is a rising-edge pre-stage plus a
-- one-cycle wait - not needed today by a wide margin.
-- Writable registers (0x1F side-invert, 0x35 margin control) are decoded
-- in mega65.vhd; all other writes are ignored.
--
-- The bank decodes addr[6:0] = 128 words (map v6 decoded only addr[5:0], so
-- old dumps of 0x7040+ were ALIASED re-reads of 0x00+ - the v7 dump range
-- is 0x7000..0x705F with no alias inside it).
--
-- Register map (word addresses), map version 0x000A (v9 layout plus the
-- WORDSYNC-conditional framing hold's control bit and the sync-seam
-- instruments at 0x60..0x6E - the version also identifies the build in
-- field dumps: 0x0007 = A4, 0x0008 = A5 registered readout, 0x0009 = A5
-- with the DPLL separator, 0x000A = the sync-seam fix + instruments):
--   0x00  signature 0xFDD0
--   0x01  map version 0x000A
--   0x02  status: {0:enable 1:selected 2:motor 3:media_ready 4:spun_up
--                  5:index_fresh 6:index_active 7:track0_n 8:wprot_n
--                  9:change_n 10:rdata 11:fifo_full}
--   0x03  DSKSYNC value the bit-aligner uses (settled)
--   0x04  half-cell estimate, Q8.4 (nominal 0x640 = 100.0 cycles)
--   0x05  FIFO fill level (write side, conservative-high)
--   0x06  index period, low word   0x07  index period, high word
--   0x08  index width,  low word   0x09  index width,  high word
--   0x0A  count: accepted index edges
--   0x0B  count: DSKSYNC bit-alignment hits
--   0x0C  count: reconstructed words
--   0x0D  count: merged runt gaps
--   0x0E  count: loss-of-lock events (gap class "11")
--   0x0F  count: words dropped on full FIFO
--   0x10  drive map in force: {0:phys_en, 2:1:phys_unit}
--   0x11  capture flags: {0:valid 1:SIDE at the capture's sync hit ('1' =
--         lower head = even Amiga tracks expected) 2:/TRK0 at the hit
--         3:live SIDE line 4:side-invert in force (readback of 0x1F)}
--   0x12  count: completed sector-header captures
--   0x13..0x1A  capture words 0..7: the 8 reconstructed words following the
--         LAST sync of the double 0x4489 = the MFM-encoded sector info long
--         (words 0..1 odd bits, 2..3 even bits) + the first 4 label words.
--         Decode: odd = (W0<<16)|W1, even = (W2<<16)|W3,
--         info = ((odd AND 0x55555555)<<1) OR (even AND 0x55555555)
--         = 0xFF track sector sectors-to-gap. Track parity vs. flag bit 1
--         is the side-inversion verdict. Dump only while the drive is idle
--         (an active read re-captures every sector).
--   0x1B  count: physical data words SERVED into Paula by the track engine
--         (ST_PHYS_DATA completions; Gray-crossed from the core clock).
--         THE go/no-go observable for the delivery path: the front-end
--         counters (0x0B..0x0C) tick whether or not Paula ever started its
--         DMA - this one only ticks when words actually entered Paula.
--         One trackdisk read = 6400 words; diff two dumps around a scan.
--   0x1C  sector-seen mask of the LAST full revolution (bits 10:0, one per
--         sector number decoded from a clean 0xFF capture that revolution;
--         0x07FF = all 11 sectors present)
--   0x1D  last full revolution: {captures[15:8], losses-of-lock[7:0]}
--         (healthy formatted track: 0x0B01..0x0B02 - 11 captures, splice)
--   0x1E  count: captures whose decoded format byte was not 0xFF (a slow
--         tick is splice noise; per-sector ticking = real corruption)
--   0x1F  WRITE bit 0: side-invert (XORed onto the f_side1 pin in
--         mega65.vhd; power-up/reset = 0). Reads back the bit.
--   0x20  store-signature, ENGINE side: XOR of the first 1024 data words
--         served after the first DSKSYNC word of the last stream session
--         (= the window Paula stores from, since WORDSYNC drops the
--         matching word and stores from the next)
--   0x21  {7'b0, engine-signature done flag, stream-session count[7:0]}
--   0x22  store-signature, PAULA side: XOR of the first 1024 words the
--         real paula_floppy.v wrote into its read FIFO in the last track-
--         read attempt. EQUAL to 0x20 (with 0x21/0x23 counters paired)
--         proves the io channel + store gating word-exact on hardware;
--         a difference is the corruption caught red-handed. Read idle.
--         NOTE: Paula has ONE disk-DMA channel, so the attempt counter
--         (and signature) also advance on ADF-unit reads - only the LAST
--         attempt before an idle dump is compared, and the 0x21/0x23
--         DELTAS across a physical-only workload pair 1:1.
--   0x23  {7'b0, live ADKCON WORDSYNC level, attempt count[7:0]} - the
--         window pairing assumes WORDSYNC=1 (trackdisk standard); bit 8
--         verifies that assumption empirically
--   0x24  engine-signature checkpoint after 64 words
--   0x25  engine-signature checkpoint after 256 words
--   0x26  Paula-signature checkpoint after 64 words
--   0x27  Paula-signature checkpoint after 256 words
--         (first differing pair 0x24/0x26 -> corruption in words 0..63;
--          else 0x25/0x27 -> 64..255; else 0x20/0x22 -> 256..1023)
--   0x28..0x2F  the first 8 words Paula STORED in the last attempt (with
--         WORDSYNC on, word 0 is the second 0x4489 and words 1..4 the
--         encoded info long - directly comparable to the front-end
--         capture at 0x13..0x1A)
--
-- Diag map v7 (2026-08-07 field falsification round - the interval-domain
-- margin instrumentation; design rationale in physical_fdd_top.vhd):
--   0x30  uptime since QNICE reset in MILLISECONDS, low word
--   0x31  uptime, high word. THE dump-freshness proof: two dumps taken at
--         different times can never show the same uptime pair; identical
--         values = the same capture pasted twice (the 2026-08-07 field
--         session delivered 7 byte-identical "dumps" = 2 observations).
--   0x32  dump nonce: increments on every QNICE READ of register 0x00,
--         i.e. once per dump of the bank (the firmware never reads 0x00).
--         Consecutive dumps must differ by exactly the number of dumps
--         taken in between.
--   0x33  count: STEP pulses towards the mechanism (select-gated, wraps)
--   0x34  current cylinder: stepdir-integrated head position, forced to 0
--         while /TRK0 asserts (mechanical ground truth). Together with
--         0x33 this separates seek phases from read phases and shows
--         WHERE the drive is grinding.
--   0x35  WRITE: margin-engine + separator control {15: writing 1 clears
--         every "since clear" statistic (self-clearing strobe; not
--         stored), 7: realign-ALWAYS word framing instead of the
--         WORDSYNC-conditional framing hold (reset default 0 = hold in
--         force; write 0x0080 for the on-hardware A/B against the
--         pre-v10 seam behavior), 6: LEGACY quantiser bit source instead
--         of the DPLL data separator (reset default 0 = DPLL; write
--         0x0040 for the on-hardware A/B against the A4 behavior), 5:
--         histogram ALL gaps (ignore the serve gate), 4: window mode -
--         only inside the armed-sector window, 3..0: armed sector K}.
--         Default 0x0000 = framing hold + DPLL separator + histogram
--         during physical read sessions only. Reads back the stored 8
--         control bits.
--   0x36  minimum acceptance margin tol - |e| since clear, Q4 (sixteenths
--         of a cycle); 0xFFFF = no gap measured yet. tol = est/2, so a
--         margin approaching 0 = a gap ON a classification boundary.
--   0x37  half-cell estimate (Q8.4) at the minimum-margin gap
--   0x38  raw length (50 MHz cycles) of the minimum-margin gap
--   0x39  margin status: {1:0 class of the min-margin gap (0=short 1=medium
--         2=long 3=none yet), 2: armed window open, 3: serving (engine
--         phys_stream, synced), 4: gate currently open}
--   0x3A  count: armed-sector window openings since clear
--   0x3B  count: gaps histogrammed since clear (saturating)
--   0x3C  count: REJECTED gaps (class "11") while the gate was open, since
--         clear (saturating) - the would-be-LOL mass of the gated region
--   0x3D  count: sync hits while the gate was open, since clear
--   0x3E  half-cell estimate minimum since clear (Q8.4)
--   0x3F  half-cell estimate maximum since clear (Q8.4) - 0x3E/0x3F show
--         the estimate excursion (drag) without sampling luck
--   0x40..0x47  SHORT-class histogram, 8 saturating bins of the SIGNED
--         classification error e = G - n*est over [-tol .. +tol), bin
--         width tol/4: bin 0 = e in [-tol,-0.75tol) ... bin 3 ends at 0,
--         bin 4 starts at 0 ... bin 7 = [0.75tol, tol]. A healthy channel
--         concentrates in bins 3/4; mass in 0/7 = gaps at the boundary;
--         a per-class OFFSET pattern is the bias signature (short class
--         centered but medium/long offset = estimate dragged by a
--         short-gap read bias; all classes offset the same way = speed).
--   0x48..0x4F  MEDIUM-class histogram, same binning
--   0x50..0x57  LONG-class histogram, same binning
--   0x58..0x5D  per-sector miss profile: 8-bit saturating counters of
--         "qualified read revolution (>= 8 captures) whose mask lacked
--         sector s", packed two per word (0x58 = {s1,s0}, 0x59 = {s3,s2},
--         ... 0x5D = {0,s10}). THE discriminator between "the decode
--         always fails at one physical spot" and "misses rove".
--   0x5E  count: qualified read revolutions since clear (the miss
--         profile's denominator)
--   0x5F  DPLL cell period, Q8.4 (nominal 0x640 = 100.0 cycles; the
--         separator's tracked half-cell - the analog of the observer
--         quantiser's estimate at 0x04, clamped to the same +/-10%)
--
-- Diag map v10 (the sync-seam fix round - tb_fdd_splice/E2 proved the
-- per-sync realignment turns the write-splice slip into a seam KS1.3
-- trackdisk cannot decode; design rationale in physical_fdd_top.vhd at
-- seam_proc and in physical_fdd_bits.vhd at FRAMING HOLD):
--   0x60  count: mid-serve REALIGN events since clear - sync-window
--         matches landing mid-word (bit phase /= 15) while the engine
--         streams words = framing seams (taken when 0x35 bit 7 = 1,
--         suppressed by the framing hold when 0; counted either way, so
--         A/B dumps compare directly). On a spliced track expect ~1 per
--         gap crossing; 0 on working tracks.
--   0x61  realign context: {15:8 count of events with an ODD bit-phase
--         remainder (8-bit saturating), 3:0 the last event's bit phase}
--   0x62..0x69  pre-sync tap: the 8 words emitted BEFORE the last
--         mid-serve realign event = the [gap run][hybrid word] seam
--         fingerprint, live (compare tb_fdd_splice's seam reports)
--   0x6A  {15:8 serving-session count (wraps; freshness), 7:0 the sector
--         number of the first clean header capture published after the
--         last session entered data streaming = the serve-start sector
--         (the escape-arc observable of audit residue r1; 0xFF = none)}
--   0x6B  count: losses of lock while streaming (serving-data) since clear
--   0x6C  count: losses of lock while NOT streaming since clear (the
--         0x6B/0x6C twins split cnt_lol by workload phase)
--   0x6D  count: index windows that met the miss-profile capture floor
--         but lost the decode chain mid-window (deselect hole) since
--         clear - these windows are EXCLUDED from 0x58..0x5E in v10 (the
--         v7..v9 profile counted them as phantom misses; 0x5E therefore
--         advances only on chain-continuous read revolutions now)
--   0x6E  live framing status: {3: 0x35 bit 7 readback, 2: serving-data
--         (synced), 1: WORDSYNC (synced), 0: framing hold in force}
-- All counters wrap at 16 bit unless marked saturating (diff two reads to
-- rate them). Recommended dump: 0x7000..0x706F (112 words).
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

    -- diag map v7 taps (margin instrumentation in physical_fdd_top)
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

    -- diag map v10 taps (seam instruments in physical_fdd_top)
    diag_realign_i      : in  unsigned(15 downto 0) := (others => '0');
    diag_realign_ctx_i  : in  std_logic_vector(15 downto 0) := (others => '0');
    diag_presync_i      : in  t_fdd_cap_words := (others => (others => '0'));
    diag_srv_sec_i      : in  std_logic_vector(15 downto 0) := x"00FF";
    diag_lol_srv_i      : in  unsigned(15 downto 0) := (others => '0');
    diag_lol_idle_i     : in  unsigned(15 downto 0) := (others => '0');
    diag_chain_win_i    : in  unsigned(15 downto 0) := (others => '0');
    diag_frame_stat_i   : in  std_logic_vector(3 downto 0) := (others => '0')
  );
end entity physical_fdd_diag;

architecture rtl of physical_fdd_diag is

  -- the registered readout: qnice_data_o is this flip-flop bank, nothing
  -- combinational ever reaches the shared device-data cone
  signal data_q : std_logic_vector(15 downto 0) := x"EEEE";

begin

  qnice_data_o <= data_q;

  -- Latched UNCONDITIONALLY on every falling edge: within a read cycle the
  -- address is stable at the falling edge and the CPU consumes the data at
  -- the rising edge that ends the cycle, so the register always holds the
  -- addressed word exactly when it is sampled - the same zero-wait timing
  -- as the kick ROM's falling-edge BRAM port, minus the BRAM clock-to-out
  -- and the die-spread routing. Between accesses the register holds
  -- whatever the floating address selects; nothing consumes it then.
  read_mux : process (qnice_clk_i)
    variable v_addr : unsigned(6 downto 0);
    variable v_data : std_logic_vector(15 downto 0);
  begin
    if falling_edge(qnice_clk_i) then
    v_addr := unsigned(qnice_addr_i(6 downto 0));
    case to_integer(v_addr) is
      when 16#00# => v_data := x"FDD0";
      when 16#01# => v_data := x"000A";
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
      -- diag map v7
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
      -- diag map v10 (sync-seam instruments)
      when 16#60# => v_data := std_logic_vector(diag_realign_i);
      when 16#61# => v_data := diag_realign_ctx_i;
      when 16#62# to 16#69# =>
        v_data := diag_presync_i(to_integer(v_addr) - 16#62#);
      when 16#6A# => v_data := diag_srv_sec_i;
      when 16#6B# => v_data := std_logic_vector(diag_lol_srv_i);
      when 16#6C# => v_data := std_logic_vector(diag_lol_idle_i);
      when 16#6D# => v_data := std_logic_vector(diag_chain_win_i);
      when 16#6E# => v_data := x"000" & diag_frame_stat_i;
      when others => v_data := x"EEEE";
    end case;
    data_q <= v_data;
    end if;
  end process read_mux;

end architecture rtl;
