----------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- Configuration data for the Shell
--
-- Based on the MiSTer2MEGA65 framework template, done by sy2002 and MJoergen
-- in 2023 and licensed under GPL v3.
-- Amiga 500 port (AExp) done by sy2002 in 2026.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity config is
port (
   clk_i       : in std_logic;

   -- bits 27 .. 12:    select configuration data block; called "Selector" hereafter
   -- bits 11 downto 0: address the up to 4k the configuration data
   address_i   : in std_logic_vector(27 downto 0);

   -- config data
   data_o      : out std_logic_vector(15 downto 0)
);
end entity config;

architecture beh of config is

--------------------------------------------------------------------------------------------------------------------
-- String and character constants (specific for the Anikki-16x16 font)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant CHR_LINE_1  : character := character'val(196);
constant CHR_LINE_5  : string := CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1;
constant CHR_LINE_10 : string := CHR_LINE_5 & CHR_LINE_5;
constant CHR_LINE_50 : string := CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10;

--------------------------------------------------------------------------------------------------------------------
-- Welcome and Help Screens (Selectors 0x1000 .. 0x1FFF)
--------------------------------------------------------------------------------------------------------------------

-- define the amount of WHS array elements: between 1 and 16
constant WHS_RECORDS   : natural := 2;

-- define the maximum amount of pages per WHS array element: between 1 and 256
-- (this is necessary because Vivado does not support unconstrained arrays in a record)
constant WHS_MAX_PAGES : natural := 7;

 -- !!! DO NOT TOUCH !!!
constant SEL_WHS           : std_logic_vector(15 downto 0) := x"1000";
type WHS_INDEX_TYPE is array (0 to WHS_MAX_PAGES - 1) of natural;
type WHS_RECORD_TYPE is record
   page_count  : natural;
   page_start  : WHS_INDEX_TYPE;
   page_length : WHS_INDEX_TYPE;
end record;
type WHS_RECORD_ARRAY_TYPE is array (0 to WHS_RECORDS - 1) of WHS_RECORD_TYPE;

-- START YOUR CONFIGURATION BELOW THIS LINE

-- The core's version string. Single source of truth (same convention as
-- C64MEGA65, its GitHub issue #182): this constant is used by SCR_WELCOME,
-- HELP_1 through HELP_7 (the welcome and help screens just below), by CORENAME
-- (the serial-terminal banner further down) and by CFG_FILE (the on-SD-card
-- config filename further down). Update this one line when releasing a new
-- version; make_release.py parses it and uses it as the official version
-- string for that release.
constant CORE_VERSION : string := "WIP-V2-A8";

constant SCR_WELCOME : string :=

   "Amiga 500 for MEGA65 - " & CORE_VERSION & "\n" &
   "MiSTer Minimig port, by sy2002 in 2026\n\n" &

   "Powered by MiSTer2MEGA65 Version 2.0.1,\n" &
   "done by sy2002 and MJoergen\n\n\n" &

   "This core needs the Kickstart 1.3 ROM on\n" &
   "your SD card (FAT32):\n\n" &
   "    /amiga/kick.rom\n\n" &
   "Raw 256 KB dump of Kickstart 1.3\n" &
   "(rev 34.5, A500), no byte swapping.\n\n\n" &

   "    Key                Amiga 500\n" &
   "    " & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_1 & CHR_LINE_1 & "\n" &
   "    MEGA               Amiga (left)\n" &
   "    Help               Help / Options menu\n\n\n" &

   "\n\n    Press Space to continue.\n\n\n";

constant HELP_1 : string :=

   "\n Amiga 500 for MEGA65 " & CORE_VERSION & "\n" &
   " MiSTer Minimig port, by sy2002 in 2026\n\n" &
   
   " Go to https://a500.mega65.org\n\n" &

   " THE MACHINE\n\n" &

   " Amiga 500, 68000 CPU, OCS, PAL only\n" &
   " 512 KB Chip RAM + 512 KB Slow RAM\n" &
   " (the A501 Slow RAM can be disabled\n" &
   " in the options menu)\n" &
   " Kickstart 1.3\n" &
   " Video: HDMI and analog RGB in parallel\n" &
   " Audio: via HDMI and 3.5 mm jack\n" &
   " (volume and filters in the menu)\n" &
   " Battery-backed real-time clock\n\n" &
   
   " Mouse:    Port 1\n" &
   " Joystick: Port 2\n\n" &  

   " Up to three floppy drives:\n" &
   " 880 KB ADF disk images (read/write)\n" &
   " and real Amiga disks in the MEGA65\n" &
   " drive (read-only for now). Pick how\n" &
   " many drives and what each one is in\n" &
   " the Drive Settings menu.\n\n" &

   " Not implemented, yet:\n" &
   " Kickstart newer than 1.3\n" &
   " ECS/AGA, NTSC, Fast RAM, hard disks\n\n" &

   " Crsr right: Next                (1/7)\n" &
   " Space or Run/Stop: Close";

constant HELP_2 : string :=

   "\n KEYBOARD\n\n" &

   " MEGA65 mode (default):\n\n" &
   " Type what is printed on the keycaps.\n" &
   " MEGA + key types front-face symbols.\n" &
   " Esc, Tab and Caps Lock work normally.\n\n" &

   " MEGA              Left Amiga\n" &
   " RESTORE           Right Amiga\n" &
   " Run/Stop (hold)   Right mouse button\n" &
   " F1,F3,F5,F7,F9    Odd Amiga F-keys\n" &
   " Shift + F-key     Even Amiga F-keys\n\n" &

   " Amiga mode:\n\n" &
   " Keys use original Amiga positions.\n" &
   " Some games need this mode.\n" &
   " The top row from Run/Stop through F11\n" &
   " becomes Esc and F1-F10.\n" &
   " F13 becomes Left Alt.\n" &
   " Hold the up-arrow symbol left of\n" &
   " RESTORE for the right mouse button.\n\n" &

   " Both modes:\n" &
   " Ctrl+MEGA+RESTORE = warm reset\n\n" &
   "\n\n\n" &  -- keep footer at bottom

   " Crsr left/right: Prev/Next      (2/7)\n" &
   " Space or Run/Stop: Close";

constant HELP_3 : string :=

   "\n ADF FLOPPY\n\n" &

   " Select a df0:/df1:/df2: line in the\n" &
   " menu. A drive shows this line only\n" &
   " while Drive Settings has it set to\n" &
   " Disk Image.\n\n" &

   " Empty drive + Space: open file browser\n" &
   " Mounted disk + Space: eject disk\n\n" &

   " File Browser:\n" &
   " Up/Down: select file\n" &
   " Left/Right: previous/next page\n" &
   " Return: mount selected file\n" &
   " Run/Stop: cancel\n" &
   " F1/F3: Switch between SD cards\n\n" &

   " Mounted disks boot automatically.\n\n" &

   " ADF files are read/write. Saves and\n" &
   " high scores modify the file on SD.\n" &
   " Writes are saved in the background;\n" &
   " the Amiga keeps running normally.\n\n" &

   " Drive LED:\n" &
   " green  = disk access\n" &
   " yellow = changes are being saved\n\n" &

   " Before eject, reset or power off:\n" &
   " wait until the LED has stayed off\n" &
   " for a few seconds. Yellow may return\n" &
   " briefly while data is still flushing.\n\n" &

   " Crsr left/right: Prev/Next      (3/7)\n" &
   " Space or Run/Stop: Close";

