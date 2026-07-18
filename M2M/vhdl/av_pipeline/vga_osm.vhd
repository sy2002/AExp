-------------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- VGA On-Screen-Menu (OSM)
--
-- The OSM is rendered using the font and is based on the VRAM and
-- VRAM attribute memory.
--
-- The standard 16x16 OSM cell is backed by the native 8x8 Anikki strike.
-- At 100% every native pixel is expanded to the exact legacy 2x2 block.  The
-- smaller integer cell sizes (15 down to 8 pixels) use sharpened bilinear
-- coverage.  In raw 15 kHz mode the vertical kernel widens towards a two-row
-- box at 50%, because the output visits only every second logical OSM row.
--
-- The signals vga_osm_on_o and vga_osm_rgb_o are delayed nine clock cycles
-- after vga_col_i and vga_row_i.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2021 and licensed under GPL v3
-------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.numeric_std_unsigned.all;

entity vga_osm is
   generic  (
      G_VGA_DX              : natural;
      G_VGA_DY              : natural;
      G_FONT_FILE           : string;
      G_FONT_DX             : natural;
      G_FONT_DY             : natural
   );
   port (
      clk_i                 : in  std_logic;

      vga_col_i             : in  integer range 0 to 2047;
      vga_row_i             : in  integer range 0 to 2047;

      vga_osm_cfg_scaling_i : in  integer range 0 to 8;
      vga_osm_cfg_enable_i  : in  std_logic;
      vga_osm_cfg_r15kHz_i  : in  std_logic;
      vga_osm_cfg_xy_i      : in  std_logic_vector(15 downto 0);
      vga_osm_cfg_dxdy_i    : in  std_logic_vector(15 downto 0);
      vga_osm_vram_addr_o   : out std_logic_vector(15 downto 0);
      vga_osm_vram_data_i   : in  std_logic_vector(7 downto 0);
      vga_osm_vram_attr_i   : in  std_logic_vector(7 downto 0);

      vga_osm_on_o          : out std_logic;
      vga_osm_rgb_o         : out std_logic_vector(23 downto 0)
   );
end vga_osm;

