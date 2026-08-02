----------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- Global constants
--
-- Based on the MiSTer2MEGA65 framework template, done by sy2002 and MJoergen
-- in 2022 and licensed under GPL v3.
-- Amiga 500 port (AExp) done by sy2002 in 2026.
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
--    VGA_*   the On-Screen-Menu (OSM) canvas => character grid
--            CHARS_DX x CHARS_DY = VGA_DX/FONT_DX x VGA_DY/FONT_DY = 45 x 36
--            (with the 16x16 font) that the firmware lays all OSM content
--            (menu, file browser, help) into. This is the overlay canvas,
--            NOT the measured video active.
-- 720x576 equals the HDMI PAL 576p frame (C_HDMI_576p_50, H_PIXELS=720) so the
-- overlay maps 1:1 on HDMI with hdmi_shift = H_PIXELS - VGA_DX = 0. VGA_DX is
-- therefore pinned to 720: a larger value makes hdmi_shift negative into the
-- 'natural' vga_cfg_shift_i port (video_overlay) and breaks the HDMI OSM. This
-- single global feeds BOTH the analog and the digital pipeline (framework.vhd),
-- so do not retarget it to the analog width. The analog post-scandoubler active
-- is actually ~754x574 (ASCAL-measured); analog OSM/frame placement is handled
-- on the analog path, not by changing this constant.
constant VGA_DX               : natural := 720;
constant VGA_DY               : natural := 576;

--    FONT_*  size of one OSM character
constant FONT_FILE            : string  := "../font/Anikki-8x8-m2m.rom";
constant FONT_DX              : natural := 16;
constant FONT_DY              : natural := 16;

-- Constants for the OSM screen memory
constant CHARS_DX             : natural := VGA_DX / FONT_DX;
constant CHARS_DY             : natural := VGA_DY / FONT_DY;
constant CHAR_MEM_SIZE        : natural := CHARS_DX * CHARS_DY;
constant VRAM_ADDR_WIDTH      : natural := f_log2(CHAR_MEM_SIZE);

----------------------------------------------------------------------------------------------------------
-- HyperRAM memory map (in units of one 4 kW window = 4096 x 16 bit = 8 kB)
----------------------------------------------------------------------------------------------------------

-- GUARD DOCTRINE, adopted from C64MEGA65 (its globals.vhd; research issue #218 is still
-- open, the theory lives in C64MEGA65/doc/issue_214_simreu_hyperram.md): every region is
-- followed by an explicit one-window (8 kB) guard - or by enough unused space - so that a
-- burst starting at the last legal word of a region can never reach the next region.
--
-- The overreach is not created by our clients but downstream of them, in shared M2M
-- infrastructure, and is at most 8 words = 16 bytes:
--   * avm_cache (main.vhd, G_CACHE_SIZE => 8) turns a read miss into an 8-word burst and
--     additionally pre-fetches the next half line at cache_addr + 8 with burstcount 4,
--     so it reaches up to +8 words past the word the engine actually asked for.
--   * hyperram_errata.vhd turns every single-word write into a 2-word burst -> +1 word.
--     adf_track_engine.vhd commits with burstcount x"01", so this applies to every
--     one of its 256 sector writes.
-- One guard window is 4096 words = 512x that worst case. The guard matters most for a
-- 160-track image: 901,120 bytes = exactly 110 windows, i.e. it ends flush on a window
-- boundary, so an end-of-image pre-fetch steps straight into the following window.
--
-- Note that the framework's own QNICE HyperRAM device (C_DEV_HYPERRAM = x"0004" in
-- M2M/vhdl/qnice_wrapper.vhd) reaches the whole die with no bounds check. This core never
-- uses it (every C_CRTROMS_* entry below is C_CRTROMTYPE_DEVICE), but it is the one path
-- that could write outside the map.
--
-- The ascal framebuffer sits at RAMBASE 0 and is hardware-masked to
-- 2**ceil(log2(VGA_DX*VGA_DY*3)) = 2 MB (ascal.vhd: avl_wadrs <= i_wadrs AND (RAMSIZE-1)),
-- so it cannot grow into the disk images - UNLESS triple buffering is switched on, which
-- would make it 6 MB and swallow all three pools. mega65.vhd ties qnice_ascal_triplebuf_o
-- to '0'; keep it that way. mega65.vhd asserts the size relation at elaboration time.
constant C_HMAP_M2M           : std_logic_vector(15 downto 0) := x"0000";     -- M2M framework, 512 windows = 4 MB, ends x"01FF"
                                                                              -- (ascal really needs only 256 windows = 2 MB)
