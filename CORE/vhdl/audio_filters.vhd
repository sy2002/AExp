----------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- Paula output filters and stereo crossfeed
--
-- Faithful port of the audio output stage of MiSTer's Minimig.sv (everything
-- between Paula's ldata/rdata and the MiSTer framework):
--
--    Paula -> [A500 fixed low-pass] -> [power-LED filter] -> [stereo crossfeed]
--
--  * a500_filter_i (OSM "A500 Filter") inserts the fixed 4400 Hz 1st-order RC
--    low-pass that sits behind Paula's DAC in every A500. Bypassing it gives
--    the brighter A1200-style output stage (the A1200 dropped this filter).
--  * led_filter_i ("LED Filter") arms the switchable 3000 Hz + 3400 Hz
--    two-stage low-pass that Commodore attached to CIA-A PA1 - the same pin
--    that controls the power LED, so a bright LED means "filter engaged".
--    While armed, the filter follows the emulated software live via pwr_led_i
--    (MiSTer's "Auto(LED)" mode); disarmed it never engages.
--  * stereo_mix_i is MiSTer's aud_mix crossfeed for Paula's hard-panned
--    channels (0+3 = left, 1+2 = right): 00 = full separation,
--    01 = 87.5%/12.5% ("Wide Stereo"), 10 = 75%/25% ("Narrow Stereo"),
--    11 = mono. The three blends are energy-preserving, so they cannot clip.
--
-- The two IIR instances reuse M2M's copy of MiSTer's iir_filter.v (the same
-- module Minimig.sv instantiates) with the Minimig.sv coefficient values
-- verbatim; coefficient ports that Minimig.sv leaves unconnected are tied to
-- zero, which is what synthesis makes of an unconnected input port. ce_i must
-- be the 14.19 MHz enable pair (clk7_en or clk7n_en): the filter
-- time-multiplexes both channels on it, yielding the 7.09 MHz per-channel
-- update rate the coefficients are designed for.
--
-- All control inputs are static OSM bits in the core clock domain. The block
-- sits ahead of the master-volume stage in main.vhd and therefore ahead of
-- the framework's split into the HDMI and analog audio paths.
--
-- This machine is based on Minimig (Amiga)
-- Powered by MiSTer2MEGA65 done by sy2002 in 2023 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_filters is
   port (
      clk_main_i    : in  std_logic;                     -- 28.375 MHz core clock
      reset_i       : in  std_logic;                     -- active high
      ce_i          : in  std_logic;                     -- clk7_en or clk7n_en (14.19 MHz)

      -- raw Paula mix from minimig (15-bit signed)
      ldata_i       : in  std_logic_vector(14 downto 0);
      rdata_i       : in  std_logic_vector(14 downto 0);

      -- static OSM controls (core clock domain)
      a500_filter_i : in  std_logic;                     -- '1' = fixed 4400 Hz low-pass in path
      led_filter_i  : in  std_logic;                     -- '1' = LED filter follows pwr_led_i
      stereo_mix_i  : in  std_logic_vector(1 downto 0);  -- 00 = full stereo .. 11 = mono
      pwr_led_i     : in  std_logic;                     -- CIA-A PA1: '1' = LED bright = filter on

      -- filtered/mixed PCM towards the master-volume stage in main.vhd
      audio_left_o  : out signed(15 downto 0);
      audio_right_o : out signed(15 downto 0)
   );
end entity audio_filters;

architecture synthesis of audio_filters is

   -- MiSTer's 3-tap stereo IIR (M2M/vhdl/controllers/MiSTer/iir_filter.v).
   -- use_params = 0 selects the coefficient ports; the float generics that
   -- exist in the Verilog module stay at their (unused) defaults.
   component IIR_filter is
      generic (
         use_params : integer;
         stereo     : integer
      );
      port (
         clk        : in  std_logic;
         reset      : in  std_logic;
         ce         : in  std_logic;
         sample_ce  : in  std_logic;
         cx         : in  std_logic_vector(39 downto 0);
         cx0        : in  std_logic_vector( 7 downto 0);
         cx1        : in  std_logic_vector( 7 downto 0);
         cx2        : in  std_logic_vector( 7 downto 0);
         cy0        : in  std_logic_vector(23 downto 0);
         cy1        : in  std_logic_vector(23 downto 0);
         cy2        : in  std_logic_vector(23 downto 0);
         input_l    : in  std_logic_vector(15 downto 0);
         input_r    : in  std_logic_vector(15 downto 0);
         output_l   : out std_logic_vector(15 downto 0);
         output_r   : out std_logic_vector(15 downto 0)
      );
   end component IIR_filter;

   -- Coefficients verbatim from Minimig.sv, designed for the 7.09 MHz
   -- per-channel rate: "LPF 4400Hz, 1st order, 6db/oct" (the A500 fixed
   -- filter) and "LPF 3000Hz 1st + 3400Hz 1st" (the LED filter)
   constant C_LPF4400_CX  : std_logic_vector(39 downto 0) := x"01009694D8";  -- 40'd4304835800
   constant C_LPF4400_CX0 : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(1, 8));
   constant C_LPF4400_CY0 : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-2088941, 24));

   constant C_LPF3275_CX  : std_logic_vector(39 downto 0) := std_logic_vector(to_unsigned(8536629, 40));
   constant C_LPF3275_CX0 : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(2, 8));
   constant C_LPF3275_CX1 : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(1, 8));
   constant C_LPF3275_CY0 : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-4182432, 24));
   constant C_LPF3275_CY1 : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(2085297, 24));

   constant C_ZERO8       : std_logic_vector( 7 downto 0) := (others => '0');
   constant C_ZERO24      : std_logic_vector(23 downto 0) := (others => '0');

   -- Paula 15-bit widened to 16-bit (as MiSTer: {data, 1'b0})
   signal paula_l   : std_logic_vector(15 downto 0);
   signal paula_r   : std_logic_vector(15 downto 0);

   signal lpf4400_l : std_logic_vector(15 downto 0);
   signal lpf4400_r : std_logic_vector(15 downto 0);
   signal audm_l    : std_logic_vector(15 downto 0);    -- post model select (A500/A1200)
   signal audm_r    : std_logic_vector(15 downto 0);
   signal lpf3275_l : std_logic_vector(15 downto 0);
   signal lpf3275_r : std_logic_vector(15 downto 0);
   signal flt_en    : std_logic;                        -- LED filter engaged right now
   signal sel_l     : std_logic_vector(15 downto 0);    -- post LED-filter select
   signal sel_r     : std_logic_vector(15 downto 0);

   -- MiSTer aud_mix_top output clamp: 17-bit intermediate back to 16-bit.
   -- Unreachable with the energy-preserving blends below; kept as a guard.
   function clamp16(v : signed(16 downto 0)) return signed is
   begin
      if v(16) /= v(15) then
         if v(16) = '0' then
            return to_signed(32767, 16);
         else
            return to_signed(-32768, 16);
         end if;
      end if;
      return v(15 downto 0);
   end function clamp16;

begin

   paula_l <= ldata_i & '0';
   paula_r <= rdata_i & '0';

   -- The A500 fixed low-pass runs unconditionally (its state must be warm the
   -- moment it is switched into the path); a500_filter_i only selects it
   i_lpf4400 : IIR_filter
      generic map (
         use_params => 0,
         stereo     => 1
      )
      port map (
         clk        => clk_main_i,
         reset      => reset_i,
         ce         => ce_i,
         sample_ce  => '1',
         cx         => C_LPF4400_CX,
         cx0        => C_LPF4400_CX0,
         cx1        => C_ZERO8,
         cx2        => C_ZERO8,
         cy0        => C_LPF4400_CY0,
         cy1        => C_ZERO24,
         cy2        => C_ZERO24,
         input_l    => paula_l,
         input_r    => paula_r,
         output_l   => lpf4400_l,
         output_r   => lpf4400_r
      ); -- i_lpf4400

   audm_l <= lpf4400_l when a500_filter_i = '1' else paula_l;
   audm_r <= lpf4400_r when a500_filter_i = '1' else paula_r;

   -- The LED filter is chained behind the model select, exactly as in
   -- Minimig.sv: with the A500 Filter off it operates on the raw Paula mix
   i_lpf3275 : IIR_filter
      generic map (
         use_params => 0,
         stereo     => 1
      )
      port map (
         clk        => clk_main_i,
         reset      => reset_i,
         ce         => ce_i,
         sample_ce  => '1',
         cx         => C_LPF3275_CX,
         cx0        => C_LPF3275_CX0,
         cx1        => C_LPF3275_CX1,
         cx2        => C_ZERO8,
         cy0        => C_LPF3275_CY0,
         cy1        => C_LPF3275_CY1,
         cy2        => C_ZERO24,
         input_l    => audm_l,
         input_r    => audm_r,
         output_l   => lpf3275_l,
         output_r   => lpf3275_r
      ); -- i_lpf3275

   flt_en <= led_filter_i and pwr_led_i;

   sel_l <= lpf3275_l when flt_en = '1' else audm_l;
   sel_r <= lpf3275_r when flt_en = '1' else audm_r;

   -- Stereo crossfeed: MiSTer's aud_mix_top blends (sys/audio_out.sv) with the
   -- identical floor-shift arithmetic; pre_in there is the halved opposite
   -- channel, so the shift amounts below already include that halving.
   -- Registered on the core clock - the one-cycle latency is inaudible.
   crossfeed_proc : process (clk_main_i)
      variable l  : signed(16 downto 0);
      variable r  : signed(16 downto 0);
      variable l3 : signed(16 downto 0);
      variable r3 : signed(16 downto 0);
   begin
      if rising_edge(clk_main_i) then
         l := resize(signed(sel_l), 17);
         r := resize(signed(sel_r), 17);
         case stereo_mix_i is
            when "00" =>                                       -- Full Stereo
               l3 := l;
               r3 := r;
            when "01" =>                                       -- Wide Stereo: 87.5% / 12.5%
               l3 := l - shift_right(l, 3) + shift_right(r, 3);
               r3 := r - shift_right(r, 3) + shift_right(l, 3);
            when "10" =>                                       -- Narrow Stereo: 75% / 25%
               l3 := l - shift_right(l, 2) + shift_right(r, 2);
               r3 := r - shift_right(r, 2) + shift_right(l, 2);
            when others =>                                     -- Mono
               l3 := shift_right(l, 1) + shift_right(r, 1);
               r3 := l3;
         end case;
         audio_left_o  <= clamp16(l3);
         audio_right_o <= clamp16(r3);
      end if;
   end process crossfeed_proc;

end architecture synthesis;
