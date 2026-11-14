-------------------------------------------------------------------------------
-- tb_engine_paula: closed-loop testbench for the physical floppy delivery
-- segment: the real adf_track_engine (ST_PHYS states) served by a synthetic
-- front-end word FIFO, talking to a cycle-faithful VHDL model of
-- paula_floppy.v's host receiver and disk-DMA logic (ported line by line
-- from CORE/Minimig_MiSTerMEGA65/rtl/paula_floppy.v: the IO_WAIT/stb7
-- two-phase clk7 handshake, cmd_cnt/cmd_fdd word counting, the tx_data mux,
-- the WORDSYNC gate trackrdok, fifo_wr + dsklen decrement, and the DISKDMA
-- state machine including the word-1 arming and the DSKBLK completion).
--
-- The physical path differs structurally from the ADF path in its frame
-- cadence: tiny 1..16-word data frames with w0/w1/w2 re-polls between them
-- instead of 544-word sector frames. This bench drives exactly that cadence:
-- feeder words arrive every few microseconds like real flux (so most frames
-- carry a single data word), the feeder emits free-running pre-lock junk
-- after every deselect (as the real front end does after a chain reset),
-- two full DMA attempts run back to back, the second with a co-selection
-- click on the other unit, and every word the Paula model stores is compared
-- against the feed ring.
--
-- Pass criteria per attempt:
--   * DSKBLK fires (the attempt completes),
--   * exactly DSKLEN (6400) words stored,
--   * the buffer starts with the sync word (serve-from-sync with WORDSYNC
--     off, as trackdisk uses it) and the stored sequence equals the feed ring
--     word for word,
--   * the engine's store signatures match the stored window,
--   * phys_data_o (the framing-hold gate source) is low through the hunt,
--     high for every stored word and low again after the DMA.
-- A single lost, duplicated, reordered or corrupted word fails with its
-- index.
--
-- Run: CORE/sim/floppy/run_fdd_regression.sh (cell engine_paula); a few
-- seconds.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use std.textio.all;

entity tb_engine_paula is
  generic (
    -- When set, every real physical read-FIFO pop is logged to this file
    -- with its clock-cycle timestamp. That pop stream is the stream main.vhd
    -- taps into Paula's DSKBYTR observation surface, so a cycle-exact diff
    -- of two traces shows whether an engine change alters what the Copylock
    -- timing loop observes. The condition mirrors the FIFO's own guard and
    -- the tap's qualifier: rd_en and not empty.
    G_POP_TRACE : string := ""
  );
end entity tb_engine_paula;

