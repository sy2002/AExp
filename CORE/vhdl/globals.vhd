----------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- Global constants
--
-- Based on the MiSTer2MEGA65 framework template, done by sy2002 and MJoergen
-- in 2022 and licensed under GPL v3.
-- Amiga 500 port (AExp) done in 2026.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.qnice_tools.all;
use work.video_modes_pkg.all;

package globals is

----------------------------------------------------------------------------------------------------------
-- QNICE Firmware
----------------------------------------------------------------------------------------------------------

-- QNICE Firmware: Use the regular QNICE "operating system" called "Monitor" while developing and
-- debugging the firmware/ROM itself. If you are using the M2M ROM (the "Shell") as provided by the
-- framework, then always use the release version of the M2M firmware: QNICE_FIRMWARE_M2M
--
-- Hint: You need to run QNICE/tools/make-toolchain.sh to obtain "monitor.rom" and
-- you need to run CORE/m2m-rom/make_rom.sh to obtain the .rom file
constant QNICE_FIRMWARE_MONITOR   : string  := "../../../M2M/QNICE/monitor/monitor.rom";    -- debug/development
constant QNICE_FIRMWARE_M2M       : string  := "../../../CORE/m2m-rom/m2m-rom.rom";         -- release

-- Select firmware here
constant QNICE_FIRMWARE           : string  := QNICE_FIRMWARE_M2M;

----------------------------------------------------------------------------------------------------------
-- Clock Speed(s)
--
-- Important: Make sure that you use very exact numbers - down to the actual Hertz - because some cores
-- rely on these exact numbers. By default M2M supports one core clock speed. In case you need more,
-- then add all the clocks speeds here by adding more constants.
----------------------------------------------------------------------------------------------------------

-- Amiga 500 PAL master clock: ideal is 28.37516 MHz (4 x 7.09379 MHz).
-- Our MMCM in CORE/vhdl/clk.vhd generates 28.375000 MHz (-5.6 ppm), which is
-- well within the tolerance of a real Amiga's crystal. This constant holds the
-- clock that the hardware actually generates.
constant CORE_CLK_SPEED       : natural := 28_375_000;

-- System clock speed (crystal that is driving the FPGA) and QNICE clock speed
-- !!! Do not touch !!!
constant BOARD_CLK_SPEED      : natural := 100_000_000;
constant QNICE_CLK_SPEED      : natural := 50_000_000;   -- a change here has dependencies in qnice_globals.vhd

----------------------------------------------------------------------------------------------------------
-- Video Mode
----------------------------------------------------------------------------------------------------------

-- Rendering constants (in pixels)
--    VGA_*   size of the core's target output post scandoubler
-- Amiga PAL: 15.625 kHz, 312/313 lines, scandoubled to ~31.25 kHz / 576 visible
-- lines: PAL 4:3 720x576@50 is the natural match.
constant VGA_DX               : natural := 720;
constant VGA_DY               : natural := 576;

--    FONT_*  size of one OSM character
constant FONT_FILE            : string  := "../font/Anikki-16x16-m2m.rom";
constant FONT_DX              : natural := 16;
constant FONT_DY              : natural := 16;

-- Constants for the OSM screen memory
constant CHARS_DX             : natural := VGA_DX / FONT_DX;
constant CHARS_DY             : natural := VGA_DY / FONT_DY;
constant CHAR_MEM_SIZE        : natural := CHARS_DX * CHARS_DY;
constant VRAM_ADDR_WIDTH      : natural := f_log2(CHAR_MEM_SIZE);

----------------------------------------------------------------------------------------------------------
-- HyperRAM memory map (in units of 4kW)
----------------------------------------------------------------------------------------------------------

-- The M2M framework's ascal framebuffer occupies bytes 0..2 MB (window 0x0000..
-- 0x00FF); ascal triple-buffering MUST stay off (mega65.vhd qnice_ascal_triplebuf_o
-- is tied '0'), otherwise the scaler would grow to 6 MB and overwrite the ADF.
constant C_HMAP_M2M           : std_logic_vector(15 downto 0) := x"0000";     -- Reserved for the M2M framework
constant C_HMAP_ADF_DF0       : std_logic_vector(15 downto 0) := x"0200";     -- df0: ADF disk image, 880-935 KB
                                                                              -- packed 2 bytes/word (adf_mount_wrapper.vhd)
constant C_HMAP_ADF_DF1       : std_logic_vector(15 downto 0) := x"0280";     -- reserved for a future df1 (+1 MB)

----------------------------------------------------------------------------------------------------------
-- QNICE device IDs of the Amiga core (must be >= 0x0100)
----------------------------------------------------------------------------------------------------------

-- Kickstart ROM (256 KB): the QNICE Shell streams the ROM file from the SD card
-- into this device at startup, while the core is still held in reset.
constant C_DEV_AMIGA_KICK     : std_logic_vector(15 downto 0) := x"0100";

-- Chip RAM (512 KB) and Slow RAM (512 KB): RESERVED, not wired. The QNICE
-- debug access had to be removed for timing closure: the QNICE address bus
-- could not reach all 256 spread-out BRAM tiles within the falling-edge
-- half-period (see mega65.vhd). Kept here so the IDs are not reused.
constant C_DEV_AMIGA_CHIP     : std_logic_vector(15 downto 0) := x"0101";
constant C_DEV_AMIGA_SLOW     : std_logic_vector(15 downto 0) := x"0102";

