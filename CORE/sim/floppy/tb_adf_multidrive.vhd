---------------------------------------------------------------------------------------------------------
-- AExp: adf_track_engine multi-drive ownership testbench
--
-- The one defect class that silently corrupts a user's disk image is a write frame belonging to drive B
-- being decoded by a write decoder that was opened for drive A and then committed into A's image. This
-- testbench is the cheap place to catch it: on hardware the same bug looks like a randomly damaged .adf.
--
-- It drives the real adf_track_engine with a behavioural model of Paula's floppy host channel and a
-- behavioural Avalon slave, and checks:
--
--   T1  a clean df0 write commits 256 words at exactly base(df0) + track*2816 + sector*256 + k, with the
--       decoded payload, and raises the dirty-track event of df0 only
--   T2  the same for df1, into df1's pool
--   T3  a foreign unit selected between the header and the data section aborts the drain: nothing is
--       committed, in particular nothing into the first drive's image
--   T4  the same injection during the sync hunt and right after the sync word
--   T5  a write towards the Hardware Floppy unit is drained and discarded - no Avalon write at all
--   T6  rotation continuation is per drive: reading df0, then df1, then df0 again resumes df0 at its
--       own next sector, not at df1's and not at sector 0
--   T7  a foreign unit sampled during a running read DMA (Paula's sel field is a priority encoder,
--       so a change-poll click on another drive does exactly this) must not re-point the DMA at
--       that drive: every fetch has to stay inside the pool of the drive the session belongs to
--   T8  a physical write whose DMA words are valid AmigaDOS sectors, with a mounted and write-armed
--       ADF drive standing by at the same track, and a persisting foreign selection to that ADF drive
--       injected mid-stream. Without episode inheritance the engine re-latches the physical DMA's
--       remainder as an ADF-owned, committing drain, which decodes those valid sectors and writes them
--       into the ADF image - a user's .adf silently overwritten with data that belongs to a real
--       floppy. The assertion is absolute: zero Avalon writes.
--   T9  the mirror of T8: an ADF write whose binding poll sees the physical unit's code while the
--       mechanism is not selected (a deselect gap) must still reach df0's image
--   T10 the same with the mechanism at df0, where "nothing selected" and "df0 selected" share one code
--   T11 an ADF write is unaffected by a busy writer with a full write FIFO
--   T12 a reset inside an open write episode clears epi_bound, and the ADF path works afterwards
--
-- A global monitor additionally asserts, for every single Avalon write of the whole run, that the address
-- lies inside the pool of the drive the testbench currently expects to be draining.
--
-- Run: CORE/sim/floppy/run_fdd_regression.sh (cell multidrive); a few seconds.
--
-- MiSTer2MEGA65 (AExp Amiga 500 port) done by sy2002 in 2026 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_adf_multidrive is
   generic (
      -- Record every io-channel word the engine sends into this trace file.
      -- The word stream is the engine's entire externally visible behaviour
      -- towards Paula, so diffing the traces of two engine versions shows
      -- whether a change alters any ADF or read behaviour.
      G_TRACE_FILE : string  := "";
      -- true = run only the ADF-only workload (T1/T2/T6/T7) a trace
      -- comparison is defined over; false = the full ownership matrix.
      G_ADF_ONLY   : boolean := false;
      -- Configure the Hardware Floppy without ever exercising it: the same
      -- ADF-only workload runs with df2 present as the physical unit. Between
      -- two engine versions the traces should then differ at most in the
      -- announce word's writable nibble for that unit (paula_floppy.v
      -- discards it, so it is invisible to the Amiga).
      G_PHYS_CFG   : boolean := false
   );
end entity tb_adf_multidrive;

