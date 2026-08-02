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
-- Amiga 500 port (AExp) done by sy2002 in 2026.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;
use work.types_pkg.all;
use work.video_modes_pkg.all;
use work.physical_fdd_pkg.all;

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

   -- MEGA65 internal floppy drive (Hardware Floppy feature): the 34-pin
   -- connector, threaded as plain wires from the board tops (M2M-UPSTREAM
   -- floppy-pins; the C64MEGA65 issue-#90 pattern). All active low. Drive B
   -- and the write pins (f_motorb/f_selectb/f_wdata/f_wgate) stay tied '1'
   -- at the top level - read-only milestone.
   f_motora_o              : out std_logic;
   f_selecta_o             : out std_logic;
   f_side1_o               : out std_logic;
   f_stepdir_o             : out std_logic;
   f_step_o                : out std_logic;
   f_density_o             : out std_logic;
   f_index_i               : in  std_logic;
   f_track0_i              : in  std_logic;
   f_writeprotect_i        : in  std_logic;
   f_rdata_i               : in  std_logic;
   f_diskchanged_i         : in  std_logic;

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

-- Master volume: OSM "Volume" radio decoded into a step index (0 = mute .. 20 = 100%)
signal main_volume            : natural range 0 to 20;

-- Stereo crossfeed: OSM "Stereo" radio decoded into MiSTer's aud_mix encoding
signal main_stereo_mix        : std_logic_vector(1 downto 0);

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

-- Hardware Floppy (main_clk side): drive-map combo decode, CIA-B taps from
-- minimig, conditioned real drive status (CDC'd from the 50 MHz front-end
-- below) and the reconstructed word stream towards the track engine
signal main_hwf_combo             : std_logic_vector(1 downto 0);  -- {single_drive, hw_is_df0}
signal main_hwf_en                : std_logic;                     -- physical unit exists
signal main_hwf_unit              : std_logic_vector(1 downto 0);  -- physical unit
signal main_adf_en                : std_logic;                     -- ADF drive exists
signal main_adf_unit              : std_logic_vector(1 downto 0);  -- ADF unit
signal main_hwf_ctrl              : std_logic_vector(7 downto 0);  -- {motor_n,sel3..0_n,side,direc,step_n}
signal main_hwf_motor_on          : std_logic_vector(3 downto 0);
signal main_hwf_selected          : std_logic := '0';
signal main_hwf_motor             : std_logic;
signal main_hwf_change_n          : std_logic;
signal main_hwf_wprot_n           : std_logic;
signal main_hwf_track0_n          : std_logic;
signal main_hwf_ready_n           : std_logic;
signal main_hwf_index             : std_logic;
signal main_hwf_present           : std_logic;
signal main_hwf_rd_data           : std_logic_vector(15 downto 0);
signal main_hwf_rd_empty          : std_logic;
signal main_hwf_rd_en             : std_logic;
signal main_hwf_dsksync           : std_logic_vector(15 downto 0);
signal main_hwf_sideinv           : std_logic;                     -- diag side-invert, synced
signal main_hwf_served_gray       : std_logic_vector(15 downto 0); -- engine served-word count (Gray)
signal main_hwf_eng_sig           : std_logic_vector(15 downto 0); -- store-signature pair: engine side
signal main_hwf_eng_ses           : std_logic_vector(7 downto 0);
signal main_hwf_eng_done          : std_logic;
signal main_hwf_eng_c64           : std_logic_vector(15 downto 0);
signal main_hwf_eng_c256          : std_logic_vector(15 downto 0);
signal main_hwf_pau_sig           : std_logic_vector(15 downto 0); -- store-signature pair: Paula side
signal main_hwf_pau_att           : std_logic_vector(7 downto 0);
signal main_hwf_pau_c64           : std_logic_vector(15 downto 0);
signal main_hwf_pau_c256          : std_logic_vector(15 downto 0);
signal main_hwf_pau_tap           : std_logic_vector(127 downto 0);
signal main_hwf_pau_ws            : std_logic;
signal main_qnice_rst             : std_logic;  -- QNICE reset synced into main_clk: the
                                                -- front-end FIFO's read-side reset MUST
                                                -- derive from the same event as the
                                                -- write side (Gray-pointer discipline)

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

-- Hardware Floppy front-end (physical_fdd_top runs on qnice_clk; every
-- magnetic constant is hardware-proven at exactly 50 MHz) + diag device 0x0104
signal qnice_fdd_track0_n     : std_logic;
signal qnice_fdd_wprot_n      : std_logic;
signal qnice_fdd_change_n     : std_logic;
signal qnice_fdd_ready_n      : std_logic;
signal qnice_fdd_index        : std_logic;
signal qnice_fdd_present      : std_logic;
signal qnice_fdd_status       : std_logic_vector(15 downto 0);
signal qnice_fdd_sync         : std_logic_vector(15 downto 0);
signal qnice_fdd_est          : unsigned(11 downto 0);
signal qnice_fdd_level        : unsigned(5 downto 0);
signal qnice_fdd_idxper       : unsigned(31 downto 0);
signal qnice_fdd_idxwid       : unsigned(31 downto 0);
signal qnice_fdd_cnt_index    : unsigned(15 downto 0);
signal qnice_fdd_cnt_sync     : unsigned(15 downto 0);
signal qnice_fdd_cnt_word     : unsigned(15 downto 0);
signal qnice_fdd_cnt_runt     : unsigned(15 downto 0);
signal qnice_fdd_cnt_lol      : unsigned(15 downto 0);
signal qnice_fdd_cnt_drop     : unsigned(15 downto 0);
signal qnice_fdd_data         : std_logic_vector(15 downto 0);
signal qnice_hwf_map3         : std_logic_vector(2 downto 0);  -- {unit[1:0], enable} for diag
signal qnice_fdd_cap_flags    : std_logic_vector(3 downto 0);
signal qnice_fdd_cap_count    : unsigned(15 downto 0);
signal qnice_fdd_cap_words    : t_fdd_cap_words;
signal qnice_fdd_sideinv      : std_logic := '0';              -- diag reg 0x1F bit 0
signal qnice_fdd_rev_mask     : std_logic_vector(10 downto 0);
signal qnice_fdd_rev_caps     : unsigned(7 downto 0);
signal qnice_fdd_rev_lol      : unsigned(7 downto 0);
signal qnice_fdd_fmt_bad      : unsigned(15 downto 0);

-- engine served-word Gray counter: 2-FF sync into the QNICE domain (single-
-- step Gray - engine increments are >= one io-word handshake apart, far
-- slower than this clock samples), then decoded/registered as binary
signal qnice_fdd_served_m     : std_logic_vector(15 downto 0);
signal qnice_fdd_served_s     : std_logic_vector(15 downto 0);
signal qnice_fdd_served       : unsigned(15 downto 0) := (others => '0');
attribute async_reg           : string;
attribute async_reg of qnice_fdd_served_m : signal is "true";

-- store-signature pair into the QNICE domain (quasi-static after each read
-- attempt; cdc_stable below)
signal qnice_fdd_eng_sig      : std_logic_vector(15 downto 0);
signal qnice_fdd_eng_ses      : std_logic_vector(7 downto 0);
signal qnice_fdd_eng_done     : std_logic;
signal qnice_fdd_eng_c64      : std_logic_vector(15 downto 0);
signal qnice_fdd_eng_c256     : std_logic_vector(15 downto 0);
signal qnice_fdd_pau_sig      : std_logic_vector(15 downto 0);
signal qnice_fdd_pau_att      : std_logic_vector(7 downto 0);
signal qnice_fdd_pau_c64      : std_logic_vector(15 downto 0);
signal qnice_fdd_pau_c256     : std_logic_vector(15 downto 0);
signal qnice_fdd_pau_tap      : std_logic_vector(127 downto 0);
signal qnice_fdd_pau_ws       : std_logic;

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

-- (the " df0:%s" mount item at line 2, the hardware-role text at line 3 and
-- the " Configure Drives" submenu head at line 4 are handled by the Shell /
-- firmware and need no C_MENU constant here)
-- ALL C_MENU_* constants below are additionally scraped by
-- CORE/m2m-rom/make_rom.sh into the autogenerated osm_const.asm (as
-- AEXP_OSM_*), so the firmware never hardcodes menu line numbers.
-- Keep them single-line for the awk scraper.
-- The Configure Drives block at lines 3..12 shifted every entry below it by
-- 10 lines vs the pre-Hardware-Floppy layout.
-- An OCS PAL Amiga is a 50 Hz machine, so only 50 Hz HDMI modes are offered.

-- Configure Drives radio (drive-map combos, Hardware Floppy feature): which
-- Amiga units the ADF drive and the MEGA65's real internal drive occupy.
-- Line 7 carries OPTM_G_STDSEL = the default (df0: ADF, df1: Hardware).
-- Decoded below into the 2-bit combo code {single_drive, hw_is_df0}:
-- A="00" df0:ADF df1:HW, B="01" df0:HW df1:ADF, C="10" df0:ADF only,
-- D="11" df0:HW only (no ADF drive). A change triggers the amiga_cold_boot
-- reset (drive count is reset-latched in Paula and AmigaOS enumerates units
-- at boot). The firmware rewrites the labels of menu lines 2+3 to match
-- (HWF_LABEL_SYNC; see config.vhd's DRIVE LINES comment).
constant C_MENU_HWFC_ADF_HW   : natural :=  7;
constant C_MENU_HWFC_HW_ADF   : natural :=  8;
constant C_MENU_HWFC_ADF_OFF  : natural :=  9;
constant C_MENU_HWFC_HW_OFF   : natural := 10;

constant C_MENU_HDMI_16_9_50  : natural := 19;
constant C_MENU_HDMI_4_3_50   : natural := 20;
constant C_MENU_HDMI_5_4_50   : natural := 21;

-- The HDMI Filter radio is read by the firmware only (dispatcher
-- LOAD_HDMI_FILTER with ASCAL_USAGE=1), never by any VHDL: these eight
-- lines exist solely as the scrape source for osm_const.asm.
constant C_MENU_FLT_NO_FILTER     : natural := 27;
constant C_MENU_FLT_SHARP         : natural := 28;
constant C_MENU_FLT_BICUBIC       : natural := 29;
constant C_MENU_FLT_SMOOTH        : natural := 30;
constant C_MENU_FLT_LANCZOS       : natural := 31;
constant C_MENU_FLT_SCANLINES     : natural := 32;
constant C_MENU_FLT_CRT_SVIDEO    : natural := 33;
constant C_MENU_FLT_CRT_COMPOSITE : natural := 34;

-- HDMI flicker-free toggle (issue #12): single-select, default ON, read here in HDL
-- (like the VGA radio) and CDC'd into the hr_clk domain to drive the core-speed FSM.
constant C_MENU_HDMI_FF       : natural := 37;

constant C_MENU_VGA_STD       : natural := 41;   -- VGA: Standard (scandoubled 31.25 kHz); default
constant C_MENU_VGA_15KHZHSVS : natural := 45;   -- VGA: raw 15.625 kHz RGB with separate HS/VS
constant C_MENU_VGA_15KHZCS   : natural := 46;   -- VGA: raw 15.625 kHz RGB with composite sync (SCART)

-- OSM Scaling follows the C64 layout: line 53 (100%, default) maps to bit 0,
-- while line 61 (50%) maps to bit 8 for the framework's first_nonzero_bit decode.
subtype C_MENU_OSM_SCALING is natural range 61 downto 53;

-- Volume radio (master volume, 5% steps): line 70 (100%, default) down to line 90
-- (0% = mute). Decoded below into main_volume (0..20 step index) and applied in
-- main.vhd as a perceptual Q15 attenuation (C_VOL_LUT) on the final Paula mix,
-- ahead of the framework's split into the HDMI and analog audio paths.
subtype C_MENU_VOLUME is natural range 90 downto 70;

-- Stereo crossfeed radio ("Stereo: %s" submenu): line 96 (Full Stereo, default)
-- down to line 99 (Mono). Decoded below into main_stereo_mix using MiSTer's
-- aud_mix encoding (00 = full separation, 01 = 87.5%/12.5%, 10 = 75%/25%,
-- 11 = mono) and applied in main.vhd's audio_filters ahead of the master volume.
subtype C_MENU_STEREO is natural range 99 downto 96;

-- Paula output filters (MiSTer Minimig.sv parity), both single-select toggles
-- with OPTM_G_STDSEL = default ON. A500 Filter inserts the fixed 4400 Hz
-- low-pass behind Paula's DAC ('0' = brighter A1200-style output stage); LED
-- Filter arms the switchable 3 kHz low-pass on CIA-A PA1, which then follows
-- the emulated power LED live (MiSTer's "Auto(LED)"). Both are static OSM bits
-- wired straight into main.vhd like the keyboard/VGA bits.
constant C_MENU_A500FILT      : natural := 102;
constant C_MENU_LEDFILT       : natural := 103;

-- Keyboard mapping mode radio (issue #6): '1' = Amiga (pure positional), '0' = MEGA65
-- (semantic "cap is law"; default). Read here in HDL and wired straight into
-- keyboard.vhd via main.vhd, exactly like the VGA/flicker-free bits. Line 108 (MEGA65)
-- carries OPTM_G_STDSEL, so this Amiga bit is 0 at power-up.
constant C_MENU_KBD_AMIGA     : natural := 107;

-- OSM-open key radio (issue #8): selects which key(s) drive the framework's
-- menu-open bit (qnice_keys bit 7). Decoded below into m2m_keyb's osm_key_a/b +
-- combo inputs and threaded core->framework->m2m_keyb, so the firmware stays
-- byte-identical (bit 7 keeps its "the menu key" meaning). Line 112 (Help) carries
-- OPTM_G_STDSEL = the classic default. MEGA+Run/Stop is a two-key combo.
constant C_MENU_OSMKEY_HELP   : natural := 112;
constant C_MENU_OSMKEY_F11    : natural := 113;
constant C_MENU_OSMKEY_F13    : natural := 114;
constant C_MENU_OSMKEY_COMBO  : natural := 115;

-- Slow RAM (A501) toggle (issue #20): single-select, default ON. '1' = the classic
-- 512 KB trapdoor expansion at $C00000 is present, '0' = chip-RAM-only A500.
-- Wired into main.vhd -> amiga_config.vhd, which encodes it in the userio memory
-- config (command 0xF5). amiga_cold_boot detects a change, invalidates Kickstart's
-- warm-boot state and resets only the emulated Amiga; QNICE keeps running.
constant C_MENU_SLOWRAM       : natural := 119;

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

   -- Master volume: the OSM "Volume" radio (C_MENU_VOLUME) is a 21-way one-hot
   -- selection in 5% steps; its lowest bit (line 60) is 100% and its highest bit
   -- (line 80) is 0%. Translate it into a 0..20 step index (0 = mute, 20 = 100%),
   -- defaulting to 100% when no bit is set (e.g. while QNICE is still booting), so
   -- the core never powers up muted. Like the OSM-key decode above this is static,
   -- pure combinational routing in the core clock domain - no CDC. The perceptual
   -- attenuation itself lives in main.vhd (C_VOL_LUT), ahead of the framework's
   -- split into the HDMI and analog audio paths.
   volume_decode_proc : process (main_osm_control_i)
   begin
      main_volume <= 20;                                  -- default: 100%
      for b in C_MENU_VOLUME'low to C_MENU_VOLUME'high loop
         if main_osm_control_i(b) = '1' then
            main_volume <= C_MENU_VOLUME'high - b;        -- bit 60 -> 20 (100%) .. bit 80 -> 0 (mute)
         end if;
      end loop;
   end process volume_decode_proc;

   -- Stereo crossfeed: the OSM "Stereo" radio (C_MENU_STEREO) is a 4-way one-hot
   -- pick; translate it into MiSTer's aud_mix encoding (bit 86 -> 00 = Full
   -- Stereo .. bit 89 -> 11 = Mono), defaulting to full separation when no bit
   -- is set yet. Static combinational routing like the volume decode above.
   stereo_decode_proc : process (main_osm_control_i)
   begin
      main_stereo_mix <= "00";                            -- default: Full Stereo
      for b in C_MENU_STEREO'low to C_MENU_STEREO'high loop
         if main_osm_control_i(b) = '1' then
            main_stereo_mix <= std_logic_vector(to_unsigned(b - C_MENU_STEREO'low, 2));
         end if;
      end loop;
   end process stereo_decode_proc;

   -- Hardware Floppy drive map: decode the Configure Drives radio into the
   -- combo code {single_drive, hw_is_df0}. The fall-through default is
   -- combo A (df0: ADF, df1: Hardware - the OPTM_G_STDSEL line), so the
   -- core behaves per the standard map even while QNICE is still booting.
   hwf_combo_decode : process (main_osm_control_i)
   begin
      if main_osm_control_i(C_MENU_HWFC_HW_ADF) = '1' then
         main_hwf_combo <= "01";                            -- B: df0 HW, df1 ADF
      elsif main_osm_control_i(C_MENU_HWFC_ADF_OFF) = '1' then
         main_hwf_combo <= "10";                            -- C: df0 ADF only
      elsif main_osm_control_i(C_MENU_HWFC_HW_OFF) = '1' then
         main_hwf_combo <= "11";                            -- D: df0 HW only
      else
         main_hwf_combo <= "00";                            -- A: df0 ADF, df1 HW (default)
      end if;
   end process hwf_combo_decode;

   main_hwf_en   <= '0' when main_hwf_combo = "10" else '1';       -- no physical unit in C
   main_adf_en   <= '0' when main_hwf_combo = "11" else '1';       -- no ADF drive in D
   main_hwf_unit <= "0" & not main_hwf_combo(0);                   -- HW: df0 in B/D, df1 in A
   main_adf_unit <= "0" & main_hwf_combo(0);                       -- ADF: the other unit

   -- Memory topology is guest state, so changing it must be a cold boot from
   -- Kickstart's perspective; the Hardware Floppy drive map is treated the
   -- same way (drive count is reset-latched in Paula, units are enumerated at
   -- boot). This local controller deliberately does not drive either M2M
   -- reset: the menu, QNICE and the framework remain alive.
   i_amiga_cold_boot : entity work.amiga_cold_boot
      port map (
         clk_i             => main_clk,
         slow_ram_i        => main_osm_control_i(C_MENU_SLOWRAM),
         hwf_map_i         => main_hwf_combo,
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

         -- Master volume (OSM "Volume" radio): 0..20 step index = mute..100%
         audio_volume_i       => main_volume,

         -- Paula output filters + stereo crossfeed (OSM "Audio" section):
         -- static bits, applied in main.vhd's audio_filters ahead of the volume
         audio_a500_filter_i  => main_osm_control_i(C_MENU_A500FILT),
         audio_led_filter_i   => main_osm_control_i(C_MENU_LEDFILT),
         audio_stereo_mix_i   => main_stereo_mix,

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

         -- Hardware Floppy: drive map, CIA-B taps, conditioned real drive
         -- status and the reconstructed word stream (front-end below)
         hwf_adf_en_i         => main_adf_en,
         hwf_adf_unit_i       => main_adf_unit,
         hwf_phys_unit_i      => main_hwf_unit,
         hwf_phys_en_i        => main_hwf_en,
         hwf_fdd_ctrl_o       => main_hwf_ctrl,
         hwf_motor_on_o       => main_hwf_motor_on,
         hwf_change_n_i       => main_hwf_change_n,
         hwf_wprot_n_i        => main_hwf_wprot_n,
         hwf_track0_n_i       => main_hwf_track0_n,
         hwf_ready_n_i        => main_hwf_ready_n,
         hwf_index_i          => main_hwf_index,
         hwf_present_i        => main_hwf_present,
         hwf_rd_data_i        => main_hwf_rd_data,
         hwf_rd_empty_i       => main_hwf_rd_empty,
         hwf_rd_en_o          => main_hwf_rd_en,
         hwf_dsksync_o        => main_hwf_dsksync,
         hwf_served_gray_o    => main_hwf_served_gray,
         hwf_eng_sig_o        => main_hwf_eng_sig,
         hwf_eng_ses_o        => main_hwf_eng_ses,
         hwf_eng_done_o       => main_hwf_eng_done,
         hwf_eng_c64_o        => main_hwf_eng_c64,
         hwf_eng_c256_o       => main_hwf_eng_c256,
         hwf_pau_sig_o        => main_hwf_pau_sig,
         hwf_pau_att_o        => main_hwf_pau_att,
         hwf_pau_c64_o        => main_hwf_pau_c64,
         hwf_pau_c256_o       => main_hwf_pau_c256,
         hwf_pau_tap_o        => main_hwf_pau_tap,
         hwf_pau_ws_o         => main_hwf_pau_ws,

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
   --   0x0103  C_DEV_AMIGA_ADF0  ADF mount buffer in HyperRAM + CSR window 0xFFFF
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

         when C_DEV_AMIGA_ADF0 =>
            qnice_adf_ce     <= qnice_dev_ce_i;
            qnice_dev_data_o <= qnice_adf_data;
            qnice_dev_wait_o <= qnice_adf_wait;

         -- Hardware Floppy diagnostics: register bank, no wait (the single
         -- writable register 0x1F lives in the process below)
         when C_DEV_AMIGA_FDD =>
            qnice_dev_data_o <= qnice_fdd_data;

         when others => null;
      end case;
   end process core_specific_devices;

   -- Hardware Floppy diag write register 0x1F, bit 0 = side-invert: XORed
   -- onto the f_side1 pin (hwf_pins_proc) for the empirical side-polarity
   -- verdict - flip it live from the QNICE debug console, no rebuild.
   -- M2M convention: QNICE device writes register on the falling edge.
   fdd_sideinv_proc : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_rst_i = '1' then
            qnice_fdd_sideinv <= '0';
         elsif qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' and
               qnice_dev_id_i = C_DEV_AMIGA_FDD and
               qnice_dev_addr_i(5 downto 0) = "011111" then
            qnice_fdd_sideinv <= qnice_dev_data_i(0);
         end if;
      end if;
   end process fdd_sideinv_proc;

   -- store-signature pair into the QNICE domain: both sides are quasi-static
   -- (they change once per read attempt, >= 200 ms apart), so cdc_stable's
   -- stability guarantee holds and the diag reads consistent values while
   -- the drive is idle
   i_cdc_hwf_sig : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 242,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i                  => main_clk,
         src_data_i(15 downto 0)    => main_hwf_eng_sig,
         src_data_i(23 downto 16)   => main_hwf_eng_ses,
         src_data_i(24)             => main_hwf_eng_done,
         src_data_i(40 downto 25)   => main_hwf_pau_sig,
         src_data_i(48 downto 41)   => main_hwf_pau_att,
         src_data_i(64 downto 49)   => main_hwf_eng_c64,
         src_data_i(80 downto 65)   => main_hwf_eng_c256,
         src_data_i(96 downto 81)   => main_hwf_pau_c64,
         src_data_i(112 downto 97)  => main_hwf_pau_c256,
         src_data_i(240 downto 113) => main_hwf_pau_tap,
         src_data_i(241)            => main_hwf_pau_ws,
         dst_clk_i                  => qnice_clk_i,
         dst_data_o(15 downto 0)    => qnice_fdd_eng_sig,
         dst_data_o(23 downto 16)   => qnice_fdd_eng_ses,
         dst_data_o(24)             => qnice_fdd_eng_done,
         dst_data_o(40 downto 25)   => qnice_fdd_pau_sig,
         dst_data_o(48 downto 41)   => qnice_fdd_pau_att,
         dst_data_o(64 downto 49)   => qnice_fdd_eng_c64,
         dst_data_o(80 downto 65)   => qnice_fdd_eng_c256,
         dst_data_o(96 downto 81)   => qnice_fdd_pau_c64,
         dst_data_o(112 downto 97)  => qnice_fdd_pau_c256,
         dst_data_o(240 downto 113) => qnice_fdd_pau_tap,
         dst_data_o(241)            => qnice_fdd_pau_ws
      ); -- i_cdc_hwf_sig

   -- served-word diagnostic counter: the engine's Gray count crosses by
   -- plain 2-FF (single-step Gray; the qnice<->main max_delay pair in
   -- CORE/CORE.xdc bounds the path), then is decoded to binary and
   -- registered for the diag read mux
   fdd_served_proc : process (qnice_clk_i)
      function f_gray2bin(g : std_logic_vector) return unsigned is
         variable b : std_logic_vector(g'range);
      begin
         b(g'high) := g(g'high);
         for i in g'high - 1 downto g'low loop
            b(i) := b(i + 1) xor g(i);
         end loop;
         return unsigned(b);
      end function f_gray2bin;
   begin
      if rising_edge(qnice_clk_i) then
         qnice_fdd_served_m <= main_hwf_served_gray;
         qnice_fdd_served_s <= qnice_fdd_served_m;
         qnice_fdd_served   <= f_gray2bin(qnice_fdd_served_s);
      end if;
   end process fdd_served_proc;

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
   -- Hardware Floppy: connector driving, 50 MHz read front-end, CDC and diagnostics
   --
   -- The MEGA65's real internal 3.5" drive as an Amiga unit (read milestone).
   -- Control pins are driven straight from Minimig's CIA-B taps (registered
   -- in the core clock domain; the connector is asynchronous). The flux
   -- front-end runs on qnice_clk = exactly 50 MHz, where all magnetic
   -- constants are hardware-proven (C64MEGA65 physical-1581 bring-up); its
   -- conditioned status levels cross into the core domain via cdc_stable and
   -- the reconstructed MFM words via the front-end's dual-clock FIFO.
   ---------------------------------------------------------------------------------------------

   -- Connector outputs, registered in the core clock domain. Polarity facts
   -- (hardware-proven on this mechanism): select/motor/step active low;
   -- f_stepdir '1' = toward track 0 = Minimig's direc; f_density '1' is the
   -- DD-safe level. f_side1 <= side is the straight wire (Minimig side=0
   -- selects the upper head = PC "side 1") - CONFIRMED on real hardware
   -- 2026-07-26 by the diag sector-header capture: a cylinder-0/head-0 read
   -- returned an info long claiming track 0, so the mapping is correct as
   -- wired. The diag register 0x1F (main_hwf_sideinv) remains as a live
   -- inversion facility for future mechanisms; it must stay 0 on this one.
   -- STEP is additionally gated on "our unit selected" (drives gate on
   -- SELECT internally anyway; this keeps the pin quiet when the virtual
   -- unit steps). main_hwf_ctrl = {motor_n,sel3..0_n,side,direc,step_n}.
   hwf_pins_proc : process (main_clk)
      variable v_sel_n : std_logic;
   begin
      if rising_edge(main_clk) then
         if main_hwf_en = '1' then
            if main_hwf_unit = "01" then
               v_sel_n := main_hwf_ctrl(4);                  -- _sel1
            else
               v_sel_n := main_hwf_ctrl(3);                  -- _sel0
            end if;
            f_selecta_o <= v_sel_n;
            if main_hwf_unit = "01" then
               f_motora_o <= not main_hwf_motor_on(1);
            else
               f_motora_o <= not main_hwf_motor_on(0);
            end if;
            f_side1_o   <= main_hwf_ctrl(2) xor main_hwf_sideinv;  -- side (verify on hardware)
            f_stepdir_o <= main_hwf_ctrl(1);                 -- direc: '1' = toward track 0
            if v_sel_n = '0' then
               f_step_o <= main_hwf_ctrl(0);
            else
               f_step_o <= '1';
            end if;
            main_hwf_selected <= not v_sel_n;
         else
            f_selecta_o       <= '1';
            f_motora_o        <= '1';
            f_side1_o         <= '1';
            f_stepdir_o       <= '1';
            f_step_o          <= '1';
            main_hwf_selected <= '0';
         end if;
         f_density_o <= '1';                                 -- DD-safe level, always
      end if;
   end process hwf_pins_proc;

   main_hwf_motor <= main_hwf_motor_on(1) when main_hwf_unit = "01" else main_hwf_motor_on(0);

   -- The read front-end: pins -> conditioner -> gaps -> adaptive quantiser ->
   -- raw-bit rebuild/DSKSYNC aligner -> word FIFO. Control context and the
   -- live DSKSYNC enter as async signals (synchronized/settle-filtered
   -- inside); the FIFO read side runs on main_clk with the QNICE reset
   -- synced below (shared-reset discipline).
   i_physical_fdd_top : entity work.physical_fdd_top
      port map (
         clk_i               => qnice_clk_i,
         rst_i               => qnice_rst_i,
         f_index_i           => f_index_i,
         f_track0_i          => f_track0_i,
         f_writeprotect_i    => f_writeprotect_i,
         f_diskchanged_i     => f_diskchanged_i,
         f_rdata_i           => f_rdata_i,
         enable_i            => main_hwf_en,
         selected_i          => main_hwf_selected,
         motor_i             => main_hwf_motor,
         side_i              => main_hwf_ctrl(2),
         dsksync_i           => main_hwf_dsksync,
         track0_n_o          => qnice_fdd_track0_n,
         wprot_n_o           => qnice_fdd_wprot_n,
         change_n_o          => qnice_fdd_change_n,
         ready_n_o           => qnice_fdd_ready_n,
         index_o             => qnice_fdd_index,
         present_o           => qnice_fdd_present,
         rd_clk_i            => main_clk,
         rd_rst_i            => main_qnice_rst,
         rd_en_i             => main_hwf_rd_en,
         rd_data_o           => main_hwf_rd_data,
         rd_empty_o          => main_hwf_rd_empty,
         diag_status_o       => qnice_fdd_status,
         diag_sync_o         => qnice_fdd_sync,
         diag_est_o          => qnice_fdd_est,
         diag_fifo_level_o   => qnice_fdd_level,
         diag_index_period_o => qnice_fdd_idxper,
         diag_index_width_o  => qnice_fdd_idxwid,
         diag_cnt_index_o    => qnice_fdd_cnt_index,
         diag_cnt_sync_o     => qnice_fdd_cnt_sync,
         diag_cnt_word_o     => qnice_fdd_cnt_word,
         diag_cnt_runt_o     => qnice_fdd_cnt_runt,
         diag_cnt_lol_o      => qnice_fdd_cnt_lol,
         diag_cnt_drop_o     => qnice_fdd_cnt_drop,
         diag_cap_flags_o    => qnice_fdd_cap_flags,
         diag_cap_count_o    => qnice_fdd_cap_count,
         diag_cap_words_o    => qnice_fdd_cap_words,
         diag_rev_mask_o     => qnice_fdd_rev_mask,
         diag_rev_caps_o     => qnice_fdd_rev_caps,
         diag_rev_lol_o      => qnice_fdd_rev_lol,
         diag_fmt_bad_o      => qnice_fdd_fmt_bad
      ); -- i_physical_fdd_top

   -- diag side-invert into the core domain (quasi-static level; covered by
   -- M2M/common.xdc's cdc_stable constraint) - XORed onto f_side1 above
   i_cdc_hwf_sideinv : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 1,
         G_REGISTER_SRC => false
      )
      port map (
         src_clk_i     => qnice_clk_i,
         src_data_i(0) => qnice_fdd_sideinv,
         dst_clk_i     => main_clk,
         dst_data_o(0) => main_hwf_sideinv
      ); -- i_cdc_hwf_sideinv

   -- QNICE reset into the core domain: the FIFO read-side reset (must derive
   -- from the same event as the write side - Gray-pointer discipline)
   i_cdc_hwf_rst : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 1,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i     => qnice_clk_i,
         src_data_i(0) => qnice_rst_i,
         dst_clk_i     => main_clk,
         dst_data_o(0) => main_qnice_rst
      ); -- i_cdc_hwf_rst

   -- conditioned real drive status into the core domain (slowly varying
   -- mechanical levels; covered by M2M/common.xdc's cdc_stable constraint)
   i_cdc_hwf_status : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 6,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i     => qnice_clk_i,
         src_data_i(0) => qnice_fdd_change_n,
         src_data_i(1) => qnice_fdd_wprot_n,
         src_data_i(2) => qnice_fdd_track0_n,
         src_data_i(3) => qnice_fdd_ready_n,
         src_data_i(4) => qnice_fdd_index,
         src_data_i(5) => qnice_fdd_present,
         dst_clk_i     => main_clk,
         dst_data_o(0) => main_hwf_change_n,
         dst_data_o(1) => main_hwf_wprot_n,
         dst_data_o(2) => main_hwf_track0_n,
         dst_data_o(3) => main_hwf_ready_n,
         dst_data_o(4) => main_hwf_index,
         dst_data_o(5) => main_hwf_present
      ); -- i_cdc_hwf_status

   -- drive map for the diag device, decoded in the QNICE domain (same OSM
   -- bits as the main-domain decode; the diag reads it CDC-free).
   -- Encoding {unit[1:0], enable} of the PHYSICAL drive:
   -- A/B/D have it enabled (df1/df0/df0), C has it off.
   qnice_hwf_map3 <= "001" when qnice_osm_control_i(C_MENU_HWFC_HW_ADF) = '1' else
                     "000" when qnice_osm_control_i(C_MENU_HWFC_ADF_OFF) = '1' else
                     "001" when qnice_osm_control_i(C_MENU_HWFC_HW_OFF) = '1' else
                     "011";                                  -- combo A (default): df1

   i_physical_fdd_diag : entity work.physical_fdd_diag
      port map (
         qnice_addr_i        => qnice_dev_addr_i,
         qnice_data_o        => qnice_fdd_data,
         diag_status_i       => qnice_fdd_status,
         diag_sync_i         => qnice_fdd_sync,
         diag_est_i          => qnice_fdd_est,
         diag_fifo_level_i   => qnice_fdd_level,
         diag_index_period_i => qnice_fdd_idxper,
         diag_index_width_i  => qnice_fdd_idxwid,
         diag_cnt_index_i    => qnice_fdd_cnt_index,
         diag_cnt_sync_i     => qnice_fdd_cnt_sync,
         diag_cnt_word_i     => qnice_fdd_cnt_word,
         diag_cnt_runt_i     => qnice_fdd_cnt_runt,
         diag_cnt_lol_i      => qnice_fdd_cnt_lol,
         diag_cnt_drop_i     => qnice_fdd_cnt_drop,
         diag_map_i          => qnice_hwf_map3,
         diag_cap_flags_i    => qnice_fdd_cap_flags,
         diag_cap_count_i    => qnice_fdd_cap_count,
         diag_cap_words_i    => qnice_fdd_cap_words,
         diag_served_i       => qnice_fdd_served,
         diag_rev_mask_i     => qnice_fdd_rev_mask,
         diag_rev_caps_i     => qnice_fdd_rev_caps,
         diag_rev_lol_i      => qnice_fdd_rev_lol,
         diag_fmt_bad_i      => qnice_fdd_fmt_bad,
         diag_eng_sig_i      => qnice_fdd_eng_sig,
         diag_eng_ses_i      => qnice_fdd_eng_ses,
         diag_eng_done_i     => qnice_fdd_eng_done,
         diag_pau_sig_i      => qnice_fdd_pau_sig,
         diag_pau_att_i      => qnice_fdd_pau_att,
         diag_eng_c64_i      => qnice_fdd_eng_c64,
         diag_eng_c256_i     => qnice_fdd_eng_c256,
         diag_pau_c64_i      => qnice_fdd_pau_c64,
         diag_pau_c256_i     => qnice_fdd_pau_c256,
         diag_pau_tap_i      => qnice_fdd_pau_tap,
         diag_pau_ws_i       => qnice_fdd_pau_ws,
         sideinv_i           => qnice_fdd_sideinv
      ); -- i_physical_fdd_diag

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