-- ADF mount buffer (df0): byte-window bridge into HyperRAM plus the M2M CSR
-- protocol in window 0xFFFF; the OSM " ADF:%s" menu item streams the disk
-- image here (adf_mount_wrapper.vhd)
constant C_DEV_AMIGA_ADF      : std_logic_vector(15 downto 0) := x"0103";

----------------------------------------------------------------------------------------------------------
-- Virtual Drive Management System
----------------------------------------------------------------------------------------------------------

-- Virtual drive management system (handled by vdrives.vhd and the firmware)
-- Permanently OFF for this core: Minimig's floppy does not speak the
-- sd_*/img_mounted protocol that vdrives implements - ADF images are mounted
-- via the manual CRT/ROM loader below (C_DEV_AMIGA_ADF) and served to Paula
-- by adf_track_engine.vhd over the IO_FPGA host channel instead.
-- See .research/INTEGRATION-SPEC-floppy-adf.md.
type vd_buf_array is array(natural range <>) of std_logic_vector;
constant C_VDNUM              : natural := 0;                                 -- amount of virtual drives; maximum is 15
constant C_VD_DEVICE          : std_logic_vector(15 downto 0) := x"EEEE";     -- device number of vdrives.vhd device
constant C_VD_BUFFER          : vd_buf_array := (x"EEEE", x"EEEE");

----------------------------------------------------------------------------------------------------------
-- System for handling simulated cartridges and ROM loaders
----------------------------------------------------------------------------------------------------------

type crtrom_buf_array is array(natural range<>) of std_logic_vector;
constant ENDSTR : character := character'val(0);

-- Cartridges and ROMs can be stored into QNICE devices, HyperRAM and SDRAM
constant C_CRTROMTYPE_DEVICE     : std_logic_vector(15 downto 0) := x"0000";
constant C_CRTROMTYPE_HYPERRAM   : std_logic_vector(15 downto 0) := x"0001";
constant C_CRTROMTYPE_SDRAM      : std_logic_vector(15 downto 0) := x"0002";           -- @TODO/RESERVED for future R4 boards

-- Types of automatically loaded ROMs:
-- If a mandatory file is missing, then the core outputs the missing file and goes fatal
constant C_CRTROMTYPE_MANDATORY  : std_logic_vector(15 downto 0) := x"0003";
constant C_CRTROMTYPE_OPTIONAL   : std_logic_vector(15 downto 0) := x"0004";

-- Manually loadable ROMs and cartridges as defined in config.vhd
-- Entry 0: the ADF disk image for df0, loaded via the OSM " ADF:%s" item into
-- the C_DEV_AMIGA_ADF device (DEVICE type: the device itself bridges to
-- HyperRAM and answers the CSR handshake - do NOT use C_CRTROMTYPE_HYPERRAM,
-- whose manual-load CSR handshake has no responder and hangs the Shell).
constant C_CRTROMS_MAN_NUM       : natural := 1;                                       -- amount of manually loadable ROMs and carts; maximum is 16
constant C_CRTROMS_MAN           : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_AMIGA_ADF,
                                                         x"EEEE");                     -- Always finish the array using x"EEEE"

-- Automatically loaded ROMs: These ROMs are loaded before the core starts
--
-- The Amiga 500 cannot work without its Kickstart ROM, therefore it is
-- MANDATORY: if the file is missing on the SD card, the firmware shows a
-- fatal error (including the file name) and the core does not start.
--
-- File format: raw 256 KB dump of Kickstart 1.3 (rev 34.5, A500/A1000/A2000),
-- big-endian as dumped from the original ROM chip (no byte swapping needed).
-- Location on the SD card (FAT32, partition 1): /amiga/kick.rom
constant KICK_ROM_NAME           : string := "/amiga/kick.rom" & ENDSTR;
constant KICK_ROM_NAME_START     : std_logic_vector(15 downto 0) := x"0000";

constant C_CRTROMS_AUTO_NUM      : natural := 1;                                       -- Amount of automatically loadable ROMs and carts, maximum is 16
constant C_CRTROMS_AUTO_NAMES    : string  := KICK_ROM_NAME;
constant C_CRTROMS_AUTO          : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_AMIGA_KICK,
                                                         C_CRTROMTYPE_MANDATORY, KICK_ROM_NAME_START,
                                                         x"EEEE");                     -- Always finish the array using x"EEEE"

----------------------------------------------------------------------------------------------------------
-- Audio filters
--
-- If you use audio filters, then you need to copy the correct values from the MiSTer core
-- that you are porting: sys/sys_top.v
----------------------------------------------------------------------------------------------------------

-- MiSTer sys_top.v default audio filter (also what MiSTer Minimig uses at this
-- pipeline stage). Note: cx1=3 per MiSTer sys_top (binomial 1,3,3,1); the M2M
-- template and C64MEGA65 carry cx1=2, which appears to be a template typo.
-- The Amiga-specific A500 RC / LED filters (Minimig.sv IIR_filter pair) are a
-- separate stage and a later milestone - see .research/INTEGRATION-SPEC-video-audio.md.
constant audio_flt_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_signed(7056000, 32));
constant audio_cx       : std_logic_vector(39 downto 0) := std_logic_vector(to_signed(4258969, 40));
constant audio_cx0      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(3, 8));
constant audio_cx1      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(3, 8));
constant audio_cx2      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(1, 8));
constant audio_cy0      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-6216759, 24));
constant audio_cy1      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed( 6143386, 24));
constant audio_cy2      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-2023767, 24));
constant audio_att      : std_logic_vector( 4 downto 0) := "00000";
constant audio_mix      : std_logic_vector( 1 downto 0) := "00"; -- 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

end package globals;