constant HELP_4 : string :=

   "\n MOUSE AND JOYSTICK\n\n" &

   " Amiga mouse: Port 1  Joystick: Port 2\n" &
   " Dual mouse and dual joystick setups work\n\n" &

   " Original tank mouse:\n" &
   " Movement and left button work.\n" &
   " Right/middle buttons cannot be read.\n\n" &

   " Active mice (e.g. Alfa Data, Amitech, and\n" &
   " Amigakit) as well as active adapters (e.g.\n" &
   " Micro Tom, mouSTer, USBAMI) support\n" &
   " all buttons.\n\n" &

   " Keyboard right-button fallback:\n" &
   " MEGA65 mode: hold Run/Stop\n" &
   " Amiga mode:  hold the up-arrow symbol\n" &
   "              left of RESTORE\n\n" &

   " No mouse? In Workbench:\n" &
   " MEGA + cursor keys: move pointer\n" &
   " Add Shift: move faster\n" &
   " MEGA65 mode: MEGA + Alt: left button\n" &
   " Amiga mode:  MEGA + F13: left button\n" &
   " Works in Workbench, not games/demos.\n\n" &

   " C64 1350/1351 mice do not work.\n\n" &
   "\n\n" &  -- keep footer at bottom

   " Crsr left/right: Prev/Next      (4/7)\n" &
   " Space or Run/Stop: Close";

constant HELP_5 : string :=

   "\n VIDEO: HDMI AND ANALOG\n\n" &

   " HDMI: PAL Amiga, so 50 Hz modes only:\n" &
   "       720p 16:9\n" &
   "       576p 4:3 or 5:4\n" &
   " HDMI interlace fixing is automatic.\n\n" &

   " IMPORTANT - HDMI: Flicker-free\n" &
   " ON for HDMI-only use\n" &
   " OFF whenever using VGA/analog video\n\n" &

   " The VGA connector always carries video:\n" &
   " Standard = 31 kHz, 50 Hz\n" &
   " 15 kHz HS/VS = separate sync\n" &
   " 15 kHz CSYNC = CRT / RGB SCART\n" &
   " https://a500.mega65.org/doc/retrotubes\n\n" &

   " VGA Standard does not fix interlace.\n" &
   " A 15 kHz CRT weaves it naturally.\n" &
   " HDMI stays active in every VGA mode.\n\n" &

   " Normal VGA displays cannot show 15 kHz\n" &
   " or its menu. Recover using HDMI.\n\n" &
   "\n\n\n\n\n\n" &  -- keep footer at bottom

   " Crsr left/right: Prev/Next      (5/7)\n" &
   " Space or Run/Stop: Close";

constant HELP_6 : string :=

   "\n SCREEN ADJUSTMENT\n\n" &

   " Supplied presets:\n" &
   " aexp_screen.cfg_4_3 & aexp_screen.cfg_16_9\n" &
   " Rename one & save: /amiga/aexp_screen.cfg\n\n" &

   " Use python tool to configure screen:\n" &
   " aexp_screen_cfg.py\n" &
   " https://a500.mega65.org/doc/screen_adjust\n\n" &

   " Menu: Reload Screen Config\n" &
   " applies changes without a reboot.\n\n" &

   " HDMI crop:\n" &
   " Reframes and slightly zooms HDMI only.\n\n" &

   " Analog position:\n" &
   " Moves the complete picture and menu\n" &
   " in all three VGA modes.\n\n" &

   " Analog overscan:\n" &
   " Hides or reveals the border edges.\n\n" &

   " Settings switch for lores, hires and\n" &
   " their interlaced modes automatically.\n\n" &

   " Analog picture size cannot be changed;\n" &
   " use the monitor H/V size controls.\n\n" &
   "\n" &  -- keep footer at bottom

   " Crsr left/right: Prev/Next      (6/7)\n" &
   " Space or Run/Stop: Close";

constant HELP_7 : string :=

   "\n REAL-TIME CLOCK\n\n" &

   " AExp reads the MEGA65 battery RTC.\n" &
   " Set date/time on MEGA65, not the Amiga.\n" &
   " Correct time gives files proper dates.\n\n" &

   " Workbench must run SetClock LOAD during\n" &
   " startup. Stock Workbench 1.3 does this.\n" &
   " In a Shell, type: date\n\n" &

   " If the year is stuck at 1978, the old\n" &
   " Workbench SetClock has a Y2K bug.\n" &
   " Replace C:SetClock with version 34.3.\n" &
   " Check with: version c:setclock\n\n" &

   " HDMI Flicker-free makes the running\n" &
   " Amiga clock gain about 6 seconds/hour.\n\n" &

   " The Amiga side can only read the clock;\n" &
   " do not use SetClock SAVE.\n\n" &
   "\n\n\n\n\n\n\n\n\n" &  -- keep footer at bottom

   " Crsr left: Previous             (7/7)\n" &
   " Space or Run/Stop: Close";

-- Concatenate all your Welcome and Help screens into one large string, so that during synthesis one large string ROM can be build.
constant WHS_DATA : string := SCR_WELCOME & HELP_1 & HELP_2 & HELP_3 & HELP_4 & HELP_5 & HELP_6 & HELP_7;

-- The WHS array needs the start address of each page.
constant SCR_WELCOME_START : natural := 0;
constant HELP_1_START      : natural := SCR_WELCOME'length;
constant HELP_2_START      : natural := HELP_1_START + HELP_1'length;
constant HELP_3_START      : natural := HELP_2_START + HELP_2'length;
constant HELP_4_START      : natural := HELP_3_START + HELP_3'length;
constant HELP_5_START      : natural := HELP_4_START + HELP_4'length;
constant HELP_6_START      : natural := HELP_5_START + HELP_5'length;
constant HELP_7_START      : natural := HELP_6_START + HELP_6'length;

