----------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- MEGA65 main file that contains the whole machine
--
-- The Amiga's memories live here as BRAM, dual-ported between the core
-- (28.375 MHz, port A) and QNICE (50 MHz falling edge, port B):
--   2 x 256K x 8  Chip RAM  (512 KB)   QNICE device 0x0101
--   2 x 256K x 8  Slow RAM  (512 KB)   QNICE device 0x0102
--   2 x 128K x 8  Kickstart (256 KB)   QNICE device 0x0100 (mandatory auto-load)
-- Each memory is split into two 8-bit lanes: lane U = data bits 15:8 = the
-- byte at the even (big-endian first) address, lane L = bits 7:0 = odd byte.
-- A raw Kickstart ROM dump streamed byte-by-byte by the QNICE Shell therefore
-- lands correctly without any byte swapping.
--
-- The core side is the BANKED word address from minimig_sram_bridge.v
-- (see CORE/Minimig_MiSTerMEGA65/rtl/minimig_sram_bridge.v:70-74):
--   chip 512 KB at ram_addr(22:19)="0000"
--   slow 512 KB at ram_addr(22:19)="1000"  (CPU $C00000-$C7FFFF)
--   kick 256 KB at ram_addr(22:19)="1111"  (CPU $F80000-$FFFFFF, bit 18
--                                           ignored = F8/FC mirror)
--
-- Based on the MiSTer2MEGA65 framework template, done by sy2002 and MJoergen
-- in 2022 and licensed under GPL v3.
-- Amiga 500 port (AExp) done in 2026.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;
use work.types_pkg.all;
use work.video_modes_pkg.all;

