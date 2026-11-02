-------------------------------------------------------------------------------
-- tb_adf_rotation: closed-loop testbench for the rotation continuation of
-- the ADF read service across the end of a read DMA.
--
-- The case is issue #40, the Apidya stage-2 loader. It reads one sector per
-- DMA with DSKLEN 0x821E (542 words) and ADKCON WORDSYNC on, and re-arms the
-- next DMA as soon as DSKBLK fires. Under WORDSYNC Paula stores from the
-- second of the two sync words, so a DMA holds the 541 remaining words of
-- sector n and, as its 542nd word, word 0 of the frame of sector n+1: it
-- ends in that frame's preamble, before the sync. Paula arms the next DMA
-- only at word 1 of a later poll frame, while the engine streams the rest of
-- the frame of n+1 past a FIFO that no longer stores. A real disk brings
-- sector n+1 under the head again, so the engine serves a sector once more
-- when a DMA that carried over from the previous frame ended in the two
-- preamble words of the sector's frame. An engine that always advances hands
-- the loader 0 2 4 6 8 10 0 2 ... and never an odd sector, and the loader
-- waits forever.
--
-- The bench drives the real adf_track_engine (df0 a mounted simulated drive
-- with 160 tracks) against:
--   * a cycle-faithful VHDL model of paula_floppy.v
--     (CORE/Minimig_MiSTerMEGA65/rtl/paula_floppy.v): the IO_WAIT/stb7
--     two-phase clk7 handshake, cmd_cnt (saturating at 3) and cmd_fdd; the
--     tx_data mux, which answers w2 and every data word with
--     {dmaen,dsklen[14:0]} while trackrd is 1 and with 0 otherwise, latched
--     at the clk7 edge that stores the word, so the response to a data word
--     carries the length before that word; the DSKLEN write semantics (every
--     write loads dsklen[15:0], dmaen <= data[15] & the previous dsklen[15],
--     so only the second write in a row with bit 15 set arms, DSKBLK clears
--     dsklen[15] and dmaen); the WORDSYNC gate trackrdok; fifo_wr gated by
--     ~lenzero with the dsklen[13:0] decrement; the 2048-word
--     paula_floppy_fifo (12-bit pointers, registered empty, reset by ~dmaen,
--     fifo_cnt[10] masking status bit 8); the DISKDMA state machine (IDLE ->
--     ACTIVE only at word 1 of a frame, DSKBLK on lenzero & empty &
--     ~fifo_wr_del). Disk DMA drains the FIFO into a Chip RAM array, one
--     DSKDATR slot every G_SLOT_CYC clk_main cycles while dmal. Constant:
--     DSKSYNC 0x4489, DMACON DSKEN on, no write DMA, status sel = df0, track
--     register G_TRACK;
--   * an Avalon slave holding a deterministic image (word = addr[15:0] xor
--     0x5A5A, three clocks of read latency);
--   * a CPU process that plays the loader: G_NDMA DMAs, each armed by two
--     DSKLEN writes, the next one G_CPU_LAT clocks after DSKBLK.
--
-- Every stored word is tagged with the stream frame it came from and its
-- index k in that frame; the frame's sector comes from the info words k=5
-- and k=7 on the io channel. The sector of a DMA is the sector of the frame
-- of its first stored word. Pass criteria:
--   * every DMA stores and drains exactly the DSKLEN word count;
--   * with WORDSYNC on, its first stored word is DSKSYNC;
--   * a DMA that holds a whole sector MFM-decodes from Chip RAM to that
--     sector (format 0xFF, track, sector, sectors-to-gap, all 256 data words
--     against the image);
--   * the sector sequence matches G_EXPECT. DMA 0 is a track-start DMA and
--     gets sector 0. 1 = step: DMA i gets s[i-1]+1 mod 11, and with
--     G_NDMA >= 11 every sector appears. 2 = skip: the sector after s[i-1]+1
--     (0 after 10), no odd sector ever - what a DMA that ends past the
--     first sync of the next frame gets. 3 = two-sector step: s[i-1]+2 mod
--     11, what a DMA of 541 + 544 + 1 words gets. 0 = report only.
--
-- The abort scenario (G_ABORT_AT > 0): DMA 0 is a long DMA (G_LONG_DSKLEN)
-- that the CPU stops with a DSKLEN write with bit 15 clear once it has
-- stored G_ABORT_AT words; then DMAs 1 .. G_NDMA-1 of G_DSKLEN follow. The
-- next DMA is armed after an engine poll has seen no read DMA (w2 bit 15 =
-- 0), or with G_ABORT_WAIT = false a few microseconds after the abort,
-- before the engine polls again. DMA 0 and DMA 1 are reported; the sequence
-- expectation applies from DMA 2 on, relative to the DMA before.
--
-- Instrumentation: a status word with trackrd = 1 whose bit 8 is masked by
-- fifo_cnt[10] is the FIFO throttle; the bench counts these samples and
-- reports every stream frame the engine closes after its w0 because of one
-- (THROTTLE DROP). Every frame entered with at most two DMA words left at w2
-- is reported (FRAME) together with whether a poll frame preceded it, i.e.
-- whether it opens a new engine read session.
--
-- Cells (run_fdd_regression.sh):
--   rotation_step     -gG_DSKLEN=33310 -gG_SLOT_CYC=8 -gG_NDMA=12
--   rotation_tiny     -gG_DSKLEN=32769 -gG_WORDSYNC=false -gG_NDMA=12
--   rotation_sync3    -gG_DSKLEN=33312 -gG_EXPECT=2 -gG_SLOT_CYC=8 -gG_NDMA=12
--   rotation_abort    -gG_DSKLEN=32769 -gG_ABORT_AT=700 -gG_NDMA=9
--   rotation_throttle -gG_DSKLEN=33854 -gG_EXPECT=3 -gG_NDMA=12  (long suite)
-- rotation_step (0x821E) is the case itself. rotation_tiny runs one-word
-- DMAs under WORDSYNC off: each ends in the preamble of its only frame,
-- which is the first frame of that DMA, so the sector advances.
-- rotation_sync3 (0x8220, 544 words) ends after the first sync of the next
-- frame, where the next DMA rightly gets the sector after it.
-- rotation_abort stops a long DMA with a DSKLEN write and then runs
-- one-word DMAs, which must step. rotation_throttle runs at the real drain
-- pace with DMAs of 541 + 544 + 1 words: a DMA that reaches a third frame
-- enters it after a FIFO throttle and a re-poll, and the sector of that
-- frame must still be served again.
--
-- Red control: with the frame-end rotation decision disabled (the engine
-- always advances) rotation_step fails with the sequence 0 2 4 6 8 10 0 ...;
-- with the first-sync sample taken at word 3 instead of word 2,
-- rotation_sync3 fails; with the carry-over threshold at three words instead
-- of two, rotation_step fails; with the decision on the first-sync sample
-- alone, without the carry-over condition, rotation_tiny fails with one
-- sector served forever.
--
-- Run: CORE/sim/floppy/run_fdd_regression.sh (cells rotation_*); the four
-- quick cells take about 7 s together, rotation_throttle about 20 s.
--
-- MiSTer2MEGA65 (AExp Amiga 500 port) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;

