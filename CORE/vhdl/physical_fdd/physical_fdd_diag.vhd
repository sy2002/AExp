-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_diag: read-only QNICE diagnostic register bank for the
-- physical floppy front-end (device C_DEV_AMIGA_FDD = 0x0104). The only
-- on-hardware instrument for the bring-up (the C64MEGA65 issue-#90 pattern:
-- no scope, no logic analyzer - a register window into the live front-end).
--
-- Every tap comes from physical_fdd_top, which runs in the same 50 MHz QNICE
-- clock domain: no CDC, no tearing. Reads are a plain combinational mux on
-- the word address (QNICE samples on its falling edge; the mux settles well
-- inside the half period). The only writable register is 0x1F (decoded in
-- mega65.vhd); all other writes are ignored.
--
-- Register map (word addresses):
--   0x00  signature 0xFDD0
--   0x01  map version 0x0006 (map identical to 0x0005; the bump marks the
--         build with the serve-from-sync fix in adf_track_engine)
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
-- All counters wrap at 16 bit (diff two reads to rate them).
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity physical_fdd_diag is
  port (
    -- QNICE device interface (word-addressed inside the 4k window)
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
    sideinv_i           : in  std_logic                       -- readback of the 0x1F bit
  );
end entity physical_fdd_diag;

architecture rtl of physical_fdd_diag is
begin

  read_mux : process (all)
  begin
    case qnice_addr_i(5 downto 0) is
      when "000000" => qnice_data_o <= x"FDD0";
      when "000001" => qnice_data_o <= x"0006";
      when "000010" => qnice_data_o <= diag_status_i;
      when "000011" => qnice_data_o <= diag_sync_i;
      when "000100" => qnice_data_o <= x"0" & std_logic_vector(diag_est_i);
      when "000101" => qnice_data_o <= std_logic_vector(resize(diag_fifo_level_i, 16));
      when "000110" => qnice_data_o <= std_logic_vector(diag_index_period_i(15 downto 0));
      when "000111" => qnice_data_o <= std_logic_vector(diag_index_period_i(31 downto 16));
      when "001000" => qnice_data_o <= std_logic_vector(diag_index_width_i(15 downto 0));
      when "001001" => qnice_data_o <= std_logic_vector(diag_index_width_i(31 downto 16));
      when "001010" => qnice_data_o <= std_logic_vector(diag_cnt_index_i);
      when "001011" => qnice_data_o <= std_logic_vector(diag_cnt_sync_i);
      when "001100" => qnice_data_o <= std_logic_vector(diag_cnt_word_i);
      when "001101" => qnice_data_o <= std_logic_vector(diag_cnt_runt_i);
      when "001110" => qnice_data_o <= std_logic_vector(diag_cnt_lol_i);
      when "001111" => qnice_data_o <= std_logic_vector(diag_cnt_drop_i);
      when "010000" => qnice_data_o <= x"000" & '0' & diag_map_i;
      when "010001" => qnice_data_o <= x"00" & "000" & sideinv_i
                                       & diag_cap_flags_i;
      when "010010" => qnice_data_o <= std_logic_vector(diag_cap_count_i);
      when "010011" => qnice_data_o <= diag_cap_words_i(0);
      when "010100" => qnice_data_o <= diag_cap_words_i(1);
      when "010101" => qnice_data_o <= diag_cap_words_i(2);
      when "010110" => qnice_data_o <= diag_cap_words_i(3);
      when "010111" => qnice_data_o <= diag_cap_words_i(4);
      when "011000" => qnice_data_o <= diag_cap_words_i(5);
      when "011001" => qnice_data_o <= diag_cap_words_i(6);
      when "011010" => qnice_data_o <= diag_cap_words_i(7);
      when "011011" => qnice_data_o <= std_logic_vector(diag_served_i);
      when "011100" => qnice_data_o <= "00000" & diag_rev_mask_i;
      when "011101" => qnice_data_o <= std_logic_vector(diag_rev_caps_i)
                                       & std_logic_vector(diag_rev_lol_i);
      when "011110" => qnice_data_o <= std_logic_vector(diag_fmt_bad_i);
      when "011111" => qnice_data_o <= x"000" & "000" & sideinv_i;
      when "100000" => qnice_data_o <= diag_eng_sig_i;
      when "100001" => qnice_data_o <= "0000000" & diag_eng_done_i
                                       & diag_eng_ses_i;
      when "100010" => qnice_data_o <= diag_pau_sig_i;
      when "100011" => qnice_data_o <= "0000000" & diag_pau_ws_i
                                       & diag_pau_att_i;
      when "100100" => qnice_data_o <= diag_eng_c64_i;
      when "100101" => qnice_data_o <= diag_eng_c256_i;
      when "100110" => qnice_data_o <= diag_pau_c64_i;
      when "100111" => qnice_data_o <= diag_pau_c256_i;
      when "101000" => qnice_data_o <= diag_pau_tap_i( 15 downto   0);
      when "101001" => qnice_data_o <= diag_pau_tap_i( 31 downto  16);
      when "101010" => qnice_data_o <= diag_pau_tap_i( 47 downto  32);
      when "101011" => qnice_data_o <= diag_pau_tap_i( 63 downto  48);
      when "101100" => qnice_data_o <= diag_pau_tap_i( 79 downto  64);
      when "101101" => qnice_data_o <= diag_pau_tap_i( 95 downto  80);
      when "101110" => qnice_data_o <= diag_pau_tap_i(111 downto  96);
      when "101111" => qnice_data_o <= diag_pau_tap_i(127 downto 112);
      when others   => qnice_data_o <= x"EEEE";
    end case;
  end process read_mux;

end architecture rtl;