architecture sim of tb_adf_multidrive is

   constant C_CLK_PER  : time    := 35.242 ns;            -- 28.375 MHz core clock
   constant C_POLL     : natural := 40;                   -- shortened poll period

   -- the real HyperRAM pool bases from globals.vhd (word addresses)
   -- C_HMAP_ADF_DF<n>(9 downto 0) & x"000" from globals.vhd, i.e. window * 4096 words
   constant C_BASE0    : std_logic_vector(21 downto 0) := std_logic_vector(to_unsigned(16#200# * 4096, 22));
   constant C_BASE1    : std_logic_vector(21 downto 0) := std_logic_vector(to_unsigned(16#280# * 4096, 22));
   constant C_BASE2    : std_logic_vector(21 downto 0) := std_logic_vector(to_unsigned(16#300# * 4096, 22));
   constant C_POOL_W   : natural := 115 * 4096;           -- words per pool

   type t_base_arr is array (0 to 2) of unsigned(31 downto 0);
   constant C_BASE : t_base_arr := (resize(unsigned(C_BASE0), 32),
                                    resize(unsigned(C_BASE1), 32),
                                    resize(unsigned(C_BASE2), 32));

   constant C_SEC_WORDS : natural := 256;                 -- payload words per sector
   constant C_TRK_WORDS : natural := 2816;

   -- one written sector on the wire: sync + 25 header words + 516 data words
   constant C_HDR_LEN   : natural := 25;
   constant C_DAT_LEN   : natural := 516;
   constant C_JUNK_LEN  : natural := 6;                   -- pre-sync words the hunt must discard
   constant C_SEC_LEN   : natural := C_JUNK_LEN + 1 + C_HDR_LEN + C_DAT_LEN;

   type t_stream  is array (natural range <>) of std_logic_vector(15 downto 0);
   type t_payload is array (0 to C_SEC_WORDS - 1) of std_logic_vector(15 downto 0);

   -- deterministic payload, distinct per drive/track/sector so a cross-drive commit cannot pass by luck
   function f_payload(unit, track, sector : natural) return t_payload is
      variable p : t_payload;
      variable s : unsigned(15 downto 0);
   begin
      s := to_unsigned(((unit * 71 + track * 13 + sector * 7) * 1021) mod 65536, 16);
      for k in 0 to C_SEC_WORDS - 1 loop
         s    := s + to_unsigned((k * 37 + 1) mod 65536, 16);
         p(k) := std_logic_vector(s xor to_unsigned((k * 259) mod 65536, 16));
      end loop;
      return p;
   end function f_payload;

   function f_odd(b : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      return ('0' & b(7 downto 1)) and x"55";
   end function f_odd;

   function f_even(b : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      return b and x"55";
   end function f_even;

   -- Build the exact word sequence an Amiga writes for one sector, so that the engine's bit-exact
   -- FindSync / GetHeader / GetData decoder accepts it: junk, sync, sync, header, data.
   function f_one_sector(unit, track, sector : natural) return t_stream is
      variable s    : t_stream(0 to C_SEC_LEN - 1);
      variable pl   : t_payload := f_payload(unit, track, sector);
      variable ck   : std_logic_vector(7 downto 0);
      variable c0, c1, c2, c3 : std_logic_vector(7 downto 0);
      variable hi, lo : std_logic_vector(7 downto 0);
      variable idx  : natural;
      variable ow, ew : std_logic_vector(15 downto 0);
      variable t8, s8, g8 : std_logic_vector(7 downto 0);
   begin
      t8 := std_logic_vector(to_unsigned(track, 8));
      s8 := std_logic_vector(to_unsigned(sector, 8));
      g8 := std_logic_vector(to_unsigned(11 - sector, 8));

      -- pre-sync junk: never 0x4489, and never a legal sync by accident
      for k in 0 to C_JUNK_LEN - 1 loop
         s(k) := std_logic_vector(to_unsigned(16#AAA0# + k, 16));
      end loop;
      idx := C_JUNK_LEN;

      s(idx) := x"4489";                       -- the word FindSync hunts for
      idx    := idx + 1;

      -- header, exactly the 25 words the decoder consumes after the hunt
      s(idx + 0) := x"4489";                                 -- second sync
      s(idx + 1) := f_odd(x"FF")  & f_odd(t8);               -- info odd:  format, track
      s(idx + 2) := f_odd(s8)     & f_odd(g8);               -- info odd:  sector, gap
      s(idx + 3) := f_even(x"FF") & f_even(t8);              -- info even: format, track
      s(idx + 4) := f_even(s8)    & f_even(g8);              -- info even: sector, gap
      for k in 5 to 20 loop
         s(idx + k) := x"AAAA";                              -- 16 label words (pure clock)
      end loop;

      -- header checksum lanes, computed exactly like the decoder does
      c0 := s(idx + 1)(15 downto 8);
      c1 := s(idx + 1)( 7 downto 0);
      c2 := s(idx + 2)(15 downto 8);
      c3 := s(idx + 2)( 7 downto 0);
      c0 := c0 xor s(idx + 3)(15 downto 8);
      c1 := c1 xor s(idx + 3)( 7 downto 0);
      c2 := c2 xor s(idx + 4)(15 downto 8);
      c3 := c3 xor s(idx + 4)( 7 downto 0);
      for k in 5 to 20 loop
         hi := s(idx + k)(15 downto 8);
         lo := s(idx + k)( 7 downto 0);
         if (k mod 2) = 1 then
            c0 := c0 xor hi;
            c1 := c1 xor lo;
         else
            c2 := c2 xor hi;
            c3 := c3 xor lo;
         end if;
      end loop;
      s(idx + 21) := x"AAAA";                                -- stored checksum, odd halves
      s(idx + 22) := x"AAAA";                                -- (all zero after masking)
      s(idx + 23) := ((c0 and x"55") or x"AA") & ((c1 and x"55") or x"AA");
      s(idx + 24) := ((c2 and x"55") or x"AA") & ((c3 and x"55") or x"AA");
      idx := idx + C_HDR_LEN;

      -- data section: 4 checksum words, then the odd-bits pass and the even-bits pass
      for k in 0 to C_SEC_WORDS - 1 loop
         ow := ('0' & pl(k)(15 downto 1)) and x"5555";
         ew := pl(k) and x"5555";
         s(idx + 4 + k)   := ow;
         s(idx + 260 + k) := ew;
      end loop;
      c0 := (others => '0');
      c1 := (others => '0');
      c2 := (others => '0');
      c3 := (others => '0');
      for k in 0 to C_SEC_WORDS - 1 loop
         for pass in 0 to 1 loop
            if pass = 0 then
               hi := s(idx + 4 + k)(15 downto 8);
               lo := s(idx + 4 + k)( 7 downto 0);
            else
               hi := s(idx + 260 + k)(15 downto 8);
               lo := s(idx + 260 + k)( 7 downto 0);
            end if;
            if (k mod 2) = 0 then
               c0 := c0 xor hi;
               c1 := c1 xor lo;
            else
               c2 := c2 xor hi;
               c3 := c3 xor lo;
            end if;
         end loop;
      end loop;
      s(idx + 0) := x"AAAA";                                 -- stored checksum, odd halves
      s(idx + 1) := x"AAAA";
      s(idx + 2) := ((c0 and x"55") or x"AA") & ((c1 and x"55") or x"AA");
      s(idx + 3) := ((c2 and x"55") or x"AA") & ((c3 and x"55") or x"AA");

      return s;
   end function f_one_sector;

   -- Three consecutive sectors. T1..T7 serve only the first
   -- (fifo_arm = C_SEC_LEN); T8..T12 serve all three. The engine's WD_HUNT
   -- chunk is min(fifo_cnt, 1000) words, so with a single 548-word sector it
   -- consumes the entire stream inside one frame and a selection injected
   -- mid-stream never reaches a poll boundary - the cross-contamination
   -- hazard could not be reproduced at all, and T8 would pass even against
   -- an engine without episode inheritance. With 1644 words the first chunk
   -- leaves a whole intact, checksum-valid sector behind for a
   -- wrongly-owned drain to decode and commit.
   function f_build_sector(unit, track, sector : natural) return t_stream is
      variable s : t_stream(0 to 3 * C_SEC_LEN - 1);
   begin
      for rep in 0 to 2 loop
         s(rep * C_SEC_LEN to (rep + 1) * C_SEC_LEN - 1) :=
            f_one_sector(unit, track, (sector + rep) mod 11);
      end loop;
      return s;
   end function f_build_sector;

   -- clock / reset
   signal clk       : std_logic := '0';
   signal rst       : std_logic := '1';
   signal running   : boolean   := true;

   -- engine interface
   signal io_fpga   : std_logic;
   signal io_strobe : std_logic;
   signal io_din    : std_logic_vector(15 downto 0);
   signal io_dout   : std_logic_vector(15 downto 0) := (others => '0');
   signal io_wait   : std_logic := '0';

   signal avm_busy        : std_logic;
   signal avm_write       : std_logic;
   signal avm_read        : std_logic;
   signal avm_address     : std_logic_vector(31 downto 0);
   signal avm_writedata   : std_logic_vector(15 downto 0);
   signal avm_byteenable  : std_logic_vector( 1 downto 0);
   signal avm_burstcount  : std_logic_vector( 7 downto 0);
   signal avm_readdata    : std_logic_vector(15 downto 0) := (others => '0');
   signal avm_rdvalid     : std_logic := '0';
   signal avm_waitrequest : std_logic := '0';

   signal disk_mounted : std_logic_vector( 2 downto 0) := "111";
   signal disk_tracks  : std_logic_vector(23 downto 0) := x"A0" & x"A0" & x"A0";  -- 160 each
   signal write_en     : std_logic_vector( 2 downto 0) := "111";
   signal adf_en       : std_logic_vector( 2 downto 0) := "111";
   signal phys_en      : std_logic := '0';
   -- The physical unit's real per-drive select line. Paula's status sel
   -- field cannot stand in for it: its priority encoder reports 2'd0 both
   -- for "df0 selected" and for "nothing selected", so the engine must not
   -- bind a write episode as physical on that sample alone. Default '0' =
   -- the mechanism is not selected, which is what an ordinary deselect gap
   -- looks like; T8 raises it because there the physical drive really is
   -- selected.
   signal phys_sel     : std_logic := '0';
   -- scopes out the single-sector word-offset expectation (see the Avalon
   -- write checker); the drive-pool assertion stays live
   signal wr_relaxed   : std_logic := '0';
   -- The writer's inputs. At their entity defaults the engine sees an
   -- infinitely fast, never-busy writer, and neither the pacing loop nor the
   -- busy interlock is exercised; T11 drives them and runs a known-good ADF
   -- workload with the writer reporting busy and its FIFO full.
   signal phys_wr_busy  : std_logic := '0';
   signal phys_wr_level : unsigned(2 downto 0) := (others => '0');
   signal phys_wr_ok    : std_logic := '0';
   -- driven so the announce word's writable nibble for the physical unit
   -- (phys_present and phys_wr_ok) can actually be exercised
   signal phys_present  : std_logic := '0';
   signal phys_unit    : std_logic_vector(1 downto 0) := "10";

   signal wr_track   : std_logic_vector(7 downto 0);
   signal wr_req     : std_logic_vector(2 downto 0);
   signal wr_ack     : std_logic_vector(2 downto 0) := "000";

   -- Paula model, driven by the stimulus process
   signal sel_base   : std_logic_vector(1 downto 0) := "00";
   signal p_sel      : std_logic_vector(1 downto 0);
   signal p_trackwr  : std_logic := '0';
   signal p_trackrd  : std_logic := '0';
   signal p_track    : std_logic_vector(7 downto 0) := x"00";

   signal fifo       : t_stream(0 to 3 * C_SEC_LEN - 1) := (others => (others => '0'));
   signal fifo_rd    : natural := 0;                     -- next word the engine will pop
   signal fifo_len   : natural := 0;                     -- words still in the model FIFO
   signal pops       : natural := 0;                     -- total words popped this scenario
   signal fifo_arm   : natural := 0;                     -- words to (re)load on the next clr_tick
   signal clr_tick   : std_logic := '0';                 -- stimulus: start a new scenario

   -- selection injection: switch p_sel to inj_sel once "pops" reaches inj_at
   signal inj_at     : natural := 0;                     -- 0 = never
   signal inj_sel    : std_logic_vector(1 downto 0) := "00";
   signal inj_done   : boolean := false;

   -- Cap on the fifo_cnt the model reports in w2, so a drain spans several
   -- poll frames. Paula's FIFO really does fill gradually from Agnus (3
   -- words per scanline), whereas this model presents the whole stream at
   -- once; with the full count visible the engine legitimately consumes an
   -- entire sector inside one frame, and a selection injected mid-stream
   -- never reaches a poll boundary. That is an artefact of the model, not a
   -- property of the DUT, and it would make T8 unable to fail. Default 1000
   -- = the engine's own chunk size, which leaves T1..T7 unaffected.
   signal cnt_cap    : natural := 1000;

   -- The engine's bus grant. T8 pulses it low mid-stream: the global abort
   -- block then clears in_drain while the write episode stays bound, and
   -- the next poll re-latches a drain. That re-latch is the only path on
   -- which the episode-inheritance branch is reached at all - the ownership
   -- guard is suppressed inside an episode, so a foreign sel alone never
   -- clears in_drain and a T8 that only injected a selection could not tell
   -- an engine without inheritance from a correct one.
   signal bus_grant  : std_logic := '1';


   -- observation
   signal exp_unit   : natural := 0;                     -- pool an Avalon write may target
   signal exp_track  : natural := 0;
   signal exp_sector : natural := 0;
   signal wr_count   : natural := 0;                     -- Avalon writes since the last clear
   signal rd_count   : natural := 0;
   signal last_rd    : std_logic_vector(31 downto 0) := (others => '0');
   signal first_rd   : std_logic_vector(31 downto 0) := (others => '0');
   signal rd_seen    : boolean := false;
   signal rd_quiet   : natural := 0;                     -- clocks since the last Avalon read
   signal rd_guard   : natural := 3;                     -- 0..2: every read must stay inside
                                                         -- that drive's pool; 3 = guard off
   signal rd_foreign : natural := 0;                     -- reads that left it
   signal errors     : natural := 0;

   -- the io-channel trace recorder: every strobed word the engine puts on
   -- io_din is one line of G_TRACE_FILE
   signal trace_words : natural := 0;

   procedure check(cond : boolean; msg : string; signal err : inout natural) is
   begin
      if not cond then
         report "FAIL: " & msg severity error;
         err <= err + 1;
      end if;
   end procedure check;

begin

   ------------------------------------------------------------------------------------------------
   -- clock
   ------------------------------------------------------------------------------------------------
   clk <= not clk after C_CLK_PER / 2 when running else '0';

   ------------------------------------------------------------------------------------------------
   -- The io-channel trace recorder (G_TRACE_FILE). The engine's word stream
   -- is its entire externally visible behaviour towards Paula, so a
   -- byte-identical trace across two engine versions is the strongest
   -- statement of "nothing visible changed" that simulation can make.
   ------------------------------------------------------------------------------------------------
   trace_gen : if G_TRACE_FILE /= "" generate
      p_trace : process
         file     f  : text;
         variable l  : line;
         variable n  : natural := 0;
      begin
         file_open(f, G_TRACE_FILE, write_mode);
         while running loop
            wait until rising_edge(clk);
            if io_strobe = '1' then
               write(l, string'(to_hstring(io_din)));
               writeline(f, l);
               n := n + 1;
               trace_words <= n;
            end if;
         end loop;
         file_close(f);
         wait;
      end process p_trace;
   end generate trace_gen;

   ------------------------------------------------------------------------------------------------
   -- the device under test
   ------------------------------------------------------------------------------------------------
   dut : entity work.adf_track_engine
      generic map (
         G_BASE_DF0   => C_BASE0,
         G_BASE_DF1   => C_BASE1,
         G_BASE_DF2   => C_BASE2,
         G_POLL_DELAY => C_POLL
      )
      port map (
         clk_main_i          => clk,
         reset_i             => rst,
         bus_grant_i         => bus_grant,
         disk_mounted_i      => disk_mounted,
         disk_tracks_i       => disk_tracks,
         write_en_i          => write_en,
         wr_track_o          => wr_track,
         wr_req_o            => wr_req,
         wr_ack_i            => wr_ack,
         adf_en_i            => adf_en,
         phys_unit_i         => phys_unit,
         phys_en_i           => phys_en,
         phys_present_i      => phys_present,
         phys_sel_i          => phys_sel,
         phys_wr_busy_i      => phys_wr_busy,
         phys_wr_level_i     => phys_wr_level,
         phys_wr_ok_i        => phys_wr_ok,
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
         avm_waitrequest_i   => avm_waitrequest
      ); -- dut

   ------------------------------------------------------------------------------------------------
   -- Paula floppy host channel model: answers the engine's per-word handshake.
   -- io_wait rises one clock after the strobe and falls four clocks later, with io_dout valid.
   ------------------------------------------------------------------------------------------------
   paula : process (clk)
      variable w_idx    : natural range 0 to 3 := 0;
      variable wait_cnt : natural range 0 to 4 := 0;
      variable v_cnt    : natural;
      variable tick_d   : std_logic := '0';
      -- Paula decides at word 0 whether a frame is a read or a write frame and
      -- keeps that decision for the whole frame; the model must do the same, or
      -- a trackwr edge between word 0 and word 2 produces a frame that is half
      -- read and half write and the engine drains a phantom FIFO.
      variable v_wr     : std_logic := '0';
   begin
      if rising_edge(clk) then
         if clr_tick /= tick_d then
            tick_d   := clr_tick;
            fifo_rd  <= 0;
            fifo_len <= fifo_arm;
            pops     <= 0;
         end if;
         if io_fpga = '0' then
            w_idx    := 0;                                 -- Paula async-clears the word counter
            wait_cnt := 0;
         else
            if io_strobe = '1' then
               wait_cnt := 4;
               case w_idx is
                  when 0 =>                                -- status word
                     io_dout <= p_sel & "00" & "00" & p_trackwr & p_trackrd & p_track;
                     v_wr    := p_trackwr;
                     w_idx   := 1;
                  when 1 =>                                -- dsksync
                     io_dout <= x"4489";
                     w_idx   := 2;
                  when 2 =>                                -- write: FIFO fill, read: dmaen/dsklen
                     if v_wr = '1' then
                        v_cnt := fifo_len;
                        if v_cnt > 1000 then
                           v_cnt := 1000;
                        end if;
                        if v_cnt > cnt_cap then
                           v_cnt := cnt_cap;      -- see cnt_cap's comment
                        end if;
                        if v_cnt = 0 then
                           io_dout <= x"0000";             -- DMA over and FIFO empty: drain done
                        else
                           io_dout <= '1' & "000" & std_logic_vector(to_unsigned(v_cnt, 12));
                        end if;
                     else
                        io_dout <= x"9900";
                     end if;
                     w_idx := 3;
                  when others =>                           -- FIFO data words (write frames only)
                     if v_wr = '1' and fifo_len > 0 then
                        io_dout  <= fifo(fifo_rd);
                        fifo_rd  <= fifo_rd + 1;
                        fifo_len <= fifo_len - 1;
                        pops     <= pops + 1;
                     else
                        io_dout <= x"0000";
                     end if;
               end case;
            elsif wait_cnt /= 0 then
               wait_cnt := wait_cnt - 1;
            end if;
         end if;
         io_wait <= '0';
         if wait_cnt /= 0 then
            io_wait <= '1';
         end if;
      end if;
   end process paula;

   ------------------------------------------------------------------------------------------------
   -- unit-selection injection: flip the selected unit the moment the engine has consumed a
   -- given number of FIFO words, i.e. in a chosen phase of the write decoder
   ------------------------------------------------------------------------------------------------
   p_sel <= inj_sel when inj_done else sel_base;

   inject : process (clk)
      variable tick_d : std_logic := '0';
   begin
      if rising_edge(clk) then
         if clr_tick /= tick_d then
            tick_d   := clr_tick;
            inj_done <= false;
         elsif inj_at /= 0 and not inj_done and pops >= inj_at then
            inj_done <= true;
         end if;
      end if;
   end process inject;

   ------------------------------------------------------------------------------------------------
   -- Avalon slave model + the global ownership monitor
   ------------------------------------------------------------------------------------------------
   avm_waitrequest <= '0';

   avalon : process (clk)
      variable rd_pend : natural range 0 to 4 := 0;
      variable rd_addr : std_logic_vector(31 downto 0) := (others => '0');
      variable v_base  : unsigned(31 downto 0);
      variable v_off   : unsigned(31 downto 0);
      variable v_exp   : unsigned(31 downto 0);
      variable v_pl    : t_payload;
      variable v_word  : std_logic_vector(15 downto 0);
      variable tick_d  : std_logic := '0';
   begin
      if rising_edge(clk) then
         avm_rdvalid <= '0';
         if clr_tick /= tick_d then
            tick_d     := clr_tick;
            wr_count   <= 0;
            rd_count   <= 0;
            rd_foreign <= 0;
            rd_seen    <= false;
         end if;

         ---------------------------------------------------------------------------------------
         -- write: the ownership assertions of this whole testbench
         ---------------------------------------------------------------------------------------
         if avm_write = '1' and avm_waitrequest = '0' then
            v_base := C_BASE(exp_unit);
            v_off  := unsigned(avm_address) - v_base;
            -- (a) inside the expected drive's pool at all
            assert unsigned(avm_address) >= v_base and v_off < C_POOL_W
               report "FAIL: Avalon write outside the expected drive pool" severity error;
            -- (b) at the exact sector word the model wrote. This is a
            -- single-sector expectation (exp_sector plus the running
            -- wr_count), so a scenario that deliberately queues several
            -- sectors and does not control which of them survives a
            -- re-latch scopes it out with wr_relaxed. Assertion (a) - the
            -- write landed in the expected drive's pool - is the ownership
            -- property and always applies.
            v_exp := v_base
                     + to_unsigned(exp_track * C_TRK_WORDS + exp_sector * C_SEC_WORDS + wr_count, 32);
            assert unsigned(avm_address) = v_exp or wr_relaxed = '1'
               report "FAIL: Avalon write to the wrong image offset" severity error;
            -- (c) carrying the payload of that drive, byte-swapped back to HyperRAM packing
            v_pl   := f_payload(exp_unit, exp_track, exp_sector);
            v_word := v_pl(wr_count mod C_SEC_WORDS);
            assert avm_writedata = v_word(7 downto 0) & v_word(15 downto 8)
                   or wr_relaxed = '1'
               report "FAIL: Avalon write data does not match the decoded sector" severity error;
            wr_count <= wr_count + 1;
         end if;

         ---------------------------------------------------------------------------------------
         -- read: deterministic content, plus address bookkeeping for the rotation test
         ---------------------------------------------------------------------------------------
         if rd_quiet < 100000 then
            rd_quiet <= rd_quiet + 1;
         end if;
         if avm_read = '1' and avm_waitrequest = '0' then
            rd_quiet <= 0;
            if rd_guard < 3 then
               v_base := C_BASE(rd_guard);
               if unsigned(avm_address) < v_base
                  or unsigned(avm_address) - v_base >= C_POOL_W then
                  rd_foreign <= rd_foreign + 1;
               end if;
            end if;
            rd_pend  := 3;
            rd_addr  := avm_address;
            last_rd  <= avm_address;
            if not rd_seen then
               first_rd <= avm_address;
               rd_seen  <= true;
            end if;
            rd_count <= rd_count + 1;
         elsif rd_pend > 1 then
            rd_pend := rd_pend - 1;
         elsif rd_pend = 1 then
            rd_pend     := 0;
            avm_readdata <= rd_addr(15 downto 0) xor x"5A5A";
            avm_rdvalid  <= '1';
         end if;
      end if;
   end process avalon;

   ------------------------------------------------------------------------------------------------
   -- dirty-track event acknowledge: mirror the request toggles like the mount wrappers do
   ------------------------------------------------------------------------------------------------
   ack : process (clk)
   begin
      if rising_edge(clk) then
         wr_ack <= wr_req;
      end if;
   end process ack;

   ------------------------------------------------------------------------------------------------
   -- stimulus
   ------------------------------------------------------------------------------------------------
   stim : process

      procedure idle(n : natural) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure idle;

      -- load one sector's write stream and let the engine drain it
      -- The Amiga selects a drive and only then starts writing, so the model must
      -- do the same: let any previous drain wind down, publish the new selection
      -- and the fresh write stream, and raise trackwr last. Raising it together
      -- with the selection would hand the tail of the previous drain a full FIFO.
      procedure arm_write(unit, track, sector : natural; at_pop : natural; to_sel : natural) is
      begin
         p_trackwr  <= '0';
         p_trackrd  <= '0';
         idle(400);
         fifo       <= f_build_sector(unit, track, sector);
         fifo_arm   <= C_SEC_LEN;
         inj_at     <= at_pop;
         inj_sel    <= std_logic_vector(to_unsigned(to_sel, 2));
         exp_unit   <= unit;
         exp_track  <= track;
         exp_sector <= sector;
         sel_base   <= std_logic_vector(to_unsigned(unit, 2));
         p_track    <= std_logic_vector(to_unsigned(track, 8));
         wait until rising_edge(clk);
         clr_tick   <= not clr_tick;
         idle(4);
         p_trackwr  <= '1';
         wait until rising_edge(clk);
      end procedure arm_write;

      procedure end_write is
      begin
         p_trackwr <= '0';
         inj_at    <= 0;
         idle(200);
      end procedure end_write;

      -- ask the engine to serve reads of one drive for a while
      -- same discipline for reads: drop trackrd, let the engine return to polling,
      -- then select the drive and raise trackrd, so that the first fetch the
      -- monitor records really belongs to the new drive
      procedure arm_read(unit, track : natural) is
      begin
         -- stop the previous drive and wait until the engine has really finished
         -- its current sector, so the first fetch recorded below is the new one
         p_trackwr <= '0';
         p_trackrd <= '0';
         idle(20);
         -- one more sector fetch still follows the last stream (ST_STREAM_DATA hands
         -- over to ST_SERVE before the status re-check aborts), so the bus must be
         -- quiet for longer than a whole sector cycle
         while rd_quiet < 10000 loop
            wait until rising_edge(clk);
         end loop;
         fifo_arm  <= 0;
         inj_at    <= 0;
         sel_base  <= std_logic_vector(to_unsigned(unit, 2));
         p_track   <= std_logic_vector(to_unsigned(track, 8));
         wait until rising_edge(clk);
         clr_tick  <= not clr_tick;
         idle(4);
         p_trackrd <= '1';
         wait until rising_edge(clk);
      end procedure arm_read;

      variable v_req0  : std_logic_vector(2 downto 0);
      variable v_req0b : std_logic_vector(2 downto 0);
      variable v_base : unsigned(31 downto 0);
      -- direct observation of the episode latch (VHDL-2008 external name):
      -- only the engine knows whether an episode is still bound, and T12 is
      -- about exactly that surviving a reset.
      alias dbg_epi_bound is << signal .tb_adf_multidrive.dut.epi_bound
                                : std_logic >>;
      variable v_sec0 : natural;
      variable v_res  : natural;

   begin
      report "=== adf_track_engine multi-drive ownership testbench ===";
      rst <= '1';
      idle(20);
      rst <= '0';
      idle(50);

      if G_PHYS_CFG then
         -- present, enabled and write-qualified, but nothing in the workload
         -- ever selects or streams it. present+wr_ok set the announce word's
         -- writable nibble for this unit, so this is the arm in which that
         -- io-channel difference actually appears - with them low a trace
         -- comparison would pass vacuously.
         adf_en       <= "011";
         phys_en      <= '1';
         phys_unit    <= "10";
         phys_present <= '1';
         phys_wr_ok   <= '1';
         idle(20);
      end if;

      ---------------------------------------------------------------------------------------
      report "T1: clean write into df0";
      ---------------------------------------------------------------------------------------
      v_req0 := wr_req;
      arm_write(0, 7, 3, 0, 0);
      -- one sector = 542 words at ~8 clocks per word plus frame overhead
      idle(40000);
      check(wr_count = C_SEC_WORDS, "df0 write did not commit exactly one sector", errors);
      check(wr_req /= v_req0, "df0 dirty-track event never fired", errors);
      check(wr_req(1) = v_req0(1) and wr_req(2) = v_req0(2),
            "a foreign drive's dirty-track event fired", errors);
      check(wr_track = std_logic_vector(to_unsigned(7, 8)), "dirty track number is wrong", errors);
      end_write;

      ---------------------------------------------------------------------------------------
      report "T2: clean write into df1";
      ---------------------------------------------------------------------------------------
      v_req0 := wr_req;
      arm_write(1, 20, 5, 0, 0);
      idle(40000);
      check(wr_count = C_SEC_WORDS, "df1 write did not commit exactly one sector", errors);
      check(wr_req(1) /= v_req0(1), "df1 dirty-track event never fired", errors);
      check(wr_req(0) = v_req0(0) and wr_req(2) = v_req0(2),
            "a foreign drive's dirty-track event fired", errors);
      end_write;

      ---------------------------------------------------------------------------------------
      report "T3: df0 drain, df1 selected between the header and the data section";
      ---------------------------------------------------------------------------------------
      -- the hunt discards C_JUNK_LEN words and consumes the sync word, the header is 25 words
      arm_write(0, 9, 2, C_JUNK_LEN + 1 + C_HDR_LEN, 1);
      idle(40000);
      check(wr_count = 0, "a drain hijacked by another unit still committed", errors);
      end_write;

      ---------------------------------------------------------------------------------------
      report "T4a: df0 drain, df1 selected during the sync hunt";
      ---------------------------------------------------------------------------------------
      arm_write(0, 11, 4, 2, 1);
      idle(40000);
      check(wr_count = 0, "a drain hijacked during the hunt still committed", errors);
      end_write;

      ---------------------------------------------------------------------------------------
      report "T4b: df1 drain, df0 selected right after the sync word";
      ---------------------------------------------------------------------------------------
      arm_write(1, 13, 6, C_JUNK_LEN + 1, 0);
      idle(40000);
      check(wr_count = 0, "a drain hijacked after the sync word still committed", errors);
      end_write;

      ---------------------------------------------------------------------------------------
      v_req0b := wr_req;
      report "T5: write towards the Hardware Floppy unit is drained and discarded";
      ---------------------------------------------------------------------------------------
      if not G_ADF_ONLY then
         adf_en   <= "011";                                -- df2 is the physical drive
         phys_en  <= '1';
         phys_unit <= "10";
         idle(10);
         arm_write(2, 15, 1, 0, 0);
         idle(40000);
         check(wr_count = 0, "a physical-unit write reached the Avalon bus", errors);
         end_write;
         adf_en  <= "111";
         phys_en <= '0';
         idle(10);
      end if;

      ---------------------------------------------------------------------------------------
      report "T6: rotation continuation is per drive";
      ---------------------------------------------------------------------------------------
      -- df0, track 7: let several sectors stream so that df0's rotation position moves away
      -- from sector 0, then remember where it stood
      arm_read(0, 7);
      idle(40000);
      check(rd_count > 0, "df0 read never fetched anything", errors);
      v_base := C_BASE(0) + to_unsigned(7 * C_TRK_WORDS, 32);
      v_sec0 := to_integer((unsigned(last_rd) - v_base) / C_SEC_WORDS) mod 11;
      report "   df0 stopped inside sector " & integer'image(v_sec0);

      -- df1, track 20: its own, untouched rotation state, so it must start at sector 0
      arm_read(1, 20);
      idle(20000);
      v_base := C_BASE(1) + to_unsigned(20 * C_TRK_WORDS, 32);
      check(rd_seen and unsigned(first_rd) = v_base,
            "df1 did not start its own track at sector 0", errors);

      -- back to df0: it must resume at its own position - the sector it was serving or the
      -- next one, depending on whether that sector's stream had completed - and never at
      -- df1's position or at sector 0 (unless it legitimately wrapped there)
      arm_read(0, 7);
      idle(20000);
      v_base := C_BASE(0) + to_unsigned(7 * C_TRK_WORDS, 32);
      check(rd_seen, "df0 did not resume reading", errors);
      check(unsigned(first_rd) >= v_base and unsigned(first_rd) < v_base + 11 * C_SEC_WORDS,
            "df0 resumed outside its own track", errors);
      v_res := to_integer((unsigned(first_rd) - v_base) / C_SEC_WORDS) mod 11;
      report "   df0 resumed at sector " & integer'image(v_res);
      check(v_res = v_sec0 or v_res = (v_sec0 + 1) mod 11,
            "df0 did not resume at its own rotation position", errors);
      ---------------------------------------------------------------------------------------
      report "T8: a physical write + a persisting foreign ADF sel must never commit";
      ---------------------------------------------------------------------------------------
      if not G_ADF_ONLY then
      -- df2 is the physical drive; df0 stays mounted and write-armed at the
      -- very track the injected sectors carry, so a wrongly-owned drain has
      -- everything it needs to commit. The stream is built for unit 0 so its
      -- header track matches df0's status track - i.e. the commit gate would
      -- be satisfied if ownership ever slipped.
      adf_en    <= "011";
      phys_en   <= '1';
      phys_unit <= "10";
      -- report only a few words per poll, so the drain spans many frames and
      -- the injected selection actually lands at a poll boundary with a full
      -- sector still to come (see cnt_cap)
      idle(10);
      p_trackwr  <= '0';
      p_trackrd  <= '0';
      idle(400);
      fifo       <= f_build_sector(0, 9, 2);      -- valid sectors, df0's track
      fifo_arm   <= 3 * C_SEC_LEN;                -- 1644 words: see f_build_sector
      -- Persist the foreign selection from a pop before the sync word and
      -- never take it back: a persisting foreign selection, not the one-poll
      -- click of T3/T4. The injection sits inside the
      -- engine's first 1000-word WD_HUNT chunk, so the next poll boundary
      -- finds a foreign owner with complete sectors still queued; injecting
      -- at word 2 would be consumed inside the same frame and never reach a
      -- poll at all.
      inj_at     <= 200;
      inj_sel    <= "00";                          -- the mounted ADF drive
      exp_unit   <= 0;
      exp_track  <= 9;
      exp_sector <= 2;
      sel_base   <= "10";                          -- the physical unit
      -- this is a genuine physical write, so the mechanism's own select
      -- line is asserted: the engine is entitled to bind the episode
      phys_sel   <= '1';
      p_track    <= std_logic_vector(to_unsigned(9, 8));
      wait until rising_edge(clk);
      clr_tick   <= not clr_tick;
      idle(4);
      p_trackwr  <= '1';
      wait until rising_edge(clk);
      -- Let the drain get going, then drop the bus grant briefly. The abort
      -- block clears in_drain while leaving the write itself pending, so the
      -- next poll re-latches the drain - and with the foreign selection
      -- persisting, that re-latch is where a wrongly re-owned drain would
      -- start decoding this write into the other drive's image.
      -- Trigger on real progress, not on a fixed delay: the abort has to
      -- land after the injection at pop 200 and while whole sectors are
      -- still queued, and the pop rate depends on the poll cadence.
      while pops < 300 loop
         wait until rising_edge(clk);
      end loop;
      check(fifo_len > C_SEC_LEN and p_sel /= sel_base,
            "T8: the abort was reached with the wrong preconditions - a whole "
            & "sector must still be queued and the foreign unit selected, or "
            & "the re-latch below proves nothing", errors);
      bus_grant <= '0';
      idle(300);
      bus_grant <= '1';
      idle(200000);
      check(wr_count = 0,
            "T8: a physical write was committed into an ADF image after a persisting foreign "
            & "selection - the episode did not keep physical ownership", errors);
      check(wr_req = v_req0b,
            "T8: a dirty-track event fired for a physical write", errors);
      end_write;
      idle(10);

      ---------------------------------------------------------------------------------------
      report "T9: an ADF write must not be bound to the physical unit by a deselect gap";
      ---------------------------------------------------------------------------------------
      -- The mirror of T8. Paula's status sel field is priority-encoded and
      -- its "nothing selected" default is 2'd0 (the sel encoder in
      -- paula_floppy.v), so with the mechanism at df0 an ordinary deselect
      -- gap is indistinguishable from "the physical unit is selected".
      -- Binding a write episode as physical is irreversible - it suspends the
      -- ownership guard for the whole episode and pins drain_commit at '0' -
      -- so a bind on such a sample would route an ordinary .adf track write
      -- into the physical write FIFO and commit nothing at all, silently,
      -- while Paula's DMA completes and DSKBLK fires. The engine therefore
      -- qualifies the bind with the real select line. Here the binding poll
      -- sees the physical unit with the mechanism not selected; the write
      -- must still reach df0's image.
      p_trackwr  <= '0';
      p_trackrd  <= '0';
      idle(400);
      adf_en     <= "011";
      phys_en    <= '1';
      phys_unit  <= "10";
      phys_sel   <= '0';                           -- the deselect gap
      fifo       <= f_build_sector(0, 9, 2);
      fifo_arm   <= 3 * C_SEC_LEN;
      inj_at     <= 200;
      inj_sel    <= "00";                          -- the real ADF target
      exp_unit   <= 0;
      exp_track  <= 9;
      exp_sector <= 2;
      sel_base   <= "10";                          -- what the binding poll sees
      wr_relaxed <= '1';   -- several sectors are queued; which one survives
                           -- the re-latch is not the property under test
      p_track    <= std_logic_vector(to_unsigned(9, 8));
      wait until rising_edge(clk);
      clr_tick   <= not clr_tick;
      idle(4);
      p_trackwr  <= '1';
      idle(400000);
      check(wr_count > 0,
            "T9: an ADF track write was silently discarded - the episode bound itself to the "
            & "physical unit on one sel sample taken during a deselect gap, so nothing was "
            & "ever committed to the image", errors);
      end_write;
      wr_relaxed <= '0';
      idle(10);

      ---------------------------------------------------------------------------------------
      report "T10: combo B - the mechanism at df0, an ADF write on df1, in a deselect gap";
      ---------------------------------------------------------------------------------------
      -- The sharpest geometry. Paula's priority encoder returns 2'd0 for
      -- "nothing selected" as well as for "df0 selected", so when the
      -- Hardware Floppy is the df0 unit (df0:HW + df1:ADF) a deselect gap is
      -- literally indistinguishable from "the physical unit is selected".
      -- T9 checks the qualifier with the mechanism at df2; this checks it
      -- where the ambiguity is real.
      p_trackwr  <= '0';
      p_trackrd  <= '0';
      idle(400);
      adf_en     <= "110";                         -- df1 + df2 are images
      phys_en    <= '1';
      phys_unit  <= "00";                          -- the mechanism is df0
      phys_sel   <= '0';                           -- ... and it is not selected
      fifo       <= f_build_sector(1, 9, 2);       -- df1's image, df1's track
      fifo_arm   <= 3 * C_SEC_LEN;
      inj_at     <= 200;
      inj_sel    <= "01";                          -- the real ADF target, df1
      exp_unit   <= 1;
      exp_track  <= 9;
      exp_sector <= 2;
      sel_base   <= "00";                          -- the deselect-gap reading
      wr_relaxed <= '1';
      p_track    <= std_logic_vector(to_unsigned(9, 8));
      wait until rising_edge(clk);
      clr_tick   <= not clr_tick;
      idle(4);
      p_trackwr  <= '1';
      idle(400000);
      check(wr_count > 0,
            "T10: with the mechanism at df0 a deselect gap read as 'the physical unit is "
            & "selected' and bound df1's ADF write as physical - the whole track write was "
            & "discarded", errors);
      end_write;
      wr_relaxed <= '0';
      adf_en    <= "111";
      phys_en   <= '0';
      phys_unit <= "10";
      phys_sel  <= '0';
      cnt_cap   <= 1000;
      idle(10);

      ---------------------------------------------------------------------------------------
      report "T12: a reset inside an open write episode must not strand epi_bound";
      ---------------------------------------------------------------------------------------
      -- The global abort deliberately keeps an open episode (Paula still
      -- holds trackwr until the host drains its FIFO). A reset destroys
      -- Paula's DMA outright, so the episode-end branches may never run, and
      -- a stale epi_bound = '1' carried into a later DMA would make the next
      -- episode skip its bind: it would inherit instead, and a physical write
      -- would silently not reach the disk. trackdisk has no write verify, so
      -- nothing would notice. This scenario checks that the reset clears
      -- epi_bound.
      p_trackwr  <= '0';
      p_trackrd  <= '0';
      idle(400);
      adf_en     <= "011";
      phys_en    <= '1';
      phys_unit  <= "10";
      phys_sel   <= '1';                           -- a genuine physical write
      fifo       <= f_build_sector(2, 11, 1);
      fifo_arm   <= 3 * C_SEC_LEN;
      inj_at     <= 0;
      inj_sel    <= "10";
      sel_base   <= "10";
      wr_relaxed <= '1';
      p_track    <= std_logic_vector(to_unsigned(11, 8));
      wait until rising_edge(clk);
      clr_tick   <= not clr_tick;
      idle(4);
      p_trackwr  <= '1';
      idle(20000);                                 -- let the episode bind
      check(dbg_epi_bound = '1',
            "T12: no episode was open when the reset was injected - the scenario proves "
            & "nothing", errors);
      rst <= '1';                                  -- the Amiga resets mid-write
      idle(50);
      rst <= '0';
      p_trackwr <= '0';                            -- the DMA died with it
      idle(20000);
      check(dbg_epi_bound = '0',
            "T12: epi_bound survived a reset that destroyed the write DMA - the next episode "
            & "will skip its bind and inherit, so a physical write would silently never reach "
            & "the disk", errors);
      end_write;
      wr_relaxed <= '0';
      phys_sel   <= '0';
      phys_en    <= '0';
      adf_en     <= "111";
      idle(200);
      -- and the ADF path must still work afterwards
      arm_write(0, 12, 4, 0, 0);
      idle(300000);
      check(wr_count > 0,
            "T12: an ADF write after a reset-in-episode committed nothing", errors);
      end_write;
      idle(10);

      ---------------------------------------------------------------------------------------
      report "T11: an ADF write must be unaffected by a busy writer with a full write FIFO";
      ---------------------------------------------------------------------------------------
      -- At their entity defaults phys_wr_busy_i / phys_wr_level_i /
      -- phys_wr_ok_i describe a writer that is never busy and infinitely
      -- fast. The busy interlock and the pacing loop are gated on the
      -- physical unit being selected, so an ADF write must not notice either;
      -- this scenario checks it with the writer busy and its FIFO full.
      phys_en       <= '1';
      phys_unit     <= "10";
      phys_sel      <= '0';
      phys_wr_busy  <= '1';                        -- the writer is draining
      phys_wr_level <= "011";                      -- and its CDC FIFO is full
      phys_wr_ok    <= '1';
      idle(200);
      arm_write(0, 9, 2, 0, 0);          -- no foreign injection: a plain write
      idle(300000);
      check(wr_count > 0,
            "T11: an ADF write committed nothing while the writer was busy - the physical "
            & "write pacing or the busy interlock leaked into the ADF path", errors);
      end_write;
      phys_wr_busy  <= '0';
      phys_wr_level <= (others => '0');
      phys_wr_ok    <= '0';
      phys_en       <= '0';
      idle(10);
      end if;

      ---------------------------------------------------------------------------------------
      report "T7: a foreign unit sampled during a running read must not steal the DMA";
      ---------------------------------------------------------------------------------------
      arm_read(0, 30);
      idle(8000);                                  -- let the session get going
      rd_guard   <= 0;                             -- from here: df0's pool only
      idle(10);
      sel_base   <= "01";                          -- the change-poll click on df1
      idle(30000);
      sel_base   <= "00";
      idle(10000);
      check(rd_foreign = 0, "a foreign unit selection re-pointed a running read DMA", errors);
      rd_guard  <= 3;
      p_trackrd <= '0';
      idle(200);

      ---------------------------------------------------------------------------------------
      idle(10);
      if errors = 0 then
         report "=== ALL TESTS PASSED ===" severity note;
      else
         report "=== " & integer'image(errors) & " CHECK(S) FAILED ===" severity failure;
      end if;
      running <= false;
      wait;
   end process stim;

end architecture sim;
