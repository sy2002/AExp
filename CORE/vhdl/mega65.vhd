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

   -- OSM-open key selection (issue #8): the core decodes the "OSM: %s" radio and
   -- tells the framework's m2m_keyb which key(s) drive the menu-open bit
   -- (qnice_keys bit 7). Threaded core->framework->m2m_keyb, exactly like video_fl_o.
   osm_key_a_o             : out integer range 0 to 79;
   osm_key_b_o             : out integer range 0 to 79;
   osm_combo_o             : out std_logic;

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

-- Amiga-local cold boot for memory-topology changes (Slow RAM / A501). The
-- controller resets only Minimig and uses a short override of Chip RAM port A
-- to invalidate the warm-boot SysBase pointer at $000004-$000007.
signal amiga_cold_reset       : std_logic;
signal amiga_chip_scrub       : std_logic;
signal amiga_chip_scrub_addr  : std_logic_vector(17 downto 0);
signal main_chip_addr         : std_logic_vector(17 downto 0);
signal main_chip_data_u       : std_logic_vector(7 downto 0);
signal main_chip_data_l       : std_logic_vector(7 downto 0);
signal main_chip_wren_u       : std_logic;
signal main_chip_wren_l       : std_logic;

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
signal main_adf_writable          : std_logic;
signal main_adf_dirty             : std_logic;
signal main_adf_wr_track          : std_logic_vector(7 downto 0);
signal main_adf_wr_req            : std_logic;
signal main_adf_wr_ack            : std_logic;

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
signal qnice_adf_write_en     : std_logic;
signal qnice_adf_any_dirty    : std_logic;
signal qnice_adf_wrt_track    : std_logic_vector(7 downto 0);
signal qnice_adf_wrt_req      : std_logic;
signal qnice_adf_wrt_ack      : std_logic;

---------------------------------------------------------------------------------------------
-- hr_clk (HyperRAM clock domain)
---------------------------------------------------------------------------------------------

-- HDMI flicker-free (issue #12): the core-speed select for clk.vhd, driven by the ascal
-- over/underflow feedback (hr_high_i/hr_low_i, already in the hr_clk domain -> no CDC), and
-- the flicker-free ON/OFF menu bit synchronized from the core clock domain. Power-up = native.
signal hr_core_speed              : unsigned(1 downto 0) := "00";
signal hr_hdmi_ff                 : std_logic;

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
-- The "Display" section headline+line at lines 4/5 (issue #6) shifted every
-- entry below it by another 2 lines vs the previous layout.
-- An OCS PAL Amiga is a 50 Hz machine, so only 50 Hz HDMI modes are offered.
constant C_MENU_HDMI_16_9_50  : natural :=  9;
constant C_MENU_HDMI_4_3_50   : natural := 10;
constant C_MENU_HDMI_5_4_50   : natural := 11;

-- The HDMI Filter radio is read by the firmware only (dispatcher
-- LOAD_HDMI_FILTER with ASCAL_USAGE=1), never by any VHDL: these eight
-- lines exist solely as the scrape source for osm_const.asm.
constant C_MENU_FLT_NO_FILTER     : natural := 17;
constant C_MENU_FLT_SHARP         : natural := 18;
constant C_MENU_FLT_BICUBIC       : natural := 19;
constant C_MENU_FLT_SMOOTH        : natural := 20;
constant C_MENU_FLT_LANCZOS       : natural := 21;
constant C_MENU_FLT_SCANLINES     : natural := 22;
constant C_MENU_FLT_CRT_SVIDEO    : natural := 23;
constant C_MENU_FLT_CRT_COMPOSITE : natural := 24;

-- HDMI flicker-free toggle (issue #12): single-select, default ON, read here in HDL
-- (like the VGA radio) and CDC'd into the hr_clk domain to drive the core-speed FSM.
constant C_MENU_HDMI_FF       : natural := 27;

constant C_MENU_VGA_STD       : natural := 31;   -- VGA: Standard (scandoubled 31.25 kHz); default
constant C_MENU_VGA_15KHZHSVS : natural := 35;   -- VGA: raw 15.625 kHz RGB with separate HS/VS
constant C_MENU_VGA_15KHZCS   : natural := 36;   -- VGA: raw 15.625 kHz RGB with composite sync (SCART)

-- OSM Scaling follows the C64 layout: line 43 (100%, default) maps to bit 0,
-- while line 51 (50%) maps to bit 8 for the framework's first_nonzero_bit decode.
subtype C_MENU_OSM_SCALING is natural range 51 downto 43;

-- Keyboard mapping mode radio (issue #6): '1' = Amiga (pure positional), '0' = MEGA65
-- (semantic "cap is law"; default). Read here in HDL and wired straight into
-- keyboard.vhd via main.vhd, exactly like the VGA/flicker-free bits. Line 58 (MEGA65)
-- carries OPTM_G_STDSEL, so this Amiga bit is 0 at power-up.
constant C_MENU_KBD_AMIGA     : natural := 57;

-- OSM-open key radio (issue #8): selects which key(s) drive the framework's
-- menu-open bit (qnice_keys bit 7). Decoded below into m2m_keyb's osm_key_a/b +
-- combo inputs and threaded core->framework->m2m_keyb, so the firmware stays
-- byte-identical (bit 7 keeps its "the menu key" meaning). Line 62 (Help) carries
-- OPTM_G_STDSEL = the classic default. MEGA+Run/Stop is a two-key combo.
constant C_MENU_OSMKEY_HELP   : natural := 62;
constant C_MENU_OSMKEY_F11    : natural := 63;
constant C_MENU_OSMKEY_F13    : natural := 64;
constant C_MENU_OSMKEY_COMBO  : natural := 65;

-- Slow RAM (A501) toggle (issue #20): single-select, default ON. '1' = the classic
-- 512 KB trapdoor expansion at $C00000 is present, '0' = chip-RAM-only A500.
-- Wired into main.vhd -> amiga_config.vhd, which encodes it in the userio memory
-- config (command 0xF5). amiga_cold_boot detects a change, invalidates Kickstart's
-- warm-boot state and resets only the emulated Amiga; QNICE keeps running.
constant C_MENU_SLOWRAM       : natural := 69;

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


   -- MMCME2_ADV clock generator: 28.375 MHz Amiga PAL master clock, plus the
   -- 28.4375 MHz HDMI flicker-free "fast" twin selected by hr_core_speed (issue #12)
   clk_gen : entity work.clk
      port map (
         sys_clk_i         => clk_i,           -- expects 100 MHz
         core_speed_i      => hr_core_speed,   -- "00"=native (28.375), "01"=fast (28.4375)
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

   -- Amiga floppy LED on the MEGA65 drive LED (Paula disk-DMA activity).
   -- While unflushed ADF writes exist the LED is forced ON and turns YELLOW -
   -- "do not power off yet" - and back to green once the background flush is
   -- done (the C64MEGA65 vdrives UX, their main.vhd:621-629).
   main_drive_led_o     <= main_fdd_led or main_adf_dirty;
   main_drive_led_col_o <= x"FFFF00" when main_adf_dirty = '1' else x"00FF00";

   -- OSM-open key selection (issue #8): decode the "OSM: %s" radio into m2m_keyb's
   -- selected-key inputs. main_osm_control_i is static in the core clock domain
   -- (like the keyboard-mode and VGA bits), so this is pure combinational routing -
   -- no CDC. Key numbers share the m2m_keyb / keyboard.vhd m65_* numbering:
   -- Help=67, F11=69, F13=70, MEGA(left)=61, Run/Stop=63. The radio is one-hot with
   -- a guaranteed STDSEL default (Help), so the fall-through = Help = classic behaviour.
   -- The MEGA+Run/Stop combo closes symmetrically (hold both again): m2m_keyb hides
   -- Run/Stop's menu-up bit 6 while MEGA is held, so no bit-6 close/bit-7 reopen bounce.
   osm_key_a_o <= 69 when main_osm_control_i(C_MENU_OSMKEY_F11)   = '1' else
                  70 when main_osm_control_i(C_MENU_OSMKEY_F13)   = '1' else
                  61 when main_osm_control_i(C_MENU_OSMKEY_COMBO) = '1' else
                  67;                                    -- Help (default)
   osm_key_b_o <= 63 when main_osm_control_i(C_MENU_OSMKEY_COMBO) = '1' else 67;
   osm_combo_o <= main_osm_control_i(C_MENU_OSMKEY_COMBO);

   -- Memory topology is guest state, so changing it must be a cold boot from
   -- Kickstart's perspective. This local controller deliberately does not drive
   -- either M2M reset: the menu, QNICE and the framework remain alive.
   i_amiga_cold_boot : entity work.amiga_cold_boot
      port map (
         clk_i             => main_clk,
         slow_ram_i        => main_osm_control_i(C_MENU_SLOWRAM),
         amiga_reset_o     => amiga_cold_reset,
         chip_scrub_o      => amiga_chip_scrub,
         chip_scrub_addr_o => amiga_chip_scrub_addr
      ); -- i_amiga_cold_boot

   -- main.vhd contains the actual MiSTer core
   i_main : entity work.main
      generic map (
         G_VDNUM              => C_VDNUM,
         G_ADF_BASE_ADDRESS   => C_HMAP_ADF_DF0(9 downto 0) & x"000"
      )
      port map (
         clk_main_i           => main_clk,
         reset_soft_i         => main_reset_core_i or amiga_cold_reset,
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

         -- ADF floppy: mount status, write-back arming, dirty-track events
         -- and the HyperRAM read/write port
         adf_mounted_i        => main_adf_mounted,
         adf_tracks_i         => main_adf_tracks,
         adf_writable_i       => main_adf_writable,
         adf_wr_track_o       => main_adf_wr_track,
         adf_wr_req_o         => main_adf_wr_req,
         adf_wr_ack_i         => main_adf_wr_ack,
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

         -- Keyboard mapping mode (issue #6): '1' = Amiga positional, '0' = MEGA65 semantic.
         -- Static OSM bit in the core clock domain, wired straight through to keyboard.vhd
         -- (like video_retro15khz_i above).
         keyboard_mode_i      => main_osm_control_i(C_MENU_KBD_AMIGA),

         -- Slow RAM (A501) toggle (issue #20): '1' = 512 KB Slow RAM at $C00000 present.
         -- Sampled by amiga_config.vhd during the Amiga-local cold boot above, so the new
         -- topology is installed before Kickstart rebuilds its memory list.
         slow_ram_i           => main_osm_control_i(C_MENU_SLOWRAM),

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
         pot2_y_i             => main_pot2_y_i,
         rtc_i                => main_rtc_i
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

   -- Default (fall-through) is 720p 50 Hz 16:9.
   qnice_video_mode_o <= C_VIDEO_HDMI_5_4_50   when qnice_osm_control_i(C_MENU_HDMI_5_4_50)    = '1' else
                         C_VIDEO_HDMI_4_3_50   when qnice_osm_control_i(C_MENU_HDMI_4_3_50)    = '1' else
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
   qnice_osm_cfg_scaling_o    <= qnice_osm_control_i(C_MENU_OSM_SCALING);

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
   -- During an Amiga-local cold boot only, the existing Chip RAM port is
   -- overridden for two clocks to clear $000004-$000007. Both byte lanes are
   -- written together; the 68000 and chipset are held in reset throughout.
   main_chip_addr   <= amiga_chip_scrub_addr when amiga_chip_scrub = '1' else main_ram_addr(18 downto 1);
   main_chip_data_u <= (others => '0') when amiga_chip_scrub = '1' else main_ram_wrdata(15 downto 8);
   main_chip_data_l <= (others => '0') when amiga_chip_scrub = '1' else main_ram_wrdata(7 downto 0);
   main_chip_wren_u <= '1' when amiga_chip_scrub = '1' else
                       main_chip_sel and not main_ram_we_n and not main_ram_bhe_n;
   main_chip_wren_l <= '1' when amiga_chip_scrub = '1' else
                       main_chip_sel and not main_ram_we_n and not main_ram_ble_n;

   chip_ram_u : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 18,
         DATA_WIDTH => 8
      )
      port map (
         clock_a   => main_clk,
         address_a => main_chip_addr,
         data_a    => main_chip_data_u,
         wren_a    => main_chip_wren_u,
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
         address_a => main_chip_addr,
         data_a    => main_chip_data_l,
         wren_a    => main_chip_wren_l,
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

         qnice_write_en_o     => qnice_adf_write_en,
         qnice_any_dirty_o    => qnice_adf_any_dirty,
         qnice_wrt_track_i    => qnice_adf_wrt_track,
         qnice_wrt_req_i      => qnice_adf_wrt_req,
         qnice_wrt_ack_o      => qnice_adf_wrt_ack,

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

   ---------------------------------------------------------------------------------------------
   -- HDMI flicker-free core-speed FSM (issue #12), hr_clk domain
   ---------------------------------------------------------------------------------------------

   -- Bang-bang loop: nudge the core clock so its frame rate embraces the exact 50.000 Hz HDMI
   -- output. hr_low_i/hr_high_i are the ascal write-lead over/underflow flags, registered in
   -- the same hr_clk net (hdmi_flicker_free.vhd) -> sampled here without any CDC. Direction is
   -- inverted vs C64MEGA65: the Amiga's native rate is BELOW 50, so "too slow" picks the FAST
   -- twin and "too fast" falls back to native. The OFF override forces authentic native and is
   -- last so it always wins. The two flags are mutually exclusive, so their order is immaterial.
   p_flicker_fsm : process (hr_clk_i)
   begin
      if rising_edge(hr_clk_i) then
         if hr_low_i = '1' then      -- core too slow (write pointer lagging) ...
            hr_core_speed <= "01";   -- ... speed up: FAST twin (28.4375 MHz, above 50)
         end if;
         if hr_high_i = '1' then     -- core too fast (write pointer leading) ...
            hr_core_speed <= "00";   -- ... slow down: NATIVE (28.375 MHz, below 50)
         end if;
         if hr_hdmi_ff = '0' then    -- flicker-free OFF ...
            hr_core_speed <= "00";   -- ... hold authentic native, no dither
         end if;
      end if;
   end process; -- p_flicker_fsm

   -- Flicker-free ON/OFF menu bit into the hr_clk domain. Toggling it live only changes the
   -- glitch-free mux select, so there is no core reset (identical to C64MEGA65's mechanism).
   i_cdc_hdmi_ff : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 1,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i     => main_clk,
         src_data_i(0) => main_osm_control_i(C_MENU_HDMI_FF),
         dst_clk_i     => hr_clk_i,
         dst_data_o(0) => hr_hdmi_ff
      ); -- i_cdc_hdmi_ff

   -- mount + write-back status into the core clock domain (slowly varying
   -- flags + track count; covered by M2M/common.xdc's cdc_stable constraint)
   i_cdc_adf_mount : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 11,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i               => qnice_clk_i,
         src_data_i(7 downto 0)  => qnice_adf_tracks,
         src_data_i(8)           => qnice_adf_mounted,
         src_data_i(9)           => qnice_adf_write_en,
         src_data_i(10)          => qnice_adf_any_dirty,
         dst_clk_i               => main_clk,
         dst_data_o(7 downto 0)  => main_adf_tracks,
         dst_data_o(8)           => main_adf_mounted,
         dst_data_o(9)           => main_adf_writable,
         dst_data_o(10)          => main_adf_dirty
      ); -- i_cdc_adf_mount

   -- dirty-track event channel main->qnice: two-phase toggle handshake. The
   -- engine holds the track number stable, waits ~1 us, THEN flips the req
   -- toggle (and the payload stays put until the ack round trip completes),
   -- so cdc_stable's per-bit settling can never deliver a torn payload with
   -- a fresh toggle. Ack returns the same way. All three instances are
   -- covered by the common.xdc cdc_stable set_max_delay constraint.
   i_cdc_adf_wrt_evt : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 9,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i               => main_clk,
         src_data_i(7 downto 0)  => main_adf_wr_track,
         src_data_i(8)           => main_adf_wr_req,
         dst_clk_i               => qnice_clk_i,
         dst_data_o(7 downto 0)  => qnice_adf_wrt_track,
         dst_data_o(8)           => qnice_adf_wrt_req
      ); -- i_cdc_adf_wrt_evt

   i_cdc_adf_wrt_ack : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 1,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i               => qnice_clk_i,
         src_data_i(0)           => qnice_adf_wrt_ack,
         dst_clk_i               => main_clk,
         dst_data_o(0)           => main_adf_wr_ack
      ); -- i_cdc_adf_wrt_ack

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
