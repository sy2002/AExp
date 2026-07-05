---------------------------------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- adf_mount_wrapper: QNICE device 0x0103 (C_DEV_AMIGA_ADF) - the ADF mount buffer in HyperRAM
--
-- The M2M Shell's OSM file browser loads the selected .ADF byte by byte into this device
-- (C_CRTROMTYPE_DEVICE manual load; see CORE/vhdl/globals.vhd). The device has two faces:
--
--   * 4k windows 0x0000.. : byte-window bridge into HyperRAM. Each QNICE word address holds ONE
--     file byte; the bridge packs two bytes per 16-bit HyperRAM word (even file offset -> word
--     bits 7:0, odd offset -> bits 15:8, i.e. little-endian-in-word) at word base G_BASE_ADDRESS.
--     NOTE for readers: Amiga data is big-endian, so the track engine byte-swaps on read-back.
--   * 4k window 0xFFFF   : the M2M CSR protocol (M2M/vhdl/qnice_csr.vhd). The Shell writes
--     STATUS=ST_LDNG before streaming, then file size + STATUS=ST_OK, then polls PARSEST until
--     the core answers READY or ERROR (M2M/rom/crts-and-roms.asm, HANDLE_CRTROM_M).
--   * 4k window 0xFFFE   : the write-back CSR (WBC) - the ADF write support's core<->firmware
--     interface (see .research/INTEGRATION-SPEC-floppy-adf-write.md). The track engine commits
--     Amiga-written sectors into HyperRAM and queues the track number over a two-phase toggle
--     handshake (CDC in mega65.vhd); this wrapper collects them in a 166-bit dirty bitmap and
--     runs the vdrives-style anti-thrashing ms-countdown. The firmware (HANDLE_CORE_IO in
--     CORE/m2m-rom/m2m-rom.asm) polls the bitmap, clears a track's bit (write-1-to-clear)
--     BEFORE reading the track through the byte window and flushing it to the SD card file.
--     Registers (word offsets): 0x000 CTRL (bit0 WR_EN, firmware-armed "disk is writable"),
--     0x001 STAT (bit0 any_dirty, bit1 flush_start), 0x002 anti-thrash delay in ms (default
--     2000, firmware loads config.vhd's VD_ANTI_THRASHING_DELAY), 0x010..0x01A DIRTY0..10
--     (track = word*16 + bit; W1C, a same-cycle hardware set wins over the clear).
--
-- The "parser" here is a trivial ADF validator in the QNICE clock domain: it divides the file
-- size by 5632 (11 sectors x 512 bytes per track) via iterative subtraction and accepts exactly
-- 160..166 tracks (80-cylinder standard ADF plus 81..83-cylinder overdumps). On success it
-- reports the disk as mounted and exposes the track count; both signals are CDC'd to the core
-- clock in mega65.vhd. STATUS=ST_LDNG (start of every load) drops "mounted" - that seconds-long
-- gap is the eject window that lets Kickstart's disk-change logic see an ADF swap.
--
-- This is a faithful clone of C64MEGA65's proven parts: CORE/vhdl/mount_buf_wrapper.vhd (the
-- byte-window QNICE<->HyperRAM bridge + avm_fifo CDC) and the qnice_csr arm of
-- CORE/vhdl/sw_cartridge_csr.vhd, with the CRT parser replaced by the size validator.
--
-- MiSTer2MEGA65 (AExp Amiga 500 port) done in July 2026 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.qnice_csr_pkg.all;

