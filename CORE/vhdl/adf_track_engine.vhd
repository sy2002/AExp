---------------------------------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- adf_track_engine: serves the mounted ADF disk image to Paula's floppy controller
--
-- This FSM replaces MiSTer's ARM-side floppy handler (Main_MiSTer/support/minimig/minimig_fdd.cpp,
-- HandleFDD/ReadTrack/SendSector): it polls Paula's floppy host channel (minimig IO_FPGA frames),
-- announces the disk-present state, fetches the requested track's sectors from the ADF image in
-- HyperRAM, MFM-encodes them bit-exactly like the MiSTer reference, and pushes the words into
-- Paula's 2048x16 FIFO. Read-only: the disk is always reported write-protected; Amiga-initiated
-- writes are drained and discarded so that wprot-ignoring software cannot hang the machine.
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

      -- Minimig floppy host channel (paula_floppy.v IO_ENA = io_fpga)
      io_fpga_o           : out std_logic;                     -- registered - async-clear pin inside Paula!
      io_strobe_o         : out std_logic;                     -- 1 clk pulse per word
      io_din_o            : out std_logic_vector(15 downto 0);
      io_dout_i           : in  std_logic_vector(15 downto 0);
      io_wait_i           : in  std_logic;

      -- ADF image read port: Avalon-MM master into avm_cache (clk_main domain).
      -- Single-word reads with byteenable "11" (required for the cache's prefetch).
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

   type t_state is (
      ST_IDLE,          -- bus released, poll timer running
      ST_ANN_OPEN,      -- drive-status frame: open
      ST_ANN_CLOSE,     -- drive-status frame: close after the single word
      ST_POLL_OPEN,     -- poll frame: open, prepare w0 = 0x0000
      ST_POLL_EVAL0,    -- w0 (status) captured: decide read / write-drain / nothing
      ST_POLL_ARM,      -- benign continuation: w1 + w2 (this is what arms Paula's DMA FSM)
      ST_WDRAIN_HDR,    -- w1 (dsksync, discarded) + w2 (wr_fifo_status) of a drain frame
      ST_WDRAIN_POP,    -- pop FIFO words 3+, discarding io_dout
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

   -- sector buffer: 256x16, byte-swapped to 68k order (even file byte in bits 15:8).
   -- MUST stay LUTRAM (BRAM is full, see CLAUDE.md rule 3).
   type t_secbuf is array (0 to 255) of std_logic_vector(15 downto 0);
   signal secbuf : t_secbuf;
   attribute ram_style : string;
   attribute ram_style of secbuf : signal is "distributed";

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

   avm_write_o      <= '0';
   avm_writedata_o  <= (others => '0');
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

      -- Buffer index for MFM stream word k: the data odd pass starts at word 32,
      -- the even pass at 288. Meaningful only for the data ranges; elsewhere the
      -- wrapped index is harmless (the read result is unused).
      function f_buf_idx(k : unsigned(9 downto 0)) return integer is
         variable idx : unsigned(9 downto 0);
      begin
         if k >= 288 then
            idx := k - 288;
         else
            idx := k - 32;
         end if;
         return to_integer(idx(7 downto 0));
      end function f_buf_idx;

      -- MFM stream word for index k (0..543 sector, 544..893 gap).
      -- bw = secbuf(f_buf_idx(k)), read DIRECTLY at the call sites so that
      -- Vivado sees the standard async-read distributed-RAM template (a RAM
      -- read buried inside this function would risk falling back to 4096 FFs).
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

      variable v_track_req : unsigned(7 downto 0);
      variable v_track_new : unsigned(7 downto 0);
      variable v_byte_hi   : std_logic_vector(7 downto 0);   -- even file byte (68k high)
      variable v_byte_lo   : std_logic_vector(7 downto 0);   -- odd file byte (68k low)

   begin
      if rising_edge(clk_main_i) then

         -- defaults: strobe and done are 1-clk pulses
         io_strobe_o <= '0';
         xfer_done   <= '0';

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
                  -- drive-status word: present = mounted, never writable (read-only MVP)
                  if disk_mounted_i = '1' then
                     io_din_o <= x"1001";
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
                     state_after <= ST_IDLE;
                     io_fpga_o   <= '0';
                     delay_cnt   <= C_GAP_DELAY;
                     state       <= ST_CLOSE;
                  elsif xfer_resp(9) = '1' then
                     -- write requested: drain it (trackwr was 1 at w0, so w1 cannot arm a read)
                     track_valid <= '0';           -- any write invalidates the rotation state
                     hdr_cnt     <= "00";
                     io_din_o    <= x"0000";
                     xfer        <= XF_STROBE;
                     state       <= ST_WDRAIN_HDR;
                  else
                     -- benign continuation w1+w2: word 1 is what arms Paula's DMA FSM
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

            -- write-drain frame: w1 = dsksync (discard), w2 = wr_fifo_status
            when ST_WDRAIN_HDR =>
               if xfer_done = '1' then
                  if hdr_cnt = 0 then
                     hdr_cnt <= "01";
                     xfer    <= XF_STROBE;         -- w2
                  else
                     -- wr_fifo_status = {dmaen&dsklen[14], "000", fifo_cnt[11:0]}
                     if xfer_resp(15) = '0' and xfer_resp(11 downto 0) = x"000" then
                        state_after <= ST_IDLE;    -- write DMA inactive and FIFO empty: done
                        io_fpga_o   <= '0';
                        delay_cnt   <= C_GAP_DELAY;
                        state       <= ST_CLOSE;
                     else
                        -- pop exactly fifo_cnt words (NEVER the raw value: bit 15 is a flag)
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
                     end if;
                  end if;
               end if;

            -- pop and discard write-FIFO words (frame words 3+ return fifo_out)
            when ST_WDRAIN_POP =>
               if xfer_done = '1' then
                  if word_cnt = word_total - 1 then
                     state_after <= ST_POLL_OPEN;  -- immediately re-poll until trackwr clears
                     io_fpga_o   <= '0';
                     delay_cnt   <= C_GAP_DELAY;
                     state       <= ST_CLOSE;
                  else
                     word_cnt <= word_cnt + 1;
                     xfer     <= XF_STROBE;
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
                        sync_word <= f_sync_subst(xfer_resp);
                        hdr_cnt   <= "01";
                        xfer      <= XF_STROBE;    -- w2
                     when others =>                -- w2: {dmaen, dsklen} - discarded
                        word_cnt <= (others => '0');
                        if sector = 10 then
                           word_total <= to_unsigned(C_MFM_SECTOR_WORDS + C_MFM_GAP_WORDS, 10);
                        else
                           word_total <= to_unsigned(C_MFM_SECTOR_WORDS, 10);
                        end if;
                        io_din_o <= f_stream_word(to_unsigned(0, 10),
                                       secbuf(f_buf_idx(to_unsigned(0, 10))));
                        xfer     <= XF_STROBE;
                        state    <= ST_STREAM_DATA;
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
                     word_cnt <= word_cnt + 1;
                     io_din_o <= f_stream_word(word_cnt + 1,
                                    secbuf(f_buf_idx(word_cnt + 1)));
                     xfer     <= XF_STROBE;
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
         -- mid-word is safe - Paula async-clears its receiver state.
         ---------------------------------------------------------------------
         if reset_i = '1' or bus_grant_i = '0'
            or (disk_mounted_i = '0' and (state = ST_SERVE or state = ST_FETCH_ISSUE
                                          or state = ST_FETCH_WAIT)) then
            io_fpga_o   <= '0';
            io_strobe_o <= '0';
            avm_read_o  <= '0';
            xfer        <= XF_IDLE;
            xfer_done   <= '0';
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

end architecture synthesis;
