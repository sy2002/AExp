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
   -- (f_motorb/f_selectb) stays tied '1' at the top level; the WRITE pins
   -- f_wdata/f_wgate are driven by physical_fdd_writer since WIP-V2-A9.
   f_wdata_o               : out std_logic;
   f_wgate_o               : out std_logic;
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
-- Simulated ADF drives, one bit / byte per Amiga unit (index 0 = df0)
signal main_adf_mounted           : std_logic_vector(2 downto 0);
signal main_adf_tracks            : std_logic_vector(23 downto 0);  -- 3 x 8 bit, unit u at 8u+7 .. 8u
signal main_adf_writable          : std_logic_vector(2 downto 0);
signal main_adf_dirty             : std_logic_vector(2 downto 0);
signal main_adf_any_dirty         : std_logic;
signal main_adf_wr_track          : std_logic_vector(7 downto 0);
signal main_adf_wr_req            : std_logic_vector(2 downto 0);
signal main_adf_wr_ack            : std_logic_vector(2 downto 0);

-- Drive configuration (main_clk side): the decoded Drive Settings radios,
-- the CIA-B taps from minimig, the conditioned real drive status (CDC'd from
-- the 50 MHz front-end below) and the reconstructed word stream to the engine
signal main_drv_mode              : std_logic_vector(5 downto 0);  -- 2 bits per unit, see C_DRV_*
signal main_drv_count             : std_logic_vector(1 downto 0);  -- number of Amiga units minus one
signal main_drv_map               : std_logic_vector(7 downto 0);  -- {count, mode per unit}
signal main_hwf_en                : std_logic;                     -- physical unit exists
signal main_hwf_unit              : std_logic_vector(1 downto 0);  -- physical unit
signal main_adf_en                : std_logic_vector(2 downto 0);  -- unit is a simulated ADF drive
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
signal main_hwf_serving           : std_logic;                     -- engine phys_stream (read session open)
signal main_hwf_serving_data      : std_logic;                     -- ... and past the serve-start sync
signal main_hwf_obs_legacy        : std_logic;                     -- DSKBYTR obs A/B (diag 0x35 bit 8), qnice->main
-- WIP-V2-A9: the physical WRITE datapath (engine <-> front end)
signal main_hwf_wr_valid          : std_logic;                     -- engine tap pulse
signal main_hwf_wr_data           : std_logic_vector(15 downto 0);
signal main_hwf_wr_session        : std_logic;                     -- episode level
signal main_hwf_selpin_n          : std_logic := '1';              -- mirror of f_selecta_o
signal main_hwf_wr_abort          : std_logic;                     -- abort level
signal main_hwf_wr_precomp        : std_logic;                     -- precomp for the episode
signal main_hwf_wr_track          : std_logic_vector(7 downto 0);  -- episode track
signal main_hwf_wr_level          : unsigned(2 downto 0);          -- write-FIFO occupancy
signal main_hwf_wr_busy           : std_logic;                     -- writer not IDLE (50M->main)
signal main_hwf_wr_ok             : std_logic;                     -- tab qualified (50M->main)
signal main_hwf_precmode          : std_logic_vector(1 downto 0);  -- 0x7C mode (50M->main)
signal main_fdd_step_n            : std_logic := '1';              -- registered mirrors of the f_step /
signal main_fdd_dir               : std_logic := '1';              -- f_stepdir pins for the diag cyl tracker
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

-- ADF mount buffer devices 0x0103 / 0x0105 / 0x0106 (three adf_mount_wrapper
-- instances, index 0 = df0). The dirty-track event carries a per-drive request
-- toggle and a SHARED track payload: the engine serves one event at a time, so
-- the payload is stable for the whole round trip of the selected drive.
type t_adf_byte is array (0 to 2) of std_logic_vector( 7 downto 0);
type t_adf_word is array (0 to 2) of std_logic_vector(15 downto 0);
type t_adf_addr is array (0 to 2) of std_logic_vector(31 downto 0);
type t_adf_be   is array (0 to 2) of std_logic_vector( 1 downto 0);

signal qnice_adf_ce           : std_logic_vector(2 downto 0);
signal qnice_adf_data         : t_adf_word;
signal qnice_adf_wait         : std_logic_vector(2 downto 0);
signal qnice_adf_mounted      : std_logic_vector(2 downto 0);
signal qnice_adf_tracks       : t_adf_byte;
signal qnice_adf_write_en     : std_logic_vector(2 downto 0);
signal qnice_adf_any_dirty    : std_logic_vector(2 downto 0);
signal qnice_adf_wrt_track    : std_logic_vector(7 downto 0);
signal qnice_adf_wrt_req      : std_logic_vector(2 downto 0);
signal qnice_adf_wrt_ack      : std_logic_vector(2 downto 0);

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
-- diag map v7: margin-engine control (reg 0x35), dump nonce, new taps
signal qnice_fdd_ctrl         : std_logic_vector(8 downto 0) := (others => '0');  -- bit 8 = DSKBYTR obs A/B (0x0100)
signal qnice_fdd_dpll_cell    : unsigned(11 downto 0);
-- diag map v10: sync-seam instruments
signal qnice_fdd_realign      : unsigned(15 downto 0);
-- WIP-V2-A9: the write instruments (diag map 0x000D) + the 0x7C register
signal qnice_fdd_precmode     : std_logic_vector(1 downto 0) := "00";
signal qnice_fdd_wr_track     : std_logic_vector(7 downto 0);
signal qnice_fdd_wr_epi       : unsigned(15 downto 0);
signal qnice_fdd_wr_wlast     : unsigned(15 downto 0);
signal qnice_fdd_wr_wtot      : unsigned(15 downto 0);
signal qnice_fdd_wr_glo       : unsigned(15 downto 0);
signal qnice_fdd_wr_ghi       : unsigned(15 downto 0);
signal qnice_fdd_wr_undr      : unsigned(15 downto 0);
signal qnice_fdd_wr_disc      : unsigned(15 downto 0);
signal qnice_fdd_wr_tail      : unsigned(15 downto 0);
signal qnice_fdd_wr_prec      : unsigned(15 downto 0);
signal qnice_fdd_wr_fl79      : std_logic_vector(15 downto 0);
signal qnice_fdd_wr_gopen     : unsigned(15 downto 0);
signal qnice_fdd_wr_reason    : std_logic_vector(7 downto 0);
signal qnice_fdd_wr_ctrl      : std_logic_vector(4 downto 0);
signal qnice_fdd_wr_busy      : std_logic;
signal qnice_fdd_wr_ok        : std_logic;
signal qnice_fdd_wr_ovf       : unsigned(15 downto 0);
signal qnice_fdd_realign_ctx  : std_logic_vector(15 downto 0);
signal qnice_fdd_presync      : t_fdd_cap_words;
signal qnice_fdd_srv_sec      : std_logic_vector(15 downto 0);
signal qnice_fdd_lol_srv      : unsigned(15 downto 0);
signal qnice_fdd_lol_idle     : unsigned(15 downto 0);
signal qnice_fdd_chain_win    : unsigned(15 downto 0);
signal qnice_fdd_frame_stat   : std_logic_vector(3 downto 0);
signal qnice_fdd_clear        : std_logic := '0';              -- 1-cycle strobe (0x35 write, bit 15)
signal qnice_fdd_nonce        : unsigned(15 downto 0) := (others => '0');
signal qnice_fdd_rd0_q        : std_logic := '0';              -- edge filter for the nonce
signal qnice_fdd_uptime       : unsigned(31 downto 0);
signal qnice_fdd_cnt_step     : unsigned(15 downto 0);
signal qnice_fdd_cyl          : unsigned(6 downto 0);
signal qnice_fdd_min_margin   : unsigned(15 downto 0);
signal qnice_fdd_min_est      : unsigned(11 downto 0);
signal qnice_fdd_min_gap      : unsigned(15 downto 0);
signal qnice_fdd_margin_stat  : std_logic_vector(15 downto 0);
signal qnice_fdd_win_opens    : unsigned(15 downto 0);
signal qnice_fdd_gap_count    : unsigned(15 downto 0);
signal qnice_fdd_lol_gate     : unsigned(15 downto 0);
signal qnice_fdd_sync_gate    : unsigned(15 downto 0);
signal qnice_fdd_est_min      : unsigned(11 downto 0);
signal qnice_fdd_est_max      : unsigned(11 downto 0);
signal qnice_fdd_hist         : t_fdd_hist;
signal qnice_fdd_miss         : t_fdd_miss;
signal qnice_fdd_qual_revs    : unsigned(15 downto 0);

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