entity MEGA65_Core is
generic (
   G_BOARD : string                                         -- Which platform are we running on.
);
port (
   --------------------------------------------------------------------------------------------------------
   -- QNICE Clock Domain
   --------------------------------------------------------------------------------------------------------

   -- Get QNICE clock from the framework: for the vdrives as well as for RAMs and ROMs
   qnice_clk_i             : in  std_logic;
   qnice_rst_i             : in  std_logic;

   -- Video and audio mode control
   qnice_dvi_o             : out std_logic;              -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_video_mode_o      : out video_mode_type;        -- Defined in video_modes_pkg.vhd
   qnice_osm_cfg_scaling_o : out std_logic_vector(8 downto 0);
   qnice_scandoubler_o     : out std_logic;              -- 0 = no scandoubler, 1 = scandoubler
   qnice_audio_mute_o      : out std_logic;
   qnice_audio_filter_o    : out std_logic;
   qnice_zoom_crop_o       : out std_logic;
   qnice_ascal_mode_o      : out std_logic_vector(1 downto 0);
   qnice_ascal_polyphase_o : out std_logic;
   qnice_ascal_triplebuf_o : out std_logic;
   qnice_retro15kHz_o      : out std_logic;              -- 0 = normal frequency, 1 = retro 15 kHz frequency
   qnice_csync_o           : out std_logic;              -- 0 = normal HS/VS, 1 = Composite Sync

   -- Flip joystick ports
   qnice_flip_joyports_o   : out std_logic;

   -- On-Screen-Menu selections
   qnice_osm_control_i     : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   qnice_gp_reg_i          : in  std_logic_vector(255 downto 0);

   -- Core-specific devices
   qnice_dev_id_i          : in  std_logic_vector(15 downto 0);
   qnice_dev_addr_i        : in  std_logic_vector(27 downto 0);
   qnice_dev_data_i        : in  std_logic_vector(15 downto 0);
   qnice_dev_data_o        : out std_logic_vector(15 downto 0);
   qnice_dev_ce_i          : in  std_logic;
   qnice_dev_we_i          : in  std_logic;
   qnice_dev_wait_o        : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- HyperRAM Clock Domain
   --------------------------------------------------------------------------------------------------------

   hr_clk_i                : in  std_logic;
   hr_rst_i                : in  std_logic;
   hr_core_write_o         : out std_logic;
   hr_core_read_o          : out std_logic;
   hr_core_address_o       : out std_logic_vector(31 downto 0);
   hr_core_writedata_o     : out std_logic_vector(15 downto 0);
   hr_core_byteenable_o    : out std_logic_vector( 1 downto 0);
   hr_core_burstcount_o    : out std_logic_vector( 7 downto 0);
   hr_core_readdata_i      : in  std_logic_vector(15 downto 0);
   hr_core_readdatavalid_i : in  std_logic;
   hr_core_waitrequest_i   : in  std_logic;
   hr_high_i               : in  std_logic;  -- Core is too fast
   hr_low_i                : in  std_logic;  -- Core is too slow

   --------------------------------------------------------------------------------------------------------
   -- Video Clock Domain
   --------------------------------------------------------------------------------------------------------

   video_clk_o             : out std_logic;
   video_rst_o             : out std_logic;
   video_ce_o              : out std_logic;
   video_ce_ovl_o          : out std_logic;
   video_red_o             : out std_logic_vector(7 downto 0);
   video_green_o           : out std_logic_vector(7 downto 0);
   video_blue_o            : out std_logic_vector(7 downto 0);
   video_vs_o              : out std_logic;
   video_hs_o              : out std_logic;
   video_hblank_o          : out std_logic;
   video_vblank_o          : out std_logic;
   video_fl_o              : out std_logic;  -- interlace field flag for ascal weave deinterlacing

   --------------------------------------------------------------------------------------------------------
   -- Core Clock Domain
   --------------------------------------------------------------------------------------------------------

   clk_i                   : in  std_logic;              -- 100 MHz clock

   -- Share clock and reset with the framework
   main_clk_o              : out std_logic;              -- CORE's 28.375 MHz clock
   main_rst_o              : out std_logic;              -- CORE's reset, synchronized

   -- M2M's reset manager provides 2 signals:
   --    m2m:   Reset the whole machine: Core and Framework
   --    core:  Only reset the core
   main_reset_m2m_i        : in  std_logic;
   main_reset_core_i       : in  std_logic;

   main_pause_core_i       : in  std_logic;

   -- On-Screen-Menu selections
   main_osm_control_i      : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register converted to main clock domain
   main_qnice_gp_reg_i     : in  std_logic_vector(255 downto 0);

   -- Audio output (Signed PCM)
   main_audio_left_o       : out signed(15 downto 0);
   main_audio_right_o      : out signed(15 downto 0);

   -- M2M Keyboard interface (incl. power led and drive led)
   main_kb_key_num_i       : in  integer range 0 to 79;  -- cycles through all MEGA65 keys
   main_kb_key_pressed_n_i : in  std_logic;              -- low active: debounced feedback: is kb_key_num_i pressed right now?
   main_power_led_o        : out std_logic;
   main_power_led_col_o    : out std_logic_vector(23 downto 0);
   main_drive_led_o        : out std_logic;
   main_drive_led_col_o    : out std_logic_vector(23 downto 0);

   -- Joysticks and paddles input
   main_joy_1_up_n_i       : in  std_logic;
   main_joy_1_down_n_i     : in  std_logic;
   main_joy_1_left_n_i     : in  std_logic;
   main_joy_1_right_n_i    : in  std_logic;
   main_joy_1_fire_n_i     : in  std_logic;
   main_joy_1_up_n_o       : out std_logic;
   main_joy_1_down_n_o     : out std_logic;
   main_joy_1_left_n_o     : out std_logic;
   main_joy_1_right_n_o    : out std_logic;
   main_joy_1_fire_n_o     : out std_logic;
   main_joy_2_up_n_i       : in  std_logic;
   main_joy_2_down_n_i     : in  std_logic;
   main_joy_2_left_n_i     : in  std_logic;
   main_joy_2_right_n_i    : in  std_logic;
   main_joy_2_fire_n_i     : in  std_logic;
   main_joy_2_up_n_o       : out std_logic;
   main_joy_2_down_n_o     : out std_logic;
   main_joy_2_left_n_o     : out std_logic;
   main_joy_2_right_n_o    : out std_logic;
   main_joy_2_fire_n_o     : out std_logic;

   main_pot1_x_i           : in  std_logic_vector(7 downto 0);
   main_pot1_y_i           : in  std_logic_vector(7 downto 0);
   main_pot2_x_i           : in  std_logic_vector(7 downto 0);
   main_pot2_y_i           : in  std_logic_vector(7 downto 0);
   main_rtc_i              : in  std_logic_vector(64 downto 0);

   -- CBM-488/IEC serial port
   iec_reset_n_o           : out std_logic;
   iec_atn_n_o             : out std_logic;
   iec_clk_en_o            : out std_logic;
   iec_clk_n_i             : in  std_logic;
   iec_clk_n_o             : out std_logic;
   iec_data_en_o           : out std_logic;
   iec_data_n_i            : in  std_logic;
   iec_data_n_o            : out std_logic;
   iec_srq_en_o            : out std_logic;
   iec_srq_n_i             : in  std_logic;
   iec_srq_n_o             : out std_logic;

   -- C64 Expansion Port (aka Cartridge Port)
   cart_en_o               : out std_logic;  -- Enable port, active high
   cart_phi2_o             : out std_logic;
   cart_dotclock_o         : out std_logic;
   cart_dma_i              : in  std_logic;
   cart_reset_oe_o         : out std_logic;
   cart_reset_i            : in  std_logic;
   cart_reset_o            : out std_logic;
   cart_game_oe_o          : out std_logic;
   cart_game_i             : in  std_logic;
   cart_game_o             : out std_logic;
   cart_exrom_oe_o         : out std_logic;
   cart_exrom_i            : in  std_logic;
   cart_exrom_o            : out std_logic;
   cart_nmi_oe_o           : out std_logic;
   cart_nmi_i              : in  std_logic;
   cart_nmi_o              : out std_logic;
   cart_irq_oe_o           : out std_logic;
   cart_irq_i              : in  std_logic;
   cart_irq_o              : out std_logic;
   cart_roml_oe_o          : out std_logic;
   cart_roml_i             : in  std_logic;
   cart_roml_o             : out std_logic;
   cart_romh_oe_o          : out std_logic;
   cart_romh_i             : in  std_logic;
   cart_romh_o             : out std_logic;
   cart_ctrl_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_ba_i               : in  std_logic;
   cart_rw_i               : in  std_logic;
   cart_io1_i              : in  std_logic;
   cart_io2_i              : in  std_logic;
   cart_ba_o               : out std_logic;
   cart_rw_o               : out std_logic;
   cart_io1_o              : out std_logic;
   cart_io2_o              : out std_logic;
   cart_addr_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_a_i                : in  unsigned(15 downto 0);
   cart_a_o                : out unsigned(15 downto 0);
   cart_data_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_d_i                : in  unsigned( 7 downto 0);
   cart_d_o                : out unsigned( 7 downto 0)
);
end entity MEGA65_Core;

architecture synthesis of MEGA65_Core is

---------------------------------------------------------------------------------------------
-- Clocks and active high reset signals for each clock domain
---------------------------------------------------------------------------------------------

signal main_clk               : std_logic;               -- Core main clock
signal main_rst               : std_logic;

