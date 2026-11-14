-- Testbench: CORE/vhdl/audio_filters.vhd glue logic (muxes, LED gating,
-- stereo crossfeed, widening) using the +100-offset IIR stub
-- (CORE/sim/stubs/iir_stub_sim.vhd), so every mux decision is observable:
--    raw path = +0, one filter in path = +100, both = +200.
--
-- The crossfeed golden values come from an independent Python
-- implementation of MiSTer's aud_mix_top blends (floor shifts, pre_in =
-- halved opposite channel folded into the shift amounts).
-- See doc/developers/audio.md, section "Verification".
--
-- Run: CORE/sim/audio/run.sh (a few seconds, together with tb_iir_amiga.v).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_audio_filters is
end entity tb_audio_filters;

architecture sim of tb_audio_filters is

   signal clk     : std_logic := '0';
   signal reset   : std_logic := '1';
   signal ce      : std_logic := '0';
   signal ldata   : std_logic_vector(14 downto 0) := (others => '0');
   signal rdata   : std_logic_vector(14 downto 0) := (others => '0');
   signal a500    : std_logic := '0';
   signal led     : std_logic := '0';
   signal mix     : std_logic_vector(1 downto 0) := "00";
   signal pwr_led : std_logic := '0';
   signal out_l   : signed(15 downto 0);
   signal out_r   : signed(15 downto 0);

   signal running : boolean := true;

   type row_t is record
      l15  : integer; r15 : integer;
      mix  : std_logic_vector(1 downto 0);
      el   : integer; er : integer;
   end record;
   type rows_t is array (0 to 23) of row_t;
   constant C_ROWS : rows_t := (
      (  1000,   -500, "00",   2000,  -1000),
      (  1000,   -500, "01",   1625,   -625),
      (  1000,   -500, "10",   1250,   -250),
      (  1000,   -500, "11",    500,    500),
      ( 16383, -16384, "00",  32766, -32768),
      ( 16383, -16384, "01",  24575, -24577),
      ( 16383, -16384, "10",  16383, -16385),
      ( 16383, -16384, "11",     -1,     -1),
      (-16384,  16383, "00", -32768,  32766),
      (-16384,  16383, "01", -24577,  24575),
      (-16384,  16383, "10", -16385,  16383),
      (-16384,  16383, "11",     -1,     -1),
      ( 12345, -11111, "00",  24690, -22222),
      ( 12345, -11111, "01",  18826, -16358),
      ( 12345, -11111, "10",  12962, -10494),
      ( 12345, -11111, "11",   1234,   1234),
      (     0,      0, "00",      0,      0),
      (     0,      0, "01",      0,      0),
      (     0,      0, "10",      0,      0),
      (     0,      0, "11",      0,      0),
      (    -1,      1, "00",     -2,      2),
      (    -1,      1, "01",     -1,      1),
      (    -1,      1, "10",     -1,      1),
      (    -1,      1, "11",      0,      0)
   );

begin

   clk <= not clk after 17.6 ns when running else '0';
   ce  <= not ce when rising_edge(clk);

   uut : entity work.audio_filters
      port map (
         clk_main_i    => clk,
         reset_i       => reset,
         ce_i          => ce,
         ldata_i       => ldata,
         rdata_i       => rdata,
         a500_filter_i => a500,
         led_filter_i  => led,
         stereo_mix_i  => mix,
         pwr_led_i     => pwr_led,
         audio_left_o  => out_l,
         audio_right_o => out_r
      );

   main : process
      variable errors : natural := 0;

      procedure settle is
      begin
         for i in 1 to 10 loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      procedure check(name : string; el, er : integer) is
      begin
         if to_integer(out_l) /= el or to_integer(out_r) /= er then
            report "FAIL " & name & ": got (" & integer'image(to_integer(out_l)) &
                   "," & integer'image(to_integer(out_r)) & ") expected (" &
                   integer'image(el) & "," & integer'image(er) & ")"
               severity error;
            errors := errors + 1;
         else
            report "pass " & name;
         end if;
      end procedure;

      procedure drive(l15, r15 : integer) is
      begin
         ldata <= std_logic_vector(to_signed(l15, 15));
         rdata <= std_logic_vector(to_signed(r15, 15));
      end procedure;

   begin
      wait for 100 ns;
      reset <= '0';
      settle;

      -- S1: everything off = bit-transparent bypass (out = {in,'0'})
      mix <= "00"; a500 <= '0'; led <= '0'; pwr_led <= '0';
      drive(1234, -4321);  settle; check("S1 bypass",           2468, -8642);
      drive(-16384, 16383); settle; check("S1 bypass extremes", -32768, 32766);
      pwr_led <= '1';      settle; check("S1 LED bit ignored",  -32768, 32766);

      -- S2: A500 filter selected (one stub stage = +100)
      a500 <= '1'; led <= '0'; pwr_led <= '0';
      drive(1000, -1000); settle; check("S2 A500 on",  2100, -1900);
      pwr_led <= '1';     settle; check("S2 LED disarmed", 2100, -1900);

      -- S3: LED filter gating (armed toggle AND live pwr_led)
      a500 <= '1'; led <= '1'; pwr_led <= '1';
      settle; check("S3 A500+LED", 2200, -1800);
      pwr_led <= '0';
      settle; check("S3 LED follows pwr off", 2100, -1900);
      a500 <= '0'; pwr_led <= '1';
      settle; check("S3 LED on raw path", 2100, -1900);
      led <= '0';
      settle; check("S3 all off again", 2000, -2000);

      -- S4: crossfeed blends against the independent golden table
      a500 <= '0'; led <= '0'; pwr_led <= '0';
      for i in C_ROWS'range loop
         drive(C_ROWS(i).l15, C_ROWS(i).r15);
         mix <= C_ROWS(i).mix;
         settle;
         check("S4 row " & integer'image(i), C_ROWS(i).el, C_ROWS(i).er);
      end loop;

      if errors = 0 then
         report "ALL PASS";
      else
         report integer'image(errors) & " FAILURES" severity failure;
      end if;
      running <= false;
      wait;
   end process main;

end architecture sim;
