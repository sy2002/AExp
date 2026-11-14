---------------------------------------------------------------------------------------------------------
-- Balanced make/break testbench for CORE/vhdl/keyboard.vhd in MEGA65 mode (keyboard_mode_i = '0',
-- the default), where shifted F-keys are substituted (Shift+F1 = Amiga F2 and so on).
--
-- It models the M2M 1 kHz key scanner (kb_key_num_i sweeps 0..79, kb_key_pressed_n_i = live
-- debounced state of the presented key) and a fast reader that acknowledges every code like
-- Kickstart's keyboard.device, drives realistic key sequences (shifted F-keys, chords, early shift
-- release, tight taps, normal keys while a substituted F-key is held), decodes the raw Amiga keycode
-- stream exactly like rtl/ciaa.v sees it (data[6:0]=keycode, data[7]=1 -> break) and tracks a
-- per-keycode "down" map. A keycode whose make was delivered without its matching break is a stuck
-- key: it stays lit in a keyboard tester that shows the keyboard.device matrix. Each scenario
-- reports either "clean after <tag>" or ">>> STUCK after <tag>"; the runner fails on any STUCK
-- line and requires the final "clean after FINAL".
--
-- Run: CORE/sim/keyboard/run.sh (about 15 seconds for this bench).
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_keyboard is
end entity tb_keyboard;

architecture sim of tb_keyboard is

   -- DUT ports
   signal clk_main        : std_logic := '0';
   signal reset           : std_logic := '1';
   signal kb_key_num      : integer range 0 to 79 := 0;
   signal kb_key_pressed_n: std_logic := '1';
   signal kbd_data        : std_logic_vector(7 downto 0);
   signal kbd_type        : std_logic_vector(1 downto 0);
   signal kms_level       : std_logic;
   signal kbd_ack         : std_logic := '0';   -- driven only by the fast-reader process below
   signal core_reset      : std_logic;
   signal mouse_rmb       : std_logic;

   -- 28.375 MHz
   constant CLK_PERIOD : time := 35.2423 ns;

   -- ~1 kHz sweep across 80 keys => ~355 core cycles per key
   constant C_DWELL : natural := 355;

   -- physical key state, '1' = pressed
   type t_phys is array(0 to 79) of std_logic;
   signal phys : t_phys := (others => '0');

   -- per-keycode "down" tracking as the Amiga (keyboard.device matrix) would see it
   signal down_map : std_logic_vector(0 to 127) := (others => '0');
   signal ev_count : natural := 0;

   -- MEGA65 key numbers of interest (mirror the DUT constants)
   constant K_F7       : integer := 3;
   constant K_F1       : integer := 4;
   constant K_F3       : integer := 5;
   constant K_F5       : integer := 6;
   constant K_LSHIFT   : integer := 15;
   constant K_RSHIFT   : integer := 52;
   constant K_F9       : integer := 68;
   constant K_F11      : integer := 69;

   -- convenient pacing constant for stimulus (> 1 ms drain, room for several queued events)
   constant T_STEP : time := 6 ms;