---------------------------------------------------------------------------------------------
-- main_clk (MiSTer core's clock)
---------------------------------------------------------------------------------------------

-- Amiga memory bus (SRAM-style, served by the BRAMs below)
signal main_ram_addr          : std_logic_vector(22 downto 1);  -- banked word address
signal main_ram_wrdata        : std_logic_vector(15 downto 0);
signal main_ram_rddata        : std_logic_vector(15 downto 0);
signal main_ram_bhe_n         : std_logic;
signal main_ram_ble_n         : std_logic;
signal main_ram_we_n          : std_logic;
signal main_ram_oe_n          : std_logic;

-- bank selects (combinational decode of the banked address)
signal main_chip_sel          : std_logic;
signal main_slow_sel          : std_logic;
signal main_kick_sel          : std_logic;

-- registered read-mux select: matches the 1-cycle BRAM read latency
signal main_rd_sel            : std_logic_vector(1 downto 0);   -- 00=chip, 01=slow, 10=kick

-- per-lane read data
signal main_chip_q_u          : std_logic_vector(7 downto 0);
signal main_chip_q_l          : std_logic_vector(7 downto 0);
signal main_slow_q_u          : std_logic_vector(7 downto 0);
signal main_slow_q_l          : std_logic_vector(7 downto 0);
signal main_kick_q_u          : std_logic_vector(7 downto 0);
signal main_kick_q_l          : std_logic_vector(7 downto 0);

-- LEDs of the emulated Amiga
signal main_pwr_led           : std_logic;
signal main_fdd_led           : std_logic;

-- ADF floppy: track engine's HyperRAM read port (main_clk side, post avm_cache
-- in main.vhd) and the mount status CDC'd from the QNICE domain
signal main_adf_avm_write         : std_logic;
signal main_adf_avm_read          : std_logic;
signal main_adf_avm_address       : std_logic_vector(31 downto 0);
signal main_adf_avm_writedata     : std_logic_vector(15 downto 0);
signal main_adf_avm_byteenable    : std_logic_vector( 1 downto 0);
signal main_adf_avm_burstcount    : std_logic_vector( 7 downto 0);
signal main_adf_avm_readdata      : std_logic_vector(15 downto 0);
signal main_adf_avm_readdatavalid : std_logic;
signal main_adf_avm_waitrequest   : std_logic;
signal main_adf_mounted           : std_logic;
signal main_adf_tracks            : std_logic_vector(7 downto 0);

---------------------------------------------------------------------------------------------
-- qnice_clk
---------------------------------------------------------------------------------------------

-- write enables and read data of the QNICE side of the Kickstart ROM.
-- NOTE: Chip and Slow RAM deliberately have NO QNICE port: their 256 BRAM
-- tiles are spread over the whole die and the QNICE address bus could not
-- meet the falling-edge half-period (10 ns) to the farthest tiles (first R3
-- run: WNS -0.757 ns on exactly these paths). The kick ROM port (64 tiles)
-- is required for the mandatory ROM auto-load and meets timing.
signal qnice_kick_we_u        : std_logic;
signal qnice_kick_we_l        : std_logic;
signal qnice_kick_q_u         : std_logic_vector(7 downto 0);
signal qnice_kick_q_l         : std_logic_vector(7 downto 0);

-- ADF mount buffer device 0x0103 (adf_mount_wrapper)
signal qnice_adf_ce           : std_logic;
signal qnice_adf_data         : std_logic_vector(15 downto 0);
signal qnice_adf_wait         : std_logic;
signal qnice_adf_mounted      : std_logic;
signal qnice_adf_tracks       : std_logic_vector(7 downto 0);

---------------------------------------------------------------------------------------------
-- hr_clk (HyperRAM clock domain)
---------------------------------------------------------------------------------------------

-- ADF track engine read chain after the main->hr CDC (avm_fifo below)
signal hr_flp_avm_write           : std_logic;
signal hr_flp_avm_read            : std_logic;
signal hr_flp_avm_address         : std_logic_vector(31 downto 0);
signal hr_flp_avm_writedata       : std_logic_vector(15 downto 0);
signal hr_flp_avm_byteenable      : std_logic_vector( 1 downto 0);
signal hr_flp_avm_burstcount      : std_logic_vector( 7 downto 0);
signal hr_flp_avm_readdata        : std_logic_vector(15 downto 0);
signal hr_flp_avm_readdatavalid   : std_logic;
signal hr_flp_avm_waitrequest     : std_logic;

-- ADF mount wrapper's Avalon master (the QNICE->hr CDC lives inside the wrapper)
signal hr_adf_avm_write           : std_logic;
signal hr_adf_avm_read            : std_logic;
signal hr_adf_avm_address         : std_logic_vector(31 downto 0);
signal hr_adf_avm_writedata       : std_logic_vector(15 downto 0);
signal hr_adf_avm_byteenable      : std_logic_vector( 1 downto 0);
signal hr_adf_avm_burstcount      : std_logic_vector( 7 downto 0);
signal hr_adf_avm_readdata        : std_logic_vector(15 downto 0);
signal hr_adf_avm_readdatavalid   : std_logic;
signal hr_adf_avm_waitrequest     : std_logic;

---------------------------------------------------------------------------------------------
-- On-Screen-Menu bit positions: zero-based line numbers in config.vhd's OPTM_ITEMS
---------------------------------------------------------------------------------------------