entity adf_mount_wrapper is
   generic (
      -- HyperRAM word base address = C_HMAP_ADF_DF0(9 downto 0) & X"000" (see globals.vhd)
      G_BASE_ADDRESS : std_logic_vector(21 downto 0)
   );
   port (
      -- QNICE clock domain: the C_DEV_AMIGA_ADF device (4k-window byte protocol + CSR)
      qnice_clk_i          : in  std_logic;
      qnice_rst_i          : in  std_logic;
      qnice_addr_i         : in  std_logic_vector(27 downto 0);
      qnice_data_i         : in  std_logic_vector(15 downto 0);
      qnice_ce_i           : in  std_logic;
      qnice_we_i           : in  std_logic;
      qnice_data_o         : out std_logic_vector(15 downto 0);
      qnice_wait_o         : out std_logic;

      -- Mount status to the core (QNICE clock domain; cdc_stable in mega65.vhd)
      qnice_disk_mounted_o : out std_logic;                     -- valid ADF completely loaded
      qnice_disk_tracks_o  : out std_logic_vector(7 downto 0);  -- 160..166 when mounted

      -- Write-back CSR status to the core (QNICE clock domain; same cdc_stable)
      qnice_write_en_o     : out std_logic;                     -- WBC WR_EN (firmware-armed)
      qnice_any_dirty_o    : out std_logic;                     -- unflushed tracks exist (LED)

      -- Dirty-track event channel from the track engine (already CDC'd to the
      -- QNICE clock in mega65.vhd; two-phase toggle handshake)
      qnice_wrt_track_i    : in  std_logic_vector(7 downto 0);
      qnice_wrt_req_i      : in  std_logic;                     -- toggle
      qnice_wrt_ack_o      : out std_logic;                     -- toggle (follows req)

      -- HyperRAM clock domain: Avalon master -> core HyperRAM arbiter slave
      hr_clk_i             : in  std_logic;
      hr_rst_i             : in  std_logic;
      hr_write_o           : out std_logic;
      hr_read_o            : out std_logic;
      hr_address_o         : out std_logic_vector(31 downto 0);
      hr_writedata_o       : out std_logic_vector(15 downto 0);
      hr_byteenable_o      : out std_logic_vector( 1 downto 0);
      hr_burstcount_o      : out std_logic_vector( 7 downto 0);
      hr_readdata_i        : in  std_logic_vector(15 downto 0);
      hr_readdatavalid_i   : in  std_logic;
      hr_waitrequest_i     : in  std_logic
   );
end entity adf_mount_wrapper;

architecture synthesis of adf_mount_wrapper is

   -- 11 sectors x 512 bytes = one Amiga DD track in the ADF file
   constant C_TRACK_BYTES : natural := 5632;
   constant C_MIN_TRACKS  : natural := 160;   -- standard 80-cylinder ADF (901,120 bytes)
   constant C_MAX_TRACKS  : natural := 166;   -- 83 cylinders, Paula's step clamp (934,912 bytes)

   -- 21 chars each: 19 text chars + the literal 2-char "\n" the Shell's printer interprets
   constant C_ERROR_STRINGS : string_vector(0 to 15) := (
     "OK                 \n",
     "Invalid ADF size   \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n",
     "OK                 \n");

   -- CSR (window 0xFFFF) plumbing
   signal qnice_csr        : std_logic;
   signal qnice_csr_data   : std_logic_vector(15 downto 0);
   signal qnice_csr_wait   : std_logic;
   signal qnice_req_status : std_logic_vector( 3 downto 0);
   signal qnice_req_length : std_logic_vector(22 downto 0);
   signal qnice_resp_status: std_logic_vector( 3 downto 0);
   signal qnice_resp_error : std_logic_vector( 3 downto 0);

   -- write-back CSR (window 0xFFFE): dirty bitmap + anti-thrash countdown.
   -- All plain FFs in the QNICE domain (falling edge, device convention) -
   -- no BRAM (rule 4), no CDC beyond the toggle handshake.
   constant C_MS_TICKS     : natural := 50_000;   -- 1 ms at the 50 MHz QNICE clock
   signal qnice_wbc        : std_logic;
   signal wbc_wr_en        : std_logic := '0';
   signal wbc_dirty        : std_logic_vector(165 downto 0) := (others => '0');
   signal wbc_any_dirty    : std_logic := '0';
   signal wbc_flush_start  : std_logic := '0';
   signal wbc_at_delay     : unsigned(15 downto 0) := to_unsigned(2000, 16);  -- ms
   signal wbc_at_cnt       : unsigned(15 downto 0) := (others => '0');        -- ms left
   signal wbc_ms_pre       : natural range 0 to C_MS_TICKS - 1 := 0;
   signal wbc_req_d        : std_logic := '0';

   -- ADF size validator
   type t_val_state is (VS_IDLE, VS_CALC, VS_DONE);
   signal val_state     : t_val_state := VS_IDLE;
   signal val_remaining : unsigned(22 downto 0);
   signal val_tracks    : unsigned( 7 downto 0);

   -- QNICE-domain byte<->word bridge internals
   signal qnice_hr_ce         : std_logic;
   signal qnice_hr_addr       : std_logic_vector(31 downto 0);
   signal qnice_hr_wait       : std_logic;
   signal qnice_hr_data       : std_logic_vector(15 downto 0);
   signal qnice_hr_byteenable : std_logic_vector( 1 downto 0);

   -- QNICE-side Avalon master (-> avm_fifo source side)
   signal qnice_avm_write         : std_logic;
   signal qnice_avm_read          : std_logic;
   signal qnice_avm_address       : std_logic_vector(31 downto 0);
   signal qnice_avm_writedata     : std_logic_vector(15 downto 0);
   signal qnice_avm_byteenable    : std_logic_vector( 1 downto 0);
   signal qnice_avm_burstcount    : std_logic_vector( 7 downto 0);
   signal qnice_avm_readdata      : std_logic_vector(15 downto 0);
   signal qnice_avm_readdatavalid : std_logic;
   signal qnice_avm_waitrequest   : std_logic;