entity tb_adf_rotation is
  generic (
    -- DSKLEN value the loader writes twice per DMA: bit 15 = DMAEN, bits
    -- 13:0 = words (0x821E = 542 words, the Apidya stage-2 value)
    G_DSKLEN      : natural := 16#821E#;
    -- ADKCON WORDSYNC: true = Paula stores from the word after the DSKSYNC
    -- match, false = from the first word it receives
    G_WORDSYNC    : boolean := true;
    -- number of DMAs (the aborted long DMA of the abort scenario included)
    G_NDMA        : natural := 24;
    -- sector-sequence expectation: 0 report only, 1 step, 2 skip,
    -- 3 two-sector step (see the header)
    G_EXPECT      : natural := 1;
    -- the engine's G_POLL_DELAY in clk_main cycles (the core uses 28374,
    -- 1 ms; shorter keeps idle stretches cheap without changing the protocol)
    G_POLL        : natural := 300;
    -- clk_main cycles between disk DMA slots: 604 = 21.3 us, three slots per
    -- 64 us line, the real pace, under which DMAs longer than two frames
    -- reach the FIFO throttle; small values drain fast and keep it out
    G_SLOT_CYC    : natural := 604;
    -- clk_main cycles from DSKBLK (or the abort) to the first DSKLEN write
    -- of the next DMA: the loader's interrupt latency
    G_CPU_LAT     : natural := 57;
    -- Paula's track register as the status word reports it ({cylinder, ~side})
    G_TRACK       : natural := 37;
    -- abort scenario: 0 = off; otherwise DMA 0 is a long DMA of
    -- G_LONG_DSKLEN that the CPU stops once it has stored this many words
    G_ABORT_AT    : natural := 0;
    G_LONG_DSKLEN : natural := 16#9900#;
    -- the DSKLEN value that stops it: bit 15 clear drops dmaen, and the DMA
    -- state machine returns to IDLE
    G_ABORT_VAL   : natural := 16#4000#;
    -- true: the next DMA is armed after an engine poll has seen no read DMA
    -- (w2 bit 15 = 0); false: G_CPU_LAT cycles after the abort, which the
    -- bench requires to precede the engine's next poll
    G_ABORT_WAIT  : boolean := true
  );
end entity tb_adf_rotation;