-- (the " ADF:%s" mount item at line 2 is handled by the Shell itself and needs
-- no C_MENU constant; it shifted everything below it by 2 lines)
-- ALL C_MENU_* constants below are additionally scraped by
-- CORE/m2m-rom/make_rom.sh into the autogenerated osm_const.asm (as
-- AEXP_OSM_*), so the firmware never hardcodes menu line numbers.
-- Keep them single-line for the awk scraper.
constant C_MENU_HDMI_16_9_50  : natural :=  7;
constant C_MENU_HDMI_16_9_60  : natural :=  8;
constant C_MENU_HDMI_4_3_50   : natural :=  9;
constant C_MENU_HDMI_5_4_50   : natural := 10;
constant C_MENU_HDMI_640_60   : natural := 11;
constant C_MENU_HDMI_720_5994 : natural := 12;
constant C_MENU_SVGA_800_60   : natural := 13;

-- The HDMI Filter radio is read by the firmware only (dispatcher
-- LOAD_HDMI_FILTER with ASCAL_USAGE=1), never by any VHDL: these eight
-- lines exist solely as the scrape source for osm_const.asm.
constant C_MENU_FLT_NO_FILTER     : natural := 19;
constant C_MENU_FLT_SHARP         : natural := 20;
constant C_MENU_FLT_BICUBIC       : natural := 21;
constant C_MENU_FLT_SMOOTH        : natural := 22;
constant C_MENU_FLT_LANCZOS       : natural := 23;
constant C_MENU_FLT_SCANLINES     : natural := 24;
constant C_MENU_FLT_CRT_SVIDEO    : natural := 25;
constant C_MENU_FLT_CRT_COMPOSITE : natural := 26;

constant C_MENU_VGA_STD       : natural := 32;   -- VGA: Standard (scandoubled 31.25 kHz); default
constant C_MENU_VGA_15KHZHSVS : natural := 36;   -- VGA: raw 15.625 kHz RGB with separate HS/VS
constant C_MENU_VGA_15KHZCS   : natural := 37;   -- VGA: raw 15.625 kHz RGB with composite sync (SCART)

