---------------------------------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- adf_track_engine: serves the mounted ADF disk image to Paula's floppy controller
--
-- This FSM replaces MiSTer's ARM-side floppy handler (Main_MiSTer/support/minimig/minimig_fdd.cpp,
-- HandleFDD/ReadTrack/SendSector/WriteTrack): it polls Paula's floppy host channel (minimig
-- IO_FPGA frames), announces the disk-present state, fetches the requested track's sectors from
-- the ADF image in HyperRAM, MFM-encodes them bit-exactly like the MiSTer reference, and pushes
-- the words into Paula's 2048x16 FIFO. Amiga-initiated writes are drained through the MFM write
-- decoder (bit-exact FindSync/GetHeader/GetData): verified sectors are committed back into the
-- HyperRAM image and the track is queued as dirty towards the QNICE firmware, which flushes it
-- to the SD card in the background (see adf_mount_wrapper.vhd and
-- .research/INTEGRATION-SPEC-floppy-adf-write.md). When write-back is not armed (write_en_i='0'),
-- the disk is announced write-protected and writes are drained and DISCARDED, so that
-- wprot-ignoring software cannot hang the machine.
--
-- The full protocol contract (verified against rtl/paula_floppy.v) and the design rationale live
-- in .research/INTEGRATION-SPEC-floppy-adf.md. The essentials this implementation relies on:
--
--   * A frame = io_fpga high; words = 1-clk io_strobe pulses; Paula's word counter saturates at 3
--     and async-clears when io_fpga drops. Word/response pairs: w0 -> status
--     {sel[1:0],drives[1:0],"00",trackwr,trackrd&~fifo_cnt[10],track[7:0]}, w1 -> dsksync,
--     w2 -> {dmaen,dsklen[14:0]} (read) / wr_fifo_status (write), w3+ -> FIFO data words.
--   * Per-word handshake: strobe only while io_wait=0, hold io_din until io_wait falls (Paula
--     samples io_din 1-2 clk7 phases AFTER the strobe), io_dout for word N is valid when io_wait
--     falls. io_wait rises only 1 clk after the strobe - wait for the rise before the fall.
--   * Paula's disk-DMA FSM only leaves IDLE at word 1 of a frame - polling is what starts DMA,
--     and the arming poll itself still reports the stale trackrd=0.
--   * Flow control is status bit 8 alone (masked while the FIFO holds >= 1024 words): push at
--     most one sector (+ track gap) per re-poll; io_wait does NOT protect against FIFO overflow.
--   * The drive-status command (w0 = 0x1000|flags) must be a strict ONE-word frame (its bit
--     pattern also sets Paula's cmd_fdd), and disk_present is wiped by every Amiga reset
--     including Kickstart's RESET instruction - so it is re-sent every poll cycle (MiSTer does
--     the same on every poll loop).
--
-- Runs entirely in the clk_main (28.375 MHz) domain - the same clock as minimig. No clk7_en
-- needed: Paula's io_wait handshake encapsulates the clk7 pacing.
--
-- MiSTer2MEGA65 (AExp Amiga 500 port) done in July 2026 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adf_track_engine is
   generic (
      -- HyperRAM word base address of the ADF image = C_HMAP_ADF_DF0(9 downto 0) & X"000"
      G_BASE_ADDRESS : std_logic_vector(21 downto 0);

      -- clk_main cycles between poll cycles (~1 ms; FIFO drain pacing makes polling
      -- faster than ~0.1 ms pointless, see the spec's bandwidth math)
      G_POLL_DELAY   : natural := 28374
   );
   port (
      clk_main_i          : in  std_logic;                     -- 28.375 MHz core clock (= minimig clk)
      reset_i             : in  std_logic;                     -- M2M core reset (amiga_rst)

      -- Bus grant: amiga_config has finished its config replay (its cpu_reset_done_o).
      -- The engine owns the shared IO_STROBE/IO_DIN bus only while this is high.
      bus_grant_i         : in  std_logic;

      -- Mount status from adf_mount_wrapper (CDC'd to clk_main in mega65.vhd)
      disk_mounted_i      : in  std_logic;
      disk_tracks_i       : in  std_logic_vector(7 downto 0);  -- 160..166

      -- Write-back armed by the firmware (WBC WR_EN, CDC'd like the mount
      -- status): announce the disk writable and commit decoded sectors
      write_en_i          : in  std_logic;

      -- Dirty-track event channel towards adf_mount_wrapper (two-phase toggle
      -- handshake; the cdc_stable instances live in mega65.vhd)
      wr_track_o          : out std_logic_vector(7 downto 0);
      wr_req_o            : out std_logic;                     -- toggle
      wr_ack_i            : in  std_logic;                     -- toggle (CDC'd)

      -- Minimig floppy host channel (paula_floppy.v IO_ENA = io_fpga)
      io_fpga_o           : out std_logic;                     -- registered - async-clear pin inside Paula!
      io_strobe_o         : out std_logic;                     -- 1 clk pulse per word
      io_din_o            : out std_logic_vector(15 downto 0);
      io_dout_i           : in  std_logic_vector(15 downto 0);
      io_wait_i           : in  std_logic;

      -- ADF image port: Avalon-MM master into avm_cache (clk_main domain).
      -- Single-word reads and writes with byteenable "11" (single-word is
      -- required for the cache's prefetch AND for its write-hit line update).
      avm_write_o         : out std_logic;
      avm_read_o          : out std_logic;
      avm_address_o       : out std_logic_vector(31 downto 0);
      avm_writedata_o     : out std_logic_vector(15 downto 0);
      avm_byteenable_o    : out std_logic_vector( 1 downto 0);
      avm_burstcount_o    : out std_logic_vector( 7 downto 0);
      avm_readdata_i      : in  std_logic_vector(15 downto 0);
      avm_readdatavalid_i : in  std_logic;
      avm_waitrequest_i   : in  std_logic
   );
end entity adf_track_engine;

architecture synthesis of adf_track_engine is

   -- Amiga DD geometry (fixed): 11 sectors x 512 bytes per track, tracks 0..165 max
   constant C_WORDS_PER_SECTOR  : natural := 256;   -- 512 bytes = 256 HyperRAM words
   constant C_TRACK_WORDS       : natural := 2816;  -- 5632 bytes / 2

   -- MFM stream word counts (bit-exact minimig_fdd.cpp layout)
   constant C_MFM_SECTOR_WORDS  : natural := 544;
   constant C_MFM_GAP_WORDS     : natural := 350;

   -- inter-frame gap and frame-open setup, in clk_main cycles (Paula needs 1; be generous)
   constant C_GAP_DELAY         : natural := 15;

   -- MFM write-decode section lengths (bit-exact minimig_fdd.cpp WriteTrack):
   -- header = 2nd sync + 4 info + 16 label + 4 stored-checksum words (GetHeader
   -- needs >= 25 buffered, :337); data = 4 stored-checksum + 256 odd + 256 even
   -- words (GetData needs >= 0x204, :469). A section is only consumed once
   -- Paula's FIFO holds ALL of it - no mid-section starvation handling needed.
   constant C_HDR_WORDS         : natural := 25;
   constant C_DATA_WORDS        : natural := 516;

   type t_state is (
      ST_IDLE,          -- bus released, poll timer running
      ST_ANN_OPEN,      -- drive-status frame: open
      ST_ANN_CLOSE,     -- drive-status frame: close after the single word
      ST_POLL_OPEN,     -- poll frame: open, prepare w0 = 0x0000
      ST_POLL_EVAL0,    -- w0 (status) captured: decide read / write-drain / nothing
      ST_POLL_ARM,      -- benign continuation: w1 + w2 (this is what arms Paula's DMA FSM)
      ST_WDRAIN_HDR,    -- w1 (dsksync, discarded) + w2 (wr_fifo_status) of a drain frame
      ST_WDRAIN_POP,    -- pop FIFO words 3+ and feed them to the MFM write decoder
      ST_WCOMMIT_ADDR,  -- commit decoded sector to HyperRAM: prime the buffer read
      ST_WCOMMIT_READ,  -- buffer read data settling
      ST_WCOMMIT_ISSUE, -- issue one avm write word
      ST_SERVE,         -- decide start sector for the requested track
      ST_FETCH_ISSUE,   -- Avalon read command for one word of the sector
      ST_FETCH_WAIT,    -- wait for readdatavalid, store into the sector buffer
      ST_STREAM_OPEN,   -- sector frame: open, w0 = status re-check
      ST_STREAM_HDR,    -- w1 = dsksync (live, substituted), w2 = discarded
      ST_STREAM_DATA,   -- 544 MFM words (+ 350 gap words after sector 10)
      ST_CLOSE          -- drop io_fpga, inter-frame gap, dispatch to next state
   );
   signal state        : t_state := ST_IDLE;
   signal state_after  : t_state := ST_IDLE;   -- where ST_CLOSE dispatches to

   -- word-transfer sub-FSM (one 16-bit word over the io bus)
   type t_xfer is (XF_IDLE, XF_STROBE, XF_WAIT_RISE, XF_WAIT_FALL);
   signal xfer         : t_xfer := XF_IDLE;
   signal xfer_done    : std_logic;                     -- 1-clk pulse: word complete, response valid
   signal xfer_resp    : std_logic_vector(15 downto 0); -- response for the completed word

   -- multi-purpose counters
   signal delay_cnt    : natural range 0 to G_POLL_DELAY := 0;
   signal word_cnt     : unsigned(9 downto 0);          -- stream/pop word index
   signal word_total   : unsigned(9 downto 0);          -- words to stream/pop in this frame
   signal hdr_cnt      : unsigned(1 downto 0);          -- w1/w2 sub-count

   -- captured Paula state
   signal status       : std_logic_vector(15 downto 0);
   signal sync_word    : std_logic_vector(15 downto 0); -- live dsksync after substitution

   -- disk service state
   signal track_eff    : unsigned(7 downto 0);          -- clamped requested track
   signal track_prev   : unsigned(7 downto 0);
   signal track_valid  : std_logic;                     -- track_prev holds a real value
   signal sector       : unsigned(3 downto 0);          -- 0..10
   signal sector_next  : unsigned(3 downto 0);          -- rotation continuation
   signal fetch_idx    : unsigned(7 downto 0);          -- 0..255 word within the sector

   -- data checksum lanes (accumulated during fetch)
   signal dc0, dc1, dc2, dc3 : std_logic_vector(7 downto 0);

   -- MFM write decoder (bit-exact minimig_fdd.cpp FindSync/GetHeader/GetData).
   -- MiSTer parity: the write path syncs on the LITERAL 0x4489 - the read
   -- path's dsksync substitution does NOT apply here (FindSync :307).
   -- Three deliberate, reviewed deviations, all no-ops for valid sectors:
   -- (1) header track <= 159 (cpp :381) is replaced by the commit-time checks
   --     header==physical AND physical < tracks_total (writable overdumps);
   -- (2) a bad header is rejected after all 25 header words (the cpp aborts
   --     after 5 and re-hunts through label/cksum words - both converge on
   --     the next true sync, ours drains more cleanly);
   -- (3) stored-checksum lanes are compared in full (the cpp drops lane 1's
   --     odd bits, a one-lane typo at :473 that cannot matter: valid Amiga
   --     checksums only ever carry 0x55-masked bits) - garbage the cpp would
   --     accept is rejected here, never committed, always drained.
   -- MiSTer-parity hang note: a write whose dsklen ends mid-section freezes
   -- both implementations in the section-admission re-poll (Paula holds
   -- dmaen, DSKBLK needs an empty FIFO) - unreachable via trackdisk, and an
   -- Amiga warm boot recovers it (reset aborts the drain) exactly like on
   -- MiSTer.
   type t_wd_mode is (WD_HUNT, WD_HDR, WD_DATA);
   signal wd_mode      : t_wd_mode := WD_HUNT;
   signal in_drain     : std_logic := '0';             -- decoder state is live
   signal wr_track_lat : unsigned(7 downto 0);         -- physical track at drain entry
   signal wd_idx       : unsigned(9 downto 0);         -- word index within a section
   signal winf_odd     : std_logic_vector(31 downto 0);-- info odd bytes: fmt,trk,sec,gap
   signal whd_fmt      : std_logic_vector(7 downto 0); -- decoded header: format (0xFF)
   signal whd_track    : std_logic_vector(7 downto 0); -- decoded header: track
   signal whd_sector   : unsigned(7 downto 0);         -- decoded header: sector (0..10)
   signal whd_gap      : unsigned(7 downto 0);         -- decoded header: sectors to gap
   signal wck0, wck1, wck2, wck3 : std_logic_vector(7 downto 0);  -- computed cksum lanes
   signal wst0, wst1, wst2, wst3 : std_logic_vector(7 downto 0);  -- stored cksum lanes

   -- dirty-track bookkeeping + event scanner (see p_dirty_scan)
   signal dirty_pend      : std_logic_vector(165 downto 0) := (others => '0');
   signal dirty_set_valid : std_logic := '0';
   signal dirty_set_track : unsigned(7 downto 0);
   type t_scan is (SC_SCAN, SC_SETTLE, SC_WAIT);
   signal scan_state   : t_scan := SC_SCAN;
   signal scan_idx     : unsigned(7 downto 0) := (others => '0');
   signal settle_cnt   : unsigned(4 downto 0);
   signal wr_req       : std_logic := '0';

   -- sector buffer: 256x16, byte-swapped to 68k order (even file byte in bits 15:8).
   -- MUST stay LUTRAM (BRAM is full, see CLAUDE.md rule 3). Accessed ONLY via the
   -- textbook simple-dual-port template (one sync write in ST_FETCH_WAIT, one
   -- unconditional registered read through secbuf_raddr/secbuf_q at the top of
   -- fsm_proc) - anything fancier makes Vivado fall back to 4096 flip-flops
   -- (Synth 8-7186 "not inferred as ram due to incorrect usage", seen in R3
   -- synthesis run 3 with a read expression at the io_din_o assignment sites).
   type t_secbuf is array (0 to 255) of std_logic_vector(15 downto 0);
   signal secbuf       : t_secbuf;
   signal secbuf_raddr : unsigned(7 downto 0);           -- primed one word ahead
   signal secbuf_q     : std_logic_vector(15 downto 0);  -- registered read data
   attribute ram_style : string;
   attribute ram_style of secbuf : signal is "distributed";

   -- decoded write-sector buffer: 256x16 in 68k byte order (even file byte in
   -- bits 15:8), byte-swapped back to HyperRAM packing at commit time. Same
   -- strict LUTRAM template and rules as secbuf (BRAM is full, rule 3): one
   -- muxed sync write, one unconditional registered read via wrbuf_raddr/
   -- wrbuf_q primed one word ahead (the even-bits pass is a read-modify-write
   -- combine, the commit pass streams the buffer to HyperRAM).
   type t_wrbuf is array (0 to 255) of std_logic_vector(15 downto 0);
   signal wrbuf        : t_wrbuf;
   signal wrbuf_raddr  : unsigned(7 downto 0);
   signal wrbuf_q      : std_logic_vector(15 downto 0);
   attribute ram_style of wrbuf : signal is "distributed";

   -- MFM byte helpers (minimig_fdd.cpp SendSector)
   function f_mfm_odd(b : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      return ('0' & b(7 downto 1)) or x"AA";             -- (b >> 1) | 0xAA
   end function f_mfm_odd;

   function f_mfm_even(b : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      return b or x"AA";                                 -- b | 0xAA
   end function f_mfm_even;

   -- info-longword bytes (NO clock fill - the only stream words without |0xAA)
   signal inf_t_odd, inf_t_even : std_logic_vector(7 downto 0);   -- track
   signal inf_s_odd, inf_s_even : std_logic_vector(7 downto 0);   -- sector
   signal inf_g_odd, inf_g_even : std_logic_vector(7 downto 0);   -- sectors until gap (11-sector)
   signal hc1, hc2, hc3         : std_logic_vector(7 downto 0);   -- header checksum (hc0 = 0 always)

begin

   avm_byteenable_o <= "11";
   avm_burstcount_o <= x"01";

   -- info bytes and header checksum, combinational from track_eff/sector.
   -- sug = 11 - sector (sector 0 -> 11 ... sector 10 -> 1) fits in 4 bits.
   p_info : process (all)
      variable t   : std_logic_vector(7 downto 0);
      variable s   : std_logic_vector(7 downto 0);
      variable sug : std_logic_vector(7 downto 0);
   begin
      t   := std_logic_vector(track_eff);
      s   := std_logic_vector(resize(sector, 8));
      sug := std_logic_vector(resize(11 - sector, 8));
      inf_t_odd  <= ('0' & t(7 downto 1)) and x"55";
      inf_t_even <= t and x"55";
      inf_s_odd  <= ('0' & s(7 downto 1)) and x"55";
      inf_s_even <= s and x"55";
      inf_g_odd  <= ('0' & sug(7 downto 1)) and x"55";
      inf_g_even <= sug and x"55";
   end process p_info;

   -- header checksum bytes = XOR of the two transmitted bytes per lane;
   -- lane 0 is 0x55 xor 0x55 = 0 always
   hc1 <= inf_t_odd xor inf_t_even;
   hc2 <= inf_s_odd xor inf_s_even;
   hc3 <= inf_g_odd xor inf_g_even;

   fsm_proc : process (clk_main_i)

      -- Buffer read address for MFM stream word k: the data odd pass starts at
      -- word 32, the even pass at 288. Meaningful only for the data ranges;
      -- elsewhere the wrapped address is harmless (the read result is unused).
      function f_buf_idx(k : unsigned(9 downto 0)) return unsigned is
         variable idx : unsigned(9 downto 0);
      begin
         if k >= 288 then
            idx := k - 288;
         else
            idx := k - 32;
         end if;
         return idx(7 downto 0);
      end function f_buf_idx;

      -- MFM stream word for index k (0..543 sector, 544..893 gap).
      -- bw = the sector-buffer word for k, delivered via the registered read
      -- port (secbuf_q, address primed one word ahead - see secbuf's comment).
      -- Still impure: reads the per-sector scalars sync_word/inf_*/hc*/dc*.
      impure function f_stream_word(k  : unsigned(9 downto 0);
                                    bw : std_logic_vector(15 downto 0))
                                    return std_logic_vector is
         variable w : std_logic_vector(15 downto 0);
      begin
         case to_integer(k) is
            when 0 | 1  => w := x"AAAA";                                  -- preamble
            when 2 | 3  => w := sync_word;                                -- 2x DSKSYNC
            when 4      => w := x"55" & inf_t_odd;                        -- info odd
            when 5      => w := inf_s_odd & inf_g_odd;
            when 6      => w := x"55" & inf_t_even;                       -- info even
            when 7      => w := inf_s_even & inf_g_even;
            when 8 to 23  => w := x"AAAA";                                -- label
            when 24 | 25  => w := x"AAAA";                                -- hdr cksum odd half (0)
            when 26     => w := x"AA" & (hc1 or x"AA");                   -- hc0|AA = AA
            when 27     => w := (hc2 or x"AA") & (hc3 or x"AA");
            when 28 | 29  => w := x"AAAA";                                -- data cksum odd half (0)
            when 30     => w := (dc0 or x"AA") & (dc1 or x"AA");
            when 31     => w := (dc2 or x"AA") & (dc3 or x"AA");
            when 32 to 287 =>                                             -- data odd bits
               w := f_mfm_odd(bw(15 downto 8)) & f_mfm_odd(bw(7 downto 0));
            when 288 to 543 =>                                            -- data even bits
               w := f_mfm_even(bw(15 downto 8)) & f_mfm_even(bw(7 downto 0));
            when others => w := x"AAAA";                                  -- track gap
         end case;
         return w;
      end function f_stream_word;

      -- dsksync substitution (minimig_fdd.cpp Copy Lock workaround)
      function f_sync_subst(s : std_logic_vector(15 downto 0)) return std_logic_vector is
      begin
         if s = x"0000" or s = x"8914" or s = x"A144" then
            return x"4489";
         else
            return s;
         end if;
      end function f_sync_subst;

      -- MFM decode: recombine an odd-bits byte and an even-bits byte into the
      -- data byte, ((odd & 0x55) << 1) | (even & 0x55) - minimig_fdd.cpp
      -- GetHeader :347-377. (b & 0x55) << 1 equals (b << 1) & 0xAA.
      function f_mfm_dec(o : std_logic_vector(7 downto 0);
                         e : std_logic_vector(7 downto 0)) return std_logic_vector is
      begin
         return ((o(6 downto 0) & '0') and x"AA") or (e and x"55");
      end function f_mfm_dec;

      variable v_track_req : unsigned(7 downto 0);
      variable v_track_new : unsigned(7 downto 0);
      variable v_byte_hi   : std_logic_vector(7 downto 0);   -- even file byte (68k high)
      variable v_byte_lo   : std_logic_vector(7 downto 0);   -- odd file byte (68k low)

      -- write-decoder scratch
      variable v_hi        : std_logic_vector(7 downto 0);   -- popped word, high byte
      variable v_lo        : std_logic_vector(7 downto 0);   -- popped word, low byte
      variable v_close     : std_logic;                      -- close the drain frame
      variable v_need      : natural range 0 to 1023;        -- section admission size
      variable v_k         : unsigned(7 downto 0);           -- data word index 0..255
      variable v_st2, v_st3            : std_logic_vector(7 downto 0);
      variable v_ck0, v_ck1, v_ck2, v_ck3 : std_logic_vector(7 downto 0);

   begin
      if rising_edge(clk_main_i) then

         -- defaults: strobe, done and the dirty-event pulse are 1-clk pulses
         io_strobe_o     <= '0';
         xfer_done       <= '0';
         dirty_set_valid <= '0';

         -- sector-buffer read ports: unconditional registered reads (the strict
         -- simple-dual-port LUTRAM template; do not condition or relocate these)
         secbuf_q <= secbuf(to_integer(secbuf_raddr));
         wrbuf_q  <= wrbuf(to_integer(wrbuf_raddr));

         ---------------------------------------------------------------------
         -- word-transfer sub-FSM: XF_STROBE is entered by the main FSM below
         -- (io_din_o must be set on the same edge or earlier)
         ---------------------------------------------------------------------
         case xfer is
            when XF_IDLE =>
               null;
            when XF_STROBE =>
               io_strobe_o <= '1';                 -- 1 clk wide; io_wait is 0 here by protocol
               xfer        <= XF_WAIT_RISE;
            when XF_WAIT_RISE =>                   -- io_wait rises 1 clk after the strobe
               if io_wait_i = '1' then
                  xfer <= XF_WAIT_FALL;
               end if;
            when XF_WAIT_FALL =>                   -- io_dout is the response once io_wait falls
               if io_wait_i = '0' then
                  xfer_resp <= io_dout_i;
                  xfer_done <= '1';
                  xfer      <= XF_IDLE;
               end if;
         end case;

         ---------------------------------------------------------------------
         -- main FSM
         ---------------------------------------------------------------------
         case state is

            -- bus released; wait for the poll timer, then run one poll cycle
            when ST_IDLE =>
               io_fpga_o <= '0';
               if delay_cnt /= 0 then
                  delay_cnt <= delay_cnt - 1;
               elsif bus_grant_i = '1' then
                  io_fpga_o <= '1';
                  -- drive-status word: present = mounted; writable only while
                  -- the firmware has write-back armed (WBC WR_EN). Re-sent
                  -- every poll cycle - Paula wipes it on every Amiga reset.
                  if disk_mounted_i = '1' then
                     if write_en_i = '1' then
                        io_din_o <= x"1011";
                     else
                        io_din_o <= x"1001";
                     end if;
                  else
                     io_din_o <= x"1000";
                  end if;
                  delay_cnt <= C_GAP_DELAY;
                  state     <= ST_ANN_OPEN;
               end if;

            -- strict ONE-word frame (the 0x1xxx pattern also sets Paula's cmd_fdd)
            when ST_ANN_OPEN =>
               if delay_cnt /= 0 then
                  delay_cnt <= delay_cnt - 1;      -- frame-open setup
               elsif xfer = XF_IDLE and xfer_done = '0' then
                  xfer  <= XF_STROBE;
                  state <= ST_ANN_CLOSE;
               end if;

            when ST_ANN_CLOSE =>
               if xfer_done = '1' then
                  state_after <= ST_POLL_OPEN;
                  io_fpga_o   <= '0';
                  delay_cnt   <= C_GAP_DELAY;
                  state       <= ST_CLOSE;
               end if;

            -- poll frame: w0 = 0x0000, response = status word
            when ST_POLL_OPEN =>
               if delay_cnt /= 0 then
                  delay_cnt <= delay_cnt - 1;
               else
                  io_fpga_o <= '1';                -- (re)open; io_din = command 0x0000
                  io_din_o  <= x"0000";
                  if io_fpga_o = '1' and xfer = XF_IDLE and xfer_done = '0' then
                     xfer  <= XF_STROBE;
                     state <= ST_POLL_EVAL0;
                  end if;
               end if;

            -- status captured. Decide BEFORE strobing word 1 (ordering matters for
            -- the write-drain: see the spec's WDRAIN race analysis)
            when ST_POLL_EVAL0 =>
               if xfer_done = '1' then
                  status <= xfer_resp;
                  if xfer_resp(15 downto 14) /= "00" then
                     -- df1..df3 selected: not ours - leave the request pending (MiSTer-identical)
                     in_drain    <= '0';
                     state_after <= ST_IDLE;
                     io_fpga_o   <= '0';
                     delay_cnt   <= C_GAP_DELAY;
                     state       <= ST_CLOSE;
                  elsif xfer_resp(9) = '1' then
                     -- write requested: drain it (trackwr was 1 at w0, so w1 cannot arm a read)
                     track_valid <= '0';           -- any write invalidates the rotation state
                     if in_drain = '1' and wd_mode = WD_HUNT
                        and unsigned(xfer_resp(7 downto 0)) /= wr_track_lat then
                        -- head stepped while hunting: end this drain pass
                        -- (FindSync :294-295); re-entered with the new track
                        -- on the next poll. Only the HUNT phase track-checks -
                        -- GetHeader/GetData don't (MiSTer parity).
                        in_drain    <= '0';
                        state_after <= ST_IDLE;
                        io_fpga_o   <= '0';
                        delay_cnt   <= C_GAP_DELAY;
                        state       <= ST_CLOSE;
                     else
                        if in_drain = '0' then
                           -- fresh drain: latch the physical track (MiSTer:
                           -- drive->track = c2) and re-arm the decoder
                           in_drain     <= '1';
                           wd_mode      <= WD_HUNT;
                           wr_track_lat <= unsigned(xfer_resp(7 downto 0));
                        end if;
                        hdr_cnt  <= "00";
                        io_din_o <= x"0000";
                        xfer     <= XF_STROBE;
                        state    <= ST_WDRAIN_HDR;
                     end if;
                  else
                     -- benign continuation w1+w2: word 1 is what arms Paula's DMA FSM
                     in_drain <= '0';              -- no write pending: decoder state is stale
                     hdr_cnt  <= "00";
                     io_din_o <= x"0000";
                     xfer     <= XF_STROBE;
                     state    <= ST_POLL_ARM;
                  end if;
               end if;

            -- w1 (arms the FSM when the CPU has a request pending) and w2, then close.
            -- If w0 showed a read request, serve it after the frame closes.
            when ST_POLL_ARM =>
               if xfer_done = '1' then
                  if hdr_cnt = 0 then
                     hdr_cnt <= "01";
                     xfer    <= XF_STROBE;         -- w2 (response discarded)
                  else
                     if status(8) = '1' and disk_mounted_i = '1'
                        and unsigned(disk_tracks_i) /= 0 then   -- /=0 guaranteed by the
                        state_after <= ST_SERVE;                -- validator; belt-and-braces
                     else                                       -- for the tracks-1 clamp
                        state_after <= ST_IDLE;
                     end if;
                     io_fpga_o <= '0';
                     delay_cnt <= C_GAP_DELAY;
                     state     <= ST_CLOSE;
                  end if;
               end if;

            -- write-drain frame: w1 = dsksync (discard - the write decoder syncs
            -- on the LITERAL 0x4489, MiSTer parity), w2 = wr_fifo_status
            when ST_WDRAIN_HDR =>
               if xfer_done = '1' then
                  if hdr_cnt = 0 then
                     hdr_cnt <= "01";
                     xfer    <= XF_STROBE;         -- w2
                  else
                     -- wr_fifo_status = {dmaen&dsklen[14], "000", fifo_cnt[11:0]}
                     if xfer_resp(15) = '0' and xfer_resp(11 downto 0) = x"000" then
                        in_drain    <= '0';        -- write DMA inactive and FIFO empty: done
                        state_after <= ST_IDLE;
                        io_fpga_o   <= '0';
                        delay_cnt   <= C_GAP_DELAY;
                        state       <= ST_CLOSE;
                     elsif wd_mode = WD_HUNT then
                        -- pop up to fifo_cnt words hunting for the sync word
                        -- (NEVER the raw value: bit 15 is a flag)
                        word_cnt   <= (others => '0');
                        word_total <= resize(unsigned(xfer_resp(9 downto 0)), 10);
                        if unsigned(xfer_resp(11 downto 0)) > 1000 then
                           word_total <= to_unsigned(1000, 10);  -- chunk large drains
                        end if;
                        if unsigned(xfer_resp(11 downto 0)) = 0 then
                           -- DMA active but nothing buffered yet: re-poll
                           state_after <= ST_POLL_OPEN;
                           io_fpga_o   <= '0';
                           delay_cnt   <= C_GAP_DELAY;
                           state       <= ST_CLOSE;
                        else
                           io_din_o <= x"0000";
                           xfer     <= XF_STROBE;
                           state    <= ST_WDRAIN_POP;
                        end if;
                     else
                        -- header/data section: consume it only when Paula's
                        -- FIFO already buffers the WHOLE section (the MiSTer
                        -- discipline - GetHeader :337, GetData :469)
                        if wd_mode = WD_HDR then
                           v_need := C_HDR_WORDS;
                        else
                           v_need := C_DATA_WORDS;
                        end if;
                        if unsigned(xfer_resp(11 downto 0)) >= v_need then
                           wd_idx     <= (others => '0');
                           word_total <= to_unsigned(v_need, 10);
                           io_din_o   <= x"0000";
                           xfer       <= XF_STROBE;
                           state      <= ST_WDRAIN_POP;
                        else
                           if xfer_resp(15) = '0' then
                              -- write DMA over, section incomplete (MiSTer
                              -- Errors 20/28): re-hunt; leftovers drain there
                              wd_mode <= WD_HUNT;
                           end if;
                           state_after <= ST_POLL_OPEN;  -- FIFO still filling
                           io_fpga_o   <= '0';
                           delay_cnt   <= C_GAP_DELAY;
                           state       <= ST_CLOSE;
                        end if;
                     end if;
                  end if;
               end if;

            -- pop write-FIFO words (frame words 3+ return fifo_out) and feed
            -- them to the MFM write decoder (bit-exact minimig_fdd.cpp:
            -- FindSync hunt / GetHeader / GetData with byte-lane checksums;
            -- checksum lanes alternate 0/1 and 2/3 per word)
            when ST_WDRAIN_POP =>
               if xfer_done = '1' then
                  v_hi    := xfer_resp(15 downto 8);
                  v_lo    := xfer_resp( 7 downto 0);
                  v_close := '0';

                  case wd_mode is

                     when WD_HUNT =>
                        if xfer_resp = x"4489" then
                           wd_mode <= WD_HDR;       -- sync found: close the
                           v_close := '1';          -- frame (FindSync :307-310)
                           state_after <= ST_POLL_OPEN;
                        elsif word_cnt = word_total - 1 then
                           v_close := '1';          -- chunk done: re-poll
                           state_after <= ST_POLL_OPEN;
                        else
                           word_cnt <= word_cnt + 1;
                           xfer     <= XF_STROBE;
                        end if;

                     when WD_HDR =>
                        case to_integer(wd_idx) is
                           when 0 =>                -- second sync word
                              if xfer_resp /= x"4489" then
                                 wd_mode <= WD_HUNT;      -- MiSTer Error 21
                                 v_close := '1';
                                 state_after <= ST_POLL_OPEN;
                              end if;
                           when 1 =>                -- info odd 1: format, track
                              winf_odd(31 downto 16) <= xfer_resp;
                              wck0 <= v_hi;         -- lanes START here (assign)
                              wck1 <= v_lo;
                           when 2 =>                -- info odd 2: sector, gap
                              winf_odd(15 downto 0) <= xfer_resp;
                              wck2 <= v_hi;
                              wck3 <= v_lo;
                           when 3 =>                -- info even 1
                              whd_fmt   <= f_mfm_dec(winf_odd(31 downto 24), v_hi);
                              whd_track <= f_mfm_dec(winf_odd(23 downto 16), v_lo);
                              wck0 <= wck0 xor v_hi;
                              wck1 <= wck1 xor v_lo;
                           when 4 =>                -- info even 2
                              whd_sector <= unsigned(f_mfm_dec(winf_odd(15 downto 8), v_hi));
                              whd_gap    <= unsigned(f_mfm_dec(winf_odd( 7 downto 0), v_lo));
                              wck2 <= wck2 xor v_hi;
                              wck3 <= wck3 xor v_lo;
                           when 5 to 20 =>          -- 16 label words
                              if wd_idx(0) = '1' then
                                 wck0 <= wck0 xor v_hi;
                                 wck1 <= wck1 xor v_lo;
                              else
                                 wck2 <= wck2 xor v_hi;
                                 wck3 <= wck3 xor v_lo;
                              end if;
                           when 21 =>               -- stored cksum, odd half
                              wst0 <= (v_hi(6 downto 0) & '0') and x"AA";
                              wst1 <= (v_lo(6 downto 0) & '0') and x"AA";
                           when 22 =>
                              wst2 <= (v_hi(6 downto 0) & '0') and x"AA";
                              wst3 <= (v_lo(6 downto 0) & '0') and x"AA";
                           when 23 =>               -- stored cksum, even half
                              wst0 <= wst0 or (v_hi and x"55");
                              wst1 <= wst1 or (v_lo and x"55");
                           when others =>           -- 24: last word + evaluate
                              v_st2 := wst2 or (v_hi and x"55");
                              v_st3 := wst3 or (v_lo and x"55");
                              -- header validation (GetHeader :379-386, :426):
                              -- format 0xFF, sector 0..10, gap 1..11, checksum.
                              -- The track itself is validated at commit time
                              -- against the PHYSICAL track and the image size
                              -- (deliberate deviation from MiSTer's <=159
                              -- limit, which would break writes on our
                              -- accepted 160..166-track overdumps).
                              if whd_fmt = x"FF"
                                 and whd_sector <= 10
                                 and whd_gap >= 1 and whd_gap <= 11
                                 and (wck0 and x"55") = wst0
                                 and (wck1 and x"55") = wst1
                                 and (wck2 and x"55") = v_st2
                                 and (wck3 and x"55") = v_st3 then
                                 wd_mode <= WD_DATA;
                              else
                                 wd_mode <= WD_HUNT;      -- MiSTer Errors 22-26
                              end if;
                              v_close := '1';
                              state_after <= ST_POLL_OPEN;
                        end case;
                        if v_close = '0' then
                           wd_idx <= wd_idx + 1;
                           xfer   <= XF_STROBE;
                        end if;

                     when WD_DATA =>
                        case to_integer(wd_idx) is
                           when 0 =>                -- stored data cksum, odd half
                              wst0 <= (v_hi(6 downto 0) & '0') and x"AA";
                              wst1 <= (v_lo(6 downto 0) & '0') and x"AA";
                           when 1 =>
                              wst2 <= (v_hi(6 downto 0) & '0') and x"AA";
                              wst3 <= (v_lo(6 downto 0) & '0') and x"AA";
                           when 2 =>                -- stored data cksum, even half
                              wst0 <= wst0 or (v_hi and x"55");
                              wst1 <= wst1 or (v_lo and x"55");
                           when 3 =>
                              wst2 <= wst2 or (v_hi and x"55");
                              wst3 <= wst3 or (v_lo and x"55");
                              wck0 <= (others => '0');    -- restart lanes for
                              wck1 <= (others => '0');    -- the data field
                              wck2 <= (others => '0');
                              wck3 <= (others => '0');
                           when 4 to 259 =>         -- odd-bits pass
                              v_k := resize(wd_idx - 4, 8);
                              wrbuf(to_integer(v_k)) <=
                                 (xfer_resp(14 downto 0) & '0') and x"AAAA";
                              if v_k(0) = '0' then
                                 wck0 <= wck0 xor v_hi;
                                 wck1 <= wck1 xor v_lo;
                              else
                                 wck2 <= wck2 xor v_hi;
                                 wck3 <= wck3 xor v_lo;
                              end if;
                              if wd_idx = 259 then
                                 wrbuf_raddr <= (others => '0');  -- prime RMW
                              end if;
                           when others =>           -- 260..515: even-bits pass
                              v_k := resize(wd_idx - 260, 8);
                              wrbuf(to_integer(v_k)) <= wrbuf_q or (xfer_resp and x"5555");
                              wrbuf_raddr <= v_k + 1;             -- prime next
                              if v_k(0) = '0' then
                                 wck0 <= wck0 xor v_hi;
                                 wck1 <= wck1 xor v_lo;
                              else
                                 wck2 <= wck2 xor v_hi;
                                 wck3 <= wck3 xor v_lo;
                              end if;
                              if wd_idx = 515 then
                                 -- data checksum verify (GetData :532-541) +
                                 -- commit gate: header track must equal the
                                 -- physical track (MiSTer Error 27 /
                                 -- WriteTrack :572), the physical track must
                                 -- be inside the image, and write-back must
                                 -- be armed on a mounted disk. Failing
                                 -- sectors are drained but never committed
                                 -- (MiSTer drains protected writes the same
                                 -- way, :581-589).
                                 v_ck0 := wck0 and x"55";
                                 v_ck1 := wck1 and x"55";
                                 v_ck2 := (wck2 xor v_hi) and x"55";
                                 v_ck3 := (wck3 xor v_lo) and x"55";
                                 if v_ck0 = wst0 and v_ck1 = wst1
                                    and v_ck2 = wst2 and v_ck3 = wst3
                                    and whd_track = std_logic_vector(wr_track_lat)
                                    and wr_track_lat < unsigned(disk_tracks_i)
                                    and write_en_i = '1' and disk_mounted_i = '1' then
                                    fetch_idx   <= (others => '0');  -- commit index
                                    state_after <= ST_WCOMMIT_ADDR;
                                 else
                                    state_after <= ST_POLL_OPEN;
                                 end if;
                                 wd_mode <= WD_HUNT;
                                 v_close := '1';
                              end if;
                        end case;
                        if v_close = '0' then
                           wd_idx <= wd_idx + 1;
                           xfer   <= XF_STROBE;
                        end if;

                  end case;

                  if v_close = '1' then
                     io_fpga_o <= '0';
                     delay_cnt <= C_GAP_DELAY;
                     state     <= ST_CLOSE;
                  end if;
               end if;

            -- commit the decoded, verified sector into the ADF image in
            -- HyperRAM: 256 single-word avm writes through the same cache/CDC
            -- chain the reads use (avm_cache is write-through and updates its
            -- line on write hits, so subsequent reads stay coherent). The
            -- frame is closed; Paula's write FIFO keeps filling from DMA
            -- meanwhile (~21 us/word against our ~0.1 us/word commits).
            when ST_WCOMMIT_ADDR =>
               wrbuf_raddr <= fetch_idx;
               state       <= ST_WCOMMIT_READ;

            when ST_WCOMMIT_READ =>                 -- wrbuf_q settles
               state <= ST_WCOMMIT_ISSUE;

            when ST_WCOMMIT_ISSUE =>
               avm_write_o     <= '1';
               -- byte-swap back to HyperRAM packing (even file byte in 7:0)
               avm_writedata_o <= wrbuf_q(7 downto 0) & wrbuf_q(15 downto 8);
               avm_address_o   <= std_logic_vector(
                                    resize(unsigned(G_BASE_ADDRESS), 32)
                                    + resize(wr_track_lat * to_unsigned(C_TRACK_WORDS, 12), 32)
                                    + resize(whd_sector(3 downto 0) * to_unsigned(C_WORDS_PER_SECTOR, 9), 32)
                                    + resize(fetch_idx, 32));
               if avm_write_o = '1' and avm_waitrequest_i = '0' then
                  avm_write_o <= '0';
                  if fetch_idx = C_WORDS_PER_SECTOR - 1 then
                     dirty_set_valid <= '1';        -- sector is in HyperRAM:
                     dirty_set_track <= wr_track_lat;  -- queue the dirty track
                     delay_cnt       <= C_GAP_DELAY;
                     state           <= ST_POLL_OPEN;  -- drain on (next sector)
                  else
                     fetch_idx <= fetch_idx + 1;
                     state     <= ST_WCOMMIT_ADDR;
                  end if;
               end if;

            -- read service: clamp the requested track, pick the start sector
            when ST_SERVE =>
               v_track_req := unsigned(status(7 downto 0));
               if v_track_req >= unsigned(disk_tracks_i) then
                  v_track_req := unsigned(disk_tracks_i) - 1;
               end if;
               track_eff <= v_track_req;
               if track_valid = '0' or v_track_req /= track_prev then
                  sector      <= (others => '0'); -- track change: restart at sector 0
                  sector_next <= (others => '0');
                  track_prev  <= v_track_req;
                  track_valid <= '1';
               else
                  sector <= sector_next;          -- same track: rotation continuation
               end if;
               fetch_idx <= (others => '0');
               dc0 <= (others => '0');
               dc1 <= (others => '0');
               dc2 <= (others => '0');
               dc3 <= (others => '0');
               state <= ST_FETCH_ISSUE;

            -- fetch the sector into the buffer, one word at a time (avm_cache
            -- turns the sequential single-word reads into 8-word HyperRAM bursts)
            when ST_FETCH_ISSUE =>
               avm_read_o    <= '1';
               avm_address_o <= std_logic_vector(
                                  resize(unsigned(G_BASE_ADDRESS), 32)
                                  + resize(track_eff * to_unsigned(C_TRACK_WORDS, 12), 32)
                                  + resize(sector * to_unsigned(C_WORDS_PER_SECTOR, 9), 32)
                                  + resize(fetch_idx, 32));
               if avm_read_o = '1' and avm_waitrequest_i = '0' then
                  avm_read_o <= '0';
                  state      <= ST_FETCH_WAIT;
               end if;

            when ST_FETCH_WAIT =>
               if avm_readdatavalid_i = '1' then
                  -- HyperRAM word: even file byte in bits 7:0 - swap to 68k order
                  v_byte_hi := avm_readdata_i( 7 downto 0);
                  v_byte_lo := avm_readdata_i(15 downto 8);
                  secbuf(to_integer(fetch_idx)) <= v_byte_hi & v_byte_lo;
                  -- data checksum: dc[lane] ^= b ^ (b>>1), lane = byte offset mod 4
                  if fetch_idx(0) = '0' then
                     dc0 <= dc0 xor v_byte_hi xor ('0' & v_byte_hi(7 downto 1));
                     dc1 <= dc1 xor v_byte_lo xor ('0' & v_byte_lo(7 downto 1));
                  else
                     dc2 <= dc2 xor v_byte_hi xor ('0' & v_byte_hi(7 downto 1));
                     dc3 <= dc3 xor v_byte_lo xor ('0' & v_byte_lo(7 downto 1));
                  end if;
                  if fetch_idx = C_WORDS_PER_SECTOR - 1 then
                     delay_cnt <= C_GAP_DELAY;
                     state     <= ST_STREAM_OPEN;
                  else
                     fetch_idx <= fetch_idx + 1;
                     state     <= ST_FETCH_ISSUE;
                  end if;
               end if;

            -- sector frame: re-check status (w0) before pushing anything
            when ST_STREAM_OPEN =>
               if delay_cnt /= 0 then
                  delay_cnt <= delay_cnt - 1;
               else
                  io_fpga_o <= '1';
                  io_din_o  <= x"0000";
                  if io_fpga_o = '1' and xfer = XF_IDLE and xfer_done = '0' then
                     xfer  <= XF_STROBE;
                     state <= ST_STREAM_HDR;
                     hdr_cnt <= "10";              -- expecting w0 next
                  end if;
               end if;

            -- w0 = status re-check, w1 = live dsksync, w2 = discarded
            when ST_STREAM_HDR =>
               if xfer_done = '1' then
                  case hdr_cnt is
                     when "10" =>                  -- w0: status
                        v_track_new := unsigned(xfer_resp(7 downto 0));
                        if v_track_new >= unsigned(disk_tracks_i) then
                           v_track_new := unsigned(disk_tracks_i) - 1;
                        end if;
                        if xfer_resp(15 downto 14) /= "00" or xfer_resp(8) = '0'
                           or xfer_resp(9) = '1' or disk_mounted_i = '0'
                           or unsigned(disk_tracks_i) = 0 then
                           -- aborted / throttled / direction change: back to polling
                           state_after <= ST_IDLE;
                           io_fpga_o   <= '0';
                           delay_cnt   <= C_GAP_DELAY;
                           state       <= ST_CLOSE;
                        elsif v_track_new /= track_eff then
                           -- head stepped while we fetched: serve the new track
                           status      <= xfer_resp;
                           state_after <= ST_SERVE;
                           io_fpga_o   <= '0';
                           delay_cnt   <= C_GAP_DELAY;
                           state       <= ST_CLOSE;
                        else
                           hdr_cnt  <= "00";
                           io_din_o <= x"0000";
                           xfer     <= XF_STROBE;  -- w1
                        end if;
                     when "00" =>                  -- w1: dsksync
                        sync_word    <= f_sync_subst(xfer_resp);
                        secbuf_raddr <= f_buf_idx(to_unsigned(0, 10));   -- prime word 0
                        hdr_cnt      <= "01";
                        xfer         <= XF_STROBE; -- w2
                     when others =>                -- w2: {dmaen, dsklen} - discarded
                        word_cnt <= (others => '0');
                        if sector = 10 then
                           word_total <= to_unsigned(C_MFM_SECTOR_WORDS + C_MFM_GAP_WORDS, 10);
                        else
                           word_total <= to_unsigned(C_MFM_SECTOR_WORDS, 10);
                        end if;
                        io_din_o     <= f_stream_word(to_unsigned(0, 10), secbuf_q);
                        secbuf_raddr <= f_buf_idx(to_unsigned(1, 10));   -- prime word 1
                        xfer         <= XF_STROBE;
                        state        <= ST_STREAM_DATA;
                  end case;
               end if;

            -- push the MFM words (Paula ignores anything beyond dsklen - harmless)
            when ST_STREAM_DATA =>
               if xfer_done = '1' then
                  if word_cnt = word_total - 1 then
                     sector_next <= (sector + 1) mod 11;
                     state_after <= ST_SERVE;      -- next sector (re-checks status first)
                     io_fpga_o   <= '0';
                     delay_cnt   <= C_GAP_DELAY;
                     state       <= ST_CLOSE;
                  else
                     word_cnt     <= word_cnt + 1;
                     io_din_o     <= f_stream_word(word_cnt + 1, secbuf_q);
                     secbuf_raddr <= f_buf_idx(word_cnt + 2);    -- prime next word
                     xfer         <= XF_STROBE;
                  end if;
               end if;

            -- io_fpga just dropped: enforce the inter-frame gap, then dispatch.
            -- Returning to ST_IDLE restarts the full poll period.
            when ST_CLOSE =>
               io_fpga_o <= '0';
               if delay_cnt /= 0 then
                  delay_cnt <= delay_cnt - 1;
               else
                  if state_after = ST_IDLE then
                     delay_cnt <= G_POLL_DELAY;
                  else
                     delay_cnt <= C_GAP_DELAY;
                  end if;
                  state <= state_after;
               end if;

         end case;

         ---------------------------------------------------------------------
         -- abort dominates everything: core reset, config replay running, or
         -- (outside the mount-status frames) a vanished disk. Dropping io_fpga
         -- mid-word is safe - Paula async-clears its receiver state. A commit
         -- must abort on unmount too: the next mount's SD streaming owns
         -- HyperRAM then. dirty_pend and the event scanner are deliberately
         -- NOT touched - dirty state survives an Amiga reboot (a sector cut
         -- short here stays un-flagged: HyperRAM keeps the torn sector, the
         -- SD keeps the old consistent one - same as real hardware losing
         -- power mid-write).
         ---------------------------------------------------------------------
         if reset_i = '1' or bus_grant_i = '0'
            or (disk_mounted_i = '0' and (state = ST_SERVE or state = ST_FETCH_ISSUE
                                          or state = ST_FETCH_WAIT
                                          or state = ST_WCOMMIT_ADDR
                                          or state = ST_WCOMMIT_READ
                                          or state = ST_WCOMMIT_ISSUE)) then
            io_fpga_o   <= '0';
            io_strobe_o <= '0';
            avm_read_o  <= '0';
            avm_write_o <= '0';
            xfer        <= XF_IDLE;
            xfer_done   <= '0';
            in_drain    <= '0';
            wd_mode     <= WD_HUNT;
            state       <= ST_IDLE;
            delay_cnt   <= G_POLL_DELAY;
            if reset_i = '1' then
               track_valid <= '0';
               sector_next <= (others => '0');
            end if;
         end if;

         -- a fresh mount always restarts the rotation state
         if disk_mounted_i = '0' then
            track_valid <= '0';
         end if;

      end if;
   end process fsm_proc;

   ---------------------------------------------------------------------------
   -- dirty-track event scanner: dirty_pend collects committed tracks; the
   -- walking scanner delivers them one at a time to the QNICE-domain bitmap
   -- in adf_mount_wrapper via a two-phase toggle handshake - payload first,
   -- then (after a settle delay far longer than the cdc_stable latency) the
   -- req toggle; the ack toggle returns the same way. The cdc_stable
   -- instances live in mega65.vhd. The pending bit is cleared BEFORE the
   -- handshake starts, so a re-dirty during the handshake raises a fresh
   -- event - no coalescing loss. Deliberately free of reset_i: dirty state
   -- must survive an Amiga reboot (the SD flush continues right through it).
   ---------------------------------------------------------------------------
   wr_req_o <= wr_req;

   p_dirty_scan : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         case scan_state is
            when SC_SCAN =>
               if dirty_pend(to_integer(scan_idx)) = '1' then
                  wr_track_o <= std_logic_vector(scan_idx);
                  dirty_pend(to_integer(scan_idx)) <= '0';
                  settle_cnt <= (others => '1');     -- 31 clks >> CDC latency
                  scan_state <= SC_SETTLE;
               elsif scan_idx = 165 then
                  scan_idx <= (others => '0');
               else
                  scan_idx <= scan_idx + 1;
               end if;

            when SC_SETTLE =>                        -- payload settles at the
               settle_cnt <= settle_cnt - 1;         -- far side of the CDC
               if settle_cnt = 0 then
                  wr_req     <= not wr_req;
                  scan_state <= SC_WAIT;
               end if;

            when SC_WAIT =>
               if wr_ack_i = wr_req then
                  scan_state <= SC_SCAN;             -- re-checks the same index
               end if;                               -- first (re-dirty case)
         end case;

         -- a commit in the same cycle wins over the scanner's clear
         if dirty_set_valid = '1' then
            dirty_pend(to_integer(dirty_set_track)) <= '1';
         end if;
      end if;
   end process p_dirty_scan;

end architecture synthesis;