architecture sim of tb_adf_rotation is

  constant C_CLK_PER  : time := 35.242 ns;           -- 28.375 MHz
  constant C_DSKSYNC  : std_logic_vector(15 downto 0) := x"4489";
  constant C_LEN      : natural := G_DSKLEN mod 16384; -- dsklen[13:0]
  constant C_BASE0    : std_logic_vector(21 downto 0) :=
                          std_logic_vector(to_unsigned(16#200# * 4096, 22));
  constant C_CHIP_PER : natural := 2048;              -- Chip RAM words per DMA
  constant C_MAXF     : natural := 8192;              -- frame table size
  constant C_ABORT    : boolean := G_ABORT_AT > 0;
  constant C_IMG_TRK  : natural := 16#200# * 4096 + G_TRACK * 2816;  -- track base

  -- clocks / reset
  signal clk      : std_logic := '0';
  signal clk7_cnt : unsigned(1 downto 0) := "00";
  signal clk7_en  : std_logic := '0';
  signal rst      : std_logic := '1';
  signal running  : boolean := true;

  -- engine <-> Paula io channel
  signal io_fpga   : std_logic;
  signal io_strobe : std_logic;
  signal io_din    : std_logic_vector(15 downto 0);
  signal io_dout   : std_logic_vector(15 downto 0) := (others => '0');
  signal io_wait   : std_logic := '0';

  -- Avalon
  signal avm_write, avm_read : std_logic;
  signal avm_address     : std_logic_vector(31 downto 0);
  signal avm_writedata   : std_logic_vector(15 downto 0);
  signal avm_byteenable  : std_logic_vector(1 downto 0);
  signal avm_burstcount  : std_logic_vector(7 downto 0);
  signal avm_readdata    : std_logic_vector(15 downto 0) := (others => '0');
  signal avm_rdvalid     : std_logic := '0';
  signal avm_busy        : std_logic;

  -- Paula model state (names follow paula_floppy.v)
  signal stb7        : std_logic := '0';
  signal rx_data     : std_logic_vector(15 downto 0) := (others => '0');
  signal cmd_cnt     : unsigned(1 downto 0) := "00";
  signal cmd_fdd     : std_logic := '0';
  signal dsklen_l    : unsigned(14 downto 0) := (others => '0');  -- dsklen[14:0]
  signal dsklen_h    : std_logic := '0';                          -- dsklen[15]
  signal dmaen       : std_logic := '0';
  signal trackrdok   : std_logic := '0';
  signal fifo_wr_del : std_logic := '0';
  type t_dsk is (DMA_IDLE, DMA_ACTIVE, DMA_INT);
  signal dskstate    : t_dsk := DMA_IDLE;
  type t_fmem is array (0 to 2047) of std_logic_vector(15 downto 0);
  signal fmem        : t_fmem := (others => (others => '0'));
  signal in_ptr      : unsigned(11 downto 0) := (others => '0');
  signal out_ptr     : unsigned(11 downto 0) := (others => '0');
  signal fifo_empty  : std_logic := '1';
  signal slot_cnt    : natural := 0;
  signal slot_pend   : std_logic := '0';

  -- derived (combinational, like the Verilog wires)
  signal lenzero, trackrd, dmaon, blckint, stbdat : std_logic;
  signal fifo_wr, fifo_full, sync_match, dmal     : std_logic;
  signal fifo_cnt : unsigned(11 downto 0);
  signal tx_data  : std_logic_vector(15 downto 0);

  function f_ws(b : boolean) return std_logic is
  begin
    if b then
      return '1';
    end if;
    return '0';
  end function f_ws;
  constant C_WS   : std_logic := f_ws(G_WORDSYNC);

  -- CPU register write port (sampled on one clk7_en edge)
  signal dsklen_we : std_logic := '0';
  signal dsklen_wd : std_logic_vector(15 downto 0) := (others => '0');

  -- bookkeeping
  signal cur_dma   : natural := 0;
  type t_wordarr is array (natural range <>) of std_logic_vector(15 downto 0);
  signal chip      : t_wordarr(0 to (G_NDMA + 1) * C_CHIP_PER - 1) :=
                       (others => (others => '0'));
  type t_natarr is array (natural range <>) of natural;
  signal st_n      : t_natarr(0 to G_NDMA) := (others => 0);   -- stored words
  signal dr_n      : t_natarr(0 to G_NDMA) := (others => 0);   -- drained words
  signal st_ffid   : t_natarr(0 to G_NDMA) := (others => 0);   -- first word: frame
  signal st_fk     : t_natarr(0 to G_NDMA) := (others => 0);   --             k
  signal st_lfid   : t_natarr(0 to G_NDMA) := (others => 0);   -- last word: frame
  signal st_lk     : t_natarr(0 to G_NDMA) := (others => 0);   --            k
  signal fr_sec    : t_natarr(0 to C_MAXF - 1) := (others => 99);
  signal fr_trk    : t_natarr(0 to C_MAXF - 1) := (others => 999);
  signal fr_ok     : std_logic_vector(0 to C_MAXF - 1) := (others => '0');
  signal thr_cnt   : natural := 0;     -- w0 samples, trackrd = 1, bit 8 masked
  signal drop_thr  : natural := 0;     -- stream frames closed after w0: throttle
  signal drop_end  : natural := 0;     -- stream frames closed after w0: DMA over
  signal idle_polls : natural := 0;    -- poll frames whose w2 shows no read DMA
  signal max_fcnt  : natural := 0;

  -- MFM decode of one byte from its odd-bits and even-bits bytes
  function f_dec(o, e : std_logic_vector(7 downto 0)) return natural is
  begin
    return to_integer(unsigned(((o(6 downto 0) & '0') and x"AA") or (e and x"55")));
  end function f_dec;

  -- the image word at a HyperRAM word address
  function f_img(addr : natural) return std_logic_vector is
    variable r : std_logic_vector(15 downto 0);
  begin
    r := std_logic_vector(to_unsigned(addr mod 65536, 16)) xor x"5A5A";
    return r;
  end function f_img;

begin

  clk <= not clk after C_CLK_PER / 2 when running else '0';

  clk7_grid : process (clk)
  begin
    if rising_edge(clk) then
      clk7_cnt <= clk7_cnt + 1;
      if clk7_cnt = "10" then
        clk7_en <= '1';
      else
        clk7_en <= '0';
      end if;
    end if;
  end process clk7_grid;

  -----------------------------------------------------------------------------
  -- DUT
  -----------------------------------------------------------------------------
  uut : entity work.adf_track_engine
    generic map (
      G_BASE_DF0   => C_BASE0,
      G_BASE_DF1   => std_logic_vector(to_unsigned(16#280# * 4096, 22)),
      G_BASE_DF2   => std_logic_vector(to_unsigned(16#300# * 4096, 22)),
      G_POLL_DELAY => G_POLL
    )
    port map (
      clk_main_i          => clk,
      reset_i             => rst,
      bus_grant_i         => '1',
      disk_mounted_i      => "001",
      disk_tracks_i       => x"0000A0",
      write_en_i          => "000",
      wr_track_o          => open,
      wr_req_o            => open,
      wr_ack_i            => "000",
      adf_en_i            => "001",
      phys_unit_i         => "11",
      phys_en_i           => '0',
      phys_present_i      => '0',
      phys_rd_data_i      => (others => '0'),
      phys_rd_empty_i     => '1',
      phys_rd_en_o        => open,
      dsksync_o           => open,
      phys_served_gray_o  => open,
      phys_sig_o          => open,
      phys_sig_ses_o      => open,
      phys_sig_done_o     => open,
      phys_sig_c64_o      => open,
      phys_sig_c256_o     => open,
      io_fpga_o           => io_fpga,
      io_strobe_o         => io_strobe,
      io_din_o            => io_din,
      io_dout_i           => io_dout,
      io_wait_i           => io_wait,
      avm_busy_o          => avm_busy,
      avm_write_o         => avm_write,
      avm_read_o          => avm_read,
      avm_address_o       => avm_address,
      avm_writedata_o     => avm_writedata,
      avm_byteenable_o    => avm_byteenable,
      avm_burstcount_o    => avm_burstcount,
      avm_readdata_i      => avm_readdata,
      avm_readdatavalid_i => avm_rdvalid,
      avm_waitrequest_i   => '0'
    );

  -----------------------------------------------------------------------------
  -- Avalon slave: the image, read only
  -----------------------------------------------------------------------------
  avalon : process (clk)
    variable rd_pend : natural range 0 to 4 := 0;
    variable rd_addr : std_logic_vector(31 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      avm_rdvalid <= '0';
      assert avm_write /= '1'
        report "unexpected Avalon write" severity failure;
      if avm_read = '1' then
        rd_pend := 3;
        rd_addr := avm_address;
      elsif rd_pend > 1 then
        rd_pend := rd_pend - 1;
      elsif rd_pend = 1 then
        rd_pend      := 0;
        avm_readdata <= f_img(to_integer(unsigned(rd_addr(15 downto 0))));
        avm_rdvalid  <= '1';
      end if;
    end if;
  end process avalon;

  -----------------------------------------------------------------------------
  -- Paula model: combinational part
  -----------------------------------------------------------------------------
  lenzero    <= '1' when dsklen_l(13 downto 0) = 0 else '0';
  trackrd    <= '1' when dskstate = DMA_ACTIVE and lenzero = '0'
                         and dsklen_l(14) = '0' else '0';
  dmaon      <= '1' when dskstate = DMA_ACTIVE
                         and (lenzero = '0' or dsklen_l(14) = '0') else '0';
  blckint    <= '1' when dskstate = DMA_INT else '0';
  stbdat     <= cmd_fdd and stb7 when cmd_cnt = "11" else '0';
  fifo_cnt   <= in_ptr - out_ptr;
  fifo_full  <= '1' when in_ptr(10 downto 0) = out_ptr(10 downto 0)
                         and in_ptr(11) /= out_ptr(11) else '0';
  sync_match <= '1' when rx_data = C_DSKSYNC and stbdat = '1'
                         and trackrd = '1' else '0';
  fifo_wr    <= trackrdok and stbdat and not lenzero;   -- buswr & dmaon = 0
  dmal       <= dmaon and not dsklen_l(14) and not fifo_empty;

  -- tx_data mux, trackwr = 0: 'b00xxx status, 'b01xxx dsksync,
  -- 'b10x1x {dmaen,dsklen}, 'b1111x {dmaen,dsklen}, default 0
  p_tx : process (all)
  begin
    if cmd_cnt = "00" then
      tx_data <= "00" & "01" & "00" & '0' & (trackrd and not fifo_cnt(10))
                 & std_logic_vector(to_unsigned(G_TRACK, 8));
    elsif cmd_cnt = "01" then
      tx_data <= C_DSKSYNC;
    elsif cmd_cnt = "10" and trackrd = '1' then
      tx_data <= dmaen & std_logic_vector(dsklen_l);
    elsif cmd_cnt = "11" and cmd_fdd = '1' and trackrd = '1' then
      tx_data <= dmaen & std_logic_vector(dsklen_l);
    else
      tx_data <= (others => '0');
    end if;
  end process p_tx;

  -----------------------------------------------------------------------------
  -- Paula model: registers, FIFO, disk DMA, and the frame bookkeeping
  -----------------------------------------------------------------------------
  paula : process (clk)
    variable v_fid   : natural := 0;       -- current data frame id
    variable v_d     : natural := 0;       -- data word index in the frame
    variable w4, w5, w6, w7 : std_logic_vector(15 downto 0);
    variable v_cmd0  : std_logic_vector(15 downto 0) := (others => '0');
    variable v_w0    : std_logic_vector(15 downto 0) := (others => '0');
    variable v_trd0  : std_logic := '0';
    variable v_words : natural := 0;       -- words of the current frame
    variable v_open  : std_logic := '0';
    variable v_slot  : std_logic;
    variable v_w2    : std_logic_vector(15 downto 0) := (others => '0');
    variable v_poll  : boolean := false;   -- a poll frame closed since the last data frame
    variable v_after : boolean := false;   -- the current data frame follows a poll
    variable v_fdma  : natural := 0;       -- the DMA that was armed at frame entry
    variable v_cnt   : natural;
  begin
    if rising_edge(clk) then
      -------------------------------------------------------------------------
      -- frame-close classification: a 0x0000 frame closed after w0 with bit 8
      -- low is a stream frame the engine dropped (throttle or DMA over); a
      -- 0x0000 frame of exactly w0..w2 is a poll
      -------------------------------------------------------------------------
      if io_fpga = '0' and v_open = '1' then
        v_open := '0';
        if v_words = 1 and v_cmd0 = x"0000" and v_w0(8) = '0' then
          if v_trd0 = '1' then
            drop_thr <= drop_thr + 1;
            report "THROTTLE DROP: 0x0000 frame closed after w0 with trackrd=1"
                   & " (status bit 8 masked by fifo_cnt[10]); DMA "
                   & integer'image(cur_dma);
          else
            drop_end <= drop_end + 1;
          end if;
        end if;
        if v_words = 3 and v_cmd0 = x"0000" then
          v_poll := true;
          if v_w2(15) = '0' then
            idle_polls <= idle_polls + 1;
          end if;
        end if;
      elsif io_fpga = '1' then
        v_open := '1';
      end if;

      -------------------------------------------------------------------------
      -- host receiver, every clk; ~IO_ENA clears (synchronously here)
      -------------------------------------------------------------------------
      if io_fpga = '0' then
        io_wait <= '0';
        stb7    <= '0';
        cmd_cnt <= "00";
        v_d     := 0;
        v_words := 0;
      else
        if io_strobe = '1' then
          io_wait <= '1';
        end if;
        if clk7_en = '1' and io_wait = '1' then
          if stb7 = '0' then
            rx_data <= io_din;
            stb7    <= '1';
          else
            stb7    <= '0';
            io_wait <= '0';
            io_dout <= tx_data;
            -- bookkeeping of the word just completed
            v_words := v_words + 1;
            if cmd_cnt = "00" then
              v_cmd0 := rx_data;
              v_w0   := tx_data;
              v_trd0 := trackrd;
              if trackrd = '1' and fifo_cnt(10) = '1' then
                thr_cnt <= thr_cnt + 1;
              end if;
            elsif cmd_cnt = "10" then
              v_w2 := tx_data;
            end if;
          end if;
        end if;
        if clk7_en = '1' and stb7 = '1' and cmd_cnt /= "11" then
          cmd_cnt <= cmd_cnt + 1;
        end if;
      end if;

      -------------------------------------------------------------------------
      -- clk7 registers
      -------------------------------------------------------------------------
      if clk7_en = '1' then
        -- data-frame tagging (the io stream as Paula receives it)
        if stbdat = '1' then
          if v_d = 0 then
            v_fid   := v_fid + 1;
            v_after := v_poll;
            v_poll  := false;
            v_fdma  := cur_dma;
          end if;
          case v_d is
            when 4 => w4 := rx_data;
            when 5 => w5 := rx_data;
            when 6 => w6 := rx_data;
            when 7 =>
              w7 := rx_data;
              if v_fid < C_MAXF then
                fr_sec(v_fid) <= f_dec(w5(15 downto 8), w7(15 downto 8));
                fr_trk(v_fid) <= f_dec(w4(7 downto 0), w6(7 downto 0));
                fr_ok(v_fid)  <= '1';
              end if;
              -- a frame entered with at most two DMA words left at w2
              if v_w2(15) = '1' and unsigned(v_w2(13 downto 0)) <= 2 then
                report "FRAME: sector "
                       & integer'image(f_dec(w5(15 downto 8), w7(15 downto 8)))
                       & " entered with w2 dsklen "
                       & integer'image(to_integer(unsigned(v_w2(13 downto 0))))
                       & ", DMA " & integer'image(v_fdma)
                       & ", first frame after a poll (new engine session): "
                       & boolean'image(v_after);
              end if;
            when others => null;
          end case;
        end if;

        -- cmd_fdd
        if rst = '1' or io_fpga = '0' then
          cmd_fdd <= '0';
        elsif stb7 = '1' and cmd_cnt = "00" then
          if rx_data(15 downto 13) = "000" then
            cmd_fdd <= '1';
          else
            cmd_fdd <= '0';
          end if;
        end if;

        -- DSKLEN: [14:0] written by the CPU, else decremented per stored word
        if rst = '1' then
          dsklen_l <= (others => '0');
        elsif dsklen_we = '1' then
          dsklen_l <= unsigned(dsklen_wd(14 downto 0));
        elsif fifo_wr = '1' then
          dsklen_l(13 downto 0) <= dsklen_l(13 downto 0) - 1;
        end if;
        if rst = '1' then
          dsklen_h <= '0';
        elsif blckint = '1' then
          dsklen_h <= '0';
        elsif dsklen_we = '1' then
          dsklen_h <= dsklen_wd(15);
        end if;
        -- dmaen: second write in a row with bit 15 set
        if rst = '1' then
          dmaen <= '0';
        elsif blckint = '1' then
          dmaen <= '0';
        elsif dsklen_we = '1' then
          dmaen <= dsklen_wd(15) and dsklen_h;
        end if;

        -- WORDSYNC gate
        if trackrd = '0' then
          trackrdok <= '0';
        elsif C_WS = '0' or sync_match = '1' or trackrdok = '1' then
          trackrdok <= '1';
        end if;
        fifo_wr_del <= fifo_wr;

        -- store bookkeeping (tag every stored word with its frame and k)
        if fifo_wr = '1' and fifo_full = '0' then
          if st_n(cur_dma) = 0 then
            st_ffid(cur_dma) <= v_fid;
            st_fk(cur_dma)   <= v_d;
          end if;
          st_lfid(cur_dma) <= v_fid;
          st_lk(cur_dma)   <= v_d;
          st_n(cur_dma)    <= st_n(cur_dma) + 1;
        end if;
        if stbdat = '1' then
          v_d := v_d + 1;
        end if;

        -- FIFO (paula_floppy_fifo), reset = reset | ~dmaen
        v_slot := slot_pend;
        if rst = '1' or dmaen = '0' then
          in_ptr  <= (others => '0');
          out_ptr <= (others => '0');
        else
          if fifo_wr = '1' and fifo_full = '0' then
            fmem(to_integer(in_ptr(10 downto 0))) <= rx_data;
            in_ptr <= in_ptr + 1;
          end if;
          -- disk DMA slot: DSKDATR read while dmal
          if v_slot = '1' and dmal = '1' then
            if dr_n(cur_dma) < C_CHIP_PER then
              chip(cur_dma * C_CHIP_PER + dr_n(cur_dma)) <=
                fmem(to_integer(out_ptr(10 downto 0)));
            end if;
            dr_n(cur_dma) <= dr_n(cur_dma) + 1;
            out_ptr <= out_ptr + 1;
          end if;
        end if;
        if in_ptr(10 downto 0) = out_ptr(10 downto 0)
           and in_ptr(11) = out_ptr(11) then
          fifo_empty <= '1';
        else
          fifo_empty <= '0';
        end if;
        v_cnt := to_integer(fifo_cnt);
        if v_cnt > max_fcnt then
          max_fcnt <= v_cnt;
        end if;
        slot_pend <= '0';

        -- DISKDMA FSM
        if rst = '1' then
          dskstate <= DMA_IDLE;
        else
          case dskstate is
            when DMA_IDLE =>
              if cmd_fdd = '1' and stb7 = '1' and cmd_cnt = "01"
                 and dmaen = '1' and lenzero = '0' then
                dskstate <= DMA_ACTIVE;
              end if;
            when DMA_ACTIVE =>
              if dmaen = '0' then
                dskstate <= DMA_IDLE;
              elsif lenzero = '1' and fifo_empty = '1'
                    and fifo_wr_del = '0' then
                dskstate <= DMA_INT;
              end if;
            when DMA_INT =>
              dskstate <= DMA_IDLE;
          end case;
        end if;
      end if;

      -- DMA slot timer (after the clk7 block: a new slot wins over the clear)
      if slot_cnt >= G_SLOT_CYC - 1 then
        slot_cnt  <= 0;
        slot_pend <= '1';
      else
        slot_cnt <= slot_cnt + 1;
      end if;
    end if;
  end process paula;

  -----------------------------------------------------------------------------
  -- CPU: the loader
  -----------------------------------------------------------------------------
  cpu : process
    type t_seq is array (0 to G_NDMA) of integer;
    variable seq      : t_seq := (others => -1);
    variable errors   : natural := 0;
    variable seen     : std_logic_vector(0 to 10) := (others => '0');
    variable sec, ex  : integer;
    variable fid      : natural;
    variable base     : natural;
    variable p        : integer;
    variable dok      : boolean;
    variable odd_seen : boolean := false;
    variable i0       : natural := 0;
    variable v_idle   : natural;
    variable v_img    : std_logic_vector(15 downto 0);

    impure function f_seqstr(n : natural) return string is
      variable l : line;
    begin
      for j in 0 to n loop
        if seq(j) >= 0 then
          write(l, integer'image(seq(j)));
        else
          write(l, string'("?"));
        end if;
        if j /= n then
          write(l, string'(" "));
        end if;
      end loop;
      return l.all;
    end function f_seqstr;

    procedure dsklen_write(v : natural) is
    begin
      wait until rising_edge(clk) and clk7_en = '1';
      dsklen_wd <= std_logic_vector(to_unsigned(v, 16));
      dsklen_we <= '1';
      wait until rising_edge(clk) and clk7_en = '1';   -- the sampling edge
      dsklen_we <= '0';
    end procedure dsklen_write;

    procedure arm(i : natural; v : natural) is
    begin
      cur_dma <= i;
      dsklen_write(v);
      for c in 1 to 16 loop
        wait until rising_edge(clk);
      end loop;
      dsklen_write(v);
    end procedure arm;

    procedure cpu_latency is
    begin
      for c in 1 to G_CPU_LAT loop
        wait until rising_edge(clk);
      end loop;
    end procedure cpu_latency;

    -- evaluate DMA i (called after DMA i+1 was armed, so the info words of
    -- its first frame have passed); an aborted DMA is only reported
    procedure evaluate(i : natural; aborted : boolean) is
      variable l : line;
    begin
      fid := st_ffid(i);
      assert st_n(i) > 0 and fid < C_MAXF
        report "DMA " & integer'image(i) & ": no word stored (or frame table "
               & "overflow); sequence so far: " & f_seqstr(i) severity failure;
      if fr_ok(fid) /= '1' then
        wait until fr_ok(fid) = '1' for 2 ms;
      end if;
      assert fr_ok(fid) = '1'
        report "DMA " & integer'image(i) & ": frame of its first stored word "
               & "never delivered its info words" severity failure;
      sec    := fr_sec(fid);
      seq(i) := sec;
      base   := i * C_CHIP_PER;

      if aborted then
        report "DMA " & integer'image(i) & ": aborted long DMA (DSKLEN "
               & to_hstring(to_unsigned(G_LONG_DSKLEN, 16)) & ") stored "
               & integer'image(st_n(i)) & " words, from sector "
               & integer'image(fr_sec(st_ffid(i))) & " k="
               & integer'image(st_fk(i)) & " to sector "
               & integer'image(fr_sec(st_lfid(i))) & " k="
               & integer'image(st_lk(i));
        return;
      end if;

      -- word count and first word
      if st_n(i) /= C_LEN or dr_n(i) /= C_LEN then
        report "DMA " & integer'image(i) & ": stored " & integer'image(st_n(i))
               & " / drained " & integer'image(dr_n(i)) & " words, expected "
               & integer'image(C_LEN) & "; sequence so far: " & f_seqstr(i)
          severity error;
        errors := errors + 1;
      end if;
      if G_WORDSYNC and chip(base) /= C_DSKSYNC then
        report "DMA " & integer'image(i) & ": first stored word "
               & to_hstring(chip(base)) & ", expected DSKSYNC 4489"
               & "; sequence so far: " & f_seqstr(i)
          severity error;
        errors := errors + 1;
      end if;

      -- full MFM decode from Chip RAM when the DMA holds the whole sector of
      -- its first frame: frame word k sits at Chip RAM index k - fk
      dok := false;
      if st_fk(i) <= 3 and C_LEN >= 544 - st_fk(i) then
        dok := true;
        for k in 2 to 3 loop                  -- the sync words it holds
          if k >= st_fk(i) and chip(base + k - st_fk(i)) /= C_DSKSYNC then
            dok := false;
          end if;
        end loop;
        p := base - st_fk(i);                 -- index of frame word k = p + k
        if f_dec(chip(p + 4)(15 downto 8), chip(p + 6)(15 downto 8)) /= 16#FF#
           or f_dec(chip(p + 4)(7 downto 0), chip(p + 6)(7 downto 0)) /= G_TRACK
           or f_dec(chip(p + 5)(15 downto 8), chip(p + 7)(15 downto 8)) /= sec
           or f_dec(chip(p + 5)(7 downto 0), chip(p + 7)(7 downto 0)) /= 11 - sec
        then
          dok := false;
        end if;
        for j in 0 to 255 loop
          -- the image word holds the even file byte in bits 7:0
          v_img := f_img(C_IMG_TRK + sec * 256 + j);
          if f_dec(chip(p + 32 + j)(15 downto 8), chip(p + 288 + j)(15 downto 8))
               /= to_integer(unsigned(v_img(7 downto 0)))
             or f_dec(chip(p + 32 + j)(7 downto 0), chip(p + 288 + j)(7 downto 0))
               /= to_integer(unsigned(v_img(15 downto 8)))
          then
            dok := false;
          end if;
        end loop;
        if not dok then
          report "DMA " & integer'image(i) & ": Chip RAM does not decode to "
                 & "sector " & integer'image(sec) & " of track "
                 & integer'image(G_TRACK) & "; sequence so far: " & f_seqstr(i)
            severity error;
          errors := errors + 1;
        end if;
      end if;

      write(l, string'("DMA ") & integer'image(i) & ": sector "
               & integer'image(sec) & ", stored words "
               & integer'image(st_n(i)) & ", first word "
               & to_hstring(chip(base)) & ", from sector "
               & integer'image(fr_sec(st_ffid(i))) & " k="
               & integer'image(st_fk(i)) & " to sector "
               & integer'image(fr_sec(st_lfid(i))) & " k="
               & integer'image(st_lk(i)));
      if dok then
        write(l, string'(", MFM decode of Chip RAM OK"));
      end if;
      if C_ABORT and i = 1 then
        write(l, string'(" (first DMA after the abort)"));
      end if;
      report l.all;

      if sec >= 0 and sec <= 10 then
        seen(sec) := '1';
        if (sec mod 2) = 1 then
          odd_seen := true;
        end if;
      end if;

      -- the sequence expectation; in the abort scenario it starts at DMA 2,
      -- relative to the DMA before
      if (G_EXPECT >= 1 and G_EXPECT <= 3) and (not C_ABORT or i >= 2) then
        if i = 0 then
          ex := 0;
        elsif G_EXPECT = 1 then
          ex := (seq(i - 1) + 1) mod 11;
        elsif G_EXPECT = 3 then
          ex := (seq(i - 1) + 2) mod 11;
        elsif seq(i - 1) = 10 then
          ex := 0;
        else
          ex := (seq(i - 1) + 2) mod 11;
        end if;
        if sec /= ex then
          report "DMA " & integer'image(i) & ": expected sector "
                 & integer'image(ex) & ", got sector " & integer'image(sec)
                 & "; sequence so far: " & f_seqstr(i)
            severity error;
          errors := errors + 1;
        end if;
      end if;
    end procedure evaluate;

  begin
    wait for 200 ns;
    wait until rising_edge(clk);
    rst <= '0';
    wait for 200 us;                         -- engine announce/poll cadence

    -- ADKCON WORDSYNC and DSKSYNC are static (G_WORDSYNC, 0x4489)
    if C_ABORT then
      arm(0, G_LONG_DSKLEN);
      wait until st_n(0) >= G_ABORT_AT for 100 ms;
      assert st_n(0) >= G_ABORT_AT
        report "DMA 0: the long DMA stored only " & integer'image(st_n(0))
               & " words, the abort point is " & integer'image(G_ABORT_AT)
        severity failure;
      v_idle := idle_polls;
      dsklen_write(G_ABORT_VAL);
      report "DMA 0: aborted with DSKLEN "
             & to_hstring(to_unsigned(G_ABORT_VAL, 16)) & " after "
             & integer'image(st_n(0)) & " stored words, in the frame of sector "
             & integer'image(fr_sec(st_lfid(0)));
      if G_ABORT_WAIT then
        wait until idle_polls > v_idle for 50 ms;
        assert idle_polls > v_idle
          report "no engine poll observed the aborted DMA" severity failure;
        cpu_latency;
      else
        cpu_latency;
      end if;
      arm(1, G_DSKLEN);
      if not G_ABORT_WAIT then
        assert idle_polls = v_idle
          report "an engine poll saw no read DMA before the re-arm: the "
                 & "immediate re-arm is not what this cell runs"
          severity failure;
      end if;
      report "DMA 1 armed; engine polls that saw no read DMA since the abort: "
             & integer'image(idle_polls - v_idle);
      evaluate(0, true);
      i0 := 1;
    else
      arm(0, G_DSKLEN);
    end if;

    for i in i0 to G_NDMA - 1 loop
      wait until blckint = '1' for 300 ms;
      assert blckint = '1'
        report "DMA " & integer'image(i) & ": DSKBLK timeout; sequence so far: "
               & f_seqstr(i)
        severity failure;
      wait until blckint = '0';
      if i < G_NDMA - 1 then
        cpu_latency;
        arm(i + 1, G_DSKLEN);                -- re-arm at once ...
      end if;
      evaluate(i, false);                    -- ... then look at the buffer
    end loop;

    report "SEQUENCE (" & integer'image(G_NDMA) & " DMAs, DSKLEN "
           & to_hstring(to_unsigned(G_DSKLEN, 16)) & ", WORDSYNC "
           & boolean'image(G_WORDSYNC) & "): " & f_seqstr(G_NDMA - 1);
    report "throttle: w0 samples with trackrd=1 masked by fifo_cnt[10]: "
           & integer'image(thr_cnt) & "; stream-frame drops at w0: "
           & integer'image(drop_thr) & " throttle, "
           & integer'image(drop_end) & " DMA end; peak fifo_cnt "
           & integer'image(max_fcnt);

    if G_EXPECT = 1 and not C_ABORT and G_NDMA >= 11 then
      for s in 0 to 10 loop
        if seen(s) /= '1' then
          report "sector " & integer'image(s) & " never served; sequence: "
                 & f_seqstr(G_NDMA - 1) severity error;
          errors := errors + 1;
        end if;
      end loop;
    elsif G_EXPECT = 2 and not C_ABORT then
      if odd_seen then
        report "an odd sector was served, the skip pattern does not hold; "
               & "sequence: " & f_seqstr(G_NDMA - 1) severity error;
        errors := errors + 1;
      end if;
    end if;

    assert errors = 0
      report "TB_ADF_ROTATION: " & integer'image(errors) & " check(s) failed"
      severity failure;
    if G_EXPECT = 0 then
      report "TB_ADF_ROTATION: REPORT DONE";
    else
      report "TB_ADF_ROTATION: ALL PASS";
    end if;
    running <= false;
    stop;
  end process cpu;

end architecture sim;