begin

   ---------------------------------------------------------------------------
   -- DUT
   ---------------------------------------------------------------------------
   dut : entity work.keyboard
      port map (
         clk_main_i         => clk_main,
         reset_i            => reset,
         kb_key_num_i       => kb_key_num,
         kb_key_pressed_n_i => kb_key_pressed_n,
         keyboard_mode_i    => '0',           -- MEGA65 mode: shifted F-keys are substituted
         kbd_mouse_data_o   => kbd_data,
         kbd_mouse_type_o   => kbd_type,
         kms_level_o        => kms_level,
         kbd_ack_i          => kbd_ack,
         core_reset_o       => core_reset,
         mouse_rmb_o        => mouse_rmb
      );

   ---------------------------------------------------------------------------
   -- clock
   ---------------------------------------------------------------------------
   clk_main <= not clk_main after CLK_PERIOD/2;

   ---------------------------------------------------------------------------
   -- 1 kHz scanner: kb_key_num sweeps 0..79, C_DWELL cycles each
   ---------------------------------------------------------------------------
   scan_gen : process (clk_main)
      variable cnt : natural := 0;
   begin
      if rising_edge(clk_main) then
         if cnt = C_DWELL - 1 then
            cnt := 0;
            if kb_key_num = 79 then
               kb_key_num <= 0;
            else
               kb_key_num <= kb_key_num + 1;
            end if;
         else
            cnt := cnt + 1;
         end if;
      end if;
   end process scan_gen;

   -- live debounced state of the currently presented key (low active)
   kb_key_pressed_n <= not phys(kb_key_num);

   ---------------------------------------------------------------------------
   -- Perfect fast reader (models Kickstart's keyboard.device): acks each code well within the
   -- 1 ms min-gap floor, so the flow-control pacer runs at the floor - identical to a pure fixed
   -- 1 ms pace. Held for a multi-cycle window (like a real E-clock-synced CIA read), not a pulse.
   -- Sole driver of kbd_ack. The reader is always idle again before the next code (100 us << 1 ms),
   -- so the per-code kms_level wait never misses a code.
   ---------------------------------------------------------------------------
   fast_reader : process
   begin
      kbd_ack <= '0';
      loop
         wait until kms_level'event and reset = '0';
         wait for 100 us;                 -- fast ack, < the 1 ms floor
         -- one read == several cck-gated pulses (the real ciaa.kbd_ack waveform), not a clean level
         for i in 1 to 3 loop
            kbd_ack <= '1'; wait for 4 * CLK_PERIOD;
            kbd_ack <= '0'; wait for 4 * CLK_PERIOD;
         end loop;
      end loop;
   end process fast_reader;

   ---------------------------------------------------------------------------
   -- Monitor: decode every keycode event exactly like ciaa.v receives it
   ---------------------------------------------------------------------------
   monitor : process (kms_level)
      variable code7 : std_logic_vector(6 downto 0);
      variable idx   : integer;
   begin
      -- ignore the power-up settle of kms_level during reset (spurious $00)
      if kms_level'event and reset = '0' then
         code7 := kbd_data(6 downto 0);
         idx   := to_integer(unsigned(code7));
         ev_count <= ev_count + 1;
         if kbd_data(7) = '0' then
            down_map(idx) <= '1';
            report "t=" & time'image(now) & "  MAKE  $" & to_hstring(code7);
         else
            down_map(idx) <= '0';
            report "t=" & time'image(now) & "  BREAK $" & to_hstring(code7);
         end if;
      end if;
   end process monitor;

   ---------------------------------------------------------------------------
   -- Stimulus: realistic user sequences
   ---------------------------------------------------------------------------
   stim : process
      -- report every still-down keycode = stuck key
      procedure report_stuck(tag : string) is
         variable any : boolean := false;
         variable v8  : std_logic_vector(7 downto 0);
      begin
         for i in 0 to 127 loop
            if down_map(i) = '1' then
               v8 := std_logic_vector(to_unsigned(i, 8));
               report "  >>> STUCK after " & tag & ": keycode $" & to_hstring(v8(6 downto 0));
               any := true;
            end if;
         end loop;
         if not any then
            report "  --- clean after " & tag & " (no stuck keys)";
         end if;
      end procedure;
   begin
      -- release reset
      wait for 1 us;
      reset <= '0';

      -- wait out the 100 ms post-reset hold-off so events actually drain
      wait for 110 ms;
      report "=== stimulus start ===";

      ----------------------------------------------------------------------
      report "### S1: hold LSHIFT, tap F1 (expect Amiga F2=$51 make+break), release LSHIFT";
      phys(K_LSHIFT) <= '1'; wait for T_STEP;
      phys(K_F1)     <= '1'; wait for T_STEP;
      phys(K_F1)     <= '0'; wait for T_STEP;
      phys(K_LSHIFT) <= '0'; wait for T_STEP;
      report_stuck("S1");

      ----------------------------------------------------------------------
      report "### S2: hold LSHIFT, tap F1/F3/F5/F7/F9 in sequence, then release LSHIFT";
      phys(K_LSHIFT) <= '1'; wait for T_STEP;
      phys(K_F1) <= '1'; wait for T_STEP; phys(K_F1) <= '0'; wait for T_STEP;
      phys(K_F3) <= '1'; wait for T_STEP; phys(K_F3) <= '0'; wait for T_STEP;
      phys(K_F5) <= '1'; wait for T_STEP; phys(K_F5) <= '0'; wait for T_STEP;
      phys(K_F7) <= '1'; wait for T_STEP; phys(K_F7) <= '0'; wait for T_STEP;
      phys(K_F9) <= '1'; wait for T_STEP; phys(K_F9) <= '0'; wait for T_STEP;
      phys(K_LSHIFT) <= '0'; wait for T_STEP;
      report_stuck("S2");

      ----------------------------------------------------------------------
      report "### S3: hold LSHIFT, press F1, release LSHIFT before F1, then release F1";
      phys(K_LSHIFT) <= '1'; wait for T_STEP;
      phys(K_F1)     <= '1'; wait for T_STEP;
      phys(K_LSHIFT) <= '0'; wait for T_STEP;
      phys(K_F1)     <= '0'; wait for T_STEP;
      report_stuck("S3");

      ----------------------------------------------------------------------
      report "### S4: fast chord - press LSHIFT and F1 within the same sweep (F1 scanned first)";
      -- change both between two scans of F1: assert together so F1 (key 4) is scanned before
      -- LSHIFT (key 15) mirror updates in the same sweep
      phys(K_LSHIFT) <= '1'; phys(K_F1) <= '1'; wait for T_STEP;
      phys(K_F1)     <= '0'; wait for T_STEP;
      phys(K_LSHIFT) <= '0'; wait for T_STEP;
      report_stuck("S4");

      ----------------------------------------------------------------------
      report "### S5: two shifted F-keys held together (LSHIFT, F1 then F3, release both F, then shift)";
      phys(K_LSHIFT) <= '1'; wait for T_STEP;
      phys(K_F1) <= '1'; wait for T_STEP;
      phys(K_F3) <= '1'; wait for T_STEP;
      phys(K_F1) <= '0'; wait for T_STEP;
      phys(K_F3) <= '0'; wait for T_STEP;
      phys(K_LSHIFT) <= '0'; wait for T_STEP;
      report_stuck("S5");

      ----------------------------------------------------------------------
      report "### S6: right shift variant - hold RSHIFT, tap F9 (expect F10=$59), release";
      phys(K_RSHIFT) <= '1'; wait for T_STEP;
      phys(K_F9)     <= '1'; wait for T_STEP;
      phys(K_F9)     <= '0'; wait for T_STEP;
      phys(K_RSHIFT) <= '0'; wait for T_STEP;
      report_stuck("S6");

      ----------------------------------------------------------------------
      report "### S7: rapid re-press of same shifted F-key while shift stays held";
      phys(K_LSHIFT) <= '1'; wait for T_STEP;
      phys(K_F5) <= '1'; wait for T_STEP; phys(K_F5) <= '0'; wait for T_STEP;
      phys(K_F5) <= '1'; wait for T_STEP; phys(K_F5) <= '0'; wait for T_STEP;
      phys(K_LSHIFT) <= '0'; wait for T_STEP;
      report_stuck("S7");

      ----------------------------------------------------------------------
      report "### S8: tap F11 alone - unmapped in MEGA65 mode, expect no event";
      phys(K_F11) <= '1'; wait for T_STEP;
      phys(K_F11) <= '0'; wait for T_STEP;
      report_stuck("S8");

      ----------------------------------------------------------------------
      report "### S9: plain (unshifted) F1 sanity - expect Amiga F1=$50 make+break";
      phys(K_F1) <= '1'; wait for T_STEP;
      phys(K_F1) <= '0'; wait for T_STEP;
      report_stuck("S9");

      ----------------------------------------------------------------------
      report "### S10: press plain F1 first, then press LSHIFT while F1 held; release both";
      phys(K_F1)     <= '1'; wait for T_STEP;   -- plain F1 ($50)
      phys(K_LSHIFT) <= '1'; wait for T_STEP;   -- shift added after the fact
      phys(K_F1)     <= '0'; wait for T_STEP;
      phys(K_LSHIFT) <= '0'; wait for T_STEP;
      report_stuck("S10");

      ----------------------------------------------------------------------
      report "### S11: tight tap - hold LSHIFT, F1 down+up inside ~2 ms (faster than 6 ms pace)";
      phys(K_LSHIFT) <= '1'; wait for T_STEP;
      phys(K_F1) <= '1'; wait for 2 ms; phys(K_F1) <= '0'; wait for T_STEP;
      phys(K_LSHIFT) <= '0'; wait for T_STEP;
      report_stuck("S11");

      ----------------------------------------------------------------------
      report "### S12: hold LSHIFT+F1 (=>F2), then tap a normal key A while both held, release all";
      phys(K_LSHIFT) <= '1'; wait for T_STEP;
      phys(K_F1)     <= '1'; wait for T_STEP;   -- F2 make, shift suppressed
      phys(10)       <= '1'; wait for T_STEP;   -- A ($20) while F2 held (shift hidden)
      phys(10)       <= '0'; wait for T_STEP;   -- A release
      phys(K_F1)     <= '0'; wait for T_STEP;   -- F2 break, shift re-made
      phys(K_LSHIFT) <= '0'; wait for T_STEP;   -- shift break
      report_stuck("S12");

      ----------------------------------------------------------------------
      -- After the substituted F-key releases while the physical shift is still held, the shift is
      -- re-made, so a normal key pressed next reads as Shift+key. Must be balanced (the re-made
      -- shift is delivered).
      report "### S13: SHIFT, F1(=>F2), release F1 (shift re-made), then A => Shift+A, release all";
      phys(K_LSHIFT) <= '1'; wait for T_STEP;   -- shift make $60
      phys(K_F1)     <= '1'; wait for T_STEP;   -- F2 make, shift retracted ($E0,$51)
      phys(K_F1)     <= '0'; wait for T_STEP;   -- F2 break, shift re-made ($D1,$60)
      phys(10)       <= '1'; wait for T_STEP;   -- A ($20) now WITH shift held => Shift+A
      phys(10)       <= '0'; wait for T_STEP;   -- A release
      phys(K_LSHIFT) <= '0'; wait for T_STEP;   -- shift break $E0
      report_stuck("S13");

      report "=== ALL SCENARIOS DONE (total events=" & integer'image(ev_count) & ") ===";
      report_stuck("FINAL");
      finish;
   end process stim;

end architecture sim;