constant C_HMAP_ADF_DF0       : std_logic_vector(15 downto 0) := x"0200";     -- df0: ADF image pool, 115 windows, ends x"0272"
constant C_HMAP_ADF_DF0_GUARD : std_logic_vector(15 downto 0) := x"0273";     -- 8 kB guard behind the df0 pool
constant C_HMAP_ADF_DF1       : std_logic_vector(15 downto 0) := x"0280";     -- df1: ADF image pool, 115 windows, ends x"02F2"
constant C_HMAP_ADF_DF1_GUARD : std_logic_vector(15 downto 0) := x"02F3";     -- 8 kB guard behind the df1 pool
constant C_HMAP_ADF_DF2       : std_logic_vector(15 downto 0) := x"0300";     -- df2: ADF image pool, 115 windows, ends x"0372"
constant C_HMAP_ADF_DF2_GUARD : std_logic_vector(15 downto 0) := x"0373";     -- 8 kB guard behind the df2 pool
constant C_HMAP_TOP_GUARD     : std_logic_vector(15 downto 0) := x"03FF";     -- 8 kB guard at the top of the die: a burst past the
                                                                              -- last region must never wrap around to x"0000"
constant C_HMAP_SIZE          : std_logic_vector(15 downto 0) := x"0400";     -- total HyperRAM = 1024 windows = 8 MB

-- Each drive owns a 128-window (1 MB) slot: 115 windows of image pool, one guard window,
-- and 12 windows of reserved slack. The slack is deliberately kept inside the owning
-- drive's slot so that any future maintenance probe address stays in its own region.
constant C_HMAP_ADF_SLOT      : natural := 128;                               -- windows per drive slot

-- The three pool bases indexed by Amiga unit, for the generate loops in mega65.vhd
type hmap_pool_array is array (0 to 2) of std_logic_vector(15 downto 0);
constant C_HMAP_ADF_POOLS     : hmap_pool_array := (C_HMAP_ADF_DF0, C_HMAP_ADF_DF1, C_HMAP_ADF_DF2);

