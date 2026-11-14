-- Checks that the power-on reference of CORE/vhdl/amiga_cold_boot.vhd equals
-- the default drive topology of the menu (one drive, df0 as Disk Image):
-- holding drv_map_i at that default from t=0 must not fire a cold boot. A
-- mismatch would cold-boot the Amiga at every power-on.
--
-- Generics: G_MAP is the drive map held from t=0, G_EXPECT_BOOT the expected
-- outcome. CORE/sim/misc/run.sh runs three cases (a few seconds):
--   default                                   no cold boot, must pass
--   -gG_MAP=10010000 -gG_EXPECT_BOOT=true     three drives, df2 Hardware Floppy:
--                                             cold boot, must pass
--   -gG_EXPECT_BOOT=true                      red control, must fail

library ieee;
use ieee.std_logic_1164.all;

entity tb_cold_boot_init is
   generic (G_MAP : std_logic_vector(7 downto 0) := "00" & "10" & "10" & "00";
            G_EXPECT_BOOT : boolean := false);
end entity;

architecture sim of tb_cold_boot_init is
   signal clk      : std_logic := '0';
   signal rst_o    : std_logic;
   signal scrub_o  : std_logic;
   signal addr_o   : std_logic_vector(17 downto 0);
   signal done     : boolean := false;
   signal saw_boot : boolean := false;
begin
   clk <= not clk after 5 ns when not done else '0';

   dut : entity work.amiga_cold_boot
      port map (clk_i => clk, slow_ram_i => '1', drv_map_i => G_MAP,
                amiga_reset_o => rst_o, chip_scrub_o => scrub_o,
                chip_scrub_addr_o => addr_o);

   watch : process (clk)
   begin
      if rising_edge(clk) then
         if rst_o = '1' or scrub_o = '1' then
            saw_boot <= true;
         end if;
      end if;
   end process;

   stim : process
   begin
      wait for 5 us;                      -- >> 64 clocks + the scrub states
      assert saw_boot = G_EXPECT_BOOT
         report "cold boot at power-on: got " & boolean'image(saw_boot) &
                ", expected " & boolean'image(G_EXPECT_BOOT)
         severity failure;
      report "PASS: saw_boot=" & boolean'image(saw_boot) severity note;
      done <= true;
      wait;
   end process;
end architecture;
