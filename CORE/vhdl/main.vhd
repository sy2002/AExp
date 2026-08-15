----------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- Wrapper for the MiSTer Minimig core that runs exclusively in the core's
-- clock domain (28.375 MHz). This file replaces MiSTer's emu module
-- (Minimig.sv): clocking enables, CPU phase generation, host configuration,
-- ADF floppy service, keyboard, video and audio glue.
--
-- Wiring follows .research/INTEGRATION-SPEC-video-audio.md and the port
-- contract in .research/phase-a/sweep-minimig.md / cpu_wrapper.md.
--
-- Based on the MiSTer2MEGA65 framework template, done by sy2002 and MJoergen
-- in 2022 and licensed under GPL v3.
-- Amiga 500 port (AExp) done by sy2002 in 2026.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_modes_pkg.all;

entity main is
   generic (
      G_VDNUM                 : natural;                    -- amount of virtual drives
      G_ADF_BASE_DF0          : std_logic_vector(21 downto 0);  -- df0 image HyperRAM word base
      G_ADF_BASE_DF1          : std_logic_vector(21 downto 0);  -- df1 image HyperRAM word base
      G_ADF_BASE_DF2          : std_logic_vector(21 downto 0)   -- df2 image HyperRAM word base
   );
   port (
      clk_main_i              : in  std_logic;
      reset_soft_i            : in  std_logic;
      reset_hard_i            : in  std_logic;
      pause_i                 : in  std_logic;

      -- MiSTer core main clock speed:
      -- Make sure you pass very exact numbers here, because they are used for avoiding clock drift at derived clocks
      clk_main_speed_i        : in  natural;

      -- Analog (VGA) output configuration: '1' = one of the retro 15 kHz OSM
      -- modes is selected, i.e. the framework's scandoubler is bypassed; the
      -- OSM overlay sampling rate follows suit (see video_ce_ovl_o)
      video_retro15khz_i      : in  std_logic;

      -- Video output
      video_ce_o              : out std_logic;
      video_ce_ovl_o          : out std_logic;
      video_red_o             : out std_logic_vector(7 downto 0);
      video_green_o           : out std_logic_vector(7 downto 0);
      video_blue_o            : out std_logic_vector(7 downto 0);
      video_vs_o              : out std_logic;
      video_hs_o              : out std_logic;
      video_hblank_o          : out std_logic;
      video_vblank_o          : out std_logic;
      video_fl_o              : out std_logic;   -- interlace field flag: toggles per field
                                                 -- while the Amiga sets BPLCON0 LACE, constant
                                                 -- '0' otherwise; drives ascal's weave deinterlacer

      -- Master volume from the OSM "Volume" radio (5% steps): 0 = mute .. 20 = 100%.
      -- Applied below as a perceptual, loudness-linear attenuation on the final
      -- Paula mix, so it affects the HDMI and analog audio outputs equally.
      audio_volume_i          : in  natural range 0 to 20;

      -- Paula output filters + stereo crossfeed (OSM "Audio" section): static
      -- bits from mega65.vhd, applied in audio_filters.vhd between Paula and
      -- the master volume (see audio_filters.vhd for the semantics)
      audio_a500_filter_i     : in  std_logic;
      audio_led_filter_i      : in  std_logic;
      audio_stereo_mix_i      : in  std_logic_vector(1 downto 0);

      -- Audio output (Signed PCM)
      audio_left_o            : out signed(15 downto 0);
      audio_right_o           : out signed(15 downto 0);

      -- Amiga chip/slow/kick memory: SRAM-style bus served by BRAM in mega65.vhd.
      -- ram_addr_o is the BANKED word address from minimig_sram_bridge.v:
      --   chip 512KB at [22:19]="0000", slow 512KB at [22:18]="10000",
      --   kick 256KB at [22:19]="1111" (mirrored across bit 18)
      ram_addr_o              : out std_logic_vector(22 downto 1);
      ram_data_o              : out std_logic_vector(15 downto 0);  -- write data
      ram_data_i              : in  std_logic_vector(15 downto 0);  -- read data
      ram_bhe_n_o             : out std_logic;                      -- byte enable bits 15:8, active low
      ram_ble_n_o             : out std_logic;                      -- byte enable bits 7:0, active low
      ram_we_n_o              : out std_logic;                      -- write enable, active low
      ram_oe_n_o              : out std_logic;                      -- read enable, active low

      -- LEDs of the emulated Amiga
      pwr_led_o               : out std_logic;
      fdd_led_o               : out std_logic;

      -- ADF floppy mount status (from adf_mount_wrapper via mega65.vhd,
      -- already CDC'd to clk_main)
      adf_mounted_i           : in  std_logic_vector( 2 downto 0);
      adf_tracks_i            : in  std_logic_vector(23 downto 0);

      -- ADF write-back: arming flag (CDC'd like the mount status) and the
      -- dirty-track event channel (two-phase toggle handshake towards
      -- adf_mount_wrapper; the cdc_stable instances live in mega65.vhd)
      adf_writable_i          : in  std_logic_vector(2 downto 0);
      adf_wr_track_o          : out std_logic_vector(7 downto 0);
      adf_wr_req_o            : out std_logic_vector(2 downto 0);
      adf_wr_ack_i            : in  std_logic_vector(2 downto 0);

      -- ADF floppy image read/write port: Avalon-MM master in the clk_main
      -- domain (post avm_cache; mega65.vhd crosses it to the HyperRAM clock)
      adf_avm_write_o         : out std_logic;
      adf_avm_read_o          : out std_logic;
      adf_avm_address_o       : out std_logic_vector(31 downto 0);
      adf_avm_writedata_o     : out std_logic_vector(15 downto 0);
      adf_avm_byteenable_o    : out std_logic_vector( 1 downto 0);
      adf_avm_burstcount_o    : out std_logic_vector( 7 downto 0);
      adf_avm_readdata_i      : in  std_logic_vector(15 downto 0);
      adf_avm_readdatavalid_i : in  std_logic;
      adf_avm_waitrequest_i   : in  std_logic;

      -- M2M Keyboard interface
      kb_key_num_i            : in  integer range 0 to 79;    -- cycles through all MEGA65 keys
      kb_key_pressed_n_i      : in  std_logic;                -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- Keyboard mapping mode (issue #6): '1' = Amiga (pure positional), '0' = MEGA65
      -- (semantic "cap is law"; default). Static OSM bit, see keyboard.vhd.
      keyboard_mode_i         : in  std_logic;

      -- Slow RAM (A501) toggle (issue #20): '1' = 512 KB Slow RAM at $C00000 present
      -- (default), '0' = chip-RAM-only A500. Static OSM bit, sampled by amiga_config
      -- while the Amiga is in reset and encoded in the replayed userio memory config.
      slow_ram_i              : in  std_logic;

      -- Hardware Floppy (the MEGA65's real internal drive as an Amiga unit).
      -- Drive map from the OSM "Configure Drives" radio (static in clk_main;
      -- changes trigger the amiga_cold_boot reset in mega65.vhd):
      drv_count_i             : in  std_logic_vector(1 downto 0);  -- Amiga units minus one
      hwf_adf_en_i            : in  std_logic_vector(2 downto 0);  -- unit is a simulated drive
      hwf_phys_unit_i         : in  std_logic_vector(1 downto 0);  -- unit of the physical drive
      hwf_phys_en_i           : in  std_logic;                     -- '1' = physical unit exists
      -- CIA-B drive-control taps towards the connector (pin driving lives in
      -- mega65.vhd next to the f_* ports):
      hwf_fdd_ctrl_o          : out std_logic_vector(7 downto 0);  -- {motor_n,sel3..0_n,side,direc,step_n}
      hwf_motor_on_o          : out std_logic_vector(3 downto 0);  -- per-unit motor latches
      -- conditioned real drive status (synced to clk_main in mega65.vhd):
      hwf_change_n_i          : in  std_logic;
      hwf_wprot_n_i           : in  std_logic;
      hwf_track0_n_i          : in  std_logic;
      hwf_ready_n_i           : in  std_logic;
      hwf_index_i             : in  std_logic;
      hwf_present_i           : in  std_logic;
      -- reconstructed MFM word stream (read side of the front-end FIFO):
      hwf_rd_data_i           : in  std_logic_vector(15 downto 0);
      hwf_rd_empty_i          : in  std_logic;
      hwf_rd_en_o             : out std_logic;
      -- live DSKSYNC towards the front-end bit-aligner:
      hwf_dsksync_o           : out std_logic_vector(15 downto 0);
      -- diag: Gray-coded count of physical data words served into Paula:
      hwf_served_gray_o       : out std_logic_vector(15 downto 0);
      -- diag: store-signature pair (engine-served vs Paula-stored, first
      -- 1024 words after the sync match of each read attempt) + counters:
      hwf_eng_sig_o           : out std_logic_vector(15 downto 0);
      hwf_eng_ses_o           : out std_logic_vector(7 downto 0);
      hwf_eng_done_o          : out std_logic;
      hwf_eng_c64_o           : out std_logic_vector(15 downto 0);
      hwf_eng_c256_o          : out std_logic_vector(15 downto 0);
      -- diag: '1' while a physical read stream session is open (gates the
      -- margin instrumentation in physical_fdd_top):
      hwf_serving_o           : out std_logic;
      -- '1' while that session streams words past its serve-start sync
      -- (gates the WORDSYNC-conditional framing hold - the sync-seam fix):
      hwf_serving_data_o      : out std_logic;
      hwf_pau_sig_o           : out std_logic_vector(15 downto 0);
      hwf_pau_att_o           : out std_logic_vector(7 downto 0);
      hwf_pau_c64_o           : out std_logic_vector(15 downto 0);
      hwf_pau_c256_o          : out std_logic_vector(15 downto 0);
      hwf_pau_tap_o           : out std_logic_vector(127 downto 0);
      hwf_pau_ws_o            : out std_logic;

      -- MEGA65 joysticks and paddles/mouse/potentiometers
      joy_1_up_n_i            : in  std_logic;
      joy_1_down_n_i          : in  std_logic;
      joy_1_left_n_i          : in  std_logic;
      joy_1_right_n_i         : in  std_logic;
      joy_1_fire_n_i          : in  std_logic;

      joy_2_up_n_i            : in  std_logic;
      joy_2_down_n_i          : in  std_logic;
      joy_2_left_n_i          : in  std_logic;
      joy_2_right_n_i         : in  std_logic;
      joy_2_fire_n_i          : in  std_logic;

      pot1_x_i                : in  std_logic_vector(7 downto 0);
      pot1_y_i                : in  std_logic_vector(7 downto 0);
      pot2_x_i                : in  std_logic_vector(7 downto 0);
      pot2_y_i                : in  std_logic_vector(7 downto 0);

      -- Current date/time from the MEGA65 battery-backed RTC (issue #13).
      -- MiSTer 65-bit format (see minimig.v / rtc_controller.vhd): bits 63-0 =
      -- MSM6242B BCD nibbles, bit 64 = "new value" toggle. Already CDC'd to
      -- clk_main_i by the framework, so it needs no further synchronisation.
      rtc_i                   : in  std_logic_vector(64 downto 0)
   );
end entity main;

architecture synthesis of main is

   ---------------------------------------------------------------------------
   -- Component declarations for the Verilog modules of the Minimig submodule
   -- (CORE/Minimig_MiSTerMEGA65/rtl). Mixed-language binding is by name;
   -- all port names are legal VHDL identifiers (see rtl/minimig_m65.v).
   ---------------------------------------------------------------------------

   component amiga_clk is
      port (
         clk_28   : in  std_logic;
         clk7_en  : out std_logic;
         clk7n_en : out std_logic;
         c1       : out std_logic;
         c3       : out std_logic;
         cck      : out std_logic;
         eclk     : out std_logic_vector(9 downto 0);
         reset_n  : in  std_logic
      );
   end component amiga_clk;

   component minimig_m65 is
      port (
         cpu_address    : in  std_logic_vector(23 downto 1);
         cpu_data       : out std_logic_vector(15 downto 0);
         cpudata_in     : in  std_logic_vector(15 downto 0);
         cpu_ipl_n      : out std_logic_vector(2 downto 0);
         cpu_as_n       : in  std_logic;
         cpu_uds_n      : in  std_logic;
         cpu_lds_n      : in  std_logic;
         cpu_r_w        : in  std_logic;
         cpu_dtack_n    : out std_logic;
         cpu_reset_n    : out std_logic;
         cpu_reset_in_n : in  std_logic;
         nmi_addr       : in  std_logic_vector(31 downto 0);

         ram_data       : out std_logic_vector(15 downto 0);
         ramdata_in     : in  std_logic_vector(15 downto 0);
         ram_address    : out std_logic_vector(22 downto 1);
         ram_bhe_n      : out std_logic;
         ram_ble_n      : out std_logic;
         ram_we_n       : out std_logic;
         ram_oe_n       : out std_logic;

         rst_ext        : in  std_logic;
         rst_out        : out std_logic;
         clk            : in  std_logic;
         clk7_en        : in  std_logic;
         clk7n_en       : in  std_logic;
         c1             : in  std_logic;
         c3             : in  std_logic;
         cck            : in  std_logic;
         eclk           : in  std_logic_vector(9 downto 0);

         joy1_n         : in  std_logic_vector(15 downto 0);
         joy2_n         : in  std_logic_vector(15 downto 0);
         mouse_btn      : in  std_logic_vector(2 downto 0);
         kms_level      : in  std_logic;
         kbd_mouse_type : in  std_logic_vector(1 downto 0);
         kbd_mouse_data : in  std_logic_vector(7 downto 0);
         kbd_ack        : out std_logic;   -- CIA-A keyboard-SDR-read handshake (see keyboard.vhd)

         pwr_led        : out std_logic;
         fdd_led        : out std_logic;
         hdd_led        : out std_logic;

         -- physical-drive support (see minimig_m65.v / paula_floppy.v)
         fdd_ctrl          : out std_logic_vector(7 downto 0);
         fdd_motor_on      : out std_logic_vector(3 downto 0);
         fdd_dsig          : out std_logic_vector(15 downto 0);
         fdd_datt          : out std_logic_vector(7 downto 0);
         fdd_dc64          : out std_logic_vector(15 downto 0);
         fdd_dc256         : out std_logic_vector(15 downto 0);
         fdd_dtap          : out std_logic_vector(127 downto 0);
         fdd_dws           : out std_logic;
         fdd_phys_mask     : in  std_logic_vector(3 downto 0);
         fdd_phys_change_n : in  std_logic;
         fdd_phys_wprot_n  : in  std_logic;
         fdd_phys_track0_n : in  std_logic;
         fdd_phys_ready_n  : in  std_logic;
         fdd_phys_index    : in  std_logic;

         rtc            : in  std_logic_vector(64 downto 0);

         io_uio         : in  std_logic;
         io_fpga        : in  std_logic;
         io_strobe      : in  std_logic;
         io_wait        : out std_logic;
         io_din         : in  std_logic_vector(15 downto 0);
         io_dout        : out std_logic_vector(15 downto 0);

         hsync_n        : out std_logic;
         vsync_n        : out std_logic;
         hblank         : out std_logic;
         vblank         : out std_logic;
         red            : out std_logic_vector(7 downto 0);
         green          : out std_logic_vector(7 downto 0);
         blue           : out std_logic_vector(7 downto 0);
         ce_pix         : out std_logic;
         res            : out std_logic_vector(1 downto 0);
         lace           : out std_logic;
         field1         : out std_logic;

         ldata          : out std_logic_vector(14 downto 0);
         rdata          : out std_logic_vector(14 downto 0)
      );
   end component minimig_m65;

   component cpu_wrapper is
      port (
         reset          : in  std_logic;                       -- ACTIVE LOW
         reset_out      : out std_logic;                       -- active low (fx68k RESET instruction)

         clk            : in  std_logic;
         ph1            : in  std_logic;
         ph2            : in  std_logic;

         cpucfg         : in  std_logic_vector(1 downto 0);
         fastramcfg     : in  std_logic_vector(2 downto 0);
         cachecfg       : in  std_logic_vector(2 downto 0);
         bootrom        : in  std_logic;

         chip_addr      : out std_logic_vector(23 downto 1);
         chip_dout      : in  std_logic_vector(15 downto 0);
         chip_din       : out std_logic_vector(15 downto 0);
         chip_as        : out std_logic;
         chip_uds       : out std_logic;
         chip_lds       : out std_logic;
         chip_rw        : out std_logic;
         chip_dtack     : in  std_logic;
         chip_ipl       : in  std_logic_vector(2 downto 0);

         fastchip_dout  : in  std_logic_vector(15 downto 0);
         fastchip_sel   : out std_logic;
         fastchip_lds   : out std_logic;
         fastchip_uds   : out std_logic;
         fastchip_rnw   : out std_logic;
         fastchip_lw    : out std_logic;
         fastchip_selack: in  std_logic;
         fastchip_ready : in  std_logic;

         ramsel         : out std_logic;
         ramaddr        : out std_logic_vector(28 downto 1);
         ramdin         : out std_logic_vector(15 downto 0);
         ramdout        : in  std_logic_vector(15 downto 0);
         ramready       : in  std_logic;
         ramlds         : out std_logic;
         ramuds         : out std_logic;
         ramshared      : out std_logic;

         toccata_ena    : out std_logic;
         toccata_base   : out std_logic_vector(7 downto 0);

         cpustate       : out std_logic_vector(1 downto 0);
         cacr           : out std_logic_vector(3 downto 0);
         nmi_addr       : out std_logic_vector(31 downto 0)
      );
   end component cpu_wrapper;

   ---------------------------------------------------------------------------
   -- Signals
   ---------------------------------------------------------------------------

   -- MiSTer2MEGA65 (AExp Amiga 500 port), June 2026: reset mapping.
   -- Modeled on C64 main.vhd "RESET SEMANTICS", simplified: no prevent_reset
   -- yet (no vdrives in milestone 1), hard and soft reset both perform a full
   -- Amiga reset. Replaces MiSTer's Minimig.sv reset_d synchronizer.
   -- July 2026: the keyboard's CTRL+MEGA+RESTORE warm-boot pulse is a third
   -- reset source (the real Amiga keyboard MCU's reset line).
   signal amiga_rst        : std_logic := '1';
   signal kbd_core_reset   : std_logic;

   -- amiga_clk outputs
   signal clk7_en          : std_logic;
   signal clk7n_en         : std_logic;
   signal c1               : std_logic;
   signal c3               : std_logic;
   signal cck              : std_logic;
   signal eclk             : std_logic_vector(9 downto 0);

   -- CPU <-> minimig chip bus
   signal cpu_addr         : std_logic_vector(23 downto 1);
   signal cpu_dout         : std_logic_vector(15 downto 0);   -- minimig -> CPU
   signal cpu_din          : std_logic_vector(15 downto 0);   -- CPU -> minimig
   signal cpu_ipl_n        : std_logic_vector(2 downto 0);
   signal cpu_as_n         : std_logic;
   signal cpu_uds_n        : std_logic;
   signal cpu_lds_n        : std_logic;
   signal cpu_rw           : std_logic;
   signal cpu_dtack_n      : std_logic;
   signal cpu_reset_n      : std_logic;                       -- minimig -> CPU reset
   signal cpu_reset_out_n  : std_logic;                       -- fx68k RESET instruction feedback
   signal cpu_nmi_addr     : std_logic_vector(31 downto 0);

   -- fx68k phase enables, see .research/phase-a/cpu_wrapper.md:
   -- one clk28 wide each, 7.09 MHz rate, 180 degrees apart, aligned to c1/c3
   signal cpu_ph1          : std_logic := '0';
   signal cpu_ph2          : std_logic := '0';

   -- shared minimig host bus: amiga_config (userio channel, enable io_uio) and
   -- adf_track_engine (floppy channel, enable io_fpga) share IO_STROBE/IO_DIN.
   -- The enables are mutually exclusive by construction: amiga_config owns the
   -- bus from reset until it parks in ST_DONE (cfg_done), the engine only runs
   -- while cfg_done='1' and drops everything the moment amiga_rst asserts.
   signal io_uio           : std_logic;
   signal io_fpga          : std_logic;
   signal io_strobe        : std_logic;
   signal io_din           : std_logic_vector(15 downto 0);
   signal io_dout          : std_logic_vector(15 downto 0);
   signal io_wait          : std_logic;

   signal cfg_strobe       : std_logic;
   signal cfg_din          : std_logic_vector(15 downto 0);
   signal cfg_done         : std_logic;

   signal eng_strobe       : std_logic;
   signal eng_din          : std_logic_vector(15 downto 0);

   -- adf_track_engine -> avm_cache (raw single-word Avalon reads)
   signal flp_avm_write         : std_logic;
   signal flp_avm_read          : std_logic;
   signal flp_avm_address       : std_logic_vector(31 downto 0);
   signal flp_avm_writedata     : std_logic_vector(15 downto 0);
   signal flp_avm_byteenable    : std_logic_vector( 1 downto 0);
   signal flp_avm_burstcount    : std_logic_vector( 7 downto 0);
   signal flp_avm_readdata      : std_logic_vector(15 downto 0);
   signal flp_avm_readdatavalid : std_logic;
   signal flp_avm_waitrequest   : std_logic;

   -- cache held in reset while nothing is mounted or the Amiga resets:
   -- in-flight HyperRAM responses from an aborted fetch are discarded (the C64
   -- REU precedent). Note amiga_rst can be as short as ~64 cycles (keyboard
   -- warm boot) - shorter than a worst-case in-flight burst - so the guarantee
   -- is NOT the reset duration: it is that (a) avm_cache ignores readdatavalid
   -- outside its refill state, and (b) the engine cannot issue new reads until
   -- bus grant + poll delay (>> 1 ms), long after any residue has drained.
   signal adf_cache_rst    : std_logic;
   signal adf_avm_busy     : std_logic;
   signal adf_avm_write_int : std_logic;
   signal adf_avm_read_int  : std_logic;
   signal adf_mounted_q    : std_logic_vector(2 downto 0) := (others => '0');
   signal adf_flush_req    : std_logic := '1';   -- flush once after power-up
   constant C_ADF_QUIET    : natural := 15;      -- quiet clocks before a flush
   signal adf_quiet        : natural range 0 to C_ADF_QUIET := 0;
   signal adf_quiet_s      : std_logic;

   -- keyboard
   signal kbd_mouse_data   : std_logic_vector(7 downto 0);
   signal kbd_mouse_type   : std_logic_vector(1 downto 0);
   signal kms_level        : std_logic;
   -- CIA-A "keyboard SDR read" back-channel (from minimig_m65) driving keyboard.vhd's
   -- send-then-wait-for-ack flow control (real keyboard handshake, see keyboard.vhd)
   signal kbd_ack          : std_logic;

   -- video
   signal vid_hsync_n      : std_logic;
   signal vid_vsync_n      : std_logic;
   signal vid_hblank       : std_logic;
   signal vid_vblank       : std_logic;
   signal vid_res          : std_logic_vector(1 downto 0);
   signal vid_vs           : std_logic;                       -- active high vsync

   -- MiSTer2MEGA65 (AExp Amiga 500 port), June 2026:
   -- frame-locked pixel-CE, transplanted from MiSTer Minimig.sv:653-675
   -- (ce_out generator) onto the single 28.375 MHz clock. 28 MHz sampling is
   -- deliberately NOT implemented: OCS cannot do SHRES and the M2M pipeline
   -- cannot take it (video_mixer LINE_LENGTH=768, ascal IHRES=1024). See
   -- .research/INTEGRATION-SPEC-video-audio.md section 3.
   signal fs_res           : std_logic_vector(1 downto 0) := "00";
   signal frame_hires      : std_logic := '0';
   signal vid_vs_d         : std_logic := '0';

   -- divide-by-2 enable (14.19 MHz) for the OSM overlay sampling in the
   -- retro 15 kHz VGA modes
   signal vid_ce_ovl_half  : std_logic := '0';

   -- audio
   signal aud_ldata        : std_logic_vector(14 downto 0);
   signal aud_rdata        : std_logic_vector(14 downto 0);
   signal aud_ce           : std_logic;                        -- 14.19 MHz filter enable
   signal flt_audio_l      : signed(15 downto 0);              -- post filters + crossfeed
   signal flt_audio_r      : signed(15 downto 0);

   -- CIA-A PA1 (power LED / audio filter bit): consumed by audio_filters and
   -- exported on pwr_led_o
   signal pwr_led          : std_logic;

   -- Master-volume LUT (used by audio_volume_proc at the bottom of this file):
   -- perceptual, loudness-linear attenuation for the OSM "Volume" radio. Each 5%
   -- step is a 5 percentage-point change in perceived loudness, so 50% sounds
   -- half as loud as 100% (-10 dB), 25% a quarter (-20 dB), and so on. The
   -- amplitude gain therefore follows (percent/100)^1.661, stored as unsigned
   -- Q15 (0x8000 = gain 1.0). Index 0 = 0% (mute) .. index 20 = 100%
   -- (bit-transparent). Same values as C64MEGA65's C_VOL_LUT, so both cores
   -- sound alike at the same slider position.
   type vol_lut_t is array (0 to 20) of unsigned(15 downto 0);
   constant C_VOL_LUT : vol_lut_t := (
      x"0000", x"00E2", x"02CB", x"057B", x"08D6", x"0CCD", x"1154", x"1662",
      x"1BF1", x"21FB", x"287A", x"2F6C", x"36CB", x"3E96", x"46C8", x"4F60",
      x"585C", x"61B8", x"6B73", x"758C", x"8000");

   -- joysticks in minimig format: active low {...,fire2,fire,up,down,left,right}
   signal joy1_n           : std_logic_vector(15 downto 0);
   signal joy2_n           : std_logic_vector(15 downto 0);

   -- Amiga mouse buttons in minimig format: active high {middle, right, left}
   signal mouse_btn        : std_logic_vector(2 downto 0);
   signal kbd_mouse_rmb    : std_logic;   -- RUN/STOP held (right mouse button substitute)

   -- Hardware Floppy: one-hot mask of the physical unit for paula_floppy's
   -- status muxes (0000 whenever the feature is off = bit-identical core)
   signal hwf_phys_mask    : std_logic_vector(3 downto 0);

   -- POT-line mouse buttons for active adapters (mouSTer and friends), see
   -- the comment block at the mouse_btn assignment and doc/mouse.md.
   -- Watchdog: 30 s at 28.375 MHz; releases a phantom "pressed" after the
   -- adapter has been unplugged (floating line reads like a held button)
   constant C_POT_BTN_TIMEOUT : natural := 30 * 28_375_000;
   signal rmb_capable      : std_logic := '0';
   signal mmb_capable      : std_logic := '0';
   signal rmb_watchdog     : natural range 0 to C_POT_BTN_TIMEOUT := 0;
   signal mmb_watchdog     : natural range 0 to C_POT_BTN_TIMEOUT := 0;
   signal pot_rmb          : std_logic;
   signal pot_mmb          : std_logic;

begin

   ---------------------------------------------------------------------------
   -- Reset
   ---------------------------------------------------------------------------

   -- One register on the core clock; minimig_syscontrol stretches the reset
   -- to 4 video frames internally. While the QNICE Shell holds the M2M reset,
   -- the Kickstart ROM is streamed into the kick BRAM (mandatory auto-load),
   -- so the Amiga only ever starts with a valid Kickstart in place.
   reset_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         amiga_rst <= reset_hard_i or reset_soft_i or kbd_core_reset;
      end if;
   end process reset_proc;

   ---------------------------------------------------------------------------
   -- Amiga clock enables (7.09 MHz, quadrature, colour clock, E-clock)
   ---------------------------------------------------------------------------

   i_amiga_clk : amiga_clk
      port map (
         clk_28   => clk_main_i,
         clk7_en  => clk7_en,
         clk7n_en => clk7n_en,
         c1       => c1,
         c3       => c3,
         cck      => cck,
         eclk     => eclk,
         reset_n  => not amiga_rst
      ); -- i_amiga_clk

   ---------------------------------------------------------------------------
   -- fx68k phase enables
   --
   -- Replicates the semantics of MiSTer's Minimig.sv:229-256 div[3:0]
   -- generator with 4 clk28 ticks per 7.09 MHz cycle: cpu_ph2 is '1' during
   -- the (c1,c3)=(1,0) quarter, cpu_ph1 during the (0,1) quarter; the
   -- condition is evaluated one cycle ahead. Both held '0' in CPU reset.
   -- See .research/phase-a/cpu_wrapper.md section 7.
   ---------------------------------------------------------------------------

   cpu_phase_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if cpu_reset_n = '0' then
            cpu_ph1 <= '0';
            cpu_ph2 <= '0';
         else
            cpu_ph2 <= (not c1) and (not c3);
            cpu_ph1 <= c1 and c3;
         end if;
      end if;
   end process cpu_phase_proc;

   ---------------------------------------------------------------------------
   -- CPU: fx68k via cpu_wrapper (68000, no caches, no fast RAM)
   ---------------------------------------------------------------------------

   i_cpu_wrapper : cpu_wrapper
      port map (
         reset           => cpu_reset_n,         -- active low, from minimig
         reset_out       => cpu_reset_out_n,     -- fx68k RESET instruction feedback

         clk             => clk_main_i,
         ph1             => cpu_ph1,
         ph2             => cpu_ph2,

         cpucfg          => "00",                -- 68000; MUST be constant so the
                                                 -- removed-TG68K muxes constant-fold
         fastramcfg      => "000",               -- no Zorro fast RAM
         cachecfg        => "000",               -- no caches
         bootrom         => '0',                 -- normal A500 memory map

         chip_addr       => cpu_addr,
         chip_dout       => cpu_dout,
         chip_din        => cpu_din,
         chip_as         => cpu_as_n,
         chip_uds        => cpu_uds_n,
         chip_lds        => cpu_lds_n,
         chip_rw         => cpu_rw,
         chip_dtack      => cpu_dtack_n,
         chip_ipl        => cpu_ipl_n,

         fastchip_dout   => x"0000",
         fastchip_sel    => open,
         fastchip_lds    => open,
         fastchip_uds    => open,
         fastchip_rnw    => open,
         fastchip_lw     => open,
         fastchip_selack => '0',
         fastchip_ready  => '0',

         ramsel          => open,
         ramaddr         => open,
         ramdin          => open,
         ramdout         => x"0000",
         ramready        => '0',
         ramlds          => open,
         ramuds          => open,
         ramshared       => open,

         toccata_ena     => open,
         toccata_base    => open,

         cpustate        => open,
         cacr            => open,
         nmi_addr        => cpu_nmi_addr
      ); -- i_cpu_wrapper

   ---------------------------------------------------------------------------
   -- Host configuration FSM: replays MiSTer's HPS startup configuration
   -- (OCS-A500 PAL, 68000, 512KB chip + OSM-selectable 512KB slow, 1 floppy,
   -- no IDE) via minimig's userio protocol after every reset
   ---------------------------------------------------------------------------

   i_amiga_config : entity work.amiga_config
      port map (
         clk_main_i       => clk_main_i,
         reset_i          => amiga_rst,
         slow_ram_i       => slow_ram_i,
         -- two drives only when BOTH the ADF drive and the physical unit
         -- exist (Configure Drives combos A/B); the single-drive combos
         -- C/D announce one drive
         floppy_drives_i  => drv_count_i,
         io_uio_o         => io_uio,
         io_strobe_o      => cfg_strobe,
         io_din_o         => cfg_din,
         io_wait_i        => io_wait,
         cpu_reset_done_o => cfg_done
      ); -- i_amiga_config

   ---------------------------------------------------------------------------
   -- ADF floppy: track engine on the floppy host channel + host-bus mux
   --
   -- The engine replaces MiSTer's ARM-side HandleFDD: it polls Paula over
   -- io_fpga frames, MFM-encodes the mounted ADF's sectors from HyperRAM and
   -- pushes them into Paula's FIFO; Amiga writes are MFM-decoded and committed
   -- back into the HyperRAM image (dirty tracks flushed to SD by the QNICE
   -- firmware). Details and protocol contract in adf_track_engine.vhd /
   -- doc/developers/floppy-adf.md (read path and write path).
   ---------------------------------------------------------------------------

   -- the strobe OR is safe only because the enables are mutually exclusive
   io_strobe <= cfg_strobe or eng_strobe;
   io_din    <= cfg_din when cfg_done = '0' else eng_din;

   i_adf_track_engine : entity work.adf_track_engine
      generic map (
         G_BASE_DF0 => G_ADF_BASE_DF0,
         G_BASE_DF1 => G_ADF_BASE_DF1,
         G_BASE_DF2 => G_ADF_BASE_DF2
      )
      port map (
         clk_main_i          => clk_main_i,
         reset_i             => amiga_rst,
         bus_grant_i         => cfg_done,
         disk_mounted_i      => adf_mounted_i,
         disk_tracks_i       => adf_tracks_i,

         write_en_i          => adf_writable_i,
         wr_track_o          => adf_wr_track_o,
         wr_req_o            => adf_wr_req_o,
         wr_ack_i            => adf_wr_ack_i,

         -- Drive configuration, real-disk presence and the reconstructed
         -- word stream from the front-end (mega65.vhd)
         adf_en_i            => hwf_adf_en_i,
         phys_unit_i         => hwf_phys_unit_i,
         phys_en_i           => hwf_phys_en_i,
         phys_present_i      => hwf_present_i,
         phys_rd_data_i      => hwf_rd_data_i,
         phys_rd_empty_i     => hwf_rd_empty_i,
         phys_rd_en_o        => hwf_rd_en_o,
         dsksync_o           => hwf_dsksync_o,
         phys_served_gray_o  => hwf_served_gray_o,
         phys_sig_o          => hwf_eng_sig_o,
         phys_sig_ses_o      => hwf_eng_ses_o,
         phys_sig_done_o     => hwf_eng_done_o,
         phys_sig_c64_o      => hwf_eng_c64_o,
         phys_sig_c256_o     => hwf_eng_c256_o,
         phys_serving_o      => hwf_serving_o,
         phys_data_o         => hwf_serving_data_o,

         io_fpga_o           => io_fpga,
         io_strobe_o         => eng_strobe,
         io_din_o            => eng_din,
         io_dout_i           => io_dout,
         io_wait_i           => io_wait,

         avm_busy_o          => adf_avm_busy,
         avm_write_o         => flp_avm_write,
         avm_read_o          => flp_avm_read,
         avm_address_o       => flp_avm_address,
         avm_writedata_o     => flp_avm_writedata,
         avm_byteenable_o    => flp_avm_byteenable,
         avm_burstcount_o    => flp_avm_burstcount,
         avm_readdata_i      => flp_avm_readdata,
         avm_readdatavalid_i => flp_avm_readdatavalid,
         avm_waitrequest_i   => flp_avm_waitrequest
      ); -- i_adf_track_engine

   -- single-line cache: turns the engine's sequential single-word reads into
   -- 8-word HyperRAM bursts (the proven C64 REU value). The engine's sector
   -- commits pass through as single-word writes (write-through; a write hit
   -- updates the cache line, so read-back after write stays coherent)
   --
   -- The cache is SHARED by all three simulated drives, so it must be
   -- invalidated whenever the Shell has streamed a new image into any drive's
   -- pool - the stale line would otherwise serve up to eight words of the
   -- previous image. A mount transition is exactly the observable event
   -- (disk_mounted drops while the wrapper loads and returns when it is
   -- validated), so any change of the mount vector arms a flush.
   --
   -- The flush must NOT happen while anything is in flight. Two things can be:
   --   * the engine, which avm_cache would leave waiting forever for a burst
   --     response that the reset threw away - avm_busy_o covers that, and it
   --     rises one state before the first read/write is issued, which also
   --     closes the race against an engine that starts fetching in the same
   --     cycle the flush is decided;
   --   * the cache itself, whose master-side write of the LAST word of a
   --     committed sector may still be waiting for waitrequest to drop. The
   --     reset clears m_avm_write_o, so that word would be silently dropped
   --     and the .adf would end up with a torn sector. adf_quiet therefore
   --     only counts up while the master side is idle as well, and the flush
   --     waits for a run of quiet cycles.
   p_adf_cache_flush : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         adf_mounted_q <= adf_mounted_i;
         if adf_mounted_i /= adf_mounted_q then
            adf_flush_req <= '1';
         elsif adf_flush_req = '1' and adf_quiet = C_ADF_QUIET then
            adf_flush_req <= '0';                 -- the reset below is asserted
         end if;                                  -- during exactly this cycle

         if adf_avm_busy = '1' or adf_avm_write_int = '1' or adf_avm_read_int = '1' then
            adf_quiet <= 0;
         elsif adf_quiet /= C_ADF_QUIET then
            adf_quiet <= adf_quiet + 1;
         end if;
      end if;
   end process p_adf_cache_flush;

   adf_cache_rst <= amiga_rst or (adf_flush_req and adf_quiet_s);
   adf_quiet_s   <= '1' when adf_quiet = C_ADF_QUIET else '0';

   i_avm_cache : entity work.avm_cache
      generic map (
         G_CACHE_SIZE   => 8,
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         clk_i                 => clk_main_i,
         rst_i                 => adf_cache_rst,
         s_avm_waitrequest_o   => flp_avm_waitrequest,
         s_avm_write_i         => flp_avm_write,
         s_avm_read_i          => flp_avm_read,
         s_avm_address_i       => flp_avm_address,
         s_avm_writedata_i     => flp_avm_writedata,
         s_avm_byteenable_i    => flp_avm_byteenable,
         s_avm_burstcount_i    => flp_avm_burstcount,
         s_avm_readdata_o      => flp_avm_readdata,
         s_avm_readdatavalid_o => flp_avm_readdatavalid,
         m_avm_waitrequest_i   => adf_avm_waitrequest_i,
         m_avm_write_o         => adf_avm_write_int,
         m_avm_read_o          => adf_avm_read_int,
         m_avm_address_o       => adf_avm_address_o,
         m_avm_writedata_o     => adf_avm_writedata_o,
         m_avm_byteenable_o    => adf_avm_byteenable_o,
         m_avm_burstcount_o    => adf_avm_burstcount_o,
         m_avm_readdata_i      => adf_avm_readdata_i,
         m_avm_readdatavalid_i => adf_avm_readdatavalid_i
      ); -- i_avm_cache

   adf_avm_write_o <= adf_avm_write_int;
   adf_avm_read_o  <= adf_avm_read_int;

   ---------------------------------------------------------------------------
   -- Keyboard: MEGA65 keys -> raw Amiga scancode events
   ---------------------------------------------------------------------------

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i         => clk_main_i,
         reset_i            => amiga_rst,

         kb_key_num_i       => kb_key_num_i,
         kb_key_pressed_n_i => kb_key_pressed_n_i,
         keyboard_mode_i    => keyboard_mode_i,

         kbd_mouse_data_o   => kbd_mouse_data,
         kbd_mouse_type_o   => kbd_mouse_type,
         kms_level_o        => kms_level,
         kbd_ack_i          => kbd_ack,
         core_reset_o       => kbd_core_reset,
         mouse_rmb_o        => kbd_mouse_rmb
      ); -- i_keyboard

   ---------------------------------------------------------------------------
   -- Joysticks and mouse: M2M active-low lines -> minimig active-low format
   -- {...., fire2, fire, up, down, left, right}. Like a real A500: mouse in
   -- port 1, joystick in port 2. Note that userio.v CROSS-maps its inputs by
   -- default (_sjoy1 <= _joy2, userio.v:267-274), which is why amiga_config
   -- sets joy_swap=1 (cmd 0xF9) - together, MEGA65 port N = Amiga port N.
   --
   -- A real Amiga quadrature mouse needs no dedicated mouse path: userio.v's
   -- "docking" counters (userio.v:284-338) count the transitions on the
   -- direction pins into JOYxDAT exactly like Denise. This only works because
   -- the M2M debouncer delivers raw, un-debounced lines (M2M debouncer.vhd is
   -- a plain 2-FF synchronizer, changed for AExp) - a real Amiga has no
   -- debouncing on the DB9 lines either.
   ---------------------------------------------------------------------------

   joy1_n <= "1111111111" & '1' & joy_1_fire_n_i & joy_1_up_n_i & joy_1_down_n_i & joy_1_left_n_i & joy_1_right_n_i;
   joy2_n <= "1111111111" & '1' & joy_2_fire_n_i & joy_2_up_n_i & joy_2_down_n_i & joy_2_left_n_i & joy_2_right_n_i;

   -- Mouse buttons, active high {middle, right, left} (userio.v:419-421).
   -- The LEFT button is not wired here: it sits on the fire pin of the mouse
   -- port and flows through joy1_n(4) into CIA-A, exactly like real hardware.
   --
   -- RIGHT (DB9 pin 9) and MIDDLE (pin 5) buttons: on a real Amiga these are
   -- passive switches to GND, and PAULA itself drives the pot lines high
   -- (input.device writes POTGO $FF00, then POTINP reads 0 = pressed). The
   -- MEGA65's paddle circuit on ALL board revisions R3..R6 can only sense
   -- these lines, never drive or pull them high (schematic-proven, see
   -- doc/mouse.md) - a passive Amiga mouse's right/middle buttons are
   -- therefore electrically invisible, and the PRIMARY right button is the
   -- RUN/STOP key (no Amiga keycode, exported by keyboard.vhd).
   --
   -- Active mouse adapters (mouSTer and friends) DO drive the pot lines, and
   -- for them the framework's paddle sampler is a good receiver: it delivers
   -- 255-x inverted readings (CDC'd to clk_main), so a line driven high
   -- reads >= 0x80 and a grounded or floating line reads < 0x80. Amiga-true
   -- polarity is pressed = line LOW - but on its own that would misread a
   -- passive mouse or an empty port (both idle low) as a permanently held
   -- button. The presence latch below is therefore load-bearing, not an
   -- optimization: only after a line has been seen driven HIGH (something
   -- only an active adapter can cause) is "low" trusted to mean "pressed".
   -- The watchdog completes the unplug story: an unplugged adapter leaves
   -- the line floating, which reads "pressed" forever; after
   -- C_POT_BTN_TIMEOUT of continuous "pressed" the latch disarms and the
   -- port behaves as empty again. Re-arming is automatic within one sampler
   -- cycle (~0.5 ms) as soon as a line is driven high again (replug, or
   -- button release). Inversion symptom and adapter behavior are
   -- field-confirmed on R6 (2026-07-04, doc/mouse.md section 6).
   pot_buttons : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         -- right button, DB9 pin 9 (MEGA65 naming: POTX = pot1_x; the Amiga
         -- reads this pin through its "Y" register channel DATLY - see the
         -- naming trap in doc/mouse.md section 1)
         if pot1_x_i(7) = '1' then
            rmb_capable  <= '1';
            rmb_watchdog <= 0;
         elsif rmb_capable = '1' then
            if rmb_watchdog = C_POT_BTN_TIMEOUT then
               rmb_capable <= '0';
            else
               rmb_watchdog <= rmb_watchdog + 1;
            end if;
         end if;

         -- middle button, DB9 pin 5 (MEGA65: POTY = pot1_y / Amiga: DATLX)
         if pot1_y_i(7) = '1' then
            mmb_capable  <= '1';
            mmb_watchdog <= 0;
         elsif mmb_capable = '1' then
            if mmb_watchdog = C_POT_BTN_TIMEOUT then
               mmb_capable <= '0';
            else
               mmb_watchdog <= mmb_watchdog + 1;
            end if;
         end if;

         if amiga_rst = '1' then
            rmb_capable  <= '0';
            rmb_watchdog <= 0;
            mmb_capable  <= '0';
            mmb_watchdog <= 0;
         end if;
      end if;
   end process pot_buttons;

   pot_rmb   <= rmb_capable and not pot1_x_i(7);
   pot_mmb   <= mmb_capable and not pot1_y_i(7);
   mouse_btn <= pot_mmb & (kbd_mouse_rmb or pot_rmb) & '0';

   ---------------------------------------------------------------------------
   -- Hardware Floppy: one-hot physical-unit mask for paula_floppy's muxes
   ---------------------------------------------------------------------------

   hwf_phys_mask <= "0001" when hwf_phys_en_i = '1' and hwf_phys_unit_i = "00" else
                    "0010" when hwf_phys_en_i = '1' and hwf_phys_unit_i = "01" else
                    "0100" when hwf_phys_en_i = '1' and hwf_phys_unit_i = "10" else
                    "0000";

   ---------------------------------------------------------------------------
   -- The Minimig core itself
   ---------------------------------------------------------------------------

   i_minimig : minimig_m65
      port map (
         cpu_address    => cpu_addr,
         cpu_data       => cpu_dout,
         cpudata_in     => cpu_din,
         cpu_ipl_n      => cpu_ipl_n,
         cpu_as_n       => cpu_as_n,
         cpu_uds_n      => cpu_uds_n,
         cpu_lds_n      => cpu_lds_n,
         cpu_r_w        => cpu_rw,
         cpu_dtack_n    => cpu_dtack_n,
         cpu_reset_n    => cpu_reset_n,
         cpu_reset_in_n => cpu_reset_out_n,
         nmi_addr       => cpu_nmi_addr,

         ram_data       => ram_data_o,
         ramdata_in     => ram_data_i,
         ram_address    => ram_addr_o,
         ram_bhe_n      => ram_bhe_n_o,
         ram_ble_n      => ram_ble_n_o,
         ram_we_n       => ram_we_n_o,
         ram_oe_n       => ram_oe_n_o,

         rst_ext        => amiga_rst,
         rst_out        => open,
         clk            => clk_main_i,
         clk7_en        => clk7_en,
         clk7n_en       => clk7n_en,
         c1             => c1,
         c3             => c3,
         cck            => cck,
         eclk           => eclk,

         joy1_n         => joy1_n,
         joy2_n         => joy2_n,
         mouse_btn      => mouse_btn,
         kms_level      => kms_level,
         kbd_mouse_type => kbd_mouse_type,
         kbd_mouse_data => kbd_mouse_data,
         kbd_ack        => kbd_ack,

         pwr_led        => pwr_led,
         fdd_led        => fdd_led_o,
         hdd_led        => open,

         -- Hardware Floppy: CIA-B taps out, real drive status in (the
         -- one-hot mask keeps every mux bit-identical when the feature is
         -- off; the status levels are already clk_main-synced in mega65.vhd)
         fdd_ctrl          => hwf_fdd_ctrl_o,
         fdd_motor_on      => hwf_motor_on_o,
         fdd_dsig          => hwf_pau_sig_o,
         fdd_datt          => hwf_pau_att_o,
         fdd_dc64          => hwf_pau_c64_o,
         fdd_dc256         => hwf_pau_c256_o,
         fdd_dtap          => hwf_pau_tap_o,
         fdd_dws           => hwf_pau_ws_o,
         fdd_phys_mask     => hwf_phys_mask,
         fdd_phys_change_n => hwf_change_n_i,
         fdd_phys_wprot_n  => hwf_wprot_n_i,
         fdd_phys_track0_n => hwf_track0_n_i,
         fdd_phys_ready_n  => hwf_ready_n_i,
         fdd_phys_index    => hwf_index_i,

         rtc            => rtc_i,

         io_uio         => io_uio,
         io_fpga        => io_fpga,
         io_strobe      => io_strobe,
         io_wait        => io_wait,
         io_din         => io_din,
         io_dout        => io_dout,

         hsync_n        => vid_hsync_n,
         vsync_n        => vid_vsync_n,
         hblank         => vid_hblank,
         vblank         => vid_vblank,
         red            => video_red_o,
         green          => video_green_o,
         blue           => video_blue_o,
         ce_pix         => open,                 -- we use the frame-locked CE instead
         res            => vid_res,
         lace           => open,                 -- would only gate the analog scandoubler
                                                 -- (MiSTer: "& ~lace"); VGA keeps bob for now
         field1         => video_fl_o,           -- field identity for ascal's weave deinterlacer
                                                 -- (as MiSTer: assign VGA_F1 = field1)

         ldata          => aud_ldata,
         rdata          => aud_rdata
      ); -- i_minimig

   ---------------------------------------------------------------------------
   -- Video output towards the M2M framework
   --
   -- M2M expects ACTIVE-HIGH sync pulses (video_mixer.sv "Positive pulses.",
   -- ascal start-of-frame on rising i_vs); minimig outputs active-low =>
   -- invert. Blanking is active high from Agnus and fully covers the syncs =>
   -- pass through. See .research/INTEGRATION-SPEC-video-audio.md sections 1+2.
   ---------------------------------------------------------------------------

   vid_vs         <= not vid_vsync_n;

   video_hs_o     <= not vid_hsync_n;
   video_vs_o     <= vid_vs;
   video_hblank_o <= vid_hblank;
   video_vblank_o <= vid_vblank;

   -- frame-locked pixel clock enable: 7.09 MHz for all-lores frames,
   -- 14.19 MHz for frames that contained any hires line
   video_ce_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if vid_hblank = '0' and vid_vblank = '0' then
            fs_res <= fs_res or vid_res;
         end if;
         vid_vs_d <= vid_vs;
         if vid_vs = '1' and vid_vs_d = '0' then      -- start of vsync
            frame_hires <= fs_res(0);
            fs_res      <= "00";
         end if;
      end if;
   end process video_ce_proc;

   video_ce_o     <= clk7_en or (clk7n_en and frame_hires);

   -- OSM overlay / analog sampling: full 28.375 MHz post-scandoubler rate in
   -- the Standard VGA mode; half rate (14.19 MHz) when the scandoubler is
   -- bypassed in the retro 15 kHz modes (same scheme as C64MEGA65 main.vhd)
   ce_ovl_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         vid_ce_ovl_half <= not vid_ce_ovl_half;
      end if;
   end process ce_ovl_proc;

   video_ce_ovl_o <= '1' when video_retro15khz_i = '0' else vid_ce_ovl_half;

   ---------------------------------------------------------------------------
   -- Audio: Paula 15-bit signed -> A500/LED output filters + stereo crossfeed
   -- (audio_filters.vhd, faithful to MiSTer's Minimig.sv output stage) ->
   -- OSM master volume
   ---------------------------------------------------------------------------

   pwr_led_o <= pwr_led;

   -- Both channels are time-multiplexed through each IIR on this enable pair,
   -- so every channel updates at the 7.09 MHz rate the coefficients expect
   aud_ce <= clk7_en or clk7n_en;

   i_audio_filters : entity work.audio_filters
      port map (
         clk_main_i    => clk_main_i,
         reset_i       => amiga_rst,
         ce_i          => aud_ce,
         ldata_i       => aud_ldata,
         rdata_i       => aud_rdata,
         a500_filter_i => audio_a500_filter_i,
         led_filter_i  => audio_led_filter_i,
         stereo_mix_i  => audio_stereo_mix_i,
         pwr_led_i     => pwr_led,
         audio_left_o  => flt_audio_l,
         audio_right_o => flt_audio_r
      ); -- i_audio_filters

   -- Apply the OSM master-volume attenuation to the filtered Paula mix.
   -- Registered on the main clock so Vivado maps the two 16x17 products to
   -- pipelined DSP48 slices; the one-cycle latency (~35 ns) is inaudible. At
   -- 100% (Q15 gain 0x8000) the multiply is bit-transparent, and the gain is
   -- always <= 1.0 so the result can never clip. This is the single point
   -- ahead of the framework's split into the HDMI and analog audio paths, so
   -- the volume affects both outputs equally. Paula's own per-channel volume
   -- registers and the 4-channel mix stay untouched upstream: this stage is
   -- the volume knob on the monitor, not part of the emulated machine.
   audio_volume_proc : process (clk_main_i)
      variable gain   : signed(16 downto 0);
      variable prod_l : signed(32 downto 0);
      variable prod_r : signed(32 downto 0);
   begin
      if rising_edge(clk_main_i) then
         gain          := signed('0' & std_logic_vector(C_VOL_LUT(audio_volume_i)));
         prod_l        := flt_audio_l * gain;               -- signed(16) x signed(17) = signed(33)
         prod_r        := flt_audio_r * gain;
         audio_left_o  <= prod_l(30 downto 15);             -- arithmetic >>15: back to signed(16)
         audio_right_o <= prod_r(30 downto 15);
      end if;
   end process audio_volume_proc;

end architecture synthesis;
