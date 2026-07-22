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
constant CORE_VERSION : string := "V1";

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
   " Battery-backed real-time clock\n\n" &
   
   " Mouse:    Port 1\n" &
   " Joystick: Port 2\n\n" &  

   " One read/write floppy drive: df0:\n" &
   " Standard 880 KB ADF disk images\n\n" &

   " Not implemented, yet:\n" &
   " More disk drives (df1:), hard disks\n" &
   " Kickstart newer than 1.3\n" &
   " ECS/AGA, NTSC, Fast RAM, hard disks\n\n" &
   "\n\n\n" &  -- keep footer at bottom

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

   " Select ADF: in the menu.\n\n" &

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

constant OPTM_GTC          : natural := 17;                -- Amount of significant bits in OPTM_G_* constants

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
constant OPTM_SIZE         : natural := 74;  -- amount of items including empty lines:
                                             -- needs to be equal to the number of lines in OPTM_ITEMS and amount of items in OPTM_GROUPS
                                             -- IMPORTANT: If SAVE_SETTINGS is true and OPTM_SIZE changes: Make sure to re-generate and
                                             -- and re-distribute the config file. You can make a new one using M2M/tools/make_config.sh

-- Net size of the Options menu on the screen in characters (excluding the frame, which is hardcoded to two characters)
-- Without submenus: Use OPTM_SIZE as height, otherwise use the height of the largest menu view: count one line per
-- item that is visible at that level, including one line per submenu label, excluding the contents of submenus.
-- (A submenu view does NOT show its own label line - see _OPTM_STRUCT in M2M/rom/menu.asm.)
-- Main menu view = 24 lines, HDMI Settings submenu view = 7 lines,
-- HDMI Filter submenu view = 12 lines, VGA submenu view = 10 lines,
-- OSM Scaling submenu view = 13 lines, OSM-open key submenu view = 8 lines.
-- The main view is the tallest, so OPTM_DY tracks it.
constant OPTM_DX           : natural := 23;
constant OPTM_DY           : natural := 24;

