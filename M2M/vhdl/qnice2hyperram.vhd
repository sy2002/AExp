library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

-- This module allows the QNICE CPU to access an Avalon Memory Mapped
-- device (normally the HyperRAM device of the MEGA65).
--
-- This module runs in the QNICE clock domain.
--
-- M2M-UPSTREAM qnice2hyperram-watchdog
-- Ported from C64MEGA65 (hardware-found while testing its issue #93), plus one
-- additional hardening step described below.
--
-- CAUTION - the QNICE CPU is hard-stalled while s_qnice_wait_o is high, so a lost
-- Avalon response freezes the whole Shell forever: no keyboard, no OSM, power-cycle
-- required. That is not hypothetical. hr_rst is derived from the CORE reset as well
-- (clk_m2m.vhd: src_arst => not (qnice_locked and sys_rstn_i and core_rstn_i)), so
-- pressing the MEGA65 reset button resets the HyperRAM clock domain while the QNICE
-- domain keeps running. A press during an in-flight read drops its response and this
-- module waits for it forever. In AExp that window is wide open: the ADF write-back
-- (FLUSH_ADF_STEP) reads the staging buffer out of HyperRAM whenever a track is
-- dirty, i.e. exactly during the "I saved my work, now reboot" reflex.
--
-- The watchdog below detects a stall far beyond any legitimate HyperRAM latency and
-- re-issues the latched read command. While the other domain is still in reset the
-- retry is dropped again and the watchdog simply fires once more; after the reset
-- releases, a retry completes and the CPU never sees wrong data - it just waited out
-- the reset.
--
-- HARDENING BEYOND THE C64 VERSION: the C64 review of this fix correctly noted that
-- the retry cannot distinguish "response was lost" from "command is still queued
-- inside avm_fifo", so a long reset can enqueue many duplicate reads whose late
-- responses could satisfy a LATER, unrelated read with stale data. Two measures
-- close that here:
--   (1) a response is only consumed while we are actually waiting for one
--       (reading = '1'); a duplicate arriving at any other time is discarded
--       instead of overwriting s_qnice_readdata_o.
--   (2) the real fix is at the transport: the instantiating core must reset the
--       SOURCE side of the downstream avm_fifo together with the HyperRAM reset, so
--       that no pre-reset command can survive to be executed twice. AExp does this in
--       CORE/vhdl/adf_mount_wrapper.vhd; see the reset comment there.
-- Measure (1) alone already makes a stale duplicate harmless for data integrity in
-- the common case; (1)+(2) together make duplicates impossible on the ADF path.

entity qnice2hyperram is
   generic (
      -- Roughly 0.65 ms at 50 MHz, i.e. orders of magnitude above worst-case HyperRAM
      -- latency, so the watchdog can never fire on a merely slow-but-healthy access.
      -- The default keeps every existing instantiation source-compatible.
      G_TIMEOUT_CYCLES      : natural := 32768
   );
   port (
      -- This is the QNICE clock
      clk_i                 : in  std_logic;
      rst_i                 : in  std_logic;

      -- Connect to QNICE CPU
      -- This is a slave interface
      s_qnice_wait_o        : out std_logic;
      s_qnice_address_i     : in  std_logic_vector(31 downto 0);
      s_qnice_cs_i          : in  std_logic;
      s_qnice_write_i       : in  std_logic;
      s_qnice_writedata_i   : in  std_logic_vector(15 downto 0);
      s_qnice_byteenable_i  : in  std_logic_vector( 1 downto 0);
      s_qnice_readdata_o    : out std_logic_vector(15 downto 0);

      -- Connect to HyperRAM (via avm_fifo)
      -- This is a master interface
      m_avm_write_o         : out std_logic;
      m_avm_read_o          : out std_logic;
      m_avm_address_o       : out std_logic_vector(31 downto 0);
      m_avm_writedata_o     : out std_logic_vector(15 downto 0);
      m_avm_byteenable_o    : out std_logic_vector( 1 downto 0);
      m_avm_burstcount_o    : out std_logic_vector( 7 downto 0);
      m_avm_readdata_i      : in  std_logic_vector(15 downto 0);
      m_avm_readdatavalid_i : in  std_logic;
      m_avm_waitrequest_i   : in  std_logic
   );
end entity qnice2hyperram;

architecture synthesis of qnice2hyperram is

   signal reading               : std_logic;
   signal m_avm_readdatavalid_d : std_logic;
   signal watchdog              : natural range 0 to G_TIMEOUT_CYCLES;

begin

   s_qnice_wait_o <= ((m_avm_write_o or m_avm_read_o) and m_avm_waitrequest_i) or reading;

   convert_proc : process (clk_i)
   begin
      if falling_edge(clk_i) then
         m_avm_readdatavalid_d <= m_avm_readdatavalid_i;

         if m_avm_waitrequest_i = '0' then
            m_avm_write_o <= '0';
            m_avm_read_o  <= '0';
         end if;

         if s_qnice_cs_i = '1' and s_qnice_wait_o = '0' and m_avm_readdatavalid_d = '0' then
            m_avm_write_o      <= s_qnice_write_i;
            m_avm_read_o       <= not s_qnice_write_i;
            m_avm_address_o    <= s_qnice_address_i;
            m_avm_writedata_o  <= s_qnice_writedata_i;
            m_avm_byteenable_o <= s_qnice_byteenable_i;
            m_avm_burstcount_o <= X"01";

            reading <= not s_qnice_write_i;
         end if;

         -- Hardening measure (1), see the entity header: only consume a response while
         -- a read is actually outstanding. An unexpected response can only be a stale
         -- duplicate produced by the watchdog across a transport reset; discarding it
         -- keeps it from overwriting the data of an unrelated later read.
         if m_avm_readdatavalid_i = '1' and reading = '1' then
            s_qnice_readdata_o <= m_avm_readdata_i;
            reading       <= '0';
         end if;

         -- Self-healing watchdog: see the CAUTION block in the entity header.
         -- A pending command (write_o/read_o still high because waitrequest is stuck)
         -- needs no action - it stays asserted and is accepted once the other domain
         -- returns. The dangerous shape is "reading with no pending command": the read
         -- response was dropped, so re-issue the read. Address, byteenable and
         -- burstcount are all still latched from the original access.
         if s_qnice_wait_o = '1' then
            if watchdog = G_TIMEOUT_CYCLES then
               watchdog <= 0;
               if reading = '1' and m_avm_read_o = '0' and m_avm_write_o = '0' then
                  m_avm_read_o <= '1';
               end if;
            else
               watchdog <= watchdog + 1;
            end if;
         else
            watchdog <= 0;
         end if;

         if rst_i = '1' then
            m_avm_write_o <= '0';
            m_avm_read_o  <= '0';
            reading       <= '0';
            watchdog      <= 0;
         end if;
      end if;
   end process convert_proc;

end architecture synthesis;