-- ADF geometry: the single source of truth for hardware AND firmware. make_rom.sh scrapes
-- these into globals.asm so the firmware size gate can never drift from the map.
-- Keep each of them on ONE line - the awk scraper is line-based.
constant C_ADF_TRACK_BYTES    : natural := 5632;                              -- 11 sectors x 512 bytes
constant C_ADF_MIN_TRACKS     : natural := 160;                               -- 80 cylinders, both heads
constant C_ADF_MAX_TRACKS     : natural := 166;                               -- 83 cylinders (Paula's step clamp)
constant C_ADF_MIN_SIZE       : natural := C_ADF_MIN_TRACKS * C_ADF_TRACK_BYTES;   -- = 901,120 bytes
constant C_ADF_MAX_SIZE       : natural := C_ADF_MAX_TRACKS * C_ADF_TRACK_BYTES;   -- = 934,912 bytes
constant C_ADF_POOL_BYTES     : natural :=
   (to_integer(unsigned(C_HMAP_ADF_DF0_GUARD)) - to_integer(unsigned(C_HMAP_ADF_DF0))) * 8192;  -- = 115*8192 = 942,080

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

-- ADF mount buffers, one per Amiga drive unit: byte-window bridge into HyperRAM plus the
-- M2M CSR protocol in window 0xFFFF and the write-back CSR in window 0xFFFE; the OSM
-- " df0:%s" / " df1:%s" / " df2:%s" mount items stream the disk images here (three
-- instances of adf_mount_wrapper.vhd, one per C_HMAP_ADF_DF* pool).
--
-- There are three of them even though at most two drives can be ADF drives at any one
-- time: an OPTM_G_LOAD_ROM menu line is bound to its manual-CRT/ROM index by its position
-- in the STATIC config array (M2M/rom/crts-and-roms.asm CRTROM_M_GI counts occurrences in
-- M2M$CFG_OPTM_CRTROM and is blind to menu-dependency visibility). So every unit that can
-- ever be an ADF drive needs its own permanently-bound mount line, hence its own device.
-- Keep each constant on ONE line - make_rom.sh scrapes them.
constant C_DEV_AMIGA_ADF0     : std_logic_vector(15 downto 0) := x"0103";
constant C_DEV_AMIGA_ADF1     : std_logic_vector(15 downto 0) := x"0105";
constant C_DEV_AMIGA_ADF2     : std_logic_vector(15 downto 0) := x"0106";

-- Physical floppy diagnostics: read-only register bank of the Hardware Floppy
-- front-end (physical_fdd_diag.vhd) - the on-hardware bring-up instrument.
-- Note that this sits BETWEEN the ADF devices: 0x0104 predates the second and third
-- ADF drive and is not moved, because the diag register map is documented by number
-- in .research/HANDOVER-hardware-floppy-round2.md.
constant C_DEV_AMIGA_FDD      : std_logic_vector(15 downto 0) := x"0104";

----------------------------------------------------------------------------------------------------------
-- Virtual Drive Management System
----------------------------------------------------------------------------------------------------------

-- Virtual drive management system (handled by vdrives.vhd and the firmware)
-- Permanently OFF for this core: Minimig's floppy does not speak the
-- sd_*/img_mounted protocol that vdrives implements - ADF images are mounted
-- via the manual CRT/ROM loader below (C_DEV_AMIGA_ADF*) and served to Paula
-- by adf_track_engine.vhd over the IO_FPGA host channel instead.
-- See doc/floppy-adf.md.
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
-- Entry 0/1/2: the ADF disk images for df0/df1/df2, loaded via the OSM " df0:%s" /
-- " df1:%s" / " df2:%s" mount items into the C_DEV_AMIGA_ADF0/1/2 devices (DEVICE type:
-- the device itself bridges to HyperRAM and answers the CSR handshake - do NOT use
-- C_CRTROMTYPE_HYPERRAM, whose manual-load CSR handshake has no responder and hangs
-- the Shell).
--
-- THE ORDER IS LOAD-BEARING and must stay in sync across all five layers: the OSM
-- OPTM_G_LOAD_ROM occurrence order in config.vhd, the manual id used here, the QNICE
-- device, the generated HANDLE_RM_FILE<n> / HNDL_RM_FILES table, the firmware drive
-- index, and the Paula unit. Occurrence 0 = df0, 1 = df1, 2 = df2 everywhere.
--
-- This count must never exceed the number of OPTM_G_LOAD_ROM lines in config.vhd -
-- the Shell resolves a manual id to a menu line via CRTROM_M_GI and goes fatal if
-- there is none. It may be smaller than the number of drives only if the surplus
-- mount lines are removed from config.vhd as well.
constant C_CRTROMS_MAN_NUM       : natural := 3;                                       -- amount of manually loadable ROMs and carts; maximum is 16
constant C_CRTROMS_MAN           : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_AMIGA_ADF0,
                                                         C_CRTROMTYPE_DEVICE, C_DEV_AMIGA_ADF1,
                                                         C_CRTROMTYPE_DEVICE, C_DEV_AMIGA_ADF2,
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
