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
-- Amiga 500 port (AExp) done in 2026.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_modes_pkg.all;

entity main is
   generic (
      G_VDNUM                 : natural;                    -- amount of virtual drives
      G_ADF_BASE_ADDRESS      : std_logic_vector(21 downto 0)  -- ADF image HyperRAM word base
   );
   port (
      clk_main_i              : in  std_logic;
      reset_soft_i            : in  std_logic;
      reset_hard_i            : in  std_logic;
      pause_i                 : in  std_logic;

      -- MiSTer core main clock speed:
      -- Make sure you pass very exact numbers here, because they are used for avoiding clock drift at derived clocks
      clk_main_speed_i        : in  natural;

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
      adf_mounted_i           : in  std_logic;
      adf_tracks_i            : in  std_logic_vector(7 downto 0);

      -- ADF floppy image read port: Avalon-MM master in the clk_main domain
      -- (post avm_cache; mega65.vhd crosses it to the HyperRAM clock)
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
      pot2_y_i                : in  std_logic_vector(7 downto 0)
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

         pwr_led        : out std_logic;
         fdd_led        : out std_logic;
         hdd_led        : out std_logic;

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
   signal amiga_rst        : std_logic := '1';

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

   -- cache held in reset while nothing is mounted: in-flight HyperRAM responses
   -- from an aborted fetch drain into the reset cache and are discarded (the
   -- C64 REU precedent; both conditions hold for >= tens of ms)
   signal adf_cache_rst    : std_logic;

   -- keyboard
   signal kbd_mouse_data   : std_logic_vector(7 downto 0);
   signal kbd_mouse_type   : std_logic_vector(1 downto 0);
   signal kms_level        : std_logic;

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

   -- audio
   signal aud_ldata        : std_logic_vector(14 downto 0);
   signal aud_rdata        : std_logic_vector(14 downto 0);

   -- joysticks in minimig format: active low {...,fire2,fire,up,down,left,right}
   signal joy1_n           : std_logic_vector(15 downto 0);
   signal joy2_n           : std_logic_vector(15 downto 0);

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
         amiga_rst <= reset_hard_i or reset_soft_i;
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
   -- (OCS-A500 PAL, 68000, 512KB chip + 512KB slow, 1 floppy, no IDE)
   -- via minimig's userio protocol after every reset
   ---------------------------------------------------------------------------

   i_amiga_config : entity work.amiga_config
      port map (
         clk_main_i       => clk_main_i,
         reset_i          => amiga_rst,
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
   -- pushes them into Paula's FIFO. Read-only; details and protocol contract
   -- in adf_track_engine.vhd / .research/INTEGRATION-SPEC-floppy-adf.md.
   ---------------------------------------------------------------------------

   -- the strobe OR is safe only because the enables are mutually exclusive
   io_strobe <= cfg_strobe or eng_strobe;
   io_din    <= cfg_din when cfg_done = '0' else eng_din;

   i_adf_track_engine : entity work.adf_track_engine
      generic map (
         G_BASE_ADDRESS => G_ADF_BASE_ADDRESS
      )
      port map (
         clk_main_i          => clk_main_i,
         reset_i             => amiga_rst,
         bus_grant_i         => cfg_done,
         disk_mounted_i      => adf_mounted_i,
         disk_tracks_i       => adf_tracks_i,

         io_fpga_o           => io_fpga,
         io_strobe_o         => eng_strobe,
         io_din_o            => eng_din,
         io_dout_i           => io_dout,
         io_wait_i           => io_wait,

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

   -- single-line read cache: turns the engine's sequential single-word reads
   -- into 8-word HyperRAM bursts (the proven C64 REU value)
   adf_cache_rst <= amiga_rst or not adf_mounted_i;

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
         m_avm_write_o         => adf_avm_write_o,
         m_avm_read_o          => adf_avm_read_o,
         m_avm_address_o       => adf_avm_address_o,
         m_avm_writedata_o     => adf_avm_writedata_o,
         m_avm_byteenable_o    => adf_avm_byteenable_o,
         m_avm_burstcount_o    => adf_avm_burstcount_o,
         m_avm_readdata_i      => adf_avm_readdata_i,
         m_avm_readdatavalid_i => adf_avm_readdatavalid_i
      ); -- i_avm_cache

   ---------------------------------------------------------------------------
   -- Keyboard: MEGA65 keys -> raw Amiga scancode events
   ---------------------------------------------------------------------------

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i         => clk_main_i,
         reset_i            => amiga_rst,

         kb_key_num_i       => kb_key_num_i,
         kb_key_pressed_n_i => kb_key_pressed_n_i,

         kbd_mouse_data_o   => kbd_mouse_data,
         kbd_mouse_type_o   => kbd_mouse_type,
         kms_level_o        => kms_level
      ); -- i_keyboard

   ---------------------------------------------------------------------------
   -- Joysticks: M2M active-low directions -> minimig active-low format
   -- {...., fire2, fire, up, down, left, right}; Amiga port 1 = mouse port,
   -- Amiga port 2 = joystick port (the common game port)
   ---------------------------------------------------------------------------

   joy1_n <= "1111111111" & '1' & joy_1_fire_n_i & joy_1_up_n_i & joy_1_down_n_i & joy_1_left_n_i & joy_1_right_n_i;
   joy2_n <= "1111111111" & '1' & joy_2_fire_n_i & joy_2_up_n_i & joy_2_down_n_i & joy_2_left_n_i & joy_2_right_n_i;

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
         mouse_btn      => "000",                -- mouse: later milestone
         kms_level      => kms_level,
         kbd_mouse_type => kbd_mouse_type,
         kbd_mouse_data => kbd_mouse_data,

         pwr_led        => pwr_led_o,
         fdd_led        => fdd_led_o,
         hdd_led        => open,

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
         lace           => open,                 -- milestone 1: cosmetic bob accepted
         field1         => open,

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

   -- OSM overlay / analog sampling run at the full 28.375 MHz post-scandoubler
   -- rate (retro 15 kHz mode is fixed off in milestone 1)
   video_ce_ovl_o <= '1';

   ---------------------------------------------------------------------------
   -- Audio: Paula 15-bit signed -> 16-bit signed PCM (as MiSTer: {data, 1'b0})
   ---------------------------------------------------------------------------

   audio_left_o  <= signed(aud_ldata & '0');
   audio_right_o <= signed(aud_rdata & '0');

end architecture synthesis;
