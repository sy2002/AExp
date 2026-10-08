---------------------------------------------------------------------------------------------------------
-- Flow-control (keyboard-handshake) testbench for CORE/vhdl/keyboard.vhd
--
-- The perfect-reader testbench (tb_keyboard.vhd) checks that the wire stream is balanced. This one
-- checks the send-then-wait-for-acknowledge flow control: no code is ever emitted while the
-- previous one is still unread by the reader (the single-byte CIA-A SDR overrun), for any reader
-- speed. Without it a slow raw-CIA reader loses codes and shifted F-keys stay stuck.
--
-- Reader model (faithful to ciaa.v + the CPU handshake):
--   * A single-byte modelled SDR (sdr_reg/sdr_full): each kms_level toggle writes it. If it is
--     written while it is still full (the previous code was not yet read) that is an overrun =
--     a lost code = the stuck-key symptom. overrun must stay 0 for any reading consumer.
--   * The reader reads the SDR a configurable latency after a code appears and drives kbd_ack_i
--     high for a realistic multi-cycle window (~40 clk_main), not a one-cycle pulse. The held
--     level matters: a level-latched pacer would let the tail of one read re-acknowledge the next
--     code (every-other-code drop); the DUT's rising-edge detect + settling blackout must make one
--     read == one ack. A 1-cycle-pulse model would let such a level design pass, so this model
--     deliberately holds the ack across the send.
--   * The read consumes the current code into down_map (the keyboard.device matrix view): a MAKE
--     left "down" at the end of a scenario == a key that stays lit in a keyboard tester.
--
-- Three reader profiles are exercised:
--   * FAST  (latency < 1 ms): acks within the min-gap floor => 1 ms pacing, identical to a pure
--     fixed-pace design (no added latency) - measured, see the burst timing check.
--   * SLOW  (latency 3 ms > floor): the read lands after pace_cnt has reached 0, the case a
--     level-latched pacer gets wrong.
--   * NONE  (reader disabled): no ack ever => the deadlock timeout must still drain the FIFO.
--
-- The bench ends with "RESULT: PASS" or fails with "RESULT: FAIL".
--
-- Run: CORE/sim/keyboard/run.sh (about a minute for this bench).
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_keyboard_lossy is
end entity tb_keyboard_lossy;