-- The three ADF mount wrappers' Avalon masters (each wrapper contains its own
-- QNICE->hr CDC), one entry per drive
signal hr_adf_avm_write           : std_logic_vector(2 downto 0);
signal hr_adf_avm_read            : std_logic_vector(2 downto 0);
signal hr_adf_avm_address         : t_adf_addr;
signal hr_adf_avm_writedata       : t_adf_word;
signal hr_adf_avm_byteenable      : t_adf_be;
signal hr_adf_avm_burstcount      : t_adf_byte;
signal hr_adf_avm_readdata        : t_adf_word;
signal hr_adf_avm_readdatavalid   : std_logic_vector(2 downto 0);
signal hr_adf_avm_waitrequest     : std_logic_vector(2 downto 0);

-- flattened arbiter interface (avm_arbit_general uses packed vectors)
signal hr_arb_write               : std_logic_vector(3 downto 0);
signal hr_arb_read                : std_logic_vector(3 downto 0);
signal hr_arb_address             : std_logic_vector(4 * 32 - 1 downto 0);
signal hr_arb_writedata           : std_logic_vector(4 * 16 - 1 downto 0);
signal hr_arb_byteenable          : std_logic_vector(4 *  2 - 1 downto 0);
signal hr_arb_burstcount          : std_logic_vector(4 *  8 - 1 downto 0);
signal hr_arb_readdata            : std_logic_vector(4 * 16 - 1 downto 0);
signal hr_arb_readdatavalid       : std_logic_vector(3 downto 0);
signal hr_arb_waitrequest         : std_logic_vector(3 downto 0);

---------------------------------------------------------------------------------------------
-- On-Screen-Menu bit positions: zero-based line numbers in config.vhd's OPTM_ITEMS
---------------------------------------------------------------------------------------------

-- (the three " dfN:%s" mount items at lines 2/4/6 and the " Drive Settings"
-- submenu head at line 8 are handled by the Shell / firmware and need no
-- C_MENU constant here; their hardware-drive twin lines 3/5/7 are TEXT)
-- ALL C_MENU_* constants below are additionally scraped by
-- CORE/m2m-rom/make_rom.sh into the autogenerated osm_const.asm (as
-- AEXP_OSM_*), so the firmware never hardcodes menu line numbers.
-- Keep them single-line for the awk scraper.
-- The drive block at lines 2..34 shifted every entry below it by 22 lines vs
-- the single-simulated-drive layout.
-- An OCS PAL Amiga is a 50 Hz machine, so only 50 Hz HDMI modes are offered.

-- Drive Settings submenu. Two radios decide the floppy configuration:
--
--   * "Drives" (lines 12..14, line 14 = OPTM_G_STDSEL = three drives) is how
--     many Amiga units exist. Paula latches the drive count at reset and
--     AmigaOS enumerates units at boot, so a change cold-boots the emulated
--     Amiga through amiga_cold_boot.
--   * one mode radio per unit: "Disk Image" (a simulated ADF drive) or
--     "Hardware Floppy" (the MEGA65 internal mechanism, at most one unit) or
--     "Off". df0 always exists and therefore has no Off item; for df1 and df2
--     the Off item is what the Drives radio swaps in (menu dependency), which
--     is also what hides that drive's twin lines in the main menu.
--
-- Decoded below into main_drv_mode (two bits per unit, see C_DRV_*) plus the
-- derived drive count. The firmware keeps these two radios consistent in
-- OSM_SEL_POST; the HDL never has to repair an inconsistent combination, it
-- just decodes what it is given.
constant C_MENU_DRIVES_1      : natural := 13;
constant C_MENU_DRIVES_2      : natural := 14;
constant C_MENU_DRIVES_3      : natural := 15;
constant C_MENU_DF0_IMG       : natural := 19;
constant C_MENU_DF0_HW        : natural := 20;
constant C_MENU_DF1_IMG       : natural := 24;
constant C_MENU_DF1_HW        : natural := 25;
constant C_MENU_DF1_OFF       : natural := 26;
constant C_MENU_DF2_IMG       : natural := 30;
constant C_MENU_DF2_HW        : natural := 31;
constant C_MENU_DF2_OFF       : natural := 32;

-- Flat main-menu indexes of the six twin lines, one pair per drive: the mount
-- line and its "Hardware Floppy" TEXT twin. These carry NO osm_control meaning
-- - the HDL never reads them - they exist so that make_rom.sh can hand the
-- firmware the line numbers it needs (the C64MEGA65 C_MENU_DRV8_1581_LN
-- pattern): HANDLE_UNMOUNT_KEY tests them against OPTM_CUR_SEL to find out
-- which drive the cursor is on, and HANDLE_CORE_IO patches the live hardware
-- status into the TEXT lines. Declaring them here rather than hardcoding them
-- in the firmware is what puts them under the cross-check of
-- .research/check_osm_menu.py, which verifies every C_MENU_* against the TEXT
-- of the line it addresses.
constant C_MENU_DF0_MOUNT_LN  : natural := 2;
constant C_MENU_DF0_HW_LN     : natural := 3;
constant C_MENU_DF1_MOUNT_LN  : natural := 4;
constant C_MENU_DF1_HW_LN     : natural := 5;
constant C_MENU_DF2_MOUNT_LN  : natural := 6;
constant C_MENU_DF2_HW_LN     : natural := 7;

-- per-unit drive mode, two bits each in main_drv_mode (unit u at 2u+1 downto 2u)
constant C_DRV_IMAGE          : std_logic_vector(1 downto 0) := "00";  -- simulated ADF drive
constant C_DRV_HW             : std_logic_vector(1 downto 0) := "01";  -- the MEGA65 mechanism
constant C_DRV_OFF            : std_logic_vector(1 downto 0) := "10";  -- unit does not exist

constant C_MENU_HDMI_16_9_50  : natural := 41;
constant C_MENU_HDMI_4_3_50   : natural := 42;
constant C_MENU_HDMI_5_4_50   : natural := 43;