architecture synthesis of vga_osm is

   -- The firmware-facing canvas remains a grid of 16x16-pixel cells.
   constant CHARS_DX          : integer := G_VGA_DX / G_FONT_DX;
   constant CHARS_DY          : integer := G_VGA_DY / G_FONT_DY;
   constant C_NATIVE_FONT_DX  : integer := 8;
   constant C_NATIVE_FONT_DY  : integer := 8;
   constant C_NATIVE_ADDR_W   : integer := 8;  -- 256 packed glyphs
   constant C_NATIVE_GLYPH_W  : integer := C_NATIVE_FONT_DX * C_NATIVE_FONT_DY;
   constant C_Q4_X_MAX        : integer := G_VGA_DX * 16 - 1;
   constant C_Q4_Y_MAX        : integer := G_VGA_DY * 16 - 1;

   subtype weight_t is integer range 0 to 16;
   type weight_phase_lut_t is array (0 to 15) of weight_t;
   type vertical_weight_lut_t is array (0 to 8) of weight_phase_lut_t;

   -- Cubic sharp-bilinear phase curve, quantized to 1/16 coverage.  It is the
   -- small-font equivalent of ascal's sharp-bilinear phase remapping.
   constant C_SHARP_WEIGHT : weight_phase_lut_t := (
      0, 0, 0, 0, 1, 2, 3, 5, 8, 11, 13, 14, 15, 16, 16, 16
   );

   -- Exact expansion of
   --   ((8-scale) * C_SHARP_WEIGHT(phase) + scale * 8 + 4) / 8
   -- for raw 15 kHz.  Looking the final weight up several stages before the
   -- filter removes that arithmetic from the glyph-to-coverage path without
   -- changing a single rounded result.
   constant C_15KHZ_WEIGHT : vertical_weight_lut_t := (
      (0, 0, 0, 0, 1, 2, 3, 5, 8, 11, 13, 14, 15, 16, 16, 16),
      (1, 1, 1, 1, 2, 3, 4, 5, 8, 11, 12, 13, 14, 15, 15, 15),
      (2, 2, 2, 2, 3, 4, 4, 6, 8, 10, 12, 13, 13, 14, 14, 14),
      (3, 3, 3, 3, 4, 4, 5, 6, 8, 10, 11, 12, 12, 13, 13, 13),
      (4, 4, 4, 4, 5, 5, 6, 7, 8, 10, 11, 11, 12, 12, 12, 12),
      (5, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 10, 11, 11, 11, 11),
      (6, 6, 6, 6, 6, 7, 7, 7, 8, 9, 9, 10, 10, 10, 10, 10),
      (7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 9, 9, 9),
      (8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8)
   );

   -- scale-coordinate reciprocal table.  For scale index S the displayed
   -- cell is 16-S pixels wide/high.  Each value is
   -- ceil(2^15 * 256 / (16-S)).  With |delta| <= 2047 the multiply/shift below
   -- is exactly equal to trunc(delta * 256 / (16-S)), including all character
   -- boundaries, while retaining four fractional source-pixel bits.
   subtype reciprocal_value_t is integer range 0 to 1048576;
   type reciprocal_t is array (0 to 8) of reciprocal_value_t;
   constant C_RECIP_Q15 : reciprocal_t := (
      524288,  -- 16 pixels = 100%
      559241,  -- 15 pixels =  94%
      599187,  -- 14 pixels =  88%
      645278,  -- 13 pixels =  81%
      699051,  -- 12 pixels =  75%
      762601,  -- 11 pixels =  69%
      838861,  -- 10 pixels =  63%
      932068,  --  9 pixels =  56%
     1048576   --  8 pixels =  50%
   );

   constant C_PRODUCT_MAX : integer := 2047 * 1048576;

   type stage_t is record
      vga_osm_cfg_scaling  : integer range 0 to 8;
      vga_osm_cfg_r15kHz   : std_logic;
      vga_osm_x1           : integer range 0 to 127;
      vga_osm_x2           : integer range 0 to 127;
      vga_osm_y1           : integer range 0 to 127;
      vga_osm_y2           : integer range 0 to 127;
      vga_pivot_x          : integer range 0 to 2047;
      vga_pivot_y          : integer range 0 to 2047;
      vga_delta_x_negative  : std_logic;
      vga_delta_y_negative  : std_logic;
      vga_delta_x_magnitude : integer range 0 to 2047;
      vga_delta_y_magnitude : integer range 0 to 2047;
      vga_scaled_x_product  : integer range 0 to C_PRODUCT_MAX;
      vga_scaled_y_product  : integer range 0 to C_PRODUCT_MAX;
      vga_coord_valid      : std_logic;
      vga_char_x           : integer range 0 to 127;
      vga_char_y           : integer range 0 to 127;
      vga_native_x         : integer range 0 to 7;
      vga_native_y         : integer range 0 to 7;
      vga_frac_x           : integer range 0 to 15;
      vga_frac_y           : integer range 0 to 15;
      vga_weight_x         : weight_t;
      vga_weight_y         : weight_t;
      vga_osm_vram_addr    : std_logic_vector(15 downto 0);
      vga_osm_vram_attr    : std_logic_vector( 7 downto 0);
      vga_alpha            : weight_t;
      vga_legacy_ink       : std_logic;
      vga_osm_on           : std_logic;
      vga_osm_rgb          : std_logic_vector(23 downto 0);
   end record stage_t;

   constant STATE_INIT : stage_t := (
      vga_osm_cfg_scaling  => 0,
      vga_osm_cfg_r15kHz   => '0',
      vga_osm_x1           => 0,
      vga_osm_x2           => 0,
      vga_osm_y1           => 0,
      vga_osm_y2           => 0,
      vga_pivot_x          => 0,
      vga_pivot_y          => 0,
      vga_delta_x_negative  => '0',
      vga_delta_y_negative  => '0',
      vga_delta_x_magnitude => 0,
      vga_delta_y_magnitude => 0,
      vga_scaled_x_product  => 0,
      vga_scaled_y_product  => 0,
      vga_coord_valid      => '0',
      vga_char_x           => 0,
      vga_char_y           => 0,
      vga_native_x         => 0,
      vga_native_y         => 0,
      vga_frac_x           => 0,
      vga_frac_y           => 0,
      vga_weight_x         => 0,
      vga_weight_y         => 0,
      vga_osm_vram_addr    => X"0000",
      vga_osm_vram_attr    => X"00",
      vga_alpha            => 0,
      vga_legacy_ink       => '0',
      vga_osm_on           => '0',
      vga_osm_rgb          => X"000000"
   );

   signal stage1 : stage_t := STATE_INIT;
   signal stage2 : stage_t := STATE_INIT;
   signal stage3 : stage_t := STATE_INIT;
   signal stage4 : stage_t := STATE_INIT;
   signal stage5 : stage_t := STATE_INIT;
   signal stage6 : stage_t := STATE_INIT;
   signal stage7 : stage_t := STATE_INIT;
   signal stage8 : stage_t := STATE_INIT;
   signal stage9 : stage_t := STATE_INIT;

   subtype glyph_t is std_logic_vector(C_NATIVE_GLYPH_W-1 downto 0);
   subtype font_row_t is std_logic_vector(C_NATIVE_FONT_DX-1 downto 0);

   signal stage5_vga_osm_font_addr : std_logic_vector(C_NATIVE_ADDR_W-1 downto 0);
   signal stage5_vga_osm_vram_attr : std_logic_vector(7 downto 0);
   signal stage6_vga_osm_font_data : glyph_t;
   signal stage7_vga_osm_font_data : glyph_t := (others => '0');

   pure function clamp_q4(value: integer; limit: integer) return integer is
   begin
      if value < 0 then
         return 0;
      elsif value > limit then
         return limit;
      else
         return value;
      end if;
   end function clamp_q4;

   pure function glyph_row(glyph: glyph_t; row: integer) return font_row_t is
   begin
      case row is
         when 0      => return glyph(63 downto 56);
         when 1      => return glyph(55 downto 48);
         when 2      => return glyph(47 downto 40);
         when 3      => return glyph(39 downto 32);
         when 4      => return glyph(31 downto 24);
         when 5      => return glyph(23 downto 16);
         when 6      => return glyph(15 downto  8);
         when others => return glyph( 7 downto  0);
      end case;
   end function glyph_row;

   pure function ink_value(pixel: std_logic; inverse: std_logic) return integer is
   begin
      if pixel = not inverse then
         return 1;
      else
         return 0;
      end if;
   end function ink_value;

   -- A horizontal two-tap row has only four possible ink patterns.  Expressing
   -- them directly avoids building two conditional adders in the final stage.
   pure function row_coverage(left_ink: integer;
                              right_ink: integer;
                              weight: integer) return integer is
   begin
      if left_ink = right_ink then
         if left_ink = 1 then
            return 16;
         else
            return 0;
         end if;
      elsif left_ink = 1 then
         return 16 - weight;
      else
         return weight;
      end if;
   end function row_coverage;

   type coverage_lut_t is array (0 to 16) of std_logic_vector(7 downto 0);

   -- Exact values of round(brightness * coverage / 16).  A lookup removes the
   -- x127/x255 shift/subtract carry chains from the font-to-RGB timing path.
   constant C_COVERAGE_BRIGHT : coverage_lut_t := (
      x"00", x"10", x"20", x"30", x"40", x"50", x"60", x"70", x"80",
      x"8F", x"9F", x"AF", x"BF", x"CF", x"DF", x"EF", x"FF"
   );
   constant C_COVERAGE_DIM : coverage_lut_t := (
      x"00", x"08", x"10", x"18", x"20", x"28", x"30", x"38", x"40",
      x"47", x"4F", x"57", x"5F", x"67", x"6F", x"77", x"7F"
   );

   pure function coverage_level(dim: std_logic;
                                amount: weight_t) return std_logic_vector is
   begin
      if dim = '0' then
         return C_COVERAGE_BRIGHT(amount);
      else
         return C_COVERAGE_DIM(amount);
      end if;
   end function coverage_level;

   pure function select_channel(fg_on: std_logic;
                                bg_on: std_logic;
                                full_level: std_logic_vector(7 downto 0);
                                fg_level: std_logic_vector(7 downto 0);
                                bg_level: std_logic_vector(7 downto 0))
                                return std_logic_vector is
   begin
      if fg_on = '1' then
         if bg_on = '1' then
            return full_level;
         else
            return fg_level;
         end if;
      else
         if bg_on = '1' then
            return bg_level;
         else
            return x"00";
         end if;
      end if;
   end function select_channel;