architecture sim of tb_keyboard_lossy is

   signal clk_main        : std_logic := '0';
   signal reset           : std_logic := '1';
   signal kb_key_num      : integer range 0 to 79 := 0;
   signal kb_key_pressed_n: std_logic := '1';
   signal kbd_data        : std_logic_vector(7 downto 0);
   signal kbd_type        : std_logic_vector(1 downto 0);
   signal kms_level       : std_logic;
   signal kbd_ack         : std_logic := '0';   -- driven only by the reader process (sole driver)
   signal core_reset      : std_logic;
   signal mouse_rmb       : std_logic;

   constant CLK_PERIOD : time := 35.2423 ns;    -- 28.375 MHz
   constant C_DWELL    : natural := 355;         -- ~1 kHz sweep / 80 keys

   type t_phys is array(0 to 79) of std_logic;
   signal phys : t_phys := (others => '0');

   -- reader model configuration (set by the stimulus per phase)
   signal rd_enable  : std_logic := '1';         -- '0' = non-reading consumer (timeout path)
   signal rd_latency : time := 3 ms;             -- reader response delay after a code appears
   -- The real ciaa.kbd_ack is a cck-gated level, so ONE CIA read appears as SEVERAL clk_main pulses
   -- (~1 clk7 = ~4 cycles apart; empirically 3 edges/read against amiga_clk + the m68k bridge). Model
   -- that faithfully so the coalescing (ack_armed) is actually exercised - a single clean pulse would
   -- not stress it. Each read = C_BOUNCE pulses of ~4 cyc high / ~4 cyc low.
   constant C_BOUNCE  : natural := 3;
   constant RD_HI     : time := 4 * CLK_PERIOD;
   constant RD_LO     : time := 4 * CLK_PERIOD;

   -- modelled single-byte CIA-A SDR + the reader's key-down view
   signal sdr_reg    : std_logic_vector(7 downto 0) := (others => '0');
   signal sdr_full   : std_logic := '0';
   signal down_map   : std_logic_vector(0 to 127) := (others => '0');
   signal overrun    : natural := 0;
   signal pv_time    : time := 0 ns;
   signal pv_valid   : std_logic := '0';
   signal scen_rst   : std_logic := '0';
   -- ONE logical read consumes ONE code, regardless of how many electrical cck bounce pulses the
   -- read produces on kbd_ack. rd_strobe pulses once per read (the logical consume); kbd_ack carries
   -- the bounce for the DUT to observe. (Consuming on each kbd_ack edge would mis-model reality:
   -- read A's later bounce edges would "consume" code B, which the reader never actually read.)
   signal rd_strobe  : std_logic := '0';

   -- burst-timing capture (latency non-regression): time between two consecutive codes
   signal last_kms_t : time := 0 ns;
   signal gap_meas   : time := 0 ns;

   constant K_F1     : integer := 4;
   constant K_F3     : integer := 5;
   constant K_F5     : integer := 6;
   constant K_F7     : integer := 3;
   constant K_LSHIFT : integer := 15;
   constant K_RSHIFT : integer := 52;
   constant K_H      : integer := 29;   -- Amiga $25
   constant K_F9     : integer := 68;
   constant K_A      : integer := 10;   -- Amiga $20
   constant K_S      : integer := 13;   -- Amiga $21
   constant K_D      : integer := 18;   -- Amiga $22

   constant T_STEP : time := 8 ms;      -- human key spacing (>= 2x the slow reader's per-code pace)

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

   ------------------------------------------------------------------------------------------------
   -- Modelled SDR + reader key-down view. Sole driver of sdr_reg / sdr_full / down_map / overrun.
   --   kms edge  : a new code enters the single-byte SDR; if it was still full => OVERRUN (lost).
   --   ack rising: the reader reads the SDR => consume the current code, mark it read.
   ------------------------------------------------------------------------------------------------
   sdr_model : process (kms_level, rd_strobe, scen_rst)
      variable idx : integer;
   begin
      if scen_rst = '1' then
         down_map <= (others => '0');
         sdr_full <= '0';
         overrun  <= 0;
         pv_valid <= '0';
      elsif kms_level'event and reset = '0' then
         if sdr_full = '1' then
            report "  [OVERRUN] code $" & to_hstring(sdr_reg) &
                   " overwritten UNREAD by $" & to_hstring(kbd_data) severity warning;
            overrun <= overrun + 1;
         end if;
         if pv_valid = '1' then
            report "t=" & time'image(now) & "  code $" & to_hstring(kbd_data) &
                   "  (gap " & time'image(now - pv_time) & ")";
         else
            report "t=" & time'image(now) & "  code $" & to_hstring(kbd_data) & "  (first)";
         end if;
         sdr_reg  <= kbd_data;
         sdr_full <= '1';
         pv_time  <= now;
         pv_valid <= '1';
      elsif rd_strobe'event and rd_strobe = '1' and reset = '0' then
         -- one logical read consumes the code currently in the SDR (once)
         if sdr_full = '1' then
            idx := to_integer(unsigned(sdr_reg(6 downto 0)));
            if sdr_reg(7) = '0' then down_map(idx) <= '1'; else down_map(idx) <= '0'; end if;
            sdr_full <= '0';
         end if;
      end if;
   end process sdr_model;

   -- burst timing: capture the gap between consecutive codes (for the latency check)
   gap_capture : process (kms_level)
   begin
      if kms_level'event and reset = '0' then
         gap_meas   <= now - last_kms_t;
         last_kms_t <= now;
      end if;
   end process gap_capture;

   ------------------------------------------------------------------------------------------------
   -- Reader: sole driver of kbd_ack. Reads each code rd_latency after it appears and holds the ack
   -- HIGH for RD_WINDOW (multi-cycle). When disabled it never acks (deadlock-timeout path).
   ------------------------------------------------------------------------------------------------
   reader : process
   begin
      kbd_ack <= '0'; rd_strobe <= '0';
      loop
         if reset = '1' then
            wait until reset = '0';
         end if;
         if sdr_full = '0' then
            wait until sdr_full = '1' or reset = '1';
         end if;
         if reset = '0' and sdr_full = '1' then
            if rd_enable = '1' then
               wait for rd_latency;
               -- logical read: consume the code currently in the SDR, exactly once
               rd_strobe <= '1'; wait for CLK_PERIOD; rd_strobe <= '0';
               -- electrical waveform the DUT observes: C_BOUNCE cck-gated pulses (not one clean level)
               for i in 1 to C_BOUNCE loop
                  kbd_ack <= '1'; wait for RD_HI;
                  kbd_ack <= '0'; wait for RD_LO;
               end loop;
            else
               wait for 1 ms;   -- non-reading consumer: idle, let the DUT time out
            end if;
         end if;
      end loop;
   end process reader;

   ------------------------------------------------------------------------------------------------
   -- Stimulus
   ------------------------------------------------------------------------------------------------
   stim : process

      variable v_fail : boolean := false;   -- global pass/fail (written by the procedures below)
      variable n1     : natural;            -- NONE-phase timeout-drain counter

      procedure new_scenario(tag : string) is
      begin
         report "### " & tag;
         scen_rst <= '1'; wait for 200 ns; scen_rst <= '0'; wait for 200 ns;
      end procedure;

      -- wait for the FIFO to fully drain and be read, then check no stuck keys + no overruns
      procedure finish_scenario(tag : string) is
         variable any : boolean := false;
         variable v8  : std_logic_vector(7 downto 0);
      begin
         wait for 60 ms;                         -- >> worst-case drain at the slow 3 ms/code pace
         if sdr_full = '1' then
            report "  [WARN] a code is still unread at end of " & tag &
                   " ($" & to_hstring(sdr_reg) & ")" severity warning;
         end if;
         for i in 0 to 127 loop
            if down_map(i) = '1' then
               v8 := std_logic_vector(to_unsigned(i, 8));
               report "  >>> STUCK after " & tag & ": keycode $" & to_hstring(v8(6 downto 0))
                      severity error;
               v_fail := true;
               any := true;
            end if;
         end loop;
         if overrun /= 0 then
            report "  >>> OVERRUN after " & tag & ": " & integer'image(overrun) &
                   " code(s) dropped" severity error;
            v_fail := true;
         end if;
         if not any and overrun = 0 then
            report "  --- clean after " & tag & " (no stuck keys, no overruns)";
         end if;
      end procedure;

      -- the full scenario battery, run under whatever reader profile is currently set
      procedure run_battery(phase : string) is
      begin
         new_scenario(phase & " B1: back-to-back burst A/S/D make+break (no drop expected)");
         phys(K_A) <= '1'; phys(K_S) <= '1'; phys(K_D) <= '1'; wait for T_STEP;
         phys(K_A) <= '0'; phys(K_S) <= '0'; phys(K_D) <= '0';
         finish_scenario(phase & " B1");

         new_scenario(phase & " L1: hold LSHIFT, tap F1 (=>F2), release F1, release LSHIFT");
         phys(K_LSHIFT) <= '1'; wait for T_STEP;
         phys(K_F1)     <= '1'; wait for T_STEP;
         phys(K_F1)     <= '0'; wait for T_STEP;
         phys(K_LSHIFT) <= '0';
         finish_scenario(phase & " L1");

         new_scenario(phase & " L2: hold LSHIFT, tap F1/F3/F5/F7/F9, release LSHIFT");
         phys(K_LSHIFT) <= '1'; wait for T_STEP;
         phys(K_F1) <= '1'; wait for T_STEP; phys(K_F1) <= '0'; wait for T_STEP;
         phys(K_F3) <= '1'; wait for T_STEP; phys(K_F3) <= '0'; wait for T_STEP;
         phys(K_F5) <= '1'; wait for T_STEP; phys(K_F5) <= '0'; wait for T_STEP;
         phys(K_F7) <= '1'; wait for T_STEP; phys(K_F7) <= '0'; wait for T_STEP;
         phys(K_F9) <= '1'; wait for T_STEP; phys(K_F9) <= '0'; wait for T_STEP;
         phys(K_LSHIFT) <= '0';
         finish_scenario(phase & " L2");

         new_scenario(phase & " L3 (control): SHIFT+H");
         phys(K_LSHIFT) <= '1'; wait for T_STEP;
         phys(K_H)      <= '1'; wait for T_STEP;
         phys(K_H)      <= '0'; wait for T_STEP;
         phys(K_LSHIFT) <= '0';
         finish_scenario(phase & " L3");

         new_scenario(phase & " L4 (control): plain F1 tap (no shift)");
         phys(K_F1) <= '1'; wait for T_STEP;
         phys(K_F1) <= '0';
         finish_scenario(phase & " L4");

         new_scenario(phase & " L5: hold LSHIFT, press F1, release LSHIFT before F1, release F1");
         phys(K_LSHIFT) <= '1'; wait for T_STEP;
         phys(K_F1)     <= '1'; wait for T_STEP;
         phys(K_LSHIFT) <= '0'; wait for T_STEP;
         phys(K_F1)     <= '0';
         finish_scenario(phase & " L5");

         new_scenario(phase & " L6: right shift - hold RSHIFT, tap F9 (=>F10), release RSHIFT");
         phys(K_RSHIFT) <= '1'; wait for T_STEP;
         phys(K_F9)     <= '1'; wait for T_STEP;
         phys(K_F9)     <= '0'; wait for T_STEP;
         phys(K_RSHIFT) <= '0';
         finish_scenario(phase & " L6");

         -- F-key and shift released in the same scan sweep. A pacer without the handshake leaves
         -- a key stuck here (the F-key for F1..F7, the shift for F9); the handshake must deliver
         -- every code.
         new_scenario(phase & " L7: tap F1, release F1 and LSHIFT together");
         phys(K_LSHIFT) <= '1'; wait for T_STEP;
         phys(K_F1)     <= '1'; wait for T_STEP;
         phys(K_F1) <= '0'; phys(K_LSHIFT) <= '0';   -- same sweep
         finish_scenario(phase & " L7");

         new_scenario(phase & " L7f: F9 variant, release F9 and RSHIFT together");
         phys(K_RSHIFT) <= '1'; wait for T_STEP;
         phys(K_F9)     <= '1'; wait for T_STEP;
         phys(K_F9) <= '0'; phys(K_RSHIFT) <= '0';   -- same sweep (F9 scanned after the shifts)
         finish_scenario(phase & " L7f");

         -- after a substituted F-key releases while the physical shift is still held, the shift is
         -- re-made, so a following normal key reads as Shift+key. Must be balanced (no stuck) - the re-made shift is delivered reliably.
         new_scenario(phase & " L8: SHIFT, F1(=>F2), release F1, then A (Shift+A), release all");
         phys(K_LSHIFT) <= '1'; wait for T_STEP;
         phys(K_F1)     <= '1'; wait for T_STEP;
         phys(K_F1)     <= '0'; wait for T_STEP;
         phys(K_A)      <= '1'; wait for T_STEP;
         phys(K_A)      <= '0'; wait for T_STEP;
         phys(K_LSHIFT) <= '0';
         finish_scenario(phase & " L8");
      end procedure;

   begin
      wait for 1 us; reset <= '0';
      wait for 110 ms;                           -- past the 100 ms post-reset hold-off
      report "=== flow-control stimulus start ===";

      ----------------------------------------------------------------------------------------------
      -- SLOW reader (3 ms latency > 1 ms floor): the read lands after pace_cnt=0
      ----------------------------------------------------------------------------------------------
      rd_enable <= '1'; rd_latency <= 3 ms;
      report "===== PHASE SLOW (reader latency 3 ms) =====";
      run_battery("SLOW");

      ----------------------------------------------------------------------------------------------
      -- FAST reader (200 us latency < 1 ms floor): must reproduce the 1 ms fixed-pace timing
      ----------------------------------------------------------------------------------------------
      rd_enable <= '1'; rd_latency <= 200 us;
      report "===== PHASE FAST (reader latency 200 us) =====";
      run_battery("FAST");

      -- latency non-regression: with a fast reader the pacing floor is 1 ms. Drive a clean burst of
      -- three well-separated codes and confirm consecutive codes are ~1 ms apart (not 3 ms).
      report "### FAST timing: burst of plain taps, expect ~1 ms code spacing";
      scen_rst <= '1'; wait for 200 ns; scen_rst <= '0'; wait for 200 ns;
      phys(K_A) <= '1'; phys(K_S) <= '1'; phys(K_D) <= '1';   -- 3 makes queued back-to-back
      wait for 100 us;                             -- let the first make out, then measure the 2nd->3rd
      wait for 5 ms;                               -- all three makes drained
      report "  measured last code spacing (fast reader) = " & time'image(gap_meas);
      assert gap_meas <= 1500 us
         report "  >>> LATENCY REGRESSION: fast-reader code spacing " & time'image(gap_meas) &
                " exceeds the 1 ms floor by too much" severity error;
      if gap_meas > 1500 us then v_fail := true; end if;
      phys(K_A) <= '0'; phys(K_S) <= '0'; phys(K_D) <= '0';
      wait for 10 ms;

      ----------------------------------------------------------------------------------------------
      -- NONE (non-reading consumer): no ack ever. The ~143 ms deadlock timeout must still drain the
      -- FIFO - verify kms keeps toggling (no deadlock). Overruns are EXPECTED here (documented drop
      -- behaviour of a non-reading consumer), so they are not a failure in this phase.
      ----------------------------------------------------------------------------------------------
      rd_enable <= '0';
      report "===== PHASE NONE (no reader; deadlock-timeout drain) =====";
      scen_rst <= '1'; wait for 200 ns; scen_rst <= '0'; wait for 200 ns;
      phys(K_A) <= '1'; phys(K_S) <= '1'; phys(K_D) <= '1';   -- 3 codes queued, no reader
      n1 := 0;
      -- watch two timeout intervals (~2 x 143 ms); expect at least 2 codes to have drained
      for i in 0 to 1 loop
         wait on kms_level for 300 ms;
         if kms_level'event then n1 := n1 + 1; end if;
      end loop;
      report "  codes drained under timeout in ~600 ms = " & integer'image(n1);
      assert n1 >= 2
         report "  >>> DEADLOCK: the timeout did not drain the FIFO (drained " &
                integer'image(n1) & ")" severity error;
      if n1 < 2 then v_fail := true; end if;
      phys(K_A) <= '0'; phys(K_S) <= '0'; phys(K_D) <= '0';

      report "=== ALL FLOW-CONTROL SCENARIOS DONE ===";
      if v_fail then
         report "@@@ RESULT: FAIL @@@" severity failure;
      else
         report "@@@ RESULT: PASS (no stuck keys, no overruns, latency floor kept, no deadlock) @@@";
      end if;
      finish;
   end process stim;

end architecture sim;