-- The HDMI Filter radio is read by the firmware only (dispatcher
-- LOAD_HDMI_FILTER with ASCAL_USAGE=1), never by any VHDL: these eight
-- lines exist solely as the scrape source for osm_const.asm.
constant C_MENU_FLT_NO_FILTER     : natural := 49;
constant C_MENU_FLT_SHARP         : natural := 50;
constant C_MENU_FLT_BICUBIC       : natural := 51;
constant C_MENU_FLT_SMOOTH        : natural := 52;
constant C_MENU_FLT_LANCZOS       : natural := 53;
constant C_MENU_FLT_SCANLINES     : natural := 54;
constant C_MENU_FLT_CRT_SVIDEO    : natural := 55;
constant C_MENU_FLT_CRT_COMPOSITE : natural := 56;

-- HDMI flicker-free toggle (issue #12): single-select, default ON, read here in HDL
-- (like the VGA radio) and CDC'd into the hr_clk domain to drive the core-speed FSM.
constant C_MENU_HDMI_FF       : natural := 59;

constant C_MENU_VGA_STD       : natural := 63;   -- VGA: Standard (scandoubled 31.25 kHz); default
constant C_MENU_VGA_15KHZHSVS : natural := 67;   -- VGA: raw 15.625 kHz RGB with separate HS/VS
constant C_MENU_VGA_15KHZCS   : natural := 68;   -- VGA: raw 15.625 kHz RGB with composite sync (SCART)

-- OSM Scaling follows the C64 layout: line 71 (100%, default) maps to bit 0,
-- while line 79 (50%) maps to bit 8 for the framework's first_nonzero_bit decode.
subtype C_MENU_OSM_SCALING is natural range 83 downto 75;

-- Volume radio (master volume, 5% steps): line 88 (100%, default) down to line 108
-- (0% = mute). Decoded below into main_volume (0..20 step index) and applied in
-- main.vhd as a perceptual Q15 attenuation (C_VOL_LUT) on the final Paula mix,
-- ahead of the framework's split into the HDMI and analog audio paths.
subtype C_MENU_VOLUME is natural range 112 downto 92;

-- Stereo crossfeed radio ("Stereo: %s" submenu): line 114 (Full Stereo, default)
-- down to line 117 (Mono). Decoded below into main_stereo_mix using MiSTer's
-- aud_mix encoding (00 = full separation, 01 = 87.5%/12.5%, 10 = 75%/25%,
-- 11 = mono) and applied in main.vhd's audio_filters ahead of the master volume.
subtype C_MENU_STEREO is natural range 121 downto 118;

-- Paula output filters (MiSTer Minimig.sv parity), both single-select toggles
-- with OPTM_G_STDSEL = default ON. A500 Filter inserts the fixed 4400 Hz
-- low-pass behind Paula's DAC ('0' = brighter A1200-style output stage); LED
-- Filter arms the switchable 3 kHz low-pass on CIA-A PA1, which then follows
-- the emulated power LED live (MiSTer's "Auto(LED)"). Both are static OSM bits
-- wired straight into main.vhd like the keyboard/VGA bits.
constant C_MENU_A500FILT      : natural := 124;
constant C_MENU_LEDFILT       : natural := 125;

-- Keyboard mapping mode radio (issue #6): '1' = Amiga (pure positional), '0' = MEGA65
-- (semantic "cap is law"; default). Read here in HDL and wired straight into
-- keyboard.vhd via main.vhd, exactly like the VGA/flicker-free bits. Line 126 (MEGA65)
-- carries OPTM_G_STDSEL, so this Amiga bit is 0 at power-up.
constant C_MENU_KBD_AMIGA     : natural := 129;

-- OSM-open key radio (issue #8): selects which key(s) drive the framework's
-- menu-open bit (qnice_keys bit 7). Decoded below into m2m_keyb's osm_key_a/b +
-- combo inputs and threaded core->framework->m2m_keyb, so the firmware stays
-- byte-identical (bit 7 keeps its "the menu key" meaning). Line 134 (Help) carries
-- OPTM_G_STDSEL = the classic default. MEGA+Run/Stop is a two-key combo.
constant C_MENU_OSMKEY_HELP   : natural := 134;
constant C_MENU_OSMKEY_F11    : natural := 135;
constant C_MENU_OSMKEY_F13    : natural := 136;
constant C_MENU_OSMKEY_COMBO  : natural := 137;

-- Slow RAM (A501) toggle (issue #20): single-select, default ON. '1' = the classic
-- 512 KB trapdoor expansion at $C00000 is present, '0' = chip-RAM-only A500.
-- Wired into main.vhd -> amiga_config.vhd, which encodes it in the userio memory
-- config (command 0xF5). amiga_cold_boot detects a change, invalidates Kickstart's
-- warm-boot state and resets only the emulated Amiga; QNICE keeps running.
constant C_MENU_SLOWRAM       : natural := 141;

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
   main_drive_led_o     <= main_fdd_led or main_adf_any_dirty;
   main_drive_led_col_o <= x"FFFF00" when main_adf_any_dirty = '1' else x"00FF00";

   -- "unflushed writes exist" is the OR across all simulated drives: the LED
   -- must stay yellow until the last drive is clean
   main_adf_any_dirty   <= '1' when main_adf_dirty /= "000" else '0';

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

   -- Drive Settings decode. Each Amiga unit gets a two-bit mode; the drive
   -- count comes from the Drives radio and is clamped so that a unit which the
   -- count does not cover is Off no matter what its own radio says (the
   -- firmware enforces the same thing in the menu, this is the belt).
   -- Fall-through defaults reproduce the OPTM_G_STDSEL lines, so the core
   -- behaves per the standard configuration while QNICE is still booting.
   drv_decode : process (main_osm_control_i)
      variable v_count : natural range 1 to 3;
      variable v_mode  : std_logic_vector(1 downto 0);
      variable v_phys  : std_logic;
   begin
      if main_osm_control_i(C_MENU_DRIVES_1) = '1' then
         v_count := 1;
      elsif main_osm_control_i(C_MENU_DRIVES_2) = '1' then
         v_count := 2;
      else
         v_count := 3;                                      -- OPTM_G_STDSEL default
      end if;
      main_drv_count <= std_logic_vector(to_unsigned(v_count - 1, 2));

      main_hwf_en   <= '0';
      main_hwf_unit <= "00";
      v_phys        := '0';

      for u in 0 to 2 loop
         if u = 0 then
            if main_osm_control_i(C_MENU_DF0_HW) = '1' then
               v_mode := C_DRV_HW;
            else
               v_mode := C_DRV_IMAGE;                       -- OPTM_G_STDSEL default
            end if;
         elsif u = 1 then
            if main_osm_control_i(C_MENU_DF1_OFF) = '1' then
               v_mode := C_DRV_OFF;
            elsif main_osm_control_i(C_MENU_DF1_HW) = '1' then
               v_mode := C_DRV_HW;
            else
               v_mode := C_DRV_IMAGE;                       -- OPTM_G_STDSEL default
            end if;
         else
            if main_osm_control_i(C_MENU_DF2_OFF) = '1' then
               v_mode := C_DRV_OFF;
            elsif main_osm_control_i(C_MENU_DF2_IMG) = '1' then
               v_mode := C_DRV_IMAGE;
            else
               v_mode := C_DRV_HW;                          -- OPTM_G_STDSEL default
            end if;
         end if;

         if u >= v_count then
            v_mode := C_DRV_OFF;                            -- beyond the drive count
         end if;

         -- only one physical mechanism exists: the lowest unit asking for it wins
         if v_mode = C_DRV_HW then
            if v_phys = '1' then
               v_mode := C_DRV_IMAGE;
            else
               v_phys        := '1';
               main_hwf_en   <= '1';
               main_hwf_unit <= std_logic_vector(to_unsigned(u, 2));
            end if;
         end if;

         main_drv_mode(2 * u + 1 downto 2 * u) <= v_mode;
         if v_mode = C_DRV_IMAGE then
            main_adf_en(u) <= '1';
         else
            main_adf_en(u) <= '0';
         end if;
      end loop;
   end process drv_decode;

   -- what the cold-boot controller watches: the complete floppy topology
   main_drv_map <= main_drv_count & main_drv_mode;

   -- Memory topology is guest state, so changing it must be a cold boot from
   -- Kickstart's perspective; the Hardware Floppy drive map is treated the
   -- same way (drive count is reset-latched in Paula, units are enumerated at
   -- boot). This local controller deliberately does not drive either M2M
   -- reset: the menu, QNICE and the framework remain alive.
   i_amiga_cold_boot : entity work.amiga_cold_boot
      port map (
         clk_i             => main_clk,
         slow_ram_i        => main_osm_control_i(C_MENU_SLOWRAM),
         drv_map_i         => main_drv_map,
         amiga_reset_o     => amiga_cold_reset,
         chip_scrub_o      => amiga_chip_scrub,
         chip_scrub_addr_o => amiga_chip_scrub_addr
      ); -- i_amiga_cold_boot

   -- main.vhd contains the actual MiSTer core
   i_main : entity work.main
      generic map (
         G_VDNUM              => C_VDNUM,
         G_ADF_BASE_DF0       => C_HMAP_ADF_DF0(9 downto 0) & x"000",
         G_ADF_BASE_DF1       => C_HMAP_ADF_DF1(9 downto 0) & x"000",
         G_ADF_BASE_DF2       => C_HMAP_ADF_DF2(9 downto 0) & x"000"
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

         -- Simulated ADF drives: per-unit mount status, write-back arming,
         -- dirty-track events and the shared HyperRAM read/write port
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

         -- Floppy configuration, plus the Hardware Floppy CIA-B taps,
         -- conditioned real drive status and reconstructed word stream
         -- (front-end below)
         drv_count_i          => main_drv_count,
         hwf_adf_en_i         => main_adf_en,
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
         hwf_serving_o        => main_hwf_serving,
         hwf_serving_data_o   => main_hwf_serving_data,
         hwf_pau_sig_o        => main_hwf_pau_sig,
         hwf_pau_att_o        => main_hwf_pau_att,
         hwf_pau_c64_o        => main_hwf_pau_c64,
         hwf_pau_c256_o       => main_hwf_pau_c256,
         hwf_pau_tap_o        => main_hwf_pau_tap,
         hwf_pau_ws_o         => main_hwf_pau_ws,
         hwf_obs_legacy_i     => main_hwf_obs_legacy,
         hwf_wr_valid_o       => main_hwf_wr_valid,
         hwf_wr_data_o        => main_hwf_wr_data,
         hwf_wr_session_o     => main_hwf_wr_session,
         hwf_wr_abort_o       => main_hwf_wr_abort,
         hwf_wr_precomp_o     => main_hwf_wr_precomp,
         hwf_wr_track_o       => main_hwf_wr_track,
         hwf_wr_level_i       => main_hwf_wr_level,
         hwf_wr_busy_i        => main_hwf_wr_busy,
         hwf_wr_ok_i          => main_hwf_wr_ok,
         hwf_selected_i       => main_hwf_selected,
         hwf_wr_precmode_i    => main_hwf_precmode,

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
   --   0x0103  C_DEV_AMIGA_ADF0  df0 ADF mount buffer in HyperRAM + CSR window 0xFFFF
   --           (adf_mount_wrapper packs its own byte order - byte address bit 0
   --           selects the HyperRAM word's LOW byte lane for EVEN addresses)
   --   0x0104  C_DEV_AMIGA_FDD   Hardware Floppy diagnostics (read-only bank)
   --   0x0105  C_DEV_AMIGA_ADF1  df1 ADF mount buffer
   --   0x0106  C_DEV_AMIGA_ADF2  df2 ADF mount buffer
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
      qnice_adf_ce     <= "000";

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
            qnice_adf_ce(0)  <= qnice_dev_ce_i;
            qnice_dev_data_o <= qnice_adf_data(0);
            qnice_dev_wait_o <= qnice_adf_wait(0);

         when C_DEV_AMIGA_ADF1 =>
            qnice_adf_ce(1)  <= qnice_dev_ce_i;
            qnice_dev_data_o <= qnice_adf_data(1);
            qnice_dev_wait_o <= qnice_adf_wait(1);

         when C_DEV_AMIGA_ADF2 =>
            qnice_adf_ce(2)  <= qnice_dev_ce_i;
            qnice_dev_data_o <= qnice_adf_data(2);
            qnice_dev_wait_o <= qnice_adf_wait(2);

         -- Hardware Floppy diagnostics: registered readout (the diag bank
         -- latches the addressed word on the falling edge and this arm sees
         -- a plain flip-flop - zero wait states, kick-ROM-identical bus
         -- timing; the writable registers 0x1F and 0x35 live in the
         -- process below)
         when C_DEV_AMIGA_FDD =>
            qnice_dev_data_o <= qnice_fdd_data;

         when others => null;
      end case;
   end process core_specific_devices;

   -- Hardware Floppy diag write registers + dump nonce (all on the falling
   -- edge, the M2M device-write convention; the front-end's rising-edge
   -- processes sample these half a 50 MHz cycle later - the same relation
   -- every QNICE MMIO register in this design already relies on):
   --   0x1F bit 0 = side-invert, XORed onto the f_side1 pin (hwf_pins_proc)
   --        for the empirical side-polarity verdict - flip it live from the
   --        QNICE debug console, no rebuild. Round 3 proved the straight
   --        wire correct on this mechanism: keep it 0.
   --   0x35 = margin-engine control {7: realign-ALWAYS word framing
   --        instead of the WORDSYNC-conditional framing hold (reset
   --        default 0 = hold in force - the sync-seam A/B switch), 6:
   --        LEGACY quantiser bit source instead of the DPLL data
   --        separator (reset default 0 = DPLL -
   --        the A/B switch), 5: all-gaps, 4: window mode, 3..0: armed
   --        sector}; writing bit 15 additionally pulses the
   --        experiment-clear strobe (strobe is not stored).
   --   The nonce counts QNICE READS of diag register 0x00 (one per dump;
   --        the firmware's live-status poll reads only 0x02/0x1B, so tester
   --        dumps are the only thing that advances it). Edge-filtered so a
   --        multi-cycle bus access counts once.
   fdd_diag_wr_proc : process (qnice_clk_i)
      variable v_rd0 : std_logic;
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_rst_i = '1' then
            qnice_fdd_sideinv  <= '0';
            qnice_fdd_ctrl     <= (others => '0');
            qnice_fdd_precmode <= "00";
            qnice_fdd_clear   <= '0';
            qnice_fdd_nonce   <= (others => '0');
            qnice_fdd_rd0_q   <= '0';
         else
            qnice_fdd_clear <= '0';
            if qnice_dev_ce_i = '1' and qnice_dev_we_i = '1' and
               qnice_dev_id_i = C_DEV_AMIGA_FDD then
               if qnice_dev_addr_i(6 downto 0) = "0011111" then      -- 0x1F
                  qnice_fdd_sideinv <= qnice_dev_data_i(0);
               elsif qnice_dev_addr_i(6 downto 0) = "1111100" then   -- 0x7C
                  -- WIP-V2-A9 WRITE control: {1:0} precomp mode
                  -- (00/11 = AUTO per the KS1.3 track >= 81 policy,
                  -- 01 = ON, 10 = OFF). Reset default 00 = AUTO.
                  qnice_fdd_precmode <= qnice_dev_data_i(1 downto 0);
               elsif qnice_dev_addr_i(6 downto 0) = "0110101" then   -- 0x35
                  -- 9 control bits: [7:0] margin/separator/framing control
                  -- (see physical_fdd_diag.vhd 0x35), bit 8 = DSKBYTR obs
                  -- surface A/B (1 = disable = revert to the A7 stub)
                  qnice_fdd_ctrl  <= qnice_dev_data_i(8 downto 0);
                  qnice_fdd_clear <= qnice_dev_data_i(15);
               end if;
            end if;

            v_rd0 := '0';
            if qnice_dev_ce_i = '1' and qnice_dev_we_i = '0' and
               qnice_dev_id_i = C_DEV_AMIGA_FDD and
               qnice_dev_addr_i(6 downto 0) = "0000000" then
               v_rd0 := '1';
            end if;
            if v_rd0 = '1' and qnice_fdd_rd0_q = '0' then
               qnice_fdd_nonce <= qnice_fdd_nonce + 1;
            end if;
            qnice_fdd_rd0_q <= v_rd0;
         end if;
      end if;
   end process fdd_diag_wr_proc;

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
            -- main_hwf_ctrl bits 6..3 are _sel3.._sel0, so the select line of
            -- unit u sits at bit 3 + u. df2 is the DEFAULT hardware unit, so
            -- getting this wrong leaves the real drive completely unselected.
            v_sel_n := main_hwf_ctrl(3 + to_integer(unsigned(main_hwf_unit)));
            f_motora_o  <= not main_hwf_motor_on(to_integer(unsigned(main_hwf_unit)));
            main_fdd_dir <= main_hwf_ctrl(1);
            if v_sel_n = '0' then
               main_fdd_step_n <= main_hwf_ctrl(0);
            else
               main_fdd_step_n <= '1';
            end if;
            main_hwf_selected <= not v_sel_n;

            f_stepdir_o <= main_hwf_ctrl(1);                 -- direc: '1' = toward track 0
            if v_sel_n = '0' then
               f_step_o <= main_hwf_ctrl(0);
            else
               f_step_o <= '1';
            end if;

            -- WIP-V2-A9 round 2: THE POST-DSKBLK PIN HOLD, SELECT AND SIDE
            -- ONLY. Paula reports the write complete when the ENGINE takes
            -- the last word out of its FIFO, so at that instant our CDC FIFO
            -- and the writer's shifter still owe ~3 word times of flux; a
            -- real Paula owes ONE, its own output shifter. X-Copy sizes its
            -- margin for a real Paula - a single trailing $AAAA word - and
            -- toggles SIDE about 30 us after DSKBLK. Letting that reach the
            -- pin lays the tail on the WRONG SURFACE; refusing to write it
            -- destroyed sector 10's last word on every upper-side track
            -- (measured: 85 bytes of 901,120, all sector 10, all head 1).
            --
            -- The two pins are held for DIFFERENT reasons and neither is
            -- redundant. SIDE: a mechanism switches heads the moment /SIDE1
            -- moves, so without this the tail lands on the other surface.
            -- SELECT: a mechanism gates its write circuitry on /SELn, so a
            -- deselected drive IGNORES WGATE and the tail is lost anyway -
            -- silently, with no abort and no tail-cut tick.
            --
            -- STEP AND DIR ARE DELIBERATELY *NOT* HELD. STEP is a PULSE, and
            -- nothing here latches or replays one, so a pulse that began and
            -- ended inside a hold would be DESTROYED rather than delayed -
            -- the host would advance its cylinder counter while the head
            -- stayed put, and every later access would silently go to the
            -- wrong cylinder. Holding it would also buy nothing: the
            -- writer's STEP abort term is left live and unqualified and
            -- closes WGATE in the same cycle, in tens of nanoseconds, while
            -- a head needs milliseconds to move.
            --
            -- SCOPE: the DRAIN only - the writer is still busy but the host
            -- has already been told the write finished. NOT the whole
            -- episode: during the DMA the host is blocked waiting for
            -- DSKBLK, and gating on busy alone would freeze the pins for the
            -- ~207 ms of a full track, for the remainder of a tab-blocked or
            -- aborted episode, and - because a held reset leaves the episode
            -- latched (adf_track_engine 'does NOT clear the episode itself')
            -- - across a reset, right where trackdisk recalibrates with a
            -- burst of steps. Keying on the drain makes all three impossible:
            -- a stuck episode keeps wr_session HIGH, so the hold never
            -- engages at all.
            --
            -- The window is the pipe depth, <= ~104 us, far inside X-Copy's
            -- own 253 us post-side settle and trackdisk's 2000 us
            -- post-DSKBLK wait. It is a strict SUPERSET of the writer's own
            -- v_hold: wr_session is native to this domain and falls first,
            -- while wr_busy returns through a cdc_stable and falls last.
            -- Note wr_session falls when the ENGINE OBSERVES the DMA end
            -- (dmaen clear and Paula's FIFO empty), which is one poll frame
            -- after DSKBLK itself, so the honest guard band against X-Copy's
            -- ~30 us side toggle is ~25 us, not the full 30.
            --
            -- HOLD ONLY AN *ASSERTED* SELECT. Freezing a DESELECTED value
            -- protects nothing - there is no flux in flight to protect, and
            -- every route that reaches the guard deselected has the gate
            -- already shut (a tab-blocked DISCARD, an episode aborted
            -- mid-stream, or a deselect inside the DSKBLK-to-observation
            -- gap). It can only do harm: a mechanism qualifies STEP by
            -- /SELn, so a drive pinned deselected IGNORES a step pulse that
            -- reaches its pin, and the head silently stays behind the host's
            -- cylinder counter - the same failure class that took STEP out
            -- of this freeze in the first place.
            --
            -- Only the PINS are held. main_hwf_selected, main_fdd_step_n and
            -- main_fdd_dir keep following the live Amiga values, because the
            -- engine's episode-bind qualifier (spec 9a) and the diagnostics
            -- must keep describing what the host is doing.
            --
            -- Holding SELECT asserted past a host deselect is safe on this
            -- board because there is exactly ONE physical drive on the
            -- cable: f_selectb/f_motorb stay tied inactive (M2M exception 7),
            -- so no second mechanism can contend for the shared open-
            -- collector status lines.
            if not (main_hwf_wr_busy = '1' and main_hwf_wr_session = '0'
                    and main_hwf_selpin_n = '0') then
               f_selecta_o       <= v_sel_n;
               main_hwf_selpin_n <= v_sel_n;
               f_side1_o         <= main_hwf_ctrl(2) xor main_hwf_sideinv;
            end if;
         else
            f_selecta_o       <= '1';
            main_hwf_selpin_n <= '1';
            f_motora_o        <= '1';
            f_side1_o         <= '1';
            f_stepdir_o       <= '1';
            f_step_o          <= '1';
            main_fdd_step_n   <= '1';
            main_fdd_dir      <= '1';
            main_hwf_selected <= '0';
         end if;
         f_density_o <= '1';                                 -- DD-safe level, always
      end if;
   end process hwf_pins_proc;

   main_hwf_motor <= main_hwf_motor_on(to_integer(unsigned(main_hwf_unit)));

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
         f_wdata_o           => f_wdata_o,
         f_wgate_o           => f_wgate_o,
         enable_i            => main_hwf_en,
         selected_i          => main_hwf_selected,
         motor_i             => main_hwf_motor,
         side_i              => main_hwf_ctrl(2),
         dsksync_i           => main_hwf_dsksync,
         step_n_i            => main_fdd_step_n,
         stepdir_i           => main_fdd_dir,
         serving_i           => main_hwf_serving,
         serving_data_i      => main_hwf_serving_data,
         wordsync_i          => main_hwf_pau_ws,
         ctrl_i              => qnice_fdd_ctrl(5 downto 0),
         clear_i             => qnice_fdd_clear,
         dpll_dis_i          => qnice_fdd_ctrl(6),
         framehold_dis_i     => qnice_fdd_ctrl(7),
         track0_n_o          => qnice_fdd_track0_n,
         wprot_n_o           => qnice_fdd_wprot_n,
         change_n_o          => qnice_fdd_change_n,
         ready_n_o           => qnice_fdd_ready_n,
         index_o             => qnice_fdd_index,
         present_o           => qnice_fdd_present,
         -- WIP-V2-A9: the write path. The tap and the level are plain
         -- core-domain wires (ready is computed engine-side, so nothing
         -- crosses); the episode levels cross inside the writer.
         wr_push_i           => main_hwf_wr_valid,
         wr_data_i           => main_hwf_wr_data,
         wr_level_o          => main_hwf_wr_level,
         wr_session_i        => main_hwf_wr_session,
         wr_abort_i          => main_hwf_wr_abort,
         wr_precomp_i        => main_hwf_wr_precomp,
         wr_track_i          => qnice_fdd_wr_track,
         wr_precmode_i       => qnice_fdd_precmode,
         wr_busy_o           => qnice_fdd_wr_busy,
         wr_ok_o             => qnice_fdd_wr_ok,
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
         diag_fmt_bad_o      => qnice_fdd_fmt_bad,
         diag_uptime_o       => qnice_fdd_uptime,
         diag_cnt_step_o     => qnice_fdd_cnt_step,
         diag_cyl_o          => qnice_fdd_cyl,
         diag_min_margin_o   => qnice_fdd_min_margin,
         diag_min_est_o      => qnice_fdd_min_est,
         diag_min_gap_o      => qnice_fdd_min_gap,
         diag_margin_stat_o  => qnice_fdd_margin_stat,
         diag_win_opens_o    => qnice_fdd_win_opens,
         diag_gap_count_o    => qnice_fdd_gap_count,
         diag_lol_gate_o     => qnice_fdd_lol_gate,
         diag_sync_gate_o    => qnice_fdd_sync_gate,
         diag_est_min_o      => qnice_fdd_est_min,
         diag_est_max_o      => qnice_fdd_est_max,
         diag_hist_o         => qnice_fdd_hist,
         diag_miss_o         => qnice_fdd_miss,
         diag_qual_revs_o    => qnice_fdd_qual_revs,
         diag_dpll_cell_o    => qnice_fdd_dpll_cell,
         diag_realign_o      => qnice_fdd_realign,
         diag_realign_ctx_o  => qnice_fdd_realign_ctx,
         diag_presync_o      => qnice_fdd_presync,
         diag_srv_sec_o      => qnice_fdd_srv_sec,
         diag_lol_srv_o      => qnice_fdd_lol_srv,
         diag_lol_idle_o     => qnice_fdd_lol_idle,
         diag_chain_win_o    => qnice_fdd_chain_win,
         diag_frame_stat_o   => qnice_fdd_frame_stat,
         dwr_epi_cnt_o       => qnice_fdd_wr_epi,
         dwr_words_last_o    => qnice_fdd_wr_wlast,
         dwr_words_tot_o     => qnice_fdd_wr_wtot,
         dwr_wgate_lo_o      => qnice_fdd_wr_glo,
         dwr_wgate_hi_o      => qnice_fdd_wr_ghi,
         dwr_underrun_o      => qnice_fdd_wr_undr,
         dwr_discard_o       => qnice_fdd_wr_disc,
         dwr_tail_o          => qnice_fdd_wr_tail,
         dwr_precomp_cnt_o   => qnice_fdd_wr_prec,
         dwr_flags79_o       => qnice_fdd_wr_fl79,
         dwr_gateopen_o      => qnice_fdd_wr_gopen,
         dwr_abortreason_o   => qnice_fdd_wr_reason,
         dwr_ctrl7c_o        => qnice_fdd_wr_ctrl,
         dwr_overflow_o      => qnice_fdd_wr_ovf
      ); -- i_physical_fdd_top

   -- DSKBYTR observation-surface A/B bit (diag 0x35 bit 8) into the core
   -- domain (quasi-static level; covered by M2M/common.xdc's cdc_stable
   -- constraint) - reverts Paula's Copylock DSKBYTR to the A7 stub when set
   i_cdc_hwf_obs_leg : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 1,
         G_REGISTER_SRC => false
      )
      port map (
         src_clk_i     => qnice_clk_i,
         src_data_i(0) => qnice_fdd_ctrl(8),
         dst_clk_i     => main_clk,
         dst_data_o(0) => main_hwf_obs_legacy
      ); -- i_cdc_hwf_obs_leg

   -- WIP-V2-A9 CDC. Three quasi-static crossings, all cdc_stable (the
   -- blanket qnice<->main max_delay pair in CORE/CORE.xdc bounds them):
   --   * the writer's status levels 50 MHz -> core (the engine's busy
   --     interlock and the announce's writable bit),
   --   * the 0x7C precomp mode 50 MHz -> core (the engine decides precomp
   --     at the episode bind, so no multi-bit track value has to cross),
   --   * the episode's track core -> 50 MHz for the 0x79 readout.
   i_cdc_hwf_wr_stat : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 4,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i              => qnice_clk_i,
         src_data_i(0)          => qnice_fdd_wr_busy,
         src_data_i(1)          => qnice_fdd_wr_ok,
         src_data_i(3 downto 2) => qnice_fdd_precmode,
         dst_clk_i              => main_clk,
         dst_data_o(0)          => main_hwf_wr_busy,
         dst_data_o(1)          => main_hwf_wr_ok,
         dst_data_o(3 downto 2) => main_hwf_precmode
      ); -- i_cdc_hwf_wr_stat

   i_cdc_hwf_wr_track : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 8,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i  => main_clk,
         src_data_i => main_hwf_wr_track,
         dst_clk_i  => qnice_clk_i,
         dst_data_o => qnice_fdd_wr_track
      ); -- i_cdc_hwf_wr_track

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

   -- drive map for the diag device, decoded in the QNICE domain (same OSM bits
   -- and the same rules as drv_decode above; the diag reads it CDC-free).
   -- Encoding {unit[1:0], enable} of the PHYSICAL drive: the lowest unit whose
   -- mode radio says "Hardware Floppy" and that the drive count still covers.
   qnice_hwf_map3_decode : process (qnice_osm_control_i)
      variable v_count : natural range 1 to 3;
      variable v_hw    : boolean;
   begin
      if qnice_osm_control_i(C_MENU_DRIVES_1) = '1' then
         v_count := 1;
      elsif qnice_osm_control_i(C_MENU_DRIVES_2) = '1' then
         v_count := 2;
      else
         v_count := 3;
      end if;

      qnice_hwf_map3 <= "000";                               -- no physical unit
      for u in 2 downto 0 loop
         if u = 0 then
            v_hw := qnice_osm_control_i(C_MENU_DF0_HW) = '1';
         elsif u = 1 then
            v_hw := qnice_osm_control_i(C_MENU_DF1_HW) = '1';
         else
            -- df2 defaults to Hardware Floppy (OPTM_G_STDSEL), so "neither of
            -- the other two items" is the default state while QNICE boots
            v_hw := qnice_osm_control_i(C_MENU_DF2_IMG) = '0' and
                    qnice_osm_control_i(C_MENU_DF2_OFF) = '0';
         end if;
         if v_hw and u < v_count then
            qnice_hwf_map3 <= std_logic_vector(to_unsigned(u, 2)) & '1';
         end if;
      end loop;
   end process qnice_hwf_map3_decode;

   i_physical_fdd_diag : entity work.physical_fdd_diag
      port map (
         qnice_clk_i         => qnice_clk_i,
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
         sideinv_i           => qnice_fdd_sideinv,
         diag_uptime_i       => qnice_fdd_uptime,
         diag_nonce_i        => qnice_fdd_nonce,
         diag_cnt_step_i     => qnice_fdd_cnt_step,
         diag_cyl_i          => qnice_fdd_cyl,
         diag_ctrl_i         => qnice_fdd_ctrl(7 downto 0),
         diag_min_margin_i   => qnice_fdd_min_margin,
         diag_min_est_i      => qnice_fdd_min_est,
         diag_min_gap_i      => qnice_fdd_min_gap,
         diag_margin_stat_i  => qnice_fdd_margin_stat,
         diag_win_opens_i    => qnice_fdd_win_opens,
         diag_gap_count_i    => qnice_fdd_gap_count,
         diag_lol_gate_i     => qnice_fdd_lol_gate,
         diag_sync_gate_i    => qnice_fdd_sync_gate,
         diag_est_min_i      => qnice_fdd_est_min,
         diag_est_max_i      => qnice_fdd_est_max,
         diag_hist_i         => qnice_fdd_hist,
         diag_miss_i         => qnice_fdd_miss,
         diag_qual_revs_i    => qnice_fdd_qual_revs,
         diag_dpll_cell_i    => qnice_fdd_dpll_cell,
         diag_realign_i      => qnice_fdd_realign,
         diag_realign_ctx_i  => qnice_fdd_realign_ctx,
         diag_presync_i      => qnice_fdd_presync,
         diag_srv_sec_i      => qnice_fdd_srv_sec,
         diag_lol_srv_i      => qnice_fdd_lol_srv,
         diag_lol_idle_i     => qnice_fdd_lol_idle,
         diag_chain_win_i    => qnice_fdd_chain_win,
         diag_frame_stat_i   => qnice_fdd_frame_stat,
         dwr_epi_cnt_i       => qnice_fdd_wr_epi,
         dwr_words_last_i    => qnice_fdd_wr_wlast,
         dwr_words_tot_i     => qnice_fdd_wr_wtot,
         dwr_wgate_lo_i      => qnice_fdd_wr_glo,
         dwr_wgate_hi_i      => qnice_fdd_wr_ghi,
         dwr_underrun_i      => qnice_fdd_wr_undr,
         dwr_discard_i       => qnice_fdd_wr_disc,
         dwr_tail_i          => qnice_fdd_wr_tail,
         dwr_precomp_cnt_i   => qnice_fdd_wr_prec,
         dwr_flags79_i       => qnice_fdd_wr_fl79,
         dwr_gateopen_i      => qnice_fdd_wr_gopen,
         dwr_abortreason_i   => qnice_fdd_wr_reason,
         dwr_ctrl7c_i        => qnice_fdd_wr_ctrl,
         dwr_overflow_i      => qnice_fdd_wr_ovf
      ); -- i_physical_fdd_diag

   ---------------------------------------------------------------------------------------------
   -- ADF floppy: HyperRAM plumbing
   --
   -- Four Avalon masters share the framework's hr_core_* port (100 MHz hr_clk):
   --   * one mount wrapper per simulated drive (QNICE devices 0x0103 / 0x0105 /
   --     0x0106): the Shell streams an ADF into that drive's HyperRAM pool at
   --     load time; each wrapper contains its own QNICE->hr avm_fifo CDC
   --   * the track engine's read/write chain from main.vhd (post avm_cache),
   --     crossed main->hr by the avm_fifo below
   -- Pattern and generics follow C64MEGA65 (REU + mount buffer chains).
   --
   -- Elaboration-time guards for the HyperRAM map in globals.vhd: the drive
   -- pools must start above the framework/ascal region, each pool must hold a
   -- maximum-size ADF, and the pools must be ordered and guarded.
   ---------------------------------------------------------------------------------------------

   assert C_ADF_POOL_BYTES >= C_ADF_MAX_SIZE
      report "HyperRAM: an ADF pool is smaller than the largest accepted image"
      severity failure;

   assert unsigned(C_HMAP_ADF_DF0) >= 256
      report "HyperRAM: the df0 pool overlaps the 2 MB ascal framebuffer"
      severity failure;

   assert unsigned(C_HMAP_ADF_DF0_GUARD) < unsigned(C_HMAP_ADF_DF1) and
          unsigned(C_HMAP_ADF_DF1_GUARD) < unsigned(C_HMAP_ADF_DF2) and
          unsigned(C_HMAP_ADF_DF2_GUARD) < unsigned(C_HMAP_TOP_GUARD) and
          unsigned(C_HMAP_TOP_GUARD)     < unsigned(C_HMAP_SIZE)
      report "HyperRAM: the drive pools are not ordered and guarded"
      severity failure;

   gen_adf_wrapper : for u in 0 to 2 generate
      constant C_POOL : std_logic_vector(15 downto 0) := C_HMAP_ADF_POOLS(u);
   begin
      i_adf_mount_wrapper : entity work.adf_mount_wrapper
         generic map (
            G_BASE_ADDRESS => C_POOL(9 downto 0) & x"000"
         )
         port map (
            qnice_clk_i          => qnice_clk_i,
            qnice_rst_i          => qnice_rst_i,
            qnice_addr_i         => qnice_dev_addr_i,
            qnice_data_i         => qnice_dev_data_i,
            qnice_ce_i           => qnice_adf_ce(u),
            qnice_we_i           => qnice_dev_we_i,
            qnice_data_o         => qnice_adf_data(u),
            qnice_wait_o         => qnice_adf_wait(u),

            qnice_disk_mounted_o => qnice_adf_mounted(u),
            qnice_disk_tracks_o  => qnice_adf_tracks(u),

            qnice_write_en_o     => qnice_adf_write_en(u),
            qnice_any_dirty_o    => qnice_adf_any_dirty(u),
            qnice_wrt_track_i    => qnice_adf_wrt_track,
            qnice_wrt_req_i      => qnice_adf_wrt_req(u),
            qnice_wrt_ack_o      => qnice_adf_wrt_ack(u),

            hr_clk_i             => hr_clk_i,
            hr_rst_i             => hr_rst_i,
            hr_write_o           => hr_adf_avm_write(u),
            hr_read_o            => hr_adf_avm_read(u),
            hr_address_o         => hr_adf_avm_address(u),
            hr_writedata_o       => hr_adf_avm_writedata(u),
            hr_byteenable_o      => hr_adf_avm_byteenable(u),
            hr_burstcount_o      => hr_adf_avm_burstcount(u),
            hr_readdata_i        => hr_adf_avm_readdata(u),
            hr_readdatavalid_i   => hr_adf_avm_readdatavalid(u),
            hr_waitrequest_i     => hr_adf_avm_waitrequest(u)
         ); -- i_adf_mount_wrapper
   end generate gen_adf_wrapper;

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

   -- mount + write-back status of all three drives into the core clock domain
   -- (slowly varying flags + track counts; covered by M2M/common.xdc's
   -- cdc_stable constraint). One instance for all drives: the drives are
   -- independent, so a per-bit settling skew between them is harmless.
   i_cdc_adf_mount : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 33,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i                 => qnice_clk_i,
         src_data_i( 7 downto  0)  => qnice_adf_tracks(0),
         src_data_i(15 downto  8)  => qnice_adf_tracks(1),
         src_data_i(23 downto 16)  => qnice_adf_tracks(2),
         src_data_i(26 downto 24)  => qnice_adf_mounted,
         src_data_i(29 downto 27)  => qnice_adf_write_en,
         src_data_i(32 downto 30)  => qnice_adf_any_dirty,
         dst_clk_i                 => main_clk,
         dst_data_o(23 downto  0)  => main_adf_tracks,
         dst_data_o(26 downto 24)  => main_adf_mounted,
         dst_data_o(29 downto 27)  => main_adf_writable,
         dst_data_o(32 downto 30)  => main_adf_dirty
      ); -- i_cdc_adf_mount

   -- dirty-track event channel main->qnice: two-phase toggle handshake, now
   -- with one request toggle per drive and a SHARED track payload. The engine
   -- holds the track number stable, waits ~1 us, THEN flips the toggle of the
   -- owning drive (and the payload stays put until that ack round trip
   -- completes), so cdc_stable's per-bit settling can never deliver a torn
   -- payload with a fresh toggle, and the two idle drives see no edge at all.
   -- Ack returns the same way. All three instances are covered by the
   -- common.xdc cdc_stable set_max_delay constraint.
   i_cdc_adf_wrt_evt : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 11,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i                => main_clk,
         src_data_i( 7 downto 0)  => main_adf_wr_track,
         src_data_i(10 downto 8)  => main_adf_wr_req,
         dst_clk_i                => qnice_clk_i,
         dst_data_o( 7 downto 0)  => qnice_adf_wrt_track,
         dst_data_o(10 downto 8)  => qnice_adf_wrt_req
      ); -- i_cdc_adf_wrt_evt

   i_cdc_adf_wrt_ack : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 3,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i               => qnice_clk_i,
         src_data_i(2 downto 0)  => qnice_adf_wrt_ack,
         dst_clk_i               => main_clk,
         dst_data_o(2 downto 0)  => main_adf_wr_ack
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

   -- Flatten the four masters into the packed arbiter interface. Slave 0 is
   -- the track engine (the only latency-sensitive one - Paula is waiting for
   -- its sector), slaves 1..3 are the three mount wrappers, which only run
   -- while the Shell streams an image from the SD card.
   hr_arb_write <= hr_adf_avm_write & hr_flp_avm_write;
   hr_arb_read  <= hr_adf_avm_read  & hr_flp_avm_read;

   hr_arb_address(31 downto 0)      <= hr_flp_avm_address;
   hr_arb_writedata(15 downto 0)    <= hr_flp_avm_writedata;
   hr_arb_byteenable(1 downto 0)    <= hr_flp_avm_byteenable;
   hr_arb_burstcount(7 downto 0)    <= hr_flp_avm_burstcount;
   hr_flp_avm_readdata              <= hr_arb_readdata(15 downto 0);
   hr_flp_avm_readdatavalid         <= hr_arb_readdatavalid(0);
   hr_flp_avm_waitrequest           <= hr_arb_waitrequest(0);

   gen_arb_flatten : for u in 0 to 2 generate
      hr_arb_address(32 * (u + 2) - 1 downto 32 * (u + 1)) <= hr_adf_avm_address(u);
      hr_arb_writedata(16 * (u + 2) - 1 downto 16 * (u + 1)) <= hr_adf_avm_writedata(u);
      hr_arb_byteenable(2 * (u + 2) - 1 downto 2 * (u + 1)) <= hr_adf_avm_byteenable(u);
      hr_arb_burstcount(8 * (u + 2) - 1 downto 8 * (u + 1)) <= hr_adf_avm_burstcount(u);
      hr_adf_avm_readdata(u)      <= hr_arb_readdata(16 * (u + 2) - 1 downto 16 * (u + 1));
      hr_adf_avm_readdatavalid(u) <= hr_arb_readdatavalid(u + 1);
      hr_adf_avm_waitrequest(u)   <= hr_arb_waitrequest(u + 1);
   end generate gen_arb_flatten;

   -- round-robin per whole transaction; the masters never compete in practice
   -- (a mount streams while the engine is idle and vice versa)
   i_avm_arbit_adf : entity work.avm_arbit_general
      generic map (
         G_NUM_SLAVES   => 4,
         G_FREQ_HZ      => 100_000_000,
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         clk_i                 => hr_clk_i,
         rst_i                 => hr_rst_i,

         s_avm_write_i         => hr_arb_write,
         s_avm_read_i          => hr_arb_read,
         s_avm_address_i       => hr_arb_address,
         s_avm_writedata_i     => hr_arb_writedata,
         s_avm_byteenable_i    => hr_arb_byteenable,
         s_avm_burstcount_i    => hr_arb_burstcount,
         s_avm_readdata_o      => hr_arb_readdata,
         s_avm_readdatavalid_o => hr_arb_readdatavalid,
         s_avm_waitrequest_o   => hr_arb_waitrequest,

         m_avm_write_o         => hr_core_write_o,
         m_avm_read_o          => hr_core_read_o,
         m_avm_address_o       => hr_core_address_o,
         m_avm_writedata_o     => hr_core_writedata_o,
         m_avm_byteenable_o    => hr_core_byteenable_o,
         m_avm_burstcount_o    => hr_core_burstcount_o,
         m_avm_readdata_i      => hr_core_readdata_i,
         m_avm_readdatavalid_i => hr_core_readdatavalid_i,
         m_avm_waitrequest_i   => hr_core_waitrequest_i
      ); -- i_avm_arbit_adf

end architecture synthesis;