begin

   -- hr_core_* is driven by the 2-master HyperRAM arbiter at the bottom of this
   -- file (ADF track engine read chain + ADF mount wrapper write/read chain)

   -- Tristate all expansion port drivers that we can directly control
   cart_ctrl_oe_o       <= '0';
   cart_addr_oe_o       <= '0';
   cart_data_oe_o       <= '0';

   -- Due to a bug in the R5/R6 boards, the cartridge port needs to be enabled for joystick port 2 to work
   cart_en_o            <= '1';

   cart_reset_oe_o      <= '0';
   cart_game_oe_o       <= '0';
   cart_exrom_oe_o      <= '0';
   cart_nmi_oe_o        <= '0';
   cart_irq_oe_o        <= '0';
   cart_roml_oe_o       <= '0';
   cart_romh_oe_o       <= '0';

   -- Default values for all signals
   cart_phi2_o          <= '0';
   cart_reset_o         <= '1';
   cart_dotclock_o      <= '0';
   cart_game_o          <= '1';
   cart_exrom_o         <= '1';
   cart_nmi_o           <= '1';
   cart_irq_o           <= '1';
   cart_roml_o          <= '0';
   cart_romh_o          <= '0';
   cart_ba_o            <= '0';
   cart_rw_o            <= '0';
   cart_io1_o           <= '0';
   cart_io2_o           <= '0';
   cart_a_o             <= (others => '0');
   cart_d_o             <= (others => '0');

   -- IEC port: unused by the Amiga core
   iec_reset_n_o        <= '1';
   iec_atn_n_o          <= '1';
   iec_clk_en_o         <= '0';
   iec_clk_n_o          <= '1';
   iec_data_en_o        <= '0';
   iec_data_n_o         <= '1';
   iec_srq_en_o         <= '0';
   iec_srq_n_o          <= '1';

   main_joy_1_up_n_o    <= '1';
   main_joy_1_down_n_o  <= '1';
   main_joy_1_left_n_o  <= '1';
   main_joy_1_right_n_o <= '1';
   main_joy_1_fire_n_o  <= '1';
   main_joy_2_up_n_o    <= '1';
   main_joy_2_down_n_o  <= '1';
   main_joy_2_left_n_o  <= '1';
   main_joy_2_right_n_o <= '1';
   main_joy_2_fire_n_o  <= '1';


   -- MMCME2_ADV clock generator: 28.375 MHz Amiga PAL master clock
   clk_gen : entity work.clk
      port map (
         sys_clk_i         => clk_i,           -- expects 100 MHz
         main_clk_o        => main_clk,        -- CORE's 28.375 MHz clock
         main_rst_o        => main_rst         -- CORE's reset, synchronized
      ); -- clk_gen

   main_clk_o  <= main_clk;
   main_rst_o  <= main_rst;
   video_clk_o <= main_clk;
   video_rst_o <= main_rst;

   ---------------------------------------------------------------------------------------------
   -- main_clk (MiSTer core's clock)
   ---------------------------------------------------------------------------------------------

   -- MEGA65's power led: By default, it is on and glows green when the MEGA65 is powered on.
   -- We switch it to blue when a long reset is detected and as long as the user keeps pressing the preset button
   main_power_led_o     <= '1';
   main_power_led_col_o <= x"0000FF" when main_reset_m2m_i else x"00FF00";

   -- Amiga floppy LED on the MEGA65 drive LED (Paula disk-DMA activity)
   main_drive_led_o     <= main_fdd_led;
   main_drive_led_col_o <= x"00FF00";

   -- main.vhd contains the actual MiSTer core
   i_main : entity work.main
      generic map (
         G_VDNUM              => C_VDNUM,
         G_ADF_BASE_ADDRESS   => C_HMAP_ADF_DF0(9 downto 0) & x"000"
      )
      port map (
         clk_main_i           => main_clk,
         reset_soft_i         => main_reset_core_i,
         reset_hard_i         => main_reset_m2m_i,
         pause_i              => main_pause_core_i,

         clk_main_speed_i     => CORE_CLK_SPEED,

         -- VGA output mode from the OSM: in the two retro 15 kHz modes the
         -- framework's scandoubler is bypassed and main.vhd halves the OSM
         -- overlay sampling rate accordingly
         video_retro15khz_i   => main_osm_control_i(C_MENU_VGA_15KHZHSVS) or
                                 main_osm_control_i(C_MENU_VGA_15KHZCS),

         -- Video output: PAL 15.625 kHz raw Amiga signal on the 28.375 MHz clock;
         -- the framework's scandoubler (on in the Standard VGA mode) doubles it
         -- for VGA and ascal scales it for HDMI. video_fl_o carries the interlace
         -- field (toggles while LACE is set), which lets ascal weave-deinterlace
         -- laced modes like 640x512 on the HDMI output; the VGA scandoubler stays
         -- field-blind (bob), while the 15 kHz modes show interlace CRT-native.
         video_ce_o           => video_ce_o,
         video_ce_ovl_o       => video_ce_ovl_o,
         video_red_o          => video_red_o,
         video_green_o        => video_green_o,
         video_blue_o         => video_blue_o,
         video_vs_o           => video_vs_o,
         video_hs_o           => video_hs_o,
         video_hblank_o       => video_hblank_o,
         video_vblank_o       => video_vblank_o,
         video_fl_o           => video_fl_o,

         -- audio output (pcm format, signed values)
         audio_left_o         => main_audio_left_o,
         audio_right_o        => main_audio_right_o,

         -- Amiga memory bus, served by the BRAMs below
         ram_addr_o           => main_ram_addr,
         ram_data_o           => main_ram_wrdata,
         ram_data_i           => main_ram_rddata,
         ram_bhe_n_o          => main_ram_bhe_n,
         ram_ble_n_o          => main_ram_ble_n,
         ram_we_n_o           => main_ram_we_n,
         ram_oe_n_o           => main_ram_oe_n,

         -- LEDs of the emulated Amiga
         pwr_led_o            => main_pwr_led,
         fdd_led_o            => main_fdd_led,

         -- ADF floppy: mount status and HyperRAM read port
         adf_mounted_i        => main_adf_mounted,
         adf_tracks_i         => main_adf_tracks,
         adf_avm_write_o      => main_adf_avm_write,
         adf_avm_read_o       => main_adf_avm_read,
         adf_avm_address_o    => main_adf_avm_address,
         adf_avm_writedata_o  => main_adf_avm_writedata,
         adf_avm_byteenable_o => main_adf_avm_byteenable,
         adf_avm_burstcount_o => main_adf_avm_burstcount,
         adf_avm_readdata_i   => main_adf_avm_readdata,
         adf_avm_readdatavalid_i => main_adf_avm_readdatavalid,
         adf_avm_waitrequest_i   => main_adf_avm_waitrequest,

         -- M2M Keyboard interface
         kb_key_num_i         => main_kb_key_num_i,
         kb_key_pressed_n_i   => main_kb_key_pressed_n_i,

         -- MEGA65 joysticks and paddles/mouse/potentiometers
         joy_1_up_n_i         => main_joy_1_up_n_i ,
         joy_1_down_n_i       => main_joy_1_down_n_i,
         joy_1_left_n_i       => main_joy_1_left_n_i,
         joy_1_right_n_i      => main_joy_1_right_n_i,
         joy_1_fire_n_i       => main_joy_1_fire_n_i,

         joy_2_up_n_i         => main_joy_2_up_n_i,
         joy_2_down_n_i       => main_joy_2_down_n_i,
         joy_2_left_n_i       => main_joy_2_left_n_i,
         joy_2_right_n_i      => main_joy_2_right_n_i,
         joy_2_fire_n_i       => main_joy_2_fire_n_i,

         pot1_x_i             => main_pot1_x_i,
         pot1_y_i             => main_pot1_y_i,
         pot2_x_i             => main_pot2_x_i,
         pot2_y_i             => main_pot2_y_i
      ); -- i_main

   ---------------------------------------------------------------------------------------------
   -- Amiga memory decode (main_clk domain)
   ---------------------------------------------------------------------------------------------

   -- bank decode of the banked word address (see header comment)
   main_chip_sel <= '1' when main_ram_addr(22 downto 19) = "0000" else '0';
   main_slow_sel <= '1' when main_ram_addr(22 downto 19) = "1000" else '0';
   main_kick_sel <= '1' when main_ram_addr(22 downto 19) = "1111" else '0';

   -- The read mux select must match the 1-cycle BRAM read latency: register it.
   -- Within one 7.09 MHz bus cycle the address is stable for 4 clk28 ticks and
   -- the consumers sample the data in the second half of the cycle, so the
   -- one-tick-late select is glitch-free where it matters.
   read_mux_sel_proc : process (main_clk)
   begin
      if rising_edge(main_clk) then
         if main_kick_sel = '1' then
            main_rd_sel <= "10";
         elsif main_slow_sel = '1' then
            main_rd_sel <= "01";
         else
            main_rd_sel <= "00";
         end if;
      end if;
   end process read_mux_sel_proc;

   main_ram_rddata <= main_kick_q_u & main_kick_q_l when main_rd_sel = "10" else
                      main_slow_q_u & main_slow_q_l when main_rd_sel = "01" else
                      main_chip_q_u & main_chip_q_l;

   ---------------------------------------------------------------------------------------------
   -- Audio and video settings (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   qnice_video_mode_o <= C_VIDEO_SVGA_800_60   when qnice_osm_control_i(C_MENU_SVGA_800_60)    = '1' else
                         C_VIDEO_HDMI_720_5994 when qnice_osm_control_i(C_MENU_HDMI_720_5994)  = '1' else
                         C_VIDEO_HDMI_640_60   when qnice_osm_control_i(C_MENU_HDMI_640_60)    = '1' else
                         C_VIDEO_HDMI_5_4_50   when qnice_osm_control_i(C_MENU_HDMI_5_4_50)    = '1' else
                         C_VIDEO_HDMI_4_3_50   when qnice_osm_control_i(C_MENU_HDMI_4_3_50)    = '1' else
                         C_VIDEO_HDMI_16_9_60  when qnice_osm_control_i(C_MENU_HDMI_16_9_60)   = '1' else
                         C_VIDEO_HDMI_16_9_50;

   -- Use On-Screen-Menu selections to configure several audio and video settings
   -- Video and audio mode control
   qnice_dvi_o                <= '0';                                         -- 0=HDMI (with sound), 1=DVI (no sound)

   -- VGA (analog) output mode, three-way radio in the OSM (decode as in
   -- C64MEGA65). The Amiga outputs a 15.625 kHz signal:
   --   Standard          = scandoubler on -> 31.25 kHz RGBHV, VGA monitors lock
   --                       (see .research/INTEGRATION-SPEC-video-audio.md section 4)
   --   15 kHz with HS/VS = raw 15.625 kHz RGB, separate syncs (retro CRTs)
   --   15 kHz with CSYNC = raw 15.625 kHz RGB, composite sync (SCART/RGB CRTs)
   -- In the 15 kHz modes a CRT displays interlace natively (the half-line
   -- vsync offset passes through) - the most authentic Amiga picture.
   qnice_scandoubler_o        <= (not qnice_osm_control_i(C_MENU_VGA_15KHZHSVS)) and
                                 (not qnice_osm_control_i(C_MENU_VGA_15KHZCS));
   qnice_retro15kHz_o         <= qnice_osm_control_i(C_MENU_VGA_15KHZHSVS) or
                                 qnice_osm_control_i(C_MENU_VGA_15KHZCS);
   qnice_csync_o              <= qnice_osm_control_i(C_MENU_VGA_15KHZCS);

   qnice_audio_mute_o         <= '0';                                         -- audio is not muted
   qnice_audio_filter_o       <= '0';                                         -- raw Paula output; "Audio improvements"
                                                                              -- menu item removed for now
   qnice_zoom_crop_o          <= '0';                                         -- no zoom/crop menu item in milestone 1
   qnice_osm_cfg_scaling_o    <= (others => '1');

   -- ascal mode: with ASCAL_USAGE=1 (AUSE_CUSTOM) in config.vhd these inputs to
   -- the QNICE co-processor are ignored (the CSR ascal-autosync bit is cleared);
   -- the HDMI Filter dispatcher in CORE/m2m-rom/m2m-rom.asm owns the ascal mode
   -- and the polyphase coefficient RAM. Keep them tied off, like C64MEGA65 V6.
   qnice_ascal_mode_o         <= "00";
   qnice_ascal_polyphase_o    <= '0';

   -- ascal triple-buffering
   -- @TODO: Right now, the M2M framework only supports OFF, so do not touch until the framework is upgraded
   qnice_ascal_triplebuf_o    <= '0';

   -- Flip joystick ports (i.e. the joystick in port 2 is used as joystick 1 and vice versa)
   qnice_flip_joyports_o      <= '0';

   ---------------------------------------------------------------------------------------------
   -- Core specific device handling (QNICE clock domain)
   --
   -- Device map (QNICE dev_addr is a BYTE address into the Amiga memories;
   -- even byte = data bits 15:8 (lane U), odd byte = bits 7:0 (lane L)):
   --   0x0100  C_DEV_AMIGA_KICK  256 KB  Kickstart ROM (mandatory auto-load target)
   --   0x0103  C_DEV_AMIGA_ADF   ADF mount buffer in HyperRAM + CSR window 0xFFFF
   --           (adf_mount_wrapper packs its own byte order - byte address bit 0
   --           selects the HyperRAM word's LOW byte lane for EVEN addresses)
   -- Chip and Slow RAM have no QNICE access for timing reasons (see the
   -- signal declarations above); their device IDs stay reserved in globals.vhd.
   ---------------------------------------------------------------------------------------------

   core_specific_devices : process(all)
   begin
      -- make sure that this is x"EEEE" by default and avoid a register here by having this default value
      qnice_dev_data_o <= x"EEEE";
      qnice_dev_wait_o <= '0';

      qnice_kick_we_u  <= '0';
      qnice_kick_we_l  <= '0';
      qnice_adf_ce     <= '0';

      case qnice_dev_id_i is

         when C_DEV_AMIGA_KICK =>
            qnice_kick_we_u <= qnice_dev_ce_i and qnice_dev_we_i and not qnice_dev_addr_i(0);
            qnice_kick_we_l <= qnice_dev_ce_i and qnice_dev_we_i and     qnice_dev_addr_i(0);
            if qnice_dev_addr_i(0) = '0' then
               qnice_dev_data_o <= x"00" & qnice_kick_q_u;
            else
               qnice_dev_data_o <= x"00" & qnice_kick_q_l;
            end if;

         when C_DEV_AMIGA_ADF =>
            qnice_adf_ce     <= qnice_dev_ce_i;
            qnice_dev_data_o <= qnice_adf_data;
            qnice_dev_wait_o <= qnice_adf_wait;

         when others => null;
      end case;
   end process core_specific_devices;

   ---------------------------------------------------------------------------------------------
   -- Dual Clocks: the Amiga's memories
   --
   -- Port A: Amiga core, rising edge of the 28.375 MHz clock. Synchronous BRAM
   --         with 1 clk28 read latency easily meets the chipset bus timing
   --         (address stable from the start of each 7.09 MHz cycle, data
   --         consumed in its second half).
   -- Port B: QNICE, falling edge of the 50 MHz QNICE clock (M2M convention).
   ---------------------------------------------------------------------------------------------

   -- Chip and Slow RAM: single-ported from the QNICE perspective (port B
   -- completely tied off, so no QNICE-domain routing reaches these 256 BRAM
   -- tiles - see the timing note at the qnice signal declarations).
   chip_ram_u : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 18,
         DATA_WIDTH => 8
      )
      port map (
         clock_a   => main_clk,
         address_a => main_ram_addr(18 downto 1),
         data_a    => main_ram_wrdata(15 downto 8),
         wren_a    => main_chip_sel and not main_ram_we_n and not main_ram_bhe_n,
         q_a       => main_chip_q_u,

         clock_b   => '0',
         address_b => (others => '0'),
         data_b    => (others => '0'),
         wren_b    => '0',
         q_b       => open
      ); -- chip_ram_u

   chip_ram_l : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 18,
         DATA_WIDTH => 8
      )
      port map (
         clock_a   => main_clk,
         address_a => main_ram_addr(18 downto 1),
         data_a    => main_ram_wrdata(7 downto 0),
         wren_a    => main_chip_sel and not main_ram_we_n and not main_ram_ble_n,
         q_a       => main_chip_q_l,

         clock_b   => '0',
         address_b => (others => '0'),
         data_b    => (others => '0'),
         wren_b    => '0',
         q_b       => open
      ); -- chip_ram_l

   slow_ram_u : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 18,
         DATA_WIDTH => 8
      )
      port map (
         clock_a   => main_clk,
         address_a => main_ram_addr(18 downto 1),
         data_a    => main_ram_wrdata(15 downto 8),
         wren_a    => main_slow_sel and not main_ram_we_n and not main_ram_bhe_n,
         q_a       => main_slow_q_u,

         clock_b   => '0',
         address_b => (others => '0'),
         data_b    => (others => '0'),
         wren_b    => '0',
         q_b       => open
      ); -- slow_ram_u

   slow_ram_l : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 18,
         DATA_WIDTH => 8
      )
      port map (
         clock_a   => main_clk,
         address_a => main_ram_addr(18 downto 1),
         data_a    => main_ram_wrdata(7 downto 0),
         wren_a    => main_slow_sel and not main_ram_we_n and not main_ram_ble_n,
         q_a       => main_slow_q_l,

         clock_b   => '0',
         address_b => (others => '0'),
         data_b    => (others => '0'),
         wren_b    => '0',
         q_b       => open
      ); -- slow_ram_l

   -- Kickstart: read-only from the Amiga side (wren_a fixed '0'); written only
   -- by the QNICE Shell during the mandatory auto-load. The core-side address
   -- ignores bit 18, mirroring the 256 KB ROM at $F80000 and $FC0000.
   kick_rom_u : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 17,
         DATA_WIDTH => 8,
         FALLING_B  => true
      )
      port map (
         clock_a   => main_clk,
         address_a => main_ram_addr(17 downto 1),
         data_a    => (others => '0'),
         wren_a    => '0',
         q_a       => main_kick_q_u,

         clock_b   => qnice_clk_i,
         address_b => qnice_dev_addr_i(17 downto 1),
         data_b    => qnice_dev_data_i(7 downto 0),
         wren_b    => qnice_kick_we_u,
         q_b       => qnice_kick_q_u
      ); -- kick_rom_u

   kick_rom_l : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 17,
         DATA_WIDTH => 8,
         FALLING_B  => true
      )
      port map (
         clock_a   => main_clk,
         address_a => main_ram_addr(17 downto 1),
         data_a    => (others => '0'),
         wren_a    => '0',
         q_a       => main_kick_q_l,

         clock_b   => qnice_clk_i,
         address_b => qnice_dev_addr_i(17 downto 1),
         data_b    => qnice_dev_data_i(7 downto 0),
         wren_b    => qnice_kick_we_l,
         q_b       => qnice_kick_q_l
      ); -- kick_rom_l

   ---------------------------------------------------------------------------------------------
   -- ADF floppy: HyperRAM plumbing
   --
   -- Two Avalon masters share the framework's hr_core_* port (100 MHz hr_clk):
   --   * the mount wrapper (QNICE device 0x0103): Shell streams the ADF into
   --     HyperRAM at load time; contains its own QNICE->hr avm_fifo CDC
   --   * the track engine's read chain from main.vhd (post avm_cache), crossed
   --     main->hr by the avm_fifo below
   -- Pattern and generics follow C64MEGA65 (REU + mount buffer chains).
   ---------------------------------------------------------------------------------------------

   i_adf_mount_wrapper : entity work.adf_mount_wrapper
      generic map (
         G_BASE_ADDRESS => C_HMAP_ADF_DF0(9 downto 0) & x"000"
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_ce_i           => qnice_adf_ce,
         qnice_we_i           => qnice_dev_we_i,
         qnice_data_o         => qnice_adf_data,
         qnice_wait_o         => qnice_adf_wait,

         qnice_disk_mounted_o => qnice_adf_mounted,
         qnice_disk_tracks_o  => qnice_adf_tracks,

         hr_clk_i             => hr_clk_i,
         hr_rst_i             => hr_rst_i,
         hr_write_o           => hr_adf_avm_write,
         hr_read_o            => hr_adf_avm_read,
         hr_address_o         => hr_adf_avm_address,
         hr_writedata_o       => hr_adf_avm_writedata,
         hr_byteenable_o      => hr_adf_avm_byteenable,
         hr_burstcount_o      => hr_adf_avm_burstcount,
         hr_readdata_i        => hr_adf_avm_readdata,
         hr_readdatavalid_i   => hr_adf_avm_readdatavalid,
         hr_waitrequest_i     => hr_adf_avm_waitrequest
      ); -- i_adf_mount_wrapper

   -- mount status into the core clock domain (slowly varying flag + track count;
   -- covered by M2M/common.xdc's cdc_stable set_max_delay constraint)
   i_cdc_adf_mount : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 9,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i               => qnice_clk_i,
         src_data_i(7 downto 0)  => qnice_adf_tracks,
         src_data_i(8)           => qnice_adf_mounted,
         dst_clk_i               => main_clk,
         dst_data_o(7 downto 0)  => main_adf_tracks,
         dst_data_o(8)           => main_adf_mounted
      ); -- i_cdc_adf_mount

   -- track engine read chain: main_clk -> hr_clk (domain resets - never the
   -- core reset: the command FIFO resets from the s side, the response FIFO
   -- from the m side, and resetting only one side desynchronizes the chain)
   i_avm_fifo_adf : entity work.avm_fifo
      generic map (
         G_WR_DEPTH     => 16,
         G_RD_DEPTH     => 16,
         G_FILL_SIZE    => 1,
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         s_clk_i               => main_clk,
         s_rst_i               => main_reset_m2m_i,
         s_avm_waitrequest_o   => main_adf_avm_waitrequest,
         s_avm_write_i         => main_adf_avm_write,
         s_avm_read_i          => main_adf_avm_read,
         s_avm_address_i       => main_adf_avm_address,
         s_avm_writedata_i     => main_adf_avm_writedata,
         s_avm_byteenable_i    => main_adf_avm_byteenable,
         s_avm_burstcount_i    => main_adf_avm_burstcount,
         s_avm_readdata_o      => main_adf_avm_readdata,
         s_avm_readdatavalid_o => main_adf_avm_readdatavalid,
         m_clk_i               => hr_clk_i,
         m_rst_i               => hr_rst_i,
         m_avm_waitrequest_i   => hr_flp_avm_waitrequest,
         m_avm_write_o         => hr_flp_avm_write,
         m_avm_read_o          => hr_flp_avm_read,
         m_avm_address_o       => hr_flp_avm_address,
         m_avm_writedata_o     => hr_flp_avm_writedata,
         m_avm_byteenable_o    => hr_flp_avm_byteenable,
         m_avm_burstcount_o    => hr_flp_avm_burstcount,
         m_avm_readdata_i      => hr_flp_avm_readdata,
         m_avm_readdatavalid_i => hr_flp_avm_readdatavalid
      ); -- i_avm_fifo_adf

   -- round-robin per whole transaction; the two masters never compete in
   -- practice (mount writes while the engine is idle and vice versa)
   i_avm_arbit_adf : entity work.avm_arbit
      generic map (
         G_PREFER_SWAP  => false,
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         clk_i                  => hr_clk_i,
         rst_i                  => hr_rst_i,

         s0_avm_write_i         => hr_flp_avm_write,
         s0_avm_read_i          => hr_flp_avm_read,
         s0_avm_address_i       => hr_flp_avm_address,
         s0_avm_writedata_i     => hr_flp_avm_writedata,
         s0_avm_byteenable_i    => hr_flp_avm_byteenable,
         s0_avm_burstcount_i    => hr_flp_avm_burstcount,
         s0_avm_readdata_o      => hr_flp_avm_readdata,
         s0_avm_readdatavalid_o => hr_flp_avm_readdatavalid,
         s0_avm_waitrequest_o   => hr_flp_avm_waitrequest,

         s1_avm_write_i         => hr_adf_avm_write,
         s1_avm_read_i          => hr_adf_avm_read,
         s1_avm_address_i       => hr_adf_avm_address,
         s1_avm_writedata_i     => hr_adf_avm_writedata,
         s1_avm_byteenable_i    => hr_adf_avm_byteenable,
         s1_avm_burstcount_i    => hr_adf_avm_burstcount,
         s1_avm_readdata_o      => hr_adf_avm_readdata,
         s1_avm_readdatavalid_o => hr_adf_avm_readdatavalid,
         s1_avm_waitrequest_o   => hr_adf_avm_waitrequest,

         m_avm_write_o          => hr_core_write_o,
         m_avm_read_o           => hr_core_read_o,
         m_avm_address_o        => hr_core_address_o,
         m_avm_writedata_o      => hr_core_writedata_o,
         m_avm_byteenable_o     => hr_core_byteenable_o,
         m_avm_burstcount_o     => hr_core_burstcount_o,
         m_avm_readdata_i       => hr_core_readdata_i,
         m_avm_readdatavalid_i  => hr_core_readdatavalid_i,
         m_avm_waitrequest_i    => hr_core_waitrequest_i
      ); -- i_avm_arbit_adf

end architecture synthesis;
