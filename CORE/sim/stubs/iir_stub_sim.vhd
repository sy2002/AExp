-- Simulation-only stub of MiSTer's IIR_filter
-- (M2M/vhdl/controllers/MiSTer/iir_filter.v) for the pure-VHDL glue testbench
-- CORE/sim/audio/tb_audio_filters.vhd: nvc cannot elaborate mixed-language
-- designs. The stub adds a fixed +100 offset, so the testbench can tell
-- exactly which filter stages the audio_filters muxes have placed in the
-- path: raw = +0, one filter = +100, both filters = +200. The real filter is
-- checked by CORE/sim/audio/tb_iir_amiga.v.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity IIR_filter is
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
end entity IIR_filter;

architecture sim of IIR_filter is
begin
   output_l <= std_logic_vector(signed(input_l) + 100);
   output_r <= std_logic_vector(signed(input_r) + 100);
end architecture sim;