begin

   assert G_FONT_DX = 16 and G_FONT_DY = 16
      report "vga_osm: native 8x8 renderer requires 16x16 OSM cells"
      severity failure;

   -----------
   -- Stage 1: Capture geometry and register distance from the scaling pivot.
   -----------

   p_stage1 : process (clk_i)
      variable vga_osm_x  : integer range 0 to 127;
      variable vga_osm_y  : integer range 0 to 127;
      variable vga_osm_dx : integer range 0 to 127;
      variable vga_osm_dy : integer range 0 to 127;
      variable pivot_x    : integer range 0 to 2047;
      variable pivot_y    : integer range 0 to 2047;
      variable delta_x    : integer range -2047 to 2047;
      variable delta_y    : integer range -2047 to 2047;
   begin
      if rising_edge(clk_i) then
         vga_osm_x  := to_integer(vga_osm_cfg_xy_i(15 downto 8));
         vga_osm_y  := to_integer(vga_osm_cfg_xy_i(7 downto 0));
         vga_osm_dx := to_integer(vga_osm_cfg_dxdy_i(15 downto 8));
         vga_osm_dy := to_integer(vga_osm_cfg_dxdy_i(7 downto 0));
         pivot_x    := vga_osm_dx * G_FONT_DX / 2;
         pivot_y    := vga_osm_dy * G_FONT_DY / 2;
         delta_x    := vga_col_i - pivot_x;
         delta_y    := vga_row_i - pivot_y;

         stage1.vga_osm_x1          <= vga_osm_x;
         stage1.vga_osm_y1          <= vga_osm_y;
         stage1.vga_osm_x2          <= vga_osm_x + vga_osm_dx;
         stage1.vga_osm_y2          <= vga_osm_y + vga_osm_dy;
         stage1.vga_pivot_x         <= pivot_x;
         stage1.vga_pivot_y         <= pivot_y;
         stage1.vga_osm_cfg_scaling <= vga_osm_cfg_scaling_i;
         stage1.vga_osm_cfg_r15kHz  <= vga_osm_cfg_r15kHz_i;

         if delta_x < 0 then
            stage1.vga_delta_x_negative  <= '1';
            stage1.vga_delta_x_magnitude <= -delta_x;
         else
            stage1.vga_delta_x_negative  <= '0';
            stage1.vga_delta_x_magnitude <= delta_x;
         end if;

         if delta_y < 0 then
            stage1.vga_delta_y_negative  <= '1';
            stage1.vga_delta_y_magnitude <= -delta_y;
         else
            stage1.vga_delta_y_negative  <= '0';
            stage1.vga_delta_y_magnitude <= delta_y;
         end if;
      end if;
   end process p_stage1;

   -----------
   -- Stage 2: Registered 11x21-bit reciprocal products.  Keeping the DSP
   -- multiply alone in this stage is required for the 74.25 MHz HDMI path.
   -----------

   p_stage2 : process (clk_i)
   begin
      if rising_edge(clk_i) then
         stage2 <= stage1;
         stage2.vga_scaled_x_product <=
            stage1.vga_delta_x_magnitude * C_RECIP_Q15(stage1.vga_osm_cfg_scaling);
         stage2.vga_scaled_y_product <=
            stage1.vga_delta_y_magnitude * C_RECIP_Q15(stage1.vga_osm_cfg_scaling);
      end if;
   end process p_stage2;

   -----------
   -- Stage 3: Restore sign/pivot, clamp, and decode character/native phase.
   -----------

   p_stage3 : process (clk_i)
      variable quotient_x   : integer range 0 to 65535;
      variable quotient_y   : integer range 0 to 65535;
      variable col_q4       : integer;
      variable row_q4       : integer;
      variable clamped_x    : integer range 0 to C_Q4_X_MAX;
      variable clamped_y    : integer range 0 to C_Q4_Y_MAX;
      variable local_x_q4   : integer range 0 to 255;
      variable local_y_q4   : integer range 0 to 255;
      variable native_x_q4 : integer range 0 to 127;
      variable native_y_q4 : integer range 0 to 127;
   begin
      if rising_edge(clk_i) then
         stage3 <= stage2;

         quotient_x := stage2.vga_scaled_x_product / 32768;
         quotient_y := stage2.vga_scaled_y_product / 32768;
         if stage2.vga_delta_x_negative = '1' then
            col_q4 := stage2.vga_pivot_x * 16 - quotient_x;
         else
            col_q4 := stage2.vga_pivot_x * 16 + quotient_x;
         end if;
         if stage2.vga_delta_y_negative = '1' then
            row_q4 := stage2.vga_pivot_y * 16 - quotient_y;
         else
            row_q4 := stage2.vga_pivot_y * 16 + quotient_y;
         end if;

         clamped_x := clamp_q4(col_q4, C_Q4_X_MAX);
         clamped_y := clamp_q4(row_q4, C_Q4_Y_MAX);
         stage3.vga_coord_valid <= '0';
         if col_q4 >= 0 and col_q4 <= C_Q4_X_MAX and
            row_q4 >= 0 and row_q4 <= C_Q4_Y_MAX
         then
            stage3.vga_coord_valid <= '1';
         end if;

         stage3.vga_char_x <= clamped_x / 256;
         stage3.vga_char_y <= clamped_y / 256;

         local_x_q4  := clamped_x mod 256;
         local_y_q4  := clamped_y mod 256;
         native_x_q4 := local_x_q4 / 2;
         native_y_q4 := local_y_q4 / 2;

         stage3.vga_native_x <= native_x_q4 / 16;
         stage3.vga_native_y <= native_y_q4 / 16;
         stage3.vga_frac_x   <= native_x_q4 mod 16;
         stage3.vga_frac_y   <= native_y_q4 mod 16;
      end if;
   end process p_stage3;

   -----------
   -- Stage 4: Address character/attribute VRAM and register the exact filter
   -- weights well before they are consumed.
   -----------

   p_stage4 : process (clk_i)
   begin
      if rising_edge(clk_i) then
         stage4 <= stage3;
         stage4.vga_osm_vram_addr <=
            to_stdlogicvector(stage3.vga_char_y * CHARS_DX + stage3.vga_char_x, 16);
         stage4.vga_weight_x <= C_SHARP_WEIGHT(stage3.vga_frac_x);
         if stage3.vga_osm_cfg_r15kHz = '1' then
            stage4.vga_weight_y <=
               C_15KHZ_WEIGHT(stage3.vga_osm_cfg_scaling)(stage3.vga_frac_y);
         else
            stage4.vga_weight_y <= C_SHARP_WEIGHT(stage3.vga_frac_y);
         end if;
      end if;
   end process p_stage4;

   -----------
   -- Stage 5: Read character and attribute from VRAM.
   -----------

   vga_osm_vram_addr_o <= stage4.vga_osm_vram_addr;

   p_stage5 : process (clk_i)
   begin
      if rising_edge(clk_i) then
         stage5 <= stage4;
      end if;
   end process p_stage5;

   -----------
   -- Stage 6: Read one complete native glyph.  Packing the 8 rows into a
   -- 256x64 ROM replaces two independent 2048x8 lookups with one shallow
   -- lookup and preserves exactly the same 16 Kibit of font information.
   -----------

   p_font_addresses : process (all)
   begin
      stage5_vga_osm_font_addr <= vga_osm_vram_data_i;
      stage5_vga_osm_vram_attr <= vga_osm_vram_attr_i;
   end process p_font_addresses;

   inst_font : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH   => C_NATIVE_ADDR_W,
         DATA_WIDTH   => C_NATIVE_GLYPH_W,
         ROM_PRELOAD  => true,
         ROM_FILE     => G_FONT_FILE,
         ROM_FILE_HEX => false,
         RAM_STYLE_SELECT => "distributed"
      )
      port map (
         clock_a         => clk_i,
         address_a       => stage5_vga_osm_font_addr,
         do_latch_addr_a => '0',
         data_a          => (others => '0'),
         wren_a          => '0',
         q_a             => stage6_vga_osm_font_data,
         clock_b         => clk_i,
         address_b       => (others => '0'),
         do_latch_addr_b => '0',
         data_b          => (others => '0'),
         wren_b          => '0',
         q_b             => open
      ); -- inst_font

   p_stage6 : process (clk_i)
   begin
      if rising_edge(clk_i) then
         stage6 <= stage5;
         stage6.vga_osm_vram_attr <= stage5_vga_osm_vram_attr;
      end if;
   end process p_stage6;

   -----------
   -- Stage 7: Register the packed ROM output.  Dynamic row/pixel selection
   -- therefore starts at a register instead of at the ROM address register.
   -----------

   p_stage7 : process (clk_i)
   begin
      if rising_edge(clk_i) then
         stage7 <= stage6;
         stage7_vga_osm_font_data <= stage6_vga_osm_font_data;
      end if;
   end process p_stage7;

   -----------
   -- Stage 8: Select the four native samples and calculate exact coverage.
   -- The 100% case remains an explicit legacy nearest-neighbour bypass.
   -----------

   p_stage8 : process (clk_i)

      variable font_row_a    : font_row_t;
      variable font_row_b    : font_row_t;
      variable lower_y       : integer range 0 to 7;
      variable right_x       : integer range 0 to 7;
      variable pixel_00      : std_logic;
      variable pixel_10      : std_logic;
      variable pixel_01      : std_logic;
      variable pixel_11      : std_logic;
      variable ink_00        : integer range 0 to 1;
      variable ink_10        : integer range 0 to 1;
      variable ink_01        : integer range 0 to 1;
      variable ink_11        : integer range 0 to 1;
      variable row_alpha_0   : weight_t;
      variable row_alpha_1   : weight_t;
      variable alpha_sum     : integer range 0 to 256;

   begin
      if rising_edge(clk_i) then
         stage8 <= stage7;

         if stage7.vga_native_y < C_NATIVE_FONT_DY - 1 then
            lower_y := stage7.vga_native_y + 1;
         else
            lower_y := stage7.vga_native_y;
         end if;
         if stage7.vga_native_x < C_NATIVE_FONT_DX - 1 then
            right_x := stage7.vga_native_x + 1;
         else
            right_x := stage7.vga_native_x;
         end if;

         font_row_a := glyph_row(stage7_vga_osm_font_data, stage7.vga_native_y);
         font_row_b := glyph_row(stage7_vga_osm_font_data, lower_y);
         pixel_00   := font_row_a(7 - stage7.vga_native_x);
         pixel_10   := font_row_a(7 - right_x);
         pixel_01   := font_row_b(7 - stage7.vga_native_x);
         pixel_11   := font_row_b(7 - right_x);

         stage8.vga_alpha      <= 0;
         stage8.vga_legacy_ink <= '0';
         if stage7.vga_osm_cfg_scaling = 0 then
            -- The generator proves that this native bit is identical to all
            -- four bits of the former 2x2 source block.
            if pixel_00 = not stage7.vga_osm_vram_attr(7) then
               stage8.vga_legacy_ink <= '1';
            end if;
         else
            ink_00 := ink_value(pixel_00, stage7.vga_osm_vram_attr(7));
            ink_10 := ink_value(pixel_10, stage7.vga_osm_vram_attr(7));
            ink_01 := ink_value(pixel_01, stage7.vga_osm_vram_attr(7));
            ink_11 := ink_value(pixel_11, stage7.vga_osm_vram_attr(7));

            row_alpha_0 := row_coverage(ink_00, ink_10, stage7.vga_weight_x);
            row_alpha_1 := row_coverage(ink_01, ink_11, stage7.vga_weight_x);
            alpha_sum := row_alpha_0 * (16 - stage7.vga_weight_y) +
                         row_alpha_1 * stage7.vga_weight_y;
            stage8.vga_alpha <= (alpha_sum + 8) / 16;
         end if;

         stage8.vga_osm_on <= '0';
         if stage7.vga_coord_valid = '1' and
            stage7.vga_char_x >= stage7.vga_osm_x1 and stage7.vga_char_x < stage7.vga_osm_x2 and
            stage7.vga_char_y >= stage7.vga_osm_y1 and stage7.vga_char_y < stage7.vga_osm_y2
         then
            stage8.vga_osm_on <= vga_osm_cfg_enable_i;
         end if;
      end if;
   end process p_stage8;

   -----------
   -- Stage 9: Map coverage to RGB.  Foreground/background levels are looked
   -- up once and shared by all three channels instead of repeating the same
   -- coverage network for red, green and blue.
   -----------

   p_stage9 : process (clk_i)

      function attr2rgb(attr: in std_logic_vector(3 downto 0)) return std_logic_vector is
         variable r, g, b    : std_logic_vector(7 downto 0);
         variable brightness : std_logic_vector(7 downto 0);
      begin
         brightness := x"FF" when attr(3) = '0' else x"7F";
         r := brightness when attr(2) = '1' else x"00";
         g := brightness when attr(1) = '1' else x"00";
         b := brightness when attr(0) = '1' else x"00";
         return r & g & b;
      end attr2rgb;

      variable full_level   : std_logic_vector(7 downto 0);
      variable fg_level     : std_logic_vector(7 downto 0);
      variable bg_level     : std_logic_vector(7 downto 0);
      variable red          : std_logic_vector(7 downto 0);
      variable green        : std_logic_vector(7 downto 0);
      variable blue         : std_logic_vector(7 downto 0);

   begin
      if rising_edge(clk_i) then
         stage9 <= stage8;

         if stage8.vga_osm_cfg_scaling = 0 then
            -- Keep the legacy color selection separate from the filtered
            -- path so 100% has no interpolation or coverage dependency.
            if stage8.vga_legacy_ink = '1' then
               stage9.vga_osm_rgb <=
                  attr2rgb(stage8.vga_osm_vram_attr(6) & stage8.vga_osm_vram_attr(2 downto 0));
            else
               stage9.vga_osm_rgb <= attr2rgb(stage8.vga_osm_vram_attr(6 downto 3));
            end if;
         else
            if stage8.vga_osm_vram_attr(6) = '0' then
               full_level := x"FF";
            else
               full_level := x"7F";
            end if;
            fg_level := coverage_level(stage8.vga_osm_vram_attr(6), stage8.vga_alpha);
            bg_level := coverage_level(stage8.vga_osm_vram_attr(6), 16 - stage8.vga_alpha);

            red   := select_channel(stage8.vga_osm_vram_attr(2),
                                    stage8.vga_osm_vram_attr(5),
                                    full_level, fg_level, bg_level);
            green := select_channel(stage8.vga_osm_vram_attr(1),
                                    stage8.vga_osm_vram_attr(4),
                                    full_level, fg_level, bg_level);
            blue  := select_channel(stage8.vga_osm_vram_attr(0),
                                    stage8.vga_osm_vram_attr(3),
                                    full_level, fg_level, bg_level);
            stage9.vga_osm_rgb <= red & green & blue;
         end if;
      end if;
   end process p_stage9;

   vga_osm_rgb_o <= stage9.vga_osm_rgb;
   vga_osm_on_o  <= stage9.vga_osm_on;

end architecture synthesis;