-- OSM bit positions (zero-based line numbers) are decoded in mega65.vhd via C_MENU_* constants:
--   line  9: 720p 50 Hz 16:9  / 10: 576p 50 4:3  / 11: 576p 50 5:4
--   line 27: HDMI Flicker-free toggle (C_MENU_HDMI_FF)
--   line 31: VGA Standard / 35: VGA 15 kHz with HS/VS / 36: VGA 15 kHz with CSYNC
--   lines 43..51: OSM Scaling radio (C_MENU_OSM_SCALING); 100% (43, default) down to 50% (51)
--   line 57: Keyboard "Amiga" radio (C_MENU_KBD_AMIGA); 0 = MEGA65 mode (default)
--   lines 62..65: OSM-open key radio (C_MENU_OSMKEY_*); Help (62, default) / F11 /
--                 F13 / MEGA+Run-Stop -> m2m_keyb's menu-open key (qnice_keys bit 7)
--   line 69: Slow RAM (A501) toggle (C_MENU_SLOWRAM), default ON; disabling it
--            removes the 512 KB at $C00000 from the Amiga memory map (issue #20).
--            The HDL cold-boots only the emulated Amiga on a change, so that
--            amiga_config.vhd replays the userio config while QNICE keeps running.
-- An OCS PAL Amiga is a 50 Hz machine, so only 50 Hz HDMI modes are offered.
-- Lines 17..24 (HDMI Filter radio) are NOT decoded in mega65.vhd: the firmware
-- dispatcher LOAD_HDMI_FILTER in CORE/m2m-rom/m2m-rom.asm reads them via
-- M2M$GET_SETTING and programs ascal directly (ASCAL_USAGE=1).
-- Line 2 (" ADF:%s") is a manual CRT/ROM load item handled by the Shell: it
-- opens the file browser and streams the .adf into the C_DEV_AMIGA_ADF device.
constant OPTM_ITEMS        : string :=

   " Amiga 500\n"           &    --  0: headline
   "\n"                     &    --  1: line

   " ADF:%s\n"              &    --  2: mount ADF disk image (df0:)
   "\n"                     &    --  3: line

   " Display\n"             &    --  4: headline (Display section)
   "\n"                     &    --  5: line

   " HDMI: %s\n"            &    --  6: HDMI submenu
   " HDMI Settings\n"       &    --  7: headline
   "\n"                     &    --  8: line
   " 720p 50 Hz 16:9\n"     &    --  9
   " 576p 50 Hz 4:3\n"      &    -- 10
   " 576p 50 Hz 5:4\n"      &    -- 11
   "\n"                     &    -- 12: line
   " Back to main menu\n"   &    -- 13: close submenu

   " HDMI: %s\n"            &    -- 14: HDMI Filter submenu, directly under HDMI Settings
   " HDMI Filter\n"         &    -- 15: headline
   "\n"                     &    -- 16: line
   " No Filter\n"           &    -- 17: ascal native NEAREST
   " Sharp Bilinear\n"      &    -- 18: ascal native SBILINEAR
   " Bicubic\n"             &    -- 19: ascal native BICUBIC
   " Smooth\n"              &    -- 20: polyphase
   " Lanczos\n"             &    -- 21: polyphase; default
   " Scanlines\n"           &    -- 22: polyphase; the former "CRT emulation" look
   " CRT (S-Video)\n"       &    -- 23: polyphase
   " CRT (Composite)\n"     &    -- 24: polyphase
   "\n"                     &    -- 25: line
   " Back to main menu\n"   &    -- 26: close submenu

   " HDMI: Flicker-free\n"  &    -- 27: single-select toggle, default ON (issue #12)

   " VGA: %s\n"             &    -- 28: VGA (analog output) submenu
   " VGA Display Mode\n"    &    -- 29: headline
   "\n"                     &    -- 30: line
   " Standard\n"            &    -- 31: scandoubled 31.25 kHz; default
   "\n"                     &    -- 32: line
   " Retro 15 kHz mode\n"   &    -- 33: text (sub-headline for the two 15 kHz options)
   "\n"                     &    -- 34: line
   " 15 kHz with HS/VS\n"   &    -- 35: raw 15.625 kHz RGB, separate syncs
   " 15 kHz with CSYNC\n"   &    -- 36: raw 15.625 kHz RGB, composite sync (SCART)
   "\n"                     &    -- 37: line
   " Back to main menu\n"   &    -- 38: close submenu

   " Reload Screen Config\n" &   -- 39: re-read /amiga/screen_*.bin (no re-synth)

   " OSM: %s\n"             &    -- 40: OSM Scaling submenu, directly under Reload Screen Config
   " OSM Scaling\n"         &    -- 41: headline (inside submenu)
   "\n"                     &    -- 42: line
   " 100%\n"                &    -- 43: full size; default
   " 94%\n"                 &    -- 44
   " 88%\n"                 &    -- 45
   " 81%\n"                 &    -- 46
   " 75%\n"                 &    -- 47
   " 69%\n"                 &    -- 48
   " 63%\n"                 &    -- 49
   " 56%\n"                 &    -- 50
   " 50%\n"                 &    -- 51
   "\n"                     &    -- 52: line
   " Back to main menu\n"   &    -- 53: close submenu

   "\n"                     &    -- 54: line

   " Keyboard\n"            &    -- 55: headline (Keyboard section, issue #6)
   "\n"                     &    -- 56: line
   " Amiga\n"               &    -- 57: keyboard mode radio: pure positional (C_MENU_KBD_AMIGA)
   " MEGA65\n"              &    -- 58: keyboard mode radio: semantic "cap is law"; default

   " OSM: %s\n"             &    -- 59: OSM-open key submenu (issue #8): "OSM: <choice>"
   " Key to open the menu\n" &   -- 60: headline (inside submenu)
   "\n"                     &    -- 61: line
   " Help\n"                &    -- 62: OSMKEY radio: Help (C_MENU_OSMKEY_HELP); default
   " F11\n"                 &    -- 63: OSMKEY radio: F11 (C_MENU_OSMKEY_F11)
   " F13\n"                 &    -- 64: OSMKEY radio: F13 (C_MENU_OSMKEY_F13)
   " MEGA + Run/Stop\n"     &    -- 65: OSMKEY radio: MEGA+Run/Stop combo (C_MENU_OSMKEY_COMBO)
   "\n"                     &    -- 66: line
   " Back to main menu\n"   &    -- 67: close submenu

   "\n"                     &    -- 68: line
   " Slow RAM (A501)\n"     &    -- 69: single-select toggle, default ON (issue #20)
   "\n"                     &    -- 70: line
   " About & Help\n"        &    -- 71: help
   "\n"                     &    -- 72: line
   " Close Menu\n";              -- 73: close

-- define your own constants here and choose meaningful names
-- make sure that your first group uses the value 1 (0 means "no menu item", such as text and line),
-- and be aware that you can only have a maximum of 254 groups (255 means "Close Menu");
-- also make sure that your group numbers are monotonic increasing (e.g. 1, 2, 3, 4, ...)
-- single-select items and therefore also drive mount items need to have unique identifiers
constant OPTM_G_ADF        : integer := 1;   -- mount ADF for df0 (manual CRT/ROM load 0)
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

-- !!! DO NOT TOUCH !!!
type OPTM_GTYPE is array (0 to OPTM_SIZE - 1) of integer range 0 to 2**OPTM_GTC- 1;

-- define your menu groups: which menu items are belonging together to form a group?
-- where are separator lines? which items should be selected by default?
-- make sure that you have exactly the same amount of entries here than in OPTM_ITEMS and defined by OPTM_SIZE
constant OPTM_GROUPS       : OPTM_GTYPE := ( OPTM_G_TEXT + OPTM_G_HEADLINE,            --  0: Headline "Amiga 500"
                                             OPTM_G_LINE,                              --  1: Line

                                             OPTM_G_ADF + OPTM_G_LOAD_ROM
                                                        + OPTM_G_START,                --  2: mount ADF (df0:); cursor start
                                             OPTM_G_LINE,                              --  3: Line

                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  4: Headline "Display"
                                             OPTM_G_LINE,                              --  5: Line

                                             OPTM_G_SUBMENU,                           --  6: HDMI submenu block: "HDMI: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  7: Headline "HDMI Settings"
                                             OPTM_G_LINE,                              --  8: Line
                                             OPTM_G_HDMI + OPTM_G_STDSEL,              --  9: 720p 50 Hz 16:9, default
                                             OPTM_G_HDMI,                              -- 10: 576p 50 Hz 4:3
                                             OPTM_G_HDMI,                              -- 11: 576p 50 Hz 5:4
                                             OPTM_G_LINE,                              -- 12: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 13: Close submenu / back to main menu

                                             OPTM_G_SUBMENU,                           -- 14: HDMI Filter submenu block: "HDMI: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 15: Headline "HDMI Filter"
                                             OPTM_G_LINE,                              -- 16: Line
                                             OPTM_G_FILTER,                            -- 17: No Filter
                                             OPTM_G_FILTER,                            -- 18: Sharp Bilinear
                                             OPTM_G_FILTER,                            -- 19: Bicubic
                                             OPTM_G_FILTER,                            -- 20: Smooth
                                             OPTM_G_FILTER + OPTM_G_STDSEL,            -- 21: Lanczos (default)
                                             OPTM_G_FILTER,                            -- 22: Scanlines
                                             OPTM_G_FILTER,                            -- 23: CRT (S-Video)
                                             OPTM_G_FILTER,                            -- 24: CRT (Composite)
                                             OPTM_G_LINE,                              -- 25: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 26: Close submenu / back to main menu

                                             OPTM_G_HDMIFF + OPTM_G_SINGLESEL
                                                           + OPTM_G_STDSEL,            -- 27: HDMI: Flicker-free (single-select, default ON)

                                             OPTM_G_SUBMENU,                           -- 28: VGA submenu block: "VGA: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 29: Headline "VGA Display Mode"
                                             OPTM_G_LINE,                              -- 30: Line
                                             OPTM_G_VGA + OPTM_G_STDSEL,               -- 31: Standard (default)
                                             OPTM_G_LINE,                              -- 32: Line
                                             OPTM_G_TEXT,                              -- 33: Text "Retro 15 kHz mode"
                                             OPTM_G_LINE,                              -- 34: Line
                                             OPTM_G_VGA,                               -- 35: 15 kHz with HS/VS
                                             OPTM_G_VGA,                               -- 36: 15 kHz with CSYNC
                                             OPTM_G_LINE,                              -- 37: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 38: Close submenu / back to main menu

                                             OPTM_G_SCRRELOAD + OPTM_G_SINGLESEL,      -- 39: Reload screen cfg (momentary action)

                                             OPTM_G_SUBMENU,                           -- 40: OSM Scaling submenu block: "OSM: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 41: Headline "OSM Scaling"
                                             OPTM_G_LINE,                              -- 42: Line
                                             OPTM_G_OSM_MODE + OPTM_G_STDSEL,           -- 43: 100% (default)
                                             OPTM_G_OSM_MODE,                          -- 44: 94%
                                             OPTM_G_OSM_MODE,                          -- 45: 88%
                                             OPTM_G_OSM_MODE,                          -- 46: 81%
                                             OPTM_G_OSM_MODE,                          -- 47: 75%
                                             OPTM_G_OSM_MODE,                          -- 48: 69%
                                             OPTM_G_OSM_MODE,                          -- 49: 63%
                                             OPTM_G_OSM_MODE,                          -- 50: 56%
                                             OPTM_G_OSM_MODE,                          -- 51: 50%
                                             OPTM_G_LINE,                              -- 52: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 53: Close submenu / back to main menu

                                             OPTM_G_LINE,                              -- 54: Line

                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 55: Headline "Keyboard"
                                             OPTM_G_LINE,                              -- 56: Line
                                             OPTM_G_KBD,                               -- 57: Amiga (pure positional)
                                             OPTM_G_KBD + OPTM_G_STDSEL,               -- 58: MEGA65 (semantic; default)

                                             OPTM_G_SUBMENU,                           -- 59: OSM-open key submenu block: "OSM: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 60: Headline "Key to open the menu"
                                             OPTM_G_LINE,                              -- 61: Line
                                             OPTM_G_OSMKEY + OPTM_G_STDSEL,            -- 62: Help (default opener)
                                             OPTM_G_OSMKEY,                            -- 63: F11
                                             OPTM_G_OSMKEY,                            -- 64: F13
                                             OPTM_G_OSMKEY,                            -- 65: MEGA + Run/Stop
                                             OPTM_G_LINE,                              -- 66: Line
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 67: Close submenu / back to main menu

                                             OPTM_G_LINE,                              -- 68: Line
                                             OPTM_G_SLOWRAM + OPTM_G_SINGLESEL
                                                            + OPTM_G_STDSEL,           -- 69: Slow RAM (A501) (single-select, default ON)
                                             OPTM_G_LINE,                              -- 70: Line
                                             OPTM_G_About   + OPTM_G_HELP,             -- 71: About & Help (WHS(1))
                                             OPTM_G_LINE,                              -- 72: Line
                                             OPTM_G_CLOSE                              -- 73: Close Menu
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

            when others                => null;
         end case;
      end if;
   end if;
end process;

end architecture beh;