-- Fill the WHS array with page start addresses and the length of each page.
-- Make sure that array element 0 is always your Welcome page.
constant WHS : WHS_RECORD_ARRAY_TYPE := (
   --- Welcome Screen
   (page_count    => 1,
    page_start    => (SCR_WELCOME_START,  0, 0, 0, 0, 0, 0),
    page_length   => (SCR_WELCOME'length, 0, 0, 0, 0, 0, 0)),

   --- Help pages
   (page_count    => 7,
    page_start    => (HELP_1_START,  HELP_2_START,  HELP_3_START,  HELP_4_START,
                      HELP_5_START,  HELP_6_START,  HELP_7_START),
    page_length   => (HELP_1'length, HELP_2'length, HELP_3'length, HELP_4'length,
                      HELP_5'length, HELP_6'length, HELP_7'length))
);

--------------------------------------------------------------------------------------------------------------------
-- Set start folder for file browser and specify config file for menu persistence (Selectors 0x0100 and 0x0101)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant SEL_DIR_START     : std_logic_vector(15 downto 0) := x"0100";
constant SEL_CFG_FILE      : std_logic_vector(15 downto 0) := x"0101";

-- START YOUR CONFIGURATION BELOW THIS LINE

constant DIR_START         : string := "/amiga";
constant CFG_FILE          : string := "/amiga/aexp-" & CORE_VERSION & ".cfg";

--------------------------------------------------------------------------------------------------------------------
-- General configuration settings: Reset, Pause, OSD behavior, Ascal, etc. (Selector 0x0110)
--------------------------------------------------------------------------------------------------------------------

constant SEL_GENERAL       : std_logic_vector(15 downto 0) := x"0110";  -- !!! DO NOT TOUCH !!!

-- START YOUR CONFIGURATION BELOW THIS LINE

-- at a minimum, keep the reset line active for this amount of "QNICE loops" (see gencfg.asm).
-- "0" means: deactivate this feature
constant RESET_COUNTER     : natural := 100;

-- put the core in PAUSE state if any OSD opens
-- IMPORTANT: must stay false for the Amiga core: main.vhd does not implement
-- pause_i yet (minimig has no clean pause point; would need gating of the
-- clk7/c1/c3/cck enables - later milestone)
constant OPTM_PAUSE        : boolean := false;

-- show the welcome screen in general
-- Switched off like in the C64MEGA65 reference: boots straight into the core.
-- The mandatory-ROM fatal screen names /amiga/kick.rom if it is missing, and
-- the About & Help pages document the SD card setup, so nothing is lost.
-- (SCR_WELCOME stays defined: WHS array position 0 must always exist.)
constant WELCOME_ACTIVE    : boolean := false;

-- shall the welcome screen also be shown after the core is reset?
-- (only relevant if WELCOME_ACTIVE is true)
constant WELCOME_AT_RESET  : boolean := false;

-- keyboard and joystick connection during reset and OSD
constant KEYBOARD_AT_RESET : boolean := false;
constant JOY_1_AT_RESET    : boolean := false;
constant JOY_2_AT_RESET    : boolean := false;

constant KEYBOARD_AT_OSD   : boolean := false;
constant JOY_1_AT_OSD      : boolean := true;   -- mouse (Amiga port 1) stays active while the OSM is
                                                -- open; the keyboard belongs to the OSM (false above)
constant JOY_2_AT_OSD      : boolean := false;

-- Avalon Scaler settings (see ascal.vhd, used for HDMI output only)
-- 0=set ascal mode (via QNICE's ascal_mode_o) to the value of the config.vhd constant ASCAL_MODE
-- 1=do nothing, leave ascal mode alone, custom QNICE assembly code can still change it via M2M$ASCAL_MODE
--               and QNICE's CSR will be set to not automatically sync ascal_mode_i
-- 2=keep ascal mode in sync with the QNICE input register ascal_mode_i:
--   use this if you want to control the ascal mode for example via the Options menu
--   where you would wire the output of certain options menu bits with ascal_mode_i
constant ASCAL_USAGE       : natural := 1;   -- AUSE_CUSTOM, like C64MEGA65 V6: the HDMI Filter dispatcher in
                                             -- CORE/m2m-rom/m2m-rom.asm writes M2M$ASCAL_MODE directly (ASCAL_INIT
                                             -- in M2M/rom/gencfg.asm clears the CSR ascal-autosync bit first)
constant ASCAL_MODE        : natural := 0;   -- ignored when ASCAL_USAGE=1; m2m-rom sets the mode per HDMI Filter
                                             -- selection (No Filter/Sharp Bilinear/Bicubic -> native
                                             -- NEAREST/SBILINEAR/BICUBIC, the other 5 -> POLYPHASE)

-- Save on-screen-display settings if the file specified by CFG_FILE exists and if it has
-- the length of OPTM_SIZE bytes. If the first byte of the file has the value 0xFF then it
-- is considered as "default", i.e. the menu items specified by OPTM_G_STDSEL are selected.
-- If the file does not exists, then settings are not saved and OPTM_G_STDSEL always denotes the standard settings.
constant SAVE_SETTINGS     : boolean := true;

-- Delay in ms between the last write request to a virtual drive from the core and the start of the
-- cache flushing (i.e. writing to the SD card).
constant VD_ANTI_THRASHING_DELAY : natural := 2000;

-- Amount of bytes saved in one iteration of the background saving (buffer flushing) process
constant VD_ITERATION_SIZE       : natural := 100;

--------------------------------------------------------------------------------------------------------------------
-- Name and version of the core  (Selector 0x0200)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant SEL_CORENAME      : std_logic_vector(15 downto 0) := x"0200";

-- START YOUR CONFIGURATION BELOW THIS LINE

-- Currently this is only used in the debug console. Use the welcome screen and the
-- help system to display the name and version of your core to the end user
constant CORENAME          : string := "Amiga 500 for MEGA65 " & CORE_VERSION;

--------------------------------------------------------------------------------------------------------------------
-- "Help" menu / Options menu  (Selectors 0x0300 .. 0x0312): DO NOT TOUCH
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!! Selectors for accessing the menu configuration data
constant SEL_OPTM_ITEMS       : std_logic_vector(15 downto 0) := x"0300";
constant SEL_OPTM_GROUPS      : std_logic_vector(15 downto 0) := x"0301";
constant SEL_OPTM_STDSEL      : std_logic_vector(15 downto 0) := x"0302";
constant SEL_OPTM_LINES       : std_logic_vector(15 downto 0) := x"0303";
constant SEL_OPTM_START       : std_logic_vector(15 downto 0) := x"0304";
constant SEL_OPTM_ICOUNT      : std_logic_vector(15 downto 0) := x"0305";
constant SEL_OPTM_MOUNT_DRV   : std_logic_vector(15 downto 0) := x"0306";
constant SEL_OPTM_SINGLESEL   : std_logic_vector(15 downto 0) := x"0307";
constant SEL_OPTM_MOUNT_STR   : std_logic_vector(15 downto 0) := x"0308";
constant SEL_OPTM_DIMENSIONS  : std_logic_vector(15 downto 0) := x"0309";
constant SEL_OPTM_SAVING_STR  : std_logic_vector(15 downto 0) := x"030A";
constant SEL_OPTM_HELP        : std_logic_vector(15 downto 0) := x"0310";
constant SEL_OPTM_CRTROM      : std_logic_vector(15 downto 0) := x"0311";
constant SEL_OPTM_CRTROM_STR  : std_logic_vector(15 downto 0) := x"0312";
constant SEL_OPTM_DEPS        : std_logic_vector(15 downto 0) := x"0313";   -- M2M-UPSTREAM osm-deps

-- !!! DO NOT TOUCH !!! Configuration constants for OPTM_GROUPS (shell.asm and menu.asm expect them to be like this)
constant OPTM_G_TEXT       : integer := 16#00000#;         -- text that cannot be selected
constant OPTM_G_CLOSE      : integer := 16#000FF#;        -- menu items that closes menu
constant OPTM_G_STDSEL     : integer := 16#00100#;        -- item within a group that is selected by default
constant OPTM_G_LINE       : integer := 16#00200#;        -- draw a line at this position
constant OPTM_G_START      : integer := 16#00400#;        -- selector / cursor position after startup (only use once!)
                                                          -- 16#00800# is used in OPTM_G_MOUNT_DRV (OPTM_G_SINGLESEL)
constant OPTM_G_HEADLINE   : integer := 16#01000#;        -- like OPTM_G_TEXT but will be shown in a brigher color
                                                          -- 16#02000# is used in OPTM_G_HELP (plus OPTM_G_SINGLESEL)
                                                          -- 16#04000# is used in OPTM_G_SUBMENU
constant OPTM_G_SINGLESEL  : integer := 16#08000#;        -- single select item
constant OPTM_G_MOUNT_DRV  : integer := 16#08800#;        -- line item means: mount drive; first occurance = drive 0, second = drive 1, ...
constant OPTM_G_HELP       : integer := 16#0A000#;        -- line item means: help screen; first occurance = WHS(1), second = WHS(2), ...
constant OPTM_G_SUBMENU    : integer := 16#0C000#;        -- starts/ends a section that is treated as submenu
constant OPTM_G_LOAD_ROM   : integer := 16#18000#;        -- line item means: load ROM; first occurance = rom 0, second = rom 1, ...
constant OPTM_G_DEPENDENT  : integer := 16#20000000#;     -- dependent line (smart dependencies, see OPTM_DEP below): visible only
                                                          -- while one of the mother-group items in a 4-bit item mask is selected (bit 29)

constant OPTM_GTC          : natural := 30;                -- Amount of significant bits in OPTM_G_* constants (max 30: 2**31 overflows
                                                           -- the integer range expression below); was 17 before the smart-dependencies
                                                           -- feature. Raising it is bit-transparent: every existing decoder arm above
                                                           -- indexes bits 0..16 of the widened vector unchanged.

--------------------------------------------------------------------------------------------------------------------
-- "Help" menu / Options menu: START YOUR CONFIGURATION BELOW THIS LINE
--------------------------------------------------------------------------------------------------------------------

-- Strings with which %s will be replaced in case the menu item is of type OPTM_G_MOUNT_DRV
constant OPTM_S_MOUNT      : string := "<Mount Drive>";     -- no disk image mounted, yet
constant OPTM_S_CRTROM     : string := "<Load>";            -- no ROM loaded, yet
constant OPTM_S_SAVING     : string := "<Saving>";          -- the internal write cache is dirty and not yet written back to the SD card

-- Size of menu and menu items
-- CAUTION: 1. End each line (also the last one) with a \n and make sure empty lines / separator lines are only consisting of a "\n"
--             Do use a lower case \n. If you forget one of them or if you use upper case, you will run into undefined behavior.
--          2. Start each line that contains an actual menu item (multi- or single-select) with a Space character,
--             otherwise you will experience visual glitches.
constant OPTM_SIZE         : natural := 146; -- amount of items including empty lines:
                                             -- needs to be equal to the number of lines in OPTM_ITEMS and amount of items in OPTM_GROUPS
                                             -- IMPORTANT: If SAVE_SETTINGS is true and OPTM_SIZE changes: Make sure to re-generate and
                                             -- and re-distribute the config file. You can make a new one using M2M/tools/make_config.sh

-- Net size of the Options menu on the screen in characters (excluding the frame, which is hardcoded to two characters)
-- Without submenus: Use OPTM_SIZE as height, otherwise use the height of the largest menu view: count one line per
-- item that is visible at that level, including one line per submenu label, excluding the contents of submenus.
-- (A submenu view does NOT show its own label line - see _OPTM_STRUCT in M2M/rom/menu.asm.)
--
-- Since the drive lines carry menu dependencies (OPTM_DEP below), OPTM_DY must count
-- the SIMULTANEOUSLY visible lines, not the structural ones: the two twin lines of a
-- drive are mutually exclusive and count once, and the "Off" variant of a drive mode
-- excludes its "Disk Image"/"Hardware Floppy" pair.
-- Main menu view = 34 lines (2 header + 3 drive twins + Drive Settings + 28 others),
-- Drive Settings submenu view = 20 lines (22 structural minus one hidden mode
-- variant for df1 and df2 each), HDMI Settings submenu view = 7 lines,
-- HDMI Filter submenu view = 12 lines, VGA submenu view = 10 lines,
-- OSM Scaling submenu view = 13 lines, Volume submenu view = 25 lines,
-- Stereo Mix submenu view = 8 lines, OSM-open key submenu view = 8 lines.
-- The main view is the tallest, so OPTM_DY tracks it.
--
-- CEILING: OPTM_DY + 2 (frame) must not exceed CHARS_DY = VGA_DY / FONT_DY = 36
-- (globals.vhd); the Shell anchors the options OSM at y = 0 (M2M/rom/screen.asm).
-- 34 + 2 = 36 means the main menu now fills the screen exactly - a further
-- main-menu line needs a line removed elsewhere or a smaller font.
constant OPTM_DX           : natural := 23;
constant OPTM_DY           : natural := 34;

-- OSM bit positions (zero-based line numbers) are decoded in mega65.vhd via C_MENU_* constants:
--   lines 12..14: Drives radio (C_MENU_DRIVES_*); how many Amiga units exist,
--                 line 14 (three drives) is the default
--   lines 17/18: df0 mode radio (C_MENU_DF0_IMG / _HW); df0 always exists
--   lines 21..23: df1 mode radio (C_MENU_DF1_IMG / _HW / _OFF)
--   lines 26..28: df2 mode radio (C_MENU_DF2_IMG / _HW / _OFF); line 27 default
--   line 37: 720p 50 Hz 16:9  / 38: 576p 50 4:3  / 39: 576p 50 5:4
--   line 55: HDMI Flicker-free toggle (C_MENU_HDMI_FF)
--   line 59: VGA Standard / 63: VGA 15 kHz with HS/VS / 64: VGA 15 kHz with CSYNC
--   lines 71..79: OSM Scaling radio (C_MENU_OSM_SCALING); 100% (71, default) down to 50% (79)
--   lines 88..108: Volume radio (C_MENU_VOLUME); 100% (88, default) down to 0% (108)
--   lines 114..117: Stereo crossfeed radio (C_MENU_STEREO); Full Stereo (114, default) /
--                 Wide Stereo / Narrow Stereo / Mono -> MiSTer aud_mix encoding
--   line 120: A500 Filter toggle (C_MENU_A500FILT), default ON; the fixed
--            4400 Hz low-pass behind Paula's DAC (off = A1200-style brightness)
--   line 121: LED Filter toggle (C_MENU_LEDFILT), default ON; arms the CIA-A PA1
--            power-LED low-pass so it follows the emulated software live
--   line 125: Keyboard "Amiga" radio (C_MENU_KBD_AMIGA); 0 = MEGA65 mode (default)
--   lines 130..133: OSM-open key radio (C_MENU_OSMKEY_*); Help (130, default) / F11 /
--                 F13 / MEGA+Run-Stop -> m2m_keyb's menu-open key (qnice_keys bit 7)
--   line 137: Slow RAM (A501) toggle (C_MENU_SLOWRAM), default ON; disabling it
--            removes the 512 KB at $C00000 from the Amiga memory map (issue #20).
--            The HDL cold-boots only the emulated Amiga on a change, so that
--            amiga_config.vhd replays the userio config while QNICE keeps running.
-- An OCS PAL Amiga is a 50 Hz machine, so only 50 Hz HDMI modes are offered.
-- Lines 45..52 (HDMI Filter radio) are NOT decoded in mega65.vhd: the firmware
-- dispatcher LOAD_HDMI_FILTER in CORE/m2m-rom/m2m-rom.asm reads them via
-- M2M$GET_SETTING and programs ascal directly (ASCAL_USAGE=1).
--
-- DRIVE LINES 2..7 - the "twin line" pattern, straight from C64MEGA65 (its
-- issue #93). Each Amiga unit owns TWO permanently allocated main-menu lines
-- and a menu dependency (OPTM_DEP below) decides which of them is on screen:
--   * the even line " dfN:%s" is the ADF mount item (manual CRT/ROM load into
--     C_DEV_AMIGA_ADF0/1/2), shown while that drive's mode is "Disk Image";
--   * the odd line " dfN:Hardware Floppy   " is a plain TEXT line showing the
--     real MEGA65 drive, shown while the mode is "Hardware Floppy".
--   * in mode "Off" neither line is shown and the drive vanishes from the menu.
-- Both variants therefore keep their own osm_control bit and their own byte in
-- the settings file; the HDL multiplexes the active variant explicitly. Hiding
-- a mount line does NOT renumber the manual CRT/ROM ids: CRTROM_M_GI counts
-- OPTM_G_LOAD_ROM occurrences in the STATIC array and is blind to visibility.
-- The hardware lines are padded to exactly OPTM_DX characters: that trailing
-- field is where the live drive status goes once the firmware writes it (the
-- C64MEGA65 "8:Internal 1581" pattern), and the fixed width is what lets it be
-- patched in the menu heap in place, without moving the arrays behind the
-- menu-struct pointers.
-- NEVER REORDER the lines (hardware-proven fatal 0x001F): submenu blocks are
-- contiguity-defined and M2M$CFM_DATA bit i is positionally bound to line i.
constant OPTM_ITEMS        : string :=

   " Amiga 500\n"           &    --    0: headline
   "\n"                     &    --    1: line

   " df0:%s\n"              &    --    2: mount ADF image into df0 (manual CRT/ROM 0)
   " df0:Hardware Floppy   \n" & --    3: TEXT twin of line 2 (live status field)
   " df1:%s\n"              &    --    4: mount ADF image into df1 (manual CRT/ROM 1)
   " df1:Hardware Floppy   \n" & --    5: TEXT twin of line 4
   " df2:%s\n"              &    --    6: mount ADF image into df2 (manual CRT/ROM 2)
   " df2:Hardware Floppy   \n" & --    7: TEXT twin of line 6

   " Drive Settings\n"      &    --    8: Drive Settings submenu (no %s)
   " Drive Settings\n"      &    --    9: headline (inside submenu)
   "\n"                     &    --  10: line
   " Drives\n"              &    --  11: headline
   "\n"                     &    --  12: line
   " 1\n"                   &    --  13: one Amiga unit (df0 only)
   " 2\n"                   &    --  14: two Amiga units (df0, df1)
   " 3\n"                   &    --  15: three Amiga units (df0, df1, df2); default
   "\n"                     &    --  16: line
   " Drive df0\n"           &    --  17: headline
   "\n"                     &    --  18: line
   " Disk Image\n"          &    --  19: df0 serves an ADF image; default
   " Hardware Floppy\n"     &    --  20: df0 is the real MEGA65 drive
   "\n"                     &    --  21: line
   " Drive df1\n"           &    --  22: headline
   "\n"                     &    --  23: line
   " Disk Image\n"          &    --  24: df1 serves an ADF image; default
   " Hardware Floppy\n"     &    --  25: df1 is the real MEGA65 drive
   " Off\n"                 &    --  26: df1 does not exist (only while Drives = 1)
   "\n"                     &    --  27: line
   " Drive df2\n"           &    --  28: headline
   "\n"                     &    --  29: line
   " Disk Image\n"          &    --  30: df2 serves an ADF image
   " Hardware Floppy\n"     &    --  31: df2 is the real MEGA65 drive; default
   " Off\n"                 &    --  32: df2 does not exist (while Drives = 1 or 2)
   "\n"                     &    --  33: line
   " Back to main menu\n"   &    --  34: close submenu

   "\n"                     &    --  35: line

   " Display\n"             &    --  36: headline (Display section)
   "\n"                     &    --  37: line

   " HDMI: %s\n"            &    --  38: HDMI submenu
   " HDMI Settings\n"       &    --  39: headline
   "\n"                     &    --  40: line
   " 720p 50 Hz 16:9\n"     &    --  41:
   " 576p 50 Hz 4:3\n"      &    --  42:
   " 576p 50 Hz 5:4\n"      &    --  43:
   "\n"                     &    --  44: line
   " Back to main menu\n"   &    --  45: close submenu

   " HDMI: %s\n"            &    --  46: HDMI Filter submenu, directly under HDMI Settings
   " HDMI Filter\n"         &    --  47: headline
   "\n"                     &    --  48: line
   " No Filter\n"           &    --  49: ascal native NEAREST
   " Sharp Bilinear\n"      &    --  50: ascal native SBILINEAR
   " Bicubic\n"             &    --  51: ascal native BICUBIC
   " Smooth\n"              &    --  52: polyphase
   " Lanczos\n"             &    --  53: polyphase; default
   " Scanlines\n"           &    --  54: polyphase; the former "CRT emulation" look
   " CRT (S-Video)\n"       &    --  55: polyphase
   " CRT (Composite)\n"     &    --  56: polyphase
   "\n"                     &    --  57: line
   " Back to main menu\n"   &    --  58: close submenu

   " HDMI: Flicker-free\n"  &    --  59: single-select toggle, default ON (issue #12)

   " VGA: %s\n"             &    --  60: VGA (analog output) submenu
   " VGA Display Mode\n"    &    --  61: headline
   "\n"                     &    --  62: line
   " Standard\n"            &    --  63: scandoubled 31.25 kHz; default
   "\n"                     &    --  64: line
   " Retro 15 kHz mode\n"   &    --  65: text (sub-headline for the two 15 kHz options)
   "\n"                     &    --  66: line
   " 15 kHz with HS/VS\n"   &    --  67: raw 15.625 kHz RGB, separate syncs
   " 15 kHz with CSYNC\n"   &    --  68: raw 15.625 kHz RGB, composite sync (SCART)
   "\n"                     &    --  69: line
   " Back to main menu\n"   &    --  70: close submenu

   " Reload Screen Config\n" &   --  71: re-read /amiga/screen_*.bin (no re-synth)

   " OSM: %s\n"             &    --  72: OSM Scaling submenu, directly under Reload Screen Config
   " OSM Scaling\n"         &    --  73: headline (inside submenu)
   "\n"                     &    --  74: line
   " 100%\n"                &    --  75: full size; default
   " 94%\n"                 &    --  76:
   " 88%\n"                 &    --  77:
   " 81%\n"                 &    --  78:
   " 75%\n"                 &    --  79:
   " 69%\n"                 &    --  80:
   " 63%\n"                 &    --  81:
   " 56%\n"                 &    --  82:
   " 50%\n"                 &    --  83:
   "\n"                     &    --  84: line
   " Back to main menu\n"   &    --  85: close submenu

   "\n"                     &    --  86: line

   " Audio\n"               &    --  87: headline (Audio section)
   "\n"                     &    --  88: line

   " Volume: %s\n"          &    --  89: Volume submenu (master volume)
   " Volume Control\n"      &    --  90: headline (inside submenu)
   "\n"                     &    --  91: line
   " 100%\n"                &    --  92: full volume; default (bit-transparent)
   " 95%\n"                 &    --  93:
   " 90%\n"                 &    --  94:
   " 85%\n"                 &    --  95:
   " 80%\n"                 &    --  96:
   " 75%\n"                 &    --  97:
   " 70%\n"                 &    --  98:
   " 65%\n"                 &    --  99:
   " 60%\n"                 &    -- 100:
   " 55%\n"                 &    -- 101:
   " 50%\n"                 &    -- 102:
   " 45%\n"                 &    -- 103:
   " 40%\n"                 &    -- 104:
   " 35%\n"                 &    -- 105:
   " 30%\n"                 &    -- 106:
   " 25%\n"                 &    -- 107:
   " 20%\n"                 &    -- 108:
   " 15%\n"                 &    -- 109:
   " 10%\n"                 &    -- 110:
   " 5%\n"                  &    -- 111:
   " 0%\n"                  &    -- 112: mute
   "\n"                     &    -- 113: line
   " Back to main menu\n"   &    -- 114: close submenu

   " Stereo: %s\n"          &    -- 115: Stereo Mix submenu (crossfeed), directly under Volume
   " Stereo Mix\n"          &    -- 116: headline (inside submenu)
   "\n"                     &    -- 117: line
   " Full Stereo\n"         &    -- 118: authentic hard-panned Paula; default
   " Wide Stereo\n"         &    -- 119: gentle crossfeed (87.5% / 12.5%)
   " Narrow Stereo\n"       &    -- 120: strong crossfeed (75% / 25%)
   " Mono\n"                &    -- 121: both channels merged
   "\n"                     &    -- 122: line
   " Back to main menu\n"   &    -- 123: close submenu

   " A500 Filter\n"         &    -- 124: single-select toggle, default ON (A500 fixed low-pass)
   " LED Filter\n"          &    -- 125: single-select toggle, default ON (CIA-A PA1 low-pass)
   "\n"                     &    -- 126: line

   " Keyboard\n"            &    -- 127: headline (Keyboard section, issue #6)
   "\n"                     &    -- 128: line
   " Amiga\n"               &    -- 129: keyboard mode radio: pure positional (C_MENU_KBD_AMIGA)
   " MEGA65\n"              &    -- 130: keyboard mode radio: semantic "cap is law"; default

   " OSM: %s\n"             &    -- 131: OSM-open key submenu (issue #8): "OSM: <choice>"
   " Key to open the menu\n" &   -- 132: headline (inside submenu)
   "\n"                     &    -- 133: line
   " Help\n"                &    -- 134: OSMKEY radio: Help (C_MENU_OSMKEY_HELP); default
   " F11\n"                 &    -- 135: OSMKEY radio: F11 (C_MENU_OSMKEY_F11)
   " F13\n"                 &    -- 136: OSMKEY radio: F13 (C_MENU_OSMKEY_F13)
   " MEGA + Run/Stop\n"     &    -- 137: OSMKEY radio: MEGA+Run/Stop combo (C_MENU_OSMKEY_COMBO)
   "\n"                     &    -- 138: line
   " Back to main menu\n"   &    -- 139: close submenu

   "\n"                     &    -- 140: line
   " Slow RAM (A501)\n"     &    -- 141: single-select toggle, default ON (issue #20)
   "\n"                     &    -- 142: line
   " About & Help\n"        &    -- 143: help
   "\n"                     &    -- 144: line
   " Close Menu\n";              -- 145: close

-- define your own constants here and choose meaningful names
-- make sure that your first group uses the value 1 (0 means "no menu item", such as text and line),
-- and be aware that you can only have a maximum of 254 groups (255 means "Close Menu");
-- also make sure that your group numbers are monotonic increasing (e.g. 1, 2, 3, 4, ...)
-- single-select items and therefore also drive mount items need to have unique identifiers
constant OPTM_G_ADF0       : integer := 1;   -- mount ADF for df0 (manual CRT/ROM load 0)
constant OPTM_G_HDMI       : integer := 2;
constant OPTM_G_FILTER     : integer := 3;   -- HDMI Filter radio; mirrored as OPTM_G_FLT in CORE/m2m-rom/m2m-rom.asm
constant OPTM_G_VGA        : integer := 4;   -- VGA/analog output mode radio (Standard / 15 kHz HS+VS / 15 kHz CSYNC)
constant OPTM_G_About      : integer := 5;
constant OPTM_G_SCRRELOAD  : integer := 6;   -- momentary: re-read /amiga/screen_*.bin
constant OPTM_G_HDMIFF     : integer := 7;   -- HDMI flicker-free toggle (issue #12); read in HDL (mega65.vhd)
constant OPTM_G_KBD        : integer := 8;   -- keyboard mapping mode radio (issue #6): Amiga / MEGA65; read in HDL (mega65.vhd)
constant OPTM_G_OSMKEY     : integer := 9;   -- OSM-open key radio (issue #8): Help / F11 / F13 / MEGA+Run-Stop; read in HDL (mega65.vhd)
constant OPTM_G_OSM_MODE   : integer := 10;  -- OSM Scaling radio; read in HDL (mega65.vhd)
constant OPTM_G_SLOWRAM    : integer := 11;  -- Slow RAM (A501) toggle (issues #20/#21); read and locally cold-booted in mega65.vhd
constant OPTM_G_VOLUME     : integer := 12;  -- master volume radio (5% steps); read in HDL (mega65.vhd), attenuation applied in main.vhd
constant OPTM_G_STEREO     : integer := 13;  -- stereo crossfeed radio (MiSTer aud_mix blends); read in HDL (mega65.vhd), applied in audio_filters.vhd
constant OPTM_G_A500FILT   : integer := 14;  -- A500 Filter toggle (fixed 4400 Hz low-pass); read in HDL (mega65.vhd)
constant OPTM_G_LEDFILT    : integer := 15;  -- LED Filter toggle (CIA-A PA1 power-LED low-pass); read in HDL (mega65.vhd)

-- Floppy drives. Every unit that can ever be a simulated ADF drive needs its OWN
-- mount group, because a manual CRT/ROM line is bound to its id by its position in
-- the static array (see the DRIVE LINES comment above).
constant OPTM_G_ADF1       : integer := 16;  -- mount ADF for df1 (manual CRT/ROM load 1)
constant OPTM_G_ADF2       : integer := 17;  -- mount ADF for df2 (manual CRT/ROM load 2)
constant OPTM_G_DRIVES     : integer := 18;  -- how many Amiga units exist (1 / 2 / 3); read in HDL (mega65.vhd)
constant OPTM_G_DF0MODE    : integer := 19;  -- df0 mode radio: Disk Image / Hardware Floppy
constant OPTM_G_DF1MODE    : integer := 20;  -- df1 mode radio: Disk Image / Hardware Floppy / Off
constant OPTM_G_DF2MODE    : integer := 21;  -- df2 mode radio: Disk Image / Hardware Floppy / Off

-- Smart dependencies (M2M-UPSTREAM osm-deps): tag a line so that it is only visible
-- while one of the items of a "mother" group is selected. This is a pure VISIBILITY
-- layer - a dependent line keeps its own osm_control bit, its own saved config-file
-- byte and its own default state, so nothing about the C_MENU_* mapping in mega65.vhd
-- or about osm_const.asm changes.
--
-- OPTM_DEP(m, i)         visible while item i of mother group m is selected
-- OPTM_DEP2(m, i, j)     visible while item i OR item j of mother group m is selected
--
-- Items 0..3 ONLY: the item selector is a 4-bit mask (bits 28..25) and item 4 would
-- collide with OPTM_G_DEPENDENT itself and overflow the integer range below. For a
-- single-select mother, item 0 means "while it is off" and item 1 "while it is on".
--
-- The drive block below uses two constructs that C64MEGA65 does not, and both are
-- covered by the boot validator in M2M/rom/optm_deps.asm (its class 2 and class 3
-- were relaxed accordingly, see the M2M-UPSTREAM note there):
--   * a PARTIALLY VISIBLE radio group - the members of OPTM_G_DF1MODE / DF2MODE
--     carry different masks, so the count radio swaps "Disk Image + Hardware
--     Floppy" against "Off". The masks of one group must reference the same
--     mother and must together cover every mother item, so exactly one variant
--     is on screen in every state.
--   * a two-level CHAIN - those mode radios are dependent themselves AND are the
--     mothers of the main-menu twins. That is sound because visibility is derived
--     from the SELECTED item only, never from another line's visibility, and the
--     firmware keeps the selected mode item inside the visible variant.
function OPTM_DEP(mother : natural; item : natural) return natural is
begin
   return OPTM_G_DEPENDENT + ((2 ** item) * 16#02000000#) + (mother * 16#00020000#);
end function OPTM_DEP;
function OPTM_DEP2(mother : natural; item_a : natural; item_b : natural) return natural is
begin
   return OPTM_G_DEPENDENT + ((2 ** item_a + 2 ** item_b) * 16#02000000#) + (mother * 16#00020000#);
end function OPTM_DEP2;

-- !!! DO NOT TOUCH !!!
type OPTM_GTYPE is array (0 to OPTM_SIZE - 1) of integer range 0 to 2**OPTM_GTC- 1;

-- define your menu groups: which menu items are belonging together to form a group?
-- where are separator lines? which items should be selected by default?
-- make sure that you have exactly the same amount of entries here than in OPTM_ITEMS and defined by OPTM_SIZE
-- NOTE: the structure is fully STATIC in every drive configuration - three
-- mount/hardware twin pairs at 2..7, Drive Settings submenu at 8..30. Only the
-- VISIBILITY of the twins follows the drive modes (OPTM_DEP), and only the
-- status text of the hardware lines is firmware-rewritten in place.
constant OPTM_GROUPS       : OPTM_GTYPE := ( OPTM_G_TEXT + OPTM_G_HEADLINE,            --    0: Headline "Amiga 500"
                                             OPTM_G_LINE,                              --    1: Line

                                             OPTM_G_ADF0 + OPTM_G_LOAD_ROM
                                                         + OPTM_G_START
                                                         + OPTM_DEP(OPTM_G_DF0MODE, 0),  --    2: mount ADF into df0; cursor start
                                             OPTM_G_TEXT + OPTM_DEP(OPTM_G_DF0MODE, 1),  --    3: Text: df0 is the hardware drive
                                             OPTM_G_ADF1 + OPTM_G_LOAD_ROM
                                                         + OPTM_DEP(OPTM_G_DF1MODE, 0),  --    4: mount ADF into df1
                                             OPTM_G_TEXT + OPTM_DEP(OPTM_G_DF1MODE, 1),  --    5: Text: df1 is the hardware drive
                                             OPTM_G_ADF2 + OPTM_G_LOAD_ROM
                                                         + OPTM_DEP(OPTM_G_DF2MODE, 0),  --    6: mount ADF into df2
                                             OPTM_G_TEXT + OPTM_DEP(OPTM_G_DF2MODE, 1),  --    7: Text: df2 is the hardware drive

                                             OPTM_G_SUBMENU,                           --    8: Drive Settings submenu head
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --    9: Headline "Drive Settings"
                                             OPTM_G_LINE,                              --  10: Line
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  11: Headline "Drives"
                                             OPTM_G_LINE,                              --  12: Line
                                             OPTM_G_DRIVES,                            --  13: 1
                                             OPTM_G_DRIVES,                            --  14: 2
                                             OPTM_G_DRIVES + OPTM_G_STDSEL,            --  15: 3 (default)
                                             OPTM_G_LINE,                              --  16: Line
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  17: Headline "Drive df0"
                                             OPTM_G_LINE,                              --  18: Line
                                             OPTM_G_DF0MODE + OPTM_G_STDSEL,           --  19: df0 Disk Image (default)
                                             OPTM_G_DF0MODE,                           --  20: df0 Hardware Floppy
                                             OPTM_G_LINE,                              --  21: Line
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  22: Headline "Drive df1"
                                             OPTM_G_LINE,                              --  23: Line
                                             OPTM_G_DF1MODE + OPTM_G_STDSEL
                                                    + OPTM_DEP2(OPTM_G_DRIVES, 1, 2),  --  24: df1 Disk Image (default)
                                             OPTM_G_DF1MODE
                                                    + OPTM_DEP2(OPTM_G_DRIVES, 1, 2),  --  25: df1 Hardware Floppy
                                             OPTM_G_DF1MODE
                                                    + OPTM_DEP(OPTM_G_DRIVES, 0),      --  26: df1 Off (only while Drives = 1)
                                             OPTM_G_LINE,                              --  27: Line
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  28: Headline "Drive df2"
                                             OPTM_G_LINE,                              --  29: Line
                                             OPTM_G_DF2MODE
                                                    + OPTM_DEP(OPTM_G_DRIVES, 2),      --  30: df2 Disk Image
                                             OPTM_G_DF2MODE + OPTM_G_STDSEL
                                                    + OPTM_DEP(OPTM_G_DRIVES, 2),      --  31: df2 Hardware Floppy (default)
                                             OPTM_G_DF2MODE
                                                    + OPTM_DEP2(OPTM_G_DRIVES, 0, 1),  --  32: df2 Off (while Drives = 1 or 2)
                                             OPTM_G_LINE,                              --  33: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            --  34: Close submenu / back to main menu

                                             OPTM_G_LINE,                              --  35: Line

                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  36: Headline "Display"
                                             OPTM_G_LINE,                              --  37: Line

                                             OPTM_G_SUBMENU,                           --  38: HDMI submenu block: "HDMI: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  39: Headline "HDMI Settings"
                                             OPTM_G_LINE,                              --  40: Line
                                             OPTM_G_HDMI + OPTM_G_STDSEL,              --  41: 720p 50 Hz 16:9, default
                                             OPTM_G_HDMI,                              --  42: 576p 50 Hz 4:3
                                             OPTM_G_HDMI,                              --  43: 576p 50 Hz 5:4
                                             OPTM_G_LINE,                              --  44: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            --  45: Close submenu / back to main menu

                                             OPTM_G_SUBMENU,                           --  46: HDMI Filter submenu block: "HDMI: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  47: Headline "HDMI Filter"
                                             OPTM_G_LINE,                              --  48: Line
                                             OPTM_G_FILTER,                            --  49: No Filter
                                             OPTM_G_FILTER,                            --  50: Sharp Bilinear
                                             OPTM_G_FILTER,                            --  51: Bicubic
                                             OPTM_G_FILTER,                            --  52: Smooth
                                             OPTM_G_FILTER + OPTM_G_STDSEL,            --  53: Lanczos (default)
                                             OPTM_G_FILTER,                            --  54: Scanlines
                                             OPTM_G_FILTER,                            --  55: CRT (S-Video)
                                             OPTM_G_FILTER,                            --  56: CRT (Composite)
                                             OPTM_G_LINE,                              --  57: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            --  58: Close submenu / back to main menu

                                             OPTM_G_HDMIFF + OPTM_G_SINGLESEL
                                                           + OPTM_G_STDSEL,            --  59: HDMI: Flicker-free (single-select, default ON)

                                             OPTM_G_SUBMENU,                           --  60: VGA submenu block: "VGA: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  61: Headline "VGA Display Mode"
                                             OPTM_G_LINE,                              --  62: Line
                                             OPTM_G_VGA + OPTM_G_STDSEL,               --  63: Standard (default)
                                             OPTM_G_LINE,                              --  64: Line
                                             OPTM_G_TEXT,                              --  65: Text "Retro 15 kHz mode"
                                             OPTM_G_LINE,                              --  66: Line
                                             OPTM_G_VGA,                               --  67: 15 kHz with HS/VS
                                             OPTM_G_VGA,                               --  68: 15 kHz with CSYNC
                                             OPTM_G_LINE,                              --  69: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            --  70: Close submenu / back to main menu

                                             OPTM_G_SCRRELOAD + OPTM_G_SINGLESEL,      --  71: Reload screen cfg (momentary action)

                                             OPTM_G_SUBMENU,                           --  72: OSM Scaling submenu block: "OSM: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  73: Headline "OSM Scaling"
                                             OPTM_G_LINE,                              --  74: Line
                                             OPTM_G_OSM_MODE + OPTM_G_STDSEL,          --  75: 100% (default)
                                             OPTM_G_OSM_MODE,                          --  76: 94%
                                             OPTM_G_OSM_MODE,                          --  77: 88%
                                             OPTM_G_OSM_MODE,                          --  78: 81%
                                             OPTM_G_OSM_MODE,                          --  79: 75%
                                             OPTM_G_OSM_MODE,                          --  80: 69%
                                             OPTM_G_OSM_MODE,                          --  81: 63%
                                             OPTM_G_OSM_MODE,                          --  82: 56%
                                             OPTM_G_OSM_MODE,                          --  83: 50%
                                             OPTM_G_LINE,                              --  84: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            --  85: Close submenu / back to main menu

                                             OPTM_G_LINE,                              --  86: Line

                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  87: Headline "Audio"
                                             OPTM_G_LINE,                              --  88: Line

                                             OPTM_G_SUBMENU,                           --  89: Volume submenu block: "Volume: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  90: Headline "Volume Control"
                                             OPTM_G_LINE,                              --  91: Line
                                             OPTM_G_VOLUME + OPTM_G_STDSEL,            --  92: 100% (default)
                                             OPTM_G_VOLUME,                            --  93: 95%
                                             OPTM_G_VOLUME,                            --  94: 90%
                                             OPTM_G_VOLUME,                            --  95: 85%
                                             OPTM_G_VOLUME,                            --  96: 80%
                                             OPTM_G_VOLUME,                            --  97: 75%
                                             OPTM_G_VOLUME,                            --  98: 70%
                                             OPTM_G_VOLUME,                            --  99: 65%
                                             OPTM_G_VOLUME,                            -- 100: 60%
                                             OPTM_G_VOLUME,                            -- 101: 55%
                                             OPTM_G_VOLUME,                            -- 102: 50%
                                             OPTM_G_VOLUME,                            -- 103: 45%
                                             OPTM_G_VOLUME,                            -- 104: 40%
                                             OPTM_G_VOLUME,                            -- 105: 35%
                                             OPTM_G_VOLUME,                            -- 106: 30%
                                             OPTM_G_VOLUME,                            -- 107: 25%
                                             OPTM_G_VOLUME,                            -- 108: 20%
                                             OPTM_G_VOLUME,                            -- 109: 15%
                                             OPTM_G_VOLUME,                            -- 110: 10%
                                             OPTM_G_VOLUME,                            -- 111: 5%
                                             OPTM_G_VOLUME,                            -- 112: 0% (mute)
                                             OPTM_G_LINE,                              -- 113: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 114: Close submenu / back to main menu

                                             OPTM_G_SUBMENU,                           -- 115: Stereo Mix submenu block: "Stereo: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 116: Headline "Stereo Mix"
                                             OPTM_G_LINE,                              -- 117: Line
                                             OPTM_G_STEREO + OPTM_G_STDSEL,            -- 118: Full Stereo (default)
                                             OPTM_G_STEREO,                            -- 119: Wide Stereo
                                             OPTM_G_STEREO,                            -- 120: Narrow Stereo
                                             OPTM_G_STEREO,                            -- 121: Mono
                                             OPTM_G_LINE,                              -- 122: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 123: Close submenu / back to main menu

                                             OPTM_G_A500FILT + OPTM_G_SINGLESEL
                                                             + OPTM_G_STDSEL,          -- 124: A500 Filter (single-select, default ON)
                                             OPTM_G_LEDFILT + OPTM_G_SINGLESEL
                                                            + OPTM_G_STDSEL,           -- 125: LED Filter (single-select, default ON)
                                             OPTM_G_LINE,                              -- 126: Line

                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 127: Headline "Keyboard"
                                             OPTM_G_LINE,                              -- 128: Line
                                             OPTM_G_KBD,                               -- 129: Amiga (pure positional)
                                             OPTM_G_KBD + OPTM_G_STDSEL,               -- 130: MEGA65 (semantic; default)

                                             OPTM_G_SUBMENU,                           -- 131: OSM-open key submenu block: "OSM: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 132: Headline "Key to open the menu"
                                             OPTM_G_LINE,                              -- 133: Line
                                             OPTM_G_OSMKEY + OPTM_G_STDSEL,            -- 134: Help (default opener)
                                             OPTM_G_OSMKEY,                            -- 135: F11
                                             OPTM_G_OSMKEY,                            -- 136: F13
                                             OPTM_G_OSMKEY,                            -- 137: MEGA + Run/Stop
                                             OPTM_G_LINE,                              -- 138: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 139: Close submenu / back to main menu

                                             OPTM_G_LINE,                              -- 140: Line
                                             OPTM_G_SLOWRAM + OPTM_G_SINGLESEL
                                                            + OPTM_G_STDSEL,           -- 141: Slow RAM (A501) (single-select, default ON)
                                             OPTM_G_LINE,                              -- 142: Line
                                             OPTM_G_About   + OPTM_G_HELP,             -- 143: About & Help (WHS(1))
                                             OPTM_G_LINE,                              -- 144: Line
                                             OPTM_G_CLOSE                              -- 145: Close Menu
                                           );

--------------------------------------------------------------------------------------------------------------------
-- !!! CAUTION: M2M FRAMEWORK CODE !!! DO NOT TOUCH ANYTHING BELOW THIS LINE !!!
--------------------------------------------------------------------------------------------------------------------

--------------------------------------------------------------------------------------------------------------------
-- Address Decoding
--------------------------------------------------------------------------------------------------------------------

begin

addr_decode : process(clk_i)
   -- return ASCII value of given string at the position defined by index (zero-based)
   pure function str2data(str : string; index : integer) return std_logic_vector is
   variable strpos : integer;
   begin
      strpos := index + 1;
      if strpos <= str'length then
         return std_logic_vector(to_unsigned(character'pos(str(strpos)), 16));
      else
         return X"0000"; -- zero terminated strings
      end if;
   end function str2data;

   -- return the dimensions of the Options menu
   pure function getDXDY(dx, dy, index: natural) return std_logic_vector is
   begin
      case index is
         when 0 => return std_logic_vector(to_unsigned(dx + 2, 16));
         when 1 => return std_logic_vector(to_unsigned(dy + 2, 16));
         when others => return X"0000";
      end case;
   end function getDXDY;

   -- convert bool to std_logic_vector
   pure function bool2slv(b: boolean) return std_logic_vector is
   begin
      if b then
         return x"0001";
      else
         return x"0000";
      end if;
   end function bool2slv;

   -- return the General Configuration settings
   function getGenConf(index: natural) return std_logic_vector is
   begin
      case index is
         when 1      => return std_logic_vector(to_unsigned(RESET_COUNTER, 16));
         when 2      => return bool2slv(OPTM_PAUSE);
         when 3      => return bool2slv(WELCOME_ACTIVE);
         when 4      => return bool2slv(WELCOME_AT_RESET);
         when 5      => return bool2slv(KEYBOARD_AT_RESET);
         when 6      => return bool2slv(JOY_1_AT_RESET);
         when 7      => return bool2slv(JOY_2_AT_RESET);
         when 8      => return bool2slv(KEYBOARD_AT_OSD);
         when 9      => return bool2slv(JOY_1_AT_OSD);
         when 10     => return bool2slv(JOY_2_AT_OSD);
         when 11     => return std_logic_vector(to_unsigned(ASCAL_USAGE, 16));
         when 12     => return std_logic_vector(to_unsigned(ASCAL_MODE, 16));
         when 13     => return std_logic_vector(to_unsigned(VD_ANTI_THRASHING_DELAY, 16));
         when 14     => return std_logic_vector(to_unsigned(VD_ITERATION_SIZE, 16));
         when 15     => return bool2slv(SAVE_SETTINGS);
         when others => return x"0000";
      end case;
   end function getGenConf;

   variable index           : integer;
   variable whs_page_index  : integer;
   variable whs_array_index : integer;

begin

   if falling_edge(clk_i) then

      index := to_integer(unsigned(address_i(11 downto 0)));
      whs_page_index  := to_integer(unsigned(address_i(19 downto 12)));
      whs_array_index := to_integer(unsigned(address_i(23 downto 20)));

      data_o <= x"EEEE";

      -----------------------------------------------------------------------------------
      -- Welcome & Help System: upper 4 bits of address equal SEL_WHS' upper 4 bits
      -----------------------------------------------------------------------------------

      if address_i(27 downto 24) = SEL_WHS(15 downto 12) then

         if  whs_array_index < WHS_RECORDS then
            if index = 4095 then
               data_o <= std_logic_vector(to_unsigned(WHS(whs_array_index).page_count, 16));
            else
               if index < WHS(whs_array_index).page_length(whs_page_index) then
                  data_o <= str2data(WHS_DATA, WHS(whs_array_index).page_start(whs_page_index) + index);
               else
                  data_o <= (others => '0'); -- zero-terminated strings
               end if;
            end if;
         end if;

      -----------------------------------------------------------------------------------
      -- All other selectors, which are 16-bit values
      -----------------------------------------------------------------------------------

      else

         case address_i(27 downto 12) is
            when SEL_GENERAL           => data_o <= getGenConf(index);
            when SEL_DIR_START         => data_o <= str2data(DIR_START, index);
            when SEL_CFG_FILE          => data_o <= str2data(CFG_FILE, index);
            when SEL_CORENAME          => data_o <= str2data(CORENAME, index);
            when SEL_OPTM_ITEMS        => data_o <= str2data(OPTM_ITEMS, index);
            when SEL_OPTM_MOUNT_STR    => data_o <= str2data(OPTM_S_MOUNT, index);
            when SEL_OPTM_CRTROM_STR   => data_o <= str2data(OPTM_S_CRTROM, index);
            when SEL_OPTM_SAVING_STR   => data_o <= str2data(OPTM_S_SAVING, index);
            when SEL_OPTM_GROUPS       => data_o <= std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15)) &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(14)) & "0" &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(12)) & "0000" &
                                                    std_logic_vector(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(7 downto 0));
            when SEL_OPTM_STDSEL       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(8));
            when SEL_OPTM_LINES        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(9));
            when SEL_OPTM_START        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(10));
            when SEL_OPTM_MOUNT_DRV    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(11));
            when SEL_OPTM_HELP         => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(13));
            when SEL_OPTM_SINGLESEL    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15));
            when SEL_OPTM_CRTROM       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(16));
            when SEL_OPTM_ICOUNT       => data_o <= x"00" & std_logic_vector(to_unsigned(OPTM_SIZE, 8));
            when SEL_OPTM_DIMENSIONS   => data_o <= getDXDY(OPTM_DX, OPTM_DY, index);

            -- Smart dependencies (M2M-UPSTREAM osm-deps). Index 4095 is the feature
            -- probe: a config.vhd without this arm falls through to "when others =>
            -- null" and keeps the x"EEEE" pre-assignment, which OPTM_DEPS_PROBE reads
            -- as "feature not available" - so the firmware stays compatible with an
            -- older core. x"2DEF" selects dependency format 2 (4-bit item mask).
            -- Served word: bit 12 = dependent flag, bits 11-8 = mother item mask,
            -- bits 7-0 = mother group id.
            when SEL_OPTM_DEPS         => if index = 4095 then
                                             data_o <= x"2DEF";
                                          else
                                             data_o <= "000" &
                                                std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(29)) &
                                                std_logic_vector(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(28 downto 25)) &
                                                std_logic_vector(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(24 downto 17));
                                          end if;

            when others                => null;
         end case;
      end if;
   end if;
end process;

end architecture beh;
