library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

-- This module allows the QNICE CPU to access an Avalon Memory Mapped
-- device (normally the HyperRAM device of the MEGA65).
--
-- This module runs in the QNICE clock domain.
--
-- M2M-UPSTREAM qnice2hyperram-watchdog (AExp 2026-08-02)
-- Ported from C64MEGA65, where the hang was found on hardware (C64MEGA65
-- GitHub #93), plus the response guard described below.
--
-- The QNICE CPU stalls while s_qnice_wait_o is high, so a lost Avalon response
-- freezes the whole Shell: no keyboard, no OSM, only a framework reset (reset
-- button held for 1.5 s) or a power cycle helps. A response is lost when the
-- HyperRAM domain is reset during a read. hr_rst includes the core reset
-- (clk_m2m.vhd: src_arst => not (qnice_locked and sys_rstn_i and
-- core_rstn_i)), so the MEGA65 reset button resets the HyperRAM clock domain
-- while the QNICE domain keeps running. In AExp the ADF write-back
-- (FLUSH_ADF_STEP) reads its staging buffer from HyperRAM whenever a track is
-- dirty, which is right after the user saved something - the moment a user is
-- most likely to press reset.
--
-- The watchdog below detects a stall far beyond any legitimate HyperRAM latency
-- and re-issues the latched read command. While the other domain is still in
-- reset, the retry is lost as well and the watchdog fires again; after the reset
-- is released, a retry completes, and the CPU receives the correct data after
-- waiting out the reset.
--
-- The retry cannot tell "response lost" from "command still queued inside
-- avm_fifo", so a long reset can queue several duplicate reads whose late
-- responses could satisfy a later, unrelated read with stale data. Two measures
-- can address this:
--   (1) a response is only consumed while a read is outstanding
--       (reading = '1'); a duplicate arriving at any other time is discarded
--       instead of overwriting s_qnice_readdata_o. This module implements it.
--   (2) the instantiating core would reset the source side of the
--       downstream avm_fifo together with the HyperRAM reset, so that no
--       command queued before the reset could survive to be executed twice.
-- Measure (1) alone covers duplicates that arrive while no read is waiting; a
-- duplicate that arrives while a later read waits is taken as its response, and
-- only (2) rules that out. AExp implements (1) only: framework.vhd and
-- adf_mount_wrapper.vhd reset each side of their avm_fifo with that side's own
-- domain reset.

entity qnice2hyperram is
   generic (
      -- Roughly 0.65 ms at 50 MHz, orders of magnitude above the worst-case HyperRAM
      -- latency, so the watchdog never fires on a slow but healthy access.
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

         -- Measure (1) of the entity header: only consume a response while a read is
         -- outstanding. An unexpected response can only be a stale duplicate that the
         -- watchdog produced across a transport reset; discarding it keeps it from
         -- overwriting s_qnice_readdata_o.
         if m_avm_readdatavalid_i = '1' and reading = '1' then
            s_qnice_readdata_o <= m_avm_readdata_i;
            reading       <= '0';
         end if;

         -- Self-healing watchdog, see the entity header.
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

