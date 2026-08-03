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
-- doc/developers/floppy-adf.md). When write-back is not armed (write_en_i='0'),
-- the disk is announced write-protected and writes are drained and DISCARDED, so that
-- wprot-ignoring software cannot hang the machine.
--
-- The full protocol contract (verified against rtl/paula_floppy.v) and the design rationale live
-- in doc/developers/floppy-adf.md. The essentials this implementation relies on:
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
-- MULTIPLE DRIVE UNITS. The engine serves up to three Amiga units df0/df1/df2 over the same host
-- channel, dispatching per poll on the status word's sel bits [15:14]. The drive index IS the
-- Amiga unit number; the OSM Drive Settings submenu decides what each unit is:
--   * adf_en_i(u) = '1'   -> a simulated ADF drive: HyperRAM fetch from that unit's own pool,
--     MFM encode, write decode and commit back into that same pool;
--   * phys_en_i = '1' and sel = phys_unit_i -> the MEGA65's real internal mechanism (at most
--     ONE unit): reconstructed MFM words from physical_fdd_top's word FIFO are streamed to
--     Paula AT REAL DISK PACE (~1 word/32 us - the words originate from live flux, so pacing is
--     inherent; flow-control bit 8 can never engage). The requested track in the status word is
--     IGNORED: data comes from wherever the real head is, in rotation order, exactly like a real
--     Amiga. The live DSKSYNC (response word 1) is exported RAW to the front-end bit-aligner
--     (dsksync_o) - no Copy Lock substitution: the real disk contains whatever sync the loader
--     programmed, which is precisely what the aligner hunts.
--   * neither -> the unit does not exist and its polls are ignored.
--
-- UNIT OWNERSHIP is the load-bearing invariant of the multi-drive engine, because all the
-- expensive state - the sector buffers, the write decoder, the Avalon master - exists only once
-- and is time-shared between the units:
--   * serve_unit is latched from the status word at the poll that accepted the request and is
--     what the read service (fetch address, track clamp, mid-stream abort check) uses. Paula
--     binds trackrd to one unit for a whole DMA, so re-deriving it later would be wrong.
--   * drain_unit is latched when a write drain starts and is what the commit address, the
--     commit gates and the dirty-track event use. The moment a poll reports a DIFFERENT unit,
--     the drain is aborted in EVERY decoder phase, not just while hunting: a frame belonging to
--     unit B fed into a decoder opened for unit A would checksum-verify and commit into unit A's
--     image. That is the one defect class that silently corrupts a disk image.
--   * Writes towards the physical unit are drained and DISCARDED (read-only milestone; the unit
--     is announced write-protected): drain_commit is only set for a drain owned by a simulated
--     drive, and it gates the sync hunt, so a physical-unit drain can never decode at all.
--   * Rotation continuation (track_prev / track_valid / sector_next) is PER UNIT: two drives
--     stepping and reading in alternation must not inherit each other's sector position.
--   * The 0x1nnn drive-status announce carries per-unit nibbles: each simulated drive's
--     present/writable from its own mount status, the physical unit's presence from the real
--     disk-change latch.
--   * While idle, the engine drains and discards the physical word FIFO (words decoded while
--     the drive spins without a pending DMA), keeping the stream fresh.
--
-- Runs entirely in the clk_main (28.375 MHz) domain - the same clock as minimig. No clk7_en
-- needed: Paula's io_wait handshake encapsulates the clk7 pacing.
--
-- MiSTer2MEGA65 (AExp Amiga 500 port) done by sy2002 in July 2026 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adf_track_engine is
   generic (
      -- HyperRAM word base address of each drive's ADF image pool
      -- (C_HMAP_ADF_DF<n>(9 downto 0) & X"000" from globals.vhd)
      G_BASE_DF0     : std_logic_vector(21 downto 0);
      G_BASE_DF1     : std_logic_vector(21 downto 0);
      G_BASE_DF2     : std_logic_vector(21 downto 0);

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

      -- Mount status of the three simulated drives, from their adf_mount_wrapper
      -- instances (CDC'd to clk_main in mega65.vhd). Index / slice = Amiga unit.
      disk_mounted_i      : in  std_logic_vector( 2 downto 0);
      disk_tracks_i       : in  std_logic_vector(23 downto 0);  -- 3 x 8 bit, 160..166 each

      -- Write-back armed by the firmware (WBC WR_EN, CDC'd like the mount
      -- status): announce that disk writable and commit its decoded sectors
      write_en_i          : in  std_logic_vector(2 downto 0);

      -- Dirty-track event channel towards the adf_mount_wrapper instances
      -- (two-phase toggle handshake; the cdc_stable instances live in
      -- mega65.vhd). One request toggle per drive with a SHARED track
      -- payload: the scanner serves one event at a time, so the payload is
      -- stable for the whole round trip and the idle drives see no edge.
      wr_track_o          : out std_logic_vector(7 downto 0);
      wr_req_o            : out std_logic_vector(2 downto 0);  -- toggle per drive
      wr_ack_i            : in  std_logic_vector(2 downto 0);  -- toggle (CDC'd)

      -- Drive configuration (OSM Drive Settings, static in clk_main):
      -- adf_en_i(u)='1' makes unit u a simulated ADF drive, phys_en_i/
      -- phys_unit_i name the one unit backed by the real mechanism. A unit
      -- that is neither does not exist: its polls are ignored, it is not
      -- announced, and no drain of it can ever commit. The mount machinery
      -- of a disabled simulated drive keeps working, its image simply has no
      -- unit until the menu gives it one again.
      adf_en_i            : in  std_logic_vector(2 downto 0);
      phys_unit_i         : in  std_logic_vector(1 downto 0);
      phys_en_i           : in  std_logic;

      -- Physical drive: presence (real disk-change latch clear, CDC'd in
      -- mega65.vhd) and the reconstructed MFM word stream (read side of
      -- physical_fdd_top's dual-clock FIFO, first-word-fall-through)
      phys_present_i      : in  std_logic;
      phys_rd_data_i      : in  std_logic_vector(15 downto 0);
      phys_rd_empty_i     : in  std_logic;
      phys_rd_en_o        : out std_logic;                     -- 1-clk pop

      -- Live DSKSYNC towards the front-end bit-aligner (raw, no substitution)
      dsksync_o           : out std_logic_vector(15 downto 0);

      -- Diagnostic: running count of physical-service data words actually
      -- pushed into Paula (ST_PHYS_DATA completions), GRAY-coded so the
      -- QNICE-domain diag can 2-FF-sample it safely (increments are >= one
      -- io-word handshake apart, far slower than the sampling clock). This
      -- is the observable that separates "trackdisk read and rejected the
      -- data" from "Paula's DMA never armed": the front-end counters all
      -- sit before the word FIFO and tick either way.
      phys_served_gray_o  : out std_logic_vector(15 downto 0);

      -- Diagnostic: served-side store signature - XOR of the first 1024
      -- data words served after the first DSKSYNC word of each physical
      -- stream session (= the window Paula stores from, since its WORDSYNC
      -- gate drops the matching word and stores from the next). Compared by
      -- the diag against the identical signature computed inside
      -- paula_floppy.v over the words it actually wrote into its read FIFO:
      -- equal values prove the io channel and the store gating word-exact
      -- on real hardware. Quasi-static after each session (cdc_stable'd in
      -- mega65.vhd); the session counter pairs the two sides.
      phys_sig_o          : out std_logic_vector(15 downto 0);
      phys_sig_ses_o      : out std_logic_vector(7 downto 0);
      phys_sig_done_o     : out std_logic;
      -- checkpoint prefixes of the same signature (after 64 and 256 words):
      -- compared against Paula's checkpoints they bracket the FIRST
      -- diverging word of a corrupted attempt in one observation
      phys_sig_c64_o      : out std_logic_vector(15 downto 0);
      phys_sig_c256_o     : out std_logic_vector(15 downto 0);

      -- Minimig floppy host channel (paula_floppy.v IO_ENA = io_fpga)
      io_fpga_o           : out std_logic;                     -- registered - async-clear pin inside Paula!
      io_strobe_o         : out std_logic;                     -- 1 clk pulse per word
      io_din_o            : out std_logic_vector(15 downto 0);
      io_dout_i           : in  std_logic_vector(15 downto 0);
      io_wait_i           : in  std_logic;

      -- '1' while an Avalon transaction is in flight or about to be issued.
      -- main.vhd uses this to invalidate the shared read cache only at a safe
      -- moment: the cache is common to all drives, so a newly streamed image
      -- must flush it, but flushing mid-fetch would swallow a burst response
      -- and hang the fetch. Asserted at least one clock BEFORE avm_read_o /
      -- avm_write_o rise (ST_SERVE and ST_WCOMMIT_ADDR precede the issue
      -- states), which closes the race against the flush decision.
      avm_busy_o          : out std_logic;

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

   -- physical service pacing: max words pushed per frame (the FIFO rarely
   -- holds more than 1 at real disk pace) and the re-poll gap while the FIFO
   -- is empty (~4.5 us; adds at most ~1/6 word time of latency)
   constant C_PHYS_BURST_MAX    : natural := 16;
   constant C_PHYS_POLL_GAP     : natural := 127;

   -- MFM write-decode section lengths (bit-exact minimig_fdd.cpp WriteTrack):
   -- header = 2nd sync + 4 info + 16 label + 4 stored-checksum words (GetHeader
   -- needs >= 25 buffered, :337); data = 4 stored-checksum + 256 odd + 256 even
   -- words (GetData needs >= 0x204, :469). A section is only consumed once
   -- Paula's FIFO holds ALL of it - no mid-section starvation handling needed.
   constant C_HDR_WORDS         : natural := 25;
   constant C_DATA_WORDS        : natural := 516;

   -- Per-unit lookup tables. Amiga unit 3 exists in the status word's sel
   -- field but can never be a drive here, so it maps to drive 0's entries and
   -- is kept out by adf_en_i, which is "000" for it by construction.
   type t_base_array is array (0 to 3) of unsigned(21 downto 0);
   constant C_BASE : t_base_array := (unsigned(G_BASE_DF0), unsigned(G_BASE_DF1),
                                      unsigned(G_BASE_DF2), unsigned(G_BASE_DF0));

   -- track count of one drive out of the packed disk_tracks_i vector
   function f_tracks(t : std_logic_vector(23 downto 0);
                     u : unsigned(1 downto 0)) return unsigned is
   begin
      case to_integer(u) is
         when 0      => return unsigned(t( 7 downto  0));
         when 1      => return unsigned(t(15 downto  8));
         when 2      => return unsigned(t(23 downto 16));
         when others => return (7 downto 0 => '0');
      end case;
   end function f_tracks;

   -- "unit u is a simulated ADF drive" (false for the non-existent unit 3)
   function f_is_adf(e : std_logic_vector(2 downto 0);
                     u : unsigned(1 downto 0)) return std_logic is
   begin
      if u = 3 then
         return '0';
      end if;
      return e(to_integer(u));
   end function f_is_adf;

   -- "unit u is a mounted simulated ADF drive" (the read/commit precondition)
   function f_is_mounted(e : std_logic_vector(2 downto 0);
                         m : std_logic_vector(2 downto 0);
                         u : unsigned(1 downto 0)) return std_logic is
   begin
      if u = 3 then
         return '0';
      end if;
      return e(to_integer(u)) and m(to_integer(u));
   end function f_is_mounted;

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
      ST_PHYS_OPEN,     -- physical service frame: open, w0 = status re-check
      ST_PHYS_HDR,      -- w0 eval + w1 = dsksync (raw, exported) + w2 discarded
      ST_PHYS_DATA,     -- stream reconstructed words from the front-end FIFO
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
   signal sync_phys    : std_logic_vector(15 downto 0) := x"4489";  -- raw dsksync for the
                                                        -- front-end aligner (Paula reset value)

   -- physical-service served-word diagnostic counter (binary + Gray shadow;
   -- free-running, wraps - the diag procedure diffs two reads). Deliberately
   -- not cleared by reset_i so an Amiga reboot does not erase the evidence.
   signal served_bin   : unsigned(15 downto 0) := (others => '0');
   signal served_gray  : std_logic_vector(15 downto 0) := (others => '0');

   -- physical stream session ownership: set when the service is dispatched,
   -- held while Paula's trackrd stays up. While set, transient foreign sel
   -- samples in poll frames (the OTHER unit's change-poll click; Paula's
   -- sel field is a priority encoder) neither abort the stream nor divert
   -- the dispatch into the ADF service (which would poison the read DMA).
   signal phys_stream  : std_logic := '0';

   -- ADF read session ownership, the exact counterpart of phys_stream and for
   -- the same reason: Paula binds trackrd to ONE unit for a whole DMA, but its
   -- sel field is a priority encoder, so a change-poll click on another drive
   -- makes one poll report a foreign unit mid-read. Without this latch the next
   -- poll would re-dispatch the running DMA to that other drive and stream ITS
   -- image into the buffer the first drive is filling - silently wrong data,
   -- with nothing on the disk to show for it. While the latch is set the
   -- serving unit is frozen; it is released when trackrd drops.
   --
   -- Sharp edge of the protocol, worth knowing before touching this: Paula's
   -- encoder (paula_floppy.v:363) returns sel = 0 BOTH when df0 is selected and
   -- when NO drive is selected, so those two states are indistinguishable in the
   -- status word. The latch freezes whatever the first accepted poll of a
   -- session reported, which is right for the case it exists for (a foreign
   -- change-poll click mid-read) and would be wrong only if a read DMA were
   -- armed with every drive deselected - which trackdisk does not do: it selects
   -- the drive before writing DSKLEN and keeps it selected for the transfer.
   signal adf_stream   : std_logic := '0';

   -- serve-from-sync gate (the round-6 root cause): ADKCON WORDSYNC is 0 in
   -- this system (hardware-measured; the ADF path works because its stream
   -- starts at a sector boundary), so Paula stores from the very FIRST word
   -- the engine serves. After a chain reset (deselect between attempts) the
   -- front end emits free-running pre-lock words - serving those puts
   -- hundreds of junk words at the buffer start and trackdisk rejects the
   -- read. The gate discards FIFO words until the head equals the live
   -- DSKSYNC, then serves from the sync word itself: the buffer starts
   -- sync-aligned exactly like a real drive behind Paula WORDSYNC, under
   -- EITHER wordsync setting.
   signal phys_hunt    : std_logic := '0';

   -- served-side store signature (see the port comment)
   constant C_SIG_WORDS : natural := 1024;
   type t_sig is (SG_HUNT, SG_RUN, SG_IDLE);
   signal sig_state    : t_sig := SG_IDLE;
   signal sig_acc      : std_logic_vector(15 downto 0) := (others => '0');
   signal sig_cnt      : unsigned(10 downto 0) := (others => '0');
   signal sig_last     : std_logic_vector(15 downto 0) := (others => '0');
   signal sig_c64      : std_logic_vector(15 downto 0) := (others => '0');
   signal sig_c256     : std_logic_vector(15 downto 0) := (others => '0');
   signal sig_done     : std_logic := '0';
   signal sig_ses      : unsigned(7 downto 0) := (others => '0');
   signal phys_din_q   : std_logic_vector(15 downto 0) := (others => '0');

   -- disk service state. track_eff / sector / fetch_idx belong to the ONE
   -- serve that is in flight; the rotation continuation is per unit, so two
   -- drives reading in alternation keep their own head and sector position
   -- (a shared sector_next would make each drive resume where the other one
   -- stopped, which shows up as random sector-order corruption).
   signal serve_unit   : unsigned(1 downto 0) := (others => '0');  -- unit of the current serve
   signal track_eff    : unsigned(7 downto 0) := (others => '0');  -- clamped requested track
   type t_track_array  is array (0 to 3) of unsigned(7 downto 0);
   type t_sector_array is array (0 to 3) of unsigned(3 downto 0);
   signal track_prev   : t_track_array := (others => (others => '0'));
   signal track_valid  : std_logic_vector(3 downto 0) := (others => '0');  -- track_prev is real
   signal sector       : unsigned(3 downto 0) := (others => '0');  -- 0..10
   signal sector_next  : t_sector_array := (others => (others => '0'));  -- rotation continuation
   signal fetch_idx    : unsigned(7 downto 0) := (others => '0');  -- word 0..255 in the sector

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
   signal drain_unit   : unsigned(1 downto 0) := (others => '0');  -- unit that owns the drain
   signal drain_commit : std_logic := '0';             -- '1' = drain belongs to a simulated
                                                       -- drive (physical-unit drains stay pure
                                                       -- discard: sync hunt disabled, so the
                                                       -- decoder can never commit them)
   signal wr_track_lat : unsigned(7 downto 0) := (others => '0');  -- physical track at drain entry
   signal wd_idx       : unsigned(9 downto 0);         -- word index within a section
   signal winf_odd     : std_logic_vector(31 downto 0);-- info odd bytes: fmt,trk,sec,gap
   signal whd_fmt      : std_logic_vector(7 downto 0); -- decoded header: format (0xFF)
   signal whd_track    : std_logic_vector(7 downto 0); -- decoded header: track
   signal whd_sector   : unsigned(7 downto 0) := (others => '0');  -- decoded header: sector 0..10
   signal whd_gap      : unsigned(7 downto 0);         -- decoded header: sectors to gap
   signal wck0, wck1, wck2, wck3 : std_logic_vector(7 downto 0);  -- computed cksum lanes
   signal wst0, wst1, wst2, wst3 : std_logic_vector(7 downto 0);  -- stored cksum lanes

   -- dirty-track bookkeeping + event scanner (see p_dirty_scan), one pending
   -- bitmap per simulated drive
   type t_dirty_array is array (0 to 2) of std_logic_vector(165 downto 0);
   signal dirty_pend      : t_dirty_array := (others => (others => '0'));
   signal dirty_set_valid : std_logic := '0';
   signal dirty_set_track : unsigned(7 downto 0) := (others => '0');
   signal dirty_set_unit  : unsigned(1 downto 0) := (others => '0');
   type t_scan is (SC_SCAN, SC_SETTLE, SC_WAIT);
   signal scan_state   : t_scan := SC_SCAN;
   signal scan_unit    : natural range 0 to 2 := 0;
   signal scan_idx     : unsigned(7 downto 0) := (others => '0');
   signal settle_cnt   : unsigned(4 downto 0);
   signal wr_req       : std_logic_vector(2 downto 0) := (others => '0');

   -- sector buffer: 256x16, byte-swapped to 68k order (even file byte in bits 15:8).
   -- MUST stay LUTRAM (BRAM is full, see CLAUDE.md rule 3). Accessed ONLY via the
   -- textbook simple-dual-port template (one sync write in ST_FETCH_WAIT, one
   -- unconditional registered read through secbuf_raddr/secbuf_q at the top of
   -- fsm_proc) - anything fancier makes Vivado fall back to 4096 flip-flops
   -- (Synth 8-7186 "not inferred as ram due to incorrect usage", seen in R3
   -- synthesis run 3 with a read expression at the io_din_o assignment sites).
   type t_secbuf is array (0 to 255) of std_logic_vector(15 downto 0);
   signal secbuf       : t_secbuf;
   signal secbuf_raddr : unsigned(7 downto 0) := (others => '0');  -- primed one word ahead
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
   signal wrbuf_raddr  : unsigned(7 downto 0) := (others => '0');
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
      variable v_sel       : std_logic_vector(1 downto 0);   -- selected unit (status bits 15:14)
      variable v_unit      : unsigned(1 downto 0);           -- the same, as an index
      variable v_drain     : std_logic;                      -- in_drain after the ownership guard
      variable v_serve     : unsigned(1 downto 0);           -- unit the read service will use
      variable v_present   : std_logic_vector(3 downto 0);   -- announce: per-unit present nibble
      variable v_writable  : std_logic_vector(3 downto 0);   -- announce: per-unit writable nibble

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

         -- defaults: strobe, done, the dirty-event pulse and the physical
         -- FIFO pop are 1-clk pulses
         io_strobe_o     <= '0';
         xfer_done       <= '0';
         dirty_set_valid <= '0';
         phys_rd_en_o    <= '0';

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

            -- bus released; wait for the poll timer, then run one poll cycle.
            -- While waiting, drain and DISCARD the physical word FIFO: words
            -- decoded while the real drive spins without a pending DMA must
            -- not linger (the stream stays at most one poll period stale).
            when ST_IDLE =>
               io_fpga_o <= '0';
               if phys_rd_empty_i = '0' then
                  phys_rd_en_o <= '1';
               end if;
               if delay_cnt /= 0 then
                  delay_cnt <= delay_cnt - 1;
               elsif bus_grant_i = '1' then
                  io_fpga_o <= '1';
                  -- drive-status word 0x1000|{writable[3:0],present[3:0]},
                  -- per-unit nibbles from the drive configuration: a
                  -- simulated drive's present = mounted, writable only while
                  -- the firmware has write-back armed for THAT drive (WBC
                  -- WR_EN); the physical unit's present from the real
                  -- disk-change latch, writable NEVER (read-only milestone -
                  -- the real /WPROT level reaches CIA-A through the
                  -- paula_floppy mux regardless). Re-sent every poll cycle -
                  -- Paula wipes it on every Amiga reset.
                  v_present  := (others => '0');
                  v_writable := (others => '0');
                  for u in 0 to 2 loop
                     if adf_en_i(u) = '1' then
                        v_present(u)  := disk_mounted_i(u);
                        v_writable(u) := disk_mounted_i(u) and write_en_i(u);
                     end if;
                  end loop;
                  if phys_en_i = '1' then
                     v_present(to_integer(unsigned(phys_unit_i))) := phys_present_i;
                  end if;
                  io_din_o  <= x"10" & v_writable & v_present;
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
                  status    <= xfer_resp;
                  v_sel     := xfer_resp(15 downto 14);
                  v_unit    := unsigned(v_sel);
                  v_drain   := in_drain;

                  -- UNIT OWNERSHIP GUARD. An open write drain belongs to
                  -- exactly one unit; the decoder holds that unit's header,
                  -- checksum lanes, half-decoded sector and commit track. As
                  -- soon as Paula selects a different unit, all of that is
                  -- meaningless - and worse, feeding the other unit's frame
                  -- into it would produce a checksum-valid sector that the
                  -- commit path writes into the FIRST unit's image. Abort in
                  -- EVERY wd_mode, not just while hunting, and not keyed on
                  -- the track number. v_drain carries the decision into the
                  -- rest of this cycle, because in_drain only clears at the
                  -- next edge. The price of being unconditional is that a
                  -- transient foreign sel sample (Paula's sel field is a
                  -- priority encoder) costs the sector that was mid-decode;
                  -- trackdisk verifies a track after writing it and retries.
                  -- Losing a sector is recoverable, committing it into the
                  -- wrong drive's image is not.
                  if in_drain = '1' and v_unit /= drain_unit then
                     in_drain <= '0';
                     wd_mode  <= WD_HUNT;
                     v_drain  := '0';
                  end if;

                  if not (f_is_adf(adf_en_i, v_unit) = '1')
                     and not (phys_en_i = '1' and v_sel = phys_unit_i)
                     and not (phys_stream = '1' and xfer_resp(8) = '1'
                              and xfer_resp(9) = '0')
                     and not (adf_stream = '1' and xfer_resp(8) = '1'
                              and xfer_resp(9) = '0') then
                     -- none of our units selected: not ours - leave the
                     -- request pending (MiSTer-identical). Exception: while
                     -- a physical stream session is in flight (trackrd
                     -- still up), a transient foreign sel sample must not
                     -- park the engine in ST_IDLE (which discards the live
                     -- word stream).
                     in_drain    <= '0';
                     state_after <= ST_IDLE;
                     io_fpga_o   <= '0';
                     delay_cnt   <= C_GAP_DELAY;
                     state       <= ST_CLOSE;
                  elsif xfer_resp(9) = '1' then
                     -- write requested: drain it (trackwr was 1 at w0, so w1 cannot arm a read).
                     -- Only drains owned by a simulated drive may decode and commit; a
                     -- physical-unit drain is a pure discard (drain_commit gates the sync
                     -- hunt below)
                     track_valid(to_integer(v_unit)) <= '0';   -- a write invalidates the
                                                               -- rotation state of ITS unit
                     if v_drain = '1' and wd_mode = WD_HUNT
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
                        if v_drain = '0' then
                           -- fresh drain: latch the physical track (MiSTer:
                           -- drive->track = c2), the owning unit, and re-arm
                           -- the decoder
                           in_drain     <= '1';
                           wd_mode      <= WD_HUNT;
                           wr_track_lat <= unsigned(xfer_resp(7 downto 0));
                           drain_unit   <= v_unit;
                           drain_commit <= f_is_adf(adf_en_i, v_unit);
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
            -- If w0 showed a read request, serve it after the frame closes -
            -- dispatched per selected unit (ADF fetch/stream vs physical stream).
            when ST_POLL_ARM =>
               if xfer_done = '1' then
                  if hdr_cnt = 0 then
                     sync_phys <= xfer_resp;       -- w1 response = live dsksync (raw)
                     hdr_cnt <= "01";
                     xfer    <= XF_STROBE;         -- w2 (response discarded)
                  else
                     if status(8) = '1' then
                        if phys_en_i = '1' and (phys_stream = '1'
                           or status(15 downto 14) = phys_unit_i) then
                           -- enter or CONTINUE the physical stream: trackrd
                           -- is bound to one unit for the whole DMA, so a
                           -- transient foreign sel sample mid-read must not
                           -- divert the dispatch (least of all into the ADF
                           -- service, which would poison the read DMA with
                           -- image data)
                           if phys_stream = '0' then
                              -- new session: (re)arm the store signature
                              sig_state <= SG_HUNT;
                              sig_acc   <= (others => '0');
                              sig_cnt   <= (others => '0');
                              sig_done  <= '0';
                              sig_c64   <= (others => '0');
                              sig_c256  <= (others => '0');
                              sig_ses   <= sig_ses + 1;
                              phys_hunt <= '1';
                           end if;
                           phys_stream <= '1';
                           state_after <= ST_PHYS_OPEN;
                        else
                           -- ADF service. On a NEW session the unit Paula
                           -- selected at w0 is latched into serve_unit and
                           -- everything downstream (fetch address, track clamp,
                           -- mid-stream abort) uses that latch instead of
                           -- re-reading the sel bits. While a session is
                           -- already running the latch is FROZEN, so a
                           -- transient foreign sel cannot re-point the running
                           -- DMA at another drive's image.
                           if adf_stream = '1' then
                              v_serve := serve_unit;
                           else
                              v_serve := unsigned(status(15 downto 14));
                           end if;
                           if f_is_mounted(adf_en_i, disk_mounted_i, v_serve) = '1'
                              and f_tracks(disk_tracks_i, v_serve) /= 0 then
                              -- (tracks /= 0 is guaranteed by the mount
                              -- validator; belt-and-braces for the clamp below)
                              serve_unit  <= v_serve;
                              adf_stream  <= '1';
                              state_after <= ST_SERVE;
                           else
                              adf_stream  <= '0';
                              state_after <= ST_IDLE;
                           end if;
                        end if;
                     else
                        phys_stream <= '0';
                        adf_stream  <= '0';           -- trackrd dropped: session over
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
                        if drain_commit = '1' and xfer_resp = x"4489" then
                           -- sync hunt only for ADF-unit drains: a physical-
                           -- unit drain stays in HUNT forever = pure discard,
                           -- so it can never reach the HyperRAM commit path
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
                                 -- every image-side gate is evaluated for the
                                 -- unit that OWNS this drain, never for a
                                 -- "current" unit: by the time the last data
                                 -- word arrives, Paula may already be polling
                                 -- someone else
                                 if v_ck0 = wst0 and v_ck1 = wst1
                                    and v_ck2 = wst2 and v_ck3 = wst3
                                    and whd_track = std_logic_vector(wr_track_lat)
                                    and wr_track_lat < f_tracks(disk_tracks_i, drain_unit)
                                    and drain_commit = '1'
                                    and write_en_i(to_integer(drain_unit)) = '1'
                                    and disk_mounted_i(to_integer(drain_unit)) = '1' then
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
               -- the pool of the unit that owns this drain - the whole point
               -- of latching drain_unit
               avm_address_o   <= std_logic_vector(
                                    resize(C_BASE(to_integer(drain_unit)), 32)
                                    + resize(wr_track_lat * to_unsigned(C_TRACK_WORDS, 12), 32)
                                    + resize(whd_sector(3 downto 0) * to_unsigned(C_WORDS_PER_SECTOR, 9), 32)
                                    + resize(fetch_idx, 32));
               if avm_write_o = '1' and avm_waitrequest_i = '0' then
                  avm_write_o <= '0';
                  if fetch_idx = C_WORDS_PER_SECTOR - 1 then
                     dirty_set_valid <= '1';        -- sector is in HyperRAM:
                     dirty_set_track <= wr_track_lat;  -- queue the dirty track
                     dirty_set_unit  <= drain_unit;    -- for the owning drive
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
               if v_track_req >= f_tracks(disk_tracks_i, serve_unit) then
                  v_track_req := f_tracks(disk_tracks_i, serve_unit) - 1;
               end if;
               track_eff <= v_track_req;
               if track_valid(to_integer(serve_unit)) = '0'
                  or v_track_req /= track_prev(to_integer(serve_unit)) then
                  sector      <= (others => '0'); -- track change: restart at sector 0
                  sector_next(to_integer(serve_unit)) <= (others => '0');
                  track_prev(to_integer(serve_unit))  <= v_track_req;
                  track_valid(to_integer(serve_unit)) <= '1';
               else
                  sector <= sector_next(to_integer(serve_unit));   -- same track:
                                                    -- rotation continuation of THIS unit
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
                                  resize(C_BASE(to_integer(serve_unit)), 32)
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
                        if v_track_new >= f_tracks(disk_tracks_i, serve_unit) then
                           v_track_new := f_tracks(disk_tracks_i, serve_unit) - 1;
                        end if;
                        -- the sel bits must still name the unit this stream was
                        -- started for - compared against the LATCHED serving unit,
                        -- so a second simulated drive polling in between aborts the
                        -- stream instead of silently inheriting it
                        if xfer_resp(8) = '0'
                           or xfer_resp(9) = '1'
                           or f_is_mounted(adf_en_i, disk_mounted_i, serve_unit) = '0'
                           or f_tracks(disk_tracks_i, serve_unit) = 0 then
                           -- the DMA really ended (or the disk vanished): drop
                           -- the session and go back to the poll cadence
                           adf_stream  <= '0';
                           state_after <= ST_IDLE;
                           io_fpga_o   <= '0';
                           delay_cnt   <= C_GAP_DELAY;
                           state       <= ST_CLOSE;
                        elsif unsigned(xfer_resp(15 downto 14)) /= serve_unit then
                           -- a foreign unit was sampled mid-stream. Close this
                           -- frame, but KEEP the session: the next poll finds
                           -- adf_stream set and resumes serving the same unit
                           -- instead of handing the DMA to the other drive.
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
                        sync_phys    <= xfer_resp;                       -- raw copy for the aligner
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
                     sector_next(to_integer(serve_unit)) <= (sector + 1) mod 11;
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

            -- physical service frame: open, w0 = status re-check (like
            -- ST_STREAM_OPEN, but data comes from the front-end FIFO at real
            -- disk pace instead of from HyperRAM)
            when ST_PHYS_OPEN =>
               if delay_cnt /= 0 then
                  delay_cnt <= delay_cnt - 1;
               else
                  io_fpga_o <= '1';
                  io_din_o  <= x"0000";
                  if io_fpga_o = '1' and xfer = XF_IDLE and xfer_done = '0' then
                     xfer    <= XF_STROBE;
                     hdr_cnt <= "10";              -- expecting w0 next
                     state   <= ST_PHYS_HDR;
                  end if;
               end if;

            -- w0 = status re-check, w1 = dsksync (raw, exported live to the
            -- front-end aligner - NO Copy Lock substitution: the real disk
            -- contains whatever sync the loader programmed), w2 = discarded
            when ST_PHYS_HDR =>
               if xfer_done = '1' then
                  case hdr_cnt is
                     when "10" =>                  -- w0: status re-check.
                        -- Deliberately NO sel-bits check: trackrd is bound
                        -- to one unit for the whole DMA, and a transient
                        -- foreign /SEL pulse (priority-encoded sel field)
                        -- must not abort the stream into ST_IDLE's discard.
                        if xfer_resp(8) = '0' or xfer_resp(9) = '1'
                           or phys_en_i = '0' then
                           -- DMA done / aborted / throttled / write started:
                           -- back to the normal poll cadence
                           phys_stream <= '0';
                           state_after <= ST_IDLE;
                           io_fpga_o   <= '0';
                           delay_cnt   <= C_GAP_DELAY;
                           state       <= ST_CLOSE;
                        else
                           hdr_cnt  <= "00";
                           io_din_o <= x"0000";
                           xfer     <= XF_STROBE;  -- w1
                        end if;
                     when "00" =>                  -- w1: dsksync -> aligner
                        sync_phys <= xfer_resp;
                        hdr_cnt   <= "01";
                        io_din_o  <= x"0000";
                        xfer      <= XF_STROBE;    -- w2 (discarded)
                     when others =>                -- w2 done: stream if words exist
                        word_cnt <= (others => '0');
                        if phys_rd_empty_i = '0' then
                           if phys_hunt = '1' and sync_phys /= x"0000"
                              and phys_rd_data_i /= sync_phys then
                              -- pre-sync word: discard it (one per frame -
                              -- ~5 us per word, far faster than the 32 us
                              -- arrival pace) and re-poll
                              phys_rd_en_o <= '1';
                              state_after  <= ST_PHYS_OPEN;
                              io_fpga_o    <= '0';
                              delay_cnt    <= C_GAP_DELAY;
                              state        <= ST_CLOSE;
                           else
                              phys_hunt    <= '0';
                              io_din_o     <= phys_rd_data_i; -- FWFT head
                              phys_din_q   <= phys_rd_data_i; -- signature shadow
                              phys_rd_en_o <= '1';            -- pop it
                              xfer         <= XF_STROBE;
                              state        <= ST_PHYS_DATA;
                           end if;
                        else
                           -- nothing decoded yet (words arrive every ~32 us):
                           -- close and re-poll after a short gap
                           state_after <= ST_PHYS_OPEN;
                           io_fpga_o   <= '0';
                           delay_cnt   <= C_PHYS_POLL_GAP;
                           state       <= ST_CLOSE;
                        end if;
                  end case;
               end if;

            -- push reconstructed words while the FIFO has them (bounded per
            -- frame so the status re-check stays fresh). io_din_o is latched
            -- before the pop, so it stays stable through Paula's late sample.
            when ST_PHYS_DATA =>
               if xfer_done = '1' then
                  -- one physical data word is complete inside Paula: count it
                  -- (binary + single-step Gray shadow for the diag CDC)
                  served_bin  <= served_bin + 1;
                  served_gray <= std_logic_vector(
                                    shift_right(served_bin + 1, 1) xor (served_bin + 1));
                  -- store signature: XOR of C_SIG_WORDS served words starting
                  -- WITH the first DSKSYNC word of the session - with the
                  -- serve-from-sync gate and WORDSYNC=0 (the measured
                  -- reality) that is exactly Paula's store window, so the
                  -- signature pair must be EQUAL on an intact channel.
                  -- phys_din_q is the word just completed (io_din_o may
                  -- re-latch on this same edge).
                  if sig_state = SG_HUNT then
                     if phys_din_q = sync_phys or sync_phys = x"0000" then
                        sig_state <= SG_RUN;
                        sig_acc   <= phys_din_q;
                        sig_cnt   <= to_unsigned(1, sig_cnt'length);
                     end if;
                  elsif sig_state = SG_RUN then
                     sig_acc <= sig_acc xor phys_din_q;
                     sig_cnt <= sig_cnt + 1;
                     if sig_cnt = to_unsigned(63, sig_cnt'length) then
                        sig_c64 <= sig_acc xor phys_din_q;
                     elsif sig_cnt = to_unsigned(255, sig_cnt'length) then
                        sig_c256 <= sig_acc xor phys_din_q;
                     elsif sig_cnt = to_unsigned(C_SIG_WORDS - 1, sig_cnt'length) then
                        sig_last  <= sig_acc xor phys_din_q;
                        sig_done  <= '1';
                        sig_state <= SG_IDLE;
                     end if;
                  end if;
                  if phys_rd_empty_i = '0'
                     and word_cnt /= to_unsigned(C_PHYS_BURST_MAX - 1, 10) then
                     word_cnt     <= word_cnt + 1;
                     io_din_o     <= phys_rd_data_i;
                     phys_din_q   <= phys_rd_data_i;
                     phys_rd_en_o <= '1';
                     xfer         <= XF_STROBE;
                  else
                     state_after <= ST_PHYS_OPEN;
                     io_fpga_o   <= '0';
                     delay_cnt   <= C_GAP_DELAY;
                     state       <= ST_CLOSE;
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
         -- note: the ST_PHYS_* states are deliberately NOT in the unmount
         -- abort list - the physical drive works without any ADF mounted
         -- the unmount test looks at the unit that owns the state in question:
         -- the serving unit while reading, the draining unit while committing.
         -- Ejecting a disk from an idle drive must not disturb another one.
         if reset_i = '1' or bus_grant_i = '0'
            or (f_is_mounted(adf_en_i, disk_mounted_i, serve_unit) = '0'
                and (state = ST_SERVE or state = ST_FETCH_ISSUE
                     or state = ST_FETCH_WAIT))
            or (f_is_mounted(adf_en_i, disk_mounted_i, drain_unit) = '0'
                and (state = ST_WCOMMIT_ADDR
                     or state = ST_WCOMMIT_READ
                     or state = ST_WCOMMIT_ISSUE)) then
            io_fpga_o    <= '0';
            io_strobe_o  <= '0';
            avm_read_o   <= '0';
            avm_write_o  <= '0';
            xfer         <= XF_IDLE;
            xfer_done    <= '0';
            in_drain     <= '0';
            wd_mode      <= WD_HUNT;
            phys_rd_en_o <= '0';
            phys_stream  <= '0';
            adf_stream   <= '0';
            sig_state    <= SG_IDLE;              -- freeze a torn signature
            state        <= ST_IDLE;
            delay_cnt    <= G_POLL_DELAY;
            if reset_i = '1' then
               track_valid <= (others => '0');
               sector_next <= (others => (others => '0'));
            end if;
         end if;

         -- a fresh mount always restarts the rotation state of THAT drive
         for u in 0 to 2 loop
            if disk_mounted_i(u) = '0' then
               track_valid(u) <= '0';
            end if;
         end loop;
         track_valid(3) <= '0';                    -- unit 3 is never a drive

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

   -- "an Avalon transaction is in flight or one state away" - see the port
   -- comment. ST_SERVE and ST_WCOMMIT_ADDR/READ are included precisely so
   -- that this rises BEFORE avm_read_o / avm_write_o do.
   avm_busy_o <= '1' when state = ST_SERVE or state = ST_FETCH_ISSUE
                       or state = ST_FETCH_WAIT or state = ST_WCOMMIT_ADDR
                       or state = ST_WCOMMIT_READ or state = ST_WCOMMIT_ISSUE
                 else '0';

   -- live DSKSYNC towards the front-end bit-aligner (registered in fsm_proc;
   -- quasi-static: it changes only when Amiga software writes the register)
   dsksync_o <= sync_phys;

   -- served-word count towards the diag (registered in fsm_proc; Gray-coded,
   -- so the QNICE domain samples it through a plain 2-FF synchronizer)
   phys_served_gray_o <= served_gray;

   -- served-side store signature towards the diag (quasi-static after each
   -- session; cdc_stable'd in mega65.vhd)
   phys_sig_o      <= sig_last;
   phys_sig_ses_o  <= std_logic_vector(sig_ses);
   phys_sig_done_o <= sig_done;
   phys_sig_c64_o  <= sig_c64;
   phys_sig_c256_o <= sig_c256;

   p_dirty_scan : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         case scan_state is
            when SC_SCAN =>
               -- walk track 0..165 of one drive, then move on to the next
               -- drive: a busy drive can therefore never starve the others
               if dirty_pend(scan_unit)(to_integer(scan_idx)) = '1' then
                  wr_track_o <= std_logic_vector(scan_idx);
                  dirty_pend(scan_unit)(to_integer(scan_idx)) <= '0';
                  settle_cnt <= (others => '1');     -- 31 clks >> CDC latency
                  scan_state <= SC_SETTLE;
               elsif scan_idx = 165 then
                  scan_idx <= (others => '0');
                  if scan_unit = 2 then
                     scan_unit <= 0;
                  else
                     scan_unit <= scan_unit + 1;
                  end if;
               else
                  scan_idx <= scan_idx + 1;
               end if;

            when SC_SETTLE =>                        -- payload settles at the
               settle_cnt <= settle_cnt - 1;         -- far side of the CDC
               if settle_cnt = 0 then
                  wr_req(scan_unit) <= not wr_req(scan_unit);
                  scan_state        <= SC_WAIT;
               end if;

            when SC_WAIT =>
               if wr_ack_i(scan_unit) = wr_req(scan_unit) then
                  scan_state <= SC_SCAN;             -- re-checks the same index
               end if;                               -- first (re-dirty case)
         end case;

         -- a commit in the same cycle wins over the scanner's clear
         if dirty_set_valid = '1' then
            dirty_pend(to_integer(dirty_set_unit))(to_integer(dirty_set_track)) <= '1';
         end if;
      end if;
   end process p_dirty_scan;

end architecture synthesis;
