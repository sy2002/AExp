---------------------------------------------------------------------------------------------------------
-- Settling-blackout micro-testbench for CORE/vhdl/keyboard.vhd (the C_ACK_GUARD window)
--
-- Checks the post-send ack blackout: an acknowledge whose rising edge falls inside the C_ACK_GUARD
-- window right after a send (the ciaa sdr_latch settling window, where a read still returns the
-- previous code) must not be attributed to the just-sent code. Otherwise the next code would be
-- released while the current one is still unread => overrun.
--
-- Method: queue two makes (A then S) in one scan sweep. The DUT sends code1 (A=$20) immediately.
-- Then:
--   1. Drive kbd_ack high a few cycles after code1's kms toggle - a rising edge inside the guard -
--      and hold it past the guard's expiry. Edge-detect + guard must ignore it (no new rising edge
--      after the guard opens, and the one during it is blacked out).
--   2. Wait 2 ms (well past the 1 ms floor). code2 must not have been sent - proof the in-guard ack
--      did not count.
--   3. Drive a fresh post-guard rising edge. code2 (S=$21) must now be sent promptly.
--
-- kbd_ack is driven only by the stimulus here (no auto-reader), so there is a single driver.
-- The bench ends with "GUARD RESULT: PASS" or fails with "GUARD RESULT: FAIL".
--
-- Run: CORE/sim/keyboard/run.sh (a few seconds for this bench).
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_keyboard_guard is
end entity tb_keyboard_guard;

architecture sim of tb_keyboard_guard is

   signal clk_main        : std_logic := '0';
   signal reset           : std_logic := '1';
   signal kb_key_num      : integer range 0 to 79 := 0;
   signal kb_key_pressed_n: std_logic := '1';
   signal kbd_data        : std_logic_vector(7 downto 0);
   signal kbd_type        : std_logic_vector(1 downto 0);
   signal kms_level       : std_logic;
   signal kbd_ack         : std_logic := '0';   -- driven only by the stimulus (sole driver)
   signal core_reset      : std_logic;
   signal mouse_rmb       : std_logic;

   constant CLK_PERIOD : time := 35.2423 ns;    -- 28.375 MHz
   constant C_DWELL    : natural := 355;

   type t_phys is array(0 to 79) of std_logic;
   signal phys : t_phys := (others => '0');

   constant K_A : integer := 10;   -- Amiga $20
   constant K_S : integer := 13;   -- Amiga $21

   signal fail : boolean := false;

begin

   dut : entity work.keyboard
      port map (
         clk_main_i => clk_main, reset_i => reset,
         kb_key_num_i => kb_key_num, kb_key_pressed_n_i => kb_key_pressed_n,
         keyboard_mode_i => '0',
         kbd_mouse_data_o => kbd_data, kbd_mouse_type_o => kbd_type, kms_level_o => kms_level,
         kbd_ack_i => kbd_ack,
         core_reset_o => core_reset, mouse_rmb_o => mouse_rmb
      );

   clk_main <= not clk_main after CLK_PERIOD/2;

   scan_gen : process (clk_main)
      variable cnt : natural := 0;
   begin
      if rising_edge(clk_main) then
         if cnt = C_DWELL - 1 then
            cnt := 0;
            if kb_key_num = 79 then kb_key_num <= 0; else kb_key_num <= kb_key_num + 1; end if;
         else
            cnt := cnt + 1;
         end if;
      end if;
   end process scan_gen;

   kb_key_pressed_n <= not phys(kb_key_num);

   stim : process
   begin
      wait for 1 us; reset <= '0';
      wait for 110 ms;                       -- past the 100 ms post-reset hold-off (pace_cnt=0)

      report "### queue two makes A,S in one sweep";
      phys(K_A) <= '1'; phys(K_S) <= '1';

      -- code1 (A=$20 make) is released immediately (first code, ack_seen='1' after reset)
      wait until kms_level'event and reset = '0';
      report "  code1 sent: $" & to_hstring(kbd_data) & " at t=" & time'image(now);
      assert kbd_data = x"20"
         report "  >>> unexpected code1 $" & to_hstring(kbd_data) & " (expected $20)" severity error;
      if kbd_data /= x"20" then fail <= true; end if;

      -- 1) IN-GUARD ack: rising edge ~4 cycles after the send (guard still open), held past its
      --    expiry (~16 cycles). Must be ignored.
      wait for 4 * CLK_PERIOD;
      kbd_ack <= '1';
      wait for 16 * CLK_PERIOD;               -- spans the 8-cycle guard and beyond
      kbd_ack <= '0';
      report "  in-guard ack injected (rising edge inside C_ACK_GUARD, held past expiry)";

      -- 2) code2 must not be sent by this in-guard ack, even after the 1 ms floor elapses
      wait until kms_level'event for 2 ms;
      if kms_level'event then
         report "  >>> BLACKOUT FAIL: code2 ($" & to_hstring(kbd_data) &
                ") released by an in-guard ack" severity error;
         fail <= true;
      else
         report "  OK: code2 withheld after the in-guard ack (blackout works)";
      end if;

      -- 3) POST-GUARD ack: fresh rising edge, guard long expired. code2 must be released promptly.
      kbd_ack <= '1';
      wait until kms_level'event for 200 us;
      if kms_level'event then
         report "  code2 sent: $" & to_hstring(kbd_data) & " at t=" & time'image(now);
         assert kbd_data = x"21"
            report "  >>> unexpected code2 $" & to_hstring(kbd_data) & " (expected $21)" severity error;
         if kbd_data /= x"21" then fail <= true; end if;
      else
         report "  >>> ACK FAIL: code2 not released by a valid post-guard ack" severity error;
         fail <= true;
      end if;
      wait for 40 * CLK_PERIOD;
      kbd_ack <= '0';

      phys(K_A) <= '0'; phys(K_S) <= '0';
      wait for 5 ms;

      if fail then
         report "@@@ GUARD RESULT: FAIL @@@" severity failure;
      else
         report "@@@ GUARD RESULT: PASS (in-guard ack ignored, post-guard ack honoured) @@@";
      end if;
      finish;
   end process stim;

end architecture sim;