architecture sim of tb_engine_paula is

  constant C_CLK_PER  : time    := 35.242 ns;    -- 28.375 MHz core clock
  constant C_DSKLEN   : natural := 6400;         -- 0x1900 words per track read
  constant C_PUSH_CYC : natural := 113;          -- feeder word cadence ~4 us

  -- feed ring: 11 pseudo-sectors of the double-sync + random payload shape
  -- plus a track gap + splice junk. Correctness is checked by equality, so
  -- random payload is the strongest stimulus (any dropped/duplicated word
  -- misaligns the comparison immediately).
  constant C_SEC_WORDS : natural := 544;
  constant C_RING_LEN  : natural := 11 * C_SEC_WORDS + 350 + 5;
  type t_ring is array (0 to C_RING_LEN - 1) of std_logic_vector(15 downto 0);

  function f_build_ring return t_ring is
    variable ring  : t_ring;
    variable seed1 : positive := 20260726;
    variable seed2 : positive := 42;
    variable r     : real;
    variable w     : natural;
    variable idx   : natural := 0;
  begin
    for sec in 0 to 10 loop
      ring(idx + 0) := x"AAAA";
      ring(idx + 1) := x"AAAA";
      ring(idx + 2) := x"4489";
      ring(idx + 3) := x"4489";
      for k in 4 to C_SEC_WORDS - 1 loop
        loop
          uniform(seed1, seed2, r);
          w := integer(trunc(r * 65535.0));
          exit when w /= 16#4489#;               -- no accidental syncs
        end loop;
        ring(idx + k) := std_logic_vector(to_unsigned(w, 16));
      end loop;
      idx := idx + C_SEC_WORDS;
    end loop;
    for k in 0 to 349 loop                       -- track gap
      ring(idx + k) := x"AAAA";
    end loop;
    idx := idx + 350;
    ring(idx + 0) := x"2AA5";                    -- splice junk (never 0x4489)
    ring(idx + 1) := x"5245";
    ring(idx + 2) := x"9128";
    ring(idx + 3) := x"2AAA";
    ring(idx + 4) := x"AAAB";
    return ring;
  end function f_build_ring;

  constant C_RING : t_ring := f_build_ring;

  -- clocks / reset
  signal clk      : std_logic := '0';
  signal clk7_cnt : unsigned(1 downto 0) := "00";
  signal clk7_en  : std_logic := '0';
  signal rst      : std_logic := '1';

  -- engine <-> Paula-model io channel
  signal io_fpga   : std_logic;
  signal io_strobe : std_logic;
  signal io_din    : std_logic_vector(15 downto 0);
  signal io_dout   : std_logic_vector(15 downto 0) := (others => '0');
  signal io_wait   : std_logic := '0';

  -- engine <-> feeder (synthetic front-end FIFO, first-word-fall-through)
  signal frd_data  : std_logic_vector(15 downto 0);
  signal frd_empty : std_logic;
  signal frd_en    : std_logic;
  signal f_ridx    : natural := 3000;            -- read/write ring indexes:
  signal f_widx    : natural := 3000;            -- start mid-track (sector 5)
  signal f_depth   : natural := 0;               -- queue fill (max 32)
  signal f_junk_w  : natural := 0;               -- pre-lock junk still to push
  signal f_junk_r  : natural := 0;               -- pre-lock junk still to pop
  -- the physical /SEL1 of our unit: deasserted only between attempts. The
  -- co-selection click changes only Paula's priority-encoded sel field
  -- (sel_stat), not this line - the front-end chain does not reset then.
  signal phys_sel  : std_logic := '0';
  signal sel_del   : std_logic := '0';

  signal served_gray : std_logic_vector(15 downto 0);
  signal eng_sig     : std_logic_vector(15 downto 0);
  signal eng_ses     : std_logic_vector(7 downto 0);
  signal eng_done    : std_logic;
  signal eng_c64     : std_logic_vector(15 downto 0);
  signal eng_c256    : std_logic_vector(15 downto 0);

  -- ADKCON WORDSYNC as trackdisk leaves it (off; measured on hardware via
  -- diag 0x23 bit 8, and the ADF path stores gap words before the syncs):
  -- storing begins at the very first data word - the engine must therefore
  -- deliver a sync-aligned stream from word 0, like the ADF service does.
  constant C_WORDSYNC : std_logic := '0';

  -- free-running pre-lock junk the front end emits after a chain reset
  -- (deselect between attempts): legal-MFM-looking words at a wrong bit
  -- phase, never 0x4489
  constant C_JUNK_LEN : natural := 1000;
  type t_junk is array (0 to 3) of std_logic_vector(15 downto 0);
  constant C_JUNK : t_junk := (x"A4A5", x"12A9", x"AAA5", x"5551");

  -- Paula model state (names follow paula_floppy.v)
  signal stb7        : std_logic := '0';
  signal rx_data     : std_logic_vector(15 downto 0) := (others => '0');
  signal cmd_cnt     : unsigned(1 downto 0) := "00";
  signal cmd_fdd     : std_logic := '0';
  signal dsklen_len  : unsigned(13 downto 0) := (others => '0');
  signal dmaen       : std_logic := '0';
  signal trackrdok   : std_logic := '0';
  signal fifo_cnt    : unsigned(11 downto 0) := (others => '0');
  signal fifo_wr_del : std_logic := '0';
  signal blckint     : std_logic := '0';
  type t_dskstate is (DMA_IDLE, DMA_ACTIVE, DMA_INT);
  signal dskstate    : t_dskstate := DMA_IDLE;
  signal sel_stat    : std_logic_vector(1 downto 0) := "00";  -- status sel field

  -- derived (combinational, like the Verilog wires)
  signal lenzero   : std_logic;
  signal trackrd   : std_logic;
  signal stbdat    : std_logic;
  signal fifo_wr   : std_logic;
  signal tx_data   : std_logic_vector(15 downto 0);

  -- the engine's framing-hold gate exports (registered phys_data_o) -
  -- checked in the loop by p_phys_data_chk, since the splice TB drives its
  -- serving_data model directly and would not catch a broken register here
  signal phys_serving : std_logic;
  signal phys_data    : std_logic;
  signal idle_cnt     : natural := 0;

  -- stored words (what would reach chip RAM) + attempt bookkeeping
  constant C_MAX_STORE : natural := 2 * C_DSKLEN + 64;
  type t_store is array (0 to C_MAX_STORE - 1) of std_logic_vector(15 downto 0);
  signal stored    : t_store := (others => (others => '0'));
  signal store_wp  : natural := 0;
  signal arm_pulse : std_logic := '0';           -- driver: CPU DSKLEN writes
  signal att_done  : natural := 0;               -- sticky DSKBLK count

  function f_gray2bin(g : std_logic_vector) return unsigned is
    variable b : std_logic_vector(g'range);
  begin
    b(g'high) := g(g'high);
    for i in g'high - 1 downto g'low loop
      b(i) := b(i + 1) xor g(i);
    end loop;
    return unsigned(b);
  end function f_gray2bin;

begin

  clk <= not clk after C_CLK_PER / 2;

  clk7_grid : process (clk)
  begin
    if rising_edge(clk) then
      clk7_cnt <= clk7_cnt + 1;
      if clk7_cnt = "10" then                    -- next cycle is the en tick
        clk7_en <= '1';
      else
        clk7_en <= '0';
      end if;
    end if;
  end process clk7_grid;

  -----------------------------------------------------------------------------
  -- DUT: the real track engine (ADF side parked: nothing mounted)
  -----------------------------------------------------------------------------
  uut : entity work.adf_track_engine
    generic map (
      G_BASE_DF0 => (others => '0'),
      G_BASE_DF1 => (others => '0'),
      G_BASE_DF2 => (others => '0')
    )
    port map (
      clk_main_i          => clk,
      reset_i             => rst,
      bus_grant_i         => '1',
      disk_mounted_i      => "000",
      disk_tracks_i       => x"000000",
      write_en_i          => "000",
      wr_track_o          => open,
      wr_req_o            => open,
      wr_ack_i            => "000",
      adf_en_i            => "001",             -- df0 is a simulated drive
      phys_unit_i         => "01",              -- df1 is the real mechanism
      phys_en_i           => '1',
      phys_present_i      => '1',
      phys_rd_data_i      => frd_data,
      phys_rd_empty_i     => frd_empty,
      phys_rd_en_o        => frd_en,
      dsksync_o           => open,
      phys_serving_o      => phys_serving,
      phys_data_o         => phys_data,
      phys_served_gray_o  => served_gray,
      phys_sig_o          => eng_sig,
      phys_sig_ses_o      => eng_ses,
      phys_sig_done_o     => eng_done,
      phys_sig_c64_o      => eng_c64,
      phys_sig_c256_o     => eng_c256,
      io_fpga_o           => io_fpga,
      io_strobe_o         => io_strobe,
      io_din_o            => io_din,
      io_dout_i           => io_dout,
      io_wait_i           => io_wait,
      avm_busy_o          => open,
      avm_write_o         => open,
      avm_read_o          => open,
      avm_address_o       => open,
      avm_writedata_o     => open,
      avm_byteenable_o    => open,
      avm_burstcount_o    => open,
      avm_readdata_i      => (others => '0'),
      avm_readdatavalid_i => '0',
      avm_waitrequest_i   => '1'
    );

  -----------------------------------------------------------------------------
  -- the registered phys_data_o (the framing-hold gate source) checked in
  -- the loop against the real engine - the splice TB drives its own
  -- serving_data model, so only this TB catches a broken register here:
  --   (1) low through the bulk of the pre-serve hunt (the "not phys_hunt"
  --       term - the hold must not engage while serve-from-sync hunts),
  --   (2) high whenever Paula stores a served word,
  --   (3) back low shortly after the DMA ends.
  -- A stuck level, inverted polarity or dropped hunt term all fail.
  -----------------------------------------------------------------------------
  p_phys_data_chk : process (clk)
  begin
    if rising_edge(clk) then
      if fifo_wr = '1' then
        assert phys_data = '1'
          report "phys_data_o LOW while Paula stores a served word - the "
                 & "framing-hold gate source is broken" severity failure;
      end if;
      if trackrd = '1' and f_junk_r > 2 then
        assert phys_data = '0'
          report "phys_data_o HIGH during the pre-serve hunt - the hold "
                 & "would engage before serve-from-sync locked"
          severity failure;
      end if;
      if dskstate = DMA_IDLE and rst = '0' then
        if idle_cnt <= 2000 then
          idle_cnt <= idle_cnt + 1;
        else
          assert phys_data = '0'
            report "phys_data_o stuck HIGH after the DMA ended"
            severity failure;
        end if;
      else
        idle_cnt <= 0;
      end if;
    end if;
  end process p_phys_data_chk;

  -----------------------------------------------------------------------------
  -- feeder: the front-end word FIFO stand-in. One word arrives every
  -- C_PUSH_CYC clocks (~4 us, real-flux-like: the engine sees mostly one
  -- word per frame); FWFT read side identical to physical_fdd_wfifo.
  -----------------------------------------------------------------------------
  -- FWFT head: junk while the pre-lock budget of the current selection is
  -- not exhausted, then the ring from a header-sync position (the aligner
  -- locks AT a sector header, so the first aligned word is its first 0x4489)
  frd_data  <= C_JUNK(f_ridx mod 4) when f_junk_r > 0
               else C_RING(f_ridx mod C_RING_LEN);
  frd_empty <= '1' when f_depth = 0 else '0';

  -- the observation-tap stream, recorded when G_POP_TRACE is set
  gen_pop_trace : if G_POP_TRACE /= "" generate
    p_pop_trace : process
      file     ftr  : text;
      variable ln   : line;
      variable cyc  : natural := 0;
      variable npop : natural := 0;
    begin
      file_open(ftr, G_POP_TRACE, write_mode);
      loop
        wait until rising_edge(clk);
        cyc := cyc + 1;
        if frd_en = '1' and frd_empty = '0' then
          npop := npop + 1;
          write(ln, integer'image(cyc));
          writeline(ftr, ln);
        end if;
        if cyc mod 4000000 = 0 then
          report "pop trace: " & integer'image(npop) & " pops so far";
        end if;
      end loop;
    end process p_pop_trace;
  end generate gen_pop_trace;

  feeder : process (clk)
    variable push_cnt : natural := 0;
    variable d        : natural;
  begin
    if rising_edge(clk) then
      d := f_depth;
      if phys_sel = '1' and sel_del = '0' then
        -- (re)selected: chain reset happened - restart with pre-lock junk,
        -- then the ring from the first 0x4489 of sector 5 (base + 2)
        f_junk_w <= C_JUNK_LEN;
        f_junk_r <= C_JUNK_LEN;
        f_ridx   <= 5 * C_SEC_WORDS + 2;
        f_widx   <= 5 * C_SEC_WORDS + 2;
        d        := 0;
      else
        push_cnt := push_cnt + 1;
        if push_cnt >= C_PUSH_CYC then
          push_cnt := 0;
          if d < 32 then                         -- wfifo depth; never full here
            if f_junk_w > 0 then
              f_junk_w <= f_junk_w - 1;
            else
              f_widx <= (f_widx + 1) mod C_RING_LEN;
            end if;
            d := d + 1;
          end if;
        end if;
        if frd_en = '1' and f_depth > 0 then
          if f_junk_r > 0 then
            f_junk_r <= f_junk_r - 1;
            f_ridx   <= f_ridx + 1;              -- cycles the junk table
            if f_junk_r = 1 then
              f_ridx <= 5 * C_SEC_WORDS + 2;     -- ring resumes at the sync
            end if;
          else
            f_ridx <= (f_ridx + 1) mod C_RING_LEN;
          end if;
          d := d - 1;
        end if;
      end if;
      f_depth <= d;
      sel_del <= phys_sel;
    end if;
  end process feeder;

  -----------------------------------------------------------------------------
  -- Paula model: line-by-line port of paula_floppy.v (see header). wordsync
  -- is enabled, dsksync = 0x4489, enable (DMACON DSKEN) = 1, trackwr = 0.
  -----------------------------------------------------------------------------
  lenzero <= '1' when dsklen_len = 0 else '0';
  trackrd <= '1' when dskstate = DMA_ACTIVE and lenzero = '0' else '0';
  stbdat  <= cmd_fdd and stb7 when cmd_cnt = "11" else '0';
  fifo_wr <= trackrdok and stbdat and (not lenzero);

  -- tx_data mux (trackwr=0): 00 status / 01 dsksync / 1x {dmaen,dsklen}
  tx_data <= sel_stat & "01" & "00" & '0' & (trackrd and not fifo_cnt(10)) & x"00"
                when cmd_cnt = "00" else
             x"4489"
                when cmd_cnt = "01" else
             dmaen & '0' & std_logic_vector(dsklen_len);

  paula_rx : process (clk)
  begin
    if rising_edge(clk) then
      if io_fpga = '0' then                      -- ~IO_ENA async clear (1-clk
        io_wait <= '0';                          -- granularity is fine: the
        stb7    <= '0';                          -- inter-frame gap is 15 clks)
        cmd_cnt <= "00";
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
          end if;
        end if;
        if clk7_en = '1' and stb7 = '1' and cmd_cnt /= "11" then
          cmd_cnt <= cmd_cnt + 1;
        end if;
      end if;
    end if;
  end process paula_rx;

  paula_fdd : process (clk)
  begin
    if rising_edge(clk) then
      blckint <= '0';
      if clk7_en = '1' then
        -- cmd_fdd (sync clear like the source)
        if rst = '1' or io_fpga = '0' then
          cmd_fdd <= '0';
        elsif stb7 = '1' and cmd_cnt = "00" then
          if rx_data(15 downto 13) = "000" then
            cmd_fdd <= '1';
          else
            cmd_fdd <= '0';
          end if;
        end if;

        -- WORDSYNC gate (trackrdok <= ~wordsync | sync_match | trackrdok)
        if trackrd = '0' then
          trackrdok <= '0';
        elsif C_WORDSYNC = '0'
              or (rx_data = x"4489" and stbdat = '1' and trackrd = '1')
              or trackrdok = '1' then
          trackrdok <= '1';
        end if;

        -- store + dsklen decrement
        fifo_wr_del <= fifo_wr;
        if fifo_wr = '1' then
          stored(store_wp) <= rx_data;
          store_wp         <= store_wp + 1;
          dsklen_len       <= dsklen_len - 1;
          if fifo_cnt /= x"FFF" then
            fifo_cnt <= fifo_cnt + 1;
          end if;
        elsif fifo_cnt /= 0 then
          fifo_cnt <= fifo_cnt - 1;              -- DMA drains far faster than
        end if;                                  -- words arrive

        -- DMA state machine (word-1 arming, DSKBLK completion)
        case dskstate is
          when DMA_IDLE =>
            if cmd_fdd = '1' and stb7 = '1' and cmd_cnt = "01"
               and dmaen = '1' and lenzero = '0' then
              dskstate <= DMA_ACTIVE;
            end if;
          when DMA_ACTIVE =>
            if dmaen = '0' then
              dskstate <= DMA_IDLE;
            elsif lenzero = '1' and fifo_cnt = 0 and fifo_wr_del = '0' then
              dskstate <= DMA_INT;
            end if;
          when DMA_INT =>
            blckint  <= '1';
            dmaen    <= '0';
            dskstate <= DMA_IDLE;
        end case;
      end if;

      -- driver interface: arming (models the CPU's double DSKLEN write)
      if arm_pulse = '1' then
        dsklen_len <= to_unsigned(C_DSKLEN, 14);
        dmaen      <= '1';
      end if;
      if rst = '1' then
        dskstate   <= DMA_IDLE;
        dmaen      <= '0';
        dsklen_len <= (others => '0');
        trackrdok  <= '0';
        fifo_cnt   <= (others => '0');
      end if;
    end if;
  end process paula_fdd;

  att_counter : process (clk)
  begin
    if rising_edge(clk) then
      if blckint = '1' then
        att_done <= att_done + 1;
      end if;
    end if;
  end process att_counter;

  -----------------------------------------------------------------------------
  -- driver ("trackdisk"): two read attempts, then the word-exact check
  -----------------------------------------------------------------------------
  driver : process
    variable a0, a1  : natural;
    variable pos     : integer;
    variable ok      : boolean;
    variable mism    : natural;
    variable sigv    : std_logic_vector(15 downto 0);

    -- locate stored[a0..a0+7] in the ring; -1 if not found
    impure function f_align(a0 : natural) return integer is
      variable hit : boolean;
    begin
      for p in 0 to C_RING_LEN - 1 loop
        hit := true;
        for k in 0 to 7 loop
          if C_RING((p + k) mod C_RING_LEN) /= stored(a0 + k) then
            hit := false;
            exit;
          end if;
        end loop;
        if hit then
          return p;
        end if;
      end loop;
      return -1;
    end function f_align;

  begin
    wait for 200 ns;
    rst <= '0';
    wait for 3 ms;                               -- engine announce/poll cadence

    for attempt in 1 to 2 loop
      a0 := store_wp;
      sel_stat <= "01";                          -- trackdisk selects df1:
      phys_sel <= '1';                           -- the real /SEL1 asserts
      wait for 300 us;                           -- settle
      arm_pulse <= '1';                          -- CPU writes DSKLEN twice
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      arm_pulse <= '0';

      if attempt = 2 then
        -- co-selection scenario: 5 ms into the read (~word 1250 of 6400),
        -- the other unit's change-poll click briefly makes Paula's priority
        -- encoder report sel=df0 while trackrd stays 1 (the 2.5 s Amiga
        -- click against the ADF unit). The engine must keep streaming - any
        -- abort discards feeder words in ST_IDLE and rips a hole into the
        -- stored sequence, which the ring-exact check below catches.
        wait for 5 ms;
        sel_stat <= "00";
        wait for 2 ms;
        sel_stat <= "01";
      end if;

      wait until att_done = attempt for 300 ms;
      assert att_done = attempt
        report "A" & integer'image(attempt) & ": DSKBLK never fired"
        severity failure;
      a1 := store_wp;
      sel_stat <= "00";                          -- deselect between attempts
      phys_sel <= '0';                           -- (the real line too)

      report "A" & integer'image(attempt) & ": stored "
             & integer'image(a1 - a0) & " words";
      assert a1 - a0 = C_DSKLEN
        report "A" & integer'image(attempt) & ": stored "
               & integer'image(a1 - a0) & " words, expected "
               & integer'image(C_DSKLEN)
        severity failure;

      -- trackdisk sync-at-start expectation: the ADF path stores its first
      -- word-aligned 0x4489 at offset 2 (measured on hardware);
      -- a buffer that starts with pre-lock junk is what trackdisk rejects
      ok := false;
      for k in 0 to 2 loop
        if stored(a0 + k) = x"4489" then
          ok := true;
        end if;
      end loop;
      assert ok
        report "A" & integer'image(attempt)
               & ": no sync in the first 3 stored words - the buffer "
               & "starts with pre-lock junk (" & to_hstring(stored(a0))
               & " " & to_hstring(stored(a0 + 1)) & " ...)"
        severity failure;

      -- word-exact comparison against the feed ring
      pos := f_align(a0);
      assert pos >= 0
        report "A" & integer'image(attempt)
               & ": stored prefix not found in the feed ring"
        severity failure;
      -- with WORDSYNC=0 and the serve-from-sync gate, the buffer starts
      -- with the sync word itself
      assert stored(a0) = x"4489"
        report "A" & integer'image(attempt)
               & ": buffer does not start with the sync word (got "
               & to_hstring(stored(a0)) & ")"
        severity failure;
      ok   := true;
      mism := 0;
      for k in 0 to C_DSKLEN - 1 loop
        if stored(a0 + k) /= C_RING((pos + k) mod C_RING_LEN) then
          if ok then
            report "A" & integer'image(attempt) & ": FIRST MISMATCH at word "
                   & integer'image(k) & " got "
                   & to_hstring(stored(a0 + k)) & " want "
                   & to_hstring(C_RING((pos + k) mod C_RING_LEN))
              severity error;
          end if;
          ok   := false;
          mism := mism + 1;
        end if;
      end loop;
      assert ok
        report "A" & integer'image(attempt) & ": "
               & integer'image(mism) & " of " & integer'image(C_DSKLEN)
               & " stored words differ from the feed"
        severity failure;

      -- served-side signature must equal the XOR of the first 1024 stored
      -- words (same window by construction: Paula stores from the word
      -- after the sync match, the engine signs from there too) - and the
      -- 64/256-word checkpoint prefixes likewise
      sigv := (others => '0');
      for k in 0 to 1023 loop
        sigv := sigv xor stored(a0 + k);
        if k = 63 then
          assert eng_c64 = sigv
            report "A" & integer'image(attempt) & ": engine c64 "
                   & to_hstring(eng_c64) & " vs stored prefix "
                   & to_hstring(sigv)
            severity failure;
        elsif k = 255 then
          assert eng_c256 = sigv
            report "A" & integer'image(attempt) & ": engine c256 "
                   & to_hstring(eng_c256) & " vs stored prefix "
                   & to_hstring(sigv)
            severity failure;
        end if;
      end loop;
      assert eng_done = '1' and eng_sig = sigv
        report "A" & integer'image(attempt) & ": engine signature "
               & to_hstring(eng_sig) & " (done=" & std_logic'image(eng_done)
               & ") vs stored-window XOR " & to_hstring(sigv)
        severity failure;

      report "A" & integer'image(attempt)
             & " PASS: 6400 stored words ring-exact, signature "
             & to_hstring(sigv) & " matches";

      wait for 3 ms;                             -- inter-attempt gap
    end loop;

    report "served total (engine): "
           & integer'image(to_integer(f_gray2bin(served_gray)));
    assert to_integer(f_gray2bin(served_gray)) >= 2 * C_DSKLEN
      report "engine served fewer words than Paula stored"
      severity failure;

    report "TB_ENGINE_PAULA: ALL PASS";
    stop;
  end process driver;

end architecture sim;