begin

   ------------------------------------------------------------------------------
   -- The framework CSR registers in window 0xFFFF (M2M/vhdl/qnice_csr.vhd)
   ------------------------------------------------------------------------------

   i_qnice_csr : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_addr_i,
         qnice_data_i         => qnice_data_i,
         qnice_ce_i           => qnice_ce_i,
         qnice_we_i           => qnice_we_i,
         qnice_data_o         => qnice_csr_data,
         qnice_wait_o         => qnice_csr_wait,
         qnice_csr_o          => qnice_csr,
         qnice_req_status_o   => qnice_req_status,
         qnice_req_length_o   => qnice_req_length,
         qnice_resp_status_i  => qnice_resp_status,
         qnice_resp_error_i   => qnice_resp_error,
         qnice_resp_address_i => (others => '0')
      ); -- i_qnice_csr

   ------------------------------------------------------------------------------
   -- ADF size validator ("parser"). Entirely in the QNICE clock domain: it only
   -- consumes qnice_req_* and only drives qnice_resp_* / the mount status, so no
   -- CDC is needed here (unlike the C64's HyperRAM-reading CRT parser).
   -- Falling edge to match the M2M QNICE device convention (qnice_csr.vhd).
   --
   -- The Shell polls PARSEST with no timeout, so this FSM must ALWAYS answer
   -- (READY or ERROR) once STATUS=ST_OK, and must return to IDLE when the
   -- request drops (STATUS=ST_LDNG of the next load) or the second mount hangs.
   ------------------------------------------------------------------------------

   p_validate : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         case val_state is
            when VS_IDLE =>
               qnice_resp_status    <= C_CSR_RESP_IDLE;
               qnice_resp_error     <= x"0";
               qnice_disk_mounted_o <= '0';
               if qnice_req_status = C_CSR_REQ_OK then
                  val_remaining <= unsigned(qnice_req_length);
                  val_tracks    <= (others => '0');
                  qnice_resp_status <= C_CSR_RESP_PARSING;
                  val_state     <= VS_CALC;
               end if;

            -- one subtraction per clock: <= 166 iterations = ~3.3 us at 50 MHz,
            -- invisible to the Shell's PARSEST poll loop
            when VS_CALC =>
               if val_remaining >= C_TRACK_BYTES and val_tracks < C_MAX_TRACKS then
                  val_remaining <= val_remaining - C_TRACK_BYTES;
                  val_tracks    <= val_tracks + 1;
               else
                  if val_remaining = 0 and val_tracks >= C_MIN_TRACKS then
                     qnice_resp_status    <= C_CSR_RESP_READY;
                     qnice_disk_tracks_o  <= std_logic_vector(val_tracks);
                     qnice_disk_mounted_o <= '1';
                  else
                     qnice_resp_status <= C_CSR_RESP_ERROR;
                     qnice_resp_error  <= x"1";           -- "Invalid ADF size"
                  end if;
                  val_state <= VS_DONE;
               end if;

            -- hold the response while the request stands; a new load (ST_LDNG)
            -- or an idle CSR returns us - and "mounted" - to idle immediately
            when VS_DONE =>
               if qnice_req_status /= C_CSR_REQ_OK then
                  qnice_disk_mounted_o <= '0';
                  qnice_resp_status    <= C_CSR_RESP_IDLE;
                  qnice_resp_error     <= x"0";
                  val_state            <= VS_IDLE;
               end if;
         end case;

         if qnice_rst_i = '1' then
            val_state            <= VS_IDLE;
            qnice_resp_status    <= C_CSR_RESP_IDLE;
            qnice_resp_error     <= x"0";
            qnice_disk_mounted_o <= '0';
            qnice_disk_tracks_o  <= (others => '0');
         end if;
      end if;
   end process p_validate;

   ------------------------------------------------------------------------------
   -- Write-back CSR (window 0xFFFE): dirty-track bitmap, anti-thrashing
   -- countdown (vdrives.vhd semantics: reloaded by every write event, flush
   -- may start once it expired), WR_EN. Falling edge like the validator.
   ------------------------------------------------------------------------------

   qnice_wbc         <= '1' when qnice_addr_i(27 downto 12) = x"FFFE" else '0';
   qnice_write_en_o  <= wbc_wr_en;
   qnice_any_dirty_o <= wbc_any_dirty;
   qnice_wrt_ack_o   <= wbc_req_d;

   p_wbc : process (qnice_clk_i)
      variable v_word  : natural range 0 to 15;
      variable v_track : natural range 0 to 255;
   begin
      if falling_edge(qnice_clk_i) then

         -- firmware register writes; the dirty words are write-1-to-clear
         if qnice_ce_i = '1' and qnice_we_i = '1' and qnice_wbc = '1' then
            case qnice_addr_i(11 downto 0) is
               when x"000" =>
                  wbc_wr_en <= qnice_data_i(0);
               when x"002" =>
                  wbc_at_delay <= unsigned(qnice_data_i);
               when others =>
                  if qnice_addr_i(11 downto 4) = x"01" then     -- 0x010..0x01F
                     v_word := to_integer(unsigned(qnice_addr_i(3 downto 0)));
                     if v_word <= 10 then
                        for b in 0 to 15 loop
                           if v_word * 16 + b <= 165 and qnice_data_i(b) = '1' then
                              wbc_dirty(v_word * 16 + b) <= '0';
                           end if;
                        end loop;
                     end if;
                  end if;
            end case;
         end if;

         -- anti-thrash ms countdown (only while armed events are pending)
         if wbc_ms_pre = C_MS_TICKS - 1 then
            wbc_ms_pre <= 0;
            if wbc_at_cnt /= 0 then
               wbc_at_cnt <= wbc_at_cnt - 1;
            end if;
         else
            wbc_ms_pre <= wbc_ms_pre + 1;
         end if;

         -- dirty event from the track engine: set wins over a same-cycle W1C
         -- (this assignment is last), and every event restarts the countdown
         if qnice_wrt_req_i /= wbc_req_d then
            wbc_req_d <= qnice_wrt_req_i;
            v_track   := to_integer(unsigned(qnice_wrt_track_i));
            if v_track <= 165 then
               wbc_dirty(v_track) <= '1';
            end if;
            wbc_at_cnt <= wbc_at_delay;
            wbc_ms_pre <= 0;
         end if;

         -- registered status (keeps the combinational read mux shallow)
         if wbc_dirty = (wbc_dirty'range => '0') then
            wbc_any_dirty   <= '0';
            wbc_flush_start <= '0';
         else
            wbc_any_dirty   <= '1';
            wbc_flush_start <= '1' when wbc_at_cnt = 0 else '0';
         end if;

         if qnice_rst_i = '1' then
            wbc_wr_en       <= '0';
            wbc_dirty       <= (others => '0');
            wbc_any_dirty   <= '0';
            wbc_flush_start <= '0';
            wbc_at_delay    <= to_unsigned(2000, 16);
            wbc_at_cnt      <= (others => '0');
            wbc_ms_pre      <= 0;
            wbc_req_d       <= qnice_wrt_req_i;   -- swallow any in-flight event
         end if;
      end if;
   end process p_wbc;

   ------------------------------------------------------------------------------
   -- QNICE byte-window -> HyperRAM word bridge (in the QNICE clock domain).
   -- Cloned from C64MEGA65 mount_buf_wrapper.vhd; the CSR and WBC windows are
   -- carved out.
   ------------------------------------------------------------------------------

   qnice_hr_ce <= qnice_ce_i and not qnice_csr and not qnice_wbc;

   -- Byte address qnice_addr_i(27..1) (bit 0 dropped) added to the 22-bit WORD base.
   -- bit 0 is the byte-lane select only - it never enters the word address.
   qnice_hr_addr <= std_logic_vector(("00000" & unsigned(qnice_addr_i(27 downto 1))) +
                                     ("0000000000" & unsigned(G_BASE_ADDRESS)));

   qnice_hr_byteenable <= "10" when qnice_addr_i(0) = '1' else
                          "01";

   -- Read mux + wait pass-through, combinational like the proven C64 bridges:
   -- qnice2hyperram holds its wait high until the HyperRAM read data is valid,
   -- so the addressed byte on qnice_hr_data is stable when wait drops. The
   -- WBC registers answer immediately (plain FFs, no wait states).
   p_read : process (all)
      variable v_word : natural range 0 to 15;
   begin
      qnice_data_o <= x"0000";
      qnice_wait_o <= '0';
      if qnice_ce_i = '1' then
         if qnice_csr = '1' then
            qnice_wait_o <= qnice_csr_wait;
            qnice_data_o <= qnice_csr_data;
         elsif qnice_wbc = '1' then
            case qnice_addr_i(11 downto 0) is
               when x"000" =>
                  qnice_data_o(0) <= wbc_wr_en;
               when x"001" =>
                  qnice_data_o(0) <= wbc_any_dirty;
                  qnice_data_o(1) <= wbc_flush_start;
               when x"002" =>
                  qnice_data_o <= std_logic_vector(wbc_at_delay);
               when others =>
                  if qnice_addr_i(11 downto 4) = x"01" then     -- 0x010..0x01F
                     v_word := to_integer(unsigned(qnice_addr_i(3 downto 0)));
                     if v_word < 10 then
                        qnice_data_o <= wbc_dirty(v_word * 16 + 15 downto v_word * 16);
                     elsif v_word = 10 then
                        qnice_data_o <= "0000000000" & wbc_dirty(165 downto 160);
                     end if;
                  end if;
            end case;
         else
            qnice_wait_o <= qnice_hr_wait;
            if qnice_addr_i(0) = '1' then
               qnice_data_o <= x"00" & qnice_hr_data(15 downto 8);
            else
               qnice_data_o <= x"00" & qnice_hr_data(7 downto 0);
            end if;
         end if;
      end if;
   end process p_read;

   i_qnice2hyperram : entity work.qnice2hyperram
      port map (
         clk_i                 => qnice_clk_i,
         rst_i                 => qnice_rst_i,
         s_qnice_wait_o        => qnice_hr_wait,
         s_qnice_address_i     => qnice_hr_addr,
         s_qnice_cs_i          => qnice_hr_ce,
         s_qnice_write_i       => qnice_we_i,
         -- write-data lane duplication: low byte on both lanes; byteenable commits one
         s_qnice_writedata_i   => qnice_data_i(7 downto 0) & qnice_data_i(7 downto 0),
         s_qnice_byteenable_i  => qnice_hr_byteenable,
         s_qnice_readdata_o    => qnice_hr_data,
         m_avm_write_o         => qnice_avm_write,
         m_avm_read_o          => qnice_avm_read,
         m_avm_address_o       => qnice_avm_address,
         m_avm_writedata_o     => qnice_avm_writedata,
         m_avm_byteenable_o    => qnice_avm_byteenable,
         m_avm_burstcount_o    => qnice_avm_burstcount,
         m_avm_readdata_i      => qnice_avm_readdata,
         m_avm_readdatavalid_i => qnice_avm_readdatavalid,
         m_avm_waitrequest_i   => qnice_avm_waitrequest
      ); -- i_qnice2hyperram

   ------------------------------------------------------------------------------
   -- Clock-domain crossing QNICE <-> HyperRAM (identical to the C64 wrappers).
   -- Domain resets on both sides - never a core reset (see the ADF spec).
   ------------------------------------------------------------------------------

   i_avm_fifo : entity work.avm_fifo
      generic map (
         G_WR_DEPTH     => 16,
         G_RD_DEPTH     => 16,
         G_FILL_SIZE    => 1,
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         s_clk_i               => qnice_clk_i,
         s_rst_i               => qnice_rst_i,
         s_avm_waitrequest_o   => qnice_avm_waitrequest,
         s_avm_write_i         => qnice_avm_write,
         s_avm_read_i          => qnice_avm_read,
         s_avm_address_i       => qnice_avm_address,
         s_avm_writedata_i     => qnice_avm_writedata,
         s_avm_byteenable_i    => qnice_avm_byteenable,
         s_avm_burstcount_i    => qnice_avm_burstcount,
         s_avm_readdata_o      => qnice_avm_readdata,
         s_avm_readdatavalid_o => qnice_avm_readdatavalid,
         m_clk_i               => hr_clk_i,
         m_rst_i               => hr_rst_i,
         m_avm_waitrequest_i   => hr_waitrequest_i,
         m_avm_write_o         => hr_write_o,
         m_avm_read_o          => hr_read_o,
         m_avm_address_o       => hr_address_o,
         m_avm_writedata_o     => hr_writedata_o,
         m_avm_byteenable_o    => hr_byteenable_o,
         m_avm_burstcount_o    => hr_burstcount_o,
         m_avm_readdata_i      => hr_readdata_i,
         m_avm_readdatavalid_i => hr_readdatavalid_i
      ); -- i_avm_fifo

end architecture synthesis;
